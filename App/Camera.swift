import CoreImage
import CryptoKit
import Foundation
import Network
import SwiftUI
import UIKit
import VideoToolbox

/// How a printer shows its camera on the local network.
enum CameraKind {
    case bambuJPEG   // A1, A1 mini, P1P, P1S: JPEG frames over TLS on port 6000
    case bambuRTSP   // X1, X1 Carbon, X1E, H2S, P2S: H.264 over RTSPS on port 322 ("LAN mode liveview")
    case moonraker   // Snapmaker U1: a snapshot Moonraker refreshes while a monitor is running
}

extension PrinterModel {
    var cameraKinds: [CameraKind] {
        switch id {
        case "bambu-a1", "bambu-a1-mini", "bambu-p1p", "bambu-p1s": return [.bambuJPEG]
        case "bambu-x1", "bambu-x1c", "bambu-x1e", "bambu-h2s": return [.bambuRTSP]
        case "bambu-p2s", "bambu-a2l": return [.bambuRTSP, .bambuJPEG]   // newer models: whichever answers
        default: return isToolChanger ? [.moonraker] : []
        }
    }
}

/// A camera stream: calls back with frames and status from its own queue.
protocol CameraSource: AnyObject {
    func start(onFrame: @escaping (UIImage) -> Void, onStatus: @escaping (String, Bool) -> Void)
    func stop()
}

/// One printer's camera. Runs only while something is looking at it.
@MainActor
final class PrinterCamera: ObservableObject {
    @Published private(set) var frame: UIImage?
    @Published private(set) var status = "Connecting to the camera…"
    @Published private(set) var live = false
    @Published private(set) var lastFrameAt: Date?
    /// The last try failed (the message says why); cleared by the next picture.
    @Published private(set) var trouble = false

    private let printer: SavedPrinter
    private var source: CameraSource?
    private var users = 0
    private var kinds: [CameraKind]
    private var kindIndex = 0
    private var retryTask: Task<Void, Never>?

    init(printer: SavedPrinter) {
        self.printer = printer
        kinds = printer.model?.cameraKinds ?? []
    }

    var available: Bool { !kinds.isEmpty }

    /// Still pointed at the same printer address and model?
    func matches(_ p: SavedPrinter) -> Bool {
        p.hostOnly == printer.hostOnly && p.modelID == printer.modelID && p.port == printer.port && p.serial == printer.serial
    }

    /// Views call acquire/release; the stream runs while at least one is on screen.
    func acquire() {
        users += 1
        if users == 1 { open() }
    }

    func release() {
        users = max(0, users - 1)
        if users == 0 { close() }
    }

    private func open() {
        guard source == nil, kindIndex < kinds.count else {
            if kinds.isEmpty { status = "This printer has no camera Duo Slicer can show." }
            return
        }
        let code = Keychain.get(printer.secretKey) ?? ""
        let host = printer.hostOnly
        let s: CameraSource
        switch kinds[kindIndex] {
        case .bambuJPEG: s = BambuJPEGSource(host: host, code: code)
        case .bambuRTSP: s = RTSPSource(host: host, port: 322, path: "/streaming/live/1", user: "bblp", password: code)
        case .moonraker: s = MoonrakerSnapshotSource(host: host, port: printer.port, apiKey: code.isEmpty ? nil : code)
        }
        source = s
        // while retrying after a failure, keep showing why it failed
        if !trouble { status = "Connecting to the camera…" }
        s.start(onFrame: { [weak self] img in
            Task { @MainActor in
                guard let self, self.source === s else { return }
                self.frame = img
                self.live = true
                self.trouble = false
                self.lastFrameAt = Date()
            }
        }, onStatus: { [weak self] text, ok in
            Task { @MainActor in
                guard let self, self.source === s else { return }
                self.status = text
                if !ok {
                    self.trouble = true
                    self.failed()
                }
            }
        })
    }

