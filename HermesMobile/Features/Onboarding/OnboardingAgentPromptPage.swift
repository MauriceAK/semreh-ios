import SwiftUI

struct OnboardingAgentPromptPage: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                OnboardingStepHeader(
                    stepNumber: 1,
                    icon: "terminal",
                    title: String(localized: "Prepare your Hermes server"),
                    description: String(localized: "Semreh connects to an existing first-party Hermes server. Follow your installed Hermes version's documentation or ask your server administrator for help.")
                )

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
