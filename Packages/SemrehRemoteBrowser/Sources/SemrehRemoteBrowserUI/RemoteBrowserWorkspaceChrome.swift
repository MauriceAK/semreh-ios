import SwiftUI
import SemrehRemoteBrowserCore

/// Presentation components for the remote browser workspace restyle.
///
/// Dark takeover chrome: charcoal shell, centered ownership header, full-width
/// stage with overlaid floating controls, and an inline local-draft composer.
/// Presentation only — no ownership, delivery, capability, or viewport
/// transform state lives here.

enum BrowserChrome {
    /// Shell charcoal, ~#181818.
    static let shell = Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255)
    /// Slightly lifted surface for the composer.
    static let raised = Color(white: 0.13)
    /// Icon chrome inside the floating capsule.
    static let icon = Color.white
}

// MARK: - Ownership header

/// Centered status header: subdued Close, title/hostname stack, trailing
/// progress or resume checkmark. Take control / Reconnect appear as a labeled
/// capsule in a contextual row beneath the centered status.
struct BrowserOwnershipHeader: View {
    @ObservedObject var viewModel: RemoteBrowserViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: { viewModel.close() }) {
                    Image(systemName: "xmark")
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("browser.close")
                .accessibilityLabel("Close")

                VStack(spacing: 2) {
                    Text(viewModel.title)
                        .font(.headline)
                    if let host = viewModel.hostDisplayName, !host.isEmpty {
                        Text(host)
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                    }
                    if showsSubtitle {
                        Text(viewModel.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("browser.status")
                .accessibilityLabel(viewModel.accessibilityStatus)

                trailingSlot
            }
            .padding(.horizontal, 16)

            contextualActionRow
        }
        .padding(.vertical, 14)
        .frame(minHeight: 80)
    }

    private var showsSubtitle: Bool {
        // The normal manual header is the intended compact two-line block
        // (title + hostname); "Remote input enabled" adds nothing the title
        // "You're in control" doesn't already say. Every other state's
        // subtitle carries real status and stays.
        if viewModel.primaryAction == .resume {
            return false
        }
        let subtitle = viewModel.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subtitle.isEmpty else { return false }
        if let host = viewModel.hostDisplayName, !host.isEmpty, subtitle == host {
            return false
        }
        return true
    }

    @ViewBuilder
    private var trailingSlot: some View {
        if viewModel.showsProgress {
            ProgressView()
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("In progress")
        } else {
            switch viewModel.primaryAction {
            case .resume:
                Button(action: { viewModel.resumeHermes() }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
                        )
                }
                .accessibilityIdentifier("browser.resume")
                .accessibilityLabel("Resume Hermes")
            default:
                // Balance the Close button so the status stays centered.
                Color.clear.frame(minWidth: 44, minHeight: 44)
            }
        }
    }

    @ViewBuilder
    private var contextualActionRow: some View {
        if !viewModel.showsProgress {
            switch viewModel.primaryAction {
            case .takeControl:
                HStack {
                    Spacer()
                    Button(action: { viewModel.requestControl() }) {
                        // Sizing lives on the label so the interactive and
                        // accessibility bounds are genuinely >= 44pt.
                        Text("Take control")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("browser.takeControl")
                    Spacer()
                }
            case .reconnect:
                HStack {
                    Spacer()
                    Button(action: { viewModel.reconnect() }) {
                        Text("Reconnect")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("browser.reconnect")
                    Spacer()
                }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Notice banner

/// Conditional, wrapping status notice beneath the header. Never a permanent
/// banner; the stale-frame shield stays on the viewport itself.
struct BrowserNoticeBanner: View {
    @ObservedObject var viewModel: RemoteBrowserViewModel

    var body: some View {
        if let notice = viewModel.notice {
            Text(notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("browser.notice")
        }
    }
}

// MARK: - Stage

/// Full-width browser stage: the unchanged viewport plus the stale-frame
/// shield, with the floating controls overlaid at the bottom. The overlay is
/// sized to its content so it never swallows viewport gestures.
struct BrowserStage: View {
    @ObservedObject var viewModel: RemoteBrowserViewModel
    var viewportControl: ViewportControl
    var composerOpen: Bool
    var onToggleComposer: () -> Void
    var onPasteIntoDraft: () -> Void

    var body: some View {
        GeometryReader { geometry in
            RemoteViewportView(
                image: viewModel.displayedImage,
                source: viewModel.sourceDimensions,
                viewportSize: geometry.size,
                generation: viewModel.surfaceGeneration,
                mode: viewModel.viewportMode,
                control: viewportControl,
                onRemoteAction: { [weak viewModel] action in
                    viewModel?.sendInput(action)
                }
            )
            .accessibilityIdentifier("browser.viewport")
            .overlay {
                if viewModel.shieldStaleFrame {
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .overlay {
                            Text("Frame may be stale")
                                .font(.caption)
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityIdentifier("browser.staleFrameShield")
                        }
                        .accessibilityLabel("Stale frame shielded")
                        .accessibilityElement(children: .contain)
                }
            }
            .allowsHitTesting(viewModel.viewportInteractive)
            .overlay(alignment: .bottom) {
                if viewModel.footerMode != .hidden {
                    BrowserControlsOverlay(
                        viewModel: viewModel,
                        viewportControl: viewportControl,
                        composerOpen: composerOpen,
                        onToggleComposer: onToggleComposer,
                        onPasteIntoDraft: onPasteIntoDraft
                    )
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Controls overlay

/// Stop Task (capability-gated) beside the compact floating tool capsule.
struct BrowserControlsOverlay: View {
    @ObservedObject var viewModel: RemoteBrowserViewModel
    var viewportControl: ViewportControl
    var composerOpen: Bool
    var onToggleComposer: () -> Void
    var onPasteIntoDraft: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if viewModel.showStopTask {
                StopTaskButton(viewModel: viewModel)
            }
            BrowserToolPalette(
                viewModel: viewModel,
                viewportControl: viewportControl,
                composerOpen: composerOpen,
                onToggleComposer: onToggleComposer,
                onPasteIntoDraft: onPasteIntoDraft
            )
        }
    }
}

/// Separate circular Stop control. Rendered only when the adapter supplies
/// the capability and the session can send human commands; stopping a video
/// stream is not stopping Hermes.
struct StopTaskButton: View {
    @ObservedObject var viewModel: RemoteBrowserViewModel

    var body: some View {
        Button(action: { viewModel.stopTask() }) {
            Image(systemName: "stop.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 48, height: 48)
                .background(BrowserChrome.shell)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.red.opacity(0.6), lineWidth: 1.5)
                )
        }
        .accessibilityLabel("Stop task")
    }
}

/// Compact floating capsule: keyboard toggle, interaction-mode menu, Fit,
/// and a More menu with paste-into-draft and special keys. Icon-only with
/// 44pt targets; smoked dark material, no bright pills.
struct BrowserToolPalette: View {
    @ObservedObject var viewModel: RemoteBrowserViewModel
    var viewportControl: ViewportControl
    var composerOpen: Bool
    var onToggleComposer: () -> Void
    var onPasteIntoDraft: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if viewModel.footerMode == .manual {
                Button(action: onToggleComposer) {
                    Image(systemName: "keyboard")
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(BrowserChrome.icon)
                        .background(
                            Circle()
                                .fill(composerOpen ? Color.white.opacity(0.18) : Color.clear)
                        )
                }
                .accessibilityIdentifier("browser.keyboard")
                .accessibilityLabel("Keyboard")

                Menu {
                    Picker("Interaction mode", selection: $viewModel.inputMode) {
                        Text("Direct").tag(ViewportInputMode.direct)
                        Text("Trackpad").tag(ViewportInputMode.trackpad)
                    }
                } label: {
                    Image(systemName: viewModel.inputMode == .direct ? "hand.raised" : "cursorarrow")
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(BrowserChrome.icon)
                }
                .accessibilityIdentifier("browser.mode")
                .accessibilityLabel("Interaction mode")
                .accessibilityValue(viewModel.inputMode == .direct ? "Direct" : "Trackpad")
            }

            Button(action: { viewportControl.fit() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(BrowserChrome.icon)
            }
            .accessibilityIdentifier("browser.fit")
            .accessibilityLabel("Fit")

            if viewModel.footerMode == .manual {
                Menu {
                    Button("Paste into draft") { onPasteIntoDraft() }
                    ForEach(SpecialKey.allCases, id: \.self) { key in
                        Button(key.displayName) { viewModel.sendSpecialKey(key) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(BrowserChrome.icon)
                }
                .accessibilityLabel("More actions")
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 52)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }
}

// MARK: - Draft composer

/// Inline local-draft composer shown above the native keyboard in normal
/// layouts. Typing and pasting only edit the local draft; Insert commits it
/// exactly once. Done only closes the composer and dismisses focus — it never
/// inserts, resumes, or closes the browser.
struct BrowserDraftComposer: View {
    @ObservedObject var viewModel: RemoteBrowserViewModel
    var editorFocus: FocusState<Bool>.Binding
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Local text draft")
                    .font(.headline)
                    .accessibilityIdentifier("browser.draftTitle")
                Spacer()
                Button("Done") { onDone() }
                    .frame(minHeight: 44)
            }

            TextEditor(text: Binding(
                get: { viewModel.draftText },
                set: { viewModel.draftText = $0 }
            ))
            .frame(minHeight: 80, maxHeight: 160)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3))
            )
            .focused(editorFocus)
            .accessibilityIdentifier("browser.draftEditor")
            .accessibilityLabel("Local text draft")

            if let status = viewModel.deliveryStatusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("browser.draftStatus")
            }

            Text("Sent only when you tap Insert text.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup("Why is this local?") {
                Text("Native composition edits this draft. Only committed text is sent when you press Insert text — this is committed-text insertion, not a mirrored remote editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Insert text") { viewModel.commitDraft() }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("browser.insertText")
        }
        .padding(12)
        .background(BrowserChrome.raised)
    }
}
