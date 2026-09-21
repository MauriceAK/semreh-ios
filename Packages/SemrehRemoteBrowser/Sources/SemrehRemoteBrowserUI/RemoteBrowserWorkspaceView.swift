import SwiftUI
import SemrehRemoteBrowserCore

/// Native browser workspace: SwiftUI chrome around the UIKit viewport.
///
/// Restyled design contract (presentation layer only):
/// - Dark takeover shell: black outer backdrop, charcoal (~#181818) shell
///   with a 32pt top corner radius.
/// - Centered ownership header (~80pt): subdued Close, title/hostname stack,
///   trailing progress or circular resume checkmark. Take control / Reconnect
///   appear as labeled capsules in a contextual row beneath the status.
/// - Conditional notice banner under the header; never permanent.
/// - Full-width viewport stage with the stale-frame shield; floating controls
///   overlaid at the bottom, sized to their content so viewport gestures are
///   never swallowed.
/// - Compact floating tool capsule (keyboard, interaction mode, Fit, More)
///   plus a separate capability-gated circular Stop Task control.
/// - Inline local-draft composer above the native keyboard in normal layouts;
///   the existing sheet remains as the compact-height fallback (short
///   allocations, compact vertical size class, accessibility text sizes).
/// - Required states/copy per the design table; accessibility identifiers
///   `browser.close`, `browser.takeControl`, `browser.reconnect`,
///   `browser.resume`, `browser.status`, `browser.notice`, `browser.keyboard`,
///   `browser.insertText`, `browser.mode`, `browser.fit`, `browser.viewport`,
///   `browser.staleFrameShield`, `browser.draftTitle`, `browser.draftEditor`,
///   `browser.draftStatus`.
///
/// This view is production-honest: it never claims a simulated session is a
/// real Hermes connection. BrowserLab adds its own simulated-session banner.
/// The frame pipeline, ownership, capabilities, and gesture engine are
/// untouched by this restyle.
public struct RemoteBrowserWorkspaceView: View {
    @ObservedObject public var viewModel: RemoteBrowserViewModel
    @StateObject private var viewportControl = ViewportControl()
    @State private var showingDraftEditor = false
    @State private var workspaceHeight: CGFloat = .greatestFiniteMagnitude
    @FocusState private var draftEditorFocused: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(viewModel: RemoteBrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        // The root is a plain VStack (never a root GeometryReader): the
        // workspace must keep its intrinsic minimum height so embedded hosts
        // like BrowserLab allocate enough room and the chrome never overlaps
        // sibling views. The compact-composer decision reads the allocated
        // height through a background measurement instead.
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                BrowserOwnershipHeader(viewModel: viewModel)
                BrowserNoticeBanner(viewModel: viewModel)
                BrowserStage(
                    viewModel: viewModel,
                    viewportControl: viewportControl,
                    composerOpen: showingDraftEditor && !compactLayout,
                    onToggleComposer: toggleComposer,
                    onPasteIntoDraft: pasteIntoDraft
                )
                if showingDraftEditor && !compactLayout {
                    BrowserDraftComposer(
                        viewModel: viewModel,
                        editorFocus: $draftEditorFocused,
                        onDone: dismissComposer
                    )
                }
            }
            .background(heightReader)
            .background(BrowserChrome.shell)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 32,
                    topTrailingRadius: 32,
                    style: .continuous
                )
            )
            .preferredColorScheme(.dark)
        }
        .onPreferenceChange(WorkspaceHeightKey.self) { workspaceHeight = $0 }
        .sheet(isPresented: sheetBinding) {
            draftEditorSheet
        }
    }

    // MARK: - Layout measurement

    /// Compact layouts (short allocated height such as BrowserLab's embedded
    /// panel, compact vertical size class, or accessibility Dynamic Type
    /// sizes) reuse the sheet for the draft editor instead of the inline
    /// composer.
    private var compactLayout: Bool {
        workspaceHeight < 520
            || verticalSizeClass == .compact
            || dynamicTypeSize.isAccessibilitySize
    }

    private var heightReader: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: WorkspaceHeightKey.self, value: geometry.size.height)
        }
    }

    // MARK: - Draft editor

    private func toggleComposer() {
        if showingDraftEditor {
            dismissComposer()
        } else {
            showingDraftEditor = true
            // Focus the inline editor once it appears; harmless when the
            // compact layout routes to the sheet instead.
            DispatchQueue.main.async { draftEditorFocused = true }
        }
    }

    private func dismissComposer() {
        showingDraftEditor = false
        draftEditorFocused = false
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { showingDraftEditor && compactLayout },
            set: { newValue in
                if !newValue { showingDraftEditor = false }
            }
        )
    }

    private func pasteIntoDraft() {
        #if canImport(UIKit)
        if let text = UIPasteboard.general.string, !text.isEmpty {
            viewModel.draftText = text
            showingDraftEditor = true
        }
        #endif
    }

    /// Compact-height / accessibility fallback: the existing draft editor as
    /// a dark sheet. Behavior is unchanged from the pre-restyle sheet.
    private var draftEditorSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Local text draft")
                    .font(.headline)
                    .accessibilityIdentifier("browser.draftTitle")
                Text("Native composition edits this draft. Only committed text is sent when you press Insert text — this is committed-text insertion, not a mirrored remote editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Sent only when you tap Insert text.")
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
            .browserInlineNavigationTitle()
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
        .preferredColorScheme(.dark)
    }
}

private struct WorkspaceHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    @ViewBuilder
    func browserInlineNavigationTitle() -> some View {
        #if canImport(UIKit)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
