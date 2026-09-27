import CoreGraphics
import Foundation
import ImageIO
import LiveDotsCore
import SwiftUI
import UniformTypeIdentifiers

/// Renders the replay offscreen at 1170 x 2532 with the same renderer and chrome as the app.
enum Exporter {
    static let framesPerSecond: Float = 30

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Every frame from keyframe 1 until the last keyframe's births finish. `destination` is a
    /// folder for frame_00000.png onward, or "-" for raw BGRA frames on stdout (what
    /// make-video.sh pipes into ffmpeg, so no frame folder ever touches the disk).
    static func exportReplay(to destination: String, options: Command.RenderOptions) throws {
        let data = try ReplayData.loadNow(folder: FixtureLocator.folder(options.fixture))
        let renderer = try DotRenderer(data: data)
        let target = try OffscreenTarget(renderer: renderer)
        let timeline = data.timeline(options.mode)
        let seconds = Float(data.keyframeCount) / Tuning.keyframesPerSecond + Tuning.birthDuration + 0.15
        let frameCount = Int((seconds * framesPerSecond).rounded(.up))
        let toStdout = destination == "-"
        let folder = URL(fileURLWithPath: destination, isDirectory: true)
        if !toStdout { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var chrome = ChromeCache()

        for frame in 0..<frameCount {
            let time = Float(frame) / framesPerSecond
            let keyframe = min(Int(time * Tuning.keyframesPerSecond), data.keyframeCount - 1)
            let request = FrameRequest(
                mode: options.mode, keyframe: keyframe, time: time,
                reduceMotion: options.reduceMotion, showFog: options.showFog, scheme: options.scheme)
            try target.render(request)
            try composite(chrome.image(for: timeline.states[keyframe]), onto: target)
            if toStdout {
                FileHandle.standardOutput.write(Data(target.bytes))
            } else {
                try writePNG(target, to: folder.appendingPathComponent(String(format: "frame_%05d.png", frame)))
            }
            if frame % 30 == 0 {
                FileHandle.standardError.write(Data("frame \(frame + 1) of \(frameCount)\n".utf8))
            }
        }
    }

    /// One keyframe, settled (every birth and evidence change finished), as a PNG.
    static func exportStill(keyframe number: Int, to path: String, options: Command.RenderOptions) throws {
        let data = try ReplayData.loadNow(folder: FixtureLocator.folder(options.fixture))
        guard number <= data.keyframeCount else {
            throw Failure(description: "--still \(number) is past the last keyframe, \(data.keyframeCount)")
        }
        let renderer = try DotRenderer(data: data)
        let target = try OffscreenTarget(renderer: renderer)
        let state = data.timeline(options.mode).states[number - 1]
        try target.render(FrameRequest(
            mode: options.mode, keyframe: number - 1, time: state.time + 1,
            reduceMotion: options.reduceMotion, showFog: options.showFog, scheme: options.scheme))
        var chrome = ChromeCache()
        try composite(chrome.image(for: state), onto: target)
        try writePNG(target, to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data(
            "\(path): keyframe \(number), \(options.mode.rawValue), \(options.scheme.rawValue), \(state.sprites.count) sprites drawn, \(state.fieldCount) dots in field (\(state.edgeCount) edges), coverage \(Int((state.coverage * 100).rounded()))%\n".utf8))
    }

    private static func composite(_ chrome: CGImage?, onto target: OffscreenTarget) throws {
        guard let chrome else { return }
        let context = try target.context()
        context.draw(chrome, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
    }

    private static func writePNG(_ target: OffscreenTarget, to url: URL) throws {
        guard let image = try target.context().makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure(description: "can't write \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "can't write \(url.path)") }
    }

    /// The chrome changes only when the coverage or the instruction does.
    private struct ChromeCache {
        private var key: (Float, Instruction)?
        private var image: CGImage?

        mutating func image(for state: KeyframeState) -> CGImage? {
            if let key, key.0 == state.coverage, key.1 == state.instruction { return image }
            let renderer = ImageRenderer(content: PhoneChrome(coverage: state.coverage, instruction: state.instruction)
                .frame(width: CGFloat(OffscreenTarget.pointSize.x), height: CGFloat(OffscreenTarget.pointSize.y)))
            renderer.scale = CGFloat(OffscreenTarget.scale)
            key = (state.coverage, state.instruction)
            image = renderer.cgImage
            return image
        }
    }
}
