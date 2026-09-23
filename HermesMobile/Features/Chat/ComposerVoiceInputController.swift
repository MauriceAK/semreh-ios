import AVFoundation
import Foundation
import Observation
import OSLog
import Speech
import UIKit

@MainActor
@Observable
final class ComposerVoiceInputController {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case serverListening
        case transcribing
    }

    private(set) var state: State = .idle
    private(set) var errorMessage: String?
    private(set) var liveTranscript = ""
    private(set) var inputLevel = 0.0

    private let speechRecognizerFactory: () -> SFSpeechRecognizer?
    private let audioEngineFactory: () -> AVAudioEngine
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var draftUpdateSession = ComposerVoiceDraftUpdateSession()
    private var updateDraft: ((String) -> Void)?
    private var suppressNextRecognitionError = false
    private var activatedAudioSessionForRecording = false
    private var audioTapInstalled = false
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var serverRecordingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var recognitionFinalizationTask: Task<Void, Never>?
    private var activeTranscriptionID: UUID?
    private var activeRecognitionID: UUID?
    private let logger = Logger.hermesVoiceInput

    @ObservationIgnored var apiClient: APIClient?
    @ObservationIgnored var profileName = "default"
    @ObservationIgnored var currentProfile: (() -> String)?
    private var recordingProfileName = "default"
    @ObservationIgnored var providerPreference = ComposerSTTProviderPreference.defaultValue
    @ObservationIgnored var locale = Locale.current

    init(
        speechRecognizerFactory: @escaping () -> SFSpeechRecognizer? = { SFSpeechRecognizer(locale: Locale.current) },
        audioEngineFactory: @escaping () -> AVAudioEngine = { AVAudioEngine() }
    ) {
        self.speechRecognizerFactory = speechRecognizerFactory
        self.audioEngineFactory = audioEngineFactory
    }

    deinit {
        meterTimer?.invalidate()
        recognitionFinalizationTask?.cancel()
        serverRecordingTimeoutTask?.cancel()
    }

    var isListening: Bool {
        state == .listening || state == .serverListening || state == .transcribing
    }

    static func profileScope(selected: String?, session: String?) -> String {
        for value in [selected, session] {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return "default"
    }

    var isRequestingPermission: Bool {
        state == .requestingPermission
    }

    func toggle(currentDraft: String, updateDraft: @escaping (String) -> Void) async {
        if isListening {
            stopKeepingTranscript()
        } else {
            await start(currentDraft: currentDraft, updateDraft: updateDraft)
        }
    }

    func stopKeepingTranscript() {
        suppressNextRecognitionError = true
        switch state {
        case .serverListening:
            stopServerRecordingAndTranscribe()
        case .listening:
            finishOnDeviceRecognition()
        case .transcribing:
            cancelServerTranscription()
            stopAcceptingDraftUpdates()
            stopAudio(cancelTask: true)
            state = .idle
        case .idle, .requestingPermission:
            stopAcceptingDraftUpdates()
            stopAudio(cancelTask: false)
            state = .idle
        }
    }

    func stopBeforeSubmittingDraft() {
        suppressNextRecognitionError = true
        cancelServerTranscription()
        stopAcceptingDraftUpdates()
        discardServerRecording()
        activeRecognitionID = nil
        stopAudio(cancelTask: true)
        state = .idle
    }

    private func start(currentDraft: String, updateDraft: @escaping (String) -> Void) async {
        guard state == .idle else { return }

        logger.info("Voice input start requested")
        recordingProfileName = Self.profileScope(selected: profileName, session: nil)
        errorMessage = nil
        liveTranscript = ""
        inputLevel = 0
        suppressNextRecognitionError = false
        cancelServerTranscription()
        discardServerRecording()
        draftUpdateSession.begin(baseDraft: currentDraft, profile: recordingProfileName,
                                 currentProfile: currentProfile)
        self.updateDraft = updateDraft
        state = .requestingPermission

        let canUseServer = apiClient != nil
        let canUseOnDevice = onDeviceSpeechRecognizerForRecording() != nil
        let providers = ComposerSTTProviderPolicy.orderedProviders(
            preference: providerPreference,
            serverConfigured: canUseServer,
            onDeviceSupported: canUseOnDevice
        )

        guard let provider = providers.first else {
            fail(
                unavailableMessage(
                    serverConfigured: canUseServer,
                    onDeviceSupported: canUseOnDevice
                ),
                logCategory: .speechUnavailable
            )
            return
        }

        await start(provider: provider)
    }

    private func start(provider: ComposerSTTProvider) async {
        switch provider {
        case .server:
            await startServerProvider()
        case .onDevice:
            await startOnDeviceProvider()
        }
    }

    private func startServerProvider() async {
        let isMicrophonePermissionGranted = await requestMicrophonePermission()
        logger.info("Server voice input microphone permission completed granted=\(isMicrophonePermissionGranted, privacy: .public)")
        guard state == .requestingPermission else { return }
        guard isMicrophonePermissionGranted else {
            fail(
                String(localized: "Microphone access is disabled. Enable it in Settings to use voice input."),
                logCategory: .microphonePermission
            )
            return
        }

        guard ComposerVoiceInputStartPolicy.canStart(appIsActive: UIApplication.shared.applicationState == .active) else {
            fail(
                ComposerVoiceInputError.appNotActive.localizedDescription,
                logCategory: .appNotActive
            )
            return
        }

        do {
            try startServerRecording()
            state = .serverListening
        } catch {
            stopAudio(cancelTask: true)
            await fallbackOrFail(
                from: .server,
                message: error.localizedDescription,
                logCategory: Self.logCategory(for: error)
            )
        }
    }

    private func startOnDeviceProvider() async {
        guard let speechRecognizer = onDeviceSpeechRecognizerForRecording() else {
            await fallbackOrFail(
                from: .onDevice,
                message: String(localized: "On-device speech recognition is not available for the current locale."),
                logCategory: .speechUnavailable
            )
            return
        }

        let speechStatus = await requestSpeechAuthorization()
        logger.info("Voice input speech authorization completed status=\(Self.logDescription(for: speechStatus), privacy: .public)")
        guard state == .requestingPermission else { return }
        guard speechStatus == .authorized else {
            await fallbackOrFail(
                from: .onDevice,
                message: Self.speechAuthorizationMessage(for: speechStatus),
                logCategory: .speechAuthorization
            )
            return
        }

        let isMicrophonePermissionGranted = await requestMicrophonePermission()
        logger.info("Voice input microphone permission completed granted=\(isMicrophonePermissionGranted, privacy: .public)")
        guard state == .requestingPermission else { return }
        guard isMicrophonePermissionGranted else {
            fail(
                String(localized: "Microphone access is disabled. Enable it in Settings to use voice input."),
                logCategory: .microphonePermission
            )
            return
        }

        guard ComposerVoiceInputStartPolicy.canStart(appIsActive: UIApplication.shared.applicationState == .active) else {
            fail(
                ComposerVoiceInputError.appNotActive.localizedDescription,
                logCategory: .appNotActive
            )
            return
        }

        do {
            try startRecognition(speechRecognizer: speechRecognizer)
            state = .listening
        } catch {
            stopAudio(cancelTask: true)
            await fallbackOrFail(
                from: .onDevice,
                message: error.localizedDescription,
                logCategory: Self.logCategory(for: error)
            )
        }
    }

    private func fallbackOrFail(
        from failedProvider: ComposerSTTProvider,
        message: String,
        logCategory: VoiceInputFailureLogCategory
    ) async {
        let fallback = ComposerSTTProviderPolicy.fallbackProvider(
            after: failedProvider,
            preference: providerPreference,
            serverConfigured: apiClient != nil,
            onDeviceSupported: onDeviceSpeechRecognizerForRecording() != nil
        )

        guard let fallback else {
            fail(message, logCategory: logCategory)
            return
        }

        logger.info("Voice input falling back after \(String(describing: failedProvider), privacy: .public)")
        state = .requestingPermission
        await start(provider: fallback)
    }

    private func unavailableMessage(serverConfigured: Bool, onDeviceSupported: Bool) -> String {
        if providerPreference == .onDeviceOnly {
            return String(localized: "On-device speech recognition is not available for the current locale.")
        }

        if !serverConfigured && !onDeviceSupported {
            return String(localized: "Speech-to-text is not available right now.")
        }

        if !serverConfigured {
            return String(localized: "Server speech-to-text is not configured.")
        }

        return String(localized: "On-device speech recognition is not available for the current locale.")
    }

    // MARK: - Server STT

    private static let maxServerRecordingDuration: UInt64 = 60

    private static let serverRecordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false
    ]

    private func startServerRecording() throws {
        stopAudio(cancelTask: true)
        logger.info("Server voice input audio startup preparing")

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            ComposerVoiceAudioSessionConfiguration.category,
            mode: ComposerVoiceAudioSessionConfiguration.mode,
            options: ComposerVoiceAudioSessionConfiguration.options
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        activatedAudioSessionForRecording = true

        try ComposerVoiceInputStartPolicy.validateAudioSessionInput(
            isInputAvailable: audioSession.isInputAvailable,
            sampleRate: audioSession.sampleRate,
            inputNumberOfChannels: audioSession.inputNumberOfChannels
        )

        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermex-composer-stt-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let recorder = try AVAudioRecorder(url: recordingURL, settings: Self.serverRecordingSettings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            try? FileManager.default.removeItem(at: recordingURL)
            throw ComposerVoiceInputError.audioRecorderStartFailed
        }

        self.recordingURL = recordingURL
        audioRecorder = recorder
        ComposerAudioCaptureState.shared.setCapturing(true)
        startMeterTimer()
        startServerRecordingTimeout()
        logger.info("Server voice input recording started")
    }

    private func startServerRecordingTimeout() {
        serverRecordingTimeoutTask?.cancel()
        serverRecordingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.maxServerRecordingDuration * 1_000_000_000)
            await MainActor.run {
                guard let self, !Task.isCancelled, self.state == .serverListening else { return }
                self.stopServerRecordingAndTranscribe()
            }
        }
    }

    private func stopServerRecordingAndTranscribe() {
        serverRecordingTimeoutTask?.cancel()
        serverRecordingTimeoutTask = nil

        guard state == .serverListening,
              let recorder = audioRecorder,
              let recordingURL
        else {
            discardServerRecording()
            stopAudio(cancelTask: true)
            state = .idle
            return
        }

        if recorder.isRecording {
            recorder.stop()
        }
        audioRecorder = nil
        ComposerAudioCaptureState.shared.setCapturing(false)
        stopMeterTimer()

        if activatedAudioSessionForRecording {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            activatedAudioSessionForRecording = false
        }

        state = .transcribing
        liveTranscript = ""

        let transcriptionID = UUID()
        activeTranscriptionID = transcriptionID
        transcriptionTask = Task { [weak self] in
            await self?.finishServerRecording(
                recordingURL: recordingURL,
                transcriptionID: transcriptionID
            )
        }
    }

    private func finishServerRecording(recordingURL: URL, transcriptionID: UUID) async {
        guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            return
        }

        guard let apiClient else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            fail(
                String(localized: "Server speech-to-text is not configured."),
                logCategory: .speechUnavailable
            )
            return
        }

        do {
            let audioData = try Data(contentsOf: recordingURL)
            let response = try await apiClient.transcribeAudio(
                data: audioData,
                mimeType: "audio/wav",
                profile: recordingProfileName
            )

            guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                return
            }

            if let transcript = response.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
               !transcript.isEmpty {
                liveTranscript = transcript
                if let composedDraft = draftUpdateSession.composedDraft(for: transcript) {
                    updateDraft?(composedDraft)
                }
                stopAcceptingDraftUpdates()
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                state = .idle
                suppressNextRecognitionError = false
                return
            }

            let serverMessage = response.error ?? String(localized: "Transcription returned no text.")
            await fallbackFromServerFailure(
                recordingURL: recordingURL,
                transcriptionID: transcriptionID,
                message: serverMessage
            )
        } catch {
            guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                return
            }

            await fallbackFromServerFailure(
                recordingURL: recordingURL,
                transcriptionID: transcriptionID,
                message: error.localizedDescription
            )
        }
    }

    private func fallbackFromServerFailure(
        recordingURL: URL,
        transcriptionID: UUID,
        message: String
    ) async {
        guard ComposerSTTProviderPolicy.fallbackProvider(
            after: .server,
            preference: providerPreference,
            serverConfigured: apiClient != nil,
            onDeviceSupported: onDeviceSpeechRecognizerForRecording() != nil
        ) == .onDevice,
              let speechRecognizer = onDeviceSpeechRecognizerForRecording()
        else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            fail(message, logCategory: .speechUnavailable)
            return
        }

        let speechStatus = await requestSpeechAuthorization()
        guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            return
        }
        guard speechStatus == .authorized else {
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            fail(Self.speechAuthorizationMessage(for: speechStatus), logCategory: .speechAuthorization)
            return
        }

        do {
            let transcript = try await recognizeRecordedFile(
                recordingURL,
                speechRecognizer: speechRecognizer
            )
            guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                return
            }

            liveTranscript = transcript
            guard !transcript.isEmpty else {
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                fail(
                    String(localized: "Transcription returned no text."),
                    logCategory: .speechUnavailable
                )
                return
            }
            if let composedDraft = draftUpdateSession.composedDraft(for: transcript) {
                updateDraft?(composedDraft)
            }
            stopAcceptingDraftUpdates()
            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            state = .idle
            suppressNextRecognitionError = false
        } catch {
            guard isActiveTranscription(transcriptionID), !Task.isCancelled else {
                cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
                return
            }

            cleanupRecordingFile(recordingURL, transcriptionID: transcriptionID)
            fail(error.localizedDescription, logCategory: .speechUnavailable)
        }
    }

    private func recognizeRecordedFile(
        _ recordingURL: URL,
        speechRecognizer: SFSpeechRecognizer
    ) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = SFSpeechURLRecognitionRequest(url: recordingURL)
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = false

                let resumeBox = SpeechRecognitionContinuationBox()
                recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, !resumeBox.didResume else { return }

                        if let error {
                            resumeBox.didResume = true
                            self.recognitionTask = nil
                            continuation.resume(throwing: error)
                            return
                        }

                        guard let result, result.isFinal else { return }
                        let transcript = result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        resumeBox.didResume = true
                        self.recognitionTask = nil
                        continuation.resume(returning: transcript)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.recognitionTask?.cancel()
                self.recognitionTask = nil
            }
        }
    }

    private func isActiveTranscription(_ transcriptionID: UUID) -> Bool {
        activeTranscriptionID == transcriptionID
    }

    private func cleanupRecordingFile(_ recordingURL: URL, transcriptionID: UUID) {
        try? FileManager.default.removeItem(at: recordingURL)
        if isActiveTranscription(transcriptionID) {
            self.recordingURL = nil
            activeTranscriptionID = nil
            transcriptionTask = nil
        }
    }

    private func startRecognition(speechRecognizer: SFSpeechRecognizer) throws {
        stopAudio(cancelTask: true)
        logger.info("Voice input audio startup preparing")

        guard ComposerVoiceInputStartPolicy.canStart(appIsActive: UIApplication.shared.applicationState == .active) else {
            throw ComposerVoiceInputError.appNotActive
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            ComposerVoiceAudioSessionConfiguration.category,
            mode: ComposerVoiceAudioSessionConfiguration.mode,
            options: ComposerVoiceAudioSessionConfiguration.options
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        activatedAudioSessionForRecording = true
        logger.info(
            "Voice input audio session active inputAvailable=\(audioSession.isInputAvailable, privacy: .public) sampleRate=\(audioSession.sampleRate, privacy: .public) inputChannels=\(audioSession.inputNumberOfChannels, privacy: .public)"
        )
        try ComposerVoiceInputStartPolicy.validateAudioSessionInput(
            isInputAvailable: audioSession.isInputAvailable,
            sampleRate: audioSession.sampleRate,
            inputNumberOfChannels: audioSession.inputNumberOfChannels
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request

        let audioEngine = audioEngineFactory()
        self.audioEngine = audioEngine
        try ComposerVoiceInputStartPolicy.validateAudioEngine(isRunning: audioEngine.isRunning)

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        try ComposerVoiceInputPreflight.validate(recordingFormat: recordingFormat)
        logger.info(
            "Voice input installing audio tap sampleRate=\(recordingFormat.sampleRate, privacy: .public) channels=\(recordingFormat.channelCount, privacy: .public)"
        )
        let recognitionID = UUID()
        activeRecognitionID = recognitionID
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            let level = ComposerVoiceAudioLevel.normalized(buffer: buffer)
            Task { @MainActor [weak self] in
                guard let self, self.state == .listening,
                      self.activeRecognitionID == recognitionID else { return }
                self.inputLevel = ComposerVoiceAudioLevel.smoothed(previous: self.inputLevel, incoming: level)
            }
        }
        audioTapInstalled = true
        logger.info("Voice input audio tap installed")

        audioEngine.prepare()

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognition(result: result, error: error, recognitionID: recognitionID)
            }
        }

        try audioEngine.start()
        ComposerAudioCaptureState.shared.setCapturing(true)
        logger.info("Voice input audio engine started")
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?, recognitionID: UUID) {
        guard activeRecognitionID == recognitionID,
              state == .listening || state == .transcribing else { return }

        if let result {
            liveTranscript = result.bestTranscription.formattedString
            if let composedDraft = draftUpdateSession.composedDraft(for: liveTranscript) {
                updateDraft?(composedDraft)
            }
        }

        if let error {
            completeOnDeviceRecognition(error: error)
        } else if result?.isFinal == true {
            completeOnDeviceRecognition(error: nil)
        }
    }

    /// Let Speech flush its final words after the user stops talking. Partial
    /// text is already in the draft, so a slow final cannot make it disappear.
    private func finishOnDeviceRecognition() {
        guard state == .listening else { return }
        state = .transcribing
        stopAudio(cancelTask: false, preserveRecognitionTask: true)
        recognitionFinalizationTask?.cancel()
        let recognitionID = activeRecognitionID
        recognitionFinalizationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.activeRecognitionID == recognitionID,
                      self.state == .transcribing else { return }
                self.completeOnDeviceRecognition(error: nil)
            }
        }
    }

    private func completeOnDeviceRecognition(error: Error?) {
        recognitionFinalizationTask?.cancel()
        recognitionFinalizationTask = nil
        let shouldReportError = liveTranscript.isEmpty
        let wasStoppedByUser = suppressNextRecognitionError
        activeRecognitionID = nil
        stopAcceptingDraftUpdates()
        stopAudio(cancelTask: true)
        state = .idle
        suppressNextRecognitionError = false
        if shouldReportError {
            errorMessage = error != nil && !wasStoppedByUser
                ? error?.localizedDescription
                : String(localized: "No speech recognized. Try again.")
        }
    }

    private func stopAcceptingDraftUpdates() {
        draftUpdateSession.stopAcceptingUpdates()
        updateDraft = nil
    }

    private func stopAudio(cancelTask: Bool, preserveRecognitionTask: Bool = false) {
        ComposerAudioCaptureState.shared.setCapturing(false)
        stopMeterTimer()
        if !preserveRecognitionTask {
            recognitionFinalizationTask?.cancel()
            recognitionFinalizationTask = nil
            activeRecognitionID = nil
        }
        serverRecordingTimeoutTask?.cancel()
        serverRecordingTimeoutTask = nil

        if let recorder = audioRecorder, recorder.isRecording {
            recorder.stop()
        }
        audioRecorder = nil

        if let audioEngine {
            if audioEngine.isRunning {
                audioEngine.stop()
                logger.info("Voice input audio engine stopped")
            }

            if audioTapInstalled {
                audioEngine.inputNode.removeTap(onBus: 0)
                audioTapInstalled = false
                logger.info("Voice input audio tap removed")
            }

            audioEngine.reset()
        }
        audioEngine = nil

        recognitionRequest?.endAudio()

        if cancelTask {
            recognitionTask?.cancel()
        }

        if !preserveRecognitionTask {
            recognitionTask = nil
        }
        recognitionRequest = nil

        if activatedAudioSessionForRecording {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            activatedAudioSessionForRecording = false
            logger.info("Voice input audio session deactivated")
        }
    }

    private func discardServerRecording() {
        stopMeterTimer()
        serverRecordingTimeoutTask?.cancel()
        serverRecordingTimeoutTask = nil

        if let recorder = audioRecorder, recorder.isRecording {
            recorder.stop()
        }
        audioRecorder = nil

        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
        }
    }

    private func cancelServerTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        activeTranscriptionID = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            self.recordingURL = nil
        }
    }

    private func onDeviceSpeechRecognizerForRecording() -> SFSpeechRecognizer? {
        if let speechRecognizer {
            return speechRecognizer.supportsOnDeviceRecognition ? speechRecognizer : nil
        }

        guard Self.isLocaleSupportedBySpeechRecognizer(locale) else {
            return nil
        }
        let speechRecognizer = speechRecognizerFactory()
        guard speechRecognizer?.supportsOnDeviceRecognition == true else {
            return nil
        }
        self.speechRecognizer = speechRecognizer
        return speechRecognizer
    }

    private static func isLocaleSupportedBySpeechRecognizer(_ locale: Locale) -> Bool {
        let target = normalizedLocaleIdentifier(locale.identifier)
        return SFSpeechRecognizer.supportedLocales().contains { supportedLocale in
            normalizedLocaleIdentifier(supportedLocale.identifier) == target
        }
    }

    private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private func fail(_ message: String, logCategory: VoiceInputFailureLogCategory) {
        logger.error("Voice input failed category=\(logCategory.rawValue, privacy: .public)")
        suppressNextRecognitionError = false
        stopAcceptingDraftUpdates()
        cancelServerTranscription()
        discardServerRecording()
        activeRecognitionID = nil
        stopAudio(cancelTask: true)
        state = .idle
        errorMessage = message
    }

    private func startMeterTimer() {
        stopMeterTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .serverListening, let recorder = self.audioRecorder else { return }
                recorder.updateMeters()
                let level = ComposerVoiceAudioLevel.normalized(decibels: Double(recorder.averagePower(forChannel: 0)))
                self.inputLevel = ComposerVoiceAudioLevel.smoothed(previous: self.inputLevel, incoming: level)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
        inputLevel = 0
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await ComposerVoiceMicrophonePermissionRequester.request()
    }

    private static func speechAuthorizationMessage(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return String(localized: "Speech recognition is disabled. Enable it in Settings to use voice input.")
        case .restricted:
            return String(localized: "Speech recognition is restricted on this device.")
        case .notDetermined:
            return String(localized: "Speech recognition permission was not granted.")
        case .authorized:
            return ""
        @unknown default:
            return String(localized: "Speech recognition is not available right now.")
        }
    }

    private static func logDescription(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "notDetermined"
        case .authorized:
            return "authorized"
        @unknown default:
            return "unknown"
        }
    }

    private static func logCategory(for error: Error) -> VoiceInputFailureLogCategory {
        guard let voiceError = error as? ComposerVoiceInputError else {
            return .audioStartup
        }

        switch voiceError {
        case .noAudioInput:
            return .noAudioInput
        case .invalidInputFormat:
            return .invalidInputFormat
        case .appNotActive:
            return .appNotActive
        case .audioEngineAlreadyRunning, .audioRecorderStartFailed:
            return .audioEngineAlreadyRunning
        }
    }
}

