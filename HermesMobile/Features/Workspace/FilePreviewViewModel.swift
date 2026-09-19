import Foundation
import PDFKit
import UniformTypeIdentifiers

enum DocumentPreviewLimits {
    static let maximumBytes = 20 * 1_024 * 1_024
    static let maximumExtensionlessRemoteMediaBytes = 50 * 1_024 * 1_024
}

enum DocumentPreviewKind: Equatable {
    case pdf
    case markdown

    static func infer(nameOrPath: String?, mimeType: String? = nil) -> DocumentPreviewKind? {
        let normalizedMIME = mimeType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedMIME == "application/pdf" {
            return .pdf
        }

        if let normalizedMIME,
           ["text/markdown", "text/x-markdown", "application/markdown"].contains(normalizedMIME) {
            return .markdown
        }

        let pathExtension = URL(fileURLWithPath: nameOrPath ?? "").pathExtension.lowercased()
        let extensionKind: DocumentPreviewKind?
        if pathExtension == "pdf" {
            extensionKind = .pdf
        } else if ["md", "markdown", "mdown", "mkd"].contains(pathExtension) {
            extensionKind = .markdown
        } else {
            extensionKind = nil
        }

        guard let normalizedMIME else {
            return extensionKind
        }

        let genericMIMETypes: Set<String> = [
            "application/octet-stream",
            "application/x-download",
            "application/x-octet-stream",
            "binary/octet-stream",
            "text/plain"
        ]
        return genericMIMETypes.contains(normalizedMIME) ? extensionKind : nil
    }

}

final class PDFPreviewDocument: Identifiable, @unchecked Sendable {
    let id = UUID()
    let document: PDFDocument

    private init(document: PDFDocument) {
        self.document = document
    }

    static func load(data: Data) async -> PDFPreviewDocument? {
        await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(data: data),
                  isPreviewable(document) else {
                return nil
            }
            return PDFPreviewDocument(document: document)
        }.value
    }

    static func isPreviewable(_ document: PDFDocument) -> Bool {
        !document.isLocked && document.pageCount > 0
    }
}

@Observable
final class FilePreviewViewModel {
    private let session: SessionSummary
    private let path: String
    private let apiClient: APIClient

    private(set) var preview: FilePreviewContent?
    private(set) var isLoading = false
    private(set) var isExporting = false
    private(set) var errorMessage: String?
    private(set) var exportErrorMessage: String?
    private(set) var lastError: Error?
    private var exportData: Data?
    private var loadRevision = 0

