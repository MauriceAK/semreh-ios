import SwiftUI

struct VoiceControls: View {
    @Bindable var voice: VoiceDictationController
    let download: () -> Void
    let finish: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize && voice.phase.recoveryFailure != nil { EmptyView() }
        else { controls }
    }

    @ViewBuilder
    private var controls: some View {
        switch voice.phase {
        case .idle: EmptyView()
        case .needsDownload(let language):
            VStack(alignment: .leading, spacing: 8) {
                Text(VoiceFailure.downloadRequired(language).localizedDescription).font(.callout)
                    .accessibilityIdentifier("voiceDownloadPrompt")
                HStack {
                    Button("Not now") { voice.cancel() }.frame(minHeight: 44)
                    Spacer(minLength: 8)
                    Button("Download", action: download).fontWeight(.semibold).frame(minHeight: 44)
                        .accessibilityIdentifier("downloadVoiceModel")
                }
            }.padding(.horizontal, 12).padding(.top, 8)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(failure.localizedDescription).font(.callout).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("voiceError")
                    Button { voice.cancel() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.accessibilityLabel("Dismiss dictation message").accessibilityIdentifier("dismissVoiceError")
                }
                if failure == .microphoneDenied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }.frame(minHeight: 44).accessibilityIdentifier("voiceSettings")
                }
            }.padding(.leading, 12)
        default:
            HStack(spacing: 8) {
                Button { voice.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).frame(width: 44, height: 44)
                }.accessibilityLabel("Cancel dictation").accessibilityIdentifier("cancelDictation")
                Group {
                    switch voice.phase {
                    case .recording:
                        VoiceWaveform(voice: voice)
                    case .downloading(let progress):
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Downloading model · \(Int(progress * 100))%").font(.caption)
                                .accessibilityIdentifier("voiceDownloadProgress")
                            ProgressView(value: progress)
                        }
                    case .transcribing:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Transcribing…").font(.callout).accessibilityIdentifier("voiceTranscribing")
                        }
                    default:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Preparing dictation…").font(.callout).accessibilityIdentifier("voicePreparing")
                        }
                    }
                }.frame(maxWidth: .infinity, minHeight: 44)
                if voice.phase == .recording {
                    Button(action: finish) {
                        Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white).frame(width: 36, height: 36)
                            .background(Color.blue, in: Circle()).frame(width: 44, height: 44)
                    }.accessibilityLabel("Finish dictation").accessibilityIdentifier("finishDictation")
                }
            }.padding(.horizontal, 4)
        }
    }
}

private struct VoiceWaveform: View {
    @Bindable var voice: VoiceDictationController
    var body: some View {
        GeometryReader { geometry in
            let count = voice.levels.count
            let spacing: CGFloat = 3
            let width = max(1, (geometry.size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(voice.levels.indices, id: \.self) { index in
                    Capsule().fill(Color.primary.opacity(0.85))
                        .frame(width: width, height: 3 + CGFloat(voice.levels[index]) * 29)
                }
            }.frame(height: geometry.size.height)
        }.frame(height: 36).clipped()
            .accessibilityElement(children: .ignore).accessibilityLabel("Recording your voice")
            .accessibilityIdentifier("voiceWaveform")
    }
}

struct VoiceRecoveryAlert: ViewModifier {
    @Bindable var voice: VoiceDictationController
    let download: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        // Explicit actions own recovery; a delayed alert dismissal must not cancel a newer attempt.
        content.alert(title, isPresented: Binding(
            get: { typeSize.isAccessibilitySize && voice.phase.recoveryFailure != nil },
            set: { _ in }
        )) {
            if case .needsDownload = voice.phase {
                Button("Download", action: download).accessibilityIdentifier("downloadVoiceModel")
                Button("Not now", role: .cancel) { voice.cancel() }
            } else {
                if voice.phase.recoveryFailure == .microphoneDenied {
                    Button("Open Settings") {
                        voice.cancel()
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }.accessibilityIdentifier("voiceSettings")
                }
                Button("Dismiss", role: .cancel) { voice.cancel() }.accessibilityIdentifier("dismissVoiceError")
            }
        } message: {
            Text(voice.phase.recoveryFailure?.localizedDescription ?? "")
        }
    }

    private var title: String {
        if case .needsDownload = voice.phase { return "Download speech model" }
        return "Dictation unavailable"
    }
}

private extension VoicePhase {
    var recoveryFailure: VoiceFailure? {
        switch self {
        case .needsDownload(let language): .downloadRequired(language)
        case .failed(let failure): failure
        default: nil
        }
    }
}
