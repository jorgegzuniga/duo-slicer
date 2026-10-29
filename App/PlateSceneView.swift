import SceneKit
import SwiftUI

/// SCNView that reports size changes (the camera's field of view follows the pane's shape).
final class PlateSCNView: SCNView {
    var onResize: ((CGSize) -> Void)?
    var onWindow: (() -> Void)?
    private var lastSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            onResize?(bounds.size)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindow?()
    }
}

/// 3D view of one plate. Printer coords (x right, y back, z up) map to SceneKit as (x, z, -y).
struct PlateSceneView: UIViewRepresentable {
    var bed: PrinterModel.Bed = .a1
    var mesh: SlicerEngine.Mesh?
    var revision: Int
    var colors: [String]
    var selected: Int?
    var pickFace: Bool
    var onSelect: (Int?) -> Void
    var onFace: (Int, SIMD3<Double>) -> Void
    /// The selected object was dragged by (dx, dy) mm on the bed.
    var onMove: (Int, Double, Double) -> Void = { _, _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let v = PlateSCNView()
        v.onResize = { [weak coord = context.coordinator] size in coord?.fitCamera(to: size) }
        v.scene = SCNScene()
        v.backgroundColor = UIColor.secondarySystemBackground
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = false
        v.antialiasingMode = .multisampling4X
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        v.addGestureRecognizer(tap)
        // one finger on the selected object drags it across the bed; anywhere else orbits the camera
        let drag = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dragged(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = context.coordinator
        v.addGestureRecognizer(drag)
        context.coordinator.drag = drag
        v.onWindow = { [weak coord = context.coordinator] in coord?.yieldCameraPans() }
        context.coordinator.view = v
        context.coordinator.yieldCameraPans()
        context.coordinator.buildStatic()
        context.coordinator.buildBed(bed)
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.bed != bed {
            c.buildBed(bed)
            c.resetCamera()
        }
        if c.revision != revision || c.colors != colors {
            let first = c.revision < 0
            c.revision = revision
            c.colors = colors
            c.rebuildModel()
            if first { c.resetCamera() }
        }
        c.applySelection()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlateSceneView
        weak var view: SCNView?
        weak var drag: UIPanGestureRecognizer?
        private var dragNodes: [SCNNode] = []
        private var dragStarts: [SCNVector3] = []
        private var dragFrom: SIMD3<Float>?
        private var dragHeight: Float = 0
        var revision = -1
        var colors: [String] = []
        var bed: PrinterModel.Bed?
        let modelNode = SCNNode()
        let bedNode = SCNNode()
        var materials: [Int: [SCNMaterial]] = [:]  // object -> materials

        init(_ p: PlateSceneView) { parent = p }

        /// Build plate of the target printer: slab, 16 mm grid and the no-print corner (X1/P1 cutter) if any.
        func buildBed(_ b: PrinterModel.Bed) {
            bed = b
            bedNode.childNodes.forEach { $0.removeFromParentNode() }
            let x0 = Float(b.x0), y0 = Float(b.y0), x1 = Float(b.x1), y1 = Float(b.y1)
            let slab = SCNBox(width: CGFloat(x1 - x0), height: 2, length: CGFloat(y1 - y0), chamferRadius: 2)
            let bm = SCNMaterial()
            bm.diffuse.contents = UIColor(red: 0.22, green: 0.24, blue: 0.26, alpha: 1)
            bm.roughness.contents = 0.9
            bm.lightingModel = .physicallyBased
            slab.materials = [bm]
            let slabNode = SCNNode(geometry: slab)
            slabNode.position = SCNVector3((x0 + x1) / 2, -1.01, -(y0 + y1) / 2)
            bedNode.addChildNode(slabNode)
            var pts: [SCNVector3] = []
            var idx: [Int32] = []
            func line(_ a: SCNVector3, _ c: SCNVector3) {
                idx.append(Int32(pts.count)); pts.append(a)
                idx.append(Int32(pts.count)); pts.append(c)
            }
            var gx = (x0 / 16).rounded(.up) * 16
            while gx <= x1 { line(SCNVector3(gx, 0.02, -y0), SCNVector3(gx, 0.02, -y1)); gx += 16 }
            var gy = (y0 / 16).rounded(.up) * 16
            while gy <= y1 { line(SCNVector3(x0, 0.02, -gy), SCNVector3(x1, 0.02, -gy)); gy += 16 }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pts)], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
            let gm = SCNMaterial()
            gm.diffuse.contents = UIColor(white: 0.45, alpha: 1)
            gm.lightingModel = .constant
            g.materials = [gm]
            bedNode.addChildNode(SCNNode(geometry: g))
            if let ex = b.excludeBox {
                let w = Float(ex.2 - ex.0), d = Float(ex.3 - ex.1)
                let plane = SCNPlane(width: CGFloat(w), height: CGFloat(d))
                let pm = SCNMaterial()
                pm.diffuse.contents = UIColor(red: 0.55, green: 0.12, blue: 0.1, alpha: 0.55)
                pm.lightingModel = .constant
                pm.isDoubleSided = true
                plane.materials = [pm]
                let n = SCNNode(geometry: plane)
                n.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
                n.position = SCNVector3(Float(ex.0) + w / 2, 0.05, -(Float(ex.1) + d / 2))
                bedNode.addChildNode(n)
            }
        }

