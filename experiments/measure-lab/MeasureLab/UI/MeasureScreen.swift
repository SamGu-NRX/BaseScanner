import SwiftUI

/// Full-screen camera with the status on top and the tools at the bottom.
///
/// Tapping the camera marks that spot; Mark marks under the center ring, which keeps a finger off
/// the target. Freeze holds one frame still so a spot can be tapped precisely.
struct MeasureScreen: View {
    let session: LabSession
    @State private var capture: CaptureController
    @State private var layerSize: CGSize = .zero
    @State private var frozenTap: CGPoint?
    @State private var isShowingMeasure = false
    @State private var isShowingSession = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: LabSession) {
        self.session = session
        _capture = State(initialValue: CaptureController(session: session))
    }

    var body: some View {
        ZStack {
            cameraLayer
                .ignoresSafeArea()
            VStack(spacing: 10) {
                StatusPanel(session: session) {
                    isShowingSession = true
                }
                Spacer(minLength: 0)
                if let event = session.lastEvent {
                    ResultCard(event: event)
                        .id(event.id)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                }
                ControlPanel(
                    session: session,
                    isFrozen: capture.frozen != nil,
                    onMark: markAtRing,
                    onToggleFreeze: toggleFreeze,
                    onMeasure: { isShowingMeasure = true }
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .animation(.easeOut(duration: 0.2), value: session.lastEvent?.id)
        }
        .sensoryFeedback(trigger: session.lastEvent) { _, event in
            switch event?.tone {
            case .accepted: .success
            case .warning: .warning
            case .refused: .error
            case nil: nil
            }
        }
        .sheet(isPresented: $isShowingMeasure) {
            MeasureSheet(session: session)
        }
        .sheet(isPresented: $isShowingSession) {
            SessionSheet(session: session) { sceneDepth in
                frozenTap = nil
                capture.startNewSession(sceneDepth: sceneDepth)
            }
        }
        .onAppear {
            session.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.save() }
        }
        .onChange(of: capture.frozen == nil) {
            frozenTap = nil
        }
    }

    private var cameraLayer: some View {
        ZStack {
            ARContainerView(capture: capture)
            if let frozen = capture.frozen {
                FrozenFrameView(frozen: frozen, size: layerSize, guide: capture.epipolarGuide())
            }
            Color.clear
                .contentShape(.rect)
                .onTapGesture(coordinateSpace: .local) { location in
                    if capture.frozen != nil { frozenTap = location }
                    capture.mark(at: location, viewSize: layerSize)
                }
                .accessibilityHidden(true)
            Reticle()
                .allowsHitTesting(false)
            if let frozenTap {
                TapMarker()
                    .position(frozenTap)
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            layerSize = size
        }
    }

    private func markAtRing() {
        let center = CGPoint(x: layerSize.width / 2, y: layerSize.height / 2)
        if capture.frozen != nil { frozenTap = center }
        capture.mark(at: center, viewSize: layerSize)
    }

    private func toggleFreeze() {
        if capture.frozen == nil {
            capture.freeze(viewSize: layerSize)
        } else {
            capture.unfreeze()
        }
    }
}
