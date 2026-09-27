import LiveDotsCore
import SwiftUI

/// Playback and comparison controls, outside the phone so nothing but the product sits on it.
struct ControlsPanel: View {
    @Bindable var player: ReplayPlayer
    let data: ReplayData
    let timer: FrameTimer

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Live dots")
                    .font(.title2.weight(.semibold))
                Text("Synthetic wall fixture, \(data.keyframeCount) keyframes played at 4 per second.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                        player.togglePlayback()
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .controlSize(.large)
                    Spacer()
                    Text("Keyframe \(player.keyframe + 1) of \(data.keyframeCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: keyframeBinding, in: 0...Double(data.keyframeCount - 1), step: 1) {
                    Text("Keyframe")
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker("Depth", selection: $player.mode) {
                    Text("LiDAR").tag(CaptureMode.lidar)
                    Text("No LiDAR").tag(CaptureMode.noLidar)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if player.mode == .noLidar {
                    Text("Simulated. The feature points and wall plane come from the fixture's depth, which a phone without LiDAR does not have.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker("Look", selection: $player.scheme) {
                    Text("Hologram").tag(DotScheme.hologram)
                    Text("Constellation").tag(DotScheme.constellation)
                    Text("Ember").tag(DotScheme.ember)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(schemeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Reduce Motion", isOn: $player.reduceMotion)
                Picker("Fog", selection: $player.fog) {
                    Text("Fog").tag(FogStyle.on)
                    Text("Flat veil").tag(FogStyle.veil)
                    Text("Off").tag(FogStyle.off)
                }
                .pickerStyle(.segmented)
                Text("Fog covers everything not yet measured and lifts where dots arrive. Flat veil is the old approach, 35% over wall cells no dot has reached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)

            Divider()

            stats
            legend
            Spacer(minLength: 0)
        }
        .frame(maxHeight: 844)
    }

    private var schemeCaption: String {
        switch player.scheme {
        case .hologram: "Edge and surface dots; opacity rises with each new view."
        case .constellation: "Edges only, linked into outlines. The wall's surface shows nothing."
        case .ember: "New dots are born amber and cool to white over 6 s, so the newest part of the map glows."
        }
    }

    private var keyframeBinding: Binding<Double> {
        Binding(get: { Double(player.keyframe) }, set: { player.scrub(to: Int($0.rounded())) })
    }

    private var stats: some View {
        let state = data.timeline(player.mode).states[player.keyframe]
        return TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let averages = timer.averages
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Dots in field")
                    Text(state.fieldCount, format: .number)
                }
                GridRow {
                    Text("Edge dots")
                    Text(state.edgeCount, format: .number)
                }
                GridRow {
                    Text("Coverage")
                    Text(Double(state.coverage), format: .percent.precision(.fractionLength(0)))
                }
                GridRow {
                    Text("Frame")
                    Text("GPU \(averages.gpuMilliseconds, format: .number.precision(.fractionLength(2))) ms, CPU \(averages.cpuMilliseconds, format: .number.precision(.fractionLength(2))) ms")
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Surface and edges")
            } icon: {
                swatch(core: Palette.hologram, glow: Palette.glow)
            }
            Label {
                Text("In front of the wall")
            } icon: {
                swatch(core: Palette.hiddenViolet, glow: Palette.hiddenViolet)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func swatch(core: Color, glow: Color) -> some View {
        Circle()
            .fill(core)
            .frame(width: 6, height: 6)
            .background(Circle().fill(glow.opacity(0.45)).frame(width: 14, height: 14))
    }
}
