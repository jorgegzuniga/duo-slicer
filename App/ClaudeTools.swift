import Foundation
import UIKit

/// The tools Claude can call (the relay lists them; names and arguments must match relay/src/tools.js).
@MainActor
struct ClaudeTools {
    let bridge: ClaudeBridge
    let model: AppModel?
    let printer: PrinterLink?
    let queue: PrintQueue?

    typealias Result = [String: Any]

    func call(_ name: String, _ a: [String: Any]) async -> Result {
        guard let model, let printer else { return fail("Duo Slicer isn't ready yet. Try again in a moment.") }
        switch name {
        case "list_projects": return listProjects(model)
        case "open_project": return await openProject(model, a)
        case "get_project": return getProject(model, printer)
        case "select_plate": return await selectPlate(model, a)
        case "list_presets": return listPresets(model, a)
        case "set_settings": return await setSettings(model, a)
        case "rotate_object": return await transform(model, a, kind: "rotate")
        case "lay_flat": return await transform(model, a, kind: "flat")
        case "reset_object": return await transform(model, a, kind: "reset")
        case "center_plate": return await centerPlate(model, a)
        case "move_object": return await moveObject(model, a)
        case "arrange_plate": return await arrangePlate(model, a)
        case "move_to_plate": return await moveToPlate(model, a)
        case "set_toolheads": return await setToolheads(model, a)
        case "slice_plate": return await slicePlate(model, a)
        case "get_layer_preview": return await layerPreview(model, a)
        case "get_plate_image": return plateImage(model, a)
        case "list_printers": return listPrinters(model, printer)
        case "select_printer": return await selectPrinter(model, printer, a)
        case "get_printer_status": return printerStatus(printer, a)
        case "get_camera_image": return await cameraImage(printer, a)
        case "start_print": return await startPrint(model, printer, a)
        case "control_print": return await controlPrint(printer, a)
        case "get_queue": return queueStatus(printer)
        case "add_to_queue": return await addToQueue(model, printer, a)
        case "remove_from_queue": return removeFromQueue(a)
        case "start_queue": return await startQueue(printer)
        case "pause_queue": return pauseQueue()
        default: return fail("Unknown tool \(name).")
        }
    }

    // MARK: results

