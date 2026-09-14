import SwiftUI
import XCTest
import UserNotifications
@testable import HermesMobile

final class AppThemeTests: XCTestCase {
    func testStoredValueFallsBackToSystemForUnknownRawValue() {
        XCTAssertEqual(AppTheme.storedValue("unexpected"), .system)
    }

    func testThemeMapsToExpectedColorScheme() {
        XCTAssertNil(AppTheme.system.colorScheme)
        XCTAssertEqual(AppTheme.semrehLight.colorScheme, .light)
        XCTAssertEqual(AppTheme.semrehDark.colorScheme, .dark)
        XCTAssertEqual(AppTheme.light.colorScheme, .light)
        XCTAssertEqual(AppTheme.dark.colorScheme, .dark)
        XCTAssertNil(AppTheme.chatgpt.colorScheme)
        XCTAssertNil(AppTheme.midnight.colorScheme)
        XCTAssertNil(AppTheme.forest.colorScheme)
        XCTAssertNil(AppTheme.sand.colorScheme)
    }

    func testThemeDropdownKeepsSemrehDefaultsAndAddsNamedPalettes() {
        XCTAssertEqual(AppTheme.allCases.map(\.rawValue), [
            "system", "semrehLight", "semrehDark", "light", "dark", "chatgpt", "midnight", "forest", "sand"
        ])
        XCTAssertEqual(AppTheme.system.title, "Semreh")
        XCTAssertEqual(AppTheme.semrehLight.title, "Light")
        XCTAssertEqual(AppTheme.semrehDark.title, "Dark")
        XCTAssertEqual(AppTheme.light.title, "Goku Light")
        XCTAssertEqual(AppTheme.dark.title, "Goku Dark")
        XCTAssertEqual(AppTheme.chatgpt.title, "ChatGPT")
        XCTAssertEqual(AppTheme.midnight.title, "Midnight")
        XCTAssertEqual(AppTheme.forest.title, "Forest")
        XCTAssertEqual(AppTheme.sand.title, "Sand")
        XCTAssertEqual(AppTheme.system.palette, .semreh)
        XCTAssertEqual(AppTheme.semrehLight.palette, .semreh)
        XCTAssertEqual(AppTheme.semrehDark.palette, .semreh)
        XCTAssertEqual(AppTheme.light.palette, .goku)
        XCTAssertEqual(AppTheme.dark.palette, .goku)
        XCTAssertEqual(AppTheme.chatgpt.palette, .chatgpt)
        XCTAssertEqual(AppTheme.midnight.palette, .midnight)
        XCTAssertEqual(AppTheme.forest.palette, .forest)
        XCTAssertEqual(AppTheme.sand.palette, .sand)
        XCTAssertEqual(AppTheme.storedValue("chatgpt"), .chatgpt)
        XCTAssertEqual(AppTheme.storedValue("light"), .light)
        XCTAssertEqual(AppTheme.storedValue("dark"), .dark)
        XCTAssertEqual(AppTheme.storedValue("semrehLight"), .semrehLight)
        XCTAssertEqual(AppTheme.storedValue("semrehDark"), .semrehDark)
    }

    func testModernSemrehModesDoNotRewriteLegacyGokuRawValues() {
        XCTAssertNotEqual(AppTheme.semrehLight.rawValue, AppTheme.light.rawValue)
        XCTAssertNotEqual(AppTheme.semrehDark.rawValue, AppTheme.dark.rawValue)
        XCTAssertEqual(AppTheme.storedValue(AppTheme.light.rawValue).palette, .goku)
        XCTAssertEqual(AppTheme.storedValue(AppTheme.dark.rawValue).palette, .goku)
        XCTAssertEqual(AppTheme.storedValue(AppTheme.semrehLight.rawValue).palette, .semreh)
        XCTAssertEqual(AppTheme.storedValue(AppTheme.semrehDark.rawValue).palette, .semreh)
    }

