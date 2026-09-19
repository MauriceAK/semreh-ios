import Foundation

extension KanbanFeatureState {
    func startLiveUpdatesIfReady() {
        guard isVisible, sceneIsActive, snapshot != nil, selectedBoardSlug != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        startStream()
    }

    func startStream() {
        guard isVisible, sceneIsActive, let board = selectedBoardSlug else { return }
        streamAttemptID += 1
        let attemptID = streamAttemptID
        let generation = liveGeneration
        let url = directKanbanEventsURL(board: board, since: liveCursor)
        streamClient.start(
            url: url,
            onFrame: { [weak self] frame in
                self?.handleStreamFrame(
                    frame,
                    board: board,
                    generation: generation,
                    attemptID: attemptID
                )
            },
            onFailure: { [weak self] in
                self?.handleStreamFailure(
                    board: board,
                    generation: generation,
                    attemptID: attemptID
                )
            }
        )
    }

    func handleStreamFrame(
        _ frame: KanbanStreamFrame,
        board: String,
        generation: Int,
        attemptID: Int
    ) {
        guard isCurrentLiveWork(board: board, generation: generation), streamAttemptID == attemptID else { return }
        switch frame {
        case .connected:
            // Stock WebSocket sends no synthetic hello/cursor. Connection
            // readiness resets retry state without inventing board progress.
            streamFailureCount = 0
            liveUpdatesDelayed = false
        case let .events(events, cursor, frameID):
            guard (frameID == nil || frameID == cursor),
                  events.allSatisfy({ event in
                      guard let eventID = event.eventID else { return false }
                      return eventID <= cursor
                  }) else {
                handleStreamFailure(board: board, generation: generation, attemptID: attemptID)
                return
            }
            guard cursor > liveCursor else { return }
            liveCursor = cursor
            scheduleCoalescedReconciliation(board: board, generation: generation)
        case .malformed:
            handleStreamFailure(board: board, generation: generation, attemptID: attemptID)
        case .hello:
            // Compatibility-only frame for the local lab/older fixtures.
            // Stock WebSocket health is established exclusively by .connected.
            break
        case .ignored:
            break
        }
    }

    func handleStreamFailure(board: String, generation: Int, attemptID: Int) {
        guard isCurrentLiveWork(board: board, generation: generation), streamAttemptID == attemptID else { return }
        streamAttemptID += 1 // Makes duplicate callbacks from this attempt inert.
        streamClient.stop()
        streamFailureCount += 1
        if streamFailureCount >= timing.failuresBeforePolling {
            liveUpdatesDelayed = true
            startPollingIfNeeded()
            return
        }

        let reconnectDelays = timing.reconnectDelays.isEmpty ? [.seconds(1)] : timing.reconnectDelays
        let delayIndex = min(streamFailureCount - 1, reconnectDelays.count - 1)
        let delay = reconnectDelays[delayIndex]
        let sleep = self.sleep
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, self.isCurrentLiveWork(board: board, generation: generation) else { return }
            self.startStream()
        }
    }

    func scheduleCoalescedReconciliation(board: String, generation: Int) {
        let sleep = self.sleep
        let delay = timing.coalescingDelay
        coalescingTask?.cancel()
        coalescingTask = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, self.isCurrentLiveWork(board: board, generation: generation) else { return }
            let succeeded = await self.refreshBoard(usingCursor: false, refreshSupplementary: true)
            guard self.isCurrentLiveWork(board: board, generation: generation) else { return }
            if !succeeded, self.isOffline { self.startPollingIfNeeded() }
        }
    }

    func startPollingIfNeeded() {
        guard pollingTask == nil, isVisible, sceneIsActive, let board = selectedBoardSlug else { return }
        streamClient.stop()
        reconnectTask?.cancel()
        reconnectTask = nil
        let generation = liveGeneration
        let sleep = self.sleep
        let interval = timing.pollingInterval
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard let self, self.isCurrentLiveWork(board: board, generation: generation) else { return }
                await self.pollBoardSnapshot(board: board, generation: generation)
            }
        }
    }

    func pollBoardSnapshot(board: String, generation: Int) async {
        guard isCurrentLiveWork(board: board, generation: generation) else { return }
        let wasOffline = isOffline
        let succeeded = await refreshBoard(usingCursor: false, refreshSupplementary: true)
        guard isCurrentLiveWork(board: board, generation: generation) else { return }
        if succeeded {
            loadedDetailIsStale = false
            if wasOffline { retryLiveStream() }
        }
    }

    func directKanbanEventsURL(board: String, since: Int) -> URL {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            return server
        }
        components.path = "/api/plugins/kanban/events"
        components.queryItems = [
            URLQueryItem(name: "board", value: board),
            URLQueryItem(name: "since", value: String(since)),
        ]
        return components.url ?? server
    }

    func retryLiveStream() {
        guard isVisible, sceneIsActive else { return }
        pollingTask?.cancel()
        pollingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        streamFailureCount = 0
        startStream()
    }

    func suspendLiveUpdates() {
        liveGeneration += 1
        activeBoardLoadID = UUID()
        streamClient.stop()
        reconnectTask?.cancel()
        reconnectTask = nil
        coalescingTask?.cancel()
        coalescingTask = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    func resetLiveUpdates(clearCursor: Bool) {
        suspendLiveUpdates()
        streamFailureCount = 0
        liveUpdatesDelayed = false
        isOffline = false
        loadedDetailIsStale = false
        if clearCursor { liveCursor = 0 }
    }

    func isCurrentLiveWork(board: String, generation: Int) -> Bool {
        isSameLiveGeneration(board: board, generation: generation)
            && isVisible
            && sceneIsActive
    }

    func isSameLiveGeneration(board: String, generation: Int) -> Bool {
        generation == liveGeneration
            && selectedBoardSlug == board
            && !Task.isCancelled
    }

    func markOfflineIfNeeded(_ error: Error) {
        guard snapshot != nil else { return }
        if let apiError = error as? APIError, case .network = apiError {
            isOffline = true
            loadedDetailIsStale = true
        }
    }
}
