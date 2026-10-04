import SwiftUI

private struct UsesMuseChatSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MuseSurfaceUsesDefaultAccentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set only by the preview shell; ordinary chat keeps its existing appearance.
    var usesMuseChatSurface: Bool {
        get { self[UsesMuseChatSurfaceKey.self] }
        set { self[UsesMuseChatSurfaceKey.self] = newValue }
    }

    /// The shell captures whether an accent preference exists. Leaves never read defaults.
    var museSurfaceUsesDefaultAccent: Bool {
        get { self[MuseSurfaceUsesDefaultAccentKey.self] }
        set { self[MuseSurfaceUsesDefaultAccentKey.self] = newValue }
    }
}

/// Local chat-surface roles. No persisted preferences or app-wide defaults change.
enum ChatSurfaceAppearance {
    enum Role: CaseIterable {
        case canvas, panel, subtleStroke, controlFill
        case actionBackground, actionForeground
        case promptBackground, promptForeground, promptBorder
    }

    static func usesReferenceStyle(
        palette: AppColorPalette, accent: AppAccent, useDefaultAccent: Bool
    ) -> Bool {
        palette == .semreh && accent == AppAccent.defaultValue && useDefaultAccent
    }

    /// A slightly deeper saturated blue keeps normal-size white message text above 4.5:1.
    static func defaultHex(for role: Role, colorScheme: ColorScheme) -> String {
        switch role {
        case .canvas: colorScheme == .dark ? "#0A0A0A" : "#FFFFFF"
        case .panel: colorScheme == .dark ? "#1C1C1E" : "#F2F2F7"
        case .subtleStroke: colorScheme == .dark ? "#343438" : "#D8D8DF"
        case .controlFill: colorScheme == .dark ? "#242426" : "#EAEAEE"
        case .actionBackground, .promptBackground, .promptBorder: "#006FE8"
        case .actionForeground, .promptForeground: "#FFFFFF"
        }
    }

    static func color(
        _ role: Role, for colorScheme: ColorScheme,
        palette: AppColorPalette, accent: AppAccent, useDefaultAccent: Bool
    ) -> Color {
        guard usesReferenceStyle(palette: palette, accent: accent, useDefaultAccent: useDefaultAccent) else {
            switch role {
            case .canvas: return SemrehVisualTheme.canvas(for: colorScheme, palette: palette)
            case .panel: return SemrehVisualTheme.panel(for: colorScheme, palette: palette)
            case .subtleStroke: return SemrehVisualTheme.subtleStroke(for: colorScheme, palette: palette)
            case .controlFill: return SemrehVisualTheme.raisedPanel(for: colorScheme, palette: palette)
            case .actionBackground: return SemrehVisualTheme.action(for: colorScheme, palette: palette, accent: accent)
            case .actionForeground: return SemrehVisualTheme.accentForeground(for: colorScheme, palette: palette, accent: accent)
            case .promptBackground: return SemrehVisualTheme.promptBubbleBackground(for: colorScheme, palette: palette, accent: accent)
            case .promptForeground: return SemrehVisualTheme.promptBubbleForeground(for: palette, colorScheme: colorScheme, accent: accent)
            case .promptBorder: return SemrehVisualTheme.promptBubbleBorder(for: colorScheme, palette: palette, accent: accent)
            }
        }
        return Color(hexRGB: defaultHex(for: role, colorScheme: colorScheme))!
    }

    static func canvas(
        for colorScheme: ColorScheme, palette: AppColorPalette,
        accent: AppAccent, useDefaultAccent: Bool
    ) -> Color {
        color(.canvas, for: colorScheme, palette: palette, accent: accent, useDefaultAccent: useDefaultAccent)
    }

    static func panel(
        for colorScheme: ColorScheme, palette: AppColorPalette,
        accent: AppAccent, useDefaultAccent: Bool
    ) -> Color {
        color(.panel, for: colorScheme, palette: palette, accent: accent, useDefaultAccent: useDefaultAccent)
    }

    static func subtleStroke(
        for colorScheme: ColorScheme, palette: AppColorPalette,
        accent: AppAccent, useDefaultAccent: Bool
    ) -> Color {
        color(.subtleStroke, for: colorScheme, palette: palette, accent: accent, useDefaultAccent: useDefaultAccent)
    }

    static func controlFill(
        for colorScheme: ColorScheme, palette: AppColorPalette,
        accent: AppAccent, useDefaultAccent: Bool
    ) -> Color {
        color(.controlFill, for: colorScheme, palette: palette, accent: accent, useDefaultAccent: useDefaultAccent)
    }

    static func actionBackground(
        for colorScheme: ColorScheme, palette: AppColorPalette,
        accent: AppAccent, useDefaultAccent: Bool
    ) -> Color {
        color(.actionBackground, for: colorScheme, palette: palette, accent: accent, useDefaultAccent: useDefaultAccent)
    }

    static func actionForeground(
        for colorScheme: ColorScheme, palette: AppColorPalette,
        accent: AppAccent, useDefaultAccent: Bool
    ) -> Color {
        color(.actionForeground, for: colorScheme, palette: palette, accent: accent, useDefaultAccent: useDefaultAccent)
    }

    static func promptBackground(
        for colorScheme: ColorScheme, palette: AppColorPalette,
        accent: AppAccent, useDefaultAccent: Bool
    ) -> Color {
        color(.promptBackground, for: colorScheme, palette: palette, accent: accent, useDefaultAccent: useDefaultAccent)
    }

    static func promptForeground(
        for colorScheme: ColorScheme, palette: AppColorPalette,
        accent: AppAccent, useDefaultAccent: Bool
    ) -> Color {
        color(.promptForeground, for: colorScheme, palette: palette, accent: accent, useDefaultAccent: useDefaultAccent)
    }

    static func promptBorder(
        for colorScheme: ColorScheme, palette: AppColorPalette,
        accent: AppAccent, useDefaultAccent: Bool
    ) -> Color {
        color(.promptBorder, for: colorScheme, palette: palette, accent: accent, useDefaultAccent: useDefaultAccent)
    }
}
