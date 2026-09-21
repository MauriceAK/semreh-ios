import SwiftUI
import SemrehRemoteBrowserCore
import SemrehRemoteBrowserUI

/// Owns the fixture and the workspace view model for one lab session.
@MainActor
final class BrowserLabState: ObservableObject {
    @Published private(set) var fixture: SimulatedBrowserAdapter!
    @Published private(set) var viewModel: RemoteBrowserViewModel!

    init() {
        let fixture = SimulatedBrowserAdapter()
        self.fixture = fixture
        self.viewModel = RemoteBrowserViewModel(
            adapter: fixture,
            decoder: UIKitFrameDecoder()
        )
    }

    /// Ended sessions are terminal; a new session rebuilds the fixture and
    /// view model the way a freshly presented workspace would.
    func startNewSession() {
        let fixture = SimulatedBrowserAdapter()
        self.fixture = fixture
        self.viewModel = RemoteBrowserViewModel(
            adapter: fixture,
            decoder: UIKitFrameDecoder()
        )
    }
}

/// BrowserLab: development fixture for the remote browser workspace.
///
/// The persistent banner marks every session as simulated — nothing here is
/// a live Hermes connection. The control panel drives the fixture through
/// every required workspace state; the workspace itself is the same exported
/// `RemoteBrowserWorkspaceView` production code uses.
struct BrowserLabView: View {
    @StateObject private var lab = BrowserLabState()
    @State private var panelVisible = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            banner
            RemoteBrowserWorkspaceView(viewModel: lab.viewModel)
            if panelVisible {
                Divider()
                controlPanel
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(panelVisible ? "Hide Panel" : "Show Panel") {
                    panelVisible.toggle()
                }
                .accessibilityIdentifier("lab.panelToggle")
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                // Real hosts suspend input on backgrounding; the lab mirrors it.
                lab.viewModel.handleBackground()
            }
        }
    }

    // MARK: - Banner

    private var banner: some View {
        Text("SIMULATED SESSION — NOT CONNECTED TO HERMES")
            .font(.caption)
            .bold()
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.orange)
            .accessibilityIdentifier("lab.banner")
    }

    // MARK: - Control panel

    private var controlPanel: some View {
        FixtureObservedContent(fixture: lab.fixture) {
            VStack(spacing: 0) {
                scenarioShortcuts
                    .padding(12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        connectionSection
                        Divider()
                        framesSection
                        Divider()
                        controlSection
                        Divider()
                        acknowledgementSection
                        Divider()
                        readbackSection
                    }
                    .padding(12)
                }
                .accessibilityIdentifier("lab.panel")
                Divider()
                insertionReadback
                    .padding(12)
            }
            .frame(height: 300)
            .background(Color(.secondarySystemBackground))
        }
    }

    /// Keep the controls needed to enter safety-critical fixture states fixed
    /// above the independently scrolling detail panel. This makes lost-ack,
    /// read-only, and fresh-observation scenarios reachable on compact screens.
    private var scenarioShortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(lab.fixture.controlSupported
                   ? "Disable control support"
                   : "Enable control support") {
                lab.fixture.setControlSupported(!lab.fixture.controlSupported)
            }
            .accessibilityIdentifier("lab.controlSupported")

            HStack(spacing: 8) {
                Button("Lose next ack") { lab.fixture.loseNextAck = true }
                    .accessibilityIdentifier("lab.loseNextAck")
                Button("Report fresh observation") { lab.fixture.reportFreshObservation() }
                    .accessibilityIdentifier("lab.freshObservation")
            }
        }
    }

    /// Exact inserted text stays in fixture memory and is exposed here for
    /// deterministic UI assertions; it is never written to the event log.
    private var insertionReadback: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Inserted text commands")
                Spacer()
                Text("\(lab.fixture.insertedTextCount)")
                    .accessibilityIdentifier("lab.insertedTextCount")
            }
            HStack {
                Text("Final inserted text")
                Spacer()
                Text(lab.fixture.lastInsertedText)
                    .lineLimit(1)
                    .accessibilityIdentifier("lab.lastInsertedText")
            }
        }
        .font(.caption)
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection").font(.headline)
            HStack(spacing: 8) {
                Button("Connect") { lab.viewModel.connect() }
                    .accessibilityIdentifier("lab.connect")
                Button("Disconnect") { lab.fixture.disconnect() }
                    .accessibilityIdentifier("lab.disconnect")
                Button("Reconnect") { lab.viewModel.reconnect() }
                    .accessibilityIdentifier("lab.reconnect")
            }
            HStack(spacing: 8) {
                Button("Rotate surface") { lab.fixture.rotateSurface() }
                    .accessibilityIdentifier("lab.rotateSurface")
                Button("End session") { lab.fixture.endSession() }
                    .accessibilityIdentifier("lab.endSession")
                Button("New session") { lab.startNewSession() }
                    .accessibilityIdentifier("lab.newSession")
            }
            Text("End session is terminal; start a New session to run again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Control grants").font(.headline)
            Toggle("Auto-grant control requests", isOn: Binding(
                get: { lab.fixture.autoGrantControl },
                set: { lab.fixture.autoGrantControl = $0 }
            ))
                .accessibilityIdentifier("lab.autoGrant")
            Button("Reject next request") { lab.fixture.rejectNextRequest = true }
                .accessibilityIdentifier("lab.rejectNext")
            Text(lab.fixture.rejectNextRequest
                 ? "Armed: the next control request will be rejected."
                 : "With auto-grant off and no rejection armed, requests stay pending.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var acknowledgementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Acknowledgements").font(.headline)
            HStack {
                Text("Ack delay")
                Slider(value: Binding(
                    get: { lab.fixture.ackDelay },
                    set: { lab.fixture.ackDelay = $0 }
                ), in: 0...2, step: 0.1)
                    .accessibilityIdentifier("lab.ackDelay")
                Text(String(format: "%.1fs", lab.fixture.ackDelay))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
            Text(lab.fixture.loseNextAck
                 ? "Armed: the next accepted command's acknowledgement will be lost."
                 : "Lost acks, including Resume, stay unknown until a fresh observation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var framesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Synthetic frames").font(.headline)
            Button(lab.fixture.framesRunning ? "Stop frames" : "Start frames") {
                lab.fixture.framesRunning
                    ? lab.fixture.stopFrames()
                    : lab.fixture.startFrames()
            }
            .accessibilityIdentifier("lab.frames")
            Text("Changing synthetic frames (moving box, sequence stamps). Disconnecting shields the last frame as stale.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var readbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Readback").font(.headline)
            LabeledContent("Session state") {
                Text(String(describing: lab.viewModel.state))
                    .accessibilityIdentifier("lab.sessionState")
            }
            LabeledContent("Accepted commands") {
                Text("\(lab.fixture.acceptedCommandCount)")
                    .accessibilityIdentifier("lab.acceptedCount")
            }
            LabeledContent("Last command") {
                Text(lab.fixture.lastCommandDescription)
                    .accessibilityIdentifier("lab.lastCommand")
            }
            Text("Event log").font(.subheadline)
            ForEach(Array(lab.fixture.eventLog.suffix(8).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .monospaced()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("lab.readback")
    }
}

/// Re-evaluates the complete fixture panel whenever its nested observable
/// adapter changes. BrowserLabState owns a replaceable adapter reference, so
/// observing only the state object would otherwise leave panel values stale.
private struct FixtureObservedContent<Content: View>: View {
    @ObservedObject var fixture: SimulatedBrowserAdapter
    private let content: () -> Content

    init(
        fixture: SimulatedBrowserAdapter,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.fixture = fixture
        self.content = content
    }

    var body: some View {
        content()
    }
}
