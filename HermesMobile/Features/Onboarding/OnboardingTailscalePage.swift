import SwiftUI

struct OnboardingTailscalePage: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                OnboardingStepHeader(
                    stepNumber: 2,
                    icon: "iphone.and.arrow.forward",
                    title: String(localized: "Install Tailscale on iPhone"),
                    description: String(localized: "If your Hermes server uses Tailscale, install it on your iPhone and sign into the same tailnet. On the next screen, use the authenticated HTTPS address provided by your server administrator.")
                )

                VStack(alignment: .leading, spacing: 14) {
                    tailscaleStep(number: "1", text: String(localized: "Install Tailscale from the App Store."))
                    tailscaleStep(number: "2", text: String(localized: "Sign in with the same account you used on your server."))
                    tailscaleStep(number: "3", text: String(localized: "Keep Tailscale connected while using Semreh."))

                    Button(action: openTailscaleInAppStore) {
                        Label("Get Tailscale on the App Store", systemImage: "arrow.up.forward.square")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(OnboardingTheme.action(for: colorScheme, palette: palette))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                            .background(
                                OnboardingTheme.panel(for: colorScheme, palette: palette).opacity(colorScheme == .dark ? 0.72 : 0.90),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(OnboardingTheme.border(for: colorScheme, palette: palette).opacity(0.78), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the Tailscale page in the App Store.")
                }
                .padding(15)
                .background(
                    OnboardingTheme.panel(for: colorScheme, palette: palette).opacity(colorScheme == .dark ? 0.62 : 0.82),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OnboardingTheme.border(for: colorScheme, palette: palette).opacity(0.72), lineWidth: 1)
                )
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 92)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func openTailscaleInAppStore() {
        openURL(OnboardingFlowPolicy.tailscaleAppStoreURL, completion: { accepted in
            guard !accepted else { return }
            openURL(OnboardingFlowPolicy.tailscaleAppStoreFallbackURL)
        })
    }

    private func tailscaleStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(OnboardingTheme.actionForeground(for: colorScheme, palette: palette))
                .frame(width: 26, height: 26)
                .background(OnboardingTheme.action(for: colorScheme, palette: palette), in: Circle())

            Text(text)
                .font(.subheadline)
                .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: palette))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
