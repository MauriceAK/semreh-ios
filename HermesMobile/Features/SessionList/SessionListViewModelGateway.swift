import Foundation
import Observation
import SwiftData
import SwiftUI

extension SessionListViewModel {
    /// Defers invalidation refreshes while the sidebar is editing a row or
    /// preparing a destructive action. The caller should clear this when the
    /// edit UI closes; a dirty list then refreshes on the next safe turn.
    func setSidebarEditing(_ editing: Bool) {
        sidebarEditing = editing
        sidebarRefreshStateChanged()
    }

    func setSidebarDestructiveActionPending(_ pending: Bool) {
        sidebarDestructiveActionPending = pending
        sidebarRefreshStateChanged()
    }

    /// Starts the one observation/connect task for the already-owned shared
    /// runtime. This is intentionally separate from `load`: the sidebar can
    /// paint its cache/list without waiting for gateway setup, while the first
    /// direct gateway event is still observed before any chat is opened.
    func startGatewayObservation() {
        gatewayObservationEnabled = true
        guard gatewayObservationTask == nil else { return }

        if gatewayObserverID == nil {
            gatewayObservationGeneration &+= 1
        }
        let generation = gatewayObservationGeneration
        gatewayObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.establishGatewayObservation(generation: generation)
            if self.gatewayObservationGeneration == generation {
                self.gatewayObservationTask = nil
            }
        }
    }

    /// Removes the shared-runtime observer when the owning sidebar surface is
    /// discarded. Old callbacks are generation-checked and cannot refresh a
    /// replacement account/profile; a later view must explicitly call
    /// `startGatewayObservation()` before it reattaches.
    func invalidateGatewayObservation() {
        gatewayObservationGeneration &+= 1
        gatewayObservationEnabled = false
        loadGeneration &+= 1
        isLoading = false
        gatewayObservationTask?.cancel()
        gatewayObservationTask = nil
        sidebarRefreshTask?.cancel()
        sidebarRefreshTask = nil
        if let gatewayObserverID, let observedGatewayRuntime {
            observedGatewayRuntime.removeObserver(gatewayObserverID)
        }
        gatewayObserverID = nil
        observedGatewayRuntime = nil
        isSidebarDirty = false
    }

    /// Root temp directory holding one UUID subdirectory per export
    /// (see `export(_:format:)`).
    nonisolated static var exportsRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session-exports", isDirectory: true)
    }

    /// Lazy static ⇒ runs exactly once per process, on first access.
    nonisolated static let sweepLeakedExportsOnce: Void = {
        try? FileManager.default.removeItem(at: exportsRootDirectory)
    }()

    var sidebarRefreshBlocked: Bool {
        sidebarEditing || sidebarDestructiveActionPending
            || isDeletingProject || isRenamingSession || isRenamingProject
            || isMovingSession || isSwitchingActiveProfile || !mutatingSessionIDs.isEmpty
    }

    func sidebarRefreshStateChanged() {
        guard isSidebarDirty, !sidebarRefreshBlocked else { return }
        scheduleSidebarRefresh()
    }

    private func establishGatewayObservation(generation: Int) async {
        guard gatewayObservationEnabled, generation == gatewayObservationGeneration else { return }

        let runtime: HermesServerRuntime
        if let observedGatewayRuntime, gatewayObserverID != nil {
            runtime = observedGatewayRuntime
        } else {
            guard let resolved = try? await gatewayRuntimeProvider(client),
                  gatewayObservationEnabled,
                  generation == gatewayObservationGeneration,
                  resolved.origin == server
            else { return }

            runtime = resolved
            observedGatewayRuntime = runtime
            gatewayObserverID = runtime.observe(event: { [weak self] event in
                guard let self, self.gatewayObservationGeneration == generation else { return }
                self.receiveGatewayEvent(event)
            }, recover: { _ in }, ready: { [weak self] in
                guard let self, self.gatewayObservationEnabled,
                      self.gatewayObservationGeneration == generation else { return }
                self.isSidebarDirty = true
                self.scheduleSidebarRefresh()
            })
        }

        do {
            try await runtime.connect()
            guard gatewayObservationEnabled, generation == gatewayObservationGeneration else { return }
        } catch {
            guard gatewayObservationEnabled, generation == gatewayObservationGeneration else { return }
            // The shared runtime owns reconnect policy. Keep the observer so a
            // later explicit start can retry connection without another socket.
        }
    }

    private func receiveGatewayEvent(_ event: HermesGatewayEvent) {
        guard event.method == "event", event.type == "sessions.changed" else { return }
        isSidebarDirty = true
        scheduleSidebarRefresh()
    }

    private func scheduleSidebarRefresh() {
        guard isSidebarDirty, !sidebarRefreshBlocked else { return }
        sidebarRefreshTask?.cancel()
        let observationGeneration = gatewayObservationGeneration
        sidebarRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self,
                      self.gatewayObservationGeneration == observationGeneration,
                      self.isSidebarDirty,
                      !self.sidebarRefreshBlocked,
                      !self.isLoading
                else { return }

                self.sidebarRefreshTask = nil
                self.isSidebarDirty = false
                let refreshed = await self.load()
                guard self.gatewayObservationEnabled,
                      self.gatewayObservationGeneration == observationGeneration
                else { return }
                if !refreshed {
                    self.isSidebarDirty = true
                }
            } catch {
                // Cancellation is the normal debounce path. A failed refresh
                // leaves the dirty bit set for the next safe transition/event.
                if let self, !Task.isCancelled {
                    self.sidebarRefreshTask = nil
                    self.isSidebarDirty = true
                }
            }
        }
    }
}
