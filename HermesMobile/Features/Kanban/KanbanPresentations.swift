import SwiftUI
import UIKit


enum KanbanCardAccessibility {
    static func summary(_ card: KanbanCard) -> String {
        var parts = [
            card.cardID ?? String(localized: "Unknown Card"),
            card.title ?? String(localized: "Untitled Card"),
            KanbanStatusPresentation(card.status?.rawValue ?? "").title,
            card.assignee ?? String(localized: "Unassigned")
        ]
        if let tenant = card.tenant { parts.append(tenant) }
        if let comments = card.commentCount { parts.append(KanbanCountFormatter.comments(comments)) }
        let prerequisites = card.linkCounts?.parents ?? 0
        let dependents = card.linkCounts?.children ?? 0
        if prerequisites > 0 { parts.append(KanbanCountFormatter.prerequisites(prerequisites)) }
        if dependents > 0 { parts.append(KanbanCountFormatter.dependents(dependents)) }
        if let age = card.ageSeconds { parts.append(String(localized: "Age \(KanbanAgeFormatter.full(age))")) }
        return parts.joined(separator: ", ")
    }
}

enum KanbanBoardAccessibility {
    static func browseLabel(_ board: KanbanBoard) -> String {
        let boardName = board.name ?? board.slug ?? String(localized: "Board")
        return String.localizedStringWithFormat(String(localized: "Browse Board: %@"), boardName)
    }

    static func actionsLabel(_ board: KanbanBoard) -> String {
        let boardName = board.name ?? board.slug ?? String(localized: "Board")
        return String.localizedStringWithFormat(String(localized: "Board actions for %@"), boardName)
    }

    static func browseSummary(_ board: KanbanBoard, isActive: Bool) -> String {
        var parts = [browseLabel(board)]
        if let description = board.description?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            parts.append(description)
        }
        parts.append(KanbanCountFormatter.cards(board.total ?? 0))
        let status = statusValue(isBrowsing: false, isActive: isActive)
        if !status.isEmpty { parts.append(status) }
        return parts.joined(separator: ", ")
    }

    static func statusValue(isBrowsing: Bool, isActive: Bool) -> String {
        var statuses: [String] = []
        if isBrowsing { statuses.append(String(localized: "Browsing")) }
        if isActive { statuses.append(String(localized: "Active")) }
        return statuses.joined(separator: ", ")
    }
}

enum KanbanBoardRowAction: Equatable {
    case edit
    case makeActive
    case archive

    var systemImage: String {
        switch self {
        case .edit: "pencil"
        case .makeActive: "checkmark.circle"
        case .archive: "archivebox"
        }
    }
}

struct KanbanBoardRowPresentation: Equatable {
    let browseSlug: String?
    let actions: [KanbanBoardRowAction]
    let mutationsAreEnabled: Bool
    let isBrowsing: Bool
    let isActive: Bool

    init(
        board: KanbanBoard,
        selectedBoardSlug: String?,
        sharedActiveBoardSlug: String?,
        canManageBoards: Bool
    ) {
        let trimmedSlug = board.slug?.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = trimmedSlug?.isEmpty == false ? trimmedSlug : nil
        isBrowsing = slug != nil && slug == selectedBoardSlug
        isActive = slug != nil && slug == sharedActiveBoardSlug
        browseSlug = isBrowsing ? nil : slug
        mutationsAreEnabled = canManageBoards && slug != nil

        guard let slug else {
            actions = []
            return
        }
        var applicableActions: [KanbanBoardRowAction] = [.edit]
        if slug != sharedActiveBoardSlug {
            applicableActions.append(.makeActive)
        }
        if slug != "default" {
            applicableActions.append(.archive)
        }
        actions = applicableActions
    }
}

enum KanbanBulkAccessibility {
    static func selectionLabel(_ card: KanbanCard, isSelected: Bool) -> String {
        var parts = [KanbanCardAccessibility.summary(card)]
        if isSelected { parts.append(String(localized: "Selected")) }
        return parts.joined(separator: ", ")
    }

    static func resultLabel(_ summary: KanbanBulkActionSummary) -> String {
        [
            "\(summary.succeededCount) \(String(localized: "Complete"))",
            "\(summary.failedCount) \(String(localized: "Failed"))",
            "\(summary.uncertainCount) \(String(localized: "Outcome Uncertain"))"
        ].joined(separator: ", ")
    }
}

struct KanbanStatusPresentation {
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }

    var title: String {
        switch rawValue {
        case "triage": String(localized: "Triage")
        case "todo": String(localized: "To Do")
        case "ready": String(localized: "Ready")
        case "running": String(localized: "Running")
        case "blocked": String(localized: "Blocked")
        case "done": String(localized: "Done")
        case "archived": String(localized: "Archived")
        case "": String(localized: "Unknown Status")
        default: String(localized: "Unsupported: \(rawValue)")
        }
    }

    var color: Color {
        switch rawValue {
        case "triage": .gray
        case "todo": .blue
        case "ready": .mint
        case "running": .orange
        case "blocked": .red
        case "done": .green
        case "archived": .secondary
        default: .purple
        }
    }
}

struct KanbanView: View {
    @State private var model: KanbanFeatureState

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        _model = State(
            initialValue: KanbanFeatureState(
                server: server,
                onAPIError: onAPIError
            )
        )
    }

    var body: some View {
        KanbanStatusFocusView(model: model)
            .background { SemrehBackdrop().ignoresSafeArea() }
            .task {
                await model.load()
            }
    }
}

enum KanbanAgeFormatter {
    static func abbreviated(_ seconds: Double) -> String { format(seconds, style: .abbreviated) }
    static func full(_ seconds: Double) -> String { format(seconds, style: .full) }

    private static func format(_ seconds: Double, style: DateComponentsFormatter.UnitsStyle) -> String {
        let formatter = switch (style, seconds) {
        case (.abbreviated, 86_400...): abbreviatedDays
        case (.abbreviated, 3_600...): abbreviatedHours
        case (.abbreviated, _): abbreviatedMinutes
        case (.full, 86_400...): fullDays
        case (.full, 3_600...): fullHours
        default: fullMinutes
        }
        return formatter.string(from: max(0, seconds)) ?? String(localized: "Just now")
    }

    private static let abbreviatedMinutes = makeFormatter(unit: .minute, style: .abbreviated)
    private static let abbreviatedHours = makeFormatter(unit: .hour, style: .abbreviated)
    private static let abbreviatedDays = makeFormatter(unit: .day, style: .abbreviated)
    private static let fullMinutes = makeFormatter(unit: .minute, style: .full)
    private static let fullHours = makeFormatter(unit: .hour, style: .full)
    private static let fullDays = makeFormatter(unit: .day, style: .full)

    private static func makeFormatter(
        unit: NSCalendar.Unit,
        style: DateComponentsFormatter.UnitsStyle
    ) -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = unit
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = style
        return formatter
    }
}

enum KanbanCountFormatter {
    static func cards(_ count: Int) -> String { localized(count, key: "%lld Cards") }
    static func comments(_ count: Int) -> String { localized(count, key: "%lld comments") }
    static func prerequisites(_ count: Int) -> String { localized(count, key: "%lld Prerequisites") }
    static func dependents(_ count: Int) -> String { localized(count, key: "%lld Dependents") }

    private static func localized(_ count: Int, key: String.LocalizationValue) -> String {
        String.localizedStringWithFormat(String(localized: key), count)
    }
}
