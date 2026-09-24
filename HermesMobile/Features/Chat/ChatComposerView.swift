import SwiftUI
import UIKit
import PhotosUI

private struct ComposerStatusView: View {
    let text: String
    let isError: Bool
    let isDismissible: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(AppFont.caption())
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isDismissible {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(AppFont.caption(weight: .bold))
                        .foregroundStyle(textColor)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss attachment error")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
    }

    private var textColor: Color {
        isError ? Color(.label) : Color.secondary
    }

    private var backgroundColor: Color {
        isError ? Color.red.opacity(0.08) : Color(.secondarySystemBackground)
    }

    private var borderColor: Color {
        isError ? Color.red.opacity(0.25) : Color(.separator).opacity(0.25)
    }
}

/// Enablement matrix for the composer "+" attach menu (item 5 of the 2026-09-18
/// app-chat UX scope).
///
/// The "+" used to be disabled for the entire duration of any run because the
/// configuration matrix includes `isWaitingForStream`. Attachments are
/// read-only inputs that queue like a send (the recording precedent: "Recording
/// mid-stream is fine (it queues like any send)"), so the attach menu
/// deliberately ignores the streaming state. It keeps only the gates that mean
/// the transcript cannot accept new content at all: cached/offline read-only,
/// an in-flight send, session compression, or a configuration update. The SEND
/// action keeps its own (stricter) gate.
enum ChatComposerAttachPolicy {
    static func isAttachMenuDisabled(
        isOfflineReadOnly: Bool,
        isSending: Bool,
        isCompressingSession: Bool,
        isUpdatingConfiguration: Bool
    ) -> Bool {
        isOfflineReadOnly || isSending || isCompressingSession || isUpdatingConfiguration
    }
}

