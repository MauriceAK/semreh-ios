import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class ChatViewModelSendTests: XCTestCase {
    override func tearDown() {
        ChatViewModel.resetActiveStreamSnapshotsForTesting()
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
    func testComposerConfigTransientBlipDoesNotShowServerDownBanner() async throws {
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.6-luna", modelProvider: "openai-codex")
        ) { request in
            switch request.url?.path {
            case "/api/profiles", "/api/commands":
                throw URLError(.networkConnectionLost)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadComposerConfiguration()

        XCTAssertNil(viewModel.composerConfigurationErrorMessage)
        XCTAssertNil(viewModel.sendErrorMessage)
    }

    @MainActor
    func testTransientStreamRecoveryDoesNotShowServerDownBanner() async throws {
        let viewModel = try makeViewModel { request in
            XCTFail("Recovery presentation should not hit the network.")
            return apiTestJSONResponse("{}", for: request)
        }

        viewModel.streamCoordinatorDidReceiveRecoveryError(
            APIError.network(underlying: URLError(.networkConnectionLost))
        )

        XCTAssertNil(viewModel.sendErrorMessage)
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
    func testUploadAttachmentDefersSizePolicyToServer() async throws {
        var didRequestUpload = false
        let viewModel = try makeViewModel { request in
            didRequestUpload = true
            XCTAssertEqual(request.url?.path, "/api/upload")
            return apiTestJSONResponse(
                #"{"error":"File too large (server policy)"}"#,
                for: request
            )
        }

        await viewModel.uploadAttachment(
            data: Data("large payload".utf8),
            filename: "large.mov"
        )

        XCTAssertTrue(didRequestUpload)
        XCTAssertTrue(viewModel.pendingAttachments.isEmpty)
        XCTAssertEqual(viewModel.uploadAttachmentErrorMessage, "File too large (server policy)")
    }

    @MainActor
    func testUploadAttachmentDownsamplesImagePreviewButUploadsOriginalData() async throws {
        let originalData = try makeJPEGData(size: CGSize(width: 1_600, height: 1_200))
        var uploadedBody: Data?
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/upload")

            let body = try XCTUnwrap(apiTestBodyData(from: request))
            uploadedBody = body
            XCTAssertNotNil(body.range(of: originalData))

            return apiTestJSONResponse("""
            {
              "filename": "large.jpg",
              "path": "/tmp/workspace/large.jpg",
              "size": \(originalData.count),
              "mime": "image/jpeg",
              "is_image": true
            }
            """, for: request)
        }

        await viewModel.uploadAttachment(data: originalData, filename: "large.jpg", previewData: originalData)

        let attachment = try XCTUnwrap(viewModel.pendingAttachments.first)
        let thumbnailData = try XCTUnwrap(attachment.thumbnailData)
        XCTAssertNotNil(uploadedBody)
        XCTAssertNotEqual(thumbnailData, originalData)
        XCTAssertGreaterThan(try maxPixelDimension(in: originalData), ImagePreviewDownsampler.attachmentMaxPixelSize)
        XCTAssertLessThanOrEqual(
            try maxPixelDimension(in: thumbnailData),
            ImagePreviewDownsampler.attachmentMaxPixelSize
        )
    }

    func testImagePreviewDownsamplerSkipsWorkWhenCallerIsCancelled() async throws {
        let originalData = try makeJPEGData(size: CGSize(width: 1_600, height: 1_200))
        let task = Task<Data?, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }

            return await ImagePreviewDownsampler.previewDataAsync(
                from: originalData,
                maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
            )
        }

        task.cancel()

        let thumbnailData = await task.value

        XCTAssertNil(thumbnailData)
    }

    @MainActor
    func testUploadAttachmentFailurePreservesExistingPendingAttachment() async throws {
        var uploadCount = 0
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            uploadCount += 1

            if uploadCount == 1 {
                return apiTestJSONResponse("""
                {
                  "filename": "notes.txt",
                  "path": "/tmp/workspace/notes.txt",
                  "size": 5,
                  "mime": "text/plain",
                  "is_image": false
                }
                """, for: request)
            }

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 413,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )
            return (try XCTUnwrap(response), Data("too large".utf8))
        }

        await viewModel.uploadAttachment(data: Data("hello".utf8), filename: "notes.txt")
        XCTAssertEqual(viewModel.pendingAttachments.count, 1)

        await viewModel.uploadAttachment(data: Data("large".utf8), filename: "large.bin")

        XCTAssertEqual(viewModel.pendingAttachments.count, 1)
        XCTAssertEqual(viewModel.pendingAttachments.first?.name, "notes.txt")
        XCTAssertNotNil(viewModel.uploadAttachmentErrorMessage)
        XCTAssertNotNil(viewModel.lastError)
    }

    @MainActor
    func testDuplicateUploadFilenamesUseDistinctServerPathsAndLocalPreviews() async throws {
        let imageA = try makeJPEGData(size: CGSize(width: 12, height: 12))
        let imageB = try makeJPEGData(size: CGSize(width: 16, height: 12))
        var uploadedFilenames: [String] = []
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/upload":
                let filename = try apiTestMultipartFilename(from: request)
                uploadedFilenames.append(filename)
                return apiTestJSONResponse("""
                {
                  "filename": "\(filename)",
                  "path": "/tmp/workspace/\(filename)",
                  "size": 4,
                  "mime": "image/jpeg",
                  "is_image": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.uploadAttachment(data: Data("image-a".utf8), filename: "shared-image.jpg", previewData: imageA)
        await viewModel.uploadAttachment(data: Data("image-b".utf8), filename: "shared-image.jpg", previewData: imageB)

        XCTAssertEqual(uploadedFilenames.count, 2)
        XCTAssertEqual(uploadedFilenames[0], "shared-image.jpg")
        XCTAssertTrue(uploadedFilenames[1].hasPrefix("shared-image-"))
        XCTAssertTrue(uploadedFilenames[1].hasSuffix(".jpg"))
        XCTAssertNotEqual(uploadedFilenames[0], uploadedFilenames[1])
        XCTAssertEqual(viewModel.pendingAttachments.map(\.name), ["shared-image.jpg", "shared-image.jpg"])
        XCTAssertEqual(Set(viewModel.pendingAttachments.map(\.path)).count, 2)

        let didStart = await viewModel.seedLegacyResponseForTesting("Compare these")

        XCTAssertTrue(didStart)
        let message = try XCTUnwrap(viewModel.messages.first)
        let messageID = try XCTUnwrap(message.messageId)
        let paths = try XCTUnwrap(message.attachments?.compactMap(\.path))
        let previews = try XCTUnwrap(viewModel.localAttachmentPreviews[messageID])
        XCTAssertEqual(Set(previews.keys), Set(paths))
        XCTAssertEqual(previews[paths[0]], imageA)
        XCTAssertEqual(previews[paths[1]], imageB)
    }

    @MainActor
    func testSelectWorkspaceUpdatesSelectionAndRollsBackOnFailure() async throws {
        var updateCount = 0
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session/update")
            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["session_id"] as? String, "session-abc")
            XCTAssertEqual(body["model"] as? String, "gpt-5.4")

            updateCount += 1
            if updateCount == 1 {
                XCTAssertEqual(body["workspace"] as? String, "/tmp/next")
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/next",
                    "model": "gpt-5.4"
                  }
                }
                """, for: request)
            }

            XCTAssertEqual(body["workspace"] as? String, "/tmp/failing")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"workspace failed"}"#.utf8))
        }

        XCTAssertEqual(viewModel.selectedWorkspacePath, "/tmp/workspace")

        await viewModel.selectWorkspacePath("/tmp/next")
        XCTAssertEqual(viewModel.selectedWorkspacePath, "/tmp/next")
        XCTAssertNil(viewModel.composerConfigurationErrorMessage)

        await viewModel.selectWorkspacePath("/tmp/failing")
        XCTAssertEqual(viewModel.selectedWorkspacePath, "/tmp/next")
        XCTAssertNotNil(viewModel.composerConfigurationErrorMessage)
        XCTAssertEqual(updateCount, 2)
    }

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
    func testSubmitGoalAttachesToServerStartedKickoffStream() async throws {
        let streamClient = SpySSEStreamingClient()
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "nil")

            switch path {
            case "/api/goal":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["args"] as? String, "Ship the TestFlight build")
                XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
                XCTAssertEqual(body["model"] as? String, "gpt-5.4")

                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "action": "set",
                  "message": "Goal set.",
                  "goal": {
                    "goal": "Ship the TestFlight build",
                    "status": "active",
                    "turns_used": 0,
                    "max_turns": 20
                  },
                  "kickoff_prompt": "Start executing the goal."
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "active_stream_id": "stream-goal",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Start executing the goal.",
                        "timestamp": 1770000100,
                        "message_id": "user-goal"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didSubmit = await viewModel.submitGoal(args: "Ship the TestFlight build")

        XCTAssertTrue(didSubmit)
        XCTAssertEqual(requestedPaths, ["/api/goal", "/api/session"])
        XCTAssertEqual(viewModel.currentGoal?.goal, "Ship the TestFlight build")
        XCTAssertEqual(viewModel.currentGoal?.status, "active")
        XCTAssertTrue(viewModel.hasActivatedGoalCommand)
        XCTAssertEqual(viewModel.activeStreamID, "stream-goal")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.startedURLs.first?.path, "/api/chat/stream")
        XCTAssertEqual(viewModel.messages.map(\.role), ["user"])
        XCTAssertEqual(viewModel.messages.last?.content, "Start executing the goal.")
        XCTAssertEqual(viewModel.pinnedLocalNotices, ["Goal set."])

        streamClient.emit(.token("Working now."))

        XCTAssertEqual(viewModel.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.content, "Working now.")
    }

    @MainActor
    func testGoalSlashCommandSubmitsStatusAndRevealsGoalControls() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/goal")

            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            XCTAssertEqual(body["session_id"] as? String, "session-abc")
            XCTAssertEqual(body["args"] as? String, "status")
            XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
            XCTAssertEqual(body["model"] as? String, "gpt-5.4")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "action": "status",
              "message": "Goal is active.",
              "goal": {
                "goal": "Ship the TestFlight build",
                "status": "active",
                "turns_used": 1,
                "max_turns": 20
              }
            }
            """, for: request)
        }

        XCTAssertFalse(viewModel.hasActivatedGoalCommand)

        let result = await SlashCommandExecutor.execute(text: "/goal", viewModel: viewModel)

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertTrue(viewModel.hasActivatedGoalCommand)
        XCTAssertEqual(viewModel.currentGoal?.goal, "Ship the TestFlight build")
        XCTAssertEqual(viewModel.currentGoal?.status, "active")
        XCTAssertEqual(viewModel.messages.map(\.role), ["local_notice"])
        XCTAssertEqual(viewModel.messages.first?.content, "Goal is active.")
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

        XCTAssertEqual(result, .sendAsMessage)
        XCTAssertEqual(requestedPaths, ["/api/skills"])
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

        XCTAssertEqual(result, .sendAsMessage)
        XCTAssertEqual(requestedPaths, ["/api/skills"])
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
    func testSkillShortcutDirectRefusalPrecedesUnknownCommandFallthrough() async throws {
        let transport = SendRetirementDirectTransport()
        let server = URL(string: "https://example.test")!
        let runtime = try HermesServerRuntime(origin: server) { sink in
            transport.installSink(sink)
            return transport
        }
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Unsupported direct shortcut must not use a WebUI lookup or send")
            throw URLError(.badURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let viewModel = ChatViewModel(session: SessionSummary(profile: "work"), server: server,
            client: client, gatewayRuntimeProvider: { _ in runtime })
        let result = await SlashCommandExecutor.execute(text: "/spotify check songs", viewModel: viewModel)
        XCTAssertEqual(result, .unsupported(friendlyMessage: "Skills are not available in direct Hermes mode yet."))
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(transport.methods().isEmpty)
        await runtime.stop()
    }

    @MainActor
    func testGoalResumeSlashCommandStillUsesGoalEndpoint() async throws {
        var requestedPaths: [String] = []
        let viewModel = try makeViewModel { request in
            let path = request.url?.path
            requestedPaths.append(path ?? "nil")

            switch path {
            case "/api/goal":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["args"] as? String, "resume")
                XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
                XCTAssertEqual(body["model"] as? String, "gpt-5.4")

                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "action": "resume",
                  "message": "Goal resumed.",
                  "goal": {
                    "goal": "Ship the TestFlight build",
                    "status": "active",
                    "turns_used": 2,
                    "max_turns": 20
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await SlashCommandExecutor.execute(text: "/goal resume", viewModel: viewModel)

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(requestedPaths, ["/api/goal"])
        XCTAssertTrue(viewModel.hasActivatedGoalCommand)
        XCTAssertEqual(viewModel.currentGoal?.status, "active")
        XCTAssertEqual(viewModel.messages.map(\.role), ["local_notice"])
        XCTAssertEqual(viewModel.messages.first?.content, "Goal resumed.")
    }

    @MainActor
    func testApprovalStreamPublishesPromptAndRespondsWithoutStoppingChatStream() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        var respondBody: [String: Any]?
        var didFetchPendingAfterResponse = false
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/approval/respond":
                respondBody = try XCTUnwrap(apiTestJSONBody(from: request))
                return apiTestJSONResponse(#"{"ok": true, "choice": "once"}"#, for: request)
            case "/api/approval/pending":
                didFetchPendingAfterResponse = true
                return apiTestJSONResponse(#"{"pending": null, "pending_count": 0}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Run the installer")

        XCTAssertTrue(didStart)
        XCTAssertEqual(streamClient.startedURLs.first?.path, "/api/chat/stream")
        XCTAssertEqual(approvalStreamClient.startedURLs.first?.path, "/api/approval/stream")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(approvalStreamClient.startedURLs.first), resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "session_id" })?
                .value,
            "session-abc"
        )

        let gatewayApproval = ApprovalPendingResponse.streamPayload(from: Data("""
        {
          "pending": {
            "id": "approval-1",
            "command": "curl https://example.test/install.sh | bash",
            "description": "High risk command",
            "pattern_keys": ["network_download", "pipe_to_shell"]
          },
          "pending_count": 2
        }
        """.utf8))
        approvalStreamClient.emit(.approvalPending(gatewayApproval))

        XCTAssertEqual(viewModel.approvalPrompt?.sessionID, "session-abc")
        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "approval-1")
        XCTAssertEqual(viewModel.approvalPrompt?.pendingCount, 2)
        XCTAssertEqual(viewModel.approvalPrompt?.patternKeys, ["network_download", "pipe_to_shell"])

        await viewModel.respondToApproval(.once)

        XCTAssertEqual(respondBody?["session_id"] as? String, "session-abc")
        XCTAssertEqual(respondBody?["choice"] as? String, "once")
        XCTAssertEqual(respondBody?["approval_id"] as? String, "approval-1")
        XCTAssertTrue(didFetchPendingAfterResponse)
        XCTAssertNil(viewModel.approvalPrompt)
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    @MainActor
    func testApprovalResponseDoesNotUseSyntheticDisplayIDWhenServerIdentifierMissing() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        var respondBody: [String: Any]?
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/approval/respond":
                respondBody = try XCTUnwrap(apiTestJSONBody(from: request))
                return apiTestJSONResponse(#"{"ok": true, "choice": "once"}"#, for: request)
            case "/api/approval/pending":
                return apiTestJSONResponse(#"{"pending": null, "pending_count": 0}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Run the installer")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(
                command: "make install",
                description: "Install command",
                patternKey: "install"
            ),
            pendingCount: 1
        )))

        XCTAssertEqual(viewModel.approvalPrompt?.pending.id, "make install-Install command-install")

        await viewModel.respondToApproval(.once)

        XCTAssertEqual(respondBody?["session_id"] as? String, "session-abc")
        XCTAssertEqual(respondBody?["choice"] as? String, "once")
        XCTAssertNil(respondBody?["approval_id"])
    }

    @MainActor
    func testApprovalResponseFailureKeepsPromptAndPublishesActionError() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        let clarifyStreamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/approval/respond":
                throw URLError(.timedOut)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Run the installer")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(
                approvalId: "approval-1",
                command: "make install",
                description: "Install command",
                patternKey: "install"
            ),
            pendingCount: 1
        )))

        let didRespond = await viewModel.respondToApproval(.deny)

        XCTAssertFalse(didRespond)
        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "approval-1")
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(viewModel.approvalErrorMessage, viewModel.sendErrorMessage)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    @MainActor
    func testApprovalStale409DismissesPromptWithFriendlyExpiredMessage() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        let clarifyStreamClient = SpySSEStreamingClient()
        var didRefreshPendingAfterStale = false
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/approval/respond":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"ok": false, "error": "Approval prompt expired or not found.", "stale": true}"#.utf8))
            case "/api/approval/pending":
                didRefreshPendingAfterStale = true
                return apiTestJSONResponse(#"{"pending": null}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Run the installer")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(
                approvalId: "approval-1",
                command: "make install",
                description: "Install command",
                patternKey: "install"
            ),
            pendingCount: 1
        )))

        let didRespond = await viewModel.respondToApproval(.once)

        // Expired prompt: the stale card dismisses with a friendly explanation
        // instead of sticking around behind a generic failure (issue #25).
        XCTAssertFalse(didRespond)
        XCTAssertNil(viewModel.approvalPrompt)
        XCTAssertNil(viewModel.approvalErrorMessage)
        XCTAssertEqual(
            viewModel.sendErrorMessage,
            PendingPromptExpiredError(prompt: .approval).localizedDescription
        )
        XCTAssertTrue(didRefreshPendingAfterStale)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    @MainActor
    func testApprovalFallbackPollingFailureStaysDiagnosticOnly() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        let approvalPendingRequests = LockedCounter()
        let pollingIntervals = ChatPollingIntervals(
            approvalNanoseconds: 100_000_000,
            clarificationNanoseconds: 100_000_000,
            backgroundNanoseconds: 100_000_000
        )
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            pollingIntervals: pollingIntervals
        ) { request in
            switch request.url?.path {
            case "/api/approval/pending":
                _ = approvalPendingRequests.increment()
                throw URLError(.timedOut)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Run the installer")
        XCTAssertTrue(didStart)

        approvalStreamClient.emit(.transportError("approval stream failed"))
        try await waitUntil {
            approvalPendingRequests.count > 0
        }

        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertNil(viewModel.lastError)
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertNil(viewModel.approvalErrorMessage)

        viewModel.cleanupPollingTasks()
    }

    @MainActor
    func testCleanupPollingTasksCancelsStoredPollingTasks() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        let clarifyStreamClient = SpySSEStreamingClient()
        let approvalPendingRequests = LockedCounter()
        let clarificationPendingRequests = LockedCounter()
        let backgroundStatusRequests = LockedCounter()
        let pollingIntervals = ChatPollingIntervals(
            approvalNanoseconds: 100_000_000,
            clarificationNanoseconds: 100_000_000,
            backgroundNanoseconds: 100_000_000
        )
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient,
            clarifyStreamClient: clarifyStreamClient,
            pollingIntervals: pollingIntervals
        ) { request in
            switch request.url?.path {
            case "/api/approval/pending":
                _ = approvalPendingRequests.increment()
                return apiTestJSONResponse(#"{"pending": null, "pending_count": 0}"#, for: request)
            case "/api/clarify/pending":
                _ = clarificationPendingRequests.increment()
                return apiTestJSONResponse(#"{"pending": null, "pending_count": 0}"#, for: request)
            case "/api/background":
                return apiTestJSONResponse(#"{"task_id": "task-1", "stream_id": "stream-bg", "session_id": "background-1"}"#, for: request)
            case "/api/background/status":
                _ = backgroundStatusRequests.increment()
                return apiTestJSONResponse(#"{"results": []}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Run the installer")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.transportError("approval stream failed"))
        clarifyStreamClient.emit(.transportError("clarification stream failed"))

        let result = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "background")),
            args: "audit tests"
        )
        XCTAssertEqual(result, .executed(message: "Background task started. I'll add the result here when it completes."))

        try await waitUntil {
            approvalPendingRequests.count > 0 &&
                clarificationPendingRequests.count > 0 &&
                backgroundStatusRequests.count > 0
        }

        viewModel.cleanupPollingTasks()
        let approvalCountAfterCleanup = approvalPendingRequests.count
        let clarificationCountAfterCleanup = clarificationPendingRequests.count
        let backgroundCountAfterCleanup = backgroundStatusRequests.count

        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(approvalPendingRequests.count, approvalCountAfterCleanup)
        XCTAssertEqual(clarificationPendingRequests.count, clarificationCountAfterCleanup)
        XCTAssertEqual(backgroundStatusRequests.count, backgroundCountAfterCleanup)
    }

    @MainActor
    func testApprovalForDifferentSessionDoesNotRenderOverCurrentChat() async throws {
        let viewModel = try makeViewModel { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)

        viewModel.applyApprovalUpdate(
            ApprovalPendingResponse(
                pending: PendingApproval(
                    approvalId: "other-approval",
                    command: "danger",
                    description: "Other session",
                    patternKey: "other"
                ),
                pendingCount: 1
            ),
            sessionID: "other-session"
        )

        XCTAssertNil(viewModel.approvalPrompt)

        viewModel.applyApprovalUpdate(
            ApprovalPendingResponse(
                pending: PendingApproval(
                    approvalId: "current-approval",
                    command: "python script.py",
                    description: "Current session",
                    patternKey: "python_exec"
                ),
                pendingCount: 1
            ),
            sessionID: "session-abc"
        )

        XCTAssertEqual(viewModel.approvalPrompt?.pending.approvalId, "current-approval")
    }

    @MainActor
    func testSkipAllThisSessionEnablesYoloAndClearsPrompt() async throws {
        let streamClient = SpySSEStreamingClient()
        let approvalStreamClient = SpySSEStreamingClient()
        var yoloBody: [String: Any]?
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            approvalStreamClient: approvalStreamClient
        ) { request in
            switch request.url?.path {
            case "/api/session/yolo":
                yoloBody = try XCTUnwrap(apiTestJSONBody(from: request))
                return apiTestJSONResponse(#"{"ok": true, "yolo_enabled": true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Run setup")
        XCTAssertTrue(didStart)
        approvalStreamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(
                approvalId: "approval-1",
                command: "make install",
                description: "Install command",
                patternKey: "install"
            ),
            pendingCount: 1
        )))
        XCTAssertNotNil(viewModel.approvalPrompt)

        await viewModel.skipApprovalsForCurrentSession()

        XCTAssertEqual(yoloBody?["session_id"] as? String, "session-abc")
        XCTAssertEqual(yoloBody?["enabled"] as? Bool, true)
        XCTAssertEqual(viewModel.isSessionApprovalBypassEnabled, true)
        XCTAssertNil(viewModel.approvalPrompt)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }

    @MainActor
    func testLiveStreamEventsUpdateTranscriptBeforeCompletion() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")

        streamClient.emit(.reasoning("I need to inspect the workspace."))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "read_file",
            preview: "Reading PROJECT_SPEC.md",
            args: ["path": .string("PROJECT_SPEC.md")],
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool.completed",
            name: "read_file",
            preview: "Read PROJECT_SPEC.md",
            args: ["path": .string("PROJECT_SPEC.md")],
            duration: 0.25,
            isError: false
        )))
        streamClient.emit(.token("First live token."))

        XCTAssertEqual(viewModel.liveReasoningText, "I need to inspect the workspace.")
        XCTAssertEqual(viewModel.liveToolCalls.count, 1)
        XCTAssertEqual(viewModel.liveToolCalls.first?.name, "read_file")
        XCTAssertEqual(viewModel.liveToolCalls.first?.isCompleted, true)
        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.content, "First live token.")
        XCTAssertNotNil(viewModel.streamingAssistantMessageID)
        XCTAssertFalse(viewModel.responseCompletionHapticTrigger > 0)
    }

    @MainActor
    func testReasoningAndToolEventsAnchorToStableAssistantTurnBeforeFirstToken() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Use tools before answering")
        XCTAssertTrue(didStart)

        streamClient.emit(.reasoning("I should inspect the workspace."))

        let liveAssistantID = try XCTUnwrap(viewModel.streamingAssistantMessageID)
        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.messageId, liveAssistantID)
        XCTAssertEqual(viewModel.messages.last?.content, "")
        XCTAssertEqual(viewModel.reasoningAnchorMessageID, liveAssistantID)
        XCTAssertFalse(viewModel.hasStreamingAssistantMessageContent)

        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "terminal",
            preview: "pwd",
            args: ["cmd": .string("pwd")],
            duration: nil,
            isError: nil
        )))

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.streamingAssistantMessageID, liveAssistantID)
        XCTAssertEqual(viewModel.toolCallAnchorMessageID, liveAssistantID)
        XCTAssertEqual(viewModel.liveToolCalls.map(\.name), ["terminal"])

        streamClient.emit(.token("Live answer starts now."))

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.streamingAssistantMessageID, liveAssistantID)
        XCTAssertEqual(viewModel.messages.last?.messageId, liveAssistantID)
        XCTAssertEqual(viewModel.messages.last?.content, "Live answer starts now.")
        XCTAssertTrue(viewModel.hasStreamingAssistantMessageContent)
    }

    @MainActor
    func testLiveStreamScrollTriggerCoalescesRapidUpdates() async throws {
        let streamClient = SpySSEStreamingClient()
        streamClient.automaticallyFlushPendingStreamingContent = false
        // Inject a tiny coalescing window. Determinism comes from flushing
        // synchronously and awaiting the pending scroll-trigger task below, not from
        // this value; a small delay just keeps those awaits fast. The production
        // default (16ms) is exercised everywhere else.
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            streamingScrollCoalescingDelayNanoseconds: 1_000_000
        ) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Stream a long response")
        XCTAssertTrue(didStart)

        // sendMessage's optimistic user-message append schedules a coalesced scroll
        // trigger. Settle it so the increments measured below come only from the
        // streaming bursts — this is the task that used to race the real 16ms window
        // before the synchronous assertion ran.
        await viewModel.awaitPendingStreamingScrollTriggerForTesting()
        let initialTrigger = viewModel.streamingScrollTrigger

        // Burst 1: 20 rapid tokens batch behind a single coalesced flush. The
        // transcript follow is size-change only — token flushes must not bump
        // streamingScrollTrigger or ChatTranscriptView re-evaluates every row.
        for index in 0..<20 {
            streamClient.emit(.token("token-\(index) "))
        }
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger)

        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger)
        await viewModel.awaitPendingStreamingScrollTriggerForTesting()
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger)
        XCTAssertTrue(viewModel.messages.last?.content?.hasPrefix("token-0 token-1") == true)

        streamClient.emit(.reasoning("Check the next step."))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "read_file",
            preview: "Reading README.md",
            args: ["path": .string("README.md")],
            duration: nil,
            isError: nil
        )))
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger)
        viewModel.flushPendingStreamingContent()
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger)
        await viewModel.awaitPendingStreamingScrollTriggerForTesting()
        XCTAssertEqual(viewModel.streamingScrollTrigger, initialTrigger)
    }

    @MainActor
    func testDisplayedTranscriptMessagesMemoMatchesPureMappingAcrossAppendsAndEdits() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        func assertMemoMatchesPureMapping(_ message: String, line: UInt = #line) {
            XCTAssertEqual(
                viewModel.displayedTranscriptMessages,
                ChatViewModel.transcriptMessages(
                    from: viewModel.messages,
                    messageOffset: viewModel.messagesOffset
                ),
                message,
                line: line
            )
        }

        // Empty transcript before any work.
        assertMemoMatchesPureMapping("memo should match for an empty transcript")

        // Append: optimistic user message + streaming assistant turn.
        let didStart = await viewModel.seedLegacyResponseForTesting("Stream a long response")
        XCTAssertTrue(didStart)
        assertMemoMatchesPureMapping("memo should match after the optimistic append")

        // Edit: streaming tokens mutate the assistant message content in place.
        streamClient.emit(.token("first chunk "))
        viewModel.flushPendingStreamingContent()
        XCTAssertTrue(viewModel.messages.last?.content?.contains("first chunk") == true)
        assertMemoMatchesPureMapping("memo should match after a streaming content edit")

        // Further edit: a second flush updates the same message again.
        streamClient.emit(.token("second chunk "))
        viewModel.flushPendingStreamingContent()
        assertMemoMatchesPureMapping("memo should match after a second content edit")
    }

    @MainActor
    func testInterimAssistantEventUpdatesTranscriptBeforeCompletion() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Use the project skill")
        XCTAssertTrue(didStart)

        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(
            text: "Inspecting repo structure.",
            alreadyStreamed: false
        )))

        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.content, "Inspecting repo structure.")
        XCTAssertNotNil(viewModel.streamingAssistantMessageID)
        XCTAssertFalse(viewModel.responseCompletionHapticTrigger > 0)
    }

    @MainActor
    func testLoadMessagesClearsPendingStreamingBuffersBeforeReload() async throws {
        let streamClient = SpySSEStreamingClient()
        streamClient.automaticallyFlushPendingStreamingContent = false
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "active_stream_id": "stream-123",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "From server.",
                        "timestamp": 1770000101,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)

        for index in 0..<5 {
            streamClient.emit(.token("buffered-\(index) "))
        }

        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.messages.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(viewModel.messages.last?.content, "From server.")

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(viewModel.messages.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(viewModel.messages.last?.content, "From server.")
    }

    @MainActor
    func testInitialLoadKeepsTheServerWindowBoundedWithoutRenderableExpansion() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            let query = Dictionary(
                uniqueKeysWithValues: (URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []).map { ($0.name, $0.value) }
            )
            XCTAssertEqual(query["msg_limit"], "50")
            XCTAssertNil(query["msg_before"])
            XCTAssertNil(query["expand_renderable"])

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "message_count": 100,
                "messages_offset": 50,
                "messages_truncated": true,
                "messages": [
                  {
                    "role": "user",
                    "content": "Recent message",
                    "timestamp": 1770000100,
                    "message_id": "recent-user"
                  }
                ]
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.messages.map(\.messageId), ["recent-user"])
        XCTAssertTrue(viewModel.hasOlderMessages)
    }

    @MainActor
    func testLoadMessagesDuringActiveStreamPreservesLiveStateWhenServerSnapshotIsStale() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)

        streamClient.emit(.reasoning("I need to inspect the workspace."))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "read_file",
            preview: "Reading CURRENT.md",
            args: ["path": .string("CURRENT.md")],
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.token("Partial live answer."))

        let liveAssistantID = try XCTUnwrap(viewModel.streamingAssistantMessageID)

        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(viewModel.liveReasoningText, "I need to inspect the workspace.")
        XCTAssertEqual(viewModel.liveToolCalls.map(\.name), ["read_file"])
        XCTAssertEqual(viewModel.streamingAssistantMessageID, liveAssistantID)
        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(viewModel.messages.last?.content, "Partial live answer.")
    }

    @MainActor
    func testTransportReconnectUsesReplayWhenInactiveStreamHasJournal() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": false,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("Partial live answer."), lastEventID: "session-abc:4")
        streamClient.emit(.transportError("lost connection"), lastEventID: "session-abc:4")

        try await waitUntil {
            streamClient.startedURLs.count == 2
        }

        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let replayQueryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(replayQueryItems.first(where: { $0.name == "stream_id" })?.value, "stream-123")
        XCTAssertEqual(replayQueryItems.first(where: { $0.name == "replay" })?.value, "1")
        XCTAssertEqual(replayQueryItems.first(where: { $0.name == "after_seq" })?.value, "4")
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
    }


    @MainActor
    func testActiveStreamStatusRefreshReloadsTranscriptWhenSSECompletionIsMissed() async throws {
        let streamClient = SpySSEStreamingClient()
        var didRequestStatus = false
        var didReloadMessages = false
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                didRequestStatus = true
                return apiTestJSONResponse("""
                {
                  "active": false,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                didReloadMessages = true
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "Final answer loaded without leaving the chat.",
                        "timestamp": 1770000110,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working"])

        await viewModel.refreshTranscriptIfActiveStreamCompleted(streamID: "stream-123")

        XCTAssertTrue(didRequestStatus)
        XCTAssertTrue(didReloadMessages)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Keep working",
            "Final answer loaded without leaving the chat."
        ])
    }

    @MainActor
    func testActiveStreamStatusRefreshWaitsForFinalTranscriptBeforeStoppingStream() async throws {
        let streamClient = SpySSEStreamingClient()
        var sessionReloadCount = 0
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": false,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                sessionReloadCount += 1
                if sessionReloadCount == 1 {
                    return apiTestJSONResponse("""
                    {
                      "session": {
                        "session_id": "session-abc",
                        "title": "Planning",
                        "messages": [
                          {
                            "role": "user",
                            "content": "Keep working",
                            "timestamp": 1770000100,
                            "message_id": "user-1"
                          }
                        ]
                      }
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "Final answer arrived after the stream was marked inactive.",
                        "timestamp": 1770000110,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("Partial live answer."))

        await viewModel.refreshTranscriptIfActiveStreamCompleted(streamID: "stream-123")

        XCTAssertEqual(sessionReloadCount, 1)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Keep working",
            "Partial live answer."
        ])

        await viewModel.refreshTranscriptIfActiveStreamCompleted(streamID: "stream-123")

        XCTAssertEqual(sessionReloadCount, 2)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Keep working",
            "Final answer arrived after the stream was marked inactive."
        ])
    }

    func testActiveStreamStatusRefreshTreatsToolOnlyAssistantAsCompletedResponse() {
        runMainActorTest {
            let streamClient = SpySSEStreamingClient()
            let viewModel = try self.makeViewModel(streamClient: streamClient) { request in
                switch request.url?.path {
                case "/api/chat/stream/status":
                    return apiTestJSONResponse("""
                    {
                      "active": false,
                      "stream_id": "stream-123"
                    }
                    """, for: request)
                case "/api/session":
                    return apiTestJSONResponse("""
                    {
                      "session": {
                        "session_id": "session-abc",
                        "title": "Planning",
                        "messages": [
                          {
                            "role": "user",
                            "content": "Run terminal",
                            "timestamp": 1770000100,
                            "message_id": "user-1"
                          },
                          {
                            "role": "assistant",
                            "content": "",
                            "timestamp": 1770000110,
                            "message_id": "assistant-tool",
                            "tool_calls": [
                              {
                                "id": "functions.terminal:1",
                                "function": {
                                  "name": "terminal",
                                  "arguments": "{\\"command\\":\\"pwd\\"}"
                                }
                              }
                            ]
                          },
                          {
                            "role": "tool",
                            "content": "/Users/hermes",
                            "timestamp": 1770000111,
                            "message_id": "tool-1",
                            "tool_call_id": "functions.terminal:1"
                          }
                        ]
                      }
                    }
                    """, for: request)
                default:
                    XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                    throw URLError(.badURL)
                }
            }

            let didStart = await viewModel.seedLegacyResponseForTesting("Run terminal")
            XCTAssertTrue(didStart)

            await viewModel.refreshTranscriptIfActiveStreamCompleted(streamID: "stream-123")

            XCTAssertNil(viewModel.activeStreamID)
            XCTAssertEqual(streamClient.stopCount, 1)
            XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant", "tool"])
            XCTAssertEqual(viewModel.messages.first(where: { $0.role == "assistant" })?.toolCalls?.count, 1)
        }
    }

    @MainActor
    func testAlreadyStreamedInterimAssistantDoesNotDuplicateTokenText() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Explain this")
        XCTAssertTrue(didStart)

        streamClient.emit(.token("Inspecting repo structure."))
        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(
            text: "Inspecting repo structure.",
            alreadyStreamed: true
        )))

        XCTAssertEqual(viewModel.messages.last?.content, "Inspecting repo structure.")
    }

    @MainActor
    func testDoneSessionReconcilesTranscriptAfterApprovalResume() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Do it one more time")
        XCTAssertTrue(didStart)

        streamClient.emit(.approvalPending(ApprovalPendingResponse(
            pending: PendingApproval(
                approvalId: "approval-1",
                command: "curl https://example.test/install.sh | bash",
                description: "Approval required",
                patternKey: "network_download"
            ),
            pendingCount: 1
        )))
        streamClient.emit(.token("Same"))

        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "title": "Approval test",
          "messages": [
            {
              "role": "user",
              "content": "Do it one more time",
              "message_id": "user-1"
            },
            {
              "role": "assistant",
              "content": "Same result -- approval gate triggered, then the usual JSON-is-not-bash errors.",
              "message_id": "assistant-1"
            }
          ]
        }
        """)
        streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

        XCTAssertNil(viewModel.approvalPrompt)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.displayTitle, "Approval test")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), [
            "Do it one more time",
            "Same result -- approval gate triggered, then the usual JSON-is-not-bash errors."
        ])
        XCTAssertEqual(viewModel.messages.last?.messageId, "assistant-1")
    }

    func testCompletedStreamSessionDoesNotRequireFollowUpTranscriptRefresh() {
        runMainActorTest {
            let streamClient = SpySSEStreamingClient()
            let viewModel = try self.makeViewModel(streamClient: streamClient) { request in
                XCTFail("Renderer setup must not submit a legacy chat request")
                throw URLError(.badURL)
            }

            let didStart = await viewModel.seedLegacyResponseForTesting("Summarize")
            XCTAssertTrue(didStart)

            let completedSession = try self.makeSessionDetail("""
            {
              "session_id": "session-abc",
              "title": "Planning",
              "messages": [
                {
                  "role": "user",
                  "content": "Summarize",
                  "message_id": "user-1"
                },
                {
                  "role": "assistant",
                  "content": "Done.",
                  "message_id": "assistant-1"
                }
              ]
            }
            """)

            streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

            XCTAssertNil(viewModel.activeStreamID)
            XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1)
            XCTAssertFalse(viewModel.responseCompletionNeedsTranscriptRefresh)
            XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Summarize", "Done."])
        }
    }

    func testDoneWithoutCompletedSessionRequiresFollowUpTranscriptRefresh() {
        runMainActorTest {
            let streamClient = SpySSEStreamingClient()
            let viewModel = try self.makeViewModel(streamClient: streamClient) { request in
                XCTFail("Renderer setup must not submit a legacy chat request")
                throw URLError(.badURL)
            }

            let didStart = await viewModel.seedLegacyResponseForTesting("Summarize")
            XCTAssertTrue(didStart)

            streamClient.emit(.token("Done."))
            streamClient.emit(.done(DoneStreamEvent(session: nil)))

            XCTAssertNil(viewModel.activeStreamID)
            XCTAssertEqual(viewModel.responseCompletionHapticTrigger, 1)
            XCTAssertTrue(viewModel.responseCompletionNeedsTranscriptRefresh)
            XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Summarize", "Done."])
        }
    }

    @MainActor
    func testCompletedStreamSessionKeepsActivityFromMessageToolCalls() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Check the workspace")
        XCTAssertTrue(didStart)
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "terminal",
            preview: "pwd",
            args: ["command": .string("pwd")],
            duration: nil,
            isError: nil
        )))

        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {
              "role": "user",
              "content": "Check the workspace",
              "message_id": "user-1"
            },
            {
              "role": "assistant",
              "content": "",
              "message_id": "assistant-tool",
              "tool_calls": [
                {
                  "id": "call-1",
                  "function": {
                    "name": "terminal",
                    "arguments": "{\\"command\\":\\"pwd\\"}"
                  }
                }
              ]
            },
            {
              "role": "tool",
              "content": "/Users/uzair/project",
              "message_id": "tool-1",
              "tool_call_id": "call-1"
            },
            {
              "role": "assistant",
              "content": "The workspace is /Users/uzair/project.",
              "message_id": "assistant-final"
            }
          ]
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(viewModel.liveToolCalls.isEmpty)
        XCTAssertEqual(viewModel.completedToolCallGroups.count, 1)
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.anchorMessageID, "assistant-tool")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.activityTitle, "Activity: 1 tool")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.name, "terminal")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.preview, "/Users/uzair/project")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.args?["command"], .string("pwd"))
        XCTAssertEqual(
            viewModel.completedToolCallGroupsForAnchor("assistant-tool"),
            viewModel.completedToolCallGroups
        )
        XCTAssertTrue(viewModel.completedToolCallGroupsForAnchor(nil).isEmpty)
    }

    @MainActor
    func testCompletedStreamSessionMergesLiveFallbackIntoCompletedTurnActivity() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Check option 2")
        XCTAssertTrue(didStart)

        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool",
            name: "skill_view",
            preview: "xurl",
            args: ["name": .string("xurl")],
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool_complete",
            name: "skill_view",
            preview: "X/Twitter via xurl CLI",
            args: ["name": .string("xurl")],
            duration: 0.2,
            isError: false
        )))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool",
            name: "terminal",
            preview: "which xurl",
            args: ["command": .string("which xurl")],
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool_complete",
            name: "terminal",
            preview: "xurl not installed",
            args: ["command": .string("which xurl")],
            duration: 0.4,
            isError: false
        )))

        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {
              "role": "user",
              "content": "Check option 2",
              "message_id": "user-option"
            },
            {
              "role": "assistant",
              "message_id": "assistant-skills",
              "content": [
                {
                  "type": "tool_use",
                  "id": "toolu-skill-xurl",
                  "name": "skill_view",
                  "input": { "name": "xurl" }
                }
              ]
            },
            {
              "role": "assistant",
              "content": "xurl is not installed.",
              "message_id": "assistant-final"
            }
          ]
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(viewModel.liveToolCalls.isEmpty)
        XCTAssertEqual(viewModel.completedToolCallGroups.count, 1)
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.anchorMessageID, "assistant-skills")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.activityTitle, "Activity: 2 tools")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.map(\.name), ["skill_view", "terminal"])
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.id, "toolu-skill-xurl")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.preview, "X/Twitter via xurl CLI")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.last?.preview, "xurl not installed")
        XCTAssertEqual(
            viewModel.completedToolCallGroupsForAnchor("assistant-skills"),
            viewModel.completedToolCallGroups
        )
    }

    @MainActor
    func testCompletedStreamSessionDeduplicatesLiveFallbackToolsWithCompletedTranscriptTools() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("I am testing tool use. Use terminal and search files.")
        XCTAssertTrue(didStart)

        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool",
            name: "terminal",
            preview: "pwd",
            args: nil,
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool_complete",
            name: "terminal",
            preview: "/tmp/workspace",
            args: nil,
            duration: 0.2,
            isError: false
        )))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool",
            name: "search_files",
            preview: "README",
            args: nil,
            duration: nil,
            isError: nil
        )))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool_complete",
            name: "search_files",
            preview: "README.md",
            args: nil,
            duration: 0.4,
            isError: false
        )))

        XCTAssertEqual(viewModel.liveToolCalls.map(\.name), ["terminal", "search_files"])

        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {
              "role": "user",
              "content": "I am testing tool use. Use terminal and search files.",
              "message_id": "user-tools"
            },
            {
              "role": "assistant",
              "content": "",
              "message_id": "assistant-tools",
              "tool_calls": [
                {
                  "id": "call-terminal",
                  "function": {
                    "name": "terminal",
                    "arguments": "{\\"command\\":\\"pwd\\"}"
                  }
                },
                {
                  "id": "call-search",
                  "function": {
                    "name": "search_files",
                    "arguments": "{\\"pattern\\":\\"README\\"}"
                  }
                }
              ]
            },
            {
              "role": "tool",
              "content": "/tmp/workspace",
              "message_id": "tool-terminal",
              "tool_call_id": "call-terminal"
            },
            {
              "role": "tool",
              "content": "README.md",
              "message_id": "tool-search",
              "tool_call_id": "call-search"
            },
            {
              "role": "assistant",
              "content": "Done.",
              "message_id": "assistant-final"
            }
          ]
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(session: completedSession)))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(viewModel.liveToolCalls.isEmpty)
        XCTAssertEqual(viewModel.completedToolCallGroups.count, 1)
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.anchorMessageID, "assistant-tools")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.activityTitle, "Activity: 2 tools")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.map(\.name), ["terminal", "search_files"])
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.map(\.id), ["call-terminal", "call-search"])
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.preview, "/tmp/workspace")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.first?.args?["command"], .string("pwd"))
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.last?.preview, "README.md")
        XCTAssertEqual(viewModel.completedToolCallGroups.first?.toolCalls.last?.args?["pattern"], .string("README"))
    }

    @MainActor
    func testReloadPreservesCachedOptimisticUserMessageWhenServerTemporarilyOmitsIt() async throws {
        let context = try makeContext()
        let streamClient = SpySSEStreamingClient()
        let sendingViewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didStart = await sendingViewModel.seedLegacyResponseForTesting("Keep working", modelContext: context)

        XCTAssertTrue(didStart)
        XCTAssertEqual(sendingViewModel.messages.compactMap(\.content), ["Keep working"])
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: URL(string: "https://example.test")!,
                sessionID: "session-abc",
                in: context
            ).compactMap(\.content),
            ["Keep working"]
        )

        let reopenedViewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "Planning",
                "messages": [
                  {
                    "role": "assistant",
                    "content": "Recovered transcript.",
                    "timestamp": 1770000100,
                    "message_id": "assistant-1"
                  }
                ]
              }
            }
            """, for: request)
        }

        await reopenedViewModel.loadMessages(modelContext: context)

        XCTAssertEqual(reopenedViewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(reopenedViewModel.messages.compactMap(\.content), ["Keep working", "Recovered transcript."])
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: URL(string: "https://example.test")!,
                sessionID: "session-abc",
                in: context
            ).compactMap(\.content),
            ["Keep working", "Recovered transcript."]
        )
    }

    @MainActor
    func testLoadMessagesUsesCachedTranscriptForTunnelUnavailableFailure() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let otherServerURL = try XCTUnwrap(URL(string: "https://other.example.test"))
        let streamClient = SpySSEStreamingClient()
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "user", content: "Cached question", timestamp: 1_770_000_001, messageId: "cached-user"),
                ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
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
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
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

        let didStart = await viewModel.seedLegacyResponseForTesting("In-flight request")
        streamClient.emit(.token("Partial response"))

        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertNotNil(viewModel.streamingAssistantMessageID)

        await viewModel.loadMessages(modelContext: context)
        let didSend = await viewModel.sendMessage("New message", modelContext: context)

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
        XCTAssertFalse(didSend)
        XCTAssertEqual(viewModel.sendErrorMessage, "Direct Hermes connection is unavailable.")
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
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
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
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
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
            "The server or Cloudflare tunnel is unavailable. Check that the Mac is awake, hermes-webui is running, and the tunnel is connected."
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
            sessionID: "session-abc",
            in: context
        )
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
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
        XCTAssertEqual(viewModel.errorMessage, "The Hermes server hit an internal error. Check the server logs, then try again.")
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
            sessionID: "session-abc",
            in: context
        )
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "Fresh planning",
                "messages": [
                  {
                    "role": "user",
                    "content": "Fresh question",
                    "timestamp": 1770000100,
                    "message_id": "fresh-user"
                  },
                  {
                    "role": "assistant",
                    "content": "Fresh answer",
                    "timestamp": 1770000101,
                    "message_id": "fresh-assistant"
                  }
                ]
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages(modelContext: context)

        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh question", "Fresh answer"])
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: serverURL,
                sessionID: "session-abc",
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
            sessionID: "session-abc",
            in: context
        )

        let sessionRequestStarted = expectation(description: "session request started")
        let releaseSessionResponse = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            sessionRequestStarted.fulfill()
            XCTAssertEqual(releaseSessionResponse.wait(timeout: .now() + .seconds(5)), .success)
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "Fresh planning",
                "messages": [
                  {
                    "role": "user",
                    "content": "Fresh question",
                    "timestamp": 1770000100,
                    "message_id": "fresh-user"
                  },
                  {
                    "role": "assistant",
                    "content": "Fresh answer",
                    "timestamp": 1770000101,
                    "message_id": "fresh-assistant"
                  }
                ]
              }
            }
            """, for: request)
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
    func testPreparedCacheFirstLoadDropsStalePrefixAndPreservesShiftedServerOffset() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [
                ChatMessage(role: "assistant", content: "Stale cached prefix", timestamp: 1, messageId: "stale-prefix"),
                ChatMessage(role: "user", content: "Cached overlap", timestamp: 2, messageId: "overlap"),
                ChatMessage(role: "assistant", content: "Cached tail", timestamp: 3, messageId: "cached-tail")
            ],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "messages": [
                  {"role":"user","content":"Fresh overlap","timestamp":20,"message_id":"overlap"},
                  {"role":"assistant","content":"Fresh server tail","timestamp":21,"message_id":"server-tail"}
                ],
                "_messages_truncated": true,
                "_messages_offset": 10
              }
            }
            """, for: request)
        }

        viewModel.prepareInitialMessageLoad(modelContext: context)
        XCTAssertEqual(
            viewModel.messages.compactMap(\.content),
            ["Stale cached prefix", "Cached overlap", "Cached tail"]
        )

        await viewModel.loadMessages(modelContext: context)

        XCTAssertEqual(viewModel.messages.map(\.id), ["overlap", "server-tail"])
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh overlap", "Fresh server tail"])
        XCTAssertEqual(viewModel.messagesOffset, 10)
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
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            sessionRequestStarted.fulfill()
            XCTAssertEqual(releaseSessionResponse.wait(timeout: .now() + .seconds(5)), .success)
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "Fresh planning",
                "messages": [
                  {
                    "role": "user",
                    "content": "Fresh question",
                    "timestamp": 1770000100,
                    "message_id": "fresh-user"
                  }
                ]
              }
            }
            """, for: request)
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
            sessionID: "session-abc",
            in: context
        )

        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "Fresh planning",
                "messages": [
                  {
                    "role": "user",
                    "content": "Fresh question",
                    "timestamp": 1770000100,
                    "message_id": "fresh-user"
                  },
                  {
                    "role": "assistant",
                    "content": "Fresh answer",
                    "timestamp": 1770000101,
                    "message_id": "fresh-assistant"
                  }
                ]
              }
            }
            """, for: request)
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
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "Fresh planning",
                "messages": [
                  {
                    "role": "user",
                    "content": "Fresh question",
                    "timestamp": 1770000100,
                    "message_id": "fresh-user"
                  }
                ]
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages(modelContext: context)

        // No cache was rendered first, so there is nothing to re-pin and the token stays put.
        XCTAssertEqual(viewModel.cacheFirstReconcileScrollToken, 0)
    }

    @MainActor
    func testCacheFirstRevertPreservesOptimisticSendOnNonCacheableError() async throws {
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

        let sessionRequestStarted = expectation(description: "session request started")
        let releaseSessionResponse = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session":
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

        // The reload renders the cache then suspends on /api/session. Kick off a send
        // *without* awaiting it (its optimistic user message is appended synchronously
        // before the network call) so the transcript is mutated while the reload is
        // still in flight.
        await fulfillment(of: [sessionRequestStarted], timeout: 2)
        let sendTask = Task { @MainActor in
            await viewModel.seedLegacyResponseForTesting("In-flight question", modelContext: context)
        }
        try await waitUntil { viewModel.messages.compactMap(\.content).contains("In-flight question") }
        XCTAssertTrue(viewModel.messages.compactMap(\.content).contains("In-flight question"))

        // Now let the reload fail with a non-cacheable error: the cache-first revert
        // must NOT wipe the optimistic send made during the load window (#289, Codex P2).
        releaseSessionResponse.signal()
        await loadTask.value
        _ = await sendTask.value

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
            sessionID: "session-abc",
            in: context
        )

        let reopenedViewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "messages": [
                  {
                    "role": "user",
                    "content": "Summarize it\\n\\n[Attached files: /tmp/workspace/photo.png]",
                    "timestamp": 1770000001,
                    "message_id": "user-1"
                  },
                  {
                    "role": "assistant",
                    "content": "Recovered transcript.",
                    "timestamp": 1770000100,
                    "message_id": "assistant-1"
                  }
                ]
              }
            }
            """, for: request)
        }

        await reopenedViewModel.loadMessages(modelContext: context)

        XCTAssertEqual(reopenedViewModel.messages.compactMap(\.role), ["user", "assistant"])
        XCTAssertEqual(reopenedViewModel.messages.first?.messageId, "user-1")
        XCTAssertEqual(reopenedViewModel.messages.filter { $0.role == "user" }.count, 1)
    }

    @MainActor
    func testTransportErrorChecksStatusAndReattachesWhenStreamIsActive() async throws {
        let streamClient = SpySSEStreamingClient()
        var didRequestStatus = false
        var didReloadMessages = false
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                didRequestStatus = true
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                didReloadMessages = true
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "active_stream_id": "stream-123",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.startedURLs.count, 1)

        streamClient.emit(.transportError("The network connection was lost."))
        try await waitUntil {
            didRequestStatus && didReloadMessages && streamClient.startedURLs.count == 2
        }

        XCTAssertTrue(didRequestStatus)
        XCTAssertTrue(didReloadMessages)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        XCTAssertEqual(streamClient.startedURLs.last?.path, "/api/chat/stream")
    }

    @MainActor
    func testNewestOverlappingTranscriptLoadWinsWhenOlderRequestFinishesLast() async throws {
        OutOfOrderChatSessionURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OutOfOrderChatSessionURLProtocol.self]
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let viewModel = ChatViewModel(
            session: try makeSession(),
            server: server,
            client: client,
            streamClient: SpySSEStreamingClient(),
            approvalStreamClient: SpySSEStreamingClient(),
            clarifyStreamClient: SpySSEStreamingClient(),
            listenAudioSession: SpyListenAudioSession(),
            listenRemoteControlCenter: SpyListenRemoteControlCenter()
        )

        let firstLoad = Task { await viewModel.loadMessages() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await viewModel.loadMessages()
        _ = await firstLoad.value

        XCTAssertEqual(viewModel.messages.map(\.messageId), ["fresh-message"])
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Fresh transcript"])
        XCTAssertEqual(OutOfOrderChatSessionURLProtocol.requestCount, 2)
    }

    @MainActor
    func testDelayedSceneRefreshCannotClobberNewlyStartedResponse() async throws {
        OutOfOrderChatSessionURLProtocol.reset(mode: .staleLoadThenSend)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OutOfOrderChatSessionURLProtocol.self]
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let streamClient = SpySSEStreamingClient()
        let viewModel = ChatViewModel(
            session: try makeSession(),
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: SpySSEStreamingClient(),
            clarifyStreamClient: SpySSEStreamingClient(),
            listenAudioSession: SpyListenAudioSession(),
            listenRemoteControlCenter: SpyListenRemoteControlCenter()
        )

        let delayedRefresh = Task { @MainActor in
            await viewModel.refreshAfterSceneActivation()
        }
        try await waitUntil {
            OutOfOrderChatSessionURLProtocol.requestCount >= 1
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("New local prompt", streamID: "stream-new")
        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-new")
        streamClient.emit(.token("Live answer"), lastEventID: "stream-new:1")

        await delayedRefresh.value

        XCTAssertEqual(viewModel.activeStreamID, "stream-new")
        XCTAssertEqual(viewModel.messages.first?.content, "New local prompt")
        XCTAssertTrue(viewModel.messages.last?.content?.hasPrefix("Live") == true)
        XCTAssertFalse(viewModel.messages.compactMap(\.content).contains("Stale transcript"))
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testNewestOverlappingTranscriptFailureRevertsPrimedCachePlaceholder() async throws {
        let context = try makeContext()
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        try CacheStore.cacheMessages(
            [ChatMessage(role: "assistant", content: "Cached answer", timestamp: 1_770_000_002, messageId: "cached-assistant")],
            serverURL: serverURL,
            sessionID: "session-abc",
            in: context
        )
        OutOfOrderChatSessionURLProtocol.reset(mode: .bothFail)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OutOfOrderChatSessionURLProtocol.self]
        let client = APIClient(baseURL: serverURL, session: URLSession(configuration: configuration))
        let viewModel = ChatViewModel(
            session: try makeSession(),
            server: serverURL,
            client: client,
            streamClient: SpySSEStreamingClient(),
            approvalStreamClient: SpySSEStreamingClient(),
            clarifyStreamClient: SpySSEStreamingClient(),
            listenAudioSession: SpyListenAudioSession(),
            listenRemoteControlCenter: SpyListenRemoteControlCenter()
        )

        viewModel.prepareInitialMessageLoad(modelContext: context)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Cached answer"])

        let firstLoad = Task { @MainActor in
            await viewModel.loadMessages(modelContext: context)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await viewModel.loadMessages(modelContext: context)
        await firstLoad.value

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(OutOfOrderChatSessionURLProtocol.requestCount, 2)
    }




    @MainActor
    func testStaleActiveStreamShowsCheckingStateAndPollsStatus() async throws {
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(requestPaths, ["/api/chat/stream/status"])
    }

    @MainActor
    func testStaleActiveStreamKeepsLiveReasoningVisibleWhileChecking() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Think through the plan")
        XCTAssertTrue(didStart)
        streamClient.emit(.reasoning("I need to inspect the workspace first."))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
        XCTAssertEqual(viewModel.liveReasoningText, "I need to inspect the workspace first.")
        XCTAssertNotNil(viewModel.streamingAssistantMessageID)
        XCTAssertEqual(viewModel.messages.compactMap(\.role), ["user", "assistant"])
    }

    @MainActor
    func testStaleActiveStreamDoesNotShowRecoveryStateBeforeFirstVisibleProgress() async throws {
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/chat/stream/status":
                XCTFail("Initial assistant wait should not poll stream status before visible progress.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(10))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(requestPaths, [])
    }

    @MainActor
    func testStaleActiveStreamRefreshesCompletedTranscriptAndClearsActiveStream() async throws {
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": false,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      },
                      {
                        "role": "assistant",
                        "content": "Recovered full answer.",
                        "timestamp": 1770000101,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("Partial "))

        // 13s: past transportFreshInterval (12), so stale recovery polls status
        // and finalizes the inactive run (#227).
        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "Recovered full answer."])
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(requestPaths, ["/api/chat/stream/status", "/api/session"])
    }

    @MainActor
    func testStaleActiveStreamInactiveWithoutFinalAssistantStopsChecking() async throws {
        let streamClient = SpySSEStreamingClient()
        let liveActivityManager = SpyChatLiveActivityManager()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            liveActivityManager: liveActivityManager
        ) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": false,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "user",
                        "content": "Keep working",
                        "timestamp": 1770000100,
                        "message_id": "user-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("Partial "))

        // 13s: past transportFreshInterval (12), so stale recovery polls status
        // and finalizes the inactive run (#227).
        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(liveActivityManager.ends, [
            SpyChatLiveActivityManager.End(
                status: .failed,
                activity: "Response failed",
                errorSummary: nil
            )
        ])
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "Partial "])
    }

    @MainActor
    func testStaleActiveStreamReconnectsWithReplayAndSkipsDuplicateTokens() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "), lastEventID: "stream-123:1")

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["replay"], "1")
        XCTAssertEqual(query["after_seq"], "1")

        streamClient.emit(.token("First "), lastEventID: "stream-123:1")
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First "])

        streamClient.emit(.token("answer."), lastEventID: "stream-123:2")

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First answer."])
        XCTAssertEqual(viewModel.messages.filter { $0.role == "assistant" }.count, 1)
    }

    @MainActor
    func testStaleActiveStreamReconnectsWithReplayFromBeginningWhenLastEventIDIsMissing() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["replay"], "1")
        XCTAssertEqual(query["after_seq"], "0")

        streamClient.emit(.token("First "))
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First "])

        streamClient.emit(.token("answer."))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First answer."])
    }

    @MainActor
    func testStaleActiveStreamReconnectsWithoutReplayQueryWhenReplayUnavailable() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": false
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "), lastEventID: "stream-123:1")

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        XCTAssertEqual(streamClient.startedURLs.count, 2)
        let reconnectURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: reconnectURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(queryItems.first(where: { $0.name == "replay" })?.value)
        XCTAssertNil(queryItems.first(where: { $0.name == "after_seq" })?.value)
    }

    @MainActor
    func testStaleActiveStreamStatusErrorOnlyReconnectsAfterForceThreshold() async throws {
        let streamClient = SpySSEStreamingClient()
        var statusRequestCount = 0
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                statusRequestCount += 1
                throw URLError(.timedOut)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertEqual(statusRequestCount, 1)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(streamClient.stopCount, 0)

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        XCTAssertEqual(statusRequestCount, 2)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        let replayURL = try XCTUnwrap(streamClient.startedURLs.last)
        let queryItems = URLComponents(url: replayURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["replay"], "1")
        XCTAssertEqual(query["after_seq"], "0")
    }

    @MainActor
    func testStaleActiveStreamStatusPollHonorsCooldown() async throws {
        let streamClient = SpySSEStreamingClient()
        var statusRequestCount = 0
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                statusRequestCount += 1
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))

        let firstPollDate = Date().addingTimeInterval(12.5)
        await viewModel.recoverStaleActiveStreamIfNeeded(now: firstPollDate)
        await viewModel.recoverStaleActiveStreamIfNeeded(now: firstPollDate.addingTimeInterval(2))
        await viewModel.recoverStaleActiveStreamIfNeeded(now: firstPollDate.addingTimeInterval(5))

        XCTAssertEqual(statusRequestCount, 2)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
    }

    @MainActor
    func testStaleActiveStreamDoesNotForceReconnectPlainSlowStreamAtTenSeconds() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(10))

        // #227: 10s of quiet is still inside transportFreshInterval, so the
        // slow-but-alive stream shows no recovery chip at all — and is
        // certainly not force-reconnected.
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testStaleActiveStreamReplayDeduplicatesMultiTokenPrefix() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))
        streamClient.emit(.token("middle "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        streamClient.emit(.token("First "))
        streamClient.emit(.token("middle "))
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First middle "])

        streamClient.emit(.token("last."))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First middle last."])
    }

    @MainActor
    func testStaleActiveStreamReplayBatchedTokensMatchLiveModeFinalContent() async throws {
        let tokens = ["Alpha ", "beta ", "gamma ", "delta."]

        let liveStreamClient = SpySSEStreamingClient()
        let liveViewModel = try makeViewModel(streamClient: liveStreamClient) { request in
            switch request.url?.path {
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStartLive = await liveViewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStartLive)
        for token in tokens {
            liveStreamClient.emit(.token(token))
        }
        let liveTranscript = liveViewModel.messages.compactMap(\.content)
        XCTAssertEqual(liveTranscript, ["Keep working", "Alpha beta gamma delta."])

        let replayStreamClient = SpySSEStreamingClient()
        let replayViewModel = try makeViewModel(streamClient: replayStreamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStartReplay = await replayViewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStartReplay)
        replayStreamClient.emit(.token(tokens[0]))
        replayStreamClient.emit(.token(tokens[1]))

        await replayViewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        // The replay connection re-sends the full token sequence from the start.
        for token in tokens {
            replayStreamClient.emit(.token(token))
        }

        XCTAssertEqual(replayViewModel.messages.compactMap(\.content), liveTranscript)
    }

    @MainActor
    func testStaleActiveStreamReplayDeduplicatesStridingOverlap() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First middle "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))
        streamClient.emit(.token("middle last."))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First middle last."])
    }

    @MainActor
    func testStaleActiveStreamReplayDuplicateOnlyConnectionCanRecoverAgain() async throws {
        let streamClient = SpySSEStreamingClient()
        var statusRequestCount = 0
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                statusRequestCount += 1
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))
        streamClient.emit(.token("First "))

        XCTAssertEqual(statusRequestCount, 1)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First "])

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertEqual(statusRequestCount, 2)
        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
    }

    @MainActor
    func testStaleActiveStreamReplayDedupFallbackDoesNotSuppressNextNewToken() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.token("First middle "))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))
        streamClient.emit(.token("middle "))
        streamClient.emit(.token("First "))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "First middle First "])
    }

    @MainActor
    func testStaleActiveStreamReplayDeduplicatesInterimAssistant() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(text: "Draft answer.")))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))
        streamClient.emit(.interimAssistant(InterimAssistantStreamEvent(text: "Draft answer.")))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep working", "Draft answer."])
    }

    @MainActor
    func testStaleActiveStreamReplayDeduplicatesReasoningAndCompletedToolEvents() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let startedTool = ToolStreamEvent(
            eventType: "tool.started",
            name: "run_command",
            preview: "Running tests",
            args: ["cmd": .string("xcodebuild test")],
            duration: nil,
            isError: nil
        )
        let completedTool = ToolStreamEvent(
            eventType: "tool.completed",
            name: "run_command",
            preview: "Passed tests",
            args: ["cmd": .string("xcodebuild test")],
            duration: 1.5,
            isError: false
        )

        let didStart = await viewModel.seedLegacyResponseForTesting("Inspect logs")
        XCTAssertTrue(didStart)
        streamClient.emit(.reasoning("Plan."))
        streamClient.emit(.toolStarted(startedTool))
        streamClient.emit(.toolCompleted(completedTool))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))
        streamClient.emit(.reasoning("Plan."))
        streamClient.emit(.toolStarted(startedTool))
        streamClient.emit(.toolCompleted(completedTool))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.liveReasoningText, "Plan.")
        XCTAssertEqual(viewModel.liveToolCalls.count, 1)
        XCTAssertEqual(viewModel.liveToolCalls.first?.name, "run_command")
        XCTAssertEqual(viewModel.liveToolCalls.first?.preview, "Passed tests")
        XCTAssertEqual(viewModel.liveToolCalls.first?.isCompleted, true)
    }

    @MainActor
    func testReplayCompletesSecondSameNameToolByStableID() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Run both checks")
        XCTAssertTrue(didStart)

        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "run_command",
            preview: "Running first check",
            args: ["cmd": .string("swift test")],
            duration: nil,
            isError: nil,
            stableID: "call-first"
        )))
        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool.completed",
            name: "run_command",
            preview: "First check passed",
            args: ["cmd": .string("swift test")],
            duration: 0.5,
            isError: false,
            stableID: "call-first"
        )))
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "run_command",
            preview: "Running second check",
            args: ["cmd": .string("swift test")],
            duration: nil,
            isError: nil,
            stableID: "call-second"
        )))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(20))

        streamClient.emit(.toolCompleted(ToolStreamEvent(
            eventType: "tool.completed",
            name: "run_command",
            preview: "Second check passed",
            args: ["cmd": .string("swift test")],
            duration: 0.75,
            isError: false,
            stableID: "call-second"
        )))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .idle)
        XCTAssertEqual(viewModel.liveToolCalls.count, 2)
        XCTAssertEqual(viewModel.liveToolCalls.map(\.id), ["call-first", "call-second"])
        XCTAssertEqual(viewModel.liveToolCalls.map(\.preview), ["First check passed", "Second check passed"])
        XCTAssertEqual(viewModel.liveToolCalls.map(\.isCompleted), [true, true])
    }

    @MainActor
    func testStaleActiveStreamDoesNotForceReconnectDuringRunningToolAtNormalThreshold() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Inspect logs")
        XCTAssertTrue(didStart)
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "run_command",
            preview: "Running tests",
            args: ["cmd": .string("xcodebuild test")],
            duration: nil,
            isError: nil
        )))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(13))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .checking)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.stopCount, 0)
        XCTAssertEqual(streamClient.startedURLs.count, 1)
        XCTAssertEqual(viewModel.liveToolCalls.count, 1)
        XCTAssertEqual(viewModel.liveToolCalls.first?.isCompleted, false)
    }

    @MainActor
    func testStaleActiveStreamForceReconnectsRunningToolAfterToolThreshold() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                return apiTestJSONResponse("""
                {
                  "active": true,
                  "stream_id": "stream-123",
                  "replay_available": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Inspect logs")
        XCTAssertTrue(didStart)
        streamClient.emit(.toolStarted(ToolStreamEvent(
            eventType: "tool.started",
            name: "run_command",
            preview: "Running tests",
            args: ["cmd": .string("xcodebuild test")],
            duration: nil,
            isError: nil
        )))

        await viewModel.recoverStaleActiveStreamIfNeeded(now: Date().addingTimeInterval(26))

        XCTAssertEqual(viewModel.activeStreamRecoveryState, .reconnecting)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")
        XCTAssertEqual(streamClient.stopCount, 1)
        XCTAssertEqual(streamClient.startedURLs.count, 2)
    }


    @MainActor
    func testLegacyComposerConfigurationUsesSessionProfileDefault() async throws {
        let openRouterModel = "deepseek/deepseek-chat-v3-0324:free"
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(model: nil, modelProvider: nil, profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "default",
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true},
                    {"name": "work", "model": "\(openRouterModel)", "provider": "openrouter"}
                  ]
                }
                """, for: request)
            case "/api/profile/switch":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["name"] as? String, "work")
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "default_model": "\(openRouterModel)",
                  "default_workspace": "/tmp/workspace",
                  "profiles": [
                    {"name": "default", "model": "gpt-5.4", "provider": "openai", "is_default": true},
                    {"name": "work", "model": "\(openRouterModel)", "provider": "openrouter", "is_active": true}
                  ]
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "default_model": "\(openRouterModel)",
                  "active_provider": "openrouter",
                  "groups": [
                    {
                      "name": "OpenRouter",
                      "provider_id": "openrouter",
                      "models": [
                        {"id": "\(openRouterModel)", "name": "DeepSeek Chat v3 Free"}
                      ]
                    }
                  ]
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces": [{"path": "/tmp/workspace"}], "last": "/tmp/workspace"}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": []}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadComposerConfiguration()
        XCTAssertEqual(viewModel.selectedModelID, openRouterModel)
        XCTAssertEqual(viewModel.selectedProfileTitle, "work")


        XCTAssertEqual(requestPaths, [
            "/api/profiles",
            "/api/profile/switch",
            "/api/models",
            "/api/reasoning",
            "/api/workspaces",
            "/api/commands",
        ])
    }

    @MainActor
    func testSessionModelOverrideSurvivesProfileDefaultLoad() async throws {
        let openRouterDefault = "deepseek/deepseek-chat-v3-0324:free"
        let sessionModel = "@openai:gpt-5.5"
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(model: sessionModel, modelProvider: "openai", profile: "work")
        ) { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "profiles": [
                    {"name": "work", "model": "\(openRouterDefault)", "provider": "openrouter", "is_active": true}
                  ]
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "default_model": "\(openRouterDefault)",
                  "active_provider": "openrouter",
                  "groups": [
                    {
                      "name": "OpenRouter",
                      "provider_id": "openrouter",
                      "models": [
                        {"id": "\(openRouterDefault)", "name": "DeepSeek Chat v3 Free"}
                      ]
                    },
                    {
                      "name": "OpenAI",
                      "provider_id": "openai",
                      "models": [
                        {"id": "\(sessionModel)", "name": "GPT 5.5"}
                      ]
                    }
                  ]
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces": [{"path": "/tmp/workspace"}], "last": "/tmp/workspace"}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": []}"#, for: request)
            case "/api/default-model":
                XCTFail("Session-scoped chat model overrides must not save profile defaults.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadComposerConfiguration()
        XCTAssertEqual(viewModel.selectedModelID, sessionModel)


    }

    @MainActor
    func testComposerConfigurationReloadDoesNotOverwriteConcurrentWorkspaceSelection() async throws {
        let initialWorkspace = "/tmp/workspace"
        let selectedWorkspace = "/tmp/selected-workspace"
        let firstProfilesStarted = expectation(description: "first profiles request started")
        let releaseFirstProfiles = DispatchSemaphore(value: 0)
        let profileRequests = LockedCounter()
        var didReleaseFirstProfiles = false
        func releaseProfilesIfNeeded() {
            guard !didReleaseFirstProfiles else { return }
            didReleaseFirstProfiles = true
            releaseFirstProfiles.signal()
        }

        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            switch request.url?.path {
            case "/api/profiles":
                let requestCount = profileRequests.increment()
                if requestCount == 1 {
                    firstProfilesStarted.fulfill()
                    XCTAssertEqual(releaseFirstProfiles.wait(timeout: .now() + .seconds(5)), .success)
                }

                return apiTestJSONResponse("""
                {
                  "active": "work",
                  "profiles": [
                    {"name": "work", "model": "gpt-5.4", "provider": "openai", "is_active": true}
                  ]
                }
                """, for: request)
            case "/api/session/update":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["workspace"] as? String, selectedWorkspace)
                XCTAssertEqual(body["model"] as? String, "gpt-5.4")
                XCTAssertEqual(body["model_provider"] as? String, "openai")

                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "\(selectedWorkspace)",
                    "model": "gpt-5.4",
                    "model_provider": "openai",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "default_model": "gpt-5.4",
                  "active_provider": "openai",
                  "groups": [
                    {
                      "name": "OpenAI",
                      "provider_id": "openai",
                      "models": [
                        {"id": "gpt-5.4", "name": "GPT 5.4"}
                      ]
                    }
                  ]
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse("""
                {
                  "workspaces": [
                    {"path": "\(initialWorkspace)"},
                    {"path": "\(selectedWorkspace)"}
                  ],
                  "last": "\(initialWorkspace)"
                }
                """, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands": []}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let loadTask = Task { @MainActor in
            await viewModel.loadComposerConfiguration()
        }
        await fulfillment(of: [firstProfilesStarted], timeout: 1)
        defer { releaseProfilesIfNeeded() }

        let selectWorkspaceTask = Task { @MainActor in
            await viewModel.selectWorkspacePath(selectedWorkspace)
        }
        try await waitUntil { viewModel.selectedWorkspacePath == selectedWorkspace }
        releaseProfilesIfNeeded()

        let didSelectWorkspace = await selectWorkspaceTask.value
        await loadTask.value

        XCTAssertTrue(didSelectWorkspace)
        XCTAssertEqual(viewModel.selectedWorkspacePath, selectedWorkspace)
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertEqual(profileRequests.count, 2)
        XCTAssertNil(viewModel.composerConfigurationErrorMessage)
    }

    @MainActor
    func testModelSelectionIsVisibleBeforePersistenceAcknowledgement() async throws {
        let requestStarted = expectation(description: "model update started")
        let releaseRequest = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel(
            sessionSummary: try makeSession(model: "gpt-5.4", modelProvider: "openai")
        ) { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/session/update", "POST"):
                requestStarted.fulfill()
                releaseRequest.wait()
                return apiTestJSONResponse(#"{"session":{"session_id":"session-abc","model":"gpt-5.5","model_provider":"openai"}}"#, for: request)
            case ("/api/reasoning", "GET"):
                return apiTestJSONResponse(#"{}"#, for: request)
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let selectionTask = Task { @MainActor in
            await viewModel.selectComposerModel(ModelCatalogOption(
                id: "gpt-5.5",
                displayName: "GPT-5.5",
                providerID: "openai"
            ))
        }
        await fulfillment(of: [requestStarted], timeout: 2)

        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.5")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertTrue(viewModel.isUpdatingComposerConfiguration)

        releaseRequest.signal()
        let didSelect = await selectionTask.value
        XCTAssertTrue(didSelect)
        XCTAssertFalse(viewModel.isUpdatingComposerConfiguration)
    }

    @MainActor
    func testModelSelectionFailureRollsBackOptimisticChip() async throws {
        let requestStarted = expectation(description: "model update started")
        let releaseRequest = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel(
            sessionSummary: try makeSession(model: "gpt-5.4", modelProvider: "openai")
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/session/update")
            requestStarted.fulfill()
            releaseRequest.wait()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"model rejected"}"#.utf8))
        }

        let selectionTask = Task { @MainActor in
            await viewModel.selectComposerModel(ModelCatalogOption(
                id: "gpt-5.5",
                displayName: "GPT-5.5",
                providerID: "openai"
            ))
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.5")

        releaseRequest.signal()
        let didSelect = await selectionTask.value
        XCTAssertFalse(didSelect)
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertFalse(viewModel.isUpdatingComposerConfiguration)
        XCTAssertNotNil(viewModel.composerConfigurationErrorMessage)
    }

    @MainActor
    func testReasoningSelectionIsVisibleBeforePersistenceAndRollsBackOnFailure() async throws {
        let requestStarted = expectation(description: "reasoning update started")
        let releaseRequest = DispatchSemaphore(value: 0)
        let viewModel = try makeViewModel(
            sessionSummary: try makeSession(model: "gpt-5.4", modelProvider: "openai")
        ) { request in
            XCTAssertEqual(request.url?.path, "/api/reasoning")
            XCTAssertEqual(request.httpMethod, "POST")
            requestStarted.fulfill()
            releaseRequest.wait()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            return (try XCTUnwrap(response), Data(#"{"error":"reasoning rejected"}"#.utf8))
        }

        let selectionTask = Task { @MainActor in
            await viewModel.selectReasoningEffort("high")
        }
        await fulfillment(of: [requestStarted], timeout: 2)

        XCTAssertEqual(viewModel.selectedReasoningEffort, "high")
        XCTAssertEqual(viewModel.selectedReasoningSelection, "high")
        XCTAssertTrue(viewModel.isUpdatingComposerConfiguration)

        releaseRequest.signal()
        let didSelect = await selectionTask.value
        XCTAssertFalse(didSelect)
        XCTAssertNil(viewModel.selectedReasoningEffort)
        XCTAssertNil(viewModel.selectedReasoningSelection)
        XCTAssertFalse(viewModel.isUpdatingComposerConfiguration)
        XCTAssertNotNil(viewModel.composerConfigurationErrorMessage)
    }

    @MainActor
    func testLegacyComposerModelSelectionUpdatesOnlyTheSession() async throws {
        let openRouterModel = "deepseek/deepseek-chat-v3-0324:free"
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: nil, profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/session/update":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
                XCTAssertEqual(body["model"] as? String, openRouterModel)
                XCTAssertEqual(body["model_provider"] as? String, "openrouter")
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(openRouterModel)",
                    "model_provider": "openrouter",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/default-model":
                XCTFail("Composer model selection must not save profile defaults.")
                throw URLError(.badURL)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: openRouterModel,
            displayName: "DeepSeek Chat v3 Free",
            providerID: "openrouter"
        ))
        XCTAssertEqual(viewModel.selectedModelID, openRouterModel)


        XCTAssertEqual(requestPaths, ["/api/session/update", "/api/reasoning"])
    }

    @MainActor
    func testLegacyCustomComposerModelSelectionRetainsProvider() async throws {
        let customModel = "moonshotai/kimi-k2-0905"
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/session/update":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
                XCTAssertEqual(body["model"] as? String, customModel)
                XCTAssertEqual(body["model_provider"] as? String, "openrouter")
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(customModel)",
                    "model_provider": "openrouter",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/default-model":
                XCTFail("Custom composer models must not save Settings defaults.")
                throw URLError(.badURL)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: customModel,
            displayName: customModel,
            providerID: "openrouter"
        ))
        XCTAssertEqual(viewModel.selectedModelID, customModel)
        XCTAssertEqual(viewModel.selectedModelProviderID, "openrouter")
        XCTAssertEqual(viewModel.selectedModelTitle, "kimi-k2-0905")


        XCTAssertEqual(requestPaths, ["/api/session/update", "/api/reasoning"])
    }

    @MainActor
    func testLegacyTypedSlashModelSelectionUpdatesSession() async throws {
        let typedModel = "gpt-5.4-mini"
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(model: "claude-sonnet-4", modelProvider: nil, profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/session/update":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["model"] as? String, typedModel)
                XCTAssertNil(body["model_provider"])
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(typedModel)",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "model")),
            args: typedModel
        )

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(requestPaths, ["/api/session/update", "/api/reasoning"])
    }

    @MainActor
    func testSelectingCustomComposerModelWhenSessionUpdateFailsDoesNotMutateState() async throws {
        let customModel = "moonshotai/kimi-k2-0905"
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/session/update":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                XCTAssertEqual(body["model"] as? String, customModel)
                XCTAssertEqual(body["model_provider"] as? String, "openrouter")

                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
                return (try XCTUnwrap(response), Data(#"{"error":"model update failed"}"#.utf8))
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: customModel,
            displayName: customModel,
            providerID: "openrouter"
        ))

        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertNotNil(viewModel.composerConfigurationErrorMessage)
        XCTAssertEqual(requestPaths, ["/api/session/update"])
    }

    @MainActor
    func testSelectingCustomComposerModelWhileStreamingIsBlocked() async throws {
        let streamClient = SpySSEStreamingClient()
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/session/update":
                XCTFail("Selecting a composer model while streaming must not call session update.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Start streaming")
        await viewModel.selectComposerModel(ModelCatalogOption(
            id: "moonshotai/kimi-k2-0905",
            displayName: "moonshotai/kimi-k2-0905",
            providerID: "openrouter"
        ))

        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertEqual(
            viewModel.composerConfigurationErrorMessage,
            "Wait for the current response to finish before changing models."
        )
        XCTAssertEqual(requestPaths, [])
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testSelectingCustomComposerModelWithNilSessionIDIsBlocked() async throws {
        let session = SessionSummary(
            sessionId: nil,
            title: "Planning",
            workspace: "/tmp/workspace",
            model: "gpt-5.4",
            modelProvider: "openai",
            profile: "work"
        )
        let viewModel = try makeViewModel(sessionSummary: session) { request in
            XCTFail("Selecting a composer model without a session ID must not call \(request.url?.path ?? "nil").")
            throw URLError(.badURL)
        }

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: "moonshotai/kimi-k2-0905",
            displayName: "moonshotai/kimi-k2-0905",
            providerID: "openrouter"
        ))

        XCTAssertEqual(viewModel.selectedModelID, "gpt-5.4")
        XCTAssertEqual(viewModel.selectedModelProviderID, "openai")
        XCTAssertEqual(viewModel.composerConfigurationErrorMessage, "The server did not provide a session ID.")
    }

    @MainActor
    func testSelectingCustomComposerModelSessionUpdateOmittingProviderFallsBackToOptionProvider() async throws {
        let customModel = "moonshotai/kimi-k2-0905"
        var requestPaths: [String] = []
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            requestPaths.append(request.url?.path ?? "")

            switch request.url?.path {
            case "/api/session/update":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["model"] as? String, customModel)
                XCTAssertEqual(body["model_provider"] as? String, "openrouter")
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(customModel)",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: customModel,
            displayName: customModel,
            providerID: "openrouter"
        ))

        XCTAssertEqual(viewModel.selectedModelID, customModel)
        XCTAssertEqual(viewModel.selectedModelProviderID, "openrouter")
        XCTAssertNil(viewModel.composerConfigurationErrorMessage)
        XCTAssertEqual(requestPaths, ["/api/session/update", "/api/reasoning"])
    }

    @MainActor
    func testSelectingComposerModelRefreshesEffortGatingAndSnapsUnsupportedEffort() async throws {
        let limitedModel = "o4-mini"
        var reasoningQueries: [[String: String?]] = []
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            switch request.url?.path {
            case "/api/reasoning" where request.httpMethod == "POST":
                return apiTestJSONResponse(#"{"ok": true, "reasoning_effort": "xhigh"}"#, for: request)
            case "/api/session/update":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(limitedModel)",
                    "model_provider": "openai",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/reasoning":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                reasoningQueries.append(Dictionary(
                    uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) }
                ))
                return apiTestJSONResponse("""
                {
                  "show_reasoning": true,
                  "reasoning_effort": "high",
                  "supported_efforts": ["low", "medium", "high"],
                  "supports_reasoning_effort": true
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.selectReasoningEffort("xhigh")
        XCTAssertEqual(viewModel.selectedReasoningEffort, "xhigh")

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: limitedModel,
            displayName: limitedModel,
            providerID: "openai"
        ))

        // The gating query is scoped to the newly selected model, never stale
        // session state (upstream #3750 class of bug).
        XCTAssertEqual(reasoningQueries.count, 1)
        XCTAssertEqual(reasoningQueries[0]["model"], limitedModel)
        XCTAssertEqual(reasoningQueries[0]["provider"], "openai")
        XCTAssertEqual(viewModel.supportedReasoningEfforts, ["low", "medium", "high"])
        XCTAssertEqual(viewModel.supportsReasoningEffort, true)
        XCTAssertTrue(viewModel.showsReasoningEffortControl)
        // "xhigh" is not supported by the new model: snap to the server's
        // coerced reasoning_effort.
        XCTAssertEqual(viewModel.selectedReasoningEffort, "high")
    }

    @MainActor
    func testSessionScopedReasoningSelectionStaysIsolatedPerConversation() async throws {
        var reasoningGETSessionEfforts: [String?] = []
        var reasoningPOSTs: [(sessionID: String?, effort: String?)] = []
        let handler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(#"{"active":"default","profiles":[]}"#, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "default_model": "gpt-5.4",
                  "groups": [{
                    "name": "OpenAI",
                    "provider_id": "openai",
                    "models": [{"id": "gpt-5.4", "name": "GPT 5.4"}]
                  }]
                }
                """, for: request)
            case "/api/session/update":
                let body = try apiTestJSONBody(from: request)
                let sessionID = body["session_id"] as? String
                let effort = body["reasoning_effort"] as? String
                reasoningPOSTs.append((sessionID: sessionID, effort: effort))
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "\(sessionID ?? "")",
                    "model": "gpt-5.4",
                    "model_provider": "openai",
                    "reasoning_effort": "\(effort ?? "")"
                  }
                }
                """, for: request)
            case "/api/reasoning":
                let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
                let sessionID = try XCTUnwrap(query["session_id"] ?? nil)
                XCTAssertTrue(sessionID == "session-alpha" || sessionID == "session-beta")
                reasoningGETSessionEfforts.append(sessionID)
                return apiTestJSONResponse("""
                {
                  "reasoning_effort": "\(sessionID == "session-alpha" ? "low" : "high")",
                  "session_reasoning_effort": "\(sessionID == "session-alpha" ? "low" : "high")",
                  "supported_efforts": ["low", "high"],
                  "supports_reasoning_effort": true,
                  "session_scoped_reasoning": true
                }
                """, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces":[]}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands":[]}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let alpha = try makeViewModel(
            sessionSummary: SessionSummary(
                sessionId: "session-alpha",
                title: "Alpha",
                workspace: "/tmp/workspace",
                model: "gpt-5.4",
                modelProvider: "openai",
                reasoningEffort: "low"
            ),
            handler: handler
        )
        let beta = try makeViewModel(
            sessionSummary: SessionSummary(
                sessionId: "session-beta",
                title: "Beta",
                workspace: "/tmp/workspace",
                model: "gpt-5.4",
                modelProvider: "openai",
                reasoningEffort: "high"
            ),
            handler: handler
        )

        await alpha.loadComposerConfiguration()
        await beta.loadComposerConfiguration()

        XCTAssertEqual(alpha.selectedReasoningEffort, "low")
        XCTAssertEqual(beta.selectedReasoningEffort, "high")
        XCTAssertEqual(reasoningGETSessionEfforts, ["session-alpha", "session-beta"])

        let alphaDidSelect = await alpha.selectReasoningEffort("high")
        let betaDidSelect = await beta.selectReasoningEffort("low")
        XCTAssertTrue(alphaDidSelect)
        XCTAssertTrue(betaDidSelect)
        XCTAssertEqual(reasoningPOSTs.map { $0.sessionID }, ["session-alpha", "session-beta"])
        XCTAssertEqual(reasoningPOSTs.map { $0.effort }, ["high", "low"])
        XCTAssertEqual(reasoningGETSessionEfforts, ["session-alpha", "session-beta", "session-alpha", "session-beta"])
    }

    @MainActor
    func testLegacyReasoningSelectionRetainsGlobalNoSessionPost() async throws {
        var postedBody: [String: Any]?
        let viewModel = try makeViewModel(
            sessionSummary: SessionSummary(
                sessionId: "session-legacy",
                title: "Legacy",
                workspace: "/tmp/workspace",
                model: "gpt-5.4",
                modelProvider: "openai"
            )
        ) { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(#"{"active":"default","profiles":[]}"#, for: request)
            case "/api/models":
                return apiTestJSONResponse(#"{"default_model":"gpt-5.4","groups":[]}"#, for: request)
            case "/api/reasoning" where request.httpMethod == "POST":
                postedBody = try apiTestJSONBody(from: request)
                return apiTestJSONResponse(#"{"ok":true,"reasoning_effort":"high"}"#, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse(#"{"reasoning_effort":"low","supported_efforts":["low","high"],"supports_reasoning_effort":true}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces":[]}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands":[]}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadComposerConfiguration()
        XCTAssertNil(viewModel.sessionScopedReasoning)
        let didSelect = await viewModel.selectReasoningEffort("high")
        XCTAssertTrue(didSelect)
        XCTAssertEqual(postedBody?["effort"] as? String, "high")
        XCTAssertNil(postedBody?["session_id"])
    }

    @MainActor
    func testReasoningSlashCommandUsesAdvertisedSessionScope() async throws {
        var sessionUpdateBody: [String: Any]?
        var reasoningQuery: [String: String?]?
        let viewModel = try makeViewModel(
            sessionSummary: SessionSummary(
                sessionId: "session-slash",
                title: "Slash",
                workspace: "/tmp/workspace",
                model: "gpt-5.4",
                modelProvider: "openai"
            )
        ) { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(#"{"active":"default","profiles":[]}"#, for: request)
            case "/api/models":
                return apiTestJSONResponse(#"{"default_model":"gpt-5.4","groups":[]}"#, for: request)
            case "/api/session/update":
                sessionUpdateBody = try apiTestJSONBody(from: request)
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-slash",
                    "model": "gpt-5.4",
                    "model_provider": "openai",
                    "reasoning_effort": "max"
                  }
                }
                """, for: request)
            case "/api/reasoning":
                let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
                reasoningQuery = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
                return apiTestJSONResponse(#"{"ok":true,"reasoning_effort":"max","supported_efforts":["low","max"],"supports_reasoning_effort":true,"session_scoped_reasoning":true}"#, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces":[]}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands":[]}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadComposerConfiguration()
        let result = await viewModel.executeSlashCommand(
            try XCTUnwrap(SlashCommandCatalog.command(named: "reasoning")),
            args: "max"
        )

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(sessionUpdateBody?["session_id"] as? String, "session-slash")
        XCTAssertEqual(sessionUpdateBody?["reasoning_effort"] as? String, "max")
        XCTAssertNil(sessionUpdateBody?["effort"])
        XCTAssertEqual(reasoningQuery?["session_id"] ?? nil, "session-slash")
        XCTAssertNil(reasoningQuery?["session_effort"] ?? nil)
        XCTAssertEqual(viewModel.selectedReasoningEffort, "max")
    }

    @MainActor
    func testSessionScopedInheritSelectionClearsOverrideAndRestoresEffectiveEffort() async throws {
        var sessionUpdateBody: [String: Any]?
        var reasoningQuery: [String: String?]?
        let viewModel = try makeViewModel(
            sessionSummary: SessionSummary(
                sessionId: "session-inherit",
                title: "Inherit",
                workspace: "/tmp/workspace",
                model: "gpt-5.6-luna",
                modelProvider: "openai-codex",
                reasoningEffort: "high"
            )
        ) { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(#"{"active":"default","profiles":[]}"#, for: request)
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "default_model":"gpt-5.6-luna",
                  "groups":[{"name":"OpenAI Codex","provider_id":"openai-codex","models":[{"id":"gpt-5.6-luna","name":"GPT-5.6 Luna"}]}]
                }
                """, for: request)
            case "/api/session/update":
                sessionUpdateBody = try apiTestJSONBody(from: request)
                return apiTestJSONResponse("""
                {"session":{"session_id":"session-inherit","model":"gpt-5.6-luna","model_provider":"openai-codex","reasoning_effort":""}}
                """, for: request)
            case "/api/reasoning":
                let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
                reasoningQuery = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
                XCTAssertEqual(reasoningQuery?["session_id"] ?? nil, "session-inherit")
                let didClearOverride = sessionUpdateBody != nil
                return apiTestJSONResponse("""
                {"reasoning_effort":"\(didClearOverride ? "xhigh" : "high")","session_reasoning_effort":\(didClearOverride ? "null" : "\"high\""),"supported_efforts":["low","high","xhigh"],"session_scoped_reasoning":true}
                """, for: request)
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces":[]}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands":[]}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadComposerConfiguration()
        XCTAssertEqual(viewModel.sessionReasoningEffort, "high")

        let didClear = await viewModel.selectReasoningEffort(ReasoningEffortOption.inheritID)

        XCTAssertTrue(didClear)
        XCTAssertEqual(sessionUpdateBody?["session_id"] as? String, "session-inherit")
        XCTAssertEqual(sessionUpdateBody?["reasoning_effort"] as? String, "")
        XCTAssertNil(sessionUpdateBody?["effort"])
        XCTAssertEqual(reasoningQuery?["session_id"] ?? nil, "session-inherit")
        XCTAssertNil(reasoningQuery?["session_effort"] ?? nil)
        XCTAssertEqual(viewModel.selectedReasoningEffort, "xhigh")
        XCTAssertEqual(viewModel.selectedReasoningSelection, ReasoningEffortOption.inheritID)
        XCTAssertNil(viewModel.sessionReasoningEffort)
    }

    @MainActor
    func testSelectingComposerModelHidesEffortControlWhenUnsupported() async throws {
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            switch request.url?.path {
            case "/api/session/update":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "no-effort-model",
                    "model_provider": "openai",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/reasoning":
                return apiTestJSONResponse("""
                {
                  "show_reasoning": true,
                  "reasoning_effort": "",
                  "supported_efforts": [],
                  "supports_reasoning_effort": false
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        XCTAssertTrue(viewModel.showsReasoningEffortControl)

        await viewModel.selectComposerModel(ModelCatalogOption(
            id: "no-effort-model",
            displayName: "no-effort-model",
            providerID: "openai"
        ))

        XCTAssertEqual(viewModel.supportedReasoningEfforts, [])
        XCTAssertEqual(viewModel.supportsReasoningEffort, false)
        XCTAssertFalse(viewModel.showsReasoningEffortControl)
    }

    @MainActor
    func testEffortGatingRefreshFailureResetsStaleGatingToFallback() async throws {
        // First switch lands restrictive gating (no effort support); the second
        // switch succeeds but its gating refresh fails. The stale "hidden"
        // gating from the first model must not stick to the new model — it
        // resets to the unknown fallback (static list, control shown).
        var reasoningCalls = 0
        var sessionModel = "gpt-5.4"
        let viewModel = try makeViewModel(
            sessionSummary: makeSession(model: "gpt-5.4", modelProvider: "openai", profile: "work")
        ) { request in
            switch request.url?.path {
            case "/api/session/update":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "workspace": "/tmp/workspace",
                    "model": "\(sessionModel)",
                    "model_provider": "openai",
                    "profile": "work"
                  }
                }
                """, for: request)
            case "/api/reasoning":
                reasoningCalls += 1
                if reasoningCalls == 1 {
                    return apiTestJSONResponse("""
                    {
                      "show_reasoning": true,
                      "reasoning_effort": "",
                      "supported_efforts": [],
                      "supports_reasoning_effort": false
                    }
                    """, for: request)
                }
                throw URLError(.timedOut)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        sessionModel = "no-effort-model"
        let didSelectFirst = await viewModel.selectComposerModel(ModelCatalogOption(
            id: "no-effort-model",
            displayName: "no-effort-model",
            providerID: "openai"
        ))
        XCTAssertTrue(didSelectFirst)
        XCTAssertEqual(viewModel.supportsReasoningEffort, false)
        XCTAssertFalse(viewModel.showsReasoningEffortControl)

        sessionModel = "flaky-model"
        let didSelect = await viewModel.selectComposerModel(ModelCatalogOption(
            id: "flaky-model",
            displayName: "flaky-model",
            providerID: "openai"
        ))

        // The model change still succeeds; the failed refresh drops the stale
        // gating instead of applying it to the new model.
        XCTAssertTrue(didSelect)
        XCTAssertEqual(viewModel.selectedModelID, "flaky-model")
        XCTAssertNil(viewModel.supportedReasoningEfforts)
        XCTAssertNil(viewModel.supportsReasoningEffort)
        XCTAssertTrue(viewModel.showsReasoningEffortControl)
        XCTAssertNil(viewModel.composerConfigurationErrorMessage)
    }

    @MainActor
    func testSelectedModelTitleRequiresExactProviderCatalogMatch() async throws {
        func makeConfiguredViewModel(
            model: String,
            provider: String?,
            modelsJSON: String
        ) throws -> ChatViewModel {
            try makeViewModel(
                sessionSummary: makeSession(model: model, modelProvider: provider)
            ) { request in
                switch request.url?.path {
                case "/api/profiles":
                    return apiTestJSONResponse(#"{"profiles": []}"#, for: request)
                case "/api/models":
                    return apiTestJSONResponse(modelsJSON, for: request)
                case "/api/reasoning":
                    return apiTestJSONResponse(#"{"reasoning_effort": "medium"}"#, for: request)
                case "/api/workspaces":
                    return apiTestJSONResponse(#"{"workspaces": []}"#, for: request)
                case "/api/commands":
                    return apiTestJSONResponse(#"{"commands": []}"#, for: request)
                default:
                    XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                    throw URLError(.badURL)
                }
            }
        }

        let exact = try makeConfiguredViewModel(
            model: "shared/model",
            provider: "openai",
            modelsJSON: """
            {
              "groups": [
                {
                  "name": "OpenAI",
                  "provider_id": "openai",
                  "models": [{"id": "shared/model", "name": "OpenAI Shared"}]
                },
                {
                  "name": "Anthropic",
                  "provider_id": "anthropic",
                  "models": [{"id": "shared/model", "name": "Anthropic Shared"}]
                }
              ]
            }
            """
        )

        await exact.loadComposerConfiguration()
        XCTAssertEqual(exact.selectedModelTitle, "OpenAI Shared")

        let providerMismatch = try makeConfiguredViewModel(
            model: "shared/model",
            provider: "openrouter",
            modelsJSON: """
            {
              "groups": [
                {
                  "name": "OpenAI",
                  "provider_id": "openai",
                  "models": [{"id": "shared/model", "name": "OpenAI Shared"}]
                }
              ]
            }
            """
        )

        await providerMismatch.loadComposerConfiguration()
        XCTAssertEqual(providerMismatch.selectedModelTitle, "model")

        let unknownCustom = try makeConfiguredViewModel(
            model: "vendor/custom-model",
            provider: "openrouter",
            modelsJSON: #"{"groups": []}"#
        )

        await unknownCustom.loadComposerConfiguration()
        XCTAssertEqual(unknownCustom.selectedModelTitle, "custom-model")
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
    func testCompletedResponseRefreshesGeneratedSessionTitle() async throws {
        let streamClient = SpySSEStreamingClient()
        var didRefreshTitle = false
        let viewModel = try makeViewModel(
            streamClient: streamClient,
            sessionSummary: makeSession(title: "Untitled Session")
        ) { request in
            switch request.url?.path {
            case "/api/session":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(query["messages"], "0")
                didRefreshTitle = true
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Generated Meal Plan"
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        XCTAssertEqual(viewModel.displayTitle, "Untitled Session")

        let didStart = await viewModel.seedLegacyResponseForTesting("Name this chat")
        XCTAssertTrue(didStart)
        streamClient.emit(.done(DoneStreamEvent()))
        streamClient.emit(.streamEnd)
        try await waitUntil {
            didRefreshTitle && viewModel.displayTitle == "Generated Meal Plan"
        }

        XCTAssertEqual(viewModel.displayTitle, "Generated Meal Plan")
    }

    @MainActor
    func testDoneUsageReplacesLiveResponseSpeedOnAssistantMessage() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didSend = await viewModel.seedLegacyResponseForTesting("Measure this")
        XCTAssertTrue(didSend)
        streamClient.emit(.token("Measured response."))
        streamClient.emit(.metering(MeteringStreamEvent(
            tokensPerSecond: 18.25,
            isTokensPerSecondAvailable: true,
            isEstimated: false,
            sessionId: "session-abc"
        )))
        XCTAssertEqual(viewModel.liveTokensPerSecond, 18.25)

        streamClient.emit(.done(DoneStreamEvent(usage: ContextWindowSnapshot(
            contextLength: nil,
            thresholdTokens: nil,
            lastPromptTokens: nil,
            inputTokens: nil,
            outputTokens: nil,
            estimatedCost: nil,
            tokensPerSecond: 20.5
        ))))

        XCTAssertNil(viewModel.liveTokensPerSecond)
        XCTAssertEqual(viewModel.messages.last(where: { $0.role == "assistant" })?.turnTps, 20.5)
    }

    @MainActor
    func testDoneUsageAppliesResponseSpeedToLastAssistantInCompletedToolTurn() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didSend = await viewModel.seedLegacyResponseForTesting("Run a tool")
        XCTAssertTrue(didSend)
        streamClient.emit(.token("I'll inspect that."))
        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {"role":"user","content":"Run a tool"},
            {"role":"assistant","content":"I'll inspect that."},
            {"role":"tool","content":"Tool output"},
            {"role":"assistant","content":"Finished."}
          ]
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(
            usage: ContextWindowSnapshot(
                contextLength: nil,
                thresholdTokens: nil,
                lastPromptTokens: nil,
                inputTokens: nil,
                outputTokens: nil,
                estimatedCost: nil,
                tokensPerSecond: 20.5
            ),
            session: completedSession
        )))

        let assistantMessages = viewModel.messages.filter { $0.role == "assistant" }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertNil(assistantMessages.first?.turnTps)
        XCTAssertEqual(assistantMessages.last?.turnTps, 20.5)
        XCTAssertFalse(viewModel.responseCompletionNeedsTranscriptRefresh)
    }

    @MainActor
    func testDoneUsageDoesNotOverwritePreviousAssistantWithoutCurrentStreamingAnchor() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didSend = await viewModel.seedLegacyResponseForTesting("Run a tool only")
        XCTAssertTrue(didSend)
        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {"role":"user","content":"Earlier question","messageId":"user-previous"},
            {"role":"assistant","content":"Earlier answer","messageId":"assistant-previous"},
            {"role":"user","content":"Run a tool only","messageId":"user-current"}
          ]
        }
        """)

        streamClient.emit(.done(DoneStreamEvent(
            usage: ContextWindowSnapshot(
                contextLength: nil,
                thresholdTokens: nil,
                lastPromptTokens: nil,
                inputTokens: nil,
                outputTokens: nil,
                estimatedCost: nil,
                tokensPerSecond: 20.5
            ),
            session: completedSession
        )))

        XCTAssertNil(viewModel.messages.first(where: { $0.messageId == "assistant-previous" })?.turnTps)
        XCTAssertFalse(viewModel.messages.contains(where: { $0.turnTps != nil }))
    }

    @MainActor
    func testCompletedResponseCachesFinalTurnTpsWithoutTranscriptReload() async throws {
        let streamClient = SpySSEStreamingClient()
        let modelContext = try makeContext()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didSend = await viewModel.seedLegacyResponseForTesting("Measure this", modelContext: modelContext)
        XCTAssertTrue(didSend)
        streamClient.emit(.token("Measured response."))
        let completedSession = try makeSessionDetail("""
        {
          "session_id": "session-abc",
          "messages": [
            {"role":"user","content":"Measure this","messageId":"user-current"},
            {"role":"assistant","content":"Measured response.","messageId":"assistant-server"}
          ]
        }
        """)
        streamClient.emit(.done(DoneStreamEvent(
            usage: ContextWindowSnapshot(
                contextLength: nil,
                thresholdTokens: nil,
                lastPromptTokens: nil,
                inputTokens: nil,
                outputTokens: nil,
                estimatedCost: nil,
                tokensPerSecond: 20.5
            ),
            session: completedSession
        )))

        XCTAssertFalse(viewModel.responseCompletionNeedsTranscriptRefresh)
        viewModel.cacheCompletedResponse(modelContext: modelContext)

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: URL(string: "https://example.test")!,
            sessionID: "session-abc",
            in: modelContext
        )
        XCTAssertEqual(
            cachedMessages.first(where: { $0.messageId == "assistant-server" })?.turnTps,
            20.5
        )
    }

    @MainActor
    func testTransportErrorChecksStatusAndFinishesWhenStreamIsInactive() async throws {
        let streamClient = SpySSEStreamingClient()
        var didRequestStatus = false
        var didReloadMessages = false
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/stream/status":
                didRequestStatus = true
                return apiTestJSONResponse("""
                {
                  "active": false,
                  "stream_id": "stream-123"
                }
                """, for: request)
            case "/api/session":
                didReloadMessages = true
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "title": "Planning",
                    "messages": [
                      {
                        "role": "assistant",
                        "content": "Recovered transcript.",
                        "timestamp": 1770000100,
                        "message_id": "assistant-1"
                      }
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        XCTAssertEqual(viewModel.activeStreamID, "stream-123")

        streamClient.emit(.transportError("The network connection was lost."))
        try await waitUntil {
            didRequestStatus && didReloadMessages
        }

        XCTAssertTrue(didRequestStatus)
        XCTAssertTrue(didReloadMessages)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertEqual(viewModel.messages.map(\.content), ["Recovered transcript."])
        XCTAssertNil(viewModel.sendErrorMessage)
        XCTAssertEqual(streamClient.stopCount, 2)
    }


    @MainActor
    func testLoadMessagesDoesNotFailForWebUICreatedSessionDecodeDrift() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "title": "WebUI-created",
                "messages": [
                  {
                    "role": "user",
                    "content": [
                      {"type": "text", "text": "Open this in mobile"}
                    ],
                    "_ts": "1770000000",
                    "message_id": 42
                  },
                  {
                    "role": "assistant",
                    "content": "Loaded",
                    "timestamp": 1770000001,
                    "tool_calls": {"unexpected": "shape"}
                  }
                ],
                "_messages_offset": "8"
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isViewingCachedData)
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messagesOffset, 8)
        XCTAssertEqual(viewModel.messages.first?.messageId, "42")
        XCTAssertTrue(viewModel.messages.first?.content?.contains("Open this in mobile") == true)
    }

    @MainActor
    func testLoadMessagesTracksOlderHistoryAvailability() async throws {
        let viewModel = try makeViewModel { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "session-abc",
                "messages": [
                  {"role": "user", "content": "Recent question", "timestamp": 1, "message_id": "u-50"}
                ],
                "_messages_truncated": true,
                "_messages_offset": 50
              }
            }
            """, for: request)
        }

        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.messagesOffset, 50)
        XCTAssertTrue(viewModel.hasOlderMessages)
    }

    @MainActor
    func testSkillShortcutWithoutArgsReturnsLocalSkillInfoWithoutStartingChat() async throws {
        var didRequestSkills = false
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/skills":
                didRequestSkills = true
                return apiTestJSONResponse("""
                {
                  "skills": [
                    {
                      "name": "Spotify",
                      "category": "media",
                      "description": "Control Spotify playback."
                    }
                  ]
                }
                """, for: request)
            case "/api/chat/start":
                XCTFail("Skill shortcut without args should not start chat.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSkillShortcutCommand(name: "spotify", args: "")

        XCTAssertTrue(didRequestSkills)
        guard case .executed(let message) = result else {
            XCTFail("Expected local skill detail response.")
            return
        }
        let unwrappedMessage = try XCTUnwrap(message)
        XCTAssertTrue(unwrappedMessage.contains("### `/spotify`"))
        XCTAssertTrue(unwrappedMessage.contains("Control Spotify playback."))
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.activeStreamID)
    }

    @MainActor
    func testSkillShortcutWithArgsDirectRefusalDoesNotStartChat() async throws {
        let transport = SendRetirementDirectTransport()
        let server = URL(string: "https://example.test")!
        let runtime = try HermesServerRuntime(origin: server) { sink in
            transport.installSink(sink)
            return transport
        }
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Unsupported direct shortcut must not use a WebUI lookup or send")
            throw URLError(.badURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let viewModel = ChatViewModel(session: SessionSummary(profile: "work"), server: server,
            client: client, gatewayRuntimeProvider: { _ in runtime })
        let result = await viewModel.executeSkillShortcutCommand(name: "spotify", args: "check songs")
        XCTAssertEqual(result, .unsupported(friendlyMessage: "Skills are not available in direct Hermes mode yet."))
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.activeStreamID)
        XCTAssertTrue(transport.methods().isEmpty)
        await runtime.stop()
    }

    @MainActor
    func testEditUserMessageTruncatesBeforeMessageThenStartsChatWithEditedText() async throws {
        var requestPaths: [String] = []
        var truncateKeepCount: Int?
        var startedMessage: String?
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            requestPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "_messages_offset": 10,
                    "messages": [
                      {"role": "user", "content": "First question", "timestamp": 1, "message_id": "u-10"},
                      {"role": "assistant", "content": "First answer", "timestamp": 2, "message_id": "a-11"},
                      {"role": "user", "content": "Original question", "timestamp": 3, "message_id": "u-12"},
                      {"role": "assistant", "content": "Original answer", "timestamp": 4, "message_id": "a-13"}
                    ]
                  }
                }
                """, for: request)
            case "/api/session/truncate":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                truncateKeepCount = body["keep_count"] as? Int
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "_messages_offset": 10,
                    "messages": [
                      {"role": "user", "content": "First question", "timestamp": 1, "message_id": "u-10"},
                      {"role": "assistant", "content": "First answer", "timestamp": 2, "message_id": "a-11"}
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/start":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                startedMessage = body["message"] as? String
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-edit"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let context = try XCTUnwrap(viewModel.actionContext(for: viewModel.messages[2], visibleIndex: 2))
        let didEdit = await viewModel.editMessage(context, newText: "  Edited question  ")

        XCTAssertTrue(didEdit)
        XCTAssertEqual(requestPaths, ["/api/session", "/api/session/truncate", "/api/chat/start"])
        XCTAssertEqual(truncateKeepCount, 12)
        XCTAssertEqual(startedMessage, "Edited question")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["First question", "First answer", "Edited question"])
        XCTAssertEqual(viewModel.activeStreamID, "stream-edit")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testRegenerateAssistantResponseUsesPrecedingUserAndTruncatesAtAssistantIndex() async throws {
        var truncateKeepCount: Int?
        var startedMessage: String?
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "_messages_offset": 5,
                    "messages": [
                      {"role": "user", "content": "First question", "timestamp": 1, "message_id": "u-5"},
                      {"role": "assistant", "content": "First answer", "timestamp": 2, "message_id": "a-6"},
                      {"role": "user", "content": "Second question", "timestamp": 3, "message_id": "u-7"},
                      {"role": "assistant", "content": "Second answer", "timestamp": 4, "message_id": "a-8"}
                    ]
                  }
                }
                """, for: request)
            case "/api/session/truncate":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                truncateKeepCount = body["keep_count"] as? Int
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "_messages_offset": 5,
                    "messages": [
                      {"role": "user", "content": "First question", "timestamp": 1, "message_id": "u-5"},
                      {"role": "assistant", "content": "First answer", "timestamp": 2, "message_id": "a-6"},
                      {"role": "user", "content": "Second question", "timestamp": 3, "message_id": "u-7"}
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/start":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                startedMessage = body["message"] as? String
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-regen"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let context = try XCTUnwrap(viewModel.actionContext(for: viewModel.messages[3], visibleIndex: 3))
        let didRegenerate = await viewModel.regenerateAssistantResponse(context)

        XCTAssertTrue(didRegenerate)
        XCTAssertEqual(truncateKeepCount, 8)
        XCTAssertEqual(startedMessage, "Second question")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["First question", "First answer", "Second question"])
        XCTAssertEqual(viewModel.activeStreamID, "stream-regen")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testDelayedSceneRefreshCannotRestoreHistoryDiscardedByEdit() async throws {
        var sessionLoads = 0
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                sessionLoads += 1
                if sessionLoads == 1 {
                    return apiTestJSONResponse("""
                    {
                      "session": {
                        "session_id": "session-abc",
                        "messages": [
                          {"role":"user","content":"Keep me","timestamp":1,"message_id":"u-1"},
                          {"role":"assistant","content":"Keep answer","timestamp":2,"message_id":"a-2"},
                          {"role":"user","content":"Discard me","timestamp":3,"message_id":"u-3"},
                          {"role":"assistant","content":"Discarded answer","timestamp":4,"message_id":"a-4"}
                        ]
                      }
                    }
                    """, for: request)
                }
                Thread.sleep(forTimeInterval: 0.20)
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role":"user","content":"Keep me","timestamp":1,"message_id":"u-1"},
                      {"role":"assistant","content":"Keep answer","timestamp":2,"message_id":"a-2"},
                      {"role":"user","content":"Discard me","timestamp":3,"message_id":"u-3"},
                      {"role":"assistant","content":"Discarded answer","timestamp":4,"message_id":"a-4"}
                    ]
                  }
                }
                """, for: request)
            case "/api/session/truncate":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role":"user","content":"Keep me","timestamp":1,"message_id":"u-1"},
                      {"role":"assistant","content":"Keep answer","timestamp":2,"message_id":"a-2"}
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/start":
                Thread.sleep(forTimeInterval: 0.25)
                return apiTestJSONResponse(#"{"session_id":"session-abc","stream_id":"stream-edit"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let context = try XCTUnwrap(viewModel.actionContext(for: viewModel.messages[2], visibleIndex: 2))
        let delayedRefresh = Task { @MainActor in
            await viewModel.refreshAfterSceneActivation()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let didEdit = await viewModel.editMessage(context, newText: "Edited question")
        await delayedRefresh.value

        XCTAssertTrue(didEdit)
        XCTAssertEqual(viewModel.activeStreamID, "stream-edit")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep me", "Keep answer", "Edited question"])
        XCTAssertFalse(viewModel.messages.compactMap(\.content).contains("Discarded answer"))
    }

    @MainActor
    func testDelayedSceneRefreshCannotRestoreHistoryDiscardedByRegenerate() async throws {
        var sessionLoads = 0
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session":
                sessionLoads += 1
                if sessionLoads == 1 {
                    return apiTestJSONResponse("""
                    {
                      "session": {
                        "session_id": "session-abc",
                        "messages": [
                          {"role":"user","content":"Keep question","timestamp":1,"message_id":"u-1"},
                          {"role":"assistant","content":"Old answer","timestamp":2,"message_id":"a-2"}
                        ]
                      }
                    }
                    """, for: request)
                }
                Thread.sleep(forTimeInterval: 0.20)
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role":"user","content":"Keep question","timestamp":1,"message_id":"u-1"},
                      {"role":"assistant","content":"Old answer","timestamp":2,"message_id":"a-2"}
                    ]
                  }
                }
                """, for: request)
            case "/api/session/truncate":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role":"user","content":"Keep question","timestamp":1,"message_id":"u-1"}
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/start":
                Thread.sleep(forTimeInterval: 0.25)
                return apiTestJSONResponse(#"{"session_id":"session-abc","stream_id":"stream-regen"}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let context = try XCTUnwrap(viewModel.actionContext(for: viewModel.messages[1], visibleIndex: 1))
        let delayedRefresh = Task { @MainActor in
            await viewModel.refreshAfterSceneActivation()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let didRegenerate = await viewModel.regenerateAssistantResponse(context)
        await delayedRefresh.value

        XCTAssertTrue(didRegenerate)
        XCTAssertEqual(viewModel.activeStreamID, "stream-regen")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Keep question"])
        XCTAssertFalse(viewModel.messages.compactMap(\.content).contains("Old answer"))
    }

    @MainActor
    func testForkFromMessageUsesKeepCountThroughMessageAndHandlesMissingForkID() async throws {
        var branchBodies: [[String: Any]] = []
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                if query["session_id"] == "fork-123" {
                    return apiTestJSONResponse("""
                    {
                      "session": {
                        "session_id": "fork-123",
                        "title": "Forked thread"
                      }
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "_messages_offset": 4,
                    "messages": [
                      {"role": "user", "content": "Question", "timestamp": 1, "message_id": "u-4"},
                      {"role": "assistant", "content": "Answer", "timestamp": 2, "message_id": "a-5"}
                    ]
                  }
                }
                """, for: request)
            case "/api/session/branch":
                branchBodies.append(try XCTUnwrap(apiTestJSONBody(from: request)))
                if branchBodies.count == 1 {
                    return apiTestJSONResponse("""
                    {
                      "session_id": "fork-123",
                      "parent_session_id": "session-abc"
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "error": "Could not fork"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        await viewModel.loadMessages()
        let context = try XCTUnwrap(viewModel.actionContext(for: viewModel.messages[1], visibleIndex: 1))
        let forked = await viewModel.forkFromMessage(context)
        let missingID = await viewModel.forkFromMessage(context)

        XCTAssertEqual(branchBodies.count, 2)
        XCTAssertEqual(branchBodies[0]["session_id"] as? String, "session-abc")
        XCTAssertEqual(branchBodies[0]["keep_count"] as? Int, 6)
        XCTAssertEqual(forked?.sessionId, "fork-123")
        XCTAssertNil(missingID)
        XCTAssertEqual(viewModel.messageActionErrorMessage, "Could not fork")
    }

    @MainActor
    func testUndoSlashCommandCallsServerThenReloadsMessages() async throws {
        var requestPaths: [String] = []
        let viewModel = try makeViewModel { request in
            requestPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session/undo":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "removed_count": 2
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Remaining message", "timestamp": 1, "message_id": "u-1"}
                    ]
                  }
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "undo")))

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(requestPaths, ["/api/session/undo", "/api/session"])
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Remaining message"])
    }

    @MainActor
    func testUndoSlashCommandIsBlockedWhileStreaming() async throws {
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/session/undo":
                XCTFail("Undo should not call the server while streaming.")
                throw URLError(.badURL)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Keep working")
        XCTAssertTrue(didStart)
        let result = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "undo")))

        XCTAssertEqual(result, .unsupported(friendlyMessage: "Wait for the current response to finish before undoing messages."))
    }

    @MainActor
    func testRetrySlashCommandReloadsTruncatedSessionThenStartsChatWithLastUserText() async throws {
        var requestPaths: [String] = []
        var startedMessage: String?
        let streamClient = SpySSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            requestPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session/retry":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                XCTAssertEqual(body["session_id"] as? String, "session-abc")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "last_user_text": "Summarize the logs",
                  "removed_count": 2
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": [
                      {"role": "user", "content": "Earlier message", "timestamp": 1, "message_id": "u-1"}
                    ]
                  }
                }
                """, for: request)
            case "/api/chat/start":
                let body = try XCTUnwrap(apiTestJSONBody(from: request))
                startedMessage = body["message"] as? String
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "stream_id": "stream-retry"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let result = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "retry")))

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(requestPaths, ["/api/session/retry", "/api/session", "/api/chat/start"])
        XCTAssertEqual(startedMessage, "Summarize the logs")
        XCTAssertEqual(viewModel.messages.compactMap(\.content), ["Earlier message", "Summarize the logs"])
        XCTAssertEqual(viewModel.activeStreamID, "stream-retry")
        XCTAssertEqual(streamClient.startedURLs.count, 1)
    }

    @MainActor
    func testRetrySlashCommandHandlesMissingLastUserTextAndMissingStreamID() async throws {
        var retryCount = 0
        var startCount = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session/retry":
                retryCount += 1
                if retryCount == 1 {
                    return apiTestJSONResponse("""
                    {
                      "ok": true,
                      "removed_count": 2
                    }
                    """, for: request)
                }

                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "last_user_text": "Try again",
                  "removed_count": 2
                }
                """, for: request)
            case "/api/session":
                return apiTestJSONResponse("""
                {
                  "session": {
                    "session_id": "session-abc",
                    "messages": []
                  }
                }
                """, for: request)
            case "/api/chat/start":
                startCount += 1
                return apiTestJSONResponse("""
                {
                  "session_id": "session-abc",
                  "error": "No stream"
                }
                """, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let retry = try XCTUnwrap(SlashCommandCatalog.command(named: "retry"))
        let missingTextResult = await viewModel.executeSlashCommand(retry)
        let missingStreamResult = await viewModel.executeSlashCommand(retry)

        XCTAssertEqual(
            missingTextResult,
            .unsupported(friendlyMessage: "The server did not return a message to retry.")
        )
        XCTAssertEqual(
            missingStreamResult,
            .unsupported(friendlyMessage: "No stream")
        )
        XCTAssertEqual(startCount, 1)
        XCTAssertNil(viewModel.activeStreamID)
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

        await viewModel.loadMessages()
        let result = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "clear")))

        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(requestCount, 1)
    }

    /// A retained SSE renderer can drain a queue, but cannot reopen WebUI send.
    @MainActor
    func testQueuedSlashMessageWithoutDirectRuntimeNeverFallsBackToLegacySend() async throws {
        let streamClient = SpySSEStreamingClient()
        var startChatAttempts = 0
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            startChatAttempts += 1
            XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }

        // 1. Establish a live stream so the queued message has something to wait behind.
        let didStart = await viewModel.seedLegacyResponseForTesting("first message")
        XCTAssertTrue(didStart)
        XCTAssertNotNil(viewModel.activeStreamID)

        // 2. Queue one slash message behind the active stream.
        let queueCommand = try XCTUnwrap(SlashCommandCatalog.command(named: "queue"))
        let queued = await viewModel.executeSlashCommand(queueCommand, args: "retry-me")
        XCTAssertEqual(queued, .executed(message: "Queued for next turn (#1)."))

        let attemptsBeforeDrain = startChatAttempts // state-only setup made no request

        // 3. Finishing the stream is the natural drain trigger. The drained send fails persistently.
        streamClient.emit(.streamEnd)
        XCTAssertNil(viewModel.activeStreamID)

        // 4. Let the drain (and any retry loop) fully quiesce. MockURLProtocol resolves
        //    synchronously, so once the attempt count is stable across several short polls no
        //    further sends are in flight.
        var lastSeen = startChatAttempts
        var stablePolls = 0
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if startChatAttempts == lastSeen {
                stablePolls += 1
                if stablePolls >= 3 { break }
            } else {
                stablePolls = 0
                lastSeen = startChatAttempts
            }
        }

        let drainedAttempts = startChatAttempts - attemptsBeforeDrain

        // A retained renderer cannot reopen the retired WebUI send path.
        XCTAssertEqual(
            drainedAttempts,
            0,
            "Missing direct ownership must never fall back to WebUI. "
                + "Observed \(drainedAttempts) drained attempt(s)."
        )
        // The message remains queued for a later natural trigger instead of being dropped.
        let status = await viewModel.executeSlashCommand(try XCTUnwrap(SlashCommandCatalog.command(named: "status")))
        guard case let .executed(message) = status, let statusText = message else {
            return XCTFail("Expected /status to return an executed message, got \(status).")
        }
        XCTAssertTrue(
            statusText.contains("Queued messages: 1"),
            "The failed queued message should still be queued. Status was:\n\(statusText)"
        )
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
        let messageJSON = (0..<120).map { index in
            #"{"role":"user","content":"Message \#(index)","timestamp":\#(index),"message_id":"message-\#(index)"}"#
        }.joined(separator: ",")
        let sessionJSON = """
        {
          "session": {
            "session_id": "session-abc",
            "messages": [\(messageJSON)],
            "message_count": 120,
            "messages_offset": 120,
            "messages_truncated": true
          }
        }
        """
        let viewModel = try makeViewModel { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(sessionJSON.utf8))
        }
        let recomputationsBeforeLoad = viewModel.transcriptDerivedStateRecomputeCountForTesting

        await viewModel.loadMessages()

        XCTAssertEqual(viewModel.messages.count, 120)
        XCTAssertEqual(viewModel.messagesOffset, 120)
        XCTAssertEqual(
            viewModel.transcriptDerivedStateRecomputeCountForTesting - recomputationsBeforeLoad,
            1
        )
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

    private func makeEphemeralUserDefaults() throws -> UserDefaults {
        let suiteName = "HermesMobileTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    @MainActor
    private func makeViewModel(
        streamClient: SSEStreamingClient? = nil,
        approvalStreamClient: SSEStreamingClient? = nil,
        clarifyStreamClient: SSEStreamingClient? = nil,
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

        let resolvedStreamClient = streamClient ?? SpySSEStreamingClient()
        let viewModel = ChatViewModel(
            session: summary,
            server: server,
            client: client,
            streamClient: resolvedStreamClient,
            approvalStreamClient: approvalStreamClient ?? SpySSEStreamingClient(),
            clarifyStreamClient: clarifyStreamClient ?? SpySSEStreamingClient(),
            liveActivityManager: liveActivityManager,
            pollingIntervals: pollingIntervals,
            streamingScrollCoalescingDelayNanoseconds: streamingScrollCoalescingDelayNanoseconds,
            speechSynthesizerFactory: speechSynthesizerFactory,
            // Default to a spy so unit tests never drive the live shared AVAudioSession.
            listenAudioSession: listenAudioSession ?? SpyListenAudioSession(),
            listenRemoteControlCenter: listenRemoteControlCenter ?? SpyListenRemoteControlCenter(),
            serverTTSAudioPlayerFactory: serverTTSAudioPlayerFactory,
            userDefaults: userDefaults
        )

        if let spyStreamClient = resolvedStreamClient as? SpySSEStreamingClient {
            spyStreamClient.flushPendingStreamingContent = { [weak viewModel] in
                viewModel?.flushPendingStreamingContent()
            }
        }

        return viewModel
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
    func testLiveStreamContentCoalescesRapidTokenUpdates() async throws {
        let streamClient = SpySSEStreamingClient()
        streamClient.automaticallyFlushPendingStreamingContent = false
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            XCTFail("Renderer setup must not submit a legacy chat request")
            throw URLError(.badURL)
        }

        let didStart = await viewModel.seedLegacyResponseForTesting("Stream a long response")
        XCTAssertTrue(didStart)

        for index in 0..<25 {
            streamClient.emit(.token("chunk-\(index)"))
        }

        try await waitForStreamingContent(
            viewModel,
            toSatisfy: { $0 == (0..<25).map { "chunk-\($0)" }.joined() }
        )
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

private final class SpySSEStreamingClient: SSEStreamingClient {
    private(set) var startedURLs: [URL] = []
    private(set) var stopCount = 0
    private(set) var lastEventID: String?
    private var onEvent: (@MainActor (SSEEvent) -> Void)?
    var automaticallyFlushPendingStreamingContent = true
    var flushPendingStreamingContent: (() -> Void)?

    func start(url: URL, onEvent: @escaping @MainActor (SSEEvent) -> Void) {
        startedURLs.append(url)
        lastEventID = nil
        self.onEvent = onEvent
    }

    func stop() {
        stopCount += 1
    }

    @MainActor
    func emit(_ event: SSEEvent, lastEventID: String? = nil) {
        self.lastEventID = lastEventID
        onEvent?(event)
        if automaticallyFlushPendingStreamingContent {
            flushPendingStreamingContent?()
        }
    }
}

private final class OutOfOrderChatSessionURLProtocol: URLProtocol {
    enum Mode: Equatable {
        case newestSucceeds
        case bothFail
        case staleLoadThenSend
        case delayedStatusAfterSend
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
            if mode == .delayedStatusAfterSend {
                delayNanoseconds = url.path == "/api/chat/stream/status" ? 200_000_000 : 10_000_000
            } else {
                delayNanoseconds = ordinal == 1 ? 200_000_000 : 10_000_000
            }
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }

            let statusCode: Int
            let data: Data
            switch mode {
            case .newestSucceeds:
                let content = ordinal == 1 ? "Stale transcript" : "Fresh transcript"
                let messageID = ordinal == 1 ? "stale-message" : "fresh-message"
                statusCode = 200
                data = Data("""
                {"session":{"session_id":"session-abc","title":"Planning","messages":[{"role":"assistant","content":"\(content)","timestamp":1770000100,"message_id":"\(messageID)"}]}}
                """.utf8)
            case .bothFail:
                statusCode = 500
                data = Data(#"{"error":"boom"}"#.utf8)
            case .staleLoadThenSend:
                statusCode = 200
                if url.path == "/api/chat/start" {
                    data = Data(#"{"session_id":"session-abc","stream_id":"stream-new"}"#.utf8)
                } else {
                    data = Data(#"{"session":{"session_id":"session-abc","title":"Planning","messages":[{"role":"assistant","content":"Stale transcript","timestamp":1770000100,"message_id":"stale-message"}]}}"#.utf8)
                }
            case .delayedStatusAfterSend:
                statusCode = 200
                if url.path == "/api/chat/start" {
                    data = Data(#"{"session_id":"session-abc","stream_id":"stream-new"}"#.utf8)
                } else {
                    data = Data(#"{"active":true,"stream_id":"stream-new","replay_available":true}"#.utf8)
                }
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
