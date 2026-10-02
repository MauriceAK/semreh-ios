import Foundation
import Observation

/// Client-side composer drafts, keyed by server + session.
///
/// ChatView owns `@State draftMessage`, so leave/reopen and process death
/// used to wipe whatever Jacob had typed. This store is the durable copy.
@MainActor
@Observable
final class ComposerDraftStore {
    static let shared = ComposerDraftStore()

    static let visibilityKeyPrefix = "semreh.composerDraft."
    private static let localDraftKeyPrefix = "semreh.localComposerDrafts."

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private var registeredLocalDrafts: [String: LocalDraft] = [:]
    @ObservationIgnored
    private var retiredLocalDraftKeys: Set<String> = []
    @ObservationIgnored
    private var retiredLocalDraftDestinations: [String: String] = [:]
    private var localDraftRevision = 0
    private static let configurationKeyPrefix = "semreh.composerConfiguration."
    @ObservationIgnored private var lastWriterGenerations: [String: Int] = [:]
    @ObservationIgnored private var retiredConfigurations: [String: LocalDraft] = [:]
    @ObservationIgnored private var writers: [String: WriterLease] = [:]
    @ObservationIgnored private var writeRevisions: [String: Int] = [:]
    @ObservationIgnored private var configurationRevisions: [String: Int] = [:]
    @ObservationIgnored private var nextWriterGeneration = 0
    @ObservationIgnored private var writerTexts: [String: String] = [:]
    private(set) var failedSubmissionRevision = 0
    private var failureRestorations: [String: FailureRestoration] = [:]

    private struct FailureRestoration {
        let notificationRevision: Int
        let textRevision: Int
    }

    struct WriterLease: Equatable {
        let owner: UUID
        let generation: Int
    }

    struct SubmissionCheckpoint {
        fileprivate let originalKey: String
        fileprivate let revision: Int
    }

    struct StreamingSubmission {
        fileprivate let writer: WriterLease
        fileprivate let checkpoint: SubmissionCheckpoint
        fileprivate let text: String
        fileprivate let configuration: [String?]
        fileprivate let configurationRevision: Int
        fileprivate let configurationMutation: Int
    }

    /// Claim only at presentation boundaries. Persistence callbacks never claim.
    func claimWriter(server: URL, sessionID: String, owner: UUID) -> WriterLease {
        let key = resolvedKey(server: server, sessionID: sessionID)
        if let current = writers[key], current.owner == owner { return current }
        nextWriterGeneration &+= 1
        let lease = WriterLease(owner: owner, generation: nextWriterGeneration)
        writers[key] = lease
        lastWriterGenerations[key] = lease.generation
        writerTexts[key] = load(server: server, sessionID: sessionID)
        return lease
    }

    func ownsWriter(_ writer: WriterLease, server: URL, sessionID: String) -> Bool {
        writers[resolvedKey(server: server, sessionID: sessionID)] == writer
    }

    func releaseWriter(_ writer: WriterLease, server: URL, sessionID: String) {
        let key = resolvedKey(server: server, sessionID: sessionID)
        guard writers[key] == writer else { return }
        writers.removeValue(forKey: key)
    }

    /// Protect even edits whose debounced durable write has not fired yet.
    func noteWriterEdit(_ text: String, writer: WriterLease, server: URL, sessionID: String) {
        guard ownsWriter(writer, server: server, sessionID: sessionID) else { return }
        let key = resolvedKey(server: server, sessionID: sessionID)
        guard writerTexts[key] != text else { return }
        writerTexts[key] = text
        writeRevisions[key, default: 0] &+= 1
    }

    @discardableResult
    func save(_ text: String, configuration: SessionSummary, server: URL,
              sessionID: String, writer: WriterLease) -> Bool {
        guard ownsWriter(writer, server: server, sessionID: sessionID) else { return false }
        // Failure restoration protects text edits/clears, not configuration-only
        // refreshes. Keep the latest options while restoring a definitely rejected turn.
        if let canonicalID = retiredLocalDraftDestinations[key(server: server, sessionID: sessionID)] {
            persistConfiguration(configuration, server: server, sessionID: canonicalID)
        } else if configuration.localDraftID != nil, configuration.sessionId == nil {
            registerLocalDraft(configuration, server: server)
        } else {
            persistConfiguration(configuration, server: server, sessionID: sessionID)
        }
        save(text, server: server, sessionID: sessionID)
        return true
    }