    func text(_ s: String) -> Result { ["content": [["type": "text", "text": s]]] }
    func fail(_ s: String) -> Result { ["content": [["type": "text", "text": s]], "isError": true] }
    func json(_ obj: [String: Any]) -> Result {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return text("\(obj)") }
        return text(String(decoding: d, as: UTF8.self))
    }
    func image(_ data: Data, mime: String = "image/png", _ caption: String) -> Result {
        ["content": [["type": "image", "data": data.base64EncodedString(), "mimeType": mime], ["type": "text", "text": caption]]]
    }

    func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    func dbl(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func needProject(_ model: AppModel) -> Result? {
        model.project == nil ? fail("No project is open. Call list_projects, then open_project.") : nil
    }

    /// Plate by the number shown in the app ("Plate 2" = 2); defaults to the current plate.
    func plateIndex(_ model: AppModel, _ v: Any?) -> Int? {
        guard let p = model.project else { return nil }
        guard let n = int(v) else { return model.plateIndex }
        if let i = p.plates.firstIndex(where: { $0.id == n }) { return i }
        return nil
    }

    // MARK: projects

    func listProjects(_ model: AppModel) -> Result {
        model.loadRecents()
        let names = model.recents.map { $0.deletingPathExtension().lastPathComponent }
        if names.isEmpty { return text("No projects yet. The user can open a .3mf in Duo Slicer (Files, Safari or MakerWorld share sheet).") }
        return json(["projects": names, "open": model.project == nil ? "" : model.fileName])
    }

    func openProject(_ model: AppModel, _ a: [String: Any]) async -> Result {
        let want = (a["name"] as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        model.loadRecents()
        guard let url = model.recents.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == want })
                ?? model.recents.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased().contains(want) }), !want.isEmpty else {
            return fail("No project called \"\(want)\". Projects: \(model.recents.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", "))")
        }
        await model.open(url: url)
        if let e = model.errorMessage { model.errorMessage = nil; return fail(e) }
        return getProject(model, printer!)
    }

    func getProject(_ model: AppModel, _ printer: PrinterLink) -> Result {
        if let r = needProject(model) { return r }
        let p = model.project!
        var plates: [[String: Any]] = []
        for pl in p.plates {
            plates.append([
                "plate": pl.id, "name": pl.name, "current": pl.index == model.plateIndex, "height_mm": (pl.height * 10).rounded() / 10,
                "filaments": pl.filaments, "fits": !pl.offBed, "problems": pl.fitIssues ?? [],
                "objects": pl.objects.map { o -> [String: Any] in
                    var size: [Double] = []
                    if o.min.count == 3, o.max.count == 3 { size = (0..<3).map { ((o.max[$0] - o.min[$0]) * 10).rounded() / 10 } }
                    return ["object": o.index, "name": o.name, "filaments": o.filaments, "moved": o.edited, "fits": !o.offBed, "size_mm": size]
                },
            ])
        }
        let fil = p.filaments.map { f -> [String: Any] in
            ["filament": f.index, "color": f.index - 1 < model.options.colors.count ? model.options.colors[f.index - 1] : f.color, "type": f.type,
             "preset": f.index - 1 < model.options.filaments.count ? model.options.filaments[f.index - 1] : f.preset]
        }
        var out: [String: Any] = [
            "project": model.fileName,
            "designed_for": p.printerModel,
            "slicing_for": model.target.name,
            "current_plate": model.plate?.id ?? 0,
            "plates": plates,
            "filaments": fil,
            "settings": settingsSummary(model),
        ]
        if model.target.isToolChanger, let pl = model.plate {
            out["toolheads"] = pl.filaments.map { ["filament": $0, "head": (model.tool(for: $0) ?? 0) + 1] }
        }
        if let s = model.slice, model.sliceIsCurrent { out["slice"] = sliceSummary(s) }
        return json(out)
    }

    func settingsSummary(_ model: AppModel) -> [String: Any] {
        var s: [String: Any] = ["process": model.options.process]
        for k in ["layer_height", "wall_loops", "top_shell_layers", "bottom_shell_layers", "sparse_infill_density", "sparse_infill_pattern",
                  "brim_type", "skirt_loops", "curr_bed_type"] {
            if let v = model.effective[k] { s[k] = v }
        }
        if !model.options.overrides.isEmpty { s["changed_from_preset"] = model.options.overrides }
        return s
    }

    func sliceSummary(_ s: SliceSummary) -> [String: Any] {
        var o: [String: Any] = ["plate": s.plateId ?? 0, "printer": s.printer ?? "", "time": formatDuration(s.seconds ?? 0),
                                "grams": ((s.grams ?? 0) * 10).rounded() / 10, "layers": s.layers ?? 0, "color_changes": s.toolChanges ?? 0,
                                "bed": s.bedType ?? "", "warnings": s.warnings ?? []]
        o["filaments"] = (s.filaments ?? []).map { f -> [String: Any] in
            var d: [String: Any] = ["filament": f.id, "type": f.type, "color": f.color, "grams": (f.grams * 10).rounded() / 10, "preset": f.preset]
            if s.isPlainGcode, let t = f.tool { d["head"] = t + 1 }
            return d
        }
        return o
    }

    func selectPlate(_ model: AppModel, _ a: [String: Any]) async -> Result {
        if let r = needProject(model) { return r }
        guard let i = plateIndex(model, a["plate"]) else { return fail("No such plate. Plates: \(model.project!.plates.map { String($0.id) }.joined(separator: ", "))") }
        await model.selectPlate(i)
        return text("Plate \(model.plate?.id ?? 0) (\(model.plate?.name ?? "")) is selected.")
    }

    // MARK: settings

    func listPresets(_ model: AppModel, _ a: [String: Any]) -> Result {
        if let r = needProject(model) { return r }
        let p = model.project!
        let kind = (a["kind"] as? String ?? "process").lowercased()
        if kind.hasPrefix("fil") {
            var list = p.filamentPresets.sorted()
            if let q = (a["search"] as? String)?.lowercased(), !q.isEmpty { list = list.filter { $0.lowercased().contains(q) } }
            return json(["filament_presets": list])
        }
        return json(["processes": p.processes.sorted(), "bed_types": p.printer?.bedTypes ?? []])
    }

    func setSettings(_ model: AppModel, _ a: [String: Any]) async -> Result {
        if let r = needProject(model) { return r }
        let p = model.project!
        var notes: [String] = []
        if let proc = a["process"] as? String, !proc.isEmpty {
            if let match = p.processes.first(where: { $0 == proc }) ?? p.processes.first(where: { $0.lowercased().contains(proc.lowercased()) }) {
                await model.setProcess(match)
                notes.append("Quality preset: \(match)")
            } else {
                return fail("No quality preset matches \"\(proc)\". Use list_presets.")
            }
        }
        if let bed = a["bed_type"] as? String, !bed.isEmpty {
            guard let match = (p.printer?.bedTypes ?? []).first(where: { $0.lowercased().contains(bed.lowercased()) }) else {
                return fail("The \(model.target.name) supports: \((p.printer?.bedTypes ?? []).joined(separator: ", ")).")
            }
            await model.setOverride("curr_bed_type", match)
            notes.append("Build plate: \(match)")
        }
        if let ov = a["overrides"] as? [String: Any] {
            for (k, v) in ov {
                if v is NSNull { await model.setOverride(k, nil); notes.append("\(k): preset value"); continue }
                let s = (v as? String) ?? "\(v)"
                await model.setOverride(k, s)
                notes.append("\(k) = \(s)")
            }
        }
        if let fp = a["filament_presets"] as? [String: Any] {
            for (k, v) in fp {
                guard let f = Int(k.filter(\.isNumber)), let want = v as? String else { continue }
                guard let match = p.filamentPresets.first(where: { $0 == want }) ?? p.filamentPresets.first(where: { $0.lowercased().contains(want.lowercased()) }) else {
                    return fail("No filament preset matches \"\(want)\". Use list_presets with kind filament.")
                }
                await model.setFilamentPreset(f, match)
                notes.append("F\(f): \(match)")
            }
        }
        if let cs = a["colors"] as? [String: Any] {
            for (k, v) in cs {
                guard let f = Int(k.filter(\.isNumber)), var hex = v as? String else { continue }
                if !hex.hasPrefix("#") { hex = "#" + hex }
                model.setColor(f, hex.uppercased())
                notes.append("F\(f) colour \(hex.uppercased())")
            }
        }
        await model.refreshEffective()
        return json(["changed": notes, "settings": settingsSummary(model), "note": "Slice again to apply."])
    }

    func objectIndex(_ model: AppModel, _ v: Any?) -> Int? {
        guard let p = model.project else { return nil }
        let all = p.plates.flatMap { $0.objects }
        if let n = int(v), all.contains(where: { $0.index == n }) { return n }
        if let s = (v as? String)?.lowercased(), !s.isEmpty {
            return (all.first { $0.name.lowercased() == s } ?? all.first { $0.name.lowercased().contains(s) })?.index
        }
        return nil
    }

    func transform(_ model: AppModel, _ a: [String: Any], kind: String) async -> Result {
        if let r = needProject(model) { return r }
        guard let o = objectIndex(model, a["object"]) else { return fail("No such object. get_project lists each plate's objects.") }
        if let pl = model.project?.plates.firstIndex(where: { $0.objects.contains { $0.index == o } }), pl != model.plateIndex { await model.selectPlate(pl) }
        switch kind {
        case "rotate":
            let axis = ["x": 0, "y": 1, "z": 2][(a["axis"] as? String ?? "z").lowercased()] ?? 2
            let deg = dbl(a["degrees"]) ?? 90
            await model.rotate(object: o, axis: axis, degrees: deg)
        case "flat": await model.autoFlat(object: o)
        default: await model.resetObject(o)
        }
        let obj = model.project?.plates.flatMap { $0.objects }.first { $0.index == o }
        var size: [Double] = []
        if let ob = obj, ob.min.count == 3, ob.max.count == 3 {
            size = (0..<3).map { ((ob.max[$0] - ob.min[$0]) * 10).rounded() / 10 }
        }
        return json(["object": o, "name": obj?.name ?? "", "fits": !(obj?.offBed ?? false), "size_mm": size])
    }

    func centerPlate(_ model: AppModel, _ a: [String: Any]) async -> Result {
        if let r = needProject(model) { return r }
        if let i = plateIndex(model, a["plate"]), i != model.plateIndex { await model.selectPlate(i) }
        await model.centerPlate()
        let pl = model.plate
        return json(["plate": pl?.id ?? 0, "fits": !(pl?.offBed ?? true), "problems": pl?.fitIssues ?? []])
    }

    /// Where an object sits now.
    func placement(_ model: AppModel, _ o: Int) -> [String: Any] {
        let obj = model.project?.plates.flatMap { $0.objects }.first { $0.index == o }
        let plate = model.project?.plates.first { $0.objects.contains { $0.index == o } }
        let c = obj?.center ?? (x: 0, y: 0)
        var size: [Double] = []
        if let ob = obj, ob.min.count == 3, ob.max.count == 3 { size = (0..<3).map { round1(ob.max[$0] - ob.min[$0]) } }
        var d: [String: Any] = ["object": o, "name": obj?.name ?? "", "plate": plate?.id ?? 0, "center_mm": [round1(c.x), round1(c.y)],
                                "size_mm": size, "fits": !(obj?.offBed ?? false)]
        if let f = obj?.fit, !f.isEmpty { d["problem"] = f }
        return d
    }

    func bedInfo(_ model: AppModel) -> [String: Any] {
        let b = model.bed
        return ["x_mm": [round1(b.x0), round1(b.x1)], "y_mm": [round1(b.y0), round1(b.y1)]]
    }

    func moveObject(_ model: AppModel, _ a: [String: Any]) async -> Result {
        if let r = needProject(model) { return r }
        guard let o = objectIndex(model, a["object"]) else { return fail("No such object. get_project lists each plate's objects.") }
        if let pl = model.project?.plates.firstIndex(where: { $0.objects.contains { $0.index == o } }), pl != model.plateIndex { await model.selectPlate(pl) }
        if let x = dbl(a["x"]), let y = dbl(a["y"]) {
            await model.place(object: o, x: x, y: y)
        } else if a["dx"] != nil || a["dy"] != nil {
            await model.move(object: o, dx: dbl(a["dx"]) ?? 0, dy: dbl(a["dy"]) ?? 0)
        } else {
            return fail("Give x and y (where the middle of the object goes on the bed, mm) or dx and dy (how far to move it, mm).")
        }
        var out = placement(model, o)
        out["bed"] = bedInfo(model)
        return json(out)
    }

    func arrangePlate(_ model: AppModel, _ a: [String: Any]) async -> Result {
        if let r = needProject(model) { return r }
        guard let i = plateIndex(model, a["plate"]) else { return fail("No such plate. Plates: \(model.project!.plates.map { String($0.id) }.joined(separator: ", "))") }
        if i != model.plateIndex { await model.selectPlate(i) }
        let left = await model.arrangePlate(i, allowRotation: (a["allow_rotation"] as? Bool) ?? false)
        if let e = model.errorMessage { model.errorMessage = nil; return fail(e) }
        let objects = model.project?.plates[safe: i]?.objects ?? []
        return json(["plate": model.project?.plates[safe: i]?.id ?? 0, "arranged": objects.count - left.count, "did_not_fit": left,
                     "objects": objects.map { placement(model, $0.index) }, "bed": bedInfo(model)])
    }

    func moveToPlate(_ model: AppModel, _ a: [String: Any]) async -> Result {
        if let r = needProject(model) { return r }
        guard let o = objectIndex(model, a["object"]) else { return fail("No such object. get_project lists each plate's objects.") }
        var target: Int?
        if let n = int(a["plate"]), n > 0 {
            guard let i = model.project?.plates.firstIndex(where: { $0.id == n }) else { return fail("There's no plate \(n). Leave plate out to put it on a new plate.") }
            target = i
        }
        guard let to = await model.moveObject(o, toPlate: target) else {
            let e = model.errorMessage ?? "Couldn't move it."
            model.errorMessage = nil
            return fail(e)
        }
        await model.selectPlate(to)
        var out = placement(model, o)
        out["plates"] = model.project?.plates.count ?? 0
        return json(out)
    }

    func setToolheads(_ model: AppModel, _ a: [String: Any]) async -> Result {
        if let r = needProject(model) { return r }
        guard model.target.isToolChanger else { return fail("The \(model.target.name) uses an AMS; spools are picked when printing (start_print's spools).") }
        guard let list = a["assignments"] as? [[String: Any]] else { return fail("Pass assignments: [{filament, head}].") }
        for item in list {
            guard let f = int(item["filament"]), let h = int(item["head"]), h >= 1, h <= model.target.tools else { continue }
            model.setTool(h - 1, for: f)
        }
        let pl = model.plate
        return json(["toolheads": (pl?.filaments ?? []).map { ["filament": $0, "head": (model.tool(for: $0) ?? 0) + 1] }, "note": "Slice again to apply."])
    }

    // MARK: slicing

    func slicePlate(_ model: AppModel, _ a: [String: Any]) async -> Result {
        if let r = needProject(model) { return r }
        if let i = plateIndex(model, a["plate"]), i != model.plateIndex { await model.selectPlate(i) }
        if model.slicing { return fail("A slice is already running.") }
        await model.sliceCurrent()
        if let e = model.errorMessage, !model.sliceIsCurrent {
            model.errorMessage = nil
            return fail(e)
        }
        guard let s = model.slice else { return fail("Slicing didn't finish.") }
        return json(sliceSummary(s))
    }

    func layerPreview(_ model: AppModel, _ a: [String: Any]) async -> Result {
        guard model.sliceIsCurrent else { return fail("Slice the plate first (slice_plate).") }
        var layer = model.layerCount - 1
        if let l = int(a["layer"]) { layer = max(1, min(model.layerCount, l)) - 1 }
        model.previewLayer = layer
        await model.loadPreview()
        guard let pv = model.preview else { return fail("No preview.") }
        let png = LayerImage.render(pv, bed: model.bed, colors: model.options.colors, side: 768)
        return image(png, String(format: "Layer %d of %d at Z %.2f mm on the %@ (bed outline shown; colours are the project's filaments).",
                                 layer + 1, model.layerCount, model.previewZ, model.target.name))
    }

    func plateImage(_ model: AppModel, _ a: [String: Any]) -> Result {
        if let r = needProject(model) { return r }
        guard let i = plateIndex(model, a["plate"]) else { return fail("No such plate.") }
        guard let img = model.thumbnails[i], let png = img.pngData() else { return fail("This project has no picture for that plate.") }
        return image(png, "Plate \(model.project!.plates[i].id) as saved by the designer.")
    }

    // MARK: printers

    /// A saved printer by name (or model), or the selected one when no name is given.
    func connection(_ printer: PrinterLink, _ v: Any?) -> PrinterConnection? {
        let want = (v as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if want.isEmpty { return printer.activeConnection }
        let all = printer.all
        return all.first { $0.printer.name.lowercased() == want }
            ?? all.first { $0.printer.name.lowercased().contains(want) }
            ?? all.first { c in
                guard let m = c.printer.model else { return false }
                return m.shortName.lowercased() == want || m.name.lowercased().contains(want)
            }
    }

    func noPrinter(_ printer: PrinterLink, _ v: Any?) -> String {
        if printer.printers.isEmpty { return "No printer is set up in Duo Slicer." }
        return "No printer matches \"\(v as? String ?? "")\". Printers: \(printer.printers.map(\.name).joined(separator: ", "))."
    }

    /// One printer's live state.
    func status(of c: PrinterConnection, _ printer: PrinterLink) -> [String: Any] {
        var o: [String: Any] = ["printer": c.printer.name, "model": c.model?.name ?? "", "address": c.printer.hostOnly,
                                "selected": c.id == printer.activeID, "connected": c.connected, "status": c.statusText,
                                "state": c.state, "summary": PrinterCard.describe(c),
                                "nozzle_c": Int(c.nozzle), "bed_c": Int(c.bed), "has_camera": c.model?.cameraKinds.isEmpty == false]
        if c.isBusy {
            o["percent"] = c.percent
            o["remaining_minutes"] = c.remainingMinutes
            o["layer"] = c.layer
            o["total_layers"] = c.totalLayers
            o["job"] = c.jobName
        }
        if let e = c.errorText { o["error"] = e }
        if let q = queue {
            if let j = q.activeJob(on: c.id) { o["queue_print"] = j.title }
            if q.running && q.needsBedCheck(c) { o["waiting_for_bed_check"] = true }
        }
        return o
    }

    func listPrinters(_ model: AppModel, _ printer: PrinterLink) -> Result {
        json(["printers": printer.all.map { status(of: $0, printer) },
              "slicing_for": model.target.name,
              "supported_models": PrinterCatalog.models.map(\.name)])
    }

    func selectPrinter(_ model: AppModel, _ printer: PrinterLink, _ a: [String: Any]) async -> Result {
        let want = (a["printer"] as? String ?? "").lowercased()
        if !want.isEmpty, let c = connection(printer, want) {
            printer.select(c.id)
            await model.setTarget(c.printer.modelID)
            return text("Selected \(c.printer.name) (\(c.model?.name ?? "")). Plates are now sliced for it.")
        }
        if printer.printers.isEmpty, let m = PrinterCatalog.models.first(where: { $0.name.lowercased().contains(want) || $0.id == want }), !want.isEmpty {
            await model.setTarget(m.id)
            return text("Slicing for the \(m.name). No printer is saved in the app, so the file can be shared but not sent.")
        }
        return fail(noPrinter(printer, a["printer"]))
    }

    func printerStatus(_ printer: PrinterLink, _ a: [String: Any]) -> Result {
        guard let c = connection(printer, a["printer"]) else {
            return printer.printers.isEmpty ? text("No printer is set up in Duo Slicer.") : fail(noPrinter(printer, a["printer"]))
        }
        var o = status(of: c, printer)
        if !c.trays.isEmpty {
            o["spools"] = c.trays.map { t -> [String: Any] in ["slot": t.label, "id": t.id, "loaded": t.loaded, "type": t.type, "color": t.color, "name": t.name] }
        }
        if !c.toolheads.isEmpty {
            o["heads"] = c.toolheads.map { h -> [String: Any] in ["head": h.id + 1, "loaded": h.loaded, "filament": h.summary, "color": h.color, "temp_c": Int(h.temperature)] }
        }
        if printer.printers.count > 1 { o["other_printers"] = printer.all.filter { $0.id != c.id }.map { "\($0.printer.name): \(PrinterCard.describe($0))" } }
        return json(o)
    }

    /// A fresh picture from a printer's camera.
    func cameraImage(_ printer: PrinterLink, _ a: [String: Any]) async -> Result {
        guard let c = connection(printer, a["printer"]) else { return fail(noPrinter(printer, a["printer"])) }
        guard c.model?.cameraKinds.isEmpty == false, let cam = printer.camera(for: c.id) else {
            return fail("Duo Slicer can't show the \(c.printer.name)'s camera.")
        }
        guard let img = await cam.snapshot(timeout: 15) else {
            return fail("The \(c.printer.name)'s camera didn't send a picture (\(cam.status))")
        }
        guard let jpeg = Self.jpeg(img, maxSide: 1280) else { return fail("Couldn't encode the camera picture.") }
        let time = Date().formatted(date: .omitted, time: .shortened)
        return image(jpeg, mime: "image/jpeg", "\(c.printer.name)'s camera at \(time). \(PrinterCard.describe(c)).")
    }

    static func jpeg(_ img: UIImage, maxSide: CGFloat) -> Data? {
        let s = img.size
        let k = min(1, maxSide / max(1, max(s.width, s.height)))
        if k >= 1 { return img.jpegData(compressionQuality: 0.75) }
        let size = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).jpegData(withCompressionQuality: 0.75) { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func startPrint(_ model: AppModel, _ printer: PrinterLink, _ a: [String: Any]) async -> Result {
        if let r = needProject(model) { return r }
        if let name = a["printer"] as? String, !name.isEmpty {
            // print on another saved printer: select it (plates are then sliced for it)
            guard let c = connection(printer, name) else { return fail(noPrinter(printer, name)) }
            if c.id != printer.activeID { printer.select(c.id) }
        }
        guard let p = printer.active, let pm = p.model else { return fail("No printer is set up in Duo Slicer.") }
        if let i = plateIndex(model, a["plate"]), i != model.plateIndex { await model.selectPlate(i) }
        if pm.id != model.target.id { await model.setTarget(pm.id) }
        if !model.sliceIsCurrent {
            await model.sliceCurrent()
            if !model.sliceIsCurrent { let e = model.errorMessage ?? "Slicing failed."; model.errorMessage = nil; return fail(e) }
        }
        guard printer.connected else { return fail("The \(pm.shortName) isn't connected (\(printer.statusText)).") }
        guard !printer.isBusy else { return fail("The \(pm.shortName) is busy (\(printer.state)).") }
        let s = model.slice!
        var mapping = printer.suggestMapping(for: s.filaments ?? [])
        if let sp = a["spools"] as? [[String: Any]] {
            for item in sp { if let f = int(item["filament"]), let slot = int(item["slot"]) { mapping[f] = slot } }
        }
        var detail = "Plate \(s.plateId ?? 0) of \(model.fileName) · \(formatDuration(s.seconds ?? 0)) · \(String(format: "%.0f g", s.grams ?? 0)). "
        if pm.isBambu {
            let names = (s.filaments ?? []).map { f -> String in
                let slot = mapping[f.id] ?? 254
                return "F\(f.id) → " + (printer.trays.first { $0.id == slot }?.label ?? "external spool")
            }
            detail += names.joined(separator: ", ") + ". "
        }
        detail += "Make sure the bed is clear and the \(bedTypeLabel(s.bedType ?? "")) plate is on."
        let ok = await bridge.requestApproval(title: "Claude wants to print on \(p.name)", detail: detail, confirm: "Start print")
        guard ok else { return fail("The user didn't approve the print on their phone.") }
        do {
            try await model.sendCurrentSlice(to: printer, mapping: mapping, options: StartOptions())
            bridge.note("Started plate \(s.plateId ?? 0) on \(p.name)")
            return text("Started. \(printer.lastResult ?? "") Use get_printer_status to follow it.")
        } catch {
            return fail(error.localizedDescription)
        }
    }

    // MARK: queue

    func queueStatus(_ printer: PrinterLink) -> Result {
        guard let queue else { return fail("The print queue isn't ready yet.") }
        let jobs = queue.jobs.map { j -> [String: Any] in
            var d: [String: Any] = ["job": j.shortID, "project": j.project, "plate": j.plateNumber, "plate_name": j.plateLabel, "status": j.status.rawValue]
            if let pid = j.printerID {
                d["printer"] = printer.connection(pid)?.printer.name ?? "(removed)"
            } else {
                d["printer"] = "any " + (PrinterCatalog.model(j.modelID)?.shortName ?? j.modelID)
            }
            if let p = j.printedOn { d["printed_on"] = printer.connection(p)?.printer.name ?? "" }
            if let m = j.message { d["message"] = m }
            if let s = j.seconds { d["time"] = formatDuration(s) }
            if let g = j.grams { d["grams"] = round1(g) }
            return d
        }
        let printers = printer.all.filter { queue.activeJob(on: $0.id) != nil || queue.next(for: $0) != nil }.map { c -> [String: Any] in
            ["printer": c.printer.name, "state": PrinterCard.describe(c), "waiting_for_bed_check": queue.needsBedCheck(c), "next_job": queue.next(for: c)?.shortID ?? ""]
        }
        return json(["running": queue.running, "jobs": jobs, "printers": printers,
                     "note": "A printer takes its next print only after the user says its bed is clear (start_queue asks on the phone)."])
    }

    func addToQueue(_ model: AppModel, _ printer: PrinterLink, _ a: [String: Any]) async -> Result {
        guard let queue else { return fail("The print queue isn't ready yet.") }
        if let r = needProject(model) { return r }
        let info = model.project!
        var indices: [Int] = []
        if (a["all_plates"] as? Bool) == true {
            indices = info.plates.filter { !$0.isEmpty }.map(\.index)
        } else if let list = a["plates"] as? [Any], !list.isEmpty {
            for v in list {
                guard let n = int(v), let i = info.plates.firstIndex(where: { $0.id == n }) else {
                    return fail("There's no plate \(v). Plates: \(info.plates.map { String($0.id) }.joined(separator: ", ")).")
                }
                indices.append(i)
            }
        } else {
            indices = [model.plateIndex]
        }
        indices = indices.filter { !info.plates[$0].isEmpty }
        guard !indices.isEmpty else { return fail("Those plates are empty.") }
        let copies = max(1, min(50, int(a["copies"]) ?? 1))
        var printerID: String?
        if let name = a["printer"] as? String, !name.isEmpty {
            guard let c = connection(printer, name) else { return fail(noPrinter(printer, name)) }
            guard c.printer.modelID == model.target.id else {
                return fail("The \(c.printer.name) is a \(c.model?.shortName ?? "different model") and the project is set up for the \(model.target.name). Call select_printer with it first.")
            }
            printerID = c.id
        }
        guard let data = await model.exportProjectData() else { return fail("Couldn't save a copy of the project for the queue.") }
        let plates = indices.map { i in QueuePlate(index: i, number: info.plates[i].id, name: info.plates[i].name, picture: model.thumbnails[i]) }
        let n = queue.add(project: model.fileName, data: data, plates: plates, copies: copies, modelID: model.target.id, printerID: printerID,
                          options: model.options, currentPlate: model.plateIndex, start: StartOptions())
        guard n > 0 else { return fail("Couldn't add those prints to the queue.") }
        bridge.note("Queued \(n) print\(n == 1 ? "" : "s")")
        return json(["added": n, "running": queue.running, "waiting": queue.waiting.count,
                     "note": queue.running ? "The queue is running; free printers with a clear bed take these next."
                                           : "The queue isn't running. start_queue starts it after the user confirms the beds are clear on the phone."])
    }

    func removeFromQueue(_ a: [String: Any]) -> Result {
        guard let queue else { return fail("The print queue isn't ready yet.") }
        let want = (a["job"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard let j = queue.find(want) else { return fail("No job \"\(want)\" in the queue. get_queue lists them.") }
        guard j.status != .slicing && j.status != .sending else { return fail("That print is being sent to its printer right now.") }
        queue.remove([j.id])
        return text("Removed \(j.title) from the queue." + (j.status == .printing ? " It keeps printing; the queue just stops following it." : ""))
    }

    func startQueue(_ printer: PrinterLink) async -> Result {
        guard let queue else { return fail("The print queue isn't ready yet.") }
        guard !queue.waiting.isEmpty else { return fail("Nothing is waiting in the queue. add_to_queue adds prints.") }
        let check = printer.all.filter { queue.needsBedCheck($0) }
        if check.isEmpty {
            queue.start(clear: [])
            return text("The queue is running. No printer that can take these prints is free right now; each starts its next print once it's free and the user says its bed is clear.")
        }
        let lines = check.map { "\($0.printer.name): \(queue.next(for: $0)?.title ?? "")" }
        let ok = await bridge.requestApproval(title: "Claude wants to start the print queue",
                                              detail: lines.joined(separator: "\n") + "\n\nOnly start if each bed is clear and has the right build plate on.",
                                              confirm: check.count == 1 ? "The bed is clear, start" : "The beds are clear, start")
        guard ok else { return fail("The user didn't confirm on their phone that the beds are clear.") }
        queue.start(clear: check.map { $0.id })
        bridge.note("Started the print queue")
        return text("Started. Next prints: " + lines.joined(separator: "; ") + ". get_queue follows them.")
    }

    func pauseQueue() -> Result {
        guard let queue else { return fail("The print queue isn't ready yet.") }
        queue.pause()
        return text("The queue is paused. Prints already sent keep printing.")
    }

    func controlPrint(_ printer: PrinterLink, _ a: [String: Any]) async -> Result {
        let action = (a["action"] as? String ?? "").lowercased()
        guard ["pause", "resume", "stop"].contains(action) else { return fail("action must be pause, resume or stop.") }
        guard let c = connection(printer, a["printer"]), c.connected else { return fail("No printer is connected.") }
        let p = c.printer
        if action == "stop" {
            let ok = await bridge.requestApproval(title: "Claude wants to stop the print on \(p.name)", detail: "\(c.jobName) · \(c.percent)%. A stopped print can't be resumed.",
                                                  confirm: "Stop print", destructive: true)
            guard ok else { return fail("The user didn't approve stopping the print.") }
        }
        do {
            try await c.control(action)
            return text("Sent \(action) to \(p.name).")
        } catch {
            return fail(error.localizedDescription)
        }
    }
}

/// Top-down picture of one sliced layer (for Claude).
enum LayerImage {
    static func render(_ pv: SlicerEngine.LayerPreview, bed: PrinterModel.Bed, colors: [String], side: CGFloat) -> Data {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt)
        return r.pngData { ctx in
            let g = ctx.cgContext
            UIColor(white: 0.12, alpha: 1).setFill()
            g.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let pad: CGFloat = 16
            let s = (side - 2 * pad) / CGFloat(max(bed.width, bed.depth))
            let ox = pad + ((side - 2 * pad) - CGFloat(bed.width) * s) / 2 - CGFloat(bed.x0) * s
            let oy = side - pad - ((side - 2 * pad) - CGFloat(bed.depth) * s) / 2 + CGFloat(bed.y0) * s
            UIColor(red: 0.23, green: 0.25, blue: 0.27, alpha: 1).setFill()
            g.fill(CGRect(x: ox + CGFloat(bed.x0) * s, y: oy - CGFloat(bed.y1) * s, width: CGFloat(bed.width) * s, height: CGFloat(bed.depth) * s))
            g.setLineCap(.round)
            g.setLineWidth(max(1, 0.42 * s))
            var byFil: [Int: [Int]] = [:]
            for i in 0..<pv.meta.count { byFil[Int(pv.meta[i] >> 8), default: []].append(i) }
            for (f, idx) in byFil {
                let hex = f >= 1 && f - 1 < colors.count ? colors[f - 1] : "#999999"
                g.setStrokeColor(UIColor(hex: hex).cgColor)
                g.beginPath()
                for i in idx {
                    g.move(to: CGPoint(x: ox + CGFloat(pv.segments[i * 4]) * s, y: oy - CGFloat(pv.segments[i * 4 + 1]) * s))
                    g.addLine(to: CGPoint(x: ox + CGFloat(pv.segments[i * 4 + 2]) * s, y: oy - CGFloat(pv.segments[i * 4 + 3]) * s))
                }
                g.strokePath()
            }
        }
    }
}
