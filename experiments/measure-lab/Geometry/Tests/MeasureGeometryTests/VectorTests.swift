import Testing
@testable import MeasureGeometry

struct VectorTests {
    @Test func `dot product sums the component products`() {
        #expect(SIMD3<Double>(1, 2, 3).dot(SIMD3(4, -5, 6)) == 12)
    }

    @Test func `cross product follows the right-hand rule`() {
        let x = SIMD3<Double>(1, 0, 0)
        let y = SIMD3<Double>(0, 1, 0)
        let z = SIMD3<Double>(0, 0, 1)
        #expect(x.cross(y) == z)
        #expect(y.cross(z) == x)
        #expect(z.cross(x) == y)
        #expect(SIMD3<Double>(1, 2, 3).cross(SIMD3(4, 5, 6)) == SIMD3(-3, 6, -3))
    }

    @Test func `length and horizontal part`() {
        #expect(SIMD3<Double>(2, 3, 6).length == 7)
        #expect(SIMD3<Double>(2, 3, 6).horizontal == SIMD3(2, 0, 6))
    }

    @Test func `acos in degrees clamps rounding past one`() {
        #expect(acosDegrees(1.0000000000000002) == 0)
        #expect(acosDegrees(-1.0000000000000002) == 180)
        #expect(isClose(acosDegrees(0.5), 60))
    }
}
