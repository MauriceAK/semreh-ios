import SwiftUI
import UIKit


#if DEBUG

actor KanbanLabClient: KanbanDataClient {
    let scenario: KanbanLabScenario
    var submittedComments: [String: [String: [String]]] = [:]
    var storedCards: [String: [String: StoredCard]] = [:]
    var cardIDsByIntent: [String: String] = [:]
    var nextCardSequence = 100
    var activeBoardSlug = "default"
    var storedBoards: [String: StoredBoard] = [
        "default": StoredBoard(
            slug: "default", name: "Default Board", description: "Primary fixture Board",
            icon: "📋", color: "#5B8DEF", total: 8
        ),
        "release": StoredBoard(
            slug: "release", name: "Release Board", description: "Shipping fixture",
            icon: "🚀", color: "#34C759", total: 2
        )
    ]

    init(scenario: KanbanLabScenario) { self.scenario = scenario }

    struct StoredCard: Sendable {
        let cardID: String
        var title: String
        var body: String?
        var status: String
        var priority: Int
        var assignee: String?
        var tenant: String?
        let workspaceKind: String
        let workspacePath: String?
        let skills: [String]?
        let maxRuntimeSeconds: Int?
        let prerequisiteID: String?

        init(
            cardID: String,
            title: String,
            body: String?,
            status: String,
            priority: Int,
            assignee: String?,
            tenant: String?,
            workspaceKind: String,
            workspacePath: String?,
            skills: [String]?,
            maxRuntimeSeconds: Int?,
            prerequisiteID: String?
        ) {
            self.cardID = cardID
            self.title = title
            self.body = body
            self.status = status
            self.priority = priority
            self.assignee = assignee
            self.tenant = tenant
            self.workspaceKind = workspaceKind
            self.workspacePath = workspacePath
            self.skills = skills
            self.maxRuntimeSeconds = maxRuntimeSeconds
            self.prerequisiteID = prerequisiteID
        }

        init(cardID: String, request: KanbanCreateCardRequest) {
            self.init(
                cardID: cardID,
                title: request.title,
                body: request.body,
                status: request.status,
                priority: request.priority ?? 0,
                assignee: request.assignee,
                tenant: request.tenant,
                workspaceKind: request.workspaceKind,
                workspacePath: request.workspacePath,
                skills: request.skills,
                maxRuntimeSeconds: request.maxRuntimeSeconds,
                prerequisiteID: request.prerequisiteID
            )
        }

        mutating func apply(_ request: KanbanEditCardRequest) {
            title = request.title
            body = request.body
            tenant = request.tenant
            priority = request.priority
            assignee = request.assignee
            if let status = request.status { self.status = status }
        }

        func matches(_ request: KanbanBoardRequest) -> Bool {
            if status == "archived", !request.includeArchived { return false }
            if let tenant = request.tenant, self.tenant != tenant { return false }
            if let assignee = request.assignee, self.assignee != assignee { return false }
            if request.onlyMine, assignee != "builder" { return false }
            return true
        }

        var object: [String: Any] {
            var result: [String: Any] = [
                "id": cardID,
                "title": title,
                "status": status,
                "priority": priority,
                "workspace_kind": workspaceKind,
                "comment_count": 0,
                "age_seconds": 0
            ]
            if let body { result["body"] = body }
            if let assignee { result["assignee"] = assignee }
            if let tenant { result["tenant"] = tenant }
            if let workspacePath { result["workspace_path"] = workspacePath }
            if let skills { result["skills"] = skills }
            if let maxRuntimeSeconds { result["max_runtime_seconds"] = maxRuntimeSeconds }
            return result
        }
    }

    struct StoredBoard: Sendable {
        let slug: String
        var name: String?
        var description: String?
        var icon: String?
        var color: String?
        let total: Int

        var object: [String: Any] {
            var result: [String: Any] = [
                "slug": slug,
                "total": total,
                "counts": total == 0 ? [:] : ["ready": total],
                "read_only": false
            ]
            result["name"] = name
            result["description"] = description
            result["icon"] = icon
            result["color"] = color
            return result
        }
    }
}

#endif
