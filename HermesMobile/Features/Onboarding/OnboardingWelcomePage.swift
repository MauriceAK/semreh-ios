import SwiftUI

struct OnboardingWelcomePage: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    private var logoWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 210 : 220
    }

    private let birdIdentities: [BirdAvatarIdentity] = {
        guard let server = URL(string: "https://semreh.example") else { return [] }
        return (0..<5).compactMap { BirdAvatarIdentity(server: server, profile: "onboarding-\($0)") }
    }()

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                ZStack {
                    if shouldShowBirds(in: geometry.size) {
                        OnboardingBirdPerimeter(
                            identities: birdIdentities,
                            canvasSize: geometry.size
                        )
                    }

                    VStack(spacing: 0) {
                        Spacer(minLength: 70)

                        SemrehBrandLockup(width: logoWidth)

                        Color.clear.frame(height: 20)

                        Text("Your Hermes companion")
                            .font(.system(.title3, design: .rounded, weight: .medium))
                            .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: .semreh))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 70)
                    }
                    .frame(width: min(420, max(0, geometry.size.width - 48)))
                    .frame(minHeight: geometry.size.height)
                    .padding(.horizontal, 24)
                }
                .frame(width: geometry.size.width)
                .frame(minHeight: geometry.size.height)
                .padding(.bottom, 18)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func shouldShowBirds(in size: CGSize) -> Bool {
        !dynamicTypeSize.isAccessibilitySize && size.width >= 320 && size.height >= 420
    }
}

private struct OnboardingBirdPerimeter: View {
    let identities: [BirdAvatarIdentity]
    let canvasSize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    private let placements: [(x: CGFloat, y: CGFloat, size: CGFloat, rotation: Double, mirrored: Bool)] = [
        (42, 90, 48, -8, false),
        (-42, 152, 58, 10, true),
        (28, 0.42, 46, -5, false),
        (-34, 0.58, 64, 8, true),
        (-70, -74, 52, -11, false)
    ]

    var body: some View {
        ZStack {
            ForEach(Array(placements.enumerated()), id: \.offset) { index, placement in
                if index < identities.count {
                    BirdAvatarView(identity: identities[index])
                        .frame(width: placement.size, height: placement.size)
                        .scaleEffect(x: placement.mirrored ? -1 : 1, y: 1)
                        .rotationEffect(.degrees(placement.rotation))
                        .opacity(reduceMotion || hasAppeared ? 1 : 0)
                        .offset(y: reduceMotion || hasAppeared ? 0 : 6)
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeOut(duration: 0.42).delay(Double(index) * 0.06),
                            value: hasAppeared
                        )
                        .position(
                            x: positionX(placement.x),
                            y: positionY(placement.y)
                        )
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { hasAppeared = true }
    }

    private func positionX(_ offset: CGFloat) -> CGFloat {
        offset >= 0 ? offset : canvasSize.width + offset
    }

    private func positionY(_ value: CGFloat) -> CGFloat {
        if value > 0, value < 1 {
            return canvasSize.height * value
        }
        return value >= 0 ? value : canvasSize.height + value
    }
}
