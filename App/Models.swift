import Foundation
import SwiftUI

struct ProjectInfo: Codable {
    var printerModel: String
    var filaments: [FilamentInfo]
    var plates: [PlateInfo]
    var processes: [String]
    var defaultProcess: String
    var filamentPresets: [String]
    var bedType: String
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
    var height: Double
}

struct ObjectInfo: Codable, Identifiable, Hashable {
    var index: Int
    var id: String
    var name: String
    var filaments: [Int]
    var offBed: Bool
    var edited: Bool
    var min: [Double]
    var max: [Double]
    var overrides: [String: String]?
}

struct SlicedFilament: Codable, Hashable, Identifiable {
    var id: Int
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
    var gcodePath: String?
    var seconds: Double?
    var modelSeconds: Double?
    var grams: Double?
    var layers: Int?
    var toolChanges: Int?
    var filaments: [SlicedFilament]?
    var bedType: String?
    var bedCode: String?
    var process: String?
    var fileBytes: Int?
    var warnings: [String]?
}

/// What the user chose in the settings screen; sent to the engine as JSON.
struct PrintOptions: Equatable {
    var process: String = ""
    var filaments: [String] = []      // preset name per project filament
    var colors: [String] = []         // hex per project filament
    var overrides: [String: String] = [:]

    func json() -> String {
        var d: [String: Any] = ["filaments": filaments, "colors": colors, "overrides": overrides]
        if !process.isEmpty { d["process"] = process }
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

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600, m = (s % 3600) / 60
    return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m) min"
}

func presetDisplayName(_ preset: String) -> String {
    if let r = preset.range(of: " @BBL") { return String(preset[..<r.lowerBound]) }
    return preset
}