    func submissionCheckpoint(server: URL, sessionID: String, writer: WriterLease) -> SubmissionCheckpoint? {
        guard ownsWriter(writer, server: server, sessionID: sessionID) else { return nil }
        return SubmissionCheckpoint(originalKey: key(server: server, sessionID: sessionID), revision: writeRevisions[resolvedKey(server: server, sessionID: sessionID), default: 0])
    }

    /// Keep configuration changes separate from ordinary-send failure restoration.
    func noteWriterConfigurationEdit(writer: WriterLease, server: URL, sessionID: String) {
        guard ownsWriter(writer, server: server, sessionID: sessionID) else { return }
        configurationRevisions[resolvedKey(server: server, sessionID: sessionID), default: 0] &+= 1
    }

    /// Streaming sends retain their submitted text until acceptance is known.
    func beginStreamingSubmission(_ text: String, configuration: SessionSummary,
                                  server: URL, sessionID: String, writer: WriterLease,
                                  configurationMutation: Int = 0) -> StreamingSubmission? {
        guard save(text, configuration: configuration, server: server, sessionID: sessionID, writer: writer),
              let checkpoint = submissionCheckpoint(server: server, sessionID: sessionID, writer: writer) else { return nil }
        return StreamingSubmission(writer: writer, checkpoint: checkpoint, text: text,
            configuration: Self.streamingConfiguration(configuration),
            configurationRevision: configurationRevisions[resolvedKey(server: server, sessionID: sessionID), default: 0],
            configurationMutation: configurationMutation)
    }

    /// Main-actor atomic settlement: return true only when the mounted composer
    /// may clear. Stale owners cannot persist or consume a replacement's draft.
    @discardableResult
    func settleStreamingSubmission(_ submission: StreamingSubmission, accepted: Bool,
                                   currentText: String, configuration: SessionSummary,
                                   server: URL, sessionID: String,
                                   configurationMutation: Int = 0) -> Bool {
        guard submission.checkpoint.originalKey == key(server: server, sessionID: sessionID),
              ownsWriter(submission.writer, server: server, sessionID: sessionID) else { return false }
        // Also catch an edit whose SwiftUI observation callback has not run yet.
        noteWriterEdit(currentText, writer: submission.writer, server: server, sessionID: sessionID)
        let key = resolvedKey(server: server, sessionID: sessionID)
        let consumesDraft = accepted && currentText == submission.text
            && writeRevisions[key, default: 0] == submission.checkpoint.revision
            && configurationRevisions[key, default: 0] == submission.configurationRevision
            && configurationMutation == submission.configurationMutation
            && Self.streamingConfiguration(configuration) == submission.configuration
        save(consumesDraft ? "" : currentText, configuration: configuration,
            server: server, sessionID: sessionID, writer: submission.writer)
        return consumesDraft
    }

    private static func streamingConfiguration(_ session: SessionSummary) -> [String?] {
        [session.sessionId, session.localDraftID, session.profile, session.model,
         session.modelProvider, session.workspace, session.reasoningEffort]
    }

    /// A definite rejection may restore an untouched empty composer after Back,
    /// but cannot erase any intervening edit or write from a replacement owner.
    @discardableResult
    func restoreFailedSubmission(_ text: String, checkpoint: SubmissionCheckpoint,
                                 server: URL, sessionID: String) -> Bool {
        let key = resolvedKey(server: server, sessionID: sessionID)
        let expectedKey = retiredLocalDraftDestinations[checkpoint.originalKey]
            .map { self.key(server: server, sessionID: $0) } ?? checkpoint.originalKey
        guard key == expectedKey, writeRevisions[key, default: 0] == checkpoint.revision,
              load(server: server, sessionID: sessionID).isEmpty else { return false }
        save(text, server: server, sessionID: sessionID)
        failedSubmissionRevision &+= 1
        failureRestorations[key] = FailureRestoration(
            notificationRevision: failedSubmissionRevision,
            textRevision: writeRevisions[key, default: 0])
        return true
    }

