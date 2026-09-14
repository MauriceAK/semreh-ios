import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

private final class DirectDestructiveTransport: HermesGatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var prompts: [JSONValue] = []
    private let promptStatus: String

    init(promptStatus: String = "streaming") {
        self.promptStatus = promptStatus
    }

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        lock.withLock { self.sink = sink }
    }
    func promptParams() -> [JSONValue] { lock.withLock { prompts } }
    func resetPrompts() { lock.withLock { prompts.removeAll() } }
    func connect() async throws {}
    func close() async {}
    func connectionIdentifier() async -> Int? { 1 }
    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        switch method {
        case "session.resume":
            return .object(["session_id": .string("runtime-existing"), "session_key": .string("durable-1"), "running": .bool(false)])
        case "session.status":
            return .object(["output": .string("Agent Running: No")])
        case "prompt.submit":
            if let params { lock.withLock { prompts.append(params) } }
            return .object(["status": .string(promptStatus)])
        default:
            throw DirectSessionError.invalidResponse
        }
    }
}

final class ChatViewModelSendTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testOpeningSessionDoesNotCreateSpeechSynthesizer() throws {
        var createdSynthesizers = 0

        _ = try makeViewModel(
            speechSynthesizerFactory: {
                createdSynthesizers += 1
                return SpySpeechSynthesizer()
            }
        ) { request in
            XCTFail("Opening a session should not request network work in this test.")
            return apiTestJSONResponse("{}", for: request)
        }

