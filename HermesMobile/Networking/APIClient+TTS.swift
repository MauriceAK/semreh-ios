import Foundation

private struct TTSSynthesisRequest: Encodable {
    let text: String
}

enum DirectTTSAudioResponse {
    static let maximumDecodedBytes = 25 * 1_024 * 1_024
    static let maximumEnvelopeBytes = ((maximumDecodedBytes + 2) / 3) * 4 + 64 * 1_024

    private struct Envelope: Decodable {
        let ok: Bool?
        let dataURL: String?
        let mimeType: String?
        enum CodingKeys: String, CodingKey {
            case ok
            case dataURL = "data_url"
            case mimeType = "mime_type"
        }
    }

    enum DecodeError: Error { case invalidEnvelope, invalidMIME, invalidAudio }

    static func decode(_ data: Data, maximumDecodedBytes: Int = maximumDecodedBytes) throws -> Data {
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.ok == true, let dataURL = envelope.dataURL, let mime = envelope.mimeType else {
                throw DecodeError.invalidEnvelope
            }
            guard ["audio/mpeg", "audio/ogg", "audio/wav", "audio/flac"].contains(mime),
                  dataURL.hasPrefix("data:\(mime);base64,") else {
                throw DecodeError.invalidMIME
            }
            let encoded = String(dataURL.dropFirst("data:\(mime);base64,".count))
            guard encoded.utf8.count <= ((maximumDecodedBytes + 2) / 3) * 4 else {
                throw PreviewDownloadError.responseTooLarge(maximumBytes: maximumDecodedBytes)
            }
            guard !encoded.isEmpty, let audio = Data(base64Encoded: encoded),
                  !audio.isEmpty, audio.base64EncodedString() == encoded else {
                throw DecodeError.invalidAudio
            }
            guard audio.count <= maximumDecodedBytes else {
                throw PreviewDownloadError.responseTooLarge(maximumBytes: maximumDecodedBytes)
            }
            return audio
        } catch let error as PreviewDownloadError { throw error }
        catch { throw APIError.decoding(underlying: error) }
    }
}

extension APIClient {
    /// Stock Hermes chooses the configured TTS provider and voice. The endpoint
    /// accepts only text and returns a JSON data URL; callers retain on-device
    /// speech fallback for unavailable synthesis or unsupported audio playback.
    func synthesizeSpeech(text: String, profile: String) async throws -> Data {
        guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.contains("\0") else { throw APIError.invalidServerURL }
        var components = URLComponents(url: baseURL.appending(path: "/api/audio/speak"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "profile", value: profile)]
        guard let url = components?.url else { throw APIError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        customHeaderProvider().apply(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TTSSynthesisRequest(text: text))

        // Retain injected session configuration and cookies while refusing
        // redirects that could forward spoken text or credentials off-origin.
        let data: Data
        let response: HTTPURLResponse
        (data, response) = try await boundedSameOriginDirectData(
            for: request, maximumBytes: DirectTTSAudioResponse.maximumEnvelopeBytes
        )
        guard response.mimeType?.lowercased() == "application/json" else {
            throw APIError.decoding(underlying: DirectTTSAudioResponse.DecodeError.invalidEnvelope)
        }
        return try DirectTTSAudioResponse.decode(data)
    }
}