    /// Observe only this exact origin/conversation, not another chat's failure.
    func failureRestorationRevision(server: URL, sessionID: String) -> Int {
        failureRestorations[resolvedKey(server: server, sessionID: sessionID)]?.notificationRevision ?? 0
    }

    /// A pending edit/clear after restoration must win even before persistence.
    func failureRestorationDraft(server: URL, sessionID: String, writer: WriterLease) -> String? {
        guard ownsWriter(writer, server: server, sessionID: sessionID) else { return nil }
        let key = resolvedKey(server: server, sessionID: sessionID)
        guard let restoration = failureRestorations[key],
              restoration.textRevision == writeRevisions[key, default: 0] else { return nil }
        return load(server: server, sessionID: sessionID)
    }

    func savedConfiguration(server: URL, sessionID: String) -> SessionSummary? {
        let resolvedID = retiredLocalDraftDestinations[key(server: server, sessionID: sessionID)] ?? sessionID
        let local = localDrafts(server: server).first { $0.id == resolvedID }
            ?? registeredLocalDrafts[key(server: server, sessionID: resolvedID)]
        let persisted = defaults.data(forKey: configurationKey(server: server, sessionID: resolvedID))
            .flatMap { try? JSONDecoder().decode(LocalDraft.self, from: $0) }
        guard let draft = local ?? persisted else { return nil }
        return SessionSummary(sessionId: local == nil ? resolvedID : nil,
            localDraftID: local == nil ? nil : draft.id,
            title: "New Chat", workspace: draft.workspace, model: draft.model,
            modelProvider: draft.modelProvider, reasoningEffort: draft.reasoningEffort,
            createdAt: draft.createdAt, updatedAt: draft.updatedAt, profile: draft.profile)
    }

    private func resolvedKey(server: URL, sessionID: String) -> String {
        key(server: server, sessionID: retiredLocalDraftDestinations[key(server: server, sessionID: sessionID)] ?? sessionID)
    }

    private func configurationKey(server: URL, sessionID: String) -> String {
        Self.configurationKeyPrefix + key(server: server, sessionID: sessionID)
    }

