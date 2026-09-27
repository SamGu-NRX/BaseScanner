import SwiftUI

/// Three short pages before the camera opens: what happens and how long, how the photos work,
/// and staying safe. The last page asks for the camera.
struct OnboardingScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            title: "Let's find a spot for your battery",
            body: "Walk along the wall by your electric meter for about 2 minutes. Your phone measures as you go.",
            art: .walk
        ),
        // What leaves the phone is said before the camera is asked for: uploads carry the wall's
        // measurements; the photos stay in the app until the scan is started over.
        OnboardingPage(
            title: "Your phone takes the photos",
            body: "Just walk slowly. The haze on the wall clears as your phone sees it.",
            note: "Only the wall's measurements are sent. Your photos stay on this phone and are deleted when you start over.",
            art: .fog
        ),
        OnboardingPage(
            title: "Stay safe out there",
            body: nil,
            art: .safety
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ModeBadge(isReplay: state.isReplay, isAutopilot: state.isAutopilot)
                DeveloperOptionsButton()
                Spacer()
                if page < pages.count - 1 {
                    Button("Skip") {
                        // Reduce Motion: the page changes in place, without sliding past the others.
                        withAnimation(reduceMotion ? nil : Motion.screen) { page = pages.count - 1 }
                    }
                    .font(Typeface.hint.weight(.semibold))
                    .foregroundStyle(Palette.signalText)
                    .frame(minWidth: Metrics.minTarget, minHeight: Metrics.minTarget)
                    .accessibilityIdentifier("action.onboardingSkip")
                }
            }
            .frame(minHeight: Metrics.minTarget)
            .padding(.horizontal, 20)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    OnboardingPageView(page: pages[index], isActive: page == index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 16) {
                PageDots(count: pages.count, current: page)
                if page == pages.count - 1 {
                    VStack(spacing: 8) {
                        Button {
                            actions.finishOnboarding()
                        } label: {
                            Label("Allow camera", systemImage: "camera.fill")
                        }
                        .buttonStyle(.primary)
                        .accessibilityHint("Your phone will ask to use the camera")
                        .accessibilityIdentifier("action.finishOnboarding")
                        Text("Your phone will ask to use the camera.")
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                    }
                    .transition(.opacity)
                } else {
                    Button("Next") {
                        withAnimation(reduceMotion ? nil : Motion.screen) { page += 1 }
                    }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("action.onboardingNext")
                    .transition(.opacity)
                }
            }
            .animation(Motion.screen, value: page)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background(Palette.canvas.ignoresSafeArea())
    }
}

private struct OnboardingPage {
    enum Art { case walk, fog, safety }
    var title: String
    var body: String?
    /// A quieter line under the body, set apart with an icon.
    var note: String?
    var art: Art
}

private struct OnboardingPageView: View {
    var page: OnboardingPage
    var isActive: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if page.art == .safety {
                    text
                    SafetyArt()
                } else {
                    Group {
                        if page.art == .walk {
                            WalkArt(isActive: isActive)
                        } else {
                            FogArt(isActive: isActive)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .accessibilityHidden(true)
                    text
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(page.title)
                .font(Typeface.screenTitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let body = page.body {
                Text(body)
                    .font(.system(.title3, design: .rounded, weight: .regular))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = page.note {
                Label(note, systemImage: "lock.fill")
                    .font(Typeface.hint)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .accessibilityIdentifier("onboarding.privacy")
            }
        }
    }
}

private struct PageDots: View {
    var count: Int
    var current: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Palette.signal : Palette.unseen.opacity(0.45))
                    .frame(width: index == current ? 22 : 8, height: 8)
            }
        }
        // The current dot widens; with Reduce Motion it changes without the stretch.
        .animation(reduceMotion ? nil : Motion.settle, value: current)
        // The page view already announces its position; these dots are for sighted users.
        .accessibilityHidden(true)
    }
}

// MARK: - Illustrations

