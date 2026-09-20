import SwiftUI
import SemrehRemoteBrowserCore

/// Native browser workspace: SwiftUI chrome around the UIKit viewport.
///
/// Fixed design contract:
/// - Compact safe-area-aware header: Close (44pt), center ownership
///   title/domain stack, trailing labeled primary action as applicable.
/// - The viewport fills all remaining space with aspect fit; letterboxing
///   reflects the aspect ratio.
/// - Floating native material footer bar, inset 12pt, 44pt hit targets,
///   kept above the keyboard by safe-area layout.
/// - Required states/copy per the design table; accessibility identifiers
///   `browser.close`, `browser.takeControl`, `browser.resume`,
///   `browser.status`, `browser.keyboard`, `browser.insertText`,
///   `browser.mode`, `browser.fit`, `browser.viewport`.
///
/// This view is production-honest: it never claims a simulated session is a
/// real Hermes connection. BrowserLab adds its own simulated-session banner.
public struct RemoteBrowserWorkspaceView: View {
    @ObservedObject public var viewModel: RemoteBrowserViewModel
    @StateObject private var viewportControl = ViewportControl()
    @State private var showingDraftEditor = false

    public init(viewModel: RemoteBrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            viewportArea
            if let notice = viewModel.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("browser.notice")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if viewModel.footerMode != .hidden {
                footerBar
            }
        }
        .sheet(isPresented: $showingDraftEditor) {
            draftEditorSheet
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.close() }) {
                Image(systemName: "xmark")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("browser.close")
            .accessibilityLabel("Close")

            VStack(spacing: 2) {
                Text(viewModel.title)
                    .font(.headline)
                Text(viewModel.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("browser.status")
            .accessibilityLabel(viewModel.accessibilityStatus)

            trailingHeaderAction
        }
        .padding(12)
    }

    @ViewBuilder
    private var trailingHeaderAction: some View {
        if viewModel.showsProgress {
            ProgressView()
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("In progress")
        } else {
            switch viewModel.primaryAction {
            case .takeControl:
                Button("Take control") { viewModel.requestControl() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("browser.takeControl")
            case .resume:
                Button("Resume Hermes") { viewModel.resumeHermes() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("browser.resume")
            case .reconnect:
                Button("Reconnect") { viewModel.reconnect() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("browser.reconnect")
            case .none:
                // Balance the Close button so the title stays centered.
                Color.clear.frame(minWidth: 44, minHeight: 44)
            }
        }
    }

    // MARK: - Viewport

    private var viewportArea: some View {
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
                        }
                        .accessibilityLabel("Stale frame shielded")
                }
            }
            .allowsHitTesting(viewModel.viewportInteractive)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 16) {
            if viewModel.footerMode == .manual {
                Button(action: { showingDraftEditor = true }) {
                    Label("Keyboard", systemImage: "keyboard")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("browser.keyboard")

                Picker("Interaction mode", selection: $viewModel.inputMode) {
                    Text("Direct").tag(ViewportInputMode.direct)
                    Text("Trackpad").tag(ViewportInputMode.trackpad)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("browser.mode")
            }

            Button(action: { viewportControl.fit() }) {
                Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("browser.fit")

            if viewModel.footerMode == .manual {
                Menu {
                    Button("Paste into draft") { pasteIntoDraft() }
                    ForEach(SpecialKey.allCases, id: \.self) { key in
                        Button(key.displayName) { viewModel.sendSpecialKey(key) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("More actions")
            }

            // The Stop Task button appears ONLY when the injected adapter
            // supplies that capability; stopping a video stream is not
            // stopping Hermes.
            if viewModel.showStopTask {
                Button("Stop Task") { viewModel.stopTask() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .frame(minHeight: 44)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func pasteIntoDraft() {
        #if canImport(UIKit)
        if let text = UIPasteboard.general.string, !text.isEmpty {
            viewModel.draftText = text
            showingDraftEditor = true
        }
        #endif
    }

    // MARK: - Draft editor

    private var draftEditorSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Local text draft")
                    .font(.headline)
                    .accessibilityIdentifier("browser.draftTitle")
                Text("Native composition edits this draft. Only committed text is sent when you press Insert text — this is committed-text insertion, not a mirrored remote editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { viewModel.draftText },
                    set: { viewModel.draftText = $0 }
                ))
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3))
                )
                .accessibilityIdentifier("browser.draftEditor")
                .accessibilityLabel("Local text draft")
                if let status = viewModel.deliveryStatusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("browser.draftStatus")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(SpecialKey.allCases, id: \.self) { key in
                            Button(key.displayName) { viewModel.sendSpecialKey(key) }
                                .buttonStyle(.bordered)
                                .frame(minHeight: 44)
                        }
                    }
                }
                Button("Insert text") { viewModel.commitDraft() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("browser.insertText")
                Spacer()
            }
            .padding()
            .navigationTitle("Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingDraftEditor = false }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    // Insert stays reachable while the software keyboard is up.
                    Button("Insert text") { viewModel.commitDraft() }
                        .accessibilityIdentifier("browser.insertTextKeyboard")
                }
            }
        }
    }
}