    private func close() {
        retryTask?.cancel()
        source?.stop()
        source = nil
        live = false
    }

    /// The stream dropped or never came: try the printer's other camera kind, then retry after a pause.
    private func failed() {
        source?.stop()
        source = nil
        live = false
        guard users > 0 else { return }
        if frame == nil && kindIndex + 1 < kinds.count {
            kindIndex += 1
            open()
            return
        }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, self.users > 0 else { return }
            self.open()
        }
    }

    /// A fresh frame (for Claude): starts the camera if needed and waits for a picture.
    func snapshot(timeout: Double = 12) async -> UIImage? {
        let started = Date()
        acquire()
        defer { release() }
        while Date().timeIntervalSince(started) < timeout {
            if let t = lastFrameAt, t >= started, let f = frame { return f }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }
}

/// Why a camera connection failed, in a few words.
func cameraReason(_ e: NWError) -> String {
    switch e {
    case .posix(let code):
        switch code {
        case .ECONNREFUSED: return "it refused the connection"
        case .ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN: return "it didn't answer"
        default: return "the connection failed"
        }
    case .tls: return "the secure connection failed"
    case .dns: return "its address couldn't be found"
    default: return "the connection failed"
    }
}

// MARK: - Bambu Lab A1 / P1: JPEG frames over TLS (port 6000)

/// After an 80-byte login (user "bblp", the access code) the printer sends frames: a 16-byte header whose first
/// four bytes are the JPEG's size (little endian), then the JPEG.
final class BambuJPEGSource: CameraSource, @unchecked Sendable {
    private let host: String
    private let code: String
    private let queue = DispatchQueue(label: "duoslicer.camera.jpeg")
    private var conn: NWConnection?
    private var buffer = Data()
    private var expected = -1

    init(host: String, code: String) {
        self.host = host
        self.code = code
    }

    static func login(code: String) -> Data {
        var d = Data()
        for v: UInt32 in [0x40, 0x3000, 0, 0] { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        var user = Data("bblp".utf8)
        user.count = 32
        var pass = Data(code.utf8.prefix(32))
        pass.count = 32
        d.append(user)
        d.append(pass)
        return d
    }

    func start(onFrame: @escaping (UIImage) -> Void, onStatus: @escaping (String, Bool) -> Void) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 6
        let c = NWConnection(host: NWEndpoint.Host(host), port: 6000, using: NWParameters(tls: tls, tcp: tcp))
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                c.send(content: Self.login(code: self.code), completion: .contentProcessed { _ in })
                onStatus("Live", true)
                self.receive(c, onFrame: onFrame, onStatus: onStatus)
            case .waiting(let e), .failed(let e):
                onStatus("Couldn't reach the camera: \(cameraReason(e)).", false)
                c.cancel()
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func receive(_ c: NWConnection, onFrame: @escaping (UIImage) -> Void, onStatus: @escaping (String, Bool) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self, self.conn === c else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parse(onFrame)
            }
            if error != nil || done {
                onStatus("The camera stopped sending. Check that the access code is right.", false)
                c.cancel()
            } else {
                self.receive(c, onFrame: onFrame, onStatus: onStatus)
            }
        }
    }

    private func parse(_ onFrame: (UIImage) -> Void) {
        while true {
            if expected < 0 {
                guard buffer.count >= 16 else { return }
                let size = buffer.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
                buffer.removeFirst(16)
                guard size > 0 && size < 16 << 20 else { buffer.removeAll(); return }
                expected = size
            }
            guard buffer.count >= expected else { return }
            let jpeg = Data(buffer.prefix(expected))
            buffer.removeFirst(expected)
            expected = -1
            if jpeg.count > 4, jpeg[jpeg.startIndex] == 0xFF, jpeg[jpeg.startIndex + 1] == 0xD8, let img = UIImage(data: jpeg) { onFrame(img) }
        }
    }

    func stop() {
        conn?.cancel()
        conn = nil
    }
}

