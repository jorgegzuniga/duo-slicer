import Foundation
import SwiftUI

struct ProjectInfo: Codable {
    var printerModel: String           // printer the project was designed for
    var printer: TargetPrinter?        // printer it is being sliced for
    var filaments: [FilamentInfo]
    var plates: [PlateInfo]
    var processes: [String]
    var defaultProcess: String
    var filamentPresets: [String]
    var bedType: String
}

/// The printer the engine is slicing for (from the engine's profile bundle).
struct TargetPrinter: Codable, Hashable {
    var id: String
    var name: String
    var vendor: String
    var kind: String
    var tools: Int
    var nozzle: Double
    var modelId: String
    var bed: PrinterModel.Bed?
    var bedTypes: [String]

    var isToolChanger: Bool { kind == "klipper_toolchanger" }
}

struct FilamentInfo: Codable, Hashable {
    var index: Int
    var color: String
    var type: String
    var settingId: String
    var preset: String
}

struct PlateInfo: Codable, Identifiable, Hashable {
    var index: Int
    var id: Int
    var name: String
    var hasThumbnail: Bool
    var objects: [ObjectInfo]
    var filaments: [Int]
    var offBed: Bool
    var fitIssues: [String]?
    var height: Double
    var toolMap: [Int]?          // tool changers: default toolhead per project filament (-1 = unused)
    var needsMoreTools: Bool?
}

struct ObjectInfo: Codable, Identifiable, Hashable {
    var index: Int
    var id: String
    var name: String
    var filaments: [Int]
    var offBed: Bool
    var fit: String?             // "", "off_bed", "too_tall", "excluded_zone"
    var edited: Bool
    var min: [Double]
    var max: [Double]
    var overrides: [String: String]?
}

struct SlicedFilament: Codable, Hashable, Identifiable {
    var id: Int                  // project filament (first one on that toolhead for tool changers)
    var tool: Int?               // G-code filament: AMS filament index on Bambu, toolhead on tool changers
    var projectFilaments: [Int]?
    var type: String
    var color: String
    var grams: Double
    var meters: Double
    var flushGrams: Double
    var preset: String
    var trayInfoIdx: String
}

struct SliceSummary: Codable {
    var ok: Bool?
    var error: String?
    var plate: Int?
    var plateId: Int?
    var printerId: String?
    var printer: String?
    var fileKind: String?        // "gcode.3mf" (Bambu) or "gcode" (Klipper)
    var gcodePath: String?
    var seconds: Double?
    var modelSeconds: Double?
    var grams: Double?
    var layers: Int?
    var toolChanges: Int?
    var filaments: [SlicedFilament]?
    var toolMap: [Int]?
    var bedType: String?
    var bedCode: String?
    var process: String?
    var fileBytes: Int?
    var warnings: [String]?

    var isPlainGcode: Bool { fileKind == "gcode" }
}

/// What the user chose in the settings screen; sent to the engine as JSON.
struct PrintOptions: Equatable {
    var process: String = ""
    var filaments: [String] = []      // preset name per project filament
    var colors: [String] = []         // hex per project filament
    var overrides: [String: String] = [:]
    var toolMap: [Int] = []           // tool changers: toolhead per project filament (-1 = choose automatically)

    func json(extra: [String: Any] = [:]) -> String {
        var d: [String: Any] = ["filaments": filaments, "colors": colors, "overrides": overrides]
        if !process.isEmpty { d["process"] = process }
        if toolMap.contains(where: { $0 >= 0 }) { d["tool_map"] = toolMap }
        for (k, v) in extra { d[k] = v }
        let data = (try? JSONSerialization.data(withJSONObject: d)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

enum JSONCoding {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: String(s.prefix(6))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(round(max(0, min(1, r)) * 255)), Int(round(max(0, min(1, g)) * 255)), Int(round(max(0, min(1, b)) * 255)))
    }
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: String(s.prefix(6))).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

/// RGB distance between two hex colours (0 = same), for matching spools and toolheads.
func colorDistance(_ a: String, _ b: String) -> Double {
    func rgb(_ h: String) -> (Double, Double, Double) {
        var s = h
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: String(s.prefix(6))).scanHexInt64(&v)
        return (Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255))
    }
    let x = rgb(a), y = rgb(b)
    return ((x.0 - y.0) * (x.0 - y.0) + (x.1 - y.1) * (x.1 - y.1) + (x.2 - y.2) * (x.2 - y.2)).squareRoot()
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600, m = (s % 3600) / 60
    return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m) min"
}

/// "Bambu PLA Basic @BBL X1C" -> "Bambu PLA Basic"; "0.20mm Standard @BBL A1" -> "0.20mm Standard".
func presetDisplayName(_ preset: String) -> String {
    if let r = preset.range(of: " @") { return String(preset[..<r.lowerBound]) }
    return preset
}

func bedTypeLabel(_ bed: String) -> String {
    switch bed {
    case "Textured PEI Plate": return "Textured PEI"
    case "High Temp Plate": return "Smooth PEI / High Temp"
    case "Cool Plate": return "Cool Plate"
    case "Supertack Plate": return "Cool Plate SuperTack"
    case "Engineering Plate": return "Engineering Plate"
    case "Textured Cool Plate": return "Textured Cool Plate"
    default: return bed
    }
}