    func testNamedPalettesKeepReadableBrandedPairs() {
        let palettes: [AppColorPalette] = [.chatgpt, .midnight, .forest, .sand]
        for palette in palettes {
            for scheme in [ColorScheme.light, .dark] {
                XCTAssertGreaterThanOrEqual(
                    SemrehVisualTheme.contrastRatio(
                        foregroundHex: SemrehVisualTheme.actionHex(for: scheme, palette: palette),
                        backgroundHex: SemrehVisualTheme.panelHex(for: scheme, palette: palette)
                    ),
                    4.5,
                    "action/panel failed for \(palette) \(scheme)"
                )
                XCTAssertGreaterThanOrEqual(
                    SemrehVisualTheme.contrastRatio(
                        foregroundHex: SemrehVisualTheme.accentForegroundHex(for: scheme, palette: palette),
                        backgroundHex: SemrehVisualTheme.actionHex(for: scheme, palette: palette)
                    ),
                    4.5,
                    "accent/action failed for \(palette) \(scheme)"
                )
                XCTAssertGreaterThanOrEqual(
                    SemrehVisualTheme.contrastRatio(
                        foregroundHex: SemrehVisualTheme.brandAccentHex(for: scheme, palette: palette),
                        backgroundHex: SemrehVisualTheme.canvasHex(for: scheme, palette: palette)
                    ),
                    4.5,
                    "brand/canvas failed for \(palette) \(scheme)"
                )
                XCTAssertGreaterThanOrEqual(
                    SemrehVisualTheme.contrastRatio(
                        foregroundHex: SemrehVisualTheme.energyForegroundHex(for: palette),
                        backgroundHex: SemrehVisualTheme.energyHex(for: palette)
                    ),
                    4.5,
                    "energy failed for \(palette)"
                )
            }
        }
    }

    func testChatGPTPaletteUsesNeutralSurfacesAndSageAccent() {
        XCTAssertEqual(SemrehVisualTheme.canvasHex(for: .light, palette: .chatgpt), "#F7F7F8")
        XCTAssertEqual(SemrehVisualTheme.canvasHex(for: .dark, palette: .chatgpt), "#212121")
        XCTAssertEqual(SemrehVisualTheme.actionHex(for: .light, palette: .chatgpt), "#0B7A5E")
        XCTAssertEqual(SemrehVisualTheme.actionHex(for: .dark, palette: .chatgpt), "#4ADE80")
        XCTAssertNotEqual(
            SemrehVisualTheme.canvasHex(for: .light, palette: .chatgpt),
            SemrehVisualTheme.canvasHex(for: .light, palette: .semreh)
        )
    }

    func testSemrehVisualThemeUsesCanonicalLogoPalette() {
        XCTAssertEqual(SemrehVisualTheme.logoNavyHex, "#032357")
        XCTAssertEqual(SemrehVisualTheme.logoTealHex, "#12C7B5")
        XCTAssertEqual(SemrehVisualTheme.logoAquaHex, "#31D8CA")
        XCTAssertEqual(SemrehVisualTheme.deepNavyHex, SemrehVisualTheme.logoNavyHex)
        XCTAssertEqual(SemrehVisualTheme.brandAction, SemrehVisualTheme.logoTeal)
        XCTAssertEqual(SemrehVisualTheme.energy, SemrehVisualTheme.logoTeal)
        XCTAssertEqual(SemrehVisualTheme.promptBubbleBackgroundHex(for: .dark), "#D4B992")
        XCTAssertEqual(SemrehVisualTheme.promptBubbleForegroundHex(), "#30251D")
    }

    func testGokuPaletteRetainsLegacyVisualTokens() {
        XCTAssertEqual(SemrehVisualTheme.tokens(for: .goku).brandActionHex, "#FFD447")
        XCTAssertEqual(SemrehVisualTheme.tokens(for: .goku).energyHex, "#FFD447")
        XCTAssertEqual(SemrehVisualTheme.tokens(for: .goku).canvasDarkHex, "#0B1B34")
        XCTAssertEqual(SemrehVisualTheme.promptBubbleBackgroundHex(for: .light, palette: .goku), "#39E89A")
        XCTAssertEqual(SemrehVisualTheme.promptBubbleForegroundHex(for: .goku), "#0B1B34")
    }

