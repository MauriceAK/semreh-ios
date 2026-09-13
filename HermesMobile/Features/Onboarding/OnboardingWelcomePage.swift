import SwiftUI

struct OnboardingWelcomePage: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    private var logoWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 208 : 244
    }

    var body: some View {
        ScrollView {
        VStack(spacing: 0) {
            Spacer(minLength: 30)

            SemrehBrandLockup(width: logoWidth)

            Spacer(minLength: 34)

            VStack(spacing: 12) {
                Text("Your conversations.\nYour agents.")
                    .font(SemrehTypography.title)
                    .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Connect to your Hermes server to pick up a conversation or start something new.")
                    .font(SemrehTypography.body)
                    .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: palette))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Use your existing server address and sign-in, or scan a server QR code.")
                    .font(SemrehTypography.caption)
                    .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: palette))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .frame(maxWidth: 420)

            Spacer(minLength: 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