/// A wall drawn in the app's own vocabulary: siding lines, the meter as a blue dot.
private struct WallDrawing: View {
    var body: some View {
        Canvas { context, size in
            let wall = CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.72)
            context.fill(Path(roundedRect: wall, cornerRadius: 18), with: .color(Color(red: 0.93, green: 0.91, blue: 0.87)))
            var siding = Path()
            var y = wall.minY + 22
            while y < wall.maxY - 6 {
                siding.move(to: CGPoint(x: wall.minX + 12, y: y))
                siding.addLine(to: CGPoint(x: wall.maxX - 12, y: y))
                y += 18
            }
            context.stroke(siding, with: .color(.black.opacity(0.06)), lineWidth: 1.5)
            let ground = CGRect(x: 0, y: wall.maxY + 8, width: size.width, height: size.height - wall.maxY - 8)
            context.fill(Path(roundedRect: ground, cornerRadius: 14), with: .color(Color(red: 0.80, green: 0.86, blue: 0.76)))
            // Meter
            let meter = CGRect(x: size.width * 0.44, y: wall.height * 0.38, width: size.width * 0.12, height: size.width * 0.15)
            context.fill(Path(roundedRect: meter, cornerRadius: 8), with: .color(Color(white: 0.62)))
            let dial = meter.insetBy(dx: meter.width * 0.2, dy: meter.height * 0.25).offsetBy(dx: 0, dy: -meter.height * 0.08)
            context.fill(Path(ellipseIn: dial), with: .color(Palette.signal))
        }
    }
}

private struct WalkArt: View {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // A slow walk from one end to the other and back: one lap every 6 s.
            let phase = reduceMotion ? 0.5 : (sin(t * .pi / 3) + 1) / 2
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    WallDrawing()
                    Canvas { context, size in
                        let y = size.height * 0.86
                        for i in 0..<11 {
                            let x = size.width * (0.08 + 0.084 * Double(i))
                            context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 3, width: 8, height: 6)), with: .color(Palette.signal.opacity(0.85)))
                        }
                    }
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(8)
                        .background(.white, in: .rect(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                        .position(x: size.width * (0.14 + 0.72 * phase), y: size.height * 0.72)
                    Text("About 2 min")
                        .font(Typeface.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Palette.ink, in: .capsule)
                        .position(x: size.width * 0.82, y: 26)
                }
            }
        }
    }
}

private struct FogArt: View {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // Cells clear left to right over 4 s, hold clear for 1.5 s, then fog rolls back in.
            let cycle = reduceMotion ? 2.4 : t.truncatingRemainder(dividingBy: 6.5)
            ZStack {
                WallDrawing()
                Canvas { context, size in
                    let wallHeight = size.height * 0.72
                    let columns = 8
                    let width = size.width / CGFloat(columns)
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 8))
                        for column in 0..<columns {
                            let clearAt = 0.4 + Double(column) * 0.45
                            let fade: Double
                            if cycle < clearAt { fade = 1 }
                            else if cycle < clearAt + 0.7 { fade = 1 - (cycle - clearAt) / 0.7 }
                            else if cycle > 5.8 { fade = min(1, (cycle - 5.8) / 0.7) }
                            else { fade = 0 }
                            let rect = CGRect(x: CGFloat(column) * width, y: -6 - (1 - fade) * 8, width: width + 1, height: wallHeight + 6)
                            layer.fill(Path(rect), with: .color(Color(white: 0.99).opacity(0.9 * fade)))
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: 18))
            }
        }
    }
}

private struct SafetyArt: View {
    private let items: [(symbol: String, title: String, detail: String)] = [
        ("figure.stand", "Stay on the ground", "No ladders, roofs or climbing."),
        ("flame.fill", "Keep clear of gas pipes", "Don't lean on or step over the gas meter."),
        ("hand.raised.fill", "Don't open the meter", "Leave covers closed and wires alone."),
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(items, id: \.title) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Palette.signal)
                        .frame(width: 48, height: 48)
                        .background(Palette.signal.opacity(0.1), in: .circle)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(Typeface.sectionTitle)
                        Text(item.detail)
                            .font(Typeface.hint)
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(Palette.surface, in: .rect(cornerRadius: 20, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }
}
