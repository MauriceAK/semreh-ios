import Foundation
import Observation

struct VoiceDraftContext: Equatable, Sendable {
    let sessionID: String?
    let hostGeneration: UUID
    let selectionGeneration: UUID
}

enum VoiceFailure: Error, LocalizedError, Equatable {
    case unsupported
    case unsupportedLanguage
    case microphoneDenied
    case downloadRequired(String)
    case assetsUnavailable
    case assetCapacity
    case audioUnavailable
    case interrupted
    case noSpeech
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .unsupported: "On-device dictation needs iOS 26 and a supported iPhone. You can still use keyboard dictation."
        case .unsupportedLanguage: "On-device dictation is not available for your current language. You can still type or use keyboard dictation."
        case .microphoneDenied: "Microphone access is off. Enable it for Hermes Companion in Settings to dictate."
        case .downloadRequired(let language): "Download the \(language) speech model to dictate on this iPhone. Audio stays on your device."
        case .assetsUnavailable: "The speech model could not be prepared. Check your internet connection and available storage, then try again. Your draft is safe."
        case .assetCapacity: "This app has reached the on-device speech language limit. Use a language already prepared for this app, or use keyboard dictation."
        case .audioUnavailable: "The microphone is unavailable. Check your audio connection and try again. Your draft is safe."
        case .interrupted: "Dictation stopped when audio was interrupted. Your draft is unchanged."
        case .noSpeech: "No speech was recognized. Your draft is unchanged."
        case .recognitionFailed: "Dictation could not finish. Your draft is unchanged. Try again when you are ready."
        }
    }
}

enum VoicePhase: Equatable {
    case idle, preparing, needsDownload(String), downloading(Double), recording, transcribing, failed(VoiceFailure)

    var isActive: Bool {
        switch self {
        case .preparing, .downloading, .recording, .transcribing: true
        default: false
        }
    }
}

enum VoiceEngineEvent: Sendable {
    case downloading(Double)
    case level(Float)
    case interrupted
    case failed
}

@MainActor
protocol VoiceEngine: AnyObject {
    func prepare(allowDownload: Bool, events: @escaping @MainActor @Sendable (VoiceEngineEvent) -> Void) async throws
    func start() async throws
    func finish() async throws -> String
    func cancel()
}

@MainActor @Observable
final class VoiceDictationController {
    private(set) var phase: VoicePhase = .idle
    private(set) var levels = Array(repeating: Float(0), count: 32)
    private struct Attempt {
        let id: UUID
        let context: VoiceDraftContext
        let engine: any VoiceEngine
    }
    private var attempt: Attempt?
    private var work: Task<Void, Never>?
    private let makeEngine: @MainActor () -> any VoiceEngine
    var isActive: Bool { phase.isActive }

    init(makeEngine: @escaping @MainActor () -> any VoiceEngine = VoiceDictationController.productionEngine) {
        self.makeEngine = makeEngine
    }