// MARK: - Snapmaker U1: Moonraker snapshot

/// The U1 writes its camera picture to Moonraker's files (camera/monitor.jpg) while a monitor is running; the monitor
/// is started over Moonraker's WebSocket and kept alive every 10 seconds. A webcam configured in Moonraker wins.
final class MoonrakerSnapshotSource: CameraSource, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let apiKey: String?
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    init(host: String, port: Int, apiKey: String?) {
        self.host = host
        self.port = port
        self.apiKey = apiKey
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 6)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if let apiKey { r.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        return r
    }

    /// A snapshot URL from Moonraker's webcam list, if the printer has one configured.
    private func configuredSnapshot() async -> URL? {
        guard let url = URL(string: "http://\(host):\(port)/server/webcams/list"),
              let reply = try? await URLSession.shared.data(for: request(url)),
              let obj = try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any],
              let cams = (obj["result"] as? [String: Any])?["webcams"] as? [[String: Any]] else { return nil }
        for cam in cams where (cam["enabled"] as? Bool) ?? true {
            guard var s = cam["snapshot_url"] as? String, !s.isEmpty else { continue }
            if s.contains("localhost") || s.contains("127.0.0.1") {
                s = s.replacingOccurrences(of: "localhost", with: host).replacingOccurrences(of: "127.0.0.1", with: host)
            }
            if s.hasPrefix("/") { s = "http://\(host)\(s)" }
            if let u = URL(string: s) { return u }
        }
        return nil
    }

    private func keepMonitorRunning() {
        guard socket == nil, let url = URL(string: "ws://\(host):\(port)/websocket") else { return }
        var r = URLRequest(url: url)
        if let apiKey { r.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        let ws = URLSession.shared.webSocketTask(with: r)
        socket = ws
        ws.resume()
        func listen() {
            ws.receive { result in if case .success = result { listen() } }
        }
        listen()
    }

    private func pokeMonitor(_ id: Int) {
        let msg = #"{"jsonrpc":"2.0","method":"camera.start_monitor","params":{"domain":"lan","interval":0},"id":\#(id)}"#
        socket?.send(.string(msg)) { _ in }
    }

    func start(onFrame: @escaping (UIImage) -> Void, onStatus: @escaping (String, Bool) -> Void) {
        task = Task { [weak self] in
            guard let self else { return }
            let custom = await self.configuredSnapshot()
            if custom == nil { self.keepMonitorRunning() }
            let fallback = URL(string: "http://\(self.host):\(self.port)/server/files/camera/monitor.jpg")!
            var n = 0
            var failures = 0
            var lastPoke = Date.distantPast
            while !Task.isCancelled {
                if custom == nil && Date().timeIntervalSince(lastPoke) > 10 {
                    n += 1
                    self.pokeMonitor(n)
                    lastPoke = Date()
                }
                var comps = URLComponents(url: custom ?? fallback, resolvingAgainstBaseURL: false)!
                comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
                if let reply = try? await URLSession.shared.data(for: self.request(comps.url!)),
                   (reply.1 as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: reply.0) {
                    failures = 0
                    onFrame(img)
                    onStatus("Live", true)
                } else {
                    failures += 1
                    if failures == 4 {
                        onStatus("The camera isn't sending pictures. On the U1, check that the camera is on.", false)
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }
}

// MARK: - Bambu Lab X1 / H2 / P2: H.264 over RTSPS (port 322)

/// A small RTSP client over TLS: DESCRIBE (Basic or Digest login), SETUP with RTP interleaved in the TCP stream, PLAY,
/// then H.264 from RTP (single NAL units, STAP-A and FU-A) into VideoToolbox.
final class RTSPSource: CameraSource, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let path: String
    private let user: String
    private let password: String
    private let queue = DispatchQueue(label: "duoslicer.camera.rtsp")
    private var conn: NWConnection?
    private var buf = Data()
    private var cseq = 0
    private var session: String?
    private var authHeader: ((String, String) -> String)?
    private var authTried = false
    private var onResponse: ((Int, [String: String], Data) -> Void)?
    private var lastRequest: (method: String, url: String, headers: [String: String])?
    private var keepAlive: DispatchSourceTimer?
    private var onFrame: ((UIImage) -> Void)?
    private var onStatus: ((String, Bool) -> Void)?
    private let decoder = H264Decoder()
    // RTP to access units
    private var nals: [Data] = []
    private var fu = Data()

    var url: String { "rtsps://\(host):\(port)\(path)" }

    init(host: String, port: UInt16, path: String, user: String, password: String) {
        self.host = host
        self.port = port
        self.path = path
        self.user = user
        self.password = password
    }

    func start(onFrame: @escaping (UIImage) -> Void, onStatus: @escaping (String, Bool) -> Void) {
        self.onFrame = onFrame
        self.onStatus = onStatus
        decoder.onImage = onFrame
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 6
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: NWParameters(tls: tls, tcp: tcp))
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive(c)
                self.describe()
            case .waiting(let e), .failed(let e):
                self.fail("Couldn't reach the camera: \(cameraReason(e)). On X1, H2 and P2 printers, turn on LAN Mode Liveview.")
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    func stop() {
        keepAlive?.cancel()
        keepAlive = nil
        conn?.cancel()
        conn = nil
    }

    private func fail(_ text: String) {
        guard conn != nil else { return }
        stop()
        onStatus?(text, false)
    }

    // MARK: requests

    private func send(_ method: String, _ url: String, _ headers: [String: String] = [:], then: @escaping (Int, [String: String], Data) -> Void) {
        cseq += 1
        lastRequest = (method, url, headers)
        var text = "\(method) \(url) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: DuoSlicer\r\n"
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        if let session { text += "Session: \(session)\r\n" }
        if let authHeader { text += "Authorization: \(authHeader(method, url))\r\n" }
        text += "\r\n"
        onResponse = { [weak self] code, h, body in
            guard let self else { return }
            if code == 401, !self.authTried, let challenge = h["www-authenticate"] {
                self.authTried = true
                self.setAuth(challenge)
                self.send(method, url, headers, then: then)
                return
            }
            then(code, h, body)
        }
        conn?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    private func setAuth(_ challenge: String) {
        let user = self.user, password = self.password
        if challenge.lowercased().hasPrefix("digest") {
            func field(_ name: String) -> String {
                guard let r = challenge.range(of: "\(name)=\"") else { return "" }
                let rest = challenge[r.upperBound...]
                return String(rest[..<(rest.firstIndex(of: "\"") ?? rest.endIndex)])
            }
            let realm = field("realm"), nonce = field("nonce")
            func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
            authHeader = { method, uri in
                let response = md5("\(md5("\(user):\(realm):\(password)")):\(nonce):\(md5("\(method):\(uri)"))")
                return "Digest username=\"\(user)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(response)\""
            }
        } else {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            authHeader = { _, _ in "Basic \(token)" }
        }
    }

    private func describe() {
        send("DESCRIBE", url, ["Accept": "application/sdp"]) { [weak self] code, headers, body in
            guard let self else { return }
            guard code == 200 else {
                self.fail(code == 401 ? "The camera didn't accept the access code." : "The camera answered \(code).")
                return
            }
            let sdp = String(decoding: body, as: UTF8.self)
            var base = headers["content-base"] ?? self.url
            if !base.hasSuffix("/") { base += "/" }
            var control = ""
            var inVideo = false
            for raw in sdp.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video") }
                guard inVideo else { continue }
                if line.hasPrefix("a=control:") { control = String(line.dropFirst("a=control:".count)) }
                if line.hasPrefix("a=fmtp:"), let r = line.range(of: "sprop-parameter-sets=") {
                    let sets = line[r.upperBound...].split(separator: ";").first.map(String.init) ?? ""
                    for b64 in sets.split(separator: ",") {
                        if let d = Data(base64Encoded: String(b64)) { self.decoder.parameter(d) }
                    }
                }
            }
            let track = control.isEmpty || control == "*" ? self.url : (control.lowercased().hasPrefix("rtsp") ? control : base + control)
            self.setup(track)
        }
    }

    private func setup(_ track: String) {
        send("SETUP", track, ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]) { [weak self] code, headers, _ in
            guard let self else { return }
            guard code == 200, let s = headers["session"] else { self.fail("The camera wouldn't set up a stream (\(code))."); return }
            self.session = s.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
            self.send("PLAY", self.url, ["Range": "npt=0.000-"]) { code, _, _ in
                guard code == 200 else { self.fail("The camera wouldn't play (\(code))."); return }
                self.onStatus?("Live", true)
                self.startKeepAlive()
            }
        }
    }

    private func startKeepAlive() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 25, repeating: 25)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.send("GET_PARAMETER", self.url) { _, _, _ in }
        }
        t.resume()
        keepAlive = t
    }

    // MARK: reading

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, done, error in
            guard let self, self.conn === c else { return }
            if let data, !data.isEmpty {
                self.buf.append(data)
                self.drain()
            }
            if error != nil || done {
                self.fail("The camera stream ended.")
            } else {
                self.receive(c)
            }
        }
    }

    private func drain() {
        while !buf.isEmpty {
            let first = buf[buf.startIndex]
            if first == 0x24 {  // '$' interleaved RTP/RTCP
                guard buf.count >= 4 else { return }
                let channel = buf[buf.startIndex + 1]
                let len = Int(buf[buf.startIndex + 2]) << 8 | Int(buf[buf.startIndex + 3])
                guard buf.count >= 4 + len else { return }
                let packet = Data(buf[(buf.startIndex + 4)..<(buf.startIndex + 4 + len)])
                buf.removeFirst(4 + len)
                if channel == 0 { rtp(packet) }
            } else if first == 0x52 {  // 'R' RTSP/1.0 response
                guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return }
                let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                var headers: [String: String] = [:]
                let lines = head.components(separatedBy: "\r\n")
                for l in lines.dropFirst() {
                    if let colon = l.firstIndex(of: ":") {
                        headers[l[..<colon].lowercased().trimmingCharacters(in: .whitespaces)] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                let bodyStart = end.upperBound
                guard buf.distance(from: bodyStart, to: buf.endIndex) >= length else { return }
                let body = Data(buf[bodyStart..<buf.index(bodyStart, offsetBy: length)])
                buf.removeFirst(buf.distance(from: buf.startIndex, to: bodyStart) + length)
                let parts = (lines.first ?? "").split(separator: " ")
                let code = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                let handler = onResponse
                onResponse = nil
                handler?(code, headers, body)
            } else {
                // lost our place: skip to the next '$' or 'R'
                if let i = buf.dropFirst().firstIndex(where: { $0 == 0x24 || $0 == 0x52 }) {
                    buf.removeFirst(buf.distance(from: buf.startIndex, to: i))
                } else {
                    buf.removeAll()
                }
            }
        }
    }

    private func rtp(_ p: Data) {
        guard p.count > 12 else { return }
        let b = [UInt8](p)
        let csrc = Int(b[0] & 0x0F)
        let hasExt = b[0] & 0x10 != 0
        let padding = b[0] & 0x20 != 0 ? Int(b[b.count - 1]) : 0
        let marker = b[1] & 0x80 != 0
        var off = 12 + csrc * 4
        if hasExt {
            guard b.count >= off + 4 else { return }
            off += 4 + (Int(b[off + 2]) << 8 | Int(b[off + 3])) * 4
        }
        let end = b.count - padding
        guard off < end else { return }
        let payload = Array(b[off..<end])
        let type = payload[0] & 0x1F
        switch type {
        case 1...23:
            nals.append(Data(payload))
        case 24:  // STAP-A
            var i = 1
            while i + 2 <= payload.count {
                let n = Int(payload[i]) << 8 | Int(payload[i + 1])
                i += 2
                guard i + n <= payload.count else { break }
                nals.append(Data(payload[i..<(i + n)]))
                i += n
            }
        case 28:  // FU-A
            guard payload.count > 2 else { return }
            let header = payload[1]
            if header & 0x80 != 0 { fu = Data([(payload[0] & 0xE0) | (header & 0x1F)]) }
            if !fu.isEmpty { fu.append(contentsOf: payload[2...]) }
            if header & 0x40 != 0, !fu.isEmpty {
                nals.append(fu)
                fu = Data()
            }
        default:
            break
        }
        if marker {
            decoder.decode(nals)
            nals = []
        }
    }
}