    init(session: SessionSummary, server: URL, path: String, apiClient: APIClient? = nil) {
        self.session = session
        self.path = path
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    var canExportFile: Bool {
        session.sessionId?.isEmpty == false && !path.isEmpty
    }

    var canSaveImageToPhotos: Bool {
        canExportFile && isRasterImagePath
    }

    @MainActor
    func load() async {
        guard let sessionID = session.sessionId else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }

        guard !path.isEmpty else {
            errorMessage = String(localized: "File path is missing.")
            return
        }

        isLoading = true
        loadRevision += 1
        let revision = loadRevision
        defer { if revision == loadRevision { isLoading = false } }
        exportData = nil
        errorMessage = nil
        exportErrorMessage = nil
        lastError = nil

        do {
            if isRasterImagePath {
                let data = try await apiClient.directWorkspaceDownload(sessionID: sessionID, profile: session.profile ?? "default", path: path)
                guard revision == loadRevision, !Task.isCancelled else { return }
                exportData = data
                if let previewData = ImagePreviewDownsampler.previewData(
                    from: data,
                    maxPixelSize: ImagePreviewDownsampler.filePreviewMaxPixelSize
                ) {
                    preview = .image(.init(data: previewData, originalByteCount: data.count))
                } else {
                    preview = .unavailable(String(localized: "Could not decode this image."))
                }
            } else if documentKind == .pdf {
                let data = try await apiClient.directWorkspaceDownload(
                    sessionID: sessionID,
                    profile: session.profile ?? "default",
                    path: path,
                    maximumBytes: DocumentPreviewLimits.maximumBytes
                )
                guard revision == loadRevision, !Task.isCancelled else { return }
                exportData = data
                let document = await PDFPreviewDocument.load(data: data)
                guard revision == loadRevision, !Task.isCancelled else { return }
                if let document {
                    preview = .pdf(document)
                } else {
                    preview = .unavailable(String(localized: "Could not decode this PDF."))
                }
            } else if documentKind == .markdown {
                let (file, data) = try await readText(sessionID: sessionID)
                guard revision == loadRevision, !Task.isCancelled else { return }
                exportData = data
                preview = .markdown(file)
            } else if isKnownUnsupportedBinaryPath {
                preview = .unavailable(String(localized: "Preview is not available for this file type."))
            } else {
                let (file, data) = try await readText(sessionID: sessionID)
                guard revision == loadRevision, !Task.isCancelled else { return }
                exportData = data
                preview = .text(file)
            }
        } catch {
            guard revision == loadRevision else { return }
            if Self.isCancellation(error) { isLoading = false; return }
            lastError = error
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    @MainActor
    func exportPayload() async throws -> FileExportPayload {
        guard let sessionID = session.sessionId else {
            throw FileExportError.missingSessionID
        }

        guard !path.isEmpty else {
            throw FileExportError.missingPath
        }

        if let exportData {
            return payload(with: exportData)
        }

        isExporting = true
        let revision = loadRevision
        exportErrorMessage = nil
        lastError = nil
        defer {
            isExporting = false
        }

        do {
            let data = try await apiClient.directWorkspaceDownload(sessionID: sessionID, profile: session.profile ?? "default", path: path)
            guard revision == loadRevision, !Task.isCancelled else { throw CancellationError() }
            exportData = data
            return payload(with: data)
        } catch {
            guard revision == loadRevision, !Task.isCancelled, !Self.isCancellation(error) else { throw error }
            lastError = error
            exportErrorMessage = error.localizedDescription
            throw error
        }
    }

    private var pathExtension: String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    private func readText(sessionID: String) async throws -> (FileResponse, Data) {
        let file = try await apiClient.directWorkspaceFile(sessionID: sessionID,
            profile: session.profile ?? "default", path: path, maximumBytes: DocumentPreviewLimits.maximumBytes)
        guard let text = String(data: file.data, encoding: .utf8) else { throw DirectWorkspaceError.invalidText }
        return (FileResponse(content: text, path: path, name: file.name, language: nil,
            size: file.data.count, lines: text.components(separatedBy: "\n").count, error: nil), file.data)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError { return error.code == .cancelled }
        if case APIError.network(let wrapped) = error { return isCancellation(wrapped) }
        return false
    }

    private var documentKind: DocumentPreviewKind? {
        DocumentPreviewKind.infer(nameOrPath: path)
    }

    private var isRasterImagePath: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "ico", "bmp"].contains(pathExtension)
    }

    private var isKnownUnsupportedBinaryPath: Bool {
        [
            "7z", "a", "aiff", "avi", "bin", "bz2", "class", "db", "dmg", "doc",
            "docx", "dylib", "exe", "flac", "gz", "jar", "m4a", "mov", "mp3",
            "mp4", "o", "pkg", "ppt", "pptx", "pyc", "rar", "sqlite",
            "svg", "tar", "tgz", "wav", "xls", "xlsx", "xz", "zip"
        ].contains(pathExtension)
    }

    private func payload(with data: Data) -> FileExportPayload {
        FileExportPayload(
            data: data,
            filename: exportFilename,
            contentType: UTType(filenameExtension: pathExtension) ?? .data,
            isImage: isRasterImagePath,
            isVideo: isVideoPath
        )
    }

    private var isVideoPath: Bool {
        ["m4v", "mov", "mp4"].contains(pathExtension)
    }

    private var exportFilename: String {
        let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return lastPathComponent.isEmpty ? String(localized: "Semreh File") : lastPathComponent
    }
}

enum FilePreviewContent {
    case text(FileResponse)
    case markdown(FileResponse)
    case pdf(PDFPreviewDocument)
    case image(ImageFilePreview)
    case audio(Data)
    case unavailable(String)
}

struct ImageFilePreview {
    let data: Data
    let originalByteCount: Int
}

struct FileExportPayload {
    let data: Data
    let filename: String
    let contentType: UTType
    let isImage: Bool
    let isVideo: Bool
}

enum FileExportError: LocalizedError {
    case missingSessionID
    case missingPath

    var errorDescription: String? {
        switch self {
        case .missingSessionID:
            String(localized: "Session ID is missing.")
        case .missingPath:
            String(localized: "File path is missing.")
        }
    }
}
