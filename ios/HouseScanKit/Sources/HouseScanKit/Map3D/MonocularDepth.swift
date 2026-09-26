import Foundation
import simd

// Metric depth for a phone without LiDAR: a monocular model's relative depth, scaled per frame by
// points ARKit measured in that frame. The model alone gives depth only up to an unknown scale
// and shift; taking its scale from the model was 4 to 12% off (S1's measurement), so the scale
// comes only from ARKit's own geometry, and a frame without enough of it gets no depth.

/// A monocular model's output for one camera image: inverse depth up to an unknown scale and
/// shift, larger nearer (Depth Anything V2's relative output). It covers the camera image's whole
/// view, stretched to the model's size: pixel (u, v) covers the image fractions u / width to
/// (u + 1) / width across and v / height to (v + 1) / height down, row `v` from the top of the
/// unrotated landscape image.
public struct RelativeInverseDepth: Sendable {
    public let width: Int
    public let height: Int
    /// Row by row from the top.
    public let values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        precondition(width > 1 && height > 1 && values.count == width * height, "\(values.count) values for \(width) x \(height)")
        self.width = width
        self.height = height
        self.values = values
    }

    /// Bilinear between the four pixel centers around a point given as fractions of the image,
    /// clamped at the edges; nil when any of the four is not finite.
    public func value(at fraction: SIMD2<Float>) -> Float? {
        let x = min(max(fraction.x * Float(width) - 0.5, 0), Float(width - 1))
        let y = min(max(fraction.y * Float(height) - 0.5, 0), Float(height - 1))
        let x0 = min(Int(x), width - 2)
        let y0 = min(Int(y), height - 2)
        let fx = x - Float(x0)
        let fy = y - Float(y0)
        let a = values[y0 * width + x0]
        let b = values[y0 * width + x0 + 1]
        let c = values[(y0 + 1) * width + x0]
        let d = values[(y0 + 1) * width + x0 + 1]
        let value = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
        return value.isFinite ? value : nil
    }
}

/// A point of the frame whose metric depth ARKit measured: a tracked feature point or a point on
/// a detected plane.
public struct DepthAnchor: Sendable, Equatable {
    /// Where it lies in the image, as fractions of the image's width and height from its top-left
    /// corner.
    public var fraction: SIMD2<Float>
    /// Meters along the camera's -z.
    public var depth: Float

    public init(fraction: SIMD2<Float>, depth: Float) {
        self.fraction = fraction
        self.depth = depth
    }

    /// World points (ARKit's `rawFeaturePoints`) that lie in front of `camera`, inside its image
    /// and between `minDepth` and `maxDepth`.
    public static func anchors(points: [SIMD3<Float>], camera: CameraFrame, minDepth: Float = 0.2, maxDepth: Float = 8) -> [DepthAnchor] {
        points.compactMap { point in
            let depth = -camera.cameraSpace(point).z
            guard depth >= minDepth, depth <= maxDepth, let pixel = camera.pixel(of: point), camera.contains(pixel: pixel) else { return nil }
            return DepthAnchor(fraction: pixel / camera.imageSize, depth: depth)
        }
    }

