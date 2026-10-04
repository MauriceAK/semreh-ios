import SwiftUI
import XCTest
@testable import HermesMobile

final class ChatSurfaceAppearanceTests: XCTestCase {
    func testSurfaceOptInsAreOffWithoutShellContext() {
        let environment = EnvironmentValues()
        XCTAssertFalse(environment.usesMuseChatSurface)
        XCTAssertFalse(environment.museSurfaceUsesDefaultAccent)
    }

    func testReferenceColorsRequireUncustomizedSemrehAppearance() {
        XCTAssertTrue(ChatSurfaceAppearance.usesReferenceStyle(
            palette: .semreh, accent: AppAccent.defaultValue, useDefaultAccent: true))
        XCTAssertFalse(ChatSurfaceAppearance.usesReferenceStyle(
            palette: .semreh, accent: AppAccent.defaultValue, useDefaultAccent: false),
            "An explicitly chosen default accent remains an explicit preference.")
        for accent in AppAccent.allCases where accent != AppAccent.defaultValue {
            XCTAssertFalse(ChatSurfaceAppearance.usesReferenceStyle(
                palette: .semreh, accent: accent, useDefaultAccent: true))
        }
        for palette in AppColorPalette.allCases where palette != .semreh {
            XCTAssertFalse(ChatSurfaceAppearance.usesReferenceStyle(
                palette: palette, accent: AppAccent.defaultValue, useDefaultAccent: true))
        }
    }

    func testExplicitPreferencesPreserveExistingPromptAndActionPairs() {
        for scheme in [ColorScheme.light, .dark] {
            for palette in AppColorPalette.allCases {
                for accent in AppAccent.allCases {
                    XCTAssertEqual(
                        ChatSurfaceAppearance.promptBackground(for: scheme, palette: palette,
                            accent: accent, useDefaultAccent: false),
                        SemrehVisualTheme.promptBubbleBackground(for: scheme, palette: palette, accent: accent))
                    XCTAssertEqual(
                        ChatSurfaceAppearance.promptForeground(for: scheme, palette: palette,
                            accent: accent, useDefaultAccent: false),
                        SemrehVisualTheme.promptBubbleForeground(for: palette, colorScheme: scheme, accent: accent))
                    XCTAssertEqual(
                        ChatSurfaceAppearance.actionBackground(for: scheme, palette: palette,
                            accent: accent, useDefaultAccent: false),
                        SemrehVisualTheme.action(for: scheme, palette: palette, accent: accent))
                    XCTAssertEqual(
                        ChatSurfaceAppearance.canvas(for: scheme, palette: palette,
                            accent: accent, useDefaultAccent: false),
                        SemrehVisualTheme.canvas(for: scheme, palette: palette))
                }
            }
        }
    }

    func testDefaultMessageAndActionTextMeetsNormalTextContrastInBothSchemes() {
        for scheme in [ColorScheme.light, .dark] {
            let pairs: [(ChatSurfaceAppearance.Role, ChatSurfaceAppearance.Role)] = [
                (.promptForeground, .promptBackground), (.actionForeground, .actionBackground)
            ]
            for (foreground, background) in pairs {
                XCTAssertGreaterThanOrEqual(SemrehVisualTheme.contrastRatio(
                    foregroundHex: ChatSurfaceAppearance.defaultHex(for: foreground, colorScheme: scheme),
                    backgroundHex: ChatSurfaceAppearance.defaultHex(for: background, colorScheme: scheme)), 4.5)
            }
            for background in [ChatSurfaceAppearance.Role.canvas, .panel, .controlFill] {
                XCTAssertGreaterThanOrEqual(SemrehVisualTheme.contrastRatio(
                    foregroundHex: SemrehVisualTheme.primaryTextHex(for: scheme),
                    backgroundHex: ChatSurfaceAppearance.defaultHex(for: background, colorScheme: scheme)), 4.5)
            }
        }
        XCTAssertNotEqual(ChatSurfaceAppearance.defaultHex(for: .canvas, colorScheme: .light),
                          ChatSurfaceAppearance.defaultHex(for: .canvas, colorScheme: .dark))
        XCTAssertNotEqual(ChatSurfaceAppearance.defaultHex(for: .panel, colorScheme: .light),
                          ChatSurfaceAppearance.defaultHex(for: .panel, colorScheme: .dark))
    }
}
