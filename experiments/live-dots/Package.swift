// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LiveDots",
    platforms: [.macOS(.v15)],
    targets: [
        // Fixture decoding and the dot field's rules. No UI, no Metal, no main actor: it runs off
        // the main thread while the app precomputes the replay, and the tests drive it directly.
        .target(
            name: "LiveDotsCore",
            // Unoptimised, fusing the 41 keyframes takes about 40 s instead of under 1 s, which
            // made plain `swift run LiveDots` sit on its loading bar.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "LiveDots",
            dependencies: ["LiveDotsCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "LiveDotsCoreTests", dependencies: ["LiveDotsCore"]),
    ],
    swiftLanguageModes: [.v6]
)
