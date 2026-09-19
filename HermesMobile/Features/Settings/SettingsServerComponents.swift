import SwiftUI

struct SettingsAccessoryRow: View {
    let title: String
    var value: String?
    let systemImage: String
    var accessorySystemImage = "chevron.forward"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize, let value {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        leadingLabel
                        Spacer(minLength: 8)
                        accessoryIcon
                    }

                    Text(value)
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .padding(.leading, 34)
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    leadingLabel

                    Spacer(minLength: 8)

                    if let value {
                        Text(value)
                            .font(AppFont.caption(weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .multilineTextAlignment(.trailing)
                    }

                    accessoryIcon
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var leadingLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(AppFont.subheadline(weight: .medium))
                .layoutPriority(1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessoryIcon: some View {
        Image(systemName: accessorySystemImage)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

struct CustomHeadersSettingsView: View {
    @Bindable var authManager: AuthManager
    @State private var headers: [CustomHeader]
    @Environment(\.scenePhase) private var scenePhase

    init(authManager: AuthManager) {
        self.authManager = authManager
        _headers = State(initialValue: authManager.currentCustomHeaders)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CustomHeadersEditor(headers: $headers)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Connection Headers")
        .navigationBarTitleDisplayMode(.inline)
        // Live-refresh the network clients on every edit (cheap, in-memory only)
        // but defer the slow Keychain write until the editor is dismissed so
        // typing never stutters.
        .onChange(of: headers) { _, newValue in
            authManager.updateCustomHeaders(newValue, persist: false)
        }
        .onDisappear {
            authManager.updateCustomHeaders(headers, persist: true)
        }
        // onDisappear doesn't fire when the app is backgrounded or terminated
        // mid-edit, so also flush to the Keychain when the scene leaves active.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                authManager.updateCustomHeaders(headers, persist: true)
            }
        }
    }
}


struct SettingsToggleRow: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsRowLabel(title: title, systemImage: systemImage)
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

struct SettingsButton: View {
    let title: String
    var role: ButtonRole?
    var isLoading = false
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(_ title: String, role: ButtonRole? = nil, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        Button(role: role, action: action) {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    Text(title)
                }
            }
            .font(AppFont.subheadline(weight: .medium))
            .foregroundStyle(role == .destructive ? .red : .primary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background {
                shape.fill((role == .destructive ? Color.red : Color.primary).opacity(0.08))
            }
            .adaptiveGlass(
                .regular,
                isInteractive: true,
                tint: role == .destructive ? .red.opacity(0.08) : nil,
                fallbackMaterial: .thinMaterial,
                in: shape
            )
            .overlay {
                shape
                    .stroke((role == .destructive ? Color.red : Color.primary).opacity(strokeOpacity), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    private var strokeOpacity: Double {
        colorSchemeContrast == .increased ? 0.24 : 0.12
    }
}

struct SettingsStatusPill: View {
    let label: String
    var tint: Color = .secondary

    var body: some View {
        Text(label)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.12)))
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 2)
            .opacity(0.72)
    }
}

// MARK: - Multi-server (#17)

/// Small circular avatar whose accent follows the active app theme.
struct ServerAvatarBadge: View {
    let initials: String
    var size: CGFloat = 32
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        Text(initials)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(SemrehVisualTheme.energyForeground(for: palette))
            .frame(width: size, height: size)
            .background(SemrehVisualTheme.brandActionColor(for: palette), in: Circle())
            .overlay(Circle().stroke(.white.opacity(colorScheme == .dark ? 0.24 : 0.34), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// One row in the Settings "Servers" list: avatar, name, URL, and an active marker.
struct SettingsServerRow: View {
    let account: ServerAccount
    let isActive: Bool

    private var hostFallback: String {
        URL(string: account.urlString)?.host ?? account.urlString
    }

    private var name: String {
        account.displayName.isEmpty ? hostFallback : account.displayName
    }

    private var previewInitials: String {
        SessionIdentitySettings.displayInitials(
            displayName: account.displayName,
            storedInitials: account.initials,
            fallbackFullName: hostFallback
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            ServerAvatarBadge(initials: previewInitials)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(AppFont.subheadline(weight: .medium))
                    .lineLimit(1)

                Text(account.urlString)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if isActive {
                SettingsStatusPill(label: String(localized: "Active"))
            }

            Image(systemName: "chevron.forward")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isActive ? String(localized: "\(name), \(account.urlString), active server") : String(localized: "\(name), \(account.urlString)"))
        .accessibilityHint("Opens server details to switch, edit, or remove.")
    }
}

/// Reusable per-server identity editor (display name and initials), used by the
/// add-server flow and the server detail screen (#17). Visual accents follow the
/// active app theme; they are no longer user-editable per profile.
struct ServerIdentityEditor: View {
    @Binding var displayName: String
    @Binding var initials: String
    /// Host-derived fallback used for the avatar preview when fields are empty.
    let fallbackName: String

    private var previewInitials: String {
        SessionIdentitySettings.displayInitials(
            displayName: displayName.isEmpty ? fallbackName : displayName,
            storedInitials: initials,
            fallbackFullName: fallbackName
        )
    }

    private var initialsBinding: Binding<String> {
        Binding(
            get: { initials },
            set: { initials = SessionIdentitySettings.normalizedInitials($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ServerAvatarBadge(initials: previewInitials, size: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Server Avatar")
                        .font(AppFont.subheadline(weight: .medium))

                    Text("Accent follows the selected app theme.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            SettingsTextFieldRow(
                title: String(localized: "Display Name"),
                text: $displayName,
                placeholder: fallbackName.isEmpty ? String(localized: "Server") : fallbackName
            )

            SettingsDivider()

            SettingsTextFieldRow(title: String(localized: "Initials"), text: initialsBinding, placeholder: previewInitials)
        }
    }
}
