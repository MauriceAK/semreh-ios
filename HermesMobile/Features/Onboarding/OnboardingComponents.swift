import SwiftUI
import UIKit

enum OnboardingTheme {
    static func primaryText(for colorScheme: ColorScheme, palette: AppColorPalette = .semreh) -> Color {
        colorScheme == .dark
            ? .white
            : Color(hexRGB: SemrehVisualTheme.tokens(for: palette).canvasDarkHex)!
    }

    static func secondaryText(for colorScheme: ColorScheme, palette: AppColorPalette = .semreh) -> Color {
        primaryText(for: colorScheme, palette: palette).opacity(colorScheme == .dark ? 0.62 : 0.64)
    }

    static func tertiaryText(for colorScheme: ColorScheme, palette: AppColorPalette = .semreh) -> Color {
        primaryText(for: colorScheme, palette: palette).opacity(colorScheme == .dark ? 0.42 : 0.50)
    }

    static func action(
        for colorScheme: ColorScheme,
        palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> Color {
        SemrehVisualTheme.action(for: colorScheme, palette: palette, accent: accent)
    }

    static func actionForeground(
        for colorScheme: ColorScheme,
        palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> Color {
        SemrehVisualTheme.accentForeground(for: colorScheme, palette: palette, accent: accent)
    }

    static func panel(for colorScheme: ColorScheme, palette: AppColorPalette = .semreh) -> Color {
        SemrehVisualTheme.panel(for: colorScheme, palette: palette)
    }

    static func border(for colorScheme: ColorScheme, palette: AppColorPalette = .semreh) -> Color {
        SemrehVisualTheme.subtleStroke(for: colorScheme, palette: palette)
    }
}

struct SemrehBrandLockup: View {
    /// The lockup stays within the compact 210–224pt onboarding target. The
    /// standalone winged-S mark stays transparent so it does not bring the
    /// opaque app-icon tile into the onboarding canvas. The wordmark remains
    /// native rounded text so it follows Dynamic Type and the active contrast.
    var width: CGFloat = 220
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            SemrehWingedSMark()
                .frame(width: 62, height: 62)

            Text("Semreh")
                .font(.system(.largeTitle, design: .rounded, weight: .medium))
                .foregroundStyle(
                    colorScheme == .dark
                        ? Color(hexRGB: "#F7F3EA")!
                        : Color(hexRGB: SemrehVisualTheme.logoNavyHex)!
                )
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: width, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Semreh")
        .accessibilityAddTraits(.isImage)
    }
}

/// Code-native rendering of the approved winged-S paths. The source SVG's
/// opaque paper rectangle is intentionally omitted; only its unchanged paths
/// and optical translation are rendered here.
struct SemrehWingedSMark: View {
    private static let designSize: CGFloat = 1024
    private static let opticalTranslation = CGAffineTransform(translationX: 49, y: -32)

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / Self.designSize

            ZStack {
                Self.upperPath
                    .applying(Self.opticalTranslation)
                    .fill(upperColor)
                Self.lowerPath
                    .applying(Self.opticalTranslation)
                    .fill(lowerColor)
            }
            .frame(width: Self.designSize, height: Self.designSize)
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var upperColor: Color {
        // These are the approved mark colors already used by the canonical
        // icon. Cream keeps the upper path legible on the dark canvas.
        colorScheme == .dark
            ? Color(hexRGB: "#F7F3EA")!
            : Color(hexRGB: "#20252B")!
    }

    private var lowerColor: Color {
        Color(hexRGB: "#8DA4B5")!
    }

