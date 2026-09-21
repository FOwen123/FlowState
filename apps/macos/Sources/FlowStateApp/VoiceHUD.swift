import AppKit
import SwiftUI
import FlowStateCore

@MainActor
final class VoiceHUDController {
    private let model = VoiceHUDModel()
    private var panel: VoiceHUDPanel?

    func show(
        status: String,
        transcript: String,
        isListening: Bool,
        purpose: SpeechSessionPurpose? = nil,
        onStop: @escaping () -> Void,
        onConfirm: (() -> Void)? = nil,
        lastResponse: String? = nil,
        currentStep: String? = nil
    ) {
        model.status = status
        model.transcript = transcript
        model.isListening = isListening
        model.purpose = purpose
        model.onStop = onStop
        model.onConfirm = onConfirm
        model.canConfirm = onConfirm != nil
        model.lastResponse = lastResponse
        model.currentStep = currentStep

        let panel = makePanelIfNeeded()
        if let host = panel.contentView as? NSHostingView<VoiceHUDView> {
            host.rootView = VoiceHUDView(model: model)
            panel.setContentSize(host.fittingSize)
        }
        position(panel)
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
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 56),
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
final class VoiceHUDModel: ObservableObject {
    @Published var status = "Ready"
    @Published var transcript = ""
    @Published var isListening = false
    @Published var purpose: SpeechSessionPurpose?
    var onStop: () -> Void = {}
    var onConfirm: (() -> Void)?
    @Published var canConfirm = false
    @Published var lastResponse: String?
    @Published var currentStep: String?
}

private final class VoiceHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct VoiceHUDView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var model: VoiceHUDModel

    private var showsDetails: Bool {
        model.canConfirm || !model.isListening ||
            model.currentStep != nil ||
            !(model.status.hasPrefix("Listening —") || model.status.hasPrefix("Listening for "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VoiceHUDWaveform(isListening: model.isListening)
                    .frame(width: 48, height: 26)
                    .accessibilityLabel(model.isListening
                        ? L10n.format("Listening %@", model.purpose?.displayName ?? "")
                        : L10n.text("Processing"))
                Spacer(minLength: 0)
                Button(action: model.onStop) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.08), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Cancel task"))
                .help(L10n.text("Cancel listening and the current Mac Control task"))
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)

            if showsDetails {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.transcript.isEmpty {
                        Text(model.transcript)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(L10n.text("Latest transcript"))
                    }
                    Text(L10n.text(model.status == "The focused control is not editable."
                        ? "Click a text field, then dictate again." : model.status))
                        .font(.custom("Helvetica Neue", size: 14))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(L10n.text("Voice status"))
                    if let currentStep = model.currentStep {
                        Text(currentStep)
                            .font(.custom("Helvetica Neue", size: 13))
                            .foregroundStyle(PaperStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(L10n.text("Current plan step"))
                    }
                    if let lastResponse = model.lastResponse, lastResponse != model.status {
                        Text(lastResponse)
                            .font(.custom("Helvetica Neue", size: 13))
                            .foregroundStyle(PaperStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(L10n.text("Last spoken response"))
                    }
                    if model.canConfirm {
                        Button(L10n.text("Confirm action")) { model.onConfirm?() }
                            .accessibilityLabel(L10n.text("Confirm proposed action"))
                            .buttonStyle(VoiceHUDActionStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(width: showsDetails ? 360 : 140)
        .glassEffect(showsDetails || reduceTransparency ? .identity : .regular.tint(PaperStyle.hud),
                     in: .rect(cornerRadius: showsDetails ? 20 : 28))
        .background {
            if showsDetails || reduceTransparency {
                RoundedRectangle(cornerRadius: showsDetails ? 20 : 28)
                    .fill(PaperStyle.hud)
                    .overlay { RoundedRectangle(cornerRadius: showsDetails ? 20 : 28).stroke(PaperStyle.controlBorder, lineWidth: 1) }
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)

    }
}

private struct VoiceHUDActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Helvetica Neue", size: 14))
            .foregroundStyle(configuration.isPressed ? PaperStyle.accent : .white)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(configuration.isPressed ? PaperStyle.selected : .clear, in: Capsule())
            .overlay(Capsule().stroke(PaperStyle.controlBorder, lineWidth: 1))
    }
}

private struct VoiceHUDWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isListening: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !isListening || reduceMotion)) { timeline in
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 4 + Double(index) * 0.7
                    let level = isListening && !reduceMotion ? 0.25 + 0.75 * ((sin(phase) + 1) / 2) : [0.2, 0.6, 0.85, 0.7, 1, 0.5, 0.2][index]
                    Capsule()
                        .fill(isListening ? PaperStyle.accent : PaperStyle.muted)
                        .frame(width: 3, height: 4 + CGFloat(level * 20))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
