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

enum GatewayBlockingPromptKind: String, Equatable, Sendable {
    case single
    case unsupportedBatch
    case unsupportedMultiSelect

    var displayQuestion: String {
        switch self {
        case .single:
            return ""
        case .unsupportedBatch:
            return "Hermes is waiting on a multi-question clarification that this app cannot answer yet. Cancel to continue."
        case .unsupportedMultiSelect:
            return "Hermes is waiting on a multi-select clarification that this app cannot answer yet. Cancel to continue."
        }
    }

    var isCancelOnly: Bool {
        self != .single
    }
}

struct GatewayBlockingPrompt: Equatable, Sendable {
    let identity: GatewayBlockingPromptIdentity
    let question: String
    let choices: [String]
    let multiSelect: Bool
    let kind: GatewayBlockingPromptKind

    var displayQuestion: String {
        kind.isCancelOnly ? kind.displayQuestion : question
    }
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

/// Contract errors for blocking request types that are not clarification
/// prompts. They remain separate from `GatewayBlockingError` so the existing
/// clarification UI/error mapping stays source-compatible.
enum GatewayBlockingContractError: Error, Equatable, Sendable {
    case malformedApproval
    case unsupportedApprovalChoice
    case malformedSecret
    case malformedSudo
}

enum GatewayApprovalChoice: String, CaseIterable, Equatable, Sendable {
    case once
    case session
    case always
    case deny
}

struct GatewayApprovalPrompt: Equatable, Sendable {
    let identity: GatewayBlockingPromptIdentity
    let command: String
    let description: String
    let patternKey: String
    let patternKeys: [String]
    let allowSession: Bool
    let allowPermanent: Bool
    let smartDenied: Bool
    let choices: [GatewayApprovalChoice]

    static func decode(
        payload: JSONValue?,
        identity: GatewayBlockingPromptIdentity
    ) throws -> Self {
        guard isValidIdentity(identity),
              case .object(let fields) = payload,
              fields["request_id"]?.gatewayString == identity.requestID,
              let command = fields["command"]?.stringValue,
              let description = fields["description"]?.stringValue,
              let patternKey = fields["pattern_key"]?.gatewayString,
              case .array(let rawPatternKeys) = fields["pattern_keys"] else {
            throw GatewayBlockingContractError.malformedApproval
        }
        let allowSession: Bool
        if let rawAllowSession = fields["allow_session"] {
            guard let value = rawAllowSession.boolValue else {
                throw GatewayBlockingContractError.malformedApproval
            }
            allowSession = value
        } else {
            // The elicitation approval producer omits both flags; stock
            // `_approval_request_payload` treats omission as enabled.
            allowSession = true
        }
        let allowPermanent: Bool
        if let rawAllowPermanent = fields["allow_permanent"] {
            guard let value = rawAllowPermanent.boolValue else {
                throw GatewayBlockingContractError.malformedApproval
            }
            allowPermanent = value
        } else {
            allowPermanent = true
        }
        let patternKeys = rawPatternKeys.compactMap { value -> String? in
            guard let string = value.gatewayString else { return nil }
            return string
        }
        guard patternKeys.count == rawPatternKeys.count,
              !patternKeys.isEmpty,
              patternKeys.contains(patternKey) else {
            throw GatewayBlockingContractError.malformedApproval
        }
        let smartDenied: Bool
        if let rawSmartDenied = fields["smart_denied"] {
            guard let value = rawSmartDenied.boolValue else {
                throw GatewayBlockingContractError.malformedApproval
            }
            smartDenied = value
        } else {
            smartDenied = false
        }
        let derivedChoices = Self.choices(
            allowSession: allowSession,
            allowPermanent: allowPermanent,
            smartDenied: smartDenied
        )
        if let rawChoices = fields["choices"] {
            guard case .array(let values) = rawChoices else {
                throw GatewayBlockingContractError.malformedApproval
            }
            let choices = values.compactMap { value in
                value.gatewayString.flatMap(GatewayApprovalChoice.init(rawValue:))
            }
            guard choices.count == values.count, choices == derivedChoices else {
                throw GatewayBlockingContractError.unsupportedApprovalChoice
            }
        }
        return Self(
            identity: identity,
            command: command,
            description: description,
            patternKey: patternKey,
            patternKeys: patternKeys,
            allowSession: allowSession,
            allowPermanent: allowPermanent,
            smartDenied: smartDenied,
            choices: derivedChoices
        )
    }

