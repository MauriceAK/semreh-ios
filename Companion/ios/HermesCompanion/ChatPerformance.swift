import Foundation
import CoreFoundation
import QuartzCore
import UIKit
import os

@MainActor
final class ChatPerformance: NSObject {
    static let shared = ChatPerformance()

    enum Work: String, Codable, Sendable {
        case draftPersistence, socketDecode, deltaFlush, transcriptUpdate, markdownLayout
        case sendReceipt, historyFetch, latestFetch, latestJump, scroll, draftChangeToNextDisplayCallback, deltaQueuedToLayout, latestRequestToLayout
        case latestWindowReadyToLayout, transcriptPublication, markdownApply, markdownBatchWait

        fileprivate var signpostName: StaticString {
            switch self {
            case .draftPersistence: "Draft persistence"
            case .socketDecode: "Socket decode"
            case .deltaFlush: "Delta flush"
            case .transcriptUpdate: "Transcript update"
            case .markdownLayout: "Markdown layout"
            case .sendReceipt: "Send receipt"
            case .historyFetch: "History fetch"
            case .latestFetch: "Latest fetch"
            case .latestJump: "Latest jump"
            case .scroll: "Chat scroll"
            case .draftChangeToNextDisplayCallback: "Draft to callback"
            case .deltaQueuedToLayout: "Delta to layout"
            case .latestRequestToLayout: "Latest to layout"
            case .latestWindowReadyToLayout: "Latest ready to layout"
            case .transcriptPublication: "Transcript publication"
            case .markdownApply: "Markdown apply"
            case .markdownBatchWait: "Markdown batch wait"
            }
        }
    }

    enum Milestone: String, Codable, Sendable {
        case draftChanged, deltaQueued, transcriptLaidOut, latestRequested
        case latestWindowReady, latestViewportMoved, latestJumpCompleted, latestCancelled, latestJumpCancelled
        case sendAction, sendProjected, sendRowLaidOut, sendEntranceCompleted
        case workingFooterLaidOut, workingFooterAlreadyLaidOut
        case conversationSelected, conversationCacheReady, conversationSnapshotReady, conversationLaidOut
    }

    enum Outcome: String, Codable, Sendable { case completed, failed, cancelled }

    enum Stage: String, Codable, Sendable {
        case projection, diffPreparation, heightMeasurement, cellConfiguration, textPreparation, textAssignment
        case tableReload, tableReloadRows, tableBatch, updateLayout, chromeLayout, sizingLayout, anchorLayout, initialLayout
        case chrome, viewportCorrection
    }

    enum Counter: String, Codable, Sendable {
        case projectionCanonicalRows, projectionOutboundRows, projectionResultRows, changedRows
        case heightCacheHits, heightCacheMisses, renderedCacheHits, renderedCacheMisses
        case textAssignedUTF8Bytes, textAppendedUTF8Bytes, chromeChanges
        case deltaQueuedItems, deltaAppliedItems, deltaAppliedUTF8Bytes
        case deltaIgnoredItems, deltaIgnoredUTF8Bytes
    }

    struct StageToken {
        fileprivate let stage: Stage
        fileprivate let publication: Int
        fileprivate let start: Double
        fileprivate let count: Int
    }

    struct StageSample: Codable, Sendable {
        let publication: Int
        let stage: Stage
        var invocations: Int
        var count: Int
        var totalSeconds: Double
        var maximumSeconds: Double
    }

    struct CounterSample: Codable, Sendable {
        let publication: Int
        let counter: Counter
        var count: Int
    }

    struct Token: Sendable {
        fileprivate let id: Int
    }

    struct Span: Codable, Sendable {
        let id: Int
        let work: Work
        let start: Double
        let end: Double
        let count: Int
        let outcome: Outcome
    }

    struct Event: Codable, Sendable {
        let milestone: Milestone
        let time: Double
        let count: Int
        let attempt: Int?
    }

    struct Frame: Codable, Sendable {
        let segment: Int
        let callback: Double
        let timestamp: Double
        let targetTimestamp: Double
        let scrolling: Bool
    }

    struct Snapshot: Codable, Sendable {
        let schema: Int
        let runID: String
        let label: String
        let configuration: String
        let bundleVersion: String
        let bundleShortVersion: String
        let os: String
        let model: String
        let simulator: Bool
        let screenMaximumFramesPerSecond: Int
        let displayLinkPolicy: String
        let startedAt: String
        let duration: Double
        let thermalStateAtStart: Int
        let thermalStateAtEnd: Int
        let lowPowerModeAtStart: Bool
        let lowPowerModeAtEnd: Bool
        let spans: [Span]
        let events: [Event]
        let frames: [Frame]
        let stagesEnabled: Bool
        let stageSamples: [StageSample]
        let counterSamples: [CounterSample]
        let unfinishedSpans: Int
        let droppedRecords: Int
        let invalidOperations: Int
        let finishReason: String
    }

