import SwiftUI

/// Sheets the Print panel, the project's ⋯ menu and the home screen open.
enum PrintSheet: String, Identifiable {
    case printers, addToQueue, queue
    var id: String { rawValue }
}

struct PrintSheetContent: View {
    @EnvironmentObject var model: AppModel
    let sheet: PrintSheet
    var start = StartOptions()

    var body: some View {
        switch sheet {
        case .printers: PrintersView()
        case .addToQueue: AddToQueueView(start: start, plate: model.plateIndex)
        case .queue: QueueView()
        }
    }
}

/// The print queue: what's printing where, what's next, and the bed checks between prints.
struct QueueView: View {
    @EnvironmentObject var queue: PrintQueue
    @EnvironmentObject var link: PrinterLink
    @Environment(\.dismiss) private var dismiss
    @State private var confirmStart = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    controls
                } footer: {
                    Text("Prints go out one per printer. After each print, its printer waits until you say the bed is clear. The queue runs while Duo Slicer is open.")
                }
                if !queuePrinters.isEmpty {
                    Section("Printers") {
                        ForEach(queuePrinters) { QueuePrinterRow(connection: $0) }
                    }
                }
                if !queue.active.isEmpty {
                    Section("Now") {
                        ForEach(queue.active) { QueueJobRow(job: $0) }
                    }
                }
                Section {
                    if queue.waiting.isEmpty {
                        Text("Nothing waiting. In a project, open Print and choose Add to print queue.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(queue.waiting) { QueueJobRow(job: $0) }
                        .onMove { queue.moveWaiting(from: $0, to: $1) }
                } header: {
                    Text("Up next")
                }
                if !queue.finished.isEmpty {
                    Section {
                        ForEach(finishedNewestFirst) { QueueJobRow(job: $0) }
                        Button("Clear finished", role: .destructive) { queue.clearFinished() }
                    } header: {
                        Text("Finished")
                    }
                }
            }
            .navigationTitle("Print queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if queue.waiting.count > 1 {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
            }
            .confirmationDialog("Start the print queue?", isPresented: $confirmStart, titleVisibility: .visible) {
                let first = startCandidates
                if first.isEmpty {
                    Button("Start") { queue.start(clear: []) }
                } else {
                    Button(first.count == 1 ? "The bed is clear, start" : "The beds are clear, start") { queue.start(clear: first.map { $0.id }) }
                    if first.count > 1 {
                        Button("Start, I'll check each printer") { queue.start(clear: []) }
                    }
                }
            } message: {
                Text(startMessage)
            }
        }
    }

    var controls: some View {
        HStack(spacing: 12) {
            Image(systemName: queue.running ? "play.circle.fill" : "pause.circle")
                .font(.title)
                .foregroundStyle(queue.running ? Theme.accent : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(queue.running ? "Running" : (queue.hasWork ? "Not running" : "Empty")).font(.headline)
                Text(QueueSummaryRow.counts(queue)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if queue.running {
                Button("Pause") { queue.pause() }.buttonStyle(.bordered)
            } else {
                Button("Start") { confirmStart = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(queue.waiting.isEmpty)
            }
        }
    }

    /// Printers with a queued print on them or waiting for them.
    var queuePrinters: [PrinterConnection] {
        link.all.filter { queue.activeJob(on: $0.id) != nil || queue.next(for: $0) != nil }
    }

    var finishedNewestFirst: [QueueJob] {
        queue.finished.sorted { ($0.finished ?? $0.added) > ($1.finished ?? $1.added) }
    }

    /// Free printers that would take the first prints.
    var startCandidates: [PrinterConnection] { link.all.filter { queue.needsBedCheck($0) } }

    var startMessage: String {
        let first = startCandidates
        if first.isEmpty {
            return "No printer that can take these prints is free right now. Each printer starts its first print after you say its bed is clear."
        }
        let lines = first.map { c in "\(c.printer.name): \(queue.next(for: c)?.title ?? "")" }
        return "First prints:\n" + lines.joined(separator: "\n") + "\n\nMake sure each bed is clear and has the right build plate on."
    }
}

/// A printer in the queue: its state, and the bed check before its next print.
struct QueuePrinterRow: View {
    @EnvironmentObject var queue: PrintQueue
    @ObservedObject var connection: PrinterConnection

    var body: some View {
        let c = connection
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(dot).frame(width: 9, height: 9)
                Text(c.printer.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(PrinterCard.describe(c)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if queue.needsBedCheck(c) {
                if queue.running {
                    Button {
                        queue.bedIsClear(c.id)
                    } label: {
                        Label("Bed is clear: print \(queue.next(for: c)?.plateLabel ?? "the next one")", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("Next: \(queue.next(for: c)?.title ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            } else if queue.preparing.contains(c.id) {
                Label("Getting the next print ready…", systemImage: "gearshape.2").font(.caption).foregroundStyle(.secondary)
            } else if queue.ready.contains(c.id) {
                Text(c.isIdle ? "Bed checked. The next print goes out in a moment." : "Bed checked. Waiting for the printer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    var dot: Color {
        guard connection.connected else { return .secondary }
        if connection.errorText != nil { return .red }
        return connection.isBusy ? Theme.accent : .green
    }
}

/// One print in the queue.
struct QueueJobRow: View {
    @EnvironmentObject var queue: PrintQueue
    @EnvironmentObject var link: PrinterLink
    let job: QueueJob

    var body: some View {
        HStack(spacing: 12) {
            picture
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(targetLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let s = statusLine {
                    Text(s).font(.caption).foregroundStyle(statusColor).lineLimit(3)
                }
                if let p = progress {
                    ProgressView(value: p).tint(Theme.accent)
                }
            }
            Spacer(minLength: 0)
            if job.status == .slicing || job.status == .sending { ProgressView() }
        }
        .padding(.vertical, 2)
        .contextMenu { menu }
        .swipeActions(edge: .trailing) {
            if job.status != .slicing && job.status != .sending {
                Button(role: .destructive) { queue.remove([job.id]) } label: { Label("Remove", systemImage: "trash") }
            }
        }
        .swipeActions(edge: .leading) {
            if job.status == .failed { Button("Try again") { queue.retry(job.id) }.tint(Theme.accent) }
            if job.status == .waiting { Button("Print next") { queue.printNext(job.id) }.tint(Theme.accent) }
        }
    }

    var picture: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemFill))
            if let img = queue.image(job) {
                Image(uiImage: img).resizable().scaledToFit().padding(2)
            } else {
                Image(systemName: "cube").foregroundStyle(.secondary)
            }
        }
        .frame(width: 46, height: 46)
        .accessibilityHidden(true)
    }

    var connection: PrinterConnection? { job.printedOn.flatMap { link.connection($0) } }
    var printerName: String { connection?.printer.name ?? "the printer" }

    var targetLine: String {
        var parts: [String] = []
        if let pid = job.printerID {
            parts.append(link.connection(pid).map { "On \($0.printer.name)" } ?? "Its printer was removed")
        } else {
            let m = PrinterCatalog.model(job.modelID)?.shortName ?? job.modelID
            let any = link.printers.contains { $0.modelID == job.modelID }
            parts.append(any ? "Any \(m)" : "Any \(m) (none added yet)")
        }
        if let s = job.seconds { parts.append(formatDuration(s)) }
        if let g = job.grams { parts.append(String(format: "%.0f g", g)) }
        return parts.joined(separator: " · ")
    }

    var statusLine: String? {
        switch job.status {
        case .waiting:
            return job.message
        case .slicing:
            return "Slicing for \(printerName)…"
        case .sending:
            if let p = connection?.uploadProgress { return "Sending to \(printerName)… \(Int(p * 100))%" }
            return "Sending to \(printerName)…"
        case .printing:
            guard let c = connection else { return "Printing" }
            guard c.connected else { return "Printing on \(c.printer.name) (not connected right now)" }
            switch c.state {
            case "RUNNING": return "Printing on \(c.printer.name) · \(c.percent)% · \(formatDuration(Double(c.remainingMinutes) * 60)) left"
            case "PAUSE": return "Paused on \(c.printer.name) at \(c.percent)%"
            default: return "Starting on \(c.printer.name)…"
            }
        case .done:
            return "Printed on \(printerName)" + (job.finished.map { " · " + $0.formatted(date: .omitted, time: .shortened) } ?? "")
        case .failed:
            return job.message ?? "Didn't print"
        }
    }

    var statusColor: Color {
        switch job.status {
        case .failed: return .red
        case .waiting: return .orange
        default: return .secondary
        }
    }

    var progress: Double? {
        guard job.status == .printing, let c = connection, c.connected, c.state == "RUNNING" || c.state == "PAUSE" else { return nil }
        return Double(c.percent) / 100
    }

    @ViewBuilder var menu: some View {
        switch job.status {
        case .waiting:
            Button { queue.printNext(job.id) } label: { Label("Print next", systemImage: "arrow.up.to.line") }
        case .failed:
            Button { queue.retry(job.id) } label: { Label("Try again", systemImage: "arrow.clockwise") }
            Button { queue.markDone(job.id) } label: { Label("Mark as printed", systemImage: "checkmark") }
        case .printing:
            Button { queue.markDone(job.id) } label: { Label("Mark as printed", systemImage: "checkmark") }
        case .done:
            Button { queue.printAgain(job.id) } label: { Label("Print again", systemImage: "plus.square.on.square") }
        default:
            EmptyView()
        }
        if job.status != .slicing && job.status != .sending {
            Button(role: .destructive) {
                queue.remove([job.id])
            } label: {
                Label(job.status == .printing ? "Stop following this print" : "Remove", systemImage: "trash")
            }
        }
    }
}

/// A printer's part of the queue, on its page.
struct QueueForPrinterSection: View {
    @EnvironmentObject var queue: PrintQueue
    @EnvironmentObject var link: PrinterLink
    let printerID: String

    var body: some View {
        if let c = link.connection(printerID) {
            let jobs = queue.list(for: c)
            if !jobs.isEmpty {
                Section {
                    if queue.running && queue.needsBedCheck(c) {
                        Button {
                            queue.bedIsClear(c.id)
                        } label: {
                            Label("The bed is clear: print the next one", systemImage: "checkmark.circle")
                        }
                    }
                    ForEach(jobs.prefix(4)) { QueueJobRow(job: $0) }
                    if jobs.count > 4 {
                        Text("and \(jobs.count - 4) more").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Print queue")
                } footer: {
                    if !queue.running { Text("The queue isn't running. Start it from Print queue.") }
                }
            }
        }
    }
}

/// The print queue at a glance (home screen, Print panel, printers).
struct QueueSummaryRow: View {
    @EnvironmentObject var queue: PrintQueue

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.number").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Print queue").foregroundStyle(.primary)
                Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
    }

    var line: String {
        let check = queue.running ? queue.printersToCheck : []
        if let c = check.first {
            return check.count == 1 ? "\(c.printer.name) is waiting for its bed to be cleared" : "\(check.count) printers are waiting for their beds to be cleared"
        }
        return Self.counts(queue)
    }

    static func counts(_ q: PrintQueue) -> String {
        let a = q.active.count, w = q.waiting.count
        if a == 0 && w == 0 {
            return q.finished.isEmpty ? "Line up plates from one or more projects to print one after another." : "\(q.finished.count) finished"
        }
        var parts: [String] = []
        if a > 0 { parts.append("\(a) printing") }
        if w > 0 { parts.append("\(w) waiting") }
        if !q.running { parts.append("not started") }
        return parts.joined(separator: " · ")
    }
}

/// Queue plates of the open project: this plate, several or all of them, any number of copies, for one printer or
/// whichever printer of that model is free first.
struct AddToQueueView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var queue: PrintQueue
    @EnvironmentObject var link: PrinterLink
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<Int>
    @State private var copies = 1
    @State private var target = "any"
    @State private var start: StartOptions
    @State private var adding = false

    init(start: StartOptions, plate: Int) {
        _start = State(initialValue: start)
        _chosen = State(initialValue: [plate])
    }

    var plates: [PlateInfo] { (model.project?.plates ?? []).filter { !$0.isEmpty } }
    var printers: [SavedPrinter] { link.printers.filter { $0.modelID == model.target.id } }
    var count: Int { chosen.count * copies }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(plates) { p in
                        Button {
                            if chosen.contains(p.index) { chosen.remove(p.index) } else { chosen.insert(p.index) }
                        } label: {
                            HStack(spacing: 12) {
                                plateImage(p)
                                Text(model.plateLabel(p.index)).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: chosen.contains(p.index) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(chosen.contains(p.index) ? Theme.accent : Color.secondary)
                            }
                        }
                    }
                    if plates.count > 1 {
                        Button(chosen.count == plates.count ? "Only this plate" : "All plates") {
                            chosen = chosen.count == plates.count ? [model.plateIndex] : Set(plates.map(\.index))
                        }
                    }
                } header: {
                    Text("Plates")
                }
                Section {
                    Stepper(value: $copies, in: 1...50) { Text(copies == 1 ? "1 copy" : "\(copies) copies") }
                } footer: {
                    if copies > 1 { Text("Each copy is its own print; the printer waits for a clear bed between them.") }
                }
                Section {
                    Picker("Print on", selection: $target) {
                        Text("Any \(model.target.shortName)").tag("any")
                        ForEach(printers) { Text($0.name).tag($0.id) }
                    }
                } header: {
                    Text("Printer")
                } footer: {
                    Text(printers.isEmpty
                         ? "No \(model.target.shortName) is added yet; these prints wait until you add one."
                         : "Set up for the \(model.target.name). To queue for another model, select one of those printers first.")
                }
                if model.target.isBambu {
                    Section("Print options") {
                        Toggle("Auto bed leveling", isOn: $start.bedLeveling)
                        Toggle("Flow calibration", isOn: $start.flowCalibration)
                        Toggle("Vibration compensation", isOn: $start.vibrationCalibration)
                        Toggle("Timelapse", isOn: $start.timelapse)
                    }
                }
                Section {
                    Button {
                        Task { await add() }
                    } label: {
                        Text(adding ? "Adding…" : (count == 1 ? "Add 1 print to the queue" : "Add \(count) prints to the queue"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || adding)
                } footer: {
                    Text("The queue keeps a copy of the project as it is now, with your changes and settings, and slices each plate when a printer is ready for it.")
                }
            }
            .navigationTitle("Add to print queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    func plateImage(_ p: PlateInfo) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemFill))
            if let img = model.thumbnails[p.index] { Image(uiImage: img).resizable().scaledToFit().padding(2) }
        }
        .frame(width: 40, height: 40)
    }

    func add() async {
        adding = true
        defer { adding = false }
        guard let info = model.project, let data = await model.exportProjectData() else {
            model.errorMessage = "Couldn't save a copy of the project for the queue."
            return
        }
        let list = info.plates.filter { chosen.contains($0.index) && !$0.isEmpty }.map {
            QueuePlate(index: $0.index, number: $0.id, name: $0.name, picture: model.thumbnails[$0.index])
        }
        let n = queue.add(project: model.fileName, data: data, plates: list, copies: copies, modelID: model.target.id,
                          printerID: target == "any" ? nil : target, options: model.options, currentPlate: model.plateIndex, start: start)
        model.say(n == 1 ? "Added 1 print to the queue" : "Added \(n) prints to the queue")
        dismiss()
    }
}
