import SwiftUI
import UIKit

struct ApprovalRequestOverlay: View {
    let prompt: ApprovalPromptState
    let isResponding: Bool
    let errorMessage: String?
    let onChoice: (ApprovalChoice) -> Void
    let onSkipAll: () -> Void
    /// `nil` preserves the legacy WebUI approval surface. Direct Hermes uses
    /// an explicit set from the server's typed `choices` contract.
    private let allowedChoices: Set<ApprovalChoice>?
    private let allowsSkipAll: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    init(
        prompt: ApprovalPromptState,
        isResponding: Bool,
        errorMessage: String?,
        onChoice: @escaping (ApprovalChoice) -> Void,
        onSkipAll: @escaping () -> Void,
        allowedChoices: Set<ApprovalChoice>? = nil,
        allowsSkipAll: Bool = true
    ) {
        self.prompt = prompt
        self.isResponding = isResponding
        self.errorMessage = errorMessage
        self.onChoice = onChoice
        self.onSkipAll = onSkipAll
        self.allowedChoices = allowedChoices
        self.allowsSkipAll = allowsSkipAll
    }

    /// Direct Hermes uses the typed gateway prompt and has no legacy
    /// "skip-all" endpoint. Reuse this renderer while preserving the exact
    /// server-advertised choices and the prompt identity captured by ChatView.
    init(
        prompt: GatewayApprovalPrompt,
        isResponding: Bool,
        errorMessage: String?,
        onChoice: @escaping (GatewayApprovalChoice) -> Void
    ) {
        self.init(
            prompt: ApprovalPromptState(
                sessionID: prompt.identity.storedID,
                pending: PendingApproval(
                    approvalId: prompt.identity.requestID,
                    command: prompt.command,
                    description: prompt.description,
                    patternKey: prompt.patternKey,
                    patternKeys: prompt.patternKeys
                ),
                pendingCount: 1
            ),
            isResponding: isResponding,
            errorMessage: errorMessage,
            onChoice: { choice in
                guard let directChoice = GatewayApprovalChoice(rawValue: choice.rawValue) else { return }
                onChoice(directChoice)
            },
            onSkipAll: {},
            allowedChoices: Set(prompt.choices.compactMap { ApprovalChoice(rawValue: $0.rawValue) }),
            allowsSkipAll: false
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.38 : 0.22)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                header
                details
                actions
            }
            .padding(16)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 12)
            .padding(.horizontal, 18)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval-request-overlay")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SemrehVisualTheme.statusWarning(for: palette))

            VStack(alignment: .leading, spacing: 4) {
                Text("Approval required")
                    .font(.headline)

                Text("Pending approvals: \(prompt.pendingCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let description = nonEmpty(prompt.pending.description) {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let command = nonEmpty(prompt.pending.command) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(SemrehVisualTheme.promptBubbleForeground(for: palette))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(
                    SemrehVisualTheme.promptBubbleBackground(for: colorScheme, palette: palette),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }

            if !prompt.patternKeys.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pattern keys")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(prompt.patternKeys, id: \.self) { key in
                            Text(key)
                                .font(.caption2.monospaced())
                                .foregroundStyle(SemrehVisualTheme.promptBubbleForeground(for: palette))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    SemrehVisualTheme.promptBubbleBackground(for: colorScheme, palette: palette).opacity(0.86),
                                    in: Capsule()
                                )
                        }
                    }
                }
            }

            if prompt.pendingCount > 1 {
                Text("1 of \(prompt.pendingCount) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = nonEmpty(errorMessage) {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(SemrehVisualTheme.statusCritical(for: palette))
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if isChoiceAllowed(.once) {
                    approvalButton("Allow once", systemImage: "checkmark.circle.fill", choice: .once, prominent: true)
                }
                if isChoiceAllowed(.session) {
                    approvalButton("Allow session", systemImage: "lock.open", choice: .session, prominent: false)
                }
            }

            HStack(spacing: 8) {
                if isChoiceAllowed(.always) {
                    approvalButton("Always allow", systemImage: "star.fill", choice: .always, prominent: false)
                }
                if isChoiceAllowed(.deny) {
                    approvalButton("Deny", systemImage: "xmark.circle.fill", choice: .deny, prominent: false, role: .destructive)
                }
            }

            if allowsSkipAll {
                Button {
                    onSkipAll()
                } label: {
                    Label("Skip all this session", systemImage: "bolt.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.chatDecision(.secondary))
                .disabled(isResponding)
                .accessibilityIdentifier("approval-request-skip-all")
            }
        }
    }

    @ViewBuilder
    private func approvalButton(
        _ title: String,
        systemImage: String,
        choice: ApprovalChoice,
        prominent: Bool,
        role: ButtonRole? = nil
    ) -> some View {
        if prominent {
            Button(role: role) {
                onChoice(choice)
            } label: {
                Label(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.chatDecision(.primary))
            .disabled(isResponding)
            .accessibilityIdentifier("approval-request-choice-\(choice.rawValue)")
        } else {
            Button(role: role) {
                onChoice(choice)
            } label: {
                Label(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.chatDecision(role == .destructive ? .destructive : .secondary))
            .disabled(isResponding)
            .accessibilityIdentifier("approval-request-choice-\(choice.rawValue)")
        }
    }

    private func isChoiceAllowed(_ choice: ApprovalChoice) -> Bool {
        allowedChoices?.contains(choice) ?? true
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Native direct-Hermes password/secret surface. Stock `secret.request` and
/// `sudo.request` have no safe text-entry contract in this app yet; the only
/// supported action here is explicit cancellation with the empty response.
struct DirectGatewaySensitivePromptOverlay: View {
    enum Kind: Equatable {
        case secret
        case sudo
    }

    let kind: Kind
    let identity: GatewayBlockingPromptIdentity
    let prompt: String?
    let isResponding: Bool
    let errorMessage: String?
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    init(
        prompt: GatewaySecretPrompt,
        isResponding: Bool,
        errorMessage: String?,
        onCancel: @escaping () -> Void
    ) {
        kind = .secret
        identity = prompt.identity
        self.prompt = prompt.prompt
        self.isResponding = isResponding
        self.errorMessage = errorMessage
        self.onCancel = onCancel
    }

    init(
        prompt: GatewaySudoPrompt,
        isResponding: Bool,
        errorMessage: String?,
        onCancel: @escaping () -> Void
    ) {
        kind = .sudo
        identity = prompt.identity
        self.prompt = nil
        self.isResponding = isResponding
        self.errorMessage = errorMessage
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.38 : 0.22)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(SemrehVisualTheme.statusWarning(for: palette))
                    Text(kind == .secret ? "Secret required" : "Sudo password required")
                        .font(.headline)
                }

                Text(prompt ?? "Hermes needs a sudo password to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("This app cannot securely enter this value yet. Cancel to unblock the request without sending a secret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let errorMessage, !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(SemrehVisualTheme.statusCritical(for: palette))
                }

                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.chatDecision(.destructive))
                .disabled(isResponding)
                .accessibilityIdentifier("direct-sensitive-prompt-cancel")
            }
            .padding(16)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 12)
            .padding(.horizontal, 18)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("direct-sensitive-prompt-overlay")
    }
}
