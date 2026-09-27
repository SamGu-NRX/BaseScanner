import Foundation
import HouseScanKit
import simd
import Testing

/// Where "Can't get there" (and "Wall ends here" during the walk) puts a wall end: the phone's s
/// along the chain, kept within the stretch walked on that side (`WalkedEnd`).
@Suite struct WalkedEndTests {
    /// A kept view's position, 2 m in front of the standard wall at s = x.
    static func stood(_ x: Float) -> SIMD3<Float> { SIMD3(x, 1.4, 2) }

    @Test func straightWallEndsWhereThePhoneIs() {
        let wall = standardWall()
        let walked = [0, -1, -2, -3].map(Self.stood)
        #expect(WalkedEnd.farthest(.left, walked: walked, wall: wall) == 3)
        #expect(WalkedEnd.end(.left, phone: Self.stood(-2.5), walked: walked, wall: wall) == -2.5)
        // Walked back toward the meter: the end follows the phone, not the farthest view.
        #expect(WalkedEnd.end(.left, phone: Self.stood(-1.2), walked: walked, wall: wall) == -1.2)
        // Ahead of every kept view: no farther than the walk has evidence for.
        #expect(WalkedEnd.end(.left, phone: Self.stood(-4), walked: walked, wall: wall) == -3)
        // How far out the phone stands doesn't matter, only its s.
        #expect(WalkedEnd.end(.left, phone: SIMD3(-2.5, 1.4, 6), walked: walked, wall: wall) == -2.5)
    }

    /// Across the meter the phone's place says nothing about this side: the end goes as far as the
    /// walk went there, not to the meter (which dropped run 1's walk).
    @Test func phoneAcrossTheMeterUsesTheWalkedStretch() {
        let wall = standardWall()
        let walked = [0, -1, -2, -3, 1, 2].map(Self.stood)
        #expect(WalkedEnd.end(.left, phone: Self.stood(1.5), walked: walked, wall: wall) == -3)
        #expect(WalkedEnd.end(.right, phone: Self.stood(-2), walked: walked, wall: wall) == 2)
        // The phone's place unknown (lost tracking): the same.
        #expect(WalkedEnd.end(.left, phone: nil, walked: walked, wall: wall) == -3)
    }

    /// A side the walk never went to ends at the meter, wherever the phone is.
    @Test func sideNeverWalkedEndsAtTheMeter() {
        let wall = standardWall()
        let walked = [0.4, 1, 2].map(Self.stood)
        #expect(WalkedEnd.farthest(.left, walked: walked, wall: wall) == 0)
        #expect(WalkedEnd.end(.left, phone: Self.stood(2), walked: walked, wall: wall) == 0)
        #expect(WalkedEnd.end(.left, phone: Self.stood(-1), walked: walked, wall: wall) == 0)
        #expect(WalkedEnd.end(.left, phone: nil, walked: [], wall: wall) == 0)
    }

    /// Round a followed corner s runs on along the chain (`rightCornerWall`: corner at s = 3, the
    /// next piece running toward -z facing +x). `CoverageAcrossCornersTests.roundCornerCamera(s:)`
    /// stands 2 m in front of that piece at chain s = c.
    @Test func cornerChainMeasuresAlongTheChain() throws {
        let wall = try rightCornerWall()
        let corner = CoverageAcrossCornersTests()
        let walked = [Self.stood(1), Self.stood(2.5)] + [4.0, 5.0].map { corner.roundCornerCamera(s: $0).position }
        #expect(nearlyEqual(WalkedEnd.farthest(.right, walked: walked, wall: wall), 5))
        #expect(nearlyEqual(WalkedEnd.end(.right, phone: corner.roundCornerCamera(s: 4.6).position, walked: walked, wall: wall), 4.6))
        #expect(nearlyEqual(WalkedEnd.end(.right, phone: corner.roundCornerCamera(s: 5.5).position, walked: walked, wall: wall), 5))
        // In front of the meter's piece, short of the corner.
        #expect(nearlyEqual(WalkedEnd.end(.right, phone: Self.stood(2), walked: walked, wall: wall), 2))
    }

