import Foundation

/// Transcription payload shared by legacy voice-note and direct dictation callers.
///
/// The server returns `{ok, transcript}` on success and `{error}` on failure —
/// and it sends a JSON `{error: ...}` body even with a non-2xx status (e.g. 503
/// when STT isn't configured). Every field is optional and unknown keys are
/// ignored, so a future server addition never crashes decoding. The direct
/// adapter additionally requires ok=true and a present transcript, and routes
/// non-success HTTP responses through the stock error classifier.
struct TranscribeResponse: Codable {
    let ok: Bool?
    let transcript: String?
    let error: String?
}
