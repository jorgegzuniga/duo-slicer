import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var project: ProjectInfo?
    @Published var fileName = ""
    @Published var plateIndex = 0
    @Published var selectedObject: Int?
    @Published var mesh: SlicerEngine.Mesh?
    @Published var meshRevision = 0
    @Published var options = PrintOptions()
    @Published var effective: [String: String] = [:]
    @Published var slice: SliceSummary?
    @Published var slicedPlate: Int?
    @Published var slicing = false
    @Published var sliceProgress = 0.0
    @Published var busy = false
    @Published var errorMessage: String?
    @Published var thumbnails: [Int: UIImage] = [:]
    @Published var recents: [URL] = []
    @Published var layerCount = 0
    @Published var previewLayer = 0
    @Published var preview: SlicerEngine.LayerPreview?
    @Published var previewZ = 0.0

    private let engine = SlicerEngine()
    private let queue = DispatchQueue(label: "a1.engine", qos: .userInitiated)

    init() { loadRecents() }

    var plate: PlateInfo? {
        guard let p = project, plateIndex >= 0, plateIndex < p.plates.count else { return nil }
        return p.plates[plateIndex]
    }

    var sliceIsCurrent: Bool { slice != nil && slicedPlate == plateIndex }

    private func run<T>(_ work: @escaping (SlicerEngine) -> T) async -> T {
        let engine = self.engine
        return await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: work(engine)) }
        }
    }

    // MARK: files

    private var projectsDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func loadRecents() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        recents = urls.filter { ["3mf", "zip"].contains($0.pathExtension.lowercased()) }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    func deleteRecent(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        loadRecents()
    }

    func open(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            errorMessage = "Couldn't read that file: \(error.localizedDescription)"
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
        var name = url.lastPathComponent
        if name.lowercased().hasSuffix(".3mf.zip") { name = String(name.dropLast(4)) }
        if url.deletingLastPathComponent().standardizedFileURL != projectsDir.standardizedFileURL {
            let dest = projectsDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try? data.write(to: dest)
        } else {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        loadRecents()
        await load(data: data, name: name)
    }

    func load(data: Data, name: String) async {
        busy = true
        defer { busy = false }
        let result: Result<ProjectInfo, Error> = await run { eng in
            do { return .success(try eng.open(data)) } catch { return .failure(error) }
        }
        switch result {
        case .failure(let e):
            errorMessage = e.localizedDescription
        case .success(let info):
            project = info
            fileName = name.replacingOccurrences(of: ".3mf", with: "", options: [.caseInsensitive])
            plateIndex = 0
            selectedObject = nil
            slice = nil
            slicedPlate = nil
            preview = nil
            options = PrintOptions(process: info.defaultProcess,
                                   filaments: info.filaments.map { $0.preset },
                                   colors: info.filaments.map { $0.color },
                                   overrides: ["curr_bed_type": "Textured PEI Plate"])
            let count = info.plates.count
            let thumbs: [Int: UIImage] = await run { eng in
                var t: [Int: UIImage] = [:]
                for i in 0..<count { if let img = eng.thumbnail(i) { t[i] = img } }
                return t
            }
            thumbnails = thumbs
            await refreshMesh()
            await refreshEffective()
        }
    }

    func close() {
        project = nil
        mesh = nil
        slice = nil
        preview = nil
    }

    // MARK: plate + mesh

    func selectPlate(_ i: Int) async {
        guard i != plateIndex else { return }
        plateIndex = i
        selectedObject = nil
        await refreshMesh()
        if slicedPlate == i { await loadPreview() }
    }

    func refreshMesh() async {
        let p = plateIndex
        mesh = await run { $0.plateMesh(p) }
        meshRevision += 1
    }

    private func afterTransform() async {
        let info: ProjectInfo? = await run { try? $0.info() }
        if let info { project = info }
        if slicedPlate == plateIndex { slice = nil; slicedPlate = nil; preview = nil }
        await refreshMesh()
    }

    func rotate(axis: Int, degrees: Double) async {
        guard let o = selectedObject else { return }
        await run { $0.rotate(object: o, axis: axis, degrees: degrees) }
        await afterTransform()
    }

    func layFlat(normal: SIMD3<Double>) async {
        guard let o = selectedObject else { return }
        await run { $0.layFlat(object: o, normal: normal) }
        await afterTransform()
    }

    func autoFlat() async {
        guard let o = selectedObject else { return }
        await run { $0.autoFlat(object: o) }
        await afterTransform()
    }

    func resetObject() async {
        guard let o = selectedObject else { return }
        await run { $0.reset(object: o) }
        await afterTransform()
    }

    // MARK: settings

    func refreshEffective() async {
        let opts = options
        let raw: [String: Any] = await run { $0.settings(opts) }
        var flat: [String: String] = [:]
        for (k, v) in raw {
            if let s = v as? String { flat[k] = s } else if let n = v as? NSNumber { flat[k] = n.stringValue }
        }
        effective = flat
    }

    func setOverride(_ key: String, _ value: String?) async {
        if let value { options.overrides[key] = value } else { options.overrides.removeValue(forKey: key) }
        invalidateSlice()
        await refreshEffective()
    }

    func setProcess(_ p: String) async {
        options.process = p
        options.overrides.removeValue(forKey: "layer_height")
        invalidateSlice()
        await refreshEffective()
    }

    func setFilamentPreset(_ filament: Int, _ preset: String) async {
        guard filament - 1 < options.filaments.count else { return }
        options.filaments[filament - 1] = preset
        invalidateSlice()
        await refreshEffective()
    }

    func setColor(_ filament: Int, _ hex: String) {
        guard filament - 1 < options.colors.count else { return }
        options.colors[filament - 1] = hex
        invalidateSlice()
    }

    func color(of filament: Int) -> Color {
        guard filament >= 1, filament - 1 < options.colors.count else { return .gray }
        return Color(hex: options.colors[filament - 1])
    }

    func invalidateSlice() {
        if slice != nil { slice = nil; slicedPlate = nil; preview = nil }
    }

    // MARK: slicing

    func sliceCurrent() async {
        guard !slicing else { return }
        slicing = true
        sliceProgress = 0
        slice = nil
        preview = nil
        let plate = plateIndex
        let opts = options
        let summary: SliceSummary = await run { eng in
            eng.slice(plate: plate, options: opts) { p in
                Task { @MainActor [weak self] in self?.sliceProgress = p }
            }
        }
        slicing = false
        if let e = summary.error {
            errorMessage = e
            return
        }
        slice = summary
        slicedPlate = plate
        layerCount = await run { $0.layerCount }
        previewLayer = max(0, layerCount - 1)
        await loadPreview()
    }

    func loadPreview() async {
        let l = previewLayer
        let (pv, z): (SlicerEngine.LayerPreview, Double) = await run { ($0.layerPreview(l), $0.layerZ(l)) }
        preview = pv
        previewZ = z
    }

    func slicedFile() async -> Data? { await run { $0.slicedFile() } }

    func exportProjectFile() async -> URL? {
        guard let data = await run({ $0.exportProject() }) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileName)-edited.3mf")
        try? FileManager.default.removeItem(at: url)
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    func exportSlicedFile() async -> URL? {
        guard let data = await slicedFile(), let s = slice else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileName)-plate\(s.plateId ?? 1).gcode.3mf")
        try? FileManager.default.removeItem(at: url)
        do { try data.write(to: url) } catch { return nil }
        return url
    }
}
