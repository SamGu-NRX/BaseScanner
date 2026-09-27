import LiveDotsCore

/// What the executable was asked to do. With no flags it opens the window.
enum Command {
    case app(fixture: String?)
    /// Every frame of the replay at 30 fps to PNG files in a folder, or raw BGRA to stdout for "-".
    case export(destination: String, options: RenderOptions)
    /// One settled keyframe (1-based, as in the fixture's ids) to a PNG file.
    case still(keyframe: Int, output: String, options: RenderOptions)
    case gradientReport(fixture: String?)
    case benchmark(fixture: String?)
    case fieldReport(fixture: String?)

    struct RenderOptions {
        var fixture: String?
        var mode: CaptureMode = .lidar
        var reduceMotion = false
        var showFog = false
    }

    struct UsageError: Error, CustomStringConvertible {
        let problem: String
        var description: String {
            """
            \(problem)
            usage: LiveDots [--fixture <dir>]
                   LiveDots --export <dir|-> --mode lidar|nolidar [--reduce-motion] [--fog] [--fixture <dir>]
                   LiveDots --still <keyframe> --out <file.png> --mode lidar|nolidar [--reduce-motion] [--fog] [--fixture <dir>]
                   LiveDots --gradient-report [--fixture <dir>]
                   LiveDots --benchmark [--fixture <dir>]
                   LiveDots --field-report [--fixture <dir>]
            """
        }
    }

    static func parse(_ arguments: [String]) throws(UsageError) -> Command {
        var options = RenderOptions()
        var export: String?, still: Int?, output: String?, mode: String?
        var report = false, benchmark = false, fieldReport = false
        var rest = arguments[...]
        func value(for flag: String) throws(UsageError) -> String {
            guard let next = rest.popFirst() else { throw UsageError(problem: "\(flag) needs a value") }
            return next
        }
        while let flag = rest.popFirst() {
            switch flag {
            case "--fixture": options.fixture = try value(for: flag)
            case "--export": export = try value(for: flag)
            case "--still":
                let text = try value(for: flag)
                guard let number = Int(text), number >= 1 else { throw UsageError(problem: "--still needs a keyframe number from 1, got \(text)") }
                still = number
            case "--out": output = try value(for: flag)
            case "--mode": mode = try value(for: flag)
            case "--reduce-motion": options.reduceMotion = true
            case "--fog": options.showFog = true
            case "--gradient-report": report = true
            case "--benchmark": benchmark = true
            case "--field-report": fieldReport = true
            // Xcode and LaunchServices pass these to GUI launches.
            case let other where other.hasPrefix("-NS") || other.hasPrefix("-Apple"): _ = rest.popFirst()
            default: throw UsageError(problem: "unknown argument \(flag)")
            }
        }
        if let mode {
            switch mode {
            case "lidar": options.mode = .lidar
            case "nolidar": options.mode = .noLidar
            default: throw UsageError(problem: "--mode must be lidar or nolidar, got \(mode)")
            }
        }
        if report { return .gradientReport(fixture: options.fixture) }
        if benchmark { return .benchmark(fixture: options.fixture) }
        if fieldReport { return .fieldReport(fixture: options.fixture) }
        if let export {
            guard mode != nil else { throw UsageError(problem: "--export needs --mode") }
            return .export(destination: export, options: options)
        }
        if let still {
            guard mode != nil else { throw UsageError(problem: "--still needs --mode") }
            guard let output else { throw UsageError(problem: "--still needs --out <file.png>") }
            return .still(keyframe: still, output: output, options: options)
        }
        return .app(fixture: options.fixture)
    }
}