    private func persistConfiguration(_ session: SessionSummary, server: URL, sessionID: String) {
        let payload = LocalDraft(id: sessionID, profile: session.profile, createdAt: session.createdAt,
            updatedAt: session.updatedAt, text: load(server: server, sessionID: sessionID), model: session.model,
            modelProvider: session.modelProvider, workspace: session.workspace,
            reasoningEffort: session.reasoningEffort)
        defaults.set(try? JSONEncoder().encode(payload), forKey: configurationKey(server: server, sessionID: sessionID))
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(server: URL, sessionID: String) -> String {
        if let canonicalID = retiredLocalDraftDestinations[key(server: server, sessionID: sessionID)] {
            // One hop only: canonical wire identity is not another local alias.
            return canonicalText(server: server, sessionID: canonicalID)
        }
        if let draft = localDrafts(server: server).first(where: { $0.id == sessionID }) {
            return Self.restorableDraft(draft.text ?? "")
        }
        return canonicalText(server: server, sessionID: sessionID)
    }

    private func canonicalText(server: URL, sessionID: String) -> String {
        let payload = defaults.data(forKey: configurationKey(server: server, sessionID: sessionID))
            .flatMap { try? JSONDecoder().decode(LocalDraft.self, from: $0) }
        return Self.restorableDraft(payload?.text
            ?? defaults.string(forKey: key(server: server, sessionID: sessionID)) ?? "")
    }

    private func updateCanonicalText(_ text: String, server: URL, sessionID: String) {
        let payloadKey = configurationKey(server: server, sessionID: sessionID)
        guard let data = defaults.data(forKey: payloadKey),
              var payload = try? JSONDecoder().decode(LocalDraft.self, from: data) else { return }
        payload.text = Self.restorableDraft(text)
        payload.updatedAt = Date().timeIntervalSince1970
        defaults.set(try? JSONEncoder().encode(payload), forKey: payloadKey)
    }

    func save(_ draft: String, server: URL, sessionID: String) {
        let resolvedKey = resolvedKey(server: server, sessionID: sessionID)
        if Self.restorableDraft(draft) != load(server: server, sessionID: sessionID) {
            writeRevisions[resolvedKey, default: 0] &+= 1
        }
        writerTexts[resolvedKey] = draft
        let key = key(server: server, sessionID: sessionID)
        if let canonicalID = retiredLocalDraftDestinations[key] {
            let canonicalKey = self.key(server: server, sessionID: canonicalID)
            updateCanonicalText(draft, server: server, sessionID: canonicalID)
            let restorable = Self.restorableDraft(draft)
            if restorable.isEmpty { defaults.removeObject(forKey: canonicalKey) }
            else { defaults.set(restorable, forKey: canonicalKey) }
            return
        }
        updateCanonicalText(draft, server: server, sessionID: sessionID)
        let restorable = Self.restorableDraft(draft)
        if restorable.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(restorable, forKey: key)
        }
        var drafts = localDrafts(server: server)
        let registered = registeredLocalDrafts[key] ?? drafts.first { $0.id == sessionID }
        drafts.removeAll { $0.id == sessionID }
        if var registered {
            // Retain registration across the pre-await clear so a definite send
            // failure can restore this exact local conversation.
            registeredLocalDrafts[key] = registered
            if !restorable.isEmpty {
                registered.text = restorable
                registered.updatedAt = Date().timeIntervalSince1970
                drafts.append(registered)
            }
            persistLocalDrafts(drafts, server: server)
        }
    }

    func clear(server: URL, sessionID: String) {
        save("", server: server, sessionID: sessionID)
    }

    /// A successful first send retires local-list identity permanently for this
    /// store lifetime. Unlike a pre-await clear, subsequent typing must not
    /// resurrect a standalone New Chat row for a now server-backed conversation.
    /// The send owner must call this only after deciding to consume the draft.
    func retireLocalDraft(server: URL, sessionID: String, canonicalSessionID: String? = nil) {
        let localKey = key(server: server, sessionID: sessionID)
        let configuration = localDrafts(server: server).first { $0.id == sessionID }
            ?? registeredLocalDrafts[localKey] ?? retiredConfigurations[localKey]
        if let configuration { retiredConfigurations[localKey] = configuration }
        retiredLocalDraftKeys.insert(localKey)
        registeredLocalDrafts.removeValue(forKey: localKey)
        if retiredLocalDraftDestinations[localKey] == nil,
           let canonicalSessionID, !canonicalSessionID.isEmpty, canonicalSessionID != sessionID {
            let canonicalKey = key(server: server, sessionID: canonicalSessionID)
            let localWriter = writers[localKey]
            let canonicalIsNewer = lastWriterGenerations[canonicalKey, default: -1]
                > lastWriterGenerations[localKey, default: -1]
            // Migrate the current stored payload, never the old send task's state.
            let pendingText = load(server: server, sessionID: sessionID)
            retiredLocalDraftDestinations[localKey] = canonicalSessionID
            if !canonicalIsNewer {
                save(pendingText, server: server, sessionID: canonicalSessionID)
                if var configuration {
                    configuration.id = canonicalSessionID
                    configuration.text = pendingText
                    defaults.set(try? JSONEncoder().encode(configuration),
                        forKey: configurationKey(server: server, sessionID: canonicalSessionID))
                }
                if let localWriter { writers[canonicalKey] = localWriter }
                lastWriterGenerations[canonicalKey] = lastWriterGenerations[localKey]
                writerTexts[canonicalKey] = writerTexts[localKey] ?? pendingText
                writeRevisions[canonicalKey] = max(writeRevisions[canonicalKey, default: 0],
                    writeRevisions[localKey, default: 0])
                configurationRevisions[canonicalKey] = configurationRevisions[localKey]
            }
            writers.removeValue(forKey: localKey)
            retiredConfigurations.removeValue(forKey: localKey)
            defaults.removeObject(forKey: localKey)
        }
        var drafts = localDrafts(server: server)
        drafts.removeAll { $0.id == sessionID }
        persistLocalDrafts(drafts, server: server)
    }

