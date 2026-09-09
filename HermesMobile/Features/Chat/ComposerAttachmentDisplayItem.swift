import Foundation

/// Small UI projection shared by the legacy uploaded attachment and the
/// direct in-memory attachment. `serverPath` is nil for direct items; callers
/// must never manufacture a client/host path for them.
struct ComposerAttachmentDisplayItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let serverPath: String?
    let mime: String?
    let size: Int?
    let isImage: Bool
    let isGenericFileReference: Bool
    let thumbnailData: Data?
    /// Direct images and PDFs provide original bytes for a local preview.
    /// Generic files intentionally use the existing no-server-path fallback.
    let localPreviewData: Data?

    private let legacyPending: PendingAttachment?

    init(pending attachment: PendingAttachment) {
        id = attachment.id
        name = attachment.name
        serverPath = attachment.path
        mime = attachment.mime
        size = attachment.size
        isImage = attachment.isImage
        isGenericFileReference = false
        thumbnailData = attachment.thumbnailData
        localPreviewData = nil
        legacyPending = attachment
    }

    init(direct attachment: DirectPendingAttachment) {
        id = attachment.id
        name = attachment.displayFilename
        serverPath = nil
        mime = attachment.mimeType
        size = attachment.byteCount
        isImage = attachment.isImage
        isGenericFileReference = attachment.isGenericFile
        thumbnailData = attachment.thumbnailData
        localPreviewData = (attachment.isImage || attachment.isPDF) ? attachment.originalBytes : nil
        legacyPending = nil
    }

    /// Keeps SwiftUI diffing metadata-only. Direct source bytes are immutable
    /// and intentionally excluded from equality to avoid comparing large Data
    /// values on every composer update.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.serverPath == rhs.serverPath &&
        lhs.mime == rhs.mime &&
        lhs.size == rhs.size &&
        lhs.isImage == rhs.isImage &&
        lhs.isGenericFileReference == rhs.isGenericFileReference
    }

    func legacyPendingAttachment() -> PendingAttachment? {
        legacyPending
    }
}
