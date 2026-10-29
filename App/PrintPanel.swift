import SwiftUI

struct PrintPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var printer: PrinterLink
    @State private var mapping: [Int: Int] = [:]
    @State private var opts = StartOptions()
    @State private var bedClear = false
    @State private var sending = false
    @State private var showSetup = false
    @State private var confirmStop = false

    var body: some View {
        List {
            Section {
                Button { showSetup = true } label: { PrinterStatusRow() }
                if printer.connected && printer.isBusy {
                    if printer.state == "RUNNING" || printer.state == "PAUSE" {
                        ProgressView(value: Double(printer.percent) / 100) {
                            Text(printer.jobName).font(.footnote).lineLimit(1)
                        } currentValueLabel: {
                            Text("Layer \(printer.layer) of \(printer.totalLayers) · nozzle \(Int(printer.nozzle))°C · bed \(Int(printer.bed))°C").font(.caption2)
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
                if printer.printError != 0 {
                    Label("The printer reports error \(String(printer.printError, radix: 16).uppercased()). Check its screen.", systemImage: "exclamationmark.octagon")
                        .font(.footnote).foregroundStyle(.red)
                }
            } header: { Text("Printer") }

            if !model.sliceIsCurrent {
                Section {
                    SliceButton()
                } footer: {
                    Text("Slice plate \(model.plate?.id ?? 0) first; you'll pick spools and send it from here.")
                }
            } else if let s = model.slice {
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
                    Text(printer.trays.isEmpty ? "Connect the printer to see what's loaded in the AMS lite." : "Matched by colour and material. Change any you like.")
                }
                Section("Options") {
                    Toggle("Auto bed leveling", isOn: $opts.bedLeveling)
                    Toggle("Flow calibration", isOn: $opts.flowCalibration)
                    Toggle("Vibration compensation", isOn: $opts.vibrationCalibration)
                    Toggle("Timelapse", isOn: $opts.timelapse)
                }
                Section {
                    Toggle("The bed is clear and the \(shortBed(s.bedType ?? "")) is on", isOn: $bedClear)
                    if let p = printer.uploadProgress {
                        ProgressView(value: p) { Text("Uploading to the printer…").font(.footnote) }
                    }
                    Button {
                        Task { await send(s) }
                    } label: {
                        Label(sending ? "Sending…" : "Print plate \(s.plateId ?? 0) on A1", systemImage: "printer.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!bedClear || sending || !printer.connected || printer.isBusy)
                    if let r = printer.lastResult { Text(r).font(.footnote).foregroundStyle(.secondary) }
                } footer: {
                    Text(String(format: "%@ · %.1f g. The A1 heats, levels and purges for a few minutes before the first layer.", formatDuration(s.seconds ?? 0), s.grams ?? 0))
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showSetup) { PrinterSetupView() }
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
        default: return "plate"
        }
    }

    func remap() {
        guard let s = model.slice else { return }
        mapping = printer.suggestMapping(for: s.filaments ?? [])
    }

    func send(_ s: SliceSummary) async {
        sending = true
        defer { sending = false }
        guard let data = await model.slicedFile() else { model.errorMessage = "The sliced file is missing. Slice again."; return }
        do {
            try await printer.startPrint(file: data, summary: s, jobName: "\(model.fileName) \(model.plate?.name ?? "")", mapping: mapping, options: opts)
            bedClear = false
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

struct PrinterSetupView: View {
    @EnvironmentObject var printer: PrinterLink
    @Environment(\.dismiss) private var dismiss
    @State private var ip = ""
    @State private var serial = ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IP address, e.g. 192.168.1.50", text: $ip).keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Serial number", text: $serial).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    SecureField(printer.hasCode ? "Access code (saved)" : "Access code", text: $code).keyboardType(.numberPad)
                } header: {
                    Text("Bambu Lab A1")
                } footer: {
                    Text("On the printer: Settings → WLAN shows the IP, LAN-only Mode shows the access code, and Settings → Device shows the serial number. The access code is stored in your iPhone's Keychain.")
                }
                Section("One-time printer setup") {
                    Label("Update the A1 to firmware 01.05 or newer", systemImage: "1.circle")
                    Label("Insert a microSD card (prints are stored on it)", systemImage: "2.circle")
                    Label("Turn on LAN-only Mode, then restart the printer", systemImage: "3.circle")
                    Label("Turn on Developer Mode in the same menu", systemImage: "4.circle")
                }
                .font(.subheadline)
                Section {
                    LabeledContent("Status", value: printer.statusText)
                    if printer.connected {
                        ForEach(printer.trays) { t in
                            HStack {
                                Circle().fill(t.loaded && !t.color.isEmpty ? Color(hex: t.color) : .clear).overlay(Circle().stroke(.secondary)).frame(width: 14, height: 14)
                                Text(t.label)
                                Spacer()
                                Text(t.loaded ? t.name : "Empty").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        printer.save(ip: ip, serial: serial, code: code)
                        code = ""
                    }
                    .disabled(ip.isEmpty || serial.isEmpty || (!printer.hasCode && code.isEmpty))
                }
            }
            .onAppear {
                ip = printer.ip
                serial = printer.serial
            }
        }
    }
}
