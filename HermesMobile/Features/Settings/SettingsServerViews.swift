import SwiftUI

/// Per-server detail: identity editing, switch-to-active, and remove/sign-out (#17).
struct ServerDetailView: View {
    @Bindable var authManager: AuthManager
    let account: ServerAccount

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var displayName: String
    @State private var initials: String
    @State private var isConfirmingRemove = false
    @State private var isRemoving = false

    init(authManager: AuthManager, account: ServerAccount) {
        self.authManager = authManager
        self.account = account
        _displayName = State(initialValue: account.displayName)
        _initials = State(initialValue: account.initials)
    }

    private var isActive: Bool { account.id == authManager.activeServerID }
    private var hasOtherServers: Bool { authManager.servers.count > 1 }
    private var hostFallback: String { URL(string: account.urlString)?.host ?? account.urlString }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsCard(title: String(localized: "Server")) {
                    SettingsInfoRow(title: String(localized: "URL"), value: account.urlString, valueIsSelectable: true)

                    SettingsDivider()

                    SettingsValueRow(title: String(localized: "Status")) {
                        SettingsStatusPill(label: isActive ? String(localized: "Active") : String(localized: "Inactive"))
                    }
                }

                SettingsCard(title: String(localized: "Identity")) {
                    ServerIdentityEditor(
                        displayName: $displayName,
                        initials: $initials,
                        fallbackName: hostFallback
                    )
                }

                if !isActive {
                    SettingsCard(title: String(localized: "Active Server")) {
                        SettingsFootnote(String(localized: "Makes this the active server. Sessions, chats, and settings reload for it."))

                        SettingsButton(String(localized: "Switch to This Server")) {
                            authManager.switchActiveServer(to: account)
                        }
                    }
                }

                SettingsCard(title: isActive ? String(localized: "Account") : String(localized: "Remove Server")) {
                    SettingsFootnote(removeFootnote)

                    SettingsButton(removeButtonTitle, role: .destructive, isLoading: isRemoving) {
                        isConfirmingRemove = true
                    }
                    .disabled(isRemoving)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .background { SemrehBackdrop().ignoresSafeArea() }
        .navigationTitle(displayName.isEmpty ? hostFallback : displayName)
        .navigationBarTitleDisplayMode(.inline)
        // Persist identity edits to this server's registry entry. When it's the
        // active server, the registry mirrors them into the global @AppStorage so
        // the avatar / header tint update live (#17).
        .onChange(of: displayName) { persistIdentity() }
        .onChange(of: initials) { persistIdentity() }
        .alert(removeAlertTitle, isPresented: $isConfirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button(removeButtonTitle, role: .destructive) {
                Task {
                    let wasActive = isActive
                    isRemoving = true
                    // Purge this server's offline cache *before* removing it, while
                    // the view (and its modelContext) is still alive — removing the
                    // active server flips auth state and tears this stack down on
                    // its own. Best-effort: the cache is server-keyed, so a leftover
                    // row can never surface as another server's content (#18, PR
                    // #286 W2).
                    if let removedServerURL = URL(string: account.urlString) {
                        try? CacheStore.clearCache(for: removedServerURL, in: modelContext)
                    }
                    await authManager.removeServer(account)
                    // Only a non-active removal leaves this view alive to reset its
                    // state and pop; the active-server case is already torn down.
                    if !wasActive {
                        isRemoving = false
                        dismiss()
                    }
                }
            }
        } message: {
            Text(removeAlertMessage)
        }
    }

    private func persistIdentity() {
        // Keep the legacy stored color untouched for older serialized accounts.
        authManager.updateServerIdentity(
            account,
            displayName: displayName,
            initials: initials,
            headerLogoColorHex: account.headerLogoColorHex
        )
    }

    private var removeButtonTitle: String {
        isActive ? String(localized: "Sign Out of This Server") : String(localized: "Remove Server")
    }

    private var removeAlertTitle: String {
        isActive ? String(localized: "Sign out of this server?") : String(localized: "Remove this server?")
    }

    private var removeFootnote: String {
        if isActive {
            return hasOtherServers
                ? String(localized: "Signs out and switches to another configured server.")
                : String(localized: "Signs out and returns to onboarding.")
        }
        return String(localized: "Removes this server and its saved settings on this device. Your active server is unaffected.")
    }

