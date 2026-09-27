import Foundation

do {
    switch try Command.parse(Array(CommandLine.arguments.dropFirst())) {
    case let .app(fixture):
        LiveDotsApp.fixtureArgument = fixture
        LiveDotsApp.main()
    case let .export(destination, options):
        try Exporter.exportReplay(to: destination, options: options)
    case let .still(keyframe, at, output, options):
        try Exporter.exportStill(keyframe: keyframe, at: at, to: output, options: options)
    case let .gradientReport(fixture):
        try GradientReport.run(fixture: fixture)
    case let .benchmark(fixture):
        try Benchmark.run(fixture: fixture)
    case let .fieldReport(fixture):
        try FieldReport.run(fixture: fixture)
    }
} catch {
    FileHandle.standardError.write(Data("LiveDots: \(error)\n".utf8))
    exit(1)
}
