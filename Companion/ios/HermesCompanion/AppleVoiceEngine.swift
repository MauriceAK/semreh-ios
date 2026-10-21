import AVFoundation
import Speech

@available(iOS 26.0, *)
@MainActor
final class AppleVoiceEngine: VoiceEngine {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioEngine: AVAudioEngine?
    private var sink: VoiceAudioSink?
    private var results: Task<String, Error>?
    private var progressTask: Task<Void, Never>?
    private var installation: AssetInstallationRequest?
    private var events: (@MainActor @Sendable (VoiceEngineEvent) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var cancelled = false
    private var audioSessionActive = false

    func prepare(allowDownload: Bool, events: @escaping @MainActor @Sendable (VoiceEngineEvent) -> Void) async throws {
        self.events = events
        try await prepareModule(allowDownload: allowDownload)
        guard await AVAudioApplication.requestRecordPermission() else { throw VoiceFailure.microphoneDenied }
        try ensureActive()
    }

    private func prepareModule(allowDownload: Bool) async throws {
        guard SpeechTranscriber.isAvailable else { throw VoiceFailure.unsupported }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { throw VoiceFailure.unsupportedLanguage }
        try ensureActive()
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [module])
        try ensureActive()
        guard status != .unsupported else { throw VoiceFailure.unsupportedLanguage }
        let language = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        if status != .installed && !allowDownload { throw VoiceFailure.downloadRequired(language) }
        do {
            let alreadyReserved = await AssetInventory.reservedLocales.contains(locale)
            try ensureActive()
            if !alreadyReserved {
                try await AssetInventory.reserve(locale: locale)
                try ensureActive()
            }
            if status != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try ensureActive()
                installation = request
                events?(.downloading(request.progress.fractionCompleted))
                progressTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled, let self, !self.cancelled else { return }
                        self.events?(.downloading(request.progress.fractionCompleted))
                    }
                }
                try await request.downloadAndInstall()
                progressTask?.cancel()
                progressTask = nil
                installation = nil
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as SFSpeechError where error.code == .tooManyAssetLocalesAllocated { throw VoiceFailure.assetCapacity }
        catch { throw VoiceFailure.assetsUnavailable }
        try ensureActive()
        transcriber = module
        analyzer = SpeechAnalyzer(modules: [module])
    }

    func start() async throws {
        try ensureActive()
        guard let analyzer, let transcriber else { throw VoiceFailure.recognitionFailed }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            audioSessionActive = true
            let engine = AVAudioEngine()
            audioEngine = engine
            let input = engine.inputNode
            let nativeFormat = input.outputFormat(forBus: 0)
            guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0,
                  let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: nativeFormat) else {
                throw VoiceFailure.audioUnavailable
            }
            try ensureActive()
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(32))
            let sink = try VoiceAudioSink(input: nativeFormat, output: format, continuation: continuation) { [weak self] event in
                Task { @MainActor [weak self] in self?.events?(event) }
            }
            self.sink = sink
            collectResults(from: transcriber)
            try await analyzer.start(inputSequence: stream)
            try ensureActive()
            input.installTap(onBus: 0, bufferSize: 2048, format: nativeFormat) { buffer, _ in sink.receive(buffer) }
            engine.prepare()
            try engine.start()
            observeInterruptions()
        } catch is CancellationError { throw CancellationError() }
        catch { throw VoiceFailure.audioUnavailable }
    }

    func finish() async throws -> String {
        try ensureActive()
        stopCapture()
        guard let analyzer, let results else { throw VoiceFailure.recognitionFailed }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try ensureActive()
        return try await results.value
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        stopCapture()
        progressTask?.cancel()
        progressTask = nil
        installation?.progress.cancel()
        installation = nil
        results?.cancel()
        results = nil
        let previousAnalyzer = analyzer
        analyzer = nil
        transcriber = nil
        events = nil
        Task {
            await previousAnalyzer?.cancelAndFinishNow()
        }
    }

    private func collectResults(from transcriber: SpeechTranscriber) {
        results = Task { [weak self] in
            do {
                var segments: [VoiceTranscriptSegment] = []
                for try await result in transcriber.results {
                    guard result.isFinal else { continue }
                    let segment = VoiceTranscriptSegment(start: result.range.start.seconds,
                                                         duration: result.range.duration.seconds,
                                                         text: String(result.text.characters))
                    VoiceTranscriptSegment.merge(segment, into: &segments)
                }
                return segments.sorted { $0.start < $1.start }.map(\.text).joined()
            } catch {
                if !Task.isCancelled { self?.events?(.failed) }
                throw error
            }
        }
    }

    #if DEBUG
    func transcribeFileForVerification(_ url: URL) async throws -> String {
        try await prepareModule(allowDownload: false)
        guard let analyzer, let transcriber else { throw VoiceFailure.recognitionFailed }
        collectResults(from: transcriber)
        let file = try AVAudioFile(forReading: url)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        guard let results else { throw VoiceFailure.recognitionFailed }
        return try await results.value
    }
    #endif

    private func ensureActive() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func stopCapture() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
        }
        sink?.finish()
        sink = nil
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in self?.events?(.interrupted) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  [.oldDeviceUnavailable, .newDeviceAvailable, .noSuitableRouteForCategory, .routeConfigurationChange].contains(reason) else { return }
            Task { @MainActor [weak self] in self?.events?(.interrupted) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.events?(.interrupted) }
        })
    }

    isolated deinit { cancel() }
}

