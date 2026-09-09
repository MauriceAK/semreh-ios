import SwiftUI

struct OnboardingFeaturesPage: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    private let features: [(icon: String, title: String, subtitle: String)] = [
        ("bubble.left.and.bubble.right.fill", String(localized: "Chat with Semreh from iPhone"), String(localized: "Drive conversations from anywhere on your tailnet.")),
        ("list.bullet.rectangle.portrait.fill", String(localized: "Manage sessions, tasks, and files remotely"), String(localized: "Browse workspaces and stay on top of agent work.")),
        ("mic.fill", String(localized: "Voice input and mobile-friendly composer controls"), String(localized: "Compose naturally with touch-first controls.")),
        ("checkmark.shield.fill", String(localized: "Review approvals and clarifications inline"), String(localized: "Respond to agent prompts without switching apps.")),
        ("server.rack", String(localized: "Self-hosted: your machine, your network"), String(localized: "Your Hermes server stays on hardware you control."))
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 24 : 28) {
                Image("SemrehWing")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 78)
                    .accessibilityHidden(true)
                    .padding(.top, 24)

                VStack(spacing: 9) {
                    Text("What you get")
                        .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 26 : 29, weight: .bold))
                        .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette))

                    Text("Semreh, reachable from iPhone over Tailscale.")
                        .font(.subheadline)
                        .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: palette))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                        OnboardingFeatureRow(
                            icon: feature.icon,
                            title: feature.title,
                            subtitle: feature.subtitle
                        )
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 92)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct OnboardingFeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnboardingTheme.action(for: colorScheme, palette: palette))
                .frame(width: 42, height: 42)
                .background(
                    OnboardingTheme.action(for: colorScheme, palette: palette).opacity(colorScheme == .dark ? 0.16 : 0.10),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette))
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(OnboardingTheme.tertiaryText(for: colorScheme, palette: palette))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            OnboardingTheme.panel(for: colorScheme, palette: palette).opacity(colorScheme == .dark ? 0.70 : 0.90),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(OnboardingTheme.border(for: colorScheme, palette: palette).opacity(0.72), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
