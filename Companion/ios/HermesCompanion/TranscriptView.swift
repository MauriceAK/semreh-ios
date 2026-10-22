import SwiftUI
import UIKit

struct TranscriptView: UIViewControllerRepresentable {
    let messages: [ChatMessage]
    let hasMore: Bool
    let loading: Bool
    let latestRevision: UUID
    var viewportInsets = UIEdgeInsets(top: 36, left: 0, bottom: 18, right: 0)
    var activity: TranscriptActivity = .idle
    var sessionID: String?
    var conversationContext: ConversationContext?
    var sends: [SendPresentationIntent] = []
    var readerRestoration: ReaderRestoration?
    var dockGeometry: TranscriptDockGeometry?
    var onReaderPosition: ((ReaderPosition, ConversationContext) -> Void)?
    var onSendPresentation: ((SendPresentationIntent, SendPresentationOutcome) -> Void)?
    var onUserScrollBegan: (() -> Void)?
    let onOlder: () -> Void
    let onReadingHistory: (Bool) -> Void

    func makeUIViewController(context: Context) -> TranscriptController { TranscriptController() }
    func updateUIViewController(_ controller: TranscriptController, context: Context) {
        controller.onReaderPosition = onReaderPosition
        controller.onSendPresentation = onSendPresentation
        controller.onOlder = onOlder
        controller.onReadingHistory = onReadingHistory
        controller.onUserScrollBegan = onUserScrollBegan
        controller.render(messages: messages, hasMore: hasMore, loading: loading, latestRevision: latestRevision, sessionID: sessionID, viewportInsets: viewportInsets, activity: activity, conversationContext: conversationContext, sends: sends, readerRestoration: readerRestoration, dockGeometry: dockGeometry)
    }
}

@MainActor
final class TranscriptDockGeometry {
    weak var view: UIView?
    func frame(in window: UIWindow) -> CGRect? {
        guard let view, view.window === window else { return nil }
        let layer = view.layer.presentation() ?? view.layer
        return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
    }
}

struct TranscriptDockProbe: UIViewRepresentable {
    let geometry: TranscriptDockGeometry
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        geometry.view = view
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct SendPresentationIntent: Equatable {
    let context: ConversationContext
    let operationID: String
    var renderID: String { "outbound:" + operationID.lowercased() }
}

enum SendPresentationOutcome: Equatable { case completed, cancelled }

enum TranscriptActivity: Equatable {
    case idle, working, waiting, stopping