    /// The same rule read off a coverage map: every kept view counts as walked, whether or not it
    /// saw anything.
    @Test func mapReadsItsKeptViews() {
        var map = CoverageMap(wall: standardWall())
        for x: Float in [0, -1.5, 2.5] { map.observe(wallCamera(s: x), trackingNormal: true) }
        // Not kept: limited tracking adds no view.
        map.observe(wallCamera(s: -4), trackingNormal: false)
        #expect(map.walkedFarthest(.left) == 1.5)
        #expect(map.walkedFarthest(.right) == 2.5)
    }

    /// "Wall ends here" during a tilt or step-back request ends the side the phone is on. The
    /// planner does the left side first, so it used to end the left whenever that was open: with
    /// the phone 2.5 m right of the meter, the left end at the farthest walked point, 3 m left.
    @Test func wallEndsHereEndsTheSideThePhoneIsOn() throws {
        let wall = standardWall()
        let walked = [0, -1, -2, -3, 1, 2, 2.5].map(Self.stood)
        let side = try #require(WalkedEnd.side(phone: Self.stood(2.5), wall: wall, leftEnd: nil, rightEnd: nil))
        #expect(side == .right)
        #expect(WalkedEnd.end(side, phone: Self.stood(2.5), walked: walked, wall: wall) == 2.5)
        // What ending the left there did.
        #expect(WalkedEnd.end(.left, phone: Self.stood(2.5), walked: walked, wall: wall) == -3)
        #expect(WalkedEnd.side(phone: Self.stood(-2), wall: wall, leftEnd: nil, rightEnd: nil) == .left)
        #expect(WalkedEnd.side(phone: Self.stood(-2), wall: wall, leftEnd: nil, rightEnd: 2.5) == .left)
        #expect(WalkedEnd.side(phone: Self.stood(2), wall: wall, leftEnd: -3, rightEnd: nil) == .right)
        // Place lost, at the meter, or on a side already ended: the first side without an end.
        #expect(WalkedEnd.side(phone: nil, wall: wall, leftEnd: nil, rightEnd: nil) == .left)
        #expect(WalkedEnd.side(phone: nil, wall: wall, leftEnd: -3, rightEnd: nil) == .right)
        #expect(WalkedEnd.side(phone: Self.stood(0), wall: wall, leftEnd: nil, rightEnd: nil) == .left)
        #expect(WalkedEnd.side(phone: Self.stood(2), wall: wall, leftEnd: nil, rightEnd: 2.5) == .left)
        #expect(WalkedEnd.side(phone: Self.stood(2), wall: wall, leftEnd: -3, rightEnd: 2.5) == nil)
    }

    /// Ending both sides at the meter without walking ("Wall ends here" or "Can't get there" on
    /// each side before a step) puts both ends there: a wall of no length, which the walk must
    /// not finish with. A meter by a corner, with one end close to it, is still a wall.
    @Test func endsAtTheMeterAreTooClose() {
        let wall = standardWall()
        var map = CoverageMap(wall: wall)
        map.observe(wallCamera(s: 0), trackingNormal: true)
        let phone = Self.stood(0.1)
        let left = WalkedEnd.end(.left, phone: phone, walked: map.walkedPositions, wall: wall)
        let right = WalkedEnd.end(.right, phone: phone, walked: map.walkedPositions, wall: wall)
        #expect(left == 0 && right == 0)
        #expect(!map.endsTooClose)
        map.setEnd(.left, at: left)
        #expect(!map.endsTooClose)
        map.setEnd(.right, at: right)
        #expect(map.endsTooClose)
        // Narrower than one battery still is.
        map.setEnd(.right, at: 0.7)
        #expect(map.endsTooClose)
        map.setEnd(.left, at: -0.1)
        map.setEnd(.right, at: 3)
        #expect(!map.endsTooClose)
    }

