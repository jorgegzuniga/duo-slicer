import Foundation
import Security
import SwiftUI

enum Keychain {
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

struct Tray: Identifiable, Hashable {
    var id: Int          // global slot: ams * 4 + tray, 254 = external spool
    var label: String
    var type: String
    var color: String    // #RRGGBB or ""
    var name: String
    var loaded: Bool
}

/// Background MQTT session (owns the C handle). Callbacks arrive on a background thread.
final class MqttSession: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var stopped = false
    let host: String, serial: String, code: String

    init(host: String, serial: String, code: String) {
        self.host = host
        self.serial = serial
        self.code = code
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func publish(_ object: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        lock.lock()
        let h = handle
        lock.unlock()
        guard let h else { return false }
        let topic = "device/\(serial)/request"
        return data.withUnsafeBytes { raw -> Bool in
            raw.withMemoryRebound(to: CChar.self) { p in a1_mqtt_publish(h, topic, p.baseAddress, data.count) == 0 }
        }
    }

    func run(onState: @escaping (Bool, String) -> Void, onMessage: @escaping (Data) -> Void) {
        var backoff: UInt32 = 2
        while !isStopped {
            onState(false, "Connecting to \(host)…")
            var err = [CChar](repeating: 0, count: 512)
            let clientId = "a1slicer-\(UInt32.random(in: 1000...999_999))"
            guard let m = a1_mqtt_connect(host, 8883, "bblp", code, clientId, 6000, &err, 512) else {
                let msg = String(cString: err)
                onState(false, msg.isEmpty ? "Couldn't connect." : msg)
                var waited: UInt32 = 0
                while waited < backoff && !isStopped { sleep(1); waited += 1 }
                backoff = min(backoff * 2, 30)
                continue
            }
            backoff = 2
            lock.lock(); handle = m; lock.unlock()
            _ = a1_mqtt_subscribe(m, "device/\(serial)/report")
            _ = publish(["pushing": ["sequence_id": "0", "command": "pushall"]])
            onState(true, "Connected")
            var lastPushAll = Date()
            while !isStopped {
                var topic: UnsafeMutablePointer<CChar>?
                var payload: UnsafeMutablePointer<CChar>?
                var len = 0
                let r = a1_mqtt_poll(m, 1000, &topic, &payload, &len)
                if r == 1 {
                    if let payload { onMessage(Data(bytes: payload, count: len)) }
                    a1_net_free(topic)
                    a1_net_free(payload)
                } else if r < 0 {
                    break
                }
                if Date().timeIntervalSince(lastPushAll) > 300 {
                    _ = publish(["pushing": ["sequence_id": "0", "command": "pushall"]])
                    lastPushAll = Date()
                }
            }
            lock.lock(); handle = nil; lock.unlock()
            a1_mqtt_close(m)
            if !isStopped { onState(false, "Lost the connection; retrying…") }
        }
    }
}

enum FTPS {
    private final class Box { let fn: (Double) -> Void; init(_ f: @escaping (Double) -> Void) { fn = f } }

    static func upload(host: String, code: String, remoteName: String, data: Data, progress: @escaping (Double) -> Void) throws {
        let box = Box(progress)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<Box>.fromOpaque(ctx).release() }
        var err = [CChar](repeating: 0, count: 512)
        let cb: A1UploadProgress = { f, c in
            guard let c else { return }
            Unmanaged<Box>.fromOpaque(c).takeUnretainedValue().fn(f)
        }
        let rc = data.withUnsafeBytes { raw -> Int32 in
            a1_ftps_upload(host, 990, "bblp", code, remoteName, raw.bindMemory(to: UInt8.self).baseAddress, data.count, cb, ctx, &err, 512)
        }
        if rc != 0 {
            let msg = String(cString: err)
            throw SlicerEngine.EngineError.message(msg.isEmpty ? "Upload failed." : msg)
        }
    }
}

struct StartOptions {
    var bedLeveling = true
    var flowCalibration = true
    var vibrationCalibration = true
    var timelapse = false
}