    var label: String {
        switch self {
        case .idle: ""
        case .working: "Hermes is working"
        case .waiting: "Hermes needs you"
        case .stopping: "Hermes is stopping"
        }
    }
}

@MainActor
final class TranscriptController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private let older = UIButton(type: .system)
    private let activityBubble = TranscriptActivityBubble()
    private var activity: TranscriptActivity = .idle
    private var requestedActivity: TranscriptActivity = .idle
    private var conversationContext: ConversationContext?
    private var readerRestorationID: UUID?
    private var dockGeometry: TranscriptDockGeometry?
    private enum SendFooterReservation: Equatable {
        case none, pending, presented(String)
    }
    private var sendFooterReservation = SendFooterReservation.none
    private struct PresentationGeometry: Equatable {
        let row: CGRect
        let viewport: CGRect
        let dock: CGRect?
    }
    private enum PresentationPhase {
        case pending
        case sampled(PresentationGeometry)
        case settled(PresentationGeometry)
    }
    private struct SendPresentation {
        let intent: SendPresentationIntent
        var phase = PresentationPhase.pending
    }
    private var sendPresentations: [SendPresentation] = []
    private var consumedSends = Set<String>()
    private var presentationLink: CADisplayLink?
    private lazy var presentationTicker = TranscriptPresentationTicker(controller: self)
    private var messages: [ChatMessage] = []
    private var firstLayout = true
    private var applying = false
    private var followingLatest = true
    private var latestRevision: UUID?
    private var viewportIntent = UUID()
    private var sessionID: String?
    private struct LatestJump {
        var startOffset: CGFloat
        var started: CFTimeInterval?
        var moved = false
        let span: ChatPerformance.Token?
    }
    private var latestJump: LatestJump?
    private var jumpLink: CADisplayLink?
    private lazy var jumpTicker = TranscriptJumpTicker(controller: self)
    var isJumpingToLatest: Bool { latestJump != nil }
    private var scrollSpan: ChatPerformance.Token?
    private var sizingTask: Task<Void, Never>?
    var onReaderPosition: ((ReaderPosition, ConversationContext) -> Void)?
    var onSendPresentation: ((SendPresentationIntent, SendPresentationOutcome) -> Void)?
    var onOlder: (() -> Void)?
    var onReadingHistory: ((Bool) -> Void)?
    var onUserScrollBegan: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        table.backgroundColor = .clear
        table.contentInsetAdjustmentBehavior = .never
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .interactive
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 90
        table.contentInset = UIEdgeInsets(top: 36, left: 0, bottom: 18, right: 0)
        table.register(BubbleCell.self, forCellReuseIdentifier: "bubble")
        table.accessibilityIdentifier = "transcript"
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([table.topAnchor.constraint(equalTo: view.topAnchor), table.bottomAnchor.constraint(equalTo: view.bottomAnchor), table.leadingAnchor.constraint(equalTo: view.leadingAnchor), table.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        older.setTitle("Load earlier messages", for: .normal)
        older.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        older.accessibilityIdentifier = "loadOlder"
        older.addTarget(self, action: #selector(loadEarlier), for: .touchUpInside)
        NotificationCenter.default.addObserver(self, selector: #selector(suspendPresentation), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }
    func render(messages: [ChatMessage], hasMore: Bool, loading: Bool, latestRevision: UUID,
                sessionID: String?, viewportInsets: UIEdgeInsets, activity: TranscriptActivity,
                conversationContext: ConversationContext? = nil, sends: [SendPresentationIntent] = [],
                readerRestoration: ReaderRestoration? = nil, dockGeometry: TranscriptDockGeometry? = nil) {
        let publication = ChatPerformance.shared.begin(.transcriptPublication, count: messages.count)
        defer { ChatPerformance.shared.end(publication) }
        self.dockGeometry = dockGeometry
        loadViewIfNeeded()
        if self.conversationContext != conversationContext {
            suspendPresentation()
            consumedSends.removeAll()
            sendFooterReservation = .none
            readerRestorationID = nil
            cancelLatestJump()
            firstLayout = true
            followingLatest = true
            self.conversationContext = conversationContext
        }
        let current = sends.filter { $0.context == conversationContext }
        consumedSends.formIntersection(current.map(\.operationID))
        sendPresentations.removeAll { pending in !current.contains(pending.intent) }
        if activity == .idle {
            switch sendFooterReservation {
            case .pending where sendPresentations.isEmpty:
                sendFooterReservation = .none
            case .presented(let renderID) where !messages.contains(where: { $0.renderID == renderID }):
                sendFooterReservation = .none
            default: break
            }
        }
        for intent in current where !consumedSends.contains(intent.operationID) && !sendPresentations.contains(where: { $0.intent == intent }) {
            sendPresentations.append(.init(intent: intent))
            if sendFooterReservation == .none { sendFooterReservation = .pending }
            followingLatest = true
            viewportIntent = UUID()
        }
        if requestedActivity != .idle && activity == .idle { sendFooterReservation = .none }
        requestedActivity = activity
        UIView.performWithoutAnimation {
            updateChrome(viewportInsets: viewportInsets, activity: presentedActivity)
            update(messages: messages, hasMore: hasMore, loading: loading, latestRevision: latestRevision, sessionID: sessionID)
            if let readerRestoration, readerRestorationID != readerRestoration.id {
                readerRestorationID = readerRestoration.id
                if sendPresentations.isEmpty { restoreReader(readerRestoration.position) }
            }
        }
        resumePresentation()
        recordPresentation()
    }
    private var presentedActivity: TranscriptActivity {
        if requestedActivity == .working && activity != .working && !sendPresentations.isEmpty { return .idle }
        return requestedActivity
    }
    func updateChrome(viewportInsets: UIEdgeInsets, activity: TranscriptActivity) {
        let chrome = ChatPerformance.shared.beginStage(.chrome, count: messages.count)
        defer { ChatPerformance.shared.endStage(chrome) }
        loadViewIfNeeded()
        let needsFooter = activity != .idle || sendFooterReservation != .none || !sendPresentations.isEmpty
        guard table.contentInset != viewportInsets || self.activity != activity || (table.tableFooterView != nil) != needsFooter else { return }
        ChatPerformance.shared.add(.chromeChanges)
        let anchor = visibleAnchor()
        applying = true
        table.contentInset = viewportInsets
        table.verticalScrollIndicatorInsets = viewportInsets
        self.activity = activity
        activityBubble.configure(activity)
        activityBubble.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: 52)
        if (table.tableFooterView != nil) != needsFooter { table.tableFooterView = needsFooter ? activityBubble : nil }
        ChatPerformance.shared.measure(.chromeLayout, count: messages.count) { table.layoutIfNeeded() }
        if followingLatest { scrollToBottom() }
        else if let anchor, let index = messages.firstIndex(where: { $0.renderID == anchor.renderID }) { restoreAnchor(anchor, at: index) }
        applying = false
        logGeometry("chrome")
    }
    private func resumePresentation() {
        guard !sendPresentations.isEmpty, presentationLink == nil, followingLatest, view.window != nil else { return }
        let link = CADisplayLink(target: presentationTicker, selector: #selector(TranscriptPresentationTicker.tick(_:)))
        presentationLink = link
        link.add(to: .main, forMode: .common)
    }
    fileprivate func advancePresentation() {
        guard followingLatest, !table.isDragging, !table.isDecelerating, view.window != nil else {
            pausePresentation()
            return
        }
        guard latestJump == nil, sizingTask == nil, let window = view.window else { return }
        table.layoutIfNeeded()
        var viewport = table.convert(table.bounds, to: window).inset(by: table.adjustedContentInset)
        let dock = dockGeometry?.frame(in: window)
        if let dock {
            viewport.size.height = max(0, min(viewport.maxY, dock.minY) - viewport.minY)
        }
        var completed: [SendPresentationIntent] = []
        for index in sendPresentations.indices {
            let intent = sendPresentations[index].intent
            guard let row = messages.firstIndex(where: { $0.renderID == intent.renderID }),
                  let cell = table.cellForRow(at: IndexPath(row: row, section: 0)) as? BubbleCell else { continue }
            let layer = cell.layer.presentation() ?? cell.layer
            let frame = layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
            let visible = frame.intersection(viewport)
            guard visible.width >= 44, visible.height >= min(32, frame.height), frame.maxY <= viewport.maxY + 1 else {
                sendPresentations[index].phase = .pending
                continue
            }
            let geometry = PresentationGeometry(row: frame, viewport: viewport, dock: dock)
            switch sendPresentations[index].phase {
            case .settled(let previous) where previous == geometry:
                completed.append(intent)
            case .sampled(let previous) where previous == geometry:
                sendPresentations[index].phase = .settled(geometry)
            default:
                sendPresentations[index].phase = .sampled(geometry)
            }
        }
        let newestCompleted = sendPresentations.last.map { completed.contains($0.intent) } == true
        for intent in completed {
            if sendFooterReservation != .none { sendFooterReservation = .presented(intent.renderID) }
            ChatPerformance.shared.markSend(.sendEntranceCompleted, operationID: intent.operationID)
            consumedSends.insert(intent.operationID)
            sendPresentations.removeAll { $0.intent == intent }
            onSendPresentation?(intent, .completed)
        }
        if newestCompleted {
            let superseded = sendPresentations.map(\.intent)
            sendPresentations.removeAll()
            for intent in superseded {
                consumedSends.insert(intent.operationID)
                onSendPresentation?(intent, .cancelled)
            }
        }
        if sendPresentations.isEmpty {
            pausePresentation()
            activity = requestedActivity
            activityBubble.configure(activity)
            recordPresentation()
        }
    }
    private func pausePresentation() {
        presentationLink?.invalidate()
        presentationLink = nil
        for index in sendPresentations.indices {
            sendPresentations[index].phase = .pending
        }
    }
    @objc private func suspendPresentation() {
        viewportIntent = UUID()
        pausePresentation()
        let cancelled = sendPresentations.map(\.intent)
        sendPresentations.removeAll()
        for intent in cancelled {
            consumedSends.insert(intent.operationID)
            onSendPresentation?(intent, .cancelled)
        }
    }
    private func restoreReader(_ position: ReaderPosition) {
        cancelLatestJump()
        viewportIntent = UUID()
        switch position {
        case .latest:
            followingLatest = true
            scrollToBottom()
        case .anchored(let id, let offset):
            guard let row = messages.firstIndex(where: { $0.renderID == id || $0.id == id }) else { return }
            followingLatest = false
            firstLayout = false
            restoreAnchor((id, CGFloat(offset) + table.adjustedContentInset.top), at: row)
        }
    }
    private func recordReaderPosition() {
        guard let conversationContext else { return }
        if followingLatest { onReaderPosition?(.latest, conversationContext) }
        else if let anchor = visibleAnchor() {
            onReaderPosition?(.anchored(messageID: anchor.renderID, offsetFromUsableTop: Double(anchor.offset - table.adjustedContentInset.top)), conversationContext)
        }
    }
    @objc private func loadEarlier() {
        cancelLatestJump()
        followingLatest = false
        viewportIntent = UUID()
        onOlder?()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if firstLayout && !messages.isEmpty && table.bounds.height > 0 {
            ChatPerformance.shared.measure(.initialLayout, count: messages.count) { table.layoutIfNeeded() }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--fixture-top") { followingLatest = false; table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false) }
            else { scrollToBottom() }
            #else
            scrollToBottom()
            #endif
            firstLayout = false
        } else if followingLatest && (!messages.isEmpty || activity != .idle) { scrollToBottom() }
        resumePresentation()
        logGeometry("layout")
        recordPresentation()
    }
    private func recordPresentation() {
        guard ChatPerformance.shared.isRecording, table.window != nil, table.bounds.width > 0, table.bounds.height > 0 else { return }
        let viewport = table.bounds.inset(by: table.adjustedContentInset)
        let visibleRows = (table.indexPathsForVisibleRows ?? []).filter { table.rectForRow(at: $0).intersects(viewport) }.map(\.row)
        let footerVisible = activity == .working && table.tableFooterView != nil && activityBubble.frame.intersects(viewport)
        ChatPerformance.shared.laidOut(messages, visibleRows: visibleRows, sessionID: sessionID, workingFooterVisible: footerVisible)
    }
    private func logGeometry(_ phase: String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fixture-geometry") {
            print("CHAT_TABLE phase=\(phase) frame=\(table.convert(table.bounds, to: nil)) bounds=\(table.bounds.size) inset=\(table.contentInset) content=\(table.contentSize) offset=\(table.contentOffset) following=\(followingLatest)")
        }
        #endif
    }
    func update(messages newMessages: [ChatMessage], hasMore: Bool, loading: Bool, latestRevision: UUID, sessionID: String? = nil) {
        var preparation = ChatPerformance.shared.beginStage(.diffPreparation, count: newMessages.count)
        defer { ChatPerformance.shared.endStage(preparation) }
        loadViewIfNeeded()
        let changedSession = self.sessionID != sessionID
        if changedSession {
            cancelLatestJump()
            viewportIntent = UUID()
            followingLatest = true
            firstLayout = true
            self.sessionID = sessionID
        }
        older.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: hasMore ? 48 : 0)
        older.setTitle(loading ? "Loading earlier messages…" : "Load earlier messages", for: .normal)
        older.isEnabled = !loading
        if hasMore { table.tableHeaderView = older } else { table.tableHeaderView = nil }
        let requestedLatest = !changedSession && self.latestRevision != nil && self.latestRevision != latestRevision
        self.latestRevision = latestRevision
        if requestedLatest {
            cancelLatestJump()
            followingLatest = true
            viewportIntent = UUID()
            latestJump = LatestJump(startOffset: table.contentOffset.y, span: ChatPerformance.shared.begin(.latestJump))
        }
        guard messages != newMessages else {
            ChatPerformance.shared.endStage(preparation)
            preparation = nil
            if requestedLatest {
                ChatPerformance.shared.measure(.updateLayout, count: messages.count) { table.layoutIfNeeded() }
                beginLatestJump()
                ChatPerformance.shared.mark(.transcriptLaidOut, count: messages.count)
            }
            return
        }
        let updateSpan = ChatPerformance.shared.begin(.transcriptUpdate, count: newMessages.count)
        applying = true
        defer {
            applying = false
            ChatPerformance.shared.end(updateSpan)
            ChatPerformance.shared.mark(.transcriptLaidOut, count: messages.count)
        }
        let wasAtBottom = followingLatest
        let anchor = visibleAnchor()
        let oldMessages = messages
        messages = newMessages
        let oldRenderIDs = oldMessages.map(\.renderID)
        let renderIDs = messages.map(\.renderID)
        if oldRenderIDs == renderIDs {
            let changed = messages.indices.filter { oldMessages[$0] != messages[$0] }.map { IndexPath(row: $0, section: 0) }
            ChatPerformance.shared.add(.changedRows, count: changed.count)
            if !changed.isEmpty {
                let deliveryOnly = Set(changed.filter { BubbleCell.canUpdateDelivery(from: oldMessages[$0.row], to: messages[$0.row]) })
                let contentChanges = changed.filter { !deliveryOnly.contains($0) }
                let appending = contentChanges.allSatisfy { BubbleCell.provisionalSuffix(from: oldMessages[$0.row], to: messages[$0.row]) != nil }
                ChatPerformance.shared.endStage(preparation)
                preparation = nil
                UIView.performWithoutAnimation {
                    for path in deliveryOnly {
                        (table.cellForRow(at: path) as? BubbleCell)?.updateDelivery(messages[path.row])
                    }
                    if !contentChanges.isEmpty && appending {
                        for path in contentChanges {
                            (table.cellForRow(at: path) as? BubbleCell)?.appendProvisional(messages[path.row])
                        }
                        ChatPerformance.shared.measure(.tableBatch, count: contentChanges.count) { table.performBatchUpdates(nil) }
                    } else if !contentChanges.isEmpty {
                        ChatPerformance.shared.measure(.tableReloadRows, count: contentChanges.count) { table.reloadRows(at: contentChanges, with: .none) }
                    }
                    ChatPerformance.shared.measure(.updateLayout, count: messages.count) { table.layoutIfNeeded() }
                }
            }
        } else {
            ChatPerformance.shared.add(.changedRows, count: messages.count)
            ChatPerformance.shared.endStage(preparation)
            preparation = nil
            UIView.performWithoutAnimation {
                ChatPerformance.shared.measure(.tableReload, count: messages.count) { table.reloadData() }
                ChatPerformance.shared.measure(.updateLayout, count: messages.count) { table.layoutIfNeeded() }
            }
        }
        ChatPerformance.shared.endStage(preparation)
        preparation = nil
        let prepended = !oldRenderIDs.isEmpty && renderIDs.count > oldRenderIDs.count && renderIDs.suffix(oldRenderIDs.count).elementsEqual(oldRenderIDs)
        if prepended && !oldMessages.isEmpty && !requestedLatest {
            cancelLatestJump()
            followingLatest = false
            viewportIntent = UUID()
            onReadingHistory?(true)
        }
        if requestedLatest {
            beginLatestJump()
        } else if wasAtBottom && !prepended {
            scrollToBottom()
        } else if let anchor, let index = messages.firstIndex(where: { $0.renderID == anchor.renderID }) {
            restoreAnchor(anchor, at: index)
        }
        if oldMessages.isEmpty { firstLayout = true; view.setNeedsLayout() }
    }
    private func restoreAnchor(_ anchor: (renderID: String, offset: CGFloat), at index: Int) {
        let correction = ChatPerformance.shared.beginStage(.viewportCorrection)
        defer { ChatPerformance.shared.endStage(correction) }
        let path = IndexPath(row: index, section: 0)
        table.scrollToRow(at: path, at: .top, animated: false)
        ChatPerformance.shared.measure(.anchorLayout, count: messages.count) { table.layoutIfNeeded() }
        table.contentOffset.y = table.rectForRow(at: path).minY - anchor.offset
        ChatPerformance.shared.measure(.anchorLayout, count: messages.count) { table.layoutIfNeeded() }
    }
    private var isAtBottom: Bool { table.contentSize.height - table.contentOffset.y - table.bounds.height + table.adjustedContentInset.bottom < 100 }
    private func visibleAnchor() -> (renderID: String, offset: CGFloat)? {
        guard let index = table.indexPathsForVisibleRows?.first, messages.indices.contains(index.row) else { return nil }
        return (messages[index.row].renderID, table.rectForRow(at: index).minY - table.contentOffset.y)
    }
    private var bottomOffset: CGFloat {
        max(-table.adjustedContentInset.top, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
    }
    private func scrollToBottom() {
        guard latestJump == nil else { return }
        let correction = ChatPerformance.shared.beginStage(.viewportCorrection)
        defer { ChatPerformance.shared.endStage(correction) }
        followingLatest = true
        var offset = bottomOffset
        if let target = sendPresentations.last?.intent,
           let row = messages.firstIndex(where: { $0.renderID == target.renderID }) {
            let bottom = table.rectForRow(at: IndexPath(row: row, section: 0)).maxY + 52
            offset = min(offset, max(-table.adjustedContentInset.top, bottom - table.bounds.height + table.adjustedContentInset.bottom))
        }
        table.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
    }
    private func beginLatestJump() {
        guard var jump = latestJump else { return }
        jump.startOffset = table.contentOffset.y
        jump.started = CACurrentMediaTime()
        latestJump = jump
        if UIAccessibility.isReduceMotionEnabled || abs(bottomOffset - jump.startOffset) < 1 {
            finishLatestJump()
            return
        }
        let link = CADisplayLink(target: jumpTicker, selector: #selector(TranscriptJumpTicker.tick(_:)))
        jumpLink = link
        link.add(to: .main, forMode: .common)
    }
    fileprivate func advanceLatestJump(_ link: CADisplayLink) {
        guard var jump = latestJump, let started = jump.started else { return }
        let fraction = min(1, max(0, (link.timestamp - started) / 0.28))
        let eased = 1 - pow(1 - fraction, 3)
        let offset = jump.startOffset + (bottomOffset - jump.startOffset) * eased
        if !jump.moved && abs(offset - table.contentOffset.y) > 0.1 {
            jump.moved = true
            latestJump = jump
            ChatPerformance.shared.mark(.latestViewportMoved)
        }
        table.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        if fraction >= 1 { finishLatestJump() }
    }
    private func finishLatestJump() {
        guard let jump = latestJump else { return }
        if !jump.moved && abs(bottomOffset - table.contentOffset.y) > 0.1 { ChatPerformance.shared.mark(.latestViewportMoved) }
        jumpLink?.invalidate()
        jumpLink = nil
        latestJump = nil
        scrollToBottom()
        ChatPerformance.shared.end(jump.span)
        ChatPerformance.shared.mark(.latestJumpCompleted)
        let context = conversationContext
        let intent = viewportIntent
        Task { @MainActor [weak self] in
            guard let self, self.conversationContext == context, self.viewportIntent == intent, self.followingLatest else { return }
            self.onReadingHistory?(false)
            self.recordReaderPosition()
        }
        resumePresentation()
    }
    private func cancelLatestJump() {
        jumpLink?.invalidate()
        jumpLink = nil
        guard let jump = latestJump else { return }
        latestJump = nil
        ChatPerformance.shared.end(jump.span, outcome: .cancelled)
        ChatPerformance.shared.mark(.latestJumpCancelled)
    }
    @objc private func reduceMotionChanged() {
        if UIAccessibility.isReduceMotionEnabled { finishLatestJump() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelLatestJump()
        suspendPresentation()
    }
    isolated deinit { jumpLink?.invalidate(); presentationLink?.invalidate() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelLatestJump()
        pausePresentation()
        followingLatest = false
        viewportIntent = UUID()
        onUserScrollBegan?()
        ChatPerformance.shared.end(scrollSpan)
        scrollSpan = ChatPerformance.shared.begin(.scroll)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { ChatPerformance.shared.end(scrollSpan); scrollSpan = nil; recordReaderPosition(); resumePresentation() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        ChatPerformance.shared.end(scrollSpan); scrollSpan = nil
        recordReaderPosition()
        resumePresentation()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !applying, !firstLayout, table.isDragging || table.isDecelerating else { return }
        followingLatest = isAtBottom
        onReadingHistory?(!followingLatest)
    }
    private func scheduleSizing() {
        guard sizingTask == nil else { return }
        // Preserve the geometry before formatted text changes any row heights.
        // Later formatting callbacks share this first anchor until layout settles.
        let anchor = visibleAnchor()
        let intent = viewportIntent
        sizingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self else { return }
            let layoutSpan = ChatPerformance.shared.begin(.markdownLayout, count: self.messages.count)
            let batchWait = ChatPerformance.shared.begin(.markdownBatchWait, count: self.messages.count)
            self.applying = true
            UIView.performWithoutAnimation {
                ChatPerformance.shared.measure(.tableBatch, count: self.messages.count) {
                    self.table.performBatchUpdates(nil) { [weak self] _ in
                        guard let self else {
                            ChatPerformance.shared.end(layoutSpan, outcome: .cancelled)
                            ChatPerformance.shared.end(batchWait, outcome: .cancelled)
                            return
                        }
                        ChatPerformance.shared.end(batchWait)
                        ChatPerformance.shared.measure(.sizingLayout, count: self.messages.count) { self.table.layoutIfNeeded() }
                        if !self.table.isDragging && !self.table.isDecelerating {
                            if self.followingLatest { self.scrollToBottom() }
                            else if intent == self.viewportIntent, let anchor, let index = self.messages.firstIndex(where: { $0.renderID == anchor.renderID }) {
                                self.restoreAnchor(anchor, at: index)
                            }
                        }
                        self.applying = false
                        self.sizingTask = nil
                        ChatPerformance.shared.end(layoutSpan)
                        self.recordPresentation()
                    }
                }
            }
        }
    }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        BubbleCell.height(messages[indexPath.row], width: tableView.bounds.width, traits: tableView.traitCollection)
    }
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        self.tableView(tableView, heightForRowAt: indexPath)
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { messages.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "bubble", for: indexPath) as! BubbleCell
        cell.onFormattingWillChange = { [weak self] in self?.scheduleSizing() }
        cell.configure(messages[indexPath.row])
        return cell
    }
}

@MainActor
private final class TranscriptPresentationTicker: NSObject {
    weak var controller: TranscriptController?
    init(controller: TranscriptController) { self.controller = controller }
    @objc func tick(_ link: CADisplayLink) {
        guard let controller else { link.invalidate(); return }
        controller.advancePresentation()
    }
}

@MainActor
private final class TranscriptJumpTicker: NSObject {
    weak var controller: TranscriptController?
    init(controller: TranscriptController) { self.controller = controller }
    @objc func tick(_ link: CADisplayLink) {
        guard let controller else { link.invalidate(); return }
        controller.advanceLatestJump(link)
    }
}

@MainActor
private final class TranscriptActivityBubble: UIView {
    private let bubble = UIView()
    private let dots = (0..<3).map { _ in UIView() }
    private var activity: TranscriptActivity = .idle

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        bubble.isAccessibilityElement = true
        bubble.accessibilityIdentifier = "workingIndicator"
        bubble.accessibilityTraits = .staticText
        bubble.backgroundColor = UIColor(white: 0.13, alpha: 1)
        bubble.layer.cornerRadius = 20
        addSubview(bubble)
        for dot in dots {
            dot.backgroundColor = .secondaryLabel
            dot.layer.cornerRadius = 3.5
            bubble.addSubview(dot)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(updateAnimation), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        bubble.frame = CGRect(x: 16, y: 5, width: 64, height: 40)
        for (index, dot) in dots.enumerated() { dot.frame = CGRect(x: 16 + index * 12, y: 17, width: 7, height: 7) }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); updateAnimation() }
    func configure(_ activity: TranscriptActivity) {
        self.activity = activity
        bubble.isHidden = activity == .idle
        bubble.accessibilityElementsHidden = activity == .idle
        bubble.accessibilityLabel = activity.label
        updateAnimation()
    }
    @objc private func updateAnimation() {
        for (index, dot) in dots.enumerated() {
            dot.layer.removeAllAnimations()
            dot.alpha = 0.65
            guard activity == .working, window != nil, !UIAccessibility.isReduceMotionEnabled else { continue }
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.3, 1, 0.3]
            pulse.keyTimes = [0, 0.4, 1]
            pulse.duration = 1.2
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.18
            pulse.repeatCount = .infinity
            dot.layer.add(pulse, forKey: "workingPulse")
            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
            bounce.values = [0, -3, 0]
            bounce.keyTimes = pulse.keyTimes
            bounce.duration = pulse.duration
            bounce.beginTime = pulse.beginTime
            bounce.repeatCount = .infinity
            dot.layer.add(bounce, forKey: "workingBounce")
        }
    }
}

@MainActor
final class BubbleCell: UITableViewCell {
    private let bubble = UIView()
    private let textView = UITextView(usingTextLayoutManager: false)
    private let deliveryLabel = UILabel()
    private var bubbleBottom: NSLayoutConstraint!
    private var left: NSLayoutConstraint!
    private var right: NSLayoutConstraint!
    private var formatTask: Task<Void, Never>?
    private var messageID: String?
    private var configuredMessage: ChatMessage?
    private var configuredFont: UIFont?
    var onFormattingWillChange: (() -> Void)?
    private static let formatting = MarkdownCache()
    private final class RenderedMarkdown {
        let text: NSAttributedString
        let revision = UUID()
        let fullyParsed: Bool
        init(_ text: NSAttributedString, fullyParsed: Bool = true) {
            self.text = text
            self.fullyParsed = fullyParsed
        }
    }
    private static let renderedCache: NSCache<NSString, RenderedMarkdown> = {
        let cache = NSCache<NSString, RenderedMarkdown>()
        cache.countLimit = 500
        cache.totalCostLimit = TranscriptWindow.maxBytes
        return cache
    }()