    /// Where rays through a `columns` x `rows` grid of pixels first meet a detected plane inside
    /// its extent, between `minDepth` and `maxDepth`. A plane's extent can run behind something
    /// standing in front of it; such a point disagrees with the model and the fit rejects it.
    public static func anchors(planes: [PlaneObservation], camera: CameraFrame, columns: Int = 16, rows: Int = 12, minDepth: Float = 0.2, maxDepth: Float = 8) -> [DepthAnchor] {
        let surfaces = planes.compactMap { plane -> (point: SIMD3<Float>, normal: SIMD3<Float>, planeFromWorld: simd_float4x4, boundary: [SIMD2<Float>])? in
            guard plane.boundary.count >= 3 else { return nil }
            let m = plane.worldFromPlane
            let normal = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
            guard simd_length_squared(normal) > 0 else { return nil }
            return (SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), simd_normalize(normal), m.inverse, plane.boundary)
        }
        guard !surfaces.isEmpty, columns > 0, rows > 0 else { return [] }
        var anchors: [DepthAnchor] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let fraction = SIMD2((Float(column) + 0.5) / Float(columns), (Float(row) + 0.5) / Float(rows))
                let ray = camera.ray(throughPixel: fraction * camera.imageSize)
                var nearest: Float?
                for surface in surfaces {
                    guard let t = ray.intersect(planePoint: surface.point, normal: surface.normal), t < nearest ?? .infinity else { continue }
                    let local = surface.planeFromWorld * SIMD4(ray.at(t), 1)
                    guard Map3D.polygon(surface.boundary, contains: SIMD2(local.x, local.z)) else { continue }
                    nearest = t
                }
                guard let t = nearest else { continue }
                let depth = -camera.cameraSpace(ray.at(t)).z
                guard depth >= minDepth, depth <= maxDepth else { continue }
                anchors.append(DepthAnchor(fraction: fraction, depth: depth))
            }
        }
        return anchors
    }
}

/// Settings of the scale fit and the per-pixel uncertainty. Each value is a hypothesis unless its
/// comment says what measured it.
public struct MonocularDepthConfig: Sendable, Equatable {
    /// A frame with fewer anchors than this gets no depth. Two points fix a scale and shift; 20
    /// leave enough over them for the residuals to say how good the fit is.
    public var minAnchors = 20
    /// A relative depth residual within this makes an anchor an inlier of a candidate fit.
    public var inlierResidual: Float = 0.1
    /// A fit must explain at least this share of the anchors, or the frame gets no depth: the
    /// residual scale is a median over all anchors and means little once most are outliers.
    public var minInlierShare: Float = 0.5
    /// Pairs of anchors tried as candidate fits; all pairs when there are fewer.
    public var candidatePairs = 300
    /// A pixel takes the residuals of the anchors within this distance, as a fraction of the
    /// image's width, as its local check on the model (about 5 degrees on an iPhone's wide
    /// camera). One global fit says nothing about a part of the image no anchor fell on: on ETH3D
    /// electro, ground with no anchor on it came out more than twice too far from a fit to a wall.
    public var supportRadius: Float = 0.08
    /// A pixel with fewer anchors than this within `supportRadius` gets no depth.
    public var minSupport = 3
    /// Least relative standard deviation of any pixel. The residual scales can come out small
    /// when the anchors lie on one smooth surface the model got right. A guess, not measured.
    public var relativeSigmaFloor: Float = 0.02
    /// Least standard deviation of any pixel, meters: about ARKit's plane and feature position
    /// noise. A guess, not measured.
    public var sigmaFloor: Float = 0.02
    /// Output pixels within this many of a pixel (a 5 x 5 window at 2) widen its deviation to
    /// half the largest depth difference among them. Mono models blur depth across edges by a
    /// pixel or two of their own, about one output pixel at 518 to 256: a pixel near an edge may
    /// belong to either side.
    public var edgeRadius = 2
    /// Depths more than this fraction beyond the nearest and farthest inlier anchors are not
    /// estimated: the fit was only measured between them.
    public var extrapolation: Float = 0.1
    /// Size of the depth frame built, ARKit's LiDAR depth size so Map3D treats both alike.
    public var outputWidth = 256
    public var outputHeight = 192

    public init() {}
}

/// Inverse depth = `scale` * prediction + `shift`, fitted to one frame's anchors.
public struct InverseDepthFit: Sendable, Equatable {
    public var scale: Float
    public var shift: Float
    public var anchorCount: Int
    public var inlierCount: Int
    /// Robust standard deviation of the anchors' relative depth residuals: 1.4826 times their
    /// median absolute value (the normal distribution's MAD factor), times 1 + 5 / (n - 2), the
    /// small-sample correction for a median-based scale of a two-parameter fit (Rousseeuw and
    /// Leroy 1987). Taken over every anchor, outliers too, so it errs wide.
    public var relativeSigma: Float
    /// Covariance of (`scale`, `shift`) from the least-squares fit on the inliers, with
    /// `relativeSigma` as the residual deviation: variance of scale, covariance, variance of shift.
    public var covariance: SIMD3<Float>
    /// Nearest and farthest inlier anchor depths, meters.
    public var anchorDepths: ClosedRange<Float>
    /// Every anchor's place in the image and relative depth residual under the fit.
    public var residuals: [Residual]

