import SwiftUI

enum Panel: String, CaseIterable, Identifiable {
    case plate = "Plate", settings = "Settings", preview = "Preview", print = "Print"
    var id: String { rawValue }
}

/// How the project screen is arranged for the space it has.
/// Folded iPhone (and Split View slivers): one column with a panel under the 3D view.
/// iPhone Duo unfolded, iPad portrait: 3D view and panels side by side, split at the middle so the fold falls on the divider.
/// Wide windows (iPad landscape, a large external display): a plates sidebar, the 3D view and the panels.
enum ProjectLayout: Equatable {
    case compact, split, threePane

    init(size: CGSize) {
        if size.width >= 1050 { self = .threePane }
        else if size.width >= 640 { self = .split }
        else { self = .compact }
    }
}

struct ProjectView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var printer: PrinterLink
    @State private var panel: Panel = .plate
    @State private var pickFace = false
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let layout = ProjectLayout(size: geo.size)
                Group {
                    switch layout {
                    case .compact: compact
                    case .split: split(geo.size)
                    case .threePane: threePane
                    }
                }
                .animation(.snappy, value: layout)
            }
            .navigationTitle(model.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { model.close() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await model.centerPlate() }
                        } label: { Label("Center plate on bed", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
                        Button {
                            Task { shareURL = await model.exportProjectFile() }
                        } label: { Label("Share edited 3MF", systemImage: "square.and.arrow.up") }
                        if model.sliceIsCurrent {
                            Button {
                                Task { shareURL = await model.exportSlicedFile() }
                            } label: { Label("Share sliced file", systemImage: "doc.zipper") }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { shareURL = $0?.url })) { item in
                ShareSheet(items: [item.url])
            }
            .onChange(of: model.slice?.ok) { _, ok in if ok == true { panel = .preview } }
            .onReceive(NotificationCenter.default.publisher(for: .duoDemoPanel)) { n in
                if let s = n.object as? String, let p = Panel(rawValue: s) { panel = p }
            }
            .background(PanelShortcuts(panel: $panel))
        }
    }

    // MARK: arrangements

    var compact: some View {
        VStack(spacing: 0) {
            PlateStrip()
            canvas
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            panelPicker
            panelContent
                .frame(height: 330)
        }
    }

    func split(_ size: CGSize) -> some View {
        // near-square (an unfolded iPhone Duo): split evenly so the fold sits on the divider
        let aspect = size.width / max(1, size.height)
        let left = (0.8...1.3).contains(aspect) ? size.width / 2 : max(size.width - 400, size.width * 0.5)
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                PlateStrip()
                canvas
            }
            .frame(width: left)
            Divider()
            inspector
        }
    }

    var threePane: some View {
        HStack(spacing: 0) {
            PlateSidebar()
                .frame(width: 250)
            Divider()
            canvas
            Divider()
            inspector
                .frame(width: 400)
        }
    }

    // MARK: pieces

    var canvas: some View {
        ZStack(alignment: .top) {
            if panel == .preview && model.sliceIsCurrent {
                LayerPreviewView()
            } else {
                PlateSceneView(bed: model.bed, mesh: model.mesh, revision: model.meshRevision, colors: model.options.colors, selected: model.selectedObject,
                               pickFace: pickFace,
                               onSelect: { obj in model.selectedObject = obj; if obj == nil { pickFace = false } },
                               onFace: { _, n in pickFace = false; Task { await model.layFlat(normal: n) } })
                    .ignoresSafeArea(edges: .horizontal)
                if model.selectedObject != nil { OrientBar(pickFace: $pickFace).padding(.top, 8) }
                if pickFace {
                    Text("Tap the face that should sit on the bed")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 60)
                }
            }
        }
    }

    var panelPicker: some View {
        Picker("Panel", selection: $panel) {
            ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder var panelContent: some View {
        switch panel {
        case .plate: PlatePanel()
        case .settings: SettingsPanel()
        case .preview: PreviewPanel()
        case .print: PrintPanel()
        }
    }

    var inspector: some View {
        VStack(spacing: 0) {
            panelPicker
            panelContent
                .frame(maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// ⌘1–⌘4 switch panels when a keyboard is attached.
struct PanelShortcuts: View {
    @Binding var panel: Panel

    var body: some View {
        ZStack {
            ForEach(Array(Panel.allCases.enumerated()), id: \.element) { i, p in
                Button(p.rawValue) { panel = p }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Plates as a vertical list (wide layouts).
struct PlateSidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.project?.plates ?? []) { p in
                    PlateCard(plate: p)
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemBackground))
    }
}

struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct PlateStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.project?.plates ?? []) { p in
                        PlateCard(plate: p).id(p.index)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: model.plateIndex) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
        }
    }
}

struct PlateCard: View {
    @EnvironmentObject var model: AppModel
    let plate: PlateInfo

    var body: some View {
        let p = plate
        Button {
            Task { await model.selectPlate(p.index) }
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let img = model.thumbnails[p.index] {
                        Image(uiImage: img).resizable().scaledToFit()
                    } else {
                        Image(systemName: "square.dashed").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 40, height: 40)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("Plate \(p.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        if p.offBed { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red) }
                        if p.filaments.count > colourLimit { Image(systemName: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange) }
                    }
                    Text(p.name).font(.caption).lineLimit(1).frame(maxWidth: 130, alignment: .leading)
                    HStack(spacing: 3) {
                        ForEach(p.filaments, id: \.self) { f in Circle().fill(model.color(of: f)).frame(width: 8, height: 8).overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 0.5)) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).fill(p.index == model.plateIndex ? Theme.accent.opacity(0.15) : Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.index == model.plateIndex ? Theme.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    /// AMS slots or toolheads available on the target printer.
    var colourLimit: Int { model.target.isToolChanger ? model.target.tools : 4 }
}

struct OrientBar: View {
    @EnvironmentObject var model: AppModel
    @Binding var pickFace: Bool

    var body: some View {
        HStack(spacing: 2) {
            button("X 90°", "rotate.3d") { await model.rotate(axis: 0, degrees: 90) }
            button("Y 90°", "rotate.3d") { await model.rotate(axis: 1, degrees: 90) }
            button("Z 90°", "rotate.right") { await model.rotate(axis: 2, degrees: 90) }
            button("Z 15°", "rotate.right") { await model.rotate(axis: 2, degrees: 15) }
            Divider().frame(height: 24)
            Button {
                pickFace.toggle()
            } label: {
                Label("Face down", systemImage: "square.bottomhalf.filled").labelStyle(.iconOnly)
                    .padding(8)
                    .background(pickFace ? Theme.accent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            button("Auto flat", "arrow.down.to.line") { await model.autoFlat() }
            button("Reset", "arrow.uturn.backward") { await model.resetObject() }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    func button(_ title: String, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.system(size: 9, weight: .medium))
            }
            .frame(minWidth: 40)
            .padding(.vertical, 4)
        }
    }
}

struct PlatePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let p = model.plate {
            List {
                Section {
                    HStack {
                        stat(footprint(p), "footprint")
                        stat(String(format: "%.1f mm", p.height), "height")
                        stat("\(p.filaments.count)", p.filaments.count == 1 ? "colour" : "colours")
                    }
                    if p.offBed {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(p.fitIssues ?? ["Part of this plate doesn't fit on the \(model.target.shortName)'s bed."], id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote).foregroundStyle(.red)
                            }
                            Button {
                                Task { await model.centerPlate() }
                            } label: {
                                Label("Center on the \(model.target.shortName)'s bed", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if !model.target.isToolChanger && p.filaments.count > 4 {
                        Label("This plate uses \(p.filaments.count) filaments; one AMS holds 4.", systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if model.target.isToolChanger && p.filaments.count > model.target.tools {
                        Label("This plate uses \(p.filaments.count) filaments and the \(model.target.shortName) has \(model.target.tools) heads.", systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section("Colours on this plate") {
                    ForEach(p.filaments, id: \.self) { f in FilamentRow(filament: f) }
                }
                Section {
                    ForEach(p.objects) { o in
                        Button {
                            model.selectedObject = model.selectedObject == o.index ? nil : o.index
                        } label: {
                            HStack {
                                HStack(spacing: 3) { ForEach(o.filaments, id: \.self) { f in Circle().fill(model.color(of: f)).frame(width: 9, height: 9) } }
                                Text(o.name).foregroundStyle(.primary).lineLimit(1)
                                Spacer()
                                if o.edited { Text("Moved").font(.caption2).foregroundStyle(Theme.accent) }
                                if o.offBed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                                if model.selectedObject == o.index { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                } header: {
                    Text("Objects")
                } footer: {
                    Text("Tap an object here or in the 3D view to rotate it.")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    func footprint(_ p: PlateInfo) -> String {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for o in p.objects where o.min.count >= 2 && o.max.count >= 2 {
            x0 = Swift.min(x0, o.min[0]); y0 = Swift.min(y0, o.min[1])
            x1 = Swift.max(x1, o.max[0]); y1 = Swift.max(y1, o.max[1])
        }
        guard x1 > x0, y1 > y0 else { return "—" }
        return "\(Int(x1 - x0))×\(Int(y1 - y0)) mm"
    }

    func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.subheadline.monospacedDigit().weight(.medium))
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FilamentRow: View {
    @EnvironmentObject var model: AppModel
    let filament: Int

    var body: some View {
        HStack {
            Text("F\(filament)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            ColorPicker("", selection: Binding(get: { model.color(of: filament) }, set: { model.setColor(filament, $0.hexString) }), supportsOpacity: false)
                .labelsHidden()
            Picker("Material", selection: Binding(get: { filament - 1 < model.options.filaments.count ? model.options.filaments[filament - 1] : "" },
                                                  set: { v in Task { await model.setFilamentPreset(filament, v) } })) {
                ForEach(model.project?.filamentPresets.sorted() ?? [], id: \.self) { Text(presetDisplayName($0)).tag($0) }
            }
            .labelsHidden()
        }
    }
}