    private static let heightCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 1000
        cache.totalCostLimit = 2 * TranscriptWindow.maxBytes
        return cache
    }()
    private static let measuringText = UITextView(usingTextLayoutManager: false)
    private static var measuringMessage: ChatMessage?
    private static var measuringWidth: CGFloat = 0
    private static var measuringFont: UIFont?
    private static var measuringWasFormatted = false

    static func canUpdateDelivery(from old: ChatMessage, to new: ChatMessage) -> Bool {
        old.renderID == new.renderID && old.role == "user" && new.role == "user"
            && old.displayText == new.displayText && old.deliveryLabel != nil && new.deliveryLabel != nil
    }

    static func provisionalSuffix(from old: ChatMessage, to new: ChatMessage) -> String? {
        guard old.provisional, new.provisional, old.id == new.id, old.role == new.role,
              old.attachments == new.attachments, old.deliveryLabel == new.deliveryLabel else { return nil }
        let previous = old.displayText
        let next = new.displayText
        // Use exact UTF-16 units rather than grapheme counts: an incoming chunk
        // may extend the previous grapheme with a combining mark or ZWJ sequence.
        guard next.utf16.starts(with: previous.utf16) else { return nil }
        return (next as NSString).substring(from: previous.utf16.count)
    }
    private static func append(_ suffix: String, to view: UITextView, font: UIFont) {
        guard !suffix.isEmpty else { return }
        let assignment = ChatPerformance.shared.beginStage(.textAssignment, count: suffix.utf8.count)
        defer { ChatPerformance.shared.endStage(assignment) }
        ChatPerformance.shared.add(.textAppendedUTF8Bytes, count: suffix.utf8.count)
        view.textStorage.append(NSAttributedString(string: suffix, attributes: [
            .font: font, .foregroundColor: view.textColor ?? UIColor.label
        ]))
    }
    private static func cacheKey(_ message: ChatMessage, font: UIFont) -> NSString {
        (font.fontName + "|" + String(describing: font.pointSize) + "|" + message.displayText) as NSString
    }
    static func height(_ message: ChatMessage, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: message.role == "tool" ? .footnote : .body, compatibleWith: traits)
        let key = cacheKey(message, font: font)
        let formatted = message.role == "user" ? nil : renderedCache.object(forKey: key)
        let sizeComponents = [message.delivery?.rawValue ?? "", String(describing: width), formatted?.revision.uuidString ?? "plain", key as String]
        let sizeKey = sizeComponents.joined(separator: "|") as NSString
        if let height = heightCache.object(forKey: sizeKey) {
            ChatPerformance.shared.add(.heightCacheHits)
            return CGFloat(height.doubleValue)
        }
        ChatPerformance.shared.add(.heightCacheMisses)
        let measurement = ChatPerformance.shared.beginStage(.heightMeasurement, count: message.displayText.utf8.count)
        defer { ChatPerformance.shared.endStage(measurement) }
        measuringText.isScrollEnabled = false
        measuringText.textContainerInset = UIEdgeInsets(top: 11, left: 16, bottom: 11, right: 16)
        measuringText.textContainer.lineFragmentPadding = 0
        let suffix = formatted == nil && !measuringWasFormatted && measuringWidth == width && measuringFont == font
            ? measuringMessage.flatMap { provisionalSuffix(from: $0, to: message) } : nil
        if let suffix {
            append(suffix, to: measuringText, font: font)
        } else {
            ChatPerformance.shared.add(.textAssignedUTF8Bytes, count: message.displayText.utf8.count)
            ChatPerformance.shared.measure(.textAssignment, count: message.displayText.utf8.count) {
                measuringText.attributedText = formatted?.text ?? NSAttributedString(
                    string: message.displayText, attributes: [.font: font, .foregroundColor: UIColor.white])
            }
        }
        measuringWasFormatted = formatted != nil
        measuringMessage = message
        measuringWidth = width
        measuringFont = font
        let baseHeight = ceil(measuringText.sizeThatFits(CGSize(width: width * 0.91, height: .greatestFiniteMagnitude)).height) + 10
        let captionHeight = ceil(UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits).lineHeight) + 4
        let deliveryHeight: CGFloat = message.deliveryLabel == nil ? 0 : captionHeight
        let height = baseHeight + deliveryHeight
        heightCache.setObject(NSNumber(value: Double(height)), forKey: sizeKey, cost: message.displayText.utf8.count)
        return height
    }
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        bubble.layer.cornerRadius = 20
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 11, left: 16, bottom: 11, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.dataDetectorTypes = .link
        textView.linkTextAttributes = [.foregroundColor: UIColor.systemCyan]
        contentView.addSubview(bubble)
        bubble.addSubview(textView)
        deliveryLabel.translatesAutoresizingMaskIntoConstraints = false
        deliveryLabel.font = .preferredFont(forTextStyle: .caption2)
        deliveryLabel.textColor = .secondaryLabel
        deliveryLabel.textAlignment = .right
        deliveryLabel.adjustsFontForContentSizeCategory = true
        contentView.addSubview(deliveryLabel)
        bubbleBottom = bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5)
        left = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        right = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        left.priority = .defaultHigh
        right.priority = .defaultHigh
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5), bubbleBottom,
            deliveryLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            deliveryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            deliveryLabel.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 2),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.91),
            bubble.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: bubble.topAnchor), textView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor), textView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func prepareForReuse() { super.prepareForReuse(); formatTask?.cancel(); formatTask = nil; messageID = nil; configuredMessage = nil; configuredFont = nil }
    func updateDelivery(_ message: ChatMessage) {
        configuredMessage = message
        messageID = message.id
        deliveryLabel.text = message.deliveryLabel
        textView.accessibilityIdentifier = "message-" + message.id
    }
    func appendProvisional(_ message: ChatMessage) {
        guard let configuredMessage, let suffix = Self.provisionalSuffix(from: configuredMessage, to: message),
              let font = configuredFont else { configure(message); return }
        Self.append(suffix, to: textView, font: font)
        if Self.renderedCache.object(forKey: Self.cacheKey(configuredMessage, font: font)) != nil {
            Self.renderedCache.setObject(RenderedMarkdown(NSAttributedString(attributedString: textView.attributedText), fullyParsed: false),
                forKey: Self.cacheKey(message, font: font), cost: message.displayText.utf8.count)
        }
        self.configuredMessage = message
        scheduleFormatting(font: font)
        textView.accessibilityLabel = (message.role == "user" ? "You. " : "Hermes. ") + message.displayText
    }
    func configure(_ message: ChatMessage) {
        let configuration = ChatPerformance.shared.beginStage(.cellConfiguration)
        defer { ChatPerformance.shared.endStage(configuration) }
        configuredMessage = message
        formatTask?.cancel()
        formatTask = nil
        messageID = message.id
        let user = message.role == "user"
        deliveryLabel.text = message.deliveryLabel
        deliveryLabel.isHidden = message.deliveryLabel == nil
        bubbleBottom.constant = message.deliveryLabel == nil ? -5 : -9 - ceil(deliveryLabel.font.lineHeight)
        left.isActive = !user
        right.isActive = user
        bubble.backgroundColor = user ? UIColor(red: 0.04, green: 0.36, blue: 0.82, alpha: 1) : UIColor(white: 0.13, alpha: 1)
        let font = UIFont.preferredFont(forTextStyle: message.role == "tool" ? .footnote : .body, compatibleWith: traitCollection)
        configuredFont = font
        let cached = user ? nil : Self.renderedCache.object(forKey: Self.cacheKey(message, font: font))
        ChatPerformance.shared.add(.textAssignedUTF8Bytes, count: message.displayText.utf8.count)
        ChatPerformance.shared.measure(.textAssignment, count: message.displayText.utf8.count) {
            textView.attributedText = cached?.text ?? NSAttributedString(
                string: message.displayText, attributes: [.font: font, .foregroundColor: UIColor.white])
        }
        textView.accessibilityLabel = (user ? "You. " : "Hermes. ") + message.displayText
        textView.accessibilityIdentifier = "message-" + message.id
        guard !user else { return }
        if let cached {
            ChatPerformance.shared.add(.renderedCacheHits)
            if cached.fullyParsed { return }
        } else { ChatPerformance.shared.add(.renderedCacheMisses) }
        scheduleFormatting(font: font)
    }

    private func scheduleFormatting(font: UIFont) {
        guard formatTask == nil, let configuredMessage, configuredMessage.role != "user" else { return }
        let generation = UUID()
        formattingGeneration = generation
        let provisional = configuredMessage.provisional
        formatTask = Task { [weak self] in
            if provisional { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled, let self, self.formattingGeneration == generation,
                  let message = self.configuredMessage else { return }
            let formatted = await Self.formatting.format(message.displayText)
            guard !Task.isCancelled, self.formattingGeneration == generation else { return }
            self.formatTask = nil
            guard self.configuredMessage == message else {
                self.scheduleFormatting(font: font)
                return
            }
            let layoutSpan = ChatPerformance.shared.begin(.markdownLayout, count: message.displayText.utf8.count)
            let applySpan = ChatPerformance.shared.begin(.markdownApply, count: message.displayText.utf8.count)
            defer { ChatPerformance.shared.end(applySpan); ChatPerformance.shared.end(layoutSpan) }
            let attributed = Self.render(formatted, font: font)
            guard self.textView.attributedText != attributed else { return }
            self.onFormattingWillChange?()
            Self.renderedCache.setObject(RenderedMarkdown(attributed), forKey: Self.cacheKey(message, font: font), cost: message.displayText.utf8.count)
            ChatPerformance.shared.add(.textAssignedUTF8Bytes, count: message.displayText.utf8.count)
            ChatPerformance.shared.measure(.textAssignment, count: message.displayText.utf8.count) { self.textView.attributedText = attributed }
        }
    }
    private var formattingGeneration = UUID()

    private static func render(_ formatted: AttributedString, font: UIFont) -> NSAttributedString {
        let preparation = ChatPerformance.shared.beginStage(.textPreparation)
        defer { ChatPerformance.shared.endStage(preparation) }
        let attributed = NSMutableAttributedString(formatted)
        attributed.addAttributes([.font: font, .foregroundColor: UIColor.white], range: NSRange(location: 0, length: attributed.length))
        var listIndents: [Int: CGFloat] = [:]
        for run in formatted.runs {
            var ordinal: Int?
            for component in run.presentationIntent?.components ?? [] {
                let marker: String
                switch component.kind {
                case .listItem(let value): ordinal = value; continue
                case .orderedList: marker = "\(ordinal ?? 1). "
                case .unorderedList: marker = "• "
                default: continue
                }
                let width = ceil((marker as NSString).size(withAttributes: [.font: font]).width)
                listIndents[component.identity] = max(listIndents[component.identity] ?? 20, width)
            }
        }
        var location = 0
        for run in formatted.runs {
            let length = String(formatted[run.range].characters).utf16.count
            let range = NSRange(location: location, length: length)
            location += length
            let inline = run.inlinePresentationIntent ?? []
            let components = run.presentationIntent?.components ?? []
            var pointSize = font.pointSize
            var traits: UIFontDescriptor.SymbolicTraits = []
            var code = inline.contains(.code)
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 8
            paragraph.lineSpacing = 2
            var listIndent: CGFloat = 0
            var markerIndent: CGFloat?
            for component in components {
                switch component.kind {
                case .header(let level):
                    pointSize += CGFloat(max(0, 4 - level)) * 2
                    traits.insert(.traitBold)
                    paragraph.paragraphSpacingBefore = 8
                case .codeBlock:
                    code = true
                    paragraph.paragraphSpacing = 0
                case .orderedList, .unorderedList:
                    let indent = listIndents[component.identity] ?? 20
                    if markerIndent == nil { markerIndent = indent }
                    listIndent += indent
                case .blockQuote:
                    paragraph.headIndent += 12
                    paragraph.firstLineHeadIndent += 12
                default: break
                }
            }
            if let markerIndent {
                paragraph.headIndent += listIndent
                paragraph.firstLineHeadIndent += listIndent - markerIndent
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
                paragraph.paragraphSpacing = 4
            }
            if inline.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if inline.contains(.emphasized) { traits.insert(.traitItalic) }
            var runFont = code ? UIFont.monospacedSystemFont(ofSize: pointSize - 1, weight: .regular) : font.withSize(pointSize)
            if !traits.isEmpty, let descriptor = runFont.fontDescriptor.withSymbolicTraits(traits) {
                runFont = UIFont(descriptor: descriptor, size: runFont.pointSize)
            }
            attributed.addAttributes([.font: runFont, .paragraphStyle: paragraph], range: range)
            if code { attributed.addAttribute(.backgroundColor, value: UIColor.white.withAlphaComponent(0.055), range: range) }
        }
        return attributed
    }
}

actor MarkdownCache {
    private var values: [String: AttributedString] = [:]
    private var order: [String] = []
    private var bytes = 0
    func format(_ text: String) -> AttributedString {
        if let value = values[text] { return value }
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(text)
        var result = AttributedString()
        var previousBlock: Int?
        var seenItems = Set<Int>()
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            if let block, let previousBlock, block != previousBlock, result.characters.last != "\n" {
                result.append(AttributedString("\n"))
            }
            if block != previousBlock {
                for component in components {
                    if case .listItem(let ordinal) = component.kind, seenItems.insert(component.identity).inserted {
                        let ordered = components.contains { $0.kind == .orderedList }
                        var marker = AttributedString(ordered ? "\(ordinal).\t" : "•\t")
                        marker.presentationIntent = run.presentationIntent
                        result.append(marker)
                        break
                    }
                }
            }
            result.append(AttributedString(parsed[run.range]))
            previousBlock = block
        }
        if text.utf8.count <= 256 * 1024 {
            values[text] = result
            order.append(text)
            bytes += text.utf8.count
            while order.count > 500 || bytes > 2 * 1024 * 1024 {
                let first = order.removeFirst()
                bytes -= first.utf8.count
                values.removeValue(forKey: first)
            }
        }
        return result
    }
}
