import Foundation
import SwiftUI
import UIKit

/// Launch arguments for screenshots and UI checks in the simulator (never used by the shipping flow):
///   -DuoDemo YES                 open the bundled demo project
///   -DuoDemoPrinter <model id>   slice for this printer model (e.g. snapmaker-u1)
///   -DuoDemoPlate <n>            select plate n (1-based)
///   -DuoDemoPanel <name>         plate, settings, preview or print
///   -DuoDemoSlice YES            slice before showing
///   -DuoDemoHome YES             stay on the home screen
///   -DuoDemoAddPrinter YES       open Add printer (searches the Wi-Fi) on the home screen
///   -DuoDemoScanHosts a,b        search these addresses instead of the Wi-Fi network (stand-in printers in CI)
///   -DuoDemoOrientation <o>      landscape or portrait (rotates the window, e.g. the iPhone Duo's inner screen held wide)
///   -DuoDemoShowFold YES         outline the crease the project layout is using
///   -DuoDemoInner wide|tall      draw the app at the iPhone Duo inner screen's size, crease in the middle
///                                (screenshots of the unfolded layouts on a large iPad simulator)
///   -DuoClaudeRelay <url>        connect "Use with Claude" to this relay (with -DuoClaudeSecret <key>)
///   -DuoDemoPrinters m@a,m@a     replace the saved printers with these (model id @ address; stand-in printers in CI) and connect
///   -DuoDemoQueue YES            fill the print queue from the demo project (a P1S plate, two U1 plates) and start it
///   -DuoDemoSheet <name>         open printers, queue or addToQueue
///   -DuoDemoOpenPrinter <model>  in the printers sheet, open that printer's page
enum DemoMode {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "DuoDemo") }
    static var showFold: Bool { UserDefaults.standard.bool(forKey: "DuoDemoShowFold") }
    static var fakeInnerSize: CGSize? {
        switch UserDefaults.standard.string(forKey: "DuoDemoInner")?.lowercased() {
        case "wide": return CGSize(width: 951, height: 669)
        case "tall": return CGSize(width: 669, height: 951)
        default: return nil
        }
    }
    static var panel: Panel? { UserDefaults.standard.string(forKey: "DuoDemoPanel").flatMap { Panel(rawValue: $0.capitalized) } }
    static var openPrinter: String? { UserDefaults.standard.string(forKey: "DuoDemoOpenPrinter") }

    /// Serial numbers of the CI stand-in printers (any serial works with them; these match the model).
    static func standInSerial(_ model: String) -> String {
        switch model {
        case "bambu-p1s": return "01P00A123456789"
        case "bambu-x1c": return "00M00A123456789"
        case "bambu-a1": return "03900A123456789"
        default: return "01S00C000000000"
        }
    }

    @MainActor
    static func run(model: AppModel, printer: PrinterLink, claude: ClaudeBridge, queue: PrintQueue) async {
        let d = UserDefaults.standard
        defer {
            if let o = d.string(forKey: "DuoDemoOrientation") { rotate(to: o) }
            if let sheet = d.string(forKey: "DuoDemoSheet") {
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    NotificationCenter.default.post(name: .duoDemoSheet, object: sheet)
                }
            }
        }
        if let relay = d.string(forKey: "DuoClaudeRelay"), !relay.isEmpty {
            claude.relayURL = relay
            claude.enabled = true
        }
        if let list = d.string(forKey: "DuoDemoPrinters"), !list.isEmpty {
            for p in printer.printers { printer.remove(p) }
            for (i, item) in list.split(separator: ",").enumerated() {
                let parts = item.split(separator: "@").map(String.init)
                guard parts.count == 2, let m = PrinterCatalog.model(parts[0]) else { continue }
                let p = SavedPrinter(modelID: m.id, name: "Workshop \(m.shortName)", host: parts[1], serial: m.isBambu ? standInSerial(m.id) : "")
                printer.upsert(p, secret: m.isBambu ? "12345678" : nil)
                if i == 0 { printer.select(p.id) }
            }
            printer.start()
        }
        if let id = d.string(forKey: "DuoDemoPrinter") {
            // a saved printer so the printer screens have something to show (it won't connect in the simulator)
            if let existing = printer.printers.first(where: { $0.modelID == id }) {
                printer.select(existing.id)
            } else {
                let m = PrinterCatalog.model(id)
                let p = SavedPrinter(modelID: id, name: "Workshop \(m?.shortName ?? "printer")", host: "192.168.1.42", serial: m?.isBambu == true ? "01S00C000000000" : "")
                printer.upsert(p, secret: m?.isBambu == true ? "12345678" : nil)
                printer.select(p.id)
            }
            await model.setTarget(id)
        }
        guard !d.bool(forKey: "DuoDemoHome"),
              let url = Bundle.main.url(forResource: "demo", withExtension: "3mf"),
              let data = try? Data(contentsOf: url) else { return }
        await model.load(data: data, name: "Duo demo.3mf")
        if let n = Int(d.string(forKey: "DuoDemoPlate") ?? ""), let i = model.project?.plates.firstIndex(where: { $0.id == n }) {
            await model.selectPlate(i)
        }
        if d.bool(forKey: "DuoDemoSlice") { await model.sliceCurrent() }
        if let p = panel { NotificationCenter.default.post(name: .duoDemoPanel, object: p.rawValue) }
        if d.bool(forKey: "DuoDemoQueue") { await fillQueue(model: model, printer: printer, queue: queue) }
    }

    /// The demo project's plate 1 for the P1S, and plates 2 and 1 for any U1; then every bed is "clear".
    @MainActor
    static func fillQueue(model: AppModel, printer: PrinterLink, queue: PrintQueue) async {
        queue.reset()
        let target = model.target.id
        let quick = StartOptions(bedLeveling: false, flowCalibration: false, vibrationCalibration: false, timelapse: false)
        for (modelID, plates, oneprinter) in [("bambu-p1s", [0], true), ("snapmaker-u1", [1, 0], false)] {
            guard let c = printer.all.first(where: { $0.printer.modelID == modelID }) else { continue }
            await model.setTarget(modelID)
            guard let info = model.project, let data = await model.exportProjectData() else { continue }
            let list = plates.compactMap { i in
                info.plates[safe: i].map { QueuePlate(index: $0.index, number: $0.id, name: $0.name, picture: model.thumbnails[$0.index]) }
            }
            queue.add(project: model.fileName, data: data, plates: list, copies: 1, modelID: modelID, printerID: oneprinter ? c.id : nil,
                      options: model.options, currentPlate: model.plateIndex, start: quick)
        }
        await model.setTarget(target)
        // give the stand-ins a moment to connect, then say every bed is clear
        var waited = 0
        while waited < 30 && !printer.all.allSatisfy({ $0.connected }) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
        queue.start(clear: printer.all.map { $0.id })
    }

    @MainActor
    static func rotate(to o: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let mask: UIInterfaceOrientationMask = o.lowercased().hasPrefix("land") ? .landscapeRight : .portrait
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { err in
            print("DuoDemoOrientation: \(err.localizedDescription)")
        }
    }
}

extension View {
    /// -DuoDemoInner: the app in a window the size of the iPhone Duo's inner screen, centred on a bigger screen.
    @ViewBuilder func duoDemoFrame() -> some View {
        if let s = DemoMode.fakeInnerSize {
            frame(width: s.width, height: s.height)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .ignoresSafeArea()
        } else {
            self
        }
    }
}

extension Notification.Name {
    static let duoDemoPanel = Notification.Name("duoDemoPanel")
    static let duoDemoSheet = Notification.Name("duoDemoSheet")
}
