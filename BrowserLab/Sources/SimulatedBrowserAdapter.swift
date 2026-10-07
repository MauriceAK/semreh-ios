import Foundation
import Combine
import SemrehRemoteBrowserCore
#if canImport(UIKit)
import UIKit
#endif

/// Scripted fixture adapter for BrowserLab.
///
/// Produces synthetic changing frames, scripted control grants/rejections,
/// delayed or lost acknowledgements, and surface rotations — so every
/// required workspace state is reachable without a real browser. This is a
/// development fixture only: it is never referenced from production code
/// paths, and the lab UI always carries the simulated-session banner.
final class SimulatedBrowserAdapter: BrowserAdapter, ObservableObject {
    var capabilities: RemoteBrowserCapabilities {
        RemoteBrowserCapabilities(
            controlSupported: controlSupported,
            stopTaskSupported: true
        )
    }
    var onEvent: ((BrowserAdapterEvent) -> Void)?

    // MARK: - Script knobs (control panel)

    /// Grant control requests automatically after a short delay.
    @Published var autoGrantControl = true
    /// Reject the next control request instead of granting it.
    @Published var rejectNextRequest = false
    /// Artificial acknowledgement delay for human commands.
    @Published var ackDelay: TimeInterval = 0.2
    /// Lose (never acknowledge) the next human command.
    @Published var loseNextAck = false
    /// Emit synthetic frames on a timer.
    @Published var framesRunning = false
    /// Allows the required watching/read-only state to be exercised.
    @Published private(set) var controlSupported = true

    // MARK: - Counters and readback

    @Published private(set) var acceptedCommandCount = 0
    @Published private(set) var lastCommandDescription = "—"
    @Published private(set) var insertedTextCount = 0
    @Published private(set) var lastInsertedText = "—"
    @Published private(set) var eventLog: [String] = []

    private var connection = ConnectionEpoch(generation: 1)
    private var surface = SurfaceIdentity(generation: 1)
    private var controlRevision: UInt64 = 1
    private var frameSequence: UInt64 = 0
    private var frameTimer: Timer?
    private var isConnected = false
    private var connectionAttempt = UUID()
    private let sourceSize = PixelDimensions(width: 390, height: 844)

    var descriptor: RemoteSurfaceDescriptor {
        RemoteSurfaceDescriptor(
            connection: connection,
            surface: surface,
            sourceDimensions: sourceSize,
            hostDisplayName: "simulated-hermes.local"
        )
    }

    // MARK: - BrowserAdapter

