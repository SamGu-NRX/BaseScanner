import Foundation
import HouseScanKit
import simd
import Testing

// The scale fit and per-pixel sigma of MonocularDepth, on predictions made from known depth:
// prediction = (1 / depth - shift) / scale, the relation the fit inverts.

/// A photo camera (1920 x 1440, ARKit's wide camera) at `position` looking at `target`, landscape.
func photoCamera(at position: SIMD3<Float>, lookingAt target: SIMD3<Float>) -> CameraFrame {
    let f = simd_normalize(target - position)
    let r = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
    let u = simd_cross(r, f)
    let m = simd_float4x4(SIMD4(r, 0), SIMD4(u, 0), SIMD4(-f, 0), SIMD4(position, 1))
    return CameraFrame(cameraToWorld: m, intrinsics: SIMD4(1450, 1450, 960, 720), imageSize: SIMD2(1920, 1440))
}

@Suite struct MonocularDepthTests {
    static let scale: Float = 0.5
    static let shift: Float = 0.1

    /// A 64 x 48 prediction of a depth field given per image fraction.
    static func prediction(width: Int = 64, height: Int = 48, _ depth: (SIMD2<Float>) -> Float) -> RelativeInverseDepth {
        var values: [Float] = []
        for v in 0..<height {
            for u in 0..<width {
                let z = depth(SIMD2((Float(u) + 0.5) / Float(width), (Float(v) + 0.5) / Float(height)))
                values.append((1 / z - shift) / scale)
            }
        }
        return RelativeInverseDepth(width: width, height: height, values: values)
    }

    /// Depth rising from 2 m at the left edge to 4 m at the right.
    static func ramp(_ f: SIMD2<Float>) -> Float { 2 + 2 * f.x }

    /// Anchors on a `columns` x `rows` grid at pixel centers of the 64 x 48 prediction, so the
    /// bilinear value there is exact.
    static func anchors(columns: Int, rows: Int, _ depth: (SIMD2<Float>) -> Float) -> [DepthAnchor] {
        (0..<rows).flatMap { row in
            (0..<columns).map { column in
                let fraction = SIMD2((Float(column * 64 / columns) + 0.5) / 64, (Float(row * 48 / rows) + 0.5) / 48)
                return DepthAnchor(fraction: fraction, depth: depth(fraction))
            }
        }
    }

    @Test func recoversAKnownScaleAndShift() throws {
        let fit = try #require(MonocularDepth.fit(Self.prediction(Self.ramp), anchors: Self.anchors(columns: 10, rows: 6, Self.ramp)))
        #expect(abs(fit.scale - Self.scale) < 1e-4 && abs(fit.shift - Self.shift) < 1e-4, "\(fit.scale) \(fit.shift)")
        #expect(fit.inlierCount == 60 && fit.anchorCount == 60)
        #expect(fit.relativeSigma < 1e-4)
        #expect(abs(fit.anchorDepths.lowerBound - Self.ramp(SIMD2(0.5 / 64, 0))) < 1e-3)
    }

    /// 25 of 85 anchors half again as deep as the prediction says (a plane's extent behind a
    /// box, a mismatched feature): the fit keeps to the other 60.
    @Test func setsOutliersAside() throws {
        let good = Self.anchors(columns: 10, rows: 6, Self.ramp)
        let bad = Self.anchors(columns: 5, rows: 5, Self.ramp).map { DepthAnchor(fraction: $0.fraction + SIMD2(0.004, 0.004), depth: $0.depth * 1.5) }
        let fit = try #require(MonocularDepth.fit(Self.prediction(Self.ramp), anchors: good + bad))
        #expect(abs(fit.scale - Self.scale) < 1e-3 && abs(fit.shift - Self.shift) < 1e-3, "\(fit.scale) \(fit.shift)")
        #expect(fit.inlierCount == 60 && fit.anchorCount == 85)
    }

