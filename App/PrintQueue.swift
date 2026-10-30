import Combine
import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// One print waiting its turn: a plate of a saved copy of a project, sliced when a printer is ready for it.
struct QueueJob: Codable, Identifiable, Hashable {
    enum Status: String, Codable { case waiting, slicing, sending, printing, done, failed }

    var id = UUID().uuidString
    var project: String          // project name, for people
    var file: String             // the project as it was when queued (a copy in the queue folder)
    var plate: Int               // plate index in that file
    var plateNumber: Int         // the plate's number in the app ("Plate 2")
    var plateName: String
    var modelID: String          // printer model it's sliced for (the presets are that model's)
    var printerID: String?       // one particular printer, or nil: the first free printer of that model
    var options: PrintOptions
    var start = StartOptions()
    var status: Status = .waiting
    var message: String?
    var printedOn: String?       // the printer it went to
    var remote: String?          // its name on the printer (PrinterConnection.fileBase)
    var confirmed = false        // the printer reported printing it
    var added = Date()
    var started: Date?
    var finished: Date?
    var grams: Double?
    var seconds: Double?

    var plateLabel: String { plateName.isEmpty || plateName == "Plate \(plateNumber)" ? "Plate \(plateNumber)" : plateName }
    var title: String { "\(project) · \(plateLabel)" }
    var shortID: String { String(id.prefix(8)).lowercased() }
    var isActive: Bool { status == .slicing || status == .sending || status == .printing }
    var isFinished: Bool { status == .done || status == .failed }
}

/// A plate to queue.
struct QueuePlate {
    var index: Int
    var number: Int
    var name: String
    var picture: UIImage?
}

/// The print queue: prints from different projects, or several plates and copies of one, sent to printers as they come free.
/// A printer only gets its next print after someone says its bed is clear, since nothing takes finished prints off the bed.
/// The queue runs while Duo Slicer is open.
@MainActor
final class PrintQueue: ObservableObject {
    @Published private(set) var jobs: [QueueJob] = []
    @Published private(set) var running = false
    /// Printers someone said have a clear bed: each takes its next print.
    @Published private(set) var ready: Set<String> = []
    /// Printers a print is being sliced or sent for.
    @Published private(set) var preparing: Set<String> = []

    private weak var link: PrinterLink?
    private var observer: AnyCancellable?
    private var timer: Timer?
    /// After a failed send, wait a minute before trying that printer again.
    private var holdUntil: [String: Date] = [:]
    private var pictureCache: [String: UIImage] = [:]
    private let work = DispatchQueue(label: "duo.queue.slicer", qos: .utility)

    static let folder: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Queue", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private var listURL: URL { Self.folder.appendingPathComponent("queue.json") }

    init() { load() }

