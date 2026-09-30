import Foundation

/// Pure helpers for pacing streamed assistant text at a word cadence (issue #212).
///
/// The streaming flush pipeline reveals buffered tokens word-by-word instead of
/// dumping whole burst batches into the transcript at once. A drainable "unit" is
/// one word plus its trailing whitespace; leading whitespace attaches to the first
/// unit, and a trailing in-progress word counts as a unit so buffers without
/// whitespace still drain. Splitting walks `Character`s (grapheme clusters), so
/// emoji/ZWJ sequences and combining marks are never split, and `head + tail`
/// always reproduces the input exactly — pacing can never alter final content.
enum StreamingWordDrain {
    /// Keeps the backlog count current as chunks arrive. A paced tick then
    /// scans only the prefix it will reveal, instead of recounting the entire
    /// pending suffix on every tick. The text remains one String so a grapheme
    /// split across network chunks is still treated as one character.
    struct Buffer {
        private(set) var text = ""
        private(set) var unitCount = 0
        private var hasSeenNonWhitespace = false
        private var previousWasWhitespace = false

        var isEmpty: Bool { text.isEmpty }

        mutating func append(_ chunk: String) {
            guard !chunk.isEmpty else { return }

            // A combining mark or ZWJ may join the previous chunk's final
            // grapheme. Recount that uncommon boundary rather than relying on
            // the old character classification (including whitespace + mark).
            let joinsPreviousGrapheme: Bool
            if let last = text.last, let first = chunk.first {
                joinsPreviousGrapheme = (String(last) + String(first)).count != 2
            } else {
                joinsPreviousGrapheme = false
            }
            text.append(chunk)
            if joinsPreviousGrapheme {
                recount()
                return
            }

            for character in chunk {
                let isWhitespace = character.isWhitespace
                if unitCount == 0 {
                    unitCount = 1
                } else if previousWasWhitespace, !isWhitespace, hasSeenNonWhitespace {
                    unitCount += 1
                }
                if !isWhitespace { hasSeenNonWhitespace = true }
                previousWasWhitespace = isWhitespace
            }
        }

        mutating func drain(maxUnits: Int) -> String {
            guard maxUnits > 0, !text.isEmpty else { return "" }
            if maxUnits >= unitCount {
                let result = text
                clear()
                return result
            }

            let (head, tail) = StreamingWordDrain.splitAtUnitBoundary(text, unitCount: maxUnits)
            text = tail
            unitCount -= maxUnits
            // A nonempty split tail begins at the next nonwhitespace word.
            hasSeenNonWhitespace = true
            previousWasWhitespace = tail.last?.isWhitespace ?? false
            return head
        }

        mutating func drainAll() -> String {
            let result = text
            clear()
            return result
        }

        mutating func clear() {
            text = ""
            unitCount = 0
            hasSeenNonWhitespace = false
            previousWasWhitespace = false
        }

        private mutating func recount() {
            unitCount = 0
            hasSeenNonWhitespace = false
            previousWasWhitespace = false
            for character in text {
                let isWhitespace = character.isWhitespace
                if unitCount == 0 {
                    unitCount = 1
                } else if previousWasWhitespace, !isWhitespace, hasSeenNonWhitespace {
                    unitCount += 1
                }
                if !isWhitespace { hasSeenNonWhitespace = true }
                previousWasWhitespace = isWhitespace
            }
        }
    }

    /// Number of drainable word units in `text`.
    static func unitCount(in text: String) -> Int {
        var count = 0
        var hasSeenNonWhitespace = false
        var previousWasWhitespace = false
        for character in text {
            let isWhitespace = character.isWhitespace
            if count == 0 {
                count = 1
            } else if previousWasWhitespace, !isWhitespace, hasSeenNonWhitespace {
                count += 1
            }
            if !isWhitespace {
                hasSeenNonWhitespace = true
            }
            previousWasWhitespace = isWhitespace
        }
        return count
    }

    /// Splits `text` after its first `unitCount` units; `head + tail == text`.
    /// A non-positive count returns everything in `tail`; a count at or beyond
    /// the backlog returns everything in `head`.
    static func splitAtUnitBoundary(_ text: String, unitCount: Int) -> (head: String, tail: String) {
        guard unitCount > 0, !text.isEmpty else { return ("", text) }

        var unitsSeen = 0
        var hasSeenNonWhitespace = false
        var previousWasWhitespace = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let isWhitespace = character.isWhitespace
            if unitsSeen == 0 {
                unitsSeen = 1
            } else if previousWasWhitespace, !isWhitespace, hasSeenNonWhitespace {
                unitsSeen += 1
                if unitsSeen > unitCount {
                    return (String(text[..<index]), String(text[index...]))
                }
            }
            if !isWhitespace {
                hasSeenNonWhitespace = true
            }
            previousWasWhitespace = isWhitespace
            index = text.index(after: index)
        }
        return (text, "")
    }

    /// Units to drain on one cadence tick. Normally one word per tick; when the
    /// backlog would take longer than `maxLagNanoseconds` to drain at
    /// `cadenceNanoseconds` per word, the quota scales up proportionally so the
    /// display catches up to the live stream within the lag bound.
    static func drainQuota(
        backlogUnitCount: Int,
        cadenceNanoseconds: UInt64,
        maxLagNanoseconds: UInt64
    ) -> Int {
        guard backlogUnitCount > 1 else { return 1 }
        guard cadenceNanoseconds > 0, maxLagNanoseconds > 0 else { return backlogUnitCount }

        let drainNanoseconds = Double(backlogUnitCount) * Double(cadenceNanoseconds)
        let quota = Int((drainNanoseconds / Double(maxLagNanoseconds)).rounded(.up))
        return min(backlogUnitCount, max(1, quota))
    }
}
