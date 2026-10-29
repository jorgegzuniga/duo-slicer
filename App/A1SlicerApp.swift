import SwiftUI
import UniformTypeIdentifiers

@main
struct A1SlicerApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var printer = PrinterLink()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(printer)
                .tint(Theme.accent)
                .onOpenURL { url in Task { await model.open(url: url) } }
                .onAppear { printer.start() }
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
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var printer: PrinterLink
    @State private var importing = false
    @State private var showPrinter = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        importing = true
                    } label: {
                        Label("Open a 3MF project", systemImage: "square.and.arrow.down")
                            .font(.headline)
                    }
                    Text("Pick a .3mf from Files, or share one to Duo Slicer from MakerWorld, Safari or Mail.")
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
                Section("Printer") {
                    Button {
                        showPrinter = true
                    } label: {
                        PrinterStatusRow()
                    }
                }
            }
            .navigationTitle("Duo Slicer")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.threeMF, .zip, .data]) { result in
                if case .success(let url) = result { Task { await model.open(url: url) } }
            }
            .sheet(isPresented: $showPrinter) { PrinterSetupView() }
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
                Text(printer.isConfigured ? "Bambu Lab A1 · \(printer.ip)" : "Set up your A1")
                    .foregroundStyle(.primary)
                Text(statusLine).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
    }

    var statusLine: String {
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
