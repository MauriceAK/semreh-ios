import Foundation

/// App-defined address import, not a Hermes authentication or trust protocol.
struct PairingImport: Equatable, Identifiable {
    let origin: URL
    var id: String { origin.absoluteString }

    enum Failure: Error { case tooLarge, invalidPayload, unsupportedVersion, invalidOrigin }

    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 2048 else { throw Failure.tooLarge }
        // Most administrators can share an ordinary QR containing the server
        // origin. Keep the custom versioned envelope for compatibility, but
        // route raw HTTPS origins through the exact same strict validator.
        if text.hasPrefix("https://") { return try validateOrigin(text) }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["type", "version", "origin"]),
              object["type"] as? String == "semreh-pairing",
              let version = object["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              let origin = object["origin"] as? String else { throw Failure.invalidPayload }
        guard version == 1 else { throw Failure.unsupportedVersion }
        return try validateOrigin(origin)
    }

    static func validateOrigin(_ raw: String) throws -> Self {
        // ASCII-only avoids invisible characters, Unicode hostname substitutions,
        // and URLComponents' permissive escaping/repair of malformed input.
        guard raw.utf8.count <= 512,
              raw.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              !raw.contains("%"), !raw.contains("\\"),
              let parts = URLComponents(string: raw), parts.scheme == "https",
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let host = parts.host, !host.isEmpty, host.count <= 253,
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                  && !label.lowercased().hasPrefix("xn--")
                  && label.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 })
              }), parts.port.map({ (1...65535).contains($0) }) ?? true,
              // Reject malformed authority spellings such as an empty port.
              raw == "https://" + host + (parts.port.map { ":\($0)" } ?? "") + parts.path
        else { throw Failure.invalidOrigin }
        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = host.lowercased()
        normalized.port = parts.port == 443 ? nil : parts.port
        guard let url = normalized.url else { throw Failure.invalidOrigin }
        return Self(origin: url)
    }
}

import CoreFoundation

/// Pure local state. No storage, network, credentials or account switching.
struct PairingSession {
    enum Stage: Equatable {
        case introduction
        case review(PairingImport)
        case checking(PairingImport, UUID)
        case signIn(PairingImport)
        case unsupported(PairingImport)
        case unreachable(PairingImport)
        case authenticated(PairingImport)
        case ready(PairingImport)
    }
    enum Discovery { case passwordSignIn, unsupported, unreachable }
    private(set) var stage: Stage = .introduction

    mutating func importCode(_ text: String) throws {
        stage = .introduction // A failed replacement cannot leave an old address actionable.
        stage = .review(try PairingImport.parse(text))
    }
    mutating func enterManually(_ text: String) throws {
        stage = .introduction
        stage = .review(try PairingImport.validateOrigin(text))
    }
    mutating func cancel() { stage = .introduction }
    mutating func confirm() -> UUID? {
        guard case let .review(value) = stage else { return nil }
        let attempt = UUID()
        stage = .checking(value, attempt)
        return attempt
    }
    mutating func discovered(_ result: Discovery, attempt: UUID) {
        guard case let .checking(value, active) = stage, active == attempt else { return }
        switch result {
        case .passwordSignIn: stage = .signIn(value)
        case .unsupported: stage = .unsupported(value)
        case .unreachable: stage = .unreachable(value)
        }
    }
    // Authentication and gateway readiness are separate adapter-owned facts.
    // This prototype deliberately exposes no function that manufactures either.
}