struct VoiceTranscriptSegment: Equatable {
    let start: Double
    let duration: Double
    let text: String

    static func merge(_ segment: Self, into segments: inout [Self]) {
        if let index = segments.firstIndex(where: { $0.start == segment.start && $0.duration == segment.duration }) {
            segments[index] = segment
        } else { segments.append(segment) }
    }
}

@available(iOS 26.0, *)
private final class VoiceAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private let event: @Sendable (VoiceEngineEvent) -> Void
    private var lastMeterTime = ContinuousClock.now

    init(input: AVAudioFormat, output: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         event: @escaping @Sendable (VoiceEngineEvent) -> Void) throws {
        guard let converter = AVAudioConverter(from: input, to: output) else { throw VoiceFailure.audioUnavailable }
        self.converter = converter
        self.output = output
        self.continuation = continuation
        self.event = event
    }

    func receive(_ input: AVAudioPCMBuffer) {
        lock.withLock {
            guard let continuation else { return }
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * output.sampleRate / input.format.sampleRate)) + 32
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { fail(); return }
            let source = VoiceConverterInput(input)
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                guard let next = source.take() else { inputStatus.pointee = .noDataNow; return nil }
                inputStatus.pointee = .haveData
                return next
            }
            guard status != .error, error == nil else { fail(); return }
            if buffer.frameLength > 0 {
                if case .dropped = continuation.yield(AnalyzerInput(buffer: buffer)) { fail(); return }
            }
            let now = ContinuousClock.now
            if lastMeterTime.duration(to: now) >= .milliseconds(80), let samples = input.floatChannelData?[0], input.frameLength > 0 {
                lastMeterTime = now
                var sum: Float = 0
                for index in 0..<Int(input.frameLength) { sum += samples[index] * samples[index] }
                let rms = sqrt(sum / Float(input.frameLength))
                let decibels = 20 * log10(max(rms, 0.00001))
                event(.level(min(max((decibels + 55) / 55, 0), 1)))
            }
        }
    }

    func finish() {
        lock.withLock { continuation?.finish(); continuation = nil }
    }

    private func fail() {
        continuation?.finish()
        continuation = nil
        event(.failed)
    }
}

private final class VoiceConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            let next = buffer
            buffer = nil
            return next
        }
    }
}