    private struct Pending {
        let work: Work
        let start: Double
        var count: Int
        let signpost: OSSignpostIntervalState
    }

    private let signposter = OSSignposter(subsystem: "org.hermescompanion.performance", category: .pointsOfInterest)
    private let logger = Logger(subsystem: "org.hermescompanion.performance", category: "export")
    private let limit = 30_000
    private let runID = UUID().uuidString
    private let origin = CACurrentMediaTime()
    private let startedAt = ISO8601DateFormatter().string(from: Date())
    private let initialThermal = ProcessInfo.processInfo.thermalState.rawValue
    private let initialLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private let label: String
    private let controlID: String?
    private var enabled: Bool
    private var link: CADisplayLink?
    private var backgroundSuspended = false
    private var frameSegment = 0
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var spans: [Span] = []
    private var events: [Event] = []
    private var frames: [Frame] = []
    private var draftTokens: [Token] = []
    private var deltaToken: Token?
    private var latestToken: Token?
    private var latestLocalToken: Token?
    private var latestAwaitingWindow = false
    private var droppedRecords = 0
    private var invalidOperations = 0
    private let stagesEnabled: Bool
    private var publication = 0
    private struct StageKey: Hashable { let publication: Int; let stage: Stage }
    private struct CounterKey: Hashable { let publication: Int; let counter: Counter }
    private var stageTotals: [StageKey: StageSample] = [:]
    private var counterTotals: [CounterKey: CounterSample] = [:]
    private var nextAttempt = 0
    private struct SendAttempt { let ordinal: Int; let sessionID: String; var milestones: Set<Milestone> = [] }
    private var sendAttempts: [String: SendAttempt] = [:]
    private var workingFooterInViewport = false
    private var presentedSessionID: String?
    private var conversation: (sessionID: String, ordinal: Int, milestones: Set<Milestone>)?
    var isRecording: Bool { enabled }