    private static func choices(
        allowSession: Bool,
        allowPermanent: Bool,
        smartDenied: Bool
    ) -> [GatewayApprovalChoice] {
        if smartDenied { return [.once, .deny] }
        var result: [GatewayApprovalChoice] = [.once]
        if allowSession {
            result.append(.session)
            if allowPermanent { result.append(.always) }
        }
        result.append(.deny)
        return result
    }
}

struct GatewaySecretPrompt: Equatable, Sendable {
    let identity: GatewayBlockingPromptIdentity
    let prompt: String
    let environmentVariable: String
    let metadata: JSONValue?
    let isCancelOnly = true

    private init(
        identity: GatewayBlockingPromptIdentity,
        prompt: String,
        environmentVariable: String,
        metadata: JSONValue?
    ) {
        self.identity = identity
        self.prompt = prompt
        self.environmentVariable = environmentVariable
        self.metadata = metadata
    }

    static func decode(
        payload: JSONValue?,
        identity: GatewayBlockingPromptIdentity
    ) throws -> Self {
        guard isValidIdentity(identity),
              case .object(let fields) = payload,
              fields["request_id"]?.gatewayString == identity.requestID,
              let prompt = fields["prompt"]?.gatewayString,
              let environmentVariable = fields["env_var"]?.gatewayString else {
            throw GatewayBlockingContractError.malformedSecret
        }
        return Self(
            identity: identity,
            prompt: prompt,
            environmentVariable: environmentVariable,
            metadata: fields["metadata"]
        )
    }

    /// Empty is the stock callback's explicit skip/cancel value; never put a
    /// user-entered secret into a model or transcript field.
    var cancelValue: String { "" }
}

struct GatewaySudoPrompt: Equatable, Sendable {
    let identity: GatewayBlockingPromptIdentity
    let isCancelOnly = true

    private init(identity: GatewayBlockingPromptIdentity) {
        self.identity = identity
    }

    static func decode(
        payload: JSONValue?,
        identity: GatewayBlockingPromptIdentity
    ) throws -> Self {
        guard isValidIdentity(identity),
              case .object(let fields) = payload,
              fields["request_id"]?.gatewayString == identity.requestID else {
            throw GatewayBlockingContractError.malformedSudo
        }
        return Self(identity: identity)
    }

    /// Empty is the stock sudo callback's explicit cancellation value.
    var cancelValue: String { "" }
}

private func isValidIdentity(_ identity: GatewayBlockingPromptIdentity) -> Bool {
    !identity.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    !identity.profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    !identity.storedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    !identity.runtimeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    !identity.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
    URL(string: identity.origin)?.scheme != nil &&
    !(URL(string: identity.origin)?.host?.isEmpty ?? true)
}

private extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

extension GatewayBlockingPrompt {
    static func decode(
        payload: JSONValue?,
        identity: GatewayBlockingPromptIdentity
    ) throws -> Self {
        guard case .object(let fields) = payload else {
            throw GatewayBlockingError.malformedClarification
        }
        guard fields["request_id"]?.gatewayString == identity.requestID else {
            throw GatewayBlockingError.malformedClarification
        }
        if let rawQuestions = fields["questions"] {
            guard case .array = rawQuestions else {
                throw GatewayBlockingError.malformedClarification
            }
            return Self(
                identity: identity,
                question: "",
                choices: [],
                multiSelect: false,
                kind: .unsupportedBatch
            )
        }
        if let rawMultiSelect = fields["multi_select"] {
            guard case .bool(let multiSelect) = rawMultiSelect else {
                throw GatewayBlockingError.malformedClarification
            }
            if multiSelect {
                guard fields["question"]?.gatewayString != nil else {
                    throw GatewayBlockingError.malformedClarification
                }
                return Self(
                    identity: identity,
                    question: "",
                    choices: [],
                    multiSelect: true,
                    kind: .unsupportedMultiSelect
                )
            }
        }
        guard let question = fields["question"]?.gatewayString else {
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
            multiSelect: false,
            kind: .single
        )
    }
}
