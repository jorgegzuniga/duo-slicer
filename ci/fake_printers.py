#!/usr/bin/env python3
"""Stand-in printers for the CI runner, so the app's printer code runs against something real:

  Bambu Lab P1S  (first address): MQTT over TLS (8883, certificate named with its serial number, AMS report, prints
                 when told to), implicit FTPS (990, takes the upload), JPEG camera over TLS (6000)
  Snapmaker U1   (second address): Moonraker (7125): status with four heads, upload, start/pause/cancel, prints,
                 camera snapshot (monitor.jpg) and the WebSocket that keeps the U1's camera monitor running
  Bambu Lab X1C  (third address, optional): MQTT (8883), FTPS (990), RTSPS H.264 camera (322, Digest login)

A print takes about 50 seconds: preparing, then layers, then finished. The access code is 12345678.

    fake_printers.py <p1s address> <u1 address> [<x1c address>]
"""
import base64
import hashlib
import http.server
import json
import os
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

P1S_IP, U1_IP = sys.argv[1], sys.argv[2]
X1C_IP = sys.argv[3] if len(sys.argv) > 3 else None
CODE = "12345678"
HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
PRINT_SECONDS = 45
PREPARE_SECONDS = 6


LOG_LOCK = threading.Lock()


def log(msg):
    with LOG_LOCK:
        print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def asset(name):
    with open(os.path.join(ASSETS, name), "rb") as f:
        return f.read()