private final class SpeechRecognitionContinuationBox {
    var didResume = false
}

enum ComposerVoiceMicrophonePermissionRequester {
    static func request() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { isGranted in
                continuation.resume(returning: isGranted)
            }
        }
    }
}

enum ComposerVoiceAudioSessionConfiguration {
    static let category = AVAudioSession.Category.playAndRecord
    static let mode = AVAudioSession.Mode.measurement
    static let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothHFP]
}

enum ComposerVoiceInputError: LocalizedError {
    case noAudioInput
    case invalidInputFormat
    case appNotActive
    case audioEngineAlreadyRunning
    case audioRecorderStartFailed

    var errorDescription: String? {
        switch self {
        case .noAudioInput:
            return String(localized: "No microphone input is available. Check the Simulator or device microphone settings.")
        case .invalidInputFormat:
            return String(localized: "Voice input is not available because the microphone input format is invalid.")
        case .appNotActive:
            return String(localized: "Voice input can start only while Semreh is active.")
        case .audioEngineAlreadyRunning:
            return String(localized: "Voice input is already preparing the microphone. Try again in a moment.")
        case .audioRecorderStartFailed:
            return String(localized: "Voice input could not start recording. Try again in a moment.")
        }
    }
}

enum VoiceInputFailureLogCategory: String {
    case speechUnavailable
    case speechAuthorization
    case microphonePermission
    case appNotActive
    case noAudioInput
    case invalidInputFormat
    case audioEngineAlreadyRunning
    case audioStartup
}