@MainActor
final class PrinterLink: ObservableObject {
    @Published var ip: String = UserDefaults.standard.string(forKey: "printer.ip") ?? ""
    @Published var serial: String = UserDefaults.standard.string(forKey: "printer.serial") ?? ""
    @Published var hasCode: Bool = Keychain.get("printer.code") != nil
    @Published var connected = false
    @Published var statusText = "Not set up"
    @Published var state = "OFFLINE"
    @Published var percent = 0
    @Published var remainingMinutes = 0
    @Published var layer = 0
    @Published var totalLayers = 0
    @Published var nozzle = 0.0
    @Published var bed = 0.0
    @Published var jobName = ""
    @Published var printError = 0
    @Published var trays: [Tray] = []
    @Published var uploadProgress: Double?
    @Published var lastResult: String?

    private var session: MqttSession?
    private var report: [String: Any] = [:]

    var isConfigured: Bool { !ip.isEmpty && !serial.isEmpty && hasCode }
    var isBusy: Bool { ["RUNNING", "PAUSE", "PREPARE", "SLICING"].contains(state) }

    func save(ip: String, serial: String, code: String?) {
        self.ip = ip.trimmingCharacters(in: .whitespaces)
        self.serial = serial.trimmingCharacters(in: .whitespaces).uppercased()
        UserDefaults.standard.set(self.ip, forKey: "printer.ip")
        UserDefaults.standard.set(self.serial, forKey: "printer.serial")
        if let code, !code.isEmpty {
            Keychain.set(code.trimmingCharacters(in: .whitespaces), for: "printer.code")
            hasCode = true
        }
        reconnect()
    }

    func start() {
        if session == nil { reconnect() }
    }

