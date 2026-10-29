import Foundation
import UIKit

/// The tools Claude can call (the relay lists them; names and arguments must match relay/src/tools.js).
@MainActor
struct ClaudeTools {
    let bridge: ClaudeBridge
    let model: AppModel?
    let printer: PrinterLink?

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
        case "set_toolheads": return await setToolheads(model, a)
        case "slice_plate": return await slicePlate(model, a)
        case "get_layer_preview": return await layerPreview(model, a)
        case "get_plate_image": return plateImage(model, a)
        case "list_printers": return listPrinters(model, printer)
        case "select_printer": return await selectPrinter(model, printer, a)
        case "get_printer_status": return printerStatus(printer)
        case "start_print": return await startPrint(model, printer, a)
        case "control_print": return await controlPrint(printer, a)
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
    func image(_ png: Data, _ caption: String) -> Result {
        ["content": [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"], ["type": "text", "text": caption]]]
    }

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

    func listPrinters(_ model: AppModel, _ printer: PrinterLink) -> Result {
        json(["printers": printer.printers.map { p -> [String: Any] in
                  ["name": p.name, "model": p.model?.name ?? p.modelID, "selected": p.id == printer.activeID, "address": p.hostOnly]
              },
              "slicing_for": model.target.name,
              "supported_models": PrinterCatalog.models.map(\.name)])
    }

    func selectPrinter(_ model: AppModel, _ printer: PrinterLink, _ a: [String: Any]) async -> Result {
        let want = (a["printer"] as? String ?? "").lowercased()
        if let p = printer.printers.first(where: { $0.name.lowercased() == want }) ?? printer.printers.first(where: { $0.name.lowercased().contains(want) || ($0.model?.name.lowercased().contains(want) ?? false) }), !want.isEmpty {
            printer.select(p.id)
            await model.setTarget(p.modelID)
            return text("Selected \(p.name) (\(p.model?.name ?? "")). Plates are now sliced for it.")
        }
        if printer.printers.isEmpty, let m = PrinterCatalog.models.first(where: { $0.name.lowercased().contains(want) || $0.id == want }), !want.isEmpty {
            await model.setTarget(m.id)
            return text("Slicing for the \(m.name). No printer is saved in the app, so the file can be shared but not sent.")
        }
        return fail("No printer matches \"\(want)\". Saved: \(printer.printers.map(\.name).joined(separator: ", ")).")
    }

    func printerStatus(_ printer: PrinterLink) -> Result {
        guard let p = printer.active else { return text("No printer is set up in Duo Slicer.") }
        var o: [String: Any] = ["printer": p.name, "model": p.model?.name ?? "", "connected": printer.connected, "status": printer.statusText,
                                "state": printer.state, "percent": printer.percent, "remaining_minutes": printer.remainingMinutes,
                                "layer": printer.layer, "total_layers": printer.totalLayers, "nozzle_c": Int(printer.nozzle), "bed_c": Int(printer.bed),
                                "job": printer.jobName]
        if let e = printer.errorText { o["error"] = e }
        if !printer.trays.isEmpty {
            o["spools"] = printer.trays.map { t -> [String: Any] in ["slot": t.label, "id": t.id, "loaded": t.loaded, "type": t.type, "color": t.color, "name": t.name] }
        }
        if !printer.toolheads.isEmpty {
            o["heads"] = printer.toolheads.map { h -> [String: Any] in ["head": h.id + 1, "loaded": h.loaded, "filament": h.summary, "color": h.color, "temp_c": Int(h.temperature)] }
        }
        return json(o)
    }

    func startPrint(_ model: AppModel, _ printer: PrinterLink, _ a: [String: Any]) async -> Result {
        if let r = needProject(model) { return r }
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

    func controlPrint(_ printer: PrinterLink, _ a: [String: Any]) async -> Result {
        let action = (a["action"] as? String ?? "").lowercased()
        guard ["pause", "resume", "stop"].contains(action) else { return fail("action must be pause, resume or stop.") }
        guard let p = printer.active, printer.connected else { return fail("No printer is connected.") }
        if action == "stop" {
            let ok = await bridge.requestApproval(title: "Claude wants to stop the print on \(p.name)", detail: "\(printer.jobName) · \(printer.percent)%. A stopped print can't be resumed.",
                                                  confirm: "Stop print", destructive: true)
            guard ok else { return fail("The user didn't approve stopping the print.") }
        }
        do {
            try await printer.control(action)
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
