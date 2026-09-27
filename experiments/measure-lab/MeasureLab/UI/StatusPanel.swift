import SwiftUI

/// Tracking state, what ARKit has found, and the way into the session sheet.
struct StatusPanel: View {
    let session: LabSession
    let onOpenSession: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(trackingText)
                        .font(.headline)
                } icon: {
                    Circle()
                        .fill(trackingColor)
                        .frame(width: 10, height: 10)
                }
                Text(countsText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let error = session.storageError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.refused)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button("Session", systemImage: "list.bullet.rectangle", action: onOpenSession)
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                .contentShape(.rect)
        }
        .padding(.leading, 14)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Theme.panelShape)
    }

    private var trackingText: String {
        if session.isInterrupted { return "Camera paused" }
        if session.trackingState == .normal, !session.isTrackingStable { return "Tracking · hold steady" }
        return session.trackingState.instruction
    }

    private var trackingColor: Color {
        switch session.trackingState {
        case .normal: session.isTrackingStable ? .green : Theme.accent
        case .limited: Theme.warning
        case .notAvailable: Theme.refused
        }
    }

    private var countsText: String {
        let depth = if !session.lidarAvailable {
            "no LiDAR"
        } else if session.sceneDepthEnabled {
            "LiDAR depth on"
        } else {
            "LiDAR depth off"
        }
        let manifest = session.manifest
        return "\(session.horizontalPlaneCount) ground · \(session.verticalPlaneCount) wall planes · \(manifest.keyframes.count) frames · \(depth)"
    }
}
