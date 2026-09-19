import SwiftUI

extension SettingsView {
    var appearanceSection: some View {
        SettingsCard {
            SettingsPickerRow(
                title: String(localized: "Theme"),
                systemImage: "circle.lefthalf.filled",
                selection: appThemeSettingsBinding
            ) {
                ForEach(settingsThemeOptions) { theme in
                    Text(settingsThemeTitle(for: theme)).tag(theme.rawValue)
                }
            }

            SettingsFootnote(String(localized: "System follows the device appearance. Light and Dark use Semreh's cream and charcoal palette."))

            if let legacyThemeTitle {
                SettingsFootnote(String(localized: "Legacy theme \(legacyThemeTitle) is still preserved. Choose System, Light, or Dark to switch."))
            }

            SettingsDivider()

            SettingsPickerRow(
                title: String(localized: "Accent"),
                systemImage: "paintbrush",
                selection: Binding(
                    get: { AppAccent.storedValue(appAccentRawValue).rawValue },
                    set: { appAccentRawValue = $0 }
                )
            ) {
                ForEach(AppAccent.allCases) { accent in
                    Text(accent.title).tag(accent.rawValue)
                }
            }

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Tint New Chat & Send"),
                systemImage: "paintbrush.pointed",
                isOn: $tintsPrimaryActions
            )

            SettingsFootnote(String(localized: "Apply the active theme accent to these primary buttons."))
        }
    }

    var chatSection: some View {
        SettingsCategory(title: "Chat", subtitle: "Responses, dictation, and transcript details", systemImage: "bubble.left.and.bubble.right") {
        SettingsCard(title: String(localized: "Interaction")) {
            SettingsToggleRow(
                title: String(localized: "Haptic Feedback"),
                systemImage: "iphone.radiowaves.left.and.right",
                isOn: $isHapticsEnabled
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Response Complete Alerts"),
                systemImage: "bell",
                isOn: responseCompletionNotificationBinding
            )

            if let notificationStatusText {
                SettingsFootnote(notificationStatusText)
            }

            SettingsFootnote(String(localized: "Uses on-device iOS notifications. Remote push delivery is not configured."))

            SettingsDivider()

            SettingsPickerRow(
                title: String(localized: "Send While Responding"),
                systemImage: "arrow.up.message",
                selection: $streamingSendBehaviorRawValue
            ) {
                ForEach(StreamingSendBehavior.allCases) { behavior in
                    Text(behavior.settingsDescription).tag(behavior.rawValue)
                }
            }

            SettingsDivider()

            SettingsPickerRow(
                title: String(localized: "Dictation Provider"),
                systemImage: "mic",
                selection: $sttProviderPreferenceRawValue
            ) {
                ForEach(ComposerSTTProviderPreference.allCases) { preference in
                    Text(preference.title).tag(preference.rawValue)
                }
            }

            SettingsFootnote(String(localized: "On-device only keeps composer dictation audio off your Hermes server."))
        }

        SettingsCard(title: String(localized: "Chat")) {
            SettingsToggleRow(
                title: String(localized: "Thinking and Tool Cards"),
                systemImage: "brain.head.profile",
                isOn: $showsThinkingAndToolCards
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Expand Thinking by Default"),
                systemImage: "rectangle.expand.vertical",
                isOn: $thinkingCardsStartExpanded
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Expand Tools by Default"),
                systemImage: "wrench.and.screwdriver",
                isOn: $toolCardsStartExpanded
            )

            SettingsFootnote(String(localized: "Thinking and Tool cards start expanded instead of collapsed. Tapping a card still toggles it."))

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Streamed Text Animation"),
                systemImage: "sparkles",
                isOn: $isStreamedTextAnimationEnabled
            )

            SettingsFootnote(String(localized: "Fades words in as a response streams. Turn off to show text instantly."))

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Response Timestamps"),
                systemImage: "clock",
                isOn: $showsAssistantTurnTimestamps
            )

            SettingsFootnote(String(localized: "Adds a small marker and the time above each response so back-to-back replies are easier to tell apart."))

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Response Speed"),
                systemImage: "gauge.with.dots.needle.67percent",
                isOn: $showsResponseSpeed
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Wrap Code Block Lines"),
                systemImage: "arrow.turn.down.left",
                isOn: $wrapsCodeBlockLines
            )

            SettingsFootnote(String(localized: "Wraps long lines in code blocks to fit the screen instead of scrolling sideways. You can also tap the wrap button in any code block."))

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Right-to-Left Chat Layout"),
                systemImage: "text.alignright",
                isOn: $rtlChatLayoutEnabled
            )

            SettingsFootnote(String(localized: "Lays out messages and the composer right-to-left for Arabic, Hebrew, Persian, and Urdu. Code, math, tables, and tool output stay left-to-right. Other screens are unaffected."))

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Hide Attachment Paths"),
                systemImage: "eye.slash",
                isOn: $hidesAttachmentPaths
            )

            SettingsFootnote(String(localized: "Hides the appended file-path line in your sent messages. Attachments still appear as previews, and the server still receives the paths."))

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Live Activity Excerpts"),
                systemImage: "lock",
                isOn: $showsLiveActivityResponseExcerpts
            )

            SettingsFootnote(String(localized: "Shows short response text on the Lock Screen and Dynamic Island."))

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Show Files in chat menu"),
                systemImage: "folder",
                isOn: $showsChatFilesButton
            )

            SettingsDivider()

            SettingsToggleRow(
                title: String(localized: "Show Git actions"),
                systemImage: "arrow.triangle.branch",
                isOn: $showsChatGitControls
            )

            SettingsFootnote(String(localized: "Covers both the git menu in the chat toolbar and the branch picker in the composer."))
        }
        }
    }
}
