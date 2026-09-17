import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import OSLog

#if DEBUG
private struct ChatTranscriptProxyGenerationDiagnostic {
    let targetKey: String
    let generation: Int
}
#endif

private struct ImportedPhotoVideo: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            ImportedPhotoVideo(data: try Data(contentsOf: received.file))
        }
    }
}

private enum GitChatAlert: Identifiable {
    case confirmRemote(GitRemoteAction)
    case error(String)

    var id: String {
        switch self {
        case .confirmRemote(let action): "remote:\(action.rawValue)"
        case .error(let message): "error:\(message)"
        }
    }
}

private enum ActiveGitSheet: Identifiable {
    case changes
    case stage

    var id: Self { self }
}

/// What the per-turn diff sheet shows (issue #316): every changed file in the turn, or a
/// single file's diff (a recap-card row tap).
private enum TurnDiffPresentation: Identifiable {
    case turnFiles([GitFile])
    case file(GitFile)

    var id: String {
        switch self {
        case .turnFiles(let files): return "turn:" + files.map(\.id).joined(separator: "|")
        case .file(let file): return "file:" + file.id
        }
    }
}

private struct DirectAttachmentRecoveryBanner: View {
    let isBusy: Bool
    let isActionAvailable: Bool
    let onDiscard: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Attachment delivery needs attention")
                    .font(AppFont.caption(weight: .semibold))
                Text("Saved chat history is kept. Reset the pending upload before sending or adding attachments.")
                    .font(AppFont.caption())
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Resetting pending upload")
            } else if isActionAvailable {
                Button("Discard pending upload", action: onDiscard)
                    .font(AppFont.caption(weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("discard-pending-upload")
            } else {
                Text("Reconnect this chat to check upload status.")
                    .font(AppFont.caption())
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct DirectPromptDeliveryRecoveryBanner: View {
    let isBusy: Bool
    let isActionAvailable: Bool
    let isSafetyRecordUnavailable: Bool
    let hasConfirmedAcceptance: Bool
    let onAllow: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(hasConfirmedAcceptance ? "Message accepted; cleanup needed" : "Message delivery needs attention")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("direct-prompt-uncertainty-banner")
                Text(recoveryExplanation)
                    .font(.caption)
                    .accessibilityIdentifier("direct-prompt-uncertainty-explanation")
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView()
                    .accessibilityLabel("Checking latest conversation")
            } else if isActionAvailable {
                Button("Allow a new message…", action: onAllow)
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("direct-prompt-uncertainty-allow-new-message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var recoveryExplanation: String {
        if hasConfirmedAcceptance {
            return "Hermes accepted the message, but Semreh could not clear its local safety record. It will not resend it."
        }
        if isSafetyRecordUnavailable {
            return "Semreh cannot verify this chat’s delivery safety record. Saved history remains readable, but this chat cannot safely send. Return to Chats and start a New Chat to continue."
        }
        return "Semreh cannot confirm the previous send. It may still appear, and Semreh will not resend it."
    }
}

private struct DirectAttachmentRecoveryAlertModifier: ViewModifier {
    @Binding var target: DirectAttachmentRecoveryTarget?
    let viewModel: ChatViewModel

    func body(content: Content) -> some View {
        content.alert(
            "Discard Pending Upload?",
            isPresented: Binding(
                get: { target != nil },
                set: { isPresented in
                    if !isPresented { target = nil }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                target = nil
            }
            Button("Discard pending upload", role: .destructive) {
                guard let capturedTarget = target else { return }
                target = nil
                Task {
                    _ = await viewModel.resetDirectAttachmentRecovery(capturedTarget)
                }
            }
        } message: {
            Text("This resets only the affected live chat and may interrupt an active response. Saved chat history and your draft will be kept. The old staged upload will not be sent again.")
        }
    }
}

private struct DirectPromptDeliveryRecoveryAlertModifier: ViewModifier {
    @Binding var target: DirectPromptDeliveryRecoveryTarget?
    let viewModel: ChatViewModel

    func body(content: Content) -> some View {
        content.alert(
            "Allow a New Message?",
            isPresented: Binding(
                get: { target != nil },
                set: { if !$0 { target = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { target = nil }
            Button("Allow a new message", role: .destructive) {
                guard let capturedTarget = target else { return }
                target = nil
                Task { _ = await viewModel.abandonDirectPromptDeliveryUncertainty(capturedTarget) }
            }
        } message: {
            Text(viewModel.directPromptDeliveryHasConfirmedAcceptance
                ? "Hermes accepted your previous message, but Semreh could not clear its local safety record. Semreh will not resend it. After checking the latest conversation, continue only if you want to write a different message."
                : "Semreh cannot confirm the previous send. It may still appear in this conversation, and Semreh will not resend it. After checking the latest conversation, continue only if you want to write a different message.")
        }
    }
}

/// Reports the first completed UIKit appearance transition for a SwiftUI destination.
/// `NavigationStack` does not expose push completion directly, while `viewDidAppear`
/// and the transition coordinator remain synchronized with system animation speed.
struct NavigationAppearanceCompletionObserver: UIViewControllerRepresentable {
    let action: @MainActor () -> Void

    func makeUIViewController(context: Context) -> NavigationAppearanceObserverViewController {
        NavigationAppearanceObserverViewController(action: action)
    }

    func updateUIViewController(
        _ uiViewController: NavigationAppearanceObserverViewController,
        context: Context
    ) {
        uiViewController.action = action
    }
}

@MainActor
final class NavigationAppearanceObserverViewController: UIViewController {
    var action: @MainActor () -> Void

    private var isAwaitingTransitionCompletion = false
    private var didReportAppearance = false

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        guard !didReportAppearance, let coordinator = transitionCoordinator else { return }
        isAwaitingTransitionCompletion = true
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self else { return }
            isAwaitingTransitionCompletion = false
            guard !context.isCancelled else { return }
            reportAppearanceIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isAwaitingTransitionCompletion else { return }
        reportAppearanceIfNeeded()
    }

    private func reportAppearanceIfNeeded() {
        guard !didReportAppearance else { return }
        didReportAppearance = true
        action()
    }
}

private struct ListenPlaybackBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    let phase: ListenPlaybackPhase
    let displayTime: TimeInterval
    let duration: TimeInterval
    let speed: ListenPlaybackSpeed
    let onTogglePlayPause: () -> Void
    let onStop: () -> Void
    let onScrub: (TimeInterval) -> Void
    let onScrubbingChanged: (Bool) -> Void
    let onSpeedChange: (ListenPlaybackSpeed) -> Void

    private var isReady: Bool {
        phase == .playing || phase == .paused
    }

    private var isPlaying: Bool {
        phase == .playing
    }

    private var boundedDisplayTime: TimeInterval {
        min(max(0, displayTime), max(duration, 0))
    }

    private var sliderUpperBound: TimeInterval {
        max(duration, 0.01)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                playPauseButton

                VStack(alignment: .leading, spacing: 4) {
                    scrubber
                    timeRow
                }
                .frame(maxWidth: .infinity)

                speedMenu
                stopButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()
        }
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var playPauseButton: some View {
        if phase == .loading {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.accentColor)
            }
            .frame(width: 34, height: 34)
            .accessibilityLabel(String(localized: "Preparing audio"))
        } else {
            Button(action: onTogglePlayPause) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(SemrehVisualTheme.accentForeground(for: colorScheme, palette: palette))
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.chatTactile(.icon))
            .disabled(!isReady)
            .accessibilityLabel(isPlaying ? String(localized: "Pause audio") : String(localized: "Play audio"))
        }
    }

    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { boundedDisplayTime },
                set: { onScrub($0) }
            ),
            in: 0...sliderUpperBound,
            onEditingChanged: onScrubbingChanged
        )
        .tint(Color.accentColor)
        .disabled(!isReady || duration <= 0)
        .accessibilityLabel(String(localized: "Playback position"))
    }

    private var timeRow: some View {
        HStack(spacing: 8) {
            Text(AudioDurationFormatter.string(from: boundedDisplayTime))
            Text("/")
            Text(AudioDurationFormatter.string(from: duration))
            Spacer(minLength: 0)
        }
        .font(AppFont.caption2().monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(AudioDurationFormatter.string(from: boundedDisplayTime)) of \(AudioDurationFormatter.string(from: duration))"))
    }

    private var speedMenu: some View {
        Menu {
            ForEach(ListenPlaybackSpeed.allCases) { option in
                Button {
                    onSpeedChange(option)
                } label: {
                    HStack {
                        Text(option.title)
                        if option == speed {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(speed.title)
                .font(AppFont.caption().weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 36, minHeight: 30)
                .padding(.horizontal, 6)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .disabled(!isReady)
        .accessibilityLabel(String(localized: "Playback speed"))
        .accessibilityValue(speed.title)
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.chatTactile(.icon))
        .accessibilityLabel(String(localized: "Stop audio"))
    }
}

struct ChatView: View {
    private let bottomAnchorID = "chat-bottom-anchor"
    /// Keep ordinary transcript messages separated while compacting adjacent
    /// Thinking/tool/action status blocks to the same restrained rhythm.
    private let transcriptMessageSpacing: CGFloat = 10
    private let transcriptBlockSpacing: CGFloat = 4
    private let composerAccessoryVerticalSpacing: CGFloat = 8
    private let activeRunStatusSpacerHeight: CGFloat = 36
    /// Keep a short, nearby return-to-latest motion readable without animating
    /// a tour through a long transcript. This is intentionally a band, not a
    /// continuously-updated distance, so scroll metrics do not invalidate the
    /// whole chat on every point of a drag.
    private let nearbyBottomMotionDistance: CGFloat = 640
#if DEBUG
    private static let transcriptScrollLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "TranscriptActivationRecovery"
    )
#endif

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(StreamingSendBehavior.storageKey) private var streamingSendBehaviorRawValue = StreamingSendBehavior.steer.rawValue
    @AppStorage(ResponseCompletionNotifications.isEnabledKey) private var isResponseCompletionNotificationsEnabled = false
    @AppStorage(AgentRunLiveActivityPrivacy.showsResponseExcerptsKey) private var showsLiveActivityResponseExcerpts = false
    @AppStorage(ChatTranscriptDisplaySettings.showsThinkingAndToolCardsKey) private var showsThinkingAndToolCards = true
    @AppStorage(ChatTranscriptDisplaySettings.rtlChatLayoutEnabledKey) private var rtlChatLayoutEnabled = ChatTranscriptDisplaySettings.rtlChatLayoutDefaultEnabled
    @AppStorage(SectionVisibilitySettings.chatFilesKey) private var showsFilesButton = true
    @AppStorage(SectionVisibilitySettings.chatGitKey) private var showsGitControls = true

    let session: SessionSummary
    let server: URL
    let onAPIError: (Error) -> Void
    let onParentBack: (() -> Void)?
    let loadsInitialMessages: Bool
    let disablesExternalLifecycle: Bool
    /// When true, the composer auto-starts voice dictation on appear — set by the
    /// "New Chat with Voice" App Intent (#338). Defaults to false for normal opens.
    let autoStartsVoiceInput: Bool

    @State private var draftMessage = ""
    @State private var followRejoinScrollToken = 0
    @State private var restoreScrollToken = 0
    @State private var transcriptRestoreCancellationToken = 0
    @State private var didRequestTranscriptRestore = false
    @State private var didInteractBeforeTranscriptRestore = false
    @State private var isTranscriptRestorePending = false
    @State private var pendingTranscriptRestoreMessageID: String?
    @State private var transcriptRestoreOutcomeState = ChatTranscriptRestoreOutcomeState()
    @State private var isScrolledNearBottom = true
    @State private var isReadingOlderTranscript = false
    @State private var shouldFollowLatestMessage = true
    @State private var visibleTranscriptRowID: String?
    @State private var followScrollGeneration = 0
    @State private var explicitBottomScrollGeneration = 0
    @State private var isExplicitBottomScrollActive = false
    @State private var hasIssuedExplicitBottomScroll = false
#if DEBUG
    @State private var explicitBottomScrollAttemptCount = 0
    @State private var hasLoggedComposerCollapseForResize = false
    @State private var pendingTranscriptProxyGenerationDiagnostic: ChatTranscriptProxyGenerationDiagnostic?
#endif
    @State private var isLatestTranscriptRowVisible = false
    @State private var isTranscriptBottomVisible = false
    @State private var explicitBottomScrollTask: Task<Void, Never>?
    @State private var isExplicitBottomDecelerationActive = false
    @State private var isUserInteractingWithScroll = false
    @State private var isNearBottomForMotion = false
    @State private var userScrollCooldownUntil: Date?
    /// While set and in the future, auto-follow scrolls snap instead of animating, so
    /// the cache-first → network reconcile re-pins to the bottom without a jump (#289).
    @State private var cacheFirstSnapUntil: Date?
    @State private var forkedSession: SessionSummary?
    /// A direct branch already owns a bound child controller. Keep the handoff
    /// alive through navigation so the destination can use the retained VM
    /// instead of resuming the child a second time.
    @State private var directBranchHandoff: DirectBranchHandoff?
    @State private var isShowingDirectBranch = false
    @State private var editContext: MessageActionContext?
    @State private var editDraft = ""
    @State private var showEditSheet = false
    @State private var showEditDiscardConfirmation = false
    @State private var regenerateContext: MessageActionContext?
    @State private var showRegenerateDiscardConfirmation = false
    @State private var selectableResponseText: SelectableTextPresentation?
    @State private var attachmentPreviewItem: ChatAttachmentPreviewItem?
    @State private var transcriptMediaPreviewItem: TranscriptMediaPreviewItem?
    @State private var pendingProfileSelection: ProfileSummary?
    @State private var showProfileNewSessionConfirmation = false
    @State private var attachmentRecoveryConfirmationTarget: DirectAttachmentRecoveryTarget?
    @State private var promptDeliveryRecoveryConfirmationTarget: DirectPromptDeliveryRecoveryTarget?
    @State private var goalDraft = ""
    @State private var showsGoalSheet = false
    @State private var activeGitSheet: ActiveGitSheet?
    @State private var turnDiffPresentation: TurnDiffPresentation?
    @State private var viewModel: ChatViewModel
    @State private var gitAvailabilityViewModel: GitWorkspaceAvailabilityViewModel
    @State private var gitToastState = GitActionToastState()
    @State private var gitAlert: GitChatAlert?
    @State private var composerHeight: CGFloat = 52
    @State private var showsChatControls = false
    @State private var showsBotDetails = false
    @State private var showsChatFiles = false
    @State private var workspacePickerRequest = 0
    @State private var gitBranchPickerRequest = 0
    @State private var isComposerResizing = false
    @State private var composerResizeFollowIntent = false
    @State private var composerResizeGeneration = 0
    @State private var composerResizeTask: Task<Void, Never>?
    @State private var shouldAnimateNextFollowAfterComposerResize = false
    @State private var composerIsFocused = false
    @State private var didCompleteInitialAppearance = false
    @State private var isInitialComposerFocusContentReady = false
    @State private var didApplyInitialComposerFocusPolicy = false
    @State private var shouldRestoreComposerFocusAfterPreview = false
    @State private var responseCompletionNotificationTracker = ResponseCompletionNotificationTracker()
    @State private var responseCompletionBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    @State private var foregroundRefreshTask: Task<Void, Never>?
    @State private var initialAttachments: [SharedAttachmentImport]
    @State private var didUploadInitialAttachments = false

    init(
        session: SessionSummary,
        server: URL,
        onAPIError: @escaping (Error) -> Void,
        onParentBack: (() -> Void)? = nil,
        initialDraft: String = "",
        initialAttachments: [SharedAttachmentImport] = [],
        loadsInitialMessages: Bool = true,
        autoStartsVoiceInput: Bool = false,
        retainedViewModel: ChatViewModel? = nil,
        disablesExternalLifecycle: Bool = false
    ) {
        self.session = session
        self.server = server
        self.onAPIError = onAPIError
        self.onParentBack = onParentBack
        self.loadsInitialMessages = loadsInitialMessages
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.disablesExternalLifecycle = disablesExternalLifecycle
        _draftMessage = State(initialValue: ComposerDraftStore.resolvedDraft(
            initialDraft: initialDraft,
            storedDraft: ComposerDraftStore.shared.load(
                server: server,
                sessionID: session.sessionId ?? session.id
            )
        ))
        _initialAttachments = State(initialValue: initialAttachments)
        let openSessionStore = OpenChatSessionStore.shared
        let resolvedRetainedViewModel = retainedViewModel ?? openSessionStore.viewModel(
            session: session,
            server: server,
            showsLiveActivityResponseExcerpts: UserDefaults.standard.bool(
                forKey: AgentRunLiveActivityPrivacy.showsResponseExcerptsKey
            )
        )
        _viewModel = State(initialValue: resolvedRetainedViewModel)
        _shouldFollowLatestMessage = State(initialValue: resolvedRetainedViewModel.savedFollowingLatest)
        let initialRestoreTarget = resolvedRetainedViewModel.transcriptRestoreTarget
        _visibleTranscriptRowID = State(initialValue: Self.savedTranscriptVisibleMessageID(from: initialRestoreTarget))
        _pendingTranscriptRestoreMessageID = State(initialValue: Self.savedTranscriptVisibleMessageID(from: initialRestoreTarget))
        _isTranscriptRestorePending = State(initialValue: Self.savedTranscriptVisibleMessageID(from: initialRestoreTarget) != nil)
        _gitAvailabilityViewModel = State(initialValue: openSessionStore.gitAvailabilityViewModel(
            session: session,
            server: server,
            chatViewModel: resolvedRetainedViewModel
        ))
    }

    // Extracted from `body` so the type-checker doesn't have to solve the whole composer
    // call alongside the rest of the screen in one expression (#316 pushed it over the
    // "unable to type-check in reasonable time" limit).
    private var messageComposer: some View {
        MessageComposerView(
            draftMessage: $draftMessage,
            isFocused: $composerIsFocused,
            isSending: viewModel.isStartingChat || viewModel.isSendingVoiceNote,
            isCompressingSession: viewModel.isCompressingSession,
            isWaitingForStream: viewModel.activeStreamID != nil,
            isCancellingStream: viewModel.isCancellingStream,
            isOfflineReadOnly: viewModel.isViewingCachedData,
            isChromeCompact: isComposerChromeCompact,
            errorMessage: viewModel.sendErrorMessage,
            configurationErrorMessage: viewModel.composerConfigurationErrorMessage,
            contextWindowSnapshot: viewModel.contextWindowSnapshot,
            gitViewModel: gitAvailabilityViewModel,
            modelGroups: viewModel.modelCatalogGroups,
            selectedModelID: viewModel.selectedModelID,
            selectedModelProviderID: viewModel.selectedModelProviderID,
            selectedModelTitle: viewModel.selectedModelTitle,
            workspaceRoots: viewModel.workspaceRoots,
            selectedWorkspacePath: viewModel.selectedWorkspacePath,
            workspaceSuggestions: viewModel.workspaceSuggestions,
            workspaceManagementServer: server,
            workspaceManagementProfile: viewModel.workspaceOrganizerProfile,
            skillSuggestions: viewModel.skillSlashSuggestions,
            agentCommands: viewModel.agentCommands,
            profileOptions: viewModel.profileOptions,
            isSingleProfileMode: viewModel.isSingleProfileMode,
            selectedProfileName: viewModel.selectedProfileName,
            selectedProfileTitle: viewModel.selectedProfileTitle,
            isLoadingModels: viewModel.isLoadingComposerConfiguration,
            selectedReasoningEffort: viewModel.selectedReasoningSelection,
            supportedReasoningEfforts: viewModel.supportedReasoningEfforts,
            allowsReasoningInheritance: viewModel.allowsReasoningInheritance,
            allowsReasoningChangesWhileStreaming: viewModel.allowsReasoningChangesWhileStreaming,
            isReasoningChangeDeferred: viewModel.isReasoningChangeDeferred,
            showsReasoningControl: viewModel.showsReasoningEffortControl,
            isUpdatingConfiguration: viewModel.isUpdatingComposerConfiguration,
            pendingAttachments: viewModel.pendingAttachments,
            displayAttachments: viewModel.usesDirectGateway
                ? viewModel.directPendingAttachmentDisplayItems
                : [],
            isUploadingAttachment: viewModel.isUploadingAttachment,
            attachmentUploadCount: viewModel.attachmentUploadCount,
            attachmentUploadGeneration: viewModel.attachmentUploadGeneration,
            isSendingVoiceNote: viewModel.isSendingVoiceNote,
            autoStartsVoiceInput: autoStartsVoiceInput,
            apiClient: viewModel.client,
            voiceInputProfileName: viewModel.voiceInputProfileName,
            currentVoiceInputProfile: { viewModel.voiceInputProfileName },
            uploadAttachmentErrorMessage: viewModel.uploadAttachmentErrorMessage,
            onSend: {
#if DEBUG
                ChatPerformanceCadenceMonitor.begin(.send)
                logChatScrollBoundary(event: "send_begin", decision: "composer_submit")
#endif
                Task { await sendDraftMessage() }
            },
            onSendVoiceNote: { data, filename in
#if DEBUG
                ChatPerformanceCadenceMonitor.begin(.send)
                logChatScrollBoundary(event: "send_begin", decision: "voice_note_submit")
#endif
                Task { await sendVoiceNote(audioData: data, filename: filename) }
            },
            onCancel: {
                Task { await cancelStream() }
            },
            onSelectModel: { option in
                Task {
                    let didSelect = await viewModel.selectComposerModel(option)
                    if didSelect {
                        ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                    }
                }
            },
            onModelPickerOpen: {
                await viewModel.refreshModelCatalogForPickerOpen()
            },
            onLoadWorkspaceSuggestions: { prefix in
                await viewModel.loadWorkspaceSuggestions(prefix: prefix)
            },
            onWorkspaceRegistryChanged: {
                await viewModel.refreshWorkspaceRoots()
            },
            onLoadSkillSuggestions: {
                await viewModel.loadSkillSlashSuggestions()
            },
            onSelectWorkspace: { path in
                let didSelect = await viewModel.selectWorkspacePath(path)
                if didSelect {
                    ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                }
            },
            onSelectProfile: { profile in
                handleProfileSelection(profile)
            },
            onSelectReasoningEffort: { effort in
                Task {
                    let didSelect = await viewModel.selectReasoningEffort(effort)
                    if didSelect {
                        ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
                    }
                }
            },
            onHeightChange: { height in
                handleComposerHeightChange(height)
            },
            onPhotoItemSelected: { item in
                Task { await handlePhotoSelection(item) }
            },
            onFileURLsSelected: { urls in
                Task { await handleSelectedFileURLs(urls) }
            },
            onPasteFileProviders: { providers in
                Task { await handlePastedFileProviders(providers) }
            },
            onPasteFileURLs: { urls in
                Task { await handlePastedFileURLs(urls) }
            },
            onPasteImageProviders: { providers in
                Task { await handlePastedImageProviders(providers) }
            },
            onPasteImages: { images in
                Task { await handlePastedImages(images) }
            },
            onRemoveAttachment: { id in
                viewModel.removePendingAttachment(id: id)
            },
            onPreviewAttachment: { attachment in
                presentPreviewRestoringComposerFocusIfNeeded {
                    attachmentPreviewItem = ChatAttachmentPreviewItem(pending: attachment)
                }
            },
            onPreviewDisplayAttachment: { item in
                if viewModel.usesDirectGateway {
                    presentPreviewRestoringComposerFocusIfNeeded {
                        attachmentPreviewItem = ChatAttachmentPreviewItem(display: item)
                    }
                } else if let attachment = item.legacyPendingAttachment() {
                    // Keep the legacy path available if a display projection is
                    // ever supplied by a non-direct caller.
                    presentPreviewRestoringComposerFocusIfNeeded {
                        attachmentPreviewItem = ChatAttachmentPreviewItem(pending: attachment)
                    }
                }
            },
            onDismissUploadAttachmentError: {
                viewModel.setUploadAttachmentError(nil)
            },
            onSelectGitBranch: { target in
                Task { await performGitCheckout(target) }
            },
            onCreateGitBranch: { target in
                Task { await performGitCheckout(target) }
            },
            onRefreshGitBranches: {
                Task { await gitAvailabilityViewModel.loadBranches() }
            },
            controlsPresentation: $showsChatControls,
            workspacePickerRequest: workspacePickerRequest,
            gitBranchPickerRequest: gitBranchPickerRequest
        )
        // The composer flips wholesale with the transcript under the RTL
        // toggle (#259): input, placeholder, and chrome mirror together.
        .environment(\.layoutDirection, chatLayoutDirection)
        .task(id: draftMessage) {
            // Debounce persistence. UserDefaults is synchronous and doing a
            // write for every keystroke makes the main-actor composer hitch.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            persistComposerDraft()
        }
        .background(
            NavigationAppearanceCompletionObserver(action: handleInitialAppearanceCompletion)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }

    private func transcriptMediaPreviewView(for item: TranscriptMediaPreviewItem) -> some View {
        TranscriptMediaPreviewView(
            server: server,
            sessionID: transcriptMediaSessionID,
            item: item,
            onAPIError: onAPIError
        )
    }

    private var transcriptMediaSessionID: String? {
        guard let sessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else {
            return nil
        }
        return sessionID
    }

    private var transcriptMediaCacheNamespace: String {
        "\(server.absoluteString)|\(transcriptMediaSessionID ?? "local:\(session.id)")"
    }

    private var chatBotHeader: some View {
        Button {
            showsBotDetails = true
        } label: {
            VStack(spacing: -3) {
                if let identity = BirdAvatarIdentity(server: server, profile: viewModel.selectedProfileName ?? session.profile) {
                    BirdAvatarView(identity: identity)
                        .frame(width: 52, height: 52)
                        .offset(y: 2)
                }

                Text(viewModel.selectedProfileTitle)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .thinMaterial, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View details for \(viewModel.selectedProfileTitle)")
        .accessibilityValue(headerSubtitle ?? viewModel.selectedProfileTitle)
        .accessibilityHint("Shows read-only bot details.")
    }

    private var chatNavigationBar: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                chatBotHeader
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 96, alignment: .center)

            HStack(alignment: .top, spacing: 8) {
                Button {
                    handleBackNavigation()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .thinMaterial, in: Circle())
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .accessibilityLabel("Back")
                Spacer()
                Button { showsChatControls = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .thinMaterial, in: Circle())
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .accessibilityLabel("Chat controls")
                chatOverflowMenu
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, 4)
            .padding(.horizontal, 12)
        }
        .frame(minHeight: 96)
        .background {
            ChatHeaderReadabilityBackdrop()
                .padding(.bottom, -24)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The Sessions shell owns the selected destination, while this view owns
    /// the actual navigation destination presented by SwiftUI. Clear both
    /// pieces of state on an explicit Back request: the parent callback keeps
    /// a late restore from reopening this chat, and `dismiss()` performs the
    /// immediate pop from the destination's navigation context. The latter is
    /// required for the custom header button because it is outside the system
    /// navigation bar and therefore has no implicit pop action of its own.
    private func handleBackNavigation() {
#if DEBUG
        ChatPerformanceCadenceMonitor.begin(.back)
#endif
        onParentBack?()
        dismiss()
    }

    private var chatOverflowMenu: some View {
        Menu {
            if showsFilesButton {
                Button("Files", systemImage: "folder") { showsChatFiles = true }
                    .disabled(viewModel.isViewingCachedData)
            }
            Button("Choose workspace path", systemImage: "folder.badge.gearshape") {
                workspacePickerRequest += 1
            }
            .disabled(viewModel.isViewingCachedData || viewModel.isStartingChat
                || viewModel.isSendingVoiceNote || viewModel.isCompressingSession
                || viewModel.activeStreamID != nil || viewModel.isUpdatingComposerConfiguration)
            if viewModel.hasActivatedGoalCommand { goalControlMenu }
            if showsGitControls, gitAvailabilityViewModel.hasRepository {
                gitActionsMenu
                Button("Git branch", systemImage: "arrow.triangle.branch") {
                    gitBranchPickerRequest += 1
                }
                .disabled(viewModel.isViewingCachedData || viewModel.activeStreamID != nil
                    || gitAvailabilityViewModel.isLoadingBranches || gitAvailabilityViewModel.isSwitchingBranch)
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .thinMaterial, in: Circle())
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .accessibilityLabel("Chat options")
    }

    private var chatBaseView: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if viewModel.isViewingCachedData {
                    ChatOfflineCacheBanner()
                }

                listenPlaybackBar

                messageContent
                    // Scope RTL to the chat transcript only (#259): the offline
                    // banner above stays in the app's default direction.
                    .environment(\.layoutDirection, chatLayoutDirection)

            }
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: viewModel.showsListenPlaybackBar)

            composerAccessoryStack

            if viewModel.attachmentRecoveryNeedsReset || viewModel.directConversationHasPromptDeliveryUncertainty {
                VStack(spacing: 8) {
                    if viewModel.attachmentRecoveryNeedsReset {
                        DirectAttachmentRecoveryBanner(
                            isBusy: viewModel.attachmentRecoveryIsBusy,
                            isActionAvailable: viewModel.directAttachmentRecoveryTarget != nil,
                            onDiscard: {
                                attachmentRecoveryConfirmationTarget = viewModel.directAttachmentRecoveryTarget
                            }
                        )
                    }
                    if viewModel.directConversationHasPromptDeliveryUncertainty {
                        DirectPromptDeliveryRecoveryBanner(
                            isBusy: viewModel.promptDeliveryRecoveryIsBusy,
                            isActionAvailable: viewModel.directPromptDeliveryRecoveryTarget != nil,
                            isSafetyRecordUnavailable: viewModel.directPromptDeliverySafetyRecordUnavailable,
                            hasConfirmedAcceptance: viewModel.directPromptDeliveryHasConfirmedAcceptance,
                            onAllow: {
                                promptDeliveryRecoveryConfirmationTarget = viewModel.directPromptDeliveryRecoveryTarget
                            }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, composerHeight + 8)
                .zIndex(12)
            }

            messageComposer

            if let directApprovalPrompt = viewModel.pendingApprovalPrompt {
                ApprovalRequestOverlay(
                    prompt: directApprovalPrompt,
                    isResponding: viewModel.blockingInteractionResponseInFlight,
                    errorMessage: viewModel.blockingInteractionErrorMessage(for: directApprovalPrompt.identity),
                    onChoice: { choice in
                        let renderedIdentity = directApprovalPrompt.identity
                        Task {
                            do {
                                let response = try await viewModel.respondToApproval(
                                    choice,
                                    expectedIdentity: renderedIdentity
                                )
                                if response == .accepted,
                                   let legacyChoice = ApprovalChoice(rawValue: choice.rawValue) {
                                    ChatHaptics.approvalSubmitted(legacyChoice, isEnabled: isHapticsEnabled)
                                }
                            } catch {
                                // The VM keeps an identity-scoped error visible
                                // when the request is still the rendered one.
                            }
                        }
                    }
                )
                .zIndex(10)
            }

            if let secretPrompt = viewModel.pendingSecretPrompt {
                DirectGatewaySensitivePromptOverlay(
                    prompt: secretPrompt,
                    isResponding: viewModel.blockingInteractionResponseInFlight,
                    errorMessage: viewModel.blockingInteractionErrorMessage(for: secretPrompt.identity),
                    onCancel: {
                        let renderedIdentity = secretPrompt.identity
                        Task {
                            _ = try? await viewModel.cancelSecret(expectedIdentity: renderedIdentity)
                        }
                    }
                )
                .zIndex(31)
            } else if let sudoPrompt = viewModel.pendingSudoPrompt {
                DirectGatewaySensitivePromptOverlay(
                    prompt: sudoPrompt,
                    isResponding: viewModel.blockingInteractionResponseInFlight,
                    errorMessage: viewModel.blockingInteractionErrorMessage(for: sudoPrompt.identity),
                    onCancel: {
                        let renderedIdentity = sudoPrompt.identity
                        Task {
                            _ = try? await viewModel.cancelSudo(expectedIdentity: renderedIdentity)
                        }
                    }
                )
                .zIndex(31)
            }

        }
        .safeAreaInset(edge: .top, spacing: 0) { chatNavigationBar }
        .background {
            SemrehBackdrop().ignoresSafeArea()
                .onChange(of: draftMessage) {
                    viewModel.setDirectComposerEditing(!draftMessage.isEmpty)
                }
                .onChange(of: viewModel.clarificationPrompt?.gatewayIdentity) { oldIdentity, newIdentity in
                    guard viewModel.usesDirectGateway,
                          let newIdentity,
                          oldIdentity != newIdentity,
                          composerIsFocused else { return }
                    // The ordinary composer owns this binding. Do not send a global
                    // resignFirstResponder action: the clarification card's answer
                    // field may already be focused and must not be hijacked.
                    composerIsFocused = false
                }
                .onChange(of: viewModel.pendingApprovalPrompt?.identity) { oldIdentity, newIdentity in
                    guard viewModel.usesDirectGateway,
                          let newIdentity,
                          oldIdentity != newIdentity,
                          composerIsFocused else { return }
                    composerIsFocused = false
                }
                .onChange(of: viewModel.pendingSecretPrompt?.identity) { oldIdentity, newIdentity in
                    guard viewModel.usesDirectGateway,
                          let newIdentity,
                          oldIdentity != newIdentity,
                          composerIsFocused else { return }
                    composerIsFocused = false
                }
                .onChange(of: viewModel.pendingSudoPrompt?.identity) { oldIdentity, newIdentity in
                    guard viewModel.usesDirectGateway,
                          let newIdentity,
                          oldIdentity != newIdentity,
                          composerIsFocused else { return }
                    composerIsFocused = false
                }
        }
        .overlay(alignment: .top) {
            GitActionToastOverlay(state: gitToastState)
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showsChatFiles) {
            FileBrowserView(session: session, server: server, onAPIError: onAPIError)
                .toolbar(.visible, for: .navigationBar)
        }
        .sheet(isPresented: $showsBotDetails) {
            NavigationStack {
                ChatBotDetailsView(
                    profile: activeProfileDetails,
                    profileTitle: viewModel.selectedProfileTitle
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-detail:\(viewModel.displayTitle)")
        .task(id: didCompleteInitialAppearance) {
            await handleInitialAppearanceTask()
        }
        .onChange(of: scenePhase) {
                handleScenePhaseChange(scenePhase)
            }
            .onChange(of: viewModel.activeStreamID) {
                handleActiveStreamChange()
            }
            .onChange(of: viewModel.cacheFirstReconcileScrollToken) {
                // Open a brief snap window so the cache-first reconcile re-pin (and any
                // message-count auto-follow racing it) lands without an animated jump (#289).
                cacheFirstSnapUntil = Date().addingTimeInterval(0.35)
            }
            .onChange(of: viewModel.isUploadingAttachment) { _, isUploading in
                if !isUploading {
                    applyInitialComposerFocusPolicyIfNeeded()
                }
            }
            .onChange(of: viewModel.uploadAttachmentErrorMessage) { _, newValue in
                if newValue == nil {
                    applyInitialComposerFocusPolicyIfNeeded()
                }
            }
            .onChange(of: showsLiveActivityResponseExcerpts) {
                viewModel.setShowsLiveActivityResponseExcerpts(showsLiveActivityResponseExcerpts)
            }
            .onDisappear {
                cancelExplicitBottomScroll()
                viewModel.setTranscriptPresentationActive(false)
                composerResizeTask?.cancel()
                composerResizeTask = nil
                persistComposerDraft()
                persistTranscriptRestore()
                foregroundRefreshTask?.cancel()
                foregroundRefreshTask = nil
                guard !disablesExternalLifecycle else { return }
                // Stop the per-session event stream when the chat is not on
                // screen. Background sync for every retained conversation caused
                // main-thread disk I/O and transcript reloads (build 19 lag).
                viewModel.stopSessionEventSync()
                viewModel.stopListening()
            }
            .onAppear {
#if DEBUG
                ChatPerformanceCadenceMonitor.end(.entry)
#endif
                viewModel.setTranscriptPresentationActive(true)
                guard !disablesExternalLifecycle else { return }
                foregroundRefreshTask?.cancel()
                foregroundRefreshTask = Task { @MainActor in
                    guard !Task.isCancelled, scenePhase == .active else { return }
                    await viewModel.reconnectStreamIfNeeded(modelContext: modelContext)
                    guard !Task.isCancelled, scenePhase == .active else { return }

                    if viewModel.activeStreamID != nil {
                        handleActiveStreamChange()
                    }

                    if let lastError = viewModel.lastError {
                        onAPIError(lastError)
                    }
                }

                // Event sync runs only while the chat is visible; leaving the
                // conversation stops it (see onDisappear).
                viewModel.startSessionEventSync()
            }
            .onChange(of: viewModel.responseCompletionHapticTrigger) {
                guard viewModel.responseCompletionHapticTrigger > 0 else { return }
                handleResponseCompletionSideEffects()
            }
            .navigationDestination(item: $forkedSession) { session in
                ChatView(session: session, server: server, onAPIError: onAPIError)
            }
            .navigationDestination(isPresented: $isShowingDirectBranch) {
                if let directBranchHandoff {
                    ChatView(
                        session: directBranchHandoff.session,
                        server: directBranchHandoff.origin,
                        onAPIError: onAPIError,
                        retainedViewModel: directBranchHandoff.viewModel
                    )
                }
            }
            .onChange(of: isShowingDirectBranch) { _, isPresented in
                guard !isPresented else { return }
                // The store owns the adopted child after transfer. Drop the
                // navigation state's extra strong reference so bounded eviction
                // remains effective after the child is popped.
                directBranchHandoff = nil
            }
            .fullScreenCover(item: $selectableResponseText) { selectableText in
                SelectableTextPresentationView(selection: selectableText)
            }
            .sheet(item: $attachmentPreviewItem) { item in
                ChatAttachmentPreviewView(
                    server: server,
                    item: item,
                    onAPIError: onAPIError
                )
            }
            .onChange(of: attachmentPreviewItem == nil) { _, isDismissed in
                if isDismissed {
                    restoreComposerFocusAfterPreviewIfNeeded()
                }
            }
            .sheet(item: $transcriptMediaPreviewItem, content: transcriptMediaPreviewView)
            .sheet(item: $activeGitSheet) { sheet in
                gitSheet(sheet).id(gitAvailabilityViewModel.requestSession)
            }
            .sheet(item: $turnDiffPresentation) { presentation in
                turnDiffSheet(presentation).id(gitAvailabilityViewModel.requestSession)
            }
            .alert(item: $gitAlert, content: gitAlertPresentation)
            .sheet(isPresented: $showsGoalSheet) {
                GoalSubmissionSheet(
                    goalDraft: $goalDraft,
                    isSubmitting: viewModel.isSubmittingGoal,
                    onSubmit: { submittedGoal in
                        Task { await submitGoalDraft(submittedGoal) }
                    }
                )
            }
            .sheet(isPresented: $showEditSheet) {
                EditMessageSheet(
                    originalText: editContext?.copyText ?? "",
                    editDraft: $editDraft,
                    onSubmit: {
                        if let context = editContext {
                            Task { await submitEdit(context) }
                        }
                    }
                )
            }
        }

    var body: some View {
        chatBaseView
            .alert(
                "Discard Later Messages?",
                isPresented: $showEditDiscardConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    editContext = nil
                    editDraft = ""
                }
                Button("Discard & Edit", role: .destructive) {
                    ChatHaptics.destructiveConfirmationAccepted(isEnabled: isHapticsEnabled)
                    showEditSheet = true
                }
            } message: {
                Text(editDiscardWarningMessage)
            }
            .alert(
                "Discard Later Messages?",
                isPresented: $showRegenerateDiscardConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    regenerateContext = nil
                }
                Button("Discard & Regenerate", role: .destructive) {
                    if let context = regenerateContext {
                        ChatHaptics.destructiveConfirmationAccepted(isEnabled: isHapticsEnabled)
                        Task { await submitRegenerate(context) }
                    }
                }
            } message: {
                Text(regenerateDiscardWarningMessage)
            }
            .alert(
                "Start New Session?",
                isPresented: $showProfileNewSessionConfirmation
            ) {
                Button("Cancel", role: .cancel) {
                    pendingProfileSelection = nil
                }
                Button("Start New Session") {
                    if let profile = pendingProfileSelection {
                        Task { await switchProfile(profile, startNewSession: true) }
                    }
                }
            } message: {
                Text(profileSwitchWarningMessage)
            }
            .alert(
                "Message Action Failed",
                isPresented: Binding(
                    get: { viewModel.messageActionErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.clearMessageActionError()
                        }
                    }
                )
            ) {
                Button("OK") {
                    viewModel.clearMessageActionError()
                }
            } message: {
                Text(viewModel.messageActionErrorMessage ?? "")
            }
            .modifier(DirectAttachmentRecoveryAlertModifier(
                target: $attachmentRecoveryConfirmationTarget,
                viewModel: viewModel
            ))
            .modifier(DirectPromptDeliveryRecoveryAlertModifier(
                target: $promptDeliveryRecoveryConfirmationTarget,
                viewModel: viewModel
            ))
    }

    @ViewBuilder
    private var listenPlaybackBar: some View {
        if viewModel.showsListenPlaybackBar {
            ListenPlaybackBar(
                phase: viewModel.listenPlaybackPhase,
                displayTime: viewModel.listenPlaybackDisplayTime,
                duration: viewModel.listenPlaybackDuration,
                speed: viewModel.listenPlaybackSpeed,
                onTogglePlayPause: {
                    viewModel.toggleListenPlaybackPlayPause()
                },
                onStop: {
                    viewModel.stopListening()
                },
                onScrub: { time in
                    viewModel.scrubListenPlayback(to: time)
                },
                onScrubbingChanged: { isScrubbing in
                    viewModel.setListenPlaybackScrubbing(isScrubbing)
                },
                onSpeedChange: { speed in
                    viewModel.setListenPlaybackSpeed(speed)
                }
            )
            .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
        }
    }

    private var gitWriteAvailability: GitWriteAvailability {
        GitWriteAvailability(
            isStreaming: viewModel.activeStreamID != nil,
            isViewingCachedData: viewModel.isViewingCachedData
        )
    }

    @ViewBuilder
    private func gitSheet(_ sheet: ActiveGitSheet) -> some View {
        switch sheet {
        case .changes:
            GitWorkspaceView(session: gitAvailabilityViewModel.requestSession, server: server, onAPIError: onAPIError)
        case .stage:
            GitCommitView(
                session: gitAvailabilityViewModel.requestSession,
                server: server,
                writesDisabled: gitWriteAvailability.writesDisabled,
                onAPIError: onAPIError
            )
        }
    }

    @ViewBuilder
    private func turnDiffSheet(_ presentation: TurnDiffPresentation) -> some View {
        switch presentation {
        case .turnFiles(let files):
            GitTurnDiffSheet(session: gitAvailabilityViewModel.requestSession, server: server, files: files, onAPIError: onAPIError)
        case .file(let file):
            GitDiffView(session: gitAvailabilityViewModel.requestSession, server: server, file: file, onAPIError: onAPIError)
        }
    }

    private var gitActionsMenu: some View {
        GitActionsMenuButton(
            presentation: GitToolbarPresentation(
                hasRepository: gitAvailabilityViewModel.hasRepository,
                isLoading: gitAvailabilityViewModel.isLoading || gitAvailabilityViewModel.isStatusLoading,
                info: gitAvailabilityViewModel.gitInfo,
                status: gitAvailabilityViewModel.status,
                statusFailed: gitAvailabilityViewModel.statusError != nil
            ),
            isEnabled: !viewModel.isViewingCachedData,
            writesDisabled: gitWriteAvailability.writesDisabled,
            isRunningAction: gitAvailabilityViewModel.isRunningGitAction,
            onTap: {
                HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
            },
            onChanges: {
                activeGitSheet = .changes
            },
            onStageEdit: {
                activeGitSheet = .stage
            },
            onPush: {
                gitAlert = .confirmRemote(.push)
            }
        )
    }

    /// Turn-end "File changes" recap card for the latest assistant turn (#316). Only for git
    /// workspaces once the response finishes (status has refreshed) and the latest turn
    /// actually changed files.
    private var turnChangesRecapSummary: TurnFileChangeSummary? {
        guard gitAvailabilityViewModel.hasRepository,
              viewModel.activeStreamID == nil,
              latestTranscriptMessageRole == "assistant"
        else { return nil }
        let summary = TurnFileChangeAggregator.summarize(
            toolCalls: viewModel.latestTurnToolCalls,
            status: gitAvailabilityViewModel.status
        )
        return summary.hasChanges ? summary : nil
    }

    /// Present the per-turn diff sheet for every changed file the turn has a status match
    /// for. No-op when there is nothing diffable yet (e.g. status still refreshing).
    private func presentTurnDiff(for summary: TurnFileChangeSummary?) {
        let files = summary?.diffFiles ?? []
        guard !files.isEmpty else { return }
        turnDiffPresentation = .turnFiles(files)
    }

    @MainActor
    private func performGitCheckout(_ target: GitCheckoutTarget, stashingChanges: Bool = false) async {
        let outcome = await gitAvailabilityViewModel.checkout(target, stashingChanges: stashingChanges)
        if outcome == .requiresStash {
            gitAlert = .error(String(localized: "Switching a branch with local changes is deferred. Commit or clean the workspace through chat first."))
        } else if let message = gitAvailabilityViewModel.actionErrorMessage {
            // Surface real failures and partial successes (branch switched but the
            // stashed changes could not be restored) — the view model sets
            // actionErrorMessage in both cases and clears it on every new checkout.
            gitAlert = .error(message)
        }
    }

    @MainActor
    private func performGitRemoteAction(_ action: GitRemoteAction) async {
        gitToastState.showProgress(GitActionProgress(
            title: action.progressTitle,
            subtitle: gitAvailabilityViewModel.currentBranchName
        ))

        if await gitAvailabilityViewModel.performRemoteAction(action) {
            gitToastState.showSuccess(GitActionSuccess(
                title: action.successTitle,
                subtitle: gitAvailabilityViewModel.currentBranchName,
                detailLines: [gitAvailabilityViewModel.lastActionMessage]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            ))
        } else {
            gitToastState.dismissProgress()
            if let message = gitAvailabilityViewModel.actionErrorMessage {
                gitAlert = .error(message)
            }
        }
    }

    private func gitAlertPresentation(_ alert: GitChatAlert) -> Alert {
        switch alert {
        case .confirmRemote(let action):
            return Alert(
                title: Text("Push Local Commits?"),
                message: Text("Push the current branch to its upstream, or to origin and set its upstream if none is configured?"),
                primaryButton: .default(Text("Push")) {
                    Task { await performGitRemoteAction(action) }
                },
                secondaryButton: .cancel()
            )
        case .error(let message):
            return Alert(
                title: Text("Git Action Failed"),
                message: Text(message),
                dismissButton: .default(Text("OK")) {
                    gitAvailabilityViewModel.clearActionError()
                }
            )
        }
    }

    @ViewBuilder
    private var composerAccessoryStack: some View {
        if composerAccessoryVisibleItemCount > 0 {
            VStack(spacing: composerAccessoryVerticalSpacing) {
                if !viewModel.pinnedLocalNotices.isEmpty {
                    PinnedLocalNoticeStack(notices: viewModel.pinnedLocalNotices)
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }

                if let activeRunStatusPresentation {
                    ChatActiveRunStatusView(presentation: activeRunStatusPresentation)
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                }

            }
            .padding(.horizontal)
            .padding(.bottom, composerHeight + 8)
            .allowsHitTesting(false)
            .zIndex(8)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: composerAccessoryVisibleItemCount)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: activeRunStatusPresentation)
            .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: viewModel.pinnedLocalNotices)
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        ChatTranscriptView(
            isLoading: viewModel.isLoading,
            errorMessage: viewModel.errorMessage,
            messages: viewModel.messages,
            displayedTranscriptMessages: displayedTranscriptMessages,
            compressionReferenceCard: viewModel.compressionReferenceCard,
            reasoningGroupsForAnchor: { anchorMessageID in
                viewModel.displayedReasoningGroupsForAnchor(anchorMessageID)
            },
            completedToolCallGroupsForAnchor: { anchorMessageID in
                viewModel.completedToolCallGroupsForAnchor(anchorMessageID)
            },
            liveReasoningText: viewModel.liveReasoningText,
            reasoningAnchorMessageID: viewModel.reasoningAnchorMessageID,
            liveToolCalls: viewModel.liveToolCalls,
            toolCallAnchorMessageID: viewModel.toolCallAnchorMessageID,
            streamingAssistantMessageID: viewModel.streamingAssistantMessageID,
            liveTokensPerSecond: viewModel.liveTokensPerSecond,
            activeStreamRecoveryState: viewModel.activeStreamRecoveryState,
            clarificationPrompt: viewModel.clarificationPrompt,
            isRespondingToClarification: viewModel.isRespondingToClarification,
            clarificationErrorMessage: viewModel.clarificationErrorMessage,
            hidesRunStatusAccessibility: activeRunStatusPresentation != nil,
            showsThinkingAndToolCards: showsThinkingAndToolCards,
            showsAssistantTypingIndicator: showsAssistantTypingIndicator,
            showsScrollToBottomButton: showsScrollToBottomButton,
            hasExplicitBottomScrollRequest: isExplicitBottomScrollActive,
            shouldFollowLatestMessage: shouldFollowLatestMessage,
            latestTranscriptMessageRole: latestTranscriptMessageRole,
            isScrolledNearBottom: isScrolledNearBottom,
            activeStreamID: viewModel.activeStreamID,
            streamingScrollTrigger: viewModel.streamingScrollTrigger,
            cacheFirstReconcileScrollToken: viewModel.cacheFirstReconcileScrollToken,
            bottomAnchorID: bottomAnchorID,
            transcriptMessageSpacing: transcriptMessageSpacing,
            transcriptBlockSpacing: transcriptBlockSpacing,
            transcriptBottomInsetHeight: transcriptBottomInsetHeight,
            scrollToBottomButtonBottomPadding: scrollToBottomButtonBottomPadding,
            localAttachmentPreviews: viewModel.localAttachmentPreviews,
            listeningMessageID: viewModel.listeningMessageID,
            isViewingCachedData: viewModel.isViewingCachedData,
            hasOlderMessages: viewModel.hasOlderMessages,
            isLoadingOlderMessages: viewModel.isLoadingOlderMessages,
            isRegeneratingMessage: viewModel.isRegeneratingMessage,
            isEditingMessage: viewModel.isEditingMessage,
            isForkingMessage: viewModel.isForkingMessage,
            loadAttachmentImage: { path in
                await viewModel.attachmentImageData(path: path)
            },
            loadAttachmentData: { path in
                await viewModel.attachmentRawData(path: path)
            },
            loadTranscriptMediaImage: { reference in
                await viewModel.transcriptMediaThumbnailData(for: reference)
            },
            loadTranscriptMediaData: { reference in
                await viewModel.transcriptMediaData(for: reference)
            },
            transcriptMediaCacheNamespace: transcriptMediaCacheNamespace,
            actionContext: { message, visibleIndex in
                viewModel.actionContext(for: message, visibleIndex: visibleIndex)
            },
            shouldRenderMessageRow: shouldRenderMessageRow,
            onLoadMessages: {
                await loadMessages()
            },
            onLoadOlderMessages: {
#if DEBUG
                let previousCancellationToken = transcriptRestoreCancellationToken
#endif
                didInteractBeforeTranscriptRestore = true
                isTranscriptRestorePending = false
                pendingTranscriptRestoreMessageID = nil
                transcriptRestoreCancellationToken &+= 1
#if DEBUG
                logTranscriptRestoreBoundary(
                    event: "transcript_restore_cancellation",
                    decision: "older_messages_callback",
                    previousCancellationToken: previousCancellationToken
                )
#endif
                return await loadOlderMessages()
            },
            onUpdateScrollMetrics: updateScrollMetrics,
            onDismissKeyboard: dismissKeyboard,
            onScrollToBottom: scrollToBottom,
            onScrollToLatestTranscriptMessage: { proxy in
                scrollToLatestTranscriptMessage(proxy)
            },
            onScrollToLatestContent: { proxy, animated in
                scrollToLatestContent(proxy, animated: animated)
            },
            onScrollToTranscriptMessage: { proxy, messageID, animated in
                scrollToTranscriptMessage(proxy, messageID: messageID, animated: animated)
            },
            onVisibleTranscriptRowIDChange: { rowID in
                if isTranscriptRestorePending {
                    guard let rowID, rowID == pendingTranscriptRestoreMessageID else {
                        return
                    }
                    isTranscriptRestorePending = false
                    pendingTranscriptRestoreMessageID = nil
                }
                guard visibleTranscriptRowID != rowID else { return }
                visibleTranscriptRowID = rowID
            },
            onTranscriptTailVisibilityChange: { latestRow, bottom in
                if isLatestTranscriptRowVisible != latestRow { isLatestTranscriptRowVisible = latestRow }
                if isTranscriptBottomVisible != bottom { isTranscriptBottomVisible = bottom }
            },
            onPreviewAttachment: { attachment, localData in
                presentPreviewRestoringComposerFocusIfNeeded {
                    attachmentPreviewItem = ChatAttachmentPreviewItem(message: attachment, localData: localData)
                }
            },
            onPreviewTranscriptMedia: { reference in
                transcriptMediaPreviewItem = TranscriptMediaPreviewItem(reference: reference)
            },
            onToggleListening: { context in
                viewModel.toggleListening(to: context)
            },
            onSubmitClarification: { response, identity in
                guard let identity else { return }
                Task {
                    let didRespond = await viewModel.respondToDirectClarification(
                        response,
                        expectedIdentity: identity
                    )
                    if didRespond {
                        ChatHaptics.clarificationSubmitted(isEnabled: isHapticsEnabled)
                    }
                }
            },
            onCancelClarification: { identity in
                guard let identity else { return }
                Task {
                    let didRespond = await viewModel.respondToDirectClarification(
                        "",
                        expectedIdentity: identity
                    )
                    if didRespond {
                        ChatHaptics.clarificationSubmitted(isEnabled: isHapticsEnabled)
                    }
                }
            },
            onSelectText: { context in
                selectableResponseText = SelectableTextPresentation(context: context)
            },
            onRegenerate: beginRegenerateResponse,
            onEdit: beginEditMessage,
            onFork: { context in
                Task { await forkFromMessage(context) }
            },
            onCopy: { context in
                UIPasteboard.general.string = context.copyText
            },
            inlineCommitContext: nil,
            onInlineCommit: {},
            turnChangesSummary: turnChangesRecapSummary,
            onOpenTurnDiff: {
                presentTurnDiff(for: turnChangesRecapSummary)
            },
            onOpenTurnFileDiff: { file in
                turnDiffPresentation = .file(file)
            },
            restoreScrollToken: restoreScrollToken,
            restoreTarget: viewModel.transcriptRestoreTarget,
            initialRestoreRequest: transcriptRestoreOutcomeState.pending,
            onInitialRestoreOutcome: { request, outcome in
                guard transcriptRestoreOutcomeState.complete(
                    request, outcome: outcome, currentScope: viewModel.outgoingInsertionScope
                ) else { return }
                isTranscriptRestorePending = false
                pendingTranscriptRestoreMessageID = nil
            },
            transcriptRestoreCancellationToken: transcriptRestoreCancellationToken,
            followRejoinScrollToken: followRejoinScrollToken,
            isComposerResizing: isComposerResizing,
            isUserInteractingWithScroll: isUserInteractingWithScroll,
            transcriptRenderRevision: viewModel.transcriptRenderRevision,
            outgoingInsertionScope: viewModel.outgoingInsertionScope,
            outgoingInsertionEvent: viewModel.outgoingInsertionEvent
        )
        .equatable()
    }

    /// The chat-canvas layout direction. Driven by the manual Settings → Chat
    /// RTL toggle (#259); applied only to the transcript + composer so the
    /// sidebar, settings, and navigation chrome stay in the default direction.
    private var chatLayoutDirection: LayoutDirection {
        ChatTranscriptDisplaySettings.chatLayoutDirection(rtlEnabled: rtlChatLayoutEnabled)
    }

    private var showsScrollToBottomButton: Bool {
        ChatScrollPolicy.shouldShowScrollToBottomButton(
            isNearBottom: isScrolledNearBottom && (
                !isExplicitBottomScrollActive || isLatestTranscriptRowVisible || isTranscriptBottomVisible
            ),
            hasExplicitBottomRequest: isExplicitBottomScrollActive,
            hasActiveStream: viewModel.activeStreamID != nil,
            shouldFollowLatestMessage: shouldFollowLatestMessage
        )
    }

    private var showsAssistantTypingIndicator: Bool {
        ChatTranscriptDisplaySettings.shouldShowAssistantTypingIndicator(
            hasActiveStream: viewModel.activeStreamID != nil,
            isCancellingStream: viewModel.isCancellingStream,
            hasStreamingAssistantMessage: viewModel.hasStreamingAssistantMessageContent,
            hasPendingClarificationPrompt: viewModel.clarificationPrompt != nil,
            liveReasoningText: viewModel.liveReasoningText,
            hasLiveToolCalls: !viewModel.liveToolCalls.isEmpty,
            showsThinkingAndToolCards: showsThinkingAndToolCards
        )
    }

    private var isComposerChromeCompact: Bool {
        isReadingOlderTranscript && !viewModel.messages.isEmpty
    }

    private var transcriptBottomInsetHeight: CGFloat {
        max(96, composerHeight + 44 + composerAccessorySpacerHeight)
    }

    private var scrollToBottomButtonBottomPadding: CGFloat {
        composerHeight + 12 + composerAccessorySpacerHeight
    }

    private var pinnedNoticeSpacerHeight: CGFloat {
        viewModel.pinnedLocalNotices.isEmpty ? 0 : CGFloat(viewModel.pinnedLocalNotices.count) * 60
    }

    private var activeRunStatusPresentation: ChatActiveRunStatusPresentation? {
        // The composer already owns the pending-stop label. A second floating
        // copy both repeats it and inserts another 36pt into the transcript.
        guard !viewModel.isCancellingStream else { return nil }
        return ChatActiveRunStatusPolicy.presentation(
            isStartingChat: viewModel.isStartingChat,
            hasActiveStream: viewModel.activeStreamID != nil,
            activeStreamRecoveryState: viewModel.activeStreamRecoveryState,
            isCancellingStream: viewModel.isCancellingStream,
            isScrolledNearBottom: isScrolledNearBottom,
            isEstablishingConnection: viewModel.isEstablishingConnection
        )
    }

    private var composerAccessorySpacerHeight: CGFloat {
        var height = pinnedNoticeSpacerHeight
        if activeRunStatusPresentation != nil {
            height += activeRunStatusSpacerHeight
        }
        let visibleItemCount = composerAccessoryVisibleItemCount
        if visibleItemCount > 1 {
            height += CGFloat(visibleItemCount - 1) * composerAccessoryVerticalSpacing
        }
        return height
    }

    private var composerAccessoryVisibleItemCount: Int {
        var count = 0
        if !viewModel.pinnedLocalNotices.isEmpty {
            count += 1
        }
        if activeRunStatusPresentation != nil {
            count += 1
        }
        return count
    }

    private var displayTitle: String {
        viewModel.displayTitle
    }

    private var activeProfileDetails: ProfileSummary? {
        guard let profileName = (viewModel.selectedProfileName ?? session.profile)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !profileName.isEmpty
        else {
            return nil
        }

        return viewModel.profileOptions.first { $0.normalizedName == profileName }
    }

    private var headerSubtitle: String? {
        ChatToolbarSubtitleResolver.subtitle(
            workspacePath: viewModel.selectedWorkspacePath,
            profileTitle: viewModel.selectedProfileTitle
        )
    }

    private func shouldRenderMessageRow(_ message: ChatMessage) -> Bool {
        if message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        return message.role == "user" && message.attachments?.isEmpty == false
    }

    private var transcriptMessages: [TranscriptMessage] {
        viewModel.displayedTranscriptMessages
    }

    private var displayedTranscriptMessages: [TranscriptMessage] {
        transcriptMessages
    }

    private var latestRenderedTranscriptMessage: TranscriptMessage? {
        var liveAnchorIDs = Set<String>()
        if showsThinkingAndToolCards, viewModel.activeStreamID != nil {
            if !viewModel.liveReasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let anchorID = viewModel.reasoningAnchorMessageID {
                liveAnchorIDs.insert(anchorID)
            }
            if !viewModel.liveToolCalls.isEmpty, let anchorID = viewModel.toolCallAnchorMessageID {
                liveAnchorIDs.insert(anchorID)
            }
        }

        return transcriptMessages.last {
            ChatTranscriptRenderSequence.includes(
                $0,
                showsThinkingAndToolCards: showsThinkingAndToolCards,
                compressionAfterRenderID: viewModel.compressionReferenceCard?.afterRenderID,
                reasoningGroupsForAnchor: viewModel.displayedReasoningGroupsForAnchor,
                toolCallGroupsForAnchor: viewModel.completedToolCallGroupsForAnchor,
                liveAccessoryAnchorIDs: liveAnchorIDs,
                shouldRenderMessage: shouldRenderMessageRow
            )
        }
    }

    private var latestTranscriptMessageID: String? {
        latestRenderedTranscriptMessage?.id
    }

    private var latestTranscriptMessageRole: String? {
        latestRenderedTranscriptMessage?.message.role
    }

    private func prepareInitialAppearance() {
        viewModel.setShowsLiveActivityResponseExcerpts(showsLiveActivityResponseExcerpts)
        guard ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(
            hasPreservedTranscript: viewModel.hasPreservedTranscript,
            wasReusedFromOpenSessionStore: viewModel.wasReusedFromOpenSessionStore
        ) else { return }
        if loadsInitialMessages {
            viewModel.prepareInitialMessageLoad(modelContext: modelContext)
        }
    }

    private func handleInitialAppearanceTask() async {
        prepareInitialAppearance()

        if disablesExternalLifecycle {
            requestTranscriptRestoreIfNeeded()
            isInitialComposerFocusContentReady = true
            handleInitialAppearanceCompletion()
            return
        }

        guard ChatInitialAppearancePolicy.shouldBeginAsyncWork(
            hasCompletedAppearance: didCompleteInitialAppearance
        ) else {
            return
        }

        async let chatStartup: Void = performInitialAsyncWork()
        async let gitAvailability: Void = loadInitialGitAvailability()
        _ = await (chatStartup, gitAvailability)
    }

    private func performInitialAsyncWork() async {
        guard !Task.isCancelled else { return }

        if loadsInitialMessages,
           ChatInitialAppearancePolicy.shouldReloadTranscriptOnAppear(
            hasPreservedTranscript: viewModel.hasPreservedTranscript,
            wasReusedFromOpenSessionStore: viewModel.wasReusedFromOpenSessionStore
           ) {
            if viewModel.activeStreamID != nil {
                // A known external run may be holding the server session lock.
                // Attach SSE first; only then reconcile the transcript so the
                // user sees live progress instead of a lone prompt bubble.
                let didLoadTranscript = await viewModel.reconnectStreamIfNeeded(modelContext: modelContext)
                if !didLoadTranscript {
                    await loadMessages(appliesInitialFocus: false, reconnectsAfterLoad: false)
                }
            } else {
                async let messages: Void = loadMessages(appliesInitialFocus: false, reconnectsAfterLoad: false)
                async let stream: Bool = viewModel.reconnectStreamIfNeeded(modelContext: modelContext)
                _ = await (messages, stream)
            }
            guard !Task.isCancelled else { return }
        } else {
            await viewModel.reconnectStreamIfNeeded(modelContext: modelContext)
            guard !Task.isCancelled else { return }
        }
        requestTranscriptRestoreIfNeeded()
        if initialAttachments.isEmpty {
            isInitialComposerFocusContentReady = true
            applyInitialComposerFocusPolicyIfNeeded()
        }
        await viewModel.loadComposerConfiguration()
        guard !Task.isCancelled else { return }

        await uploadInitialAttachmentsIfNeeded()
        guard !Task.isCancelled else { return }

        isInitialComposerFocusContentReady = true
        applyInitialComposerFocusPolicyIfNeeded()
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func loadInitialGitAvailability() async {
        if viewModel.usesDirectGateway {
            await gitAvailabilityViewModel.loadIfNeeded()
            return
        }
        let availabilityViewModel = GitWorkspaceAvailabilityViewModel(session: session, server: server)
        gitAvailabilityViewModel = availabilityViewModel
        await availabilityViewModel.loadIfNeeded()
    }

    private var goalControlMenu: some View {
        GoalControlsMenu(
            currentGoal: viewModel.currentGoal,
            isViewingCachedData: viewModel.isViewingCachedData,
            isActionDisabled: isGoalActionDisabled,
            isRunning: viewModel.activeStreamID != nil,
            onSetGoal: {
                showsGoalSheet = true
            },
            onSubmitCommand: { command in
                Task { await submitGoalCommand(command) }
            }
        )
    }

    private var isGoalActionDisabled: Bool {
        viewModel.isViewingCachedData || viewModel.isSubmittingGoal
    }

    private func loadMessages(appliesInitialFocus: Bool = true, reconnectsAfterLoad: Bool = true) async {
        await viewModel.loadMessages(modelContext: modelContext)
        if reconnectsAfterLoad {
            await viewModel.reconnectStreamIfNeeded(modelContext: modelContext)
        }
        if appliesInitialFocus {
            applyInitialComposerFocusPolicyIfNeeded()
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func loadOlderMessages() async -> Bool {
#if DEBUG
        let previousFollowLatest = shouldFollowLatestMessage
#endif
        shouldFollowLatestMessage = false
#if DEBUG
        logChatScrollBoundary(
            event: "follow_state_transition",
            decision: "load_older_messages",
            previousFollowLatest: previousFollowLatest
        )
#endif
        if !isReadingOlderTranscript {
            withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                isReadingOlderTranscript = true
            }
        }

        let didLoad = await viewModel.loadOlderMessages(modelContext: modelContext)
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        return didLoad
    }

    private func submitGoalDraft(_ submittedGoal: String) async {
        await submitGoal(submittedGoal, clearsDraftOnSuccess: true)
    }

    private func submitGoalCommand(_ command: String) async {
        await submitGoal(command, clearsDraftOnSuccess: false)
    }

    private func submitGoal(_ args: String, clearsDraftOnSuccess: Bool) async {
        prepareTranscriptForExplicitSend()

        let didSubmit = await viewModel.submitGoal(args: args, modelContext: modelContext)
        if didSubmit, clearsDraftOnSuccess {
            goalDraft = ""
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func sendDraftMessage() async {
#if DEBUG
        defer { ChatPerformanceCadenceMonitor.end(.send) }
#endif
        let submittedDraft = draftMessage
        let shouldRestoreFocusAfterSend = composerIsFocused

        if submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            let parsedCommand = SlashCommandExecutor.parse(submittedDraft)?.command
            let result = await SlashCommandExecutor.execute(text: submittedDraft, viewModel: viewModel)
            handleSlashExecutionResult(result, parsedCommand: parsedCommand)

            if result != .sendAsMessage {
                if let lastError = viewModel.lastError {
                    onAPIError(lastError)
                }
                return
            }
        }

        let didStart: Bool
        if viewModel.activeStreamID != nil {
            prepareTranscriptForExplicitSend()
            let result = await viewModel.submitStreamingMessage(
                submittedDraft,
                behavior: StreamingSendBehavior.storedValue(streamingSendBehaviorRawValue)
            )
            handleSlashExecutionResult(result, parsedCommand: SlashCommandCatalog.command(named: streamingSendBehaviorCommandName))
            didStart = result.isSuccessfulSubmission
        } else {
            didStart = await sendStandardMessage(submittedDraft)
        }

        if didStart {
            ChatHaptics.messageSent(isEnabled: isHapticsEnabled)
            if shouldRestoreFocusAfterSend {
                requestComposerFocusIfPossible()
            } else {
                composerIsFocused = false
            }
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func sendVoiceNote(audioData: Data, filename: String) async {
#if DEBUG
        defer { ChatPerformanceCadenceMonitor.end(.send) }
#endif
        prepareTranscriptForExplicitSend()

        let didSend = await viewModel.sendVoiceNote(
            audioData: audioData,
            filename: filename,
            modelContext: modelContext
        )

        if didSend {
            ChatHaptics.messageSent(isEnabled: isHapticsEnabled)
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func sendStandardMessage(_ submittedDraft: String) async -> Bool {
        guard !submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        prepareTranscriptForExplicitSend()

        draftMessage = ""
        if viewModel.usesDirectGateway {
            // Clear saved direct draft before awaiting submission to reduce
            // stale composer restoration after termination. UserDefaults
            // does not guarantee synchronous disk durability.
            persistComposerDraft()
        }

        let didStart = await viewModel.sendMessage(submittedDraft, modelContext: modelContext)
        if !didStart, draftMessage.isEmpty {
            draftMessage = submittedDraft
        }
        persistComposerDraft()

        return didStart
    }

    private func handleSlashExecutionResult(
        _ result: SlashCommandExecutionResult,
        parsedCommand: SlashCommand?
    ) {
        switch result {
        case .executed(let message):
            if let message {
                if shouldRenderAsLocalNotice(parsedCommand) {
                    if viewModel.activeStreamID == nil {
                        viewModel.appendLocalNoticeMessage(message)
                    } else {
                        viewModel.pinLocalNoticeMessage(message)
                    }
                } else {
                    viewModel.appendLocalAssistantMessage(message)
                }
            }
            draftMessage = ""
        case .openedSession(let session):
            forkedSession = session
            draftMessage = ""
        case .openedDirectBranch(let handoff):
            guard OpenChatSessionStore.shared.adoptBranch(handoff) != nil else {
                OpenChatSessionStore.shared.releaseUnadoptedBranch(handoff)
                viewModel.setSendErrorMessage(String(localized: "The direct branch could not be opened safely."))
                return
            }
            directBranchHandoff = handoff
            isShowingDirectBranch = true
            draftMessage = ""
        case .unsupported(let friendlyMessage):
            viewModel.setSendErrorMessage(friendlyMessage)
            draftMessage = ""
        case .needsSubArg:
            viewModel.setSendErrorMessage(String(localized: "Choose a slash command or continue typing."))
        case .sendAsMessage:
            break
        }
    }

    private func shouldRenderAsLocalNotice(_ command: SlashCommand?) -> Bool {
        command?.handler == .serverSide(.compress) ||
            command?.handler == .serverSide(.queue) ||
            command?.handler == .serverSide(.steer) ||
            command?.handler == .serverSide(.interrupt) ||
            command?.handler == .serverSide(.background)
    }

    private var streamingSendBehaviorCommandName: String {
        switch StreamingSendBehavior.storedValue(streamingSendBehaviorRawValue) {
        case .steer:
            "steer"
        case .interrupt:
            "interrupt"
        case .queue:
            "queue"
        }
    }

    private func cancelStream() async {
        let didCancel = await viewModel.cancelActiveStream()
        if didCancel {
            ChatHaptics.streamCancelled(isEnabled: isHapticsEnabled)
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func forkFromMessage(_ context: MessageActionContext) async {
        let session = await viewModel.forkFromMessage(context, modelContext: modelContext)

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        if let session {
            forkedSession = session
        }
    }

    private func handleProfileSelection(_ profile: ProfileSummary) {
        if viewModel.isSelectedProfile(profile) {
            return
        }

        if viewModel.messages.isEmpty {
            Task { await switchProfile(profile, startNewSession: false) }
        } else {
            pendingProfileSelection = profile
            showProfileNewSessionConfirmation = true
        }
    }

    private func switchProfile(_ profile: ProfileSummary, startNewSession: Bool) async {
        let outcome = await viewModel.switchProfile(profile, startNewSession: startNewSession)
        pendingProfileSelection = nil

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        if outcome != nil {
            ChatHaptics.configurationSelected(isEnabled: isHapticsEnabled)
        }

        if let session = outcome?.session {
            forkedSession = session
        }
    }

    private func uploadInitialAttachmentsIfNeeded() async {
        guard !didUploadInitialAttachments, !initialAttachments.isEmpty else {
            return
        }

        didUploadInitialAttachments = true
        for attachment in initialAttachments {
            await viewModel.uploadAttachment(
                data: attachment.data,
                filename: attachment.filename,
                previewData: previewData(for: attachment)
            )
        }
    }

    private func previewData(for attachment: SharedAttachmentImport) -> Data? {
        if let typeIdentifier = attachment.typeIdentifier,
           UTType(typeIdentifier)?.conforms(to: .image) == true {
            return attachment.data
        }

        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"]
        let fileExtension = URL(fileURLWithPath: attachment.filename).pathExtension.lowercased()
        return imageExtensions.contains(fileExtension) ? attachment.data : nil
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        do {
            // Photos videos are file-backed assets. Data.self is not a reliable
            // transferable representation for every Photos/iCloud movie, so use
            // the file-representation API for movies and read the temporary file
            // while Photos guarantees it is available.
            let contentType = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) })
                ?? item.supportedContentTypes.first
            let isVideo = contentType?.conforms(to: .movie) == true
            let data: Data?
            if isVideo {
                data = try await item.loadTransferable(type: ImportedPhotoVideo.self)?.data
            } else {
                data = try await item.loadTransferable(type: Data.self)
            }

            guard let data else {
                viewModel.setUploadAttachmentError(String(localized: "Could not read the selected media."))
                return
            }

            let fileExtension = contentType?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
            let prefix = isVideo ? "video" : "image"
            let filename = "\(prefix)_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(4)).\(fileExtension)"

            await viewModel.uploadAttachment(
                data: data,
                filename: filename,
                previewData: isVideo ? nil : data
            )
        } catch {
            viewModel.setUploadAttachmentError(error.localizedDescription)
        }
    }

    private func handleSelectedFileURLs(_ urls: [URL]) async {
        let fileURLs = urls.filter(\.isFileURL)

        guard !fileURLs.isEmpty else {
            viewModel.setUploadAttachmentError(String(localized: "Select a file to attach it."))
            return
        }

        for url in fileURLs {
            do {
                let file = try await loadPastedFile(from: url, suggestedName: nil)
                await viewModel.uploadAttachment(data: file.data, filename: file.filename)
            } catch {
                viewModel.setUploadAttachmentError(error.localizedDescription)
            }
        }
    }

    private func handlePastedFileProviders(_ providers: [NSItemProvider]) async {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard !fileProviders.isEmpty else {
            viewModel.setUploadAttachmentError(String(localized: "Paste a copied file to attach it."))
            return
        }

        for provider in fileProviders {
            do {
                let file = try await loadPastedFile(from: provider)
                await viewModel.uploadAttachment(data: file.data, filename: file.filename)
            } catch {
                viewModel.setUploadAttachmentError(error.localizedDescription)
            }
        }
    }

    private func handlePastedImageProviders(_ providers: [NSItemProvider]) async {
        let imageProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }

        guard !imageProviders.isEmpty else {
            viewModel.setUploadAttachmentError(String(localized: "Paste a copied image to attach it."))
            return
        }

        for provider in imageProviders {
            do {
                let image = try await loadPastedImage(from: provider)
                await viewModel.uploadAttachment(data: image.data, filename: image.filename, previewData: image.data)
            } catch {
                viewModel.setUploadAttachmentError(error.localizedDescription)
            }
        }
    }

    private func handlePastedImages(_ images: [UIImage]) async {
        guard !images.isEmpty else {
            viewModel.setUploadAttachmentError(String(localized: "Paste a copied image to attach it."))
            return
        }

        for image in images {
            guard let data = image.jpegData(compressionQuality: 0.92) ?? image.pngData() else {
                viewModel.setUploadAttachmentError(String(localized: "Could not read the pasted image."))
                continue
            }

            await viewModel.uploadAttachment(data: data, filename: pastedImageFilename(), previewData: data)
        }
    }

    private func loadPastedFile(from provider: NSItemProvider) async throws -> PastedFile {
        let suggestedName = provider.suggestedName

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let url = pastedFileURL(from: item) else {
                    continuation.resume(throwing: PastedFileError.unreadableURL)
                    return
                }

                Task {
                    do {
                        let file = try await loadPastedFile(from: url, suggestedName: suggestedName)
                        continuation.resume(returning: file)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func handlePastedFileURLs(_ urls: [URL]) async {
        let fileURLs = urls.filter(\.isFileURL)

        guard !fileURLs.isEmpty else {
            viewModel.setUploadAttachmentError(String(localized: "Paste a copied file to attach it."))
            return
        }

        for url in fileURLs {
            do {
                let file = try await loadPastedFile(from: url, suggestedName: nil)
                await viewModel.uploadAttachment(data: file.data, filename: file.filename)
            } catch {
                viewModel.setUploadAttachmentError(error.localizedDescription)
            }
        }
    }

    private func loadPastedFile(from url: URL, suggestedName: String?) async throws -> PastedFile {
        try await PastedFileLoader.load(from: url, suggestedName: suggestedName)
    }

    private func loadPastedImage(from provider: NSItemProvider) async throws -> PastedFile {
        let suggestedName = provider.suggestedName
        let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image)
        } ?? UTType.image.identifier

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data else {
                    continuation.resume(throwing: PastedFileError.unreadableImage)
                    return
                }

                continuation.resume(
                    returning: PastedFile(
                        data: data,
                        filename: pastedImageFilename(suggestedName: suggestedName)
                    )
                )
            }
        }
    }

    nonisolated private func pastedImageFilename(suggestedName: String? = nil) -> String {
        if let suggestedName,
           !suggestedName.isEmpty,
           !URL(fileURLWithPath: suggestedName).pathExtension.isEmpty {
            return suggestedName
        }

        return "image_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(4)).jpg"
    }

    nonisolated private func pastedFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }

        if let string = item as? String {
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }

        return nil
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            viewModel.setTranscriptPresentationActive(false)
            persistComposerDraft()
            persistTranscriptRestore()
            foregroundRefreshTask?.cancel()
            foregroundRefreshTask = nil
            if viewModel.activeStreamID != nil {
                beginResponseCompletionBackgroundTask()
            }
        case .active:
            viewModel.setTranscriptPresentationActive(true)
            viewModel.refreshListenPlaybackProgressAfterSceneActivation()
            endResponseCompletionBackgroundTask()
            guard !disablesExternalLifecycle else { return }
            foregroundRefreshTask?.cancel()
            foregroundRefreshTask = Task { @MainActor in
                await viewModel.refreshAfterSceneActivation(modelContext: modelContext)
                guard !Task.isCancelled, scenePhase == .active else { return }

                if let lastError = viewModel.lastError {
                    onAPIError(lastError)
                }
            }
        case .inactive:
            viewModel.setTranscriptPresentationActive(false)
            foregroundRefreshTask?.cancel()
            foregroundRefreshTask = nil
        @unknown default:
            break
        }
    }

    private func handleActiveStreamChange() {
        guard viewModel.activeStreamID == nil else { return }

        if responseCompletionNotificationTracker.shouldEndBackgroundTaskOnStreamInactive(
            completionTrigger: viewModel.responseCompletionHapticTrigger
        ) {
            endResponseCompletionBackgroundTask()
        }

        // The agent may have edited files this turn, so refresh git state once
        // the response finishes.
        Task { await gitAvailabilityViewModel.refreshAfterExternalMutation() }
    }

#if DEBUG
    private func debugOpaqueTranscriptTargetKey(_ targetID: String) -> String {
        // Use a deterministic opaque key for cross-boundary correlation without
        // placing a transcript/render ID in the diagnostic stream.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in targetID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func logTranscriptRestoreBoundary(
        event: String,
        decision: String,
        previousCancellationToken: Int? = nil
    ) {
        let previousCancellationValue = previousCancellationToken.map(String.init) ?? "none"
        Self.transcriptScrollLogger.debug("""
            event=\(event, privacy: .public) decision=\(decision, privacy: .public) \
            restoreScrollToken=\(restoreScrollToken, privacy: .public) transcriptRestoreCancellationToken=\(transcriptRestoreCancellationToken, privacy: .public) \
            previousCancellationToken=\(previousCancellationValue, privacy: .public) didRequestRestore=\(didRequestTranscriptRestore, privacy: .public) \
            didInteractBeforeRestore=\(didInteractBeforeTranscriptRestore, privacy: .public) restorePending=\(isTranscriptRestorePending, privacy: .public) \
            savedFollowLatest=\(shouldFollowLatestMessage, privacy: .public) userInteracting=\(isUserInteractingWithScroll, privacy: .public) \
            followGeneration=\(followScrollGeneration, privacy: .public)
            """)
    }

    private func logTranscriptProxyGenerationBoundary(
        event: String,
        decision: String,
        targetKey: String,
        generation: Int
    ) {
        Self.transcriptScrollLogger.debug("""
            event=\(event, privacy: .public) decision=\(decision, privacy: .public) \
            proxyTargetKey=\(targetKey, privacy: .public) generation=\(generation, privacy: .public) \
            currentGeneration=\(followScrollGeneration, privacy: .public) userInteracting=\(isUserInteractingWithScroll, privacy: .public) \
            directTranscriptRestore=\(isTranscriptRestorePending, privacy: .public) followLatest=\(shouldFollowLatestMessage, privacy: .public)
            """)
    }

    /// Emits bounded, content-free ChatView scroll-boundary evidence. Metrics are
    /// supplied only by an existing scroll callback; no per-sample state is kept.
    private func logChatScrollBoundary(
        event: String,
        decision: String,
        previousFollowLatest: Bool? = nil,
        metrics: ChatScrollMetrics? = nil
    ) {
        if let previousFollowLatest, previousFollowLatest == shouldFollowLatestMessage {
            return
        }
        let previousFollowValue = previousFollowLatest.map { $0 ? "true" : "false" } ?? "unknown"
        let directInteractionValue = metrics.map { $0.isDirectlyInteracting ? "true" : "false" } ?? "unknown"
        let deceleratingValue = metrics.map { $0.isDecelerating ? "true" : "false" } ?? "unknown"
        let distanceValue = metrics.map { String(Double($0.distanceFromBottom)) } ?? "unknown"

        Self.transcriptScrollLogger.debug("""
            event=\(event, privacy: .public) decision=\(decision, privacy: .public) \
            followLatest=\(shouldFollowLatestMessage, privacy: .public) previousFollowLatest=\(previousFollowValue, privacy: .public) \
            directInteraction=\(directInteractionValue, privacy: .public) decelerating=\(deceleratingValue, privacy: .public) \
            effectiveUserInteraction=\(isUserInteractingWithScroll, privacy: .public) explicitBottomDeceleration=\(isExplicitBottomDecelerationActive, privacy: .public) \
            followGeneration=\(followScrollGeneration, privacy: .public) distanceFromBottom=\(distanceValue, privacy: .public) \
            nearBottom=\(isScrolledNearBottom, privacy: .public) nearMotionBand=\(isNearBottomForMotion, privacy: .public) \
            latestRowVisible=\(isLatestTranscriptRowVisible, privacy: .public) tailVisible=\(isTranscriptBottomVisible, privacy: .public) \
            composerHeight=\(Double(composerHeight), privacy: .public) transcriptBottomInsetHeight=\(Double(transcriptBottomInsetHeight), privacy: .public) \
            composerAccessorySpacerHeight=\(Double(composerAccessorySpacerHeight), privacy: .public) composerResizeGeneration=\(composerResizeGeneration, privacy: .public) composerResizing=\(isComposerResizing, privacy: .public) \
            streamActive=\(viewModel.activeStreamID != nil, privacy: .public)
            """)
    }
#endif

    private func handleResponseCompletionSideEffects() {
        if !viewModel.responseCompletionNeedsTranscriptRefresh {
            viewModel.cacheCompletedResponse(modelContext: modelContext)
        }

        guard let completionContext = responseCompletionNotificationTracker.completionContext(
            completionTrigger: viewModel.responseCompletionHapticTrigger,
            sceneIsActive: scenePhase == .active
        ) else {
            return
        }

        ChatHaptics.assistantResponseCompleted(isEnabled: isHapticsEnabled)

        Task { @MainActor in
            defer { endResponseCompletionBackgroundTask() }

            if viewModel.responseCompletionNeedsTranscriptRefresh {
                await loadMessages()
            }

            await ResponseCompletionNotificationService.scheduleResponseCompletedIfAllowed(
                sessionID: session.sessionId,
                preferenceEnabled: isResponseCompletionNotificationsEnabled,
                completedNormally: true,
                sceneIsActive: completionContext.sceneIsActive
            )
        }
    }

    private func beginResponseCompletionBackgroundTask() {
        guard responseCompletionBackgroundTask == .invalid else { return }

        let taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "Semreh response completion") {
            Task { @MainActor in
                endResponseCompletionBackgroundTask()
            }
        }

        responseCompletionBackgroundTask = taskIdentifier
    }

    private func endResponseCompletionBackgroundTask() {
        guard responseCompletionBackgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(responseCompletionBackgroundTask)
        responseCompletionBackgroundTask = .invalid
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        transcriptRestoreOutcomeState.acceptUserIntent()
        didInteractBeforeTranscriptRestore = true
        isTranscriptRestorePending = false
        pendingTranscriptRestoreMessageID = nil
        beginExplicitBottomScroll(proxy)
    }

    private func beginExplicitBottomScroll(_ proxy: ScrollViewProxy) {
        explicitBottomScrollTask?.cancel()
        explicitBottomScrollGeneration &+= 1
        let generation = explicitBottomScrollGeneration
        let shouldAnimateInitialJump = ChatScrollPolicy.shouldAnimateExplicitBottomJump(
            reduceMotion: reduceMotion
        )
#if DEBUG
        explicitBottomScrollAttemptCount = 0
        Self.transcriptScrollLogger.debug("""
            event=explicit_bottom_start decision=\(shouldAnimateInitialJump ? "animate" : "reduce_motion_snap", privacy: .public) \
            animated=\(shouldAnimateInitialJump, privacy: .public) reduceMotion=\(reduceMotion, privacy: .public) \
            nearMotionBand=\(isNearBottomForMotion, privacy: .public) directInteraction=\(isUserInteractingWithScroll, privacy: .public)
            """)
#endif

        userScrollCooldownUntil = nil
        isExplicitBottomDecelerationActive = false
        hasIssuedExplicitBottomScroll = false
        // Invalidate any previously scheduled automatic follow operation. Its
        // delayed proxy call must not win after an explicit user jump begins.
        followScrollGeneration &+= 1
        // The explicit jump owns positioning until its concrete tail arrives.
        // Re-enabling automatic anchoring or expanding the composer here races
        // lazy measurement and can turn an estimated offset into a blank tail.
#if DEBUG
        let previousFollowLatest = shouldFollowLatestMessage
#endif
        shouldFollowLatestMessage = false
        isExplicitBottomScrollActive = true
#if DEBUG
        logChatScrollBoundary(
            event: "follow_state_transition",
            decision: "explicit_bottom_settling",
            previousFollowLatest: previousFollowLatest
        )
#endif

        // Do not wait for a task hop before the first jump. In particular, an
        // old near-bottom/tail-visible metrics sample must not make the request
        // look settled without ever delivering its target to UIKit.
        issueExplicitBottomScroll(proxy, animated: shouldAnimateInitialJump)
        guard isExplicitBottomScrollActive else { return }

        explicitBottomScrollTask = Task { @MainActor in
            for delay in ChatScrollPolicy.explicitBottomSettlementDelays.dropFirst() {
                try? await Task.sleep(nanoseconds: delay)

                guard !Task.isCancelled,
                      generation == explicitBottomScrollGeneration,
                      isExplicitBottomScrollActive
                else { return }

                if ChatScrollPolicy.shouldFinishExplicitBottomRequest(
                    isNearBottom: isScrolledNearBottom,
                    isTailVisible: isLatestTranscriptRowVisible || isTranscriptBottomVisible,
                    hasIssuedScroll: hasIssuedExplicitBottomScroll
                ) {
                    completeExplicitBottomScroll(generation: generation)
                    return
                }

                // Realize the concrete last row before refining toward trailing
                // content. Keep nearby settlement calls animated so a retry
                // retargets the in-flight motion instead of cancelling it;
                // far-history settlement remains direct.
                issueExplicitBottomScroll(proxy, animated: shouldAnimateInitialJump)
            }

            guard generation == explicitBottomScrollGeneration else { return }
            explicitBottomScrollTask = nil
#if DEBUG
            Self.transcriptScrollLogger.debug("""
                event=explicit_bottom_exhausted decision=keep_request_visible \
                attempts=\(explicitBottomScrollAttemptCount, privacy: .public) nearBottom=\(isScrolledNearBottom, privacy: .public) \
                latestRowVisible=\(isLatestTranscriptRowVisible, privacy: .public) tailVisible=\(isTranscriptBottomVisible, privacy: .public)
                """)
#endif
            // Leave the request active (and the button visible) if UIKit still
            // reports distance. A subsequent tap starts a fresh settlement pass.
        }
    }

    private func issueExplicitBottomScroll(
        _ proxy: ScrollViewProxy,
        animated: Bool = false
    ) {
        let target = ChatScrollPolicy.explicitBottomTargetID(
            latestMessageID: latestTranscriptMessageID,
            latestMessageIsVisible: isLatestTranscriptRowVisible,
            bottomAnchorID: bottomAnchorID
        )
#if DEBUG
        explicitBottomScrollAttemptCount += 1
        Self.transcriptScrollLogger.debug("""
            event=explicit_bottom_attempt decision=proxy_scroll \
            attempt=\(explicitBottomScrollAttemptCount, privacy: .public) animated=\(animated, privacy: .public) \
            targetKind=\(target == bottomAnchorID ? "tail" : "latest_row", privacy: .public) \
            latestRowExists=\(latestTranscriptMessageID != nil, privacy: .public) latestRowVisible=\(isLatestTranscriptRowVisible, privacy: .public)
            """)
#endif
        if animated, let animation = ChatMotion.scrollToLatest(reduceMotion: reduceMotion) {
            withAnimation(animation) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(target, anchor: .bottom)
        }
        guard isExplicitBottomScrollActive else { return }
        hasIssuedExplicitBottomScroll = true
    }

    private func finishExplicitBottomScroll(generation: Int? = nil) {
        if let generation, generation != explicitBottomScrollGeneration { return }
        explicitBottomScrollTask?.cancel()
        explicitBottomScrollTask = nil
        isExplicitBottomScrollActive = false
        hasIssuedExplicitBottomScroll = false
    }

    private func completeExplicitBottomScroll(generation: Int? = nil) {
        guard generation == nil || generation == explicitBottomScrollGeneration else { return }
#if DEBUG
        Self.transcriptScrollLogger.debug("""
            event=explicit_bottom_settled decision=near_bottom_and_tail_visible \
            attempts=\(explicitBottomScrollAttemptCount, privacy: .public) latestRowVisible=\(isLatestTranscriptRowVisible, privacy: .public) \
            tailVisible=\(isTranscriptBottomVisible, privacy: .public)
            """)
#endif
        finishExplicitBottomScroll(generation: generation)
#if DEBUG
        let previousFollowLatest = shouldFollowLatestMessage
#endif
        shouldFollowLatestMessage = true
#if DEBUG
        logChatScrollBoundary(
            event: "follow_state_transition",
            decision: "explicit_bottom_settled",
            previousFollowLatest: previousFollowLatest
        )
#endif
        isReadingOlderTranscript = false
    }

    private func cancelExplicitBottomScroll() {
#if DEBUG
        Self.transcriptScrollLogger.debug("""
            event=explicit_bottom_cancelled decision=direct_interaction \
            attempts=\(explicitBottomScrollAttemptCount, privacy: .public)
            """)
#endif
        explicitBottomScrollGeneration &+= 1
        isExplicitBottomDecelerationActive = false
        finishExplicitBottomScroll()
    }

    private func scrollToLatestTranscriptMessage(
        _ proxy: ScrollViewProxy,
        animated: Bool = true,
        isUserInitiated: Bool = false
    ) {
        guard let latestTranscriptMessageID else { return }

        scheduleFollowScroll(
            proxy,
            targetID: latestTranscriptMessageID,
            anchor: .bottom,
            animated: animated,
            isUserInitiated: isUserInitiated
        )
    }

    private func scrollToLatestContent(
        _ proxy: ScrollViewProxy,
        animated: Bool = true,
        isUserInitiated: Bool = false
    ) {
        let animateAfterComposerResize = shouldAnimateNextFollowAfterComposerResize
        shouldAnimateNextFollowAfterComposerResize = false
        guard !viewModel.messages.isEmpty else { return }

        scheduleFollowScroll(
            proxy,
            targetID: bottomAnchorID,
            anchor: .bottom,
            animated: animated || animateAfterComposerResize,
            isUserInitiated: isUserInitiated
        )
    }

    private func scrollToTranscriptMessage(
        _ proxy: ScrollViewProxy,
        messageID: String,
        animated: Bool
    ) {
#if DEBUG
        let targetKey = debugOpaqueTranscriptTargetKey(messageID)
        if let pendingDiagnostic = pendingTranscriptProxyGenerationDiagnostic {
            logTranscriptProxyGenerationBoundary(
                event: "transcript_proxy_generation",
                decision: "superseded_before_fire",
                targetKey: pendingDiagnostic.targetKey,
                generation: pendingDiagnostic.generation
            )
            pendingTranscriptProxyGenerationDiagnostic = nil
        }
#endif
        followScrollGeneration += 1
        let generation = followScrollGeneration
#if DEBUG
        pendingTranscriptProxyGenerationDiagnostic = ChatTranscriptProxyGenerationDiagnostic(
            targetKey: targetKey,
            generation: generation
        )
        logTranscriptProxyGenerationBoundary(
            event: "transcript_proxy_generation",
            decision: "scheduled",
            targetKey: targetKey,
            generation: generation
        )
#endif

        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 16_000_000)
#if DEBUG
            let taskWasCancelled = Task.isCancelled
            let generationChanged = generation != followScrollGeneration
            guard !taskWasCancelled, !generationChanged else {
                if pendingTranscriptProxyGenerationDiagnostic?.generation == generation {
                    logTranscriptProxyGenerationBoundary(
                        event: "transcript_proxy_generation",
                        decision: taskWasCancelled ? "task_cancelled" : "generation_changed",
                        targetKey: targetKey,
                        generation: generation
                    )
                    pendingTranscriptProxyGenerationDiagnostic = nil
                }
                return
            }
#else
            guard !Task.isCancelled, generation == followScrollGeneration else { return }
#endif

            if animated {
                withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(messageID, anchor: .top)
                }
            } else {
                proxy.scrollTo(messageID, anchor: .top)
            }
#if DEBUG
            if pendingTranscriptProxyGenerationDiagnostic?.generation == generation {
                logTranscriptProxyGenerationBoundary(
                    event: "transcript_proxy_generation",
                    decision: "issued",
                    targetKey: targetKey,
                    generation: generation
                )
                pendingTranscriptProxyGenerationDiagnostic = nil
            }
#endif
        }
    }

    private func scheduleFollowScroll(
        _ proxy: ScrollViewProxy,
        targetID: String,
        anchor: UnitPoint,
        animated: Bool,
        isUserInitiated: Bool
    ) {
#if DEBUG
        let targetKind = targetID == bottomAnchorID ? "latest_content" : "latest_row"
#endif
        // Auto-follow (streaming tokens, new rows) must not override the user's
        // scroll position while they are interacting or within the cooldown.
        if !isUserInitiated, isAutoFollowScrollPaused {
#if DEBUG
            let cooldownActive = userScrollCooldownUntil.map { Date() < $0 } ?? false
            Self.transcriptScrollLogger.debug("""
                event=follow_scroll_skipped decision=auto_follow_paused targetKind=\(targetKind, privacy: .public) \
                userInitiated=\(isUserInitiated, privacy: .public) animatedRequested=\(animated, privacy: .public) \
                effectiveUserInteraction=\(isUserInteractingWithScroll, privacy: .public) cooldownActive=\(cooldownActive, privacy: .public)
                """)
#endif
            return
        }

        if isUserInitiated {
            userScrollCooldownUntil = nil
        }

#if DEBUG
        let previousFollowLatest = shouldFollowLatestMessage
#endif
        shouldFollowLatestMessage = true
        isReadingOlderTranscript = false
        followScrollGeneration += 1
        let generation = followScrollGeneration
#if DEBUG
        logChatScrollBoundary(
            event: "follow_state_transition",
            decision: isUserInitiated ? "user_follow_scroll" : "automatic_follow_scroll",
            previousFollowLatest: previousFollowLatest
        )
#endif
#if DEBUG
        Self.transcriptScrollLogger.debug("""
            event=follow_scroll_scheduled decision=await_layout targetKind=\(targetKind, privacy: .public) \
            userInitiated=\(isUserInitiated, privacy: .public) animatedRequested=\(animated, privacy: .public) \
            generation=\(generation, privacy: .public) nearMotionBand=\(isNearBottomForMotion, privacy: .public)
            """)
#endif

        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled, generation == followScrollGeneration else {
#if DEBUG
                Self.transcriptScrollLogger.debug("""
                    event=follow_scroll_cancelled decision=generation_changed targetKind=\(targetKind, privacy: .public) \
                    generation=\(generation, privacy: .public)
                    """)
#endif
                return
            }
            // Re-check at fire time: a gesture may have begun during the delay.
            if !isUserInitiated, isAutoFollowScrollPaused {
#if DEBUG
                Self.transcriptScrollLogger.debug("""
                    event=follow_scroll_skipped decision=auto_follow_paused_at_fire targetKind=\(targetKind, privacy: .public) \
                    generation=\(generation, privacy: .public) directInteraction=\(isUserInteractingWithScroll, privacy: .public)
                    """)
#endif
                return
            }

            // Snap (no animation) while inside the cache-first reconcile window so the
            // taller server transcript replacing the cached one doesn't animate a jump
            // (#289). Evaluated at fire time so it's robust to onChange ordering.
            let isCacheFirstSnapWindow = cacheFirstSnapUntil.map { Date() < $0 } ?? false
            // Keep nearby follow motions readable, but never animate a long
            // return through history. `isNearBottomForMotion` is a coarse band
            // updated only when crossing its threshold, not a per-pixel state.
            let shouldAnimate = animated
                && isNearBottomForMotion
                && !isCacheFirstSnapWindow
                && !reduceMotion
#if DEBUG
            Self.transcriptScrollLogger.debug("""
                event=follow_scroll_command decision=proxy_scroll targetKind=\(targetKind, privacy: .public) \
                generation=\(generation, privacy: .public) animated=\(shouldAnimate, privacy: .public) \
                nearMotionBand=\(isNearBottomForMotion, privacy: .public) cacheFirstSnap=\(isCacheFirstSnapWindow, privacy: .public) reduceMotion=\(reduceMotion, privacy: .public)
                """)
#endif
            if shouldAnimate {
                // While streaming, follow with the short cadence-synced curve so
                // back-to-back triggers retarget smoothly; otherwise keep the
                // regular follow-scroll feel.
                let animation = viewModel.activeStreamID != nil
                    ? ChatMotion.streamingFollow(reduceMotion: reduceMotion)
                    : ChatMotion.scrollToLatest(reduceMotion: reduceMotion)
                withAnimation(animation) {
                    proxy.scrollTo(targetID, anchor: anchor)
                }
            } else {
                proxy.scrollTo(targetID, anchor: anchor)
            }
        }
    }

    private func dismissKeyboard() {
        composerIsFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private var canFocusComposer: Bool {
        !viewModel.isViewingCachedData
            && !viewModel.isUploadingAttachment
            && viewModel.uploadAttachmentErrorMessage == nil
    }

    private func handleInitialAppearanceCompletion() {
        didCompleteInitialAppearance = true
        applyInitialComposerFocusPolicyIfNeeded()
    }

    private func applyInitialComposerFocusPolicyIfNeeded() {
        guard !didApplyInitialComposerFocusPolicy else { return }
        guard didCompleteInitialAppearance, isInitialComposerFocusContentReady else { return }

        if !viewModel.messages.isEmpty {
            didApplyInitialComposerFocusPolicy = true
            return
        }

        guard viewModel.errorMessage == nil, canFocusComposer else { return }
        didApplyInitialComposerFocusPolicy = true
        requestComposerFocusIfPossible()
    }

    private func presentPreviewRestoringComposerFocusIfNeeded(_ present: () -> Void) {
        shouldRestoreComposerFocusAfterPreview = composerIsFocused
        if composerIsFocused {
            composerIsFocused = false
        }
        present()
    }

    private func restoreComposerFocusAfterPreviewIfNeeded() {
        guard shouldRestoreComposerFocusAfterPreview else { return }
        shouldRestoreComposerFocusAfterPreview = false
        requestComposerFocusIfPossible()
    }

    private func requestComposerFocusIfPossible() {
        guard canFocusComposer else { return }

        Task { @MainActor in
            await Task.yield()
            guard canFocusComposer else { return }
            composerIsFocused = true
        }
    }

    private func persistComposerDraft() {
        ComposerDraftStore.shared.save(
            draftMessage,
            server: server,
            sessionID: session.sessionId ?? session.id
        )
    }

    private func handleComposerHeightChange(_ height: CGFloat) {
        guard abs(composerHeight - height) > 0.5 else { return }

#if DEBUG
        let previousComposerHeight = composerHeight
        if height > 100, hasLoggedComposerCollapseForResize {
            hasLoggedComposerCollapseForResize = false
        }
#endif
        if !isComposerResizing {
            composerResizeFollowIntent = shouldFollowLatestMessage
        }
        composerHeight = height
        isComposerResizing = true
#if DEBUG
        if previousComposerHeight > 100,
           height <= 100,
           !hasLoggedComposerCollapseForResize {
            hasLoggedComposerCollapseForResize = true
            logChatScrollBoundary(event: "composer_collapse", decision: "height_decreased")
        }
#endif
        composerResizeGeneration &+= 1
        let generation = composerResizeGeneration

        composerResizeTask?.cancel()
        composerResizeTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled, generation == composerResizeGeneration else { return }

            let shouldFollow = ChatScrollPolicy.shouldFollowAfterComposerResize(
                wasFollowingLatest: composerResizeFollowIntent && shouldFollowLatestMessage,
                isUserInteracting: isUserInteractingWithScroll
            )
            composerResizeFollowIntent = false
            composerResizeTask = nil
            isComposerResizing = false

            guard shouldFollow else { return }
            shouldAnimateNextFollowAfterComposerResize = true
            followRejoinScrollToken += 1
        }
    }

    private func persistTranscriptRestore() {
        guard !transcriptRestoreOutcomeState.preservesDurableTarget else { return }
        guard didRequestTranscriptRestore || didInteractBeforeTranscriptRestore else {
            // The durable point remains authoritative until appearance
            // restoration has initialized local state or the user makes a
            // real gesture.
            return
        }
        viewModel.rememberTranscriptRestorePoint(
            followingLatest: shouldFollowLatestMessage,
            // Persist only the row identity, not the high-frequency scroll offset.
            // Reopening a reader's position then uses the same stable render ID
            // without adding a scroll-position binding to ChatView.
            visibleMessageID: visibleTranscriptRowID
        )
    }

    private func requestTranscriptRestoreIfNeeded() {
        guard !didRequestTranscriptRestore else { return }
        guard !viewModel.messages.isEmpty else { return }
        didRequestTranscriptRestore = true
        let restoreTarget = viewModel.transcriptRestoreTarget
        pendingTranscriptRestoreMessageID = Self.savedTranscriptVisibleMessageID(from: restoreTarget)
        isTranscriptRestorePending = pendingTranscriptRestoreMessageID != nil
        guard ChatTranscriptRestorePolicy.shouldStartRestore(
            hasMessages: true,
            hasUserInteractedBeforeRestore: didInteractBeforeTranscriptRestore
        ) else {
            isTranscriptRestorePending = false
            pendingTranscriptRestoreMessageID = nil
            return
        }

#if DEBUG
        let previousFollowLatest = shouldFollowLatestMessage
#endif
        shouldFollowLatestMessage = viewModel.savedFollowingLatest
#if DEBUG
        logChatScrollBoundary(
            event: "follow_state_transition",
            decision: "restore_saved_follow_intent",
            previousFollowLatest: previousFollowLatest
        )
#endif
        restoreScrollToken += 1
        transcriptRestoreOutcomeState.begin(ChatTranscriptRestoreRequest(
            scope: viewModel.outgoingInsertionScope,
            generation: restoreScrollToken,
            target: restoreTarget
        ))
#if DEBUG
        logTranscriptRestoreBoundary(
            event: "transcript_restore_request",
            decision: "saved_target_requested"
        )
#endif
    }

    private func updateScrollMetrics(_ metrics: ChatScrollMetrics) {
#if DEBUG
        let previousFollowLatest = shouldFollowLatestMessage
#endif
        if metrics.isDirectlyInteracting {
            transcriptRestoreOutcomeState.acceptUserIntent()
            didInteractBeforeTranscriptRestore = true
            isTranscriptRestorePending = false
            pendingTranscriptRestoreMessageID = nil
        }

        let isStreaming = viewModel.activeStreamID != nil
        let isNearBottomForMotionNow = max(0, metrics.distanceFromBottom) <= nearbyBottomMotionDistance
        if isNearBottomForMotion != isNearBottomForMotionNow {
            isNearBottomForMotion = isNearBottomForMotionNow
        }
        let isNearBottom = ChatScrollPolicy.isNearBottom(
            distanceFromBottom: max(0, metrics.distanceFromBottom),
            isStreaming: isStreaming
        )
        isScrolledNearBottom = isNearBottom

        // Direct touch is a new user decision, even if a stale geometry sample
        // still says that the tail is visible. Inherited deceleration belongs to
        // the explicit jump and must not create a fresh follow cooldown.
        let wasExplicitBottomScrollActive = isExplicitBottomScrollActive
        let wasExplicitBottomDecelerationActive = isExplicitBottomDecelerationActive
        var cancelledExplicitBottomScroll = false

        isExplicitBottomDecelerationActive = ChatScrollPolicy.nextExplicitBottomDecelerationContext(
            wasExplicitBottomScrollActive: wasExplicitBottomScrollActive,
            wasExplicitBottomDecelerationActive: wasExplicitBottomDecelerationActive,
            isDirectlyInteracting: metrics.isDirectlyInteracting,
            isDecelerating: metrics.isDecelerating
        )

        let isExplicitBottomScrollContext = wasExplicitBottomScrollActive
            || wasExplicitBottomDecelerationActive
        let isEffectiveUserInteraction = ChatScrollPolicy.isEffectiveUserInteraction(
            isUserInteracting: metrics.isUserInteracting,
            isDirectlyInteracting: metrics.isDirectlyInteracting,
            isDecelerating: metrics.isDecelerating,
            isExplicitBottomScrollContext: isExplicitBottomScrollContext
        )
        isUserInteractingWithScroll = isEffectiveUserInteraction

        guard ChatTranscriptRestorePolicy.shouldApplyScrollMetricsBeforeRestore(
            hasRequestedRestore: didRequestTranscriptRestore,
            hasPendingMessageRestore: isTranscriptRestorePending,
            hasUserInteractedBeforeRestore: didInteractBeforeTranscriptRestore,
            isDirectlyInteracting: metrics.isDirectlyInteracting
        ) else {
            return
        }

        if isExplicitBottomScrollActive {
            if ChatScrollPolicy.shouldCancelExplicitBottomRequest(
                isDirectlyInteracting: metrics.isDirectlyInteracting,
                isDecelerating: metrics.isDecelerating
            ) {
                cancelExplicitBottomScroll()
                cancelledExplicitBottomScroll = true
            } else if ChatScrollPolicy.shouldFinishExplicitBottomRequest(
                isNearBottom: isNearBottom,
                isTailVisible: isLatestTranscriptRowVisible || isTranscriptBottomVisible,
                hasIssuedScroll: hasIssuedExplicitBottomScroll
            ) {
                completeExplicitBottomScroll()
            }
        }

        let confirmedNearBottom = !cancelledExplicitBottomScroll && isNearBottom && (
            !isExplicitBottomScrollActive || isLatestTranscriptRowVisible || isTranscriptBottomVisible
        )

        // Touching the scroll view pauses auto-follow for a short window so
        // streaming layout growth cannot yank the viewport mid-gesture.
        if ChatScrollPolicy.shouldRecordUserScrollCooldown(
            isUserInteracting: metrics.isUserInteracting,
            isDirectlyInteracting: metrics.isDirectlyInteracting,
            isDecelerating: metrics.isDecelerating,
            isExplicitBottomScrollContext: isExplicitBottomScrollContext
        ) {
            followScrollGeneration += 1
            userScrollCooldownUntil = ChatScrollPolicy.cooldownDeadline()
        }

        if confirmedNearBottom {
            if ChatScrollPolicy.shouldSnapWhenRejoiningLatest(
                wasFollowingLatest: shouldFollowLatestMessage,
                isNearBottom: true
            ) {
                followRejoinScrollToken += 1
            }
            shouldFollowLatestMessage = true
            if isReadingOlderTranscript {
                withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                    isReadingOlderTranscript = false
                }
            }
        } else if isEffectiveUserInteraction {
            shouldFollowLatestMessage = false
            if !isReadingOlderTranscript,
               ChatScrollPolicy.shouldEnterReadingOlder(
                   distanceFromBottom: metrics.distanceFromBottom,
                   isStreaming: isStreaming
               ) {
                withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                    isReadingOlderTranscript = true
                }
            }
        }
