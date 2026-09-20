import AppKit
import SwiftUI

@MainActor
final class VoiceHUDController {
    private let model = VoiceHUDModel()
    private var panel: VoiceHUDPanel?

    func show(
        status: String,
        transcript: String,
        isListening: Bool,
        onFinish: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        model.status = status
        model.transcript = transcript
        model.isListening = isListening
        model.onFinish = onFinish
        model.onStop = onStop

        let panel = makePanelIfNeeded()
        if !panel.isVisible { position(panel) }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanelIfNeeded() -> VoiceHUDPanel {
        if let panel {
            return panel
        }

        let panel = VoiceHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 156),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: VoiceHUDView(model: model))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let frame = panel.frame
        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.minY + 24
        )
        panel.setFrameOrigin(origin)
    }
}

@MainActor
private final class VoiceHUDModel: ObservableObject {
    @Published var status = "Ready"
    @Published var transcript = ""
    @Published var isListening = false
    var onFinish: () -> Void = {}
    var onStop: () -> Void = {}
}

private final class VoiceHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct VoiceHUDView: View {
    @ObservedObject private var localization = UILocalization.shared
    @ObservedObject var model: VoiceHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VoiceHUDWaveform(isListening: model.isListening)
                    .frame(width: 64, height: 30)
                    .accessibilityLabel(L10n.text(model.isListening ? "Listening" : "Processing"))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Flow State"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VoiceHUDPalette.text)
                    Text(L10n.text(model.status))
                        .font(.system(size: 12))
                        .foregroundStyle(VoiceHUDPalette.muted)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button(L10n.text("Finish"), action: model.onFinish)
                        .buttonStyle(VoiceHUDButtonStyle(tint: VoiceHUDPalette.accent))
                        .accessibilityLabel(L10n.text("Finish voice session"))
                        .disabled(!model.isListening)
                        .opacity(model.isListening ? 1 : 0.45)
                    Button(L10n.text("Stop"), action: model.onStop)
                        .buttonStyle(VoiceHUDButtonStyle(tint: VoiceHUDPalette.stop))
                        .accessibilityLabel(L10n.text("Stop voice session"))
                }
            }

            Divider()
                .overlay(VoiceHUDPalette.divider)
                .padding(.vertical, 12)

            Text(model.transcript.isEmpty ? (model.isListening ? L10n.text("Listening for your voice…") : L10n.text("No transcript yet")) : model.transcript)
                .font(.system(size: 13))
                .foregroundStyle(model.transcript.isEmpty ? VoiceHUDPalette.muted : VoiceHUDPalette.text)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(L10n.text("Latest transcript"))
        }
        .padding(16)
        .frame(width: 460, height: 156)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(VoiceHUDPalette.panel)
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(VoiceHUDPalette.divider, lineWidth: 1)
                }
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
    }
}

private struct VoiceHUDButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(VoiceHUDPalette.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(tint.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
    }
}

private struct VoiceHUDWaveform: View {
    let isListening: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !isListening)) { timeline in
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<8, id: \.self) { index in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 4.0 + Double(index) * 0.7
                    let level = isListening ? 0.25 + 0.75 * ((sin(phase) + 1) / 2) : 0.25
                    Capsule()
                        .fill(isListening ? VoiceHUDPalette.accent : VoiceHUDPalette.muted)
                        .frame(width: 4, height: 6 + CGFloat(level * 22))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private enum VoiceHUDPalette {
    static let panel = Color(red: 11 / 255, green: 14 / 255, blue: 20 / 255)
    static let text = Color.white
    static let muted = Color(red: 161 / 255, green: 164 / 255, blue: 165 / 255)
    static let divider = Color(red: 41 / 255, green: 45 / 255, blue: 48 / 255)
    static let accent = Color(red: 88 / 255, green: 194 / 255, blue: 255 / 255)
    static let stop = Color(red: 214 / 255, green: 95 / 255, blue: 104 / 255)
}
