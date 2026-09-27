import SwiftUI

/// Tool picker, the current step, and the Freeze · Mark · Measure row.
struct ControlPanel: View {
    let session: LabSession
    let isFrozen: Bool
    let onMark: () -> Void
    let onToggleFreeze: () -> Void
    let onMeasure: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Tool.allCases) { tool in
                    ToolButton(tool: tool, isSelected: session.tool == tool) {
                        session.select(tool)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stepText)
                    .font(.subheadline)
                    .foregroundStyle(session.markBlocker == nil ? .primary : Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = session.restartTitle {
                    Button(title, action: session.restartTool)
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                }
            }

            HStack(spacing: 10) {
                Button(action: onToggleFreeze) {
                    Label(isFrozen ? "Live" : "Freeze", systemImage: isFrozen ? "video" : "pause")
                        .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
                }
                .buttonStyle(PressableButtonStyle())
                .background(.thinMaterial, in: .capsule)

                Button(action: onMark) {
                    Label("Mark", systemImage: "plus.viewfinder")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
                        .background(Theme.accent.opacity(session.markBlocker == nil ? 1 : 0.4), in: .capsule)
                }
                .buttonStyle(PressableButtonStyle())
                .layoutPriority(1)

                Button(action: onMeasure) {
                    Label("Measure", systemImage: "ruler")
                        .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
                }
                .buttonStyle(PressableButtonStyle())
                .background(.thinMaterial, in: .capsule)
                .disabled(session.manifest.points.isEmpty)
            }
            .font(.subheadline.bold())
            .labelStyle(.titleAndIcon)
        }
        .padding(12)
        .background(.regularMaterial, in: Theme.panelShape)
    }

    private var stepText: String {
        if let blocker = session.markBlocker { return blocker }
        if isFrozen { return "Frozen frame. Tap the spot to measure. \(session.instruction)" }
        return session.instruction
    }
}

private struct ToolButton: View {
    let tool: Tool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tool.systemImage)
                    .font(.body)
                Text(tool.title)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? .black : .primary)
            .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
            .background(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.thinMaterial), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
