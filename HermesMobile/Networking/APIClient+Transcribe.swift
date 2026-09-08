import Foundation

enum DirectTranscriptionError: LocalizedError {
    case invalidRecording, recordingTooLarge, invalidAcknowledgement
    var errorDescription: String? {
        switch self {
        case .invalidRecording: return "The audio recording is empty or its format is unsupported."
        case .recordingTooLarge: return "The audio recording exceeds the 25 MiB upload limit."
        case .invalidAcknowledgement: return "The server returned an invalid transcription response."
        }
    }
}

extension APIClient {
    static let maximumTranscriptionBytes = 25 * 1_024 * 1_024

    /// Stock Hermes selects STT using this explicit profile's configuration.
    func transcribeAudio(data: Data, mimeType: String, profile: String) async throws -> TranscribeResponse {
        guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.contains("\0") else { throw APIError.invalidServerURL }
        guard !data.isEmpty, ["audio/wav", "audio/mp4", "audio/mpeg", "audio/webm", "audio/ogg", "audio/flac"].contains(mimeType) else {
            throw DirectTranscriptionError.invalidRecording
        }
        guard data.count <= Self.maximumTranscriptionBytes else { throw DirectTranscriptionError.recordingTooLarge }
        var path = URLComponents()
        path.path = "/api/audio/transcribe"
        path.queryItems = [URLQueryItem(name: "profile", value: profile)]
        guard let path = path.string else { throw APIError.invalidServerURL }
        let body = ["data_url": "data:\(mimeType);base64,\(data.base64EncodedString())", "mime_type": mimeType]
        let responseData = try await sendDirectData(path: path, method: "POST",
            encodedBody: JSONEncoder().encode(body), classifyStructuredAuthExpiry: true)
        let response = try decode(TranscribeResponse.self, from: responseData)
        guard response.ok == true, response.transcript != nil, response.error == nil else {
            throw DirectTranscriptionError.invalidAcknowledgement
        }
        return response
    }
}
