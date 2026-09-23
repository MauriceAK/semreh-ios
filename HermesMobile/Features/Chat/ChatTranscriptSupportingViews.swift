import SwiftUI
import UIKit
import OSLog
import Darwin

#if DEBUG

/// Diagnostic only: geometry is logged, never published back into layout.
struct NativeRefinementProbe: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        content.background {
            if ProcessInfo.processInfo.arguments.contains("--native-refinement-trace"),
               ["last-row", "sentinel", "viewport", "composer"].contains(name) {
                NativeRefinementMarker(name: name)
            }
        }.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
            guard ProcessInfo.processInfo.arguments.contains("--native-refinement-trace") else { return }
            Logger(subsystem: "com.maurice.semreh", category: "NativeBaseline").debug("event=rect name=\(name, privacy: .public) y=\(rect.minY, privacy: .public) height=\(rect.height, privacy: .public) bottom=\(rect.maxY, privacy: .public)")
        }
    }
}

private struct NativeRefinementMarker: UIViewRepresentable {
    let name: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.isUserInteractionEnabled = false
        NativeRefinementViews.views.setObject(view, forKey: name as NSString)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        NativeRefinementViews.views.setObject(view, forKey: name as NSString)
    }
}
@MainActor private enum NativeRefinementViews {
    static let views = NSMapTable<NSString, UIView>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    static func tailAlignmentError() -> CGFloat? {
        guard let tail = views.object(forKey: "sentinel"), let viewport = views.object(forKey: "viewport"),
              tail.window != nil, tail.window === viewport.window else { return nil }
        return tail.convert(tail.bounds, to: nil).maxY - viewport.convert(viewport.bounds, to: nil).maxY
    }
    static func snapshot() -> String {
        ["last-row", "sentinel", "viewport", "composer"].map { name in
            guard let view = views.object(forKey: name as NSString), view.window != nil else { return "\(name):unmounted" }
            let rect = view.convert(view.bounds, to: nil)
            var detail = "\(name):\(rect.minY):\(rect.height):\(rect.maxY)"
            if name == "sentinel" {
                var parent = view.superview
                while let ancestor = parent {
                    if let scroll = ancestor as? UIScrollView {
                        let end = view.convert(view.bounds, to: scroll).maxY
                        detail += ":nativeContentEnd=\(end):contentHeight=\(scroll.contentSize.height):offset=\(scroll.contentOffset):boundsHeight=\(scroll.bounds.height):adjustedInsets=\(scroll.adjustedContentInset)"
                        break
                    }
                    parent = ancestor.superview
                }
            }
            return detail
        }.joined(separator: ",")
    }
}

/// Control experiment: native ID scrolling only, no restore, offset writer,
/// geometry-to-State feedback, row measurements, or UIKit delegate override.
struct NativeBaselineTranscript<Rows: View>: View {
    let firstID: String?
    let lastID: String?
    let bottomID: String
    let bottomInset: CGFloat
    let spacing: CGFloat
    let reduceMotion: Bool
    @ViewBuilder let rows: () -> Rows
    @State private var trace = NativeBaselineTrace()
    @State private var position = ScrollPosition(idType: String.self)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var horizontalPadding: CGFloat { dynamicTypeSize.isAccessibilitySize ? 20 : 16 }
    private var usesContentBottomPadding: Bool {
        ProcessInfo.processInfo.arguments.contains("--native-content-bottom-padding")
    }
    private var usesEagerControl: Bool {
        ProcessInfo.processInfo.arguments.contains("--native-eager-control")
            && ProcessInfo.processInfo.arguments.contains("--representative-count=120")
    }

    @ViewBuilder private var stackContent: some View {
        rows()
        Color.clear.frame(height: 1)
            .modifier(NativeRefinementProbe(name: "sentinel"))
            .onScrollVisibilityChange(threshold: 1) { trace.tailVisible = $0 }
            .id(bottomID)
    }

    @ViewBuilder private var transcriptStack: some View {
        if usesEagerControl {
            VStack(spacing: spacing) { stackContent }
                .scrollTargetLayout()
        } else {
            LazyVStack(spacing: spacing) { stackContent }
                .scrollTargetLayout()
        }
    }

    var body: some View {
        GeometryReader { viewport in
          ZStack(alignment: .bottom) {
            ScrollView {
                transcriptStack
                    .padding(.top, 16)
                    .frame(width: max(0, viewport.size.width - horizontalPadding * 2), alignment: .leading)
                    .padding(.horizontal, horizontalPadding)
                    .frame(width: max(0, viewport.size.width), alignment: .leading)
                    .clipped()
                    .padding(.bottom, usesContentBottomPadding ? bottomInset : 0)
                    .background {
                        if ProcessInfo.processInfo.arguments.contains("--native-production-axis-guard") {
                            ChatVerticalScrollAxisGuard().accessibilityHidden(true)
                        }
                    }
            }
            .frame(width: max(0, viewport.size.width))
            .scrollPosition($position)
            .modifier(NativeRefinementProbe(name: "viewport"))
            .accessibilityIdentifier("native-baseline-scroll")
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: usesContentBottomPadding ? 0 : bottomInset) }
            .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, point in
                trace.x = point.x
                trace.observe(point.y)
            }
            .onScrollPhaseChange { _, phase in trace.recordPhase(phase) }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    jump()
                } label: {
                    Image(systemName: "arrow.down").frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityIdentifier("native-baseline-jump")
                .padding(.trailing, 16).padding(.bottom, bottomInset + 8)
            }
            .task {
                guard ProcessInfo.processInfo.arguments.contains("--native-baseline-autojump") else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                jump()
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let firstID else { return }
                position.scrollTo(id: firstID, anchor: .top)
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                jump()
            }
            .onDisappear { trace.stop() }
            .onAppear { NativeOpeningTrace.shared.armFirstFrame(eager: usesEagerControl) }
          }
        }
    }

    private func jump() {
        trace.start(waitForAnimation: !reduceMotion, correction: ProcessInfo.processInfo.arguments.contains("--native-edge-single-settlement") ? {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                position.scrollTo(edge: .bottom)
            }
        } : nil)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
            if ProcessInfo.processInfo.arguments.contains("--native-bottom-edge") {
                position.scrollTo(edge: .bottom)
            } else {
                position.scrollTo(id: lastID ?? bottomID, anchor: .bottom)
            }
        }
    }
}

/// Includes fixture creation and full view construction before the first display
/// callback. It does not pretend to include process launch before fixture init.
@MainActor final class NativeOpeningTrace: NSObject {
    static let shared = NativeOpeningTrace()
    private var began: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var eager = false
    private var callbackCount = 0
    private var postcommitProbeCompleted = false
#if DEBUG
    var afterFirstCallback: (() -> Void)?
#endif
    private let logger = Logger(subsystem: "com.maurice.semreh", category: "NativeBaseline")
    func begin() {
        guard ProcessInfo.processInfo.arguments.contains("--native-baseline")
            || ProcessInfo.processInfo.arguments.contains("--viewport-opening-probe") else { return }
        guard began == 0, link == nil else { return }
        if ProcessInfo.processInfo.arguments.contains("--viewport-postcommit-readable-probe"), postcommitProbeCompleted { return }
        began = CACurrentMediaTime()
        callbackCount = 0
        logger.debug("event=opening_begin footprintMB=\(self.footprintMB(), privacy: .public)")
    }
    func armFirstFrame(eager: Bool) {
        guard began > 0, link == nil else { return }
        self.eager = eager
        link = CADisplayLink(target: self, selector: #selector(firstFrame))
        link?.add(to: .main, forMode: .common)
    }
    @objc private func firstFrame() {
        callbackCount += 1
        if callbackCount == 1 {
            logger.debug("event=opening_first_callback eager=\(self.eager, privacy: .public) totalOpeningMS=\((CACurrentMediaTime()-self.began)*1000, privacy: .public) footprintMB=\(self.footprintMB(), privacy: .public)")
            // The first callback can run before its transaction reaches the
            // display. Only the DEBUG probe waits for a second display tick.
            if ProcessInfo.processInfo.arguments.contains("--viewport-postcommit-readable-probe") { return }
        } else {
            logger.debug("event=opening_postcommit_callback eager=\(self.eager, privacy: .public) totalOpeningMS=\((CACurrentMediaTime()-self.began)*1000, privacy: .public) footprintMB=\(self.footprintMB(), privacy: .public)")
        }
        postcommitProbeCompleted = ProcessInfo.processInfo.arguments.contains("--viewport-postcommit-readable-probe")
        link?.invalidate(); link = nil; began = 0
#if DEBUG
        let callback = afterFirstCallback
        afterFirstCallback = nil
        // One display interval lets the just-observed readable viewport paint
        // before the DEBUG cold-tap diagnostic, without warming the jump path.
        if let callback {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: callback)
        }
#endif
    }
    func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

/// Read-only bounded callback trace. No values publish to SwiftUI or drive layout.
@MainActor private final class NativeBaselineTrace: NSObject {
    var tailVisible = false
    var x: CGFloat = 0
    var y: CGFloat = 0
    private var startY: CGFloat = 0
    private var started: CFTimeInterval = 0
    private var previous: CFTimeInterval = 0
    private var firstMotion: CFTimeInterval?
    private var worstGap: CFTimeInterval = 0
    private var samples: [String] = []
    private var link: CADisplayLink?
    private var phase: ScrollPhase = .idle
    private var sawAnimation = false
    private var waitsForAnimation = false
    private var correction: (() -> Void)?
    private var stableSample: CGPoint?
    private var stableSampleCount = 0
    private let logger = Logger(subsystem: "com.maurice.semreh", category: "NativeBaseline")
    func recordPhase(_ phase: ScrollPhase) {
        self.phase = phase
        if phase == .animating { sawAnimation = true; stableSample = nil; stableSampleCount = 0 }
        if phase == .tracking || phase == .interacting || phase == .decelerating {
            if correction != nil { logger.debug("event=single_settlement_cancelled reason=manual") }
            correction = nil
        }
        logger.debug("event=scroll_phase phase=\(String(describing: phase), privacy: .public) x=\(self.x, privacy: .public) y=\(self.y, privacy: .public)")
        if phase == .idle, ProcessInfo.processInfo.arguments.contains("--native-refinement-trace") {
            logger.debug("event=idle_native_extent value=\(NativeRefinementViews.snapshot(), privacy: .public)")
        }
    }
    func observe(_ value: CGFloat) {
        y = value
        if link != nil, firstMotion == nil, abs(y - startY) > 1 { firstMotion = CACurrentMediaTime() - started }
    }
    func start(waitForAnimation: Bool = false, correction: (() -> Void)? = nil) {
        stop()
        self.correction = correction; waitsForAnimation = waitForAnimation; sawAnimation = false
        stableSample = nil; stableSampleCount = 0
        started = CACurrentMediaTime(); previous = started; startY = y
        firstMotion = nil; worstGap = 0; samples = []
        logger.debug("event=jump_start y=\(Double(self.y), privacy: .public)")
        logger.debug("event=jump_memory footprintMB=\(NativeOpeningTrace.shared.footprintMB(), privacy: .public)")
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    @objc private func tick() {
        let now = CACurrentMediaTime()
        worstGap = max(worstGap, now - previous); previous = now
        samples.append("\(Int((now-started)*1000)):\(Int(y))")
        // One correction only, after real native motion ends and two consecutive
        // fresh marker/offset samples agree. No estimate, proxy, or offset write.
        // A new jump replaces this closure; manual tracking cancels it above.
        if correction != nil, phase == .idle, (!waitsForAnimation || sawAnimation),
           now - started < 0.85, let error = NativeRefinementViews.tailAlignmentError(), abs(error) > 2 {
            let sample = CGPoint(x: error, y: y)
            if let old = stableSample, abs(old.x-sample.x) < 0.5, abs(old.y-sample.y) < 0.5 {
                stableSampleCount += 1
            } else { stableSampleCount = 1 }
            stableSample = sample
            if stableSampleCount >= 2 {
                let action = correction; correction = nil
                logger.debug("event=single_settlement_issue error=\(error, privacy: .public) elapsedMS=\((now-self.started)*1000, privacy: .public)")
                logger.debug("event=single_settlement_native_extent value=\(NativeRefinementViews.snapshot(), privacy: .public)")
                action?()
            }
        }
        if now - started >= 1.5 {
            if ProcessInfo.processInfo.arguments.contains("--native-refinement-trace") {
                logger.debug("event=settled_rects y_height_bottom=\(NativeRefinementViews.snapshot(), privacy: .public)")
                logger.debug("event=settled_offsets x=\(self.x, privacy: .public) y=\(self.y, privacy: .public)")
            }
            logger.debug("event=jump_end firstMotionMS=\((self.firstMotion ?? -1)*1000, privacy: .public) worstCallbackMS=\(self.worstGap*1000, privacy: .public) tail=\(self.tailVisible, privacy: .public) samples=\(self.samples.joined(separator: ","), privacy: .public)")
            stop()
        }
    }
    func stop() { link?.invalidate(); link = nil; correction = nil }
}
#endif

final class PrototypeCodeViewport: ObservableObject {
    @Published var rect: CGRect = .zero
    var correctAnchor: (CGFloat) -> Void = { _ in }
#if DEBUG
    var nativeRichSnapshot: NativeRichRowSnapshot?
    var nativeRichToggleCodeWrap: (() -> Void)?
    var forceExpandThinking = false
    var forceExpandTool = false
#endif
}

private struct PrototypeCodeViewportKey: EnvironmentKey {
    static let defaultValue: PrototypeCodeViewport? = nil
}

extension EnvironmentValues {
    var prototypeCodeViewport: PrototypeCodeViewport? {
        get { self[PrototypeCodeViewportKey.self] }
        set { self[PrototypeCodeViewportKey.self] = newValue }
    }
}

/// Opt-in transcript viewport path. Hosts the existing production row views,
/// while owning estimated geometry and preserving the visible reader anchor
/// when a measured height refines. The existing ScrollView remains the default.
struct StableViewportRowRevision: Equatable {
    let message: TranscriptMessage
    let latestCompletedAssistantRenderID: String?
    let outgoingInsertionEvent: OutgoingInsertionEvent?
    let allowsOutgoingMotion: Bool
    let reasoningGroups: [ReasoningGroup]
    let toolCallGroups: [ToolCallGroup]
    let liveReasoningText: String
    let liveToolCalls: [ToolCall]
    let streamingAssistantMessageID: String?
    let liveTokensPerSecond: Double?
    let localAttachmentPreviews: [String: Data]?
    let compressionReferenceCard: CompressionReferenceCard?
    let listeningMessageID: String?
    let showsThinkingAndToolCards: Bool
    let isViewingCachedData: Bool
    let hasActiveStream: Bool
    let isRegeneratingMessage: Bool
    let isEditingMessage: Bool
    let isForkingMessage: Bool
    let transcriptMediaCacheNamespace: String
}

struct ChatStableViewportPrototype: UIViewControllerRepresentable {
    let ids: [String]
    let revisionAt: (Int) -> StableViewportRowRevision
    let revision: Int
    let typeKey: String
    let bottomInset: CGFloat
    let spacing: CGFloat
    let reduceMotion: Bool
    let initialID: String?
    let startsAtBottom: Bool
    let onJumpToLatest: () -> Void
    let onScrollState: (ChatScrollMetrics, String?, Bool, Bool) -> Void
    let nativeRichDark: Bool
    let nativeRichWrapsCodeLines: Bool
    let nativePromptFillHex: String
    let nativePromptForegroundHex: String
    let nativePromptBorderHex: String
    let onDirectSelectText: (Int) -> Void
    let onDirectCopy: (Int) -> Void
    let onDirectOpenURL: (URL) -> Void
    let makeRow: (Int, PrototypeCodeViewport) -> AnyView

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.configure(self) }

    @MainActor final class Controller: UIViewController, UIScrollViewDelegate {
        struct HeightKey: Hashable { let id: String; let width: Int; let type: String }
        struct CachedHeight { let height: CGFloat; let revision: StableViewportRowRevision }
        let scroll = UIScrollView()
        let arrow = UIButton(type: .system)
#if DEBUG
        let directArrowStatus = UILabel()
#endif
        var input: ChatStableViewportPrototype?
        var heights: [CGFloat] = []
        var positions: [CGFloat] = [16]
        var cache: [HeightKey: CachedHeight] = [:]
        var cacheOrder: [HeightKey] = []
        var indicesByID: [String: Int] = [:]
        var lastReportedScrollState: ReportedScrollState?
        var hosts: [Int: UIHostingController<AnyView>] = [:]
        var hostRevisions: [Int: StableViewportRowRevision] = [:]
        var codeViewports: [Int: PrototypeCodeViewport] = [:]
        var measured = Set<Int>()
        var width: CGFloat = 0
        var layingOut = false
        var seeded = false
        var link: CADisplayLink?
        var started: CFTimeInterval = 0
        var previousTick: CFTimeInterval = 0
        var previousProgress: CGFloat = 0
        var maximumGap: CFTimeInterval = 0
        var maximumMeasure: CFTimeInterval = 0
        var frameCount = 0
        var measurementCount = 0
        var hostCost: CFTimeInterval = 0
        var sizingCost: CFTimeInterval = 0
        var geometryCost: CFTimeInterval = 0
        var layoutCost: CFTimeInterval = 0
        var maximumLayoutCost: CFTimeInterval = 0
        var maximumTickCost: CFTimeInterval = 0
        var hostCreationCount = 0
        var peakHosts = 0
        var layoutCount = 0
        var refinementCount = 0
        var memoryAtStart: Double = 0
#if DEBUG
        struct NativeRichKey: Equatable {
            let id: String
            let source: String
            let width: CGFloat
            let dark: Bool
            let presentation: String
        }
        var nativeRichKey: NativeRichKey?
        var nativeRichSnapshot: NativeRichRowSnapshot?
        var nativeRichAlternateSnapshot: NativeRichRowSnapshot?
        var nativeRichTask: Task<Void, Never>?
        var nativeRichFailed = false
        // Exactly twenty representative assistant rows, sampled across the
        // cold 120-row trajectory (9/11/13, 71/73/75, 97/99, 103/105/107,
        // 113/115/117/119 were actually fitted in the signed control trace).
        static let nativeRichPilotIndices: [Int] = [5, 7, 9, 11, 13, 69, 71, 73, 75, 95,
                                                    97, 99, 101, 103, 105, 107, 113, 115, 117, 119]
        var nativeRichPilotKeys: [Int: NativeRichKey] = [:]
        var nativeRichPilotSnapshots: [Int: NativeRichRowSnapshot] = [:]
        var nativeRichPilotAlternates: [Int: NativeRichRowSnapshot] = [:]
        var nativeRichPilotTasks: [Int: Task<Void, Never>] = [:]
        var nativeRichPilotFailed: Set<Int> = []
        var nativeRichPilotFinished: Set<Int> = []
        var nativeRichPilotBatchStartedAt: CFTimeInterval?
        var nativeRichPilotStartMB = 0.0
        var nativeRichPilotScanTask: Task<Void, Never>?
        struct DirectKey: Equatable {
            let id: String
            let revision: StableViewportRowRevision
            let width: CGFloat
            let typeKey: String
            let dark: Bool
            let wrapsCode: Bool
            let promptFill: String
            let promptForeground: String
            let promptBorder: String
        }
        struct DirectEntry {
            let key: DirectKey
            let row: NativeDirectPreparedRow
        }
        struct DirectBodyKey: Hashable {
            let id: String
            let sourceBytes: [UInt8]
            let width: CGFloat
            let dark: Bool
            let wrapsCode: Bool
        }
        var directBodies: [DirectBodyKey: NativeRichRowSnapshot] = [:]
        var directEntries: [Int: DirectEntry] = [:]
        var directAlternates: [Int: NativeDirectPreparedRow] = [:]
        var directThinkingSnapshots: [Int: (key: DirectKey, detail: NativeRichRowSnapshot)] = [:]
        var directExpandedThinking = Set<Int>()
        var directToolSnapshots: [Int: (key: DirectKey, details: [String: NativeRichRowSnapshot])] = [:]
        var directExpandedToolIDs: [Int: Set<String>] = [:]
        var directExpandedToolGroups = Set<Int>()
        var directTasks: [Int: Task<Void, Never>] = [:]
        var directStreamRequestedBodyKey: DirectBodyKey?
        var directStreamFailedBodyKey: DirectBodyKey?
        var requestedDirect10kIndices: [Int] = []
        var direct10kJumpStartOffset: CGFloat = 0
        var direct10kMissingFrames = 0
        var direct10kPeakEntries = 0
        var strictDirect10kGate: Bool {
            ProcessInfo.processInfo.arguments.contains("--native-direct-strict-10k-gate")
        }
        var flightProxies: [Int: UIView] = [:]
        var flightProxyMounts = 0
        var flightLegacyFits = 0
        var flightReportsSuppressed = 0
        var directViews: [Int: NativeDirectTranscriptRowView] = [:]
        var directFailed = Set<Int>()
        var directFallbackDisclosure: [Int: String] = [:]
        var directMountedDuringJump = 0
        var directMeasuredDuringJump = 0
        var directAllStartedAt: CFTimeInterval?
        var directAllReported = false
        var pendingDirectWidthTask: Task<Void, Never>?
        var pendingDirectWidth: CGFloat?
        var failedDirectWidth: CGFloat?
        var pendingDirectPresentationTask: Task<Void, Never>?
        var pendingDirectPresentation: String?
        var pendingNativeJumpAt: CFTimeInterval?
        var tapStarted: CFTimeInterval = 0
        // The bounded stream fixture shares the arrow's display link. Its
        // offset is the only moving coordinate; mounted row frames stay tied
        // to their source-derived positions as the bottom target grows.
        var directStreamFollowing = false
        var directStreamAnimating = false
        var directStreamVelocity: CGFloat = 0
        var directStreamPreviousTick: CFTimeInterval = 0
        var directStreamConfiguring = false
        var directStreamTickWriting = false
        var directStreamLastOffset: CGFloat?
        var directStreamUnexpectedMoves = 0
#endif
        let logger = Logger(subsystem: "com.maurice.semreh", category: "ViewportPrototype")


