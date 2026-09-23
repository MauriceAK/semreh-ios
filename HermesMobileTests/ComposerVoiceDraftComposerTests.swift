import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

final class ComposerVoiceDraftComposerTests: XCTestCase {
    func testComposerSendKeyboardCommandIsDiscoverableCommandReturn() {
        XCTAssertEqual(ComposerKeyboardCommand.title, "Send Message")
        XCTAssertEqual(ComposerKeyboardCommand.input, "\r")
        XCTAssertEqual(ComposerKeyboardCommand.modifierFlags, .command)
    }

    func testComposedDraftUsesTranscriptWhenDraftIsEmpty() {
        XCTAssertEqual(
            ComposerVoiceDraftComposer.composedDraft(baseDraft: "", transcript: "Open the workspace"),
            "Open the workspace"
        )
    }

    func testComposedDraftAppendsTranscriptToExistingDraft() {
        XCTAssertEqual(
            ComposerVoiceDraftComposer.composedDraft(baseDraft: "Please", transcript: "summarize this file"),
            "Please summarize this file"
        )
    }

    func testComposedDraftPreservesBaseDraftWhenTranscriptIsBlank() {
        XCTAssertEqual(
            ComposerVoiceDraftComposer.composedDraft(baseDraft: "Keep this", transcript: "   \n"),
            "Keep this"
        )
    }

