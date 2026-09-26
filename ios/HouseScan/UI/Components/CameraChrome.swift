import SwiftUI

/// The frame shared by every camera screen: status row and one instruction at the top, the
/// camera open in the middle, actions within thumb reach at the bottom.
struct CameraChrome<Bottom: View>: View {
    var instruction: Instruction
    var tone: InstructionCard.Tone = .normal
    var reply: InstructionCard.Reply?
    var photoCount: Int?
    var lastCaptureID: Int?
    var isReplay: Bool
    var isAutopilot: Bool
    @ViewBuilder var bottom: Bottom

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                ModeBadge(isReplay: isReplay, isAutopilot: isAutopilot)
                Spacer(minLength: 8)
                if let photoCount {
                    PhotoCounter(count: photoCount, lastCaptureID: lastCaptureID)
                }
            }
            .frame(minHeight: 36)
            InstructionCard(instruction: instruction, tone: tone, reply: reply)
            Spacer(minLength: 0)
            bottom
        }
        .padding(.horizontal, Metrics.edge)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .dynamicTypeSize(cameraTypeCap)
    }
}

/// A full-screen invisible layer that turns taps on the camera image into view points in the
/// camera view's coordinate space (full screen, ignoring safe areas), as `ScanActions` expects.
struct CameraTapLayer: View {
    var onTap: (CGPoint, CGSize) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(.rect)
                .onTapGesture(coordinateSpace: .local) { point in
                    onTap(point, proxy.size)
                }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Reads the full-screen camera view size so buttons can send "the reticle" (nil point)
/// with the right `viewSize`.
struct CameraSizeReader: View {
    @Binding var size: CGSize

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { size = proxy.size }
                .onChange(of: proxy.size) { _, newValue in size = newValue }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Crosshair ring at the center of the camera: "the phone is pointing here".
struct Reticle: View {
    var diameter: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().strokeBorder(.black.opacity(0.35), lineWidth: 6)
            Circle().strokeBorder(.white, lineWidth: 3)
            Circle().fill(.white).frame(width: 6, height: 6)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