    @Test func tooFewAnchorsGiveNoFit() {
        #expect(MonocularDepth.fit(Self.prediction(Self.ramp), anchors: Array(Self.anchors(columns: 10, rows: 6, Self.ramp).prefix(19))) == nil)
    }

    /// Outliers outnumbering the anchors that agree: no fit rather than a guess.
    @Test func mostlyOutliersGiveNoFit() {
        let good = Array(Self.anchors(columns: 10, rows: 6, Self.ramp).prefix(12))
        let bad = Self.anchors(columns: 6, rows: 3, Self.ramp).enumerated().map { index, anchor in
            DepthAnchor(fraction: anchor.fraction, depth: anchor.depth * (index % 2 == 0 ? 1.6 : 0.55) * (1 + Float(index) * 0.03))
        }
        #expect(MonocularDepth.fit(Self.prediction(Self.ramp), anchors: good + bad) == nil)
    }

    /// Anchors that put the prediction's near side far: no fit.
    @Test func reversedOrderGivesNoFit() {
        let reversed = Self.anchors(columns: 10, rows: 6, Self.ramp).map { DepthAnchor(fraction: $0.fraction, depth: 6 - $0.depth) }
        #expect(MonocularDepth.fit(Self.prediction(Self.ramp), anchors: reversed) == nil)
    }

    /// Anchors off by 5% alternately up and down, on the app's 16 x 12 plane grid: the fit's
    /// relative sigma is the robust scale of that, and each pixel's sigma at least depth times it.
    @Test func sigmaIsTheResidualScaleTimesDepth() throws {
        let anchors = Self.anchors(columns: 16, rows: 12, Self.ramp).enumerated().map { index, anchor in
            DepthAnchor(fraction: anchor.fraction, depth: anchor.depth * (index % 2 == 0 ? 1.05 : 0.95))
        }
        let prediction = Self.prediction(Self.ramp)
        let fit = try #require(MonocularDepth.fit(prediction, anchors: anchors))
        // Residuals are about +-5%; 1.4826 * 0.05 * (1 + 5 / 190) = 0.0761.
        #expect(abs(fit.relativeSigma - 0.0761) < 0.004, "\(fit.relativeSigma)")
        let photo = photoCamera(at: .zero, lookingAt: SIMD3(0, 0, -1))
        let frame = try #require(MonocularDepth.depthFrame(prediction, fit: fit, photo: photo))
        guard case .estimated(let sigma) = frame.kind else { Issue.record("not estimated"); return }
        let middle = 96 * frame.width + 128
        let z = frame.depth[middle]
        #expect(abs(z - Self.ramp(SIMD2(128.5 / 256, 0))) < 0.02 * z)
        #expect(sigma[middle] >= z * fit.relativeSigma && sigma[middle] < z * fit.relativeSigma * 1.2, "sigma \(sigma[middle]) at \(z) m")
    }

    /// Exact anchors: every pixel's sigma is the floor, 2% of depth and at least 2 cm.
    @Test func exactAnchorsGiveTheFloor() throws {
        let prediction = Self.prediction(Self.ramp)
        let fit = try #require(MonocularDepth.fit(prediction, anchors: Self.anchors(columns: 10, rows: 6, Self.ramp)))
        let frame = try #require(MonocularDepth.depthFrame(prediction, fit: fit, photo: photoCamera(at: .zero, lookingAt: SIMD3(0, 0, -1))))
        guard case .estimated(let sigma) = frame.kind else { Issue.record("not estimated"); return }
        for index in Swift.stride(from: 0, to: frame.depth.count, by: 97) where frame.depth[index] > 0 {
            #expect(abs(sigma[index] - max(0.02 * frame.depth[index], 0.02)) < 1e-3, "sigma \(sigma[index]) at \(frame.depth[index])")
        }
    }

