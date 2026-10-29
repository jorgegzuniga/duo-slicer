import Foundation
import Network
import Security

/// A printer found on the local network by `PrinterDiscovery`.
struct FoundPrinter: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case bambu, snapmakerU1, klipper }

    var host: String
    var kind: Kind
    var serial = ""              // Bambu: the serial number in the printer's TLS certificate
    var modelID: String?         // catalog model, when the serial number or the printer says which one it is
    var unsupported: String?     // why it can't be added, e.g. dual-nozzle printers
    var needsKey = false         // Moonraker asked for an API key

    var id: String { host }
    var model: PrinterModel? { modelID.flatMap(PrinterCatalog.model) }
    var isSupported: Bool { unsupported == nil }

    var title: String {
        if let m = model { return m.name }
        switch kind {
        case .bambu: return BambuSerial.unsupportedNames[String(serial.prefix(3))].map { "Bambu Lab \($0)" } ?? "Bambu Lab printer"
        case .snapmakerU1: return "Snapmaker U1"
        case .klipper: return "Klipper printer"
        }
    }
}

/// What a Bambu Lab serial number says about the printer.
enum BambuSerial {
    /// Models by the first three characters of the serial number (Bambu Lab wiki and owners' lists).
    static let models: [String: String] = [
        "00M": "bambu-x1c", "00W": "bambu-x1", "03W": "bambu-x1e",
        "01S": "bambu-p1p", "01P": "bambu-p1s", "22E": "bambu-p2s",
        "030": "bambu-a1-mini", "039": "bambu-a1",
    ]
    /// Dual-nozzle printers the slicer doesn't support yet.
    static let unsupportedNames: [String: String] = ["094": "H2D", "239": "H2D Pro"]

    static func looksLikeSerial(_ s: String) -> Bool {
        (12...20).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isNumber || $0.isUppercase) }
    }

    static func printer(host: String, serial: String) -> FoundPrinter {
        let prefix = String(serial.prefix(3))
        var f = FoundPrinter(host: host, kind: .bambu, serial: serial, modelID: models[prefix])
        if let name = unsupportedNames[prefix] { f.unsupported = "The \(name) isn't supported yet (two nozzles)" }
        return f
    }
}

/// The iPhone's Wi-Fi network.
enum LocalNetwork {
    struct IPv4: Sendable {
        var address: UInt32
        var mask: UInt32
    }

    /// Address and netmask on Wi-Fi (en0); nil when the iPhone isn't on Wi-Fi.
    static func wifi() -> IPv4? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var best: IPv4?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            cursor = cur.pointee.ifa_next
            let ifa = cur.pointee
            guard String(cString: ifa.ifa_name) == "en0", let a = ifa.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), let m = ifa.ifa_netmask else { continue }
            let address = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard address != 0, mask != 0xFFFF_FFFF else { continue }  // single-address aliases
            if best == nil || mask < best!.mask { best = IPv4(address: address, mask: mask) }
        }
        return best
    }

    /// Every other address on the network, nearest to the iPhone's own first. Networks bigger than /22 are
    /// narrowed to the iPhone's /24, where home routers put printers.
    static func hosts(around net: IPv4) -> [String] {
        var mask = net.mask
        if mask.nonzeroBitCount < 22 { mask = 0xFFFF_FF00 }
        let base = net.address & mask
        let last = base | ~mask
        guard last > base &+ 1 else { return [] }
        let all = (base + 1 ..< last).filter { $0 != net.address }
        return all.sorted { distance($0, net.address) < distance($1, net.address) }.map(string)
    }

    private static func distance(_ a: UInt32, _ b: UInt32) -> UInt32 { a > b ? a - b : b - a }

    static func string(_ a: UInt32) -> String { "\(a >> 24 & 255).\(a >> 16 & 255).\(a >> 8 & 255).\(a & 255)" }
}

/// Short-lived connections that check one port on one host.
enum PortProbe {
    enum Result: Sendable { case open, closed, blocked }

    private static let queue = DispatchQueue(label: "duoslicer.discovery", attributes: .concurrent)

    /// iOS reports a connection stopped by the Local Network privacy setting as this DNS-SD error.
    private static func isBlocked(_ e: NWError) -> Bool {
        if case .dns(let code) = e { return code == -65570 }  // kDNSServiceErr_PolicyDenied
        return false
    }

