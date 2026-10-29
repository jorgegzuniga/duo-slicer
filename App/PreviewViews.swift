import SwiftUI

/// Top-down toolpath view of one sliced layer.
struct LayerPreviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - 16
            Canvas { ctx, size in
                let s = side / 256
                let ox = (size.width - side) / 2, oy = (size.height - side) / 2
                ctx.fill(Path(roundedRect: CGRect(x: ox, y: oy, width: side, height: side), cornerRadius: 6), with: .color(Theme.bed))
                var grid = Path()
                for i in 0...16 {
                    let t = CGFloat(i) * 16 * s
                    grid.move(to: CGPoint(x: ox + t, y: oy)); grid.addLine(to: CGPoint(x: ox + t, y: oy + side))
                    grid.move(to: CGPoint(x: ox, y: oy + t)); grid.addLine(to: CGPoint(x: ox + side, y: oy + t))
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                guard let pv = model.preview else { return }
                // one path per (filament, role) for speed
                var paths: [UInt16: Path] = [:]
                let n = pv.meta.count
                pv.segments.withUnsafeBufferPointer { sp in
                    for i in 0..<n {
                        let key = pv.meta[i]
                        let x0 = ox + CGFloat(sp[i * 4]) * s, y0 = oy + side - CGFloat(sp[i * 4 + 1]) * s
                        let x1 = ox + CGFloat(sp[i * 4 + 2]) * s, y1 = oy + side - CGFloat(sp[i * 4 + 3]) * s
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
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.slicing || model.plate?.offBed == true)
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
            LabeledContent("Build plate", value: summary.bedType ?? "")
            ForEach(summary.filaments ?? []) { f in
                HStack {
                    Circle().fill(Color(hex: f.color)).frame(width: 12, height: 12)
                    Text("F\(f.id) · \(presetDisplayName(f.preset))").lineLimit(1)
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