        struct ReportedScrollState: Equatable {
            let nearBottom: Bool
            let direct: Bool
            let decelerating: Bool
            let visibleID: String?
            let latestVisible: Bool
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            scroll.backgroundColor = .clear
            scroll.delegate = self
            scroll.alwaysBounceVertical = true
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.keyboardDismissMode = .interactive
            scroll.accessibilityIdentifier = "prototype-transcript-scroll"
            view.addSubview(scroll)
            arrow.setImage(UIImage(systemName: "arrow.down"), for: .normal)
            arrow.backgroundColor = .secondarySystemBackground
            arrow.layer.cornerRadius = 24
            arrow.accessibilityLabel = "Prototype scroll to latest"
            arrow.addTarget(self, action: #selector(jump), for: .touchUpInside)
            view.addSubview(arrow)
#if DEBUG
            directArrowStatus.text = "Preparing latest messages"
            directArrowStatus.font = .systemFont(ofSize: 12, weight: .medium)
            directArrowStatus.textColor = .secondaryLabel
            directArrowStatus.textAlignment = .center
            directArrowStatus.backgroundColor = .secondarySystemBackground
            directArrowStatus.layer.cornerRadius = 14
            directArrowStatus.clipsToBounds = true
            directArrowStatus.isHidden = true
            directArrowStatus.accessibilityIdentifier = "native-direct-arrow-unready"
            view.addSubview(directArrowStatus)
#endif
        }

        func configure(_ new: ChatStableViewportPrototype) {
#if DEBUG
            let configureStarted = CACurrentMediaTime()
            defer {
                if ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic"), link != nil {
                    logger.debug("event=direct_10k_flight_configure_ms value=\(Int((CACurrentMediaTime() - configureStarted) * 1_000), privacy: .public) frame=\(self.frameCount, privacy: .public)")
                }
            }
#endif
            let oldInput = input
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-direct-premount-window-gate"),
               let oldInput, oldInput.ids == new.ids, oldInput.revision == new.revision,
               oldInput.typeKey != new.typeKey,
               new.ids.indices.contains(1),
               let source = new.revisionAt(1).message.message.content,
               let id = new.revisionAt(1).message.message.messageId,
               let prepared = NativePremountRichFixtureStore.entry,
               prepared.messageID == id, prepared.source == source,
               abs(prepared.bodyWidth - (width - 48)) < 0.5,
               prepared.snapshot(dark: new.nativeRichDark,
                                 wrapsCodeLines: new.nativeRichWrapsCodeLines) == nil {
                stageDirectWindowPresentation(new, id: id, source: source)
                return
            }
            pendingDirectPresentationTask?.cancel()
            pendingDirectPresentationTask = nil
            pendingDirectPresentation = nil
            let oldNativeSnapshot = nativeRichSnapshot
            let oldNativeAlternate = nativeRichAlternateSnapshot
            let oldNativeKey = nativeRichKey
            let wrapOnlyChange = oldInput?.ids == new.ids && oldInput?.revision == new.revision
                && oldInput?.nativeRichDark == new.nativeRichDark
                && oldInput?.typeKey != new.typeKey
                && oldInput?.typeKey.components(separatedBy: "|wrap:").first == new.typeKey.components(separatedBy: "|wrap:").first
            if wrapOnlyChange, let oldNativeSnapshot, let oldNativeAlternate,
               oldNativeAlternate.wrapsCodeLines == new.nativeRichWrapsCodeLines, let oldNativeKey,
               oldNativeKey.source == new.ids.indices.last.flatMap({ new.revisionAt($0).message.message.content }),
               oldNativeKey.width == width - 48 {
                nativeRichSnapshot = oldNativeAlternate
                nativeRichAlternateSnapshot = oldNativeSnapshot
                nativeRichKey = NativeRichKey(id: oldNativeKey.id, source: oldNativeKey.source,
                                              width: oldNativeKey.width, dark: oldNativeKey.dark,
                                              presentation: new.typeKey)
            }
            if wrapOnlyChange {
                for index in selectedNativeRichPilotIndices {
                    guard let key = nativeRichPilotKeys[index],
                          let oldSnapshot = nativeRichPilotSnapshots[index],
                          let alternate = nativeRichPilotAlternates[index],
                          alternate.wrapsCodeLines == new.nativeRichWrapsCodeLines,
                          new.ids.indices.contains(index), key.id == new.ids[index],
                          key.source == new.revisionAt(index).message.message.content,
                          key.width == width - 48 else { continue }
                    nativeRichPilotSnapshots[index] = alternate
                    nativeRichPilotAlternates[index] = oldSnapshot
                    nativeRichPilotKeys[index] = NativeRichKey(id: key.id, source: key.source,
                                                               width: key.width, dark: key.dark,
                                                               presentation: new.typeKey)
                }
                for index in (ProcessInfo.processInfo.arguments.contains("--native-direct-all120-diagnostic")
                              ? [1, 3, 118, 119]
                              : ProcessInfo.processInfo.arguments.contains("--native-direct-premount-window-gate")
                                ? [1, 3] : [118, 119]) {
                    guard new.ids.indices.contains(index), let old = directEntries[index],
                          old.key.id == new.ids[index], old.key.revision == new.revisionAt(index),
                          old.key.width == width, old.key.dark == new.nativeRichDark else { continue }
                    let newKey = DirectKey(id: old.key.id, revision: old.key.revision, width: width,
                        typeKey: new.typeKey, dark: new.nativeRichDark, wrapsCode: new.nativeRichWrapsCodeLines,
                        promptFill: new.nativePromptFillHex, promptForeground: new.nativePromptForegroundHex,
                        promptBorder: new.nativePromptBorderHex)
                    if !index.isMultiple(of: 2), let alternate = directAlternates[index],
                       case .assistant(let body, _, _, _, _, _, _, _, _) = alternate.content,
                       body.wrapsCodeLines == new.nativeRichWrapsCodeLines,
                       case .assistant(let oldBody, _, _, _, _, _, _, _, _) = old.row.content {
                        directAlternates[index] = old.row
                        if let reasoning = new.revisionAt(index).reasoningGroups.first,
                           case .ready(let detail) = NativeBasicFirstRowPreparation.prepare(
                               source: reasoning.text, width: width - 48,
                               dark: new.nativeRichDark,
                               wrapsCodeLines: new.nativeRichWrapsCodeLines) {
                            directThinkingSnapshots[index] = (newKey, detail)
                        }
                        directEntries[index] = DirectEntry(key: newKey,
                            row: makeDirectAssistantRow(body: body, key: newKey,
                                thinkingDetail: directExpandedThinking.contains(index)
                                    ? directThinkingSnapshots[index]?.detail : nil))
                        logger.debug("event=premount_rich_wrap_swap index=\(index, privacy: .public) oldBodyHeight=\(oldBody.height, privacy: .public) newBodyHeight=\(body.height, privacy: .public)")
                    } else if index.isMultiple(of: 2) {
                        directEntries[index] = DirectEntry(key: newKey, row: old.row)
                    }
                }
            }
#endif
            let changed = oldInput?.ids != new.ids || oldInput?.typeKey != new.typeKey
            let contentChanged = input?.revision != new.revision
            let priorIDs = input?.ids ?? []
            let anchorIndex = heights.isEmpty ? nil : row(at: max(0, scroll.contentOffset.y))
            let anchorID = anchorIndex.flatMap { priorIDs.indices.contains($0) ? priorIDs[$0] : nil }
            let anchorLocal = anchorIndex.map { scroll.contentOffset.y - positions[$0] } ?? 0
            let wasAtBottom = seeded && !scroll.isDragging && !scroll.isDecelerating
                && abs(bottomOffset - scroll.contentOffset.y) < 3
            let oldBottomDistance = bottomOffset - scroll.contentOffset.y
#if DEBUG
            let beginsDirectStreamFollow = directBodyCacheGateEnabled
                && oldInput?.ids.count == 120 && new.ids.count == 122
                && Array(new.ids.prefix(120)) == oldInput?.ids
                && (wasAtBottom || link != nil)
            if beginsDirectStreamFollow {
                cancel(reason: "stream_insert")
                directStreamFollowing = true
                directStreamConfiguring = true
                directStreamLastOffset = scroll.contentOffset.y
                directStreamUnexpectedMoves = 0
                scroll.accessibilityValue = "stream motion active"
            } else if directStreamFollowing,
                      (oldInput?.ids != new.ids || oldInput?.typeKey != new.typeKey) {
                cancel(reason: "stream_identity_changed")
                directStreamFollowing = false
                directStreamLastOffset = nil
            }
#endif
            input = new
#if DEBUG
            if oldInput?.ids != new.ids {
                let preservesDirectAppend = ProcessInfo.processInfo.arguments.contains("--native-direct-body-cache-gate")
                    && oldInput?.ids.count == 120 && new.ids.count == 122
                    && Array(new.ids.prefix(120)) == oldInput?.ids
                pendingDirectWidthTask?.cancel()
                pendingDirectWidthTask = nil
                pendingDirectWidth = nil
                failedDirectWidth = nil
                pendingNativeJumpAt = nil
                nativeRichTask?.cancel()
                nativeRichKey = nil
                nativeRichSnapshot = nil
                nativeRichAlternateSnapshot = nil
                nativeRichFailed = false
                for task in nativeRichPilotTasks.values { task.cancel() }
                nativeRichPilotTasks.removeAll()
                nativeRichPilotKeys.removeAll()
                nativeRichPilotSnapshots.removeAll()
                nativeRichPilotAlternates.removeAll()
                nativeRichPilotFailed.removeAll()
                nativeRichPilotFinished.removeAll()
                nativeRichPilotBatchStartedAt = nil
                for task in directTasks.values { task.cancel() }
                directTasks.removeAll()
                directStreamRequestedBodyKey = nil
                directStreamFailedBodyKey = nil
                if !preservesDirectAppend {
                    directEntries.removeAll()
                    directAlternates.removeAll()
                    directBodies.removeAll()
                    directThinkingSnapshots.removeAll()
                    directExpandedThinking.removeAll()
                    directToolSnapshots.removeAll()
                    directExpandedToolIDs.removeAll()
                    directExpandedToolGroups.removeAll()
                    directFailed.removeAll()
                    directFallbackDisclosure.removeAll()
                } else {
                    logger.error("event=direct_body_append_preserved entries=\(self.directEntries.count, privacy: .public) bodies=\(self.directBodies.count, privacy: .public)")
                }
                directAllStartedAt = nil
                directAllReported = false
            }
#endif
#if DEBUG
            if !isViewLoaded { directStreamConfiguring = false }
#endif
            guard isViewLoaded else { return }
            scroll.contentInset.bottom = new.bottomInset
            if changed {
                let oldIDs = oldInput?.ids ?? []
                let sameType = oldInput?.typeKey == new.typeKey
                let prefix = sameType ? zip(oldIDs, new.ids).prefix(while: { $0.0 == $0.1 }).count : 0
#if DEBUG
                // Source-derived outgoing and pending-assistant extents must
                // exist before reconcile adds their positions. An estimated
                // 100pt pair would make the target shrink during first mount.
                if beginsDirectStreamFollow { prepareDirectTwoRowsIfNeeded() }
#endif
                if prefix > 0, !oldIDs.isEmpty {
                    reconcileCommonPrefix(prefix, oldIDs: oldIDs)
                } else {
                    indicesByID = Dictionary(uniqueKeysWithValues: new.ids.enumerated().map { ($0.element, $0.offset) })
                    resetRows()
#if DEBUG
                    if wrapOnlyChange, nativeRichSnapshot != nil, let last = new.ids.indices.last { measure(last) }
#endif
                }
#if DEBUG
                if beginsDirectStreamFollow, let oldTail = directEntries[119] {
                    applyHeight(oldTail.row.height, index: 119)
                }
#endif
#if DEBUG
                // The bounded four-row fixture has all appearance/wrap variants
                // ready before mount. Recreate its direct rows synchronously
                // before the normal viewport pass can fit a legacy host.
                if ProcessInfo.processInfo.arguments.contains("--native-direct-premount-window-gate") {
                    prepareDirectTwoRowsIfNeeded()
                }
                if ProcessInfo.processInfo.arguments.contains("--native-direct-body-cache-gate"),
                   new.ids.count == 122 {
                    prepareDirectTwoRowsIfNeeded()
                }
#endif
                if seeded && anchorID.flatMap({ indicesByID[$0] }) == nil {
                    seeded = false
                } else if seeded {
#if DEBUG
                    let snapToBottom = wasAtBottom && !directStreamFollowing
#else
                    let snapToBottom = wasAtBottom
#endif
                    if snapToBottom {
                        scroll.contentOffset.y = bottomOffset
                    } else if let anchorID, let index = indicesByID[anchorID] {
                        scroll.contentOffset.y = positions[index] + anchorLocal
                    }
                    invalidateChangedRows(scanCache: contentChanged)
                    layoutRows()
                }
            } else {
                // SwiftUI state such as editing, cached-data presentation or
                // insertion motion can change without a ViewModel render token.
                // Comparing only mounted rows keeps that check viewport-bounded.
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--native-direct-body-cache-gate"),
                   new.ids.count == 122 {
                    prepareDirectTwoRowsIfNeeded()
                }
#endif
                invalidateChangedRows(scanCache: contentChanged)
            }
            view.setNeedsLayout()
#if DEBUG
            prepareNativeRichIfNeeded()
            prepareNativeRichPilotIfNeeded()
            prepareDirectTwoRowsIfNeeded()
            if ProcessInfo.processInfo.arguments.contains("--native-direct-body-cache-gate"),
               new.ids.count == 122, priorIDs.count >= 120 {
                logger.error("event=direct_stream_anchor oldBottomDistance=\(oldBottomDistance, privacy: .public) newBottomDistance=\(self.bottomOffset - self.scroll.contentOffset.y, privacy: .public) wasAtBottom=\(wasAtBottom, privacy: .public) row119Height=\(self.heights[119], privacy: .public)")
            }
            directStreamConfiguring = false
            if directStreamFollowing { startDirectStreamFollow() }
#endif
        }

#if DEBUG
        var selectedNativeRichPilotIndices: [Int] {
            ProcessInfo.processInfo.arguments.contains("--native-rich-all-eligible-120")
                ? Array(stride(from: 1, through: 119, by: 2)) : Self.nativeRichPilotIndices
        }

        func finishNativeRichPilotPreparation(_ index: Int) {
            nativeRichPilotFinished.insert(index)
            guard nativeRichPilotFinished.count == selectedNativeRichPilotIndices.count,
                  let started = nativeRichPilotBatchStartedAt else { return }
            let wallMS = Int((CACurrentMediaTime() - started) * 1_000)
            let footprint = footprintMB()
            logger.debug("event=native_rich_pilot_batch_complete selected=\(self.selectedNativeRichPilotIndices.count, privacy: .public) ready=\(self.nativeRichPilotSnapshots.count, privacy: .public) failed=\(self.nativeRichPilotFailed.count, privacy: .public) wallMs=\(wallMS, privacy: .public) startMB=\(self.nativeRichPilotStartMB, privacy: .public) finishMB=\(footprint, privacy: .public)")
        }

