import Foundation
import SwiftUI
import UIKit

/// Lets Claude drive Duo Slicer through the Duo Slicer relay (a small Cloudflare Worker).
/// The app keeps a WebSocket to the relay while it's open; claude.ai talks to the relay's MCP endpoint,
/// and the relay forwards each tool call here. Starting or stopping a print always waits for approval on the phone.
@MainActor
final class ClaudeBridge: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "claude.enabled")
            if enabled { connect() } else { disconnect() }
        }
    }
    @Published var relayURL: String {
        didSet {
            UserDefaults.standard.set(relayURL, forKey: "claude.relay")
            if enabled { connect() }
        }
    }
    @Published private(set) var connected = false
    @Published private(set) var status = "Off"
    @Published private(set) var activity: [String] = []
    @Published var approval: ApprovalRequest?

    private weak var model: AppModel?
    private weak var printer: PrinterLink?
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var foreground = true
    private var retry = 1.0

    init() {
        enabled = UserDefaults.standard.bool(forKey: "claude.enabled")
        let saved = UserDefaults.standard.string(forKey: "claude.relay") ?? ""
        let baked = (Bundle.main.object(forInfoDictionaryKey: "DuoRelayURL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        relayURL = saved.isEmpty ? baked : saved
    }

    func attach(model: AppModel, printer: PrinterLink) {
        self.model = model
        self.printer = printer
        if enabled { connect() }
    }

    // MARK: pairing

    /// Secret in the connector URL; anyone with the URL can use the app's tools, so it stays in the Keychain.
    var secret: String {
        if let s = UserDefaults.standard.string(forKey: "DuoClaudeSecret"), s.count >= 32 { return s }  // simulator tests
        if let s = Keychain.get("claude.secret"), s.count >= 32 { return s }
        let s = Self.newSecret()
        Keychain.set(s, for: "claude.secret")
        return s
    }

    private static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// New connector URL; the old one stops working.
    func resetSecret() {
        Keychain.set(Self.newSecret(), for: "claude.secret")
        if enabled { connect() }
    }

    var relayBase: URL? {
        var s = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), u.scheme == "https" || u.scheme == "http", u.host != nil else { return nil }
        return u
    }

    var connectorURL: String? { relayBase.map { "\($0.absoluteString)/mcp/\(secret)" } }

    // MARK: connection

    func setForeground(_ active: Bool) {
        foreground = active
        if active { if enabled && socket == nil { connect() } } else { disconnect(keepStatus: true) }
    }

    func connect() {
        disconnect(keepStatus: true)
        guard enabled, foreground else { return }
        guard let base = relayBase, var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            status = "Add the relay address below."
            return
        }
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/device"
        comps.queryItems = [URLQueryItem(name: "token", value: secret)]
        guard let url = comps.url else { return }
        generation += 1
        let gen = generation
        let t = URLSession.shared.webSocketTask(with: url)
        t.maximumMessageSize = 8 << 20
        socket = t
        status = "Connecting…"
        t.resume()
        listen(t, gen: gen)
        let hello: [String: Any] = ["type": "hello", "app": "Duo Slicer", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"]
        send(hello, on: t) { [weak self] ok in
            guard let self, self.generation == gen else { return }
            if ok {
                self.connected = true
                self.retry = 1
                self.status = "Connected. Claude can use Duo Slicer while the app is open."
            } else {
                self.dropped(gen: gen, reason: "Can't reach the relay.")
            }
        }
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.generation == gen, let s = self.socket else { return }
                self.sendText("{\"type\":\"ping\"}", on: s) { ok in if !ok { self.dropped(gen: gen, reason: "The relay connection dropped.") } }
            }
        }
    }

    func disconnect(keepStatus: Bool = false) {
        generation += 1
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
        if !keepStatus { status = "Off" }
    }

    private func dropped(gen: Int, reason: String) {
        guard gen == generation else { return }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
        status = reason + " Retrying…"
        let delay = retry
        retry = min(retry * 2, 30)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.enabled, self.foreground, self.socket == nil else { return }
            self.connect()
        }
    }

    private func listen(_ t: URLSessionWebSocketTask, gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                switch result {
                case .failure:
                    self.dropped(gen: gen, reason: "The relay connection dropped.")
                case .success(let msg):
                    var text: String?
                    switch msg {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: break
                    }
                    if let text { Task { await self.handle(text, on: t) } }
                    self.listen(t, gen: gen)
                }
            }
        }
    }

    private func sendText(_ text: String, on t: URLSessionWebSocketTask, done: @escaping @MainActor (Bool) -> Void) {
        t.send(.string(text)) { err in
            Task { @MainActor in done(err == nil) }
        }
    }

    private func send(_ obj: [String: Any], on t: URLSessionWebSocketTask, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { done(false); return }
        sendText(s, on: t, done: done)
    }

    private func handle(_ text: String, on t: URLSessionWebSocketTask) async {
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let id = msg["id"] else { return }
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        note("Claude: \(name.replacingOccurrences(of: "_", with: " "))")
        let result = await ClaudeTools(bridge: self, model: model, printer: printer).call(name, args)
        // long calls (slicing, approvals) can outlive a reconnect; the relay matches the answer by id on any connection
        send(["id": id, "result": result], on: socket ?? t)
    }

    func note(_ line: String) {
        activity.insert(line, at: 0)
        if activity.count > 8 { activity.removeLast() }
    }

    // MARK: approvals

    /// Shows a sheet on the phone and waits (up to two minutes) for the user to approve.
    func requestApproval(title: String, detail: String, confirm: String, destructive: Bool = false) async -> Bool {
        if approval != nil { return false }
        return await withCheckedContinuation { cont in
            let box = ApprovalRequest.Once(cont)
            let req = ApprovalRequest(title: title, detail: detail, confirm: confirm, destructive: destructive, once: box)
            approval = req
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                if box.resume(false) { self?.approval = nil }
            }
        }
    }

    func answer(_ ok: Bool) {
        guard let a = approval else { return }
        approval = nil
        _ = a.once.resume(ok)
    }
}

struct ApprovalRequest: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let confirm: String
    let destructive: Bool
    let once: Once

    /// Resumes the waiting tool call exactly once.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Bool, Never>?
        init(_ c: CheckedContinuation<Bool, Never>) { cont = c }
        @discardableResult func resume(_ v: Bool) -> Bool {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(returning: v)
            return c != nil
        }
    }
}

struct ApprovalSheet: View {
    @EnvironmentObject var bridge: ClaudeBridge
    let request: ApprovalRequest

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: request.destructive ? "stop.circle" : "printer.fill")
                .font(.system(size: 40))
                .foregroundStyle(request.destructive ? .red : Theme.accent)
            Text(request.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(request.detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button(role: request.destructive ? .destructive : nil) {
                    bridge.answer(true)
                } label: {
                    Text(request.confirm).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Not now") { bridge.answer(false) }
                    .controlSize(.large)
            }
        }
        .padding(24)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}
