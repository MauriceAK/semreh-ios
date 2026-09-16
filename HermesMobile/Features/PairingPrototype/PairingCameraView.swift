import AVFoundation
import SwiftUI
import UIKit

private protocol PairingScanEventSource: AnyObject {
    var previewSession: AVCaptureSession? { get }
    var result: (@Sendable (String, UUID) -> Void)? { get set }
    var unavailable: (@Sendable (UUID) -> Void)? { get set }
    func setActive(_ active: Bool, generation: UUID)
}

/// Capture operations and delegate callbacks are confined to one serial queue.
private final class PairingCapture: NSObject, AVCaptureMetadataOutputObjectsDelegate, PairingScanEventSource, @unchecked Sendable {
    let session = AVCaptureSession()
    var previewSession: AVCaptureSession? { session }
    private let queue = DispatchQueue(label: "semreh.prototype.qr.capture")
    private var generation: UUID?
    private var configured = false
    var result: (@Sendable (String, UUID) -> Void)?
    var unavailable: (@Sendable (UUID) -> Void)?

    func setActive(_ active: Bool, generation: UUID) {
        queue.async { [self] in
            self.generation = active ? generation : nil
            guard active else {
                if session.isRunning { session.stopRunning() }
                return
            }
            if !configured {
                guard let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera) else {
                    unavailable?(generation); return
                }
                let output = AVCaptureMetadataOutput()
                session.beginConfiguration()
                guard session.canAddInput(input) else {
                    session.commitConfiguration(); unavailable?(generation); return
                }
                session.addInput(input)
                guard session.canAddOutput(output) else {
                    session.removeInput(input)
                    session.commitConfiguration(); unavailable?(generation); return
                }
                session.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    session.removeOutput(output); session.removeInput(input)
                    session.commitConfiguration(); unavailable?(generation); return
                }
                output.setMetadataObjectsDelegate(self, queue: queue)
                output.metadataObjectTypes = [.qr]
                session.commitConfiguration()
                configured = true
            }
            if !session.isRunning { session.startRunning() }
            if !session.isRunning { unavailable?(generation) }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let generation,
              let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first(where: { $0.type == .qr })?.stringValue else { return }
        result?(code, generation)
    }
}

#if DEBUG
/// Delivers deterministic strings only when the UI test explicitly asks for one.
/// It never opens the camera and sends each string through the same result path
/// as AVCaptureMetadataOutput.
private final class PairingTestScanEventSource: PairingScanEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: UUID?
    var result: (@Sendable (String, UUID) -> Void)?
    var unavailable: (@Sendable (UUID) -> Void)?
    var previewSession: AVCaptureSession? { nil }

    func setActive(_ active: Bool, generation: UUID) {
        lock.lock()
        activeGeneration = active ? generation : nil
        lock.unlock()
    }

    func emit(_ text: String) {
        lock.lock()
        let generation = activeGeneration
        lock.unlock()
        guard let generation else { return }
        result?(text, generation)
    }
}
#endif

@MainActor
private final class PairingCameraModel: ObservableObject {
    enum Status { case explanation, scanning, denied, unavailable }
    @Published var status: Status = .explanation
    @Published var invalidCode = false
    private let cameraSource = PairingCapture()
    private var policy = PairingScanPolicy()
    private var visible = false
    private var sceneActive = false
    private var requested = false
    var accepted: ((PairingImport) -> Void)?

#if DEBUG
    private let testEventSourceRequested: Bool
    private var testEventSource: PairingTestScanEventSource?
#endif

    private var activeEventSource: PairingScanEventSource {
#if DEBUG
        if let testEventSource { return testEventSource }
#endif
        return cameraSource
    }

    var previewSession: AVCaptureSession? { activeEventSource.previewSession }

    var showsInjectedScanControls: Bool {
#if DEBUG
        return testEventSource != nil
#else
        return false
#endif
    }

    init() {
#if DEBUG
        let process = ProcessInfo.processInfo
        testEventSourceRequested = process.arguments.contains("--semreh-pairing-test-event-source")
            && process.environment["SEMREH_PAIRING_TEST_SOURCE"] == "injected"
#endif
        cameraSource.result = scanResultHandler()
        cameraSource.unavailable = { [weak self] generation in
            Task { @MainActor [weak self] in
                guard let self, self.policy.active, self.policy.generation == generation else { return }
                self.status = .unavailable
                self.policy.setActive(false)
                self.activeEventSource.setActive(false, generation: self.policy.generation)
            }
        }
    }

