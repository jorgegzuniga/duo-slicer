import simd
import UIKit

/// Plate pictures drawn from the slicer's triangles: for plates whose 3MF picture is missing or no longer matches
/// (objects moved, rotated or brought over from another plate). Seen from the front and above, like Bambu Studio's.
enum PlateThumbnail {
    static func render(_ mesh: SlicerEngine.Mesh, colors: [String], bed: PrinterModel.Bed, side: CGFloat = 256) -> UIImage {
        let tilt = 0.95  // radians from straight down
        let st = sin(tilt), ct = cos(tilt)
        // printer (x, y, z) -> picture (u right, v up) and depth (bigger = further away)
        func project(_ x: Double, _ y: Double, _ z: Double) -> (u: Double, v: Double, depth: Double) {
            (x, y * st + z * ct, y * ct - z * st)
        }
        let corners = [(bed.x0, bed.y0), (bed.x1, bed.y0), (bed.x1, bed.y1), (bed.x0, bed.y1)].map { project($0.0, $0.1, 0) }
        var u0 = corners.map(\.u).min()!, u1 = corners.map(\.u).max()!
        var v0 = corners.map(\.v).min()!, v1 = corners.map(\.v).max()!
        let p = mesh.positions
        let n = mesh.filaments.count
        var tris: [(pts: [CGPoint], depth: Double, shade: Double, filament: Int)] = []
        tris.reserveCapacity(n)
        var projected: [(Double, Double, Double)] = []
        projected.reserveCapacity(n * 3)
        for i in 0..<(n * 3) {
            let q = project(Double(p[i * 3]), Double(p[i * 3 + 1]), Double(p[i * 3 + 2]))
            projected.append((q.u, q.v, q.depth))
            u0 = min(u0, q.u); u1 = max(u1, q.u); v0 = min(v0, q.v); v1 = max(v1, q.v)
        }
        let pad = 0.06
        let span = max(u1 - u0, v1 - v0) * (1 + 2 * pad)
        let k = Double(side) / max(span, 1)
        let cu = (u0 + u1) / 2, cv = (v0 + v1) / 2
        func point(_ u: Double, _ v: Double) -> CGPoint {
            CGPoint(x: (u - cu) * k + Double(side) / 2, y: Double(side) / 2 - (v - cv) * k)
        }
        // light from the front left, above
        let light = simd_normalize(SIMD3<Double>(-0.35, -0.55, 0.75))
        for t in 0..<n {
            let a = SIMD3<Double>(Double(p[t * 9]), Double(p[t * 9 + 1]), Double(p[t * 9 + 2]))
            let b = SIMD3<Double>(Double(p[t * 9 + 3]), Double(p[t * 9 + 4]), Double(p[t * 9 + 5]))
            let c = SIMD3<Double>(Double(p[t * 9 + 6]), Double(p[t * 9 + 7]), Double(p[t * 9 + 8]))
            var normal = simd_cross(b - a, c - a)
            let len = simd_length(normal)
            if len < 1e-9 { continue }
            normal /= len
            let qa = projected[t * 3], qb = projected[t * 3 + 1], qc = projected[t * 3 + 2]
            let pts = [point(qa.0, qa.1), point(qb.0, qb.1), point(qc.0, qc.1)]
            // skip slivers smaller than a pixel
            let area = abs((pts[1].x - pts[0].x) * (pts[2].y - pts[0].y) - (pts[2].x - pts[0].x) * (pts[1].y - pts[0].y))
            if area < 0.15 { continue }
            let shade = 0.5 + 0.5 * abs(simd_dot(normal, light))
            tris.append((pts, (qa.2 + qb.2 + qc.2) / 3, shade, Int(mesh.filaments[t])))
        }
        tris.sort { $0.depth > $1.depth }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { ctx in
            let g = ctx.cgContext
            let bedPath = UIBezierPath()
            bedPath.move(to: point(corners[0].u, corners[0].v))
            for c in corners.dropFirst() { bedPath.addLine(to: point(c.u, c.v)) }
            bedPath.close()
            UIColor(red: 0.27, green: 0.29, blue: 0.31, alpha: 1).setFill()
            bedPath.fill()
            var palette: [Int: (Double, Double, Double)] = [:]
            for f in Set(tris.map(\.filament)) {
                let hex = f >= 1 && f - 1 < colors.count ? colors[f - 1] : "#999999"
                var r: CGFloat = 0.6, gr: CGFloat = 0.6, bl: CGFloat = 0.6, al: CGFloat = 1
                UIColor(hex: hex).getRed(&r, green: &gr, blue: &bl, alpha: &al)
                palette[f] = (Double(r), Double(gr), Double(bl))
            }
            for t in tris {
                let base = palette[t.filament] ?? (0.6, 0.6, 0.6)
                g.setFillColor(red: base.0 * t.shade, green: base.1 * t.shade, blue: base.2 * t.shade, alpha: 1)
                g.move(to: t.pts[0])
                g.addLine(to: t.pts[1])
                g.addLine(to: t.pts[2])
                g.closePath()
                g.fillPath()
            }
        }
    }
}