        func prepareNativeRichIfNeeded() {
            guard ProcessInfo.processInfo.arguments.contains("--native-rich-row-prototype"),
                  let input, width > 48, let index = input.ids.indices.last,
                  let source = input.revisionAt(index).message.message.content,
                  source.hasPrefix("## Response 119\n") else { return }
            // The content width follows the mounted assistant row's 24pt
            // trailing inset and 12pt horizontal bubble padding on both sides.
            let key = NativeRichKey(id: input.ids[index], source: source,
                                    width: width - 48, dark: input.nativeRichDark,
                                    presentation: input.typeKey)
            guard nativeRichKey != key else { return }
            pendingNativeJumpAt = nil
            nativeRichTask?.cancel()
            nativeRichKey = key
            nativeRichSnapshot = nil
            nativeRichAlternateSnapshot = nil
            nativeRichFailed = false
            let scheduledAt = CACurrentMediaTime()
            nativeRichTask = Task { [weak self] in
                let result = await NativeRichRowPreparationActor.shared.prepare(
                    source: key.source, width: key.width, dark: key.dark,
                    wrapsCodeLines: input.nativeRichWrapsCodeLines
                )
                guard let self, !Task.isCancelled, self.nativeRichKey == key,
                      self.input?.ids.indices.contains(index) == true,
                      self.input?.ids[index] == key.id else { return }
                switch result {
                case .ready(let snapshot):
                    let alternate = await NativeRichRowPreparationActor.shared.prepare(
                        source: key.source, width: key.width, dark: key.dark,
                        wrapsCodeLines: !snapshot.wrapsCodeLines
                    )
                    guard case .ready(let alternateSnapshot) = alternate,
                          !Task.isCancelled, self.nativeRichKey == key else {
                        self.nativeRichFailed = true
                        self.logger.error("event=native_rich_wrap_prep_failed")
                        if self.pendingNativeJumpAt != nil { self.jump() }
                        return
                    }
                    guard snapshot.sourceBytes == Array(key.source.utf8),
                          abs(snapshot.width - key.width) < 0.5 else {
                        self.nativeRichFailed = true
                        self.logger.error("event=native_rich_prep_invalid_snapshot")
                        if self.pendingNativeJumpAt != nil { self.jump() }
                        return
                    }
                    let wasMounted = self.hosts[index] != nil
                    guard !wasMounted else {
                        self.nativeRichFailed = true
                        self.logger.error("event=native_rich_premount_failed_already_mounted")
                        if self.pendingNativeJumpAt != nil { self.jump() }
                        return
                    }
                    self.nativeRichSnapshot = snapshot
                    self.nativeRichAlternateSnapshot = alternateSnapshot
                    let fitStarted = CACurrentMediaTime()
                    self.measure(index)
                    let fitMS = Int((CACurrentMediaTime() - fitStarted) * 1_000)
                    let wallMS = Int((CACurrentMediaTime() - scheduledAt) * 1_000)
                    self.logger.debug("event=native_rich_premount_ready prepMs=\(Int(snapshot.preparationMS), privacy: .public) wallMs=\(wallMS, privacy: .public) mainFitMs=\(fitMS, privacy: .public) mountedBefore=\(wasMounted, privacy: .public) rowHeight=\(self.heights[index], privacy: .public) bodyHeight=\(snapshot.height, privacy: .public)")
                    self.layoutRows()
                    if self.pendingNativeJumpAt != nil { self.jump() }
                case .unsupported(let kinds):
                    self.nativeRichFailed = true
                    self.logger.error("event=native_rich_premount_unsupported kinds=\(kinds.joined(separator: ","), privacy: .public)")
                    if self.pendingNativeJumpAt != nil { self.jump() }
                }
            }
        }

        func prepareNativeRichPilotIfNeeded() {
            guard (ProcessInfo.processInfo.arguments.contains("--native-rich-20-row-pilot")
                   || ProcessInfo.processInfo.arguments.contains("--native-rich-all-eligible-120")),
                  let input, input.ids.count == 120, width > 48 else { return }
            if nativeRichPilotBatchStartedAt == nil {
                nativeRichPilotBatchStartedAt = CACurrentMediaTime()
                nativeRichPilotStartMB = footprintMB()
            }
            for index in selectedNativeRichPilotIndices {
                guard input.ids.indices.contains(index),
                      let source = input.revisionAt(index).message.message.content,
                      source.hasPrefix("## Response \(index)\n") else { continue }
                let key = NativeRichKey(id: input.ids[index], source: source, width: width - 48,
                                        dark: input.nativeRichDark, presentation: input.typeKey)
                guard nativeRichPilotKeys[index] != key else { continue }
                nativeRichPilotTasks[index]?.cancel()
                nativeRichPilotKeys[index] = key
                nativeRichPilotSnapshots[index] = nil
                nativeRichPilotAlternates[index] = nil
                nativeRichPilotFailed.remove(index)
                nativeRichPilotFinished.remove(index)
                guard hosts[index] == nil else {
                    nativeRichPilotFailed.insert(index)
                    logger.error("event=native_rich_pilot_already_mounted index=\(index, privacy: .public)")
                    finishNativeRichPilotPreparation(index)
                    continue
                }
                let scheduledAt = CACurrentMediaTime()
                nativeRichPilotTasks[index] = Task { [weak self] in
                    let result = await NativeRichRowPreparationActor.shared.prepare(
                        source: key.source, width: key.width, dark: key.dark,
                        wrapsCodeLines: input.nativeRichWrapsCodeLines
                    )
                    guard let self, !Task.isCancelled, self.nativeRichPilotKeys[index] == key,
                          self.input?.ids.indices.contains(index) == true,
                          self.input?.ids[index] == key.id else { return }
                    guard case .ready(let snapshot) = result else {
                        self.nativeRichPilotFailed.insert(index)
                        self.logger.error("event=native_rich_pilot_unsupported index=\(index, privacy: .public)")
                        self.finishNativeRichPilotPreparation(index)
                        return
                    }
                    let alternate = await NativeRichRowPreparationActor.shared.prepare(
                        source: key.source, width: key.width, dark: key.dark,
                        wrapsCodeLines: !snapshot.wrapsCodeLines
                    )
                    guard case .ready(let alternateSnapshot) = alternate, !Task.isCancelled,
                          self.nativeRichPilotKeys[index] == key,
                          snapshot.sourceBytes == Array(key.source.utf8),
                          alternateSnapshot.sourceBytes == snapshot.sourceBytes,
                          abs(snapshot.width - key.width) < 0.5 else {
                        self.nativeRichPilotFailed.insert(index)
                        self.logger.error("event=native_rich_pilot_invalid index=\(index, privacy: .public)")
                        self.finishNativeRichPilotPreparation(index)
                        return
                    }
                    guard self.hosts[index] == nil else {
                        self.nativeRichPilotFailed.insert(index)
                        self.logger.error("event=native_rich_pilot_late_mounted index=\(index, privacy: .public)")
                        self.finishNativeRichPilotPreparation(index)
                        return
                    }
                    self.nativeRichPilotSnapshots[index] = snapshot
                    self.nativeRichPilotAlternates[index] = alternateSnapshot
                    let wallMS = Int((CACurrentMediaTime() - scheduledAt) * 1_000)
                    self.logger.debug("event=native_rich_pilot_ready index=\(index, privacy: .public) prepMs=\(Int(snapshot.preparationMS), privacy: .public) wallMs=\(wallMS, privacy: .public) bodyHeight=\(snapshot.height, privacy: .public) readyCount=\(self.nativeRichPilotSnapshots.count, privacy: .public)")
                    self.finishNativeRichPilotPreparation(index)
                }
            }
        }

        func nativeRichPilotSnapshot(at index: Int) -> NativeRichRowSnapshot? {
            guard (ProcessInfo.processInfo.arguments.contains("--native-rich-20-row-pilot")
                   || ProcessInfo.processInfo.arguments.contains("--native-rich-all-eligible-120")),
                  let input, input.ids.indices.contains(index),
                  let source = input.revisionAt(index).message.message.content,
                  let key = nativeRichPilotKeys[index],
                  key == NativeRichKey(id: input.ids[index], source: source, width: width - 48,
                                       dark: input.nativeRichDark, presentation: input.typeKey),
                  let snapshot = nativeRichPilotSnapshots[index],
                  snapshot.sourceBytes == Array(source.utf8), snapshot.dark == input.nativeRichDark,
                  snapshot.wrapsCodeLines == input.nativeRichWrapsCodeLines else { return nil }
            return snapshot
        }

        func directKey(at index: Int, input: ChatStableViewportPrototype) -> DirectKey {
            DirectKey(id: input.ids[index], revision: input.revisionAt(index), width: width,
                      typeKey: input.typeKey, dark: input.nativeRichDark,
                      wrapsCode: input.nativeRichWrapsCodeLines,
                      promptFill: input.nativePromptFillHex,
                      promptForeground: input.nativePromptForegroundHex,
                      promptBorder: input.nativePromptBorderHex)
        }

        func directBodyKey(_ key: DirectKey, wrapsCode: Bool? = nil) -> DirectBodyKey? {
            guard key.revision.message.message.role == "assistant",
                  let source = key.revision.message.message.content else { return nil }
            return DirectBodyKey(id: key.id, sourceBytes: Array(source.utf8),
                                 width: key.width - 48, dark: key.dark,
                                 wrapsCode: wrapsCode ?? key.wrapsCode)
        }

        func directRow(at index: Int) -> NativeDirectPreparedRow? {
            let all120 = ProcessInfo.processInfo.arguments.contains("--native-direct-all120-diagnostic")
            let firstWindow = ProcessInfo.processInfo.arguments.contains("--native-direct-premount-window-gate")
            let windowed10k = strictDirect10kGate
                || ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic")
                || ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic")
            guard (all120 || firstWindow || windowed10k || ProcessInfo.processInfo.arguments.contains("--native-direct-two-row-proof")),
                  let input,
                  input.ids.count == (windowed10k ? 10_000 : 120)
                    || (all120 && ProcessInfo.processInfo.arguments.contains("--native-direct-body-cache-gate")
                        && input.ids.count == 122),
                  ((all120 && (index < 120 || (input.ids.count == 122 && index < 122))) || windowed10k
                    || (firstWindow ? [0, 1, 2, 3] : [118, 119]).contains(index)),
                  input.ids.indices.contains(index), !directFailed.contains(index)
            else { return nil }
            let key = directKey(at: index, input: input)
            refreshDirectEntryKey(index, key: key)
            guard let entry = directEntries[index], entry.key == key else { return nil }
            if hosts[index] != nil {
                if directViews[index] != nil {
                    logger.error("event=direct_two_host_overlap index=\(index, privacy: .public)")
                    directViews.removeValue(forKey: index)?.removeFromSuperview()
                }
                directFailed.insert(index)
                return nil
            }
            return entry.row
        }

        func directPresentationMatches(_ old: DirectKey, _ new: DirectKey) -> Bool {
            guard old.id == new.id, old.width == new.width, old.typeKey == new.typeKey,
                  old.dark == new.dark, old.wrapsCode == new.wrapsCode,
                  old.promptFill == new.promptFill,
                  old.promptForeground == new.promptForeground,
                  old.promptBorder == new.promptBorder else { return false }
            let a = old.revision, b = new.revision
            return a.message == b.message
                && a.latestCompletedAssistantRenderID == b.latestCompletedAssistantRenderID
                && a.outgoingInsertionEvent == b.outgoingInsertionEvent
                && (a.outgoingInsertionEvent == nil || a.allowsOutgoingMotion == b.allowsOutgoingMotion)
                && a.reasoningGroups == b.reasoningGroups
                && a.toolCallGroups == b.toolCallGroups
                && a.liveReasoningText == b.liveReasoningText
                && a.liveToolCalls == b.liveToolCalls
                && a.streamingAssistantMessageID == b.streamingAssistantMessageID
                && a.liveTokensPerSecond == b.liveTokensPerSecond
                && a.localAttachmentPreviews == b.localAttachmentPreviews
                && a.compressionReferenceCard == b.compressionReferenceCard
                && a.listeningMessageID == b.listeningMessageID
                && a.showsThinkingAndToolCards == b.showsThinkingAndToolCards
                && a.isViewingCachedData == b.isViewingCachedData
                && a.hasActiveStream == b.hasActiveStream
                && a.isRegeneratingMessage == b.isRegeneratingMessage
                && a.isEditingMessage == b.isEditingMessage
                && a.isForkingMessage == b.isForkingMessage
                && a.transcriptMediaCacheNamespace == b.transcriptMediaCacheNamespace
        }

        func directRetainedPresentationMatches(_ old: DirectKey, _ new: DirectKey) -> Bool {
            if directPresentationMatches(old, new) { return true }
            guard directBodyCacheGateEnabled,
                  old.revision.message.message.role == "user",
                  old.id == new.id, old.width == new.width,
                  old.typeKey == new.typeKey, old.dark == new.dark,
                  old.wrapsCode == new.wrapsCode,
                  old.promptFill == new.promptFill,
                  old.promptForeground == new.promptForeground,
                  old.promptBorder == new.promptBorder else { return false }
            let a = old.revision, b = new.revision
            return a.message == b.message
                && a.outgoingInsertionEvent == b.outgoingInsertionEvent
                && (a.outgoingInsertionEvent == nil || a.allowsOutgoingMotion == b.allowsOutgoingMotion)
        }

        func refreshDirectEntryKey(_ index: Int, key: DirectKey) {
            guard let existing = directEntries[index], existing.key != key else { return }
            if directRetainedPresentationMatches(existing.key, key) {
                directEntries[index] = DirectEntry(key: key, row: existing.row)
                logger.debug("event=direct_two_rekey index=\(index, privacy: .public) ignoredField=allowsOutgoingMotion old=\(existing.key.revision.allowsOutgoingMotion, privacy: .public) new=\(key.revision.allowsOutgoingMotion, privacy: .public) insertionEventNil=\(key.revision.outgoingInsertionEvent == nil, privacy: .public) allOtherFieldsEqual=true")
            } else if ProcessInfo.processInfo.arguments.contains("--native-direct-body-cache-gate"),
                      let bodyKey = directBodyKey(key), let body = directBodies[bodyKey],
                      case .assistant = existing.row.content {
                let row = makeDirectAssistantRow(body: body, key: key,
                    thinkingDetail: directExpandedThinking.contains(index)
                        ? directThinkingSnapshots[index]?.detail : nil,
                    toolDetails: directToolSnapshots[index]?.details ?? [:],
                    expandedToolIDs: directExpandedToolIDs[index] ?? [],
                    expandedToolGroup: directExpandedToolGroups.contains(index))
                directEntries[index] = DirectEntry(key: key, row: row)
                directViews[index]?.install(row)
                if measured.contains(index) && !(directStreamConfiguring && index == 119) {
                    applyHeight(row.height, index: index)
                }
                logger.error("event=direct_body_recomposed index=\(index, privacy: .public) oldHeight=\(existing.row.height, privacy: .public) newHeight=\(row.height, privacy: .public)")
            } else {
                logger.error("event=direct_two_key_changed index=\(index, privacy: .public) sourceChanged=\(existing.key.revision.message.message.content != key.revision.message.message.content, privacy: .public) roleChanged=\(existing.key.revision.message.message.role != key.revision.message.message.role, privacy: .public) activityChanged=\(existing.key.revision.reasoningGroups != key.revision.reasoningGroups || existing.key.revision.toolCallGroups != key.revision.toolCallGroups, privacy: .public) widthOld=\(existing.key.width, privacy: .public) widthNew=\(key.width, privacy: .public) typeOld=\(existing.key.typeKey, privacy: .public) typeNew=\(key.typeKey, privacy: .public)")
            }
        }

        func prepareDirectStreamAssistant(key: DirectKey) {
            guard ProcessInfo.processInfo.arguments.contains("--native-direct-body-cache-gate"),
                  input?.ids.count == 122, key.revision.message.message.role == "assistant",
                  let source = key.revision.message.message.content,
                  key.revision.message.message.attachments?.isEmpty != false,
                  key.revision.localAttachmentPreviews == nil,
                  key.revision.compressionReferenceCard == nil else { return }
            let index = 121
            guard let bodyKey = directBodyKey(key) else { return }
            if let body = directBodies[bodyKey] {
                if directEntries[index]?.key != key {
                    directTasks[index]?.cancel()
                    directTasks[index] = nil
                    directStreamRequestedBodyKey = nil
                    let row = makeDirectAssistantRow(body: body, key: key)
                    directEntries[index] = DirectEntry(key: key, row: row)
                    directViews[index]?.install(row)
                    if measured.contains(index) { applyHeight(row.height, index: index) }
                    logger.error("event=direct_stream_cached index=121 height=\(row.height, privacy: .public)")
                }
                return
            }
            if directStreamFailedBodyKey == bodyKey { return }
            if directStreamRequestedBodyKey == bodyKey {
                if let previous = directEntries[index], previous.key != key {
                    directEntries[index] = DirectEntry(key: key, row: previous.row)
                }
                return
            }
            directTasks[index]?.cancel()
            directTasks[index] = nil
            directStreamRequestedBodyKey = bodyKey
            if let previous = directEntries[index] {
                // The last complete native snapshot remains visible until the
                // observed new bytes have an off-main prepared replacement.
                directEntries[index] = DirectEntry(key: key, row: previous.row)
            } else {
                let message = key.revision.message.message
                let pending = NativeDirectPreparedRow(height: 44,
                    rowIdentifier: ChatMessageAccessibility.rowIdentifier(
                        messageID: message.messageId, renderID: key.revision.message.renderID),
                    rowLabel: "Assistant response is preparing",
                    content: .pendingAssistant(status: "Preparing response"))
                directEntries[index] = DirectEntry(key: key, row: pending)
                logger.error("event=direct_stream_pending index=121")
            }
            let started = CACurrentMediaTime()
            directTasks[index] = Task { [weak self] in
                let result = await NativeRichRowPreparationActor.shared.prepare(
                    source: source, width: key.width - 48, dark: key.dark,
                    wrapsCodeLines: key.wrapsCode)
                guard let self, !Task.isCancelled,
                      self.directStreamRequestedBodyKey == bodyKey else { return }
                self.directTasks[index] = nil
                self.directStreamRequestedBodyKey = nil
                guard let input = self.input, input.ids.count == 122,
                      let currentKey = input.ids.indices.contains(index)
                        ? Optional(self.directKey(at: index, input: input)) : nil,
                      self.directBodyKey(currentKey) == bodyKey,
                      case .ready(let body) = result,
                      body.sourceBytes == bodyKey.sourceBytes,
                      body.dark == bodyKey.dark,
                      body.wrapsCodeLines == bodyKey.wrapsCode else {
                    self.directStreamFailedBodyKey = bodyKey
                    if let previous = self.directEntries[index],
                       case .pendingAssistant = previous.row.content {
                        let failed = NativeDirectPreparedRow(height: previous.row.height,
                            rowIdentifier: previous.row.rowIdentifier,
                            rowLabel: "Assistant response preparation failed",
                            content: .pendingAssistant(status: "Response unavailable"))
                        self.directEntries[index] = DirectEntry(key: previous.key, row: failed)
                        self.directViews[index]?.install(failed)
                    }
                    self.logger.error("event=direct_stream_prepare_failed index=121")
                    return
                }
                let row = self.makeDirectAssistantRow(body: body, key: currentKey)
                self.directEntries[index] = DirectEntry(key: currentKey, row: row)
                self.directViews[index]?.install(row)
                let oldBottomDistance = self.bottomOffset - self.scroll.contentOffset.y
                if self.measured.contains(index) { self.applyHeight(row.height, index: index) }
                self.layoutRows()
                self.logger.error("event=direct_stream_native_ready index=121 prepMs=\(Int((CACurrentMediaTime() - started) * 1_000), privacy: .public) height=\(row.height, privacy: .public) oldBottomDistance=\(oldBottomDistance, privacy: .public) newBottomDistance=\(self.bottomOffset - self.scroll.contentOffset.y, privacy: .public)")
            }
        }