    private func scanResultHandler() -> @Sendable (String, UUID) -> Void {
        { [weak self] text, generation in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard let value = try self.policy.admit(text, generation: generation) else { return }
                    self.activeEventSource.setActive(false, generation: self.policy.generation)
                    self.accepted?(value)
                } catch {
                    self.invalidCode = true
                }
            }
        }
    }

    func lifecycle(visible: Bool, active: Bool) {
        self.visible = visible
        sceneActive = active
        reconcile()
    }

    func enableCamera() {
#if DEBUG
        if testEventSourceRequested {
            let source = PairingTestScanEventSource()
            source.result = cameraSource.result
            testEventSource = source
            requested = true
            reconcile()
            return
        }
#endif
        // A missing integration key must fall back rather than crash on requestAccess.
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .unavailable; return
        }
        requested = true
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconcile() }
            }
        } else { reconcile() }
    }

    private func reconcile() {
#if DEBUG
        if testEventSourceRequested {
            let shouldScan = visible && sceneActive && requested && !policy.consumed
            policy.setActive(shouldScan)
            testEventSource?.setActive(policy.active, generation: policy.generation)
            if requested { status = .scanning }
            return
        }
#endif
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed = requested && authorization == .authorized
        policy.setActive(visible && sceneActive && allowed && !policy.consumed)
        cameraSource.setActive(policy.active, generation: policy.generation)
        if requested {
            switch authorization {
            case .authorized: status = .scanning
            case .denied, .restricted: status = .denied
            case .notDetermined: break
            @unknown default: status = .unavailable
            }
        }
    }

#if DEBUG
    func emitTestScan(_ text: String) {
        guard testEventSourceRequested, policy.active else { return }
        testEventSource?.emit(text)
    }
#endif
}

private final class PairingPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct PairingCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PairingPreviewUIView {
        let view = PairingPreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PairingPreviewUIView, context: Context) {}
    static func dismantleUIView(_ uiView: PairingPreviewUIView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }
}

struct PairingCameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PairingCameraModel()
    let accepted: (PairingImport) -> Void
    let manual: () -> Void
    let cancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Scan your server address", systemImage: "camera").font(.title2)
                Text("Scan a QR containing your server’s HTTPS address. Review the full address before continuing; scanning does not connect or sign in.")
                switch model.status {
                case .explanation:
                    Button("Allow camera scanning") { model.enableCamera() }
                case .scanning:
                    Group {
                        if let session = model.previewSession {
                            PairingCameraPreview(session: session)
                                .frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 16))
                                .accessibilityLabel("Camera viewfinder. Aim at a QR containing your server’s HTTPS address.")
                        }
#if DEBUG
                        if model.showsInjectedScanControls {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Test-only injected QR events; no camera is used.")
                                    .font(.footnote)
                                    .accessibilityIdentifier("pairing-test-event-source-active")
                                Button("Inject invalid QR event") {
                                    model.emitTestScan("not a supported HTTPS server address")
                                }
                                .accessibilityIdentifier("pairing-test-invalid-qr")
                                Button("Inject valid HTTPS address QR") {
                                    model.emitTestScan("https://scan.example.test")
                                }
                                .accessibilityIdentifier("pairing-test-valid-qr")
                            }
                        }
#endif
                    }
                case .denied:
                    Text("Camera access is denied or restricted. You can enter the address manually, or enable camera access in Settings if permitted.")
                case .unavailable:
                    Text("Camera scanning is unavailable. Enter your server address below instead.")
                }
                if model.invalidCode {
                    Text("This QR does not contain a supported HTTPS server address. Try another QR or enter the address manually.")
                        .font(.footnote)
                        .accessibilityIdentifier("pairing-invalid-code")
                }
                Button("Enter an address instead") { stop(); manual() }
                Button("Cancel", role: .cancel) { stop(); cancel() }
            }.padding(28)
        }
        .onAppear {
            model.accepted = accepted
            model.lifecycle(visible: true, active: scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in model.lifecycle(visible: true, active: phase == .active) }
        .onDisappear { stop(); model.accepted = nil }
    }

    private func stop() { model.lifecycle(visible: false, active: false) }
}