    private override init() {
        let arguments = ProcessInfo.processInfo.arguments
        enabled = arguments.contains("--chat-performance")
        stagesEnabled = arguments.contains("--chat-performance-stages")
        let suppliedLabel = Self.argument("--chat-performance-label", in: arguments) ?? "unlabeled"
        label = String(suppliedLabel.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(64))
        controlID = Self.argument("--chat-performance-control", in: arguments).flatMap(UUID.init(uuidString:))?.uuidString
        super.init()
        guard enabled else { return }
        spans.reserveCapacity(2_000)
        events.reserveCapacity(2_000)
        frames.reserveCapacity(12_000)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foregrounded), name: UIApplication.didBecomeActiveNotification, object: nil)
        if let controlID {
            let name = "org.hermescompanion.performance.finish." + controlID
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
                Task { @MainActor in ChatPerformance.shared.finish(reason: "controlled") }
            }, name as CFString, nil, .deliverImmediately)
        }
        if let durationText = Self.argument("--chat-performance-duration", in: arguments),
           let duration = Double(durationText), duration.isFinite, (1...600).contains(duration) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                self?.finish(reason: "duration")
            }
        }
    }

    private static func argument(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    func begin(_ work: Work, count: Int = 1) -> Token? {
        guard enabled else { return nil }
        guard count >= 0, pending.count < 128, reserveRecord() else { invalidOperations += 1; return nil }
        nextID += 1
        let state = work == .scroll
            ? signposter.beginAnimationInterval(work.signpostName, id: signposter.makeSignpostID())
            : signposter.beginInterval(work.signpostName, id: signposter.makeSignpostID())
        pending[nextID] = Pending(work: work, start: CACurrentMediaTime() - origin, count: count, signpost: state)
        if work == .transcriptPublication { publication = nextID }
        if observesFrames(work) { ensureDisplayLink() }
        return Token(id: nextID)
    }

    func end(_ token: Token?, outcome: Outcome = .completed, count: Int? = nil) {
        guard enabled, let token else { return }
        guard let value = pending.removeValue(forKey: token.id) else { invalidOperations += 1; return }
        let end = CACurrentMediaTime() - origin
        signposter.endInterval(value.work.signpostName, value.signpost)
        let workCount = count ?? value.count
        guard workCount >= 0 else { invalidOperations += 1; return }
        spans.append(Span(id: token.id, work: value.work, start: value.start, end: end, count: workCount, outcome: outcome))
        if value.work == .transcriptPublication { publication = 0 }
        if !pending.values.contains(where: { observesFrames($0.work) }) { link?.isPaused = true }
    }

    func mark(_ milestone: Milestone, count: Int = 1, attempt: Int? = nil) {
        guard enabled else { return }
        guard count >= 0, reserveRecord() else { invalidOperations += 1; return }
        events.append(Event(milestone: milestone, time: CACurrentMediaTime() - origin, count: count, attempt: attempt))
        switch milestone {
        case .draftChanged:
            if let token = begin(.draftChangeToNextDisplayCallback, count: count) { draftTokens.append(token) }
        case .deltaQueued:
            if let deltaToken, var value = pending[deltaToken.id] {
                value.count += count
                pending[deltaToken.id] = value
            } else { deltaToken = begin(.deltaQueuedToLayout, count: count) }
        case .latestRequested:
            end(latestToken, outcome: .cancelled)
            end(latestLocalToken, outcome: .cancelled)
            latestLocalToken = nil
            latestToken = begin(.latestRequestToLayout, count: count)
            latestAwaitingWindow = true
        case .latestWindowReady:
            latestAwaitingWindow = false
            end(latestLocalToken, outcome: .cancelled)
            latestLocalToken = begin(.latestWindowReadyToLayout, count: count)
        case .latestCancelled:
            end(latestToken, outcome: .cancelled)
            end(latestLocalToken, outcome: .cancelled)
            latestLocalToken = nil
            latestToken = nil
            latestAwaitingWindow = false
        case .latestViewportMoved, .latestJumpCompleted, .latestJumpCancelled,
             .sendAction, .sendProjected, .sendRowLaidOut, .sendEntranceCompleted,
             .workingFooterLaidOut, .workingFooterAlreadyLaidOut,
             .conversationSelected, .conversationCacheReady, .conversationSnapshotReady, .conversationLaidOut:
            break
        case .transcriptLaidOut:
            end(deltaToken)
            deltaToken = nil
            if !latestAwaitingWindow {
                end(latestToken)
                latestToken = nil
                end(latestLocalToken)
                latestLocalToken = nil
            }
        }
    }

    func beginStage(_ stage: Stage, count: @autoclosure () -> Int = 1) -> StageToken? {
        guard enabled, stagesEnabled else { return nil }
        return StageToken(stage: stage, publication: publication, start: CACurrentMediaTime(), count: count())
    }

    func endStage(_ token: StageToken?) {
        guard enabled, let token else { return }
        let duration = CACurrentMediaTime() - token.start
        guard token.count >= 0 else { invalidOperations += 1; return }
        let key = StageKey(publication: token.publication, stage: token.stage)
        if var sample = stageTotals[key] {
            sample.invocations += 1
            sample.count += token.count
            sample.totalSeconds += duration
            sample.maximumSeconds = max(sample.maximumSeconds, duration)
            stageTotals[key] = sample
        } else if reserveRecord() {
            stageTotals[key] = StageSample(publication: token.publication, stage: token.stage, invocations: 1,
                                          count: token.count, totalSeconds: duration, maximumSeconds: duration)
        }
    }

    func measure<T>(_ stage: Stage, count: @autoclosure () -> Int = 1, _ body: () throws -> T) rethrows -> T {
        let token = beginStage(stage, count: count())
        defer { endStage(token) }
        return try body()
    }

    func add(_ counter: Counter, count: @autoclosure () -> Int = 1) {
        guard enabled else { return }
        let value = count()
        guard value >= 0 else { invalidOperations += 1; return }
        let key = CounterKey(publication: publication, counter: counter)
        if var sample = counterTotals[key] { sample.count += value; counterTotals[key] = sample }
        else if reserveRecord() { counterTotals[key] = CounterSample(publication: publication, counter: counter, count: value) }
    }

    func beginSend(operationID: String, sessionID: String) {
        guard enabled else { return }
        guard sendAttempts.count < 128 else { droppedRecords += 1; return }
        nextAttempt += 1
        sendAttempts[operationID.lowercased()] = SendAttempt(ordinal: nextAttempt, sessionID: sessionID)
        markSend(.sendAction, operationID: operationID)
        if workingFooterInViewport && presentedSessionID == sessionID { markSend(.workingFooterAlreadyLaidOut, operationID: operationID) }
    }

    func markSend(_ milestone: Milestone, operationID: String, count: Int = 1) {
        guard enabled, var attempt = sendAttempts[operationID.lowercased()], attempt.milestones.insert(milestone).inserted else { return }
        sendAttempts[operationID.lowercased()] = attempt
        mark(milestone, count: count, attempt: attempt.ordinal)
    }

    func projected(_ messages: [ChatMessage]) {
        guard enabled else { return }
        for message in messages {
            if let operationID = message.operationId { markSend(.sendProjected, operationID: operationID) }
        }
    }

    func selectConversation(_ sessionID: String) {
        guard enabled else { return }
        nextAttempt += 1
        conversation = (sessionID, nextAttempt, [])
        markConversation(.conversationSelected, sessionID: sessionID)
    }

    func markConversation(_ milestone: Milestone, sessionID: String, count: Int = 1) {
        guard enabled, var conversation, conversation.sessionID == sessionID,
              conversation.milestones.insert(milestone).inserted else { return }
        self.conversation = conversation
        mark(milestone, count: count, attempt: conversation.ordinal)
    }

    func laidOut(_ messages: [ChatMessage], visibleRows: [Int], sessionID: String?, workingFooterVisible: Bool) {
        guard enabled else { return }
        for row in visibleRows where messages.indices.contains(row) {
            if let operationID = messages[row].operationId { markSend(.sendRowLaidOut, operationID: operationID) }
        }
        if let sessionID, !visibleRows.isEmpty { markConversation(.conversationLaidOut, sessionID: sessionID, count: visibleRows.count) }
        workingFooterInViewport = workingFooterVisible
        presentedSessionID = sessionID
        if workingFooterVisible {
            for (operationID, attempt) in sendAttempts where attempt.sessionID == sessionID && !attempt.milestones.contains(.workingFooterAlreadyLaidOut) {
                markSend(.workingFooterLaidOut, operationID: operationID)
            }
        }
    }

    func finish() { finish(reason: "explicit") }

    @objc private func backgrounded() {
        guard controlID != nil else { finish(reason: "backgrounded"); return }
        backgroundSuspended = true
        link?.isPaused = true
    }

    @objc private func foregrounded() {
        guard enabled, backgroundSuspended else { return }
        backgroundSuspended = false
        if pending.values.contains(where: { observesFrames($0.work) }) { ensureDisplayLink() }
    }

    private func finish(reason: String) {
        guard enabled else { return }
        enabled = false
        if let controlID {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil,
                CFNotificationName(rawValue: ("org.hermescompanion.performance.finish." + controlID) as CFString), nil)
        }
        link?.invalidate()
        link = nil
        for value in pending.values { signposter.endInterval(value.work.signpostName, value.signpost) }
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        let snapshot = Snapshot(
            schema: 2, runID: runID, label: label, configuration: configuration,
            bundleVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            bundleShortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            os: UIDevice.current.systemVersion, model: UIDevice.current.model, simulator: simulator,
            screenMaximumFramesPerSecond: UIScreen.main.maximumFramesPerSecond,
            displayLinkPolicy: "default-adaptive; callback diagnostics only; not presented frames",
            startedAt: startedAt, duration: CACurrentMediaTime() - origin,
            thermalStateAtStart: initialThermal, thermalStateAtEnd: ProcessInfo.processInfo.thermalState.rawValue,
            lowPowerModeAtStart: initialLowPower, lowPowerModeAtEnd: ProcessInfo.processInfo.isLowPowerModeEnabled,
            spans: spans, events: events, frames: frames, stagesEnabled: stagesEnabled,
            stageSamples: stageTotals.values.sorted { ($0.publication, $0.stage.rawValue) < ($1.publication, $1.stage.rawValue) },
            counterSamples: counterTotals.values.sorted { ($0.publication, $0.counter.rawValue) < ($1.publication, $1.counter.rawValue) },
            unfinishedSpans: pending.count,
            droppedRecords: droppedRecords, invalidOperations: invalidOperations, finishReason: reason
        )
        let logger = logger
        let controlID = controlID
        Task.detached(priority: .utility) {
            do {
                let directory = URL.cachesDirectory.appending(path: "ChatPerformance", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(snapshot).write(to: directory.appending(path: "latest.json"), options: .atomic)
                if let controlID {
                    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                        CFNotificationName(rawValue: ("org.hermescompanion.performance.exported." + controlID) as CFString), nil, nil, true)
                }
                logger.notice("Chat performance diagnostic export complete")
            } catch { logger.error("Chat performance diagnostic export failed") }
        }
    }

    private func reserveRecord() -> Bool {
        guard spans.count + events.count + frames.count + pending.count + stageTotals.count + counterTotals.count < limit else { droppedRecords += 1; return false }
        return true
    }

    private func ensureDisplayLink() {
        guard !backgroundSuspended else { return }
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        if link?.isPaused != false || frameSegment == 0 { frameSegment += 1 }
        link?.isPaused = false
    }

    private func observesFrames(_ work: Work) -> Bool {
        [.scroll, .latestJump, .draftChangeToNextDisplayCallback, .deltaQueuedToLayout, .latestRequestToLayout].contains(work)
    }

    @objc private func tick(_ sender: CADisplayLink) {
        let callback = CACurrentMediaTime()
        if reserveRecord() {
            frames.append(Frame(segment: frameSegment, callback: callback - origin, timestamp: sender.timestamp - origin,
                                targetTimestamp: sender.targetTimestamp - origin,
                                scrolling: pending.values.contains { $0.work == .scroll }))
        }
        let drafts = draftTokens
        draftTokens.removeAll(keepingCapacity: true)
        for token in drafts { end(token) }
    }
}
