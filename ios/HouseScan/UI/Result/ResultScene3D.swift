import RealityKit
import SwiftUI
import UIKit

// The result as a small 3D model of the homeowner's own wall: the meter, the battery standing
// where the server placed it, the cable run between them and the clearance zones tinted by
// outcome. Seeing the battery on your own wall is the moment the scan pays off, so the view opens
// with a short camera sweep that settles on the battery, then lets the homeowner turn it.
//
// Everything is built in the wall frame of `WallGeometry`, not in ARKit world coordinates:
// x = s (meters along the wall, + to the right), y = height above the ground, z = meters out
// from the wall toward the viewer. The meter sits at (0, meterHeight, 0).

struct ResultScene3D: View {
    let wall: WallGeometry
    let result: ResultPresentation
    let features: [MarkedFeature]
    let wallHeight: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Camera orbit, degrees. Starts at the resting pose so a Reduce Motion user never sees a jump.
    @State private var yaw = CameraPose.rest.yaw
    @State private var pitch = CameraPose.rest.pitch
    @State private var zoom: Float = 1
    @State private var dragOrigin: SIMD2<Float>?
    @State private var zoomOrigin: Float?
    @State private var introPlayed = false
    @State private var introInterrupted = false

    init(wall: WallGeometry, result: ResultPresentation, features: [MarkedFeature], wallHeight: Float) {
        self.wall = wall
        self.result = result
        self.features = features
        self.wallHeight = wallHeight
    }

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(buildDiorama())
            let camera = PerspectiveCamera()
            camera.name = Self.cameraName
            camera.camera.fieldOfViewInDegrees = 40
            camera.camera.near = 0.1
            content.add(camera)
            placeCamera(camera)
        } update: { content in
            guard let camera = content.entities.first(where: { $0.name == Self.cameraName }) else { return }
            placeCamera(camera)
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0xDC / 255, green: 0xE6 / 255, blue: 0xF2 / 255),
                         Color(red: 0xF2 / 255, green: 0xF1 / 255, blue: 0xEC / 255)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .gesture(orbitGesture)
        .simultaneousGesture(zoomGesture)
        .task { await playIntro() }
        .accessibilityElement()
        .accessibilityLabel("3D view of your wall")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("Drag to turn the view")
    }

    // MARK: - Camera

    private static let cameraName = "result-orbit-camera"

    private enum CameraPose {
        static let intro = (yaw: Float(-35), pitch: Float(30))
        static let rest = (yaw: Float(18), pitch: Float(18))
        static let yawRange: ClosedRange<Float> = -70...70
        static let pitchRange: ClosedRange<Float> = 8...45
        static let zoomRange: ClosedRange<Float> = 0.6...1.6
        static let introSeconds = 1.6
    }

    /// The point the camera circles: the battery's center when there is one, else the meter.
    private var orbitTarget: SIMD3<Float> {
        if let spot = result.spot {
            let mid = (spot.span.lowerBound + spot.span.upperBound) / 2
            return SIMD3(mid, spot.height / 2, spot.offsetFromWall + spot.depth / 2)
        }
        return SIMD3(0, wall.meterHeight / 2, 0)
    }

    private var orbitDistance: Float {
        max(5, (wallExtent.upperBound - wallExtent.lowerBound) * 0.9) / zoom
    }

    private func placeCamera(_ camera: Entity) {
        let yawRad = yaw * .pi / 180
        let pitchRad = pitch * .pi / 180
        let direction = SIMD3(sin(yawRad) * cos(pitchRad), sin(pitchRad), cos(yawRad) * cos(pitchRad))
        camera.look(at: orbitTarget, from: orbitTarget + direction * orbitDistance, relativeTo: nil)
    }

    /// Sweeps from a high three-quarter view down to the resting pose, easing out so it lands
    /// softly on the battery. Plays once; a drag stops it where it is and takes over from there.
    private func playIntro() async {
        guard !introPlayed else { return }
        introPlayed = true
        guard !reduceMotion else { return }
        yaw = CameraPose.intro.yaw
        pitch = CameraPose.intro.pitch
        let clock = ContinuousClock()
        let start = clock.now
        while !introInterrupted {
            let t = Float(min((clock.now - start) / .seconds(CameraPose.introSeconds), 1))
            let eased = 1 - pow(1 - t, 3)
            yaw = CameraPose.intro.yaw + (CameraPose.rest.yaw - CameraPose.intro.yaw) * eased
            pitch = CameraPose.intro.pitch + (CameraPose.rest.pitch - CameraPose.intro.pitch) * eased
            if t >= 1 { return }
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        }
    }

    private var orbitGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                introInterrupted = true
                let origin = dragOrigin ?? SIMD2(yaw, pitch)
                dragOrigin = origin
                yaw = (origin.x - Float(value.translation.width) * 0.3).clamped(to: CameraPose.yawRange)
                pitch = (origin.y + Float(value.translation.height) * 0.2).clamped(to: CameraPose.pitchRange)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let origin = zoomOrigin ?? zoom
                zoomOrigin = origin
                zoom = (origin * Float(value.magnification)).clamped(to: CameraPose.zoomRange)
            }
            .onEnded { _ in zoomOrigin = nil }
    }

    // MARK: - Scene

    /// The wall's s range: the marked ends, or everything the result mentions plus 1.5 m of wall
    /// on each side for an end the homeowner didn't mark.
    private var wallExtent: ClosedRange<Float> {
        var spans: [ClosedRange<Float>] = [0...0]
        if let spot = result.spot { spans.append(spot.span) }
        spans += features.map(\.span)
        spans += result.clearances.map(\.span)
        spans += result.cableRoute.map { $0.x...$0.x }
        let left = wall.leftEnd ?? (spans.map(\.lowerBound).min() ?? 0) - 1.5
        let right = wall.rightEnd ?? (spans.map(\.upperBound).max() ?? 0) + 1.5
        return min(left, right)...max(left, right)
    }

    private func buildDiorama() -> Entity {
        let root = Entity()
        let extent = wallExtent
        let width = extent.upperBound - extent.lowerBound
        let centerX = (extent.lowerBound + extent.upperBound) / 2

        root.addChild(box(width: width, height: wallHeight, depth: 0.12,
                          center: SIMD3(centerX, wallHeight / 2, -0.06), material: matte(SceneColor.wall)))
        root.addChild(plane(width: width + 1, depth: Self.groundDepth,
                            center: SIMD3(centerX, 0, Self.groundDepth / 2), material: matte(SceneColor.ground)))

        root.addChild(box(width: 0.3, height: 0.4, depth: 0.15,
                          center: SIMD3(0, wall.meterHeight, 0.075), material: matte(SceneColor.meter)))
        let dial = ModelEntity(mesh: .generateCylinder(height: 0.01, radius: 0.07), materials: [matte(SceneColor.signal)])
        dial.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        dial.position = SIMD3(0, wall.meterHeight + 0.04, 0.155)
        root.addChild(dial)

        for feature in features { addFeature(feature, to: root) }

        for (index, zone) in result.clearances.enumerated() {
            var material = UnlitMaterial(color: SceneColor.outcome(zone.outcome))
            material.blending = .transparent(opacity: .init(floatLiteral: 0.35))
            let zoneWidth = zone.span.upperBound - zone.span.lowerBound
            // Stacked zones sit a few millimeters apart so overlapping ones don't flicker.
            let lift = 0.006 + Float(index) * 0.003
            root.addChild(plane(width: zoneWidth, depth: zone.depth,
                                center: SIMD3(zone.span.lowerBound + zoneWidth / 2, lift, zone.depth / 2), material: material))
        }

        addCable(to: root)
        if let spot = result.spot { addBattery(spot, to: root) }
        addLights(to: root)
        return root
    }

    private static let groundDepth: Float = 2.5

    private func addFeature(_ feature: MarkedFeature, to root: Entity) {
        let width = max(feature.span.upperBound - feature.span.lowerBound, 0.05)
        let centerX = (feature.span.lowerBound + feature.span.upperBound) / 2
        switch feature.kind {
        case .window, .door:
            let bottom = feature.bottom ?? (feature.kind == .door ? 0 : 0.9)
            let top = feature.top ?? (feature.kind == .door ? 2.03 : 2.1)
            let height = max(top - bottom, 0.05)
            root.addChild(box(width: width, height: height, depth: 0.02,
                              center: SIMD3(centerX, bottom + height / 2, 0), material: matte(SceneColor.opening)))
        case .gasMeter:
            let bottom = feature.bottom ?? 0.15
            root.addChild(box(width: 0.3, height: 0.35, depth: 0.2,
                              center: SIMD3(centerX, bottom + 0.175, 0.1), material: matte(SceneColor.gas)))
        case .acUnit:
            let back = feature.out ?? 0.3
            root.addChild(box(width: 0.8, height: 0.8, depth: 0.8,
                              center: SIMD3(centerX, 0.4, back + 0.4), material: matte(SceneColor.meter)))
        case .battery, .elecBox:
            let bottom = feature.bottom ?? 0
            let height = max((feature.top ?? bottom + 1) - bottom, 0.05)
            let depth: Float = feature.kind == .battery ? 0.56 : 0.15
            root.addChild(box(width: width, height: height, depth: depth,
                              center: SIMD3(centerX, bottom + height / 2, depth / 2), material: matte(SceneColor.meter)))
        case .driveway:
            root.addChild(plane(width: width, depth: Self.groundDepth,
                                center: SIMD3(centerX, 0.003, Self.groundDepth / 2), material: matte(SceneColor.driveway)))
        case .fence:
            root.addChild(box(width: width, height: 1.2, depth: 0.04,
                              center: SIMD3(centerX, 0.6, feature.out ?? 2.0), material: matte(SceneColor.fence)))
        }
    }

    private func addBattery(_ spot: BatterySpot, to root: Entity) {
        let width = max(spot.span.upperBound - spot.span.lowerBound, 0.1)
        let centerX = (spot.span.lowerBound + spot.span.upperBound) / 2
        let front = spot.offsetFromWall + spot.depth
        var body = PhysicallyBasedMaterial()
        body.baseColor = .init(tint: SceneColor.battery)
        body.roughness = 0.35
        let corner = min(0.03, min(width, spot.height, spot.depth) / 4)
        let unit = ModelEntity(
            mesh: .generateBox(width: width, height: spot.height, depth: spot.depth, cornerRadius: corner),
            materials: [body]
        )
        unit.position = SIMD3(centerX, spot.height / 2, spot.offsetFromWall + spot.depth / 2)
        root.addChild(unit)
        // A vertical light bar on the front face so the unit reads as "the battery", not a box.
        root.addChild(box(width: 0.04, height: spot.height * 0.7, depth: 0.006,
                          center: SIMD3(centerX, spot.height / 2, front + 0.003), material: UnlitMaterial(color: SceneColor.signal)))
    }

    private func addCable(to root: Entity) {
        let points = result.cableRoute.map { SIMD3($0.x, $0.y, 0.03) }
        let material = matte(SceneColor.signal)
        let radius: Float = 0.015
        for (from, to) in zip(points, points.dropFirst()) {
            let length = simd_distance(from, to)
            guard length > 0.001 else { continue }
            let segment = ModelEntity(mesh: .generateCylinder(height: length, radius: radius), materials: [material])
            segment.position = (from + to) / 2
            segment.orientation = simd_quatf(from: SIMD3(0, 1, 0), to: (to - from) / length)
            root.addChild(segment)
        }
        // Round joints so bends don't show a notch.
        for point in points.dropFirst().dropLast() {
            let joint = ModelEntity(mesh: .generateSphere(radius: radius), materials: [material])
            joint.position = point
            root.addChild(joint)
        }
    }

    private func addLights(to root: Entity) {
        // Key light from upper left front, casting the battery's shadow onto the ground.
        let key = DirectionalLight()
        key.light.intensity = 2500
        key.shadow = DirectionalLightComponent.Shadow(maximumDistance: orbitDistance * 1.6 + 6, depthBias: 1)
        key.look(at: .zero, from: SIMD3(-3, 6, 4), relativeTo: nil)
        root.addChild(key)
        // Weak fill from the right so faces turned away from the key light don't go black.
        let fill = DirectionalLight()
        fill.light.intensity = 600
        fill.look(at: .zero, from: SIMD3(4, 2, 3), relativeTo: nil)
        root.addChild(fill)
    }

    private func box(width: Float, height: Float, depth: Float, center: SIMD3<Float>, material: any RealityKit.Material) -> ModelEntity {
        let entity = ModelEntity(mesh: .generateBox(width: width, height: height, depth: depth), materials: [material])
        entity.position = center
        return entity
    }

    /// A horizontal rectangle facing up.
    private func plane(width: Float, depth: Float, center: SIMD3<Float>, material: any RealityKit.Material) -> ModelEntity {
        let entity = ModelEntity(mesh: .generatePlane(width: width, depth: depth), materials: [material])
        entity.position = center
        return entity
    }

    private func matte(_ color: UIColor) -> SimpleMaterial {
        SimpleMaterial(color: color, roughness: 0.85, isMetallic: false)
    }

    // MARK: - Accessibility

    /// Lengths are spelled out: VoiceOver reads "ft" and "in" as letters (B-16).
    private var accessibilitySummary: String {
        guard let spot = result.spot else { return "No battery spot shown" }
        var parts: [String]
        if spot.span.lowerBound > 0 {
            parts = ["Battery \(Distance.spoken(spot.span.lowerBound)) right of your meter"]
        } else if spot.span.upperBound < 0 {
            parts = ["Battery \(Distance.spoken(-spot.span.upperBound)) left of your meter"]
        } else {
            parts = ["Battery below your meter"]
        }
        if let cable = result.cableLength {
            parts.append("cable \(Distance.spoken(cable))")
        }
        return parts.joined(separator: ", ")
    }
}

