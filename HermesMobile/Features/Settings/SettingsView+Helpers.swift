import SwiftUI
import UserNotifications

extension SettingsView {
    @ViewBuilder
    var settingsDestinationIndex: some View {
        VStack(spacing: 0) {
            NavigationLink {
                SettingsView(authManager: authManager, server: server, destination: .appearance)
            } label: {
                SettingsDestinationRow(
                    title: String(localized: "Appearance"),
                    subtitle: String(localized: "Theme and primary actions"),
                    systemImage: "paintpalette"
                )
            }
            .buttonStyle(.plain)

            SettingsIndexDivider()

            NavigationLink {
                SettingsView(authManager: authManager, server: server, destination: .chat)
            } label: {
                SettingsDestinationRow(
                    title: String(localized: "Chat"),
                    subtitle: String(localized: "Interaction, dictation, and transcript details"),
                    systemImage: "bubble.left.and.bubble.right"
                )
            }
            .buttonStyle(.plain)

            SettingsIndexDivider()

            NavigationLink {
                SettingsView(authManager: authManager, server: server, destination: .connections)
            } label: {
                SettingsDestinationRow(
                    title: String(localized: "Connections"),
                    subtitle: String(localized: "Servers, profiles, models, and headers"),
                    systemImage: "server.rack"
                )
            }
            .buttonStyle(.plain)

            SettingsIndexDivider()

            NavigationLink {
                SettingsView(authManager: authManager, server: server, destination: .toolsAndHistory)
            } label: {
                SettingsDestinationRow(
                    title: String(localized: "Tools & History"),
                    subtitle: String(localized: "Organizers, session visibility, and archives"),
                    systemImage: "square.grid.2x2"
                )
            }
            .buttonStyle(.plain)

            SettingsIndexDivider()

            NavigationLink {
                SettingsView(authManager: authManager, server: server, destination: .aboutAndStorage)
            } label: {
                SettingsDestinationRow(
                    title: String(localized: "About & Storage"),
                    subtitle: String(localized: "Support, offline data, and account"),
                    systemImage: "info.circle"
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(
            SemrehVisualTheme.raisedPanel(for: colorScheme, palette: palette),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    var defaultModelLabel: String {
        if isLoadingDefaultModel {
            return String(localized: "Loading")
        }

        guard let defaultModel, !defaultModel.isEmpty else {
            return String(localized: "Not set")
        }

        return defaultModel
    }

    var defaultProfileLabel: String {
        if isLoadingDefaultProfile {
            return String(localized: "Loading")
        }

        if let defaultProfileDisplayName, !defaultProfileDisplayName.isEmpty {
            return defaultProfileDisplayName
        }

        guard let defaultProfileName, !defaultProfileName.isEmpty else {
            return String(localized: "Unavailable")
        }

        return defaultProfileName == "default" ? String(localized: "Default") : defaultProfileName
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "Unknown")
    }

    var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? String(localized: "Unknown")
    }

    var settingsThemeOptions: [AppTheme] {
        [.system, .semrehLight, .semrehDark]
    }

    /// The index intentionally offers only the supported three choices. An
    /// older stored palette remains untouched until the user explicitly picks
    /// one of these options, so upgrading never silently changes appearance.
    var appThemeSettingsBinding: Binding<String> {
        Binding(
            get: {
                guard let storedTheme = AppTheme(rawValue: appThemeRawValue),
                      settingsThemeOptions.contains(storedTheme) else {
                    return AppTheme.system.rawValue
                }
                return storedTheme.rawValue
            },
            set: { appThemeRawValue = $0 }
        )
    }

    var legacyThemeTitle: String? {
        guard let storedTheme = AppTheme(rawValue: appThemeRawValue),
              !settingsThemeOptions.contains(storedTheme) else {
            return nil
        }
        return storedTheme.title
    }

    func settingsThemeTitle(for theme: AppTheme) -> String {
        switch theme {
        case .system:
            return String(localized: "System")
        case .semrehLight:
            return String(localized: "Light")
        case .semrehDark:
            return String(localized: "Dark")
        case .light, .dark, .chatgpt, .midnight, .forest, .sand:
            return theme.title
        }
    }

    var responseCompletionNotificationBinding: Binding<Bool> {
        Binding(
            get: { isResponseCompletionNotificationsEnabled },
            set: { isEnabled in
                if isEnabled {
                    Task {
                        await enableResponseCompletionNotifications()
                    }
                } else {
                    isResponseCompletionNotificationsEnabled = false
                    Task {
                        await refreshNotificationPermissionStatus()
                    }
                }
            }
        )
    }

    var notificationStatusText: String? {
        notificationStatusMessage ?? notificationPermissionStatus.map(notificationPermissionLabel)
    }

    func refreshNotificationPermissionStatus() async {
        let status = await ResponseCompletionNotificationService.authorizationStatus()
        notificationPermissionStatus = status

        if !status.allowsSettingsToggleOn {
            isResponseCompletionNotificationsEnabled = false
        }

        notificationStatusMessage = nil
    }

    func enableResponseCompletionNotifications() async {
        let currentStatus = await ResponseCompletionNotificationService.authorizationStatus()
        notificationPermissionStatus = currentStatus

        switch currentStatus {
        case .authorized, .provisional, .ephemeral:
            isResponseCompletionNotificationsEnabled = true
            notificationStatusMessage = nil
        case .notDetermined:
            guard !hasRequestedResponseCompletionNotificationPermission else {
                isResponseCompletionNotificationsEnabled = false
                notificationStatusMessage = String(localized: "Permission not requested.")
                return
            }

            hasRequestedResponseCompletionNotificationPermission = true
            let granted = await ResponseCompletionNotificationService.requestAuthorization()
            let updatedStatus = await ResponseCompletionNotificationService.authorizationStatus()
            notificationPermissionStatus = updatedStatus
            isResponseCompletionNotificationsEnabled = granted && updatedStatus.allowsSettingsToggleOn
            notificationStatusMessage = isResponseCompletionNotificationsEnabled ? nil : notificationPermissionLabel(updatedStatus)
        case .denied:
            isResponseCompletionNotificationsEnabled = false
            notificationStatusMessage = notificationPermissionLabel(currentStatus)
        @unknown default:
            isResponseCompletionNotificationsEnabled = false
            notificationStatusMessage = String(localized: "Notifications unavailable.")
        }
    }

    func notificationPermissionLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return String(localized: "iOS notifications allowed.")
        case .notDetermined:
            return String(localized: "iOS permission not requested.")
        case .denied:
            return String(localized: "iOS notifications disabled.")
        @unknown default:
            return String(localized: "Notifications unavailable.")
        }
    }
}
