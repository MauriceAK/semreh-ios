import Foundation
import Observation

struct ChatAttachmentSendPreparation {
    let attachments: [PendingAttachment]
    let messageAttachments: [MessageAttachment]

    var apiPayloads: [JSONValue]? {
        attachments.isEmpty ? nil : attachments.map { $0.toJSONValue() }
    }

    func chatMessageText(draft: String) -> String {
        PendingAttachment.chatMessageText(draft: draft, attachments: attachments)
    }
}

@MainActor
protocol ChatAttachmentCoordinatorDelegate: AnyObject {
    var attachmentSessionID: String? { get }
}

@MainActor
@Observable
final class ChatAttachmentCoordinator {
    private(set) var pendingAttachments: [PendingAttachment] = []
    private(set) var localAttachmentPreviews: [String: [String: Data]] = [:]

    weak var delegate: ChatAttachmentCoordinatorDelegate?

    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func clearPendingAttachments() {
        pendingAttachments.removeAll()
    }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func transcriptMediaThumbnailData(for reference: TranscriptMediaReference) async -> Data? {
        guard reference.isRasterImageCandidate else { return nil }
        guard let sessionID = delegate?.attachmentSessionID else { return nil }

        do {
            let data = try await client.transcriptMediaData(for: reference, sessionID: sessionID)
            return await ImagePreviewDownsampler.previewDataAsync(
                from: data,
                maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
            ) ?? data
        } catch {
            return nil
        }
    }

    /// Raw transcript media bytes for inline audio/video playback. Local paths
    /// still require a real session ID so `/api/media` can authorize session media.
    func transcriptMediaData(for reference: TranscriptMediaReference) async -> Data? {
        guard let sessionID = delegate?.attachmentSessionID else { return nil }

        do {
            return try await client.transcriptMediaData(for: reference, sessionID: sessionID)
        } catch {
            return nil
        }
    }

    func prepareForSend(localMessageID: String) -> ChatAttachmentSendPreparation {
        let attachmentsForSend = pendingAttachments
        let messageAttachments = attachmentsForSend.map { pending in
            MessageAttachment(
                name: pending.name,
                path: pending.path,
                mime: pending.mime,
                size: pending.size,
                isImage: pending.isImage
            )
        }

        var previews: [String: Data] = [:]
        for pending in attachmentsForSend {
            if let data = pending.thumbnailData {
                previews[pending.path] = data
            }
        }
        if !previews.isEmpty {
            localAttachmentPreviews[localMessageID] = previews
        }

        pendingAttachments.removeAll()
        return ChatAttachmentSendPreparation(
            attachments: attachmentsForSend,
            messageAttachments: messageAttachments
        )
    }

    func restorePendingAttachments(_ attachments: [PendingAttachment]) {
        guard !attachments.isEmpty else { return }
        pendingAttachments = attachments + pendingAttachments
    }

    func consumePendingAttachments() -> [PendingAttachment] {
        let attachments = pendingAttachments
        pendingAttachments.removeAll()
        return attachments
    }

    func replacePendingAttachments(_ attachments: [PendingAttachment]) {
        pendingAttachments = attachments
    }

    func removeLocalPreviews(messageID: String) {
        localAttachmentPreviews[messageID] = nil
    }

    func removeAllLocalPreviews() {
        localAttachmentPreviews.removeAll()
    }

    func mergeLocalAttachmentPreviews(_ previews: [String: [String: Data]]) {
        localAttachmentPreviews.merge(previews) { current, _ in current }
    }

}
