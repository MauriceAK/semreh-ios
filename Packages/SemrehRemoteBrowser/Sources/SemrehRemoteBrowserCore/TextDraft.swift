import Foundation

/// Local committed-text draft for native text entry (v1).
///
/// Native composition, autocorrection and emoji edit the local draft; only
/// committed text is sent when Insert is pressed. This is committed-text
/// insertion, not a mirrored remote editor.
///
/// Safety rules:
/// - The draft is preserved when transmission becomes uncertain
///   (`markUnconfirmed` / `markRejected`).
/// - Nothing here resends automatically; a retry is always an explicit new commit.
/// - The draft is cleared only on confirmed receipt.
public struct TextDraft: Equatable, Sendable {
    public enum Delivery: Equatable, Sendable {
        case idle
        case sending
        /// Transmission outcome unknown (acknowledgement lost). The draft is
        /// preserved and marked; it is never resent automatically.
        case unconfirmed
        case confirmed
        case rejected(reason: String)
    }

    public private(set) var text: String
    public private(set) var delivery: Delivery

    public init(text: String = "") {
        self.text = text
        self.delivery = .idle
    }

    /// Local composition/editing. Allowed whenever no send is in flight;
    /// starts a fresh draft (previous confirmed/unconfirmed outcome stays
    /// observable until the edit).
    public mutating func edit(_ newText: String) {
        guard delivery != .sending else { return }
        text = newText
        delivery = .idle
    }

    /// Begin transmission of the current text. Returns the text to send,
    /// or nil when there is nothing to send, a send is already in flight, or
    /// the prior delivery is unconfirmed. Retrying an ambiguous commit first
    /// requires an explicit edit that creates a new local draft.
    public mutating func beginCommit() -> String? {
        switch delivery {
        case .idle, .rejected:
            break
        case .sending, .unconfirmed, .confirmed:
            return nil
        }
        guard !text.isEmpty else { return nil }
        delivery = .sending
        return text
    }

    /// The adapter reported the acknowledgement was lost. The draft is
    /// preserved and marked `unconfirmed`; it is never resent automatically.
    public mutating func markUnconfirmed() {
        guard delivery == .sending else { return }
        delivery = .unconfirmed
    }

    public mutating func markConfirmed() {
        guard delivery == .sending || delivery == .unconfirmed else { return }
        delivery = .confirmed
    }

    /// The adapter rejected the text. The draft is preserved for inspection.
    public mutating func markRejected(reason: String) {
        guard delivery == .sending || delivery == .unconfirmed else { return }
        delivery = .rejected(reason: reason)
    }

    /// Authority changed before a pending delivery was authoritatively
    /// resolved. Preserve the draft and prevent an automatic resend.
    public mutating func invalidatePendingDelivery() {
        guard delivery == .sending else { return }
        delivery = .unconfirmed
    }

    /// Clear the draft. Only valid after confirmed receipt.
    public mutating func clearAfterConfirmation() {
        guard delivery == .confirmed else { return }
        text = ""
        delivery = .idle
    }
}
