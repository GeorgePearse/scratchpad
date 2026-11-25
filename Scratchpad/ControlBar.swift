import ScratchKit
import SwiftUI

/// The only chrome on the pad: model status, pen and eraser, undo, clear, settings.
struct ControlBar: View {
    let store: PadStore
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 2) {
            LoopButton(store: store, showSettings: $showSettings)

            Divider().frame(height: 22).padding(.horizontal, 4)

            // Two explicit tools, one always lit, so it is obvious which is active and how to get back.
            BarButton("Pen", systemImage: "pencil.tip", isOn: store.tool == .pen) {
                store.tool = .pen
            }
            BarButton("Eraser", systemImage: "eraser", isOn: store.tool == .eraser) {
                store.tool = .eraser
            }

            Divider().frame(height: 22).padding(.horizontal, 4)

            BarButton("Show everything", systemImage: "arrow.down.right.and.arrow.up.left") {
                store.showContent()
            }
            .disabled(store.isBlank)
            BarButton("Undo", systemImage: "arrow.uturn.backward") {
                store.undo()
            }
            .disabled(!store.canUndo)
            BarButton("Clear", systemImage: "trash") {
                store.clear()
            }
            .disabled(store.isBlank)
            BarButton("Settings", systemImage: "gearshape") {
                showSettings = true
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .barBackground()
    }
}

/// Shows what the model loop is doing, and switches it on and off.
private struct LoopButton: View {
    let store: PadStore
    @Binding var showSettings: Bool

    private var loop: ModelLoop { store.loop }

    var body: some View {
        Button {
            if needsKey {
                showSettings = true
            } else {
                store.setLoopEnabled(!loop.isEnabled)
            }
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    if loop.phase == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: status.symbol)
                            .foregroundStyle(status.tint)
                    }
                }
                .frame(width: 22, height: 22)

                Text(status.text)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(loop.isEnabled ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    // Hug short statuses; wrap long error messages at 260 points.
                    .frame(maxWidth: 260, alignment: .leading)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model")
        .accessibilityValue(status.text)
        .accessibilityHint(needsKey ? "Opens settings" : loop.isEnabled ? "Switches the model off" : "Switches the model on")
    }

    /// The loop is on but has no model to run.
    private var needsKey: Bool {
        loop.isEnabled && (loop.needsSetup || store.needsAPIKey)
    }

    private var status: (text: String, symbol: String, tint: Color) {
        if needsKey {
            return ("Add an API key", "key.fill", .orange)
        }
        if let error = loop.lastError {
            return (error, "exclamationmark.triangle.fill", .orange)
        }
        switch loop.phase {
        case .off:
            return ("Model off", "sparkles", .secondary)
        case .running:
            return ("Thinking", "sparkles", .accentColor)
        case .idle, .waiting:
            guard let latency = loop.lastLatency, let edits = loop.lastEditCount else {
                return ("Watching", "sparkles", .accentColor)
            }
            let seconds = Double(latency.components.seconds) + Double(latency.components.attoseconds) / 1e18
            let time = seconds.formatted(.number.precision(.fractionLength(1)))
            return ("\(time) s · \(edits) \(edits == 1 ? "edit" : "edits")", "sparkles", .accentColor)
        }
    }
}

private struct BarButton: View {
    let title: String
    let systemImage: String
    var isOn = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, systemImage: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                .opacity(isEnabled ? 1 : 0.3)
                .frame(width: 44, height: 44)
                .background(isOn ? Color.accentColor.opacity(0.15) : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private extension View {
    @ViewBuilder
    func barBackground() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
        }
    }
}