    func testPromptBubblesUseReadableThemeSpecificAccentPairs() {
        for palette in [AppColorPalette.goku, .semreh] {
            for scheme in [ColorScheme.light, .dark] {
                XCTAssertGreaterThanOrEqual(
                    SemrehVisualTheme.contrastRatio(
                        foregroundHex: SemrehVisualTheme.promptBubbleForegroundHex(for: palette),
                        backgroundHex: SemrehVisualTheme.promptBubbleBackgroundHex(for: scheme, palette: palette)
                    ),
                    4.5,
                    "prompt bubble failed for \(palette) \(scheme)"
                )
            }
        }
    }

    func testSemrehDarkCanvasStaysSeparateFromLogoNavy() {
        XCTAssertEqual(SemrehVisualTheme.canvasHex(for: .dark), "#211E1A")
        XCTAssertNotEqual(SemrehVisualTheme.canvasHex(for: .dark), SemrehVisualTheme.logoNavyHex)
    }
    func testSemrehVisualThemeActionAdaptsForDarkModeContrast() {
        XCTAssertEqual(SemrehVisualTheme.actionHex(for: .light), "#795334")
        XCTAssertEqual(SemrehVisualTheme.actionHex(for: .dark), "#D9B98C")

        for scheme in [ColorScheme.light, .dark] {
            XCTAssertGreaterThanOrEqual(
                SemrehVisualTheme.contrastRatio(
                    foregroundHex: SemrehVisualTheme.actionHex(for: scheme),
                    backgroundHex: SemrehVisualTheme.panelHex(for: scheme)
                ),
                4.5
            )
        }
    }

    func testSemrehVisualThemeUsesReadableAccentForegrounds() {
        XCTAssertEqual(SemrehVisualTheme.accentForegroundHex(for: .light), "#FFF9EF")
        XCTAssertEqual(SemrehVisualTheme.accentForegroundHex(for: .dark), "#30251D")

        for scheme in [ColorScheme.light, .dark] {
            XCTAssertGreaterThanOrEqual(
                SemrehVisualTheme.contrastRatio(
                    foregroundHex: SemrehVisualTheme.accentForegroundHex(for: scheme),
                    backgroundHex: SemrehVisualTheme.actionHex(for: scheme)
                ),
                4.5
            )
        }
    }