    private static func parameters(tls: NWProtocolTLS.Options?, timeout: Double) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// Whether a TCP port accepts connections.
    static func tcp(_ host: String, _ port: UInt16, timeout: Double) async -> Result {
        guard let p = NWEndpoint.Port(rawValue: port) else { return .closed }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            let once = ResumeOnce(cont)
            let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: parameters(tls: nil, timeout: timeout))
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(.open)
                    c.cancel()
                case .waiting(let e), .failed(let e):
                    once.resume(isBlocked(e) ? .blocked : .closed)
                    c.cancel()
                default:
                    break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(.closed)
                c.cancel()
            }
        }
    }

    /// The subject (common name) of the certificate a TLS port presents. Bambu Lab printers put their serial number there.
    static func certificateName(_ host: String, _ port: UInt16, timeout: Double) async -> String? {
        guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(cont)
            let name = Locked<String?>(nil)
            let tls = NWProtocolTLS.Options()
            // printers use self-signed certificates: accept it, but keep its name
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let t = sec_trust_copy_ref(trust).takeRetainedValue()
                if let chain = SecTrustCopyCertificateChain(t) as? [SecCertificate], let leaf = chain.first {
                    name.value = SecCertificateCopySubjectSummary(leaf) as String?
                }
                complete(true)
                once.resume(name.value)
            }, queue)
            let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: parameters(tls: tls, timeout: timeout))
            c.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .waiting:
                    once.resume(name.value)
                    c.cancel()
                default:
                    break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(name.value)
                c.cancel()
            }
        }
    }

    /// A Moonraker (Klipper) server on port 7125: a Snapmaker U1 has four extruders and its own filament table.
    static func moonraker(_ host: String) async -> FoundPrinter? {
        guard let url = URL(string: "http://\(host):7125/printer/objects/list") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            // only the U1 is supported among Klipper printers; let the user add it with its API key
            return FoundPrinter(host: host, kind: .snapmakerU1, modelID: "snapmaker-u1", needsKey: true)
        }
        guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objects = (obj["result"] as? [String: Any])?["objects"] as? [String] else { return nil }
        if objects.contains("print_task_config") || objects.contains("extruder3") {
            return FoundPrinter(host: host, kind: .snapmakerU1, modelID: "snapmaker-u1")
        }
        return FoundPrinter(host: host, kind: .klipper, unsupported: "Only the Snapmaker U1 is supported among Klipper printers")
    }
}

/// Finds Bambu Lab printers (TLS on port 8883) and Snapmaker U1s (Moonraker on port 7125) on the iPhone's Wi-Fi.
/// It checks every address on the network instead of listening for broadcasts, which iOS reserves for apps with
/// Apple's multicast entitlement.
@MainActor
final class PrinterDiscovery: ObservableObject {
    enum Problem: Equatable { case noWiFi, localNetworkBlocked }

    @Published private(set) var found: [FoundPrinter] = []
    @Published private(set) var scanning = false
    @Published private(set) var problem: Problem?
    @Published private(set) var progress = 0.0

    private var task: Task<Void, Never>?
    private var retried = false
    private let parallel = 40

    func scan() {
        task?.cancel()
        task = Task { [weak self] in await self?.run() }
    }

    /// One search, start to finish (no UI).
    static func search() async -> [FoundPrinter] {
        let d = PrinterDiscovery()
        d.retried = true
        await d.run()
        return d.found
    }

    func stop() {
        task?.cancel()
        task = nil
        scanning = false
    }

    private func run() async {
        scanning = true
        problem = nil
        found = []
        progress = 0
        defer { if !Task.isCancelled { scanning = false } }
        guard let net = LocalNetwork.wifi() else {
            problem = .noWiFi
            return
        }
        let hosts = LocalNetwork.hosts(around: net)
        guard !hosts.isEmpty else { return }
        var blocked = 0
        var done = 0
        await withTaskGroup(of: (FoundPrinter?, Bool).self) { group in
            var next = 0
            while next < min(parallel, hosts.count) {
                let h = hosts[next]
                group.addTask { await Self.probe(h) }
                next += 1
            }
            while let result = await group.next() {
                let (printer, wasBlocked) = result
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                done += 1
                progress = Double(done) / Double(hosts.count)
                if wasBlocked { blocked += 1 }
                if let printer { add(printer) }
                if next < hosts.count {
                    let h = hosts[next]
                    group.addTask { await Self.probe(h) }
                    next += 1
                }
            }
        }
        guard !Task.isCancelled else { return }
        if found.isEmpty && blocked > hosts.count / 2 {
            problem = .localNetworkBlocked
            // the first scan can race the Local Network prompt; look once more after the user answers
            if !retried {
                retried = true
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { await run() }
            }
        }
    }

