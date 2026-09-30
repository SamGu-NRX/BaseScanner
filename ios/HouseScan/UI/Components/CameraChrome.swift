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
    /// (`CameraOverlays`). At the accessibility sizes it goes inside the card instead and
    /// scrolls with the words there (`InstructionCard.legend`).
    var legend: String? = nil
    /// Set to the open camera between the card and the actions, in global coordinates, for
    /// the aim ring to stay inside (`WayfindingOverlay.clearArea`). It moves when the chrome
    /// scrolls.
    var cameraWindow: Binding<CGRect?>? = nil
    @ViewBuilder var bottom: Bottom

    @Environment(\.dynamicTypeSize) private var typeSize

    private var capsWords: Bool { typeSize.isAccessibilitySize }
    /// The status row's height, for the card's budget.
    @State private var statusRowHeight: CGFloat = 0

    var body: some View {
        // One layout at every text size: the chrome fills the screen and, only when the largest
        // text makes it taller than the screen, scrolls instead of squeezing the words. The
        // scroll view would swallow taps meant for the camera, so camera taps are caught inside
        // it, behind the chrome.
        GeometryReader { proxy in
            ScrollView {
                stack(cardMaxHeight: capsWords ? cardMaxHeight(proxy) : nil)
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

    /// The tallest the card may be for it to end `windowHalfHeight` above the middle of the
    /// screen, measured from the top of this view, which starts under the status bar.
    private func cardMaxHeight(_ proxy: GeometryProxy) -> CGFloat {
        let screenMiddle = (proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom) / 2 - proxy.safeAreaInsets.top
        let above = CameraChromeLayout.stackTopPadding + statusRowHeight + CameraChromeLayout.stackSpacing
        return max(CameraChromeLayout.minCardHeight, (screenMiddle - CameraChromeLayout.windowHalfHeight - above).rounded(.down))
    }

    private func stack(cardMaxHeight: CGFloat?) -> some View {
        VStack(spacing: CameraChromeLayout.stackSpacing) {
            HStack(alignment: .center) {
                ModeBadge(isReplay: isReplay, isAutopilot: isAutopilot)
                Spacer(minLength: 8)
                if let photoCount {
                    PhotoCounter(count: photoCount, lastCaptureID: lastCaptureID)
                }
            }
            .frame(minHeight: 36)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { statusRowHeight = $0 }
            InstructionCard(
                instruction: instruction,
                tone: tone,
                reply: reply,
                eyebrow: eyebrow,
                // Capped, the words scroll and the legend scrolls with them; a separate legend
                // line at these sizes ran to seven lines and took the camera's place.
                legend: capsWords ? legend : nil,
                maxHeight: cardMaxHeight
            )
            if let legend, !capsWords {
                legendLine(legend)
            }
            Spacer(minLength: capsWords ? 2 * CameraChromeLayout.windowHalfHeight : 0)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { window in
                    if let cameraWindow, cameraWindow.wrappedValue != window { cameraWindow.wrappedValue = window }
                }
            bottom
        }
        .animation(.easeOut(duration: 0.2), value: legend)
        .padding(.horizontal, Metrics.edge)
        .padding(.top, CameraChromeLayout.stackTopPadding)
        .padding(.bottom, 8)
    }

    /// One Text with the symbol inline, as the result's sample badge is: the audit reported a
    /// Label with fixedSize as partially supporting Dynamic Type.
    private func legendLine(_ text: String) -> some View {
        Text("\(Image(systemName: "scope")) \(text)")
            .font(Typeface.hint)
            .foregroundStyle(Palette.chalk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ScrimShape.rounded(14))
            .accessibilityLabel(text)
            .accessibilityIdentifier("aim.legend")
            .transition(.opacity)
    }
}

/// `CameraChrome`'s layout constants, outside it because a generic type can't hold stored
/// static properties.
enum CameraChromeLayout {
    /// Half the open camera the chrome keeps around the middle of the screen at the
    /// accessibility sizes, where the reticle sits and where a target the phone points at
    /// lands. Room for a 64 pt aim ring with a margin. Uncapped, one instruction at AX5 filled
    /// an iPhone 17's screen and hid the ring under it (B-36). A layout choice, not measured on
    /// a phone.
    static let windowHalfHeight: CGFloat = 90
    /// The shortest the card gets to keep that window: about two lines of the instruction at
    /// AX5 and its reply. On a small screen the window gives way first.
    static let minCardHeight: CGFloat = 200
    static let stackSpacing: CGFloat = 10
    static let stackTopPadding: CGFloat = 4
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
