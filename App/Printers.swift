import Foundation

/// A printer model the slicer has profiles for (Resources/profiles/index.json).
struct PrinterModel: Codable, Identifiable, Hashable {
    var id: String              // e.g. "bambu-x1c"
    var vendor: String          // "Bambu Lab", "Snapmaker"
    var name: String            // "Bambu Lab X1 Carbon"
    var kind: String            // "bambu" or "klipper_toolchanger"
    var machineName: String
    var modelId: String
    var nozzle: Double
    var tools: Int
    var bed: Bed
    var defaultProcess: String

    struct Bed: Codable, Hashable {
        var min: [Double]
        var max: [Double]
        var height: Double
        var exclude: [[Double]]

        var x0: Double { min.first ?? 0 }
        var y0: Double { min.count > 1 ? min[1] : 0 }
        var x1: Double { max.first ?? 256 }
        var y1: Double { max.count > 1 ? max[1] : 256 }
        var width: Double { x1 - x0 }
        var depth: Double { y1 - y0 }
        /// No-print box (X1/P1 filament cutter corner): x0, y0, x1, y1.
        var excludeBox: (Double, Double, Double, Double)? {
            guard exclude.count == 2, exclude[0].count == 2, exclude[1].count == 2 else { return nil }
            return (exclude[0][0], exclude[0][1], exclude[1][0], exclude[1][1])
        }

        static let a1 = Bed(min: [0, 0], max: [256, 256], height: 256, exclude: [])
    }

    var isBambu: Bool { kind == "bambu" }
    var isToolChanger: Bool { kind == "klipper_toolchanger" }
    /// "X1 Carbon", "A1 mini", "U1"
    var shortName: String {
        for prefix in ["Bambu Lab ", "Snapmaker "] where name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
        return name
    }
}

enum PrinterCatalog {
    static let fallbackID = "bambu-a1"

    static let models: [PrinterModel] = {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "json", subdirectory: "profiles"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONCoding.decoder.decode([PrinterModel].self, from: data) else { return [] }
        return list
    }()

    static func model(_ id: String) -> PrinterModel? { models.first { $0.id == id } }

    static var vendors: [String] {
        var seen: [String] = []
        for m in models where !seen.contains(m.vendor) { seen.append(m.vendor) }
        return seen
    }

    /// Full profile bundle for the engine (machine, quality and filament presets).
    static func bundleJSON(_ id: String) -> String? {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "profiles") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// A printer on the user's network.
struct SavedPrinter: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var modelID: String          // PrinterModel.id
    var name: String             // what the user calls it
    var host: String             // IP address or host name
    var serial: String = ""      // Bambu: serial number (MQTT topic)
    var port: Int = 7125         // Moonraker (Snapmaker U1)

    var model: PrinterModel? { PrinterCatalog.model(modelID) }
    /// Keychain key for the Bambu access code or the Moonraker API key.
    var secretKey: String { "printer.secret.\(id)" }

    var hostOnly: String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["http://", "https://"] where h.lowercased().hasPrefix(p) { h = String(h.dropFirst(p.count)) }
        while h.hasSuffix("/") { h.removeLast() }
        return h
    }
}

enum PrinterStore {
    private static let listKey = "printers.v2"
    private static let activeKey = "printers.active"

    static func load() -> (printers: [SavedPrinter], active: String?) {
        let d = UserDefaults.standard
        if let data = d.data(forKey: listKey), let list = try? JSONDecoder().decode([SavedPrinter].self, from: data) {
            let active = d.string(forKey: activeKey)
            return (list, list.contains { $0.id == active } ? active : list.first?.id)
        }
        // first launch after the multi-printer update: bring over the single A1 from earlier builds
        if let ip = d.string(forKey: "printer.ip"), !ip.isEmpty {
            let p = SavedPrinter(modelID: "bambu-a1", name: "Bambu Lab A1", host: ip, serial: d.string(forKey: "printer.serial") ?? "")
            if let code = Keychain.get("printer.code") { Keychain.set(code, for: p.secretKey) }
            save([p], active: p.id)
            return ([p], p.id)
        }
        return ([], nil)
    }

    static func save(_ printers: [SavedPrinter], active: String?) {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(printers) { d.set(data, forKey: listKey) }
        d.set(active, forKey: activeKey)
    }
}
