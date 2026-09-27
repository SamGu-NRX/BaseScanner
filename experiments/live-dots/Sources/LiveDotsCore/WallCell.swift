/// The synthetic fixture's wall, z = 0, x from -6 to 6 m, 3 m high. Only the simulated no-LiDAR
/// plane dots and the fog comparison use it; the LiDAR field finds surfaces from depth alone.
public enum FixtureWall {
    public static let xRange: ClosedRange<Float> = -6...6
    public static let yRange: ClosedRange<Float> = 0...3
}

/// A 30 cm square of the fixture wall, for the "unseen as fog" comparison veil.
public struct WallCell: Hashable, Sendable, Comparable {
    public let column: Int
    public let row: Int

    public static let size = Tuning.fogCell
    public static let columns = Int(((FixtureWall.xRange.upperBound - FixtureWall.xRange.lowerBound) / size).rounded())
    public static let rows = Int(((FixtureWall.yRange.upperBound - FixtureWall.yRange.lowerBound) / size).rounded())

    public static let all: [WallCell] = (0..<rows).flatMap { row in (0..<columns).map { WallCell(column: $0, row: row) } }

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    public static func containing(x: Float, y: Float) -> WallCell? {
        let column = Int(((x - FixtureWall.xRange.lowerBound) / size).rounded(.down))
        let row = Int(((y - FixtureWall.yRange.lowerBound) / size).rounded(.down))
        guard (0..<columns).contains(column), (0..<rows).contains(row) else { return nil }
        return WallCell(column: column, row: row)
    }

    public var minX: Float { FixtureWall.xRange.lowerBound + Float(column) * Self.size }
    public var minY: Float { FixtureWall.yRange.lowerBound + Float(row) * Self.size }

    public static func < (a: WallCell, b: WallCell) -> Bool {
        (a.row, a.column) < (b.row, b.column)
    }
}