    func reconnect() {
        session?.stop()
        session = nil
        report = [:]
        trays = []
        connected = false
        guard isConfigured, let code = Keychain.get("printer.code") else {
            statusText = "Add your printer's IP, serial number and access code."
            return
        }
        let s = MqttSession(host: ip, serial: serial, code: code)
        session = s
        DispatchQueue.global(qos: .utility).async {
            s.run(onState: { ok, text in
                Task { @MainActor [weak self] in
                    guard let self, self.session === s else { return }
                    self.connected = ok
                    self.statusText = text
                    if !ok { self.state = "OFFLINE" }
                }
            }, onMessage: { data in
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.session === s else { return }
                    self.merge(obj)
                }
            })
        }
    }

    func disconnect() {
        session?.stop()
        session = nil
        connected = false
        statusText = "Disconnected"
    }

    private static func deepMerge(_ a: inout [String: Any], _ b: [String: Any]) {
        for (k, v) in b {
            if let vb = v as? [String: Any], var va = a[k] as? [String: Any] {
                deepMerge(&va, vb)
                a[k] = va
            } else {
                a[k] = v
            }
        }
    }

    private func merge(_ obj: [String: Any]) {
        PrinterLink.deepMerge(&report, obj)
        guard let p = report["print"] as? [String: Any] else { return }
        func int(_ k: String) -> Int? { (p[k] as? NSNumber)?.intValue ?? Int(p[k] as? String ?? "") }
        func dbl(_ k: String) -> Double? { (p[k] as? NSNumber)?.doubleValue ?? Double(p[k] as? String ?? "") }
        if let s = p["gcode_state"] as? String { state = s }
        percent = int("mc_percent") ?? percent
        remainingMinutes = int("mc_remaining_time") ?? remainingMinutes
        layer = int("layer_num") ?? layer
        totalLayers = int("total_layer_num") ?? totalLayers
        nozzle = dbl("nozzle_temper") ?? nozzle
        bed = dbl("bed_temper") ?? bed
        jobName = (p["subtask_name"] as? String) ?? jobName
        printError = int("print_error") ?? 0
        var t: [Tray] = []
        if let ams = (p["ams"] as? [String: Any])?["ams"] as? [[String: Any]] {
            for unit in ams {
                let aid = Int(unit["id"] as? String ?? "") ?? (unit["id"] as? NSNumber)?.intValue ?? 0
                for tray in (unit["tray"] as? [[String: Any]]) ?? [] {
                    let tid = Int(tray["id"] as? String ?? "") ?? (tray["id"] as? NSNumber)?.intValue ?? 0
                    let type = tray["tray_type"] as? String ?? ""
                    let col = tray["tray_color"] as? String ?? ""
                    t.append(Tray(id: aid * 4 + tid,
                                  label: ams.count > 1 ? "AMS \(aid + 1) · Slot \(tid + 1)" : "Slot \(tid + 1)",
                                  type: type, color: col.count >= 6 ? "#" + col.prefix(6) : "",
                                  name: (tray["tray_sub_brands"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? type,
                                  loaded: !type.isEmpty))
                }
            }
        }
        if let vt = p["vt_tray"] as? [String: Any] {
            let type = vt["tray_type"] as? String ?? ""
            let col = vt["tray_color"] as? String ?? ""
            t.append(Tray(id: 254, label: "External spool", type: type, color: col.count >= 6 ? "#" + col.prefix(6) : "", name: type, loaded: !type.isEmpty))
        }
        if !t.isEmpty { trays = t }
    }

    func send(_ command: String) {
        _ = session?.publish(["print": ["sequence_id": "0", "command": command, "param": ""]])
    }

    /// Best spool for each sliced filament: nearest colour, preferring the same material, each spool used once if possible.
    func suggestMapping(for filaments: [SlicedFilament]) -> [Int: Int] {
        func rgb(_ h: String) -> (Double, Double, Double) {
            var s = h; if s.hasPrefix("#") { s.removeFirst() }
            var v: UInt64 = 0
            Scanner(string: String(s.prefix(6))).scanHexInt64(&v)
            return (Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255))
        }
        var used = Set<Int>()
        var out: [Int: Int] = [:]
        let candidates = trays.filter { $0.loaded && $0.id != 254 }
        for f in filaments {
            var best: Tray?
            var bd = Double.infinity
            for t in candidates {
                let a = rgb(f.color), b = rgb(t.color)
                var d = ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
                if !t.type.isEmpty && t.type.uppercased() != f.type.uppercased() { d += 120 }
                if used.contains(t.id) { d += 60 }
                if d < bd { bd = d; best = t }
            }
            if let best { out[f.id] = best.id; used.insert(best.id) } else { out[f.id] = 254 }
        }
        return out
    }

    func startPrint(file: Data, summary: SliceSummary, jobName: String, mapping: [Int: Int], options: StartOptions) async throws {
        guard connected, let session else { throw SlicerEngine.EngineError.message("The printer isn't connected.") }
        guard !isBusy else { throw SlicerEngine.EngineError.message("The printer is busy. Wait for the current print to finish.") }
        guard let code = Keychain.get("printer.code") else { throw SlicerEngine.EngineError.message("Add the access code in Printer settings.") }
        let safe = jobName.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression).prefix(60)
        let plateId = summary.plateId ?? 1
        let remote = "\(safe.isEmpty ? "print" : String(safe))_p\(plateId).gcode.3mf"
        let host = ip
        uploadProgress = 0
        defer { uploadProgress = nil }
        try await Task.detached(priority: .userInitiated) {
            try FTPS.upload(host: host, code: code, remoteName: remote, data: file) { p in
                Task { @MainActor [weak self] in self?.uploadProgress = p }
            }
        }.value
        let ids = (summary.filaments ?? []).map { $0.id }
        var ams = Array(repeating: -1, count: max(ids.max() ?? 1, 1))
        for f in summary.filaments ?? [] { ams[f.id - 1] = mapping[f.id] ?? 254 }
        let useAms = ams.contains { $0 >= 0 && $0 != 254 }
        let inner: [String: Any] = [
            "sequence_id": String(Int(Date().timeIntervalSince1970) % 100_000_000),
            "command": "project_file",
            "param": summary.gcodePath ?? "Metadata/plate_\(plateId).gcode",
            "project_id": "0", "profile_id": "0", "task_id": "0", "subtask_id": "0",
            "subtask_name": String(safe),
            "file": remote,
            "url": "ftp:///\(remote)",
            "md5": "",
            "bed_type": summary.bedCode ?? "auto",
            "bed_leveling": options.bedLeveling,
            "bed_levelling": options.bedLeveling,
            "flow_cali": options.flowCalibration,
            "vibration_cali": options.vibrationCalibration,
            "layer_inspect": false,
            "timelapse": options.timelapse,
            "use_ams": useAms,
            "ams_mapping": useAms ? ams : [Int](),
        ]
        let cmd: [String: Any] = ["print": inner]
        guard session.publish(cmd) else { throw SlicerEngine.EngineError.message("The upload worked, but the print command didn't go through. Try again.") }
        lastResult = "Sent \(remote) to the printer."
    }
}