        XCTAssertEqual(createdSynthesizers, 0)
    }

    @MainActor
    func testListenCreatesSpeechSynthesizerOnlyWhenRequested() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        var createdSynthesizers = 0
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: {
                createdSynthesizers += 1
                return speechSynthesizer
            }
        ) { request in
            // Listen now prefers server TTS (#15); refuse it so the on-device
            // fallback path is what creates the synthesizer.
            XCTAssertEqual(request.url?.path, "/api/audio/speak")
            return Self.ttsUnavailableResponse(for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Playback should be explicit.",
                timestamp: 1_770_000_001,
                messageId: "assistant-1"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-1")
        await viewModel.listenPreparationTask?.value

        XCTAssertEqual(createdSynthesizers, 1)
        XCTAssertEqual(speechSynthesizer.spokenStrings, ["Playback should be explicit."])
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-1")
    }

    func testListenAudioSessionRoutesToSpeakerNotEarpiece() {
        // `.playback` forces the speaker (not the receiver/earpiece) by default, and
        // `.spokenAudio` is Apple's recommended mode for synthesized speech. #252.
        XCTAssertEqual(ListenAudioSessionConfiguration.category, .playback)
        XCTAssertEqual(ListenAudioSessionConfiguration.mode, .spokenAudio)
        XCTAssertTrue(
            ListenAudioSessionConfiguration.deactivationOptions.contains(.notifyOthersOnDeactivation)
        )
    }

    @MainActor
    func testListenActivatesAudioSessionBeforeSpeaking() async throws {
        let recorder = ListenCallRecorder()
        let speechSynthesizer = SpySpeechSynthesizer(recorder: recorder)
        let audioSession = SpyListenAudioSession(recorder: recorder)
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            listenAudioSession: audioSession
        ) { request in
            Self.ttsUnavailableResponse(for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Out loud, please.",
                timestamp: 1_770_000_002,
                messageId: "assistant-2"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        // Regression (review on #35): the tap itself must NOT activate the session —
        // a slow `/api/audio/speak` fetch would otherwise silence other audio while Semreh
        // has nothing to play. Activation belongs to the moment playback starts.
        XCTAssertEqual(audioSession.activateCount, 0)
        await viewModel.listenPreparationTask?.value

        XCTAssertEqual(audioSession.activateCount, 1)
        XCTAssertEqual(speechSynthesizer.spokenStrings, ["Out loud, please."])
        // Prove activate precedes speak on a single interleaved timeline shared by both
        // spies (the audio session and the synthesizer), so the "before speaking" claim
        // is provable rather than relying on two independent logs (review on #332).
        let activateIndex = try XCTUnwrap(recorder.events.firstIndex(of: "activate"))
        let speakIndex = try XCTUnwrap(recorder.events.firstIndex(of: "speak"))
        XCTAssertLessThan(activateIndex, speakIndex)
    }

    @MainActor
    func testStaleCancelAfterSwitchingMessagesKeepsNewListenActive() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        let audioSession = SpyListenAudioSession()
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            listenAudioSession: audioSession
        ) { request in
            Self.ttsUnavailableResponse(for: request)
        }
        func makeContext(_ id: String, _ text: String, _ timestamp: Double) throws -> MessageActionContext {
            try XCTUnwrap(MessageActionContext(
                message: ChatMessage(role: "assistant", content: text, timestamp: timestamp, messageId: id),
                visibleIndex: 0,
                messagesOffset: 0
            ))
        }

        // Start listening to A, then switch to B while A is still "speaking".
        viewModel.toggleListening(to: try makeContext("assistant-A", "First message.", 1_770_000_010))
        await viewModel.listenPreparationTask?.value
        let utteranceA = try XCTUnwrap(speechSynthesizer.spokenUtterances.first)
        viewModel.toggleListening(to: try makeContext("assistant-B", "Second message.", 1_770_000_011))
        await viewModel.listenPreparationTask?.value

        XCTAssertEqual(viewModel.listeningMessageID, "assistant-B")
        let deactivationsBeforeStaleCallback = audioSession.deactivateCount

        // A's cancel callback now arrives late, after B has started speaking. It must be
        // ignored so it can't clear B's "now playing" state or deactivate the session.
        speechSynthesizer.fireDidCancel(utteranceA)
        await drainMainActor()

        XCTAssertEqual(viewModel.listeningMessageID, "assistant-B")
        XCTAssertEqual(audioSession.deactivateCount, deactivationsBeforeStaleCallback)

        // A matching completion (for the live utterance B) still tears down cleanly.
        let utteranceB = try XCTUnwrap(speechSynthesizer.spokenUtterances.last)
        speechSynthesizer.fireDidCancel(utteranceB)
        await drainMainActor()

        XCTAssertNil(viewModel.listeningMessageID)
        XCTAssertEqual(audioSession.deactivateCount, deactivationsBeforeStaleCallback + 1)
    }

    @MainActor
    func testStoppingListeningReleasesAudioSession() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        let audioSession = SpyListenAudioSession()
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            listenAudioSession: audioSession
        ) { request in
            Self.ttsUnavailableResponse(for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Stop me cleanly.",
                timestamp: 1_770_000_003,
                messageId: "assistant-3"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await viewModel.listenPreparationTask?.value
        let deactivationsAfterStart = audioSession.deactivateCount

        viewModel.stopListening()

        XCTAssertGreaterThan(audioSession.deactivateCount, deactivationsAfterStart)
        XCTAssertNil(viewModel.listeningMessageID)
    }

    @MainActor
    func testListenPrefersServerTTSAndPlaysReturnedAudio() async throws {
        let audioSession = SpyListenAudioSession()
        let remoteControlCenter = SpyListenRemoteControlCenter()
        let userDefaults = try makeEphemeralUserDefaults()
        let player = SpyListenAudioPlayer()
        player.duration = 83
        var receivedAudioData: [Data] = []
        var createdSynthesizers = 0
        let serverAudio = Data([0xFF, 0xF3, 0x18, 0xC4])
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: {
                createdSynthesizers += 1
                return SpySpeechSynthesizer()
            },
            listenAudioSession: audioSession,
            listenRemoteControlCenter: remoteControlCenter,
            serverTTSAudioPlayerFactory: { data in
                receivedAudioData.append(data)
                return player
            },
            userDefaults: userDefaults
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/audio/speak")
            guard let body = apiTestBodyData(from: request),
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                XCTFail("Missing TTS request body")
                throw URLError(.badServerResponse)
            }
            XCTAssertEqual(json["text"] as? String, "Neural, please.")
            XCTAssertEqual(Set(json.keys), ["text"])
            return try Self.ttsAudioResponse(serverAudio, for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Neural, please.",
                timestamp: 1_770_000_020,
                messageId: "assistant-20"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        XCTAssertTrue(viewModel.showsListenPlaybackBar)
        XCTAssertEqual(viewModel.listenPlaybackPhase, .loading)
        // Regression (review on #35): no session activation while the fetch is in
        // flight — only once decoded server audio is about to play.
        XCTAssertEqual(audioSession.activateCount, 0)
        await viewModel.listenPreparationTask?.value

        // Server audio plays; the on-device synthesizer is never touched.
        XCTAssertEqual(receivedAudioData, [serverAudio])
        XCTAssertEqual(player.prepareToPlayCount, 1)
        XCTAssertEqual(player.playCount, 1)
        XCTAssertEqual(player.rate, Float(1))
        XCTAssertEqual(createdSynthesizers, 0)
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-20")
        XCTAssertTrue(viewModel.showsListenPlaybackBar)
        XCTAssertEqual(viewModel.listenPlaybackPhase, .playing)
        XCTAssertEqual(viewModel.listenPlaybackDuration, 83)
        XCTAssertEqual(audioSession.activateCount, 1)
        XCTAssertEqual(remoteControlCenter.configureCount, 1)
        XCTAssertEqual(remoteControlCenter.snapshots.last, ListenNowPlayingSnapshot(
            title: "Semreh response 1",
            duration: 83,
            elapsedTime: 0,
            speed: .normal,
            isPlaying: true
        ))

        // Natural finish tears listen state down and releases the session. The
        // defensive stopListening() at the start of toggleListening also
        // deactivates once, so assert the finish-driven delta, not a total.
        let deactivationsBeforeFinish = audioSession.deactivateCount
        player.finishPlayback()
        XCTAssertNil(viewModel.listeningMessageID)
        XCTAssertFalse(viewModel.showsListenPlaybackBar)
        XCTAssertGreaterThan(audioSession.deactivateCount, deactivationsBeforeFinish)
    }

    @MainActor
    func testListenPlaybackCanPauseResumeSeekAndUseRemoteCommands() async throws {
        let player = SpyListenAudioPlayer()
        player.duration = 120
        let remoteControlCenter = SpyListenRemoteControlCenter()
        let viewModel = try makeViewModel(
            listenRemoteControlCenter: remoteControlCenter,
            serverTTSAudioPlayerFactory: { _ in player }
        ) { request in
            return try Self.ttsAudioResponse(Data([0xFF, 0xF3]), for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Give me controls.",
                timestamp: 1_770_000_025,
                messageId: "assistant-25"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await viewModel.listenPreparationTask?.value

        remoteControlCenter.firePause()
        XCTAssertEqual(player.pauseCount, 1)
        XCTAssertEqual(viewModel.listenPlaybackPhase, .paused)
        XCTAssertFalse(try XCTUnwrap(remoteControlCenter.snapshots.last).isPlaying)

        remoteControlCenter.firePlay()
        XCTAssertEqual(player.playCount, 2)
        XCTAssertEqual(viewModel.listenPlaybackPhase, .playing)
        XCTAssertTrue(try XCTUnwrap(remoteControlCenter.snapshots.last).isPlaying)

        remoteControlCenter.fireChangePlaybackPosition(37)
        XCTAssertEqual(player.currentTime, 37)
        XCTAssertEqual(viewModel.listenPlaybackElapsedTime, 37)

        viewModel.toggleListenPlaybackPlayPause()
        XCTAssertEqual(player.pauseCount, 2)
        XCTAssertEqual(viewModel.listenPlaybackPhase, .paused)

        remoteControlCenter.fireTogglePlayPause()
        XCTAssertEqual(player.playCount, 3)
        XCTAssertEqual(viewModel.listenPlaybackPhase, .playing)
    }

    @MainActor
    func testListenPlaybackResyncsProgressWhenSceneBecomesActive() async throws {
        let player = SpyListenAudioPlayer()
        player.duration = 90
        let remoteControlCenter = SpyListenRemoteControlCenter()
        let viewModel = try makeViewModel(
            listenRemoteControlCenter: remoteControlCenter,
            serverTTSAudioPlayerFactory: { _ in player }
        ) { request in
            return try Self.ttsAudioResponse(Data([0xFF, 0xF3]), for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Keep progress honest.",
                timestamp: 1_770_000_026,
                messageId: "assistant-26"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await viewModel.listenPreparationTask?.value
        XCTAssertEqual(viewModel.listenPlaybackElapsedTime, 0)
        let nowPlayingUpdatesAfterStart = remoteControlCenter.snapshots.count

        // Simulates background audio advancing while the foreground UI timer is not
        // firing. Returning to the scene must pull the latest player time into the bar.
        player.currentTime = 42
        viewModel.refreshListenPlaybackProgressAfterSceneActivation()

        XCTAssertEqual(viewModel.listenPlaybackElapsedTime, 42)
        XCTAssertEqual(viewModel.listenPlaybackDisplayTime, 42)
        XCTAssertEqual(remoteControlCenter.snapshots.count, nowPlayingUpdatesAfterStart)
    }

    @MainActor
    func testListenPlaybackSeekAndSpeedPersist() async throws {
        let userDefaults = try makeEphemeralUserDefaults()
        let player = SpyListenAudioPlayer()
        player.duration = 120
        let viewModel = try makeViewModel(
            serverTTSAudioPlayerFactory: { _ in player },
            userDefaults: userDefaults
        ) { request in
            return try Self.ttsAudioResponse(Data([0xFF, 0xF3]), for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Remember my speed.",
                timestamp: 1_770_000_026,
                messageId: "assistant-26"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await viewModel.listenPreparationTask?.value

        viewModel.scrubListenPlayback(to: 64)
        XCTAssertEqual(viewModel.listenPlaybackDisplayTime, 64)
        XCTAssertEqual(player.currentTime, 0)

        viewModel.setListenPlaybackScrubbing(false)
        XCTAssertEqual(player.currentTime, 64)
        XCTAssertEqual(viewModel.listenPlaybackElapsedTime, 64)
        XCTAssertNil(viewModel.listenPlaybackScrubTime)

        viewModel.setListenPlaybackSpeed(.oneAndHalf)
        XCTAssertEqual(player.rate, Float(1.5))
        XCTAssertEqual(userDefaults.double(forKey: ListenPlaybackSpeed.storageKey), 1.5)

        let reloadedViewModel = try makeViewModel(userDefaults: userDefaults) { request in
            XCTFail("Reading stored playback speed should not hit \(request.url?.path ?? "unknown path")")
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(reloadedViewModel.listenPlaybackSpeed, .oneAndHalf)
    }

    @MainActor
    func testStartingListenOnDifferentMessageStopsCurrentServerAudio() async throws {
        let firstPlayer = SpyListenAudioPlayer()
        let secondPlayer = SpyListenAudioPlayer()
        var players = [firstPlayer, secondPlayer]
        let viewModel = try makeViewModel(
            serverTTSAudioPlayerFactory: { _ in
                players.removeFirst()
            }
        ) { request in
            return try Self.ttsAudioResponse(Data([0xFF, 0xF3]), for: request)
        }
        func makeContext(_ id: String, text: String, visibleIndex: Int) throws -> MessageActionContext {
            try XCTUnwrap(MessageActionContext(
                message: ChatMessage(role: "assistant", content: text, timestamp: 1_770_000_030, messageId: id),
                visibleIndex: visibleIndex,
                messagesOffset: 0
            ))
        }

        viewModel.toggleListening(to: try makeContext("assistant-30", text: "First audio.", visibleIndex: 0))
        await viewModel.listenPreparationTask?.value
        viewModel.toggleListening(to: try makeContext("assistant-31", text: "Second audio.", visibleIndex: 1))
        await viewModel.listenPreparationTask?.value

        XCTAssertEqual(firstPlayer.stopCount, 1)
        XCTAssertEqual(secondPlayer.playCount, 1)
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-31")
        XCTAssertEqual(viewModel.listenPlaybackPhase, .playing)
    }

    @MainActor
    func testListenFallsBackToSynthesizerSilentlyWhenServerTTSFails() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        var playerFactoryCalls = 0
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            serverTTSAudioPlayerFactory: { _ in
                playerFactoryCalls += 1
                return SpyListenAudioPlayer()
            }
        ) { request in
            // A raw 429 from the ~2 s rate limit must never surface to the user.
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error": "rate limit exceeded — please wait"}"#.utf8))
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Fall back quietly.",
                timestamp: 1_770_000_021,
                messageId: "assistant-21"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await viewModel.listenPreparationTask?.value

        XCTAssertEqual(playerFactoryCalls, 0)
        XCTAssertEqual(speechSynthesizer.spokenStrings, ["Fall back quietly."])
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-21")
        // Silent fallback: no error alert for the user (#15).
        XCTAssertNil(viewModel.messageActionErrorMessage)
    }

    @MainActor
    func testListenFallsBackToSynthesizerWhenServerAudioIsUndecodable() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            serverTTSAudioPlayerFactory: { _ in
                throw URLError(.cannotDecodeContentData)
            }
        ) { request in
            return try Self.ttsAudioResponse(Data("not really audio".utf8), for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Bad bytes, good fallback.",
                timestamp: 1_770_000_022,
                messageId: "assistant-22"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        await viewModel.listenPreparationTask?.value

        XCTAssertEqual(speechSynthesizer.spokenStrings, ["Bad bytes, good fallback."])
        XCTAssertNil(viewModel.messageActionErrorMessage)
    }

    @MainActor
    func testListenOverServerLimitSkipsServerTTSEntirely() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer }
        ) { request in
            XCTFail("Text over the 5000-char cap must not hit /api/audio/speak.")
            return apiTestJSONResponse("{}", for: request)
        }
        let longText = String(repeating: "a", count: ServerTTSPolicy.maximumTextLength + 1)
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: longText,
                timestamp: 1_770_000_023,
                messageId: "assistant-23"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)

        // Straight to the on-device path — synchronous, no preparation task.
        XCTAssertNil(viewModel.listenPreparationTask)
        XCTAssertEqual(speechSynthesizer.spokenStrings, [longText])
        XCTAssertEqual(viewModel.listeningMessageID, "assistant-23")
    }

    @MainActor
    func testSecondTapWhileFetchingServerAudioStopsInsteadOfRestarting() async throws {
        let speechSynthesizer = SpySpeechSynthesizer()
        var playerFactoryCalls = 0
        var ttsRequests = 0
        let viewModel = try makeViewModel(
            speechSynthesizerFactory: { speechSynthesizer },
            serverTTSAudioPlayerFactory: { _ in
                playerFactoryCalls += 1
                return SpyListenAudioPlayer()
            }
        ) { request in
            ttsRequests += 1
            return try Self.ttsAudioResponse(Data([0xFF, 0xF3]), for: request)
        }
        let context = try XCTUnwrap(MessageActionContext(
            message: ChatMessage(
                role: "assistant",
                content: "Tap tap.",
                timestamp: 1_770_000_024,
                messageId: "assistant-24"
            ),
            visibleIndex: 0,
            messagesOffset: 0
        ))

        viewModel.toggleListening(to: context)
        let firstFetch = viewModel.listenPreparationTask
        // Second tap lands while the server fetch is still in flight: it must act
        // as "Stop Listening", not queue a second /api/audio/speak call (#15 double-tap).
        viewModel.toggleListening(to: context)

        XCTAssertNil(viewModel.listeningMessageID)
        XCTAssertNil(viewModel.listenPreparationTask)

        // Even if the first response completes after the stop, its stale request
        // ID must not start playback or speech.
        await firstFetch?.value
        XCTAssertEqual(playerFactoryCalls, 0)
        XCTAssertTrue(speechSynthesizer.spokenStrings.isEmpty)
        XCTAssertNil(viewModel.listeningMessageID)
        XCTAssertLessThanOrEqual(ttsRequests, 1)
    }

    func testServerTTSPolicyRoutesByClientTextCap() {
        XCTAssertTrue(ServerTTSPolicy.shouldUseServerTTS(for: String(repeating: "a", count: 5000)))
        XCTAssertFalse(ServerTTSPolicy.shouldUseServerTTS(for: String(repeating: "a", count: 5001)))
    }

    @MainActor
    func testChatMessageTextStillAppendsAttachedFilesSuffixForFileUploads() {
        // Guard: the voice-note path deliberately bypasses chatMessageText to send
        // the bare transcript (#330), but real file uploads from the text composer
        // MUST keep the "[Attached files: …]" suffix so the agent can inspect them.
        let file = PendingAttachment(
            name: "report.pdf",
            path: "/tmp/workspace/report.pdf",
            mime: "application/pdf",
            size: 1234,
            isImage: false,
            thumbnailData: nil
        )

        let text = PendingAttachment.chatMessageText(draft: "Summarize this", attachments: [file])

        XCTAssertEqual(text, "Summarize this\n\n[Attached files: /tmp/workspace/report.pdf]")
    }

    @MainActor
    func testDirectGoalMissingRunningProfileDoesNotStartLegacyKickoffOrPrompt() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel(directLoad: true) { request in
            requestedPaths.append(request.url?.path ?? "nil")
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.path == "/api/sessions/session-abc/messages" {
                return apiTestJSONResponse(#"{"session_id":"session-abc","messages":[],"pagination":{"limit":120,"offset":0,"order":"latest","returned":0}}"#, for: request)
            }
            guard request.url?.path == "/api/profiles/active" else {
                XCTFail("Profile-gated direct goal must not issue legacy requests")
                throw URLError(.badURL)
            }
            return apiTestJSONResponse(#"{"active":"default","current":null}"#, for: request)
        }
        let accepted = await viewModel.submitGoal(args: "Ship the TestFlight build")
        XCTAssertFalse(accepted)
        XCTAssertEqual(requestedPaths, ["/api/sessions/session-abc/messages", "/api/profiles/active"])
        XCTAssertEqual(viewModel.goalErrorMessage, "The chat or running Hermes profile changed, so the goal command was not sent.")
        XCTAssertNil(viewModel.currentGoal)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    @MainActor
    func testBareResumeSlashCommandFallsThroughToNormalSendPath() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "nil")

            switch path {
            case "/api/skills":
                return apiTestJSONResponse(#"{"skills": []}"#, for: request)
            case "/api/chat/start":
                XCTFail("Executor fallthrough should let ChatView perform the normal send later.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await SlashCommandExecutor.execute(text: "/resume", viewModel: viewModel)

        XCTAssertEqual(result, .unsupported(friendlyMessage: "Skills require a direct Hermes connection."))
        XCTAssertEqual(requestedPaths, [])
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testUnknownNonBlockedSlashCommandFallsThroughToNormalSendPath() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "nil")

            switch path {
            case "/api/skills":
                return apiTestJSONResponse(#"{"skills": []}"#, for: request)
            case "/api/chat/start":
                XCTFail("Executor fallthrough should let ChatView perform the normal send later.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await SlashCommandExecutor.execute(text: "/unknown-slash keep going", viewModel: viewModel)

        XCTAssertEqual(result, .unsupported(friendlyMessage: "Skills require a direct Hermes connection."))
        XCTAssertEqual(requestedPaths, [])
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testKnownUnsupportedSlashCommandStaysBlockedWithoutSkillLookup() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            requestedPaths.append(request.url?.path ?? "nil")
            XCTFail("Known unsupported commands should not request skills or start chat.")
            throw URLError(.badURL)
        }

        let result = await SlashCommandExecutor.execute(text: "/terminal", viewModel: viewModel)

        XCTAssertEqual(result, .unsupported(friendlyMessage: "Terminal is not available in the mobile app."))
        XCTAssertEqual(requestedPaths, [])
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testUnknownDirectSkillShortcutUsesScopedCatalogThenFallsThrough() async throws {
        let transport = SendRetirementDirectTransport()
        let server = URL(string: "https://example.test")!
        let runtime = try HermesServerRuntime(origin: server) { sink in
            transport.installSink(sink)
            return transport
        }
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/skills")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "profile" }?.value, "work")
            return apiTestJSONResponse("[]", for: request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let viewModel = ChatViewModel(session: SessionSummary(profile: "work"), server: server,
            client: client, gatewayRuntimeProvider: { _ in runtime })
        let result = await SlashCommandExecutor.execute(text: "/spotify check songs", viewModel: viewModel)
        XCTAssertEqual(result, .sendAsMessage)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(transport.methods().isEmpty)
        await runtime.stop()
    }

    @MainActor
    func testInitialLoadKeepsTheServerWindowBoundedWithoutRenderableExpansion() async throws {
        let viewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "limit" }?.value, "120")
            XCTAssertEqual(query?.first { $0.name == "offset" }?.value, "0")
            XCTAssertEqual(query?.first { $0.name == "profile" }?.value, "default")
            XCTAssertNil(query?.first { $0.name == "expand_renderable" })
            return try self.directLoadResponse(rows: (1...120).map { ["id": $0, "role": "user", "content": "Row \($0)"] }, for: request)
        }
        await viewModel.loadMessages()
        XCTAssertEqual(viewModel.messages.count, 120)
        XCTAssertEqual(viewModel.messages.first?.id, "1")
        XCTAssertEqual(viewModel.messages.last?.id, "120")
        XCTAssertTrue(viewModel.hasOlderMessages)
        XCTAssertEqual(viewModel.messagesOffset, 0)
    }






    @MainActor
    func testDirectAuthoritativeReloadReplacesUnconfirmedCachedPlaceholder() async throws {
        let context = try makeContext()
        try CacheStore.cacheMessages([ChatMessage(role: "user", content: "Unconfirmed old text",
            timestamp: 1, messageId: "local-old")], serverURL: URL(string: "https://example.test")!,
            sessionID: "direct:7:default:session-abc", in: context)
        let viewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            return try self.directLoadResponse(rows: [["id": 1, "role": "assistant", "content": "Authoritative row"]], for: request)
        }
        viewModel.prepareInitialMessageLoad(modelContext: context)
        XCTAssertEqual(viewModel.messages.first?.id, "local-old")
        await viewModel.loadMessages(modelContext: context)
        XCTAssertEqual(viewModel.messages.map(\.id), ["1"])
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Authoritative row"])
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(try CacheStore.cachedMessages(serverURL: URL(string: "https://example.test")!,
            sessionID: "direct:7:default:session-abc", in: context).map(\.id), ["1"])
    }

    @MainActor
    func testLoadMessagesUsesCachedTranscriptForTunnelUnavailableFailure() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let otherServerURL = try XCTUnwrap(URL(string: "https://other.example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "direct:7:default:session-abc",
            in: context
        )
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Wrong session", timestamp: 1_770_000_003, messageId: "wrong-session")
            ],
            serverURL: serverURL,
            sessionID: "other-session",
            in: context
        )
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Wrong server", timestamp: 1_770_000_004, messageId: "wrong-server")
            ],
            serverURL: otherServerURL,
            sessionID: "direct:7:default:session-abc",
            in: context
        )

        let viewModel = try makeViewModel(directLoad: true) { request in
            switch request.url?.path {
            case "/api/sessions/session-abc/messages":
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 502,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )
                return (try XCTUnwrap(response), Data("bad gateway".utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached question", "Cached answer"])
        XCTAssertEqual(viewModel.messagesOffset, 0)
        XCTAssertTrue(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertNil(viewModel.streamingAssistantMessageID)
        XCTAssertNil(viewModel.contextWindowSnapshot)
        XCTAssertTrue(viewModel.completedToolCallGroups.isEmpty)
        XCTAssertTrue(viewModel.completedToolCallGroupsForAnchor("cached-assistant").isEmpty)
        XCTAssertTrue(viewModel.completedToolCallGroupsForAnchor(nil).isEmpty)
        XCTAssertTrue(viewModel.completedReasoningGroups.isEmpty)
        XCTAssertTrue(viewModel.liveToolCalls.isEmpty)
        XCTAssertTrue(viewModel.liveReasoningText.isEmpty)
        XCTAssertTrue(viewModel.pinnedLocalNotices.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testLoadMessagesUsesCachedTranscriptForNetworkTimeout() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "direct:7:default:session-abc",
            in: context
        )

        let viewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            throw URLError(.timedOut)
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached question", "Cached answer"])
        XCTAssertTrue(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testLoadMessagesSurfacesTunnelUnavailableFailureWhenCacheIsEmpty() async throws {
        let context = try makeContext()
        let viewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 502,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )
            return (try XCTUnwrap(response), Data("bad gateway".utf8))
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(
            viewModel.errorMessage,
            DirectHermesRequestError.http(statusCode: 502, reason: .other).localizedDescription
        )
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testLoadMessagesDoesNotUseCachedTranscriptForRealServerError() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Stale cached answer", timestamp: 1_770_000_001, messageId: "stale")
            ],
            serverURL: serverURL,
            sessionID: "direct:7:default:session-abc",
            in: context
        )
        let viewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"boom"}"#.utf8))
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(viewModel.errorMessage, DirectHermesRequestError.http(statusCode: 500, reason: .other).localizedDescription)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testLoadMessagesDoesNotReplaceSuccessfulOnlineTranscriptWithStaleCache() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Stale cached answer", timestamp: 1_770_000_001, messageId: "stale")
            ],
            serverURL: serverURL,
            sessionID: "direct:7:default:session-abc",
            in: context
        )
        let viewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            return apiTestJSONResponse(#"{"session_id":"session-abc","messages":[{"role":"user","content":"Fresh question","timestamp":1770000100,"id":1},{"role":"assistant","content":"Fresh answer","timestamp":1770000101,"id":2}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}"#, for: request)
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh question", "Fresh answer"])
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: serverURL,
                sessionID: "direct:7:default:session-abc",
                in: context
            ).compactMap(\.content),
            ["Fresh question", "Fresh answer"]
        )
    }

    @MainActor
    func testLoadMessagesRendersCachedMessagesBeforeNetworkReconcile() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "direct:7:default:session-abc",
            in: context
        )

        let sessionRequestStarted = expectation(description: "session request started")
        let releaseSessionResponse = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            sessionRequestStarted.fulfill()
            XCTAssertEqual(releaseSessionResponse.wait(timeout: .now() + .seconds(5)), .success)
            return apiTestJSONResponse(#"{"session_id":"session-abc","messages":[{"role":"user","content":"Fresh question","timestamp":1770000100,"id":1},{"role":"assistant","content":"Fresh answer","timestamp":1770000101,"id":2}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}"#, for: request)
        }

        let loadTask = Task { @MainActor in
            await viewModel.loadMessages(modelContext: context)
        }
        defer { releaseSessionResponse.signal() }

        // While the network reload is still in flight, the cached transcript is
        // already on screen (no skeleton, since messages is non-empty) and the
        // offline indicator stays off because this is the success-expected window.
        await fulfillment(of: [sessionRequestStarted], timeout: 2)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached question", "Cached answer"])
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertFalse(viewModel.isViewingCachedData)

        releaseSessionResponse.signal()
        await loadTask.value

        // After the reload completes it reconciles in place to the fresh server content.
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh question", "Fresh answer"])
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testPrepareInitialMessageLoadPrimesCacheWithoutStartingNetwork() throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel { request in
            XCTFail("Cache preparation must not start a request: \(request.url?.absoluteString ?? "nil")")
            throw URLError(.badURL)
        }

        viewModel.prepareInitialMessageLoad(modelContext: context)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached question", "Cached answer"])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isViewingCachedData)
    }

    @MainActor
    func testDirectPreparedCacheLoadDropsStalePrefixAndUsesBackwardsPagination() async throws {
        let context = try makeContext()
        try CacheStore.cacheMessages([ChatMessage(role: "assistant", content: "Stale prefix",
            timestamp: 1, messageId: "stale-prefix")], serverURL: URL(string: "https://example.test")!,
            sessionID: "direct:7:default:session-abc", in: context)
        let viewModel = try makeViewModel(directLoad: true) { request in
            return try self.directLoadResponse(rows: (101...220).map { ["id": $0, "role": "user", "content": "Fresh \($0)"] }, for: request)
        }
        viewModel.prepareInitialMessageLoad(modelContext: context)
        XCTAssertEqual(viewModel.messages.first?.id, "stale-prefix")
        await viewModel.loadMessages(modelContext: context)
        XCTAssertEqual(viewModel.messages.first?.id, "101")
        XCTAssertEqual(viewModel.messages.count, 120)
        XCTAssertEqual(viewModel.messagesOffset, 0)
        XCTAssertTrue(viewModel.hasOlderMessages)
    }

    @MainActor
    func testPrepareInitialMessageLoadBoundsLargeCachedTranscriptToNewestPage() throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let cachedMessages = (0..<75).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Cached message \(index)",
                timestamp: Double(1_770_000_000 + index),
                messageId: "cached-\(index)"
            )
        }
        try CacheStore.cacheMessages(
            cachedMessages,
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel { request in
            XCTFail("Cache preparation must not start a request: \(request.url?.absoluteString ?? "nil")")
            throw URLError(.badURL)
        }

        viewModel.prepareInitialMessageLoad(modelContext: context)

        XCTAssertEqual(viewModel.messages.count, 50)
        XCTAssertEqual(viewModel.messages.first?.content, "Cached message 25")
        XCTAssertEqual(viewModel.messages.last?.content, "Cached message 74")
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isViewingCachedData)
    }

    @MainActor
    func testLoadMessagesKeepsTranscriptEmptyDuringNetworkWhenCacheIsEmpty() async throws {
        let context = try makeContext()

        let sessionRequestStarted = expectation(description: "session request started")
        let releaseSessionResponse = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            sessionRequestStarted.fulfill()
            XCTAssertEqual(releaseSessionResponse.wait(timeout: .now() + .seconds(5)), .success)
            return apiTestJSONResponse(#"{"session_id":"session-abc","messages":[{"role":"user","content":"Fresh question","timestamp":1770000100,"id":1}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":1}}"#, for: request)
        }

        let loadTask = Task { @MainActor in
            await viewModel.loadMessages(modelContext: context)
        }
        defer { releaseSessionResponse.signal() }

        // With no cache, nothing is painted before the network resolves, so the
        // first-open skeleton path (isLoading && messages.isEmpty) is preserved.
        await fulfillment(of: [sessionRequestStarted], timeout: 2)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.isLoading)

        releaseSessionResponse.signal()
        await loadTask.value

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh question"])
    }

    @MainActor
    func testCacheFirstReconcileBumpsScrollTokenForSmoothSettle() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "direct:7:default:session-abc",
            in: context
        )

        let viewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            return apiTestJSONResponse(#"{"session_id":"session-abc","messages":[{"role":"user","content":"Fresh question","timestamp":1770000100,"id":1},{"role":"assistant","content":"Fresh answer","timestamp":1770000101,"id":2}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}"#, for: request)
        }

        XCTAssertEqual(viewModel.cacheFirstReconcileScrollToken, 0)
        await viewModel.loadMessages(modelContext: context)

        // The cache-first reconcile fired exactly once so the view can snap back to the
        // bottom as the taller server transcript replaces the lighter cached render.
        XCTAssertEqual(viewModel.cacheFirstReconcileScrollToken, 1)
    }

    @MainActor
    func testColdOpenWithoutCacheDoesNotBumpReconcileScrollToken() async throws {
        let context = try makeContext()
        let viewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            return apiTestJSONResponse(#"{"session_id":"session-abc","messages":[{"role":"user","content":"Fresh question","timestamp":1770000100,"id":1}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":1}}"#, for: request)
        }

        await viewModel.loadMessages(modelContext: context)

        // No cache was rendered first, so there is nothing to re-pin and the token stays put.
        XCTAssertEqual(viewModel.cacheFirstReconcileScrollToken, 0)
    }

    @MainActor
    func testCacheFirstRevertPreservesMutatedPresentationOnDirectServerError() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "direct:7:default:session-abc",
            in: context
        )

        let sessionRequestStarted = expectation(description: "session request started")
        let releaseSessionResponse = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel(directLoad: true) { request in
            switch request.url?.path {
            case "/api/sessions/session-abc/messages":
                sessionRequestStarted.fulfill()
                XCTAssertEqual(releaseSessionResponse.wait(timeout: .now() + .seconds(5)), .success)
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"boom"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let loadTask = Task { @MainActor in
            await viewModel.loadMessages(modelContext: context)
        }
        defer { releaseSessionResponse.signal() }

        // Mutate only presentation while the real direct read is held. Actual
        // send supersession is separately covered by the held-load/send test.
        await fulfillment(of: [sessionRequestStarted], timeout: 2)
        viewModel.seedTranscriptForTesting(viewModel.messages + [ChatMessage(role: "user", content: "In-flight question", timestamp: 2, messageId: "local-pending")])
        try await waitUntil { viewModel.messages.compactMap(\.content).contains("In-flight question") }
        XCTAssertTrue(viewModel.messages.compactMap(\.content).contains("In-flight question"))

        // Now let the reload fail with a non-cacheable error: the cache-first revert
        // must NOT wipe the optimistic send made during the load window (#289, Codex P2).
        releaseSessionResponse.signal()
        await loadTask.value

        XCTAssertTrue(
            viewModel.messages.compactMap(\.content).contains("In-flight question"),
            "Optimistic send made during the cache-first window must survive a non-cacheable reload failure"
        )
    }

    @MainActor
    func testReloadDoesNotDuplicateCachedOptimisticAttachmentMessageWhenServerReturnsIt() async throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Summarize it",
                    timestamp: 1_770_000_000,
                    messageId: "local-attachment",
                    attachments: [
                        MessageAttachment(
                            name: "photo.png",
                            path: "/tmp/workspace/photo.png",
                            mime: "image/png",
                            size: 4,
                            isImage: true
                        )
                    ]
                )
            ],
            serverURL: serverURL,
            sessionID: "direct:7:default:session-abc",
            in: context
        )

        let reopenedViewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            return apiTestJSONResponse(#"{"session_id":"session-abc","messages":[{"role":"user","content":"Summarize it\n\n[Attached files: /tmp/workspace/photo.png]","timestamp":1770000001,"id":1},{"role":"assistant","content":"Recovered transcript.","timestamp":1770000100,"id":2}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}"#, for: request)
        }

        await reopenedViewModel.loadMessages(modelContext: context)

        XCTAssertEqual(reopenedViewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(reopenedViewModel.messages.first?.messageId, "1")
        XCTAssertEqual(reopenedViewModel.messages.filter { $0.role == "user" }.count, 1)
    }


    @MainActor
    func testNewestOverlappingTranscriptLoadWinsWhenOlderRequestFinishesLast() async throws {
        let viewModel = try makeOutOfOrderDirectLoadViewModel(mode: .newestSucceeds)
        await viewModel.loadMessages()
        let first = Task { await viewModel.loadMessages() }
        try await Task.sleep(for: .milliseconds(30))
        await viewModel.loadMessages()
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh transcript"])
        await first.value
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh transcript"])
        XCTAssertEqual(OutOfOrderChatSessionURLProtocol.requestCount, 3)
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    func testDelayedSceneRefreshCannotClobberNewlyStartedResponse() async throws {
        let viewModel = try makeOutOfOrderDirectLoadViewModel(mode: .staleLoadThenSend, acceptsPrompt: true)
        await viewModel.loadMessages()
        viewModel.seedTranscriptForTesting([])
        let delayed = Task { await viewModel.loadMessages() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(viewModel.isLoading)
        let accepted = await viewModel.sendMessage("New local prompt")
        XCTAssertTrue(accepted)
        await delayed.value
        XCTAssertTrue(viewModel.messages.compactMap(\.content).contains("New local prompt"))
        XCTAssertFalse(viewModel.messages.compactMap(\.content).contains("Stale transcript"))
        XCTAssertFalse(viewModel.isLoading, "Successful send superseding a load must not strand its wait owner")
    }

    @MainActor
    func testCachedHeldLoadFailureCannotClobberRealDirectSendOrClaimOffline() async throws {
        for failure in [(status: 502, body: "bad gateway"),
                        (status: 401, body: #"{"error":"unauthenticated"}"#)] {
            let context = try makeContext()
            let server = try XCTUnwrap(URL(string: "https://example.test"))
            try CacheStore.cacheMessages([
                ChatMessage(role: "user", content: "Cached question", timestamp: 1, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 2, messageId: "cached-assistant")
            ], serverURL: server, sessionID: "direct:7:default:session-abc", in: context)

            let requestStarted = expectation(description: "held transcript read started \(failure.status)")
            let releaseResponse = DispatchSemaphore(value: 0)
            let requestCount = LockedCounter()
            let transport = CacheSendRaceDirectTransport()
            MockURLProtocol.requestHandler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
                if requestCount.increment() == 1 {
                    return apiTestJSONResponse(
                        #"{"session_id":"session-abc","messages":[{"id":"cached-user","role":"user","content":"Cached question"},{"id":"cached-assistant","role":"assistant","content":"Cached answer"}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}"#,
                        for: request
                    )
                }
                requestStarted.fulfill()
                XCTAssertEqual(releaseResponse.wait(timeout: .now() + .seconds(5)), .success)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: failure.status,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"]
                ))
                return (response, Data(failure.body.utf8))
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
            let runtime = try HermesServerRuntime(origin: server) { sink in
                transport.installSink(sink)
                return transport
            }
            let viewModel = ChatViewModel(
                session: try makeSession(), server: server, client: client,
                gatewayRuntimeProvider: { _ in runtime },
                promptUncertaintyStore: InMemoryDirectPromptDeliveryUncertaintyStore()
            )
            // Initial open owns resume plus its canonical read, so establish the
            // real attached controller before racing a later warm refresh.
            await viewModel.loadMessages(modelContext: context)
            let load = Task { @MainActor in await viewModel.loadMessages(modelContext: context) }
            defer { releaseResponse.signal() }

            await fulfillment(of: [requestStarted], timeout: 2)
            XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached question", "Cached answer"])
            XCTAssertFalse(viewModel.isLoading,
                "A warm refresh with preserved transcript must remain nonblocking while its read is pending")
            XCTAssertFalse(viewModel.isViewingCachedData)

            let accepted = await viewModel.sendMessage("Real pending prompt")
            XCTAssertTrue(accepted)
            try await waitUntil {
                viewModel.messages.last?.content == "Live assistant"
                    && viewModel.liveReasoningText == "Live reasoning"
                    && viewModel.liveToolCalls.map(\.id) == ["race-tool"]
            }
            let liveAssistantID = try XCTUnwrap(viewModel.streamingAssistantMessageID)
            let reasoningAnchor = try XCTUnwrap(viewModel.reasoningAnchorMessageID)
            let toolAnchor = try XCTUnwrap(viewModel.toolCallAnchorMessageID)

            releaseResponse.signal()
            await load.value

            XCTAssertEqual(viewModel.messages.compactMap(\.content), [
                "Cached question", "Cached answer", "Real pending prompt", "Live assistant"
            ])
            XCTAssertEqual(viewModel.streamingAssistantMessageID, liveAssistantID)
            XCTAssertEqual(viewModel.reasoningAnchorMessageID, reasoningAnchor)
            XCTAssertEqual(viewModel.toolCallAnchorMessageID, toolAnchor)
            XCTAssertEqual(viewModel.liveReasoningText, "Live reasoning")
            XCTAssertEqual(viewModel.liveToolCalls.map(\.id), ["race-tool"])
            XCTAssertFalse(viewModel.isViewingCachedData)
            XCTAssertNil(viewModel.errorMessage)
            XCTAssertNil(viewModel.sendErrorMessage)
            XCTAssertFalse(viewModel.isLoading, "The superseded load must release its wait owner")
            XCTAssertEqual(transport.callCount(method: "prompt.submit"), 1)
            await viewModel.disposeDirectConversation()
            await runtime.stop()
        }
    }

    @MainActor
    func testNewestOverlappingDirectFailurePreservesOnlineTranscriptWithoutOfflineClaim() async throws {
        let viewModel = try makeOutOfOrderDirectLoadViewModel(mode: .bothFail)
        await viewModel.loadMessages()
        let first = Task { await viewModel.loadMessages() }
        try await Task.sleep(for: .milliseconds(30))
        await viewModel.loadMessages()
        await first.value
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Baseline"])
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(OutOfOrderChatSessionURLProtocol.requestCount, 3)
        XCTAssertFalse(viewModel.isLoading)
    }




    @MainActor


    func testSelectedModelTitleRequiresExactProviderCatalogMatch() {
        let models = [
            ModelCatalogOption(id: "shared/model", displayName: "OpenAI Shared", providerID: "openai"),
            ModelCatalogOption(id: "shared/model", displayName: "Anthropic Shared", providerID: "anthropic")
        ]

        XCTAssertEqual(
            models.firstMatchingSelection(modelID: "shared/model", providerID: "openai")?.displayName,
            "OpenAI Shared"
        )
        XCTAssertNil(
            models.firstMatchingSelection(modelID: "shared/model", providerID: "openrouter"),
            "A same-ID model from a different provider must not supply the selected title"
        )
    }

    func testDeduplicatedReasoningTextsRemovesIdenticalThinkingBodies() {
        let texts = ChatViewModel.deduplicatedReasoningTexts([
            "  **Reading workout profile**\nChecking the user's profile and workout log.  ",
            "\n**Reading workout profile**\nChecking the user's profile and workout log.\n",
            "Checking a different source.",
            "   "
        ])

        XCTAssertEqual(
            texts,
            [
                "**Reading workout profile**\nChecking the user's profile and workout log.",
                "Checking a different source."
            ]
        )
    }

    @MainActor
    func testDirectLoadToleratesStructuredContentAndOptionalFieldDecodeDrift() async throws {
        let viewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")

            return apiTestJSONResponse(#"{"session_id":"session-abc","messages":[{"role":"user","content":[{"type":"text","text":"Open this in mobile"}],"_ts":"1770000000","id":42},{"role":"assistant","content":"Loaded","timestamp":1770000001,"tool_calls":{"unexpected":"shape"}}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}"#, for: request)
        }

        await viewModel.loadMessages()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messagesOffset, 0)
        XCTAssertEqual(viewModel.messages.first?.messageId, "42")
        XCTAssertTrue(viewModel.messages.first?.content?.contains("Open this in mobile") == true)
    }

    @MainActor
    func testLoadMessagesTracksOlderHistoryAvailability() async throws {
        let viewModel = try makeViewModel(directLoad: true) { request in
            return try self.directLoadResponse(rows: [["id": 50, "role": "user", "content": "Only row"]], for: request)
        }
        await viewModel.loadMessages()
        XCTAssertEqual(viewModel.messagesOffset, 0)
        XCTAssertEqual(viewModel.messages.first?.id, "50")
        XCTAssertFalse(viewModel.hasOlderMessages)
    }

    @MainActor
    func testSkillShortcutWithoutDirectProviderRefusesWithoutNetwork() async throws {
        let viewModel = try makeViewModel { request in
            XCTFail("Nil-provider skill shortcut must not use legacy HTTP: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }

        let result = await viewModel.executeSkillShortcutCommand(name: "spotify", args: "")

        XCTAssertEqual(result, .unsupported(friendlyMessage: "Skills require a direct Hermes connection."))
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testDirectSkillShortcutWithoutArgsReturnsScopedCatalogDetailWithoutStartingChat() async throws {
        let transport = SendRetirementDirectTransport()
        let server = URL(string: "https://example.test")!
        let runtime = try HermesServerRuntime(origin: server) { sink in
            transport.installSink(sink)
            return transport
        }
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/skills")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "profile" }?.value, "work")
            return apiTestJSONResponse(
                #"[{"name":"Spotify","category":"media","description":"Control playback.","enabled":true}]"#,
                for: request
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let viewModel = ChatViewModel(session: SessionSummary(profile: "work"), server: server,
            client: client, gatewayRuntimeProvider: { _ in runtime })
        let result = await viewModel.executeSkillShortcutCommand(name: "spotify", args: "")
        guard case .executed(let message) = result else { return XCTFail("Expected local detail") }
        XCTAssertTrue(message?.contains("### `/spotify`") == true)
        XCTAssertTrue(message?.contains("Control playback.") == true)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(transport.methods().isEmpty)
        await runtime.stop()
    }

    @MainActor
    private func makeDirectDestructiveViewModel(
        transport: DirectDestructiveTransport,
        returned: Int = 2,
        rows: @escaping () -> String
    ) throws -> ChatViewModel {
        let server = URL(string: "https://example.test")!
        let runtime = try HermesServerRuntime(origin: server) { sink in
            transport.installSink(sink)
            return transport
        }
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions/durable-1/messages")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "profile" }?.value, "work")
            return apiTestJSONResponse(
                #"{"session_id":"durable-1","messages":\#(rows()),"pagination":{"limit":120,"offset":0,"order":"latest","returned":\#(returned)}}"#,
                for: request
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        return ChatViewModel(
            session: SessionSummary(sessionId: "durable-1", profile: "work"),
            server: server,
            client: client,
            gatewayRuntimeProvider: { _ in runtime },
            directAttachmentRecoveryMarkerStore: DirectGatewayAttachmentRecoveryMarkerStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ChatViewModelSendTests-\(UUID().uuidString)", isDirectory: true)
            ),
            promptUncertaintyStore: InMemoryDirectPromptDeliveryUncertaintyStore()
        )
    }

    @MainActor
    func testDirectEditUsesExactDurableUserRowAndSingleSubmit() async throws {
        let transport = DirectDestructiveTransport()
        let viewModel = try makeDirectDestructiveViewModel(transport: transport) {
            #"[{"id":11,"role":"user","content":"Original question"},{"id":12,"role":"assistant","content":"Completed answer"}]"#
        }
        await viewModel.loadMessages()
        let context = try XCTUnwrap(MessageActionContext(message: viewModel.messages[0], visibleIndex: 0, messagesOffset: 0))
        let edited = await viewModel.editMessage(context, newText: "Edited question")
        let recordedPrompts = transport.promptParams()
        await viewModel.disposeDirectConversation()
        XCTAssertTrue(edited)
        let params = try XCTUnwrap(recordedPrompts.first?.gatewayFields)
        XCTAssertEqual(params["text"], .string("Edited question"))
        XCTAssertEqual(params["truncate_before_row_id"], .number(11))
        XCTAssertEqual(params["truncate_before_user_ordinal"], .number(0))
        XCTAssertEqual(params["confirm_truncate"], .bool(true))
        XCTAssertEqual(params["confirm_empty_truncate"], .bool(true))
        XCTAssertEqual(recordedPrompts.count, 1)
    }

    @MainActor
    func testDirectRegenerateTargetsOriginatingUserAndStaleRefreshRefuses() async throws {
        let transport = DirectDestructiveTransport()
        var rows = #"[{"id":11,"role":"user","content":"Question one"},{"id":12,"role":"assistant","content":"Answer one"},{"id":21,"role":"user","content":"Question two"},{"id":22,"role":"assistant","content":"Answer two"}]"#
        let viewModel = try makeDirectDestructiveViewModel(transport: transport, returned: 4) { rows }
        await viewModel.loadMessages()
        let context = try XCTUnwrap(MessageActionContext(message: viewModel.messages[3], visibleIndex: 3, messagesOffset: 0))
        let regenerated = await viewModel.regenerateAssistantResponse(context)
        let recordedPrompts = transport.promptParams()
        await viewModel.disposeDirectConversation()

        rows = #"[{"id":11,"role":"user","content":"Question one"},{"id":12,"role":"assistant","content":"Changed externally"}]"#
        let staleTransport = DirectDestructiveTransport()
        let staleViewModel = try makeDirectDestructiveViewModel(transport: staleTransport) { rows }
        await staleViewModel.loadMessages()
        let staleRegenerate = await staleViewModel.regenerateAssistantResponse(context)
        let stalePrompts = staleTransport.promptParams()
        let staleMessage = staleViewModel.messageActionErrorMessage
        await staleViewModel.disposeDirectConversation()

        XCTAssertTrue(regenerated)
        let params = try XCTUnwrap(recordedPrompts.first?.gatewayFields)
        XCTAssertEqual(params["text"], .string("Question two"))
        XCTAssertEqual(params["truncate_before_row_id"], .number(21))
        XCTAssertEqual(params["truncate_before_user_ordinal"], .number(1))
        XCTAssertFalse(staleRegenerate)
        XCTAssertTrue(stalePrompts.isEmpty)
        XCTAssertEqual(staleMessage, "The conversation changed, so no history was replaced. Review the latest messages and try again.")
    }

    @MainActor
    func testDirectEditQueuedAcknowledgementIsAmbiguousAndNeverResent() async throws {
        let transport = DirectDestructiveTransport(promptStatus: "queued")
        let viewModel = try makeDirectDestructiveViewModel(transport: transport) {
            #"[{"id":11,"role":"user","content":"Original question"},{"id":12,"role":"assistant","content":"Completed answer"}]"#
        }
        await viewModel.loadMessages()
        let context = try XCTUnwrap(MessageActionContext(message: viewModel.messages[0], visibleIndex: 0, messagesOffset: 0))

        let first = await viewModel.editMessage(context, newText: "Edited question")
        XCTAssertFalse(first)
        XCTAssertEqual(transport.promptParams().count, 1)
        XCTAssertTrue(viewModel.messageActionErrorMessage?.contains("not resent") == true)

        let second = await viewModel.editMessage(context, newText: "Edited question")
        XCTAssertFalse(second)
        XCTAssertEqual(transport.promptParams().count, 1)
        await viewModel.disposeDirectConversation()
    }

    @MainActor
    func testDirectEditRejectsRowIDThatCannotBeRepresentedExactlyOnWire() async throws {
        let transport = DirectDestructiveTransport()
        let viewModel = try makeDirectDestructiveViewModel(transport: transport) {
            #"[{"id":"9007199254740993","role":"user","content":"Original question"},{"id":12,"role":"assistant","content":"Completed answer"}]"#
        }
        await viewModel.loadMessages()
        let context = try XCTUnwrap(MessageActionContext(message: viewModel.messages[0], visibleIndex: 0, messagesOffset: 0))
        let accepted = await viewModel.editMessage(context, newText: "Edited question")
        XCTAssertFalse(accepted)
        XCTAssertTrue(transport.promptParams().isEmpty)
        await viewModel.disposeDirectConversation()
    }

    @MainActor
    private func assertDirectDestructiveActionRefused(action: String, staleOrRepeated: Bool) async throws {
        XCTAssertEqual(action, "retry")
        let transport = DirectDestructiveTransport()
        let viewModel = try makeDirectDestructiveViewModel(transport: transport) {
            #"[{"id":11,"role":"user","content":"Original question"},{"id":12,"role":"assistant","content":"Completed answer"}]"#
        }
        await viewModel.loadMessages()
        let originalIDs = viewModel.messages.map(\.id)
        for _ in 0..<(staleOrRepeated ? 2 : 1) {
            let result = await viewModel.executeSlashCommand(
                try XCTUnwrap(SlashCommandCatalog.command(named: "retry"))
            )
            XCTAssertEqual(result, .unsupported(friendlyMessage: "Retry is not available in direct Hermes mode yet."))
        }
        XCTAssertEqual(viewModel.messages.map(\.id), originalIDs)
        XCTAssertTrue(transport.promptParams().isEmpty)
        XCTAssertNil(viewModel.activeStreamID)
        await viewModel.disposeDirectConversation()
    }

    @MainActor
    func testForkFromMessageRemainsUnavailableWithoutLegacyNetworkFallback() async throws {
        let viewModel = try makeViewModel { request in
            XCTFail("Message-level fork must not issue a legacy request: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }

        viewModel.seedTranscriptForTesting([ChatMessage(role: "user", content: "Question", timestamp: 1, messageId: "u-4"), ChatMessage(role: "assistant", content: "Answer", timestamp: 2, messageId: "a-5")], messagesOffset: 4)
        let context = try XCTUnwrap(viewModel.actionContext(for: viewModel.messages[1], visibleIndex: 1))
        let forked = await viewModel.forkFromMessage(context)

        XCTAssertNil(forked)
        XCTAssertEqual(viewModel.messageActionErrorMessage, "Forking is not available in direct Hermes mode yet.")
    }

    @MainActor
    func testDirectUndoRefusalDoesNotMutateOrLoad() async throws {
        let viewModel = try makeViewModel(directLoad: true) { _ in
            XCTFail("Unsupported direct undo must not issue legacy requests")
            throw URLError(.badURL)
        }
        viewModel.seedTranscriptForTesting([ChatMessage(role: "user", content: "Keep this", timestamp: 1, messageId: "11")])
        let result = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "undo")))
        XCTAssertEqual(result, .unsupported(friendlyMessage: "Undo is not available in direct Hermes mode yet."))
        XCTAssertEqual(viewModel.messages.map(\.id), ["11"])
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testDirectRetryRefusalPreservesDurableHistoryAndMakesNoRequest() async throws {
        try await assertDirectDestructiveActionRefused(action: "retry", staleOrRepeated: false)
    }

    @MainActor
    func testDirectRetryRepeatedRefusalDoesNotMutateOrStartStream() async throws {
        try await assertDirectDestructiveActionRefused(action: "retry", staleOrRepeated: true)
    }

    @MainActor
    func testClearSlashCommandClearsLocalTranscriptWithoutServerRequest() async throws {
        var requestCount = 0
        let viewModel = try makeViewModel { request in
            requestCount += 1
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Question", "timestamp": 1, "message_id": "u-1"},
                      {"role": "assistant", "content": "Answer", "timestamp": 2, "message_id": "a-2"}
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Clear should not call \(request.url?.path ?? "unknown path").")
                throw URLError(.badURL)
            }
        }

        viewModel.seedTranscriptForTesting([ChatMessage(role: "user", content: "Question", timestamp: 1, messageId: "u-4"), ChatMessage(role: "assistant", content: "Answer", timestamp: 2, messageId: "a-5")])
        let result = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "clear")))

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(requestCount, 0)
    }

    /// Lets a `Task { @MainActor … }` enqueued by a delegate callback run to completion
    /// before assertions. Same-actor tasks run FIFO, so awaiting a task enqueued *after*
    /// the callback's drains it; the leading yields add slack.
    @MainActor
    private func drainMainActor() async {
        for _ in 0..<3 { await Task.yield() }
        await Task { @MainActor in }.value
    }

    /// A `503 {"error": ...}` for `/api/audio/speak` — the canonical "server TTS refused,
    /// use the on-device fallback" stimulus for Listen tests (#15).
    private static func ttsAudioResponse(_ audio: Data, for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true, "mime_type": "audio/mpeg",
            "data_url": "data:audio/mpeg;base64,\(audio.base64EncodedString())"
        ])
        return apiTestJSONResponse(String(decoding: data, as: UTF8.self), for: request)
    }

    private static func ttsUnavailableResponse(for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(#"{"error": "TTS engine unavailable"}"#.utf8))
    }

    @MainActor
    func testCanonicalTranscriptSnapshotRecomputesDerivedStateOnce() async throws {
        let viewModel = try makeViewModel { _ in
            XCTFail("Renderer state setup must not request a transcript")
            throw URLError(.badURL)
        }
        let rows = (0..<120).map { ChatMessage(role: "user", content: "Message \($0)",
            timestamp: TimeInterval($0), messageId: "message-\($0)") }
        let before = viewModel.transcriptDerivedStateRecomputeCountForTesting
        viewModel.seedTranscriptForTesting(rows, messagesOffset: 120)
        XCTAssertEqual(viewModel.messages.count, 120)
        XCTAssertEqual(viewModel.messagesOffset, 120)
        XCTAssertEqual(viewModel.transcriptDerivedStateRecomputeCountForTesting - before, 1)
    }

    func testTranscriptClassificationHasBoundedRuntimeAndMemory() {
        let messages = (0..<1_000).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Transcript message \(index) with **markdown** and a tool marker.",
                timestamp: TimeInterval(index),
                messageId: "performance-message-\(index)"
            )
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            _ = ChatViewModel.transcriptMessages(from: messages, messageOffset: 0)
        }
    }

    @MainActor
    func testPerformanceLabStreamingUpdatesOnlyTheSelectedTranscriptIncrementally() async throws {
        let fixtures = ChatViewModel.makePerformanceLabFixtures(count: 3)
        XCTAssertEqual(fixtures.count, 3)

        for fixture in fixtures {
            XCTAssertEqual(fixture.viewModel.messages.count, 10_000)
            XCTAssertTrue(fixture.viewModel.displayedTranscriptMessages.indices.contains(20))
            let row20 = fixture.viewModel.displayedTranscriptMessages[20]
            let sessionID = try XCTUnwrap(fixture.session.sessionId)
            let restorePoint = TranscriptRestoreStore.shared.load(
                server: fixture.server,
                sessionID: sessionID
            )
            XCTAssertEqual(
                restorePoint.visibleMessageID,
                row20.renderID,
                "Fixture restore target must use the transcript's actual render ID."
            )
        }

        let siblingSnapshots = fixtures.dropFirst().map { $0.viewModel.messages }
        let selected = fixtures[0].viewModel
        let fullRecomputesBefore = selected.transcriptFullRecomputeCountForTesting
        let derivedRecomputesBefore = selected.transcriptDerivedStateRecomputeCountForTesting

        await selected.appendPerformanceLabStreamingTurn()

        XCTAssertEqual(selected.messages.count, 10_002)
        XCTAssertTrue(
            selected.messages.last?.content?.contains("SEMREH_MULTI_CHAT_STREAM_1") == true,
            "The selected fixture must finish with the deterministic streamed marker."
        )
        XCTAssertEqual(
            selected.transcriptFullRecomputeCountForTesting,
            fullRecomputesBefore,
            "Streaming tail updates must use the incremental transcript mapping."
        )
        XCTAssertEqual(
            selected.transcriptDerivedStateRecomputeCountForTesting,
            derivedRecomputesBefore,
            "Streaming tail updates must not trigger full derived-state recomputation."
        )

        for (fixture, snapshot) in zip(fixtures.dropFirst(), siblingSnapshots) {
            XCTAssertEqual(fixture.viewModel.messages, snapshot, "A sibling long chat must remain unchanged.")
            XCTAssertEqual(fixture.viewModel.messages.count, 10_000)
        }
    }

    @MainActor
    func testDirectEventsRenderReasoningToolInterimAndTextBeforeCompletion() throws {
        let viewModel = try makeViewModel { request in
            XCTFail("Direct renderer setup must not issue an HTTP request: \(request)")
            throw URLError(.badURL)
        }
        viewModel.seedTranscriptForTesting([
            ChatMessage(role: "user", content: "Inspect this", timestamp: 1, messageId: "user-1")
        ])

        viewModel.handleDirectEventForTesting(directEvent(type: "message.start", sequence: 1))
        viewModel.handleDirectEventForTesting(directEvent(
            type: "reasoning.delta", sequence: 2,
            payload: ["text": .string("Check the workspace.")]
        ))
        viewModel.handleDirectEventForTesting(directEvent(
            type: "tool.start", sequence: 3,
            payload: ["tool_id": .string("tool-1"), "name": .string("read_file")]
        ))
        viewModel.handleDirectEventForTesting(directEvent(
            type: "tool.complete", sequence: 4,
            payload: ["tool_id": .string("tool-1"), "name": .string("read_file"),
                      "result": .string("done")]
        ))
        viewModel.handleDirectEventForTesting(directEvent(
            type: "message.interim", sequence: 5,
            payload: ["text": .string("Draft answer.")]
        ))
        let sealedAnchor = viewModel.reasoningAnchorMessageID
        viewModel.handleDirectEventForTesting(directEvent(
            type: "message.delta", sequence: 6,
            payload: ["text": .string(" Final answer.")]
        ))
        viewModel.flushPendingStreamingContent()

        XCTAssertEqual(viewModel.messages.map(\.role), ["user", "assistant", "assistant"])
        XCTAssertEqual(assistantContents(in: viewModel), ["Draft answer.", " Final answer."])
        XCTAssertEqual(viewModel.liveReasoningText, "Check the workspace.")
        XCTAssertEqual(viewModel.liveToolCalls.map(\.name), ["read_file"])
        XCTAssertEqual(viewModel.liveToolCalls.first?.isCompleted, true)
        XCTAssertEqual(viewModel.reasoningAnchorMessageID, sealedAnchor)
        XCTAssertEqual(viewModel.toolCallAnchorMessageID, sealedAnchor)
    }

    @MainActor
    func testAlreadyStreamedInterimSealsBeforeDifferentFinal() throws {
        let viewModel = try makeDirectRendererViewModel()
        viewModel.seedTranscriptForTesting([
            ChatMessage(role: "user", content: "Inspect", timestamp: 1, messageId: "user-1")
        ])

        viewModel.handleDirectEventForTesting(directEvent(type: "message.start", sequence: 1))
        viewModel.handleDirectEventForTesting(directEvent(type: "message.delta", sequence: 2,
            payload: ["text": .string("## Interim heading")]))
        viewModel.handleDirectEventForTesting(directEvent(type: "message.interim", sequence: 3,
            payload: ["text": .string("## Interim heading"), "already_streamed": .bool(true)]))
        viewModel.handleDirectEventForTesting(directEvent(type: "message.complete", sequence: 4,
            payload: ["text": .string("Final answer")]))

        XCTAssertEqual(assistantContents(in: viewModel), ["## Interim heading", "Final answer"])
    }

    @MainActor
    func testUnstreamedInterimIsAddedAndSealedBeforeDifferentFinal() throws {
        let viewModel = try makeDirectRendererViewModel()
        viewModel.handleDirectEventForTesting(directEvent(type: "message.start", sequence: 1))
        viewModel.handleDirectEventForTesting(directEvent(type: "message.interim", sequence: 2,
            payload: ["text": .string("Tool commentary"), "already_streamed": .bool(false)]))
        viewModel.handleDirectEventForTesting(directEvent(type: "message.complete", sequence: 3,
            payload: ["text": .string("Final answer")]))

        XCTAssertEqual(assistantContents(in: viewModel), ["Tool commentary", "Final answer"])
    }

    @MainActor
    func testMatchingAndPrefixFinalsReconcileOntoSealedInterim() throws {
        for finalText in ["Partial answer", "Partial answer continued"] {
            let viewModel = try makeDirectRendererViewModel()
            viewModel.handleDirectEventForTesting(directEvent(type: "message.start", sequence: 1))
            viewModel.handleDirectEventForTesting(directEvent(type: "message.interim", sequence: 2,
                payload: ["text": .string("Partial answer"), "already_streamed": .bool(false)]))
            viewModel.handleDirectEventForTesting(directEvent(type: "message.complete", sequence: 3,
                payload: ["text": .string(finalText)]))

            XCTAssertEqual(assistantContents(in: viewModel), [finalText])
        }
    }

    @MainActor
    func testMatchingTerminalUpdatesSealedInterimAcrossTrailingNotice() throws {
        let viewModel = try makeDirectRendererViewModel()
        viewModel.handleDirectEventForTesting(directEvent(type: "message.start", sequence: 1))
        viewModel.handleDirectEventForTesting(directEvent(type: "message.interim", sequence: 2,
            payload: ["text": .string("Partial answer"), "already_streamed": .bool(false)]))
        viewModel.handleDirectEventForTesting(directEvent(type: "status.update", sequence: 3,
            payload: ["kind": .string("goal"), "text": .string("Continuing the task")]))
        viewModel.handleDirectEventForTesting(directEvent(type: "message.complete", sequence: 4,
            payload: ["text": .string("Partial answer continued")]))

        XCTAssertEqual(assistantContents(in: viewModel), ["Partial answer continued"])
        XCTAssertTrue(viewModel.messages.contains {
            $0.role == "local_notice" && $0.content == "Continuing the task"
        })
    }

    @MainActor
    func testPrefixTerminalAfterRepeatedStartStillReconcilesPinnedDesktopContinuity() throws {
        let viewModel = try makeDirectRendererViewModel()
        viewModel.handleDirectEventForTesting(directEvent(type: "message.start", sequence: 1))
        viewModel.handleDirectEventForTesting(directEvent(type: "message.interim", sequence: 2,
            payload: ["text": .string("Partial answer"), "already_streamed": .bool(false)]))
        viewModel.handleDirectEventForTesting(directEvent(type: "message.start", sequence: 3))
        viewModel.handleDirectEventForTesting(directEvent(type: "message.complete", sequence: 4,
            payload: ["text": .string("Partial answer continued")]))

        XCTAssertEqual(assistantContents(in: viewModel), ["Partial answer continued"])
    }

    @MainActor
    func testMultipleInterimsKeepDistinctSegmentsAndToolAnchor() throws {
        let viewModel = try makeDirectRendererViewModel()
        viewModel.handleDirectEventForTesting(directEvent(type: "message.start", sequence: 1))
        viewModel.handleDirectEventForTesting(directEvent(type: "message.interim", sequence: 2,
            payload: ["text": .string("First check"), "already_streamed": .bool(false)]))
        viewModel.handleDirectEventForTesting(directEvent(type: "tool.start", sequence: 3,
            payload: ["tool_id": .string("tool-1"), "name": .string("read_file")]))
        viewModel.handleDirectEventForTesting(directEvent(type: "tool.complete", sequence: 4,
            payload: ["tool_id": .string("tool-1"), "name": .string("read_file")]))
        viewModel.handleDirectEventForTesting(directEvent(type: "message.interim", sequence: 5,
            payload: ["text": .string("Second check"), "already_streamed": .bool(false)]))
        let toolAnchor = viewModel.toolCallAnchorMessageID
        viewModel.handleDirectEventForTesting(directEvent(type: "message.complete", sequence: 6,
            payload: ["text": .string("Done")]))

        XCTAssertEqual(assistantContents(in: viewModel), ["First check", "Second check", "Done"])
        XCTAssertNotNil(toolAnchor)
        XCTAssertEqual(viewModel.liveToolCalls.map(\.id), ["tool-1"])
    }

    @MainActor
    private func makeDirectRendererViewModel() throws -> ChatViewModel {
        try makeViewModel { request in
            XCTFail("Direct renderer setup must not issue an HTTP request: \(request)")
            throw URLError(.badURL)
        }
    }

    @MainActor
    private func assistantContents(in viewModel: ChatViewModel) -> [String] {
        viewModel.flushPendingStreamingContent()
        return viewModel.messages
            .filter { $0.role == "assistant" }
            .compactMap(\.content)
            .filter { !$0.isEmpty }
    }

    @MainActor
    func testDirectEventTokenBurstKeepsTranscriptMemoAndCoalescesContent() throws {
        let viewModel = try makeViewModel(
            streamingScrollCoalescingDelayNanoseconds: 1_000_000
        ) { request in
            XCTFail("Direct renderer setup must not issue an HTTP request: \(request)")
            throw URLError(.badURL)
        }
        viewModel.seedTranscriptForTesting([
            ChatMessage(role: "user", content: "Stream", timestamp: 1, messageId: "user-1")
        ])
        viewModel.handleDirectEventForTesting(directEvent(type: "message.start", sequence: 1))
        let initialTrigger = viewModel.streamingScrollTrigger

        for index in 0..<25 {
            viewModel.handleDirectEventForTesting(directEvent(
                type: "message.delta", sequence: index + 2,
                payload: ["text": .string("chunk-\(index) ")]
            ))
        }
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger)
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(
            viewModel.messages.last?.content,
            (0..<25).map { "chunk-\($0) " }.joined()
        )
        XCTAssertEqual(
            viewModel.displayedTranscriptMessages,
            ChatViewModel.transcriptMessages(
                from: viewModel.messages, messageOffset: viewModel.messagesOffset
            )
        )

        viewModel.handleDirectEventForTesting(directEvent(
            type: "message.delta", sequence: 27,
            payload: ["text": .string("must be cleared")]
        ))
        viewModel.seedTranscriptForTesting([
            ChatMessage(role: "user", content: "Stream", timestamp: 1, messageId: "user-1"),
            ChatMessage(role: "assistant", content: "Authoritative", timestamp: 2, messageId: "assistant-1")
        ])
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(viewModel.messages.last?.content, "Authoritative")
    }

    @MainActor
    func testDirectTerminalUsageAppliesAndCachesFinalTurnTPS() throws {
        let context = try makeContext()
        let viewModel = try makeViewModel { request in
            XCTFail("Direct terminal renderer must not issue an HTTP request: \(request)")
            throw URLError(.badURL)
        }
        viewModel.seedTranscriptForTesting([
            ChatMessage(role: "user", content: "Measure", timestamp: 1, messageId: "user-1")
        ])
        viewModel.handleDirectEventForTesting(directEvent(type: "message.start", sequence: 1))
        viewModel.handleDirectEventForTesting(directEvent(
            type: "message.delta", sequence: 2,
            payload: ["text": .string("Measured response.")]
        ))
        viewModel.handleDirectEventForTesting(directEvent(
            type: "message.complete", sequence: 3,
            payload: [
                "status": .string("complete"),
                "text": .string("Measured response."),
                "usage": .object(["avg_tps": .number(20.5)])
            ]
        ))

        XCTAssertNil(viewModel.liveTokensPerSecond)
        XCTAssertEqual(viewModel.messages.last?.turnTps, 20.5)
        XCTAssertFalse(viewModel.responseCompletionNeedsTranscriptRefresh)
        viewModel.cacheCompletedResponse(modelContext: context)
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: URL(string: "https://example.test")!,
                sessionID: "session-abc", in: context
            ).last?.turnTps,
            20.5
        )
    }

    private func directEvent(
        type: String,
        sequence: Int,
        payload: [String: JSONValue]? = nil
    ) -> HermesGatewayEvent {
        HermesGatewayEvent(
            method: "event", type: type, sessionID: "runtime-test",
            sequence: sequence, payload: payload.map(JSONValue.object),
            params: nil, connectionGeneration: 1
        )
    }

    private func makeEphemeralUserDefaults() throws -> UserDefaults {
        let suiteName = "HermesMobileTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    @MainActor
    private func makeViewModel(
        directLoad: Bool = false,
        directLoadFailure: HermesGatewayError? = nil,
        sessionSummary: SessionSummary? = nil,
        liveActivityManager: (any AgentLiveActivityManaging)? = nil,
        pollingIntervals: ChatPollingIntervals = .standard,
        streamingScrollCoalescingDelayNanoseconds: UInt64 = 16_000_000,
        speechSynthesizerFactory: @escaping () -> any ChatSpeechSynthesizing = { AVSpeechSynthesizer() },
        listenAudioSession: (any ListenAudioSessionControlling)? = nil,
        listenRemoteControlCenter: (any ListenRemoteControlControlling)? = nil,
        serverTTSAudioPlayerFactory: (@MainActor (Data) throws -> any ListenAudioPlaying)? = nil,
        userDefaults: UserDefaults = .standard,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)
        let summary: SessionSummary
        if let sessionSummary {
            summary = sessionSummary
        } else {
            summary = try makeSession()
        }

        let viewModel = ChatViewModel(
            session: summary,
            server: server,
            client: client,
            liveActivityManager: liveActivityManager,
            pollingIntervals: pollingIntervals,
            streamingScrollCoalescingDelayNanoseconds: streamingScrollCoalescingDelayNanoseconds,
            speechSynthesizerFactory: speechSynthesizerFactory,
            // Default to a spy so unit tests never drive the live shared AVAudioSession.
            listenAudioSession: listenAudioSession ?? SpyListenAudioSession(),
            listenRemoteControlCenter: listenRemoteControlCenter ?? SpyListenRemoteControlCenter(),
            serverTTSAudioPlayerFactory: serverTTSAudioPlayerFactory,
            userDefaults: userDefaults,
            gatewayRuntimeProvider: directLoad ? { _ in
                try HermesServerRuntime(origin: server) { _ in DirectLoadTestTransport(failure: directLoadFailure) }
            } : nil,
            promptUncertaintyStore: InMemoryDirectPromptDeliveryUncertaintyStore()
        )

        return viewModel
    }

    private func directLoadResponse(rows: [[String: Any]], for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
        let data = try JSONSerialization.data(withJSONObject: ["session_id": "session-abc", "messages": rows,
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": rows.count]])
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (response, data)
    }

    @MainActor
    private func makeOutOfOrderDirectLoadViewModel(mode: OutOfOrderChatSessionURLProtocol.Mode, acceptsPrompt: Bool = false) throws -> ChatViewModel {
        OutOfOrderChatSessionURLProtocol.reset(mode: mode)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OutOfOrderChatSessionURLProtocol.self]
        let server = URL(string: "https://example.test")!
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let runtime = try HermesServerRuntime(origin: server) { _ in DirectLoadTestTransport(acceptsPrompt: acceptsPrompt) }
        return ChatViewModel(session: try makeSession(), server: server, client: client,
            gatewayRuntimeProvider: { _ in runtime },
            promptUncertaintyStore: InMemoryDirectPromptDeliveryUncertaintyStore())
    }

    @MainActor
    func testDirectLoadGatewayConnectivityFailuresAdoptCacheButEncodingFailureDoesNot() async throws {
        let cases: [(HermesGatewayError, Bool)] = [
            (.closed, true), (.notConnected, true),
            (.timeout(method: "session.resume", requestID: "fixture"), true),
            (.transport("WebSocket receive failed"), true),
            (.transport("WebSocket send failed"), true),
            (.transport("request encoding failed"), false)
        ]
        for (failure, shouldUseCache) in cases {
            let context = try makeContext()
            try CacheStore.cacheMessages([ChatMessage(role: "assistant", content: "Cached row", timestamp: 1, messageId: "cached")],
                serverURL: URL(string: "https://example.test")!, sessionID: "direct:7:default:session-abc", in: context)
            let viewModel = try makeViewModel(directLoad: true, directLoadFailure: failure) { _ in
                XCTFail("Failed resume must not fall back to HTTP/WebUI")
                throw URLError(.badURL)
            }
            await viewModel.loadMessages(modelContext: context)
            XCTAssertEqual(viewModel.isViewingCachedData, shouldUseCache)
            XCTAssertEqual(viewModel.messages.compactMap(\.content), shouldUseCache ? ["Cached row"] : [])
            XCTAssertEqual(viewModel.lastError as? HermesGatewayError, failure)
            XCTAssertFalse(viewModel.isLoading)
        }
    }

    @MainActor
    func testDirectIdleLoadPreservesToolOnlyAssistantAndIsNotRunning() async throws {
        let viewModel = try makeViewModel(directLoad: true) { request in
            try self.directLoadResponse(rows: [
                ["id": 1, "role": "user", "content": "Run terminal"],
                ["id": 2, "role": "assistant", "content": "", "tool_calls": [
                    ["id": "tool-1", "function": ["name": "terminal", "arguments": "{\"command\":\"pwd\"}"]]
                ]],
                ["id": 3, "role": "tool", "content": "/tmp/fixture", "tool_call_id": "tool-1"]
            ], for: request)
        }
        await viewModel.loadMessages()
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant", "tool"])
        XCTAssertEqual(viewModel.messages.first { $0.role == "assistant" }?.toolCalls?.count, 1)
    }

    @MainActor
    func testOlderLoadCompletionCannotClearNewerLoadWait() async throws {
        let viewModel = try makeOutOfOrderDirectLoadViewModel(mode: .newestPending)
        await viewModel.loadMessages()
        viewModel.seedTranscriptForTesting([])
        let first = Task { await viewModel.loadMessages() }
        try await Task.sleep(for: .milliseconds(30))
        let second = Task { await viewModel.loadMessages() }
        await first.value
        XCTAssertTrue(viewModel.isLoading, "Older load must not end newer load's connection wait")
        await second.value
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh transcript"])
    }

    @MainActor
    func testDirectLoadStructuredAuthFailureRevertsCachePlaceholderWithoutOfflineClaim() async throws {
        let context = try makeContext()
        try CacheStore.cacheMessages([ChatMessage(role: "assistant", content: "Cached row", timestamp: 1, messageId: "cached")],
            serverURL: URL(string: "https://example.test")!, sessionID: "direct:7:default:session-abc", in: context)
        let viewModel = try makeViewModel(directLoad: true) { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-abc/messages")
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            return (response, Data(#"{"error":"unauthenticated"}"#.utf8))
        }
        await viewModel.loadMessages(modelContext: context)
        XCTAssertEqual(viewModel.lastError as? DirectHermesAuthError, .sessionExpired)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    func testLoadWithoutDirectRuntimeMakesNoWebUIRequestOrOfflineClaim() async throws {
        let viewModel = try makeViewModel { _ in
            XCTFail("Missing runtime must not fall back to WebUI")
            throw URLError(.badURL)
        }
        viewModel.seedTranscriptForTesting([ChatMessage(role: "assistant", content: "Existing row", timestamp: 1, messageId: "existing")])
        await viewModel.loadMessages()
        XCTAssertEqual(viewModel.messages.first?.content, "Existing row")
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<40 {
            if condition() {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func runMainActorTest(
        timeout: TimeInterval = 5,
        _ body: @escaping @MainActor () async throws -> Void
    ) {
        let expectation = expectation(description: "MainActor async test")
        Task { @MainActor in
            defer { expectation.fulfill() }

            do {
                try await body()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        wait(for: [expectation], timeout: timeout)
    }

    private func makeSession(
        title: String = "Planning",
        model: String? = "gpt-5.4",
        modelProvider: String? = nil,
        profile: String? = nil
    ) throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let modelJSON = model.map { ",\n              \"model\": \"\($0)\"" } ?? ""
        let modelProviderJSON = modelProvider.map { ",\n              \"model_provider\": \"\($0)\"" } ?? ""
        let profileJSON = profile.map { ",\n              \"profile\": \"\($0)\"" } ?? ""
        return try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-abc",
              "title": "\(title)",
              "workspace": "/tmp/workspace"\(modelJSON)\(modelProviderJSON)\(profileJSON)
            }
            """.utf8)
        )
    }

    private func makeSessionDetail(_ json: String) throws -> SessionDetail {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionDetail.self, from: Data(json.utf8))
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedSession.self,
            CachedMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func makeJPEGData(size: CGSize) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }

        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    private func maxPixelDimension(in data: Data) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue
        return max(width, height)
    }

    @MainActor
    private func waitForStreamingContent(
        _ viewModel: ChatViewModel,
        toSatisfy predicate: (String?) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<20 {
            if predicate(viewModel.messages.last?.content) {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(
            predicate(viewModel.messages.last?.content),
            file: file,
            line: line
        )
    }
}

private actor DirectLoadTestTransport: HermesGatewayTransport {
    let acceptsPrompt: Bool
    let failure: HermesGatewayError?
    init(acceptsPrompt: Bool = false, failure: HermesGatewayError? = nil) {
        self.acceptsPrompt = acceptsPrompt
        self.failure = failure
    }
    func connect() async throws {}
    func close() async {}
    func connectionIdentifier() async -> Int? { 1 }
    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        if let failure { throw failure }
        if acceptsPrompt, method == "prompt.submit" { return .object(["status": .string("streaming")]) }
        // Idle direct loads schedule a best-effort context snapshot after the
        // canonical transcript read.  This fixture does not need to publish a
        // usage value, but it must accept the legitimate nonblocking RPC.
        if method == "session.usage" { return .object([:]) }
        guard method == "session.resume" else {
            XCTFail("Unexpected load RPC: \(method)")
            throw URLError(.badURL)
        }
        return .object(["session_id": .string("session-abc"), "session_key": .string("session-abc"), "running": .bool(false)])
    }
}

private final class CacheSendRaceDirectTransport: HermesGatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var methods: [String] = []

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        withLock { self.sink = sink }
    }
    func connect() async throws {}
    func close() async {}
    func connectionIdentifier() async -> Int? { 1 }
    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        withLock { methods.append(method) }
        switch method {
        case "session.resume":
            return .object([
                "session_id": .string("runtime-cache-race"),
                "session_key": .string("session-abc"),
                "running": .bool(false)
            ])
        case "prompt.submit":
            let sink = withLock { self.sink }
            sink?(event(type: "message.start", sequence: 1))
            sink?(event(type: "message.delta", sequence: 2,
                payload: ["text": .string("Live assistant")]))
            sink?(event(type: "reasoning.delta", sequence: 3,
                payload: ["text": .string("Live reasoning")]))
            sink?(event(type: "tool.start", sequence: 4,
                payload: ["tool_id": .string("race-tool"), "name": .string("read_file")]))
            return .object(["status": .string("streaming")])
        default:
            return .object([:])
        }
    }
    func callCount(method: String) -> Int {
        withLock { methods.filter { $0 == method }.count }
    }
    private func event(type: String, sequence: Int, payload: [String: JSONValue]? = nil) -> HermesGatewayEvent {
        HermesGatewayEvent(method: "event", type: type, sessionID: "runtime-cache-race",
            sequence: sequence, payload: payload.map(JSONValue.object), params: nil, connectionGeneration: 1)
    }
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class LockedCounter {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }

        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }

        return value
    }
}

@MainActor
private final class SpyChatLiveActivityManager: AgentLiveActivityManaging {
    struct End: Equatable {
        let status: AgentRunActivityStatus
        let activity: String
        let errorSummary: String?
    }

    private(set) var ends: [End] = []

    func start(sessionID: String, sessionTitle: String, streamID: String?) {}

    func update(_ event: AgentLiveActivityEvent) {}

    func markStale() {}

    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {
        ends.append(End(status: status, activity: activity, errorSummary: errorSummary))
    }
}

/// Shared, interleaved call log so tests can prove ordering ACROSS the audio-session
/// spy and the speech-synthesizer spy in one timeline — not two independent logs.
private final class ListenCallRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private final class SpySpeechSynthesizer: ChatSpeechSynthesizing {
    var delegate: (any AVSpeechSynthesizerDelegate)?
    var isSpeaking = false
    var isPaused = false
    private(set) var spokenStrings: [String] = []
    private(set) var spokenUtterances: [AVSpeechUtterance] = []
    private(set) var stopBoundaries: [AVSpeechBoundary] = []
    private let recorder: ListenCallRecorder?

    init(recorder: ListenCallRecorder? = nil) {
        self.recorder = recorder
    }

    func speak(_ utterance: AVSpeechUtterance) {
        spokenStrings.append(utterance.speechString)
        spokenUtterances.append(utterance)
        isSpeaking = true
        recorder?.record("speak")
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopBoundaries.append(boundary)
        isSpeaking = false
        isPaused = false
        return true
    }

    /// Drives the production delegate's `didCancel` exactly as `AVSpeechSynthesizer`
    /// would after `stopSpeaking(at:)` — late, via the delegate's `@MainActor` hop. The
    /// delegate ignores the synthesizer argument, so a throwaway instance is fine.
    func fireDidCancel(_ utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didCancel: utterance)
    }
}

@MainActor
private final class SpyListenAudioPlayer: ListenAudioPlaying {
    var onFinish: (@MainActor () -> Void)?
    var playResult = true
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 75
    var rate: Float = 1
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    private(set) var prepareToPlayCount = 0

    func prepareToPlay() {
        prepareToPlayCount += 1
    }

    func play() -> Bool {
        playCount += 1
        return playResult
    }

    func pause() {
        pauseCount += 1
    }

    func stop() {
        stopCount += 1
    }

    /// Simulates the wrapped `AVAudioPlayer` finishing naturally.
    func finishPlayback() {
        onFinish?()
    }
}

@MainActor
private final class SpyListenAudioSession: ListenAudioSessionControlling {
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private let recorder: ListenCallRecorder?

    init(recorder: ListenCallRecorder? = nil) {
        self.recorder = recorder
    }

    func activate() {
        activateCount += 1
        recorder?.record("activate")
    }

    func deactivate() {
        deactivateCount += 1
        recorder?.record("deactivate")
    }
}

@MainActor
private final class SpyListenRemoteControlCenter: ListenRemoteControlControlling {
    private(set) var configureCount = 0
    private(set) var clearCount = 0
    private(set) var snapshots: [ListenNowPlayingSnapshot] = []
    private var playHandler: (@MainActor () -> Void)?
    private var pauseHandler: (@MainActor () -> Void)?
    private var togglePlayPauseHandler: (@MainActor () -> Void)?
    private var changePlaybackPositionHandler: (@MainActor (TimeInterval) -> Void)?

    func configure(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        changePlaybackPosition: @escaping @MainActor (TimeInterval) -> Void
    ) {
        configureCount += 1
        playHandler = play
        pauseHandler = pause
        togglePlayPauseHandler = togglePlayPause
        changePlaybackPositionHandler = changePlaybackPosition
    }

    func update(_ snapshot: ListenNowPlayingSnapshot) {
        snapshots.append(snapshot)
    }

    func clear() {
        clearCount += 1
        snapshots.removeAll()
    }

    func firePlay() {
        playHandler?()
    }

    func firePause() {
        pauseHandler?()
    }

    func fireTogglePlayPause() {
        togglePlayPauseHandler?()
    }

    func fireChangePlaybackPosition(_ position: TimeInterval) {
        changePlaybackPositionHandler?(position)
    }
}

private final class OutOfOrderChatSessionURLProtocol: URLProtocol {
    enum Mode: Equatable {
        case newestSucceeds
        case newestPending
        case bothFail
        case staleLoadThenSend
    }

    private static let lock = NSLock()
    private static var nextOrdinal = 0
    private static var mode: Mode = .newestSucceeds
    private var loadingTask: Task<Void, Never>?

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextOrdinal
    }

    static func reset(mode: Mode = .newestSucceeds) {
        lock.lock()
        nextOrdinal = 0
        self.mode = mode
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.nextOrdinal += 1
        let ordinal = Self.nextOrdinal
        let mode = Self.mode
        Self.lock.unlock()

        loadingTask = Task { [weak self] in
            guard let self, let url = request.url else { return }
            let delayNanoseconds: UInt64
            if mode == .newestPending {
                delayNanoseconds = ordinal == 3 ? 250_000_000 : ordinal == 2 ? 100_000_000 : 10_000_000
            } else {
                delayNanoseconds = ordinal == 2 ? 200_000_000 : 10_000_000
            }
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }

            let statusCode: Int
            let data: Data
            switch mode {
            case .newestSucceeds, .newestPending:
                let content = ordinal == 1 ? "Baseline" : ordinal == 2 ? "Stale transcript" : "Fresh transcript"
                statusCode = 200
                data = Data("""
                {"session_id":"session-abc","messages":[{"role":"assistant","content":"\(content)","timestamp":1770000100,"id":\(ordinal)}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":1}}
                """.utf8)
            case .bothFail:
                statusCode = ordinal == 1 ? 200 : 500
                data = Data((ordinal == 1 ? #"{"session_id":"session-abc","messages":[{"id":1,"role":"assistant","content":"Baseline"}],"pagination":{"limit":120,"offset":0,"order":"latest","returned":1}}"# : #"{"error":"boom"}"#).utf8)
            case .staleLoadThenSend:
                statusCode = 200
                let content = ordinal == 1 ? "Baseline" : "Stale transcript"
                data = Data("{\"session_id\":\"session-abc\",\"messages\":[{\"id\":1,\"role\":\"assistant\",\"content\":\"\(content)\"}],\"pagination\":{\"limit\":120,\"offset\":0,\"order\":\"latest\",\"returned\":1}}".utf8)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }
}
