import SwiftUI

/// Print in one place: slices the plate when it needs it, shows what it will take, matches spools or heads, and starts
/// the print with one tap ("the bed is clear" is part of that button). Opened from the Print button on the project
/// screen and from Print on a project card at home.
struct PrintFlowView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var printer: PrinterLink
    @Environment(\.dismiss) private var dismiss
    @State private var mapping: [Int: Int] = [:]
    @State private var sending = false
    @State private var sent = false
    @State private var sliceError: String?
    @State private var sendError: String?
    @State private var showOptions = false
    @State private var sheet: PrintSheet?
    @State private var addPrinter = false
    @State private var shareURL: URL?
    @State private var confirmStop = false
    @AppStorage("start.bedLeveling") private var bedLeveling = true
    @AppStorage("start.flowCalibration") private var flowCalibration = true
    @AppStorage("start.vibrationCalibration") private var vibrationCalibration = true
    @AppStorage("start.timelapse") private var timelapse = false

    var start: StartOptions {
        StartOptions(bedLeveling: bedLeveling, flowCalibration: flowCalibration, vibrationCalibration: vibrationCalibration, timelapse: timelapse)
    }

    var body: some View {
        NavigationStack {
            List {
                header
                // tool changers: heads are matched first (before slicing), since changing a head means slicing again
                if !sent, model.target.isToolChanger, let p = model.plate, !p.isEmpty {
                    ToolheadSection(plate: p)
                }
                if sent {
                    sentSection
                } else if let e = sliceError {
                    Section {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.subheadline)
                        Button("Try again") { sliceError = nil; Task { await sliceIfNeeded() } }
                    }
                } else if model.plate?.isEmpty ?? true {
                    Section { Text("This plate is empty. Pick a plate with objects on it.").foregroundStyle(.secondary) }
                } else if model.slicing || !model.sliceIsCurrent {
                    slicingSection
                } else if let s = model.slice {
                    summary(s)
                    if !model.target.isToolChanger {
                        spools(s)
                        optionsSection
                    }
                    actionSection(s)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(sent ? "Printing" : "Print")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $sheet) { s in PrintSheetContent(sheet: s, start: start) }
            .sheet(isPresented: $addPrinter) { AddPrinterView() }
            .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { shareURL = $0?.url })) { item in
                ShareSheet(items: [item.url])
            }
            .confirmationDialog("Stop this print?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop print", role: .destructive) { printer.send("stop") }
            } message: {
                Text("It can't be resumed after stopping.")
            }
        }
        .task { await sliceIfNeeded() }
        .onChange(of: model.sliceIsCurrent) { _, current in
            // a change of printer, head or setting drops the slice: slice again
            if !current && !model.slicing && !sent { Task { await sliceIfNeeded() } }
            if current { remap() }
        }
        .onChange(of: printer.trays) { _, _ in if mapping.isEmpty || mapping.values.allSatisfy({ $0 == 254 }) { remap() } }
    }

    // MARK: sections

    var header: some View {
        Section {
            HStack(spacing: 14) {
                Group {
                    if let img = model.thumbnails[model.plateIndex] {
                        Image(uiImage: img).resizable().scaledToFit()
                    } else {
                        Image(systemName: "cube.transparent").font(.title).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.fileName).font(.headline).lineLimit(1)
                    Text(model.plateLabel(model.plateIndex)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 4) {
                        ForEach(model.plate?.filaments ?? [], id: \.self) { ColorDot(color: model.color(of: $0), size: 10) }
                        Text(presetDisplayName(model.options.process)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 4)
            printerRow
        }
    }

    @ViewBuilder var printerRow: some View {
        if printer.printers.count > 1 {
            Picker(selection: Binding(get: { printer.activeID ?? "" }, set: { if !$0.isEmpty { printer.select($0) } })) {
                ForEach(printer.printers) { p in Text(p.name).tag(p.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "printer").foregroundStyle(Theme.accent)
                    printerState
                }
                .accessibilityLabel("Printer")
            }
            .pickerStyle(.menu)
        } else if printer.isConfigured {
            HStack {
                Label(printer.active?.name ?? "Printer", systemImage: "printer")
                Spacer()
                printerState
            }
        } else {
            Button { addPrinter = true } label: {
                Label("Add your printer", systemImage: "plus.circle.fill")
            }
        }
    }

    var printerState: some View {
        let (text, color): (String, Color) = {
            guard printer.connected else { return (printer.isConfigured ? "Connecting…" : "No printer", .secondary) }
            switch printer.state {
            case "RUNNING": return ("Printing \(printer.percent)%", Theme.accent2)
            case "PAUSE": return ("Paused", Theme.warm)
            case "PREPARE": return ("Starting", Theme.accent2)
            default: return ("Ready", .green)
            }
        }()
        return StatusPill(text: text, color: color)
    }

    var slicingSection: some View {
        Section {
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color(.tertiarySystemFill), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: max(0.02, model.sliceProgress))
                        .stroke(Theme.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.2), value: model.sliceProgress)
                    Text("\(Int(model.sliceProgress * 100))%").font(.headline.monospacedDigit())
                }
                .frame(width: 84, height: 84)
                Text("Slicing for the \(model.target.shortName)…").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    func summary(_ s: SliceSummary) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                StatTile(value: formatDuration(s.seconds ?? 0), label: "print time", icon: "clock")
                StatTile(value: String(format: "%.1f g", s.grams ?? 0), label: "filament", icon: "scalemass")
                StatTile(value: "\(s.layers ?? 0)", label: "layers", icon: "square.stack.3d.up")
                StatTile(value: (s.toolChanges ?? 0) > 0 ? "\(s.toolChanges ?? 0)" : "\(max(1, s.filaments?.count ?? 1))",
                         label: (s.toolChanges ?? 0) > 0 ? "colour changes" : ((s.filaments?.count ?? 1) == 1 ? "colour" : "colours"), icon: "paintpalette")
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .listRowBackground(Color.clear)
            ForEach(s.warnings ?? [], id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            Button {
                model.revealPreview += 1
                dismiss()
            } label: {
                Label("See the layers", systemImage: "square.stack.3d.up")
            }
        }
    }

    @ViewBuilder func spools(_ s: SliceSummary) -> some View {
        Section {
            ForEach(s.filaments ?? []) { f in
                HStack {
                    ColorDot(color: Color(hex: f.color), size: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("F\(f.id) \(f.type)").font(.subheadline)
                        Text(String(format: "%.1f g", f.grams)).font(.caption).foregroundStyle(.secondary)
                    }
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
    }

    var optionsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showOptions) {
                Toggle("Auto bed leveling", isOn: $bedLeveling)
                Toggle("Flow calibration", isOn: $flowCalibration)
                Toggle("Vibration compensation", isOn: $vibrationCalibration)
                Toggle("Timelapse", isOn: $timelapse)
            } label: {
                HStack {
                    Text("Print options")
                    Spacer()
                    Text(optionsSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .tint(Theme.accent)
        }
    }

    var optionsSummary: String {
        var on: [String] = []
        if bedLeveling { on.append("leveling") }
        if flowCalibration { on.append("flow") }
        if vibrationCalibration { on.append("vibration") }
        if timelapse { on.append("timelapse") }
        return on.isEmpty ? "none" : on.joined(separator: ", ")
    }

    func actionSection(_ s: SliceSummary) -> some View {
        Section {
            VStack(spacing: 10) {
                if printer.isConfigured {
                    Button {
                        Task { await send() }
                    } label: {
                        VStack(spacing: 2) {
                            Label(sending ? "Sending…" : "Start print", systemImage: "printer.fill")
                            Text("The bed is clear and the \(plateName(s.bedType ?? "")) is on").font(.caption).opacity(0.85)
                        }
                    }
                    .buttonStyle(GradientButtonStyle(height: 62))
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    if let p = printer.uploadProgress {
                        ProgressView(value: p) { Text("Uploading to the printer…").font(.footnote) }
                    }
                    if let why = blocked {
                        Text(why).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if let e = sendError {
                        Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
                    }
                } else {
                    Button { addPrinter = true } label: { Label("Add a printer to print over Wi-Fi", systemImage: "wifi") }
                        .buttonStyle(GradientButtonStyle())
                }
                HStack(spacing: 10) {
                    Button { sheet = .addToQueue } label: {
                        Label("Queue", systemImage: "text.badge.plus").frame(maxWidth: .infinity)
                    }
                    Button { Task { shareURL = await model.exportSlicedFile() } } label: {
                        Label("Share file", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
        } footer: {
            Text("The \(model.target.shortName) heats, levels and cleans the nozzle for a few minutes before the first layer.")
        }
    }

    var sentSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Theme.gradient)
                Text("Sent to \(printer.active?.name ?? "the printer")").font(.headline)
                Text("You can close this; progress shows on the Print tab and the home screen.").font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            PrintProgressRows(confirmStop: $confirmStop)
            Button("Done") { dismiss() }
                .buttonStyle(GradientButtonStyle(height: 48))
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
        }
    }

    // MARK: logic

    var canSend: Bool { !sending && printer.connected && !printer.isBusy && model.sliceIsCurrent }

    var blocked: String? {
        guard !sending else { return nil }
        if !printer.connected { return "Waiting for \(printer.active?.name ?? "the printer") to connect. It needs to be on and on this Wi-Fi." }
        if printer.isBusy { return "\(printer.active?.name ?? "The printer") is busy. Add this plate to the queue to print it next." }
        return nil
    }

    var trayOptions: [Tray] {
        printer.trays.isEmpty ? [Tray(id: 254, label: "External spool", type: "", color: "", name: "", loaded: true)] : printer.trays
    }

    func plateName(_ b: String) -> String {
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

    func sliceIfNeeded() async {
        guard !model.sliceIsCurrent, !model.slicing, model.plate?.isEmpty == false else {
            if model.sliceIsCurrent { remap() }
            return
        }
        await model.sliceCurrent(reveal: false)
        // keep the error on this sheet (an alert can't show over it)
        if let e = model.errorMessage {
            sliceError = e
            model.errorMessage = nil
        }
        remap()
    }

    func send() async {
        sending = true
        sendError = nil
        defer { sending = false }
        do {
            try await model.sendCurrentSlice(to: printer, mapping: mapping, options: start)
            withAnimation { sent = true }
        } catch {
            sendError = error.localizedDescription
        }
    }
}
