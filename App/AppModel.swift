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
    @Published var toolMapIsCustom = false   // the user picked toolheads by hand
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
    /// A short message over the 3D view ("Moved Tag 2 to Plate 3"); clears itself.
    @Published var notice: String?
    private var noticeTask: Task<Void, Never>?
    /// Printer model the plates are sliced for (follows the selected printer).
    @Published private(set) var target: PrinterModel

    private let engine = SlicerEngine()
    private let queue = DispatchQueue(label: "duo.engine", qos: .userInitiated)
    private var engineTarget = ""

    init() {
        let saved = UserDefaults.standard.string(forKey: "target.model") ?? PrinterCatalog.fallbackID
        target = PrinterCatalog.model(saved) ?? PrinterCatalog.model(PrinterCatalog.fallbackID) ?? PrinterModel(
            id: PrinterCatalog.fallbackID, vendor: "Bambu Lab", name: "Bambu Lab A1", kind: "bambu", machineName: "", modelId: "N2S",
            nozzle: 0.4, tools: 1, bed: .a1, defaultProcess: "")
        loadRecents()
    }

    var plate: PlateInfo? {
        guard let p = project, plateIndex >= 0, plateIndex < p.plates.count else { return nil }
        return p.plates[plateIndex]
    }

    var bed: PrinterModel.Bed { project?.printer?.bed ?? target.bed }
    var sliceIsCurrent: Bool { slice != nil && slicedPlate == plateIndex }

    private func run<T>(_ work: @escaping (SlicerEngine) -> T) async -> T {
        let engine = self.engine
        return await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: work(engine)) }
        }
    }

    // MARK: target printer

    /// Make sure the engine has a printer before opening or slicing.
    private func ensureEngineTarget() async {
        guard engineTarget != target.id else { return }
        let id = target.id
        let r: Result<ProjectInfo?, Error> = await run { eng in
            do { return .success(try eng.setPrinter(id)) } catch { return .failure(error) }
        }
        if case .failure(let e) = r { errorMessage = e.localizedDescription; return }
        engineTarget = id
    }

    /// Slice for another printer model: re-places the plates on its bed and swaps to its presets.
    func setTarget(_ id: String) async {
        guard let m = PrinterCatalog.model(id), m.id != target.id || engineTarget != m.id else { return }
        target = m
        UserDefaults.standard.set(m.id, forKey: "target.model")
        let r: Result<ProjectInfo?, Error> = await run { eng in
            do { return .success(try eng.setPrinter(m.id)) } catch { return .failure(error) }
        }
        switch r {
        case .failure(let e):
            errorMessage = e.localizedDescription
        case .success(let info):
            engineTarget = m.id
            guard let info else { return }
            project = info
            // quality and filament presets are per printer; colours, tweaks and plate choice carry over
            options.process = info.defaultProcess
            options.filaments = info.filaments.map { $0.preset }
            if let bt = options.overrides["curr_bed_type"], !(info.printer?.bedTypes ?? []).contains(bt) {
                options.overrides["curr_bed_type"] = info.bedType
            }
            options.toolMap = []
            toolMapIsCustom = false
            slice = nil
            slicedPlate = nil
            preview = nil
            await refreshMesh()
            await refreshEffective()
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
        await ensureEngineTarget()
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
            toolMapIsCustom = false
            options = PrintOptions(process: info.defaultProcess,
                                   filaments: info.filaments.map { $0.preset },
                                   colors: info.filaments.map { $0.color },
                                   overrides: ["curr_bed_type": info.bedType])
            let count = info.plates.count
            let thumbs: [Int: UIImage] = await run { eng in
                var t: [Int: UIImage] = [:]
                for i in 0..<count { if let img = eng.thumbnail(i) { t[i] = img } }
                return t
            }
            thumbnails = thumbs
            await refreshMesh()
            await refreshThumbnails(old: info, new: info)
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
        if !toolMapIsCustom { options.toolMap = [] }
        await refreshMesh()
        if slicedPlate == i { await loadPreview() }
    }

    func refreshMesh() async {
        let p = plateIndex
        mesh = await run { $0.plateMesh(p) }
        meshRevision += 1
    }

    private func afterTransform() async {
        let old = project
        let info: ProjectInfo? = await run { try? $0.info() }
        if let info { await adopt(info, old: old) }
    }

    /// Take the project after a placement edit: drop a slice of a plate that changed, refresh the 3D view and the
    /// pictures of the plates that changed.
    private func adopt(_ info: ProjectInfo, old: ProjectInfo?) async {
        project = info
        if plateIndex >= info.plates.count { plateIndex = max(0, info.plates.count - 1) }
        if let s = selectedObject, !(plate?.objects.contains { $0.index == s } ?? false) { selectedObject = nil }
        if let sp = slicedPlate {
            let before = old.flatMap { $0.plates.indices.contains(sp) ? $0.plates[sp].objects : nil }
            let after = info.plates.indices.contains(sp) ? info.plates[sp].objects : nil
            if before != after { slice = nil; slicedPlate = nil; preview = nil }
        }
        await refreshMesh()
        await refreshThumbnails(old: old, new: info)
    }

    /// Draw pictures for plates whose objects changed, and for plates the 3MF has no picture of.
    private func refreshThumbnails(old: ProjectInfo?, new info: ProjectInfo) async {
        var changed: [Int] = []
        for (i, p) in info.plates.enumerated() {
            let before = old.flatMap { $0.plates.indices.contains(i) ? $0.plates[i] : nil }
            if before?.objects != p.objects || thumbnails[i] == nil { changed.append(i) }
        }
        thumbnails = thumbnails.filter { $0.key < info.plates.count }
        guard !changed.isEmpty else { return }
        let colors = options.colors.isEmpty ? info.filaments.map(\.color) : options.colors
        let bed = self.bed
        let images: [Int: UIImage] = await run { eng in
            var out: [Int: UIImage] = [:]
            for i in changed { out[i] = PlateThumbnail.render(eng.plateMesh(i), colors: colors, bed: bed) }
            return out
        }
        for (i, img) in images { thumbnails[i] = img }
    }

    // MARK: moving objects and plates

    var canUndo: Bool { project?.canUndo ?? false }

    func say(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    func plateLabel(_ i: Int) -> String {
        guard let p = project?.plates[safe: i] else { return "Plate \(i + 1)" }
        return p.name == "Plate \(p.id)" ? p.name : "Plate \(p.id) (\(p.name))"
    }

    func move(object o: Int, dx: Double, dy: Double) async {
        await run { $0.move(object: o, dx: dx, dy: dy) }
        await afterTransform()
    }

    /// Put the middle of an object's footprint at (x, y) on the bed.
    func place(object o: Int, x: Double, y: Double) async {
        await run { $0.place(object: o, x: x, y: y) }
        await afterTransform()
    }

    /// Pack the current plate's objects front-left first and centre them. Returns the names of objects that didn't fit.
    @discardableResult
    func arrangePlate(_ p: Int? = nil, allowRotation: Bool = false) async -> [String] {
        let plate = p ?? plateIndex
        let old = project
        let r = await run { $0.arrange(plate: plate, allowRotation: allowRotation) }
        if let e = r.error { errorMessage = e; return [] }
        if let info = r.project { await adopt(info, old: old) }
        let left = r.leftOver ?? []
        if left.isEmpty {
            say("Arranged \(r.placed ?? 0) object\((r.placed ?? 0) == 1 ? "" : "s")")
        } else {
            say("\(left.joined(separator: ", ")) didn't fit; move \(left.count == 1 ? "it" : "them") to another plate")
        }
        return left
    }

    /// Move an object to another plate (nil: a new plate). Returns the plate it went to.
    @discardableResult
    func moveObject(_ o: Int, toPlate target: Int?) async -> Int? {
        let old = project
        let name = old?.plates.flatMap(\.objects).first { $0.index == o }?.name ?? "Object"
        let r = await run { $0.moveToPlate(object: o, plate: target ?? -1) }
        if let e = r.error { errorMessage = e; return nil }
        if selectedObject == o { selectedObject = nil }
        if let info = r.project { await adopt(info, old: old) }
        if let p = r.plate { say("Moved \(name) to \(plateLabel(p))") }
        return r.plate
    }

    @discardableResult
    func addPlate() async -> Int {
        let i = await run { $0.addPlate() }
        await afterTransform()
        return i
    }

    func removePlate(_ p: Int) async {
        let ok = await run { $0.removePlate(p) }
        if ok { await afterTransform() }
    }

    func undo() async {
        let ok = await run { $0.undo() }
        if ok {
            await afterTransform()
            say("Undone")
        }
    }

    func rotate(axis: Int, degrees: Double) async {
        guard let o = selectedObject else { return }
        await rotate(object: o, axis: axis, degrees: degrees)
    }

    func rotate(object o: Int, axis: Int, degrees: Double) async {
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
        await autoFlat(object: o)
    }

    func autoFlat(object o: Int) async {
        await run { $0.autoFlat(object: o) }
        await afterTransform()
    }

    func resetObject() async {
        guard let o = selectedObject else { return }
        await resetObject(o)
    }

    func resetObject(_ o: Int) async {
        await run { $0.reset(object: o) }
        await afterTransform()
    }

    /// Move the plate's parts to the middle of the target printer's bed.
    func centerPlate() async {
        let p = plateIndex
        await run { $0.centerPlate(p) }
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

    // MARK: toolheads (tool changers)

    /// Toolhead currently assigned to a project filament (1-based), or nil when the engine picks.
    func tool(for filament: Int) -> Int? {
        let i = filament - 1
        if i < options.toolMap.count, options.toolMap[i] >= 0 { return options.toolMap[i] }
        if let m = plate?.toolMap, i < m.count, m[i] >= 0 { return m[i] }
        return nil
    }

    func setTool(_ head: Int, for filament: Int) {
        let n = project?.filaments.count ?? 0
        // pin every filament on the plate to its current head first, so swapping one doesn't shuffle the rest
        if options.toolMap.count < n { options.toolMap += Array(repeating: -1, count: n - options.toolMap.count) }
        for f in plate?.filaments ?? [] where f - 1 < options.toolMap.count && options.toolMap[f - 1] < 0 {
            options.toolMap[f - 1] = self.tool(for: f) ?? -1
        }
        // one filament per head (the filament that had this head takes the other one's old head),
        // unless the plate has more colours than heads: then colours may share a head
        let sharing = (plate?.filaments.count ?? 0) > target.tools
        let old = self.tool(for: filament)
        for f in plate?.filaments ?? [] where !sharing && f != filament && self.tool(for: f) == head {
            if f - 1 < options.toolMap.count { options.toolMap[f - 1] = old ?? -1 }
        }
        if filament - 1 < options.toolMap.count { options.toolMap[filament - 1] = head }
        toolMapIsCustom = true
        invalidateSlice()
    }

    /// Apply a suggested head for each filament on this plate (unless the user already chose).
    func applySuggestedToolMap(_ map: [Int: Int]) {
        guard !toolMapIsCustom, !map.isEmpty else { return }
        let n = project?.filaments.count ?? 0
        var tm = Array(repeating: -1, count: n)
        for (f, t) in map where f >= 1 && f <= n { tm[f - 1] = t }
        if tm != options.toolMap {
            options.toolMap = tm
            invalidateSlice()
        }
    }

    // MARK: slicing

    /// Plate pictures for the printer: Klipper printers show 48 and 300 px squares on their screen; Bambu printers
    /// show the plate picture in the .gcode.3mf (512 px).
    private func gcodeThumbnails() -> [Data] {
        guard let img = thumbnails[plateIndex] else { return [] }
        return (target.isToolChanger ? [48, 300] : [512]).map { side in
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            fmt.opaque = false
            let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt)
            return r.pngData { _ in
                let s = img.size
                let k = min(CGFloat(side) / max(1, s.width), CGFloat(side) / max(1, s.height))
                let w = s.width * k, h = s.height * k
                img.draw(in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
            }
        }
    }

    func sliceCurrent() async {
        guard !slicing else { return }
        slicing = true
        sliceProgress = 0
        slice = nil
        preview = nil
        await ensureEngineTarget()
        let plate = plateIndex
        let opts = options
        let thumbs = gcodeThumbnails()
        let summary: SliceSummary = await run { eng in
            eng.slice(plate: plate, options: opts, thumbnails: thumbs) { p in
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

    var jobName: String { "\(fileName) \(plate?.name ?? "")" }

    func exportProjectFile() async -> URL? {
        guard let data = await run({ $0.exportProject() }) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileName)-edited.3mf")
        try? FileManager.default.removeItem(at: url)
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    func exportSlicedFile() async -> URL? {
        guard let data = await slicedFile(), let s = slice else { return nil }
        let ext = s.isPlainGcode ? "gcode" : "gcode.3mf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileName)-plate\(s.plateId ?? 1).\(ext)")
        try? FileManager.default.removeItem(at: url)
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    /// Send the current slice to the selected printer.
    func sendCurrentSlice(to printer: PrinterLink, mapping: [Int: Int], options start: StartOptions) async throws {
        guard let s = slice, sliceIsCurrent else { throw SlicerEngine.EngineError.message("Slice this plate first.") }
        guard let data = await slicedFile() else { throw SlicerEngine.EngineError.message("The sliced file is missing. Slice again.") }
        try await printer.startPrint(file: data, summary: s, jobName: jobName, mapping: mapping, options: start)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