        func prepareDirectTwoRowsIfNeeded() {
            let all120 = ProcessInfo.processInfo.arguments.contains("--native-direct-all120-diagnostic")
            let firstWindow = ProcessInfo.processInfo.arguments.contains("--native-direct-premount-window-gate")
            let flight10k = ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic")
            let windowed10k = strictDirect10kGate
                || ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic") || flight10k
            guard (all120 || firstWindow || windowed10k || ProcessInfo.processInfo.arguments.contains("--native-direct-two-row-proof")),
                  let input,
                  input.ids.count == (windowed10k ? 10_000 : 120)
                    || (all120 && ProcessInfo.processInfo.arguments.contains("--native-direct-body-cache-gate")
                        && input.ids.count == 122), width > 80 else { return }
            if all120 && directAllStartedAt == nil {
                directAllStartedAt = CACurrentMediaTime()
                logger.debug("event=direct_all_prepare_started memoryMB=\(self.footprintMB(), privacy: .public)")
            }
            let indices: [Int]
            if flight10k {
                indices = [input.ids.count - 1]
            } else if windowed10k {
                indices = requestedDirect10kIndices.isEmpty
                    ? [0, 1, 2, 3, input.ids.count - 1] : requestedDirect10kIndices
            } else if all120 && ProcessInfo.processInfo.arguments.contains("--native-direct-target-first-immediate-diagnostic") {
                // DEBUG causal control: prepare the exact jump target before
                // the background history queue; no fixture height is assumed.
                indices = [0, 1, 2, 3, 119] + Array(4..<119)
                    + (input.ids.count == 122 ? [120, 121] : [])
            } else {
                indices = all120 ? Array(0..<min(ProcessInfo.processInfo.arguments.contains("--native-direct-body-cache-gate")
                    ? 122 : 120, input.ids.count))
                                 : firstWindow ? [0, 1, 2, 3] : [118, 119]
            }
            for index in indices {
                if windowed10k && directTasks.count >= 24 { break }
                let key = directKey(at: index, input: input)
                if all120 && input.ids.count == 122 && index == 121 {
                    prepareDirectStreamAssistant(key: key)
                    continue
                }
                refreshDirectEntryKey(index, key: key)
                guard directEntries[index]?.key != key, directTasks[index] == nil,
                      !directFailed.contains(index) else { continue }
                guard hosts[index] == nil, directViews[index] == nil else {
                    directFailed.insert(index)
                    logger.error("event=direct_two_late_host index=\(index, privacy: .public)")
                    reportDirectAllPreparationIfFinished()
                    continue
                }
                let message = key.revision.message.message
                guard message.attachments?.isEmpty != false,
                      key.revision.localAttachmentPreviews == nil,
                      key.revision.compressionReferenceCard == nil,
                      (!key.revision.hasActiveStream ||
                       (all120 && input.ids.count == 122 && index == 120)),
                      !key.revision.isViewingCachedData else {
                    directFailed.insert(index)
                    logger.error("event=direct_two_unsupported_presentation index=\(index, privacy: .public)")
                    reportDirectAllPreparationIfFinished()
                    continue
                }
                if index.isMultiple(of: 2) {
                    guard message.role == "user", let source = message.content, !source.isEmpty,
                          key.revision.reasoningGroups.isEmpty, key.revision.toolCallGroups.isEmpty else {
                        directFailed.insert(index)
                        logger.error("event=direct_two_unsupported_outgoing")
                        reportDirectAllPreparationIfFinished()
                        continue
                    }
                    let font = UIFont.preferredFont(forTextStyle: .body)
                    let lineHeight = ceil(font.lineHeight * UIScreen.main.scale) / UIScreen.main.scale
                    let textWidth = min(width - 60, ceil((source as NSString).size(withAttributes: [.font: font]).width * UIScreen.main.scale) / UIScreen.main.scale)
                    let bubbleWidth = textWidth + 28
                    let bubble = CGRect(x: width - bubbleWidth, y: 2, width: bubbleWidth, height: lineHeight + 16)
                    let textFrame = CGRect(x: bubble.minX + 14, y: 10, width: textWidth, height: lineHeight)
                    let row = NativeDirectPreparedRow(height: lineHeight + 20,
                        rowIdentifier: ChatMessageAccessibility.rowIdentifier(messageID: message.messageId, renderID: key.revision.message.renderID),
                        rowLabel: ChatMessageAccessibility.rowLabel(role: message.role, content: message.content,
                            visibleContent: key.revision.message.attachmentDisplayContent, attachmentCount: 0),
                        content: .outgoing(text: source, textFrame: textFrame, bubbleFrame: bubble,
                            fillHex: key.promptFill, foregroundHex: key.promptForeground, borderHex: key.promptBorder))
                    directEntries[index] = DirectEntry(key: key, row: row)
                    logger.debug("event=direct_two_ready index=\(index, privacy: .public) height=\(row.height, privacy: .public)")
                    reportDirectAllPreparationIfFinished()
                } else {
                    guard message.role == "assistant", let source = message.content,
                          key.revision.reasoningGroups.count <= 1,
                          key.revision.toolCallGroups.count <= 1,
                          key.revision.liveReasoningText.isEmpty,
                          key.revision.liveToolCalls.isEmpty,
                          !UserDefaults.standard.bool(forKey: ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey),
                          !UserDefaults.standard.bool(forKey: ChatTranscriptDisplaySettings.toolCardsStartExpandedKey) else {
                        directFailed.insert(index)
                        logger.error("event=direct_two_unsupported_assistant")
                        reportDirectAllPreparationIfFinished()
                        continue
                    }
                    if (all120 || firstWindow || windowed10k) && index == 1
                        && ProcessInfo.processInfo.arguments.contains("--native-direct-premount-rich-one") {
                        guard let prepared = NativePremountRichFixtureStore.entry,
                              prepared.messageID == message.messageId,
                              prepared.source == source,
                              abs(prepared.bodyWidth - (key.width - 48)) < 0.5,
                              let body = prepared.snapshot(dark: key.dark, wrapsCodeLines: key.wrapsCode),
                              body.sourceBytes == Array(source.utf8) else {
                            directFailed.insert(index)
                            logger.error("event=premount_rich_handoff_mismatch index=\(index, privacy: .public) width=\(key.width - 48, privacy: .public)")
                            reportDirectAllPreparationIfFinished()
                            continue
                        }
                        guard body.wrapsCodeLines == key.wrapsCode else {
                            directFailed.insert(index)
                            logger.error("event=premount_rich_wrap_mismatch")
                            reportDirectAllPreparationIfFinished()
                            continue
                        }
                        if let reasoning = key.revision.reasoningGroups.first {
                            guard case .ready(let detail) = NativeBasicFirstRowPreparation.prepare(
                                source: reasoning.text, width: key.width - 48,
                                dark: key.dark, wrapsCodeLines: key.wrapsCode),
                                  detail.sourceBytes == Array(reasoning.text.utf8) else {
                                directFailed.insert(index)
                                logger.error("event=premount_rich_reasoning_unsupported")
                                reportDirectAllPreparationIfFinished()
                                continue
                            }
                            directThinkingSnapshots[index] = (key, detail)
                        }
                        if ProcessInfo.processInfo.arguments.contains("--native-direct-two-tool-first-fixture") {
                            guard let group = key.revision.toolCallGroups.first,
                                  group.toolCalls.count == 2 else {
                                directFailed.insert(index)
                                logger.error("event=premount_rich_tool_shape_failed")
                                reportDirectAllPreparationIfFinished()
                                continue
                            }
                            var details: [String: NativeRichRowSnapshot] = [:]
                            var supported = true
                            for call in group.toolCalls {
                                let detailSource = directToolDetailSource(call)
                                guard case .ready(let detail) = NativeBasicFirstRowPreparation.prepare(
                                    source: detailSource, width: key.width - 48,
                                    dark: key.dark, wrapsCodeLines: key.wrapsCode, asLiteral: true),
                                      detail.sourceBytes == Array(detailSource.utf8) else {
                                    supported = false
                                    break
                                }
                                details[call.id] = detail
                            }
                            guard supported, details.count == 2 else {
                                directFailed.insert(index)
                                logger.error("event=premount_rich_tool_prepare_failed")
                                reportDirectAllPreparationIfFinished()
                                continue
                            }
                            directToolSnapshots[index] = (key, details)
                        }
                        directEntries[index] = DirectEntry(key: key,
                            row: makeDirectAssistantRow(body: body, key: key,
                                toolDetails: directToolSnapshots[index]?.details ?? [:]))
                        logger.debug("event=premount_rich_handoff_ready index=\(index, privacy: .public) height=\(self.directEntries[index]!.row.height, privacy: .public) width=\(body.width, privacy: .public)")
                        reportDirectAllPreparationIfFinished()
                        continue
                    }
                    if (all120 || windowed10k)
                       && (index == input.ids.count - 1 || ProcessInfo.processInfo.arguments.contains("--native-direct-bounded-path-immediate-diagnostic") || windowed10k),
                       (ProcessInfo.processInfo.arguments.contains("--native-direct-target-first-immediate-diagnostic") || windowed10k),
                       let prepared = index == input.ids.count - 1 ? NativePremountRichFixtureStore.target
                                                   : NativePremountRichFixtureStore.path[index] {
                        guard
                              prepared.messageID == message.messageId,
                              prepared.source == source,
                              abs(prepared.bodyWidth - (key.width - 48)) < 0.5,
                              let body = prepared.snapshot(dark: key.dark, wrapsCodeLines: key.wrapsCode),
                              body.sourceBytes == Array(source.utf8) else {
                            directFailed.insert(index)
                            logger.error("event=premount_rich_path_handoff_mismatch index=\(index, privacy: .public)")
                            reportDirectAllPreparationIfFinished()
                            continue
                        }
                        directEntries[index] = DirectEntry(key: key,
                            row: makeDirectAssistantRow(body: body, key: key))
                        logger.debug("event=premount_rich_path_handoff_ready index=\(index, privacy: .public) height=\(self.directEntries[index]!.row.height, privacy: .public)")
                        reportDirectAllPreparationIfFinished()
                        continue
                    }
                    if (all120 || firstWindow) && [1, 3].contains(index)
                        && ProcessInfo.processInfo.arguments.contains("--native-direct-first-visible-basic") {
                        let started = CACurrentMediaTime()
                        let result = NativeBasicFirstRowPreparation.prepare(
                            source: source, width: key.width - 48, dark: key.dark,
                            wrapsCodeLines: key.wrapsCode)
                        let alternate = NativeBasicFirstRowPreparation.prepare(
                            source: source, width: key.width - 48, dark: key.dark,
                            wrapsCodeLines: !key.wrapsCode)
                        guard case .ready(let body) = result,
                              case .ready(let otherBody) = alternate,
                              body.sourceBytes == Array(source.utf8),
                              otherBody.sourceBytes == body.sourceBytes else {
                            directFailed.insert(index)
                            logger.error("event=direct_first_basic_failed index=\(index, privacy: .public)")
                            reportDirectAllPreparationIfFinished()
                            continue
                        }
                        // One early-row interaction proof only. Prepare the
                        // canonical Thinking source before its first mount so
                        // disclosure never invokes a legacy host fit.
                        if index == 1, let reasoning = key.revision.reasoningGroups.first {
                            guard case .ready(let detail) = NativeBasicFirstRowPreparation.prepare(
                                source: reasoning.text, width: key.width - 48,
                                dark: key.dark, wrapsCodeLines: key.wrapsCode),
                                  detail.sourceBytes == Array(reasoning.text.utf8) else {
                                directFailed.insert(index)
                                logger.error("event=direct_thinking_prepare_failed index=\(index, privacy: .public)")
                                reportDirectAllPreparationIfFinished()
                                continue
                            }
                            directThinkingSnapshots[index] = (key, detail)
                            logger.debug("event=direct_thinking_prepared index=\(index, privacy: .public) height=\(detail.height, privacy: .public) prepMs=\(Int(detail.preparationMS), privacy: .public)")
                        }
                        if index == 1,
                           ProcessInfo.processInfo.arguments.contains("--native-direct-two-tool-first-fixture") {
                            guard let group = key.revision.toolCallGroups.first,
                                  group.toolCalls.count == 2 else {
                                directFailed.insert(index)
                                logger.error("event=direct_tool_fixture_shape_failed")
                                reportDirectAllPreparationIfFinished()
                                continue
                            }
                            var details: [String: NativeRichRowSnapshot] = [:]
                            var supported = true
                            for call in group.toolCalls {
                                let source = directToolDetailSource(call)
                                guard case .ready(let detail) = NativeBasicFirstRowPreparation.prepare(
                                    source: source, width: key.width - 48, dark: key.dark,
                                    wrapsCodeLines: key.wrapsCode, asLiteral: true),
                                      detail.sourceBytes == Array(source.utf8) else {
                                    supported = false
                                    break
                                }
                                details[call.id] = detail
                            }
                            guard supported, details.count == 2 else {
                                directFailed.insert(index)
                                logger.error("event=direct_tool_prepare_failed index=\(index, privacy: .public)")
                                reportDirectAllPreparationIfFinished()
                                continue
                            }
                            directToolSnapshots[index] = (key, details)
                            logger.debug("event=direct_tool_prepared index=\(index, privacy: .public) actions=\(details.count, privacy: .public)")
                        }
                        let row = makeDirectAssistantRow(body: body, key: key,
                            toolDetails: directToolSnapshots[index]?.details ?? [:])
                        directEntries[index] = DirectEntry(key: key, row: row)
                        directAlternates[index] = makeDirectAssistantRow(body: otherBody, key: key,
                            toolDetails: directToolSnapshots[index]?.details ?? [:])
                        logger.debug("event=direct_first_basic_ready index=\(index, privacy: .public) height=\(row.height, privacy: .public) mainPrepMs=\(Int((CACurrentMediaTime() - started) * 1_000), privacy: .public) bodyPrepMs=\(Int(body.preparationMS), privacy: .public)")
                        reportDirectAllPreparationIfFinished()
                        continue
                    }
                    let scheduledAt = CACurrentMediaTime()
                    directTasks[index] = Task { [weak self] in
                        let result = await NativeRichRowPreparationActor.shared.prepare(
                            source: source, width: key.width - 48, dark: key.dark, wrapsCodeLines: key.wrapsCode)
                        let alternate = windowed10k ? result : await NativeRichRowPreparationActor.shared.prepare(
                            source: source, width: key.width - 48, dark: key.dark, wrapsCodeLines: !key.wrapsCode)
                        guard let self else { return }
                        self.directTasks[index] = nil
                        if windowed10k && Task.isCancelled { return }
                        guard !Task.isCancelled, self.input?.ids.indices.contains(index) == true,
                              self.directKey(at: index, input: self.input!) == key,
                              self.hosts[index] == nil, self.directViews[index] == nil,
                              case .ready(let body) = result, case .ready(let otherBody) = alternate,
                              body.sourceBytes == Array(source.utf8), otherBody.sourceBytes == body.sourceBytes else {
                            self.directFailed.insert(index)
                            self.logger.error("event=direct_two_prepare_failed index=\(index, privacy: .public)")
                            self.reportDirectAllPreparationIfFinished()
                            return
                        }
                        let row = self.makeDirectAssistantRow(body: body, key: key)
                        let other = self.makeDirectAssistantRow(body: otherBody, key: key)
                        self.directEntries[index] = DirectEntry(key: key, row: row)
                        if !windowed10k { self.directAlternates[index] = other }
                        self.logger.debug("event=direct_two_ready index=\(index, privacy: .public) height=\(row.height, privacy: .public) prepWallMs=\(Int((CACurrentMediaTime() - scheduledAt) * 1_000), privacy: .public)")
                        self.reportDirectAllPreparationIfFinished()
                    }
                }
            }
        }

        /// DEBUG-only bounded scheduling proof. Predict the next few visible
        /// windows from the same viewport geometry that drives the jump; never
        /// enumerate or prepare the 10k history. A miss remains a logged legacy
        /// fit so this diagnostic cannot silently report a green frame.
        func stageDirect10kWindows(elapsed: CFTimeInterval) {
            guard (strictDirect10kGate
                   || ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic")),
                  let input, input.ids.count == 10_000, width > 80 else { return }
            var requested: [Int] = [input.ids.count - 1]
            var seen = Set(requested)
            for lead in [0.0, 0.035, 0.070, 0.105] {
                let progress = min(1, max(0, (elapsed + lead) / 0.55))
                let eased = progress * progress * (3 - 2 * progress)
                let y = direct10kJumpStartOffset + (bottomOffset - direct10kJumpStartOffset) * eased
                let first = row(at: max(0, y - 80))
                let last = row(at: y + scroll.bounds.height + 80)
                for index in first...min(last, first + 11) where seen.insert(index).inserted {
                    requested.append(index)
                }
            }
            requestedDirect10kIndices = requested
            let keep = Set(requested).union(directViews.keys)
            for index in Array(directTasks.keys) where !keep.contains(index) {
                directTasks[index]?.cancel()
                directTasks.removeValue(forKey: index)
            }
            for index in Array(directEntries.keys) where directEntries.count > 64 && !keep.contains(index) {
                directEntries.removeValue(forKey: index)
                directAlternates.removeValue(forKey: index)
                directThinkingSnapshots.removeValue(forKey: index)
                directToolSnapshots.removeValue(forKey: index)
            }
            direct10kPeakEntries = max(direct10kPeakEntries, directEntries.count)
            logger.debug("event=direct_10k_stage elapsedMs=\(Int(elapsed * 1_000), privacy: .public) requested=\(requested.count, privacy: .public) ready=\(self.directEntries.count, privacy: .public) tasks=\(self.directTasks.count, privacy: .public) memoryMB=\(Int(self.footprintMB()), privacy: .public)")
            prepareDirectTwoRowsIfNeeded()
        }

        func flightPreview(_ index: Int) -> UIView {
            if let existing = flightProxies[index] { return existing }
            let message = input!.revisionAt(index).message.message
            let source = message.content ?? ""
            let firstReadable = source.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("|") && !$0.hasPrefix("---") } ?? "Code response"
            let clean = firstReadable.replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let container = UIView()
            container.backgroundColor = message.role == "user" ? UIColor.secondarySystemBackground : .clear
            container.layer.cornerRadius = message.role == "user" ? 14 : 0
            let label = UILabel()
            label.font = UIFont.systemFont(ofSize: 15, weight: .regular)
            label.textColor = .label
            label.numberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.text = clean
            label.frame = CGRect(x: 12, y: 3, width: max(1, width - 24), height: 60)
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(label)
            container.accessibilityLabel = "Scrolling preview: \(clean)"
            scroll.addSubview(container)
            flightProxies[index] = container
            flightProxyMounts += 1
            return container
        }

        func reportDirectAllPreparationIfFinished() {
            guard ProcessInfo.processInfo.arguments.contains("--native-direct-all120-diagnostic"),
                  !directAllReported, let started = directAllStartedAt,
                  directEntries.count + directFailed.count >= 120 else { return }
            directAllReported = true
            logger.debug("event=direct_all_prepare_complete ready=\(self.directEntries.count, privacy: .public) fallback=\(self.directFailed.count, privacy: .public) wallMs=\(Int((CACurrentMediaTime() - started) * 1_000), privacy: .public) memoryMB=\(self.footprintMB(), privacy: .public)")
        }

