import Foundation

/// Display-only projection for the directive lines Hermes persists in direct
/// user messages. The server reference remains opaque: this helper never
/// resolves a path on the phone or checks the file system.
struct DirectHermesMessageAttachmentProjection: Equatable {
    let cleanedText: String
    let attachments: [MessageAttachment]

    private struct FenceState {
        let character: Character
        let length: Int
    }

    static func project(userContent content: String) -> Self {
        var retainedLines: [String] = []
        var attachments: [MessageAttachment] = []
        var fenceState: FenceState?

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let activeFence = fenceState {
                retainedLines.append(line)
                if let run = fenceRun(in: trimmed),
                   run.character == activeFence.character,
                   run.length >= activeFence.length,
                   run.suffix.allSatisfy(\.isWhitespace) {
                    fenceState = nil
                }
                continue
            }

            if let marker = openingFence(in: trimmed) {
                retainedLines.append(line)
                fenceState = marker
                continue
            }

            guard let attachment = attachment(fromStandaloneLine: line) else {
                retainedLines.append(line)
                continue
            }

            attachments.append(attachment)
        }

        return Self(
            cleanedText: retainedLines
                .joined(separator: "\n"),
            attachments: attachments
        )
    }

    /// Native-vision transcript rows persist one typed text part followed by
    /// non-text image parts. Project only that exact shape; the original parts
    /// remain owned by ChatMessage and are never rewritten here.
    static func project(userParts parts: [JSONValue]) -> Self? {
        var text: String?
        var nonTextPartCount = 0

        for part in parts {
            guard case .object(let object) = part,
                  case .string(let type) = object["type"]
            else {
                return nil
            }

            if ["image", "image_url", "input_image"].contains(type) {
                nonTextPartCount += 1
                continue
            }

            guard type == "text" else { return nil }

            guard text == nil,
                  case .string(let value) = object["text"]
            else {
                return nil
            }
            text = value
        }

        guard let text, nonTextPartCount > 0 else { return nil }
        return project(userContent: text)
    }

    /// Merge inferred directive attachments without replacing authoritative
    /// metadata returned in the row's explicit `attachments` field.
    static func merge(
        explicit: [MessageAttachment]?,
        inferred: [MessageAttachment]
    ) -> [MessageAttachment]? {
        var result = explicit ?? []
        var existingPaths = Set(result.compactMap(opaquePath(for:)))
        var explicitNameOnlyIndices: [String: [Int]] = [:]
        for index in result.indices where opaquePath(for: result[index]) == nil {
            if let name = displayNameKey(for: result[index]) {
                explicitNameOnlyIndices[name, default: []].append(index)
            }
        }

        var inferredPathsByName: [String: Set<String>] = [:]
        for attachment in inferred {
            if let name = displayNameKey(for: attachment),
               let path = opaquePath(for: attachment) {
                inferredPathsByName[name, default: []].insert(path)
            }
        }

        for attachment in inferred {
            if let path = opaquePath(for: attachment) {
                if existingPaths.contains(path) {
                    continue
                }
                if let name = displayNameKey(for: attachment),
                   let indices = explicitNameOnlyIndices[name],
                   indices.count == 1,
                   inferredPathsByName[name]?.count == 1,
                   let index = indices.first {
                    let existing = result[index]
                    result[index] = MessageAttachment(
                        name: existing.name ?? attachment.name,
                        path: path,
                        mime: existing.mime ?? attachment.mime,
                        size: existing.size ?? attachment.size,
                        isImage: existing.isImage ?? attachment.isImage
                    )
                    existingPaths.insert(path)
                    continue
                }
                result.append(attachment)
                existingPaths.insert(path)
                continue
            }

            guard let name = displayNameKey(for: attachment) else {
                result.append(attachment)
                continue
            }
            let hasExactNameOnly = result.contains { existing in
                opaquePath(for: existing) == nil && displayNameKey(for: existing) == name
            }
            if !hasExactNameOnly {
                result.append(attachment)
            }
        }

        return result.isEmpty ? nil : result
    }

    private static func openingFence(in line: String) -> FenceState? {
        guard let run = fenceRun(in: line), run.length >= 3 else { return nil }
        return FenceState(character: run.character, length: run.length)
    }

    private static func fenceRun(in line: String) -> (character: Character, length: Int, suffix: Substring)? {
        guard let character = line.first, character == "`" || character == "~" else { return nil }
        var end = line.startIndex
        var length = 0
        while end < line.endIndex, line[end] == character {
            length += 1
            end = line.index(after: end)
        }
        return (character, length, line[end...])
    }

    private static func attachment(fromStandaloneLine line: String) -> MessageAttachment? {
        let kind: (prefix: String, isImage: Bool)
        if line.hasPrefix("@image:") {
            kind = ("@image:", true)
        } else if line.hasPrefix("@file:") {
            kind = ("@file:", false)
        } else {
            return nil
        }

        let rawValue = String(line.dropFirst(kind.prefix.count))
        guard let path = unquotedReferenceValue(rawValue), !path.isEmpty else {
            return nil
        }

        let basename = URL(fileURLWithPath: path).lastPathComponent
        let name = basename.isEmpty ? path : basename
        return MessageAttachment(name: name, path: path, isImage: kind.isImage)
    }

    private static func unquotedReferenceValue(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }

        if let first = raw.first, ["`", "\"", "'"].contains(first) {
            guard raw.count >= 2, raw.last == first else { return nil }
            let inner = String(raw.dropFirst().dropLast())
            guard !inner.isEmpty,
                  !inner.allSatisfy(\.isWhitespace),
                  !inner.contains(first)
            else { return nil }
            return inner
        }

        // Canonical formatRefValue quotes values containing whitespace. Keep
        // malformed unquoted forms visible instead of silently truncating them.
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.contains(where: { $0.isWhitespace }) else { return nil }
        return raw
    }

    private static func opaquePath(for attachment: MessageAttachment) -> String? {
        let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }

    private static func displayNameKey(for attachment: MessageAttachment) -> String? {
        let name = attachment.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }
}