        func buildStatic() {
            guard let scene = view?.scene else { return }
            scene.rootNode.addChildNode(bedNode)
            // lights
            let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 450
            scene.rootNode.addChildNode(amb)
            let sun = SCNNode(); sun.light = SCNLight(); sun.light!.type = .directional; sun.light!.intensity = 900
            sun.eulerAngles = SCNVector3(-Float.pi / 3, -Float.pi / 5, 0)
            scene.rootNode.addChildNode(sun)
            let fill = SCNNode(); fill.light = SCNLight(); fill.light!.type = .directional; fill.light!.intensity = 350
            fill.eulerAngles = SCNVector3(-Float.pi / 6, Float.pi * 0.8, 0)
            scene.rootNode.addChildNode(fill)
            scene.rootNode.addChildNode(modelNode)
            let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera!.zFar = 4000; cam.camera!.zNear = 1; cam.name = "cam"
            scene.rootNode.addChildNode(cam)
            view?.pointOfView = cam
        }

        /// Keep the whole bed in view in tall, narrow panes (the field of view follows the narrow side).
        func fitCamera(to size: CGSize) {
            guard size.width > 0, size.height > 0,
                  let cam = view?.scene?.rootNode.childNode(withName: "cam", recursively: false)?.camera else { return }
            cam.projectionDirection = size.height > size.width ? .horizontal : .vertical
            cam.fieldOfView = 60
        }

        func resetCamera() {
            guard let cam = view?.scene?.rootNode.childNode(withName: "cam", recursively: false) else { return }
            let b = bed ?? .a1
            let cx = Float(b.x0 + b.x1) / 2, cy = Float(b.y0 + b.y1) / 2
            let k = Float(max(b.width, b.depth)) / 256
            cam.position = SCNVector3(cx - 148 * k, 300 * k, -cy + 308 * k)
            cam.look(at: SCNVector3(cx, 0, -cy))
            view?.pointOfView = cam
            view?.defaultCameraController.target = SCNVector3(cx, 0, -cy)
            if let v = view { fitCamera(to: v.bounds.size) }
        }