    public struct Residual: Sendable, Equatable {
        public var fraction: SIMD2<Float>
        public var residual: Float
    }

    /// Metric depth for a prediction, or nil where the fit gives none (at or past infinity).
    public func depth(_ prediction: Float) -> Float? {
        let inverse = scale * prediction + shift
        return inverse > 0 ? 1 / inverse : nil
    }

    /// Relative deviation of the depth at `prediction` that comes from the fit's own uncertainty:
    /// depth times the deviation of scale * prediction + shift. It grows as a prediction lies
    /// farther from the anchors' predictions, where the fit extrapolates.
    public func parameterSigma(_ prediction: Float, depth: Float) -> Float {
        let variance = covariance.x * prediction * prediction + 2 * covariance.y * prediction + covariance.z
        return depth * max(variance, 0).squareRoot()
    }
}

public enum MonocularDepth {
    /// The robust affine fit of 1 / depth to the prediction at the anchors, or nil when there
    /// are fewer than `minAnchors`, too few inliers, or the fit makes nearer things farther.
    ///
    /// Residuals are relative depth errors, depth * (scale * p + shift) - 1, so a far anchor
    /// counts as much as a near one. Candidate fits through pairs of anchors (RANSAC) pick the
    /// inliers; least squares on the inliers then refines it, three times at most.
    public static func fit(_ prediction: RelativeInverseDepth, anchors: [DepthAnchor], config: MonocularDepthConfig = MonocularDepthConfig()) -> InverseDepthFit? {
        var samples: [(p: Double, z: Double, fraction: SIMD2<Float>)] = []
        samples.reserveCapacity(anchors.count)
        for anchor in anchors where anchor.depth.isFinite && anchor.depth > 0 {
            guard let p = prediction.value(at: anchor.fraction) else { continue }
            samples.append((Double(p), Double(anchor.depth), anchor.fraction))
        }
        let n = samples.count
        guard n >= max(config.minAnchors, 3) else { return nil }
        let threshold = Double(config.inlierResidual)
        func residual(_ i: Int, _ a: Double, _ b: Double) -> Double { samples[i].z * (a * samples[i].p + b) - 1 }
        func inliers(_ a: Double, _ b: Double) -> [Int] { samples.indices.filter { abs(residual($0, a, b)) <= threshold } }

        var best: (a: Double, b: Double, count: Int, cost: Double)?
        func consider(_ i: Int, _ j: Int) {
            let dp = samples[i].p - samples[j].p
            guard abs(dp) > 1e-9 else { return }
            let a = (1 / samples[i].z - 1 / samples[j].z) / dp
            guard a > 0 else { return }
            let b = 1 / samples[i].z - a * samples[i].p
            var count = 0
            var cost = 0.0
            for k in 0..<n {
                let r = abs(residual(k, a, b))
                if r <= threshold { count += 1; cost += r }
            }
            if let current = best, count < current.count || (count == current.count && cost >= current.cost) { return }
            best = (a, b, count, cost)
        }
        if n * (n - 1) / 2 <= config.candidatePairs {
            for i in 0..<n { for j in (i + 1)..<n { consider(i, j) } }
        } else {
            // A fixed seed, so a frame always gets the same fit.
            var generator = SplitMix64(seed: UInt64(n))
            for _ in 0..<config.candidatePairs {
                let i = Int(generator.next() % UInt64(n))
                let j = Int(generator.next() % UInt64(n - 1))
                consider(i, j < i ? j : j + 1)
            }
        }
        guard var (a, b, _, _) = best else { return nil }
        var kept = inliers(a, b)
        // Normal matrix of the least squares z (a p + b) = 1 over the kept anchors.
        func normal(_ indices: [Int]) -> simd_double2x2 {
            var m = simd_double2x2()
            for i in indices {
                let row = SIMD2(samples[i].z * samples[i].p, samples[i].z)
                m += simd_double2x2(rows: [row * row.x, row * row.y])
            }
            return m
        }
        for _ in 0..<3 {
            let m = normal(kept)
            guard abs(m.determinant) > 1e-18 else { break }
            var y = SIMD2<Double>.zero
            for i in kept { y += SIMD2(samples[i].z * samples[i].p, samples[i].z) }
            let solved = m.inverse * y
            guard solved.x > 0 else { break }
            let refined = inliers(solved.x, solved.y)
            guard refined.count >= kept.count else { break }
            (a, b) = (solved.x, solved.y)
            let changed = refined != kept
            kept = refined
            if !changed { break }
        }
        let m = normal(kept)
        guard a > 0, Double(kept.count) >= Double(config.minInlierShare) * Double(n), kept.count >= 3, abs(m.determinant) > 1e-18 else { return nil }
        let residuals = (0..<n).map { residual($0, a, b) }
        let absolute = residuals.map(abs).sorted()
        let median = n % 2 == 1 ? absolute[n / 2] : (absolute[n / 2 - 1] + absolute[n / 2]) / 2
        let sigma = 1.4826 * median * (1 + 5 / Double(n - 2))
        let covariance = m.inverse * (sigma * sigma)
        let depths = kept.map { samples[$0].z }
        return InverseDepthFit(
            scale: Float(a), shift: Float(b), anchorCount: n, inlierCount: kept.count, relativeSigma: Float(sigma),
            covariance: SIMD3(Float(covariance[0, 0]), Float(covariance[1, 0]), Float(covariance[1, 1])),
            anchorDepths: Float(depths.min()!)...Float(depths.max()!),
            residuals: (0..<n).map { InverseDepthFit.Residual(fraction: samples[$0].fraction, residual: Float(residuals[$0])) })
    }