    func testSemrehVisualThemeAccessibilitySurfaceTreatments() {
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertGreaterThan(
                SemrehVisualTheme.panelStrokeOpacity(for: scheme, increasedContrast: true),
                SemrehVisualTheme.panelStrokeOpacity(for: scheme, increasedContrast: false)
            )
            XCTAssertEqual(
                SemrehVisualTheme.navigationBarOpacity(for: scheme, reduceTransparency: true),
                1
            )
            XCTAssertLessThan(
                SemrehVisualTheme.navigationBarOpacity(for: scheme, reduceTransparency: false),
                1
            )
        }
    }

    func testSemrehVisualThemeChromeSurfacesBecomeOpaqueWithReduceTransparency() {
        XCTAssertEqual(SemrehVisualTheme.chromeSurfaceOpacity(reduceTransparency: true), 1)
        XCTAssertLessThan(SemrehVisualTheme.chromeSurfaceOpacity(reduceTransparency: false), 1)
    }

    func testSemrehVisualThemeUsesReadablePrimaryActionForeground() {
        XCTAssertEqual(SemrehVisualTheme.primaryActionForegroundHex, SemrehVisualTheme.logoNavyHex)
        XCTAssertGreaterThan(
            SemrehVisualTheme.contrastRatio(
                foregroundHex: SemrehVisualTheme.primaryActionForegroundHex,
                backgroundHex: SemrehVisualTheme.logoTealHex
            ),
            4.5
        )
    }

    func testSemrehVisualThemeCanvasAdaptsToColorScheme() {
        XCTAssertEqual(SemrehVisualTheme.canvasHex(for: .light), "#F3E8D5")
        XCTAssertEqual(SemrehVisualTheme.canvasHex(for: .dark), "#211E1A")
        XCTAssertEqual(SemrehVisualTheme.panelHex(for: .light), "#FBF2E3")
        XCTAssertEqual(SemrehVisualTheme.panelHex(for: .dark), "#2C2721")
    }

    func testAdaptiveBrandAccentMeetsTextContrastInBothAppearances() {
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertGreaterThanOrEqual(
                SemrehVisualTheme.contrastRatio(
                    foregroundHex: SemrehVisualTheme.brandAccentHex(for: scheme),
                    backgroundHex: SemrehVisualTheme.canvasHex(for: scheme)
                ),
                4.5
            )
        }
    }

    func testHeaderLogoColorNormalizesStoredHexValues() {
        XCTAssertEqual(HeaderLogoColor.normalizedHex("#5b7cff"), "#5B7CFF")
        XCTAssertEqual(HeaderLogoColor.normalizedHex(" ff3b30 "), "#FF3B30")
        XCTAssertNil(HeaderLogoColor.normalizedHex("#123"))
        XCTAssertNil(HeaderLogoColor.normalizedHex("#GG0000"))
    }

    func testHeaderLogoColorDisplayNameUsesPresetOrCustomFallback() {
        XCTAssertEqual(HeaderLogoColor.displayName(for: "#FFD700"), "Yellow")
        XCTAssertEqual(HeaderLogoColor.displayName(for: "#123456"), "Custom")
        XCTAssertEqual(HeaderLogoColor.displayName(for: "not-a-color"), "Teal")
    }

    func testHeaderLogoColorFormatsRGBComponentsAsHex() {
        XCTAssertEqual(HeaderLogoColor.hexString(red: 1, green: 0, blue: 0.5), "#FF0080")
        XCTAssertEqual(HeaderLogoColor.hexString(red: -0.2, green: 1.2, blue: 0), "#00FF00")
    }

    func testRTLLayoutHorizontalOffsetMirrorsUnderRightToLeft() {
        XCTAssertEqual(RTLLayout.horizontalOffset(6, isRightToLeft: false), 6)
        XCTAssertEqual(RTLLayout.horizontalOffset(6, isRightToLeft: true), -6)
        XCTAssertEqual(RTLLayout.horizontalOffset(-4, isRightToLeft: true), 4)
        XCTAssertEqual(RTLLayout.horizontalOffset(0, isRightToLeft: true), 0)
    }

    func testRTLDisclosureChevronRotationReversesUnderRightToLeft() {
        // Collapsed: no rotation regardless of direction.
        XCTAssertEqual(RTLLayout.disclosureChevronRotationDegrees(isExpanded: false, isRightToLeft: false), 0)
        XCTAssertEqual(RTLLayout.disclosureChevronRotationDegrees(isExpanded: false, isRightToLeft: true), 0)
        // Expanded: clockwise in LTR, counter-clockwise in RTL so it still points down.
        XCTAssertEqual(RTLLayout.disclosureChevronRotationDegrees(isExpanded: true, isRightToLeft: false), 90)
        XCTAssertEqual(RTLLayout.disclosureChevronRotationDegrees(isExpanded: true, isRightToLeft: true), -90)
    }

    func testHeaderLogoColorChoosesReadableForeground() {
        XCTAssertTrue(HeaderLogoColor.prefersDarkForeground(for: "#FFD700"))
        XCTAssertTrue(HeaderLogoColor.prefersDarkForeground(for: "#FFFFFF"))
        XCTAssertFalse(HeaderLogoColor.prefersDarkForeground(for: "#5B7CFF"))
        XCTAssertFalse(HeaderLogoColor.prefersDarkForeground(for: "#AF52DE"))
    }

    func testSessionIdentityInitialsPreferStoredValueThenDisplayName() {
        XCTAssertEqual(
            SessionIdentitySettings.displayInitials(
                displayName: "Ada Lovelace",
                storedInitials: " hm ",
                fallbackFullName: "Fallback Person"
            ),
            "HM"
        )
        XCTAssertEqual(
            SessionIdentitySettings.displayInitials(
                displayName: "Ada Lovelace",
                storedInitials: "",
                fallbackFullName: "Fallback Person"
            ),
            "AL"
        )
        XCTAssertEqual(
            SessionIdentitySettings.displayInitials(
                displayName: "",
                storedInitials: "",
                fallbackFullName: ""
            ),
            "UZ"
        )
    }

    func testSessionIdentityInitialsNormalizeUserInput() {
        XCTAssertEqual(SessionIdentitySettings.normalizedInitials(" u-z!9 "), "UZ9")
        XCTAssertEqual(SessionIdentitySettings.normalizedInitials("abcd"), "ABC")
    }
}

