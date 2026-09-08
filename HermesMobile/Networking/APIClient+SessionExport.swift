import Foundation

/// Stock exports JSON; HTML is a self-contained local presentation of that export.
enum SessionExportFormat: String, CaseIterable {
    case html
    case json

    var fileExtension: String { rawValue }
}

/// A downloaded session export: the raw file bytes plus the filename the share
/// sheet should offer (never "download.bin").
struct SessionExportFile: Equatable {
    let data: Data
    let filename: String
}

extension APIClient {
    /// Bound stock's streaming JSON before decoding/rendering; never silently truncate.
    func exportSession(
        id: String,
        format: SessionExportFormat,
        fallbackTitle: String? = nil,
        profile: String,
        maximumBytes: Int = 20 * 1_024 * 1_024
    ) async throws -> SessionExportFile {
        var components = URLComponents()
        components.path = "/api/sessions/\(id)/export"
        components.queryItems = [URLQueryItem(name: "profile", value: profile)]
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\"),
              id.rangeOfCharacter(from: .controlCharacters) == nil,
              !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let relative = components.string, let url = URL(string: relative, relativeTo: baseURL) else {
            throw SessionExportError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        customHeaderProvider().apply(to: &request)
        let protected = URLSession(configuration: session.configuration,
            delegate: DirectHermesRedirectGuard(origin: baseURL), delegateQueue: nil)
        defer { protected.invalidateAndCancel() }
        let data: Data
        do {
            data = try await boundedData(for: request, using: protected, mapsUnauthorized: false,
                maximumBytes: maximumBytes).0
        } catch let APIError.http(statusCode, body) {
            let bytes = Data((body ?? "").utf8)
            if DirectHermesAuthFailureClassifier.isSessionExpired(statusCode: statusCode, body: bytes) {
                throw DirectHermesAuthError.sessionExpired
            }
            throw DirectHermesRequestError.from(statusCode: statusCode, body: bytes)
        }
        try Task.checkCancellation()
        let rendering = Task.detached {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["id"] as? String == id,
                  (object["profile"] as? String ?? profile) == profile,
                  object["messages"] is [[String: Any]] else { throw SessionExportError.invalidResponse }
            return format == .json ? data : try SessionExportFile.html(from: object)
        }
        let output = try await withTaskCancellationHandler {
            try await rendering.value
        } onCancel: { rendering.cancel() }
        let filename = SessionExportFile.filename(
            contentDisposition: nil,
            fallbackTitle: fallbackTitle,
            sessionID: id,
            format: format
        )

        try Task.checkCancellation()
        return SessionExportFile(data: output, filename: filename)
    }
}

enum SessionExportError: LocalizedError {
    case invalidResponse, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Hermes returned an invalid session export."
        case .tooLarge: "The HTML export exceeds the 40 MiB size limit. Export JSON instead."
        }
    }
}