    private var removeAlertMessage: String {
        if isActive {
            return hasOtherServers
                ? String(localized: "You'll switch to another configured server. Sign in again to use this one.")
                : String(localized: "You'll return to onboarding and need the server URL and password to sign back in.")
        }
        return String(localized: "This removes the server and its saved settings on this device. Your active server is unaffected.")
    }
}


/// Secondary onboarding/auth flow to add another server, collecting URL/password
/// (existing validation + login), custom headers, and per-server identity. Routes
/// through `AuthManager.addServer`, which never disturbs the active server on
/// failure (#17). Presented from Settings and from the session-list avatar
/// long-press switcher (#283).
struct AddServerView: View {
    @Bindable var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var serverURLString = ""
    @State private var username = ""
    @State private var password = ""
    @State private var customHeaders: [CustomHeader] = []
    @State private var needsPassword = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var displayName = ""
    @State private var initials = ""

    private var trimmedURL: String {
        serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool { !trimmedURL.isEmpty && !isWorking }

    private var derivedHost: String {
        (try? AuthManager.normalizedServerURL(from: serverURLString))?.host ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    SettingsCard(title: String(localized: "Server")) {
                        SettingsTextFieldRow(
                            title: String(localized: "URL"),
                            text: $serverURLString,
                            placeholder: "https://server.tailnet-name.ts.net",
                            keyboardType: .URL,
                            autocapitalization: .never,
                            submitLabel: .go,
                            onSubmit: { Task { await submit() } }
                        )

                        SettingsTextFieldRow(
                            title: String(localized: "Username"),
                            text: $username,
                            placeholder: String(localized: "Server username"),
                            autocapitalization: .never,
                            submitLabel: .next
                        )

                        if needsPassword {
                            SettingsDivider()

                            SettingsTextFieldRow(
                                title: String(localized: "Password"),
                                text: $password,
                                placeholder: String(localized: "Server password"),
                                autocapitalization: .never,
                                isSecure: true,
                                submitLabel: .go,
                                onSubmit: { Task { await submit() } }
                            )
                        }
                    }

                    SettingsCard(title: String(localized: "Connection Headers")) {
                        CustomHeadersEditor(headers: $customHeaders)
                    }

                    SettingsCard(title: String(localized: "Identity")) {
                        ServerIdentityEditor(
                            displayName: $displayName,
                            initials: $initials,
                            fallbackName: derivedHost
                        )
                    }

                    statusBanner
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .background { SemrehBackdrop().ignoresSafeArea() }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await submit() } }
                        .disabled(!canSubmit)
                }
            }
        }
        .adaptiveFormPresentation()
    }

    @ViewBuilder
    private var statusBanner: some View {
        if isWorking {
            SettingsFootnote(String(localized: "Checking server…"))
        } else if needsPassword, errorMessage == nil {
            SettingsFootnote(String(localized: "This server requires a password."))
        }

        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(AppFont.footnote())
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        errorMessage = nil
        isWorking = true
        let outcome = await authManager.addServer(
            serverURLString: serverURLString,
            username: username,
            password: password,
            customHeaders: customHeaders
        )
        isWorking = false

        switch outcome {
        case .needsPassword:
            needsPassword = true
        case .failed:
            errorMessage = authManager.lastErrorMessage
        case let .added(url):
            applyIdentity(to: url)
            dismiss()
        }
    }

    /// Overrides the new server's seeded identity (the registry seeds it from the
    /// previous active server's global defaults) with the add-flow's chosen values.
    private func applyIdentity(to url: URL) {
        guard let account = authManager.servers.first(where: { $0.id == url.absoluteString }) else { return }

        let finalName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (url.host ?? account.displayName)
            : displayName
        let finalInitials = SessionIdentitySettings.displayInitials(
            displayName: finalName,
            storedInitials: initials,
            fallbackFullName: url.host ?? finalName
        )
        authManager.updateServerIdentity(
            account,
            displayName: finalName,
            initials: finalInitials,
            headerLogoColorHex: account.headerLogoColorHex
        )
    }
}
