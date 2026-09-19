import SwiftUI

struct YouView: View {
    @Bindable var authManager: AuthManager
    let server: URL

    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        NavigationStack {
            SettingsView(
                authManager: authManager,
                server: server,
                header: AnyView(youHeader)
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
            connectionCard
        }
        .padding(.top, 16)
    }

    private var connectionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(HeaderLogoColor.color(for: headerLogoColorHex))
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
        .padding(16)
        .background(
            SemrehVisualTheme.raisedPanel(for: colorScheme, palette: palette),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .accessibilityElement(children: .combine)
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