final class AppAccentTests: XCTestCase {
    func testPresetOrderAndStorageContractAreStable() {
        XCTAssertEqual(AppAccent.allCases.map(\.rawValue), ["warm", "violet", "blue", "mint", "rose"])
        XCTAssertEqual(AppAccent.storageKey, "appearance.appAccent")
        XCTAssertEqual(AppAccent.defaultValue, .warm)
        XCTAssertEqual(AppAccent.allCases.map(\.title), ["Warm", "Violet", "Blue", "Mint", "Rose"])
    }

    func testStoredAccentFallsBackToWarmForUnknownValues() {
        XCTAssertEqual(AppAccent.storedValue(AppAccent.violet.rawValue), .violet)
        XCTAssertEqual(AppAccent.storedValue("old-accent"), .warm)
        XCTAssertEqual(AppAccent.storedValue(""), .warm)
    }

    func testWarmAccentPreservesTheExistingSemrehAppearance() {
        XCTAssertEqual(SemrehVisualTheme.actionHex(for: .light, accent: .warm), "#795334")
        XCTAssertEqual(SemrehVisualTheme.actionHex(for: .dark, accent: .warm), "#D9B98C")
        XCTAssertEqual(SemrehVisualTheme.promptBubbleBackgroundHex(for: .light, accent: .warm), "#E7D3B3")
        XCTAssertEqual(SemrehVisualTheme.promptBubbleBackgroundHex(for: .dark, accent: .warm), "#D4B992")
        XCTAssertEqual(SemrehVisualTheme.promptBubbleForegroundHex(for: .semreh, accent: .warm), "#30251D")
    }

    func testNamedAccentsProduceDistinctSemrehActionsAndBubbles() {
        let lightActions = Set(AppAccent.allCases.map {
            SemrehVisualTheme.actionHex(for: .light, accent: $0)
        })
        let darkActions = Set(AppAccent.allCases.map {
            SemrehVisualTheme.actionHex(for: .dark, accent: $0)
        })
        let lightBubbles = Set(AppAccent.allCases.map {
            SemrehVisualTheme.promptBubbleBackgroundHex(for: .light, accent: $0)
        })
        let darkBubbles = Set(AppAccent.allCases.map {
            SemrehVisualTheme.promptBubbleBackgroundHex(for: .dark, accent: $0)
        })

        XCTAssertEqual(lightActions.count, AppAccent.allCases.count)
        XCTAssertEqual(darkActions.count, AppAccent.allCases.count)
        XCTAssertEqual(lightBubbles.count, AppAccent.allCases.count)
        XCTAssertEqual(darkBubbles.count, AppAccent.allCases.count)
    }

    func testEachSemrehAccentHasReadableLightAndDarkActionPairs() {
        for accent in AppAccent.allCases {
            for scheme in [ColorScheme.light, .dark] {
                XCTAssertGreaterThanOrEqual(
                    SemrehVisualTheme.contrastRatio(
                        foregroundHex: SemrehVisualTheme.actionHex(for: scheme, accent: accent),
                        backgroundHex: SemrehVisualTheme.panelHex(for: scheme)
                    ),
                    4.5,
                    "action/panel failed for \(accent) \(scheme)"
                )
                XCTAssertGreaterThanOrEqual(
                    SemrehVisualTheme.contrastRatio(
                        foregroundHex: SemrehVisualTheme.accentForegroundHex(for: scheme, accent: accent),
                        backgroundHex: SemrehVisualTheme.actionHex(for: scheme, accent: accent)
                    ),
                    4.5,
                    "foreground/action failed for \(accent) \(scheme)"
                )
                XCTAssertGreaterThanOrEqual(
                    SemrehVisualTheme.contrastRatio(
                        foregroundHex: SemrehVisualTheme.brandAccentHex(for: scheme, accent: accent),
                        backgroundHex: SemrehVisualTheme.canvasHex(for: scheme)
                    ),
                    4.5,
                    "brand/canvas failed for \(accent) \(scheme)"
                )
            }
        }
    }