        func stageDirectWindowPresentation(_ next: ChatStableViewportPrototype,
                                           id: String, source: String) {
            guard pendingDirectPresentation != next.typeKey else { return }
            pendingDirectPresentationTask?.cancel()
            pendingDirectPresentation = next.typeKey
            let expectedWidth = width - 48
            let started = CACurrentMediaTime()
            logger.debug("event=direct_window_presentation_stage key=\(next.typeKey, privacy: .public)")
            pendingDirectPresentationTask = Task { [weak self] in
                let result = await NativeRichRowPreparationActor.shared.prepare(
                    source: source, width: expectedWidth, dark: next.nativeRichDark,
                    wrapsCodeLines: next.nativeRichWrapsCodeLines)
                guard let self, !Task.isCancelled,
                      self.pendingDirectPresentation == next.typeKey,
                      self.input?.ids == next.ids,
                      self.input?.revision == next.revision,
                      abs(self.width - 48 - expectedWidth) < 0.5 else { return }
                guard case .ready(let body) = result,
                      body.sourceBytes == Array(source.utf8),
                      abs(body.width - expectedWidth) < 0.5,
                      body.dark == next.nativeRichDark,
                      body.wrapsCodeLines == next.nativeRichWrapsCodeLines else {
                    self.logger.error("event=direct_window_presentation_unsupported")
                    self.pendingDirectPresentation = nil
                    self.pendingDirectPresentationTask = nil
                    return
                }
                NativePremountRichFixtureStore.entry = .init(
                    messageID: id, source: source, bodyWidth: expectedWidth, snapshot: body)
                self.pendingDirectPresentation = nil
                self.pendingDirectPresentationTask = nil
                self.logger.debug("event=direct_window_presentation_ready durationMs=\(Int((CACurrentMediaTime() - started) * 1_000), privacy: .public)")
                self.configure(next)
            }
        }

        func stageDirectWindowWidth(_ nextWidth: CGFloat) {
            guard ProcessInfo.processInfo.arguments.contains("--native-direct-premount-window-gate"),
                  pendingDirectWidth != nextWidth, failedDirectWidth != nextWidth,
                  let input, input.ids.count == 120, input.ids.indices.contains(3),
                  let source = input.revisionAt(1).message.message.content,
                  let id = input.revisionAt(1).message.message.messageId,
                  nextWidth > 80 else { return }
            pendingDirectWidthTask?.cancel()
            pendingDirectWidth = nextWidth
            let started = CACurrentMediaTime()
            logger.debug("event=direct_window_width_stage old=\(self.width, privacy: .public) new=\(nextWidth, privacy: .public)")
            pendingDirectWidthTask = Task { [weak self] in
                let dark = input.nativeRichDark
                let wraps = input.nativeRichWrapsCodeLines
                let result = await NativeRichRowPreparationActor.shared.prepare(
                    source: source, width: nextWidth - 48,
                    dark: dark, wrapsCodeLines: wraps)
                guard case .ready(let body) = result,
                      body.sourceBytes == Array(source.utf8),
                      abs(body.width - (nextWidth - 48)) < 0.5,
                      body.dark == dark, body.wrapsCodeLines == wraps else {
                    self?.failedDirectWidth = nextWidth
                    self?.pendingDirectWidth = nil
                    self?.pendingDirectWidthTask = nil
                    self?.logger.error("event=direct_window_width_unsupported")
                    return
                }
                guard let self, !Task.isCancelled, self.pendingDirectWidth == nextWidth,
                      abs(max(1, self.view.bounds.width - 32) - nextWidth) < 0.5,
                      self.input?.ids.indices.contains(3) == true,
                      self.input?.revisionAt(1).message.message.messageId == id,
                      self.input?.revisionAt(1).message.message.content == source else { return }
                guard case .ready = NativeBasicFirstRowPreparation.prepare(
                    source: self.input!.revisionAt(3).message.message.content ?? "",
                    width: nextWidth - 48, dark: dark, wrapsCodeLines: wraps),
                    self.input!.revisionAt(0).message.message.role == "user",
                    self.input!.revisionAt(2).message.message.role == "user" else {
                    self.failedDirectWidth = nextWidth
                    self.pendingDirectWidth = nil
                    self.pendingDirectWidthTask = nil
                    self.logger.error("event=direct_window_width_visible_unsupported")
                    return
                }
                let anchor = self.row(at: max(0, self.scroll.contentOffset.y))
                let local = self.scroll.contentOffset.y - self.positions[anchor]
                let oldHeight = self.heights[1]
                NativePremountRichFixtureStore.entry = .init(
                    messageID: id, source: source, bodyWidth: nextWidth - 48,
                    snapshot: body)
                self.width = nextWidth
                self.directEntries.removeAll()
                self.directAlternates.removeAll()
                self.directThinkingSnapshots.removeAll()
                self.directFailed.subtract([0, 1, 2, 3])
                self.resetRows()
                self.prepareDirectTwoRowsIfNeeded()
                for index in 0...3 { self.measure(index) }
                self.scroll.contentOffset.y = min(self.bottomOffset,
                    max(0, self.positions[anchor] + local))
                self.layoutRows()
                let newHeight = self.heights[1]
                self.pendingDirectWidth = nil
                self.pendingDirectWidthTask = nil
                self.logger.debug("event=direct_window_width_commit old=\(oldHeight, privacy: .public) new=\(newHeight, privacy: .public) durationMs=\(Int((CACurrentMediaTime() - started) * 1_000), privacy: .public) anchor=\(anchor, privacy: .public) local=\(local, privacy: .public) fallback=\(self.directFailed.count, privacy: .public)")
            }
        }

        func directToolDetailSource(_ call: ToolCall) -> String {
            let display = ToolCallDisplayFormatter.content(for: call)
            var sections: [String] = []
            if !display.argumentRows.isEmpty {
                sections.append("Arguments\n" + display.argumentRows.map {
                    "\($0.key): \($0.value)"
                }.joined(separator: "\n"))
            }
            if let result = display.result {
                sections.append("\(result.title)\n\(result.text)")
            }
            if sections.isEmpty {
                sections.append(ToolCallStatusDisplay(toolCall: call).detailText)
            }
            return sections.joined(separator: "\n\n")
        }

        func makeDirectAssistantRow(body: NativeRichRowSnapshot, key: DirectKey,
                                    thinkingDetail: NativeRichRowSnapshot? = nil,
                                    toolDetails: [String: NativeRichRowSnapshot] = [:],
                                    expandedToolIDs: Set<String> = [],
                                    expandedToolGroup: Bool = false) -> NativeDirectPreparedRow {
            if ProcessInfo.processInfo.arguments.contains("--native-direct-body-cache-gate"),
               let bodyKey = directBodyKey(key, wrapsCode: body.wrapsCodeLines),
               body.sourceBytes == bodyKey.sourceBytes,
               abs(body.width - bodyKey.width) < 0.5,
               body.dark == bodyKey.dark {
                directBodies[bodyKey] = body
            }
            let revision = key.revision
            let message = revision.message.message
            let thinking = revision.showsThinkingAndToolCards && !revision.reasoningGroups.isEmpty
            let toolCalls = revision.showsThinkingAndToolCards
                ? (revision.toolCallGroups.first?.toolCalls ?? []) : []
            let detailFrame = thinkingDetail.map { detail in
                CGRect(x: 12, y: 48, width: body.width, height: detail.height)
            }
            let detailExtra = detailFrame.map { $0.height + 8 } ?? 0
            var headerHeight = CGFloat(thinking ? 1 : 0) * 48 + detailExtra
            var actions: [NativeDirectPreparedRow.ToolAction] = []
            let grouped = ProcessInfo.processInfo.arguments.contains("--native-direct-parity-gate")
                && toolCalls.count > 1
            if grouped, let group = revision.toolCallGroups.first {
                actions.append(.init(id: "__native_group__",
                    title: ToolActivityGroupPresentation.title(for: group),
                    symbol: ToolActivityGroupPresentation.icon(for: group),
                    accessibilityStatus: ToolActivityGroupPresentation.status(for: group) ?? "",
                    headerFrame: CGRect(x: 0, y: headerHeight, width: key.width, height: 44),
                    isExpanded: expandedToolGroup, detail: nil, detailFrame: nil))
                headerHeight += 48
            }
            for call in grouped && !expandedToolGroup ? [] : toolCalls {
                let expandedDetail = expandedToolIDs.contains(call.id) ? toolDetails[call.id] : nil
                let leading: CGFloat = grouped ? 28 : 0
                let headerFrame = CGRect(x: leading, y: headerHeight,
                                         width: key.width - leading, height: 44)
                let toolDetailFrame = expandedDetail.map { detail in
                    CGRect(x: 12, y: headerHeight + 48,
                           width: detail.width, height: detail.height)
                }
                actions.append(.init(id: call.id,
                    title: ToolCallPresentationLabel.title(for: call),
                    symbol: call.isError == true ? "exclamationmark.triangle.fill"
                        : ToolCallPresentationLabel.icon(for: call.name),
                    accessibilityStatus: ToolCallStatusDisplay(toolCall: call).detailText,
                    headerFrame: headerFrame, isExpanded: expandedDetail != nil,
                    detail: expandedDetail,
                    detailFrame: toolDetailFrame))
                headerHeight += 48 + (toolDetailFrame.map { $0.height + 8 } ?? 0)
            }
            let previewURL = TranscriptLinkPreviewEligibility.previewURL(
                for: message, isStreaming: revision.hasActiveStream)
            let previewExtra: CGFloat = previewURL == nil ? 0 : 90
            let bubble = CGRect(x: 0, y: headerHeight + 2, width: key.width - 24,
                                height: body.height + 24 + previewExtra)
            let canvas = CGRect(x: 12, y: bubble.minY + 12, width: body.width, height: body.height)
            let preview = previewURL.map { NativeDirectPreparedRow.LinkPreview(url: $0,
                frame: CGRect(x: 12, y: canvas.maxY + 6,
                              width: min(300, body.width), height: 84)) }
            let showsCopy = revision.latestCompletedAssistantRenderID == revision.message.renderID
            let copy = showsCopy ? CGRect(x: 2, y: headerHeight + body.height + previewExtra + 30,
                                           width: 90, height: 44) : nil
            return NativeDirectPreparedRow(height: ceil(headerHeight + body.height + previewExtra + 28
                                                        + (showsCopy ? 46 : 0)),
                rowIdentifier: ChatMessageAccessibility.rowIdentifier(messageID: message.messageId, renderID: revision.message.renderID),
                rowLabel: ChatMessageAccessibility.rowLabel(role: message.role, content: message.content,
                    visibleContent: revision.message.attachmentDisplayContent, attachmentCount: 0),
                content: .assistant(body: body, canvasFrame: canvas, bubbleFrame: bubble,
                    thinkingTitle: thinking ? "Thinking" : nil,
                    thinkingDetail: thinkingDetail, thinkingDetailFrame: detailFrame,
                    toolActions: actions, linkPreview: preview, copyFrame: copy))
        }

        func ensureDirectView(_ index: Int, row: NativeDirectPreparedRow) -> NativeDirectTranscriptRowView {
            if let view = directViews[index] { return view }
            let view = NativeDirectTranscriptRowView(frame: CGRect(x: 16, y: positions[index],
                                                             width: width, height: row.height))
            view.hostingParent = self
            view.onSelectText = { [weak self] in self?.input?.onDirectSelectText(index) }
            view.onCopyResponse = { [weak self] in self?.input?.onDirectCopy(index) }
            view.onOpenLink = { [weak self] url in self?.input?.onDirectOpenURL(url) }
            view.onToggleCodeWrap = { [weak self] in
                guard let self, let input = self.input else { return }
                UserDefaults.standard.set(!input.nativeRichWrapsCodeLines,
                    forKey: ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey)
            }
            view.onUnsupportedDisclosure = { [weak self] title in
                guard let self else { return }
                if title == "Thinking", self.toggleDirectThinking(at: index) { return }
                self.fallbackDirectDisclosure(at: index, title: title)
            }
            view.onToggleTool = { [weak self] toolID in
                guard let self else { return }
                if toolID == "__native_group__", self.toggleDirectToolGroup(at: index) { return }
                if self.toggleDirectTool(at: index, toolID: toolID) { return }
                self.fallbackDirectDisclosure(at: index, title: "Tool")
            }
            view.install(row)
            scroll.addSubview(view)
            directViews[index] = view
            if link != nil { directMountedDuringJump += 1 }
            logger.debug("event=direct_two_mounted index=\(index, privacy: .public) height=\(row.height, privacy: .public) jumping=\(self.link != nil, privacy: .public)")
            return view
        }

        func toggleDirectThinking(at index: Int) -> Bool {
            let started = CACurrentMediaTime()
            guard let input, input.ids.indices.contains(index),
                  let prepared = directThinkingSnapshots[index],
                  let current = directEntries[index],
                  directPresentationMatches(prepared.key, directKey(at: index, input: input)),
                  directPresentationMatches(current.key, directKey(at: index, input: input)),
                  case .assistant(let body, _, _, _, _, _, _, _, _) = current.row.content,
                  let view = directViews[index] else { return false }
            let expands = !directExpandedThinking.contains(index)
            let next = makeDirectAssistantRow(body: body, key: current.key,
                thinkingDetail: expands ? prepared.detail : nil,
                toolDetails: directToolSnapshots[index]?.details ?? [:],
                expandedToolIDs: directExpandedToolIDs[index] ?? [],
                expandedToolGroup: directExpandedToolGroups.contains(index))
            let oldHeight = heights[index]
            if expands { directExpandedThinking.insert(index) }
            else { directExpandedThinking.remove(index) }
            directEntries[index] = DirectEntry(key: current.key, row: next)
            view.install(next)
            applyHeight(next.height, index: index)
            layoutRows()
            logger.debug("event=direct_thinking_toggle index=\(index, privacy: .public) expanded=\(expands, privacy: .public) oldHeight=\(oldHeight, privacy: .public) newHeight=\(next.height, privacy: .public) tapWorkMs=\(Int((CACurrentMediaTime() - started) * 1_000), privacy: .public) legacyFit=false")
            return true
        }

        func toggleDirectTool(at index: Int, toolID: String) -> Bool {
            let started = CACurrentMediaTime()
            guard let input, input.ids.indices.contains(index),
                  let prepared = directToolSnapshots[index],
                  let detail = prepared.details[toolID], !detail.blocks.isEmpty,
                  let current = directEntries[index],
                  directPresentationMatches(prepared.key, directKey(at: index, input: input)),
                  directPresentationMatches(current.key, directKey(at: index, input: input)),
                  case .assistant(let body, _, _, _, _, _, _, _, _) = current.row.content,
                  let view = directViews[index] else { return false }
            var expanded = directExpandedToolIDs[index] ?? []
            let opens = !expanded.contains(toolID)
            if opens { expanded.insert(toolID) }
            else { expanded.remove(toolID) }
            let thinkingDetail = directExpandedThinking.contains(index)
                ? directThinkingSnapshots[index]?.detail : nil
            let next = makeDirectAssistantRow(body: body, key: current.key,
                thinkingDetail: thinkingDetail,
                toolDetails: prepared.details, expandedToolIDs: expanded,
                expandedToolGroup: directExpandedToolGroups.contains(index))
            let oldHeight = heights[index]
            directExpandedToolIDs[index] = expanded
            directEntries[index] = DirectEntry(key: current.key, row: next)
            view.install(next)
            applyHeight(next.height, index: index)
            layoutRows()
            logger.debug("event=direct_tool_toggle index=\(index, privacy: .public) toolID=\(toolID, privacy: .public) expanded=\(opens, privacy: .public) oldHeight=\(oldHeight, privacy: .public) newHeight=\(next.height, privacy: .public) tapWorkMs=\(Int((CACurrentMediaTime() - started) * 1_000), privacy: .public) legacyFit=false")
            return true
        }

        func toggleDirectToolGroup(at index: Int) -> Bool {
            guard let input, input.ids.indices.contains(index),
                  let current = directEntries[index],
                  directPresentationMatches(current.key, directKey(at: index, input: input)),
                  case .assistant(let body, _, _, _, _, _, _, _, _) = current.row.content,
                  let view = directViews[index] else { return false }
            let expands = !directExpandedToolGroups.contains(index)
            if expands { directExpandedToolGroups.insert(index) }
            else { directExpandedToolGroups.remove(index) }
            let next = makeDirectAssistantRow(body: body, key: current.key,
                thinkingDetail: directExpandedThinking.contains(index)
                    ? directThinkingSnapshots[index]?.detail : nil,
                toolDetails: directToolSnapshots[index]?.details ?? [:],
                expandedToolIDs: directExpandedToolIDs[index] ?? [],
                expandedToolGroup: expands)
            directEntries[index] = DirectEntry(key: current.key, row: next)
            view.install(next)
            applyHeight(next.height, index: index)
            layoutRows()
            return true
        }

        func fallbackDirectDisclosure(at index: Int, title: String) {
            guard directViews[index] != nil else { return }
            logger.error("event=direct_two_disclosure_fallback index=\(index, privacy: .public) title=\(title, privacy: .public)")
            directFailed.insert(index)
            directFallbackDisclosure[index] = title
            directViews.removeValue(forKey: index)?.removeFromSuperview()
            measured.remove(index)
            layoutRows()
        }
#endif

        func reconcileCommonPrefix(_ prefix: Int, oldIDs: [String]) {
            guard let input else { return }
            for index in prefix..<oldIDs.count {
                if let host = hosts.removeValue(forKey: index) { remove(host) }
                hostRevisions.removeValue(forKey: index)
                codeViewports.removeValue(forKey: index)
                measured.remove(index)
                indicesByID.removeValue(forKey: oldIDs[index])
#if DEBUG
                directViews.removeValue(forKey: index)?.removeFromSuperview()
#endif
            }
            heights.removeSubrange(prefix..<heights.count)
            for index in prefix..<input.ids.count {
                indicesByID[input.ids[index]] = index
#if DEBUG
                let preparedHeight = directBodyCacheGateEnabled && input.ids.count == 122
                    ? directEntries[index]?.row.height : nil
#else
                let preparedHeight: CGFloat? = nil
#endif
                heights.append(cachedHeight(index) ?? preparedHeight ?? 100)
            }
            rebuildPositions()
        }

