import SwiftUI

enum Panel: String, CaseIterable, Identifiable {
    case plate = "Plate", settings = "Settings", preview = "Preview", print = "Print"
    var id: String { rawValue }
}

/// How the project screen is arranged for the space it has.
/// - iPhone Duo unfolded: the two halves of the screen, split exactly at the crease. Held wide, the 3D view is on the
///   left half and the panels on the right; held tall (or half-folded like a laptop), the 3D view is on top and the panels below.
/// - Folded iPhone and Split View: one column with a panel under the 3D view.
/// - iPad and other large windows: 3D view and panels side by side; very wide windows add a plates sidebar.
enum ProjectLayout: Equatable {
    case compact
    case split(left: CGFloat, gap: CGFloat)   // 3D view | panels; gap = the crease
    case stacked(top: CGFloat, gap: CGFloat)  // 3D view over panels around a horizontal crease
    case threePane

    init(size: CGSize, fold: CGRect?) {
        if let f = fold {
            let runsDown = f.height >= size.height * 0.8 && f.width < size.width * 0.3
            let runsAcross = f.width >= size.width * 0.8 && f.height < size.height * 0.3
            if runsDown && f.minX >= 260 && size.width - f.maxX >= 260 { self = .split(left: f.minX, gap: f.width); return }
            if runsAcross && f.minY >= 220 && size.height - f.maxY >= 220 { self = .stacked(top: f.minY, gap: f.height); return }
        }
        if size.width >= 1050 {
            self = .threePane
        } else if size.width >= 640 {
            let aspect = size.width / max(1, size.height)
            self = .split(left: (0.8...1.3).contains(aspect) ? size.width / 2 : max(size.width - 400, size.width * 0.5), gap: 0)
        } else {
            self = .compact
        }
    }
}

