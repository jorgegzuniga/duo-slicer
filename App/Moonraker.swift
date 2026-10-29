import Foundation

/// Moonraker (Klipper) HTTP API, used for the Snapmaker U1. LAN only, plain HTTP on port 7125.
struct MoonrakerClient: Sendable {
    let base: URL
    let apiKey: String?

    init?(host: String, port: Int, apiKey: String?) {
        guard !host.isEmpty, let url = URL(string: "http://\(host):\(port)") else { return nil }
        base = url
        self.apiKey = (apiKey?.isEmpty ?? true) ? nil : apiKey
    }

    enum Failure: LocalizedError {
        case http(Int, String)
        case bad(String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let m): return m.isEmpty ? "The printer answered with HTTP \(code)." : m
            case .bad(let m): return m
            }
        }
    }

    private func request(_ path: String, method: String = "GET", timeout: TimeInterval = 8) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!, timeoutInterval: timeout)
        r.httpMethod = method
        if let apiKey { r.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        return r
    }

    private static func parse(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200..<300).contains(code) {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? ""
            if code == 401 || code == 403 { throw Failure.http(code, "The printer needs an API key. Add it in the printer's settings in Duo Slicer.") }
            throw Failure.http(code, msg)
        }
        return obj
    }

    /// Printer state: print_stats, virtual_sdcard, toolhead, extruders, bed and the U1's loaded-filament table.
    func status() async throws -> [String: Any] {
        let q = "print_stats&virtual_sdcard&display_status&toolhead&extruder&extruder1&extruder2&extruder3&heater_bed&webhooks" +
            "&print_task_config=filament_type,filament_color_rgba,filament_exist,filament_vendor,filament_sub_type"
        let (data, resp) = try await URLSession.shared.data(for: request("/printer/objects/query?" + q, timeout: 5))
        let obj = try Self.parse(data, resp)
        return ((obj["result"] as? [String: Any])?["status"] as? [String: Any]) ?? [:]
    }

    private final class UploadDelegate: NSObject, URLSessionTaskDelegate {
        let progress: @Sendable (Double) -> Void
        init(_ p: @escaping @Sendable (Double) -> Void) { progress = p }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            if totalBytesExpectedToSend > 0 { progress(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
        }
    }

    /// Uploads G-code into the printer's gcodes folder (does not start it).
    func upload(name: String, data: Data, progress: @escaping @Sendable (Double) -> Void) async throws {
        let boundary = "duo-\(UUID().uuidString)"
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".utf8))
        }
        field("root", "gcodes")
        field("print", "false")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var r = request("/server/files/upload", method: "POST", timeout: 300)
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (out, resp) = try await URLSession.shared.upload(for: r, from: body, delegate: UploadDelegate(progress))
        _ = try Self.parse(out, resp)
    }

    func start(name: String) async throws {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let (out, resp) = try await URLSession.shared.data(for: request("/printer/print/start?filename=\(enc)", method: "POST"))
        _ = try Self.parse(out, resp)
    }

    /// pause, resume or cancel
    func control(_ action: String) async throws {
        let (out, resp) = try await URLSession.shared.data(for: request("/printer/print/\(action)", method: "POST"))
        _ = try Self.parse(out, resp)
    }
}

/// Polls a Moonraker printer every couple of seconds until stopped.
final class MoonrakerPoller: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    let client: MoonrakerClient

    init(client: MoonrakerClient) { self.client = client }

    func stop() { lock.lock(); stopped = true; lock.unlock() }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func run(onState: @escaping @Sendable (Bool, String) -> Void, onStatus: @escaping @Sendable ([String: Any]) -> Void) async {
        var failures = 0
        while !isStopped {
            do {
                let s = try await client.status()
                if isStopped { break }
                failures = 0
                onState(true, "Connected")
                onStatus(s)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                if isStopped { break }
                failures += 1
                onState(false, failures == 1 ? "Connecting to \(client.base.host ?? "")…" : "Can't reach the printer: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(min(10, 2 * failures)) * 1_000_000_000)
            }
        }
    }
}