        func invalidateChangedRows(scanCache: Bool) {
            guard let input else { return }
            let anchor = heights.isEmpty ? 0 : row(at: max(0, scroll.contentOffset.y))
            let local = heights.isEmpty ? 0 : scroll.contentOffset.y - positions[anchor]
            var changedIndices = Set<Int>()
            var staleKeys: [HeightKey] = []
#if DEBUG
            var equivalentDirectKeys: [(HeightKey, StableViewportRowRevision)] = []
#endif
            if scanCache {
                for (key, entry) in cache {
                    guard let index = indicesByID[key.id], entry.revision != input.revisionAt(index) else { continue }
#if DEBUG
                    if let direct = directEntries[index], !directFailed.contains(index),
                       abs(entry.height - direct.row.height) < 0.5,
                       directRetainedPresentationMatches(
                           DirectKey(id: direct.key.id, revision: entry.revision,
                                     width: direct.key.width, typeKey: direct.key.typeKey,
                                     dark: direct.key.dark, wrapsCode: direct.key.wrapsCode,
                                     promptFill: direct.key.promptFill,
                                     promptForeground: direct.key.promptForeground,
                                     promptBorder: direct.key.promptBorder),
                           directKey(at: index, input: input)) {
                        equivalentDirectKeys.append((key, input.revisionAt(index)))
                        continue
                    }
#endif
                    staleKeys.append(key)
                    changedIndices.insert(index)
                }
            }
#if DEBUG
            for (key, revision) in equivalentDirectKeys {
                if let entry = cache[key] {
                    cache[key] = CachedHeight(height: entry.height, revision: revision)
                    logger.debug("event=direct_two_cache_rekey id=\(key.id, privacy: .public) ignoredField=allowsOutgoingMotion")
                }
            }
#endif
            for key in staleKeys { cache.removeValue(forKey: key) }
            for (index, oldRevision) in hostRevisions where oldRevision != input.revisionAt(index) {
                changedIndices.insert(index)
            }
            guard !changedIndices.isEmpty else { return }
            for index in changedIndices {
                if let host = hosts.removeValue(forKey: index) { remove(host) }
                hostRevisions.removeValue(forKey: index)
                codeViewports.removeValue(forKey: index)
                measured.remove(index)
#if DEBUG
                directViews.removeValue(forKey: index)?.removeFromSuperview()
#endif
                // Keep the last observed size until this row's replacement is
                // synchronously fitted. Other rows retain exact geometry.
            }
            rebuildPositions()
            if !heights.isEmpty { scroll.contentOffset.y = positions[anchor] + local }
            layoutRows()
        }

#if DEBUG
        func startNativeRichPilotScanIfRequested() {
            let control = ProcessInfo.processInfo.arguments.contains("--native-rich-pilot-control-scan")
            guard (ProcessInfo.processInfo.arguments.contains("--native-rich-pilot-mount-scan") || control),
                  input?.ids.count == 120,
                  nativeRichPilotScanTask == nil else { return }
            nativeRichPilotScanTask = Task { [weak self] in
                guard let self else { return }
                for _ in 0..<20 where !control && self.nativeRichPilotSnapshots.count < Self.nativeRichPilotIndices.count {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled,
                      control || self.nativeRichPilotSnapshots.count == Self.nativeRichPilotIndices.count else {
                    self.logger.error("event=native_rich_pilot_scan_incomplete ready=\(self.nativeRichPilotSnapshots.count, privacy: .public)")
                    return
                }
                let scannedIndices = control ? Self.nativeRichPilotIndices + [4, 6, 20, 100, 118]
                                             : Self.nativeRichPilotIndices
                for index in scannedIndices {
                    guard !Task.isCancelled, self.input?.ids.indices.contains(index) == true,
                          control || self.nativeRichPilotSnapshot(at: index) != nil else { return }
                    self.measure(index)
                    self.scroll.contentOffset.y = self.positions[index]
                    self.layoutRows()
                    let viewport = CGRect(x: 0, y: self.scroll.contentOffset.y,
                                          width: self.scroll.bounds.width, height: self.scroll.bounds.height)
                    let mounted = self.hosts[index]?.view.window != nil
                        && self.hosts[index]?.view.frame.intersects(viewport) == true
                    let native = self.codeViewports[index]?.nativeRichSnapshot != nil
                    self.logger.debug("event=native_rich_pilot_scan index=\(index, privacy: .public) mounted=\(mounted, privacy: .public) native=\(native, privacy: .public) height=\(self.heights[index], privacy: .public)")
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
        }
#endif

        func resetRows() {
            cancel(reason: "input_changed")
#if DEBUG
            for view in directViews.values { view.removeFromSuperview() }
            directViews.removeAll()
            for proxy in flightProxies.values { proxy.removeFromSuperview() }
            flightProxies.removeAll()
#endif
            for host in hosts.values { remove(host) }
            hosts.removeAll()
            hostRevisions.removeAll()
            codeViewports.removeAll()
            measured.removeAll()
            heights = input?.ids.enumerated().map { index, _ in cachedHeight(index) ?? 100 } ?? []
            rebuildPositions()
        }

        func cachedHeight(_ index: Int) -> CGFloat? {
            guard let entry = cache[key(index)], entry.revision == input?.revisionAt(index) else { return nil }
            return entry.height
        }

        func key(_ index: Int) -> HeightKey {
            let input = input!
            return HeightKey(id: input.ids[index], width: Int(width.rounded()), type: input.typeKey)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard let input else { return }
            scroll.frame = view.bounds
            let nextWidth = max(1, view.bounds.width - 32)
            if width != nextWidth {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--native-direct-premount-window-gate"), seeded {
                    stageDirectWindowWidth(nextWidth)
                } else {
                for task in directTasks.values { task.cancel() }
                directTasks.removeAll()
                directEntries.removeAll()
                directAlternates.removeAll()
                directThinkingSnapshots.removeAll()
                directExpandedThinking.removeAll()
                directToolSnapshots.removeAll()
                directExpandedToolIDs.removeAll()
                directExpandedToolGroups.removeAll()
                directFailed.removeAll()
                directAllStartedAt = nil
                directAllReported = false
                width = nextWidth
                resetRows()
                }
#else
                width = nextWidth
                resetRows()
#endif
            }
#if DEBUG
            prepareNativeRichIfNeeded()
            prepareNativeRichPilotIfNeeded()
            prepareDirectTwoRowsIfNeeded()
#endif
            // In the parity fixture the UIKit viewport already ends above the
            // composer. Its bottom content inset reserves composer clearance;
            // subtracting the old extra 58pt put the arrow over the rich row.
            let arrowClearance: CGFloat = ProcessInfo.processInfo.arguments.contains("--native-direct-parity-gate")
                ? 10 : 58
            arrow.frame = CGRect(x: (view.bounds.width - 48) / 2,
                                 y: max(0, view.bounds.height - input.bottomInset - arrowClearance),
                                 width: 48, height: 48)
#if DEBUG
            directArrowStatus.frame = CGRect(x: (view.bounds.width - 190) / 2,
                                             y: max(0, arrow.frame.minY - 34),
                                             width: 190, height: 28)
#endif
            if !seeded, !heights.isEmpty {
                seeded = true
                let index = input.initialID.flatMap { input.ids.firstIndex(of: $0) } ?? 0
                scroll.contentOffset.y = input.startsAtBottom && input.initialID == nil
                    ? bottomOffset : positions[index]
                // Diagnostic only: isolate renderer cadence from XCTest's
                // expensive accessibility snapshots. No target prewarming.
                if ProcessInfo.processInfo.arguments.contains("--viewport-cost-autojump") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, self.view.window != nil else { return }
                        self.logger.debug("event=prototype_automatic_cold")
                        self.jump()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
                        guard let self, self.view.window != nil else { return }
                        self.scroll.contentOffset.y = max(0, self.bottomOffset - 300)
                        self.layoutRows()
                        self.logger.debug("event=prototype_automatic_warm")
                        self.jump()
                    }
                }
            }
            layoutRows()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--viewport-opening-probe") {
                if ProcessInfo.processInfo.arguments.contains("--viewport-immediate-readable-autojump") {
                    NativeOpeningTrace.shared.afterFirstCallback = { [weak self] in
                        guard let self, self.view.window != nil else { return }
                        self.logger.debug("event=prototype_immediate_readable_tap ready=\(self.directEntries.count, privacy: .public) fallback=\(self.directFailed.count, privacy: .public) row1Native=\(self.directViews[1]?.window != nil, privacy: .public) row1Legacy=\(self.hosts[1]?.view.window != nil, privacy: .public) memoryMB=\(self.footprintMB(), privacy: .public)")
                        self.jump()
                    }
                }
                NativeOpeningTrace.shared.armFirstFrame(eager: false)
            }
            startNativeRichPilotScanIfRequested()
#endif
        }

        func rebuildPositions() {
            positions = [16]
            let spacing = input?.spacing ?? 12
            for height in heights { positions.append(positions.last! + height + spacing) }
            scroll.contentSize = CGSize(width: view.bounds.width, height: positions.last ?? 16)
        }

        func row(at y: CGFloat) -> Int {
            guard !heights.isEmpty else { return 0 }
            var low = 0, high = heights.count
            while low + 1 < high {
                let mid = (low + high) / 2
                if positions[mid] <= y { low = mid } else { high = mid }
            }
            return min(low, heights.count - 1)
        }

        func applyHeight(_ height: CGFloat, index: Int) {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic"),
               link != nil, index != heights.count - 1 {
                logger.error("event=direct_10k_flight_forbidden_refinement index=\(index, privacy: .public) frame=\(self.frameCount, privacy: .public)")
                return
            }
#endif
            let resolvedHeight: CGFloat
#if DEBUG
            if (index == heights.count - 1 && nativeRichSnapshot != nil
                && ProcessInfo.processInfo.arguments.contains("--native-rich-row-prototype"))
                || nativeRichPilotSnapshot(at: index) != nil {
                // `sizeThatFits` and the geometry callback must commit the
                // same pixel-independent row extent. The former already
                // ceils; accepting raw callback fractions oscillated 545↔544.
                resolvedHeight = ceil(height)
            } else {
                resolvedHeight = height
            }
#else
            resolvedHeight = height
#endif
            guard heights.indices.contains(index), resolvedHeight.isFinite, resolvedHeight > 0,
                  abs(heights[index] - resolvedHeight) > 0.5 else { return }
            let before = CACurrentMediaTime()
            defer { geometryCost += CACurrentMediaTime() - before }
            let anchor = row(at: max(0, scroll.contentOffset.y))
            let local = scroll.contentOffset.y - positions[anchor]
            let followsBottom = link == nil && !scroll.isTracking && !scroll.isDragging
                && !scroll.isDecelerating && abs(bottomOffset - scroll.contentOffset.y) < 3
            if index == heights.count - 1 {
                logger.debug("event=prototype_tail_height old=\(self.heights[index], privacy: .public) new=\(resolvedHeight, privacy: .public) elapsedMs=\(Int((CACurrentMediaTime() - self.started) * 1000), privacy: .public) jumping=\(self.link != nil, privacy: .public)")
            }
            heights[index] = resolvedHeight
            let heightKey = key(index)
            cache[heightKey] = CachedHeight(height: resolvedHeight, revision: input!.revisionAt(index))
            cacheOrder.removeAll { $0 == heightKey }
            cacheOrder.append(heightKey)
            if cacheOrder.count > 256 {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
            rebuildPositions()
            // A refinement above the reader moves the coordinate system, not
            // the visible text. This same compensation applies during a jump.
#if DEBUG
            let snapToBottom = followsBottom && !directStreamFollowing
#else
            let snapToBottom = followsBottom
#endif
            scroll.contentOffset.y = snapToBottom ? bottomOffset : positions[anchor] + local
#if DEBUG
            if directStreamFollowing && !directStreamConfiguring { startDirectStreamFollow() }
#endif
        }

        func ensureHost(_ index: Int) -> UIHostingController<AnyView> {
            if let host = hosts[index] { return host }
            let before = CACurrentMediaTime()
            defer { hostCost += CACurrentMediaTime() - before }
            let input = input!
            let id = input.ids[index]
            let heightKey = key(index)
            let rowRevision = input.revisionAt(index)
            let viewport = PrototypeCodeViewport()
#if DEBUG
            viewport.forceExpandThinking = directFallbackDisclosure[index] == "Thinking"
            viewport.forceExpandTool = directFallbackDisclosure[index] != nil
                && directFallbackDisclosure[index] != "Thinking"
            if ProcessInfo.processInfo.arguments.contains("--native-rich-row-prototype"),
               index == input.ids.count - 1, nativeRichKey?.id == id {
                viewport.nativeRichSnapshot = nativeRichSnapshot
                viewport.nativeRichToggleCodeWrap = { [weak self] in
                    guard let self, self.nativeRichAlternateSnapshot != nil else { return }
                    UserDefaults.standard.set(!input.nativeRichWrapsCodeLines,
                                              forKey: ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey)
                }
            } else if let snapshot = nativeRichPilotSnapshot(at: index) {
                viewport.nativeRichSnapshot = snapshot
                viewport.nativeRichToggleCodeWrap = { [weak self] in
                    guard let self, self.nativeRichPilotAlternates[index] != nil else { return }
                    UserDefaults.standard.set(!input.nativeRichWrapsCodeLines,
                                              forKey: ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey)
                }
            }
#endif
            viewport.rect = CGRect(x: 0, y: scroll.contentOffset.y - positions[index], width: width, height: scroll.bounds.height)
            viewport.correctAnchor = { [weak self] delta in
                guard let self, self.link == nil, self.hosts[index] != nil,
                      self.input?.ids.indices.contains(index) == true, self.input?.ids[index] == id,
                      abs(self.bottomOffset - self.scroll.contentOffset.y) >= 3 else { return }
                self.scroll.contentOffset.y += delta
            }
            codeViewports[index] = viewport
            let row = input.makeRow(index, viewport).fixedSize(horizontal: false, vertical: true)
                .environment(\.prototypeCodeViewport, viewport)
                .coordinateSpace(name: "prototype-row")
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size, initial: true) { _, size in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.input?.ids.indices.contains(index) == true,
                                  self.input?.ids[index] == id, self.hosts[index] != nil,
                                  self.key(index) == heightKey,
                                  self.input?.revisionAt(index) == rowRevision else { return }
                            // SwiftUI also reports intrinsic/minimum-width
                            // probes while fitting a host. Those are not the
                            // displayed row's geometry and must not retarget it.
                            guard Self.isDisplaySize(size, width: self.width) else {
                                self.logger.debug("event=prototype_rejected_width measured=\(size.width, privacy: .public) expected=\(self.width, privacy: .public)")
                                return
                            }
                            if index == self.heights.count - 1 {
                                self.logger.debug("event=prototype_tail_sample width=\(size.width, privacy: .public) intendedWidth=\(self.width, privacy: .public) height=\(size.height, privacy: .public)")
                            }
                            self.layingOut = true
                            self.refinementCount += 1
                            self.applyHeight(size.height, index: index)
                            self.layingOut = false
                            self.layoutRows()
                        }
                    }
                })
            let host = UIHostingController(rootView: AnyView(row))
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(x: 16, y: positions[index], width: width, height: heights[index])
            addChild(host)
            scroll.addSubview(host.view)
            host.didMove(toParent: self)
            hosts[index] = host
            hostRevisions[index] = rowRevision
            hostCreationCount += 1
            peakHosts = max(peakHosts, hosts.count)
            return host
        }

        static func isDisplaySize(_ size: CGSize, width: CGFloat) -> Bool {
            width.isFinite && width > 1 && size.width.isFinite && size.height.isFinite
                && size.height > 0 && abs(size.width - width) < 0.5
        }

        func measure(_ index: Int) {
            guard !measured.contains(index), width > 1 else { return }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic"), link != nil,
               index != heights.count - 1 {
                flightLegacyFits += 1
                logger.error("event=direct_10k_flight_forbidden_fit index=\(index, privacy: .public) frame=\(self.frameCount, privacy: .public)")
                return
            }
#endif
#if DEBUG
            if let row = directRow(at: index) {
                measured.insert(index)
                applyHeight(row.height, index: index)
                directMeasuredDuringJump += link == nil ? 0 : 1
                logger.debug("event=direct_two_measure index=\(index, privacy: .public) height=\(row.height, privacy: .public) jumping=\(self.link != nil, privacy: .public)")
                return
            }
            if (directBodyCacheGateEnabled || strictDirect10kGate) && link != nil {
                logger.error("event=direct_arrow_forbidden_fit index=\(index, privacy: .public)")
                cancel(reason: "unready_measure")
                showDirectArrowUnready(count: 0, missing: index)
                return
            }
#endif
            let before = CACurrentMediaTime()
            let host = ensureHost(index)
            let sizingStarted = CACurrentMediaTime()
            let size = host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
            sizingCost += CACurrentMediaTime() - sizingStarted
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-direct-all120-diagnostic")
                || ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic")
                || ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic") {
                logger.error("event=direct_all_legacy_fit index=\(index, privacy: .public) fitMs=\(Int((CACurrentMediaTime() - sizingStarted) * 1_000), privacy: .public) jumping=\(self.link != nil, privacy: .public)")
            }
#endif
            measured.insert(index)
            applyHeight(ceil(size.height), index: index)
            maximumMeasure = max(maximumMeasure, CACurrentMediaTime() - before)
            measurementCount += 1
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-rich-pilot-fit-trace") {
                let native = codeViewports[index]?.nativeRichSnapshot != nil
                logger.debug("event=native_rich_fit index=\(index, privacy: .public) native=\(native, privacy: .public) fitMs=\(Int((CACurrentMediaTime() - before) * 1_000), privacy: .public) height=\(self.heights[index], privacy: .public) jumping=\(self.link != nil, privacy: .public)")
            }
#endif
        }

        func layoutRows() {
            guard !layingOut, !heights.isEmpty, scroll.bounds.height > 0 else { return }
#if DEBUG
            let flightActive = link != nil
                && ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic")
            if !flightActive, !flightProxies.isEmpty {
                let anchor = row(at: max(0, scroll.contentOffset.y))
                let id = input?.ids[anchor] ?? ""
                let local = scroll.contentOffset.y - positions[anchor]
                for proxy in flightProxies.values { proxy.removeFromSuperview() }
                flightProxies.removeAll()
                logger.debug("event=direct_10k_flight_reconcile anchor=\(id, privacy: .public) local=\(local, privacy: .public) offset=\(self.scroll.contentOffset.y, privacy: .public)")
            }
#else
            let flightActive = false
#endif
            let before = CACurrentMediaTime()
            layingOut = true
            defer {
                layingOut = false
                let elapsed = CACurrentMediaTime() - before
                layoutCost += elapsed
                maximumLayoutCost = max(maximumLayoutCost, elapsed)
                layoutCount += 1
            }
            // Recompute visibility after each newly measured row, since a
            // single tall response may replace many estimated short rows.
            for _ in 0..<(flightActive ? 0 : 12) {
                let first = row(at: max(0, scroll.contentOffset.y - 80))
                let last = row(at: scroll.contentOffset.y + scroll.bounds.height + 80)
                guard let index = (first...last).first(where: { !measured.contains($0) }) else { break }
                measure(index)
            }
            let first = row(at: max(0, scroll.contentOffset.y - 80))
            let last = row(at: scroll.contentOffset.y + scroll.bounds.height + 80)
            let keep = Set(first...last).union(link != nil ? [heights.count - 1] : [])
            for index in keep {
#if DEBUG
                if let row = directRow(at: index) {
                    let view = ensureDirectView(index, row: row)
                    view.frame = CGRect(x: 16, y: positions[index], width: width, height: heights[index])
                    continue
                }
                if (directBodyCacheGateEnabled || strictDirect10kGate) && link != nil {
                    logger.error("event=direct_arrow_forbidden_mount index=\(index, privacy: .public)")
                    cancel(reason: "unready_mount")
                    showDirectArrowUnready(count: 0, missing: index)
                    return
                }
                if flightActive {
                    if let host = hosts[index] {
                        host.view.frame = CGRect(x: 16, y: positions[index], width: width, height: heights[index])
                    } else {
                        let proxy = flightPreview(index)
                        proxy.frame = CGRect(x: 16, y: positions[index], width: width, height: heights[index])
                    }
                    continue
                }
                if directViews[index] != nil {
                    logger.error("event=direct_two_visible_fallback index=\(index, privacy: .public)")
                    directViews.removeValue(forKey: index)?.removeFromSuperview()
                    directFailed.insert(index)
                }
                if ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic"),
                   link != nil, hosts[index] == nil {
                    direct10kMissingFrames += 1
                    logger.error("event=direct_10k_missing_visible index=\(index, privacy: .public) frame=\(self.frameCount, privacy: .public) ready=\(self.directEntries.count, privacy: .public) tasks=\(self.directTasks.count, privacy: .public)")
                }
#endif
                let host = ensureHost(index)
                let visible = CGRect(x: 0, y: scroll.contentOffset.y - positions[index], width: width, height: scroll.bounds.height)
                if codeViewports[index]?.rect != visible { codeViewports[index]?.rect = visible }
                host.view.frame = CGRect(x: 16, y: positions[index], width: width, height: heights[index])
            }
            for index in Array(hosts.keys) where !keep.contains(index) {
                if let host = hosts.removeValue(forKey: index) { remove(host) }
                hostRevisions.removeValue(forKey: index)
                codeViewports.removeValue(forKey: index)
            }
#if DEBUG
            for index in Array(directViews.keys) where !keep.contains(index) {
                directViews.removeValue(forKey: index)?.removeFromSuperview()
            }
            for index in Array(flightProxies.keys) where !keep.contains(index) {
                flightProxies.removeValue(forKey: index)?.removeFromSuperview()
            }
#endif
            arrow.isHidden = abs(bottomOffset - scroll.contentOffset.y) < 3 && link == nil
            reportScrollState()
        }

        func reportScrollState() {
            guard let input, !heights.isEmpty, scroll.bounds.height > 0 else { return }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-direct-flight-suppress-scroll-report"),
               ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic"),
               link != nil, !scroll.isTracking, !scroll.isDragging {
                flightReportsSuppressed += 1
                return
            }
#endif
            let distance = max(0, bottomOffset - scroll.contentOffset.y)
            let first = row(at: max(0, scroll.contentOffset.y))
            let latest = heights.count - 1
            let latestVisible = positions[latest] < scroll.contentOffset.y + scroll.bounds.height
                && positions[latest + 1] > scroll.contentOffset.y
            let state = ReportedScrollState(
                nearBottom: distance < 3,
                direct: scroll.isTracking || scroll.isDragging,
                decelerating: scroll.isDecelerating,
                visibleID: input.ids[first],
                latestVisible: latestVisible
            )
            guard state != lastReportedScrollState else { return }
            lastReportedScrollState = state
            let metrics = ChatScrollMetrics(
                distanceFromBottom: distance,
                isUserInteracting: state.direct || state.decelerating,
                isDirectlyInteracting: state.direct,
                isDecelerating: state.decelerating
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastReportedScrollState == state else { return }
#if DEBUG
                let callbackStarted = CACurrentMediaTime()
#endif
                self.input?.onScrollState(metrics, state.visibleID, state.latestVisible, state.nearBottom)
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic") {
                    self.logger.debug("event=direct_10k_scroll_report_callback_ms value=\(Int((CACurrentMediaTime() - callbackStarted) * 1_000), privacy: .public) frame=\(self.frameCount, privacy: .public) visible=\(state.visibleID ?? "nil", privacy: .public)")
                }
#endif
            }
        }

        func remove(_ host: UIHostingController<AnyView>) {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }

        var bottomOffset: CGFloat { max(0, scroll.contentSize.height - scroll.bounds.height + scroll.contentInset.bottom) }