        func rebuildModel() {
            modelNode.childNodes.forEach { $0.removeFromParentNode() }
            materials = [:]
            guard let mesh = parent.mesh, !mesh.filaments.isEmpty else { return }
            // group triangles by (object, filament)
            var groups: [Int64: [Int]] = [:]
            for t in 0..<mesh.filaments.count {
                let key = Int64(mesh.objects[t]) << 8 | Int64(mesh.filaments[t])
                groups[key, default: []].append(t)
            }
            for (key, tris) in groups {
                let obj = Int(key >> 8), fil = Int(key & 0xff)
                var verts: [SCNVector3] = []
                var norms: [SCNVector3] = []
                verts.reserveCapacity(tris.count * 3)
                norms.reserveCapacity(tris.count * 3)
                for t in tris {
                    let p = mesh.positions
                    let b = t * 9
                    let a = SIMD3<Float>(p[b], p[b + 2], -p[b + 1])
                    let c = SIMD3<Float>(p[b + 3], p[b + 5], -p[b + 4])
                    let d = SIMD3<Float>(p[b + 6], p[b + 8], -p[b + 7])
                    var n = simd_cross(c - a, d - a)
                    let len = simd_length(n)
                    n = len > 0 ? n / len : SIMD3<Float>(0, 1, 0)
                    for q in [a, c, d] { verts.append(SCNVector3(q.x, q.y, q.z)); norms.append(SCNVector3(n.x, n.y, n.z)) }
                }
                let indices = (0..<Int32(verts.count)).map { $0 }
                let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: norms)],
                                      elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
                let m = SCNMaterial()
                let hex = fil - 1 < colors.count && fil >= 1 ? colors[fil - 1] : "#999999"
                m.diffuse.contents = UIColor(hex: hex)
                m.lightingModel = .physicallyBased
                m.roughness.contents = 0.75
                m.metalness.contents = 0.0
                m.isDoubleSided = true
                geo.materials = [m]
                let node = SCNNode(geometry: geo)
                node.name = "obj-\(obj)"
                modelNode.addChildNode(node)
                materials[obj, default: []].append(m)
            }
        }

        func applySelection() {
            for (obj, mats) in materials {
                for m in mats { m.emission.contents = obj == parent.selected ? UIColor(red: 0.05, green: 0.3, blue: 0.3, alpha: 1) : UIColor.black }
            }
        }

        /// SceneKit's camera pans wait for the object drag to decline the touch.
        func yieldCameraPans() {
            guard let v = view, let drag else { return }
            for g in v.gestureRecognizers ?? [] where g !== drag && g is UIPanGestureRecognizer {
                g.require(toFail: drag)
            }
        }

        private func objectAt(_ p: CGPoint) -> (Int, SCNHitTestResult)? {
            guard let v = view else { return nil }
            let hits = v.hitTest(p, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue])
            guard let hit = hits.first(where: { ($0.node.name ?? "").hasPrefix("obj-") }),
                  let name = hit.node.name, let obj = Int(name.dropFirst(4)) else { return nil }
            return (obj, hit)
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === drag, let v = view, let sel = parent.selected, !parent.pickFace,
                  let found = objectAt(g.location(in: v)), found.0 == sel else { return false }
            dragHeight = found.1.worldCoordinates.y
            return true
        }

        /// Where a screen point lands on the horizontal plane at the grabbed height (scene coordinates).
        private func planePoint(_ p: CGPoint) -> SIMD3<Float>? {
            guard let v = view else { return nil }
            let near = v.unprojectPoint(SCNVector3(Float(p.x), Float(p.y), 0))
            let far = v.unprojectPoint(SCNVector3(Float(p.x), Float(p.y), 1))
            let a = SIMD3<Float>(near.x, near.y, near.z), b = SIMD3<Float>(far.x, far.y, far.z)
            let dir = b - a
            guard abs(dir.y) > 1e-6 else { return nil }
            let t = (dragHeight - a.y) / dir.y
            guard t > 0 else { return nil }
            return a + dir * t
        }

        @objc func dragged(_ g: UIPanGestureRecognizer) {
            guard let v = view, let obj = parent.selected else { return }
            let p = g.location(in: v)
            switch g.state {
            case .began:
                dragFrom = planePoint(p)
                dragNodes = modelNode.childNodes.filter { $0.name == "obj-\(obj)" }
                dragStarts = dragNodes.map(\.position)
            case .changed:
                guard let from = dragFrom, let to = planePoint(p) else { return }
                let d = to - from
                for (n, s) in zip(dragNodes, dragStarts) { n.position = SCNVector3(s.x + d.x, s.y, s.z + d.z) }
            case .ended:
                guard let from = dragFrom, let to = planePoint(p) else { restoreDrag(); return }
                let d = to - from
                dragFrom = nil
                // scene (x, -z) is the printer's (x, y); the nodes stay where they are until the new mesh arrives
                if abs(d.x) > 0.05 || abs(d.z) > 0.05 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    parent.onMove(obj, Double(d.x), Double(-d.z))
                }
            default:
                restoreDrag()
            }
        }

        private func restoreDrag() {
            for (n, s) in zip(dragNodes, dragStarts) { n.position = s }
            dragFrom = nil
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            let hits = v.hitTest(g.location(in: v), options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue])
            let hit = hits.first { ($0.node.name ?? "").hasPrefix("obj-") }
            guard let hit, let name = hit.node.name, let obj = Int(name.dropFirst(4)) else {
                if !parent.pickFace { parent.onSelect(nil) }
                return
            }
            if parent.pickFace, obj == parent.selected {
                let n = hit.worldNormal
                // scene (x, y, z) -> printer (x, -z, y)
                parent.onFace(obj, SIMD3<Double>(Double(n.x), Double(-n.z), Double(n.y)))
            } else {
                parent.onSelect(obj)
            }
        }
    }
}
