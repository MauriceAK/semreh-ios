import SwiftUI
import UIKit
import Combine

struct SessionSidebarUtilityRows: View {
    // Vertical gap between every utility row, matching the navigation rows so the
    // headers and subrows share one consistent rhythm now that each is its own row.
    private static let rowSpacing: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let viewModel: SessionListViewModel
    let topPadding: CGFloat
    let automatedVisibility: AutomatedSessionVisibility
    let sectionVisibility: SidebarSectionVisibility
    @Binding var profilesAreExpanded: Bool
    @Binding var projectsAreExpanded: Bool
    @Binding var selectedProjectID: String?
    @Binding var projectPendingDeletion: ProjectSummary?
    @Binding var projectPendingRename: ProjectSummary?

    let openDestination: (SessionListUtilityDestination) -> Void
    let switchActiveProfile: (ProfileSummary) -> Void
    let presentProjectCreation: () -> Void

    // Each disclosure subrow is emitted as its own List row (like the session
    // rows below it). List does not animate height/transition changes inside a
    // single row, so packing the subrows into one row made expand/collapse snap
    // instantly. As real rows, List animates them folding in/out; the fold is
    // driven by a value-based .animation on the List in SessionListView, which
    // works even though the disclosure booleans are @AppStorage-backed.
    var body: some View {
        if sectionVisibility.showsAnyUtilityLink {
            utilityLinks
                .padding(.top, topPadding)
                .sessionsScreenListRow()
        }

        // In single-profile mode the server rejects switching, so the whole
        // "Active Profile" disclosure would only no-op or error — hide it (#24).
        if showsActiveProfile {
            activeProfileHeader
                .padding(.top, activeProfileTopPadding)
                .sessionsScreenListRow()

            if profilesAreExpanded {
                activeProfileOptionRows
            }
        }

        if sectionVisibility.projects {
            projectsHeader
                .padding(.top, projectsTopPadding)
                .sessionsScreenListRow()

            if projectsAreExpanded {
                projectOptionRows
            }
        }
    }

    private var showsActiveProfile: Bool {
        sectionVisibility.activeProfile && !viewModel.isSingleProfileMode
    }

    // Whichever row lands first carries the section's top padding, since #189 can
    // hide the rows above it; the rest keep the tight inter-row spacing.
    private var activeProfileTopPadding: CGFloat {
        sectionVisibility.showsAnyUtilityLink ? Self.rowSpacing : topPadding
    }

    private var projectsTopPadding: CGFloat {
        sectionVisibility.showsAnyUtilityLink || showsActiveProfile ? Self.rowSpacing : topPadding
    }

