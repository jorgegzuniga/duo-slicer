import SwiftUI
import UIKit

/// Add a printer by finding it on the Wi-Fi: Bambu Lab printers need only their access code, a Snapmaker U1 nothing.
struct AddPrinterView: View {
    @EnvironmentObject var link: PrinterLink
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = PrinterDiscovery()
    @State private var path: [FoundPrinter] = []
    @State private var manual = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(discovery.found) { f in
                        let saved = link.saved(matching: f)
                        Button { path.append(f) } label: { FoundPrinterRow(found: f, saved: saved) }
                            .disabled(saved != nil || !f.isSupported)
                    }
                    status
                } header: {
                    Text("On your Wi-Fi")
                } footer: {
                    Text("Turn the printer on and connect it to the same Wi-Fi as this iPhone. Duo Slicer finds Bambu Lab printers and the Snapmaker U1.")
                }
                Section {
                    Button {
                        discovery.scan()
                    } label: {
                        Label("Search again", systemImage: "arrow.clockwise")
                    }
                    .disabled(discovery.scanning)
                    Button {
                        manual = true
                    } label: {
                        Label("Enter its IP address instead", systemImage: "keyboard")
                    }
                }
            }
            .navigationTitle("Add printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(for: FoundPrinter.self) { f in
                ConnectFoundPrinterView(found: f) { dismiss() }
            }
            .sheet(isPresented: $manual) { PrinterEditor(printer: nil) }
            // added by hand: nothing left to do here
            .onChange(of: link.printers.count) { old, new in if new > old { dismiss() } }
            // a saved Bambu printer that the router gave a new address
            .onChange(of: discovery.found) { _, list in list.forEach { link.follow($0) } }
            .task { if discovery.found.isEmpty && !discovery.scanning { discovery.scan() } }
            .onDisappear { discovery.stop() }
        }
    }

    @ViewBuilder var status: some View {
        if discovery.scanning {
            HStack(spacing: 12) {
                ProgressView()
                Text(discovery.found.isEmpty ? "Looking for printers on your Wi-Fi…" : "Still looking…")
                    .foregroundStyle(.secondary)
            }
        } else if discovery.found.isEmpty {
            switch discovery.problem {
            case .noWiFi:
                Label("Connect this iPhone to Wi-Fi to find printers.", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            case .localNetworkBlocked:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Duo Slicer needs Local Network access to find printers. Turn it on in Settings › Privacy & Security › Local Network.")
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            case nil:
                Text("No printers found. Check that the printer is on and on this Wi-Fi, then search again.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct FoundPrinterRow: View {
    let found: FoundPrinter
    let saved: SavedPrinter?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "printer.fill")
                .foregroundStyle(found.isSupported ? Theme.accent : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(found.title).foregroundStyle(found.isSupported && saved == nil ? .primary : .secondary)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if saved == nil && found.isSupported {
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
        }
    }

    var detail: String {
        if let saved { return "Added as \(saved.name) · \(found.host)" }
        if let why = found.unsupported { return "\(found.host) · \(why)" }
        if found.needsKey { return "\(found.host) · asks for an API key" }
        return found.serial.isEmpty ? found.host : "\(found.host) · \(found.serial)"
    }
}

/// The one step left after finding a printer: the access code for a Bambu Lab printer (checked by signing in),
/// a quick check for a Snapmaker U1.
struct ConnectFoundPrinterView: View {
    @EnvironmentObject var link: PrinterLink
    let found: FoundPrinter
    let done: () -> Void
    @State private var modelID: String
    @State private var name = ""
    @State private var code = ""
    @State private var working = false
    @State private var failure: String?

    init(found: FoundPrinter, done: @escaping () -> Void) {
        self.found = found
        self.done = done
        _modelID = State(initialValue: found.modelID ?? "")
    }

    var isBambu: Bool { found.kind == .bambu }
    var model: PrinterModel? { PrinterCatalog.model(modelID) }
    var trimmedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Address", value: found.host)
                if !found.serial.isEmpty { LabeledContent("Serial number", value: found.serial) }
                if isBambu && found.modelID == nil {
                    Picker("Model", selection: $modelID) {
                        Text("Find out when connecting").tag("")
                        ForEach(PrinterCatalog.models.filter(\.isBambu)) { Text($0.shortName).tag($0.id) }
                    }
                }
                TextField("Name", text: $name, prompt: Text(model?.name ?? found.title))
            }
            if isBambu {
                Section {
                    TextField("8-character code", text: $code)
                        .font(.body.monospaced())
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { if !trimmedCode.isEmpty { Task { await connect() } } }
                } header: {
                    Text("Access code")
                } footer: {
                    Text("On the printer's screen, open Settings and its network (WLAN) page: the access code is shown there. Turn on LAN-only Mode and Developer Mode on the same page, and keep a microSD card in the printer for prints.")
                }
            } else if found.needsKey {
                Section {
                    SecureField("API key", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("This printer's Moonraker asks for an API key.")
                }
            }
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Spacer()
                        if working {
                            ProgressView()
                        } else {
                            Text(isBambu ? "Connect" : "Add printer").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(working || (isBambu && trimmedCode.isEmpty) || (found.needsKey && trimmedCode.isEmpty))
            }
        }
        .navigationTitle(found.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    func connect() async {
        guard !working else { return }
        working = true
        failure = nil
        defer { working = false }
        do {
            var id = modelID
            if isBambu {
                if let detected = try await BambuCheck.login(host: found.host, serial: found.serial, code: trimmedCode) { id = detected }
                guard !id.isEmpty else {
                    failure = "Connected, but the printer didn't say which model it is. Choose it above, then connect again."
                    return
                }
            } else {
                guard let client = MoonrakerClient(host: found.host, port: 7125, apiKey: trimmedCode.isEmpty ? nil : trimmedCode) else { return }
                _ = try await client.status()
                id = "snapmaker-u1"
            }
            let p = SavedPrinter(modelID: id, name: name, host: found.host, serial: found.serial)
            link.upsert(p, secret: trimmedCode.isEmpty ? nil : trimmedCode)
            link.select(p.id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            done()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if isBambu && msg.contains("refused") {
                failure = msg + " Check the code on the printer's screen. If it's right, turn on Developer Mode there and try again."
            } else {
                failure = msg
            }
        }
    }
}