    /// The fitted depth and its per-pixel standard deviation, as a `DepthFrame` for `photo`'s
    /// view at `outputWidth` x `outputHeight`, or nil when no pixel has depth.
    ///
    /// Each output pixel takes the prediction at its center. Its relative deviation combines, as
    /// independent errors, the fit's (`parameterSigma`) and the model's: the largest of the fit's
    /// `relativeSigma`, the local scale (1.4826 times the median absolute residual of the anchors
    /// within `supportRadius`) and `relativeSigmaFloor`. Its deviation is then the largest of:
    /// - depth times that relative deviation;
    /// - half the largest depth difference to the pixels within `edgeRadius`, so a pixel next to
    ///   an edge is uncertain by the edge's whole jump (twice the deviation, the span `Map3D`
    ///   carves short of a depth, then reaches the nearer side);
    /// - `sigmaFloor`.
    ///
    /// No depth (0) where the fit gives none, where fewer than `minSupport` anchors lie within
    /// `supportRadius`, or at a depth beyond `extrapolation` past the inlier anchors' depths. A
    /// pixel next to one without a depth from the fit takes a deviation of `farSigma`, because a
    /// blurred edge against the sky reads farther than it is.
    public static func depthFrame(_ prediction: RelativeInverseDepth, fit: InverseDepthFit, photo: CameraFrame, config: MonocularDepthConfig = MonocularDepthConfig()) -> DepthFrame? {
        let w = config.outputWidth
        let h = config.outputHeight
        let near = fit.anchorDepths.lowerBound / (1 + config.extrapolation)
        let far = fit.anchorDepths.upperBound * (1 + config.extrapolation)
        // Depth everywhere the fit gives one, NaN elsewhere, before the range is applied: the
        // edge term needs the depth on both sides of an edge.
        var raw = [Float](repeating: .nan, count: w * h)
        var predictions = [Float](repeating: .nan, count: w * h)
        for v in 0..<h {
            for u in 0..<w {
                let fraction = SIMD2((Float(u) + 0.5) / Float(w), (Float(v) + 0.5) / Float(h))
                guard let p = prediction.value(at: fraction) else { continue }
                predictions[v * w + u] = p
                if let z = fit.depth(p) { raw[v * w + u] = z }
            }
        }
        let local = localScale(fit.residuals, width: w, height: h, aspect: photo.imageSize.y / photo.imageSize.x, config: config)
        let model = max(fit.relativeSigma, config.relativeSigmaFloor)
        let r = max(0, config.edgeRadius)
        var depth = [Float](repeating: 0, count: w * h)
        var sigma = [Float](repeating: 0, count: w * h)
        var any = false
        for v in 0..<h {
            for u in 0..<w {
                let z = raw[v * w + u]
                guard z.isFinite, z >= near, z <= far, let localSigma = local[v * w + u] else { continue }
                var jump: Float = 0
                for dv in -r...r {
                    let y = v + dv
                    guard y >= 0, y < h else { continue }
                    for du in -r...r {
                        let x = u + du
                        guard x >= 0, x < w else { continue }
                        let q = raw[y * w + x]
                        jump = max(jump, q.isFinite && q <= far ? abs(q - z) : farSigma * 2)
                    }
                }
                let modelSigma = max(model, localSigma)
                let fitSigma = fit.parameterSigma(predictions[v * w + u], depth: z)
                let relative = (modelSigma * modelSigma + fitSigma * fitSigma).squareRoot()
                depth[v * w + u] = z
                sigma[v * w + u] = max(z * relative, jump / 2, config.sigmaFloor)
                any = true
            }
        }
        guard any else { return nil }
        return DepthFrame(photo: photo, width: w, height: h, depth: depth, kind: .estimated(sigma: sigma))
    }