/// The result for "See it on your wall" (`LiveCapture.showResult`): the battery, the cable run and
/// the clearance zones, the same pieces as `BatteryOverlay` draws over a replay. Built from
/// `WallGeometry` in world axes with the meter at the origin, so it turns a corner where the wall does.
@MainActor
enum ResultARModel {
    /// The LiDAR mesh sits a centimeter or two off the real wall and ground, and hides whatever is
    /// behind it: anything flush with either would be cut into.
    static let meshClearance: Float = 0.03

    private static let unitName = "result-ar-battery"

    static func build(wall: WallGeometry, result: ResultPresentation) -> Entity {
        let root = Entity()
        func local(_ s: Float, _ height: Float, _ out: Float) -> SIMD3<Float> {
            wall.world(s: s, height: height, out: out) - wall.meter
        }
        for (index, zone) in result.clearances.enumerated() {
            var material = UnlitMaterial(color: SceneColor.outcome(zone.outcome))
            material.blending = .transparent(opacity: .init(floatLiteral: 0.35))
            let width = zone.span.upperBound - zone.span.lowerBound
            let middle = zone.span.lowerBound + width / 2
            // Stacked zones sit a few millimeters apart so overlapping ones don't flicker.
            let entity = ModelEntity(mesh: .generatePlane(width: width, depth: zone.depth), materials: [material])
            entity.position = local(middle, meshClearance + Float(index) * 0.003, zone.depth / 2)
            entity.orientation = facing(wall, atS: middle)
            root.addChild(entity)
        }
        let cable = result.cableRoute.map { local($0.x, $0.y, meshClearance) }
        let material = SimpleMaterial(color: SceneColor.signal, roughness: 0.85, isMetallic: false)
        let radius: Float = 0.015
        for (from, to) in zip(cable, cable.dropFirst()) {
            let length = simd_distance(from, to)
            guard length > 0.001 else { continue }
            let segment = ModelEntity(mesh: .generateCylinder(height: length, radius: radius), materials: [material])
            segment.position = (from + to) / 2
            segment.orientation = simd_quatf(from: SIMD3(0, 1, 0), to: (to - from) / length)
            root.addChild(segment)
        }
        for point in cable.dropFirst().dropLast() {
            let joint = ModelEntity(mesh: .generateSphere(radius: radius), materials: [material])
            joint.position = point
            root.addChild(joint)
        }
        if let spot = result.spot {
            let width = max(spot.span.upperBound - spot.span.lowerBound, 0.1)
            let middle = (spot.span.lowerBound + spot.span.upperBound) / 2
            let back = max(spot.offsetFromWall, meshClearance)
            // Origin at the middle of the footprint on the ground, so `rise` grows it upward.
            let unit = Entity()
            unit.name = unitName
            unit.position = local(middle, 0, back + spot.depth / 2)
            unit.orientation = facing(wall, atS: middle)
            var paint = PhysicallyBasedMaterial()
            paint.baseColor = .init(tint: SceneColor.battery)
            paint.roughness = 0.35
            let corner = min(0.03, min(width, spot.height, spot.depth) / 4)
            let body = ModelEntity(
                mesh: .generateBox(width: width, height: spot.height, depth: spot.depth, cornerRadius: corner),
                materials: [paint]
            )
            body.position = SIMD3(0, spot.height / 2, 0)
            body.components.set(GroundingShadowComponent(castsShadow: true))
            unit.addChild(body)
            let bar = ModelEntity(
                mesh: .generateBox(width: 0.04, height: spot.height * 0.7, depth: 0.006),
                materials: [UnlitMaterial(color: SceneColor.signal)]
            )
            bar.position = SIMD3(0, spot.height / 2, spot.depth / 2 + 0.003)
            unit.addChild(bar)
            root.addChild(unit)
        }
        return root
    }

