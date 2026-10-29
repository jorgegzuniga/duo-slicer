import Foundation

/// Launch arguments for screenshots and UI checks in the simulator (never used by the shipping flow):
///   -DuoDemo YES                 open the bundled demo project
///   -DuoDemoPrinter <model id>   slice for this printer model (e.g. snapmaker-u1)
///   -DuoDemoPlate <n>            select plate n (1-based)
///   -DuoDemoPanel <name>         plate, settings, preview or print
///   -DuoDemoSlice YES            slice before showing
///   -DuoDemoHome YES             stay on the home screen
///   -DuoClaudeRelay <url>        connect "Use with Claude" to this relay (with -DuoClaudeSecret <key>)
enum DemoMode {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "DuoDemo") }
    static var panel: Panel? { UserDefaults.standard.string(forKey: "DuoDemoPanel").flatMap { Panel(rawValue: $0.capitalized) } }

    @MainActor
    static func run(model: AppModel, printer: PrinterLink, claude: ClaudeBridge) async {
        let d = UserDefaults.standard
        if let relay = d.string(forKey: "DuoClaudeRelay"), !relay.isEmpty {
            claude.relayURL = relay
            claude.enabled = true
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
    }
}

extension Notification.Name {
    static let duoDemoPanel = Notification.Name("duoDemoPanel")
}