    /// Registration alone never creates a persistent sidebar row. Only a
    /// nonempty composer saved by ChatView makes the conversation reachable.
    func registerLocalDraft(_ session: SessionSummary, server: URL) {
        guard session.sessionId == nil, let id = session.localDraftID,
              !retiredLocalDraftKeys.contains(key(server: server, sessionID: id)) else { return }
        registeredLocalDrafts[key(server: server, sessionID: id)] = LocalDraft(
            id: id, profile: session.profile, createdAt: session.createdAt,
            updatedAt: session.updatedAt, text: nil, model: session.model,
            modelProvider: session.modelProvider, workspace: session.workspace,
            reasoningEffort: session.reasoningEffort
        )
    }

    func reachableLocalDrafts(server: URL, profile: String) -> [SessionSummary] {
        _ = localDraftRevision // Observe saves/clears while the sidebar stays mounted.
        return localDrafts(server: server).compactMap { draft in
            guard let id = draft.id, !id.isEmpty, draft.profile == profile,
                  !Self.restorableDraft(draft.text ?? "").isEmpty else { return nil }
            return SessionSummary(
                localDraftID: id, title: "New Chat", workspace: draft.workspace,
                model: draft.model, modelProvider: draft.modelProvider,
                reasoningEffort: draft.reasoningEffort, createdAt: draft.createdAt,
                updatedAt: draft.updatedAt, profile: draft.profile
            )
        }
    }

    /// One origin-local index of unsent drafts, never a scan of transcript history
    /// or the entire defaults domain. Text, identity and configuration share one
    /// durable payload. Nil reasoning is the raw inherit override, never the
    /// profile's effective effort. Optional fields preserve older saved drafts.
    private struct LocalDraft: Codable {
        var id: String?
        var profile: String?
        var createdAt: Double?
        var updatedAt: Double?
        var text: String?
        var model: String?
        var modelProvider: String?
        var workspace: String?
        var reasoningEffort: String?
    }

    private func localDrafts(server: URL) -> [LocalDraft] {
        guard let data = defaults.data(forKey: localDraftKey(server: server)),
              let drafts = try? JSONDecoder().decode([LocalDraft].self, from: data)
        else { return [] }
        return drafts
    }

    private func persistLocalDrafts(_ drafts: [LocalDraft], server: URL) {
        let key = localDraftKey(server: server)
        if drafts.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(drafts) {
            defaults.set(data, forKey: key)
        }
        localDraftRevision &+= 1
    }

    private func localDraftKey(server: URL) -> String {
        Self.localDraftKeyPrefix + server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func resetForTesting() {
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(Self.visibilityKeyPrefix) || key.hasPrefix(Self.localDraftKeyPrefix) || key.hasPrefix(Self.configurationKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        writers.removeAll()
        lastWriterGenerations.removeAll()
        retiredConfigurations.removeAll()
        writeRevisions.removeAll()
        configurationRevisions.removeAll()
        writerTexts.removeAll()
        failedSubmissionRevision = 0
        failureRestorations.removeAll()
        nextWriterGeneration = 0
        registeredLocalDrafts.removeAll()
        retiredLocalDraftKeys.removeAll()
        retiredLocalDraftDestinations.removeAll()
        localDraftRevision &+= 1
    }

    static func resolvedDraft(initialDraft: String, storedDraft: String) -> String {
        let initial = initialDraft
        if !initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return initial
        }
        return restorableDraft(storedDraft)
    }

    private static func restorableDraft(_ draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : draft
    }

    private func key(server: URL, sessionID: String) -> String {
        let serverKey = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sessionKey = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(Self.visibilityKeyPrefix)\(serverKey)|\(sessionKey)"
    }
}

struct TranscriptRestorePoint: Equatable {
    var followingLatest: Bool
    var visibleMessageID: String?