    func attach(_ link: PrinterLink) {
        guard self.link !== link else { return }
        self.link = link
        observer = link.objectWillChange
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.tick() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    // MARK: what's in it

    var waiting: [QueueJob] { jobs.filter { $0.status == .waiting } }
    var active: [QueueJob] { jobs.filter(\.isActive) }
    var finished: [QueueJob] { jobs.filter(\.isFinished) }
    var hasWork: Bool { jobs.contains { $0.status == .waiting || $0.isActive } }

    /// A job by its id or the short id Claude sees.
    func find(_ id: String) -> QueueJob? {
        let s = id.lowercased()
        return jobs.first { $0.id == id || $0.shortID == s }
    }

    /// Whether a printer can print this job (the printer it was queued for, or any printer of that model).
    func takes(_ c: PrinterConnection, _ j: QueueJob) -> Bool {
        j.printerID == c.id || (j.printerID == nil && j.modelID == c.printer.modelID)
    }

    /// The next waiting job a printer would take.
    func next(for c: PrinterConnection) -> QueueJob? {
        jobs.first { $0.status == .waiting && takes(c, $0) }
    }

    /// The job being sliced for, sent to or printed on a printer.
    func activeJob(on printerID: String) -> QueueJob? {
        jobs.first { $0.isActive && $0.printedOn == printerID }
    }

    /// A printer's part of the queue: what it's printing, then what it would print next.
    func list(for c: PrinterConnection) -> [QueueJob] {
        jobs.filter { ($0.isActive && $0.printedOn == c.id) || ($0.status == .waiting && takes(c, $0)) }
    }

    /// Free, with more to print, but nobody has said its bed is clear yet.
    func needsBedCheck(_ c: PrinterConnection) -> Bool {
        c.isIdle && !ready.contains(c.id) && activeJob(on: c.id) == nil && next(for: c) != nil
    }

    /// Printers that would take a print right now if their bed were clear.
    var printersToCheck: [PrinterConnection] { (link?.all ?? []).filter(needsBedCheck) }

    func image(_ job: QueueJob) -> UIImage? {
        if let i = pictureCache[job.id] { return i }
        guard let i = UIImage(contentsOfFile: imageURL(job.id).path) else { return nil }
        pictureCache[job.id] = i
        return i
    }

    private func imageURL(_ id: String) -> URL { Self.folder.appendingPathComponent("\(id).png") }

    // MARK: changing it

    /// Queue plates of a project (`data` is a copy of it as it is now, edits included), `copies` times each.
    @discardableResult
    func add(project: String, data: Data, plates: [QueuePlate], copies: Int, modelID: String, printerID: String?,
             options: PrintOptions, currentPlate: Int, start: StartOptions) -> Int {
        guard !plates.isEmpty, copies > 0 else { return 0 }
        let file = "\(UUID().uuidString).3mf"
        do { try data.write(to: Self.folder.appendingPathComponent(file)) } catch { return 0 }
        var png: [Int: Data] = [:]
        for p in plates { if let d = p.picture?.pngData() { png[p.index] = d } }
        var added = 0
        for _ in 0..<copies {
            for p in plates {
                var o = options
                // heads chosen by hand were for the plate on screen; other plates get the heads loaded with the closest colours
                if p.index != currentPlate { o.toolMap = [] }
                let job = QueueJob(project: project, file: file, plate: p.index, plateNumber: p.number, plateName: p.name,
                                   modelID: modelID, printerID: printerID, options: o, start: start)
                if let d = png[p.index] { try? d.write(to: imageURL(job.id)) }
                jobs.append(job)
                added += 1
            }
        }
        save()
        tick()
        return added
    }

    /// Remove jobs (one that's printing keeps printing; the queue just stops following it).
    func remove(_ ids: Set<String>) {
        for id in ids { QueueNotifier.cancel(id) }
        jobs.removeAll { ids.contains($0.id) && $0.status != .slicing && $0.status != .sending }
        cleanFiles()
        save()
    }

    /// Reorder the waiting jobs among themselves; the others keep their places.
    func moveWaiting(from: IndexSet, to: Int) {
        var w = waiting
        w.move(fromOffsets: from, toOffset: to)
        var it = w.makeIterator()
        for i in jobs.indices where jobs[i].status == .waiting {
            if let n = it.next() { jobs[i] = n }
        }
        save()
    }

    /// Make a waiting job the next one out.
    func printNext(_ id: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id && $0.status == .waiting }) else { return }
        let j = jobs.remove(at: i)
        let first = jobs.firstIndex { $0.status == .waiting } ?? jobs.endIndex
        jobs.insert(j, at: first)
        save()
    }

    func retry(_ id: String) {
        update(id) {
            $0.status = .waiting
            $0.message = nil
            $0.printedOn = nil
            $0.remote = nil
            $0.confirmed = false
            $0.started = nil
            $0.finished = nil
        }
        tick()
    }

    /// The same print again, at the end of the queue.
    func printAgain(_ id: String) {
        guard let j = find(id) else { return }
        var copy = QueueJob(project: j.project, file: j.file, plate: j.plate, plateNumber: j.plateNumber, plateName: j.plateName,
                            modelID: j.modelID, printerID: j.printerID, options: j.options, start: j.start)
        copy.seconds = j.seconds
        copy.grams = j.grams
        try? FileManager.default.copyItem(at: imageURL(j.id), to: imageURL(copy.id))
        jobs.append(copy)
        save()
        tick()
    }

    func markDone(_ id: String) {
        guard let j = find(id), j.status != .slicing, j.status != .sending else { return }
        finish(j.id, ok: true)
    }

    func clearFinished() {
        jobs.removeAll(where: \.isFinished)
        cleanFiles()
        save()
    }

    /// Someone checked the bed: this printer takes its next print.
    func bedIsClear(_ printerID: String) {
        ready.insert(printerID)
        holdUntil[printerID] = nil
        tick()
    }

    /// Start (or resume) the queue. `clear`: printers whose bed someone just checked.
    func start(clear: [String]) {
        ready.formUnion(clear)
        for p in clear { holdUntil[p] = nil }
        running = true
        save()
        if !DemoMode.isOn { QueueNotifier.ask() }
        tick()
    }

    /// No new prints go out; prints already sent carry on.
    func pause() {
        running = false
        save()
    }

    /// Empty the queue (demo and tests).
    func reset() {
        jobs.removeAll { $0.status != .slicing && $0.status != .sending }
        ready = []
        running = false
        cleanFiles()
        save()
    }

    private func update(_ id: String, _ change: (inout QueueJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        save()
    }

    private func cleanFiles() {
        let keep = Set(jobs.map(\.file)).union(jobs.map { "\($0.id).png" }).union(["queue.json"])
        for f in (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? [] where !keep.contains(f) {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(f))
        }
        let ids = Set(jobs.map(\.id))
        pictureCache = pictureCache.filter { ids.contains($0.key) }
    }

    // MARK: saving

    private struct Saved: Codable {
        var jobs: [QueueJob]
        var running: Bool
    }

    private func load() {
        guard let d = try? Data(contentsOf: listURL), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        jobs = s.jobs
        // prints interrupted while slicing or sending wait again
        for i in jobs.indices where jobs[i].status == .slicing || jobs[i].status == .sending {
            jobs[i].status = .waiting
            jobs[i].printedOn = nil
        }
        running = s.running
    }

    private func save() {
        if let d = try? JSONEncoder().encode(Saved(jobs: jobs, running: running)) { try? d.write(to: listURL, options: .atomic) }
    }

    // MARK: running it

    /// Follow the prints that went out, then send the next print to each free printer whose bed is clear.
    func tick() {
        guard let link else { return }
        track(link)
        guard running else { return }
        for c in link.all where canStart(on: c) {
            guard let job = next(for: c) else { continue }
            preparing.insert(c.id)
            ready.remove(c.id)
            // claimed now, so another free printer of the same model doesn't take the same job in this pass
            update(job.id) {
                $0.status = .slicing
                $0.message = nil
                $0.printedOn = c.id
            }
            Task { await self.run(job.id, on: c) }
        }
        if !hasWork {
            running = false
            save()
        }
    }

    private func canStart(on c: PrinterConnection) -> Bool {
        c.isIdle && c.errorText == nil && ready.contains(c.id) && !preparing.contains(c.id)
            && (holdUntil[c.id] ?? .distantPast) < Date() && activeJob(on: c.id) == nil
    }

    /// Prints that went out: done when the printer reports it finished, failed when it stopped or never started it.
    private func track(_ link: PrinterLink) {
        for job in jobs where job.status == .printing {
            guard let pid = job.printedOn else { continue }
            guard let c = link.connection(pid) else {
                finish(job.id, ok: false, message: "That printer was removed from Duo Slicer.")
                continue
            }
            guard c.connected else { continue }
            let started = job.started ?? .distantPast
            let age = Date().timeIntervalSince(started)
            // the printer's job name starts with the name the print was sent under
            let ours = job.remote.map { !c.jobName.isEmpty && c.jobName.hasPrefix($0) } ?? false
            // busy by the printer's own report since it was sent (a copy of the same plate has the same name, so the
            // name alone could be the previous copy's)
            let seenBusy = ours && (c.reportedBusyAt ?? .distantPast) > started
            if seenBusy && !job.confirmed { update(job.id) { $0.confirmed = true } }
            let confirmed = job.confirmed || seenBusy
            switch c.state {
            case "FINISH":
                if confirmed || (ours && age > 180) {
                    finish(job.id, ok: true)
                } else if age > 240 {
                    finish(job.id, ok: false, message: notStarted(c))
                }
            case "FAILED":
                if confirmed || (ours && age > 180) {
                    finish(job.id, ok: false, message: c.errorText ?? "The print was stopped on the \(c.printer.name).")
                } else if age > 240 {
                    finish(job.id, ok: false, message: notStarted(c))
                }
            case "IDLE":
                if confirmed {
                    finish(job.id, ok: true)
                } else if age > 240 {
                    finish(job.id, ok: false, message: notStarted(c))
                }
            default:
                break
            }
        }
    }

    private func notStarted(_ c: PrinterConnection) -> String {
        "The \(c.printer.name) didn't start this print. Check its screen, then retry."
    }

    private func finish(_ id: String, ok: Bool, message: String? = nil) {
        update(id) {
            $0.status = ok ? .done : .failed
            $0.finished = Date()
            $0.message = message
        }
        QueueNotifier.cancel(id)
    }

    /// Slice a job for a printer and send it.
    private func run(_ id: String, on c: PrinterConnection) async {
        defer {
            preparing.remove(c.id)
            tick()
        }
        guard let job = find(id) else { return }
        update(id) {
            $0.status = .slicing
            $0.message = nil
            $0.printedOn = c.id
        }
        guard let data = try? Data(contentsOf: Self.folder.appendingPathComponent(job.file)) else {
            return failed(id, "The copy of the project for this print is missing.", printer: c)
        }
        let model = PrinterCatalog.model(job.modelID)
        let eng = SlicerEngine()
        let modelID = job.modelID
        let opened: Result<ProjectInfo, Error> = await onWork(eng) { e in
            do {
                try e.setPrinter(modelID)
                return .success(try e.open(data))
            } catch {
                return .failure(error)
            }
        }
        let info: ProjectInfo
        switch opened {
        case .failure(let e): return failed(id, e.localizedDescription, printer: c)
        case .success(let i): info = i
        }
        guard let plate = info.plates.first(where: { $0.id == job.plateNumber }) ?? info.plates[safe: job.plate], !plate.isEmpty else {
            return failed(id, "That plate isn't in the project any more.", printer: c)
        }
        var options = job.options
        if model?.isToolChanger == true && !options.toolMap.contains(where: { $0 >= 0 }) {
            // heads with the closest loaded colours, as the Print panel would pick them
            let colors = options.colors
            let fil = plate.filaments.map { f in
                (index: f, color: colors[safe: f - 1] ?? info.filaments[safe: f - 1]?.color ?? "#888888",
                 type: info.filaments[safe: f - 1]?.type ?? "PLA")
            }
            let map = c.suggestToolMap(filaments: fil, tools: model?.tools ?? 4)
            var tm = Array(repeating: -1, count: info.filaments.count)
            for (f, t) in map where f >= 1 && f <= tm.count { tm[f - 1] = t }
            options.toolMap = tm
        }
        let thumbs = pictures(for: job, toolChanger: model?.isToolChanger == true)
        let opts = options
        let plateIndex = plate.index
        let sliced: (SliceSummary, Data?) = await onWork(eng) { e in
            let s = e.slice(plate: plateIndex, options: opts, thumbnails: thumbs) { _ in }
            return (s, s.error == nil ? e.slicedFile() : nil)
        }
        guard sliced.0.error == nil, let file = sliced.1 else {
            return failed(id, sliced.0.error ?? "Slicing failed.", printer: c)
        }
        let summary = sliced.0
        // paused meanwhile, or someone started a print on it by hand: this one waits again
        guard running, c.isIdle else {
            requeue(id, nil)
            if c.isIdle { ready.insert(c.id) }
            return
        }
        update(id) {
            $0.status = .sending
            $0.grams = summary.grams
            $0.seconds = summary.seconds
        }
        let mapping = c.model?.isBambu == true ? c.suggestMapping(for: summary.filaments ?? []) : [:]
        let name = "\(job.project) \(job.plateLabel)"
        do {
            try await c.startPrint(file: file, summary: summary, jobName: name, mapping: mapping, options: job.start)
            update(id) {
                $0.status = .printing
                $0.started = Date()
                $0.confirmed = false
                $0.remote = PrinterConnection.fileBase(name)
            }
            if let j = find(id), next(for: c) != nil {
                // the app is usually closed by the time a print ends: remind the user to clear the bed for the next one
                QueueNotifier.schedule(j, printer: c.printer.name, after: (summary.seconds ?? 0) + 420)
            }
        } catch {
            requeue(id, "Couldn't send it to the \(c.printer.name): \(error.localizedDescription) Trying again in a minute.")
            ready.insert(c.id)
            holdUntil[c.id] = Date().addingTimeInterval(60)
        }
    }

    /// The job itself can't be printed (its file, its plate, slicing): it fails, and the printer's bed is still clear.
    private func failed(_ id: String, _ message: String, printer c: PrinterConnection) {
        finish(id, ok: false, message: message)
        update(id) { $0.printedOn = nil }
        ready.insert(c.id)
    }

    private func requeue(_ id: String, _ message: String?) {
        update(id) {
            $0.status = .waiting
            $0.message = message
            $0.printedOn = nil
        }
    }

    private func onWork<T>(_ eng: SlicerEngine, _ f: @escaping (SlicerEngine) -> T) async -> T {
        await withCheckedContinuation { cont in
            work.async { cont.resume(returning: f(eng)) }
        }
    }

    /// The plate picture saved with the job, at the sizes the printer shows.
    private func pictures(for job: QueueJob, toolChanger: Bool) -> [Data] {
        guard let img = image(job) else { return [] }
        return (toolChanger ? [48, 300] : [512]).map { side in
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            fmt.opaque = false
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).pngData { _ in
                let s = img.size
                let k = min(CGFloat(side) / max(1, s.width), CGFloat(side) / max(1, s.height))
                let w = s.width * k, h = s.height * k
                img.draw(in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
            }
        }
    }
}

/// A reminder when a queued print should be done and the next one is waiting for a clear bed.
enum QueueNotifier {
    static func ask() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func schedule(_ job: QueueJob, printer: String, after seconds: Double) {
        let content = UNMutableNotificationContent()
        content.title = "\(printer) should be finishing"
        content.body = "\(job.title) is about done. Clear the bed, then open Duo Slicer to start the next print in the queue."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, seconds), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "queue.\(job.id)", content: content, trigger: trigger),
                                               withCompletionHandler: nil)
    }

    static func cancel(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["queue.\(id)"])
    }
}
