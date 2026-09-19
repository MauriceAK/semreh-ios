import SwiftUI
import UIKit
import Combine

struct ScheduledSessionsDisclosure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let viewModel: SessionListViewModel
    let sessions: [SessionSummary]
    let totalCount: Int
    let isSearchActive: Bool
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let selectedSessionID: String?
    @Binding var userIsExpanded: Bool
    let actions: SessionListRowActions
    let viewAll: () -> Void

    private var isExpanded: Bool { isSearchActive || userIsExpanded }
    private var displayedSessions: [SessionSummary] {
        isSearchActive ? sessions : Array(sessions.prefix(5))
    }

    var body: some View {
        SidebarDisclosureButton(
            title: String(localized: "Scheduled sessions"),
            assetImage: "LucideCalendarClock",
            isExpanded: isExpanded
        ) {
            guard !isSearchActive else { return }
            userIsExpanded.toggle()
        } accessory: {
            Text("\(totalCount)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.top, isSearchActive ? 16 : 12)
        .sessionsScreenListRow()
        .accessibilityLabel(
            isSearchActive
                ? String(localized: "Scheduled sessions")
                : isExpanded
                    ? String(localized: "Collapse scheduled sessions")
                    : String(localized: "Expand scheduled sessions")
        )

        if isExpanded {
            ForEach(displayedSessions) { session in
                SessionInteractiveRow(
                    viewModel: viewModel,
                    session: session,
                    showsMessageCount: showsMessageCount,
                    showsWorkspace: showsWorkspace,
                    selectedSessionID: selectedSessionID,
                    actions: actions
                )
                .transition(SessionListMotion.disclosureContentTransition(reduceMotion: reduceMotion))
            }

            if !isSearchActive && sessions.count > 5 {
                HapticButton(action: viewAll) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .frame(width: 24)
                        Text("View all")
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sessionsScreenListRow()
                .transition(SessionListMotion.disclosureContentTransition(reduceMotion: reduceMotion))
            }
        }
    }
}

struct ScheduledSessionsView: View {
    let viewModel: SessionListViewModel
    let showsCronSessions: Bool
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let selectedSessionID: String?
    let actions: SessionListRowActions

    @State private var searchText = ""

    var body: some View {
        List {
            if sessions.isEmpty {
                SessionListStatusRow(
                    title: searchText.isEmpty
                        ? String(localized: "No sessions yet")
                        : String(localized: "No matching sessions"),
                    description: searchText.isEmpty
                        ? nil
                        : String(localized: "Try another search or project filter."),
                    systemImage: "calendar.badge.clock"
                )
                .padding(.horizontal, 24)
                .sessionsScreenListRow()
            } else {
                ForEach(sessions) { session in
                    SessionInteractiveRow(
                        viewModel: viewModel,
                        session: session,
                        showsMessageCount: showsMessageCount,
                        showsWorkspace: showsWorkspace,
                        selectedSessionID: selectedSessionID,
                        actions: actions
                    )
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background { SemrehBackdrop().ignoresSafeArea() }
        .navigationTitle("Scheduled sessions")
        .searchable(text: $searchText, prompt: "Search sessions")
    }

    private var sessions: [SessionSummary] {
        guard showsCronSessions else { return [] }

        return viewModel.visibleSessions(searchText: searchText, selectedProjectID: nil)
            .filter { $0.isCronSession && $0.archived != true }
    }
}
