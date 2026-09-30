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
    @Environment(\.internalChatRendererEnabled) private var internalChatRendererEnabled
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView: UITextView
        #if DEBUG || SEMREH_INTERNAL_CHAT_PREVIEW
        if internalChatRendererEnabled {
            textView = ParagraphSelectableTextView()
        } else {
            textView = UITextView()
        }
        #else
        textView = UITextView()
        #endif
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

#if DEBUG || SEMREH_INTERNAL_CHAT_PREVIEW
/// Add explicit paragraph selection to the experimental read-only surface.
/// Keep selection, handles, Copy and the remaining edit actions owned by UIKit.
final class ParagraphSelectableTextView: UITextView {
    private let paragraphMenu = UIEditMenuInteraction(delegate: nil)

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        let paragraphTap = UITapGestureRecognizer(target: self, action: #selector(selectParagraph(_:)))
        paragraphTap.numberOfTapsRequired = 3
        addGestureRecognizer(paragraphTap)
        addInteraction(paragraphMenu)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func selectParagraph(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, isSelectable,
              let position = closestPosition(to: gesture.location(in: self)) else { return }
        let source = (text ?? "") as NSString
        guard source.length > 0 else { return }
        let location = min(source.length - 1, max(0, offset(from: beginningOfDocument, to: position)))
        var range = source.paragraphRange(for: NSRange(location: location, length: 0))
        // Select content exactly, preserving spaces and composed Unicode; a
        // paragraph terminator belongs to the boundary, not the copied passage.
        while range.length > 0,
              [10, 13, 0x2028, 0x2029].contains(source.character(at: NSMaxRange(range) - 1)) {
            range.length -= 1
        }
        guard range.length > 0, becomeFirstResponder() else { return }
        selectedRange = range
        paragraphMenu.presentEditMenu(with: UIEditMenuConfiguration(
            identifier: nil, sourcePoint: gesture.location(in: self)
        ))
    }
}
#endif

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