    func testEachSemrehAccentHasReadableUserBubblePairs() {
        for accent in AppAccent.allCases {
            let foreground = SemrehVisualTheme.promptBubbleForegroundHex(for: .semreh, accent: accent)
            for scheme in [ColorScheme.light, .dark] {
                XCTAssertGreaterThanOrEqual(
                    SemrehVisualTheme.contrastRatio(
                        foregroundHex: foreground,
                        backgroundHex: SemrehVisualTheme.promptBubbleBackgroundHex(
                            for: scheme,
                            palette: .semreh,
                            accent: accent
                        )
                    ),
                    4.5,
                    "bubble failed for \(accent) \(scheme)"
                )
            }
        }
    }

    func testEachSemrehAccentHasReadableEnergyPairs() {
        for accent in AppAccent.allCases {
            XCTAssertGreaterThanOrEqual(
                SemrehVisualTheme.contrastRatio(
                    foregroundHex: SemrehVisualTheme.energyForegroundHex(for: .semreh, accent: accent),
                    backgroundHex: SemrehVisualTheme.energyHex(for: .semreh, accent: accent)
                ),
                4.5,
                "energy failed for \(accent)"
            )
        }
    }

    func testAccentDoesNotRewriteLegacyPalettes() {
        for palette in [AppColorPalette.goku, .chatgpt, .midnight, .forest, .sand] {
            for scheme in [ColorScheme.light, .dark] {
                XCTAssertEqual(
                    SemrehVisualTheme.actionHex(for: scheme, palette: palette, accent: .rose),
                    SemrehVisualTheme.actionHex(for: scheme, palette: palette, accent: .warm)
                )
                XCTAssertEqual(
                    SemrehVisualTheme.promptBubbleBackgroundHex(for: scheme, palette: palette, accent: .violet),
                    SemrehVisualTheme.promptBubbleBackgroundHex(for: scheme, palette: palette, accent: .warm)
                )
            }
        }
    }
}

final class PrimaryActionTintSettingsTests: XCTestCase {
    func testStorageKeyIsStable() {
        XCTAssertEqual(
            PrimaryActionTintSettings.isEnabledKey,
            "appearance.tintsPrimaryActionsWithThemeColor"
        )
    }

    func testUsesThemeColorRequiresBothEnabledAndInteractive() {
        XCTAssertTrue(
            PrimaryActionTintSettings.usesThemeColor(isEnabled: true, controlIsEnabled: true)
        )
        XCTAssertFalse(
            PrimaryActionTintSettings.usesThemeColor(isEnabled: false, controlIsEnabled: true)
        )
        XCTAssertFalse(
            PrimaryActionTintSettings.usesThemeColor(isEnabled: true, controlIsEnabled: false)
        )
        XCTAssertFalse(
            PrimaryActionTintSettings.usesThemeColor(isEnabled: false, controlIsEnabled: false)
        )
    }
}

final class ChatLayoutDirectionSettingsTests: XCTestCase {
    func testRTLChatLayoutKeyIsStable() {
        XCTAssertEqual(
            ChatTranscriptDisplaySettings.rtlChatLayoutEnabledKey,
            "chatTranscript.rtlChatLayoutEnabled"
        )
    }

    func testChatLayoutDirectionFollowsToggle() {
        XCTAssertEqual(ChatTranscriptDisplaySettings.chatLayoutDirection(rtlEnabled: true), .rightToLeft)
        XCTAssertEqual(ChatTranscriptDisplaySettings.chatLayoutDirection(rtlEnabled: false), .leftToRight)
    }

    func testRightToLeftLanguageDetectionUsesPrimaryPreferredLanguage() {
        // RTL primaries auto-enable, including region-qualified identifiers.
        for rtl in [["ar-SA", "en-US"], ["he"], ["fa-IR"], ["ur"]] {
            XCTAssertTrue(
                ChatTranscriptDisplaySettings.isRightToLeftLanguage(preferredLanguages: rtl),
                "expected RTL for \(rtl)"
            )
        }
        // LTR primaries stay off — even when an RTL language is further down the list.
        for ltr in [["en-US"], ["de"], ["de", "ar"], []] {
            XCTAssertFalse(
                ChatTranscriptDisplaySettings.isRightToLeftLanguage(preferredLanguages: ltr),
                "expected LTR for \(ltr)"
            )
        }
    }
}

