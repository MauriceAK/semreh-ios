import AVFoundation
import Foundation
import SwiftUI

private struct TranscriptMediaLoadedResource {
    let data: Data
    let mimeType: String?
}

@MainActor
@Observable
final class TranscriptMediaPreviewViewModel {
    private let sessionID: String?
    private let reference: TranscriptMediaReference
    private let apiClient: APIClient
    private var didLoad = false
    private var loadGeneration = 0
    private var originalData: Data?
    private var temporaryVideoURL: URL?

    private(set) var previewData: Data?
    private(set) var audioData: Data?
    private(set) var pdfDocument: PDFPreviewDocument?
    private(set) var markdownText: String?
    private(set) var videoFileURL: URL?
    private(set) var originalByteCount: Int?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?

    init(
        server: URL,
        sessionID: String?,
        reference: TranscriptMediaReference,
        apiClient: APIClient? = nil
    ) {
        self.sessionID = sessionID
        self.reference = reference
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    var canSaveImageToPhotos: Bool {
        reference.isRasterImageCandidate && previewData != nil
    }

    var canSaveVideoToPhotos: Bool {
        videoFileURL != nil && originalData != nil
    }

    var canSaveMediaToPhotos: Bool {
        canSaveImageToPhotos || canSaveVideoToPhotos
    }

    var canExportMedia: Bool {
        originalData != nil
    }

    func load(force: Bool = false) async {
        guard force || !didLoad else { return }
        loadGeneration += 1
        let generation = loadGeneration
        didLoad = true
        previewData = nil
        audioData = nil
        pdfDocument = nil
        markdownText = nil
        videoFileURL = nil
        originalByteCount = nil
        originalData = nil
        removeTemporaryVideoFile()

        guard reference.isRasterImageCandidate
                || reference.isAudioCandidate
                || reference.isVideoCandidate
                || reference.isPDFCandidate
                || reference.isMarkdownCandidate
        else {
            errorMessage = String(localized: "Preview is not available for this media type.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }

        do {
            let resource = try await transcriptMediaResource()
            let data = resource.data
            guard !Task.isCancelled, loadGeneration == generation else { return }
            originalData = data
            originalByteCount = data.count

            let documentKind = DocumentPreviewKind.infer(
                nameOrPath: reference.rawReference,
                mimeType: resource.mimeType
            )
            if documentKind == .pdf {
                if let document = await PDFPreviewDocument.load(data: data) {
                    pdfDocument = document
                } else {
                    errorMessage = String(localized: "Could not decode this PDF.")
                }
            } else if documentKind == .markdown {
                if let text = String(data: data, encoding: .utf8) {
                    markdownText = text
                } else {
                    errorMessage = String(localized: "Could not decode this Markdown document.")
                }
            } else if reference.isVideoCandidate {
                let fileURL = try writeTemporaryVideoFile(data)
                guard !Task.isCancelled, loadGeneration == generation else {
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                temporaryVideoURL = fileURL
                videoFileURL = fileURL
            } else if reference.isAudioCandidate {
                audioData = data
            } else {
                if let downsampled = await ImagePreviewDownsampler.previewDataAsync(
                    from: data,
                    maxPixelSize: ImagePreviewDownsampler.filePreviewMaxPixelSize
                ) {
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    previewData = downsampled
                } else {
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    if reference.isExtensionlessRemoteMediaCandidate {
                        if Self.isAudioData(data) {
                            audioData = data
                        } else {
                            let fileURL = try writeTemporaryVideoFile(data)
                            temporaryVideoURL = fileURL
                            videoFileURL = fileURL
                        }
                    } else {
                        errorMessage = String(localized: "Could not decode this image.")
                    }
                }
            }
        } catch {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    func originalImageData() async throws -> Data {
        try await originalMediaData()
    }

    func originalMediaData() async throws -> Data {
        if let originalData {
            return originalData
        }

        let data = try await transcriptMediaData()
        try Task.checkCancellation()
        originalData = data
        originalByteCount = data.count
        return data
    }

    func exportPayload() async throws -> FileExportPayload {
        let data = try await originalMediaData()
        return TranscriptMediaExportSupport.payload(
            for: reference,
            data: data,
            resolvedKind: resolvedExportKind
        )
    }

    private func transcriptMediaData() async throws -> Data {
        try await transcriptMediaResource().data
    }

    private func transcriptMediaResource() async throws -> TranscriptMediaLoadedResource {
        switch reference.source {
        case let .localPath(path):
            if reference.isRasterImageCandidate {
                guard let sessionID = resolvedSessionID else {
                    throw TranscriptMediaPreviewError.missingSessionID
                }
                let data = try await apiClient.transcriptMediaData(for: reference, sessionID: sessionID)
                return TranscriptMediaLoadedResource(data: data, mimeType: nil)
            }
            guard path.hasPrefix("/"), !path.contains("\0") else {
                throw TranscriptMediaDataError.absoluteLocalPathRequired
            }
            let maximumBytes = reference.isPDFCandidate || reference.isMarkdownCandidate
                ? DocumentPreviewLimits.maximumBytes
                : 25 * 1_024 * 1_024
            let file = try await apiClient.directReadManagedFile(path: path, maximumBytes: maximumBytes)
            return TranscriptMediaLoadedResource(data: file.data, mimeType: file.mimeType)
        case let .remoteURL(url):
            let response = try await apiClient.remoteTranscriptMediaPreviewResource(
                from: url,
                maximumBytes: DocumentPreviewLimits.maximumExtensionlessRemoteMediaBytes,
                documentMaximumBytes: DocumentPreviewLimits.maximumBytes,
                nameOrPath: reference.rawReference
            )
            return TranscriptMediaLoadedResource(
                data: response.0,
                mimeType: response.1.value(forHTTPHeaderField: "Content-Type")
            )
        }
    }

    private var resolvedSessionID: String? {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else {
            return nil
        }
        return sessionID
    }

    func cleanupTemporaryFiles() {
        loadGeneration += 1
        isLoading = false
        audioData = nil
        pdfDocument = nil
        markdownText = nil
        removeTemporaryVideoFile()
        videoFileURL = nil
    }

    private func writeTemporaryVideoFile(_ data: Data) throws -> URL {
        let ext = reference.videoFileExtension
        let filename = "transcript-media-\(UUID().uuidString).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic])
        return url
    }

    private func removeTemporaryVideoFile() {
        if let temporaryVideoURL {
            try? FileManager.default.removeItem(at: temporaryVideoURL)
        }
        temporaryVideoURL = nil
    }

    private static func isAudioData(_ data: Data) -> Bool {
        (try? AVAudioPlayer(data: data)) != nil
    }

    private var resolvedExportKind: TranscriptMediaResolvedExportKind? {
        if previewData != nil {
            return .image
        }

        if audioData != nil {
            return .audio
        }

        if videoFileURL != nil {
            return .video
        }

        return nil
    }
}

private enum TranscriptMediaPreviewError: LocalizedError {
    case missingSessionID

    var errorDescription: String? {
        String(localized: "Preview is not available for this media without a server session.")
    }
}

private extension TranscriptMediaReference {
    var videoFileExtension: String {
        switch source {
        case let .remoteURL(url):
            let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            return ext.isEmpty ? "mp4" : ext
        case let .localPath(path):
            let ext = URL(fileURLWithPath: path).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            return ext.isEmpty ? "mp4" : ext
        }
    }
}