    func connect() {
        connection = ConnectionEpoch(generation: connection.generation + 1)
        let attempt = UUID()
        connectionAttempt = attempt
        isConnected = false
        frameSequence = 0
        log("connection requested")
        // Delay the observation so the Connecting state is visibly reachable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.connectionAttempt == attempt else { return }
            self.isConnected = true
            self.log("connected (connection epoch \(self.connection.generation))")
            self.onEvent?(.connected(self.descriptor, self.capabilities))
        }
    }

    func disconnect() {
        connectionAttempt = UUID()
        isConnected = false
        stopFrames()
        log("disconnected")
        onEvent?(.disconnected)
    }

    func perform(_ action: BrowserAdapterAction, commandID: CommandID) {
        switch action {
        case .requestControl(let requestID):
            handleControlRequest(requestID: requestID)
        case .resumeHermes:
            record(action)
            settle(action, commandID: commandID)
        case .click, .scroll, .insertText, .specialKey, .stopTask:
            record(action)
            settle(action, commandID: commandID)
        }
    }

    // MARK: - Fixture controls

    func startFrames() {
        guard frameTimer == nil else { return }
        framesRunning = true
        log("frames started")
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            self?.emitFrame()
        }
    }

    func stopFrames() {
        frameTimer?.invalidate()
        frameTimer = nil
        if framesRunning {
            framesRunning = false
            log("frames stopped")
        }
    }

    func rotateSurface() {
        surface = SurfaceIdentity(generation: surface.generation + 1)
        frameSequence = 0
        log("surface rotated (generation \(surface.generation))")
        onEvent?(.surfaceChanged(surface))
    }

    func endSession() {
        connectionAttempt = UUID()
        isConnected = false
        stopFrames()
        log("session ended")
        onEvent?(.sessionEnded)
    }

    func setControlSupported(_ supported: Bool) {
        guard controlSupported != supported else { return }
        controlSupported = supported
        log(supported ? "control capability enabled" : "control capability disabled")
        guard isConnected else { return }
        // Capability changes are authoritative observations in a new fixture
        // connection epoch, so they can never preserve an old manual lease.
        connection = ConnectionEpoch(generation: connection.generation + 1)
        frameSequence = 0
        onEvent?(.connected(descriptor, capabilities))
    }

    func reportFreshObservation() {
        guard isConnected else { return }
        log("fresh quiescent observation")
        onEvent?(.quiescent)
    }

    // MARK: - Private

    private func handleControlRequest(requestID: UUID) {
        // Control grants require an observation made after this request.
        onEvent?(.quiescent)
        if rejectNextRequest {
            rejectNextRequest = false
            log("control request rejected (fixture)")
            onEvent?(.controlRequestRejected(
                requestID: requestID,
                reason: "Simulated rejection from the BrowserLab fixture."
            ))
            return
        }
        guard autoGrantControl else {
            log("control request held (auto-grant off)")
            return
        }
        let requestedConnection = connection
        let requestedSurface = surface
        // Small delay so the requestPending state is observable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self,
                  self.isConnected,
                  self.connection == requestedConnection,
                  self.surface == requestedSurface
            else { return }
            self.log("control granted (revision \(self.controlRevision))")
            self.onEvent?(.controlGranted(ControlGrant(
                requestID: requestID,
                connection: self.connection,
                surface: self.surface,
                revision: self.controlRevision
            )))
        }
    }

    private func record(_ action: BrowserAdapterAction) {
        acceptedCommandCount += 1
        if case .insertText(let text) = action {
            insertedTextCount += 1
            lastInsertedText = text
        }
        lastCommandDescription = describe(action)
        log("accepted: \(lastCommandDescription)")
    }

    private func settle(_ action: BrowserAdapterAction, commandID: CommandID) {
        if loseNextAck {
            loseNextAck = false
            log("ack lost: \(describe(action))")
            onEvent?(.acknowledgementLost(commandID))
        } else {
            acknowledge(commandID)
        }
    }

    private func acknowledge(_ commandID: CommandID) {
        let delay = ackDelay
        let commandConnection = connection
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.isConnected,
                  self.connection == commandConnection
            else { return }
            self.onEvent?(.commandAcknowledged(commandID))
            // This is a separate authoritative observation after the command
            // acknowledgement. Resume cannot complete on the ack alone.
            self.onEvent?(.quiescent)
        }
    }

    private func describe(_ action: BrowserAdapterAction) -> String {
        switch action {
        case .requestControl(let id): return "requestControl \(id.uuidString.prefix(8))"
        case .resumeHermes: return "resumeHermes"
        case .insertText(let text): return "insertText (\(text.count) characters)"
        case .click(let point):
            return String(format: "click (%.2f, %.2f)", point.x, point.y)
        case .scroll(let dx, let dy):
            return String(format: "scroll (%.3f, %.3f)", dx, dy)
        case .specialKey(let key): return "specialKey \(key.rawValue)"
        case .stopTask: return "stopTask"
        }
    }

    private func log(_ message: String) {
        let stamp = DateFormatter.labTime.string(from: Date())
        eventLog.append("[\(stamp)] \(message)")
        if eventLog.count > 60 {
            eventLog.removeFirst(eventLog.count - 60)
        }
    }

    private func emitFrame() {
        frameSequence += 1
        #if canImport(UIKit)
        guard let data = renderFrame(sequence: frameSequence) else { return }
        let payload = FramePayload(
            sequence: frameSequence,
            generation: surface.generation,
            dimensions: sourceSize,
            compressedByteCount: data.count,
            data: data
        )
        onEvent?(.frameArrived(payload))
        #else
        // No renderer off iOS; frame delivery is exercised on device.
        _ = frameSequence
        #endif
    }

    #if canImport(UIKit)
    /// A synthetic "browser page" that visibly changes every frame so the
    /// pipeline, viewport and stale-frame shielding can be exercised.
    private func renderFrame(sequence: UInt64) -> Data? {
        let size = CGSize(width: sourceSize.width, height: sourceSize.height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            // Page background.
            cg.setFillColor(UIColor.systemBackground.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            // Header bar.
            cg.setFillColor(UIColor.systemBlue.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 64))
            // Moving box: position is a function of the sequence number.
            let t = Double(sequence)
            let boxX = 20 + 140 * (0.5 + 0.5 * sin(t * 0.6))
            let boxY = 120 + 200 * (0.5 + 0.5 * cos(t * 0.4))
            cg.setFillColor(UIColor.systemOrange.cgColor)
            cg.fill(CGRect(x: boxX, y: boxY, width: 90, height: 90))
            // Fake text lines.
            cg.setFillColor(UIColor.secondaryLabel.cgColor)
            for i in 0..<8 {
                let y = 480 + Double(i) * 28
                let w = size.width - 40 - Double((Int(sequence) + i * 37) % 120)
                cg.fill(CGRect(x: 20, y: y, width: max(w, 60), height: 12))
            }
            // Sequence + timestamp readback.
            let stamp = "frame \(sequence) · \(DateFormatter.labTime.string(from: Date()))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.label,
            ]
            stamp.draw(at: CGPoint(x: 20, y: 88), withAttributes: attrs)
        }
        return image.pngData()
    }
    #endif
}

private extension DateFormatter {
    static let labTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