/// H.264 NAL units -> pictures, through VideoToolbox. Hands out a picture about eight times a second.
final class H264Decoder: @unchecked Sendable {
    var onImage: ((UIImage) -> Void)?
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sawKeyframe = false
    private var lastImage = Date.distantPast
    private let ci = CIContext()

    func parameter(_ nal: Data) {
        guard let t = nal.first.map({ $0 & 0x1F }) else { return }
        if t == 7, nal != sps { sps = nal; reset() }
        if t == 8, nal != pps { pps = nal; reset() }
    }

    private func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }

    private func makeSession() -> Bool {
        guard let sps, let pps else { return false }
        var fmt: CMVideoFormatDescription?
        let ok: OSStatus = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                                                                           parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        guard ok == noErr, let fmt else { return false }
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s) == noErr,
              let s else { return false }
        format = fmt
        session = s
        return true
    }

    func decode(_ nals: [Data]) {
        var frame = Data()
        var key = false
        for n in nals {
            guard let t = n.first.map({ $0 & 0x1F }) else { continue }
            if t == 7 || t == 8 { parameter(n); continue }
            if t == 5 { key = true }
            var len = UInt32(n.count).bigEndian
            frame.append(Data(bytes: &len, count: 4))
            frame.append(n)
        }
        guard !frame.isEmpty else { return }
        if key { sawKeyframe = true }
        guard sawKeyframe, session != nil || makeSession(), let session, let format else { return }
        var block: CMBlockBuffer?
        let count = frame.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        _ = frame.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) }
        var sample: CMSampleBuffer?
        var size = count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self, status == noErr, let image else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastImage) > 0.12 else { return }
            self.lastImage = now
            let ciImage = CIImage(cvPixelBuffer: image)
            if let cg = self.ci.createCGImage(ciImage, from: ciImage.extent) { self.onImage?(UIImage(cgImage: cg)) }
        }
    }

    deinit { reset() }
}

// MARK: - View

/// A printer's camera, live while on screen.
struct CameraView: View {
    @EnvironmentObject var link: PrinterLink
    @ObservedObject var connection: PrinterConnection
    var height: CGFloat = 220

    var body: some View {
        if let cam = link.camera(for: connection.id) {
            // a new camera object (the printer moved to another address) is a new view, so the old stream is released
            CameraPicture(camera: cam, height: height)
                .id(ObjectIdentifier(cam))
        }
    }
}

private struct CameraPicture: View {
    @ObservedObject var camera: PrinterCamera
    let height: CGFloat

    var body: some View {
        ZStack {
            Color.black
            if let img = camera.frame {
                Image(uiImage: img).resizable().scaledToFit()
            }
            if !camera.live || camera.frame == nil {
                VStack(spacing: 8) {
                    if camera.available && camera.frame == nil && !camera.trouble { ProgressView().tint(.white) }
                    Text(camera.status).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center).padding(.horizontal)
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .onAppear { camera.acquire() }
        .onDisappear { camera.release() }
        .accessibilityLabel(camera.live ? "Printer camera" : camera.status)
    }
}
