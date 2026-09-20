import SwiftUI

struct SettingsDestinationRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(SemrehVisualTheme.action(for: colorScheme, palette: palette))
                .frame(width: 36, height: 36)
                .background(
                    SemrehVisualTheme.canvas(for: colorScheme, palette: palette),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.forward")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this settings section.")
    }
}

struct SettingsIndexDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 50)
            .opacity(0.72)
    }
}

struct SettingsCategory<Content: View>: View {
    @Environment(\.appColorPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SemrehVisualTheme.action(for: colorScheme, palette: palette))
                    .frame(width: 34, height: 34)
                    .background(SemrehVisualTheme.canvas(for: colorScheme, palette: palette), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(SemrehTypography.label).foregroundStyle(.primary)
                    Text(subtitle).font(SemrehTypography.caption).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            VStack(spacing: 20) { content }
        }
    }
}

struct SettingsTextFieldRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    @Binding var text: String
    let placeholder: String
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .words
    var isSecure = false
    var submitLabel: SubmitLabel = .return
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    titleLabel
                    textField
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    titleLabel

                    Spacer(minLength: 12)

                    textField
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 190)
                }
            }
        }
    }

    private var titleLabel: some View {
        Text(title)
            .font(AppFont.subheadline())
    }

    @ViewBuilder
    private var textField: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .font(AppFont.subheadline())
        .textInputAutocapitalization(autocapitalization)
        .autocorrectionDisabled()
        .keyboardType(keyboardType)
        .submitLabel(submitLabel)
        .onSubmit { onSubmit?() }
    }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.appColorPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var contentSpacing: CGFloat = 12

    let title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
            Text(title)
                .textCase(.uppercase)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(SemrehVisualTheme.brandAccent(for: colorScheme, palette: palette))
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }

            VStack(alignment: .leading, spacing: contentSpacing) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SemrehVisualTheme.panel(for: colorScheme, palette: palette), in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

struct SettingsPickerRow<SelectionValue: Hashable, Options: View>: View {
    let title: String
    let systemImage: String
    @Binding var selection: SelectionValue
    @ViewBuilder let options: Options

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        title: String,
        systemImage: String,
        selection: Binding<SelectionValue>,
        @ViewBuilder options: () -> Options
    ) {
        self.title = title
        self.systemImage = systemImage
        _selection = selection
        self.options = options()
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsRowLabel(title: title, systemImage: systemImage)
                        .accessibilityHidden(true)

                    picker
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    SettingsRowLabel(title: title, systemImage: systemImage)
                        .accessibilityHidden(true)

                    Spacer(minLength: 12)

                    picker
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            options
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel(Text(title))
    }
}

struct SettingsRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsValueRow<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    titleText

                    trailing
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    titleText

                    Spacer(minLength: 16)

                    trailing
                }
            }
        }
        .font(AppFont.subheadline())
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private var titleText: some View {
        Text(title)
            .foregroundStyle(.primary)
    }
}

struct SettingsInfoRow: View {
    let title: String
    let value: String
    var valueIsSelectable = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        SettingsValueRow(title: title) {
            if valueIsSelectable {
                valueText
                    .textSelection(.enabled)
            } else {
                valueText
            }
        }
    }

    private var valueText: some View {
        Text(value)
            .foregroundStyle(.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
    }
}
