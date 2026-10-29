import Foundation
import UIKit

/// Thin Swift wrapper over the C++ slicing engine. Not thread-safe: call it from one serial queue.
final class SlicerEngine {
    private let handle: OpaquePointer

    init() {
        let url = Bundle.main.url(forResource: "a1-profiles", withExtension: "json")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "{}"
        handle = a1_create(text)!
    }

    deinit { a1_destroy(handle) }

    enum EngineError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    private func take(_ p: UnsafeMutablePointer<CChar>?) -> Data {
        guard let p else { return Data("{}".utf8) }
        defer { a1_free(p) }
        return Data(bytes: p, count: strlen(p))
    }

    private func errorIn(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    func open(_ data: Data) throws -> ProjectInfo {
        let out = data.withUnsafeBytes { raw -> Data in
            take(a1_open(handle, raw.bindMemory(to: UInt8.self).baseAddress, data.count))
        }
        if let e = errorIn(out) { throw EngineError.message(e) }
        struct Wrap: Decodable { let project: ProjectInfo }
        return try JSONCoding.decoder.decode(Wrap.self, from: out).project
    }

    func info() throws -> ProjectInfo {
        let out = take(a1_info(handle))
        if let e = errorIn(out) { throw EngineError.message(e) }
        return try JSONCoding.decoder.decode(ProjectInfo.self, from: out)
    }

    func settings(_ options: PrintOptions) -> [String: Any] {
        let out = take(a1_settings(handle, options.json()))
        return (try? JSONSerialization.jsonObject(with: out) as? [String: Any]) ?? [:]
    }

    func rotate(object: Int, axis: Int, degrees: Double) { _ = a1_rotate(handle, Int32(object), Int32(axis), degrees) }
    func layFlat(object: Int, normal: SIMD3<Double>) { _ = a1_lay_flat(handle, Int32(object), normal.x, normal.y, normal.z) }
    func autoFlat(object: Int) { _ = a1_auto_flat(handle, Int32(object)) }
    func reset(object: Int) { _ = a1_reset_transform(handle, Int32(object)) }

    struct Mesh {
        var positions: [Float]   // 9 per triangle, printer coordinates (mm)
        var filaments: [UInt8]   // 1 per triangle
        var objects: [Int32]     // 1 per triangle
    }

    func plateMesh(_ plate: Int) -> Mesh {
        var xyz: UnsafeMutablePointer<Float>?
        var fil: UnsafeMutablePointer<UInt8>?
        var obj: UnsafeMutablePointer<Int32>?
        var count = 0
        guard a1_plate_mesh(handle, Int32(plate), &xyz, &fil, &obj, &count) == 0 else { return Mesh(positions: [], filaments: [], objects: []) }
        defer { a1_free(xyz); a1_free(fil); a1_free(obj) }
        return Mesh(positions: Array(UnsafeBufferPointer(start: xyz, count: count * 9)),
                    filaments: Array(UnsafeBufferPointer(start: fil, count: count)),
                    objects: Array(UnsafeBufferPointer(start: obj, count: count)))
    }

    func thumbnail(_ plate: Int) -> UIImage? {
        var data: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard a1_plate_thumbnail(handle, Int32(plate), &data, &len) == 0, let data else { return nil }
        defer { a1_free(data) }
        return UIImage(data: Data(bytes: data, count: len))
    }

    private final class ProgressBox {
        let fn: (Double) -> Void
        init(_ fn: @escaping (Double) -> Void) { self.fn = fn }
    }

    func slice(plate: Int, options: PrintOptions, progress: @escaping (Double) -> Void) -> SliceSummary {
        let box = ProgressBox(progress)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(ctx).release() }
        let cb: A1Progress = { fraction, ctx in
            guard let ctx else { return }
            Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue().fn(fraction)
        }
        let out = take(a1_slice(handle, Int32(plate), options.json(), cb, ctx))
        return (try? JSONCoding.decoder.decode(SliceSummary.self, from: out)) ?? SliceSummary(error: "The slicer returned an unreadable result.")
    }

    func slicedFile() -> Data? {
        var data: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard a1_sliced_file(handle, &data, &len) == 0, let data else { return nil }
        defer { a1_free(data) }
        return Data(bytes: data, count: len)
    }

    func exportProject() -> Data? {
        var data: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard a1_export_project(handle, &data, &len) == 0, let data else { return nil }
        defer { a1_free(data) }
        return Data(bytes: data, count: len)
    }

    var layerCount: Int { Int(a1_layer_count(handle)) }
    func layerZ(_ i: Int) -> Double { a1_layer_z(handle, Int32(i)) }

    struct LayerPreview {
        var segments: [Float]   // x0 y0 x1 y1
        var meta: [UInt16]      // role | filament << 8
    }

    func layerPreview(_ i: Int) -> LayerPreview {
        var segs: UnsafeMutablePointer<Float>?
        var meta: UnsafeMutablePointer<UInt16>?
        var count = 0
        guard a1_layer_preview(handle, Int32(i), &segs, &meta, &count) == 0 else { return LayerPreview(segments: [], meta: []) }
        defer { a1_free(segs); a1_free(meta) }
        return LayerPreview(segments: Array(UnsafeBufferPointer(start: segs, count: count * 4)),
                            meta: Array(UnsafeBufferPointer(start: meta, count: count)))
    }
}