extension SessionExportFile {
    static func write(_ data: Data, to url: URL) async throws {
        let writer = Task.detached {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler {
            try await writer.value
        } onCancel: { writer.cancel() }
    }

    static func html(from object: [String: Any], maximumBytes: Int = 40 * 1_024 * 1_024) throws -> Data {
        var output = Data()
        func append(_ text: String) throws {
            let bytes = Data(text.utf8)
            guard bytes.count <= maximumBytes - output.count else { throw SessionExportError.tooLarge }
            output.append(bytes)
        }
        func escaped(_ text: String) throws {
            var pending = ""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "&": pending += "&amp;"
                case "<": pending += "&lt;"
                case ">": pending += "&gt;"
                case "\"": pending += "&quot;"
                case "'": pending += "&#39;"
                default: pending.unicodeScalars.append(scalar)
                }
                if pending.utf8.count >= 4096 {
                    try Task.checkCancellation()
                    try append(pending)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            try append(pending)
        }
        func json(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        }
        try append("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\"><title>Session export</title><style>body{font:16px system-ui;max-width:900px;margin:24px auto;padding:0 16px}pre{white-space:pre-wrap;overflow-wrap:anywhere}section{border-top:1px solid #888;padding:12px 0}</style></head><body><h1>")
        try escaped(object["title"] as? String ?? "Session export")
        try append("</h1><details><summary>Session metadata</summary><pre>")
        var metadata = object
        metadata.removeValue(forKey: "messages")
        try escaped(json(metadata))
        try append("</pre></details>")
        for message in object["messages"] as? [[String: Any]] ?? [] {
            try Task.checkCancellation()
            try append("<section><h2>")
            try escaped(message["role"] as? String ?? "Message")
            try append("</h2><pre>")
            if let content = message["content"] as? String { try escaped(content) }
            else if let content = message["content"] { try escaped(json(["content": content])) }
            try append("</pre><details><summary>Complete message and tool metadata</summary><pre>")
            try escaped(json(message))
            try append("</pre></details></section>")
        }
        try append("</body></html>")
        return output
    }
    /// Derives the filename to offer in the share sheet.
    ///
    /// Preference order:
    /// 1. `filename="…"` (or unquoted `filename=…`) from `Content-Disposition`.
    /// 2. Sanitized session title + the format's extension.
    /// 3. `hermes-<session-id>.<ext>` (mirrors the upstream server's own name).
    static func filename(
        contentDisposition: String?,
        fallbackTitle: String?,
        sessionID: String,
        format: SessionExportFormat
    ) -> String {
        if let headerName = filenameParameter(in: contentDisposition),
           let sanitized = sanitizedFilename(headerName) {
            return sanitized
        }

        if let title = fallbackTitle,
           let sanitizedTitle = sanitizedFilenameStem(title) {
            return "\(sanitizedTitle).\(format.fileExtension)"
        }

        let sanitizedID = sanitizedFilenameStem(sessionID) ?? "session"
        return "hermes-\(sanitizedID).\(format.fileExtension)"
    }

    /// Extracts the `filename` parameter value from a `Content-Disposition`
    /// header (quoted or bare token). Intentionally does not implement the
    /// RFC 5987 `filename*=` extended form — upstream never sends it, and the
    /// sanitized fallback covers any server that does.
    private static func filenameParameter(in contentDisposition: String?) -> String? {
        guard let contentDisposition else { return nil }

        for parameter in contentDisposition.split(separator: ";").dropFirst() {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard let separatorIndex = trimmed.firstIndex(of: "=") else { continue }

            let key = trimmed[..<separatorIndex].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "filename" else { continue }

            var value = trimmed[trimmed.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }

        return nil
    }

    /// Keeps only the last path component and strips characters that are
    /// unsafe in filenames, so a hostile/buggy header can't escape the temp
    /// directory or produce an unusable name.
    private static func sanitizedFilename(_ raw: String) -> String? {
        let lastComponent = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? raw

        let cleaned = replacingUnsafeFilenameCharacters(in: lastComponent)
        guard !cleaned.isEmpty, cleaned != "." , cleaned != ".." else { return nil }
        return cleaned
    }

    /// Sanitizes free text (session title / ID) into a filename stem, or nil
    /// when nothing usable remains.
    private static func sanitizedFilenameStem(_ raw: String) -> String? {
        let cleaned = replacingUnsafeFilenameCharacters(in: raw)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(80))
    }

    private static func replacingUnsafeFilenameCharacters(in raw: String) -> String {
        var unsafe = CharacterSet(charactersIn: "/\\:")
        unsafe.formUnion(.controlCharacters)
        unsafe.formUnion(.newlines)
        unsafe.formUnion(.illegalCharacters)

        let replaced = raw.unicodeScalars
            .map { unsafe.contains($0) ? " " : Character($0) }
            .reduce(into: "") { $0.append($1) }

        // Collapse whitespace runs and trim so titles like "  a  /  b  " come
        // out as "a b" rather than "a    b".
        return replaced
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
