import Foundation
import Testing
@testable import MeasureGeometry

struct TriangulationTests {
    @Test func `rays that meet give the meeting point`() throws {
        // Two cameras 1 m apart both aim exactly at (0.5, 2, −3).
        let target = SIMD3<Double>(0.5, 2, -3)
        let o1 = SIMD3<Double>(0, 1, 0)
        let o2 = SIMD3<Double>(1, 1, 0)
        let result = try Triangulation(
            try Ray(origin: o1, direction: target - o1),
            try Ray(origin: o2, direction: target - o2)
        )
        #expect(isClose(result.point, target))
        #expect(isClose(result.gap, 0))
        // Both rays have length √(0.25 + 1 + 9) = √10.25 to the target.
        #expect(isClose(result.t1, 10.25.squareRoot()))
        #expect(isClose(result.t2, 10.25.squareRoot()))
        // d1·d2 = (−0.25 + 1 + 9) / 10.25 = 9.75 / 10.25.
        #expect(isClose(result.rayAngle, acos(9.75 / 10.25) * 180 / .pi))
        #expect(result.rayAngle > 17.9 && result.rayAngle < 18.0)
        #expect(result.baseline == 1)
    }

    @Test func `skew rays give the midpoint of closest approach`() throws {
        // Ray 1 runs down −z from the origin. Ray 2 starts at (1, 0.03, 0) heading (−1, 0, −1)/√2.
        // Seen from above they cross at (0, −1); ray 2 stays 3 cm higher the whole way.
        // w = (−1, −0.03, 0), a = c = 1, b = 1/√2, d = 0, e = 1/√2, so a·c − b² = 1/2,
        // t1 = (b·e − c·d) / (1/2) = 1 and t2 = (a·e − b·d) / (1/2) = √2.
        let result = try Triangulation(
            try Ray(origin: .zero, direction: SIMD3(0, 0, -1)),
            try Ray(origin: SIMD3(1, 0.03, 0), direction: SIMD3(-1, 0, -1))
        )
        #expect(isClose(result.t1, 1))
        #expect(isClose(result.t2, 2.0.squareRoot()))
        #expect(isClose(result.closest1, SIMD3(0, 0, -1)))
        #expect(isClose(result.closest2, SIMD3(0, 0.03, -1)))
        #expect(isClose(result.point, SIMD3(0, 0.015, -1)))
        #expect(isClose(result.gap, 0.03))
        #expect(isClose(result.rayAngle, 45))
    }

    @Test func `rays that miss by more than two inches are refused`() throws {
        let error = #expect(throws: TriangulationError.self) {
            try Triangulation(
                try Ray(origin: .zero, direction: SIMD3(0, 0, -1)),
                try Ray(origin: SIMD3(1, 0.06, 0), direction: SIMD3(-1, 0, -1))
            )
        }
        guard case .raysMiss(let gap, let maximum)? = error else {
            Issue.record("Expected raysMiss, got \(String(describing: error))")
            return
        }
        #expect(isClose(gap, 0.06))
        #expect(maximum == 0.0508)
    }

    @Test(arguments: [10.0, 14.9])
    func `ray angles under fifteen degrees are refused`(angle: Double) throws {
        let r = angle * .pi / 180
        let error = #expect(throws: TriangulationError.self) {
            try Triangulation(
                try Ray(origin: SIMD3(-1, 0, 0), direction: SIMD3(0, 0, -1)),
                try Ray(origin: .zero, direction: SIMD3(-sin(r), 0, -cos(r)))
            )
        }
        guard case .rayAngleTooSmall(let measured, let minimum)? = error else {
            Issue.record("Expected rayAngleTooSmall, got \(String(describing: error))")
            return
        }
        #expect(isClose(measured, angle, within: 1e-7))
        #expect(minimum == 15)
    }

    @Test func `fifteen degrees and up is accepted`() throws {
        // Ray 2 turns 15.1° toward ray 1 from 1 m to its right, so they cross in front of both.
        let r = 15.1 * Double.pi / 180
        let result = try Triangulation(
            try Ray(origin: .zero, direction: SIMD3(0, 0, -1)),
            try Ray(origin: SIMD3(1, 0, 0), direction: SIMD3(-sin(r), 0, -cos(r)))
        )
        #expect(isClose(result.rayAngle, 15.1, within: 1e-7))
        // They meet where ray 2 has moved 1 m left: depth 1 / tan 15.1°.
        #expect(isClose(result.point, SIMD3(0, 0, -1 / tan(r)), within: 1e-9))
    }

    @Test func `parallel rays are refused before dividing by zero`() throws {
        let error = #expect(throws: TriangulationError.self) {
            try Triangulation(
                try Ray(origin: .zero, direction: SIMD3(0, 0, -1)),
                try Ray(origin: SIMD3(1, 0, 0), direction: SIMD3(0, 0, -1))
            )
        }
        #expect(error == .rayAngleTooSmall(angle: 0, minimum: 15))
    }

    @Test func `a meeting point behind a camera is refused`() throws {
        // The lines meet at (0, 0, 1), behind both cameras: t1 = −1, t2 = −√2.
        let error = #expect(throws: TriangulationError.self) {
            try Triangulation(
                try Ray(origin: .zero, direction: SIMD3(0, 0, -1)),
                try Ray(origin: SIMD3(1, 0, 0), direction: SIMD3(1, 0, -1))
            )
        }
        guard case .behindCamera(let t1, let t2)? = error else {
            Issue.record("Expected behindCamera, got \(String(describing: error))")
            return
        }
        #expect(isClose(t1, -1))
        #expect(isClose(t2, -(2.0.squareRoot())))
    }
}
