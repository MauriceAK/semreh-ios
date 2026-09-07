import Foundation

/// The local identity of the socket/session that confirmed an attachment
/// stage. A later controller may reuse a confirmed stage only for this exact
/// binding and transport generation.
struct DirectPendingAttachmentStageScope: Equatable, Sendable {
    let origin: String
    let storedID: String
    let runtimeID: String
    let profile: String
    let connectionGeneration: Int

    init(binding: GatewaySessionBinding, connectionGeneration: Int, origin: URL) {
        self.origin = origin.absoluteString
        storedID = binding.storedID
        runtimeID = binding.runtimeID
        profile = binding.profile
        self.connectionGeneration = connectionGeneration
    }
}

enum DirectPendingAttachmentStageState: Equatable, Sendable {
    case pending
    case confirmed(
        scope: DirectPendingAttachmentStageScope,
        referenceText: String?,
        serverDetachPaths: [String]
    )
    case unknown(scope: DirectPendingAttachmentStageScope)

    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

/// Memory-only pending direct attachment state. It intentionally remains
/// separate from legacy `PendingAttachment`, whose path is a server-upload
/// result and cannot retain bytes for direct RPC retry.
struct DirectPendingAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: DirectGatewayAttachment
    let thumbnailData: Data?
    private(set) var stageState: DirectPendingAttachmentStageState = .pending

    init(
        id: UUID = UUID(),
        source: DirectGatewayAttachment,
        thumbnailData: Data? = nil
    ) {
        self.id = id
        self.source = source
        self.thumbnailData = thumbnailData
    }

    var displayFilename: String { source.displayFilename }
    var mimeType: String { source.mimeType }
    var originalBytes: Data { source.originalBytes }
    var byteCount: Int { source.originalBytes.count }
    var isImage: Bool { source.kind == .image }
    var isPDF: Bool { source.kind == .pdf }
    var isGenericFile: Bool { source.kind == .file }

    /// A confirmed stage is reusable only on the exact socket/session scope;
    /// this prevents a reconnect or session switch from duplicating a queued
    /// image/PDF or reusing a file reference from another binding.
    func isConfirmed(for scope: DirectPendingAttachmentStageScope) -> Bool {
        guard case .confirmed(let confirmedScope, _, _) = stageState else { return false }
        return confirmedScope == scope
    }

    func referenceText(for scope: DirectPendingAttachmentStageScope) -> String? {
        guard case .confirmed(let confirmedScope, let referenceText, _) = stageState,
              confirmedScope == scope else {
            return nil
        }
        return referenceText
    }

    /// These are gateway-returned image/PDF paths only. Generic files have no
    /// detach RPC in the pinned stock contract, so they intentionally return
    /// no cleanup paths.
    func serverDetachPaths(for scope: DirectPendingAttachmentStageScope) -> [String] {
        guard case .confirmed(let confirmedScope, _, let paths) = stageState,
              confirmedScope == scope else {
            return []
        }
        return paths
    }

    /// Returns false for an unknown stage. The caller must not blind-retry a
    /// request whose response may have been lost after reaching Hermes.
    @discardableResult
    mutating func confirm(
        scope: DirectPendingAttachmentStageScope,
        referenceText: String? = nil,
        serverDetachPaths: [String] = []
    ) -> Bool {
        guard case .pending = stageState else { return false }
        stageState = .confirmed(
            scope: scope,
            referenceText: referenceText,
            serverDetachPaths: serverDetachPaths
        )
        return true
    }

    @discardableResult
    mutating func markUnknown(scope: DirectPendingAttachmentStageScope) -> Bool {
        guard case .pending = stageState else { return false }
        stageState = .unknown(scope: scope)
        return true
    }
}
