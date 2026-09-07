import Foundation

/// Identity captured with a single server-owned blocking request. Runtime and
/// connection fields are intentionally transient; they are never persisted.
struct GatewayBlockingPromptIdentity: Equatable, Sendable {
    let origin: String
    let profile: String
    let storedID: String
    let runtimeID: String
    let connectionGeneration: Int
    let requestID: String
}

struct GatewayBlockingPrompt: Equatable, Sendable {
    let identity: GatewayBlockingPromptIdentity
    let question: String
    let choices: [String]
    let multiSelect: Bool
}

enum GatewayBlockingResponse: Equatable, Sendable {
    case accepted
    case expired
}

enum GatewayBlockingError: Error, Equatable, Sendable {
    case malformedClarification
    case unsupportedBatchClarification
    case unsupportedMultiSelectClarification
    case noPendingClarification
    case staleClarification
    case invalidClarificationResponse
    case responseInFlight
}

extension GatewayBlockingPrompt {
    static func decode(
        payload: JSONValue?,
        identity: GatewayBlockingPromptIdentity
    ) throws -> Self {
        guard case .object(let fields) = payload else {
            throw GatewayBlockingError.malformedClarification
        }
        if fields["questions"] != nil {
            throw GatewayBlockingError.unsupportedBatchClarification
        }
        if let rawMultiSelect = fields["multi_select"] {
            guard case .bool(let multiSelect) = rawMultiSelect else {
                throw GatewayBlockingError.malformedClarification
            }
            if multiSelect {
                throw GatewayBlockingError.unsupportedMultiSelectClarification
            }
        }
        guard fields["request_id"]?.gatewayString == identity.requestID,
              let question = fields["question"]?.gatewayString else {
            throw GatewayBlockingError.malformedClarification
        }

        let choices: [String]
        if let rawChoices = fields["choices"] {
            guard case .array(let values) = rawChoices else {
                throw GatewayBlockingError.malformedClarification
            }
            choices = values.compactMap { value in
                guard case .string(let choice) = value else { return nil }
                let trimmed = choice.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            guard choices.count == values.count else {
                throw GatewayBlockingError.malformedClarification
            }
        } else {
            choices = []
        }

        return Self(
            identity: identity,
            question: question,
            choices: choices,
            multiSelect: false
        )
    }
}