enum ComposerVoiceInputStartPolicy {
    static func canStart(appIsActive: Bool) -> Bool {
        appIsActive
    }

    static func validateAudioSessionInput(
        isInputAvailable: Bool,
        sampleRate: Double,
        inputNumberOfChannels: Int
    ) throws {
        guard isInputAvailable else {
            throw ComposerVoiceInputError.noAudioInput
        }

        try ComposerVoiceInputPreflight.validate(
            sampleRate: sampleRate,
            channelCount: UInt32(max(inputNumberOfChannels, 0))
        )
    }

    static func validateAudioEngine(isRunning: Bool) throws {
        guard !isRunning else {
            throw ComposerVoiceInputError.audioEngineAlreadyRunning
        }
    }
}

enum ComposerVoiceInputPreflight {
    static let validSampleRateRange: ClosedRange<Double> = 8_000...192_000
    static let validChannelCountRange: ClosedRange<UInt32> = 1...16

    static func validate(sampleRate: Double, channelCount: UInt32) throws {
        guard sampleRate.isFinite,
              validSampleRateRange.contains(sampleRate),
              validChannelCountRange.contains(channelCount)
        else {
            throw ComposerVoiceInputError.invalidInputFormat
        }
    }

    static func validate(recordingFormat: AVAudioFormat) throws {
        try validate(
            sampleRate: recordingFormat.sampleRate,
            channelCount: recordingFormat.channelCount
        )
    }
}

