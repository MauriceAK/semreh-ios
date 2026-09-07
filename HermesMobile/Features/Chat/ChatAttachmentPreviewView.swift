import SwiftUI
import UIKit

struct ChatAttachmentPreviewItem: Identifiable, Equatable {
    let id = UUID()
    let name: String?
    let path: String?
    let mime: String?
    let size: Int?
    let isImage: Bool?
    let localPreviewData: Data?

    init(message attachment: MessageAttachment, localData: Data?) {
        name = attachment.name
        path = attachment.path
        mime = attachment.mime
        size = attachment.size
        isImage = attachment.isImage
        localPreviewData = localData
    }

    init(pending attachment: PendingAttachment) {
        name = attachment.name
        path = attachment.path
        mime = attachment.mime
        size = attachment.size
        isImage = attachment.isImage
        localPreviewData = attachment.thumbnailData
    }

    init(display item: ComposerAttachmentDisplayItem) {
        name = item.name
        path = item.serverPath
        mime = item.mime
        size = item.size
        isImage = item.isImage
        localPreviewData = item.localPreviewData
    }

    var displayName: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }

        if let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
            return lastPathComponent.isEmpty ? path : lastPathComponent
        }

        return inferredIsImage ? String(localized: "Image") : String(localized: "File")
    }

    var displayPath: String {
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedPath, !trimmedPath.isEmpty else {
            return displayName
        }
        return trimmedPath
    }

    var inferredIsImage: Bool {
        if isImage == true { return true }
        if let mime = mime?.lowercased(), mime.hasPrefix("image/") { return true }
        return Self.imageExtensions.contains(pathExtension)
    }

    var inferredIsAudio: Bool {
        AttachmentAudioDetection.isAudio(isImage: isImage, mime: mime, name: name, path: path)
    }

    var documentKind: DocumentPreviewKind? {
        DocumentPreviewKind.infer(nameOrPath: name ?? path, mimeType: mime)
    }

    var isKnownUnsupportedBinary: Bool {
        documentKind == nil && Self.unsupportedBinaryExtensions.contains(pathExtension)
    }

    private var pathExtension: String {
        URL(fileURLWithPath: name ?? path ?? "").pathExtension.lowercased()
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "ico"
    ]

    private static let unsupportedBinaryExtensions: Set<String> = [
        "7z", "a", "aiff", "avi", "bin", "bz2", "class", "db", "dmg", "doc",
        "docx", "dylib", "exe", "flac", "gz", "jar", "m4a", "mov", "mp3",
        "mp4", "o", "pkg", "ppt", "pptx", "pyc", "rar", "sqlite",
        "svg", "tar", "tgz", "wav", "xls", "xlsx", "xz", "zip"
    ]
}

struct ChatAttachmentPreviewView: View {
    let onAPIError: (Error) -> Void