def tls_context(cn):
    work = tempfile.mkdtemp()
    key, cert = os.path.join(work, "key.pem"), os.path.join(work, "cert.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                    "-days", "2", "-subj", f"/CN={cn}"], check=True, capture_output=True)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    return ctx


def listen(ip, port, handler, name):
    """Accept connections on ip:port in a thread; each one goes to handler(conn, addr) in its own thread."""
    def run():
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind((ip, port))
        except OSError as e:
            log(f"{name}: can't listen on {ip}:{port}: {e}")
            return
        s.listen(64)
        log(f"{name} on {ip}:{port}")
        while True:
            conn, addr = s.accept()
            threading.Thread(target=handler, args=(conn, addr), daemon=True).start()
    threading.Thread(target=run, daemon=True).start()


def recv_exact(sock, n):
    out = b""
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise ConnectionError("closed")
        out += chunk
    return out


# ------------------------------------------------------------------ a print, as the printer runs it

class Job:
    """A print in progress: preparing for a few seconds, then layers, then finished."""

    def __init__(self):
        self.lock = threading.Lock()
        self.name = ""
        self.started = None
        self.paused_at = None
        self.paused_for = 0.0
        self.cancelled = False
        self.layers = 60

    def start(self, name):
        with self.lock:
            self.name, self.started, self.paused_at, self.paused_for, self.cancelled = name, time.time(), None, 0.0, False

    def pause(self):
        with self.lock:
            if self.started and not self.paused_at:
                self.paused_at = time.time()

    def resume(self):
        with self.lock:
            if self.paused_at:
                self.paused_for += time.time() - self.paused_at
                self.paused_at = None

    def cancel(self):
        with self.lock:
            if self.started:
                self.cancelled = True

    def snapshot(self):
        """(state, fraction, layer): state is idle, prepare, running, paused, finished or cancelled."""
        with self.lock:
            if not self.started:
                return "idle", 0.0, 0
            if self.cancelled:
                return "cancelled", 0.0, 0
            now = self.paused_at or time.time()
            t = now - self.started - self.paused_for
            if t < PREPARE_SECONDS:
                return ("paused" if self.paused_at else "prepare"), 0.0, 0
            f = min(1.0, (t - PREPARE_SECONDS) / PRINT_SECONDS)
            if f >= 1.0:
                return "finished", 1.0, self.layers
            return ("paused" if self.paused_at else "running"), f, max(1, int(f * self.layers))


# ------------------------------------------------------------------ Bambu Lab: MQTT broker

def mqtt_packet(kind, body=b""):
    out = bytes([kind])
    n = len(body)
    while True:
        b = n % 128
        n //= 128
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            break
    return out + body


def mqtt_read(sock):
    h = recv_exact(sock, 1)[0]
    length, mult = 0, 1
    while True:
        b = recv_exact(sock, 1)[0]
        length += (b & 127) * mult
        mult *= 128
        if not b & 128:
            break
    return h, (recv_exact(sock, length) if length else b"")


def mqtt_str(body, i):
    n = int.from_bytes(body[i:i + 2], "big")
    return body[i + 2:i + 2 + n].decode("utf-8", "replace"), i + 2 + n


class Bambu:
    def __init__(self, name, ip, serial, project_name, product, ams):
        self.name, self.ip, self.serial = name, ip, serial
        self.project_name, self.product, self.ams = project_name, product, ams
        self.job = Job()
        self.clients = []
        self.lock = threading.Lock()
        self.uploads = {}
        self.tls = tls_context(serial)

    def report(self):
        state, f, layer = self.job.snapshot()
        gcode_state = {"idle": "IDLE", "prepare": "PREPARE", "running": "RUNNING", "paused": "PAUSE",
                       "finished": "FINISH", "cancelled": "FAILED"}[state]
        busy = state in ("prepare", "running", "paused")
        p = {
            "command": "push_status", "msg": 0, "sequence_id": "1",
            "gcode_state": gcode_state, "mc_percent": int(f * 100),
            "mc_remaining_time": int((1 - f) * PRINT_SECONDS / 60 * 30) if busy else 0,
            "layer_num": layer, "total_layer_num": self.job.layers if busy or state == "finished" else 0,
            "nozzle_temper": 220.0 if busy else 26.0, "nozzle_target_temper": 220 if busy else 0,
            "bed_temper": 60.0 if busy else 25.0, "bed_target_temper": 60 if busy else 0,
            "subtask_name": self.job.name, "gcode_file": self.job.name, "print_error": 0,
            "ams": {"ams": [{"id": "0", "humidity": "4", "temp": "25.0", "tray": self.ams}] if self.ams else []},
            "vt_tray": {"id": "254", "tray_type": "", "tray_color": "00000000"},
        }
        return {"print": p}

    def send_all(self, obj):
        data = json.dumps(obj).encode()
        with self.lock:
            clients = list(self.clients)
        for sock, topic, slock in clients:
            pk = mqtt_packet(0x30, len(topic).to_bytes(2, "big") + topic + data)
            try:
                with slock:
                    sock.sendall(pk)
            except OSError:
                pass

    def pusher(self):
        while True:
            state = self.job.snapshot()[0]
            self.send_all(self.report())
            time.sleep(1 if state in ("prepare", "running", "paused") else 4)

    def handle_request(self, payload):
        try:
            msg = json.loads(payload)
        except ValueError:
            return
        if "pushing" in msg:
            self.send_all(self.report())
        elif "info" in msg and msg["info"].get("command") == "get_version":
            self.send_all({"info": {"command": "get_version", "sequence_id": msg["info"].get("sequence_id", "0"),
                                    "module": [{"name": "ota", "project_name": self.project_name, "product_name": self.product,
                                                "sw_ver": "01.09.00.00", "sn": self.serial}]}})
        elif "print" in msg:
            p = msg["print"]
            cmd = p.get("command")
            if cmd == "project_file":
                name = p.get("subtask_name") or p.get("file", "")
                uploaded = self.uploads.get(p.get("file", ""))
                log(f"{self.name}: print {p.get('file')} as {name!r} (uploaded: {uploaded} bytes, plate {p.get('param')}, "
                    f"ams {p.get('use_ams')} {p.get('ams_mapping')}, leveling {p.get('bed_leveling')})")
                self.job.start(name)
                self.send_all(self.report())
            elif cmd in ("pause", "resume", "stop"):
                log(f"{self.name}: {cmd}")
                {"pause": self.job.pause, "resume": self.job.resume, "stop": self.job.cancel}[cmd]()
                self.send_all(self.report())

    def mqtt_client(self, conn, addr):
        log(f"{self.name}: 8883 connection from {addr[0]}")
        slock = threading.Lock()
        entry = None
        try:
            sock = self.tls.wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError):
            return  # the Add printer search reads the certificate and hangs up
        try:
            h, body = mqtt_read(sock)
            if h >> 4 != 1:
                return
            i = 2 + int.from_bytes(body[0:2], "big") + 1  # protocol name, level
            flags = body[i]
            i += 3  # flags, keep alive
            _, i = mqtt_str(body, i)
            user = pw = ""
            if flags & 0x80:
                user, i = mqtt_str(body, i)
            if flags & 0x40:
                pw, i = mqtt_str(body, i)
            ok = user == "bblp" and pw == CODE
            log(f"{self.name}: MQTT login from {addr[0]} as {user}: {'ok' if ok else 'wrong access code'}")
            with slock:
                sock.sendall(bytes([0x20, 2, 0, 0 if ok else 5]))
            if not ok:
                return
            while True:
                h, body = mqtt_read(sock)
                kind = h >> 4
                if kind == 8:  # SUBSCRIBE
                    pid = body[0:2]
                    topic, _ = mqtt_str(body, 2)
                    entry = (sock, topic.encode(), slock)
                    with self.lock:
                        self.clients.append(entry)
                    with slock:
                        sock.sendall(mqtt_packet(0x90, pid + b"\x00"))
                elif kind == 3:  # PUBLISH
                    topic, i = mqtt_str(body, 0)
                    if (h >> 1) & 3:
                        i += 2
                    self.handle_request(body[i:])
                elif kind == 12:  # PINGREQ
                    with slock:
                        sock.sendall(bytes([0xD0, 0]))
                elif kind == 14:  # DISCONNECT
                    return
        except (ConnectionError, OSError, ssl.SSLError):
            pass
        finally:
            if entry:
                with self.lock:
                    if entry in self.clients:
                        self.clients.remove(entry)
            try:
                sock.close()
            except OSError:
                pass

    # ---------------- implicit FTPS (port 990)

    def ftps_client(self, conn, addr):
        try:
            sock = self.tls.wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError):
            return
        buf = b""

        def line():
            nonlocal buf
            while b"\r\n" not in buf:
                chunk = sock.recv(4096)
                if not chunk:
                    return None
                buf += chunk
            text, buf = buf.split(b"\r\n", 1)
            return text.decode("utf-8", "replace")

        def reply(text):
            sock.sendall((text + "\r\n").encode())

        data_listener = None
        try:
            reply("220 Bambu FTP ready")
            while True:
                text = line()
                if text is None:
                    return
                cmd, _, arg = text.partition(" ")
                cmd = cmd.upper()
                if cmd == "USER":
                    reply("331 Password required")
                elif cmd == "PASS":
                    reply("230 Logged in" if arg == CODE else "530 Login incorrect")
                elif cmd in ("PBSZ", "PROT", "TYPE"):
                    reply("200 OK")
                elif cmd == "PASV":
                    data_listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    data_listener.bind((self.ip, 0))
                    data_listener.listen(1)
                    port = data_listener.getsockname()[1]
                    reply(f"227 Entering Passive Mode ({self.ip.replace('.', ',')},{port >> 8},{port & 255})")
                elif cmd == "STOR" and data_listener:
                    reply("150 Opening data connection")
                    dconn, _ = data_listener.accept()
                    d = self.tls.wrap_socket(dconn, server_side=True)
                    total = 0
                    while True:
                        try:
                            chunk = d.recv(65536)
                        except (ssl.SSLError, OSError):
                            break
                        if not chunk:
                            break
                        total += len(chunk)
                    try:
                        d.unwrap()  # answer the client's close_notify
                    except (ssl.SSLError, OSError, ValueError):
                        pass
                    try:
                        d.close()
                    except OSError:
                        pass
                    data_listener.close()
                    data_listener = None
                    self.uploads[arg] = total
                    log(f"{self.name}: FTPS upload {arg} ({total} bytes)")
                    reply("226 Transfer complete")
                elif cmd == "QUIT":
                    reply("221 Bye")
                    return
                else:
                    reply("502 Not implemented")
        except (ConnectionError, OSError, ssl.SSLError) as e:
            log(f"{self.name}: FTPS ended: {e}")
        finally:
            try:
                sock.close()
            except OSError:
                pass

    # ---------------- A1 / P1 camera: JPEG frames over TLS (port 6000)

    def jpeg_client(self, conn, addr):
        try:
            sock = self.tls.wrap_socket(conn, server_side=True)
            auth = recv_exact(sock, 80)
            user = auth[16:48].rstrip(b"\0").decode("utf-8", "replace")
            code = auth[48:80].rstrip(b"\0").decode("utf-8", "replace")
            head = struct.unpack("<IIII", auth[:16])
            ok = user == "bblp" and code == CODE and head[0] == 0x40 and head[1] == 0x3000
            log(f"{self.name}: camera login from {addr[0]}: {'ok' if ok else f'refused ({user}, header {head})'}")
            if not ok:
                sock.close()
                return
            frames = [asset("frame1.jpg"), asset("frame2.jpg")]
            n = 0
            while True:
                jpg = frames[n % 2]
                sock.sendall(struct.pack("<IIII", len(jpg), 0, 1, 0) + jpg)
                n += 1
                if n == 1 or n % 20 == 0:
                    log(f"{self.name}: camera frame {n}")
                time.sleep(0.5)
        except (ConnectionError, OSError, ssl.SSLError):
            pass

    # ---------------- X1 camera: RTSPS with H.264 (port 322)

    def rtsp_client(self, conn, addr):
        try:
            sock = self.tls.wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError):
            return
        realm, nonce, session = "LIVE555 Streaming Media", "6f1d3bd0e23c4a6b", "4C3A2B1F"
        slock = threading.Lock()
        streaming = threading.Event()
        authed = False
        buf = b""
        try:
            while True:
                while b"\r\n\r\n" not in buf:
                    chunk = sock.recv(4096)
                    if not chunk:
                        return
                    buf += chunk
                head, buf = buf.split(b"\r\n\r\n", 1)
                lines = head.decode("utf-8", "replace").split("\r\n")
                method, url = lines[0].split(" ")[0], lines[0].split(" ")[1]
                hdr = {}
                for l in lines[1:]:
                    if ":" in l:
                        k, v = l.split(":", 1)
                        hdr[k.strip().lower()] = v.strip()
                cseq = hdr.get("cseq", "0")

                def send(status, extra=None, body=b""):
                    out = f"RTSP/1.0 {status}\r\nCSeq: {cseq}\r\n"
                    for k, v in (extra or {}).items():
                        out += f"{k}: {v}\r\n"
                    if body:
                        out += f"Content-Length: {len(body)}\r\n"
                    with slock:
                        sock.sendall(out.encode() + b"\r\n" + body)

                if not authed:
                    a = hdr.get("authorization", "")
                    if a.startswith("Digest"):
                        f = {}
                        for part in a[6:].split(","):
                            if "=" in part:
                                k, v = part.split("=", 1)
                                f[k.strip()] = v.strip().strip('"')
                        md5 = lambda s: hashlib.md5(s.encode()).hexdigest()
                        want = md5(f"{md5('bblp:' + realm + ':' + CODE)}:{nonce}:{md5(method + ':' + f.get('uri', ''))}")
                        authed = f.get("username") == "bblp" and f.get("response") == want
                        log(f"{self.name}: RTSP Digest login from {addr[0]}: {'ok' if authed else 'wrong'}")
                    if not authed:
                        send("401 Unauthorized", {"WWW-Authenticate": f'Digest realm="{realm}", nonce="{nonce}"'})
                        continue
                if method == "OPTIONS":
                    send("200 OK", {"Public": "OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER"})
                elif method == "DESCRIBE":
                    sps, pps = H264.params()
                    sdp = ("v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\ns=Stand-in X1C\r\nt=0 0\r\n"
                           "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
                           f"a=fmtp:96 packetization-mode=1;profile-level-id=42C01E;sprop-parameter-sets="
                           f"{base64.b64encode(sps).decode()},{base64.b64encode(pps).decode()}\r\na=control:track1\r\n").encode()
                    send("200 OK", {"Content-Type": "application/sdp", "Content-Base": url.rstrip("/") + "/"}, sdp)
                    log(f"{self.name}: RTSP DESCRIBE {url}")
                elif method == "SETUP":
                    send("200 OK", {"Transport": "RTP/AVP/TCP;unicast;interleaved=0-1", "Session": f"{session};timeout=60"})
                    log(f"{self.name}: RTSP SETUP {url}")
                elif method == "PLAY":
                    send("200 OK", {"Session": session, "Range": "npt=0.000-"})
                    log(f"{self.name}: RTSP PLAY, streaming H.264")
                    if not streaming.is_set():
                        streaming.set()
                        threading.Thread(target=H264.stream, args=(sock, slock, self.name), daemon=True).start()
                elif method == "TEARDOWN":
                    send("200 OK", {"Session": session})
                    return
                else:
                    send("200 OK", {"Session": session})
        except (ConnectionError, OSError, ssl.SSLError, IndexError):
            pass

    def run(self, rtsp=False, jpeg=False):
        listen(self.ip, 8883, self.mqtt_client, f"{self.name} MQTT")
        listen(self.ip, 990, self.ftps_client, f"{self.name} FTPS")
        if jpeg:
            listen(self.ip, 6000, self.jpeg_client, f"{self.name} camera (JPEG)")
        if rtsp:
            listen(self.ip, 322, self.rtsp_client, f"{self.name} camera (RTSPS)")
        threading.Thread(target=self.pusher, daemon=True).start()


