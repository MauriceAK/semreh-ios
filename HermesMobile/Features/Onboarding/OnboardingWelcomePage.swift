import SwiftUI

struct OnboardingWelcomePage: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    private var logoWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 208 : 244
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)

            SemrehBrandLockup(width: logoWidth)

            Spacer(minLength: 34)

            VStack(spacing: 12) {
                Text("Control Semreh from iPhone or iPad.")
                    .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 27 : 31, weight: .bold))
                    .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.86)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Connect to your self-hosted Hermes server over private HTTPS.")
                    .font(.subheadline)
                    .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: palette))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        HeroBadge(systemImage: "lock.shield.fill", title: String(localized: "Password protected"))
                        HeroBadge(systemImage: "network", title: String(localized: "Tailscale ready"))
                    }

                    VStack(spacing: 8) {
                        HeroBadge(systemImage: "lock.shield.fill", title: String(localized: "Password protected"))
                        HeroBadge(systemImage: "network", title: String(localized: "Tailscale ready"))
                    }
                }
            }
            .frame(maxWidth: 420)

            Spacer(minLength: 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }
}
