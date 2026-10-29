import SceneKit
import SwiftUI

/// 3D view of one plate. Printer coords (x right, y back, z up) map to SceneKit as (x, z, -y).
struct PlateSceneView: UIViewRepresentable {
    var mesh: SlicerEngine.Mesh?
    var revision: Int
    var colors: [String]
    var selected: Int?
    var pickFace: Bool
    var onSelect: (Int?) -> Void
    var onFace: (Int, SIMD3<Double>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = SCNScene()
        v.backgroundColor = UIColor.secondarySystemBackground
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = false
        v.antialiasingMode = .multisampling4X
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        v.addGestureRecognizer(tap)
        context.coordinator.view = v
        context.coordinator.buildStatic()
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.revision != revision || c.colors != colors {
            let first = c.revision < 0
            c.revision = revision
            c.colors = colors
            c.rebuildModel()
            if first { c.resetCamera() }
        }
        c.applySelection()
    }

    final class Coordinator: NSObject {
        var parent: PlateSceneView
        weak var view: SCNView?
        var revision = -1
        var colors: [String] = []
        let modelNode = SCNNode()
        var materials: [Int: [SCNMaterial]] = [:]  // object -> materials

        init(_ p: PlateSceneView) { parent = p }

        func buildStatic() {
            guard let scene = view?.scene else { return }
            let bed = SCNBox(width: 256, height: 2, length: 256, chamferRadius: 2)
            let bm = SCNMaterial()
            bm.diffuse.contents = UIColor(red: 0.22, green: 0.24, blue: 0.26, alpha: 1)
            bm.roughness.contents = 0.9
            bm.lightingModel = .physicallyBased
            bed.materials = [bm]
            let bedNode = SCNNode(geometry: bed)
            bedNode.position = SCNVector3(128, -1.01, -128)
            scene.rootNode.addChildNode(bedNode)
            // grid
            var pts: [SCNVector3] = []
            var idx: [Int32] = []
            for i in 0...16 {
                let t = Float(i) * 16
                for (a, b) in [(SCNVector3(t, 0.02, 0), SCNVector3(t, 0.02, -256)), (SCNVector3(0, 0.02, -t), SCNVector3(256, 0.02, -t))] {
                    idx.append(Int32(pts.count)); pts.append(a)
                    idx.append(Int32(pts.count)); pts.append(b)
                }
            }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pts)], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
            let gm = SCNMaterial()
            gm.diffuse.contents = UIColor(white: 0.45, alpha: 1)
            gm.lightingModel = .constant
            g.materials = [gm]
            scene.rootNode.addChildNode(SCNNode(geometry: g))
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

        func resetCamera() {
            guard let cam = view?.scene?.rootNode.childNode(withName: "cam", recursively: false) else { return }
            cam.position = SCNVector3(-20, 300, 180)
            cam.look(at: SCNVector3(128, 0, -128))
            view?.pointOfView = cam
            view?.defaultCameraController.target = SCNVector3(128, 0, -128)
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
