import AppKit
import SceneKit
import SwiftUI

/// All building parts use the same polygon extrusion. No asset-specific drawing or remote loading.
struct SpatialSceneView: NSViewRepresentable {
    let asset: SpatialAsset
    let wireframe: Bool
    let resetToken: Int
    let isActive: Bool

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = Palette.bg
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false
        view.setAccessibilityLabel("건축물 3D · 드래그 회전 · 스크롤 확대")
        view.setAccessibilityIdentifier("spatial-scene")
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.asset != asset || coordinator.resetToken != resetToken {
            coordinator.asset = asset; coordinator.resetToken = resetToken
            SpatialScene.configure(view, asset: asset)
        }
        view.scene?.rootNode.enumerateChildNodes { node, _ in
            if node.name?.hasPrefix("part:") == true {
                node.geometry?.materials.forEach { $0.fillMode = wireframe ? .lines : .fill }
            }
        }
        view.isPlaying = isActive
        view.allowsCameraControl = isActive
    }

    final class Coordinator {
        var asset: SpatialAsset?
        var resetToken = -1
    }
}

enum SpatialScene {
    static func configure(_ view: SCNView, asset: SpatialAsset) {
        let scene = SCNScene()
        let points = asset.parts.flatMap(\.footprint)
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 1
        let minimumElevation = asset.parts.map(\.elevation).min() ?? 0
        let top = asset.parts.map { $0.elevation + $0.height }.max() ?? 1
        let originX = (minX + maxX) / 2, originY = (minY + maxY) / 2
        let span = max(maxX - minX, maxY - minY, top - minimumElevation, 1)
        // ponytail: material colors are copied at configure time; an appearance switch shows on the next reload.
        let appearance = view.effectiveAppearance
        // Recenter before Float conversion; preserve the imported source coordinates in the archive.
        for part in asset.parts {
            let path = NSBezierPath()
            for (index, point) in part.footprint.enumerated() {
                let p = NSPoint(x: point.x - originX, y: -(point.y - originY))
                if index == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close()
            let shape = SCNShape(path: path, extrusionDepth: CGFloat(part.height))
            let material = SCNMaterial()
            material.diffuse.contents = color(part.provenance.kind).resolved(for: appearance)
            material.roughness.contents = 0.8
            material.isDoubleSided = true
            shape.materials = [material]
            let node = SCNNode(geometry: shape)
            node.name = "part:" + part.id
            // SCNShape is centered on its local Z axis; rotate that axis into world up (Y).
            node.eulerAngles.x = -.pi / 2
            node.position.y = CGFloat(part.elevation - minimumElevation + part.height / 2)
            scene.rootNode.addChildNode(node)
        }
        let ground = SCNPlane(width: CGFloat(span * 2.5), height: CGFloat(span * 2.5))
        let groundMaterial = SCNMaterial()
        groundMaterial.diffuse.contents = Palette.surface2.resolved(for: appearance)
        groundMaterial.isDoubleSided = true
        ground.materials = [groundMaterial]
        let plane = SCNNode(geometry: ground)
        plane.eulerAngles.x = -.pi / 2; plane.position.y = -0.003 * span
        scene.rootNode.addChildNode(plane)

        let target = SCNVector3(0, (top - minimumElevation) / 2, 0)
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 45
        camera.camera?.zNear = max(0.001, span / 10_000)
        camera.camera?.zFar = span * 50
        camera.position = SCNVector3(span * 1.8, CGFloat(target.y) + span * 1.3, span * 1.8)
        camera.look(at: target)
        scene.rootNode.addChildNode(camera)
        view.scene = scene
        view.pointOfView = camera
        view.defaultCameraController.pointOfView = camera
        view.defaultCameraController.target = target
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = false
    }

    /// Measured, estimated, schematic: three palette tones, no extra hues.
    static func color(_ kind: SpatialProvenance.Kind) -> NSColor {
        switch kind {
        case .measured: return Palette.fg
        case .estimated: return Palette.fg2
        case .schematic: return Palette.line2
        }
    }
}
