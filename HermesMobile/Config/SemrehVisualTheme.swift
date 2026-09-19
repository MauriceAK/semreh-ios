import Foundation
import SwiftUI

/// The small, product-level accent family used by Semreh's native controls and
/// user message surfaces. This is intentionally separate from `HeaderLogoColor`,
/// which remains a legacy per-server identity color.
enum AppAccent: String, CaseIterable, Identifiable, Sendable {
    case warm
    case violet
    case blue
    case mint
    case rose

    static let storageKey = "appearance.appAccent"
    static let defaultValue: AppAccent = .warm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .warm:
            String(localized: "Warm")
        case .violet:
            String(localized: "Violet")
        case .blue:
            String(localized: "Blue")
        case .mint:
            String(localized: "Mint")
        case .rose:
            String(localized: "Rose")
        }
    }

    /// Invalid or stale persisted values must never change the default look.
    static func storedValue(_ rawValue: String) -> AppAccent {
        AppAccent(rawValue: rawValue) ?? defaultValue
    }
}

private struct AppAccentKey: EnvironmentKey {
    static let defaultValue = AppAccent.defaultValue
}

extension EnvironmentValues {
    /// The resolved accent for the current app tree. Pure theme functions take
    /// this value explicitly so they remain deterministic and testable.
    var appAccent: AppAccent {
        get { self[AppAccentKey.self] }
        set { self[AppAccentKey.self] = newValue }
    }
}

private struct AppColorPaletteKey: EnvironmentKey {
    static let defaultValue = AppColorPalette.semreh
}

extension EnvironmentValues {
    var appColorPalette: AppColorPalette {
        get { self[AppColorPaletteKey.self] }
        set { self[AppColorPaletteKey.self] = newValue }
    }
}

/// Product-wide semantic palette. Semreh stays the default; named themes swap
/// canvas/action/energy tokens while keeping the same roles and contrast rules.
enum SemrehVisualTheme {
    // Legacy Goku palette: disciplined royal blue + warm yellow, with no orange brand token.
    static let gokuBlueHex = "#1E4FA3"
    static let gokuBlueDarkHex = "#6FA8FF"
    static let gokuYellowHex = "#FFD447"
    static let gokuYellowForegroundHex = "#241B00"
    static let gokuDeepNavyHex = "#0B1B34"

    // Canonical Semreh logo colors.
    static let logoNavyHex = "#032357"
    static let logoTealHex = "#12C7B5"
    static let logoAquaHex = "#31D8CA"
    static let deepNavyHex = logoNavyHex
    static let primaryActionForegroundHex = logoNavyHex

    static let gokuBlue = Color(hexRGB: gokuBlueHex)!
    static let gokuBlueDark = Color(hexRGB: gokuBlueDarkHex)!
    static let gokuYellow = Color(hexRGB: gokuYellowHex)!
    static let gokuDeepNavy = Color(hexRGB: gokuDeepNavyHex)!
    static let deepNavy = Color(hexRGB: deepNavyHex)!
    static let logoNavy = Color(hexRGB: logoNavyHex)!
    static let logoTeal = Color(hexRGB: logoTealHex)!
    static let logoAqua = Color(hexRGB: logoAquaHex)!
    static let brandAction = logoTeal
    static let energy = logoTeal
    static let primaryActionForeground = Color(hexRGB: primaryActionForegroundHex)!

    static func canvasHex(for colorScheme: ColorScheme, palette: AppColorPalette = .semreh) -> String {
        tokens(for: palette).canvasHex(for: colorScheme)
    }

    static func panelHex(for colorScheme: ColorScheme, palette: AppColorPalette = .semreh) -> String {
        tokens(for: palette).panelHex(for: colorScheme)
    }

