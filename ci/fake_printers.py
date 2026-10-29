#!/usr/bin/env python3
"""Stand-ins for printers on the CI runner's network, for the Add printer search:
a Bambu Lab printer's TLS port (8883, certificate named with a P1S serial number) on one address and
a Snapmaker U1's Moonraker (7125, four extruders and the U1's filament table) on another.

    fake_printers.py <bambu address> <u1 address>
"""
import http.server
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import threading

BAMBU_IP, U1_IP = sys.argv[1], sys.argv[2]
SERIAL = "01P00A123456789"

work = tempfile.mkdtemp()
key, cert = os.path.join(work, "key.pem"), os.path.join(work, "cert.pem")
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                "-days", "2", "-subj", f"/CN={SERIAL}"], check=True, capture_output=True)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(cert, key)


def bambu_client(conn):
    try:
        with tls.wrap_socket(conn, server_side=True) as t:
            t.settimeout(5)
            t.recv(16)
    except Exception:
        pass


def bambu():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((BAMBU_IP, 8883))
    s.listen(64)
    print(f"bambu tls on {BAMBU_IP}:8883", flush=True)
    while True:
        conn, addr = s.accept()
        print(f"8883 connection from {addr[0]}", flush=True)
        threading.Thread(target=bambu_client, args=(conn,), daemon=True).start()


class Moonraker(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/printer/objects/list"):
            body = {"result": {"objects": ["webhooks", "print_stats", "toolhead", "extruder", "extruder1", "extruder2",
                                           "extruder3", "heater_bed", "print_task_config"]}}
        elif self.path.startswith("/printer/objects/query"):
            body = {"result": {"eventtime": 1.0, "status": {"webhooks": {"state": "ready"},
                                                             "print_stats": {"state": "standby", "filename": ""}}}}
        else:
            body = {"result": {}}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        print(f"7125 {self.path} from {self.client_address[0]}", flush=True)

    def log_message(self, *args):
        pass


threading.Thread(target=bambu, daemon=True).start()
print(f"moonraker on {U1_IP}:7125", flush=True)
http.server.ThreadingHTTPServer((U1_IP, 7125), Moonraker).serve_forever()