final class CodeBlockWrappingSettingsTests: XCTestCase {
    func testWrapsCodeBlockLinesKeyIsStable() {
        XCTAssertEqual(
            ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey,
            "chatTranscript.wrapsCodeBlockLines"
        )
    }

    /// Wrap mode concatenates a line's 500-char segments back into one `Text`, so
    /// joining them must reproduce the source line exactly (no dropped/duplicated
    /// characters) even when the line is split into several segments.
    func testPlainFormatterSegmentsRejoinLosslessly() throws {
        let longLine = String(repeating: "abcde", count: 240) // 1200 chars > 2x maxSegmentLength
        let lines = MarkdownPlainCodeFormatter.lines(in: longLine)

        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertGreaterThan(line.segments.count, 1, "A 1200-char line should split into multiple segments")
        XCTAssertEqual(line.segments.map(\.text).joined(), longLine)
    }

    /// The highlighted wrap path concatenates `MarkdownAttributedCodeFormatter`
    /// segments back into one `Text`, so the segments must rejoin losslessly *and*
    /// preserve their syntax-highlight attributes — including across a 500-char
    /// segment boundary.
    func testAttributedFormatterSegmentsRejoinLosslesslyPreservingAttributes() throws {
        let source = String(repeating: "x", count: 1200)
        let attributed = NSMutableAttributedString(string: source)
        // An attribute spanning the first 500-char boundary (480..<520) must survive.
        attributed.addAttribute(.kern, value: NSNumber(value: 3), range: NSRange(location: 480, length: 40))

        let lines = MarkdownAttributedCodeFormatter.lines(in: attributed)
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertGreaterThan(line.segments.count, 1, "A 1200-char line should split into multiple segments")

        let rejoined = NSMutableAttributedString()
        for segment in line.segments {
            rejoined.append(segment.attributedText)
        }

        XCTAssertEqual(rejoined.string, source)
        XCTAssertEqual(rejoined.attribute(.kern, at: 490, effectiveRange: nil) as? NSNumber, NSNumber(value: 3))
        XCTAssertEqual(rejoined.attribute(.kern, at: 510, effectiveRange: nil) as? NSNumber, NSNumber(value: 3))
        XCTAssertNil(rejoined.attribute(.kern, at: 600, effectiveRange: nil))
    }
}

final class ResponseCompletionNotificationPolicyTests: XCTestCase {
    func testAllowsEnabledAuthorizedNormalCompletionWhileSceneInactive() {
        XCTAssertTrue(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: true,
                authorizationStatus: .authorized,
                completedNormally: true,
                sceneIsActive: false
            )
        )
    }

    func testBlocksForegroundCompletion() {
        XCTAssertFalse(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: true,
                authorizationStatus: .authorized,
                completedNormally: true,
                sceneIsActive: true
            )
        )
    }

    func testBlocksCancelledOrFailedCompletion() {
        XCTAssertFalse(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: true,
                authorizationStatus: .authorized,
                completedNormally: false,
                sceneIsActive: false
            )
        )
    }

    func testBlocksWhenPreferenceOrPermissionDisallows() {
        XCTAssertFalse(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: false,
                authorizationStatus: .authorized,
                completedNormally: true,
                sceneIsActive: false
            )
        )

        XCTAssertFalse(
            ResponseCompletionNotificationPolicy.shouldSchedule(
                preferenceEnabled: true,
                authorizationStatus: .denied,
                completedNormally: true,
                sceneIsActive: false
            )
        )
    }
}

final class ResponseCompletionNotificationServiceTests: XCTestCase {
    func testRequestCarriesOnlySessionIDPayload() {
        XCTAssertEqual(
            ResponseCompletionNotificationRequest(sessionID: "session-abc").userInfo,
            ["session_id": "session-abc"]
        )
        XCTAssertEqual(ResponseCompletionNotificationRequest(sessionID: "").userInfo, [:])
        XCTAssertEqual(ResponseCompletionNotificationRequest(sessionID: nil).userInfo, [:])
    }

