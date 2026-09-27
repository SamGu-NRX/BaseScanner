import Foundation

/// Everything that can be wrong with a replay folder. Each message names the file and, for size
/// mismatches, both counts, so a broken fixture says exactly what to regenerate.
public enum FixtureError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unreadable(path: String, reason: String)
    case wrongFormat(path: String, found: String)
    case unsupportedVersion(path: String, found: Int)
    case malformed(path: String, detail: String)
    case noDepth(path: String, keyframe: String)
    case depthByteCount(path: String, found: Int, expected: Int, width: Int, height: Int)
    case confidenceByteCount(path: String, found: Int, expected: Int, width: Int, height: Int)
    case undecodableImage(path: String)
    case imageSize(path: String, found: SIMD2<Int>, expected: SIMD2<Int>)

    public var description: String {
        switch self {
        case let .unreadable(path, reason):
            "can't read \(path): \(reason)"
        case let .wrongFormat(path, found):
            "\(path) has format \"\(found)\", expected \"measure-lab-session\""
        case let .unsupportedVersion(path, found):
            "\(path) has formatVersion \(found), this reader supports 2"
        case let .malformed(path, detail):
            "\(path) is malformed: \(detail)"
        case let .noDepth(path, keyframe):
            "\(path): keyframe \(keyframe) lists no depth, and LiDAR mode needs depth on every keyframe"
        case let .depthByteCount(path, found, expected, width, height):
            "\(path) has \(found) bytes, expected \(expected) for \(width) x \(height) Float32"
        case let .confidenceByteCount(path, found, expected, width, height):
            "\(path) has \(found) bytes, expected \(expected) for \(width) x \(height) UInt8"
        case let .undecodableImage(path):
            "\(path) is not a decodable image"
        case let .imageSize(path, found, expected):
            "\(path) is \(found.x) x \(found.y) pixels, session.json says \(expected.x) x \(expected.y)"
        }
    }

    public var errorDescription: String? { description }
}
