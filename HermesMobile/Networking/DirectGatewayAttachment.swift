import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An attachment that can be staged through the direct gateway without ever
/// resolving a client path on the gateway host.
///
/// This is deliberately an in-memory value.  The later send coordinator owns
/// its lifetime and ordering; this type only validates the source bytes and
/// prepares the attachment-specific RPC fields.
enum DirectGatewayAttachmentKind: Equatable, Sendable {
    case image
    case file
    case pdf
}

enum DirectGatewayAttachmentError: Error, Equatable, Sendable {
    case empty
    case malformed
    case unsupportedType
    case unsupportedImageExtension
    case tooLarge(kind: DirectGatewayAttachmentKind, maximumBytes: Int)
}

enum DirectGatewayAttachmentLimits {
    static let imageMaximumBytes = 25 * 1_024 * 1_024
    static let pdfMaximumBytes = 50 * 1_024 * 1_024

    /// Client-side memory/back-pressure policy for generic files. This is not
    /// a stock Hermes protocol cap; the pinned server's `file.attach` path has
    /// no source-byte limit of its own. It matches the PDF client policy while
    /// keeping base64 preparation bounded on mobile.
    static let fileMaximumBytes: Int? = 50 * 1_024 * 1_024

    static func maximumBytes(for kind: DirectGatewayAttachmentKind) -> Int? {
        switch kind {
        case .image:
            return imageMaximumBytes
        case .file:
            return fileMaximumBytes
        case .pdf:
            return pdfMaximumBytes
        }
    }
}

struct DirectGatewayAttachment: Equatable, Sendable {
    let kind: DirectGatewayAttachmentKind
    /// The original source bytes are retained for draft/retry ownership.  No
    /// disk path is retained or emitted in the direct RPC parameters.
    let originalBytes: Data
    let displayFilename: String
    let mimeType: String
    let uniformTypeIdentifier: String

    init(
        data: Data,
        filename: String,
        typeIdentifier: String? = nil
    ) throws {
        let normalizedFilename = Self.normalizedFilename(filename)
        let suppliedType = typeIdentifier.flatMap(UTType.init)
        let filenameType = UTType(filenameExtension: URL(fileURLWithPath: normalizedFilename).pathExtension)
        let inferredType = suppliedType ?? filenameType ?? .data
        let inferredKind: DirectGatewayAttachmentKind

        if inferredType.conforms(to: .pdf) || URL(fileURLWithPath: normalizedFilename).pathExtension.lowercased() == "pdf" {
            inferredKind = .pdf
        } else if inferredType.conforms(to: .image) || Self.supportedImageExtensions.contains(
            URL(fileURLWithPath: normalizedFilename).pathExtension.lowercased()
        ) {
            inferredKind = .image
        } else {
            inferredKind = .file
        }

        try self.init(
            data: data,
            filename: normalizedFilename,
            kind: inferredKind,
            type: inferredType
        )
    }

    init(
        data: Data,
        filename: String,
        kind: DirectGatewayAttachmentKind,
        typeIdentifier: String? = nil
    ) throws {
        let normalizedFilename = Self.normalizedFilename(filename)
        let suppliedType = typeIdentifier.flatMap(UTType.init)
        let filenameType = UTType(filenameExtension: URL(fileURLWithPath: normalizedFilename).pathExtension)
        let type = suppliedType ?? filenameType ?? Self.defaultType(for: kind)

        try self.init(data: data, filename: normalizedFilename, kind: kind, type: type)
    }

    private init(
        data: Data,
        filename: String,
        kind: DirectGatewayAttachmentKind,
        type: UTType
    ) throws {
        guard !data.isEmpty else { throw DirectGatewayAttachmentError.empty }
        try Self.validate(byteCount: data.count, kind: kind)

        let filenameWithExtension = Self.filenameWithExtension(filename, for: kind, type: type)
        let extensionName = URL(fileURLWithPath: filenameWithExtension).pathExtension.lowercased()
        // Apple's UTType mapping reports `audio/x-m4a` on some SDKs, while
        // Hermes' recorder/transcription contract accepts the standard MP4
        // audio media type for `.m4a` clips.
        let mimeType: String
        if kind == .file && extensionName == "m4a" {
            mimeType = "audio/mp4"
        } else {
            mimeType = UTType(filenameExtension: extensionName)?.preferredMIMEType
                ?? type.preferredMIMEType
                ?? Self.defaultMIMEType(for: kind)
        }

        switch kind {
        case .image:
            guard Self.supportedImageExtensions.contains(extensionName) else {
                throw DirectGatewayAttachmentError.unsupportedImageExtension
            }
            guard Self.isValidImage(data, extensionName: extensionName) else {
                throw DirectGatewayAttachmentError.malformed
            }
        case .pdf:
            guard extensionName == "pdf", data.prefix(5) == Data("%PDF-".utf8) else {
                throw DirectGatewayAttachmentError.malformed
            }
        case .file:
            break
        }

        self.kind = kind
        self.originalBytes = data
        self.displayFilename = filenameWithExtension
        self.mimeType = mimeType
        self.uniformTypeIdentifier = type.identifier
    }