class H264:
    """ci/assets/camera.h264 (Annex B, 10 fps) as RTP packets over the RTSP connection, looped."""
    units = None

    @classmethod
    def nals(cls):
        if cls.units is None:
            d = asset("camera.h264")
            starts = []
            i = 0
            while True:
                j = d.find(b"\x00\x00\x01", i)
                if j < 0:
                    break
                starts.append(j + 3)
                i = j + 3
            out = []
            for k, s in enumerate(starts):
                e = starts[k + 1] - 3 if k + 1 < len(starts) else len(d)
                nal = d[s:e]
                while nal.endswith(b"\x00"):
                    nal = nal[:-1]
                out.append(nal)
            cls.units = out
        return cls.units

    @classmethod
    def params(cls):
        sps = next(n for n in cls.nals() if n[0] & 0x1F == 7)
        pps = next(n for n in cls.nals() if n[0] & 0x1F == 8)
        return sps, pps

    @classmethod
    def frames(cls):
        """Access units: parameter sets and SEI ride with the picture after them."""
        frames, pending = [], []
        for n in cls.nals():
            pending.append(n)
            if n[0] & 0x1F in (1, 5):
                frames.append(pending)
                pending = []
        return frames

    @classmethod
    def stream(cls, sock, slock, name):
        seq, ts, ssrc = 1, 0, 0x1D0E5
        frames = cls.frames()
        sent = 0
        try:
            while True:
                for frame in frames:
                    packets = []
                    for n in frame:
                        if len(n) <= 1400:
                            packets.append(n)
                        else:
                            hdr, body = n[0], n[1:]
                            for o in range(0, len(body), 1400):
                                part = body[o:o + 1400]
                                fu_head = (hdr & 0x1F) | (0x80 if o == 0 else 0) | (0x40 if o + 1400 >= len(body) else 0)
                                packets.append(bytes([(hdr & 0xE0) | 28, fu_head]) + part)
                    out = b""
                    for k, p in enumerate(packets):
                        marker = 0x80 if k == len(packets) - 1 else 0
                        rtp = struct.pack(">BBHII", 0x80, marker | 96, seq & 0xFFFF, ts & 0xFFFFFFFF, ssrc) + p
                        seq += 1
                        out += b"$" + bytes([0]) + struct.pack(">H", len(rtp)) + rtp
                    with slock:
                        sock.sendall(out)
                    ts += 9000
                    sent += 1
                    if sent == 1 or sent % 100 == 0:
                        log(f"{name}: RTSP frame {sent}")
                    time.sleep(0.1)
        except (OSError, ssl.SSLError):
            log(f"{name}: RTSP stream ended after {sent} frames")


