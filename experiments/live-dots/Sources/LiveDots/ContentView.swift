import LiveDotsCore
import SwiftUI

/// The phone on the left, the controls on the right.
struct ContentView: View {
    let fixtureArgument: String?

    @State private var stage: Stage = .loading
    @State private var progress = LoadProgress()
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    enum Stage {
        case loading
        case failed(String)
        case ready(DotRenderer, ReplayPlayer, FrameTimer)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            PhoneFrame {
                switch stage {
                case .loading:
                    ProgressView(value: progress.fraction) {
                        Text("Fusing keyframes")
                    }
                    .progressViewStyle(.linear)
                    .tint(Palette.hologram)
                    .foregroundStyle(.white)
                    .padding(48)
                case let .failed(message):
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(32)
                case let .ready(renderer, player, timer):
                    ZStack {
                        DotsMetalView(renderer: renderer, player: player, timer: timer)
                            .accessibilityHidden(true)
                        TimelineView(.animation) { _ in
                            let data = renderer.data, request = player.request
                            PhoneChrome(
                                state: data.timeline(request.mode).states[request.keyframe],
                                keyframe: data.replay.keyframes[request.keyframe],
                                boxes: data.boxes[request.keyframe], time: request.time)
                        }
                    }
                }
            }
            Group {
                if case let .ready(renderer, player, timer) = stage {
                    ControlsPanel(player: player, data: renderer.data, timer: timer)
                } else {
                    Color.clear
                }
            }
            .frame(width: 280)
        }
        .padding(28)
        .background(Palette.window)
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func load() async {
        let progress = progress
        do {
            let folder = try FixtureLocator.folder(fixtureArgument)
            let data = try await ReplayData.load(folder: folder) { done, total in
                Task { @MainActor in progress.fraction = Double(done) / Double(total) }
            }
            let renderer = try DotRenderer(data: data)
            let player = ReplayPlayer(keyframeCount: data.keyframeCount, reduceMotion: systemReduceMotion)
            stage = .ready(renderer, player, FrameTimer())
            player.togglePlayback()
        } catch {
            stage = .failed(String(describing: error))
        }
    }
}