#if DEBUG
        if previousFollowLatest != shouldFollowLatestMessage {
            logChatScrollBoundary(
                event: "follow_state_transition",
                decision: shouldFollowLatestMessage ? "metrics_confirmed_near_bottom" : "metrics_effective_user_interaction",
                previousFollowLatest: previousFollowLatest,
                metrics: metrics
            )
        }
#endif
    }

    private var isAutoFollowScrollPaused: Bool {
        ChatScrollPolicy.isAutoScrollPaused(
            isUserInteracting: isUserInteractingWithScroll,
            cooldownUntil: userScrollCooldownUntil
        )
    }

    private static func savedTranscriptVisibleMessageID(
        from target: ChatTranscriptRestoreTarget
    ) -> String? {
        guard case let .message(id) = target else { return nil }
        return id
    }

    private func prepareTranscriptForExplicitSend() {
        transcriptRestoreOutcomeState.acceptUserIntent()
        didInteractBeforeTranscriptRestore = true
        isTranscriptRestorePending = false
        pendingTranscriptRestoreMessageID = nil
        transcriptRestoreCancellationToken &+= 1
#if DEBUG
        let previousFollowLatest = shouldFollowLatestMessage
#endif
        shouldFollowLatestMessage = true
        userScrollCooldownUntil = nil
        followScrollGeneration += 1
#if DEBUG
        logChatScrollBoundary(
            event: "follow_state_transition",
            decision: "explicit_send",
            previousFollowLatest: previousFollowLatest
        )
#endif
        if isReadingOlderTranscript {
            withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                isReadingOlderTranscript = false
            }
        }
    }

    private func beginEditMessage(_ context: MessageActionContext) {
        editDraft = context.copyText
        editContext = context
        let messagesAfter = transcriptMessagesAfter(context)
        if messagesAfter > 0 {
            showEditDiscardConfirmation = true
        } else {
            showEditSheet = true
        }
    }

    private func submitEdit(_ context: MessageActionContext) async {
        editContext = nil
        showEditDiscardConfirmation = false

        let success = await viewModel.editMessage(context, newText: editDraft, modelContext: modelContext)

        if success {
            editDraft = ""
        }

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func beginRegenerateResponse(_ context: MessageActionContext) {
        regenerateContext = context
        let messagesAfter = transcriptMessagesAfter(context)
        if messagesAfter > 0 {
            showRegenerateDiscardConfirmation = true
        } else {
            Task { await submitRegenerate(context) }
        }
    }

    private func submitRegenerate(_ context: MessageActionContext) async {
        regenerateContext = nil
        showRegenerateDiscardConfirmation = false

        _ = await viewModel.regenerateAssistantResponse(context, modelContext: modelContext)

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private var editDiscardWarningMessage: String {
        guard let context = editContext else { return "" }
        let messagesAfter = transcriptMessagesAfter(context)
        return String(localized: "Editing this message will discard \(messagesAfter) later messages.")
    }

    private var regenerateDiscardWarningMessage: String {
        guard let context = regenerateContext else { return "" }
        let messagesAfter = transcriptMessagesAfter(context)
        return String(localized: "Regenerating this response will discard \(messagesAfter) later messages.")
    }

    private var profileSwitchWarningMessage: String {
        guard let profile = pendingProfileSelection else {
            return String(localized: "Switching profiles starts a separate session so this transcript is not retagged.")
        }

        return String(localized: "Switch to \(profile.displayName) and start a new session. This keeps the current transcript on its original profile.")
    }

    private func transcriptMessagesAfter(_ context: MessageActionContext) -> Int {
        guard let index = transcriptMessages.firstIndex(where: { $0.id == context.messageID }) else {
            return 0
        }

        return max(0, transcriptMessages.count - 1 - index)
    }
}

/// A scroll-edge fade, not a separate header panel. It protects the status bar
/// and floating identity without changing transcript layout or intercepting taps.
private struct ChatHeaderReadabilityBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        let canvas = SemrehVisualTheme.canvas(for: colorScheme, palette: palette)
        LinearGradient(
            stops: [
                .init(color: canvas.opacity(0.98), location: 0),
                .init(color: canvas.opacity(0.94), location: 0.45),
                .init(color: canvas.opacity(0.70), location: 0.75),
                .init(color: canvas.opacity(0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct ChatBotDetailsView: View {
    let profile: ProfileSummary?
    let profileTitle: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Profile") {
                LabeledContent("Name", value: profile?.displayName ?? profileTitle)
                if let provider = nonEmpty(profile?.provider) {
                    LabeledContent("Provider", value: provider)
                }
                if let model = nonEmpty(profile?.model) {
                    LabeledContent("Model", value: model)
                }
            }

            if let profile {
                Section("Available metadata") {
                    if let gatewayRunning = profile.gatewayRunning {
                        LabeledContent("Gateway", value: gatewayRunning ? "Running" : "Stopped")
                    }
                    if let hasEnv = profile.hasEnv {
                        LabeledContent("Environment", value: hasEnv ? "Configured" : "Not configured")
                    }
                    if let skillCount = profile.skillCount {
                        LabeledContent("Skills", value: String(skillCount))
                    }
                    if profile.isDefault == true {
                        LabeledContent("Server default", value: "Yes")
                    }
                    if profile.isActive == true {
                        LabeledContent("Active profile", value: "Yes")
                    }
                }
            }
        }
        .navigationTitle(profileTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .scrollContentBackground(.hidden)
        .background { SemrehBackdrop().ignoresSafeArea() }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ChatToolbarTitleLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if showsSubtitle, let subtitle {
                Text(subtitle)
                    .font(AppFont.caption2())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var showsSubtitle: Bool {
        !dynamicTypeSize.isAccessibilitySize
    }

    private var accessibilityLabel: String {
        guard let subtitle else { return title }
        return "\(title), \(subtitle)"
    }
}

struct ChatToolbarActionCluster<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
        .modifier(LegacyToolbarClusterStyle())
        .accessibilityElement(children: .contain)
    }
}

/// On iOS 26+ the navigation toolbar already renders this trailing item inside a
/// Liquid Glass pill, so styling the cluster ourselves stacked a second capsule
/// and produced the double border reported in #333. Below iOS 26 the system
/// supplies no pill, so we keep the original material capsule there.
private struct LegacyToolbarClusterStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .background(
                    Color(.secondarySystemBackground).opacity(colorScheme == .dark ? 0.24 : 0.42),
                    in: Capsule()
                )
                .adaptiveGlass(
                    .regular,
                    isInteractive: false,
                    fallbackMaterial: .ultraThinMaterial,
                    in: Capsule()
                )
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color(.separator).opacity(colorScheme == .dark ? 0.38 : 0.24), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct ChatToolbarActionSlot<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .labelStyle(.iconOnly)
            .font(.body)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

enum ChatToolbarSubtitleResolver {
    static func subtitle(workspacePath: String?, profileTitle: String?) -> String? {
        if let workspace = nonEmpty(workspacePath) {
            return workspace.lastPathComponentFallback
        }

        guard let profile = nonEmpty(profileTitle), profile != "Profile" else {
            return nil
        }

        return profile
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct PastedFile: Sendable {
    let data: Data
    let filename: String
}

enum PastedFileLoader {
    static func load(from url: URL, suggestedName: String?) async throws -> PastedFile {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        try Task.checkCancellation()
        let file = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent.isEmpty
                ? suggestedName ?? "pasted-file"
                : url.lastPathComponent
            return PastedFile(data: data, filename: filename)
        }.value
        try Task.checkCancellation()
        return file
    }
}

private enum PastedFileError: LocalizedError {
    case unreadableURL
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unreadableURL:
            String(localized: "Could not read the pasted file.")
        case .unreadableImage:
            String(localized: "Could not read the pasted image.")
        }
    }
}

private extension SlashCommandExecutionResult {
    var isSuccessfulSubmission: Bool {
        switch self {
        case .executed, .openedSession, .openedDirectBranch:
            true
        case .sendAsMessage, .unsupported, .needsSubArg:
            false
        }
    }
}