    static func productionEngine() -> any VoiceEngine {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--fixture"), let index = args.firstIndex(of: "--voice-fixture"), args.indices.contains(index + 1) {
            return FixtureVoiceEngine(scenario: args[index + 1])
        }
        #endif
        if #available(iOS 26.0, *) { return AppleVoiceEngine() }
        return UnsupportedVoiceEngine()
    }

    func begin(context: VoiceDraftContext, allowDownload: Bool = false) {
        guard !isActive else { return }
        cancel()
        let current = Attempt(id: UUID(), context: context, engine: makeEngine())
        attempt = current
        phase = .preparing
        levels = Array(repeating: 0, count: 32)
        work = Task { [weak self] in
            do {
                try await current.engine.prepare(allowDownload: allowDownload) { [weak self] event in
                    self?.receive(event, id: current.id)
                }
                try Task.checkCancellation()
                guard self?.attempt?.id == current.id else { return }
                try await current.engine.start()
                try Task.checkCancellation()
                guard self?.attempt?.id == current.id else { return }
                self?.phase = .recording
            } catch {
                guard self?.attempt?.id == current.id else { return }
                self?.fail(error as? VoiceFailure ?? .recognitionFailed)
            }
        }
    }

    func finish(currentContext: @escaping @MainActor () -> VoiceDraftContext,
                insert: @escaping @MainActor (String) -> Void) {
        guard phase == .recording, let current = attempt else { return }
        phase = .transcribing
        work = Task { [weak self] in
            do {
                let result = try await current.engine.finish().trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard let self, self.attempt?.id == current.id else { return }
                guard currentContext() == current.context else { self.cancel(); return }
                guard !result.isEmpty else { self.fail(.noSpeech); return }
                self.cancel()
                insert(result)
            } catch {
                guard self?.attempt?.id == current.id else { return }
                self?.fail(error as? VoiceFailure ?? .recognitionFailed)
            }
        }
    }

    func contextChanged(_ context: VoiceDraftContext) {
        if let attempt, attempt.context != context { cancel() }
    }

    func cancel() {
        let previous = attempt
        attempt = nil
        work?.cancel()
        work = nil
        phase = .idle
        previous?.engine.cancel()
    }

    func interrupted() {
        guard isActive else { return }
        fail(.interrupted)
    }

    private func receive(_ event: VoiceEngineEvent, id: UUID) {
        guard attempt?.id == id else { return }
        switch event {
        case .downloading(let value): phase = .downloading(min(max(value, 0), 1))
        case .level(let value):
            guard phase == .recording else { return }
            levels.removeFirst()
            levels.append(min(max(value, 0), 1))
        case .interrupted: interrupted()
        case .failed: fail(.recognitionFailed)
        }
    }

    private func fail(_ failure: VoiceFailure) {
        cancel()
        if case .downloadRequired(let language) = failure { phase = .needsDownload(language) }
        else { phase = .failed(failure) }
    }

    static func appending(_ text: String, to draft: String) -> String {
        guard !draft.isEmpty else { return text }
        return draft + (draft.last?.isWhitespace == true ? "" : " ") + text
    }

    isolated deinit {
        work?.cancel()
        attempt?.engine.cancel()
    }
}

@MainActor
private final class UnsupportedVoiceEngine: VoiceEngine {
    func prepare(allowDownload: Bool, events: @escaping @MainActor @Sendable (VoiceEngineEvent) -> Void) async throws { throw VoiceFailure.unsupported }
    func start() async throws { throw VoiceFailure.unsupported }
    func finish() async throws -> String { throw VoiceFailure.unsupported }
    func cancel() {}
}

#if DEBUG
@MainActor
private final class FixtureVoiceEngine: VoiceEngine {
    private let scenario: String
    private var events: (@MainActor @Sendable (VoiceEngineEvent) -> Void)?
    private var meter: Task<Void, Never>?
    private var heldFinalization: CheckedContinuation<String, Error>?
    init(scenario: String) { self.scenario = scenario }
    func prepare(allowDownload: Bool, events: @escaping @MainActor @Sendable (VoiceEngineEvent) -> Void) async throws {
        self.events = events
        if scenario == "denied" { throw VoiceFailure.microphoneDenied }
        if scenario == "unsupported" { throw VoiceFailure.unsupported }
        if scenario == "download" || scenario == "offline" || scenario == "instant-offline" {
            guard allowDownload else { throw VoiceFailure.downloadRequired("English") }
            if scenario == "instant-offline" { throw VoiceFailure.assetsUnavailable }
            events(.downloading(0.25))
            try await Task.sleep(for: .milliseconds(450))
            if scenario == "offline" { throw VoiceFailure.assetsUnavailable }
            events(.downloading(1))
        }
    }
    func start() async throws {
        meter = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.events?(.level([Float(0.15), 0.4, 0.9, 0.5, 0.2][index % 5]))
                index += 1
            }
        }
    }
    func finish() async throws -> String {
        meter?.cancel()
        try Task.checkCancellation()
        if scenario == "held-finalization" {
            return try await withCheckedThrowingContinuation { heldFinalization = $0 }
        }
        try await Task.sleep(for: .milliseconds(400))
        return scenario == "silence" ? "" : "A dictated thought ready to edit."
    }
    func cancel() {
        meter?.cancel()
        meter = nil
        events = nil
        let pending = heldFinalization
        heldFinalization = nil
        pending?.resume(throwing: CancellationError())
    }
}
#endif
