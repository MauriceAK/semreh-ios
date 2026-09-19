import SwiftUI
import UIKit
import Combine

struct ActiveProfilePickerRow: View {
    let profile: ProfileSummary
    let isSelected: Bool
    let isSwitching: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                SidebarUtilityIcon(
                    assetImage: "LucideUserRound",
                    tint: isSelected ? Color.accentColor : .primary
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(defaultModelTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isSwitching {
                    ProgressView()
                        .controlSize(.small)
                } else if isSelected {
                    SidebarSelectedSubrowIndicator()
                }
            }
            .frame(minHeight: 44)
            .sidebarSubrowSelectionStyle(isSelected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var defaultModelTitle: String {
        let model = profile.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !model.isEmpty else {
            return String(localized: "Default model unavailable")
        }
        return model
    }

    private var accessibilityLabel: String {
        let state = isSelected ? String(localized: "Active profile") : String(localized: "Profile")
        let switchingState = isSwitching ? String(localized: ", switching in progress") : ""
        return String(localized: "\(state), \(profile.displayName), \(defaultModelTitle)\(switchingState)")
    }
}

struct ProjectFilterRow: View {
    let project: ProjectSummary
    let isSelected: Bool
    let count: Int
    let isViewingCachedData: Bool
    let isRenamingProject: Bool
    let isDeletingProject: Bool
    let action: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 18) {
                    SidebarUtilityIcon(assetImage: "LucideFolder", tint: projectColor)

                    Text(displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        if isSelected {
                            SidebarSelectedSubrowIndicator()
                        }
                    }
                }
                .padding(.leading, 18)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(displayName)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(isSelected ? "Clears this project filter." : "Filters sessions to this project.")

            Menu {
                Button {
                    rename()
                } label: {
                    Label("Rename Project", systemImage: "pencil")
                }
                .disabled(projectActionsAreDisabled)

                Button(role: .destructive) {
                    delete()
                } label: {
                    Label("Delete Project", systemImage: "trash")
                }
                .disabled(projectActionsAreDisabled)
            } label: {
                Label(String(localized: "Project actions for \(displayName)"), systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Project actions for \(displayName)"))
            .accessibilityHint("Shows rename and delete actions for this project.")
        }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
                    }
            }
        }
    }

    private var displayName: String {
        let name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else {
            return String(localized: "Untitled Project")
        }
        return name
    }

    private var accessibilityValue: String {
        let countTitle = String(localized: "\(count) sessions")
        return isSelected ? String(localized: "Selected, \(countTitle)") : countTitle
    }

    private var projectActionsAreDisabled: Bool {
        isViewingCachedData
            || isRenamingProject
            || isDeletingProject
            || project.projectId == nil
    }

    private var projectColor: Color {
        if let apiColor = Color(hexString: project.color) {
            return apiColor
        }

        switch stableColorSeed % 5 {
        case 0: return .green
        case 1: return .blue
        case 2: return .red
        case 3: return .orange
        default: return .primary
        }
    }

    private var stableColorSeed: Int {
        let source = project.projectId ?? displayName
        return source.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult &+ Int(scalar.value)
        }
    }
}

extension Color {
    init?(hexString: String?) {
        guard let hexString else { return nil }

        var trimmed = hexString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            trimmed.removeFirst()
        }

        let expanded: String
        switch trimmed.count {
        case 3:
            expanded = trimmed.map { "\($0)\($0)" }.joined()
        case 6:
            expanded = trimmed
        default:
            return nil
        }

        guard let value = UInt64(expanded, radix: 16) else { return nil }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

struct CompactStatusRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 42)
    }
}

struct SessionListStatusRow: View {
    let title: String
    let description: String?
    let systemImage: String
    var descriptionLineLimit: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)

                if let description {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(descriptionLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 42)
    }
}