    /// Lifts the battery out of the ground. Call once the model is in the scene.
    static func rise(_ model: Entity) {
        guard let unit = model.findEntity(named: unitName) else { return }
        let settled = unit.transform
        unit.scale = SIMD3(1, 0.02, 1)
        unit.move(to: settled, relativeTo: unit.parent, duration: UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.7, timingFunction: .easeOut)
    }

    /// x along the wall, y up, z out from the wall toward the homeowner.
    private static func facing(_ wall: WallGeometry, atS s: Float) -> simd_quatf {
        let up = SIMD3<Float>(0, 1, 0)
        let outward = simd_normalize(wall.outward(atS: s))
        return simd_quatf(simd_float3x3(columns: (simd_normalize(simd_cross(up, outward)), up, outward)))
    }
}

/// Fixed scene colors. They match the asset-catalog palette in light mode; a model of a house
/// in daylight shouldn't change color with the phone's dark mode.
private enum SceneColor {
    static var signal: UIColor { rgb(0x1F66F2) }
    static var wall: UIColor { rgb(0xE3D7C3) }
    static var ground: UIColor { rgb(0x6F7F5E) }
    static var meter: UIColor { rgb(0x8E949C) }
    static var battery: UIColor { rgb(0xF4F5F7) }
    static var opening: UIColor { rgb(0x7F93A8) }
    static var gas: UIColor { rgb(0xD9B84A) }
    static var driveway: UIColor { rgb(0x5A5E63) }
    static var fence: UIColor { rgb(0x9A8466) }

    static func outcome(_ outcome: CheckOutcome) -> UIColor {
        switch outcome {
        case .pass: rgb(0x2FC273)
        case .unsure: rgb(0xF5B53D)
        case .fail: rgb(0xFF5A4E)
        }
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
