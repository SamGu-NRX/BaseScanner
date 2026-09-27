import simd

/// The constellation scheme's hairlines. Each edge dot links to its `DotScheme.linksPerDot`
/// nearest edge dots within `DotScheme.linkRadius` whose normals agree within 35 degrees, so a
/// link follows an outline and never jumps from the wall to the bin in front of it.
public enum EdgeLinks {
    /// Index pairs into `sprites`, lower index first, each pair once.
    public static func links(among sprites: [DotSprite]) -> [SIMD2<Int32>] {
        let radius = DotScheme.linkRadius
        func cell(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>((p / radius).rounded(.down)) }
        let edges = sprites.indices.filter { sprites[$0].kind == .edge && simd_length(sprites[$0].normal) > 0.5 }
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for i in edges { grid[cell(sprites[i].position), default: []].append(i) }

        var pairs = Set<SIMD2<Int32>>()
        for i in edges {
            let a = sprites[i]
            var nearest: [(index: Int, distance: Float)] = []
            let c = cell(a.position)
            for dz in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dx in Int32(-1)...1 {
                        for j in grid[c &+ SIMD3(dx, dy, dz)] ?? [] where j != i {
                            let b = sprites[j]
                            let distance = simd_distance(a.position, b.position)
                            guard distance <= radius, !VoxelField.normalsDisagree(a.normal, b.normal) else { continue }
                            nearest.append((j, distance))
                        }
                    }
                }
            }
            nearest.sort { ($0.distance, $0.index) < ($1.distance, $1.index) }
            for (j, _) in nearest.prefix(DotScheme.linksPerDot) {
                pairs.insert(SIMD2(Int32(min(i, j)), Int32(max(i, j))))
            }
        }
        return pairs.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    }
}
