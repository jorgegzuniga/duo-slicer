import SwiftUI
import UniformTypeIdentifiers

@main
struct A1SlicerApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var printer = PrinterLink()
    @StateObject private var claude = ClaudeBridge()
    @StateObject private var queue = PrintQueue()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .duoDemoFrame()
                .environmentObject(model)
                .environmentObject(printer)
                .environmentObject(claude)
                .environmentObject(queue)
                .tint(Theme.accent)
                .onOpenURL { url in Task { await model.open(url: url) } }
                .onAppear {
                    claude.attach(model: model, printer: printer, queue: queue)
                    queue.attach(printer)
                    if DemoMode.isOn {
                        Task { await DemoMode.run(model: model, printer: printer, claude: claude, queue: queue) }
                    } else {
                        printer.start()
                    }
                }
                .onChange(of: scenePhase) { _, phase in claude.setForeground(phase == .active) }
        }
    }
}

extension UTType {
    static let threeMF = UTType(importedAs: "com.jorgegzuniga.duoslicer.3mf", conformingTo: .data)
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var printer: PrinterLink
    @EnvironmentObject var claude: ClaudeBridge
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if model.project != nil {
                ProjectView()
            } else {
                HomeView()
            }
        }
        .overlay {
            if model.busy {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView("Opening project…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18).stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // drag a .3mf in from Files or another app (Split View on an unfolded iPhone Duo or iPad)
        .onDrop(of: [UTType.threeMF, UTType.zip, UTType.data, UTType.fileURL], isTargeted: $dropTargeted) { providers in
            DropLoader.load(providers) { url in Task { await model.open(url: url) } }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: Binding(get: { claude.approval }, set: { if $0 == nil { claude.answer(false) } })) { req in
            ApprovalSheet(request: req)
        }
        .task(id: printer.activeID) {
            // slice for the printer that's selected
            if let m = printer.activeModel, m.id != model.target.id { await model.setTarget(m.id) }
        }
    }
}

/// Copies dropped files into a temporary folder, then hands back a file URL.
enum DropLoader {
    static func load(_ providers: [NSItemProvider], open: @escaping @MainActor (URL) -> Void) -> Bool {
        guard let p = providers.first else { return false }
        let types = [UTType.threeMF.identifier, UTType.zip.identifier, UTType.data.identifier]
        guard let type = types.first(where: { p.hasItemConformingToTypeIdentifier($0) }) else { return false }
        p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
            guard let url else { return }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return }
            Task { @MainActor in open(dest) }
        }
        return true
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var printer: PrinterLink
    @EnvironmentObject var claude: ClaudeBridge
    @State private var importing = false
    @State private var showPrinters = false
    @State private var showAddPrinter = false
    @State private var showClaude = false
    @State private var showQueue = false
    @State private var fold: CGRect?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // on the unfolded iPhone Duo: projects on one side of the crease, printer and Claude on the other
                switch ProjectLayout(size: geo.size, fold: fold) {
                case .split(let left, let gap) where gap > 0:
                    HStack(spacing: 0) {
                        column { header; projectSections }.frame(width: left)
                        FoldGap(vertical: true, background: Color(.systemGroupedBackground)).frame(width: gap)
                        column { deviceSections }
                    }
                case .stacked(let top, let gap):
                    VStack(spacing: 0) {
                        column { header; projectSections }.frame(height: top)
                        FoldGap(vertical: false, background: Color(.systemGroupedBackground)).frame(height: gap)
                        column { deviceSections }
                    }
                default:
                    column {
                        header
                        projectSections
                        deviceSections
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .background(FoldReader(fold: $fold))
            // the title is part of the page (a bar-wide title would sit on the iPhone Duo's crease)
            .toolbar(.hidden, for: .navigationBar)
            .navigationTitle("Duo Slicer")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.threeMF, .zip, .data]) { result in
                if case .success(let url) = result { Task { await model.open(url: url) } }
            }
            .sheet(isPresented: $showPrinters) { PrintersView() }
            .sheet(isPresented: $showAddPrinter) { AddPrinterView() }
            .sheet(isPresented: $showClaude) { ClaudeSettingsView() }
            .sheet(isPresented: $showQueue) { QueueView() }
            .onAppear { if UserDefaults.standard.bool(forKey: "DuoDemoAddPrinter") { showAddPrinter = true } }
            .onReceive(NotificationCenter.default.publisher(for: .duoDemoSheet)) { n in
                switch n.object as? String {
                case "printers": showPrinters = true
                case "queue": showQueue = true
                default: break
                }
            }
        }
    }

    func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content() }
                .padding(.horizontal)
                .padding(.vertical, 12)
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            AppMark(size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("Duo Slicer").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Slicing for the \(model.target.name)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder var projectSections: some View {
        Button {
            importing = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open a 3MF project").font(.headline)
                    Text("From Files, or share one to Duo Slicer from MakerWorld, Safari or Mail").font(.caption).opacity(0.9)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: Theme.accent2.opacity(0.25), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("o", modifiers: .command)

        if !model.recents.isEmpty {
            CardTitle(title: "Recent projects", icon: "clock.arrow.circlepath")
                .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(model.recents, id: \.self) { url in
                    RecentProjectCard(url: url)
                }
            }
        }
    }

    @ViewBuilder var deviceSections: some View {
        CardTitle(title: printer.printers.count > 1 ? "Printers" : "Printer", icon: "printer",
                  trailing: printer.printers.count > 1 ? "\(printer.printers.count) saved" : nil)
        Button {
            // no printer yet: go straight to finding one on the Wi-Fi
            if printer.printers.isEmpty { showAddPrinter = true } else { showPrinters = true }
        } label: {
            PrinterStatusRow().card()
        }
        .buttonStyle(.plain)
        Button {
            showQueue = true
        } label: {
            QueueSummaryRow().card()
        }
        .buttonStyle(.plain)
        Button {
            showClaude = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use with Claude").foregroundStyle(.primary)
                    Text(claude.enabled ? claude.status : "Let Claude open, slice and print from this app.")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }
}

/// A recent project: its first plate's picture (once it's been opened here), name, and a Print shortcut that opens
/// the project straight into the Print sheet.
struct RecentProjectCard: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    @State private var confirmDelete = false

    var name: String { AppModel.projectName(url.lastPathComponent) }

    var modified: Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await model.open(url: url) }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.softGradient)
                        if let img = model.picture(for: url) {
                            Image(uiImage: img).resizable().scaledToFit().padding(6)
                        } else {
                            Image(systemName: "cube.transparent").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent.opacity(0.7))
                        }
                    }
                    .frame(height: 112)
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                if let d = modified {
                    Text(d.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    Task {
                        model.printOnOpen = true
                        await model.open(url: url)
                        if model.project == nil { model.printOnOpen = false }
                    }
                } label: {
                    Label("Print", systemImage: "printer.fill").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(Theme.accent)
            }
        }
        .card(padding: 10)
        .contextMenu {
            Button { Task { await model.open(url: url) } } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
        }
        .confirmationDialog("Delete \(name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteRecent(url) }
        }
    }
}