    static func image(data: Data, filename: String, typeIdentifier: String? = nil) throws -> Self {
        try Self(data: data, filename: filename, kind: .image, typeIdentifier: typeIdentifier)
    }

    static func file(data: Data, filename: String, typeIdentifier: String? = nil) throws -> Self {
        try Self(data: data, filename: filename, kind: .file, typeIdentifier: typeIdentifier)
    }

    static func pdf(data: Data, filename: String = "attachment.pdf", typeIdentifier: String? = nil) throws -> Self {
        try Self(data: data, filename: filename, kind: .pdf, typeIdentifier: typeIdentifier)
    }

    /// Pure byte-count validation lets tests exercise cap boundaries without
    /// allocating 25/50 MiB fixtures.
    static func validate(byteCount: Int, kind: DirectGatewayAttachmentKind) throws {
        guard byteCount > 0 else { throw DirectGatewayAttachmentError.empty }
        if let maximumBytes = DirectGatewayAttachmentLimits.maximumBytes(for: kind), byteCount > maximumBytes {
            throw DirectGatewayAttachmentError.tooLarge(kind: kind, maximumBytes: maximumBytes)
        }
    }

    /// Returns only the attachment fields.  The session ID and RPC method are
    /// intentionally owned by the later controller.  `file.attach` receives a
    /// data URL and name, never a client path.
    func rpcParameters() async throws -> [String: JSONValue] {
        try Task.checkCancellation()
        let bytes = originalBytes
        let kind = kind
        let filename = displayFilename
        let mimeType = mimeType
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let base64 = bytes.base64EncodedString()
            try Task.checkCancellation()

            switch kind {
            case .image:
                return [
                    "content_base64": JSONValue.string(base64),
                    "filename": JSONValue.string(filename)
                ]
            case .file:
                return [
                    "data_url": JSONValue.string("data:\(mimeType);base64,\(base64)"),
                    "name": JSONValue.string(filename)
                ]
            case .pdf:
                return [
                    "content_base64": JSONValue.string(base64),
                    "filename": JSONValue.string(filename)
                ]
            }
        }

        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    // Exact pinned-stock `cli._IMAGE_EXTENSIONS` set (source 29112bef).
    private static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "ico"
    ]

    private static func defaultType(for kind: DirectGatewayAttachmentKind) -> UTType {
        switch kind {
        case .image:
            return .png
        case .file:
            return .data
        case .pdf:
            return .pdf
        }
    }

    private static func defaultMIMEType(for kind: DirectGatewayAttachmentKind) -> String {
        switch kind {
        case .image:
            return "image/png"
        case .file:
            return "application/octet-stream"
        case .pdf:
            return "application/pdf"
        }
    }

    private static func normalizedFilename(_ rawFilename: String) -> String {
        let pathStripped = rawFilename
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""
        let controlsReplaced = pathStripped.map { character in
            character.unicodeScalars.allSatisfy { $0.value < 0x20 } ? "_" : String(character)
        }.joined()
        let trimmed = controlsReplaced.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "attachment" : trimmed
    }

    private static func filenameWithExtension(_ filename: String, for kind: DirectGatewayAttachmentKind, type: UTType) -> String {
        guard URL(fileURLWithPath: filename).pathExtension.isEmpty,
              let preferredExtension = type.preferredFilenameExtension,
              !preferredExtension.isEmpty else {
            return filename
        }
        if kind == .file, type == .data { return filename }
        return "\(filename).\(preferredExtension)"
    }

    private static func isValidImage(_ data: Data, extensionName: String) -> Bool {
        if extensionName == "svg" {
            guard let text = String(data: Data(data.prefix(512)), encoding: .utf8) else { return false }
            return text.range(of: "<svg", options: [.caseInsensitive]) != nil
        }
        if extensionName == "ico" {
            return data.starts(with: [0x00, 0x00, 0x01, 0x00])
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return false
        }
        return CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }
}