    private static var upperPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 780, y: 187))
        path.addCurve(
            to: CGPoint(x: 681, y: 339),
            control1: CGPoint(x: 774, y: 245),
            control2: CGPoint(x: 779, y: 291)
        )
        path.addCurve(
            to: CGPoint(x: 742, y: 319),
            control1: CGPoint(x: 704, y: 337),
            control2: CGPoint(x: 724, y: 328)
        )
        path.addCurve(
            to: CGPoint(x: 622, y: 413),
            control1: CGPoint(x: 724, y: 376),
            control2: CGPoint(x: 682, y: 409)
        )
        path.addLine(to: CGPoint(x: 428, y: 414))
        path.addCurve(
            to: CGPoint(x: 362, y: 483),
            control1: CGPoint(x: 387, y: 416),
            control2: CGPoint(x: 363, y: 445)
        )
        path.addCurve(
            to: CGPoint(x: 475, y: 621),
            control1: CGPoint(x: 359, y: 541),
            control2: CGPoint(x: 411, y: 582)
        )
        path.addLine(to: CGPoint(x: 362, y: 621))
        path.addCurve(
            to: CGPoint(x: 212, y: 493),
            control1: CGPoint(x: 268, y: 621),
            control2: CGPoint(x: 211, y: 578)
        )
        path.addCurve(
            to: CGPoint(x: 351, y: 291),
            control1: CGPoint(x: 212, y: 396),
            control2: CGPoint(x: 264, y: 324)
        )
        path.addCurve(
            to: CGPoint(x: 523, y: 270),
            control1: CGPoint(x: 399, y: 272),
            control2: CGPoint(x: 454, y: 274)
        )
        path.addCurve(
            to: CGPoint(x: 780, y: 187),
            control1: CGPoint(x: 637, y: 271),
            control2: CGPoint(x: 725, y: 264)
        )
        path.closeSubpath()
        return path
    }

    private static var lowerPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 432, y: 477))
        path.addLine(to: CGPoint(x: 552, y: 477))
        path.addCurve(
            to: CGPoint(x: 711, y: 619),
            control1: CGPoint(x: 641, y: 477),
            control2: CGPoint(x: 711, y: 530)
        )
        path.addCurve(
            to: CGPoint(x: 561, y: 805),
            control1: CGPoint(x: 711, y: 716),
            control2: CGPoint(x: 650, y: 784)
        )
        path.addCurve(
            to: CGPoint(x: 441, y: 811),
            control1: CGPoint(x: 527, y: 813),
            control2: CGPoint(x: 486, y: 810)
        )
        path.addLine(to: CGPoint(x: 334, y: 811))
        path.addCurve(
            to: CGPoint(x: 173, y: 885),
            control1: CGPoint(x: 259, y: 811),
            control2: CGPoint(x: 211, y: 830)
        )
        path.addCurve(
            to: CGPoint(x: 289, y: 699),
            control1: CGPoint(x: 173, y: 790),
            control2: CGPoint(x: 218, y: 728)
        )
        path.addCurve(
            to: CGPoint(x: 407, y: 680),
            control1: CGPoint(x: 326, y: 683),
            control2: CGPoint(x: 363, y: 681)
        )
        path.addLine(to: CGPoint(x: 462, y: 680))
        path.addCurve(
            to: CGPoint(x: 551, y: 614),
            control1: CGPoint(x: 514, y: 680),
            control2: CGPoint(x: 550, y: 654)
        )
        path.addCurve(
            to: CGPoint(x: 432, y: 477),
            control1: CGPoint(x: 552, y: 563),
            control2: CGPoint(x: 493, y: 518)
        )
        path.closeSubpath()
        return path
    }
}

struct HeroBadge: View {
    let systemImage: String
    let title: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: palette))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                OnboardingTheme.panel(for: colorScheme, palette: palette).opacity(colorScheme == .dark ? 0.68 : 0.82),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(OnboardingTheme.border(for: colorScheme, palette: palette).opacity(0.65), lineWidth: 1)
            )
    }
}

struct SetupStepRow: View {
    let number: String
    let title: String
    let subtitle: String
    var command: String?
    var commandPrefix: String? = "$"
    var copyValue: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(OnboardingTheme.actionForeground(for: colorScheme, palette: palette))
                .frame(width: 26, height: 26)
                .background(OnboardingTheme.action(for: colorScheme, palette: palette), in: Circle())
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette))

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(OnboardingTheme.tertiaryText(for: colorScheme, palette: palette))
                    .fixedSize(horizontal: false, vertical: true)

                if let command {
                    OnboardingCommandPill(text: command, prefix: commandPrefix, copyValue: copyValue)
                }
            }
        }
    }
}