struct ProjectView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var printer: PrinterLink
    @State private var panel: Panel = .plate
    @State private var pickFace = false
    @State private var shareURL: URL?
    @State private var fold: CGRect?
    @State private var sheet: PrintSheet?

    /// A crease running top to bottom (the unfolded iPhone Duo held wide): the navigation bar's centred title would sit on it,
    /// so each half gets its own header instead. Depends only on the fold, not on the layout, so hiding the bar can't flip it.
    private var paneHeaders: Bool { fold.map { $0.height > $0.width } ?? false }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let layout = ProjectLayout(size: geo.size, fold: fold)
                Group {
                    switch layout {
                    case .compact: compact(geo.size)
                    case .split(let left, let gap): split(left: left, gap: gap)
                    case .stacked(let top, let gap): stacked(top: top, gap: gap)
                    case .threePane: threePane
                    }
                }
                .animation(.snappy, value: layout)
                .overlay {
                    if DemoMode.showFold { FoldDebugOverlay(fold: fold, size: geo.size) }
                }
            }
            .sheet(item: $sheet) { s in PrintSheetContent(sheet: s) }
            .onReceive(NotificationCenter.default.publisher(for: .duoDemoSheet)) { n in
                if let s = (n.object as? String).flatMap(PrintSheet.init(rawValue:)) { sheet = s }
            }
            .background(FoldReader(fold: $fold))
            .navigationTitle(model.fileName)
            .navigationBarTitleDisplayMode(.inline)
            // unfolded iPhone Duo held wide: the bar's centred title would sit on the crease
            .toolbar(paneHeaders ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { model.close() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    moreMenu
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

    /// One column. The panel takes less room on short screens (the iPhone Duo's outer screen) so the 3D view stays usable.
    func compact(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            if paneHeaders { fullHeader }
            PlateStrip()
            canvas
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            panelPicker
            panelContent
                .frame(height: max(220, min(330, size.height * 0.42)))
        }
    }

    func split(left: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if paneHeaders { leftHeader }
                PlateStrip()
                canvas
            }
            .frame(width: left)
            if gap > 0 { FoldGap(vertical: true).frame(width: gap).ignoresSafeArea(edges: .bottom) } else { Divider() }
            inspector(menu: paneHeaders)
        }
    }

    /// Close, the project name and the ⋯ menu across the top, when the navigation bar is hidden but the layout isn't split.
    var fullHeader: some View {
        HStack(spacing: 12) {
            leftHeader
            moreMenu
                .font(.title2)
                .padding(.trailing)
        }
    }

    /// Close and the project name, on the left half when the navigation bar is hidden.
    var leftHeader: some View {
        HStack(spacing: 12) {
            Button("Close") { model.close() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            Text(model.fileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    var moreMenu: some View {
        Menu {
            Button {
                Task { await model.arrangePlate() }
            } label: { Label("Arrange plate", systemImage: "square.grid.3x3.square") }
            .disabled(model.plate?.isEmpty ?? true)
            Button {
                Task { await model.centerPlate() }
            } label: { Label("Center plate on bed", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
            Button {
                Task { let i = await model.addPlate(); await model.selectPlate(i) }
            } label: { Label("New plate", systemImage: "plus.rectangle.on.rectangle") }
            if model.canUndo {
                Button {
                    Task { await model.undo() }
                } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            }
            Button {
                Task { shareURL = await model.exportProjectFile() }
            } label: { Label("Share edited 3MF", systemImage: "square.and.arrow.up") }
            if model.sliceIsCurrent {
                Button {
                    Task { shareURL = await model.exportSlicedFile() }
                } label: { Label("Share sliced file", systemImage: "doc.zipper") }
            }
            Divider()
            Button {
                sheet = .addToQueue
            } label: { Label("Add to print queue", systemImage: "text.badge.plus") }
            .disabled(model.plate?.isEmpty ?? true)
            Button {
                sheet = .queue
            } label: { Label("Print queue", systemImage: "list.number") }
            Button {
                sheet = .printers
            } label: { Label("Printers", systemImage: "printer") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("More")
        }
    }

    /// Unfolded iPhone Duo held tall, or half-folded on a table: 3D view on the top half, panels on the bottom half.
    func stacked(top: CGFloat, gap: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                PlateStrip()
                canvas
            }
            .frame(height: top)
            FoldGap(vertical: false).frame(height: gap)
            inspector()
        }
    }

    var threePane: some View {
        VStack(spacing: 0) {
            if paneHeaders { fullHeader }
            threePaneBody
        }
    }

    var threePaneBody: some View {
        HStack(spacing: 0) {
            PlateSidebar()
                .frame(width: 250)
            Divider()
            canvas
            Divider()
            inspector()
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
                               onFace: { _, n in pickFace = false; Task { await model.layFlat(normal: n) } },
                               onMove: { obj, dx, dy in Task { await model.move(object: obj, dx: dx, dy: dy) } })
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
        .overlay(alignment: .bottomLeading) {
            if model.canUndo && !(panel == .preview && model.sliceIsCurrent) {
                Button {
                    Task { await model.undo() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .keyboardShortcut("z", modifiers: .command)
                .padding(12)
            }
        }
        .overlay(alignment: .bottom) {
            if let n = model.notice {
                Text(n)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 56)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)
        // full-bleed under the home indicator when the 3D view is at the bottom (side-by-side layouts)
        .ignoresSafeArea(edges: .bottom)
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

    /// The panels. With `menu`, the ⋯ menu sits next to the panel picker (the navigation bar is hidden).
    func inspector(menu: Bool = false) -> some View {
        VStack(spacing: 0) {
            if menu {
                HStack(spacing: 12) {
                    Picker("Panel", selection: $panel) {
                        ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    moreMenu
                        .font(.title2)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            } else {
                panelPicker
            }
            panelContent
                .frame(maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// The strip over the iPhone Duo's crease: nothing interactive lands on the fold.
struct FoldGap: View {
    let vertical: Bool
    var background = Color(.secondarySystemBackground)

    var body: some View {
        ZStack {
            background
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: vertical ? 3 : 36, height: vertical ? 36 : 3)
        }
        .accessibilityHidden(true)
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
                NewPlateCard()
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
                    NewPlateCard()
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
                        if p.isEmpty { Text("Empty").font(.caption2).foregroundStyle(.secondary) }
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
        .contextMenu {
            if !p.isEmpty {
                Button {
                    Task { await model.selectPlate(p.index); await model.arrangePlate(p.index) }
                } label: { Label("Arrange", systemImage: "square.grid.3x3.square") }
            }
            if p.isEmpty && (model.project?.plates.count ?? 0) > 1 {
                Button(role: .destructive) {
                    Task { await model.removePlate(p.index) }
                } label: { Label("Remove plate", systemImage: "trash") }
            }
        }
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
            if let o = model.selectedObject {
                Divider().frame(height: 24)
                Menu {
                    MoveToPlateItems(object: o)
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: "rectangle.portrait.on.rectangle.portrait").font(.system(size: 14))
                        Text("Plate").font(.system(size: 9, weight: .medium))
                    }
                    .frame(minWidth: 40)
                    .padding(.vertical, 4)
                }
            }
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
                    HStack(spacing: 10) {
                        Button {
                            Task { await model.arrangePlate() }
                        } label: {
                            Label("Arrange", systemImage: "square.grid.3x3.square")
                        }
                        .disabled(p.isEmpty)
                        Menu {
                            Button {
                                Task { await model.arrangePlate(allowRotation: true) }
                            } label: { Label("Arrange, turning parts to fit", systemImage: "rotate.right") }
                            .disabled(p.isEmpty)
                            Button {
                                Task { await model.centerPlate() }
                            } label: { Label("Center on bed", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
                            Button {
                                Task { let i = await model.addPlate(); await model.selectPlate(i) }
                            } label: { Label("New plate", systemImage: "plus.rectangle.on.rectangle") }
                            if p.isEmpty && (model.project?.plates.count ?? 0) > 1 {
                                Button(role: .destructive) {
                                    Task { await model.removePlate(p.index) }
                                } label: { Label("Remove this plate", systemImage: "trash") }
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        Spacer()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                if let sel = model.selectedObject, let o = p.objects.first(where: { $0.index == sel }) {
                    ObjectPositionSection(object: o)
                }
                if p.isEmpty {
                    Section {
                        Text("This plate is empty. Move objects here from another plate: select one there, then Plate › \(model.plateLabel(p.index)).")
                            .font(.footnote).foregroundStyle(.secondary)
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
                        .contextMenu {
                            Menu {
                                MoveToPlateItems(object: o.index)
                            } label: { Label("Move to plate", systemImage: "rectangle.portrait.on.rectangle.portrait") }
                        }
                    }
                } header: {
                    Text("Objects")
                } footer: {
                    Text("Tap an object here or in the 3D view to select it, then drag it on the bed, rotate it or move it to another plate.")
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

/// Menu items that send an object to another plate of the project, or to a new one.
struct MoveToPlateItems: View {
    @EnvironmentObject var model: AppModel
    let object: Int

    var body: some View {
        ForEach(model.project?.plates ?? []) { p in
            if !p.objects.contains(where: { $0.index == object }) {
                Button {
                    Task { await model.moveObject(object, toPlate: p.index) }
                } label: {
                    Text(model.plateLabel(p.index))
                }
            }
        }
        Button {
            Task { await model.moveObject(object, toPlate: nil) }
        } label: {
            Label("New plate", systemImage: "plus")
        }
    }
}

/// The "+" card after the plates.
struct NewPlateCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            Task {
                let i = await model.addPlate()
                await model.selectPlate(i)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                Text("New plate").font(.caption2)
            }
            .foregroundStyle(Theme.accent)
            .frame(width: 72, height: 52)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New plate")
    }
}

/// Where the selected object sits on the bed: type a position or nudge it.
struct ObjectPositionSection: View {
    @EnvironmentObject var model: AppModel
    let object: ObjectInfo
    @State private var x = ""
    @State private var y = ""
    @State private var step = 1.0

    var body: some View {
        Section {
            HStack(spacing: 10) {
                field("X", $x)
                field("Y", $y)
                Button("Move") {
                    let c = object.center
                    Task { await model.place(object: object.index, x: Double(x.replacingOccurrences(of: ",", with: ".")) ?? c.x,
                                             y: Double(y.replacingOccurrences(of: ",", with: ".")) ?? c.y) }
                }
                .buttonStyle(.bordered)
                .disabled(!changed)
            }
            HStack(spacing: 6) {
                nudge("arrow.left", -step, 0)
                nudge("arrow.down", 0, -step)
                nudge("arrow.up", 0, step)
                nudge("arrow.right", step, 0)
                Spacer(minLength: 8)
                Picker("Step", selection: $step) {
                    Text("1 mm").tag(1.0)
                    Text("5 mm").tag(5.0)
                    Text("10 mm").tag(10.0)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            Menu {
                MoveToPlateItems(object: object.index)
            } label: {
                Label("Move to another plate", systemImage: "rectangle.portrait.on.rectangle.portrait")
            }
        } header: {
            Text(object.name)
        } footer: {
            Text("Drag the object in the 3D view, or set where its middle sits on the bed (mm from the front-left corner). Up moves it towards the back.")
        }
        .onAppear(perform: load)
        .onChange(of: object) { _, _ in load() }
    }

    var changed: Bool {
        let c = object.center
        return String(format: "%.1f", c.x) != x || String(format: "%.1f", c.y) != y
    }

    func load() {
        let c = object.center
        x = String(format: "%.1f", c.x)
        y = String(format: "%.1f", c.y)
    }

    func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            TextField(label, text: text)
                .keyboardType(.decimalPad)
                .font(.body.monospacedDigit())
                .frame(minWidth: 56)
        }
    }

    func nudge(_ icon: String, _ dx: Double, _ dy: Double) -> some View {
        Button {
            Task { await model.move(object: object.index, dx: dx, dy: dy) }
        } label: {
            Image(systemName: icon).frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(dx < 0 ? "Left" : dx > 0 ? "Right" : dy > 0 ? "Back" : "Front")
    }
}
