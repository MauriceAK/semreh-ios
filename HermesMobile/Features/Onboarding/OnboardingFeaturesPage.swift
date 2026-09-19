import SwiftUI

/// The appearance step writes the same values as Settings so the preview is
/// real state, not a one-off onboarding decoration.
struct OnboardingAppearancePage: View {
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue
    @AppStorage(AppAccent.storageKey) private var appAccentRawValue = AppAccent.defaultValue.rawValue
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    private let themeOptions: [AppTheme] = [.system, .semrehLight, .semrehDark]

    private var selectedTheme: AppTheme {
        let stored = AppTheme.storedValue(appThemeRawValue)
        return themeOptions.contains(stored) ? stored : .system
    }

    private var selectedThemeTitle: String {
        switch selectedTheme {
        case .system: String(localized: "System")
        case .semrehLight: String(localized: "Light")
        case .semrehDark: String(localized: "Dark")
        default: selectedTheme.title
        }
    }

    private var selectedAccent: AppAccent {
        AppAccent.storedValue(appAccentRawValue)
    }

    private var previewColorScheme: ColorScheme {
        selectedTheme.colorScheme ?? colorScheme
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 24 : 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Make it yours")
                        .font(SemrehTypography.heading)
                        .foregroundStyle(OnboardingTheme.primaryText(for: previewColorScheme, palette: .semreh))

                    Text("Choose a look for Semreh. You can change it anytime in Settings.")
                        .font(SemrehTypography.body)
                        .foregroundStyle(OnboardingTheme.secondaryText(for: previewColorScheme, palette: .semreh))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Theme")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OnboardingTheme.primaryText(for: previewColorScheme, palette: .semreh))

                    HStack(spacing: 10) {
                        ForEach(themeOptions) { theme in
                            ThemeChoiceButton(
                                theme: theme,
                                isSelected: selectedTheme == theme,
                                colorScheme: previewColorScheme,
                                accent: selectedAccent,
                                action: { appThemeRawValue = theme.rawValue }
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Accent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OnboardingTheme.primaryText(for: previewColorScheme, palette: .semreh))

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5),
                        spacing: 10
                    ) {
                        ForEach(AppAccent.allCases) { accent in
                            AccentChoiceButton(
                                accent: accent,
                                isSelected: selectedAccent == accent,
                                colorScheme: previewColorScheme,
                                action: { appAccentRawValue = accent.rawValue }
                            )
                        }
                    }
                }

                AppearancePreview(
                    colorScheme: previewColorScheme,
                    accent: selectedAccent
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    String(localized: "Preview using \(selectedThemeTitle) appearance and \(selectedAccent.title) accent")
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, dynamicTypeSize.isAccessibilitySize ? 26 : 40)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Keep the environment consumed by onboarding descendants in sync even
        // when this screen is previewed outside the app root.
        .environment(\.appAccent, selectedAccent)
        .environment(\.appColorPalette, .semreh)
    }
}

// Keep the former source symbol available for previews and older callers while
// the production pager uses the focused appearance step above.
typealias OnboardingFeaturesPage = OnboardingAppearancePage

private struct ThemeChoiceButton: View {
    let theme: AppTheme
    let isSelected: Bool
    let colorScheme: ColorScheme
    let accent: AppAccent
    let action: () -> Void

    private var title: String {
        switch theme {
        case .system: String(localized: "System")
        case .semrehLight: String(localized: "Light")
        case .semrehDark: String(localized: "Dark")
        default: theme.title
        }
    }

    private var systemImage: String {
        switch theme {
        case .system: "circle.lefthalf.filled"
        case .semrehLight: "sun.max.fill"
        case .semrehDark: "moon.fill"
        default: "circle.lefthalf.filled"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .foregroundStyle(
                isSelected
                    ? SemrehVisualTheme.accentForeground(for: colorScheme, palette: .semreh, accent: accent)
                    : OnboardingTheme.primaryText(for: colorScheme, palette: .semreh)
            )
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(
                isSelected
                    ? SemrehVisualTheme.action(for: colorScheme, palette: .semreh, accent: accent)
                    : SemrehVisualTheme.panel(for: colorScheme, palette: .semreh),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isSelected
                            ? SemrehVisualTheme.action(for: colorScheme, palette: .semreh, accent: accent)
                            : OnboardingTheme.border(for: colorScheme, palette: .semreh),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AccentChoiceButton: View {
    let accent: AppAccent
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(SemrehVisualTheme.action(for: colorScheme, palette: .semreh, accent: accent))
                    .frame(width: 25, height: 25)

                if isSelected {
                    Circle()
                        .stroke(
                            SemrehVisualTheme.accentForeground(
                                for: colorScheme,
                                palette: .semreh,
                                accent: accent
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 35, height: 35)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(String(localized: "\(accent.title) accent"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AppearancePreview: View {
    let colorScheme: ColorScheme
    let accent: AppAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OnboardingTheme.tertiaryText(for: colorScheme, palette: .semreh))

            HStack(spacing: 12) {
                BirdAvatarView(identity: previewIdentity)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Hermes companion")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: .semreh))
                    Text("Ready when you are")
                        .font(.caption)
                        .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: .semreh))
                }

                Spacer(minLength: 0)
            }

            HStack {
                Spacer(minLength: 28)

                Text("Hello, Hermes")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(
                        SemrehVisualTheme.accentForeground(
                            for: colorScheme,
                            palette: .semreh,
                            accent: accent
                        )
                    )
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(
                        SemrehVisualTheme.action(
                            for: colorScheme,
                            palette: .semreh,
                            accent: accent
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
            }
        }
        .padding(.top, 4)
    }

    private var previewIdentity: BirdAvatarIdentity {
        // The URL/profile are visual-only and never used for routing.
        BirdAvatarIdentity(
            server: URL(string: "https://semreh.example"),
            profile: "appearance-preview"
        )!
    }
}