struct OnboardingCommandPill: View {
    let text: String
    var prefix: String? = "$"
    var copyValue: String?
    @State private var didCopy = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                if let prefix {
                    Text("\(prefix) ")
                        .foregroundStyle(OnboardingTheme.tertiaryText(for: colorScheme, palette: palette).opacity(0.72))
                }

                Text(text)
                    .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette).opacity(0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let copyValue {
                Button {
                    UIPasteboard.general.string = copyValue
                    didCopy = true
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            didCopy
                                ? Color.green
                                : OnboardingTheme.primaryText(for: colorScheme, palette: palette).opacity(0.76)
                        )
                        .frame(width: 30, height: 30)
                        .background(
                            OnboardingTheme.action(for: colorScheme, palette: palette).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    didCopy
                        ? String(localized: "Copied setup value")
                        : String(localized: "Copy setup value")
                )
            }
        }
        .font(.system(.caption, design: .monospaced, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            OnboardingTheme.panel(for: colorScheme, palette: palette).opacity(colorScheme == .dark ? 0.72 : 0.88),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(OnboardingTheme.border(for: colorScheme, palette: palette).opacity(0.72), lineWidth: 1)
        )
    }
}

struct OnboardingField<Content: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette
    @Environment(\.appAccent) private var accent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnboardingTheme.action(for: colorScheme, palette: palette, accent: accent))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OnboardingTheme.tertiaryText(for: colorScheme, palette: palette))

                content
                    .font(.body.weight(.medium))
                    .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(
            OnboardingTheme.panel(for: colorScheme, palette: palette).opacity(colorScheme == .dark ? 0.74 : 0.92),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OnboardingTheme.border(for: colorScheme, palette: palette).opacity(0.70), lineWidth: 1)
        )
    }
}

struct OnboardingStatusBanner: View {
    let text: String
    let systemImage: String
    let tint: Color
    var showsProgress = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsProgress {
                ProgressView()
                    .tint(tint)
                    .padding(.top, 1)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .padding(.top, 1)
            }

            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette).opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(colorScheme == .dark ? 0.14 : 0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        )
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette
    @Environment(\.appAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(OnboardingTheme.actionForeground(for: colorScheme, palette: palette, accent: accent))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .frame(minHeight: 52)
            .background(OnboardingTheme.action(for: colorScheme, palette: palette, accent: accent), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct OnboardingStepHeader: View {
    let stepNumber: Int
    let icon: String
    let title: String
    let description: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(OnboardingTheme.action(for: colorScheme, palette: palette))
                .frame(width: 68, height: 68)
                .background(
                    OnboardingTheme.panel(for: colorScheme, palette: palette).opacity(colorScheme == .dark ? 0.72 : 0.92),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OnboardingTheme.action(for: colorScheme, palette: palette).opacity(0.30), lineWidth: 1)
                )
                .accessibilityHidden(true)

            VStack(spacing: 9) {
                Text("STEP \(stepNumber)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(OnboardingTheme.brandAccent(for: colorScheme, palette: palette).opacity(0.86))
                    .kerning(1.5)

                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(OnboardingTheme.secondaryText(for: colorScheme, palette: palette))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private extension OnboardingTheme {
    static func brandAccent(for colorScheme: ColorScheme, palette: AppColorPalette = .semreh) -> Color {
        SemrehVisualTheme.brandAccent(for: colorScheme, palette: palette)
    }
}

struct OnboardingPageIndicator: View {
    let pageCount: Int
    let currentPage: Int
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette
    @Environment(\.appAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(
                        index == currentPage
                            ? OnboardingTheme.action(for: colorScheme, palette: palette, accent: accent)
                            : OnboardingTheme.primaryText(for: colorScheme, palette: palette).opacity(0.18)
                    )
                    .frame(width: index == currentPage ? 24 : 8, height: 8)
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
            value: currentPage
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Page \(currentPage + 1) of \(pageCount)"))
    }
}

struct OnboardingSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(OnboardingTheme.primaryText(for: colorScheme, palette: palette).opacity(0.86))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 15)
            .background(
                OnboardingTheme.panel(for: colorScheme, palette: palette).opacity(colorScheme == .dark ? 0.72 : 0.90),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(OnboardingTheme.border(for: colorScheme, palette: palette).opacity(0.78), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
