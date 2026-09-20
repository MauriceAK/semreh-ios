import SwiftUI
import UserNotifications

/// Phases of the in-app stock Hermes update flow.
enum ServerUpdateApplyPhase: Equatable {
    /// No update in flight; show the "Update" button.
    case idle
    /// The apply request is in flight (before the server confirms a restart).
    case applying
    /// Server accepted the update and is restarting; we are polling for it.
    case recovering
    /// Restart was blocked by active chat/agent work; offer a retry.
    case blocked
    /// The request may have started an update, but ownership/completion is not provable.
    case unknown
    /// The update failed (conflict, diverged, unreachable, or timed-out restart).
    case failed
}


extension UNAuthorizationStatus {
    var allowsSettingsToggleOn: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }
}


extension SettingsView {
    @ViewBuilder
    var serversCard: some View {
        SettingsCard(title: String(localized: "Servers")) {
            ForEach(authManager.servers) { account in
                if account.id != authManager.servers.first?.id {
                    SettingsDivider()
                }

                NavigationLink {
                    ServerDetailView(authManager: authManager, account: account)
                } label: {
                    SettingsServerRow(
                        account: account,
                        isActive: account.id == authManager.activeServerID
                    )
                }
                .buttonStyle(.plain)
            }

            SettingsDivider()

            HapticButton {
                isPresentingAddServer = true
            } label: {
                SettingsAccessoryRow(title: String(localized: "Add Server"), systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Adds another Hermes server.")
        }
    }

    /// The active server's registry entry, or nil while unconfigured.
    var activeAccount: ServerAccount? {
        authManager.servers.first { $0.id == authManager.activeServerID }
    }

    /// Pushes the current identity values into the active server's registry entry.
    /// The stored legacy color field is preserved for decode compatibility, but
    /// no longer controls any profile/avatar rendering.
    func syncActiveServerIdentity() {
        guard let account = activeAccount else { return }
        authManager.updateServerIdentity(
            account,
            displayName: identityDisplayName,
            initials: identityInitials,
            headerLogoColorHex: account.headerLogoColorHex
        )
    }

    var signOutFootnote: String {
        authManager.servers.count > 1
            ? String(localized: "Signs out of the active server and switches to another configured server.")
            : String(localized: "Signs out of the active server and returns to onboarding.")
    }

    var signOutMessage: String {
        authManager.servers.count > 1
            ? String(localized: "You'll switch to another configured server. Sign in again to use this one.")
            : String(localized: "You'll return to onboarding and need the server URL and password to sign back in.")
    }

    @ViewBuilder
    var serverVersionContent: some View {
        if isLoadingServerSettings {
            ProgressView()
        } else if let serverVersion {
            Text(serverVersion)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            Text(serverSettingsError ?? String(localized: "Unknown"))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    var serverStatusPill: some View {
        if isLoadingServerSettings {
            SettingsStatusPill(label: String(localized: "Loading"))
        } else if serverSettingsError == nil, serverVersion != nil {
            // Only "Connected" when the latest load actually succeeded — a stale
            // `serverVersion` from an earlier success must not mask a now-failed
            // load (e.g. a restart that never came back).
            SettingsStatusPill(label: String(localized: "Connected"))
        } else {
            SettingsStatusPill(label: serverSettingsError ?? String(localized: "Unknown"), tint: .orange)
        }
    }

    // True while the server is applying/restarting an update. The manual check
    // button is disabled then so a forced check can't race the recovery poll.
    var isUpdateApplyInFlight: Bool {
        switch updateApplyPhase {
        case .applying, .recovering:
            return true
        case .idle, .blocked, .failed, .unknown:
            return false
        }
    }

    // The manual "Check for updates" control (#308). Distinct from the passive
    // on-open check: it forces a live git fetch on the server. While a check is in
    // flight it swaps to a "Checking…" spinner; it's disabled during an apply so
    // the two update flows never run at once.
    @ViewBuilder
    var serverUpdateCheckAction: some View {
        if isCheckingForUpdates {
            updateProgressRow(String(localized: "Checking for updates…"))
        } else {
            SettingsButton(String(localized: "Check for updates")) {
                updateOperation = Task {
                    await checkForUpdatesManually()
                }
            }
            .disabled(isUpdateApplyInFlight)
            .padding(.top, 4)
        }
    }

    var forcedCheckAlertTitle: String {
        switch forcedCheckOutcome {
        case let .updateAvailable(behind):
            return behind.map { String(localized: "Update available · \($0) behind") }
                ?? String(localized: "Update available")
        case .upToDate:
            return String(localized: "You're up to date")
        case .managed:
            return String(localized: "Update managed externally")
        case .error, .none:
            return String(localized: "Couldn't check for updates")
        }
    }

    var forcedCheckAlertMessage: String {
        switch forcedCheckOutcome {
        case .updateAvailable:
            return String(localized: "This pulls the latest Hermes server version and restarts it. Active chats may be interrupted briefly; the app reconnects when the server is back.")
        case .upToDate:
            return String(localized: "The Hermes server is running the latest version.")
        case let .managed(message):
            return message ?? String(localized: "This Hermes installation must be updated outside the app.")
        case .error, .none:
            return String(localized: "Something went wrong reaching the server. Try again in a moment.")
        }
    }

    // Informational only — never a warning. A normal, up-to-date server shows a
    // calm "Up to date"; a server that genuinely lags shows how far behind it is.
    // When the check is disabled, errored, or hasn't loaded, we show nothing here
    // and let the plain version row stand on its own.
    @ViewBuilder
    var serverUpdateNote: some View {
        if serverVersion != nil, let serverUpdateState {
            switch serverUpdateState {
            case .upToDate:
                updateNoteRow(systemImage: "checkmark.circle", tint: .secondary, text: String(localized: "Up to date"))
            case let .updateAvailable(behind):
                updateNoteRow(systemImage: "arrow.up.circle", tint: .blue,
                    text: behind.map { String(localized: "Update available · \($0) behind") }
                        ?? String(localized: "Update available"))
            case let .managed(message):
                updateNoteRow(systemImage: "info.circle", tint: .secondary,
                    text: message ?? String(localized: "Updates are managed outside this app."))
            case .unavailable:
                EmptyView()
            }
        }
    }

    func updateNoteRow(systemImage: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(text)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // The in-app "Update" action. Every phase resolves to a concrete UI so there
    // is never a stuck spinner *or* a silent vanish: the initial Update button is
    // gated on the server reporting a pending update, but once a run is underway
    // the progress / blocked / failed UI is driven purely by `updateApplyPhase`.
    // That keeps the message + Retry visible even if a slow/failed restart leaves
    // `serverUpdateState` nil or stale. Success returns to `.idle`, where the
    // refreshed `.upToDate` state removes the button.
    @ViewBuilder
    var serverUpdateAction: some View {
        switch updateApplyPhase {
        case .idle:
            if serverVersion != nil, case .updateAvailable = serverUpdateState {
                updateActionButton(title: String(localized: "Update"))
            }
        case .applying:
            updateProgressRow(String(localized: "Starting update…"))
        case .recovering:
            updateProgressRow(String(localized: "Updating & restarting…"))
        case .blocked:
            VStack(alignment: .leading, spacing: 10) {
                updateMessageRow(systemImage: "clock", tint: .secondary)
                updateActionButton(title: String(localized: "Retry update"))
            }
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                updateMessageRow(systemImage: "exclamationmark.triangle", tint: .orange)
                updateActionButton(title: String(localized: "Retry update"))
            }
        case .unknown:
            updateMessageRow(systemImage: "questionmark.circle", tint: .orange)
        }
    }

    func updateActionButton(title: String) -> some View {
        SettingsButton(title) {
            isConfirmingUpdate = true
        }
        // Mirror of the check button's `isUpdateApplyInFlight` guard: while a
        // forced check is running, block Update/Retry so apply can't race it.
        .disabled(isCheckingForUpdates)
        .padding(.top, 4)
    }

    func updateProgressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()

            Text(text)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    func updateMessageRow(systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(updateApplyMessage ?? String(localized: "The update could not be applied."))
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    func loadServerSettings() async {
        guard !isLoadingServerSettings else {
            return
        }

        isLoadingServerSettings = true
        isLoadingDefaultModel = true
        isLoadingDefaultProfile = true
        serverSettingsError = nil
        serverUpdateState = nil
        let client = APIClient(baseURL: server)

        do {
            let status = try await client.directStatus()
            serverVersion = status.version
            if serverVersion == nil {
                serverSettingsError = String(localized: "Unknown")
            }
        } catch {
            authManager.handleAPIError(error)
            serverSettingsError = String(localized: "Unavailable")
        }

        isLoadingServerSettings = false

        do {
            let updates = try await client.updatesCheck()
            serverUpdateState = updates.updateState
        } catch {
            // Non-fatal: update availability is optional info. On any failure we
            // degrade to showing the version only, with no indicator.
            serverUpdateState = nil
        }

        do {
            let context = try await client.directActiveProfile()
            guard let running = context.current?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !running.isEmpty else { throw DirectMainModelError.invalidSelection }
            defaultModel = try await client.directModelOptions(profile: running).model
        } catch {
            // Non-fatal: default model is optional info
            defaultModel = nil
        }

        isLoadingDefaultModel = false

        do {
            let profiles = try await client.directProfiles()
            let active = try await client.directActiveProfile()
            // Sticky startup default, not the running process or reserved
            // `is_default` profile row.
            defaultProfileName = active.startupDefaultName
            defaultProfileDisplayName = profiles.displayName(for: defaultProfileName)
        } catch {
            // Non-fatal: default profile is optional info
            defaultProfileName = nil
            defaultProfileDisplayName = nil
        }

        isLoadingDefaultProfile = false
    }

    func checkForUpdatesManually() async {
        // Ignore taps while a check is already running or an apply/restart is in
        // flight — both would race the shared `serverUpdateState`.
        guard !isCheckingForUpdates, !isUpdateApplyInFlight else {
            return
        }

        isCheckingForUpdates = true
        let client = APIClient(baseURL: server)

        do {
            let response = try await client.updatesCheckForced()
            // Refresh the passive inline indicator from the fresh result too, so a
            // forced check keeps the on-open note in sync (issue #308).
            serverUpdateState = response.updateState
            forcedCheckOutcome = response.forcedCheckOutcome
        } catch {
            authManager.handleAPIError(error)
            forcedCheckOutcome = .error
        }

        isCheckingForUpdates = false
        isPresentingForcedCheckResult = true
    }

    func applyServerUpdate() async {
        // Never start an apply while a forced check is in flight — the two race
        // the same server-side git state, and the check's completion would
        // overwrite update state / present its popup mid-apply. The inline
        // Update button is also disabled then; this guards the path regardless
        // (e.g. a tap that slips through the confirm dialog). The forced-check
        // popup's own Update is safe: `isCheckingForUpdates` is already false
        // before that popup presents (#308 review).
        guard !isCheckingForUpdates else { return }

        // Allow a fresh attempt only from a resting phase; ignore taps while a
        // request is in flight or the server is mid-restart.
        switch updateApplyPhase {
        case .idle, .blocked, .failed:
            break
        case .applying, .recovering, .unknown:
            return
        }

        updateApplyPhase = .applying
        updateApplyMessage = nil
        let client = APIClient(baseURL: server)

        let response: UpdatesApplyResponse
        do {
            response = try await client.applyUpdate()
        } catch {
            // The server may have accepted the bodyless POST before its ACK was
            // lost. Do not retry or claim failure when action ownership is unknown.
            authManager.handleAPIError(error)
            updateApplyMessage = String(localized: "Hermes may have started updating, but the response was lost. Check the server status before trying again.")
            updateApplyPhase = .unknown
            return
        }

        // Navigation may cancel monitoring while the POST acknowledgement is
        // returning. Do not overwrite onDisappear's unknown state with a
        // recovering spinner that a cancelled task can never finish.
        guard !Task.isCancelled else {
            updateApplyPhase = .unknown
            return
        }
        switch HermesUpdateStart.evaluate(response) {
        case .refused:
            updateApplyMessage = response.displayMessage(
                default: String(localized: "The update could not be applied.")
            )
            updateApplyPhase = .blocked
            return
        case .unknown:
            updateApplyMessage = String(localized: "Hermes may already be updating, but this app could not identify that update. Check the server status before trying again.")
            updateApplyPhase = .unknown
            return
        case let .monitor(actionID):
            updateApplyPhase = .recovering
            await waitForUpdateCompletion(using: client, actionID: actionID)
        }
    }

    /// Polls the stock action status for a bounded interval. Completion is owned
    /// only when its durable marker matches the POST-returned action ID and the
    /// corroborating exit code is zero; version/liveness/latest receipt are not
    /// substitutes. A confirmed completion then refreshes Settings from stock.
    func waitForUpdateCompletion(using client: APIClient, actionID: String) async {
        let maxAttempts = 30 // ~60s at a 2s cadence — generous for a self-restart.

        for _ in 0..<maxAttempts {
            guard !Task.isCancelled else { return }
            // Wait first: the server flushes the response, then restarts ~2s
            // later, so an immediate probe could hit the outgoing process.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            guard let status = try? await client.hermesUpdateStatus() else {
                continue
            }
            guard !Task.isCancelled else { return }
            switch HermesUpdateCompletion.evaluate(expectedActionID: actionID, status: status) {
            case .waiting:
                continue
            case .succeeded:
                await loadServerSettings()
                guard !Task.isCancelled else { return }
                updateApplyPhase = .idle
                updateApplyMessage = nil
                return
            case .unknown:
                updateApplyMessage = String(localized: "The update outcome could not be confirmed. Inspect the server before trying again.")
                updateApplyPhase = .unknown
                return
            }
        }

        // A timeout is ambiguous. Do not silently retry the POST or infer success.
        updateApplyMessage = String(localized: "The update outcome could not be confirmed in time. Inspect the server before trying again.")
        updateApplyPhase = .unknown
    }

    func clearOfflineCache() async {
        guard !isClearingCache else {
            return
        }

        isClearingCache = true
        do {
            // Scoped to the active server only, so clearing one server's cache
            // never wipes another configured server's offline data (#18).
            try CacheStore.clearCache(for: server, in: modelContext)
            cacheStatusMessage = String(localized: "This server's offline cache was cleared.")
        } catch {
            cacheStatusMessage = String(localized: "Could not clear offline cache.")
        }
        isClearingCache = false
    }
}
