import SwiftUI

/// Top-down toolpath view of one sliced layer.
struct LayerPreviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let bed = model.bed
            let bw = CGFloat(bed.width), bd = CGFloat(bed.depth)
            let scale = min((geo.size.width - 16) / bw, (geo.size.height - 16) / bd)
            Canvas { ctx, size in
                let s = scale
                let w = bw * s, h = bd * s
                let ox = (size.width - w) / 2 - CGFloat(bed.x0) * s, oy = (size.height - h) / 2 + h + CGFloat(bed.y0) * s
                // printer (x, y) -> view (ox + x*s, oy - y*s)
                ctx.fill(Path(roundedRect: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h), cornerRadius: 6), with: .color(Theme.bed))
                var grid = Path()
                let step: CGFloat = 16
                var gx = (CGFloat(bed.x0) / step).rounded(.up) * step
                while gx <= CGFloat(bed.x1) {
                    grid.move(to: CGPoint(x: ox + gx * s, y: oy - CGFloat(bed.y0) * s)); grid.addLine(to: CGPoint(x: ox + gx * s, y: oy - CGFloat(bed.y1) * s))
                    gx += step
                }
                var gy = (CGFloat(bed.y0) / step).rounded(.up) * step
                while gy <= CGFloat(bed.y1) {
                    grid.move(to: CGPoint(x: ox + CGFloat(bed.x0) * s, y: oy - gy * s)); grid.addLine(to: CGPoint(x: ox + CGFloat(bed.x1) * s, y: oy - gy * s))
                    gy += step
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                if let ex = bed.excludeBox {
                    let r = CGRect(x: ox + CGFloat(ex.0) * s, y: oy - CGFloat(ex.3) * s, width: CGFloat(ex.2 - ex.0) * s, height: CGFloat(ex.3 - ex.1) * s)
                    ctx.fill(Path(r), with: .color(.black.opacity(0.35)))
                }
                guard let pv = model.preview else { return }
                // one path per (filament, role) for speed
                var paths: [UInt16: Path] = [:]
                let n = pv.meta.count
                pv.segments.withUnsafeBufferPointer { sp in
                    for i in 0..<n {
                        let key = pv.meta[i]
                        let x0 = ox + CGFloat(sp[i * 4]) * s, y0 = oy - CGFloat(sp[i * 4 + 1]) * s
                        let x1 = ox + CGFloat(sp[i * 4 + 2]) * s, y1 = oy - CGFloat(sp[i * 4 + 3]) * s
                        paths[key, default: Path()].move(to: CGPoint(x: x0, y: y0))
                        paths[key, default: Path()].addLine(to: CGPoint(x: x1, y: y1))
                    }
                }
                for (key, path) in paths {
                    let role = Int(key & 0xff), fil = Int(key >> 8)
                    var c = model.color(of: fil)
                    if role == 5 { c = c.opacity(0.75) }       // sparse infill
                    let w = max(0.6, 0.42 * s)
                    ctx.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: role <= 1 ? w * 1.05 : w, lineCap: .round))
                }
            }
        }
        .background(Color(.secondarySystemBackground))
    }
}

struct PreviewPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.slicing {
            VStack(spacing: 12) {
                ProgressView(value: model.sliceProgress)
                Text("Slicing plate \(model.plate?.id ?? 0)…").foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxHeight: .infinity)
        } else if model.sliceIsCurrent, let s = model.slice {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Layer \(model.previewLayer + 1) of \(model.layerCount)").font(.subheadline.weight(.medium))
                            Spacer()
                            Text(String(format: "Z %.2f mm", model.previewZ)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { Double(model.previewLayer) }, set: { v in
                            let l = Int(v.rounded())
                            if l != model.previewLayer { model.previewLayer = l; Task { await model.loadPreview() } }
                        }), in: 0...Double(max(1, model.layerCount - 1)), step: 1)
                    }
                }
                SliceSummaryView(summary: s)
            }
            .listStyle(.insetGrouped)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(.secondary)
                Text("Slice this plate to see its layers, print time and filament use.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                SliceButton()
            }
            .padding()
            .frame(maxHeight: .infinity)
        }
    }
}

struct SliceButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            Task { await model.sliceCurrent() }
        } label: {
            Label(model.slicing ? "Slicing…" : "Slice plate \(model.plate?.id ?? 0)", systemImage: "square.stack.3d.down.right")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.slicing || model.plate?.offBed == true)
        .keyboardShortcut("r", modifiers: .command)
    }
}

struct SliceSummaryView: View {
    @EnvironmentObject var model: AppModel
    let summary: SliceSummary

    var body: some View {
        Section("Sliced") {
            LabeledContent("Print time", value: formatDuration(summary.seconds ?? 0))
            LabeledContent("Filament", value: String(format: "%.1f g", summary.grams ?? 0))
            LabeledContent("Layers", value: "\(summary.layers ?? 0)")
            if let t = summary.toolChanges, t > 0 { LabeledContent("Colour changes", value: "\(t)") }
            LabeledContent("Build plate", value: bedTypeLabel(summary.bedType ?? ""))
            if let p = summary.printer { LabeledContent("Printer", value: p) }
            ForEach(summary.filaments ?? []) { f in
                HStack {
                    Circle().fill(Color(hex: f.color)).frame(width: 12, height: 12)
                    if let t = f.tool, summary.isPlainGcode {
                        Text("Head \(t + 1) · F\((f.projectFilaments ?? [f.id]).map(String.init).joined(separator: ", F")) · \(presetDisplayName(f.preset))").lineLimit(1)
                    } else {
                        Text("F\(f.id) · \(presetDisplayName(f.preset))").lineLimit(1)
                    }
                    Spacer()
                    Text(String(format: "%.1f g", f.grams)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            ForEach(summary.warnings ?? [], id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
    }
}