    private func disclosureSubrow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 24)
            .padding(.top, Self.rowSpacing)
            .sessionsScreenListRow()
            .transition(SessionListMotion.disclosureContentTransition(reduceMotion: reduceMotion))
    }

    private var utilityLinks: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            if sectionVisibility.tasks {
                SidebarNavButton(title: String(localized: "Tasks"), assetImage: "LucideCalendarClock") {
                    openDestination(.tasks)
                }
            }

            if sectionVisibility.kanban {
                SidebarNavButton(title: String(localized: "Kanban"), assetImage: "LucideColumns3") {
                    openDestination(.kanban)
                }
            }

            if sectionVisibility.skills {
                SidebarNavButton(title: String(localized: "Skills"), assetImage: "LucideHammer") {
                    openDestination(.skills)
                }
            }

            if sectionVisibility.memory {
                SidebarNavButton(title: String(localized: "Memory"), assetImage: "LucideBrain") {
                    openDestination(.memory)
                }
            }

            if sectionVisibility.insights {
                SidebarNavButton(title: String(localized: "Insights"), assetImage: "LucideChartColumnIncreasing") {
                    openDestination(.insights)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private var activeProfileHeader: some View {
        SidebarDisclosureButton(
            title: String(localized: "Active Profile"),
            assetImage: "LucideUserRoundCog",
            isExpanded: profilesAreExpanded,
            tint: viewModel.activeProfileErrorMessage == nil ? .primary : .orange
        ) {
            profilesAreExpanded.toggle()
        } accessory: {
            if viewModel.isLoadingActiveProfile {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .accessibilityLabel(profilesAreExpanded ? "Collapse active profile picker" : "Expand active profile picker")
    }

    @ViewBuilder
    private var activeProfileOptionRows: some View {
        if viewModel.isLoadingActiveProfile && viewModel.profileOptions.isEmpty {
            disclosureSubrow {
                CompactStatusRow(title: String(localized: "Loading profiles..."), systemImage: "person.crop.circle")
            }
        } else if viewModel.profileOptions.isEmpty {
            disclosureSubrow {
                CompactStatusRow(
                    title: viewModel.activeProfileErrorMessage == nil ? String(localized: "No profiles") : String(localized: "Could not load profiles"),
                    systemImage: "exclamationmark.triangle"
                )
            }
        } else {
            ForEach(viewModel.profileOptions) { profile in
                let profileIsActive = isActiveProfile(profile)

                disclosureSubrow {
                    ActiveProfilePickerRow(
                        profile: profile,
                        isSelected: profileIsActive,
                        isSwitching: viewModel.isSwitchingActiveProfile
                            && viewModel.switchingActiveProfileName == profile.normalizedName
                    ) {
                        guard !profileIsActive else { return }
                        switchActiveProfile(profile)
                    }
                    .disabled(
                        viewModel.isViewingCachedData
                            || viewModel.isSwitchingActiveProfile
                            || profile.normalizedName == nil
                    )
                }
            }
        }
    }

    private var projectsHeader: some View {
        HStack(spacing: 8) {
            SidebarDisclosureButton(
                title: String(localized: "Projects"),
                assetImage: "LucideFolder",
                isExpanded: projectsAreExpanded
            ) {
                projectsAreExpanded.toggle()
            } accessory: {
                EmptyView()
            }
            .accessibilityLabel(projectsAreExpanded ? "Collapse projects" : "Expand projects")

            // Standalone "create empty project" affordance, shown only while the
            // Projects list is expanded. It is a sibling of the disclosure button
            // (not nested inside its label) so VoiceOver exposes it as its own
            // focusable control, mirroring the "All" button below. Nesting it in
            // the button's label flattened it into the parent's a11y element and
            // made it unreachable by assistive tech.
            if projectsAreExpanded {
                addProjectButton
            }

            if selectedProjectID != nil {
                HapticButton {
                    withAnimation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion)) {
                        selectedProjectID = nil
                    }
                } label: {
                    Text("All")
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                        // Flat translucent fill rather than Liquid Glass: the glass
                        // elevation shadow would spill past this tightly-sized List
                        // row and get clipped by the next row's opaque background.
                        .background(.thinMaterial, in: Capsule())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .accessibilityLabel("Show all projects")
                .accessibilityHint("Clears the selected project filter.")
            }
        }
        .padding(.horizontal, 24)
    }

    private var addProjectButton: some View {
        HapticButton {
            presentProjectCreation()
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add project")
        .accessibilityHint("Creates a new empty project.")
    }

    @ViewBuilder
    private var projectOptionRows: some View {
        if viewModel.isLoadingProjects && viewModel.projects.isEmpty {
            disclosureSubrow {
                CompactStatusRow(title: String(localized: "Loading projects..."), systemImage: "folder")
            }
        } else if viewModel.projects.isEmpty {
            disclosureSubrow {
                CompactStatusRow(title: String(localized: "No projects"), systemImage: "folder")
            }
        } else {
            ForEach(viewModel.projects) { project in
                disclosureSubrow {
                    ProjectFilterRow(
                        project: project,
                        isSelected: selectedProjectID == project.projectId,
                        count: sessionCount(for: project),
                        isViewingCachedData: viewModel.isViewingCachedData,
                        isRenamingProject: viewModel.isRenamingProject,
                        isDeletingProject: viewModel.isDeletingProject
                    ) {
                        guard let projectID = project.projectId else { return }

                        withAnimation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion)) {
                            selectedProjectID = selectedProjectID == projectID ? nil : projectID
                        }
                    } rename: {
                        projectPendingRename = project
                    } delete: {
                        projectPendingDeletion = project
                    }
                }
            }
        }
    }

    private func isActiveProfile(_ profile: ProfileSummary) -> Bool {
        guard let profileName = profile.normalizedName else { return false }

        if let activeProfileName = viewModel.activeProfileName {
            return profileName == activeProfileName
        }

        return profile.isActive == true
    }

    private func sessionCount(for project: ProjectSummary) -> Int {
        guard let projectID = project.projectId else { return 0 }
        return viewModel.sessions.filter { session in
            session.projectId == projectID && automatedVisibility.shows(session)
        }.count
    }
}

struct SidebarNavButton: View {
    let title: String
    let assetImage: String
    let action: () -> Void

    var body: some View {
        HapticButton(action: action) {
            HStack(spacing: 18) {
                SidebarUtilityIcon(assetImage: assetImage)

                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct SidebarDisclosureButton<Accessory: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let assetImage: String
    let isExpanded: Bool
    var tint: Color = .primary
    let action: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HapticButton(action: action) {
            HStack(alignment: .center, spacing: 18) {
                SidebarUtilityIcon(assetImage: assetImage, tint: tint)

                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                accessory()

                SidebarDisclosureChevron(isExpanded: isExpanded)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SidebarDisclosureChevron: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let isExpanded: Bool

    // Rotate inside a square box so the pivot is the visual center; the outer
    // frame keeps a fixed slot so the chevron never shifts horizontally or
    // vertically. A value-based animation rotates it in place (and is skipped
    // under Reduce Motion) regardless of the ambient List transaction.
    // `chevron.forward` mirrors to point leading-ward under RTL; the expand
    // rotation reverses there so the open state still points down (issue #294).
    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .rotationEffect(
                .degrees(RTLLayout.disclosureChevronRotationDegrees(
                    isExpanded: isExpanded,
                    isRightToLeft: layoutDirection == .rightToLeft
                )),
                anchor: .center
            )
            .frame(width: 24, height: 40)
            .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
            .accessibilityHidden(true)
    }
}

struct SidebarUtilityIcon: View {
    let assetImage: String
    var tint: Color = .primary

    var body: some View {
        Image(assetImage)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 21, height: 21)
            .foregroundStyle(tint)
            .frame(width: 28)
            .accessibilityHidden(true)
    }
}

struct SidebarSelectedSubrowIndicator: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
            .foregroundStyle(SemrehVisualTheme.accentForeground(for: colorScheme, palette: palette))
            .frame(width: 18, height: 18)
            .background(Color.accentColor, in: Circle())
            .accessibilityHidden(true)
    }
}

struct SidebarSubrowSelectionStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.leading, 18)
            .padding(.trailing, 10)
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
}