struct MessageComposerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette
    @Environment(\.appAccent) private var accent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @ScaledMetric(relativeTo: .footnote) private var actionIconSize: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var actionButtonSize: CGFloat = 30
    @ScaledMetric(relativeTo: .title3) private var plusIconSize: CGFloat = 24
    @ScaledMetric(relativeTo: .title3) private var plusButtonSize: CGFloat = 44

    @Binding var draftMessage: String
    @Binding var isFocused: Bool
    let isSending: Bool
    let isCompressingSession: Bool
    let isWaitingForStream: Bool
    let isCancellingStream: Bool
    let isOfflineReadOnly: Bool
    let isChromeCompact: Bool
    let errorMessage: String?
    let configurationErrorMessage: String?
    let configurationDiagnosticCode: String?
    let contextWindowSnapshot: ContextWindowSnapshot?
    let gitViewModel: GitWorkspaceAvailabilityViewModel
    let modelGroups: [ModelCatalogGroup]
    let selectedModelID: String?
    let selectedModelProviderID: String?
    let selectedModelTitle: String
    let allowsModelChanges: Bool
    let allowsModelAndWorkspaceChanges: Bool
    let isModelChangeDeferred: Bool
    let modelConfirmationMessage: String?
    let workspaceRoots: [WorkspaceRoot]
    let selectedWorkspacePath: String?
    let workspaceSuggestions: [String]
    /// Server base URL for the workspace-registry manager; nil hides the
    /// Manage affordance in the workspace picker.
    let workspaceManagementServer: URL?
    let workspaceManagementProfile: String
    let skillSuggestions: [SkillSlashSuggestion]
    let agentCommands: [AgentCommand]
    let profileOptions: [ProfileSummary]
    let isSingleProfileMode: Bool
    let selectedProfileName: String?
    let selectedProfileTitle: String
    let isLoadingModels: Bool
    let selectedReasoningEffort: String?
    /// Model-aware effort vocabulary; `nil` → full static list (issue #18).
    let supportedReasoningEfforts: [String]?
    /// Draft inheritance and legacy override clearing are distinct from the
    /// direct gateway's explicit per-session effort choices.
    let allowsReasoningInheritance: Bool
    let allowsReasoningChangesWhileStreaming: Bool
    let isReasoningChangeDeferred: Bool
    /// When false the model has no effort control — hide the reasoning menu.
    let showsReasoningControl: Bool
    let reasoningUnavailableMessage: String
    let isUpdatingConfiguration: Bool
    let pendingAttachments: [PendingAttachment]
    /// Optional direct-mode projection. Legacy callers may continue supplying
    /// `pendingAttachments`; when this is empty they are mapped locally below.
    var displayAttachments: [ComposerAttachmentDisplayItem] = []
    let isUploadingAttachment: Bool
    let attachmentUploadCount: Int
    let attachmentUploadGeneration: Int
    let isSendingVoiceNote: Bool
    /// When true, dictation auto-starts once this composer appears with the app active —
    /// the "New Chat with Voice" App Intent (#338). Defaults to false for normal composers.
    let autoStartsVoiceInput: Bool
    let apiClient: APIClient?
    var voiceInputProfileName: String = "default"
    var currentVoiceInputProfile: (() -> String)? = nil
    let uploadAttachmentErrorMessage: String?
    let onSend: () -> Void
    let onSendVoiceNote: (Data, String) -> Void
    let onCancel: () -> Void
    let onSelectModel: (ModelCatalogOption) -> Void
    let onConfirmModelSelection: () async -> Void
    let onCancelModelSelection: () -> Void
    let onModelPickerOpen: () async -> Void
    let onLoadWorkspaceSuggestions: (String) async -> Void
    let onWorkspaceRegistryChanged: () async -> Void
    let onLoadSkillSuggestions: () async -> Void
    let onSelectWorkspace: (String) async -> Void
    let onSelectProfile: (ProfileSummary) -> Void
    let onSelectReasoningEffort: (String) -> Void
    let onHeightChange: (CGFloat) -> Void
    let onPhotoItemSelected: (PhotosPickerItem) -> Void
    let onFileURLsSelected: ([URL]) -> Void
    let onPasteFileProviders: ([NSItemProvider]) -> Void
    let onPasteFileURLs: ([URL]) -> Void
    let onPasteImageProviders: ([NSItemProvider]) -> Void
    let onPasteImages: ([UIImage]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onPreviewAttachment: (PendingAttachment) -> Void
    /// Direct-mode owner supplies this callback when it needs the projection's
    /// local bytes/metadata. Legacy call sites can omit it.
    var onPreviewDisplayAttachment: ((ComposerAttachmentDisplayItem) -> Void)? = nil
    let onDismissUploadAttachmentError: () -> Void
    let onSelectGitBranch: (GitCheckoutTarget) -> Void
    let onCreateGitBranch: (GitCheckoutTarget) -> Void
    let onRefreshGitBranches: () -> Void
    var controlsPresentation: Binding<Bool>? = nil
    var onStartNewChat: (() -> Void)? = nil
    var workspacePickerRequest = 0
    var gitBranchPickerRequest = 0

    @State private var textFieldHeight: CGFloat = 0
    @State private var textInputHeight: CGFloat = 22
    @State private var noticeMessage: String?
    @State private var showsAllModelsSheet = false
    @State private var showsConfigurationModelPicker = false
    @State private var showsModelConfirmation = false
    @State private var pendingConfigurationProfile: ProfileSummary?
    @State private var startsNewChatAfterControlsDismiss = false
    @State private var showsWorkspaceSheet = false
    @State private var showsGitBranchSheet = false
    @State private var optimisticWorkspacePath: String?
    @State private var favoriteModelKeys = ModelFavoritesStore.shared.favoriteKeys
    @State private var recentModelKeys = ModelRecentsStore.shared.recentKeys
    @State private var keyboardIsVisible = false
    @State private var shouldRestoreFocusAfterPresentation = false
    @State private var deferredUploadFocusPhase: DeferredUploadFocusPhase = .none
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var showFileImporter = false
    @State private var voiceInput = ComposerVoiceInputController()
    @State private var voiceNoteRecorder = ComposerVoiceNoteRecorder()
    @State private var voiceNoteCancelArmed = false
    @State private var didAutoStartVoiceInput = false
    @AppStorage(ComposerSTTProviderPreference.storageKey) private var sttProviderPreferenceRawValue = ComposerSTTProviderPreference.defaultValue.rawValue
    @AppStorage(SectionVisibilitySettings.chatGitKey) private var showsGitControls = true

    private enum DeferredUploadFocusPhase: Equatable {
        case none
        case waitingForUploadStart(afterGeneration: Int)
        case waitingForUploadsToFinish
    }

    private var showsSlashAutocomplete: Bool {
        let query = draftMessage.drop(while: { $0.isWhitespace })
        guard query.hasPrefix("/") else { return false }

        let parsed = ParsedSlashQuery(query: draftMessage)
        if let command = parsed.command,
           command.subArgs == .none,
           hasWhitespaceAfterSlashCommand(command.name, in: String(query)) {
            return false
        }

        if SlashSkillFormatter.skill(named: parsed.commandName, in: skillSuggestions) != nil,
           hasWhitespaceAfterSlashCommand(parsed.commandName, in: String(query)) {
            return false
        }

        if AgentSlashCommandSuggestion.command(named: parsed.commandName, in: agentCommands) != nil,
           hasWhitespaceAfterSlashCommand(parsed.commandName, in: String(query)) {
            return false
        }

        if parsed.commandName.lowercased() == "skills",
           SlashSkillFormatter.invocation(from: parsed.argQuery, suggestions: skillSuggestions) != nil {
            return false
        }

        if parsed.command?.subArgs == .goalActions,
           parsed.isSubArgMode,
           !parsed.argQuery.isEmpty,
           !SlashCommandCatalog.goalActions.contains(where: {
               $0.hasPrefix(parsed.argQuery.lowercased())
           }) {
            return false
        }

        return true
    }

    private func hasWhitespaceAfterSlashCommand(_ commandName: String, in query: String) -> Bool {
        let prefix = "/\(commandName)"
        guard query.lowercased().hasPrefix(prefix.lowercased()) else { return false }
        let afterCommand = query.dropFirst(prefix.count)
        return afterCommand.first?.isWhitespace == true
    }

    private var parsedSlashQuery: ParsedSlashQuery {
        ParsedSlashQuery(query: draftMessage)
    }

    private var slashAutocompleteLoadKey: String {
        guard showsSlashAutocomplete,
              let command = parsedSlashQuery.command
        else {
            return showsSlashAutocomplete ? "skills" : ""
        }

        guard parsedSlashQuery.isSubArgMode else {
            return "skills"
        }

        switch command.subArgs {
        case .workspaces:
            return "workspace:\(parsedSlashQuery.argQuery)"
        case .personalities:
            return "personalities"
        case .skills:
            return "skills"
        case .models, .reasoningLevels, .goalActions, .none:
            return ""
        }
    }

    private var attachmentDisplayItems: [ComposerAttachmentDisplayItem] {
        displayAttachments.isEmpty
            ? pendingAttachments.map(ComposerAttachmentDisplayItem.init(pending:))
            : displayAttachments
    }

    var body: some View {
        let composer = AnyView(
            AdaptiveGlassContainer(spacing: 6) {
                VStack(spacing: 6) {
                if voiceNoteRecorder.isRecording {
                    ComposerVoiceRecordingBar(
                        recorder: voiceNoteRecorder,
                        isCancelArmed: voiceNoteCancelArmed,
                        onStop: { finishVoiceNote(translationHeight: 0) },
                        onCancel: cancelVoiceNote
                    )
                    .padding(.horizontal, 16)
                } else if let voiceNoteStatus {
                    ComposerVoiceStatusView(status: voiceNoteStatus)
                } else if let voiceStatus, !voiceInput.isListening {
                    ComposerVoiceStatusView(status: voiceStatus)
                } else if let composerStatus {
                    ComposerStatusView(
                        text: composerStatus.text,
                        isError: composerStatus.isError,
                        isDismissible: composerStatus.isDismissible,
                        onDismiss: onDismissUploadAttachmentError
                    )
                }

                Group {
                    if showsSlashAutocomplete {
                        SlashCommandAutocompleteView(
                            query: draftMessage,
                            selectedModelID: selectedModelID,
                            modelGroups: modelGroups,
                            workspaceRoots: workspaceRoots,
                            workspaceSuggestions: workspaceSuggestions,
                            skillSuggestions: skillSuggestions,
                            agentCommands: agentCommands,
                            selectedReasoningEffort: selectedReasoningEffort,
                            supportedReasoningEfforts: supportedReasoningEfforts,
                            onSelectCommand: { command in
                                draftMessage = "/\(command.name) "
                            },
                            onSelectSkillCommand: { skill in
                                draftMessage = "/\(skill.slashName) "
                            },
                            onSelectAgentCommand: { command in
                                draftMessage = "/\(command.name) "
                            },
                            onSelectSkillSubArg: { skill in
                                draftMessage = "/skills \(skill.slashName) "
                            },
                            onSelectSubArg: { subArg in
                                let parsed = ParsedSlashQuery(query: draftMessage)
                                draftMessage = "/\(parsed.commandName) \(subArg)"
                            },
                            onDismiss: {
                                draftMessage = ""
                            }
                        )
                        .padding(.horizontal)
                        .transition(ChatMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
                    }
                }
                .animation(ChatMotion.quickState(reduceMotion: reduceMotion), value: showsSlashAutocomplete)

                HStack(alignment: isComposerExpanded ? .bottom : .center, spacing: 8) {
                    composerPlusMenu
                        .adaptiveGlass(.regular, isInteractive: true,
                                       fallbackMaterial: .ultraThinMaterial, in: Circle())

                    VStack(spacing: 0) {
                        ComposerAttachmentStripView(
                            attachments: attachmentDisplayItems,
                            onRemove: onRemoveAttachment,
                            onPreview: { item in
                                if let onPreviewDisplayAttachment {
                                    onPreviewDisplayAttachment(item)
                                } else if let pending = item.legacyPendingAttachment() {
                                    onPreviewAttachment(pending)
                                }
                            }
                        )

                        if attachmentDisplayItems.contains(where: \.isGenericFileReference) {
                            Text("Will be sent as a file reference. Ask Hermes to inspect it.")
                                .font(.footnote)
                                .foregroundStyle(Color(.secondaryLabel))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 4)
                        }

                        if voiceInput.isListening {
                            ComposerVoiceLiveStatusView(input: voiceInput)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                        }

                        HStack(alignment: isComposerExpanded ? .bottom : .center, spacing: 2) {
                            ComposerTextInputView(
                                text: $draftMessage,
                                isFocused: $isFocused,
                                inputHeight: $textInputHeight,
                                measuredHeight: $textFieldHeight,
                                isDisabled: isOfflineReadOnly,
                                isKeyboardSendEnabled: !showsStopButton && !isActionButtonDisabled,
                                verticalPadding: textFieldVerticalPadding,
                                onKeyboardSend: actionButtonTapped,
                                onPasteFileProviders: onPasteFileProviders,
                                onPasteFileURLs: onPasteFileURLs,
                                onPasteImageProviders: onPasteImageProviders,
                                onPasteImages: onPasteImages
                            )

                            ComposerVoiceControlButton(
                                isListening: voiceInput.isListening,
                                isDisabled: isVoiceInputDisabled,
                                color: metaControlColor,
                                isRecordingVoiceNote: voiceNoteRecorder.isRecording,
                                onTap: toggleVoiceInput,
                                onRecordingStart: startVoiceNoteRecording,
                                onRecordingDragChanged: { height in
                                    voiceNoteCancelArmed = ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: height)
                                },
                                onRecordingEnd: { height in
                                    finishVoiceNote(translationHeight: height)
                                }
                            )

                            if showsStopButton || !trimmedDraftMessage.isEmpty || !attachmentDisplayItems.isEmpty || isSending {
                                Button(action: actionButtonTapped) {
                                    actionButtonLabel
                                        .frame(width: actionButtonSize, height: actionButtonSize)
                                        .background(actionButtonBackground)
                                        .foregroundStyle(actionButtonForeground)
                                        .clipShape(Circle())
                                        .chatMinimumHitTarget(in: Circle())
                                }
                                .buttonStyle(.chatTactile(.icon))
                                .disabled(isActionButtonDisabled)
                                .accessibilityLabel(showsStopButton ? "Stop response" : "Send")
                            }
                        }
                        .padding(.trailing, 8)
                        .padding(.top, 2)
                        .padding(.bottom, isComposerExpanded ? 8 : 2)
                    }
                    .adaptiveGlass(
                        .regular,
                        isInteractive: true,
                        fallbackMaterial: .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                            .stroke(SemrehVisualTheme.subtleStroke(for: colorScheme, palette: palette), lineWidth: 0.8)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                }
            }
        )
        let composerWithControls = composer
            .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        onHeightChange(proxy.size.height)
                    }
                    .onChange(of: proxy.size.height) { _, newHeight in
                        onHeightChange(newHeight)
                    }
            }
            )
            .task(id: slashAutocompleteLoadKey) {
            await loadSlashAutocompleteSubArgsIfNeeded()
            }
            .task {
            // Cold path: the composer appears already active (the usual case for the
            // "New Chat with Voice" intent once its session is created) — start here.
            autoStartVoiceInputIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                voiceInput.stopBeforeSubmittingDraft()
                // Backgrounding stops the recorder's run-loop ticker, so cancel
                // the in-flight recording rather than leave it silently stalled.
                cancelVoiceNote()
            } else {
                // An intent that opened this composer may have foregrounded the app
                // a beat after it appeared; auto-start once we're active (#338).
                autoStartVoiceInputIfNeeded()
            }
            }
            .onChange(of: voiceInputProfileName) { _, _ in
            voiceInput.stopBeforeSubmittingDraft()
            }
            .onChange(of: voiceNoteRecorder.elapsed) { _, elapsed in
            // Enforce the max-duration cap: auto-stop and send (not cancel) once
            // the clip hits the limit, mirroring a finger release.
            if voiceNoteRecorder.isRecording, elapsed >= ComposerVoiceNoteRecorder.maximumDuration {
                finishVoiceNote(translationHeight: 0)
            }
            }
            .sheet(isPresented: controlsPresentation ?? $showsAllModelsSheet, onDismiss: finishControlsDismissal) {
            controlsSheetContent
            }
            .toolbar {
            if controlsPresentation == nil {
              ToolbarItemGroup(placement: .topBarTrailing) {
                gitBranchPicker
                intelligenceOptionsButton
                chatOptionsMenu
              }
            }
            }
            .onChange(of: controlsPresentation?.wrappedValue) { _, presented in
            if presented == true { prepareForComposerPresentation() }
            }
            .onChange(of: workspacePickerRequest) { _, _ in
            guard allowsModelAndWorkspaceChanges else { return }
            prepareForComposerPresentation()
            showsWorkspaceSheet = true
            }
            .onChange(of: gitBranchPickerRequest) { _, _ in
            prepareForComposerPresentation()
            showsGitBranchSheet = true
            }
            .sheet(isPresented: $showsGitBranchSheet, onDismiss: restoreFocusAfterPresentationIfNeeded) {
            gitBranchSheetContent
            }
            .sheet(isPresented: $showsWorkspaceSheet, onDismiss: restoreFocusAfterPresentationIfNeeded) {
            workspaceSheetContent
            }
        let composerWithImporter = composerWithControls
            .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                if !urls.isEmpty {
                    deferFocusRestoreUntilUploadCompletes()
                }
                onFileURLsSelected(urls)
            case let .failure(error):
                if isFileImporterCancellation(error) {
                    restoreFocusAfterPresentationDismissalSettles()
                    return
                }

                shouldRestoreFocusAfterPresentation = false
                deferredUploadFocusPhase = .none
                noticeMessage = error.localizedDescription
            }
        }
        let composerWithAlert = composerWithImporter
            .alert(
            "Composer Option",
            isPresented: Binding(
                get: { noticeMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        noticeMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                noticeMessage = nil
            }
        } message: {
            Text(noticeMessage ?? "")
        }
        return composerWithAlert
            .onChange(of: selectedWorkspacePath) { _, newValue in
            if optimisticWorkspacePath == newValue {
                optimisticWorkspacePath = nil
            }
        }
        .onChange(of: isUpdatingConfiguration) { _, isUpdating in
            if !isUpdating {
                optimisticWorkspacePath = nil
            }
        }
        .onChange(of: configurationErrorMessage) { _, newValue in
            if newValue != nil {
                optimisticWorkspacePath = nil
            }
        }
        .onChange(of: showPhotoPicker) { _, isPresented in
            if !isPresented, selectedPhotoItems.isEmpty {
                restoreFocusAfterPresentationDismissalSettles()
            }
        }
        .onChange(of: showFileImporter) { _, isPresented in
            if !isPresented {
                restoreFocusAfterPresentationDismissalSettles()
            }
        }
        .onChange(of: attachmentUploadGeneration) { _, newGeneration in
            handleDeferredUploadStart(newGeneration)
        }
        .onChange(of: attachmentUploadCount) { _, newCount in
            handleDeferredUploadCountChange(newCount)
        }
        .onChange(of: uploadAttachmentErrorMessage) { _, newValue in
            if newValue != nil {
                deferredUploadFocusPhase = .none
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
        }
        .onDisappear {
            voiceInput.stopBeforeSubmittingDraft()
            cancelVoiceNote()
        }
        .padding(.bottom, keyboardIsVisible ? 10 : 0)
    }

    private var controlsSheetContent: some View {
        NavigationStack {
            ScrollView {
                chatControlsHeader.padding(20)
            }
            .background { SemrehBackdrop().ignoresSafeArea() }
            .navigationTitle("Chat settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismissControls)
                }
            }
            .sheet(isPresented: $showsConfigurationModelPicker) {
                modelPickerSheetContent
            }
        }
        .onChange(of: showsConfigurationModelPicker) { _, presented in
            if !presented && modelConfirmationMessage != nil { showsModelConfirmation = true }
        }
        .onChange(of: modelConfirmationMessage) { _, message in
            if message != nil && !showsConfigurationModelPicker { showsModelConfirmation = true }
        }
        .alert("Confirm model switch", isPresented: $showsModelConfirmation) {
            Button("Cancel") { onCancelModelSelection() }
            Button("Switch model") { Task { await onConfirmModelSelection() } }
        } message: {
            Text(modelConfirmationMessage ?? "")
        }
        .presentationDetents(usesAccessibilityLayout ? [.large] : [.height(580), .large])
        .presentationDragIndicator(.visible)
        .task { await onModelPickerOpen() }
    }

    private func dismissControls() {
        controlsPresentation?.wrappedValue = false
        showsAllModelsSheet = false
    }

    private func finishControlsDismissal() {
        if let profile = pendingConfigurationProfile {
            pendingConfigurationProfile = nil
            shouldRestoreFocusAfterPresentation = false
            onSelectProfile(profile)
        } else if startsNewChatAfterControlsDismiss {
            startsNewChatAfterControlsDismiss = false
            shouldRestoreFocusAfterPresentation = false
            onStartNewChat?()
        } else {
            restoreFocusAfterPresentationIfNeeded()
        }
    }

    private var modelPickerSheetContent: some View {
        ComposerModelPickerSheet(
            modelGroups: modelGroups,
            selectedModelID: selectedModelID,
            selectedModelProviderID: selectedModelProviderID,
            favoriteModelKeys: favoriteModelKeys,
            recentModelKeys: recentModelKeys,
            onSelect: { option in
                selectModel(option)
            },
            onToggleFavorite: { option in
                favoriteModelKeys = ModelFavoritesStore.shared.toggleFavorite(for: option)
            },
            onDeleteSavedCustom: { option in
                favoriteModelKeys = ModelFavoritesStore.shared.removeFavorite(for: option)
                recentModelKeys = ModelRecentsStore.shared.removeRecent(for: option)
            },
            selectionDisabled: isModelControlDisabled
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var gitBranchSheetContent: some View {
        GitBranchPickerSheet(
            branches: gitViewModel.branches,
            currentBranch: gitViewModel.currentBranchName,
            isLoading: gitViewModel.isLoadingBranches,
            isSwitching: gitViewModel.isSwitchingBranch,
            onSelect: { target in
                showsGitBranchSheet = false
                onSelectGitBranch(target)
            },
            onRefresh: onRefreshGitBranches
        )
        .presentationDetents([.medium, .large])
    }

    private var workspaceSheetContent: some View {
        ComposerWorkspacePickerSheet(
            workspaceRoots: workspaceRoots,
            selectedWorkspacePath: displayedWorkspacePath,
            suggestions: workspaceSuggestions,
            managementServer: isOfflineReadOnly ? nil : workspaceManagementServer,
            managementProfile: workspaceManagementProfile,
            onLoadSuggestions: onLoadWorkspaceSuggestions,
            onSelect: { path in
                guard allowsModelAndWorkspaceChanges else { return }
                optimisticWorkspacePath = path
                showsWorkspaceSheet = false
                await onSelectWorkspace(path)
            },
            onRegistryChanged: onWorkspaceRegistryChanged
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var actionButtonLabel: some View {
        if isSending || isCancellingStream || isCompressingSession {
            ProgressView()
                .tint(actionButtonForeground)
                .scaleEffect(0.82)
        } else if showsStopButton {
            Image(systemName: "stop.fill")
                .font(.system(size: actionIconSize, weight: .semibold))
        } else {
            Image(systemName: "arrow.up")
                .font(.system(size: actionIconSize, weight: .semibold))
        }
    }

    private func loadSlashAutocompleteSubArgsIfNeeded() async {
        guard showsSlashAutocomplete else {
            return
        }

        guard parsedSlashQuery.isSubArgMode,
              let command = parsedSlashQuery.command
        else {
            await onLoadSkillSuggestions()
            return
        }

        switch command.subArgs {
        case .workspaces:
            await onLoadWorkspaceSuggestions(parsedSlashQuery.argQuery)
        case .personalities:
            break
        case .skills:
            await onLoadSkillSuggestions()
        case .models, .reasoningLevels, .goalActions, .none:
            break
        }
    }

    private var composerPlusMenu: some View {
        // Match the UIKit menu backer's hit region to the SwiftUI expansion.
        ChatUIKitMenuButton(horizontalPadding: 8, verticalPadding: 8) {
            Image(systemName: "plus")
                .font(.system(size: plusIconSize, weight: .regular))
                .foregroundStyle(metaControlColor)
                .frame(width: plusButtonSize, height: plusButtonSize)
                .chatMinimumHitTarget(in: Circle())
        } menu: {
            composerOptionsMenu()
        }
        .tint(metaControlColor)
        .disabled(isAttachMenuDisabled)
        .accessibilityLabel("Composer options")
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItems, matching: .any(of: [.images, .videos]))
        .onChange(of: selectedPhotoItems) {
            let items = selectedPhotoItems
            guard !items.isEmpty else { return }
            deferFocusRestoreUntilUploadCompletes()
            selectedPhotoItems.removeAll()
            for item in items {
                onPhotoItemSelected(item)
            }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPickerView { image in
                deferFocusRestoreUntilUploadCompletes()
                onPasteImages([image])
            }
            .ignoresSafeArea()
        }
        .onChange(of: showCameraPicker) { _, isPresented in
            if !isPresented {
                restoreFocusAfterPresentationDismissalSettles()
            }
        }
    }

    private func composerOptionsMenu() -> UIMenu {
        UIMenu(title: "", children: [
            UIMenu(
                title: String(localized: "Attach"),
                options: [.displayInline],
                children: [
                    UIAction(
                        title: String(localized: "Attach File"),
                        image: UIImage(systemName: "paperclip")
                    ) { _ in
                        Task { @MainActor in
                            prepareForComposerPresentation()
                            showFileImporter = true
                        }
                    },
                    UIAction(
                        title: String(localized: "Photos"),
                        image: UIImage(systemName: "photo.on.rectangle")
                    ) { _ in
                        Task { @MainActor in
                            prepareForComposerPresentation()
                            showPhotoPicker = true
                        }
                    },
                    UIAction(
                        title: String(localized: "Camera"),
                        image: UIImage(systemName: "camera"),
                        attributes: UIImagePickerController.isSourceTypeAvailable(.camera) ? [] : .disabled
                    ) { _ in
                        Task { @MainActor in
                            prepareForComposerPresentation()
                            showCameraPicker = true
                        }
                    }
                ]
            )
        ])
    }

    private var intelligenceOptionsButton: some View {
        Button {
            prepareForComposerPresentation()
            showsAllModelsSheet = true
        } label: {
            Label("Chat controls", systemImage: "slider.horizontal.3")
        }
        .accessibilityLabel("Chat controls")
    }

    private var chatControlsHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                if let server = workspaceManagementServer,
                   let identity = BirdAvatarIdentity(server: server, profile: selectedProfileName) {
                    BirdAvatarView(identity: identity)
                        .frame(width: 62, height: 62)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedProfileTitle)
                        .font(AppFont.title2(weight: .semibold))
                    Text("Profile & model")
                        .font(AppFont.subheadline())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                if !isSingleProfileMode {
                    Menu {
                        ForEach(profileOptions, id: \.self) { profile in
                            Button {
                                guard profile.normalizedName != selectedProfileName else { return }
                                pendingConfigurationProfile = profile
                                dismissControls()
                            } label: {
                                if profile.normalizedName == selectedProfileName {
                                    Label(profile.displayName, systemImage: "checkmark")
                                } else {
                                    Text(profile.displayName)
                                }
                            }
                        }
                    } label: {
                        configurationRow(
                            allowsModelAndWorkspaceChanges ? "Profile" : "New chat profile",
                            value: selectedProfileTitle,
                            icon: "person.crop.circle",
                            accessory: "chevron.up.chevron.down"
                        )
                    }
                    .disabled(isConfigurationControlDisabled || profileOptions.isEmpty)
                    .accessibilityLabel("Choose profile")
                    .accessibilityValue(selectedProfileTitle)
                    Divider().padding(.leading, 52)
                }
                Button {
                    showsConfigurationModelPicker = true
                } label: {
                    configurationRow("Model", value: selectedModelTitle, icon: "sparkles", accessory: allowsModelChanges ? "chevron.right" : "lock")
                }
                .disabled(!allowsModelChanges || isModelControlDisabled)
                .accessibilityIdentifier("chatControlsModelButton")
                .accessibilityLabel("Model")
                .accessibilityValue(selectedModelTitle)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .adaptiveGlass(.regular, isInteractive: false, fallbackMaterial: .thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            if isModelChangeDeferred {
                Text("Model switch queued for the next turn.")
                    .font(AppFont.subheadline())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chatControlsModelDeferred")
            }

            if !allowsModelAndWorkspaceChanges {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This chat keeps its workspace. You can change its model for the next turn. Changing profiles starts a separate chat so this transcript stays with its original profile.")
                        .font(AppFont.subheadline())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chatControlsConfigurationReadOnly")
                    if onStartNewChat != nil {
                        Button {
                            startsNewChatAfterControlsDismiss = true
                            dismissControls()
                        } label: {
                            Label("New chat with \(selectedProfileTitle)", systemImage: "square.and.pencil")
                                .font(AppFont.subheadline(weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(isConfigurationControlDisabled)
                        .accessibilityIdentifier("chatControlsNewChat")
                    }
                }
            }

            if showsReasoningControl {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Thinking", systemImage: "brain")
                        .font(AppFont.subheadline(weight: .semibold))
                    ComposerReasoningStepControl(
                        supportedEfforts: supportedReasoningEfforts,
                        selectedEffort: selectedReasoningEffort,
                        allowsInheritance: allowsReasoningInheritance,
                        isDisabled: isReasoningControlDisabled,
                        isDeferred: isReasoningChangeDeferred,
                        onSelect: onSelectReasoningEffort
                    )
                    .id("\(selectedModelProviderID ?? "")|\(selectedModelID ?? "")")
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Thinking", systemImage: "brain")
                        .font(AppFont.subheadline(weight: .semibold))
                    Text(reasoningUnavailableMessage)
                        .font(AppFont.subheadline())
                        .foregroundStyle(.secondary)
                    Button("Retry reasoning settings") {
                        Task { await onModelPickerOpen() }
                    }
                    .disabled(isConfigurationControlDisabled)
                }
                .accessibilityIdentifier("chatControlsReasoningUnavailable")
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workspace").font(AppFont.caption(weight: .semibold))
                        Text(selectedWorkspacePath ?? "Default workspace")
                            .font(AppFont.subheadline())
                            .textSelection(.enabled)
                    }
                    if let snapshot = contextWindowSnapshot,
                       let used = snapshot.tokensUsed, used >= 0,
                       let limit = snapshot.contextLength, limit > 0 {
                        Text(ContextWindowFormatter.tokensLabel(from: snapshot) + " tokens")
                        ProgressView(value: min(Double(used) / Double(limit), 1))
                            .accessibilityLabel("Context used")
                            .accessibilityValue(ContextWindowFormatter.tokensLabel(from: snapshot))
                    } else {
                        Text("Context usage unavailable")
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 12)
            } label: {
                Label("Session details", systemImage: "info.circle")
                    .font(AppFont.subheadline())
            }
            if let configurationErrorMessage {
                Text(configurationErrorMessage).font(.caption).foregroundStyle(.secondary)
            }
            if let configurationDiagnosticCode {
                LabeledContent("Diagnostic code") {
                    Text(configurationDiagnosticCode)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Settings diagnostic code")
                .accessibilityValue(configurationDiagnosticCode)
                .accessibilityIdentifier("chatControlsConfigurationDiagnostic")
            }
            if isLoadingModels { ProgressView("Loading settings").font(AppFont.caption()) }
        }
        .tint(.primary)
    }

    private func configurationRow(_ title: String, value: String, icon: String, accessory: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppFont.caption()).foregroundStyle(.secondary)
                Text(value)
                    .font(AppFont.body(weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(title == "Model" ? "chatControlsCurrentModel" : "chatControlsCurrentProfile")
            }
            Spacer(minLength: 8)
            Image(systemName: accessory)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var chatOptionsMenu: some View {
        Menu {
            Section("Workspace") {
                Text(workspaceTitle)
                Button(allowsModelAndWorkspaceChanges ? "Choose workspace path" : "Workspace is read-only", systemImage: "folder") {
                    prepareForComposerPresentation()
                    showsWorkspaceSheet = true
                }
                .disabled(!allowsModelAndWorkspaceChanges || isConfigurationControlDisabled)
            }

        } label: {
            Label("Chat options", systemImage: "ellipsis")
        }
        .accessibilityLabel("Chat options")
    }

    @ViewBuilder
    private var gitBranchPicker: some View {
        // One "Git Actions" toggle covers every git control in chat (#189), so the
        // branch chip goes with the toolbar menu rather than lingering alone.
        if showsGitControls, gitViewModel.hasRepository {
            GitBranchPickerButton(
                currentBranch: gitViewModel.currentBranchName,
                branches: gitViewModel.branches,
                isLoading: gitViewModel.isLoadingBranches,
                isSwitching: gitViewModel.isSwitchingBranch,
                isDisabled: isOfflineReadOnly || isWaitingForStream,
                onSelect: onSelectGitBranch,
                onCreate: onCreateGitBranch,
                onRefresh: onRefreshGitBranches
            )
        }
    }

    private var usesAccessibilityLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private func selectModel(_ option: ModelCatalogOption) {
        guard allowsModelChanges else { return }
        recentModelKeys = ModelRecentsStore.shared.recordRecent(option)
        onSelectModel(option)
    }

    private var composerStatus: (text: String, isError: Bool, isDismissible: Bool)? {
        if isOfflineReadOnly {
            return (String(localized: "Reconnect to send messages."), false, false)
        } else if isWaitingForStream && isCancellingStream {
            return (String(localized: "Stopping response..."), false, false)
        } else if isCompressingSession {
            return (String(localized: "Compressing context..."), false, false)
        } else if let uploadAttachmentErrorMessage {
            return (uploadAttachmentErrorMessage, true, true)
        } else if isSendingVoiceNote {
            return (String(localized: "Sending voice note..."), false, false)
        } else if isUploadingAttachment {
            return (String(localized: "Uploading attachment..."), false, false)
        } else if let errorMessage {
            return (errorMessage, true, false)
        } else if let configurationErrorMessage {
            return (configurationErrorMessage, true, false)
        } else if isUpdatingConfiguration {
            return (String(localized: "Updating composer settings..."), false, false)
        } else if isReasoningChangeDeferred {
            return (String(localized: "Reasoning applies to the next message."), false, false)
        }

        return nil
    }

    private var voiceStatus: ComposerVoiceStatus? {
        switch voiceInput.state {
        case .listening, .serverListening, .transcribing:
            return nil
        case .requestingPermission:
            return ComposerVoiceStatus(
                text: String(localized: "Requesting voice permissions..."),
                systemImage: "mic.badge.plus",
                isError: false
            )
        case .idle:
            break
        }

        if let errorMessage = voiceInput.errorMessage {
            return ComposerVoiceStatus(
                text: errorMessage,
                systemImage: "exclamationmark.triangle",
                isError: true
            )
        }

        return nil
    }

    /// Voice-note status shown above the composer when *not* actively recording
    /// (the recording bar covers that case): the permission prompt and recorder
    /// errors like a denied microphone.
    private var voiceNoteStatus: ComposerVoiceStatus? {
        if voiceNoteRecorder.isRequestingPermission {
            return ComposerVoiceStatus(
                text: String(localized: "Requesting microphone access..."),
                systemImage: "mic.badge.plus",
                isError: false
            )
        }

        if let errorMessage = voiceNoteRecorder.errorMessage {
            return ComposerVoiceStatus(
                text: errorMessage,
                systemImage: "exclamationmark.triangle",
                isError: true
            )
        }

        return nil
    }

    private var metaControlColor: Color {
        Color(.secondaryLabel)
    }

    private var workspaceTitle: String {
        guard let selectedWorkspacePath = displayedWorkspacePath,
              !selectedWorkspacePath.isEmpty
        else {
            return String(localized: "Workspace")
        }

        if let root = workspaceRoots.first(where: { $0.path == selectedWorkspacePath }),
           let name = root.name,
           !name.isEmpty {
            return name
        }

        return selectedWorkspacePath.lastPathComponentFallback
    }

    private var displayedWorkspacePath: String? {
        optimisticWorkspacePath ?? selectedWorkspacePath
    }

    private var isConfigurationControlDisabled: Bool {
        isOfflineReadOnly || isSending || isCompressingSession || isWaitingForStream || isUpdatingConfiguration
    }

    private var isModelControlDisabled: Bool {
        isOfflineReadOnly || isSending || isCompressingSession || isUpdatingConfiguration
    }

    private var isAttachMenuDisabled: Bool {
        ChatComposerAttachPolicy.isAttachMenuDisabled(
            isOfflineReadOnly: isOfflineReadOnly,
            isSending: isSending,
            isCompressingSession: isCompressingSession,
            isUpdatingConfiguration: isUpdatingConfiguration
        )
    }

    private var isReasoningControlDisabled: Bool {
        isOfflineReadOnly || isSending || isCompressingSession || isCancellingStream || isUpdatingConfiguration
            || (isWaitingForStream && !allowsReasoningChangesWhileStreaming)
    }

    private var isVoiceInputDisabled: Bool {
        if voiceInput.isListening {
            return false
        }

        return isOfflineReadOnly
            || isSending
            || isCompressingSession
            || isWaitingForStream
            || isUploadingAttachment
            || isUpdatingConfiguration
            || voiceInput.isRequestingPermission
    }

    /// Whether a hold-to-record gesture is allowed to start a new voice note.
    /// Recording mid-stream is fine (it queues like any send), so unlike dictation
    /// this does not block on `isWaitingForStream`.
    private var isVoiceNoteRecordingDisabled: Bool {
        isOfflineReadOnly
            || isSending
            || isSendingVoiceNote
            || isCompressingSession
            || isUploadingAttachment
            || isUpdatingConfiguration
    }

    private var actionButtonBackground: Color {
        if PrimaryActionTintSettings.usesThemeColor(
            isEnabled: tintsPrimaryActions,
            controlIsEnabled: !isActionButtonDisabled
        ) {
            return SemrehVisualTheme.action(for: colorScheme, palette: palette, accent: accent)
        }

        if isActionButtonDisabled {
            return colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        }

        return SemrehVisualTheme.energy(for: palette, accent: accent)
    }

    private var actionButtonForeground: Color {
        if PrimaryActionTintSettings.usesThemeColor(
            isEnabled: tintsPrimaryActions,
            controlIsEnabled: !isActionButtonDisabled
        ) {
            return SemrehVisualTheme.accentForeground(for: colorScheme, palette: palette, accent: accent)
        }

        if isActionButtonDisabled {
            return Color(.secondaryLabel)
        }

        return SemrehVisualTheme.energyForeground(for: palette, accent: accent)
    }

    private var isComposerExpanded: Bool {
        // A wrapped second line needs the same bottom-anchored controls as an
        // explicit newline. Waiting for three lines made the mic/send jump.
        draftMessage.contains("\n") || textFieldHeight > 26
    }

    private var composerCornerRadius: CGFloat {
        isComposerExpanded ? 20 : 24
    }

    private var textFieldVerticalPadding: CGFloat {
        isComposerExpanded ? 8 : 7
    }


    private var trimmedDraftMessage: String {
        draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsStopButton: Bool {
        isWaitingForStream && trimmedDraftMessage.isEmpty
    }

    private var isActionButtonDisabled: Bool {
        if isOfflineReadOnly {
            return true
        }

        if showsStopButton {
            return isCancellingStream
        }

        return trimmedDraftMessage.isEmpty
            || isSending
            || isCompressingSession
            || isUploadingAttachment
            || isUpdatingConfiguration
    }

    private func actionButtonTapped() {
        if showsStopButton {
            onCancel()
        } else {
            if voiceInput.isListening {
                voiceInput.stopBeforeSubmittingDraft()
            }
            onSend()
        }
    }

    /// Starts dictation once for a composer opened by the "New Chat with Voice" intent (#338),
    /// mirroring a mic tap. Gated so it fires a single time, only while the app is active and
    /// the mic is free; the reused tap path handles the mic/speech permission prompt and surfaces
    /// a clear error if access is denied, so a denied/undetermined mic degrades gracefully.
    @MainActor
    private func autoStartVoiceInputIfNeeded() {
        guard autoStartsVoiceInput, !didAutoStartVoiceInput else { return }
        guard scenePhase == .active else { return }
        didAutoStartVoiceInput = true
        guard !voiceInput.isListening, !isVoiceInputDisabled else { return }
        toggleVoiceInput()
    }

    @MainActor
    private func toggleVoiceInput() {
        voiceInput.apiClient = apiClient
        voiceInput.profileName = voiceInputProfileName
        voiceInput.currentProfile = currentVoiceInputProfile
        voiceInput.providerPreference = ComposerSTTProviderPreference.storedValue(sttProviderPreferenceRawValue)
        voiceInput.locale = .current
        Task {
            await voiceInput.toggle(currentDraft: draftMessage) { newDraft in
                draftMessage = newDraft
            }
        }
    }

    /// Hold recognized → start recording a voice note. Gated by the recording
    /// disabled conditions; stops dictation first if it's running.
    @MainActor
    private func startVoiceNoteRecording() {
        guard !isVoiceNoteRecordingDisabled, !voiceNoteRecorder.isRecording else { return }

        if voiceInput.isListening {
            voiceInput.stopKeepingTranscript()
        }
        voiceNoteCancelArmed = false
        Task { await voiceNoteRecorder.begin() }
    }

    /// Finger lifted (or max duration hit). Cancels if slid up past the threshold,
    /// otherwise stops and sends the clip.
    @MainActor
    private func finishVoiceNote(translationHeight: CGFloat) {
        let shouldCancel = ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: translationHeight)
        voiceNoteCancelArmed = false

        guard !shouldCancel else {
            voiceNoteRecorder.cancel()
            return
        }

        guard let note = voiceNoteRecorder.finish() else { return }
        onSendVoiceNote(note.data, note.filename)
    }

    @MainActor
    private func cancelVoiceNote() {
        voiceNoteCancelArmed = false
        voiceNoteRecorder.cancel()
    }

    private var canFocusTextView: Bool {
        !isOfflineReadOnly && !isUploadingAttachment && uploadAttachmentErrorMessage == nil
    }

    private func prepareForComposerPresentation() {
        shouldRestoreFocusAfterPresentation = isFocused
        if isFocused {
            isFocused = false
        }
    }

    private func restoreFocusAfterPresentationIfNeeded() {
        guard shouldRestoreFocusAfterPresentation else { return }
        shouldRestoreFocusAfterPresentation = false
        requestTextViewFocusIfPossible()
    }

    private func restoreFocusAfterPresentationDismissalSettles() {
        guard shouldRestoreFocusAfterPresentation else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard shouldRestoreFocusAfterPresentation else { return }
            restoreFocusAfterPresentationIfNeeded()
        }
    }

    private func deferFocusRestoreUntilUploadCompletes() {
        guard shouldRestoreFocusAfterPresentation else { return }
        shouldRestoreFocusAfterPresentation = false
        deferredUploadFocusPhase = .waitingForUploadStart(afterGeneration: attachmentUploadGeneration)
    }

    private func handleDeferredUploadStart(_ newGeneration: Int) {
        guard case let .waitingForUploadStart(afterGeneration) = deferredUploadFocusPhase,
              newGeneration > afterGeneration
        else { return }

        if attachmentUploadCount == 0 {
            restoreFocusAfterDeferredUploadIfNeeded()
        } else {
            deferredUploadFocusPhase = .waitingForUploadsToFinish
        }
    }

    private func handleDeferredUploadCountChange(_ newCount: Int) {
        guard case .waitingForUploadsToFinish = deferredUploadFocusPhase else { return }
        if newCount == 0 {
            restoreFocusAfterDeferredUploadIfNeeded()
        }
    }

    private func restoreFocusAfterDeferredUploadIfNeeded() {
        guard deferredUploadFocusPhase != .none else { return }
        deferredUploadFocusPhase = .none
        requestTextViewFocusIfPossible()
    }

    private func requestTextViewFocusIfPossible() {
        guard canFocusTextView else { return }

        Task { @MainActor in
            await Task.yield()
            guard canFocusTextView else { return }
            isFocused = true
        }
    }

    private func isFileImporterCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == CocoaError.Code.userCancelled.rawValue
    }
}
