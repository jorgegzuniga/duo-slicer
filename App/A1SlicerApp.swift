import SwiftUI
import UniformTypeIdentifiers

@main
struct A1SlicerApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var printer = PrinterLink()
    @StateObject private var claude = ClaudeBridge()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .duoDemoFrame()
                .environmentObject(model)
                .environmentObject(printer)
                .environmentObject(claude)
                .tint(Theme.accent)
                .onOpenURL { url in Task { await model.open(url: url) } }
                .onAppear {
                    claude.attach(model: model, printer: printer)
                    if DemoMode.isOn {
                        Task { await DemoMode.run(model: model, printer: printer, claude: claude) }
                    } else {
                        printer.start()
                    }
                }
                .onChange(of: scenePhase) { _, phase in claude.setForeground(phase == .active) }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.04, green: 0.43, blue: 0.44)
    static let bed = Color(red: 0.23, green: 0.25, blue: 0.27)
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
    @State private var fold: CGRect?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // on the unfolded iPhone Duo: projects on one side of the crease, printer and Claude on the other
                switch ProjectLayout(size: geo.size, fold: fold) {
                case .split(let left, let gap) where gap > 0:
                    HStack(spacing: 0) {
                        List { titleRow; projectSections }.frame(width: left)
                        FoldGap(vertical: true, background: Color(.systemGroupedBackground)).frame(width: gap)
                        List { deviceSections }
                    }
                case .stacked(let top, let gap):
                    VStack(spacing: 0) {
                        List { titleRow; projectSections }.frame(height: top)
                        FoldGap(vertical: false, background: Color(.systemGroupedBackground)).frame(height: gap)
                        List { deviceSections }
                    }
                default:
                    List {
                        titleRow
                        projectSections
                        deviceSections
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .background(FoldReader(fold: $fold))
            // the title is the first row of the list (a bar-wide title would sit on the iPhone Duo's crease)
            .toolbar(.hidden, for: .navigationBar)
            .navigationTitle("Duo Slicer")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.threeMF, .zip, .data]) { result in
                if case .success(let url) = result { Task { await model.open(url: url) } }
            }
            .sheet(isPresented: $showPrinters) { PrintersView() }
            .sheet(isPresented: $showAddPrinter) { AddPrinterView() }
            .sheet(isPresented: $showClaude) { ClaudeSettingsView() }
            .onAppear { if UserDefaults.standard.bool(forKey: "DuoDemoAddPrinter") { showAddPrinter = true } }
        }
    }

    var titleRow: some View {
        Text("Duo Slicer")
            .font(.largeTitle.bold())
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 0, trailing: 0))
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder var projectSections: some View {
        Section {
            Button {
                importing = true
            } label: {
                Label("Open a 3MF project", systemImage: "square.and.arrow.down")
                    .font(.headline)
            }
            .keyboardShortcut("o", modifiers: .command)
            Text("Pick a .3mf from Files, share one to Duo Slicer from MakerWorld, Safari or Mail, or drag one in.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if !model.recents.isEmpty {
            Section("Recent projects") {
                ForEach(model.recents, id: \.self) { url in
                    Button {
                        Task { await model.open(url: url) }
                    } label: {
                        Label(url.deletingPathExtension().lastPathComponent, systemImage: "cube.transparent")
                    }
                }
                .onDelete { idx in idx.map { model.recents[$0] }.forEach(model.deleteRecent) }
            }
        }
    }

    @ViewBuilder var deviceSections: some View {
        Section {
            Button {
                // no printer yet: go straight to finding one on the Wi-Fi
                if printer.printers.isEmpty { showAddPrinter = true } else { showPrinters = true }
            } label: {
                PrinterStatusRow()
            }
        } header: {
            Text("Printer")
        } footer: {
            Text("Slicing for the \(model.target.name).")
        }
        Section {
            Button {
                showClaude = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use with Claude").foregroundStyle(.primary)
                        Text(claude.enabled ? claude.status : "Let Claude open, slice and print from this app.")
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct PrinterStatusRow: View {
    @EnvironmentObject var printer: PrinterLink

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(printer.connected ? (printer.isBusy ? Theme.accent : Color.green) : Color.secondary)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.active.map { "\($0.name) · \($0.hostOnly)" } ?? "Add your printer")
                    .foregroundStyle(.primary)
                Text(statusLine).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
    }

    var statusLine: String {
        guard printer.isConfigured else { return "Find your Bambu Lab printer or Snapmaker U1 on this Wi-Fi" }
        guard printer.connected else { return printer.statusText }
        switch printer.state {
        case "RUNNING": return "Printing \(printer.percent)% · \(formatDuration(Double(printer.remainingMinutes) * 60)) left"
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