#if DEBUG
        var directBodyCacheGateEnabled: Bool {
            ProcessInfo.processInfo.arguments.contains("--native-direct-body-cache-gate")
                && ProcessInfo.processInfo.arguments.contains("--native-direct-all120-diagnostic")
        }

        func finishDirectStreamFollowIfComplete() {
            guard let input, input.ids.count == 122 else {
                directStreamFollowing = false
                directStreamLastOffset = nil
                return
            }
            let tail = input.revisionAt(121)
            if !tail.hasActiveStream,
               tail.latestCompletedAssistantRenderID == tail.message.renderID {
                directStreamFollowing = false
                directStreamLastOffset = nil
                logger.debug("event=direct_stream_follow_complete")
            }
        }

        func startDirectStreamFollow() {
            guard directStreamFollowing else { return }
            if input?.reduceMotion == true {
                if directStreamAnimating {
                    link?.invalidate(); link = nil
                    directStreamAnimating = false
                }
                directStreamVelocity = 0
                scroll.contentOffset.y = bottomOffset
                layoutRows()
                scroll.accessibilityValue = "stream motion settled; unexpected moves \(directStreamUnexpectedMoves)"
                finishDirectStreamFollowIfComplete()
                return
            }
            guard !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else {
                directStreamFollowing = false
                return
            }
            guard !directStreamAnimating else { return }
            guard abs(bottomOffset - scroll.contentOffset.y) > 0.5 else {
                scroll.accessibilityValue = "stream motion settled; unexpected moves \(directStreamUnexpectedMoves)"
                finishDirectStreamFollowIfComplete()
                return
            }
            if link != nil { cancel(reason: "stream_follow_replaces_arrow") }
            directStreamAnimating = true
            directStreamVelocity = 0
            directStreamPreviousTick = CACurrentMediaTime()
            let display = CADisplayLink(target: self, selector: #selector(tick))
            display.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link = display
            display.add(to: .main, forMode: .common)
            logger.error("event=direct_stream_motion_start offset=\(self.scroll.contentOffset.y, privacy: .public) target=\(self.bottomOffset, privacy: .public) row119Y=\(self.positions[119] - self.scroll.contentOffset.y, privacy: .public)")
        }

        func tickDirectStreamFollow(_ display: CADisplayLink) {
            guard directStreamFollowing, view.window != nil,
                  !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else {
                cancel(reason: "stream_follow_interrupted")
                directStreamFollowing = false
                return
            }
            let workStarted = CACurrentMediaTime()
            let elapsed = CGFloat(max(0, min(display.timestamp - directStreamPreviousTick, 0.1)))
            directStreamPreviousTick = display.timestamp
            let target = bottomOffset
            // Match the existing 0.15s streaming-follow response with a
            // critically damped, time-based trajectory. New content only
            // changes the target; it cannot issue another offset animation.
            let responseTime: CGFloat = 0.15
            let omega: CGFloat = 4.74 / responseTime
            let displacement = scroll.contentOffset.y - target
            let next = (displacement + (directStreamVelocity + omega * displacement) * elapsed)
                * exp(-omega * elapsed)
            directStreamVelocity = (directStreamVelocity
                - omega * (directStreamVelocity + omega * displacement) * elapsed)
                * exp(-omega * elapsed)
            directStreamTickWriting = true
            scroll.contentOffset.y = max(0, min(target, target + next))
            directStreamTickWriting = false
            layoutRows()
            logger.error("event=direct_stream_motion_tick offset=\(self.scroll.contentOffset.y, privacy: .public) target=\(target, privacy: .public) row119Y=\(self.positions[119] - self.scroll.contentOffset.y, privacy: .public) callbackGapMs=\(Int(elapsed * 1_000), privacy: .public) targetLeadMs=\(Int((display.targetTimestamp - display.timestamp) * 1_000), privacy: .public) workMs=\(Int((CACurrentMediaTime() - workStarted) * 1_000), privacy: .public)")
            let onePixel = 1 / max(1, UIScreen.main.scale)
            let nextFrame = CGFloat(max(0, display.targetTimestamp - display.timestamp))
            if abs(target - scroll.contentOffset.y) <= onePixel
                && abs(directStreamVelocity) * nextFrame <= onePixel {
                directStreamTickWriting = true
                scroll.contentOffset.y = target
                directStreamTickWriting = false
                link?.invalidate(); link = nil
                directStreamAnimating = false
                directStreamVelocity = 0
                scroll.accessibilityValue = "stream motion settled; unexpected moves \(directStreamUnexpectedMoves)"
                logger.error("event=direct_stream_motion_settled offset=\(self.scroll.contentOffset.y, privacy: .public) row119Y=\(self.positions[119] - self.scroll.contentOffset.y, privacy: .public)")
                finishDirectStreamFollowIfComplete()
            }
        }

        /// A far jump is admitted only when each sampled visible position has
        /// the real prepared row and its measured height. No hosted/proxy row
        /// can enter the active display-link path in this diagnostic.
        func prepareDirectArrowCorridor() -> (ready: Bool, count: Int, missing: Int?) {
            guard let input,
                  input.ids.count == 120 || (directBodyCacheGateEnabled && input.ids.count == 122)
                    || (strictDirect10kGate && input.ids.count == 10_000)
            else { return (false, 0, input?.ids.count) }
            if input.ids.count == 120 || input.ids.count == 122 {
                // This exact small fixture can settle every already-prepared
                // native height before motion. The 10k route never enters here.
                if input.ids.count == 122 {
                    guard directTasks[121] == nil,
                          let tail = directRow(at: 121),
                          case .assistant = tail.content else { return (false, 0, 121) }
                }
                let started = CACurrentMediaTime()
                for index in input.ids.indices {
                    guard hosts[index] == nil, directRow(at: index) != nil else {
                        return (false, 0, index)
                    }
                }
                let before = measured.count
                for index in input.ids.indices where !measured.contains(index) { measure(index) }
                logger.error("event=direct_small_height_settle rows=\(input.ids.count, privacy: .public) measured=\(self.measured.count - before, privacy: .public) elapsedMs=\(Int((CACurrentMediaTime() - started) * 1_000), privacy: .public)")
            }
            var needed = Set<Int>()
            for _ in 0..<2 {
                needed.removeAll()
                let start = scroll.contentOffset.y
                let target = bottomOffset
                let samples = strictDirect10kGate ? 33 : 24
                for sample in 0...samples {
                    let progress = CGFloat(sample) / CGFloat(samples)
                    let eased = strictDirect10kGate
                        ? progress * progress * (3 - 2 * progress)
                        : 1 - pow(1 - progress, 3)
                    let y = start + (target - start) * eased
                    let first = row(at: max(0, y - 80))
                    let last = row(at: y + scroll.bounds.height + 80)
                    needed.formUnion(first...last)
                    if strictDirect10kGate && needed.count > 64 {
                        logger.error("event=direct_10k_corridor_over_budget count=\(needed.count, privacy: .public) cap=64")
                        return (false, needed.count, nil)
                    }
                    if needed.count > min(directEntries.count, input.ids.count) {
                        return (false, needed.count, nil)
                    }
                }
                for index in needed.sorted() {
                    guard hosts[index] == nil, directRow(at: index) != nil else {
                        return (false, needed.count, index)
                    }
                }
                for index in needed.sorted() where !measured.contains(index) {
                    measure(index)
                }
            }
            return (true, needed.count, nil)
        }

        func directArrowWindowReady(at offset: CGFloat) -> Bool {
            let first = row(at: max(0, offset - 80))
            let last = row(at: offset + scroll.bounds.height + 80)
            return (first...last).allSatisfy {
                hosts[$0] == nil && measured.contains($0) && directRow(at: $0) != nil
            }
        }

        func showDirectArrowUnready(count: Int, missing: Int?) {
            directArrowStatus.isHidden = false
            arrow.accessibilityLabel = "Preparing latest messages"
            logger.error("event=direct_arrow_unready corridor=\(count, privacy: .public) missing=\(missing ?? -1, privacy: .public) ready=\(self.directEntries.count, privacy: .public) tasks=\(self.directTasks.count, privacy: .public)")
            prepareDirectTwoRowsIfNeeded()
        }
#endif

        @objc func jump() {
#if DEBUG
            if directStreamFollowing {
                cancel(reason: "explicit_arrow")
                directStreamFollowing = false
            }
            if ProcessInfo.processInfo.arguments.contains("--native-rich-row-prototype"),
               nativeRichKey != nil, nativeRichSnapshot == nil, !nativeRichFailed {
                if pendingNativeJumpAt == nil { pendingNativeJumpAt = CACurrentMediaTime() }
                logger.debug("event=native_rich_jump_waiting_for_snapshot")
                prepareNativeRichIfNeeded()
                return
            }
            tapStarted = pendingNativeJumpAt ?? CACurrentMediaTime()
            pendingNativeJumpAt = nil
#endif
            cancel(reason: "replaced")
            guard !heights.isEmpty else { return }
#if DEBUG
            if strictDirect10kGate {
                direct10kJumpStartOffset = scroll.contentOffset.y
                stageDirect10kWindows(elapsed: 0)
            }
            if directBodyCacheGateEnabled || strictDirect10kGate {
                let corridor = prepareDirectArrowCorridor()
                guard corridor.ready else {
                    showDirectArrowUnready(count: corridor.count, missing: corridor.missing)
                    return
                }
                directArrowStatus.isHidden = true
                arrow.accessibilityLabel = "Prototype scroll to latest"
                logger.error("event=direct_arrow_admitted corridor=\(corridor.count, privacy: .public) ready=\(self.directEntries.count, privacy: .public)")
            }
#endif
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic"),
               directRow(at: heights.count - 1) == nil {
                logger.error("event=direct_10k_flight_target_missing")
                return
            }
#endif
            started = CACurrentMediaTime()
            previousTick = started
            previousProgress = 0
            maximumGap = 0
            maximumMeasure = 0
            measurementCount = 0
            frameCount = 0
            hostCost = 0; sizingCost = 0; geometryCost = 0; layoutCost = 0
            maximumLayoutCost = 0; maximumTickCost = 0
            hostCreationCount = 0; peakHosts = hosts.count; layoutCount = 0; refinementCount = 0
#if DEBUG
            directMountedDuringJump = 0; directMeasuredDuringJump = 0
#endif
            memoryAtStart = footprintMB()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic") {
                flightProxyMounts = 0
                flightLegacyFits = 0
                flightReportsSuppressed = 0
                logger.debug("event=direct_10k_flight_start targetHeight=\(self.directEntries[self.heights.count - 1]?.row.height ?? -1, privacy: .public) ready=\(self.directEntries.count, privacy: .public) memoryMB=\(Int(self.footprintMB()), privacy: .public)")
            }
            if ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic") {
                direct10kJumpStartOffset = scroll.contentOffset.y
                direct10kMissingFrames = 0
                direct10kPeakEntries = directEntries.count
                stageDirect10kWindows(elapsed: 0)
                logger.debug("event=direct_10k_jump_start ready=\(self.directEntries.count, privacy: .public) tasks=\(self.directTasks.count, privacy: .public) fallback=\(self.directFailed.count, privacy: .public)")
            }
            if ProcessInfo.processInfo.arguments.contains("--native-direct-all120-diagnostic") {
                logger.debug("event=direct_all_jump_start ready=\(self.directEntries.count, privacy: .public) fallback=\(self.directFailed.count, privacy: .public) activeTasks=\(self.directTasks.count, privacy: .public) prepWallMs=\(Int((CACurrentMediaTime() - (self.directAllStartedAt ?? CACurrentMediaTime())) * 1_000), privacy: .public) paced=\(ProcessInfo.processInfo.arguments.contains("--native-direct-all120-paced-diagnostic"), privacy: .public)")
            }
#endif
            layingOut = true
            measure(heights.count - 1)
            layingOut = false
            let display = CADisplayLink(target: self, selector: #selector(tick))
            display.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link = display
            display.add(to: .main, forMode: .common)
            logger.debug("event=prototype_jump_started rows=\(self.heights.count, privacy: .public)")
        }

        @objc func tick() {
#if DEBUG
            if directStreamAnimating, let link {
                tickDirectStreamFollow(link)
                return
            }
#endif
            let tickStarted = CACurrentMediaTime()
            defer { maximumTickCost = max(maximumTickCost, CACurrentMediaTime() - tickStarted) }
            guard view.window != nil, !scroll.isTracking, !scroll.isDragging else { cancel(reason: "interaction"); return }
            let now = CACurrentMediaTime()
            maximumGap = max(maximumGap, now - previousTick)
            previousTick = now
            frameCount += 1
            if frameCount == 1 {
                logger.debug("event=prototype_first_motion latencyMs=\(Int((now - self.started) * 1000), privacy: .public)")
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--native-rich-row-prototype") {
                    logger.debug("event=native_rich_tap_to_first_motion latencyMs=\(Int((now - self.tapStarted) * 1000), privacy: .public)")
                }
#endif
            }
            let pacedDiagnostic = (ProcessInfo.processInfo.arguments.contains("--native-direct-all120-diagnostic")
                || ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic")
                || ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic"))
                && ProcessInfo.processInfo.arguments.contains("--native-direct-all120-paced-diagnostic")
            let progress: CGFloat = input?.reduceMotion == true ? 1 : min(1, (now - started) / (pacedDiagnostic ? 0.55 : 0.35))
            let eased = pacedDiagnostic ? progress * progress * (3 - 2 * progress)
                                         : 1 - pow(1 - progress, 3)
            let fraction = previousProgress >= 1 ? 1 : (eased - previousProgress) / (1 - previousProgress)
            previousProgress = eased
            let priorOffset = scroll.contentOffset.y
            let proposedOffset = scroll.contentOffset.y + (bottomOffset - scroll.contentOffset.y) * fraction
#if DEBUG
            if (directBodyCacheGateEnabled || strictDirect10kGate)
                && !directArrowWindowReady(at: proposedOffset) {
                cancel(reason: "unready_visible_window")
                showDirectArrowUnready(count: 0, missing: row(at: proposedOffset))
                return
            }
#endif
            scroll.contentOffset.y = proposedOffset
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic") {
                stageDirect10kWindows(elapsed: now - started)
            }
#endif
            layoutRows()
#if DEBUG
            if directBodyCacheGateEnabled && frameCount == 1 {
                logger.error("event=direct_arrow_first_motion tapToMs=\(Int((now - self.tapStarted) * 1_000), privacy: .public) moved=\(abs(self.scroll.contentOffset.y - priorOffset), privacy: .public) rows=\(self.heights.count, privacy: .public)")
            }
            if ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic") {
                let visible = row(at: max(0, scroll.contentOffset.y))
                logger.debug("event=direct_10k_flight_frame frame=\(self.frameCount, privacy: .public) visible=\(visible, privacy: .public) proxies=\(self.flightProxies.count, privacy: .public) legacyFits=\(self.flightLegacyFits, privacy: .public) elapsedMs=\(Int((now - self.started) * 1_000), privacy: .public)")
            }