    /// Per output pixel, the local relative scale of the model's error: 1.4826 times the median
    /// absolute residual of the anchors within `supportRadius`, or nil with fewer than
    /// `minSupport` of them. Computed per 4 x 4 block of pixels, at the block's center.
    static func localScale(_ residuals: [InverseDepthFit.Residual], width: Int, height: Int, aspect: Float, config: MonocularDepthConfig) -> [Float?] {
        let block = 4
        let columns = (width + block - 1) / block
        let rows = (height + block - 1) / block
        let radius2 = config.supportRadius * config.supportRadius
        var cells = [Float?](repeating: nil, count: columns * rows)
        var nearby: [Float] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let center = SIMD2(
                    (Float(min(column * block + block / 2, width - 1)) + 0.5) / Float(width),
                    (Float(min(row * block + block / 2, height - 1)) + 0.5) / Float(height))
                nearby.removeAll(keepingCapacity: true)
                for anchor in residuals {
                    // Distances in units of the image's width.
                    let d = SIMD2(anchor.fraction.x - center.x, (anchor.fraction.y - center.y) * aspect)
                    if simd_length_squared(d) <= radius2 { nearby.append(abs(anchor.residual)) }
                }
                guard nearby.count >= max(1, config.minSupport) else { continue }
                nearby.sort()
                let k = nearby.count
                let median = k % 2 == 1 ? nearby[k / 2] : (nearby[k / 2 - 1] + nearby[k / 2]) / 2
                cells[row * columns + column] = 1.4826 * median
            }
        }
        return (0..<(width * height)).map { index in cells[(index / width / block) * columns + (index % width) / block] }
    }

    /// Deviation for a pixel next to one with no depth, meters: beyond anything `Map3D` measures,
    /// so it carves no free space and marks no surface.
    public static let farSigma: Float = 100

    /// The fit and depth frame for one camera image in one call; nil when the fit fails.
    public static func estimate(_ prediction: RelativeInverseDepth, anchors: [DepthAnchor], photo: CameraFrame, config: MonocularDepthConfig = MonocularDepthConfig()) -> (fit: InverseDepthFit, frame: DepthFrame)? {
        guard let fit = fit(prediction, anchors: anchors, config: config), let frame = depthFrame(prediction, fit: fit, photo: photo, config: config) else { return nil }
        return (fit, frame)
    }
}

/// Steele, Lea and Flood's SplitMix64: a small deterministic generator.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