    static let followingLatest = TranscriptRestorePoint(followingLatest: true, visibleMessageID: nil)
}

@MainActor
final class TranscriptRestoreStore {
    static let shared = TranscriptRestoreStore()
    static let visibilityKeyPrefix = "semreh.transcriptRestore."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(server: URL, sessionID: String) -> TranscriptRestorePoint {
        guard let data = defaults.data(forKey: key(server: server, sessionID: sessionID)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .followingLatest
        }
        return TranscriptRestorePoint(
            followingLatest: payload.followingLatest,
            visibleMessageID: payload.visibleMessageID
        )
    }

    func save(_ point: TranscriptRestorePoint, server: URL, sessionID: String) {
        let key = key(server: server, sessionID: sessionID)
        if point.followingLatest {
            defaults.removeObject(forKey: key)
            return
        }
        let payload = Payload(followingLatest: false, visibleMessageID: point.visibleMessageID)
        defaults.set(try? JSONEncoder().encode(payload), forKey: key)
    }

    func resetForTesting() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.visibilityKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private struct Payload: Codable {
        var followingLatest: Bool
        var visibleMessageID: String?
    }

    private func key(server: URL, sessionID: String) -> String {
        let serverKey = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sessionKey = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(Self.visibilityKeyPrefix)\(serverKey)|\(sessionKey)"
    }
}

struct LiveRunBookmark: Equatable, Codable {
    var streamID: String
    var lastEventID: String?
    var liveReasoningText: String
    var streamingAssistantMessageID: String?
    var liveToolCalls: [ToolCall]

    init(
        streamID: String,
        lastEventID: String?,
        liveReasoningText: String,
        streamingAssistantMessageID: String?,
        liveToolCalls: [ToolCall] = []
    ) {
        self.streamID = streamID
        self.lastEventID = lastEventID
        self.liveReasoningText = liveReasoningText
        self.streamingAssistantMessageID = streamingAssistantMessageID
        self.liveToolCalls = liveToolCalls
    }

    private enum CodingKeys: String, CodingKey {
        case streamID
        case lastEventID
        case liveReasoningText
        case streamingAssistantMessageID
        case liveToolCalls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try container.decode(String.self, forKey: .streamID)
        lastEventID = try container.decodeIfPresent(String.self, forKey: .lastEventID)
        liveReasoningText = try container.decodeIfPresent(String.self, forKey: .liveReasoningText) ?? ""
        streamingAssistantMessageID = try container.decodeIfPresent(String.self, forKey: .streamingAssistantMessageID)
        liveToolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .liveToolCalls) ?? []
    }
}

@MainActor
final class LiveRunBookmarkStore {
    static let shared = LiveRunBookmarkStore()
    static let visibilityKeyPrefix = "semreh.liveRunBookmark."
    static let maxReasoningCharacters = 8_192

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(server: URL, sessionID: String) -> LiveRunBookmark? {
        guard let data = defaults.data(forKey: key(server: server, sessionID: sessionID)) else {
            return nil
        }
        return try? JSONDecoder().decode(LiveRunBookmark.self, from: data)
    }

    func save(_ bookmark: LiveRunBookmark, server: URL, sessionID: String) {
        var trimmed = bookmark
        if trimmed.liveReasoningText.count > Self.maxReasoningCharacters {
            trimmed.liveReasoningText = String(trimmed.liveReasoningText.suffix(Self.maxReasoningCharacters))
        }
        defaults.set(try? JSONEncoder().encode(trimmed), forKey: key(server: server, sessionID: sessionID))
    }

    func remove(server: URL, sessionID: String) {
        defaults.removeObject(forKey: key(server: server, sessionID: sessionID))
    }

    func resetForTesting() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.visibilityKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func key(server: URL, sessionID: String) -> String {
        let serverKey = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sessionKey = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(Self.visibilityKeyPrefix)\(serverKey)|\(sessionKey)"
    }
}