    static func actionHex(
        for colorScheme: ColorScheme,
        palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> String {
        if palette == .semreh {
            return accentTokens(for: accent).actionHex(for: colorScheme)
        }

        return tokens(for: palette).actionHex(for: colorScheme)
    }

    static func action(
        for colorScheme: ColorScheme,
        palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> Color {
        Color(hexRGB: actionHex(for: colorScheme, palette: palette, accent: accent))!
    }

    static func accentForegroundHex(
        for colorScheme: ColorScheme,
        palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> String {
        if palette == .semreh {
            return accentTokens(for: accent).accentForegroundHex(for: colorScheme)
        }

        return tokens(for: palette).accentForegroundHex(for: colorScheme)
    }

    static func accentForeground(
        for colorScheme: ColorScheme,
        palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> Color {
        Color(hexRGB: accentForegroundHex(for: colorScheme, palette: palette, accent: accent))!
    }

    static func brandAccentHex(
        for colorScheme: ColorScheme,
        palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> String {
        if palette == .semreh {
            return accentTokens(for: accent).brandAccentHex(for: colorScheme)
        }

        return tokens(for: palette).brandAccentHex(for: colorScheme)
    }

    static func brandAccent(
        for colorScheme: ColorScheme,
        palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> Color {
        Color(hexRGB: brandAccentHex(for: colorScheme, palette: palette, accent: accent))!
    }

    static func canvas(for colorScheme: ColorScheme, palette: AppColorPalette = .semreh) -> Color {
        Color(hexRGB: canvasHex(for: colorScheme, palette: palette))!
    }

    static func panel(for colorScheme: ColorScheme, palette: AppColorPalette = .semreh) -> Color {
        Color(hexRGB: panelHex(for: colorScheme, palette: palette))!
    }

    static func raisedPanel(for colorScheme: ColorScheme, palette: AppColorPalette = .semreh) -> Color {
        Color(hexRGB: tokens(for: palette).raisedHex(for: colorScheme))!
    }

    static func energyHex(
        for palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> String {
        if palette == .semreh {
            return accentTokens(for: accent).energyHex
        }

        return tokens(for: palette).energyHex
    }

    static func energy(
        for palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> Color {
        Color(hexRGB: energyHex(for: palette, accent: accent))!
    }

    static func energyForegroundHex(
        for palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> String {
        if palette == .semreh {
            return accentTokens(for: accent).energyForegroundHex
        }

        return tokens(for: palette).energyForegroundHex
    }

    static func energyForeground(
        for palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> Color {
        Color(hexRGB: energyForegroundHex(for: palette, accent: accent))!
    }

    static func brandActionHex(
        for palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> String {
        if palette == .semreh {
            return accentTokens(for: accent).brandActionHex
        }

        return tokens(for: palette).brandActionHex
    }

    static func brandActionColor(
        for palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> Color {
        Color(hexRGB: brandActionHex(for: palette, accent: accent))!
    }

    /// Prompt surfaces coordinate with the accent without saturating the transcript.
    static func promptBubbleBackgroundHex(
        for colorScheme: ColorScheme,
        palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> String {
        if palette == .semreh {
            return accentTokens(for: accent).promptBubbleBackgroundHex(for: colorScheme)
        }

        switch palette {
        case .goku:
            return colorScheme == .dark ? "#2FE099" : "#39E89A"
        case .semreh:
            return colorScheme == .dark ? "#D4B992" : "#E7D3B3"
        case .chatgpt:
            return colorScheme == .dark ? "#2DD4A0" : "#43D39E"
        case .midnight:
            return colorScheme == .dark ? "#73E8C0" : "#8BE8C7"
        case .forest:
            return colorScheme == .dark ? "#6ED39A" : "#8BE0A5"
        case .sand:
            return colorScheme == .dark ? "#8FD6A4" : "#A8E6B8"
        }
    }

    static func promptBubbleForegroundHex(
        for palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> String {
        if palette == .semreh {
            return accentTokens(for: accent).promptBubbleForegroundHex
        }

        switch palette {
        case .goku:
            return gokuDeepNavyHex
        case .semreh:
            return "#30251D"
        case .chatgpt:
            return "#06281F"
        case .midnight:
            return "#151B3D"
        case .forest:
            return "#102016"
        case .sand:
            return "#1B2A20"
        }
    }

    static func promptBubbleBorderHex(
        for colorScheme: ColorScheme,
        palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> String {
        if palette == .semreh {
            return accentTokens(for: accent).promptBubbleBorderHex(for: colorScheme)
        }

        switch palette {
        case .goku:
            return colorScheme == .dark ? gokuBlueDarkHex : "#5F8FE8"
        case .semreh:
            return colorScheme == .dark ? "#AC8C63" : "#C6AB83"
        case .chatgpt:
            return colorScheme == .dark ? "#62D9B4" : "#19C37D"
        case .midnight:
            return colorScheme == .dark ? "#A5B4FF" : "#7C8CFF"
        case .forest:
            return colorScheme == .dark ? "#6ED39A" : "#4FAE73"
        case .sand:
            return colorScheme == .dark ? "#E8A07A" : "#C96442"
        }
    }

    static func promptBubbleBackground(
        for colorScheme: ColorScheme,
        palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> Color {
        Color(hexRGB: promptBubbleBackgroundHex(for: colorScheme, palette: palette, accent: accent))!
    }

    static func promptBubbleForeground(
        for palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> Color {
        Color(hexRGB: promptBubbleForegroundHex(for: palette, accent: accent))!
    }

    static func promptBubbleBorder(
        for colorScheme: ColorScheme,
        palette: AppColorPalette = .semreh,
        accent: AppAccent = .warm
    ) -> Color {
        Color(hexRGB: promptBubbleBorderHex(for: colorScheme, palette: palette, accent: accent))!
    }

    static func statusPositive(for palette: AppColorPalette = .semreh) -> Color {
        switch palette {
        case .goku: Color(hexRGB: "#65D7A4")!
        case .semreh: Color(hexRGB: "#4FD6A1")!
        case .chatgpt: Color(hexRGB: "#4ADE80")!
        case .midnight: Color(hexRGB: "#A5B4FF")!
        case .forest: Color(hexRGB: "#7BC67E")!
        case .sand: Color(hexRGB: "#E0B07A")!
        }
    }

    static func statusWarning(for palette: AppColorPalette = .semreh) -> Color {
        switch palette {
        case .goku: gokuYellow
        case .semreh: Color(hexRGB: "#E6C45A")!
        case .chatgpt: Color(hexRGB: "#E7C56A")!
        case .midnight: Color(hexRGB: "#C4B5FD")!
        case .forest: Color(hexRGB: "#C6D77A")!
        case .sand: Color(hexRGB: "#E8A07A")!
        }
    }

    static func statusCritical(for palette: AppColorPalette = .semreh) -> Color {
        switch palette {
        case .goku: Color(hexRGB: "#FF8A8A")!
        case .semreh: Color(hexRGB: "#E87980")!
        case .chatgpt: Color(hexRGB: "#F28B82")!
        case .midnight: Color(hexRGB: "#FF9A9A")!
        case .forest: Color(hexRGB: "#E98B8B")!
        case .sand: Color(hexRGB: "#D96C75")!
        }
    }

    static func statusInfo(for colorScheme: ColorScheme, palette: AppColorPalette = .semreh) -> Color {
        action(for: colorScheme, palette: palette)
    }

    static func chromeSurfaceOpacity(reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1 : 0.88
    }

    static func navigationBarOpacity(
        for colorScheme: ColorScheme,
        reduceTransparency: Bool
    ) -> Double {
        guard !reduceTransparency else { return 1 }
        return colorScheme == .dark ? 0.86 : 0.92
    }

    static func navigationBarBackground(
        for colorScheme: ColorScheme,
        reduceTransparency: Bool,
        palette: AppColorPalette = .semreh
    ) -> Color {
        canvas(for: colorScheme, palette: palette).opacity(navigationBarOpacity(
            for: colorScheme,
            reduceTransparency: reduceTransparency
        ))
    }

    static func panelStrokeOpacity(
        for colorScheme: ColorScheme,
        increasedContrast: Bool
    ) -> Double {
        switch (colorScheme, increasedContrast) {
        case (.dark, true): 0.42
        case (.light, true): 0.32
        case (.dark, false): 0.20
        case (.light, false): 0.14
        @unknown default: increasedContrast ? 0.36 : 0.17
        }
    }

    static func subtleStroke(
        for colorScheme: ColorScheme,
        increasedContrast: Bool = false,
        palette: AppColorPalette = .semreh
    ) -> Color {
        (palette == .semreh ? Color.primary : action(for: colorScheme, palette: palette)).opacity(panelStrokeOpacity(
            for: colorScheme,
            increasedContrast: increasedContrast
        ))
    }

    static var brandGradient: LinearGradient {
        brandGradient(for: .semreh)
    }

    static func brandGradient(for palette: AppColorPalette) -> LinearGradient {
        let tokens = tokens(for: palette)
        return LinearGradient(
            colors: [
                Color(hexRGB: tokens.energyHex)!,
                Color(hexRGB: tokens.brandActionHex)!
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var energyGradient: LinearGradient {
        energyGradient(for: .semreh)
    }

    static func energyGradient(for palette: AppColorPalette) -> LinearGradient {
        let tokens = tokens(for: palette)
        return LinearGradient(
            colors: [
                Color(hexRGB: tokens.actionLightHex)!,
                Color(hexRGB: tokens.gradientMidHex)!,
                Color(hexRGB: tokens.energyHex)!
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    static func contrastRatio(foregroundHex: String, backgroundHex: String) -> Double {
        guard let foreground = relativeLuminance(for: foregroundHex),
              let background = relativeLuminance(for: backgroundHex)
        else { return 1 }

        let lighter = max(foreground, background)
        let darker = min(foreground, background)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func accentTokens(for accent: AppAccent) -> SemrehAccentTokens {
        switch accent {
        case .warm:
            SemrehAccentTokens(
                brandActionHex: "#D4B992",
                energyHex: "#D4B992",
                energyForegroundHex: "#30251D",
                actionLightHex: "#795334",
                actionDarkHex: "#D9B98C",
                brandAccentLightHex: "#795334",
                brandAccentDarkHex: "#D9B98C",
                accentForegroundLightHex: "#FFF9EF",
                accentForegroundDarkHex: "#30251D",
                promptBubbleBackgroundLightHex: "#E7D3B3",
                promptBubbleBackgroundDarkHex: "#D4B992",
                promptBubbleForegroundHex: "#30251D",
                promptBubbleBorderLightHex: "#C6AB83",
                promptBubbleBorderDarkHex: "#AC8C63"
            )
        case .violet:
            SemrehAccentTokens(
                brandActionHex: "#CBB6E6",
                energyHex: "#CBB6E6",
                energyForegroundHex: "#211629",
                actionLightHex: "#6B4AA1",
                actionDarkHex: "#C8A8FF",
                brandAccentLightHex: "#6B4AA1",
                brandAccentDarkHex: "#C8A8FF",
                accentForegroundLightHex: "#FFFFFF",
                accentForegroundDarkHex: "#251938",
                promptBubbleBackgroundLightHex: "#E8DDF6",
                promptBubbleBackgroundDarkHex: "#CBB6E6",
                promptBubbleForegroundHex: "#211629",
                promptBubbleBorderLightHex: "#A989CF",
                promptBubbleBorderDarkHex: "#9676BC"
            )
        case .blue:
            SemrehAccentTokens(
                brandActionHex: "#BFD8F7",
                energyHex: "#BFD8F7",
                energyForegroundHex: "#0D223C",
                actionLightHex: "#285B9E",
                actionDarkHex: "#8EBBFF",
                brandAccentLightHex: "#285B9E",
                brandAccentDarkHex: "#8EBBFF",
                accentForegroundLightHex: "#FFFFFF",
                accentForegroundDarkHex: "#102A4B",
                promptBubbleBackgroundLightHex: "#DCEBFB",
                promptBubbleBackgroundDarkHex: "#BFD8F7",
                promptBubbleForegroundHex: "#0D223C",
                promptBubbleBorderLightHex: "#8CB6E5",
                promptBubbleBorderDarkHex: "#6195D0"
            )
        case .mint:
            SemrehAccentTokens(
                brandActionHex: "#B7E6D3",
                energyHex: "#B7E6D3",
                energyForegroundHex: "#103328",
                actionLightHex: "#1D725F",
                actionDarkHex: "#77DCC2",
                brandAccentLightHex: "#1D725F",
                brandAccentDarkHex: "#77DCC2",
                accentForegroundLightHex: "#FFFFFF",
                accentForegroundDarkHex: "#12352B",
                promptBubbleBackgroundLightHex: "#D8F2E8",
                promptBubbleBackgroundDarkHex: "#B7E6D3",
                promptBubbleForegroundHex: "#103328",
                promptBubbleBorderLightHex: "#73C5AB",
                promptBubbleBorderDarkHex: "#4BA889"
            )
        case .rose:
            SemrehAccentTokens(
                brandActionHex: "#F0BCCD",
                energyHex: "#F0BCCD",
                energyForegroundHex: "#351A22",
                actionLightHex: "#9A3E5C",
                actionDarkHex: "#F1A0B8",
                brandAccentLightHex: "#9A3E5C",
                brandAccentDarkHex: "#F1A0B8",
                accentForegroundLightHex: "#FFFFFF",
                accentForegroundDarkHex: "#401523",
                promptBubbleBackgroundLightHex: "#F6DCE4",
                promptBubbleBackgroundDarkHex: "#F0BCCD",
                promptBubbleForegroundHex: "#351A22",
                promptBubbleBorderLightHex: "#D17C98",
                promptBubbleBorderDarkHex: "#C86B8A"
            )
        }
    }

    static func tokens(for palette: AppColorPalette) -> VisualThemeTokens {
        switch palette {
        case .goku:
            VisualThemeTokens(
                brandActionHex: gokuYellowHex,
                energyHex: gokuYellowHex,
                energyForegroundHex: gokuYellowForegroundHex,
                actionLightHex: gokuBlueHex,
                actionDarkHex: gokuBlueDarkHex,
                canvasLightHex: "#F4F7FC",
                canvasDarkHex: gokuDeepNavyHex,
                panelLightHex: "#FFFFFF",
                panelDarkHex: "#122C50",
                raisedLightHex: "#FBFDFF",
                raisedDarkHex: "#193A66",
                brandAccentLightHex: "#785800",
                brandAccentDarkHex: "#FFE08A",
                accentForegroundLightHex: "#FFFFFF",
                accentForegroundDarkHex: gokuDeepNavyHex,
                backdropMidLightHex: "#E8F0FF",
                backdropMidDarkHex: "#0E2546",
                gradientMidHex: "#3F76D6",
            )
        case .semreh:
            VisualThemeTokens(
                brandActionHex: "#D4B992",
                energyHex: "#D4B992",
                energyForegroundHex: "#30251D",
                actionLightHex: "#795334",
                actionDarkHex: "#D9B98C",
                canvasLightHex: "#F3E8D5",
                canvasDarkHex: "#211E1A",
                panelLightHex: "#FBF2E3",
                panelDarkHex: "#2C2721",
                raisedLightHex: "#EADCC5",
                raisedDarkHex: "#393127",
                brandAccentLightHex: "#795334",
                brandAccentDarkHex: "#D9B98C",
                accentForegroundLightHex: "#FFF9EF",
                accentForegroundDarkHex: "#30251D",
                backdropMidLightHex: "#F3E8D5",
                backdropMidDarkHex: "#211E1A",
                gradientMidHex: "#B68E60",
            )
        case .chatgpt:
            VisualThemeTokens(
                brandActionHex: "#10A37F",
                energyHex: "#10A37F",
                energyForegroundHex: "#06281F",
                actionLightHex: "#0B7A5E",
                actionDarkHex: "#4ADE80",
                canvasLightHex: "#F7F7F8",
                canvasDarkHex: "#212121",
                panelLightHex: "#FFFFFF",
                panelDarkHex: "#2F2F2F",
                raisedLightHex: "#F3F4F6",
                raisedDarkHex: "#3A3A3A",
                brandAccentLightHex: "#0B7A5E",
                brandAccentDarkHex: "#86EFAC",
                accentForegroundLightHex: "#FFFFFF",
                accentForegroundDarkHex: "#102018",
                backdropMidLightHex: "#EEF2F1",
                backdropMidDarkHex: "#191919",
                gradientMidHex: "#19C37D"
            )
        case .midnight:
            VisualThemeTokens(
                brandActionHex: "#5B6CFF",
                energyHex: "#8B7CFF",
                energyForegroundHex: "#16132A",
                actionLightHex: "#3D4FD8",
                actionDarkHex: "#A5B4FF",
                canvasLightHex: "#F3F5FF",
                canvasDarkHex: "#0B1020",
                panelLightHex: "#FFFFFF",
                panelDarkHex: "#161C33",
                raisedLightHex: "#F7F8FF",
                raisedDarkHex: "#1E2744",
                brandAccentLightHex: "#2F3DB0",
                brandAccentDarkHex: "#C4B5FD",
                accentForegroundLightHex: "#FFFFFF",
                accentForegroundDarkHex: "#12162A",
                backdropMidLightHex: "#E8ECFF",
                backdropMidDarkHex: "#10162B",
                gradientMidHex: "#7C8CFF"
            )
        case .forest:
            VisualThemeTokens(
                brandActionHex: "#2F8F57",
                energyHex: "#7BC67E",
                energyForegroundHex: "#102016",
                actionLightHex: "#1B6B43",
                actionDarkHex: "#6ED39A",
                canvasLightHex: "#F3F8F3",
                canvasDarkHex: "#0C1A12",
                panelLightHex: "#FFFFFF",
                panelDarkHex: "#163022",
                raisedLightHex: "#F8FBF7",
                raisedDarkHex: "#1C3B29",
                brandAccentLightHex: "#165736",
                brandAccentDarkHex: "#8EE0B0",
                accentForegroundLightHex: "#FFFFFF",
                accentForegroundDarkHex: "#0C1A12",
                backdropMidLightHex: "#E7F3E8",
                backdropMidDarkHex: "#102418",
                gradientMidHex: "#4FAE73"
            )
        case .sand:
            VisualThemeTokens(
                brandActionHex: "#C96442",
                energyHex: "#E0B07A",
                energyForegroundHex: "#2A1B10",
                actionLightHex: "#9A4328",
                actionDarkHex: "#E8A07A",
                canvasLightHex: "#FAF6F1",
                canvasDarkHex: "#1C1916",
                panelLightHex: "#FFFFFF",
                panelDarkHex: "#2A241F",
                raisedLightHex: "#FFFCF8",
                raisedDarkHex: "#352C25",
                brandAccentLightHex: "#8A3B22",
                brandAccentDarkHex: "#F0C7A8",
                accentForegroundLightHex: "#FFFFFF",
                accentForegroundDarkHex: "#2A1B10",
                backdropMidLightHex: "#F3EBE1",
                backdropMidDarkHex: "#241E1A",
                gradientMidHex: "#D08A5A"
            )
        }
    }

    private static func relativeLuminance(for rawHex: String) -> Double? {
        guard let hex = HeaderLogoColor.normalizedHex(rawHex),
              let value = UInt32(String(hex.dropFirst()), radix: 16)
        else { return nil }

        let components = [
            Double((value & 0xFF0000) >> 16) / 255,
            Double((value & 0x00FF00) >> 8) / 255,
            Double(value & 0x0000FF) / 255
        ].map { component in
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return (0.2126 * components[0]) + (0.7152 * components[1]) + (0.0722 * components[2])
    }
}

struct VisualThemeTokens: Equatable {
    let brandActionHex: String
    let energyHex: String
    let energyForegroundHex: String
    let actionLightHex: String
    let actionDarkHex: String
    let canvasLightHex: String
    let canvasDarkHex: String
    let panelLightHex: String
    let panelDarkHex: String
    let raisedLightHex: String
    let raisedDarkHex: String
    let brandAccentLightHex: String
    let brandAccentDarkHex: String
    let accentForegroundLightHex: String
    let accentForegroundDarkHex: String
    let backdropMidLightHex: String
    let backdropMidDarkHex: String
    let gradientMidHex: String

    func canvasHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? canvasDarkHex : canvasLightHex
    }

    func panelHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? panelDarkHex : panelLightHex
    }

    func raisedHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? raisedDarkHex : raisedLightHex
    }

    func actionHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? actionDarkHex : actionLightHex
    }

    func brandAccentHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? brandAccentDarkHex : brandAccentLightHex
    }

    func accentForegroundHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? accentForegroundDarkHex : accentForegroundLightHex
    }
}

struct SemrehAccentTokens: Equatable {
    let brandActionHex: String
    let energyHex: String
    let energyForegroundHex: String
    let actionLightHex: String
    let actionDarkHex: String
    let brandAccentLightHex: String
    let brandAccentDarkHex: String
    let accentForegroundLightHex: String
    let accentForegroundDarkHex: String
    let promptBubbleBackgroundLightHex: String
    let promptBubbleBackgroundDarkHex: String
    let promptBubbleForegroundHex: String
    let promptBubbleBorderLightHex: String
    let promptBubbleBorderDarkHex: String

    func actionHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? actionDarkHex : actionLightHex
    }

    func brandAccentHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? brandAccentDarkHex : brandAccentLightHex
    }

    func accentForegroundHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? accentForegroundDarkHex : accentForegroundLightHex
    }

    func promptBubbleBackgroundHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? promptBubbleBackgroundDarkHex : promptBubbleBackgroundLightHex
    }

    func promptBubbleBorderHex(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? promptBubbleBorderDarkHex : promptBubbleBorderLightHex
    }
}

struct SemrehBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        let tokens = SemrehVisualTheme.tokens(for: palette)
        ZStack {
            SemrehVisualTheme.canvas(for: colorScheme, palette: palette)

            // The warm default is a quiet, flat reading surface. Keep the older
            // decorative backgrounds only for explicitly selected legacy themes.
            if !reduceTransparency && palette != .semreh {
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [
                            SemrehVisualTheme.canvas(for: .dark, palette: palette),
                            Color(hexRGB: tokens.backdropMidDarkHex)!,
                            SemrehVisualTheme.canvas(for: .dark, palette: palette)
                        ]
                        : [
                            SemrehVisualTheme.canvas(for: .light, palette: palette),
                            Color(hexRGB: tokens.backdropMidLightHex)!,
                            Color(hexRGB: tokens.raisedLightHex)!
                        ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [
                        SemrehVisualTheme.brandActionColor(for: palette)
                            .opacity(colorScheme == .dark ? 0.16 : 0.10),
                        .clear
                    ],
                    center: .topTrailing,
                    startRadius: 4,
                    endRadius: 360
                )

                RadialGradient(
                    colors: [
                        SemrehVisualTheme.action(for: colorScheme, palette: palette)
                            .opacity(colorScheme == .dark ? 0.18 : 0.08),
                        .clear
                    ],
                    center: .bottomLeading,
                    startRadius: 8,
                    endRadius: 420
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SemrehAppThemeModifier: ViewModifier {
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue
    @AppStorage(AppAccent.storageKey) private var appAccentRawValue = AppAccent.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var palette: AppColorPalette {
        AppTheme.storedValue(appThemeRawValue).palette
    }

    private var accent: AppAccent {
        AppAccent.storedValue(appAccentRawValue)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.appColorPalette, palette)
            .environment(\.appAccent, accent)
            .tint(SemrehVisualTheme.action(for: colorScheme, palette: palette, accent: accent))
            .background { SemrehBackdrop().ignoresSafeArea() }
            .toolbarBackground(
                SemrehVisualTheme.navigationBarBackground(
                    for: colorScheme,
                    reduceTransparency: reduceTransparency,
                    palette: palette
                ),
                for: .navigationBar
            )
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct SemrehPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.appColorPalette) private var palette
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(
                    reduceTransparency
                        ? SemrehVisualTheme.panel(for: colorScheme, palette: palette)
                        : SemrehVisualTheme.panel(for: colorScheme, palette: palette)
                            .opacity(colorScheme == .dark ? 0.78 : 0.82)
                )
            }
            .overlay {
                shape
                    .stroke(
                        SemrehVisualTheme.subtleStroke(
                            for: colorScheme,
                            increasedContrast: colorSchemeContrast == .increased,
                            palette: palette
                        ),
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.8
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: palette == .semreh ? .black.opacity(colorScheme == .dark ? 0 : 0.035) : colorScheme == .dark
                    ? SemrehVisualTheme.action(for: .dark, palette: palette).opacity(0.10)
                    : SemrehVisualTheme.brandActionColor(for: palette).opacity(0.07),
                radius: palette == .semreh ? 6 : 16,
                y: palette == .semreh ? 2 : 7
            )
    }
}

extension View {
    func semrehAppTheme() -> some View {
        modifier(SemrehAppThemeModifier())
    }

    func semrehPanel(cornerRadius: CGFloat = 18) -> some View {
        modifier(SemrehPanelModifier(cornerRadius: cornerRadius))
    }
}
