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
    /// Where the card and the bottom controls cover the camera, measured as laid out at the
    /// current text size. Nil when the screen doesn't need it.
    var cover: Binding<ChromeCover>?
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
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { value in if let cover { cover.wrappedValue.cardBottom = value } }
            Spacer(minLength: 0)
            bottom
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { value in if let cover { cover.wrappedValue.controlsTop = value } }
        }
        .padding(.horizontal, Metrics.edge)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

/// Where `CameraChrome` covers the camera, in the window's coordinates: the instruction card's
/// bottom edge and the bottom controls' top edge. The camera between them is what the homeowner
/// can see. Measured, not assumed: at the largest text sizes the card grows far past its usual
/// 220 pt (review of #100). Nil until laid out. Measured with `onGeometryChange` rather than a
/// preference key, whose change handler can't set view state under Swift 6's checks.
struct ChromeCover: Equatable {
    var cardBottom: CGFloat?
    var controlsTop: CGFloat?
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
