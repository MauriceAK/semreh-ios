import Foundation
import SwiftUI

extension SettingsView {
    var toolsAndHistorySection: some View {
        SettingsCategory(title: "Tools & History", subtitle: "Organizers, session visibility, and archives", systemImage: "square.grid.2x2") {
        SettingsCard(title: String(localized: "Tools")) {
            NavigationLink {
                ControlView(
                    authManager: authManager,
                    server: server,
                    showsConnectionRows: false
                )
            } label: {
                SettingsAccessoryRow(
                    title: String(localized: "Open Tools"),
                    systemImage: "square.grid.2x2"
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens secondary tools and organizers.")

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Tasks"),
                systemImage: "calendar.badge.clock",
                isOn: $showsTasksSection
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Kanban"),
                systemImage: "rectangle.split.3x1",
                isOn: $showsKanbanSection
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Skills"),
                systemImage: "hammer",
                isOn: $showsSkillsSection
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Memory"),
                systemImage: "brain",
                isOn: $showsMemorySection
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Insights"),
                systemImage: "chart.bar",
                isOn: $showsInsightsSection
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Active Profile"),
                systemImage: "person.crop.circle",
                isOn: $showsActiveProfileSection
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Projects"),
                systemImage: "folder.badge.gearshape",
                isOn: $showsProjectsSection
            )

            SettingsFootnote(String(localized: "Choose which entries appear in Settings → Tools. Turn an entry back on here whenever you need it."))
        }

        SettingsCard(title: String(localized: "Sessions")) {
            SettingsToggleRow(
                title: String(localized: "Message Count"),
                systemImage: "number",
                isOn: $showsSessionMessageCount
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Workspace"),
                systemImage: "folder",
                isOn: $showsSessionWorkspace
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Cron Sessions"),
                systemImage: "clock.arrow.2.circlepath",
                isOn: $showsCronSessions
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "CLI Sessions"),
                systemImage: "terminal",
                isOn: Binding(
                    get: { cliSessionsSync.showsCliSessions },
                    set: { cliSessionsSync.setShowsCliSessions($0) }
                )
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Claude Code Sessions"),
                systemImage: "chevron.left.forwardslash.chevron.right",
                isOn: Binding(
                    get: { cliSessionsSync.showsClaudeCodeSessions },
                    set: { cliSessionsSync.setShowsClaudeCodeSessions($0) }
                )
            )
            .disabled(!cliSessionsSync.showsCliSessions)

            // Only the CLI rows above are per-server; the other session toggles
            // in this card are global to this device.
            SettingsFootnote(String(localized: "CLI session visibility is saved on this device for this server."))

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Subagent Sessions"),
                systemImage: "arrow.triangle.branch",
                isOn: $showsSubagentSessions
            )
        }

        SettingsCard(title: String(localized: "Archived Sessions")) {
            SettingsArchivedSessionsLink(server: server, onAPIError: authManager.handleAPIError)
                .id(server)
        }
        }
    }

    var connectionsSection: some View {
        SettingsCategory(title: "Connections", subtitle: "Servers, profiles, providers, and updates", systemImage: "server.rack") {
        serversCard

        SettingsCard(title: String(localized: "Active Server")) {
            HapticButton {
                showDefaultModelPicker = true
            } label: {
                SettingsAccessoryRow(
                    title: String(localized: "Default Model"),
                    value: defaultModelLabel,
                    systemImage: "cpu"
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the default model picker.")

            SettingsDivider()

            HapticButton {
                showDefaultProfilePicker = true
            } label: {
                SettingsAccessoryRow(
                    title: String(localized: "Default Profile"),
                    value: defaultProfileLabel,
                    systemImage: "person.crop.circle"
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the default profile picker.")

            SettingsDivider()

            SettingsValueRow(title: String(localized: "Status")) {
                serverStatusPill
            }

            SettingsDivider()

            SettingsValueRow(title: String(localized: "Version")) {
                serverVersionContent
            }

            serverUpdateCheckAction
            serverUpdateNote
            serverUpdateAction
        }

        SettingsCard(title: String(localized: "Advanced")) {

            NavigationLink {
                ProvidersView(server: server)
            } label: {
                SettingsAccessoryRow(
                    title: String(localized: "Providers"),
                    systemImage: "key.horizontal"
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the provider status screen.")

            SettingsDivider()

            NavigationLink {
                CustomHeadersSettingsView(authManager: authManager)
            } label: {
                SettingsAccessoryRow(
                    title: String(localized: "Connection Headers"),
                    systemImage: "list.bullet.rectangle"
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the custom request headers editor.")
        }
        }
    }

    var aboutAndStorageSection: some View {
        SettingsCategory(title: "About & Storage", subtitle: "Support, offline data, and account", systemImage: "info.circle") {
        SettingsCard(title: String(localized: "Siri & Shortcuts")) {
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: settingsURL) {
                    SettingsAccessoryRow(
                        title: String(localized: "Open Semreh Settings"),
                        systemImage: "gearshape",
                        accessorySystemImage: "arrow.up.forward"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Semreh Settings")
            }

            SettingsFootnote(String(localized: "Run Semreh actions like New Chat from Siri, Spotlight, the Lock Screen, or the iPhone Action button. Open Semreh Settings to manage its Siri & Search options. To assign an action to the Action button, open the iOS Settings app, choose Action Button, then Shortcut, and pick a Semreh action."))
        }

        SettingsCard(title: String(localized: "App")) {
            SettingsInfoRow(title: String(localized: "Version"), value: appVersion)
            SettingsInfoRow(title: String(localized: "Build"), value: appBuild)

            SettingsDivider()

            Link(destination: AppConfig.privacyPolicyURL) {
                SettingsAccessoryRow(
                    title: String(localized: "Privacy Policy"),
                    systemImage: "hand.raised",
                    accessorySystemImage: "arrow.up.forward"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Privacy Policy")

            SettingsDivider()

            Link(destination: AppConfig.supportURL) {
                SettingsAccessoryRow(
                    title: String(localized: "Support"),
                    systemImage: "questionmark.circle",
                    accessorySystemImage: "arrow.up.forward"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Support")
        }

        #if DEBUG
        SettingsCard(title: String(localized: "Developer")) {
            NavigationLink {
                StreamingLabView()
            } label: {
                SettingsAccessoryRow(title: String(localized: "Streaming Lab"), systemImage: "waveform.path.ecg")
            }
            .buttonStyle(.plain)

            SettingsFootnote(String(localized: "Debug builds only. Replay a canned reply and tune the streamed-text fade feel live."))
        }
        #endif

        SettingsCard(title: String(localized: "Offline Data")) {
            SettingsFootnote(cacheStatusMessage ?? String(localized: "Cached sessions and messages are kept for offline viewing. Clearing removes this server's cache only — other servers and the Hermes server are not affected."))

            SettingsButton(String(localized: "Clear Offline Cache"), role: .destructive, isLoading: isClearingCache) {
                isConfirmingClearCache = true
            }
            .disabled(isClearingCache)
        }

        SettingsCard(title: String(localized: "Account")) {
            SettingsFootnote(signOutFootnote)

            SettingsButton(String(localized: "Sign Out of This Server"), role: .destructive) {
                isConfirmingReconfigure = true
            }
        }
        }
    }
}

enum SettingsArchivedSessionsProfileResolutionError: LocalizedError, Equatable {
    case missingCurrentProfile

    var errorDescription: String? {
        switch self {
        case .missingCurrentProfile:
            return String(localized: "Hermes did not report the current profile. Try again before opening archived sessions.")
        }
    }
}

enum SettingsArchivedSessionsProfileResolver {
    static func resolve(client: APIClient) async throws -> String {
        let activeProfile = try await client.directActiveProfile()
        guard let current = activeProfile.current?.trimmingCharacters(in: .whitespacesAndNewlines),
              !current.isEmpty else {
            throw SettingsArchivedSessionsProfileResolutionError.missingCurrentProfile
        }
        return current
    }
}

private struct SettingsArchivedSessionsResolutionRequest: Hashable {
    let server: URL
    let id: UUID
}

private struct SettingsArchivedSessionsDestination: Hashable, Identifiable {
    let server: URL
    let profile: String

    var id: String {
        "\(server.absoluteString)|\(profile)"
    }
}

private enum SettingsArchivedSessionsLinkState {
    case idle
    case resolving(SettingsArchivedSessionsResolutionRequest)
    case failed(String)
    case ready(SettingsArchivedSessionsDestination)

    var resolutionRequest: SettingsArchivedSessionsResolutionRequest? {
        guard case let .resolving(request) = self else { return nil }
        return request
    }

    var destination: SettingsArchivedSessionsDestination? {
        guard case let .ready(destination) = self else { return nil }
        return destination
    }

    var isResolving: Bool {
        resolutionRequest != nil
    }

    var statusValue: String? {
        switch self {
        case .idle, .ready:
            return nil
        case .resolving:
            return String(localized: "Loading…")
        case .failed:
            return String(localized: "Try again")
        }
    }

    var systemImage: String {
        switch self {
        case .failed:
            return "exclamationmark.triangle"
        case .idle, .resolving, .ready:
            return "archivebox"
        }
    }

    var errorMessage: String? {
        guard case let .failed(message) = self else { return nil }
        return message
    }
}

private struct SettingsArchivedSessionsLink: View {
    let server: URL
    let onAPIError: (Error) -> Void
    @State private var state: SettingsArchivedSessionsLinkState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                beginResolution()
            } label: {
                SettingsAccessoryRow(
                    title: String(localized: "Archived Sessions"),
                    value: state.statusValue,
                    systemImage: state.systemImage
                )
            }
            .buttonStyle(.plain)
            .disabled(state.isResolving)

            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(String(localized: "Try Again")) {
                    beginResolution()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
            }
        }

        .navigationDestination(
            item: Binding(
                get: { state.destination },
                set: { destination in
                    state = destination.map(SettingsArchivedSessionsLinkState.ready) ?? .idle
                }
            )
        ) { destination in
            ArchivedSessionsView(
                server: destination.server,
                profile: destination.profile,
                onAPIError: onAPIError
            )
        }
        .task(id: state.resolutionRequest) {
            guard let request = state.resolutionRequest else { return }
            await resolve(request)
        }
    }

    private func beginResolution() {
        guard !state.isResolving else { return }
        state = .resolving(
            SettingsArchivedSessionsResolutionRequest(server: server, id: UUID())
        )
    }

    private func resolve(_ request: SettingsArchivedSessionsResolutionRequest) async {
        do {
            let profile = try await SettingsArchivedSessionsProfileResolver.resolve(
                client: APIClient(baseURL: request.server)
            )
            guard !Task.isCancelled else { return }
            state = .ready(
                SettingsArchivedSessionsDestination(server: request.server, profile: profile)
            )
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
            onAPIError(error)
        }
    }
}