    /// A box 1 m nearer than the wall behind it in the middle of the image: pixels within two
    /// of its edge are uncertain by half the jump; pixels well away from it are not.
    @Test func sigmaWidensAtADepthEdge() throws {
        func scene(_ f: SIMD2<Float>) -> Float { f.x > 0.4 && f.x < 0.6 && f.y > 0.3 && f.y < 0.7 ? 2 : 3 }
        let prediction = Self.prediction(width: 256, height: 192, scene)
        // Anchors at pixel centers of the 256 x 192 prediction, 16 across and 12 down.
        var anchors: [DepthAnchor] = []
        for row in 0..<12 {
            for column in 0..<16 {
                let pixel = SIMD2<Float>(Float(column * 16 + 8) + 0.5, Float(row * 16 + 8) + 0.5)
                let fraction = pixel / SIMD2<Float>(256, 192)
                anchors.append(DepthAnchor(fraction: fraction, depth: scene(fraction)))
            }
        }
        let fit = try #require(MonocularDepth.fit(prediction, anchors: anchors))
        let frame = try #require(MonocularDepth.depthFrame(prediction, fit: fit, photo: photoCamera(at: .zero, lookingAt: SIMD3(0, 0, -1))))
        guard case .estimated(let sigma) = frame.kind else { Issue.record("not estimated"); return }
        // The box starts at output column 102 (its center, 102.5 / 256, is past 0.4).
        let row = 96 * 256
        let wallBeside: Float = sigma[row + 101]
        let boxBeside: Float = sigma[row + 103]
        let wallAway: Float = sigma[row + 60]
        let boxAway: Float = sigma[row + 128]
        #expect(wallBeside >= 0.499, "wall beside the edge: \(wallBeside)")
        #expect(boxBeside >= 0.499, "box beside the edge: \(boxBeside)")
        #expect(wallAway < 0.1, "wall away from the edge: \(wallAway)")
        #expect(boxAway < 0.1, "box away from the edge: \(boxAway)")
    }

    /// Anchors only on the left half: the right half gets no depth, since nothing there checked
    /// the model.
    @Test func noDepthWhereNoAnchorIsNear() throws {
        let prediction = Self.prediction(Self.ramp)
        let left = Self.anchors(columns: 10, rows: 6, Self.ramp).filter { $0.fraction.x < 0.5 }
        let fit = try #require(MonocularDepth.fit(prediction, anchors: left + left.map { DepthAnchor(fraction: $0.fraction + SIMD2(0.02, 0.02), depth: Self.ramp($0.fraction + SIMD2(0.02, 0.02))) }))
        let frame = try #require(MonocularDepth.depthFrame(prediction, fit: fit, photo: photoCamera(at: .zero, lookingAt: SIMD3(0, 0, -1))))
        #expect(frame.depth[96 * 256 + 40] > 0)
        #expect(frame.depth[96 * 256 + 250] == 0)
    }

    /// Anchors that agree with the model only up to 3.2 m (the right two fifths are outliers):
    /// pixels the fit puts past 10% beyond that get no depth, and the last pixel before them is
    /// as uncertain as can be.
    @Test func noDepthBeyondTheAnchorsDepths() throws {
        let prediction = Self.prediction(Self.ramp)
        let near = Self.anchors(columns: 16, rows: 12, Self.ramp).map { anchor in
            anchor.depth <= 3.2 ? anchor : DepthAnchor(fraction: anchor.fraction, depth: anchor.depth * 0.5)
        }
        let fit = try #require(MonocularDepth.fit(prediction, anchors: near))
        #expect(fit.anchorDepths.upperBound <= 3.2)
        let frame = try #require(MonocularDepth.depthFrame(prediction, fit: fit, photo: photoCamera(at: .zero, lookingAt: SIMD3(0, 0, -1))))
        guard case .estimated(let sigma) = frame.kind else { Issue.record("not estimated"); return }
        let farthest = frame.depth.max() ?? 0
        #expect(farthest <= fit.anchorDepths.upperBound * 1.1 + 1e-3, "\(farthest)")
        let edge = (0..<256).last { frame.depth[96 * 256 + $0] > 0 }!
        #expect(sigma[96 * 256 + edge] == MonocularDepth.farSigma)
    }