    private let item: ChatAttachmentPreviewItem
    @State private var viewModel: ChatAttachmentPreviewViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        session: SessionSummary,
        server: URL,
        item: ChatAttachmentPreviewItem,
        usesDirectGateway: Bool = false,
        onAPIError: @escaping (Error) -> Void
    ) {
        self.item = item
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: ChatAttachmentPreviewViewModel(
            session: session,
            server: server,
            item: item,
            usesDirectGateway: usesDirectGateway
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.preview == nil {
                    ProgressView("Loading attachment...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = viewModel.errorMessage, viewModel.preview == nil {
                    ContentUnavailableView {
                        Label("Could Not Load Attachment", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            Task { await loadAttachment() }
                        }
                    }
                } else if let preview = viewModel.preview {
                    previewContent(preview)
                } else {
                    unavailableContent(String(localized: "Preview is not available for this attachment."))
                }
            }
            .navigationTitle(item.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .background { SemrehBackdrop().ignoresSafeArea() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadAttachment()
            }
            .refreshable {
                await loadAttachment(force: true)
            }
        }
        .adaptivePagePresentation()
    }

    @ViewBuilder
    private func previewContent(_ preview: FilePreviewContent) -> some View {
        switch preview {
        case let .text(file):
            textContent(file)
        case let .markdown(file):
            markdownContent(file)
        case let .pdf(document):
            pdfContent(document)
        case let .image(file):
            imageContent(file)
        case let .audio(data):
            audioContent(data)
        case let .unavailable(message):
            unavailableContent(message)
        }
    }

    private func audioContent(_ data: Data) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                fileHeader

                InlineAudioPlayerView(
                    title: item.displayName,
                    load: { data }
                )
            }
            .padding()
        }
        .background(Color.clear)
    }

    private func textContent(_ file: FileResponse) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 12) {
                fileHeader

                Text(file.content ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color.clear)
    }

    private func markdownContent(_ file: FileResponse) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                fileHeader

                MarkdownRenderer(content: file.content ?? "", isStreaming: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color.clear)
    }

    private func pdfContent(_ document: PDFPreviewDocument) -> some View {
        PDFDocumentView(document: document)
            .background(Color(.systemGroupedBackground))
            .accessibilityLabel(String(localized: "PDF document \(item.displayName)"))
    }

    @ViewBuilder
    private func imageContent(_ file: ImageFilePreview) -> some View {
        if let image = UIImage(data: file.data) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fileHeader

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(item.displayName)
                }
                .padding()
            }
            .background(Color.clear)
        } else {
            unavailableContent(String(localized: "Could not preview this image."))
        }
    }

    private func unavailableContent(_ message: String) -> some View {
        ContentUnavailableView {
            Label("No Preview", systemImage: item.inferredIsImage ? "photo" : "doc.questionmark")
        } description: {
            VStack(spacing: 8) {
                Text(message)
                Text(item.displayPath)
                    .font(.footnote)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var fileHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.displayPath)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let metadataText {
                Text(metadataText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metadataText: String? {
        var parts: [String] = []

        if let preview = viewModel.preview {
            switch preview {
            case let .text(file), let .markdown(file):
                if let size = file.size {
                    parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
                if let lines = file.lines {
                    parts.append(String(localized: "\(lines) lines"))
                }
            case .pdf:
                if let size = item.size {
                    parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
            case let .image(file):
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(file.originalByteCount), countStyle: .file))
            case let .audio(data):
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
            case .unavailable:
                break
            }
        } else if let size = item.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }

        if let mime = item.mime?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mime.isEmpty {
            parts.append(mime)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    private func loadAttachment(force: Bool = false) async {
        await viewModel.load(force: force)
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }
}

@MainActor
@Observable
final class ChatAttachmentPreviewViewModel {
    private static let directTextPreviewMaximumBytes = 256 * 1_024

    private let session: SessionSummary
    private let item: ChatAttachmentPreviewItem
    private let apiClient: APIClient
    private let usesDirectGateway: Bool
    private var didLoad = false

    private(set) var preview: FilePreviewContent?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?

    init(
        session: SessionSummary,
        server: URL,
        item: ChatAttachmentPreviewItem,
        apiClient: APIClient? = nil,
        usesDirectGateway: Bool = false
    ) {
        self.session = session
        self.item = item
        self.apiClient = apiClient ?? APIClient(baseURL: server)
        self.usesDirectGateway = usesDirectGateway
    }

    func load(force: Bool = false) async {
        guard force || !didLoad else { return }
        didLoad = true
        preview = nil

        let trimmedPath = item.path?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = trimmedPath, !path.isEmpty else {
            if usesDirectGateway, let localPreviewData = item.localPreviewData {
                guard !Task.isCancelled else { return }
                if item.inferredIsImage {
                    let originalByteCount = localPreviewData.count
                    guard let previewData = await ImagePreviewDownsampler.previewDataAsync(
                        from: localPreviewData,
                        maxPixelSize: ImagePreviewDownsampler.filePreviewMaxPixelSize
                    ), !Task.isCancelled else {
                        return
                    }
                    preview = .image(.init(data: previewData, originalByteCount: originalByteCount))
                    return
                }
                if item.documentKind == .pdf {
                    let declaredByteCount = item.size ?? 0
                    guard max(localPreviewData.count, declaredByteCount) <= DocumentPreviewLimits.maximumBytes else {
                        preview = .unavailable(String(localized: "This PDF preview is too large to display."))
                        return
                    }
                    guard let document = await PDFPreviewDocument.load(data: localPreviewData),
                          !Task.isCancelled else {
                        if !Task.isCancelled {
                            preview = .unavailable(String(localized: "Could not decode this PDF."))
                        }
                        return
                    }
                    preview = .pdf(document)
                    return
                }
            }
            preview = localFallbackPreview
            return
        }

        if usesDirectGateway {
            // Direct references are opaque server-owned paths. The managed-file
            // route requires an absolute path; never turn a relative reference
            // into a guessed host path or fall back to a legacy endpoint.
            guard path.hasPrefix("/") else {
                preview = .unavailable(String(localized: "Preview is not available for this attachment."))
                return
            }

            // These extensions are known binary types without a native preview.
            // Keep the no-fetch behavior explicit even though the managed-file
            // route can return arbitrary bytes.
            if item.isKnownUnsupportedBinary {
                preview = .unavailable(String(localized: "Preview is not available for this file type."))
                return
            }

            isLoading = true
            errorMessage = nil
            lastError = nil
            defer { isLoading = false }

            do {
                let managedFile = try await apiClient.directReadManagedFile(path: path)
                guard !Task.isCancelled else { return }
                let mimeType = managedFile.mimeType ?? item.mime
                let nameOrPath = item.name ?? managedFile.name ?? path
                let documentKind = DocumentPreviewKind.infer(
                    nameOrPath: nameOrPath,
                    mimeType: mimeType
                )
                let isImage = item.inferredIsImage || mimeType?.lowercased().hasPrefix("image/") == true

                if isImage {
                    let previewData = await ImagePreviewDownsampler.previewDataAsync(
                        from: managedFile.data,
                        maxPixelSize: ImagePreviewDownsampler.filePreviewMaxPixelSize
                    )
                    guard !Task.isCancelled else { return }
                    if let previewData {
                        preview = .image(.init(
                            data: previewData,
                            originalByteCount: managedFile.data.count
                        ))
                    } else {
                        preview = .unavailable(String(localized: "Could not decode this image."))
                    }
                } else if documentKind == .pdf {
                    guard managedFile.data.count <= DocumentPreviewLimits.maximumBytes else {
                        throw PreviewDownloadError.responseTooLarge(
                            maximumBytes: DocumentPreviewLimits.maximumBytes
                        )
                    }
                    if let document = await PDFPreviewDocument.load(data: managedFile.data) {
                        guard !Task.isCancelled else { return }
                        preview = .pdf(document)
                    } else {
                        guard !Task.isCancelled else { return }
                        preview = .unavailable(String(localized: "Could not decode this PDF."))
                    }
                } else if documentKind == .markdown {
                    let textPreview = try makeTextPreview(
                        from: managedFile.data,
                        path: managedFile.path ?? path,
                        name: managedFile.name ?? item.name,
                        markdown: true
                    )
                    guard !Task.isCancelled else { return }
                    preview = textPreview
                } else if item.inferredIsAudio {
                    guard !Task.isCancelled else { return }
                    preview = .audio(managedFile.data)
                } else {
                    let textPreview = try makeTextPreview(
                        from: managedFile.data,
                        path: managedFile.path ?? path,
                        name: managedFile.name ?? item.name,
                        markdown: false
                    )
                    guard !Task.isCancelled else { return }
                    preview = textPreview
                }
            } catch {
                if Task.isCancelled { return }
                lastError = error
                errorMessage = error.localizedDescription
            }
            return
        }

        guard let sessionID = session.sessionId else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { isLoading = false }

        do {
            if item.inferredIsImage {
                let data = try await apiClient.rawFileData(sessionID: sessionID, path: path)
                if let previewData = await ImagePreviewDownsampler.previewDataAsync(
                    from: data,
                    maxPixelSize: ImagePreviewDownsampler.filePreviewMaxPixelSize
                ) {
                    preview = .image(.init(data: previewData, originalByteCount: data.count))
                } else {
                    preview = .unavailable(String(localized: "Could not decode this image."))
                }
            } else if item.inferredIsAudio {
                // Raw bytes (no downsampling) so AVAudioPlayer gets the original
                // encoded audio; checked before the unsupported-binary list,
                // which would otherwise reject m4a/mp3/wav/flac.
                preview = .audio(try await apiClient.rawFileData(sessionID: sessionID, path: path))
            } else if item.documentKind == .pdf {
                let data = try await apiClient.rawFilePreviewData(
                    sessionID: sessionID,
                    path: path,
                    maximumBytes: DocumentPreviewLimits.maximumBytes
                )
                if let document = await PDFPreviewDocument.load(data: data) {
                    preview = .pdf(document)
                } else {
                    preview = .unavailable(String(localized: "Could not decode this PDF."))
                }
            } else if item.documentKind == .markdown {
                let data = try await apiClient.rawFilePreviewData(
                    sessionID: sessionID,
                    path: path,
                    maximumBytes: DocumentPreviewLimits.maximumBytes
                )
                guard let text = String(data: data, encoding: .utf8) else {
                    preview = .unavailable(String(localized: "Could not decode this Markdown document."))
                    return
                }
                preview = .markdown(
                    FileResponse(
                        content: text,
                        path: path,
                        name: item.displayName,
                        language: "markdown",
                        size: data.count,
                        lines: text.split(separator: "\n", omittingEmptySubsequences: false).count,
                        error: nil
                    )
                )
            } else if item.isKnownUnsupportedBinary {
                preview = .unavailable(String(localized: "Preview is not available for this file type."))
            } else {
                preview = .text(try await apiClient.file(sessionID: sessionID, path: path))
            }
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    private func makeTextPreview(
        from data: Data,
        path: String,
        name: String?,
        markdown: Bool
    ) throws -> FilePreviewContent {
        guard data.count <= Self.directTextPreviewMaximumBytes else {
            return .unavailable(String(localized: "This text preview is too large to display."))
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return .unavailable(String(localized: "Could not decode this text file."))
        }

        let file = FileResponse(
            content: text,
            path: path,
            name: name ?? item.displayName,
            language: markdown ? "markdown" : nil,
            size: data.count,
            lines: text.split(separator: "\n", omittingEmptySubsequences: false).count,
            error: nil
        )
        return markdown ? .markdown(file) : .text(file)
    }

    private var localFallbackPreview: FilePreviewContent {
        if item.inferredIsImage, let data = item.localPreviewData {
            return .image(.init(data: data, originalByteCount: data.count))
        }

        return .unavailable(String(localized: "This attachment does not have a server file path."))
    }
}