#endif
            if progress == 1 {
                scroll.contentOffset.y = bottomOffset
                layoutRows()
                let elapsed = CACurrentMediaTime() - started
                maximumTickCost = max(maximumTickCost, CACurrentMediaTime() - tickStarted)
                logger.debug("event=prototype_jump_finished elapsedMs=\(Int(elapsed * 1000), privacy: .public) frames=\(self.frameCount, privacy: .public) maxGapMs=\(Int(self.maximumGap * 1000), privacy: .public) maxMeasureMs=\(Int(self.maximumMeasure * 1000), privacy: .public) measuredRows=\(self.measurementCount, privacy: .public) withinBudget=\(elapsed <= 0.65, privacy: .public)")
#if DEBUG
                if directBodyCacheGateEnabled {
                    logger.error("event=direct_arrow_finished elapsedMs=\(Int(elapsed * 1_000), privacy: .public) frames=\(self.frameCount, privacy: .public) maxTickGapMs=\(Int(self.maximumGap * 1_000), privacy: .public) createdHosts=\(self.hostCreationCount, privacy: .public) bottomDistance=\(self.bottomOffset - self.scroll.contentOffset.y, privacy: .public) rows=\(self.heights.count, privacy: .public)")
                }
#endif
                logger.debug("event=prototype_cost hostMs=\(Int(self.hostCost * 1000), privacy: .public) sizingMs=\(Int(self.sizingCost * 1000), privacy: .public) geometryMs=\(Int(self.geometryCost * 1000), privacy: .public) layoutMs=\(Int(self.layoutCost * 1000), privacy: .public) maxLayoutMs=\(Int(self.maximumLayoutCost * 1000), privacy: .public) maxTickMs=\(Int(self.maximumTickCost * 1000), privacy: .public) createdHosts=\(self.hostCreationCount, privacy: .public) peakHosts=\(self.peakHosts, privacy: .public) layouts=\(self.layoutCount, privacy: .public) refinements=\(self.refinementCount, privacy: .public)")
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--native-direct-two-row-proof")
                    || ProcessInfo.processInfo.arguments.contains("--native-direct-all120-diagnostic") {
                    logger.debug("event=direct_two_cost nativeMounted=\(self.directMountedDuringJump, privacy: .public) nativeMeasured=\(self.directMeasuredDuringJump, privacy: .public) fallback=\(self.directFailed.count, privacy: .public)")
                }
#endif
                let footprint = footprintMB()
                logger.debug("event=prototype_memory startMB=\(Int(self.memoryAtStart), privacy: .public) finishMB=\(Int(footprint), privacy: .public) retainedHosts=\(self.hosts.count, privacy: .public)")
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic") {
                    logger.debug("event=direct_10k_flight_finished proxyMounts=\(self.flightProxyMounts, privacy: .public) legacyFits=\(self.flightLegacyFits, privacy: .public) reportsSuppressed=\(self.flightReportsSuppressed, privacy: .public) memoryMB=\(Int(self.footprintMB()), privacy: .public)")
                }
                if ProcessInfo.processInfo.arguments.contains("--native-direct-windowed-10k-diagnostic") {
                    logger.debug("event=direct_10k_jump_finished missingVisible=\(self.direct10kMissingFrames, privacy: .public) peakEntries=\(self.direct10kPeakEntries, privacy: .public) ready=\(self.directEntries.count, privacy: .public) tasks=\(self.directTasks.count, privacy: .public) fallback=\(self.directFailed.count, privacy: .public)")
                }
#endif
                link?.invalidate(); link = nil
                layoutRows()
                input?.onJumpToLatest()
            }
        }

        func cancel(reason: String) {
            guard link != nil else { return }
            link?.invalidate(); link = nil
#if DEBUG
            directStreamAnimating = false
            directStreamVelocity = 0
#endif
            logger.debug("event=prototype_jump_cancelled reason=\(reason, privacy: .public)")
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-direct-flight-10k-diagnostic"), reason == "manual_drag" {
                layoutRows()
                logger.debug("event=direct_10k_flight_cancel_reconciled offset=\(self.scroll.contentOffset.y, privacy: .public)")
            }
#endif
        }
        func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
#if DEBUG
            if directStreamFollowing {
                let current = scrollView.contentOffset.y
                if let previous = directStreamLastOffset,
                   abs(current - previous) > 0.5,
                   !directStreamTickWriting,
                   !scrollView.isTracking, !scrollView.isDragging {
                    directStreamUnexpectedMoves += 1
                    logger.error("event=direct_stream_unowned_move from=\(previous, privacy: .public) to=\(current, privacy: .public) configuring=\(self.directStreamConfiguring, privacy: .public)")
                }
                directStreamLastOffset = current
            }
#endif
            layoutRows()
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
#if DEBUG
            directStreamFollowing = false
            pendingNativeJumpAt = nil
            if ProcessInfo.processInfo.arguments.contains("--native-rich-wrap-fixture") {
                logger.debug("event=native_rich_vertical_begin offset=\(scrollView.contentOffset.y, privacy: .public)")
            }
#endif
            cancel(reason: "manual_drag")
            reportScrollState()
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-rich-wrap-fixture") {
                logger.debug("event=native_rich_vertical_end offset=\(scrollView.contentOffset.y, privacy: .public) decelerate=\(decelerate, privacy: .public)")
            }
#endif
            reportScrollState()
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportScrollState() }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            cancel(reason: "disappear")
#if DEBUG
            directStreamFollowing = false
            directStreamLastOffset = nil
            nativeRichTask?.cancel()
            for task in nativeRichPilotTasks.values { task.cancel() }
            nativeRichPilotTasks.removeAll()
            nativeRichPilotKeys.removeAll()
            nativeRichPilotSnapshots.removeAll()
            nativeRichPilotAlternates.removeAll()
            nativeRichPilotFinished.removeAll()
            nativeRichPilotBatchStartedAt = nil
            nativeRichPilotScanTask?.cancel()
            nativeRichPilotScanTask = nil
            pendingNativeJumpAt = nil
#endif
        }
    }
}

struct ChatScrollMetrics: Equatable {
    let distanceFromBottom: CGFloat
    let isUserInteracting: Bool
    let isDirectlyInteracting: Bool
    let isDecelerating: Bool
}

struct ChatScrollObserver: UIViewRepresentable {
    let isStreaming: Bool
    let onMetrics: @MainActor (ChatScrollMetrics) -> Void
    var onContentSizeChange: @MainActor (CGSize) -> Void = { _ in }
    var onScrollViewReady: @MainActor (UIScrollView?) -> Void = { _ in }

    private var metricContext: MetricContext {
        MetricContext(isStreaming: isStreaming)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            metricContext: metricContext,
            onMetrics: onMetrics,
            onContentSizeChange: onContentSizeChange,
            onScrollViewReady: onScrollViewReady
        )
    }

    func makeUIView(context: Context) -> ObserverView {
        ObserverView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        context.coordinator.onMetrics = onMetrics
        context.coordinator.onContentSizeChange = onContentSizeChange
        context.coordinator.onScrollViewReady = onScrollViewReady
        uiView.coordinator = context.coordinator
        context.coordinator.updateMetricContext(metricContext)

        context.coordinator.attachIfNeeded(from: uiView, delivery: .deferred)
    }

    static func dismantleUIView(_ uiView: ObserverView, coordinator: Coordinator) {
        uiView.coordinator = nil
        coordinator.detach()
    }

    struct MetricContext: Equatable {
        let isStreaming: Bool
    }

    @MainActor
    final class ObserverView: UIView {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator?.attachIfNeeded(from: self, delivery: .deferred)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attachIfNeeded(from: self, delivery: .deferred)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.reportMetrics(delivery: .deferred)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        enum MetricDelivery {
            case immediate
            case deferred
        }

        var onMetrics: @MainActor (ChatScrollMetrics) -> Void
        var onContentSizeChange: @MainActor (CGSize) -> Void
        var onScrollViewReady: @MainActor (UIScrollView?) -> Void

        private weak var scrollView: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var metricContext: MetricContext
        private var lastMetrics: ChatScrollMetrics?
        private var lastReportedContentSize: CGSize?
        private var pendingMetrics: ChatScrollMetrics?
        private var hasScheduledMetricDelivery = false

        init(
            metricContext: MetricContext,
            onMetrics: @escaping @MainActor (ChatScrollMetrics) -> Void,
            onContentSizeChange: @escaping @MainActor (CGSize) -> Void,
            onScrollViewReady: @escaping @MainActor (UIScrollView?) -> Void
        ) {
            self.metricContext = metricContext
            self.onMetrics = onMetrics
            self.onContentSizeChange = onContentSizeChange
            self.onScrollViewReady = onScrollViewReady
        }

        func updateMetricContext(_ newContext: MetricContext) {
            guard metricContext != newContext else { return }

            metricContext = newContext
            lastMetrics = nil
        }

        func attachIfNeeded(from view: UIView, delivery: MetricDelivery) {
            guard let scrollView = enclosingScrollView(for: view) else { return }

            guard scrollView !== self.scrollView else {
                onScrollViewReady(scrollView)
                reportMetrics(delivery: delivery)
                return
            }

            observations.removeAll()
            lastMetrics = nil
            lastReportedContentSize = scrollView.contentSize
            self.scrollView = scrollView
            onScrollViewReady(scrollView)
            // Establish the app-facing baseline before observing later growth;
            // this snapshot is not itself a follow request.
            onContentSizeChange(scrollView.contentSize)

            observations = [
                scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    Self.reportObservedMetrics(for: self)
                },
                scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                    Self.reportObservedContentSize(for: self)
                    Self.reportObservedMetrics(for: self)
                }
            ]

            reportMetrics(delivery: delivery)
        }

        func detach() {
            observations.removeAll()
            lastMetrics = nil
            pendingMetrics = nil
            hasScheduledMetricDelivery = false
            lastReportedContentSize = nil
            scrollView = nil
            onScrollViewReady(nil)
        }

        func reportMetrics(delivery: MetricDelivery) {
            guard let scrollView else { return }

            let inset = scrollView.adjustedContentInset
            let visibleHeight = scrollView.bounds.height - inset.top - inset.bottom
            guard visibleHeight > 0 else { return }

            let currentOffset = scrollView.contentOffset.y + inset.top
            let maximumOffset = scrollView.contentSize.height - visibleHeight
            // Clamp short-content bounce/overscroll out of the app-owned
            // follow state. Signed distance made every content-size KVO pass
            // look like a new recovery request and could feed scrollTo back
            // into this observer repeatedly.
            let distanceFromBottom = max(0, maximumOffset - currentOffset)
            let isDirectlyInteracting = scrollView.isDragging || scrollView.isTracking
            let metrics = ChatScrollMetrics(
                distanceFromBottom: distanceFromBottom,
                isUserInteracting: isDirectlyInteracting || scrollView.isDecelerating,
                isDirectlyInteracting: isDirectlyInteracting,
                isDecelerating: scrollView.isDecelerating
            )
            guard metrics != lastMetrics else { return }

            lastMetrics = metrics

            switch delivery {
            case .immediate:
                pendingMetrics = nil
                hasScheduledMetricDelivery = false
                onMetrics(metrics)
            case .deferred:
                if metrics.isDirectlyInteracting {
                    // A drag must invalidate restore before a later main-queue
                    // geometry callback can reissue the saved scroll target.
                    pendingMetrics = nil
                    hasScheduledMetricDelivery = false
                    onMetrics(metrics)
                    return
                }

                pendingMetrics = metrics
                guard !hasScheduledMetricDelivery else { return }

                hasScheduledMetricDelivery = true
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let metrics = self.pendingMetrics
                        self.pendingMetrics = nil
                        self.hasScheduledMetricDelivery = false
                        guard let metrics, self.lastMetrics == metrics else { return }
                        self.onMetrics(metrics)
                    }
                }
            }
        }

        nonisolated private static func reportObservedMetrics(for coordinator: Coordinator?) {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak coordinator] in
                    MainActor.assumeIsolated {
                        coordinator?.reportMetrics(delivery: .deferred)
                    }
                }
                return
            }

            MainActor.assumeIsolated {
                coordinator?.reportMetrics(delivery: .deferred)
            }
        }

        nonisolated private static func reportObservedContentSize(for coordinator: Coordinator?) {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak coordinator] in
                    MainActor.assumeIsolated {
                        coordinator?.reportContentSizeIfChanged()
                    }
                }
                return
            }

            MainActor.assumeIsolated {
                coordinator?.reportContentSizeIfChanged()
            }
        }

        private func reportContentSizeIfChanged() {
            guard let scrollView,
                  scrollView.contentSize != lastReportedContentSize
            else { return }

            lastReportedContentSize = scrollView.contentSize
            onContentSizeChange(scrollView.contentSize)
        }

        private func enclosingScrollView(for view: UIView) -> UIScrollView? {
            var current = view.superview

            while let candidate = current {
                if let scrollView = candidate as? UIScrollView {
                    return scrollView
                }

                current = candidate.superview
            }

            return nil
        }
    }
}

/// Pins a subtree to left-to-right regardless of the surrounding chat layout
/// direction, so code, math, data tables, tool-call bodies, file paths, and
/// images never render mirrored inside an RTL message (issue #259). A fixed
/// `layoutDirection` also isolates the subtree's bidi resolution from the parent
/// paragraph direction.
///
/// Forcing LTR also changes how the *parent* resolves this view's
/// `.leading`/`.trailing` alignment guides: an LTR child inside an RTL
/// `VStack(alignment: .leading)` reports its leading edge as its physical left,
/// so the RTL parent — which pins `.leading` to its right edge — would hug or push
/// a narrower-than-container child off the wrong side. When the parent is RTL we
/// remap the guides back to the parent's expectation; in LTR (the default) the
/// guide closures return the unmodified values, so it is a no-op.
private struct ForcedLeftToRightModifier: ViewModifier {
    @Environment(\.layoutDirection) private var parentDirection

    func body(content: Content) -> some View {
        content
            .environment(\.layoutDirection, .leftToRight)
            .alignmentGuide(.leading) { dimensions in
                parentDirection == .rightToLeft ? dimensions[.trailing] : dimensions[.leading]
            }
            .alignmentGuide(.trailing) { dimensions in
                parentDirection == .rightToLeft ? dimensions[.leading] : dimensions[.trailing]
            }
    }
}

extension View {
    func forcedLeftToRight() -> some View {
        modifier(ForcedLeftToRightModifier())
    }
}

struct ChatVerticalScrollAxisGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> ChatVerticalScrollAxisGuardView {
        ChatVerticalScrollAxisGuardView()
    }

    func updateUIView(_ uiView: ChatVerticalScrollAxisGuardView, context: Context) {
        // The transcript flips wholesale under the chat RTL toggle (#259); read
        // the resolved direction here so the guard pins the horizontal offset to
        // the layout-direction-aware leading edge (folds in #139).
        uiView.isRightToLeft = context.environment.layoutDirection == .rightToLeft
        uiView.attachToNearestScrollViewIfNeeded()
    }

    static func dismantleUIView(_ uiView: ChatVerticalScrollAxisGuardView, coordinator: ()) {
        uiView.detach()
    }
}

@MainActor
final class ChatVerticalScrollAxisGuardView: UIView {
    private weak var guardedScrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []

    /// Whether the guarded transcript is laid out right-to-left (#259). Drives
    /// which physical edge the horizontal offset rests against; re-clamps on change.
    var isRightToLeft = false {
        didSet {
            guard oldValue != isRightToLeft else { return }
            clampHorizontalOffset()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard superview != nil else {
            detach()
            return
        }

        attachToNearestScrollViewIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachToNearestScrollViewIfNeeded()
    }

    func attachToNearestScrollViewIfNeeded() {
        guard let scrollView = enclosingScrollView() else { return }

        guard scrollView !== guardedScrollView else {
            clampHorizontalOffset()
            return
        }

        observations.removeAll()
        guardedScrollView = scrollView
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true

        observations = [
            scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                Self.clampObservedHorizontalOffset(for: self)
            },
            scrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                Self.clampObservedHorizontalOffset(for: self)
            },
            // Under RTL the pinned rest offset depends on contentSize.width, so a
            // width change (a wide table/streaming code block loading) must re-clamp
            // immediately instead of waiting for the next offset/bounds change (#259).
            scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                Self.clampObservedHorizontalOffset(for: self)
            }
        ]

        clampHorizontalOffset()
    }

    func detach() {
        observations.removeAll()
        guardedScrollView = nil
    }

    private func enclosingScrollView() -> UIScrollView? {
        sequence(first: superview, next: { $0?.superview })
            .first { $0 is UIScrollView } as? UIScrollView
    }

    private func clampHorizontalOffset() {
        guard let scrollView = guardedScrollView else { return }

        let pinnedX = Self.pinnedHorizontalOffsetX(
            isRightToLeft: isRightToLeft,
            adjustedInset: scrollView.adjustedContentInset,
            contentSize: scrollView.contentSize,
            boundsSize: scrollView.bounds.size
        )
        guard abs(scrollView.contentOffset.x - pinnedX) > 0.5 else { return }

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-baseline") {
            Logger(subsystem: "com.maurice.semreh", category: "NativeBaseline").debug("event=production_axis_clamp x=\(scrollView.contentOffset.x, privacy: .public) targetX=\(pinnedX, privacy: .public) y=\(scrollView.contentOffset.y, privacy: .public)")
        }
#endif

        var offset = scrollView.contentOffset
        offset.x = pinnedX
        scrollView.setContentOffset(offset, animated: false)
    }

    /// The horizontal content offset the transcript should rest at, pinned to the
    /// layout-direction-aware *leading* edge so the vertical-only transcript never
    /// drifts sideways (#130) under either direction (#139/#259).
    ///
    /// LTR leading is the physical left, so it rests at `-left inset` exactly as
    /// before — this branch is byte-for-byte the prior behavior. RTL leading is
    /// the physical right, so it rests at the content's trailing edge
    /// (`contentSize.width + right inset - viewport width`), clamped to never fall
    /// below the LTR minimum. When the transcript has no horizontal overflow and
    /// no horizontal inset — its normal case — both branches resolve to `0`.
    nonisolated static func pinnedHorizontalOffsetX(
        isRightToLeft: Bool,
        adjustedInset: UIEdgeInsets,
        contentSize: CGSize,
        boundsSize: CGSize
    ) -> CGFloat {
        let leftEdge = -adjustedInset.left
        guard isRightToLeft else { return leftEdge }

        let rightEdge = contentSize.width + adjustedInset.right - boundsSize.width
        return max(leftEdge, rightEdge)
    }

    nonisolated private static func clampObservedHorizontalOffset(for guardView: ChatVerticalScrollAxisGuardView?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak guardView] in
                MainActor.assumeIsolated {
                    guardView?.clampHorizontalOffset()
                }
            }
            return
        }

        MainActor.assumeIsolated {
            guardView?.clampHorizontalOffset()
        }
    }
}

struct AssistantTypingIndicatorView: View {
    var body: some View {
        Text("Thinking")
            .font(AppFont.subheadline())
            .modifier(ReasoningTextShineModifier(isActive: true))
            .padding(.leading, 4)
            .padding(.vertical, 8)
            .accessibilityLabel("Semreh is preparing a response")
    }
}

struct BottomComposerMaterialFade: View {
    @Environment(\.colorScheme) private var colorScheme

    let composerHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Rectangle()
                    .fill(.bar)

                if colorScheme == .dark {
                    Rectangle()
                        .fill(Color.black.opacity(0.58))
                }
            }
            .frame(height: max(96, composerHeight + 34))
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.18), location: 0.18),
                        .init(color: .black.opacity(0.72), location: 0.46),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct StreamRecoveryStatusView: View {
    let state: ActiveStreamRecoveryState

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)

            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.88)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .idle:
            return String(localized: "Stream active")
        case .checking:
            return String(localized: "Checking stream")
        case .reconnecting:
            return String(localized: "Reconnecting stream")
        }
    }
}

struct ChatTranscriptLoadingSkeletonView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .tint(.secondary)

            Text("Loading conversation…")
                .font(AppFont.body())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading conversation")
    }
}

struct ChatOfflineCacheBanner: View {
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .imageScale(.small)

            Text("Offline — viewing cached version")
                .font(.subheadline)
                .fontWeight(.semibold)

            Spacer()
        }
        .foregroundStyle(SemrehVisualTheme.statusWarning(for: palette))
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(SemrehVisualTheme.statusWarning(for: palette).opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

struct PinnedLocalNoticeStack: View {
    let notices: [String]
    @Environment(\.appColorPalette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SemrehVisualTheme.statusPositive(for: palette))

                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.separator).opacity(0.45), lineWidth: 0.5)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notices.joined(separator: "\n"))
    }
}
