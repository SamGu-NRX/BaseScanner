import SwiftUI

/// The spot check before the result: one kept photo with the answer's spot and its clearance area
/// outlined, and one question with two equal answers. A photo can claim wall and ground behind a
/// bush, so the homeowner, who is standing there, says whether anything is in the way.
///
/// The answer replaces the two buttons and stays up a moment, saying what happens next, before
/// the engine moves on (to the result, or to checking the wall again).
struct SpotConfirmScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @State private var outlineShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if let check = state.spotCheck {
            content(check)
        } else {
            Palette.canvas.ignoresSafeArea()
        }
    }

    private func content(_ check: SpotCheck) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                badges(check)
                VStack(alignment: .leading, spacing: 8) {
                    Text(ScanCopy.spotQuestion.title)
                        .font(Typeface.screenTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let detail = ScanCopy.spotQuestion.detail {
                        Text(detail)
                            .font(Typeface.hint)
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("spot.question")
                VStack(alignment: .leading, spacing: 10) {
                    photo(check)
                    Text(ScanCopy.spotArea(check.area))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
                if typeSize.isAccessibilitySize {
                    answerArea(check)
                }
            }
            .padding(20)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The answers stay in reach at the bottom while the photo scrolls: below the photo they
        // started off screen, and the audit read the sliver that showed as failing contrast. At
        // accessibility sizes a pinned card would cover most of the screen and the question under
        // it, so there they follow the photo and the homeowner scrolls to them.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !typeSize.isAccessibilitySize {
                answerArea(check)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .background(Palette.canvas.shadow(.drop(color: .black.opacity(0.08), radius: 8, y: -2)), ignoresSafeAreaEdges: .bottom)
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.settle, value: check.answer)
        .onAppear {
            // The outline fades in once the photo is up, so the eye lands on the photo first.
            if reduceMotion {
                outlineShown = true
            } else {
                withAnimation(.easeOut(duration: 0.35).delay(0.15)) { outlineShown = true }
            }
        }
    }

    @ViewBuilder
    private func badges(_ check: SpotCheck) -> some View {
        if check.isSample || state.isReplay || state.isAutopilot {
            // Stacked, as on the result: side by side they squeeze each other at the largest sizes.
            VStack(alignment: .leading, spacing: 8) {
                if check.isSample {
                    // The spot is the bundled sample's: it must not pass for the homeowner's result.
                    Label("Sample spot, not from the server", systemImage: "flask.fill")
                        .font(Typeface.caption)
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Palette.caution, in: .capsule)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("spot.sampleBadge")
                }
                ModeBadge(isReplay: state.isReplay, isAutopilot: state.isAutopilot)
            }
        }
    }

    @ViewBuilder
    private func photo(_ check: SpotCheck) -> some View {
        Group {
            if let photo = check.photo, let wall = state.wall {
                let size = photo.projection.imageSize
                // The sensor image shown upright (rotated 90° clockwise) at its own aspect, so
                // filling the frame crops nothing and the projection's fill mapping holds.
                Color.clear
                    .aspectRatio(CGFloat(size.y / size.x), contentMode: .fit)
                    .overlay {
                        Image(decorative: photo.image, scale: 1, orientation: .right)
                            .resizable()
                            .scaledToFill()
                    }
                    .overlay {
                        SpotOutline(photo: photo, wall: wall, check: check)
                            .opacity(outlineShown ? 1 : 0)
                    }
                    .clipShape(.rect(cornerRadius: Metrics.cardRadius, style: .continuous))
                    // Tall enough to judge, short enough that the question and the photo share
                    // the screen with the answers on a 6.1 in phone.
                    .frame(maxHeight: 400)
                    .frame(maxWidth: .infinity)
            } else {
                // No kept photo shows the spot from the front: the homeowner looks at the wall.
                Label("No photo shows this spot well. Take a look at the wall itself.", systemImage: "photo")
                    .font(Typeface.hint)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(check.photo == nil ? "No photo of this spot" : "Photo of your wall")
        .accessibilityValue(ScanCopy.spotPhotoDescription(check))
        .accessibilityAddTraits(check.photo == nil ? [] : .isImage)
        .accessibilityIdentifier("spot.photo")
    }

    /// The two answers, or once answered, what happens next.
    @ViewBuilder
    private func answerArea(_ check: SpotCheck) -> some View {
        if let answer = check.answer {
            Answered(answer: answer)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
        } else {
            answers
                .transition(.opacity)
        }
    }

    /// Two equal answers on a white card, so neither reads as the default.
    private var answers: some View {
        VStack(spacing: 10) {
            AnswerButton(title: ScanCopy.spotClear, selected: false) { actions.answerSpotCheck(clear: true) }
                .accessibilityHint(ScanCopy.spotClearHint)
                .accessibilityIdentifier("action.spotClear")
            AnswerButton(title: ScanCopy.spotSomethingThere, selected: false) { actions.answerSpotCheck(clear: false) }
                .accessibilityHint(ScanCopy.spotSomethingThereHint)
                .accessibilityIdentifier("action.spotSomethingThere")
        }
        .padding(12)
        .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
    }
}

/// The answer given, and what happens next.
private struct Answered: View {
    var answer: SpotCheckAnswer

    var body: some View {
        let copy = ScanCopy.spotAnswered(answer)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: answer == .clear ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.title3.weight(.semibold))
                .foregroundStyle(answer == .clear ? Palette.passInk : Palette.reviewInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.title)
                    .font(Typeface.sectionTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = copy.detail {
                    Text(detail)
                        .font(Typeface.hint)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("spot.answered")
    }
}

/// The spot's footprint and its clearance area drawn over the photo, on the ground and up the
/// wall face to the battery's height: the space the question is about. Blue, the app's "look
/// here", with a white edge under the outline so it reads on any wall.
private struct SpotOutline: View {
    var photo: SpotCheck.Photo
    var wall: WallGeometry
    var check: SpotCheck

    var body: some View {
        Canvas { context, size in
            let geometry = WallProjection(projection: photo.projection, wall: wall, size: size)
            let face = polygon(geometry, along: check.area) { s, top in wall.world(s: s, height: top ? check.spotHeight : 0) }
            let ground = polygon(geometry, along: check.area) { s, far in wall.world(s: s, height: 0, out: far ? check.areaDepth : 0) }
            let footprint = polygon(geometry, along: check.spot) { s, far in
                wall.world(s: s, height: 0, out: far ? check.spotOut.upperBound : check.spotOut.lowerBound)
            }
            let dashed = StrokeStyle(lineWidth: 2.5, lineJoin: .round, dash: [9, 6])
            for path in [face, ground].compactMap(\.self) {
                context.fill(path, with: .color(Palette.signal.opacity(0.16)))
                context.stroke(path, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 5, lineJoin: .round))
                context.stroke(path, with: .color(Palette.signal), style: dashed)
            }
            if let footprint {
                context.fill(footprint, with: .color(Palette.signal.opacity(0.38)))
                context.stroke(footprint, with: .color(.white), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A band along the wall over `span`: its near edge from left to right, then its far edge back,
    /// in steps of at most 0.25 m so it bends round a corner the walk followed. Nil when any point
    /// is behind the camera.
    private func polygon(_ geometry: WallProjection, along span: ClosedRange<Float>, point: (_ s: Float, _ far: Bool) -> SIMD3<Float>) -> Path? {
        let steps = max(1, Int(((span.upperBound - span.lowerBound) / 0.25).rounded(.up)))
        let along = (0...steps).map { span.lowerBound + (span.upperBound - span.lowerBound) * Float($0) / Float(steps) }
        return geometry.polygon(along.map { point($0, false) } + along.reversed().map { point($0, true) })
    }
}