    func testSchedulesAllowedResponseCompletionWithSessionID() async {
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .authorized)

        let didSchedule = await ResponseCompletionNotificationService.scheduleResponseCompletedIfAllowed(
            sessionID: "session-abc",
            preferenceEnabled: true,
            completedNormally: true,
            sceneIsActive: false,
            scheduler: scheduler
        )

        XCTAssertTrue(didSchedule)
        XCTAssertEqual(scheduler.authorizationStatusCallCount, 1)
        XCTAssertEqual(scheduler.scheduledRequests, [ResponseCompletionNotificationRequest(sessionID: "session-abc")])
    }

    func testDoesNotScheduleBlockedResponseCompletion() async {
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .authorized)

        let didSchedule = await ResponseCompletionNotificationService.scheduleResponseCompletedIfAllowed(
            sessionID: "session-abc",
            preferenceEnabled: true,
            completedNormally: true,
            sceneIsActive: true,
            scheduler: scheduler
        )

        XCTAssertFalse(didSchedule)
        XCTAssertEqual(scheduler.authorizationStatusCallCount, 1)
        XCTAssertTrue(scheduler.scheduledRequests.isEmpty)
    }

    func testRequestAuthorizationUsesInjectedScheduler() async {
        let scheduler = SpyResponseCompletionNotificationScheduler(status: .notDetermined, requestAuthorizationResult: true)

        let granted = await ResponseCompletionNotificationService.requestAuthorization(scheduler: scheduler)

        XCTAssertTrue(granted)
        XCTAssertEqual(scheduler.requestAuthorizationCallCount, 1)
    }
}

final class ResponseCompletionNotificationTrackerTests: XCTestCase {
    func testDefersBackgroundTaskEndUntilNormalCompletionContextIsHandled() {
        var tracker = ResponseCompletionNotificationTracker()

        XCTAssertTrue(tracker.shouldEndBackgroundTaskOnStreamInactive(completionTrigger: 0))
        XCTAssertFalse(tracker.shouldEndBackgroundTaskOnStreamInactive(completionTrigger: 1))

        let context = tracker.completionContext(completionTrigger: 1, sceneIsActive: false)

        XCTAssertEqual(context, ResponseCompletionNotificationCompletionContext(sceneIsActive: false))
        XCTAssertTrue(tracker.shouldEndBackgroundTaskOnStreamInactive(completionTrigger: 1))
        // The same completion trigger is consumed only once.
        XCTAssertNil(tracker.completionContext(completionTrigger: 1, sceneIsActive: false))
    }

    func testCompletionContextCapturesSceneStateAtCompletion() {
        var tracker = ResponseCompletionNotificationTracker()

        let context = tracker.completionContext(completionTrigger: 1, sceneIsActive: true)

        XCTAssertEqual(context, ResponseCompletionNotificationCompletionContext(sceneIsActive: true))
    }

    func testInactiveStreamWithoutCompletionTriggerCanEndBackgroundTaskImmediately() {
        let tracker = ResponseCompletionNotificationTracker()

        XCTAssertTrue(tracker.shouldEndBackgroundTaskOnStreamInactive(completionTrigger: 0))
    }
}

private final class SpyResponseCompletionNotificationScheduler: ResponseCompletionNotificationScheduling {
    private let status: UNAuthorizationStatus
    private let requestAuthorizationResult: Bool
    private(set) var authorizationStatusCallCount = 0
    private(set) var requestAuthorizationCallCount = 0
    private(set) var scheduledRequests: [ResponseCompletionNotificationRequest] = []

    init(
        status: UNAuthorizationStatus,
        requestAuthorizationResult: Bool = false
    ) {
        self.status = status
        self.requestAuthorizationResult = requestAuthorizationResult
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatusCallCount += 1
        return status
    }

    func requestAuthorization() async -> Bool {
        requestAuthorizationCallCount += 1
        return requestAuthorizationResult
    }

    func schedule(_ request: ResponseCompletionNotificationRequest) async {
        scheduledRequests.append(request)
    }
}