/// A bounded, privacy-preserving display level. Only the scalar level reaches
/// SwiftUI; no microphone samples are retained by the meter.
enum ComposerVoiceAudioLevel {
    static func normalized(decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels + 50) / 42))
    }

    static func normalized(buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0 else { return 0 }

        var sum = 0.0
        var samples = 0
        for channel in 0..<channelCount {
            let data = channels[channel]
            for frame in stride(from: 0, to: frameCount, by: 8) {
                let sample = Double(data[frame])
                sum += sample * sample
                samples += 1
            }
        }
        guard samples > 0 else { return 0 }
        let rms = sqrt(sum / Double(samples))
        return normalized(decibels: 20 * log10(max(rms, 0.000_001)))
    }

    static func smoothed(previous: Double, incoming: Double) -> Double {
        let boundedIncoming = min(1, max(0, incoming.isFinite ? incoming : 0))
        let boundedPrevious = min(1, max(0, previous.isFinite ? previous : 0))
        let weight = boundedIncoming > boundedPrevious ? 0.55 : 0.16
        return boundedPrevious + (boundedIncoming - boundedPrevious) * weight
    }
}

enum ComposerVoiceDraftComposer {
    static func composedDraft(baseDraft: String, transcript: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return baseDraft
        }

        let trimmedTrailingDraft = baseDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrailingDraft.isEmpty else {
            return trimmedTranscript
        }

        return "\(trimmedTrailingDraft) \(trimmedTranscript)"
    }
}

struct ComposerVoiceDraftUpdateSession {
    private var baseDraft = ""
    private var acceptsUpdates = false
    private var profile: String?
    private var currentProfile: (() -> String)?

    mutating func begin(baseDraft: String, profile: String? = nil,
                        currentProfile: (() -> String)? = nil) {
        self.baseDraft = baseDraft
        self.profile = profile
        self.currentProfile = currentProfile
        acceptsUpdates = true
    }

    mutating func stopAcceptingUpdates() {
        acceptsUpdates = false
    }

    func composedDraft(for transcript: String) -> String? {
        guard acceptsUpdates else {
            return nil
        }
        // Read the live model scope at the synchronous commit boundary, not a
        // SwiftUI snapshot whose onChange cancellation may still be queued.
        if let profile, let currentProfile, currentProfile() != profile {
            return nil
        }

        return ComposerVoiceDraftComposer.composedDraft(
            baseDraft: baseDraft,
            transcript: transcript
        )
    }
}

private extension Logger {
    static let hermesVoiceInput = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "VoiceInput"
    )
}
