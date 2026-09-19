#if DEBUG
import Foundation
import OSLog

/// Deliberately narrow, one-shot harness for unattended native-auth E2E.
///
/// The flag carries no value. Synthetic values are minted in-process only after
/// a complete browser-issued loopback prompt passes every gate, are handed to the
/// production submission closure once, and are discarded immediately afterward.
@MainActor
final class NativeAuthE2EAutoSubmitController {
    static let launchFlag = "--native-auth-e2e-auto-submit"
    private static let diagnosticLog = Logger(
        subsystem: "com.mauriceak.semreh",
        category: "NativeAuthE2E"
    )

    private enum State {
        case idle
        case submitting
        case spent
    }

    private static var didResolveProcessController = false
    private static var resolvedProcessController: NativeAuthE2EAutoSubmitController?

    private var state: State = .idle
    private var pendingValues: [String: String] = [:]
    private(set) var attemptCount = 0

    var hasPendingValues: Bool { !pendingValues.isEmpty }
    var isSpent: Bool {
        if case .spent = state { return true }
        return false
    }

    static func processController(
        serverURL: URL,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> NativeAuthE2EAutoSubmitController? {
        // Revalidate every caller's server. The cached controller is process-wide
        // only after an explicitly flagged, direct-loopback caller establishes it;
        // a later remote ChatViewModel must never inherit that authorization.
        guard arguments.contains(launchFlag), isDirectLoopbackServer(serverURL) else {
            diagnosticLog.notice("[DEBUG-NATIVE-AUTH-E2E] controller disabled by launch/server gate")
            return nil
        }
        guard !didResolveProcessController else {
            diagnosticLog.notice("[DEBUG-NATIVE-AUTH-E2E] reusing process controller")
            return resolvedProcessController
        }
        didResolveProcessController = true
        resolvedProcessController = NativeAuthE2EAutoSubmitController()
        diagnosticLog.notice("[DEBUG-NATIVE-AUTH-E2E] process controller enabled")
        return resolvedProcessController
    }

    static func resetProcessControllerForTesting() {
        didResolveProcessController = false
        resolvedProcessController = nil
    }

    static func resolve(arguments: [String], serverURL: URL) -> NativeAuthE2EAutoSubmitController? {
        guard arguments.contains(launchFlag), isDirectLoopbackServer(serverURL) else { return nil }
        return NativeAuthE2EAutoSubmitController()
    }

    /// Returns true only when this call consumed the controller's one attempt.
    @discardableResult
    func submitIfEligible(
        prompt: NativeAuthPromptState,
        submit: ([String: String], NativeAuthWireComponent, String) async -> Bool
    ) async -> Bool {
        guard case .idle = state,
              let request = Self.request(for: prompt)
        else {
            Self.diagnosticLog.notice("[DEBUG-NATIVE-AUTH-E2E] submit skipped before mutation")
            return false
        }

        state = .submitting
        attemptCount += 1
        pendingValues = Self.makeDisposableValues(for: request.inputs)
        var disposableValues = pendingValues
        Self.diagnosticLog.notice("[DEBUG-NATIVE-AUTH-E2E] eligible; invoking production submit path")

        defer {
            for key in pendingValues.keys { pendingValues[key] = "" }
            pendingValues.removeAll(keepingCapacity: false)
            for key in disposableValues.keys { disposableValues[key] = "" }
            disposableValues.removeAll(keepingCapacity: false)
            state = .spent
        }

        _ = await submit(disposableValues, request.submit, request.submit.actionHandle)
        Self.diagnosticLog.notice("[DEBUG-NATIVE-AUTH-E2E] production submit path returned")
        return true
    }

    private static func request(
        for prompt: NativeAuthPromptState
    ) -> (inputs: [NativeAuthWireComponent], submit: NativeAuthWireComponent)? {
        guard let state = prompt.state else { return reject("missing-state") }
        guard state.status == .available else { return reject("state-not-available") }
        guard state.browserFlow == nil else { return reject("browser-owned-state") }
        guard let anchor = prompt.components.first else { return reject("missing-anchor") }
        guard prompt.contextID == anchor.contextID else { return reject("prompt-anchor-context") }
        guard isLoopbackHTTPSOrigin(anchor.providerOrigin) else { return reject("provider-origin") }
        guard !prompt.components.contains(where: { $0.isExpired || $0.kind.isBrowserOwned }) else {
            return reject("expired-or-browser-owned-component")
        }

        let inputs = prompt.inputComponents
        let submits = prompt.components.filter { $0.kind == .submit }
        guard (1...8).contains(inputs.count) else { return reject("input-count") }
        guard submits.count == 1, let submit = submits.first else { return reject("submit-count") }
        guard prompt.components.count == inputs.count + submits.count else { return reject("component-count") }
        guard Set(prompt.components.map(\.componentID)).count == prompt.components.count else {
            return reject("duplicate-component")
        }
        guard Set(prompt.components.map(\.field)).count == prompt.components.count else {
            return reject("duplicate-field")
        }
        guard Set(prompt.components.map(\.actionHandle)).count == prompt.components.count else {
            return reject("duplicate-action-handle")
        }
        guard inputs.allSatisfy({ $0.binding?.editability != "not_editable" }) else {
            return reject("input-not-editable")
        }
        guard prompt.components.allSatisfy({ sharesImmutableContext($0, anchor) }) else {
            return reject("immutable-context")
        }
        guard state.contextID == submit.contextID else { return reject("state-context") }
        guard state.browserSessionID == submit.browserSessionID else { return reject("state-browser-session") }
        guard state.componentID == submit.componentID else { return reject("state-component") }
        guard state.actionHandle == submit.actionHandle else { return reject("state-action") }
        guard state.kind == submit.kind else { return reject("state-kind") }
        guard state.providerOrigin == submit.providerOrigin else { return reject("state-origin") }
        guard state.path == submit.path else { return reject("state-path") }

        return (inputs, submit)
    }

    private static func reject(
        _ reason: String
    ) -> (inputs: [NativeAuthWireComponent], submit: NativeAuthWireComponent)? {
        diagnosticLog.notice("[DEBUG-NATIVE-AUTH-E2E] rejected: \(reason, privacy: .public)")
        return nil
    }

    private static func sharesImmutableContext(
        _ component: NativeAuthWireComponent,
        _ anchor: NativeAuthWireComponent
    ) -> Bool {
        guard component.contextID == anchor.contextID,
              component.browserSessionID == anchor.browserSessionID,
              component.providerOrigin == anchor.providerOrigin,
              component.path == anchor.path,
              component.runtimePublicKey == anchor.runtimePublicKey,
              component.keyID == anchor.keyID,
              component.expiresAt == anchor.expiresAt
        else { return false }

        switch (component.binding, anchor.binding) {
        case (nil, nil):
            return true
        case let (.some(componentBinding), .some(anchorBinding)):
            return componentBinding.tabHandle == anchorBinding.tabHandle
                && componentBinding.frameHandle == anchorBinding.frameHandle
                && componentBinding.documentGeneration == anchorBinding.documentGeneration
        default:
            return false
        }
    }

    private static func makeDisposableValues(
        for inputs: [NativeAuthWireComponent]
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: inputs.map { component in
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let value: String
            switch component.kind {
            case .identifier:
                value = "e2e-\(token)@localhost.invalid"
            case .secret:
                value = "Z9!\(token)"
            case .oneTimeCode:
                value = String(Int.random(in: 100_000...999_999))
            case .recoveryCode:
                value = token
            default:
                preconditionFailure("Non-fillable native-auth kind passed the E2E gate")
            }
            return (component.field, value)
        })
    }

    private static func isDirectLoopbackServer(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              isLoopbackHost(host),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return false }
        return true
    }

    private static func isLoopbackHTTPSOrigin(_ rawOrigin: String) -> Bool {
        guard let components = URLComponents(string: rawOrigin),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              isLoopbackHost(host),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return false }
        return true
    }

    private static func isLoopbackHost(_ rawHost: String) -> Bool {
        // URLComponents may preserve IPv6 address brackets in `host` on some
        // Foundation versions. Normalize only the literal wrapper; do not
        // broaden the accepted loopback address space.
        let unwrappedHost: String
        if rawHost.hasPrefix("[") && rawHost.hasSuffix("]") {
            unwrappedHost = String(rawHost.dropFirst().dropLast())
        } else {
            unwrappedHost = rawHost
        }
        let host = unwrappedHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        if host == "localhost" || host == "::1" { return true }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.first == "127",
              octets.allSatisfy({ part in
                  !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part).map { (0...255).contains($0) } == true
              })
        else { return false }
        return true
    }
}
#endif