    /// A phone past an unexplored end whose view shows nothing between the ends takes photos the
    /// scan can't use; one that still sees the wall between them doesn't, nor one past a limit end,
    /// whose ground still counts.
    @Test func pastAnUnexploredEndWithNothingBetweenTheEndsInView() {
        var map = CoverageMap(wall: standardWall())
        map.setEnd(.right, at: 2)
        map.setEnd(.left, at: -2)
        // `wallCamera` sees the wall within 0.9 m of its s.
        #expect(map.unexploredEndPassed(by: wallCamera(s: 4)) == .right)
        #expect(map.unexploredEndPassed(by: wallCamera(s: -4)) == .left)
        #expect(map.unexploredEndPassed(by: wallCamera(s: 2.5)) == nil)
        #expect(map.unexploredEndPassed(by: wallCamera(s: 1)) == nil)
        map.setEndIsLimit(.right, true)
        #expect(map.unexploredEndPassed(by: wallCamera(s: 4)) == nil)
    }

    /// Device run 1 in miniature on the synthetic replay (ios/HouseScanUITests/Fixtures): the walk
    /// goes to 5 m left and 5 m right, pitched 20 degrees down. Its views cover both bands, the
    /// wall to the walk's 4.5 ft (`CoverageConfig.wallWalkHeight`), along the whole walk and
    /// 0.33 m past each turn, so the unbroken covered reach is 5.334 m either side. (With the wall
    /// band at 7.5 ft it was 0.762 m, and ends there would have left out the rest of the walk.)
    /// Ends where the phone stood keep its wall and ground whatever the reach.
    @Test func syntheticWalkKeepsItsWallAndGround() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../HouseScanUITests/Fixtures/synthetic-wall")
            .standardizedFileURL
        let session = try ReplaySession.load(folder: folder)
        let declared = try #require(session.declaredWall)
        let wall = try #require(WallFrame(meter: declared.meter, outward: declared.outward, groundY: declared.groundY))
        var map = CoverageMap(wall: wall)
        let cameras = session.frames.map { frame in
            CameraFrame(cameraToWorld: frame.cameraToWorld, intrinsics: frame.intrinsics, imageSize: SIMD2(Float(frame.width), Float(frame.height)))
        }
        // Frames 5 to 37: stepping back from the meter, then the walk (0 to -5 m and back to 5 m).
        for index in 5..<38 {
            map.observe(cameras[index], trackingNormal: true, time: session.frames[index].timestamp)
        }
        let planner = GuidancePlanner()
        let oldLeft = planner.reach(.left, coverage: map)
        let oldRight = planner.reach(.right, coverage: map)
        #expect(nearlyEqual(oldLeft, 5.334) && nearlyEqual(oldRight, 5.334))
        // Where the walk turned (frame 17, x = -5) and where it stopped (frame 37, x = 5).
        let left = WalkedEnd.end(.left, phone: cameras[17].position, walked: map.walkedPositions, wall: map.wall)
        let right = WalkedEnd.end(.right, phone: cameras[37].position, walked: map.walkedPositions, wall: map.wall)
        #expect(nearlyEqual(left, -5, 1e-3))
        #expect(nearlyEqual(right, 5, 1e-3))

        var old = map
        old.setEnd(.left, at: -oldLeft)
        old.setEnd(.right, at: oldRight)
        #expect(old.groundDepthSpans().allSatisfy { $0.span.lowerBound >= -oldLeft && $0.span.upperBound <= oldRight })

        map.setEnd(.left, at: left)
        map.setEnd(.right, at: right)
        let wallSeen = map.wallSeenSpans()
        let groundSeen = map.groundDepthSpans()
        #expect(!wallSeen.isEmpty && !groundSeen.isEmpty)
        #expect(wallSeen.allSatisfy { $0.span.lowerBound >= left && $0.span.upperBound <= right })
        // The ground in front of the meter and along both sides of it.
        #expect(groundSeen.contains { $0.span.contains(0) })
        #expect(groundSeen.contains { $0.span.upperBound < -3 || $0.span.lowerBound < -3 })
        #expect(groundSeen.contains { $0.span.upperBound > 3 })
    }
}