struct PrinterStatusRow: View {
    @EnvironmentObject var printer: PrinterLink

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: printer.isConfigured ? "printer.fill" : "plus")
                .font(.headline)
                .foregroundStyle(printer.isConfigured ? stateColor : Theme.accent)
                .frame(width: 38, height: 38)
                .background((printer.isConfigured ? stateColor : Theme.accent).opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.active.map { "\($0.name) · \($0.hostOnly)" } ?? "Add your printer")
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(statusLine).font(.footnote).foregroundStyle(.secondary)
                if printer.connected && printer.state == "RUNNING" {
                    ProgressView(value: Double(printer.percent) / 100).tint(Theme.accent2)
                }
                if let others = othersLine {
                    Text(others).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
    }

    var stateColor: Color {
        guard printer.connected else { return .secondary }
        switch printer.state {
        case "RUNNING", "PREPARE": return Theme.accent2
        case "PAUSE": return Theme.warm
        default: return .green
        }
    }

    /// The other printers, briefly: "Also: Office U1 printing 45%, Garage X1C ready".
    var othersLine: String? {
        let others = printer.all.filter { $0.id != printer.activeID }
        guard !others.isEmpty else { return nil }
        let parts = others.map { c -> String in
            guard c.connected else { return "\(c.printer.name) offline" }
            switch c.state {
            case "RUNNING": return "\(c.printer.name) printing \(c.percent)%"
            case "PAUSE": return "\(c.printer.name) paused"
            case "PREPARE": return "\(c.printer.name) starting"
            case "FINISH": return "\(c.printer.name) finished"
            default: return "\(c.printer.name) ready"
            }
        }
        return "Also: " + parts.joined(separator: ", ")
    }

    var statusLine: String {
        guard printer.isConfigured else { return "Find your Bambu Lab printer or Snapmaker U1 on this Wi-Fi" }
        guard printer.connected else { return printer.statusText }
        switch printer.state {
        case "RUNNING": return "Printing \(printer.percent)%\(timeLeft(minutes: printer.remainingMinutes))"
        case "PAUSE": return "Paused at \(printer.percent)%"
        case "PREPARE": return "Preparing: heating and leveling"
        case "FINISH": return "Ready · last print finished"
        case "FAILED": return "Ready · last print stopped"
        default: return "Ready"
        }
    }
}

struct ClaudeSettingsView: View {
    @EnvironmentObject var claude: ClaudeBridge
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Let Claude use Duo Slicer", isOn: $claude.enabled)
                    if claude.enabled {
                        LabeledContent("Status") {
                            Text(claude.status).multilineTextAlignment(.trailing).foregroundStyle(claude.connected ? Theme.accent : .secondary)
                        }
                    }
                } footer: {
                    Text("Claude can open your projects, change settings, slice plates and check your printer. Starting or stopping a print always asks you here first. It works while Duo Slicer is open.")
                }
                if claude.enabled {
                    Section {
                        if let url = claude.connectorURL {
                            Text(url).font(.footnote.monospaced()).textSelection(.enabled)
                            Button {
                                UIPasteboard.general.string = url
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy connector URL", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                        } else {
                            Text("Add the relay address below to get your connector URL.").foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Connector URL")
                    } footer: {
                        Text("In Claude, open Customize › Connectors, choose + Add › Add custom connector, paste this URL and pick No sign in. Keep the URL private: it's the key to these tools.")
                    }
                    Section {
                        TextField("https://duo-slicer-relay.example.workers.dev", text: $claude.relayURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Button("Make a new connector URL", role: .destructive) { confirmReset = true }
                    } header: {
                        Text("Relay")
                    } footer: {
                        Text("The relay is the small Cloudflare Worker in the duo-slicer repository. It passes Claude's requests to this app.")
                    }
                    if !claude.activity.isEmpty {
                        Section("Recent") {
                            ForEach(Array(claude.activity.enumerated()), id: \.offset) { _, line in Text(line).font(.footnote) }
                        }
                    }
                }
            }
            .navigationTitle("Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Make a new connector URL?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("New URL", role: .destructive) { claude.resetSecret(); copied = false }
            } message: {
                Text("The current URL stops working; add the new one in Claude.")
            }
        }
    }
}
