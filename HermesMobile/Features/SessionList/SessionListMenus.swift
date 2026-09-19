import SwiftUI
import UIKit
import Combine

struct SessionRowContextMenu: View {
    let session: SessionSummary
    let projects: [ProjectSummary]
    let isViewingCachedData: Bool
    let isRenamingSession: Bool
    let isCreatingProject: Bool
    let isMovingSession: Bool
    let isLoadingProjects: Bool
    let isMutating: Bool
    var capabilities: SessionRowActionPolicy.Capabilities = .canonical
    let actions: SessionListRowActions

    private var effectiveCapabilities: SessionRowActionPolicy.Capabilities {
        capabilities.includingCachedData(isViewingCachedData)
    }

    var body: some View {
        let fullTitle = SessionRowView.displayTitle(for: session)

        Section("Full Title") {
            Text(fullTitle)

            Button {
                UIPasteboard.general.string = fullTitle
            } label: {
                Label("Copy Full Title", systemImage: "doc.on.doc")
            }
        }

        if SessionRowActionPolicy.offersMetadataActions(
            for: session,
            capabilities: effectiveCapabilities
        ) {
            Button {
                actions.togglePinned(session)
            } label: {
                Label(session.pinned == true ? "Unpin" : "Pin", systemImage: "pin")
            }
            .disabled(!canShowSessionMutationActions || isMutating)

            Button {
                actions.rename(session)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(isViewingCachedData || isRenamingSession || !hasServerSessionID(session))
        }

        if SessionRowActionPolicy.offersCollectionActions(
            for: session,
            capabilities: effectiveCapabilities
        ) {
            Button {
                actions.duplicate(session)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            .disabled(isViewingCachedData || session.sessionId == nil || isMutating)

            if actions.projectsEnabled {
                Menu {
                    SessionProjectMoveMenu(
                        session: session,
                        projects: projects,
                        isCreatingProject: isCreatingProject,
                        isMovingSession: isMovingSession,
                        isLoadingProjects: isLoadingProjects,
                        actions: actions
                    )
                } label: {
                    Label("Move to Project", systemImage: "folder")
                }
                .disabled(isViewingCachedData || session.sessionId == nil || isMutating)
            }
        }

        // Export works for canonical sessions the server can see, including
        // read-only and foreign/CLI rows. Search-only rows retain the local
        // deeplink action but do not claim collection-backed export support.
        Menu {
            if canExportSession {
                Button {
                    actions.export(session, .html)
                } label: {
                    Label("Export as HTML", systemImage: "doc.richtext")
                }

                Button {
                    actions.export(session, .json)
                } label: {
                    Label("Export as JSON", systemImage: "curlybraces")
                }
            }

            if let deepLinkURL = SessionRowActionPolicy.deepLinkURL(
                for: session,
                isViewingCachedData: isViewingCachedData,
                isMutating: isMutating
            ) {
                Button {
                    UIPasteboard.general.string = deepLinkURL.absoluteString
                } label: {
                    Label("Copy Deeplink", systemImage: "doc.on.doc")
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled((!canExportSession && !canCopyDeepLink) || isMutating)

        if SessionRowActionPolicy.offersMetadataActions(
            for: session,
            capabilities: effectiveCapabilities
        ) {
            Button {
                actions.archive(session)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(!canShowSessionMutationActions || isMutating)
        }

        if SessionRowActionPolicy.offersCollectionActions(
            for: session,
            capabilities: effectiveCapabilities
        ) {
            Button(role: .destructive) {
                actions.delete(session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!canShowSessionMutationActions || isMutating)
        }
    }

    private var canShowSessionMutationActions: Bool {
        SessionRowActionPolicy.offersMetadataActions(
            for: session,
            capabilities: effectiveCapabilities
        )
    }

    private var canExportSession: Bool {
        SessionRowActionPolicy.canExport(session, capabilities: effectiveCapabilities)
    }

    private var canCopyDeepLink: Bool {
        SessionRowActionPolicy.deepLinkURL(
            for: session,
            isViewingCachedData: isViewingCachedData,
            isMutating: isMutating
        ) != nil
    }
}

struct SessionProjectMoveMenu: View {
    let session: SessionSummary
    let projects: [ProjectSummary]
    let isCreatingProject: Bool
    let isMovingSession: Bool
    let isLoadingProjects: Bool
    let actions: SessionListRowActions

    var body: some View {
        Button {
            actions.move(session, nil)
        } label: {
            Label("No project", systemImage: session.projectId == nil ? "checkmark" : "tray")
        }
        .disabled(isMovingSession || session.projectId == nil)

        if !projects.isEmpty {
            Divider()

            ForEach(projects) { project in
                let projectID = project.projectId
                let isSelected = session.projectId == projectID
                let projectName = project.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Untitled Project")

                Button {
                    actions.move(session, projectID)
                } label: {
                    Label(
                        projectName,
                        systemImage: isSelected ? "checkmark" : "folder"
                    )
                }
                .disabled(isMovingSession || projectID == nil || isSelected)
            }
        }

        Divider()

        Button {
            actions.createProject(session)
        } label: {
            Label("New Project", systemImage: "folder.badge.plus")
        }
        .disabled(isCreatingProject || isMovingSession)

        if projects.isEmpty {
            Button {
                actions.refreshProjects()
            } label: {
                Label("Refresh Projects", systemImage: "arrow.clockwise")
            }
            .disabled(isLoadingProjects)
        }
    }
}

/// Long-press menu on the session-list avatar: switch the active server (the
/// active one marked + disabled, mirroring `SessionProjectMoveMenu`'s checkmark
/// idiom), plus shortcuts into #17's add-server flow and the Settings server
/// list (#283). Holds no switching logic — it calls back into the tested #17
/// `AuthManager.switchActiveServer` action and the existing navigation.
struct AvatarServerSwitcherMenu: View {
    let model: AvatarServerSwitcherModel
    let switchToServer: (ServerAccount) -> Void
    let addServer: () -> Void
    let manageServers: () -> Void

    var body: some View {
        Section("Servers") {
            ForEach(model.entries) { entry in
                Button {
                    switchToServer(entry.account)
                } label: {
                    Label(entry.displayName, systemImage: entry.isActive ? "checkmark" : "server.rack")
                }
                .disabled(entry.isActive)
                .accessibilityLabel(
                    entry.isActive
                        ? String(localized: "\(entry.displayName), active server")
                        : String(localized: "Switch to \(entry.displayName)")
                )
            }
        }

        Section {
            Button {
                addServer()
            } label: {
                Label("Add Server…", systemImage: "plus")
            }

            Button {
                manageServers()
            } label: {
                Label("Manage Servers", systemImage: "gearshape")
            }
        }
    }
}

/// Sheet item for a finished session export: the temp file offered to the
/// share sheet. Identity is the file URL, which is unique per export.
struct SessionExportShareItem: Identifiable {
    let fileURL: URL

    var id: String { fileURL.absoluteString }
}

/// Minimal `UIActivityViewController` wrapper — the app has no other share
/// surface and `ShareLink` can't be presented programmatically after an async
/// download finishes. Cleanup of the temp file happens in the sheet's
/// `onDismiss`, which runs after the activity UI is gone in both the
/// completed and cancelled paths.
struct SessionExportShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
