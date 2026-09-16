import SwiftUI

struct OnboardingAgentPromptPage: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect to your Hermes")
                        .font(SemrehTypography.heading)
                        .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette))
                    Text("Already have a server address? Close this guide and enter it, or scan a QR containing that address. Review the imported address, then sign in with your existing server account.")
                        .font(SemrehTypography.body)
                        .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: palette))
                    Text("If someone manages your server, ask them for the address and connection details. The notes below are for people setting up their own server.")
                        .font(SemrehTypography.body)
                        .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: palette))
                }

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(OnboardingFlowPolicy.serverGuidanceSteps.enumerated()), id: \.offset) { index, step in
                        SetupStepRow(number: String(index + 1), title: step.title, subtitle: step.detail)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 92)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
