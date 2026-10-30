import SwiftUI

struct PrintPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var printer: PrinterLink
    @State private var mapping: [Int: Int] = [:]
    @State private var opts = StartOptions()
    @State private var bedClear = false
    @State private var sending = false
    @State private var sheet: PrintSheet?
    @State private var confirmStop = false
    @State private var showCamera = false

    var body: some View {
        List {
            Section {
                Button { sheet = .printers } label: { PrinterStatusRow() }
                PrintProgressRows(confirmStop: $confirmStop)
                if let c = printer.activeConnection, c.connected, c.model?.cameraKinds.isEmpty == false {
                    // the camera shows while printing; before a print it's a tap away (is the bed clear?)
                    if printer.isBusy || showCamera {
                        CameraView(connection: c, height: 190)
                            .listRowInsets(EdgeInsets())
                    }
                    if !printer.isBusy {
                        Button {
                            showCamera.toggle()
                        } label: {
                            Label(showCamera ? "Hide camera" : "Show camera", systemImage: showCamera ? "video.slash" : "video")
                        }
                    }
                }
            } header: { Text("Printer") }

            if model.target.isToolChanger, let p = model.plate {
                ToolheadSection(plate: p)
            }

            if !model.sliceIsCurrent {
                Section {
                    SliceButton()
                } footer: {
                    Text(model.target.isToolChanger
                         ? "Slice plate \(model.plate?.id ?? 0) for the \(model.target.shortName) with these heads, then send it from here."
                         : "Slice plate \(model.plate?.id ?? 0) first; you'll pick spools and send it from here.")
                }
            } else if let s = model.slice {
                if !model.target.isToolChanger {
                    Section {
                        ForEach(s.filaments ?? []) { f in
                            HStack {
                                Circle().fill(Color(hex: f.color)).frame(width: 14, height: 14)
                                Text("F\(f.id) \(f.type)").font(.subheadline)
                                Spacer()
                                Picker("Spool", selection: Binding(get: { mapping[f.id] ?? 254 }, set: { mapping[f.id] = $0 })) {
                                    ForEach(trayOptions) { t in
                                        Text(t.loaded ? "\(t.label) · \(t.name)" : "\(t.label) · empty").tag(t.id)
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    } header: {
                        Text("Spools")
                    } footer: {
                        Text(printer.trays.isEmpty ? "Connect the printer to see what's loaded in the AMS." : "Matched by colour and material. Change any you like.")
                    }
                    Section("Options") {
                        Toggle("Auto bed leveling", isOn: $opts.bedLeveling)
                        Toggle("Flow calibration", isOn: $opts.flowCalibration)
                        Toggle("Vibration compensation", isOn: $opts.vibrationCalibration)
                        Toggle("Timelapse", isOn: $opts.timelapse)
                    }
                }
                Section {
                    Toggle("The bed is clear and the \(shortBed(s.bedType ?? "")) is on", isOn: $bedClear)
                    if let p = printer.uploadProgress {
                        ProgressView(value: p) { Text("Uploading to the printer…").font(.footnote) }
                    }
                    Button {
                        Task { await send() }
                    } label: {
                        Label(sending ? "Sending…" : "Print plate \(s.plateId ?? 0) on \(printer.activeModel?.shortName ?? "printer")", systemImage: "printer.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!bedClear || sending || !printer.connected || printer.isBusy)
                    .keyboardShortcut("p", modifiers: .command)
                    if !printer.isConfigured {
                        Text("Add a printer to print over Wi-Fi, or share the sliced file from the ••• menu.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let r = printer.lastResult { Text(r).font(.footnote).foregroundStyle(.secondary) }
                } footer: {
                    Text(String(format: "%@ · %.1f g. The %@ heats, levels and cleans the nozzle for a few minutes before the first layer.",
                                formatDuration(s.seconds ?? 0), s.grams ?? 0, model.target.shortName))
                }
            }

            Section {
                Button { sheet = .addToQueue } label: { Label("Add to print queue", systemImage: "text.badge.plus") }
                Button { sheet = .queue } label: { QueueSummaryRow() }
            } header: {
                Text("Queue")
            } footer: {
                Text("Line up this plate, all plates or several copies, on this printer or any \(model.target.shortName). Each print starts after you say the bed is clear.")
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $sheet) { s in PrintSheetContent(sheet: s, start: opts) }
        .confirmationDialog("Stop this print?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop print", role: .destructive) { printer.send("stop") }
        } message: {
            Text("It can't be resumed after stopping.")
        }
        .onAppear(perform: remap)
        .onChange(of: model.slice?.plateId) { _, _ in remap() }
        .onChange(of: printer.trays) { _, _ in if mapping.isEmpty || mapping.values.allSatisfy({ $0 == 254 }) { remap() } }
    }

    var trayOptions: [Tray] {
        printer.trays.isEmpty ? [Tray(id: 254, label: "External spool", type: "", color: "", name: "", loaded: true)] : printer.trays
    }

    func shortBed(_ b: String) -> String {
        switch b {
        case "Textured PEI Plate": return "textured PEI plate"
        case "High Temp Plate": return "smooth PEI plate"
        case "Supertack Plate": return "SuperTack plate"
        case "Cool Plate": return "cool plate"
        case "Engineering Plate": return "engineering plate"
        case "Textured Cool Plate": return "textured cool plate"
        default: return "plate"
        }
    }

    func remap() {
        guard let s = model.slice else { return }
        mapping = printer.suggestMapping(for: s.filaments ?? [])
    }

    func send() async {
        sending = true
        defer { sending = false }
        do {
            try await model.sendCurrentSlice(to: printer, mapping: mapping, options: opts)
            bedClear = false
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

/// Live progress, pause / resume / stop and errors for the selected printer.
struct PrintProgressRows: View {
    @EnvironmentObject var printer: PrinterLink
    @Binding var confirmStop: Bool

    var body: some View {
        if printer.connected && printer.isBusy {
            if printer.state == "RUNNING" || printer.state == "PAUSE" {
                ProgressView(value: Double(printer.percent) / 100) {
                    Text(printer.jobName).font(.footnote).lineLimit(1)
                } currentValueLabel: {
                    Text(detail).font(.caption2)
                }
            }
            HStack {
                if printer.state == "PAUSE" {
                    Button("Resume") { printer.send("resume") }.buttonStyle(.bordered)
                } else {
                    Button("Pause") { printer.send("pause") }.buttonStyle(.bordered)
                }
                Spacer()
                Button("Stop print", role: .destructive) { confirmStop = true }.buttonStyle(.bordered)
            }
        }
        if let e = printer.errorText {
            Label(e, systemImage: "exclamationmark.octagon").font(.footnote).foregroundStyle(.red)
        }
    }

    var detail: String {
        var parts: [String] = []
        if printer.totalLayers > 0 { parts.append("Layer \(printer.layer) of \(printer.totalLayers)") }
        parts.append("nozzle \(Int(printer.nozzle))°C")
        parts.append("bed \(Int(printer.bed))°C")
        return parts.joined(separator: " · ")
    }
}

/// Tool changers: which head prints each colour on this plate. Defaults to the closest loaded filament.
struct ToolheadSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var printer: PrinterLink
    let plate: PlateInfo

    var body: some View {
        Section {
            ForEach(plate.filaments, id: \.self) { f in
                HStack {
                    Circle().fill(model.color(of: f)).frame(width: 14, height: 14).overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 0.5))
                    Text("F\(f) \(filamentType(f))").font(.subheadline)
                    Spacer()
                    Picker("Head", selection: Binding(get: { model.tool(for: f) ?? -1 }, set: { if $0 >= 0 { model.setTool($0, for: f) } })) {
                        if model.tool(for: f) == nil { Text("Choose a head").tag(-1) }
                        ForEach(0..<max(1, model.target.tools), id: \.self) { t in
                            Text(headLabel(t)).tag(t)
                        }
                    }
                    .labelsHidden()
                }
            }
            if plate.filaments.count > model.target.tools {
                Label("This plate uses \(plate.filaments.count) colours and the \(model.target.shortName) has \(model.target.tools) heads. Colours that share a head print in that head's filament.",
                      systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Toolheads")
        } footer: {
            Text(printer.toolheads.contains(where: { $0.loaded })
                 ? "Matched to the filament loaded in each head. Changing a head means slicing again."
                 : "Connect the \(model.target.shortName) to match colours to what's loaded in each head.")
        }
        .onAppear(perform: suggest)
        .onChange(of: printer.toolheads) { _, _ in suggest() }
        .onChange(of: model.plateIndex) { _, _ in suggest() }
    }

    func filamentType(_ f: Int) -> String {
        guard let p = model.project, f - 1 < p.filaments.count else { return "" }
        return p.filaments[f - 1].type
    }

    func headLabel(_ t: Int) -> String {
        if let h = printer.toolheads.first(where: { $0.id == t }) { return "Head \(t + 1) · \(h.shortSummary)" }
        return "Head \(t + 1)"
    }

    func suggest() {
        guard !model.toolMapIsCustom, let p = model.project else { return }
        let fs = plate.filaments.map { f in
            (index: f, color: f - 1 < model.options.colors.count ? model.options.colors[f - 1] : "#888888",
             type: f - 1 < p.filaments.count ? p.filaments[f - 1].type : "PLA")
        }
        model.applySuggestedToolMap(printer.suggestToolMap(filaments: fs, tools: model.target.tools))
    }
}

/// Saved printers: pick the one to slice for and print on, add or edit them.
struct PrinterEditor: View {
    @EnvironmentObject var link: PrinterLink
    @Environment(\.dismiss) private var dismiss
    let original: SavedPrinter?
    @State private var modelID: String
    @State private var name: String
    @State private var host: String
    @State private var serial: String
    @State private var port: String
    @State private var secret = ""

    init(printer: SavedPrinter?) {
        original = printer
        _modelID = State(initialValue: printer?.modelID ?? PrinterCatalog.fallbackID)
        _name = State(initialValue: printer?.name ?? "")
        _host = State(initialValue: printer?.host ?? "")
        _serial = State(initialValue: printer?.serial ?? "")
        _port = State(initialValue: String(printer?.port ?? 7125))
    }

    var model: PrinterModel? { PrinterCatalog.model(modelID) }
    var isBambu: Bool { model?.isBambu ?? true }
    var hasSecret: Bool { original.map { link.hasSecret($0) } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section("Printer") {
                    Picker("Model", selection: $modelID) {
                        ForEach(PrinterCatalog.vendors, id: \.self) { v in
                            Section(v) {
                                ForEach(PrinterCatalog.models.filter { $0.vendor == v }) { Text($0.shortName).tag($0.id) }
                            }
                        }
                    }
                    TextField("Name", text: $name, prompt: Text(model?.name ?? "Name"))
                }
                Section {
                    TextField("IP address, e.g. 192.168.1.50", text: $host)
                        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if isBambu {
                        TextField("Serial number", text: $serial).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        SecureField(hasSecret ? "Access code (saved)" : "Access code", text: $secret).keyboardType(.asciiCapable)
                    } else {
                        TextField("Port", text: $port).keyboardType(.numberPad)
                        SecureField(hasSecret ? "API key (saved)" : "API key (only if you set one)", text: $secret)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: {
                    Text("On your Wi-Fi")
                } footer: {
                    Text(isBambu
                         ? "On the printer's screen, the network settings show the IP address and, in LAN-only mode, the access code; the device page shows the serial number. The access code stays in your iPhone's Keychain."
                         : "The \(model?.shortName ?? "printer")'s screen shows its IP address in the Wi-Fi settings. Duo Slicer talks to it through Moonraker on port 7125.")
                }
                Section("One-time printer setup") {
                    if isBambu {
                        Label("Update the printer to its latest firmware", systemImage: "1.circle")
                        Label("Insert a microSD card (prints are stored on it)", systemImage: "2.circle")
                        Label("Turn on LAN-only mode, then restart the printer", systemImage: "3.circle")
                        Label("Turn on Developer mode in the same menu", systemImage: "4.circle")
                    } else {
                        Label("Connect the \(model?.shortName ?? "printer") to the same Wi-Fi as your iPhone", systemImage: "1.circle")
                        Label("Load filament in each head so colours can be matched", systemImage: "2.circle")
                        Label("Put the smooth PEI plate on the bed", systemImage: "3.circle")
                    }
                }
                .font(.subheadline)
                if let original {
                    Section {
                        Button("Remove printer", role: .destructive) {
                            link.remove(original)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(original == nil ? "Add printer" : "Edit printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var p = original ?? SavedPrinter(modelID: modelID, name: name, host: host)
                        p.modelID = modelID
                        p.name = name
                        p.host = host
                        p.serial = isBambu ? serial : ""
                        p.port = Int(port) ?? 7125
                        link.upsert(p, secret: secret.isEmpty ? nil : secret)
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || (isBambu && (serial.isEmpty || (!hasSecret && secret.isEmpty))))
                }
            }
        }
    }
}
