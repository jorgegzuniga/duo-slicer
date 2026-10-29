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

    static func delete(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
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
            let clientId = "duoslicer-\(UInt32.random(in: 1000...999_999))"
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

/// One head of a tool changer (Snapmaker U1) and the filament the printer reports in it.
struct Toolhead: Identifiable, Hashable {
    var id: Int            // 0-based (T0 in G-code)
    var type: String       // "PLA", "" when unknown
    var color: String      // "#RRGGBB", "" when unknown
    var vendor: String
    var subType: String
    var loaded: Bool
    var temperature: Double

    var label: String { "Head \(id + 1)" }
    var summary: String {
        guard loaded else { return "Empty" }
        let name = [vendor, type, subType].filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return name.joined(separator: " ")
    }
}

@MainActor
final class PrinterLink: ObservableObject {
    @Published private(set) var printers: [SavedPrinter] = []
    @Published private(set) var activeID: String?
    @Published var connected = false
    @Published var statusText = "Not set up"
    @Published var state = "OFFLINE"   // IDLE, PREPARE, RUNNING, PAUSE, FINISH, FAILED, OFFLINE
    @Published var percent = 0
    @Published var remainingMinutes = 0
    @Published var layer = 0
    @Published var totalLayers = 0
    @Published var nozzle = 0.0
    @Published var bed = 0.0
    @Published var jobName = ""
    @Published var printError = 0
    @Published var errorText: String?
    @Published var trays: [Tray] = []          // Bambu AMS
    @Published var toolheads: [Toolhead] = []  // tool changers
    @Published var uploadProgress: Double?
    @Published var lastResult: String?

    private var mqtt: MqttSession?
    private var poller: MoonrakerPoller?
    private var report: [String: Any] = [:]

    init() {
        let s = PrinterStore.load()
        printers = s.printers
        activeID = s.active
    }

    var active: SavedPrinter? { printers.first { $0.id == activeID } }
    var activeModel: PrinterModel? { active?.model }
    var isConfigured: Bool { active != nil }
    var isBusy: Bool { ["RUNNING", "PAUSE", "PREPARE", "SLICING"].contains(state) }

    func secret(for p: SavedPrinter) -> String? { Keychain.get(p.secretKey) }
    func hasSecret(_ p: SavedPrinter) -> Bool { secret(for: p) != nil }

    // MARK: printer list

    func upsert(_ printer: SavedPrinter, secret: String?) {
        var p = printer
        p.host = p.hostOnly
        p.serial = p.serial.trimmingCharacters(in: .whitespaces).uppercased()
        p.name = p.name.trimmingCharacters(in: .whitespaces).isEmpty ? (p.model?.name ?? "Printer") : p.name.trimmingCharacters(in: .whitespaces)
        if let i = printers.firstIndex(where: { $0.id == p.id }) { printers[i] = p } else { printers.append(p) }
        if let secret {
            let t = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { Keychain.set(t, for: p.secretKey) }
        }
        if activeID == nil || activeID == p.id { activeID = p.id }
        persist()
        if activeID == p.id { reconnect() }
    }

    func remove(_ p: SavedPrinter) {
        printers.removeAll { $0.id == p.id }
        Keychain.delete(p.secretKey)
        if activeID == p.id {
            activeID = printers.first?.id
            reconnect()
        }
        persist()
    }

    func select(_ id: String) {
        guard id != activeID, printers.contains(where: { $0.id == id }) else { return }
        activeID = id
        persist()
        reconnect()
    }

    private func persist() { PrinterStore.save(printers, active: activeID) }

    /// The saved printer a found one is (same serial number, or same address).
    func saved(matching f: FoundPrinter) -> SavedPrinter? {
        printers.first { (!f.serial.isEmpty && $0.serial == f.serial) || $0.hostOnly == f.host }
    }

    /// A saved Bambu printer turned up at a new address (the router handed out another one): follow it.
    func follow(_ f: FoundPrinter) {
        guard !f.serial.isEmpty,
              let i = printers.firstIndex(where: { $0.serial == f.serial && $0.hostOnly != f.host }) else { return }
        printers[i].host = f.host
        persist()
        if printers[i].id == activeID { reconnect() }
    }

    // MARK: connection

    func start() {
        if mqtt == nil && poller == nil { reconnect() }
    }

    func reconnect() {
        mqtt?.stop()
        mqtt = nil
        poller?.stop()
        poller = nil
        report = [:]
        trays = []
        toolheads = []
        connected = false
        state = "OFFLINE"
        percent = 0
        layer = 0
        totalLayers = 0
        jobName = ""
        printError = 0
        errorText = nil
        guard let p = active, let model = p.model else {
            statusText = "Add a printer to send prints over Wi-Fi."
            return
        }
        if model.isBambu {
            guard !p.hostOnly.isEmpty, !p.serial.isEmpty, let code = secret(for: p) else {
                statusText = "Add the \(model.shortName)'s IP address, serial number and access code."
                return
            }
            let s = MqttSession(host: p.hostOnly, serial: p.serial, code: code)
            mqtt = s
            DispatchQueue.global(qos: .utility).async {
                s.run(onState: { ok, text in
                    Task { @MainActor [weak self] in
                        guard let self, self.mqtt === s else { return }
                        self.connected = ok
                        self.statusText = text
                        if !ok { self.state = "OFFLINE" }
                    }
                }, onMessage: { data in
                    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.mqtt === s else { return }
                        self.mergeBambu(obj)
                    }
                })
            }
        } else {
            guard let client = MoonrakerClient(host: p.hostOnly, port: p.port, apiKey: secret(for: p)) else {
                statusText = "Add the \(model.shortName)'s IP address."
                return
            }
            let poll = MoonrakerPoller(client: client)
            poller = poll
            statusText = "Connecting to \(p.hostOnly)…"
            Task.detached(priority: .utility) {
                await poll.run(onState: { ok, text in
                    Task { @MainActor [weak self] in
                        guard let self, self.poller === poll else { return }
                        self.connected = ok
                        self.statusText = text
                        if !ok { self.state = "OFFLINE" }
                    }
                }, onStatus: { st in
                    Task { @MainActor [weak self] in
                        guard let self, self.poller === poll else { return }
                        self.mergeMoonraker(st)
                    }
                })
            }
        }
    }

    func disconnect() {
        mqtt?.stop()
        mqtt = nil
        poller?.stop()
        poller = nil
        connected = false
        statusText = "Disconnected"
    }

    // MARK: status

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

    private func mergeBambu(_ obj: [String: Any]) {
        PrinterLink.deepMerge(&report, obj)
        guard let p = report["print"] as? [String: Any] else { return }
        func int(_ k: String) -> Int? { (p[k] as? NSNumber)?.intValue ?? Int(p[k] as? String ?? "") }
        func dbl(_ k: String) -> Double? { (p[k] as? NSNumber)?.doubleValue ?? Double(p[k] as? String ?? "") }
        if let s = p["gcode_state"] as? String { state = s == "IDLE" || s.isEmpty ? "IDLE" : s }
        percent = int("mc_percent") ?? percent
        remainingMinutes = int("mc_remaining_time") ?? remainingMinutes
        layer = int("layer_num") ?? layer
        totalLayers = int("total_layer_num") ?? totalLayers
        nozzle = dbl("nozzle_temper") ?? nozzle
        bed = dbl("bed_temper") ?? bed
        jobName = (p["subtask_name"] as? String) ?? jobName
        printError = int("print_error") ?? 0
        errorText = printError != 0 ? "The printer reports error \(String(printError, radix: 16).uppercased()). Check its screen." : nil
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

    private func mergeMoonraker(_ st: [String: Any]) {
        func obj(_ k: String) -> [String: Any] { st[k] as? [String: Any] ?? [:] }
        func num(_ o: [String: Any], _ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        func clean(_ v: Any) -> String {
            let s = "\(v)".trimmingCharacters(in: .whitespaces)
            return s.uppercased() == "NONE" || s == "<null>" ? "" : s
        }
        let ps = obj("print_stats")
        let info = ps["info"] as? [String: Any] ?? [:]
        let s = ps["state"] as? String ?? "standby"
        let curLayer = (info["current_layer"] as? NSNumber)?.intValue ?? 0
        let totLayer = (info["total_layer"] as? NSNumber)?.intValue ?? 0
        switch s {
        case "printing": state = curLayer > 0 ? "RUNNING" : "PREPARE"
        case "paused": state = "PAUSE"
        case "complete": state = "FINISH"
        case "cancelled", "error": state = "FAILED"
        default: state = "IDLE"
        }
        let wh = obj("webhooks")
        if let ws = wh["state"] as? String, ws != "ready" {
            errorText = (wh["state_message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Klipper is \(ws)."
        } else if s == "error" {
            errorText = (ps["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "The print stopped with an error."
        } else {
            errorText = nil
        }
        printError = errorText == nil ? 0 : 1
        var progress = num(obj("display_status"), "progress") ?? 0
        if progress <= 0 { progress = num(obj("virtual_sdcard"), "progress") ?? 0 }
        percent = max(0, min(100, Int((progress * 100).rounded())))
        let dur = num(ps, "print_duration") ?? 0
        remainingMinutes = progress > 0.01 && progress < 1 ? Int(dur * (1 - progress) / progress / 60) : 0
        layer = curLayer
        totalLayers = totLayer
        var name = ps["filename"] as? String ?? ""
        if name.lowercased().hasSuffix(".gcode") { name = String(name.dropLast(6)) }
        jobName = name
        let activeExt = obj("toolhead")["extruder"] as? String ?? "extruder"
        nozzle = num(obj(activeExt), "temperature") ?? 0
        bed = num(obj("heater_bed"), "temperature") ?? 0
        let ptc = obj("print_task_config")
        let types = ptc["filament_type"] as? [Any] ?? []
        let colors = ptc["filament_color_rgba"] as? [Any] ?? []
        let exist = ptc["filament_exist"] as? [Any] ?? []
        let vendors = ptc["filament_vendor"] as? [Any] ?? []
        let subs = ptc["filament_sub_type"] as? [Any] ?? []
        let n = max(1, activeModel?.tools ?? 4)
        var heads: [Toolhead] = []
        for i in 0..<n {
            func at(_ a: [Any]) -> String { i < a.count ? clean(a[i]) : "" }
            let type = at(types)
            var present = !type.isEmpty
            if i < exist.count {
                if let b = exist[i] as? Bool { present = b } else if let nb = exist[i] as? NSNumber { present = nb.boolValue }
            }
            let rgba = at(colors).replacingOccurrences(of: "#", with: "")
            let color = rgba.count >= 6 && !type.isEmpty ? "#" + rgba.prefix(6).uppercased() : ""
            let ext = obj(i == 0 ? "extruder" : "extruder\(i)")
            heads.append(Toolhead(id: i, type: type, color: color, vendor: at(vendors), subType: at(subs), loaded: present && !type.isEmpty,
                                  temperature: num(ext, "temperature") ?? 0))
        }
        toolheads = heads
    }

    // MARK: control

    /// pause, resume or stop the current print
    func control(_ action: String) async throws {
        guard let p = active, let model = p.model else { throw SlicerEngine.EngineError.message("Add a printer first.") }
        if model.isBambu {
            guard let mqtt, mqtt.publish(["print": ["sequence_id": "0", "command": action, "param": ""]]) else {
                throw SlicerEngine.EngineError.message("The printer isn't connected.")
            }
        } else {
            guard let client = MoonrakerClient(host: p.hostOnly, port: p.port, apiKey: secret(for: p)) else {
                throw SlicerEngine.EngineError.message("The printer isn't set up.")
            }
            try await client.control(action == "stop" ? "cancel" : action)
        }
    }

    func send(_ command: String) {
        Task {
            do { try await control(command) } catch { lastResult = error.localizedDescription }
        }
    }

    /// Best spool for each sliced filament: nearest colour, preferring the same material, each spool used once if possible.
    func suggestMapping(for filaments: [SlicedFilament]) -> [Int: Int] {
        var used = Set<Int>()
        var out: [Int: Int] = [:]
        let candidates = trays.filter { $0.loaded && $0.id != 254 }
        for f in filaments {
            var best: Tray?
            var bd = Double.infinity
            for t in candidates {
                var d = colorDistance(f.color, t.color)
                if !t.type.isEmpty && t.type.uppercased() != f.type.uppercased() { d += 120 }
                if used.contains(t.id) { d += 60 }
                if d < bd { bd = d; best = t }
            }
            if let best { out[f.id] = best.id; used.insert(best.id) } else { out[f.id] = 254 }
        }
        return out
    }

    /// Toolhead for each filament on a plate (tool changers): the loaded head with the closest colour, same material preferred,
    /// each head used once. Without printer data the filaments take heads in order.
    func suggestToolMap(filaments: [(index: Int, color: String, type: String)], tools: Int) -> [Int: Int] {
        var out: [Int: Int] = [:]
        var taken = Set<Int>()
        let heads = toolheads.filter { $0.loaded }
        if !heads.isEmpty {
            // closest pairs first
            var pairs: [(d: Double, f: Int, h: Int)] = []
            for f in filaments {
                for h in heads {
                    var d = colorDistance(f.color, h.color)
                    if h.type.uppercased() != f.type.uppercased() { d += 150 }
                    pairs.append((d, f.index, h.id))
                }
            }
            for p in pairs.sorted(by: { $0.d < $1.d }) where out[p.f] == nil && !taken.contains(p.h) {
                out[p.f] = p.h
                taken.insert(p.h)
            }
        }
        for f in filaments where out[f.index] == nil {
            if let t = (0..<tools).first(where: { !taken.contains($0) }) {
                out[f.index] = t
                taken.insert(t)
            }
        }
        return out
    }

    // MARK: printing

    func startPrint(file: Data, summary: SliceSummary, jobName: String, mapping: [Int: Int], options: StartOptions) async throws {
        guard let p = active, let model = p.model else { throw SlicerEngine.EngineError.message("Add a printer first.") }
        guard connected else { throw SlicerEngine.EngineError.message("The \(model.shortName) isn't connected.") }
        guard !isBusy else { throw SlicerEngine.EngineError.message("The printer is busy. Wait for the current print to finish.") }
        if let target = summary.printerId, target != model.id {
            throw SlicerEngine.EngineError.message("This plate was sliced for the \(summary.printer ?? target). Slice it again for the \(model.name).")
        }
        let safe = String(jobName.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression).prefix(60))
        let base = safe.isEmpty ? "print" : safe
        let plateId = summary.plateId ?? 1
        uploadProgress = 0
        defer { uploadProgress = nil }
        if model.isBambu {
            try await startBambu(p, file: file, summary: summary, remote: "\(base)_p\(plateId).gcode.3mf", subtask: base, mapping: mapping, options: options)
        } else {
            guard let client = MoonrakerClient(host: p.hostOnly, port: p.port, apiKey: secret(for: p)) else {
                throw SlicerEngine.EngineError.message("Add the printer's IP address.")
            }
            let name = "\(base)_p\(plateId).gcode"
            try await client.upload(name: name, data: file) { f in
                Task { @MainActor [weak self] in self?.uploadProgress = f }
            }
            try await client.start(name: name)
            lastResult = "Sent \(name) to the \(model.shortName)."
        }
    }

    private func startBambu(_ p: SavedPrinter, file: Data, summary: SliceSummary, remote: String, subtask: String, mapping: [Int: Int], options: StartOptions) async throws {
        guard let session = mqtt else { throw SlicerEngine.EngineError.message("The printer isn't connected.") }
        guard let code = secret(for: p) else { throw SlicerEngine.EngineError.message("Add the access code in the printer's settings.") }
        let host = p.hostOnly
        try await Task.detached(priority: .userInitiated) {
            try FTPS.upload(host: host, code: code, remoteName: remote, data: file) { f in
                Task { @MainActor [weak self] in self?.uploadProgress = f }
            }
        }.value
        let ids = (summary.filaments ?? []).map { $0.id }
        var ams = Array(repeating: -1, count: max(ids.max() ?? 1, 1))
        for f in summary.filaments ?? [] { ams[f.id - 1] = mapping[f.id] ?? 254 }
        let useAms = ams.contains { $0 >= 0 && $0 != 254 }
        let ams2: [[String: Int]] = ams.map { t in
            if t == 254 { return ["ams_id": 255, "slot_id": 0] }
            if t < 0 { return ["ams_id": 255, "slot_id": 255] }
            return ["ams_id": t / 4, "slot_id": t % 4]
        }
        let plateId = summary.plateId ?? 1
        let inner: [String: Any] = [
            "sequence_id": String(Int(Date().timeIntervalSince1970) % 100_000_000),
            "command": "project_file",
            "param": summary.gcodePath ?? "Metadata/plate_\(plateId).gcode",
            "project_id": "0", "profile_id": "0", "task_id": "0", "subtask_id": "0",
            "subtask_name": subtask,
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
            "ams_mapping2": useAms ? ams2 : [[String: Int]](),
        ]
        guard session.publish(["print": inner]) else {
            throw SlicerEngine.EngineError.message("The upload worked, but the print command didn't go through. Try again.")
        }
        lastResult = "Sent \(remote) to the printer."
    }
}
