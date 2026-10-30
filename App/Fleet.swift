import SwiftUI

/// Every saved printer at once: live status, progress and controls for each, and which one plates are sliced for.
struct PrintersView: View {
    @EnvironmentObject var printer: PrinterLink
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SavedPrinter?
    @State private var adding = false
    @State private var showQueue = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(printer.all) { c in
                        NavigationLink(value: c.id) {
                            PrinterCard(connection: c, selected: c.id == printer.activeID)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Remove", role: .destructive) { printer.remove(c.printer) }
                            Button("Edit") { editing = c.printer }.tint(.gray)
                        }
                        .swipeActions(edge: .leading) {
                            if c.id != printer.activeID {
                                Button("Use") { printer.select(c.id) }.tint(Theme.accent)
                            }
                        }
                    }
                    Button { adding = true } label: { Label("Add printer", systemImage: "plus") }
                } header: {
                    Text("Your printers")
                } footer: {
                    Text(printer.printers.count > 1
                         ? "Duo Slicer stays connected to all of them while it's open. The selected printer (✓) is the one plates are sliced for and sent to; the queue can use any of them."
                         : "Duo Slicer slices for the selected printer and sends prints to it over your Wi-Fi.")
                }

                if !printer.printers.isEmpty {
                    Section {
                        Button { showQueue = true } label: { QueueSummaryRow() }
                    }
                }

                if printer.printers.isEmpty {
                    Section {
                        Picker("Slice for", selection: Binding(get: { model.target.id }, set: { id in Task { await model.setTarget(id) } })) {
                            ForEach(PrinterCatalog.models) { Text($0.name).tag($0.id) }
                        }
                    } footer: {
                        Text("No printer on your network yet? You can still slice for any of these and share the file.")
                    }
                }
            }
            .navigationTitle("Printers")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                if let c = printer.connection(id) { PrinterDetailView(connection: c) }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editing) { p in PrinterEditor(printer: p) }
            .sheet(isPresented: $adding) { AddPrinterView() }
            .sheet(isPresented: $showQueue) { QueueView() }
            .onAppear {
                // screenshots: open one printer's page
                if let m = DemoMode.openPrinter, let c = printer.all.first(where: { $0.printer.modelID == m }) { path = [c.id] }
            }
        }
    }
}

/// One printer in the list: name, state, progress.
struct PrinterCard: View {
    @ObservedObject var connection: PrinterConnection
    let selected: Bool

    var body: some View {
        let c = connection
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(c.printer.name).font(.body.weight(.medium)).lineLimit(1)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.footnote)
                            .accessibilityLabel("Selected for slicing")
                    }
                }
                Text("\(c.printer.model?.shortName ?? c.printer.modelID) · \(c.printer.hostOnly)")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Text(line).font(.footnote).foregroundStyle(c.errorText != nil ? .red : .secondary).lineLimit(2)
                if c.isBusy && c.percent > 0 {
                    ProgressView(value: Double(c.percent), total: 100).tint(Theme.accent)
                }
            }
        }
        .padding(.vertical, 2)
    }

    var dotColor: Color {
        guard connection.connected else { return .secondary }
        if connection.errorText != nil { return .red }
        return connection.isBusy ? Theme.accent : .green
    }

    var line: String { PrinterCard.describe(connection) }

    /// "Printing 45% · 1 h 20 min left", "Ready", or why it isn't connected.
    static func describe(_ c: PrinterConnection) -> String {
        if let e = c.errorText { return e }
        guard c.connected else { return c.statusText }
        switch c.state {
        case "RUNNING":
            let job = c.jobName.isEmpty ? "" : " \(c.jobName)"
            return "Printing\(job) · \(c.percent)% · \(formatDuration(Double(c.remainingMinutes) * 60)) left"
        case "PAUSE": return "Paused at \(c.percent)%"
        case "PREPARE": return "Preparing: heating and leveling"
        case "FINISH": return "Finished · take the print off the bed"
        case "FAILED": return "Last print stopped"
        default: return "Ready"
        }
    }
}

/// One printer: status, temperatures, what's loaded, and its controls.
struct PrinterDetailView: View {
    @EnvironmentObject var link: PrinterLink
    @ObservedObject var connection: PrinterConnection
    @State private var editing = false
    @State private var confirmStop = false

    var body: some View {
        let c = connection
        List {
            Section {
                CameraView(connection: c)
                    .listRowInsets(EdgeInsets())
            }
            Section("Status") {
                LabeledContent("State", value: PrinterCard.describe(c))
                if c.connected {
                    if c.totalLayers > 0 && c.isBusy { LabeledContent("Layer", value: "\(c.layer) of \(c.totalLayers)") }
                    LabeledContent("Nozzle", value: "\(Int(c.nozzle))°C")
                    LabeledContent("Bed", value: "\(Int(c.bed))°C")
                }
                if c.isBusy {
                    HStack {
                        if c.state == "PAUSE" {
                            Button("Resume") { c.send("resume") }.buttonStyle(.borderedProminent)
                        } else {
                            Button("Pause") { c.send("pause") }.buttonStyle(.bordered)
                        }
                        Spacer()
                        Button("Stop", role: .destructive) { confirmStop = true }.buttonStyle(.bordered)
                    }
                }
                if let r = c.lastResult { Text(r).font(.footnote).foregroundStyle(.secondary) }
            }
            if !c.trays.isEmpty {
                Section("AMS") {
                    ForEach(c.trays) { t in
                        HStack {
                            Circle().fill(t.loaded && !t.color.isEmpty ? Color(hex: t.color) : .clear).overlay(Circle().stroke(.secondary)).frame(width: 14, height: 14)
                            Text(t.label)
                            Spacer()
                            Text(t.loaded ? t.name : "Empty").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !c.toolheads.isEmpty {
                Section("Heads") {
                    ForEach(c.toolheads) { h in
                        HStack {
                            Circle().fill(h.loaded && !h.color.isEmpty ? Color(hex: h.color) : .clear).overlay(Circle().stroke(.secondary)).frame(width: 14, height: 14)
                            Text(h.label)
                            Spacer()
                            Text("\(h.summary) · \(Int(h.temperature))°C").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            QueueForPrinterSection(printerID: c.id)
            Section {
                if c.id != link.activeID {
                    Button {
                        link.select(c.id)
                    } label: {
                        Label("Slice for and print to this printer", systemImage: "checkmark.circle")
                    }
                } else {
                    Label("Plates are sliced for this printer", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                }
                Button {
                    c.connect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                Button {
                    editing = true
                } label: {
                    Label("Edit printer", systemImage: "pencil")
                }
            }
        }
        .navigationTitle(c.printer.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) { PrinterEditor(printer: c.printer) }
        .confirmationDialog("Stop the print on \(c.printer.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop print", role: .destructive) { c.send("stop") }
        }
    }
}
