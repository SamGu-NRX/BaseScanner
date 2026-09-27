import SwiftUI

/// The frame shared by every camera screen: status row and one instruction at the top, the
/// camera open in the middle, actions within thumb reach at the bottom.
struct CameraChrome<Bottom: View>: View {
    var instruction: Instruction
    var tone: InstructionCard.Tone = .normal
    var reply: InstructionCard.Reply?
    /// See `InstructionCard.eyebrow`.
    var eyebrow: String?
    var photoCount: Int?
    var lastCaptureID: Int?
    var isReplay: Bool
    var isAutopilot: Bool
    /// Taps on the open camera area, in the camera view's coordinates (full screen, which is
    /// the window's global space). Nil when the screen has nothing to tap.
    var onCameraTap: ((CGPoint) -> Void)?
    /// A line under the card about something drawn on the camera: the aim ring's legend
    /// (`CameraOverlays`). It is part of the chrome's stack, so it grows with the card and
    /// scrolls with it at the largest text sizes, where the card covers most of the camera.
    var legend: String? = nil
    @ViewBuilder var bottom: Bottom

    var body: some View {
        // One layout at every text size: the chrome fills the screen and, only when the largest
        // text makes it taller than the screen, scrolls instead of squeezing the words. The
        // scroll view would swallow taps meant for the camera, so camera taps are caught inside
        // it, behind the chrome.
        GeometryReader { proxy in
            ScrollView {
                stack
                    .frame(width: proxy.size.width)
                    .frame(minHeight: proxy.size.height)
                    .background {
                        if let onCameraTap {
                            Color.clear
                                .contentShape(.rect)
                                .onTapGesture(coordinateSpace: .global) { point in onCameraTap(point) }
                                .accessibilityHidden(true)
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
    }

    private var stack: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                ModeBadge(isReplay: isReplay, isAutopilot: isAutopilot)
                Spacer(minLength: 8)
                if let photoCount {
                    PhotoCounter(count: photoCount, lastCaptureID: lastCaptureID)
                }
            }
            .frame(minHeight: 36)
            InstructionCard(instruction: instruction, tone: tone, reply: reply, eyebrow: eyebrow)
            if let legend {
                legendLine(legend)
            }
            Spacer(minLength: 0)
            bottom
        }
        .animation(.easeOut(duration: 0.2), value: legend)
        .padding(.horizontal, Metrics.edge)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private func legendLine(_ text: String) -> some View {
        Label(text, systemImage: "scope")
            .font(Typeface.hint)
            .foregroundStyle(Palette.chalk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ScrimShape.rounded(14))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("aim.legend")
            .transition(.opacity)
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
