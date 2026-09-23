import Foundation
import SwiftUI

struct ComposerVoiceStatus: Equatable {
    let text: String
    let systemImage: String
    let isError: Bool
    var inputLevel: Double? = nil
    var isTranscribing = false
}

struct ComposerVoiceStatusView: View {
    let status: ComposerVoiceStatus

    var body: some View {
        HStack(spacing: 8) {
            if let inputLevel = status.inputLevel {
                ComposerVoiceLevelBars(level: inputLevel)
            } else if status.isTranscribing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 24, height: 19)
            } else {
                Image(systemName: status.systemImage)
                    .frame(width: 24, height: 19)
            }

            Text(status.text)
                .lineLimit(2)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(status.isError ? Color.red : Color.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.text)
    }
}

/// Owns the 20 Hz level observation so microphone activity only redraws this
/// small view, rather than the whole composer and transcript layout.
struct ComposerVoiceLiveStatusView: View {
    let input: ComposerVoiceInputController

    var body: some View {
        let status: ComposerVoiceStatus
        switch input.state {
        case .listening, .serverListening:
            status = ComposerVoiceStatus(
                text: String(localized: "Listening..."), systemImage: "waveform",
                isError: false, inputLevel: input.inputLevel
            )
        case .transcribing:
            status = ComposerVoiceStatus(
                text: String(localized: "Transcribing..."), systemImage: "waveform",
                isError: false, isTranscribing: true
            )
        case .idle, .requestingPermission:
            status = ComposerVoiceStatus(text: "", systemImage: "waveform", isError: false)
        }
        return ComposerVoiceStatusView(status: status)
    }
}

/// The microphone meter is driven by measured audio power. A fixed footprint
/// keeps the composer from moving as bars change; Reduce Motion disables tweening.
struct ComposerVoiceLevelBars: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barScales: [Double] = [0.55, 0.8, 1, 0.72, 0.48]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(barScales.indices, id: \.self) { index in
                Capsule()
                    .frame(width: 3, height: 4 + 14 * min(1, max(0, level)) * barScales[index])
            }
        }
        .frame(width: 23, height: 19)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

/// The composer mic. A quick **tap** toggles on-device dictation (unchanged); a
/// **press-and-hold** records a server-transcribed voice note, releasing to send
/// and sliding up to cancel. Both paths run through a single
/// `DragGesture(minimumDistance: 0)`: touch-down schedules a `DispatchWorkItem`
/// after the hold threshold, and a release before it fires cancels the item and
/// counts as a tap → dictation. See `pressGesture` for why timing beats composing
/// `LongPressGesture`/`TapGesture`.
struct ComposerVoiceControlButton: View {
    let isListening: Bool
    let isDisabled: Bool
    let color: Color
    let isRecordingVoiceNote: Bool
    let onTap: () -> Void
    let onRecordingStart: () -> Void
    let onRecordingDragChanged: (CGFloat) -> Void
    let onRecordingEnd: (CGFloat) -> Void

    @State private var isPressing = false
    @State private var didTriggerRecording = false
    @State private var holdWorkItem: DispatchWorkItem?

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 18, weight: .regular))
            .frame(width: 28, height: 28)
            .chatMinimumHitTarget(in: Circle())
            .foregroundStyle(isListening || isRecordingVoiceNote ? Color.red : color)
            .scaleEffect(isRecordingVoiceNote ? 1.3 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecordingVoiceNote)
            .contentShape(Circle())
            .opacity(isDisabled && !isRecordingVoiceNote ? 0.4 : 1)
            .gesture(pressGesture)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                // Default VoiceOver activation (double-tap) toggles dictation.
                // VoiceOver synthesizes an activation rather than a real touch, so
                // the gesture's tap path never fires for it; without this the
                // dictation toggle is unreachable for VoiceOver users.
                if !isDisabled { onTap() }
            }
            .accessibilityAction(named: Text("Record voice note")) {
                // VoiceOver can't hold-to-talk, so this starts recording; the
                // recording bar then exposes "Stop and send" / "Cancel" actions.
                onRecordingStart()
            }
    }

    private var symbolName: String {
        if isRecordingVoiceNote { return "mic.fill" }
        return isListening ? "stop.circle.fill" : "mic"
    }

    private var accessibilityLabel: Text {
        if isRecordingVoiceNote { return Text("Recording voice note") }
        return isListening ? Text("Stop voice input") : Text("Voice input")
    }

    /// One `DragGesture(minimumDistance: 0)` distinguishes tap from hold by timing,
    /// which is far more reliable than composing `LongPressGesture`/`TapGesture`/
    /// `highPriorityGesture` (those let the press keep claiming the touch so the tap
    /// never wins). Touch-down schedules a delayed "start recording"; a release
    /// before the delay cancels it and counts as a tap → dictation. A perfectly
    /// still hold still records because the delay is timer-driven, not movement-driven.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isPressing {
                    isPressing = true
                    scheduleRecordingStart()
                }
                if isRecordingVoiceNote {
                    onRecordingDragChanged(value.translation.height)
                }
            }
            .onEnded { value in
                cancelScheduledRecordingStart()
                let triggered = didTriggerRecording
                isPressing = false
                didTriggerRecording = false

                if triggered {
                    onRecordingEnd(value.translation.height)
                } else if !isDisabled {
                    onTap()
                }
            }
    }

    private func scheduleRecordingStart() {
        didTriggerRecording = false
        let item = DispatchWorkItem {
            didTriggerRecording = true
            onRecordingStart()
        }
        holdWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ComposerVoiceNoteGesture.holdActivationDelay,
            execute: item
        )
    }

    private func cancelScheduledRecordingStart() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
    }
}

/// Telegram-style indicator shown above the composer while a voice note records:
/// a pulsing red dot, an `m:ss` timer, and a slide-to-cancel hint that turns red
/// once the cancel threshold is armed. Exposes explicit VoiceOver actions because
/// the hold-to-talk gesture isn't reachable with VoiceOver on.
struct ComposerVoiceRecordingBar: View {
    let recorder: ComposerVoiceNoteRecorder
    let isCancelArmed: Bool
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(isCancelArmed ? 0.4 : 1)

            ComposerVoiceLevelBars(level: recorder.inputLevel)
                .foregroundStyle(Color.red)

            Text(AudioDurationFormatter.string(from: recorder.elapsed))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Label(
                isCancelArmed
                    ? String(localized: "Release to cancel")
                    : String(localized: "Slide up to cancel"),
                systemImage: isCancelArmed ? "xmark.circle.fill" : "chevron.up"
            )
            .font(.caption)
            .foregroundStyle(isCancelArmed ? Color.red : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recording voice note, \(AudioDurationFormatter.string(from: recorder.elapsed))"))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAction(named: Text("Stop and send"), onStop)
        .accessibilityAction(named: Text("Cancel recording"), onCancel)
    }
}