    private func add(_ p: FoundPrinter) {
        found.removeAll { $0.host == p.host }
        found.append(p)
        found.sort { a, b in
            if a.isSupported != b.isSupported { return a.isSupported }
            return a.title == b.title ? a.host < b.host : a.title < b.title
        }
    }

    /// One address: a Bambu printer's TLS port first, then Moonraker.
    nonisolated static func probe(_ host: String) async -> (FoundPrinter?, Bool) {
        async let bambuPort = PortProbe.tcp(host, 8883, timeout: 1.5)
        async let moonrakerPort = PortProbe.tcp(host, 7125, timeout: 1.5)
        let (b, m) = await (bambuPort, moonrakerPort)
        let blocked = b == .blocked || m == .blocked
        // the TLS handshake on a Bambu printer's ESP32 can take a couple of seconds
        if b == .open, let name = await PortProbe.certificateName(host, 8883, timeout: 6) {
            let serial = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if BambuSerial.looksLikeSerial(serial) { return (BambuSerial.printer(host: host, serial: serial), blocked) }
        }
        if m == .open, let p = await PortProbe.moonraker(host) { return (p, blocked) }
        return (nil, blocked)
    }
}

/// Signs in to a Bambu Lab printer once with its access code (proving the code works) and asks which model it is.
enum BambuCheck {
    /// Returns the catalog model id when the printer's version report names it.
    static func login(host: String, serial: String, code: String) async throws -> String? {
        try await Task.detached(priority: .userInitiated) { () throws -> String? in
            var err = [CChar](repeating: 0, count: 512)
            let client = "duoslicer-add-\(UInt32.random(in: 1000...999_999))"
            guard let m = a1_mqtt_connect(host, 8883, "bblp", code, client, 8000, &err, 512) else {
                let msg = String(cString: err)
                throw SlicerEngine.EngineError.message(msg.isEmpty ? "Couldn't connect to the printer." : msg)
            }
            defer { a1_mqtt_close(m) }
            _ = a1_mqtt_subscribe(m, "device/\(serial)/report")
            let request = Data(#"{"info":{"sequence_id":"20","command":"get_version"}}"#.utf8)
            _ = request.withUnsafeBytes { raw in
                raw.withMemoryRebound(to: CChar.self) { p in a1_mqtt_publish(m, "device/\(serial)/request", p.baseAddress, request.count) }
            }
            let end = Date().addingTimeInterval(5)
            while Date() < end {
                var topic: UnsafeMutablePointer<CChar>?
                var payload: UnsafeMutablePointer<CChar>?
                var len = 0
                let r = a1_mqtt_poll(m, 500, &topic, &payload, &len)
                if r == 1 {
                    let data = payload.map { Data(bytes: $0, count: len) }
                    a1_net_free(topic)
                    a1_net_free(payload)
                    if let data, let id = modelID(fromVersion: data) { return id }
                } else if r < 0 {
                    break
                }
            }
            return nil
        }.value
    }

    /// The model in a get_version report: a module's project_name is the printer's model code (C12 for the P1S),
    /// and newer firmware also sends a product_name ("Bambu Lab P1S").
    static func modelID(fromVersion data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = obj["info"] as? [String: Any], (info["command"] as? String) == "get_version",
              let modules = info["module"] as? [[String: Any]] else { return nil }
        let bambu = PrinterCatalog.models.filter(\.isBambu)
        for mod in modules {
            if let code = mod["project_name"] as? String,
               let m = bambu.first(where: { $0.modelId.caseInsensitiveCompare(code) == .orderedSame }) {
                return m.id
            }
        }
        // longest names first, so "A1 mini" wins over "A1" and "X1 Carbon" over "X1"
        let byName = bambu.sorted { $0.shortName.count > $1.shortName.count }
        for mod in modules {
            if let product = mod["product_name"] as? String,
               let m = byName.first(where: { product.range(of: $0.shortName, options: .caseInsensitive) != nil }) {
                return m.id
            }
        }
        return nil
    }
}

/// Resumes a continuation exactly once (connections report several states, and the timer races them).
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?

    init(_ c: CheckedContinuation<T, Never>) { cont = c }

    func resume(_ value: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ v: T) { stored = v }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
