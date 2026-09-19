import Foundation

extension APIClient {
    func transcriptMediaData(for reference: TranscriptMediaReference, sessionID: String) async throws -> Data {
        let requiresDocumentBudget = reference.isPDFCandidate || reference.isMarkdownCandidate

        switch reference.source {
        case let .localPath(path):
            if reference.isRasterImageCandidate {
                return try await mediaData(sessionID: sessionID, path: path)
            }
            guard path.hasPrefix("/"), !path.contains("\0") else {
                throw TranscriptMediaDataError.absoluteLocalPathRequired
            }
            let maximumBytes = requiresDocumentBudget
                ? DocumentPreviewLimits.maximumBytes
                : TranscriptMediaDataLimits.maximumLocalNonImageBytes
            return try await directReadManagedFile(path: path, maximumBytes: maximumBytes).data
        case let .remoteURL(url):
            if requiresDocumentBudget {
                return try await remoteTranscriptMediaPreviewData(
                    from: url,
                    maximumBytes: DocumentPreviewLimits.maximumBytes
                )
            }
            return try await remoteTranscriptMediaData(from: url)
        }
    }
}

enum TranscriptMediaDataError: LocalizedError {
    case absoluteLocalPathRequired

    var errorDescription: String? {
        String(localized: "Preview is not available because this media reference is not an absolute server path.")
    }
}

private enum TranscriptMediaDataLimits {
    // Matches the previous stock /api/media response cap for local media while
    // allowing its supported non-image formats to use the managed-file route.
    static let maximumLocalNonImageBytes = 25 * 1_024 * 1_024
}
