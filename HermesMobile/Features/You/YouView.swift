import SwiftUI

struct YouView: View {
    @Bindable var authManager: AuthManager
    let server: URL

    @AppStorage(SessionIdentitySettings.displayNameKey) private var identityDisplayName = ""
    @AppStorage(SessionIdentitySettings.initialsKey) private var identityInitials = ""
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    @State private var navigationPath = NavigationPath()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette
    @ScaledMetric(relativeTo: .title2) private var avatarSize: CGFloat = 64

    var body: some View {
        NavigationStack(path: $navigationPath) {
            SettingsView(
                authManager: authManager,
                server: server,
                header: AnyView(youHeader)
            )
            .toolbar(
                navigationPath.isEmpty ? .hidden : .visible,
                for: .navigationBar
            )
        }
        .background(SemrehVisualTheme.canvas(for: colorScheme, palette: palette).ignoresSafeArea())
    }

    private var youHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(SemrehTypography.title)
                .foregroundStyle(.primary)
            Text("Preferences and your Hermes setup.")
                .font(SemrehTypography.body).foregroundStyle(.secondary)
            profileCard
        }
        .padding(.top, 16)
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Text(displayInitials)
                    .font(.title2.bold())
                    .foregroundStyle(
                        HeaderLogoColor.prefersDarkForeground(for: headerLogoColorHex) ? .black : .white
                    )
                    .frame(width: avatarSize, height: avatarSize)
                    .background(HeaderLogoColor.color(for: headerLogoColorHex), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(SemrehTypography.heading)
                    Text("Your Semreh profile")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            Divider()
            connectionCard
        }
        .padding(20)
        .background(SemrehVisualTheme.raisedPanel(for: colorScheme, palette: palette), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var connectionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(SemrehVisualTheme.action(for: colorScheme, palette: palette))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Current server")
                    .font(SemrehTypography.label)
                Text(serverDisplayName)
                    .font(SemrehTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var displayName: String {
        let trimmed = identityDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Your profile") : trimmed
    }

    private var displayInitials: String {
        let trimmed = identityInitials.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return String(trimmed.prefix(2)).uppercased()
        }

        let parts = displayName.split(separator: " ")
        if parts.count > 1 {
            return String(parts.prefix(2).compactMap(\.first)).uppercased()
        }

        return String(displayName.prefix(2)).uppercased()
    }

    private var serverDisplayName: String {
        if let host = server.host, !host.isEmpty {
            return host
        }

        return server.absoluteString
    }
}

#Preview {
    YouView(
        authManager: AuthManager(),
        server: URL(staticString: "https://hermes.example.test")
    )
}