# ------------------------------------------------------------------ Snapmaker U1: Moonraker

U1_JOB = Job()
U1_FILES = {}
U1_FRAMES = None
BAMBUS = {}


class Moonraker(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, body, code=200, kind="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def status(self):
        state, f, layer = U1_JOB.snapshot()
        busy = state in ("prepare", "running", "paused")
        ps = {"idle": "standby", "prepare": "printing", "running": "printing", "paused": "paused",
              "finished": "complete", "cancelled": "cancelled"}[state]
        heads = {}
        for i in range(4):
            heads["extruder" if i == 0 else f"extruder{i}"] = {"temperature": 220.0 if busy and i < 2 else 26.0,
                                                               "target": 220.0 if busy and i < 2 else 0.0}
        return {
            "webhooks": {"state": "ready", "state_message": "Printer is ready"},
            "print_stats": {"state": ps, "filename": U1_JOB.name, "print_duration": f * PRINT_SECONDS,
                            "message": "", "info": {"current_layer": layer, "total_layer": U1_JOB.layers if U1_JOB.started else 0}},
            "virtual_sdcard": {"progress": f, "is_active": busy},
            "display_status": {"progress": f, "message": ""},
            "toolhead": {"extruder": "extruder"},
            "heater_bed": {"temperature": 60.0 if busy else 25.0, "target": 60.0 if busy else 0.0},
            "print_task_config": {
                "filament_type": ["PLA", "PLA", "PETG", "PLA"],
                "filament_color_rgba": ["F2F2F2FF", "1F1F1FFF", "0A6E70FF", "C8102EFF"],
                "filament_exist": [True, True, True, True],
                "filament_vendor": ["Snapmaker", "Snapmaker", "Snapmaker", "Snapmaker"],
                "filament_sub_type": ["Basic", "Matte", "", "Silk"],
            },
            **heads,
        }

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/websocket" and self.headers.get("Upgrade", "").lower() == "websocket":
            return self.websocket()
        if path != "/printer/objects/query" and not path.startswith("/server/files/camera"):
            log(f"U1: GET {path} from {self.client_address[0]}")
        if path == "/printer/objects/list":
            self.reply({"result": {"objects": ["webhooks", "print_stats", "toolhead", "extruder", "extruder1", "extruder2",
                                               "extruder3", "heater_bed", "print_task_config", "virtual_sdcard", "display_status"]}})
        elif path == "/printer/objects/query":
            self.reply({"result": {"eventtime": time.time(), "status": self.status()}})
        elif path == "/server/webcams/list":
            self.reply({"result": {"webcams": []}})
        elif path == "/server/files/camera/monitor.jpg":
            global U1_FRAMES
            if U1_FRAMES is None:
                U1_FRAMES = [asset("u1-frame1.jpg"), asset("u1-frame2.jpg")]
            self.reply(U1_FRAMES[int(time.time()) % 2], kind="image/jpeg")
        elif path == "/server/info":
            self.reply({"result": {"klippy_state": "ready", "moonraker_version": "stand-in"}})
        else:
            self.reply({"error": {"code": 404, "message": f"Not found: {path}"}}, 404)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length else b""
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/server/files/upload":
            name = "upload"
            marker = b'filename="'
            if marker in body:
                name = body.split(marker, 1)[1].split(b'"', 1)[0].decode()
            U1_FILES[name] = len(body)
            log(f"U1: upload {name} ({len(body)} bytes with the form)")
            self.reply({"result": {"item": {"path": name, "root": "gcodes"}, "action": "create_file"}}, 201)
        elif u.path == "/printer/print/start":
            name = q.get("filename", [""])[0]
            if name not in U1_FILES:
                log(f"U1: start {name}: no such file")
                return self.reply({"error": {"code": 400, "message": f"File {name} does not exist"}}, 400)
            log(f"U1: start {name}")
            U1_JOB.start(name)
            self.reply({"result": "ok"})
        elif u.path == "/debug/print":
            # CI: put a stand-in mid-print (?printer=P1S|X1C|U1&name=...)
            who, name = q.get("printer", ["U1"])[0], q.get("name", ["Benchy"])[0]
            (U1_JOB if who == "U1" else BAMBUS[who].job).start(name)
            log(f"{who}: debug print {name}")
            self.reply({"result": "ok"})
        elif u.path in ("/printer/print/pause", "/printer/print/resume", "/printer/print/cancel"):
            action = u.path.rsplit("/", 1)[1]
            log(f"U1: {action}")
            {"pause": U1_JOB.pause, "resume": U1_JOB.resume, "cancel": U1_JOB.cancel}[action]()
            self.reply({"result": "ok"})
        else:
            self.reply({"error": {"code": 404, "message": "Not found"}}, 404)

    def websocket(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        sock = self.connection

        def read(n):  # through the request's buffered reader, which may hold bytes already
            out = self.rfile.read(n)
            if len(out) < n:
                raise ConnectionError("closed")
            return out

        log("U1: WebSocket open")
        try:
            while True:
                b0, b1 = read(2)
                op, n = b0 & 0x0F, b1 & 0x7F
                if n == 126:
                    n = struct.unpack(">H", read(2))[0]
                elif n == 127:
                    n = struct.unpack(">Q", read(8))[0]
                mask = read(4) if b1 & 0x80 else b"\0\0\0\0"
                data = bytes(c ^ mask[i % 4] for i, c in enumerate(read(n)))
                if op == 8:
                    return
                if op == 9:
                    sock.sendall(bytes([0x8A, len(data)]) + data)
                    continue
                if op != 1:
                    continue
                try:
                    msg = json.loads(data)
                except ValueError:
                    continue
                log(f"U1: WebSocket {msg.get('method')} {json.dumps(msg.get('params'))}")
                out = json.dumps({"jsonrpc": "2.0", "result": "ok", "id": msg.get("id")}).encode()
                head = bytes([0x81, len(out)]) if len(out) < 126 else bytes([0x81, 126]) + struct.pack(">H", len(out))
                sock.sendall(head + out)
        except (ConnectionError, OSError):
            pass

    def log_message(self, *args):
        pass


# ------------------------------------------------------------------ start

TRAYS = [
    {"id": "0", "tray_type": "PLA", "tray_color": "F2F2F2FF", "tray_sub_brands": "PLA Basic"},
    {"id": "1", "tray_type": "PLA", "tray_color": "1F1F1FFF", "tray_sub_brands": "PLA Basic"},
    {"id": "2", "tray_type": "PLA", "tray_color": "C8102EFF", "tray_sub_brands": "PLA Matte"},
    {"id": "3", "tray_type": "PETG", "tray_color": "0A6E70FF", "tray_sub_brands": "PETG HF"},
]

BAMBUS["P1S"] = Bambu("P1S", P1S_IP, "01P00A123456789", "C12", "Bambu Lab P1S", TRAYS)
BAMBUS["P1S"].run(jpeg=True)
if X1C_IP:
    BAMBUS["X1C"] = Bambu("X1C", X1C_IP, "00M00A123456789", "BL-P001", "Bambu Lab X1 Carbon", TRAYS[:2])
    BAMBUS["X1C"].run(rtsp=True)
log(f"U1 Moonraker on {U1_IP}:7125")
http.server.ThreadingHTTPServer((U1_IP, 7125), Moonraker).serve_forever()