    @Test func anchorsFromPointsKeepThoseInView() {
        let camera = photoCamera(at: SIMD3(0, 1.4, 2), lookingAt: SIMD3(0, 1.4, 0))
        let anchors = DepthAnchor.anchors(points: [SIMD3(0, 1.4, 0), SIMD3(0.5, 1.0, 0.5), SIMD3(0, 1.4, 3), SIMD3(20, 1.4, 0)], camera: camera)
        #expect(anchors.count == 2)
        #expect(abs(anchors[0].depth - 2) < 1e-4 && simd_distance(anchors[0].fraction, SIMD2(0.5, 0.5)) < 1e-4)
        #expect(abs(anchors[1].depth - 1.5) < 1e-4)
    }

    @Test func anchorsFromAPlaneLieOnIt() {
        let camera = photoCamera(at: SIMD3(0, 1.4, 2), lookingAt: SIMD3(0, 1.4, 0))
        // A wall plane at z = 0 facing +z: plane-local y along world +z.
        let wall = PlaneObservation(
            id: UUID(), worldFromPlane: simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 1.4, 0, 1)),
            alignment: .vertical, center: .zero, width: 2, length: 2)
        let anchors = DepthAnchor.anchors(planes: [wall], camera: camera)
        #expect(!anchors.isEmpty)
        for anchor in anchors { #expect(abs(anchor.depth - 2) < 1e-3) }
        // A 2 m square seen from 2 m covers the middle of a 67 x 53 degree view, not its corners.
        #expect(!anchors.contains { $0.fraction.x < 0.1 || $0.fraction.x > 0.9 })
    }

    /// End to end on a wall 1.5 m away: a prediction rendered at the model's 518 x 392 from the
    /// photo's view, anchors from the scene's surface points, and the depth frame it builds agree
    /// with the scene pixel for pixel, so the image fractions and intrinsics line up.
    @Test func depthFrameMatchesTheSceneItWasFittedTo() throws {
        let scene = SyntheticScene(walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(5, 0))])
        let photo = photoCamera(at: SIMD3(0.3, 1.4, 1.5), lookingAt: SIMD3(-0.4, 0.8, 0))
        func depth(_ f: SIMD2<Float>) -> Float {
            let ray = photo.ray(throughPixel: f * photo.imageSize)
            guard let hit = scene.intersect(origin: ray.origin, direction: ray.direction) else { return 50 }
            return hit.t * simd_dot(ray.direction, photo.forward)
        }
        let prediction = Self.prediction(width: 518, height: 392, depth)
        var points: [SIMD3<Float>] = []
        for row in 0..<12 {
            for column in 0..<16 {
                let fraction = SIMD2<Float>((Float(column) + 0.5) / 16, (Float(row) + 0.5) / 12)
                let ray = photo.ray(throughPixel: fraction * photo.imageSize)
                if let hit = scene.intersect(origin: ray.origin, direction: ray.direction) { points.append(ray.at(hit.t)) }
            }
        }
        let estimate = try #require(MonocularDepth.estimate(prediction, anchors: DepthAnchor.anchors(points: points, camera: photo), photo: photo))
        let frame = estimate.frame
        #expect(frame.width == 256 && frame.height == 192)
        var checked = 0
        for v in Swift.stride(from: 10, to: 182, by: 17) {
            for u in Swift.stride(from: 10, to: 246, by: 19) where frame.depth[v * 256 + u] > 0 {
                let ray = frame.camera.ray(throughPixel: SIMD2(Float(u) + 0.5, Float(v) + 0.5))
                let hit = try #require(scene.intersect(origin: ray.origin, direction: ray.direction))
                let truth: Float = hit.t * simd_dot(ray.direction, frame.camera.forward)
                let estimated: Float = frame.depth[v * 256 + u]
                #expect(abs(estimated - truth) < 0.005 * truth, "pixel \(u), \(v): \(estimated) vs \(truth)")
                checked += 1
            }
        }
        #expect(checked > 100, "\(checked) pixels with depth")
    }
}