    func testDraftUpdateSessionComposesWhileAcceptingUpdates() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "Please")

        XCTAssertEqual(session.composedDraft(for: "summarize this file"), "Please summarize this file")
    }

    func testDraftUpdateSessionIgnoresLateTranscriptAfterStop() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "Send this")
        session.stopAcceptingUpdates()

        XCTAssertNil(session.composedDraft(for: "late final transcript"))
    }

    func testDraftUpdateSessionUsesNewBaseDraftAfterRestart() {
        var session = ComposerVoiceDraftUpdateSession()

        session.begin(baseDraft: "Old")
        session.stopAcceptingUpdates()
        session.begin(baseDraft: "New")

        XCTAssertEqual(session.composedDraft(for: "transcript"), "New transcript")
    }

    func testVoiceInputPreflightAcceptsValidInputFormatValues() {
        XCTAssertNoThrow(
            try ComposerVoiceInputPreflight.validate(sampleRate: 44_100, channelCount: 1)
        )
    }

    func testVoiceLevelMapsSilenceSpeechAndInvalidPowerIntoBoundedRange() {
        XCTAssertEqual(ComposerVoiceAudioLevel.normalized(decibels: -.infinity), 0)
        XCTAssertEqual(ComposerVoiceAudioLevel.normalized(decibels: -60), 0)
        XCTAssertGreaterThan(ComposerVoiceAudioLevel.normalized(decibels: -25), 0.5)
        XCTAssertEqual(ComposerVoiceAudioLevel.normalized(decibels: 0), 1)
    }

    func testVoiceLevelReadsSyntheticAudioWithoutKeepingSamples() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
        buffer.frameLength = 32
        let samples = buffer.floatChannelData![0]
        for index in 0..<32 { samples[index] = 0 }
        XCTAssertEqual(ComposerVoiceAudioLevel.normalized(buffer: buffer), 0)

        for index in 0..<32 { samples[index] = 0.2 }
        XCTAssertGreaterThan(ComposerVoiceAudioLevel.normalized(buffer: buffer), 0.6)
    }

    func testVoiceLevelAttacksFasterThanItDecays() {
        let attack = ComposerVoiceAudioLevel.smoothed(previous: 0, incoming: 1)
        let decay = ComposerVoiceAudioLevel.smoothed(previous: 1, incoming: 0)
        XCTAssertGreaterThan(attack, 1 - decay)
        XCTAssertTrue((0...1).contains(ComposerVoiceAudioLevel.smoothed(previous: .nan, incoming: .infinity)))
    }

    @MainActor
    func testVoiceStatusMeterAndTranscribingKeepTheSameHeight() {
        let sizes = [
            ComposerVoiceStatus(text: "Listening...", systemImage: "waveform", isError: false, inputLevel: 0),
            ComposerVoiceStatus(text: "Listening...", systemImage: "waveform", isError: false, inputLevel: 1),
            ComposerVoiceStatus(text: "Transcribing...", systemImage: "waveform", isError: false, isTranscribing: true)
        ].map { status in
            UIHostingController(rootView: ComposerVoiceStatusView(status: status))
                .sizeThatFits(in: CGSize(width: 240, height: 100))
        }

        XCTAssertGreaterThan(sizes[0].height, 0)
        XCTAssertEqual(sizes[0].height, sizes[1].height, accuracy: 1)
        XCTAssertEqual(sizes[1].height, sizes[2].height, accuracy: 1)
    }

    func testVoiceInputPreflightRejectsZeroSampleRate() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(sampleRate: 0, channelCount: 1)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsInfiniteSampleRate() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(sampleRate: .infinity, channelCount: 1)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsTooLowSampleRate() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(
                sampleRate: ComposerVoiceInputPreflight.validSampleRateRange.lowerBound - 1,
                channelCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsTooHighSampleRate() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(
                sampleRate: ComposerVoiceInputPreflight.validSampleRateRange.upperBound + 1,
                channelCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsZeroChannelCount() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(sampleRate: 44_100, channelCount: 0)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputPreflightRejectsTooHighChannelCount() {
        XCTAssertThrowsError(
            try ComposerVoiceInputPreflight.validate(
                sampleRate: 44_100,
                channelCount: ComposerVoiceInputPreflight.validChannelCountRange.upperBound + 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputAudioSessionConfigurationDoesNotDuckOtherAudio() {
        XCTAssertEqual(ComposerVoiceAudioSessionConfiguration.category, .playAndRecord)
        XCTAssertEqual(ComposerVoiceAudioSessionConfiguration.mode, .measurement)
        XCTAssertTrue(ComposerVoiceAudioSessionConfiguration.options.contains(.mixWithOthers))
        XCTAssertTrue(ComposerVoiceAudioSessionConfiguration.options.contains(.allowBluetoothHFP))
        XCTAssertFalse(ComposerVoiceAudioSessionConfiguration.options.contains(.duckOthers))
    }

    func testVoiceInputStartPolicyAllowsActiveAppState() {
        XCTAssertTrue(ComposerVoiceInputStartPolicy.canStart(appIsActive: true))
    }

    func testVoiceInputStartPolicyRejectsInactiveAppState() {
        XCTAssertFalse(ComposerVoiceInputStartPolicy.canStart(appIsActive: false))
    }

    func testVoiceInputStartPolicyRejectsMissingAudioInput() {
        XCTAssertThrowsError(
            try ComposerVoiceInputStartPolicy.validateAudioSessionInput(
                isInputAvailable: false,
                sampleRate: 44_100,
                inputNumberOfChannels: 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .noAudioInput)
        }
    }

    func testVoiceInputStartPolicyRejectsInvalidSessionFormat() {
        XCTAssertThrowsError(
            try ComposerVoiceInputStartPolicy.validateAudioSessionInput(
                isInputAvailable: true,
                sampleRate: 0,
                inputNumberOfChannels: 1
            )
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .invalidInputFormat)
        }
    }

    func testVoiceInputStartPolicyRejectsRunningEngineBeforeTapInstall() {
        XCTAssertThrowsError(
            try ComposerVoiceInputStartPolicy.validateAudioEngine(isRunning: true)
        ) { error in
            XCTAssertEqual(error as? ComposerVoiceInputError, .audioEngineAlreadyRunning)
        }
    }

    @MainActor
    func testVoiceInputControllerDoesNotCreateSpeechOrAudioObjectsBeforeRecording() {
        let counter = VoiceInputFactoryCounter()
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: {
                counter.speechRecognizerCalls += 1
                return nil
            },
            audioEngineFactory: {
                counter.audioEngineCalls += 1
                return AVAudioEngine()
            }
        )

        XCTAssertEqual(counter.speechRecognizerCalls, 0)
        XCTAssertEqual(counter.audioEngineCalls, 0)

        controller.stopKeepingTranscript()

        XCTAssertEqual(counter.speechRecognizerCalls, 0)
        XCTAssertEqual(counter.audioEngineCalls, 0)
    }

    func testSTTProviderPreferenceDefaultsToServerFirst() {
        XCTAssertEqual(ComposerSTTProviderPreference.defaultValue, .serverFirst)
        XCTAssertEqual(
            ComposerSTTProviderPreference.storedValue("unknown"),
            .serverFirst
        )
    }

    func testServerFirstPolicyPrefersServerThenOnDevice() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .serverFirst,
                serverConfigured: true,
                onDeviceSupported: true
            ),
            [.server, .onDevice]
        )
    }

    func testServerFirstPolicyFallsBackToOnDeviceWhenServerIsNotConfigured() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .serverFirst,
                serverConfigured: false,
                onDeviceSupported: true
            ),
            [.onDevice]
        )
    }

    func testOnDeviceFirstPolicyFallsBackToServerWhenOnDeviceIsUnsupported() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .onDeviceFirst,
                serverConfigured: true,
                onDeviceSupported: false
            ),
            [.server]
        )
    }

    func testOnDeviceOnlyPolicyNeverRoutesToServer() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .onDeviceOnly,
                serverConfigured: true,
                onDeviceSupported: true
            ),
            [.onDevice]
        )
        XCTAssertEqual(
            ComposerSTTProviderPolicy.orderedProviders(
                preference: .onDeviceOnly,
                serverConfigured: true,
                onDeviceSupported: false
            ),
            []
        )
    }

    func testProviderPolicyReturnsNextFallbackOnly() {
        XCTAssertEqual(
            ComposerSTTProviderPolicy.fallbackProvider(
                after: .server,
                preference: .serverFirst,
                serverConfigured: true,
                onDeviceSupported: true
            ),
            .onDevice
        )
        XCTAssertNil(
            ComposerSTTProviderPolicy.fallbackProvider(
                after: .server,
                preference: .onDeviceOnly,
                serverConfigured: true,
                onDeviceSupported: true
            )
        )
    }
}

private final class VoiceInputFactoryCounter {
    var speechRecognizerCalls = 0
    var audioEngineCalls = 0
}
