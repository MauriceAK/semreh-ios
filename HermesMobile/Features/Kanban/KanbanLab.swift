import SwiftUI
import UIKit


#if DEBUG

struct KanbanLabView: View {
    @State private var scenario = KanbanLabScenario.dense
    @State private var model = KanbanLabScenario.dense.makeModel()

    var body: some View {
        KanbanStatusFocusView(model: model)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Picker("Scenario", selection: $scenario) {
                            ForEach(KanbanLabScenario.allCases) { scenario in
                                Text(scenario.title).tag(scenario)
                            }
                        }
                    } label: {
                        Image(systemName: "testtube.2")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(Text("Kanban Lab Scenario"))
                    .accessibilityHint(Text("Uses local fixtures and never contacts or changes a Kanban server."))
                }
            }
            .task(id: scenario) {
                model = scenario.makeModel()
                await model.load()
                if scenario == .filteredEmpty { model.searchText = "no matching fixture" }
            }
    }
}

enum KanbanLabScenario: String, CaseIterable, Identifiable {
    case firstLoad
    case dense
    case empty
    case filteredEmpty
    case partial
    case authentication
    case network
    case serverUnavailable
    case incompatible
    case liveDelayed
    case offline
    case detailEmpty
    case detailError
    case detailTruncated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstLoad: "First load"
        case .dense: "Dense Board"
        case .empty: "Empty Board"
        case .filteredEmpty: "Filtered empty"
        case .partial: "Partial capability"
        case .authentication: "Authentication"
        case .network: "Network"
        case .serverUnavailable: "Server unavailable"
        case .incompatible: "Incompatible"
        case .liveDelayed: "Live updates delayed"
        case .offline: "Offline snapshot"
        case .detailEmpty: "Empty Card detail"
        case .detailError: "Card detail error"
        case .detailTruncated: "Truncated worker log"
        }
    }

    @MainActor
    func makeModel() -> KanbanFeatureState {
        KanbanFeatureState(
            server: URL(string: "https://kanban-lab.invalid")!,
            client: KanbanLabClient(scenario: self),
            streamClient: KanbanLabStreamClient(fails: self == .liveDelayed || self == .offline),
            timing: KanbanLiveUpdateTiming(
                coalescingDelay: .milliseconds(10),
                reconnectDelays: [.milliseconds(10), .milliseconds(10)],
                pollingInterval: self == .offline ? .milliseconds(10) : .seconds(30),
                failuresBeforePolling: 3
            )
        )
    }
}

@MainActor
private final class KanbanLabStreamClient: KanbanEventStreamingClient {
    private let fails: Bool
    private var callbackTask: Task<Void, Never>?

    init(fails: Bool) { self.fails = fails }

    func start(
        url: URL,
        onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) {
        stop()
        callbackTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            if fails {
                onFailure()
            } else {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let board = components?.queryItems?.first(where: { $0.name == "board" })?.value ?? "main"
                let cursor = Int(components?.queryItems?.first(where: { $0.name == "since" })?.value ?? "0") ?? 0
                onFrame(.hello(cursor: cursor, board: board))
            }
        }
    }

    func stop() {
        callbackTask?.cancel()
        callbackTask = nil
    }
}
#endif
