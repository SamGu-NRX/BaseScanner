import Foundation
import HouseScanKit
import simd
import Testing

// The chosen-spot check: what the map says about the battery's volume at a stretch of wall,
// and how that combines with the homeowner's answer.
@Suite struct Map3DSpotTests {
    static let wall = standardWall()
    static let bush: Map3D = {
        var map = Map3D(frame: sceneFrame())
        for (index, camera) in bushWalk().enumerated() { map.integrate(bushScene().depthFrame(from: camera, noise: 0.02, seed: UInt64(index))) }
        return map
    }()

    /// The bush stands 0.4 to 1.0 m out between s = 1 and 2, inside the battery's 0.56 m depth.
    @Test func aMeasuredBushIsAnOccluder() {
        #expect(Self.bush.spotView(span: 1.2...1.8, along: Self.wall) == .occluder)
    }

    @Test func openWallIsClear() {
        #expect(Self.bush.spotView(span: -1.5...(-0.7), along: Self.wall) == .clear)
    }

    /// Beyond the walk, and in an empty map: nothing measured either way.
    @Test func unmeasuredSpansAreUnknown() {
        #expect(Self.bush.spotView(span: 6.5...7.3, along: Self.wall) == .unknown)
        #expect(Map3D(frame: sceneFrame()).spotView(span: -0.4...0.4, along: Self.wall) == .unknown)
    }

    /// Estimated depth alone never decides the spot, occluder or clear.
    @Test func estimatedDepthAloneDecidesNothing() {
        var map = Map3D(frame: sceneFrame())
        for camera in bushWalk() {
            let lidar = bushScene().depthFrame(from: camera)
            map.integrate(DepthFrame(camera: camera, width: lidar.width, height: lidar.height, depth: lidar.depth, kind: .estimated(sigma: lidar.depth.map { $0 * 0.01 })))
        }
        #expect(map.spotView(span: 1.2...1.8, along: Self.wall) == .unknown)
        #expect(map.spotView(span: -1.5...(-0.7), along: Self.wall) == .unknown)
    }

    /// The bush seen in a single frame (from x = 1.5 m, straight on) is hit once: not enough to
    /// be an occluder, and not clear either.
    @Test func aSurfaceHitInOneFrameIsNotEnough() {
        var map = Map3D(frame: sceneFrame())
        let camera = bushWalk()[30]
        #expect(abs(camera.position.x - 1.5) < 1e-4)
        map.integrate(bushScene().depthFrame(from: camera))
        // The part of the bush inside the battery's volume is its top, 0.9 m up, 0.4 to 0.56 m out.
        #expect(map.evidence(at: SIMD3(1.5, 0.9, 0.5)).hits == 1)
        #expect(map.spotView(span: 1.2...1.8, along: Self.wall) == .unknown)
        map.integrate(bushScene().depthFrame(from: bushWalk()[28]))
        #expect(map.spotView(span: 1.2...1.8, along: Self.wall) == .occluder)
    }

    @Test func theHomeownerCannotOverrideAnOccluder() {
        for answer in [true, false, nil] as [Bool?] {
            #expect(SpotDecision.decide(.occluder, homeownerSaysClear: answer) == .needsAnotherView)
        }
    }

    @Test func unknownFallsBackToTheHomeowner() {
        #expect(SpotDecision.decide(.unknown, homeownerSaysClear: true) == .clear)
        #expect(SpotDecision.decide(.unknown, homeownerSaysClear: false) == .obstacle)
        #expect(SpotDecision.decide(.unknown, homeownerSaysClear: nil) == .needsConfirmation)
        #expect(SpotDecision.decide(.clear, homeownerSaysClear: nil) == .clear)
        #expect(SpotDecision.decide(.clear, homeownerSaysClear: false) == .obstacle)
    }

    /// ARKit refines the meter anchor 5 cm along the wall and 2 degrees about +y: the map moves
    /// with it, the walk's wall is re-derived from the moved anchor, and the answers stay.
    @Test func theAnswerFollowsTheMeterAnchor() throws {
        var map = Self.bush
        let old = map.frame.poseInWorld
        let turn = simd_float4x4(simd_quatf(angle: 2 * .pi / 180, axis: SIMD3(0, 1, 0)))
        var new = turn * old
        new.columns.3 = old.columns.3 + SIMD4(0.05, 0, 0, 0)
        let moved = map.frame.following(anchorMovedFrom: old, to: new)
        map.reanchor(moved)
        let meter = moved.world(.zero)
        let outward = moved.worldDirection(SIMD3(0, 0, 1))
        let wall = try #require(WallFrame(meter: meter, outward: outward, groundY: meter.y + moved.groundY))
        #expect(map.spotView(span: 1.2...1.8, along: wall) == .occluder)
        #expect(map.spotView(span: -1.5...(-0.7), along: wall) == .clear)
    }
}
