import SwiftUI
import UIKit

struct SelectableTextPresentation: Identifiable, Equatable {
    let id: String
    let text: String

    init(id: String, text: String) {
        self.id = id
        self.text = text
    }

    init(context: MessageActionContext) {
        self.init(id: context.messageID, text: context.copyText)
    }
}

struct ChatMessageActionMenu: View {
    let context: MessageActionContext
    let listeningMessageID: String?
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let onToggleListening: (MessageActionContext) -> Void
    let onSelectText: (MessageActionContext) -> Void
    let onRegenerate: (MessageActionContext) -> Void
    let onEdit: (MessageActionContext) -> Void
    let onFork: (MessageActionContext) -> Void
    let onCopy: (MessageActionContext) -> Void

    var body: some View {
        if context.role == .assistant {
            Button {
                onToggleListening(context)
            } label: {
                Label(
                    isListening ? "Stop Listening" : "Listen",
                    systemImage: isListening ? "speaker.slash" : "speaker.wave.2"
                )
            }

            Button {
                onSelectText(context)
            } label: {
                Label("Select Text", systemImage: "text.cursor")
            }

            Button {
                onRegenerate(context)
            } label: {
                Label("Regenerate Response", systemImage: "arrow.clockwise")
            }
            .disabled(isViewingCachedData || hasActiveStream || isRegeneratingMessage)
        }

        if context.role == .user {
            Button {
                onEdit(context)
            } label: {
                Label("Edit Message", systemImage: "pencil")
            }
            .disabled(isViewingCachedData || hasActiveStream || isEditingMessage)
        }

        Button {
            onFork(context)
        } label: {
            Label("Fork From Here", systemImage: "arrow.triangle.branch")
        }
        .disabled(isViewingCachedData || hasActiveStream || isForkingMessage)

        Button {
            onCopy(context)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    private var isListening: Bool {
        listeningMessageID == context.messageID
    }
}

enum AssistantResponseActionPolicy {
    /// Derives one stable row ID per transcript update. While a stream is active,
    /// ignore assistant rows after the current user turn so the previous
    /// completed response retains Copy until the new answer settles.
    static func latestCompletedAssistantRenderID(
        in transcriptMessages: [TranscriptMessage],
        hasActiveStream: Bool,
        streamingAssistantMessageID: String?
    ) -> String? {
        let activeMessageID = hasActiveStream ? streamingAssistantMessageID : nil

        if hasActiveStream,
           let activeUserTurnStart = transcriptMessages.lastIndex(where: {
               TranscriptTurnClassifier.isUserTurnBoundary($0.message)
           }) {
            return transcriptMessages[..<activeUserTurnStart]
                .reversed()
                .first(where: { isCopyableAssistant($0, excluding: activeMessageID) })?
                .renderID
        }

        return transcriptMessages.reversed()
            .first(where: { isCopyableAssistant($0, excluding: activeMessageID) })?
            .renderID
    }

    static func shouldShowPersistentCopy(
        context: MessageActionContext?,
        messageRole: String?,
        isStreaming: Bool,
        isLatestCompletedAssistant: Bool
    ) -> Bool {
        guard let context else { return false }
        return context.role == .assistant &&
            messageRole == "assistant" &&
            !isStreaming &&
            isLatestCompletedAssistant
    }

    private static func isCopyableAssistant(
        _ transcriptMessage: TranscriptMessage,
        excluding streamingAssistantMessageID: String?
    ) -> Bool {
        let message = transcriptMessage.message
        let isStreamingMessage = streamingAssistantMessageID.map {
            message.messageId == $0
        } ?? false
        return message.role == "assistant" &&
            ChatMarkerMessageClassifier.classify(message) == nil &&
            !isStreamingMessage &&
            !(message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A compact persistent action shown only under a completed assistant reply.
/// It reuses the transcript's existing copy callback and introduces no new
/// response feedback or backend behavior.
struct AssistantResponseActionRow: View {
    let context: MessageActionContext
    let onCopy: (MessageActionContext) -> Void

    var body: some View {
        HStack {
            Button {
                onCopy(context)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("assistant-response-copy")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 2)
        .padding(.top, 2)
    }
}

struct SelectableTextPresentationView: View {
    let selection: SelectableTextPresentation

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: selection.text)
                .accessibilityIdentifier("selectable-response-text")
                .background(Color(.systemBackground))
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .systemBackground
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        // A wrapped UITextView does not inherit SwiftUI's layoutDirection; `.natural`
        // lets each paragraph align by its own writing direction so RTL message text
        // reads right-aligned while LTR stays left-aligned (issue #294).
        textView.textAlignment = .natural
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.alwaysBounceVertical = true
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }
}

struct EditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss

    let originalText: String
    @Binding var editDraft: String
    let onSubmit: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $editDraft)
                    .font(.body)
                    .padding()
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("Edit Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        dismiss()
                        onSubmit()
                    }
                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .adaptiveFormPresentation()
    }
}
