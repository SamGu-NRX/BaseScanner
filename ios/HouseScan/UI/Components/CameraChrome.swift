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
    /// Given the open camera between the card and the actions, for the aim ring to stay inside
    /// (`WayfindingOverlay`). It moves when the chrome scrolls.
    var cameraWindow: CameraWindow? = nil
    @ViewBuilder var bottom: Bottom

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var capsWords: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        // One layout at every text size: the chrome fills the screen and, only when the largest
        // text makes it taller than the screen, scrolls instead of squeezing the words. The
        // scroll view would swallow taps meant for the camera, so camera taps are caught inside
        // it, behind the chrome.
        GeometryReader { proxy in
            ScrollView {
                stack(topLimit: capsWords ? topLimit(proxy) : nil)
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

    /// How tall the status row and the card together may be for the card to end
    /// `windowHalfHeight` above the middle of the screen. This view starts under the status
    /// bar, above the stack's top padding.
    private func topLimit(_ proxy: GeometryProxy) -> CGFloat {
        let screenMiddle = (proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom) / 2 - proxy.safeAreaInsets.top
        return (screenMiddle - CameraChromeLayout.windowHalfHeight - CameraChromeLayout.stackTopPadding).rounded(.down)
    }

    private func stack(topLimit: CGFloat?) -> some View {
        VStack(spacing: CameraChromeLayout.stackSpacing) {
            if let topLimit {
                CardUnderStatusLayout(spacing: CameraChromeLayout.stackSpacing, limit: topLimit) {
                    statusRow
                    // The legend scrolls with the words in the card; a separate legend line at
                    // these sizes ran to seven lines and took the camera's place.
                    card(scrollsWords: true, legend: legend)
                }
            } else {
                statusRow
                card(scrollsWords: false, legend: nil)
                if let legend {
                    legendLine(legend)
                }
            }
            Spacer(minLength: capsWords ? 2 * CameraChromeLayout.windowHalfHeight : 0)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { window in
                    if let cameraWindow, cameraWindow.frame != window { cameraWindow.frame = window }
                }
            bottom
        }
        // The legend's arrival resizes the stack. With Reduce Motion it lands at once, since a
        // shorter resize still moves everything under it.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: legend)
        .padding(.horizontal, Metrics.edge)
        .padding(.top, CameraChromeLayout.stackTopPadding)
        .padding(.bottom, 8)
    }

    private var statusRow: some View {
        HStack(alignment: .center) {
            ModeBadge(isReplay: isReplay, isAutopilot: isAutopilot)
            Spacer(minLength: 8)
            if let photoCount {
                PhotoCounter(count: photoCount, lastCaptureID: lastCaptureID)
            }
        }
        .frame(minHeight: 36)
    }

    private func card(scrollsWords: Bool, legend: String?) -> some View {
        InstructionCard(instruction: instruction, tone: tone, reply: reply, eyebrow: eyebrow, scrollsWords: scrollsWords, legend: legend)
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

/// The open camera between the instruction card and the actions, in global coordinates.
/// `CameraChrome` writes it and only `WayfindingOverlay` reads it, so scrolling the chrome
/// redraws the aim overlay rather than the whole screen, as state owned by the screen did.
@MainActor
@Observable
final class CameraWindow {
    var frame: CGRect?
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

/// The status row, then the card under it, offered the height left under `limit` (never less
/// than `CameraChromeLayout.minCardHeight`). The chrome's scroll view offers its content no
/// height at all, so without this the card would never be told it has to fit.
private struct CardUnderStatusLayout: Layout {
    var spacing: CGFloat
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (status, card) = sizes(proposal: proposal, subviews: subviews)
        return CGSize(width: proposal.width ?? max(status.width, card.width), height: status.height + spacing + card.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (status, card) = sizes(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: status.height))
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + status.height + spacing),
            proposal: ProposedViewSize(width: bounds.width, height: card.height)
        )
    }

    private func sizes(proposal: ProposedViewSize, subviews: Subviews) -> (status: CGSize, card: CGSize) {
        let status = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let room = max(CameraChromeLayout.minCardHeight, limit - status.height - spacing)
        let card = subviews[1].sizeThatFits(ProposedViewSize(width: proposal.width, height: room))
        return (status, CGSize(width: card.width, height: min(card.height, room)))
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
