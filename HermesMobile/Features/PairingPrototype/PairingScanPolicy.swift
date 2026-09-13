import Foundation

/// One result per visible, active presentation; never retains raw QR content.
struct PairingScanPolicy {
    private(set) var generation = UUID()
    private(set) var active = false
    private(set) var consumed = false

    mutating func setActive(_ value: Bool) {
        if active != value { generation = UUID() }
        active = value
    }

    mutating func admit(_ text: String, generation candidate: UUID) throws -> PairingImport? {
        guard active, !consumed, candidate == generation else { return nil }
        // Invalid codes don't consume the presentation. The user can aim again.
        let value = try PairingImport.parse(text)
        consumed = true
        return value
    }
}
