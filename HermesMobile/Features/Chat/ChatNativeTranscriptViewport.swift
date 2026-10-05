import SwiftUI
import UIKit

/// Measured realization owner shared by the existing SwiftUI row renderers.
/// IDs/index geometry scale with canonical history; hosted rich content scales
/// with the viewport. No SwiftUI scroll target resolver also writes its offset.
struct ChatNativeTranscriptViewport: UIViewControllerRepresentable {
    let ids: [String]
    let revisionAt: (Int) -> StableViewportRowRevision
    let revision: Int
    let typeKey: String
    let scope: String
    let initialID: String?
    let restoreRequest: ChatTranscriptRestoreRequest?
    let cancellationToken: Int
    let latestToken: Int
    let explicitLatest: Bool
    let following: Bool
    var isStreaming: Bool = false
    let horizontalPadding: CGFloat
    let spacing: CGFloat
    let bottomInset: CGFloat
    /// Extra chrome above the viewport, independent of its keyboard-sized bounds.
    /// Content inset keeps native anchor/restore geometry below that chrome.
    var topInset: CGFloat = 0
    /// Explicit button clearance for measured chrome. Nil retains the old surface.
    var latestBottomInset: CGFloat? = nil
    let environment: EnvironmentValues
    /// Opt-in only for inert geometry with no captured actions. Factories remain
    /// authoritative; rich content uses nil and refreshes on every update.
    enum BoundaryRevision: Equatable { case spacer(height: CGFloat) }
    var headerRevision: BoundaryRevision? = nil
    var footerRevision: BoundaryRevision? = nil
    let makeRow: (Int) -> AnyView
    let makeHeader: () -> AnyView
    let makeFooter: () -> AnyView
    let onLatest: () -> Void
    let onState: (ChatScrollMetrics, String?, Bool, Bool) -> Void
    let onRestore: (ChatTranscriptRestoreRequest, ChatTranscriptRestoreOutcome) -> Void
    var metricPublication: ChatScrollMetricPublication? = nil
    var onStreamingInteractionChanged: (Bool) -> Void = { _ in }
    var allowsAutomaticPaging = false
    var onOlder: @MainActor (ChatTranscriptOlderLoadIntent, @escaping @MainActor () -> Bool) async -> Bool = { _, _ in false }
    let onRefresh: @MainActor (@escaping @MainActor () -> Bool) async -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(input: self) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.update(self) }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.stop() }

    class Collection: UICollectionView {
        var willLayout: (() -> Void)?
        var didLayout: (() -> Void)?
        override func layoutSubviews() { willLayout?(); super.layoutSubviews(); didLayout?() }
    }

    final class Controller: UIViewController, UICollectionViewDelegate {
        enum Item: Hashable { case header, row(String), footer }
        /// Scalar-only LRU. Heights are hints until this mount fits the hosted cell.
        struct EstimateKey: Hashable {
            let scope: String
            let width: CGFloat
            let type: String
            let padding: CGFloat
        }
        struct EstimateStore {
            static let scopeLimit = 16
            static let rowLimit = 2_048
            private(set) var values: [EstimateKey: [Item: CGFloat]] = [:]
            private var order: [EstimateKey] = []
            mutating func heights(for key: EstimateKey) -> [Item: CGFloat] {
                guard let result = values[key] else { return [:] }
                order.removeAll { $0 == key }; order.append(key)
                return result
            }
            mutating func put(_ height: CGFloat, item: Item, key: EstimateKey) {
                guard height.isFinite, height >= 0 else { return }
                if values[key] == nil {
                    if order.count == Self.scopeLimit { values.removeValue(forKey: order.removeFirst()) }
                    values[key] = [:]
                }
                order.removeAll { $0 == key }; order.append(key)
                if values[key]?[item] == nil, values[key]!.count >= Self.rowLimit {
                    // A bounded dictionary; eviction ordering has no geometry semantics.
                    if let victim = values[key]?.keys.first { values[key]?.removeValue(forKey: victim) }
                }
                values[key]?[item] = height
            }
        }
        static var estimates = EstimateStore()

        final class ColumnLayout: UICollectionViewLayout {
            private var items: [Item] = []
            private var ids: [String]?
            private(set) var key: EstimateKey?
            private var heights: [Item: CGFloat] = [:]
            private var measurementOrder: [Item] = []
            private(set) var measured: Set<Item> = []
            var retainedMeasurementCount: Int { heights.count }
            private(set) var warmHits = 0
            private var frames: [CGRect] = []
            private var dirty = true
            private var dirtyFrom = 0
            private(set) var lastRebuiltFrameCount = 0
            private var preparedCount = -1
            private var snapshotTransition = false
            var snapshotItems: (() -> [Item])?
            private var spacing: CGFloat = 0
            private var bottom: CGFloat = 0
            private var size: CGSize = .zero

            func configure(input: ChatNativeTranscriptViewport, width: CGFloat) {
                guard width.isFinite, width > 0 else { return }
                let nextKey = EstimateKey(scope: input.scope, width: width, type: input.typeKey,
                                          padding: input.horizontalPadding)
                let identityChanged = ids != input.ids
                if identityChanged {
                    ids = input.ids
                    // Input is staged before diffable application. It cannot
                    // replace the identities owned by the committed collection.
                    invalidateFrames(from: 0)
                }
                if key != nextKey {
                    key = nextKey
                    heights = Controller.estimates.heights(for: nextKey)
                    measurementOrder = Array(heights.keys)
                    measured.removeAll()
                    let warmItems = [.header] + input.ids.map(Item.row) + [.footer]
                    warmHits = min(EstimateStore.rowLimit, warmItems.filter { heights[$0] != nil }.count)
#if DEBUG
                    ChatPerformanceInvalidationProbe.shared?.record("native_layout_estimate_hits", a: warmHits)
#endif
                    invalidateFrames(from: 0)
                }
                if spacing != input.spacing {
                    spacing = input.spacing
                    invalidateFrames(from: 0)
                }
                if bottom != input.bottomInset {
                    bottom = input.bottomInset
                    // Composer growth changes content size, not any row frame.
                    invalidateFrames(from: items.count)
                }
                if dirty { invalidateLayout() }
            }
            private func invalidateFrames(from index: Int) {
                dirtyFrom = dirty ? min(dirtyFrom, index) : index
                dirty = true
            }
            func beginSnapshotTransition() {
                snapshotTransition = true
                invalidateLayout()
            }
            func commitSnapshot(_ committed: [Item]) {
                snapshotTransition = false
                setItems(committed)
                // An apply can prepare against the old count, including a
                // same-count replacement. Rebuild even when identities match.
                invalidateFrames(from: 0)
                invalidateLayout()
            }
            private func setItems(_ committed: [Item]) {
                guard items != committed else { return }
                items = committed
                let retained = Set(items)
                measured.formIntersection(retained)
                heights = heights.filter { retained.contains($0.key) }
                measurementOrder.removeAll { !retained.contains($0) }
                invalidateFrames(from: 0)
            }
            func retire(_ item: Item) { measured.remove(item) }

            func needsFit(_ item: Item) {
                rebuildFramesIfNeeded()
                measured.remove(item)
                guard let index = items.firstIndex(of: item), index < committedCount else { return }
                let context = UICollectionViewLayoutInvalidationContext()
                context.invalidateItems(at: [IndexPath(item: index, section: 0)])
                invalidateLayout(with: context)
            }
            private var committedCount: Int {
                guard let collectionView, collectionView.numberOfSections > 0 else { return 0 }
                return collectionView.numberOfItems(inSection: 0)
            }
            private func rebuildFramesIfNeeded() {
                // During apply, diffable identity and UIKit's count can advance
                // at different times. Resolve identity from the data source and
                // bound geometry by the count UIKit has actually committed.
                if snapshotTransition, let snapshotItems { setItems(snapshotItems()) }
                let count = committedCount
                guard dirty || preparedCount != count, let key else { return }
                let end = min(count, items.count)
                let start = min(dirty ? dirtyFrom : frames.count, min(frames.count, end))
                if start < frames.count { frames.removeSubrange(start...) }
                var y: CGFloat = frames.last.map { $0.maxY + spacing } ?? 16
                lastRebuiltFrameCount = end - start
                for item in items[start..<end] {
                    let height = heights[item] ?? 160
                    frames.append(CGRect(x: key.padding, y: y,
                        width: max(1, key.width - 2 * key.padding), height: height))
                    y += height + spacing
                }
                size = CGSize(width: key.width, height: max(0, y - (frames.isEmpty ? 0 : spacing) + bottom))
                preparedCount = count
                dirty = false
                dirtyFrom = end
            }
            override func prepare() {
                super.prepare()
                rebuildFramesIfNeeded()
            }
            override var collectionViewContentSize: CGSize {
                rebuildFramesIfNeeded()
                return size
            }
            override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
                rebuildFramesIfNeeded()
                guard path.section == 0, path.item < committedCount,
                      frames.indices.contains(path.item) else { return nil }
                return attributes(at: path)
            }
            private func attributes(at path: IndexPath) -> UICollectionViewLayoutAttributes {
                let value = UICollectionViewLayoutAttributes(forCellWith: path)
                value.frame = frames[path.item]
                return value
            }
            override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
                rebuildFramesIfNeeded()
                var low = 0, high = frames.count
                while low < high {
                    let mid = (low + high) / 2
                    if frames[mid].maxY < rect.minY { low = mid + 1 } else { high = mid }
                }
                var result: [UICollectionViewLayoutAttributes] = []
                let limit = min(frames.count, committedCount)
                while low < limit, frames[low].minY <= rect.maxY {
                    result.append(attributes(at: IndexPath(item: low, section: 0)))
                    low += 1
                }
                return result
            }
            override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
                newBounds.width != collectionView?.bounds.width
            }
            override func shouldInvalidateLayout(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                                  withOriginalAttributes original: UICollectionViewLayoutAttributes) -> Bool {
                rebuildFramesIfNeeded()
                let index = preferred.indexPath.item
                guard preferred.indexPath.section == 0, index < committedCount,
                      items.indices.contains(index), let key,
                      preferred.size.height.isFinite, preferred.size.height >= 0,
                      preferred.size.width == max(1, key.width - 2 * key.padding) else { return false }
                return preferred.size.height != original.size.height
            }
            func didFit(_ attributes: UICollectionViewLayoutAttributes, item: Item, key fittedKey: EstimateKey?) {
                rebuildFramesIfNeeded()
                guard attributes.indexPath.section == 0, attributes.indexPath.item < committedCount,
                      let key, key == fittedKey, items.indices.contains(attributes.indexPath.item),
                      items[attributes.indexPath.item] == item,
                      attributes.size.width == max(1, key.width - 2 * key.padding),
                      attributes.size.height.isFinite, attributes.size.height >= 0 else { return }
                measured.insert(item)
                let oldHeight = heights[item] ?? 160
                var leadingAdjustment: CGFloat = 0
                let top = (collectionView?.contentOffset.y ?? 0) + (collectionView?.adjustedContentInset.top ?? 0)
                if frames.indices.contains(attributes.indexPath.item), frames[attributes.indexPath.item].maxY <= top {
                    leadingAdjustment += attributes.size.height - oldHeight
                }
                if oldHeight != attributes.size.height {
                    invalidateFrames(from: attributes.indexPath.item)
                }
                heights[item] = attributes.size.height
                measurementOrder.removeAll { $0 == item }
                measurementOrder.append(item)
                while heights.count > EstimateStore.rowLimit, let victim = measurementOrder.first {
                    measurementOrder.removeFirst()
                    if let old = heights.removeValue(forKey: victim), let index = items.firstIndex(of: victim) {
                        if frames.indices.contains(index), frames[index].maxY <= top {
                            leadingAdjustment += 160 - old
                        }
                        invalidateFrames(from: index)
                    }
                    measured.remove(victim)
                }
                Controller.estimates.put(attributes.size.height, item: item, key: key)
                if dirty {
                    // Maintain the same viewport Y while an earlier estimate is
                    // refined/evicted, even during UIKit momentum. This is layout
                    // geometry, not a delayed restore or another motion owner.
                    let context = UICollectionViewLayoutInvalidationContext()
                    context.contentOffsetAdjustment = CGPoint(x: 0, y: leadingAdjustment)
                    invalidateLayout(with: context)
                }
            }
        }
        struct RowStamp: Equatable {
            let id: String
            let key: EstimateKey
            let revision: StableViewportRowRevision
        }
        func rowStamp(for id: String) -> RowStamp? {
            guard let index = indices[id] else { return nil }
            return RowStamp(id: id, key: EstimateKey(scope: input.scope,
                width: collection.bounds.width, type: input.typeKey, padding: input.horizontalPadding),
                revision: input.revisionAt(index))
        }
        struct BoundaryStamp: Equatable {
            let item: Item
            let revision: BoundaryRevision
            let scope: String
            let type: String
            let width: CGFloat
            let padding: CGFloat
            let spacing: CGFloat
            let bottomInset: CGFloat
            let presentation: Int
        }
        final class Cell: UICollectionViewCell {
            var representedItem: Item?
            var boundaryStamp: BoundaryStamp?
            var rowStamp: RowStamp?
            var layoutPolicy = 0
            var didFit: ((UICollectionViewLayoutAttributes) -> Void)?
            override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
#if DEBUG
                let probe = ChatPerformanceInvalidationProbe.shared
                let start = probe == nil ? 0 : CACurrentMediaTime()
#endif
                let result = super.preferredLayoutAttributesFitting(layoutAttributes)
#if DEBUG
                probe?.record("native_layout_fit", b: Int((CACurrentMediaTime() - start) * 1_000_000), c: layoutPolicy)
#endif
                // UIKit may skip the invalidation delegate when the fitted size
                // equals its estimate; fitting itself is the measurement receipt.
                didFit?(result)
                return result
            }
            override func prepareForReuse() {
                super.prepareForReuse()
                representedItem = nil
                contentConfiguration = nil
                boundaryStamp = nil
                rowStamp = nil
                didFit = nil
            }
        }
        private(set) var boundaryConfigurations = 0
        var reusesBoundaryConfigurations = !ChatSurfacePolicy.debugArgument("--chat-native-eager-boundaries")

        func boundaryStamp(for item: Item) -> BoundaryStamp? {
            let revision: BoundaryRevision?
            switch item {
            case .header: revision = input.headerRevision
            case .footer: revision = input.footerRevision
            case .row: return nil
            }
            guard let revision else { return nil }
            return BoundaryStamp(item: item, revision: revision, scope: input.scope,
                type: input.typeKey, width: collection.bounds.width,
                padding: input.horizontalPadding, spacing: input.spacing,
                bottomInset: input.bottomInset, presentation: presentationEpoch)
        }
        struct Anchor { let id: String; let delta: CGFloat }
        struct ReaderHandoff {
            let anchor: Anchor
            let scope: String
            let width: CGFloat
            let revision: Int
            let cancellation: Int
            let generation: Int
            let presentation: Int
        }
        private(set) var lastSourceMutation = ChatTranscriptSourceMutation.unchanged
        private var olderBoundary: String?
        private var olderTask: Task<Void, Never>?
        private var olderGeneration = 0
        private var olderEchoCancellationToken: Int?
        enum Ownership { case restoring(Anchor?), following, reading }
        struct Memory { let anchor: Anchor; let following: Bool }
        /// Compact reader points only, ordered least to most recently used.
        struct MemoryStore {
            private var values: [String: Memory] = [:]
            private var order: [String] = []
            var count: Int { values.count }

            subscript(key: String) -> Memory? {
                mutating get {
                    guard let value = values[key] else { return nil }
                    order.removeAll { $0 == key }
                    order.append(key)
                    return value
                }
                set {
                    order.removeAll { $0 == key }
                    guard let newValue else {
                        values.removeValue(forKey: key)
                        return
                    }
                    if values[key] == nil, values.count == 32 {
                        values.removeValue(forKey: order.removeFirst())
                    }
                    values[key] = newValue
                    order.append(key)
                }
            }

            mutating func removeAll() {
                values.removeAll()
                order.removeAll()
            }
        }
        static var memory = MemoryStore()
        var input: ChatNativeTranscriptViewport
        var ownership: Ownership
        var anchor: Anchor?
        var collection: Collection!
        private let edgeMask = CAGradientLayer()
        var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
        var revisions: [String: StableViewportRowRevision] = [:]
        private(set) var deferredStreamingRowIDs: Set<String> = []
        private(set) var streamingInteractionActive = false
        private var interactionEndTask: Task<Void, Never>?
        private var interactionEndGeneration = 0
        let markdownPresentationInteraction = MarkdownPresentationInteraction()
        var indices: [String: Int] = [:]
        var appliedIDs: [String]?
        var identityBuilds = 0
        var applying = false
        var correcting = false
        var stopped = false
        var generation = 0
        // Presentation epochs invalidate UI callbacks without invalidating refresh work.
        var presentationEpoch = 0
        var presentationVisible = false
        var applicationActive = UIApplication.shared.applicationState == .active
        // Initial mounted layout remains available to the first-layer restore.
        // Once presentation is lost, only an active appearance can reopen it.
        var presentationSuspended = false
        var isPresentationActive: Bool { presentationVisible && applicationActive && !stopped }
        var lifecycleObserver: LifecycleObserver?
#if DEBUG
        private var observedKeyboardFrame: CGRect = .zero
#endif
        var pendingRestore: (request: ChatTranscriptRestoreRequest, outcome: ChatTranscriptRestoreOutcome)?
        @MainActor final class LifecycleObserver: NSObject {
            weak var owner: Controller?
            init(_ owner: Controller) {
                self.owner = owner
                super.init()
                NotificationCenter.default.addObserver(self, selector: #selector(older(_:)), name: .semrehTranscriptLoadOlder, object: nil)
                NotificationCenter.default.addObserver(self, selector: #selector(resign(_:)), name: UIApplication.willResignActiveNotification, object: nil)
                NotificationCenter.default.addObserver(self, selector: #selector(activate(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
#if DEBUG
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
#endif
            }
            @objc func resign(_ notification: Notification) {
                owner?.applicationActive = false
                owner?.suspendPresentation()
            }
            @objc func older(_ notification: Notification) {
                guard let owner, notification.object as? String == owner.input.scope else { return }
                owner.loadOlder(intent: .explicitUserRequest)
            }
            @objc func activate(_ notification: Notification) {
                owner?.applicationActive = true
                owner?.resumePresentation()
            }
#if DEBUG
            @objc func keyboardChanged(_ notification: Notification) {
                guard let owner, owner.isPresentationActive, let window = owner.collection.window,
                      let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
                let frame = value.cgRectValue
                let occupied = frame.intersection(window.convert(window.bounds, to: window.screen.coordinateSpace))
                owner.observedKeyboardFrame = occupied.isNull ? .zero : occupied
                owner.updateDebugProbe()
            }
#endif
            deinit { NotificationCenter.default.removeObserver(self) }
        }
        var width: CGFloat = 0
        var initialized = false
        var completedRequest: ChatTranscriptRestoreRequest?
        struct SettlementSample: Equatable {
            let request: ChatTranscriptRestoreRequest
            let width: CGFloat
            let contentSize: CGSize
            let targetFrame: CGRect
            let offset: CGPoint
        }
        var settlementSample: SettlementSample?
        var confirmationQueued = false
        var confirmationPasses = 0
        var refreshTask: Task<Void, Never>?
        // One display-linked UIKit offset owner. The target is recomputed from the
        // live self-sizing layout each frame; no estimated endpoint is cached.
        @MainActor final class MotionTarget: NSObject {
            weak var owner: Controller?
            init(_ owner: Controller) { self.owner = owner }
            @objc func tick(_ link: CADisplayLink) { owner?.advanceMotion(link) }
        }
        @MainActor final class FollowTarget: NSObject {
            weak var owner: Controller?
            init(_ owner: Controller) { self.owner = owner }
            @objc func tick(_ link: CADisplayLink) { owner?.advanceFollow(link) }
        }
        var followLink: CADisplayLink?
        private(set) var followTicks = 0
        private var realizedBottomEstablished = false
        private var followTimestamp: CFTimeInterval = 0
        private var followContentChangedAt: CFTimeInterval = 0
        private var viewportSize: CGSize = .zero
        private var viewportInsets: UIEdgeInsets = .zero
        // Late self-sizing after a viewport/keyboard resize stays immediate until
        // new semantic content arrives, even if the tail was briefly realized.
        private var immediateFollowRevision: Int?

        var motionLink: CADisplayLink?
        var motionStarted: CFTimeInterval = 0
        var motionProgress: CGFloat = 0
        var motionTailSample: CGRect?
        var motionTailOffset: CGFloat?
        private var motionDeadlineConfirmationPending = false
        var motionCompleted = 0
        var motionCancelled = 0
        var motionSamples = 0
        // Actual native work, not delivered callbacks or presented FPS.
        private(set) var motionTicks = 0
        private(set) var publishComputations = 0
        private(set) var descendantScanPasses = 0
        private(set) var motionPublishComputations = 0
        private(set) var motionDescendantScanPasses = 0
        private(set) var followObservationSteps = 0
        private(set) var followPublishComputations = 0
        private(set) var followDescendantScanPasses = 0
        private(set) var batchingMotionObservations = false
        private var needsMotionDescendantScan = false
        private var scrollObservationTicket = 0
        private var pendingScrollObservation: Int?
        private(set) var scrollObservationDrains = 0
        var decelerationTakeovers = 0
        // Persists through settlement (including Reduce Motion) until a newer
        // gesture or cancellation takes ownership. Late UIKit end callbacks do not.
        var explicitLatestOwnsViewport = false
        // Only the synchronous stop of inherited rejoin momentum owns this guard.
        // Ordinary follow must not acquire explicit jump's suspension semantics.
        private var handingOffRejoinMomentum = false
        var latestEchoCancellationToken: Int?
        var systemTopActive = false
        var systemTopReaderIntent = false
        var systemTopRequests = 0
        var systemTopCompleted = 0
        // Retained across interruption until the parent acknowledges reader intent.
        var systemTopEchoCancellationToken: Int?
        struct Published: Equatable {
            let metrics: ChatScrollMetrics
            let visible: String?
            let last: Bool
            let bottom: Bool
        }
        var lastPublished: Published?
        var publication = 0
        let latest = UIButton(type: .system)
        private var latestBottomConstraint: NSLayoutConstraint?
#if DEBUG
        final class DebugProbeLabel: UILabel {
            weak var presentationInteraction: MarkdownPresentationInteraction?
            override var accessibilityValue: String? {
                get {
                    // Held async preparation need not cause another native
                    // layout. AX samples these counters directly from the owner.
                    let interaction = presentationInteraction
                    return (super.accessibilityValue ?? "")
                        + ";canonicalHold=\(interaction?.holdsCanonicalPresentation ?? false)"
                        + ";canonicalBlocked=\(interaction?.blocksCanonicalPresentation ?? false)"
                        + ";canonicalPrepared=\(interaction?.canonicalPreparationCount ?? 0)"
                        + ";canonicalCommitted=\(interaction?.canonicalCommitCount ?? 0)"
                }
                set { super.accessibilityValue = newValue }
            }
        }
        let probe = DebugProbeLabel()
        private var debugDragEndCallbacks = 0
        private var debugDecelerationEndCallbacks = 0
        private var debugLastInteractionEndFlags = "none"
        private var debugMotionReceipt = "none"
#else
        let probe = UILabel()
#endif

        let reduceMotionEnabled: () -> Bool
        let reusesIdentitySnapshot: Bool
        let coalescesScrollObservations: Bool
        let batchesMotionObservations: Bool
        let makeCollection: @MainActor (UICollectionViewLayout) -> Collection

        init(input: ChatNativeTranscriptViewport,
             reduceMotionEnabled: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled },
             reusesIdentitySnapshot: Bool = true,
             batchesMotionObservations: Bool = true,
             coalescesScrollObservations: Bool = true,
             makeCollection: @escaping @MainActor (UICollectionViewLayout) -> Collection = {
                 Collection(frame: .zero, collectionViewLayout: $0)
             }) {
            self.makeCollection = makeCollection
            self.reduceMotionEnabled = reduceMotionEnabled
            self.reusesIdentitySnapshot = reusesIdentitySnapshot
            self.batchesMotionObservations = batchesMotionObservations
            self.coalescesScrollObservations = coalescesScrollObservations
            self.input = input
            ownership = .restoring(input.initialID.map { Anchor(id: $0, delta: 0) })
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func makeLayout() -> UICollectionViewLayout {
            if !ChatSurfacePolicy.debugArgument("--chat-native-compositional-layout") {
                return ColumnLayout()
            }
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(160)))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(160)), subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = input.spacing
            section.contentInsets = .init(top: 16, leading: input.horizontalPadding, bottom: input.bottomInset, trailing: input.horizontalPadding)
            return UICollectionViewCompositionalLayout(section: section)
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            lifecycleObserver = LifecycleObserver(self)
            collection = makeCollection(makeLayout())
            collection.backgroundColor = .clear
            edgeMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor,
                               UIColor.black.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
            collection.layer.mask = edgeMask
            // UIKit must not accumulate prepared rich hosts outside the current
            // realization region while fast motion visits many source IDs.
            collection.isPrefetchingEnabled = false
            collection.alwaysBounceVertical = true
            collection.scrollsToTop = true
            collection.keyboardDismissMode = .interactive
            collection.contentInsetAdjustmentBehavior = .never
            collection.accessibilityIdentifier = "chat-transcript-scroll"
            collection.delegate = self
            collection.register(Cell.self, forCellWithReuseIdentifier: "rich")
            view.addSubview(collection)
            collection.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                collection.leadingAnchor.constraint(equalTo: view.leadingAnchor), collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                collection.topAnchor.constraint(equalTo: view.topAnchor), collection.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            dataSource = UICollectionViewDiffableDataSource<Int, Item>(collectionView: collection) { [weak self] collection, path, item in
                guard let self else { return nil }
                let cell = collection.dequeueReusableCell(withReuseIdentifier: "rich", for: path)
                self.configure(cell, item: item)
                return cell
            }
            (collection.collectionViewLayout as? ColumnLayout)?.snapshotItems = { [weak self] in
                self?.dataSource.snapshot().itemIdentifiers ?? []
            }
            collection.willLayout = { [weak self] in
                guard let self else { return }
                (self.collection.collectionViewLayout as? ColumnLayout)?.configure(input: self.input, width: self.collection.bounds.width)
                self.primeInitialViewport()
            }
            collection.didLayout = { [weak self] in
                self?.updateEdgeMask()
                self?.settleLayout()
            }
            let refresh = UIRefreshControl()
            refresh.addTarget(self, action: #selector(refreshHistory), for: .valueChanged)
            collection.refreshControl = refresh
            latest.setImage(UIImage(systemName: "arrow.down"), for: .normal)
            latest.backgroundColor = .secondarySystemBackground
            latest.layer.cornerRadius = 22
            latest.accessibilityLabel = "Scroll to latest message"
            latest.accessibilityIdentifier = "chat-scroll-to-bottom"
            latest.addTarget(self, action: #selector(jumpToLatest), for: .touchUpInside)
            view.addSubview(latest)
            latest.translatesAutoresizingMaskIntoConstraints = false
            let bottomConstraint = latest.bottomAnchor.constraint(equalTo: view.bottomAnchor,
                constant: -resolvedLatestBottomInset(input))
            latestBottomConstraint = bottomConstraint
            NSLayoutConstraint.activate([latest.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20), bottomConstraint, latest.widthAnchor.constraint(equalToConstant: 44), latest.heightAnchor.constraint(equalToConstant: 44)])
#if DEBUG
            probe.presentationInteraction = markdownPresentationInteraction
            probe.font = .systemFont(ofSize: 1)
            probe.textColor = .clear
            probe.isAccessibilityElement = true
            probe.accessibilityIdentifier = "chat-native-transcript-v2"
            view.addSubview(probe)
            probe.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
#endif
            collection.accessibilityIdentifier = input.environment.internalChatRendererEnabled
                ? "chat-native-transcript-v2" : "chat-transcript-scroll"
            update(input)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            presentationVisible = true
            applicationActive = UIApplication.shared.applicationState == .active
            resumePresentation()
        }
        override func viewWillDisappear(_ animated: Bool) {
            presentationVisible = false
            suspendPresentation()
            super.viewWillDisappear(animated)
        }
        func invalidatePublications() {
            pendingScrollObservation = nil
            presentationEpoch += 1
            publication += 1
            lastPublished = nil
            confirmationQueued = false
        }
        func suspendPresentation() {
            guard !stopped, !presentationSuspended else { return }
            setStreamingInteraction(false)
            deferredStreamingRowIDs.removeAll()
            presentationSuspended = true
            cancelOlder()
            invalidatePublications()
            guard isViewLoaded else { return }
            let interruptedMotion = motionLink != nil
            let preservesFollowing = follows && !explicitLatestOwnsViewport
            cancelSystemTop()
            cancelMotion()
            if initialized { anchor = currentAnchor() ?? anchor }
            // Never acknowledge a covered restore merely because presentation ended.
            // An undelivered success must prove its geometry again on return.
            if let pendingRestore, case .success = pendingRestore.outcome {
                self.pendingRestore = nil
                ownership = requestedOwnership(input)
            } else if interruptedMotion, pendingRestore == nil,
                      let request = input.restoreRequest, request != completedRequest {
                ownership = requestedOwnership(input)
            } else if input.restoreRequest == nil || input.restoreRequest == completedRequest {
                // Ordinary follow intent survives background/cover suspension;
                // explicit motion still cancels into a stable reader position.
                ownership = preservesFollowing ? .following : .reading
            }
            saveMemory(scope: input.scope)
            resetSettlement()
        }
        func resumePresentation() {
            guard isPresentationActive, isViewLoaded else { return }
            let wasSuspended = presentationSuspended
            presentationSuspended = false
            if wasSuspended {
                // Hidden updates can be fitted by UIKit while publication is
                // deliberately suspended. Reacquire only realized hosts so their
                // fitting receipts use the current presentation; cached geometry
                // alone must not masquerade as a measured tail on foreground.
                for path in collection.indexPathsForVisibleItems {
                    guard let item = dataSource.itemIdentifier(for: path),
                          let cell = collection.cellForItem(at: path) else { continue }
                    configure(cell, item: item)
                }
            }
            if let pending = pendingRestore {
                pendingRestore = nil
                finishRestore(pending.outcome)
            }
            collection.setNeedsLayout()
        }

        func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                            forItemAt indexPath: IndexPath) {
            // Reuse-pool cells retain no rich host, actions or revision payload.
            // Canonical content remains in input and is reconstructed by ID.
            guard !collectionView.visibleCells.contains(where: { $0 === cell }) else { return }
            if let item = (cell as? Cell)?.representedItem {
                if case .row(let id) = item { revisions.removeValue(forKey: id) }
                (collection.collectionViewLayout as? ColumnLayout)?.retire(item)
            }
            (cell as? Cell)?.representedItem = nil
            cell.contentConfiguration = nil
            (cell as? Cell)?.rowStamp = nil
            (cell as? Cell)?.boundaryStamp = nil
            (cell as? Cell)?.didFit = nil
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                            forItemAt indexPath: IndexPath) {
            guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
            switch item {
            case .row(let id):
                // Prepared offscreen cells can survive without another dequeue.
                // Their host and fit callback must use the current geometry/content.
                if (cell as? Cell)?.rowStamp != rowStamp(for: id) { configure(cell, item: item) }
            case .header, .footer:
                // UIKit can retain a prepared offscreen cell without dequeuing it.
                let stamp = boundaryStamp(for: item)
                if stamp == nil || (cell as? Cell)?.boundaryStamp != stamp {
                    configure(cell, item: item)
                }
            }
        }

        func configure(_ cell: UICollectionViewCell, item: Item) {
            synchronizeCanonicalPresentationHold()
            if case .row(let id) = item { deferredStreamingRowIDs.remove(id) }
            let column = collection.collectionViewLayout as? ColumnLayout
            column?.needsFit(item)
            (cell as? Cell)?.layoutPolicy = column == nil ? 0 : 1
            let fittedKey = column?.key
            let fittedScope = input.scope
            let fittedPresentation = presentationEpoch
            let fittedStamp: RowStamp?
            if case .row(let id) = item { fittedStamp = rowStamp(for: id) }
            else { fittedStamp = nil }
            let stamp = boundaryStamp(for: item)
            let fittedRevision = input.revision
            (cell as? Cell)?.representedItem = item
            (cell as? Cell)?.didFit = { [weak self, weak column] attributes in
                guard let self, !self.stopped, !self.presentationSuspended,
                      self.input.scope == fittedScope else { return }
                if case .row(let id) = item {
                    guard self.rowStamp(for: id) == fittedStamp else { return }
                } else if let stamp {
                    guard self.boundaryStamp(for: item) == stamp else { return }
                } else {
                    guard self.input.revision == fittedRevision,
                          self.presentationEpoch == fittedPresentation else { return }
                }
                column?.didFit(attributes, item: item, key: fittedKey)
            }
            (cell as? Cell)?.boundaryStamp = stamp
            (cell as? Cell)?.rowStamp = nil
            let content: AnyView
            switch item {
            case .header, .footer:
                boundaryConfigurations += 1
#if DEBUG
                ChatPerformanceInvalidationProbe.shared?.record(
                    "native_boundary_configuration", a: item == .header ? 0 : 1,
                    b: stamp == nil ? 0 : 1)
#endif
                content = item == .header ? input.makeHeader() : input.makeFooter()
            case .row(let id):
                guard let index = indices[id] else { return }
                content = input.makeRow(index)
                let rowStamp = rowStamp(for: id)
                (cell as? Cell)?.rowStamp = rowStamp
                revisions[id] = rowStamp?.revision
            }
            let rowWidth = max(1, collection.bounds.width - input.horizontalPadding * 2)
            var hostedEnvironment = input.environment
            if case .row = item {
                hostedEnvironment.markdownPresentationInteraction = markdownPresentationInteraction
            }
            cell.contentConfiguration = UIHostingConfiguration {
                // Compose the row-specific value into the snapshot: an inner
                // whole-environment modifier would override an outer key modifier.
                content.environment(\.self, hostedEnvironment)
                    .id(item)
                    .frame(width: rowWidth, alignment: .leading)
            }.margins(.all, 0)
        }

        private func resolvedLatestBottomInset(_ value: ChatNativeTranscriptViewport) -> CGFloat {
            value.latestBottomInset.map { max(0, $0) } ?? max(16, value.bottomInset - 32)
        }

        private func setStreamingInteraction(_ active: Bool) {
            if !active { cancelPendingInteractionEnd() }
            // Establish the stationary reader hold before the gesture gate opens.
            // Model publication and terminal row configuration remain independent.
            synchronizeCanonicalPresentationHold()
            guard streamingInteractionActive != active else { return }
            streamingInteractionActive = active
            markdownPresentationInteraction.isInteracting = active
            input.onStreamingInteractionChanged(active)
        }

        private func synchronizeCanonicalPresentationHold() {
            let restoresReader: Bool
            if case .restoring(let target) = ownership {
                if target != nil { restoresReader = true }
                else if let request = input.restoreRequest, case .message = request.target { restoresReader = true }
                else { restoresReader = false }
            } else { restoresReader = false }
            let held: Bool
            if stopped || !input.environment.usesMuseChatSurface {
                held = false
            } else if presentationSuspended {
                // A covered same-scope reader can return to the existing host.
                return
            } else if explicitLatestOwnsViewport {
                held = false
            } else if restoresReader {
                // The currently realized tail may belong to the old viewport,
                // before the requested reader anchor has been positioned.
                held = true
            } else if initialized, collection != nil, !systemTopActive, realizedTailArrival {
                held = false
            } else {
                switch ownership {
                case .reading: held = true
                case .restoring, .following:
                    // A follow hint alone cannot reformat a detached reader.
                    // Actual measured tail arrival releases an existing hold.
                    return
                }
            }
            if markdownPresentationInteraction.holdsCanonicalPresentation != held {
                markdownPresentationInteraction.holdsCanonicalPresentation = held
            }
        }

        private func cancelPendingInteractionEnd() {
            interactionEndGeneration &+= 1
            interactionEndTask?.cancel()
            interactionEndTask = nil
        }

        private func deferInteractionEndUntilTrackingSettles() {
            guard streamingInteractionActive, interactionEndTask == nil else { return }
            let ticket = interactionEndGeneration
            let scope = input.scope
            interactionEndTask = Task { [weak self] in
                // UIKit can deliver didEndDragging while isTracking is still
                // true. Yield its cleanup without dropping the only end event.
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                guard let self, !Task.isCancelled,
                      self.interactionEndGeneration == ticket,
                      self.input.scope == scope, !self.stopped,
                      !self.presentationSuspended else { return }
                self.interactionEndTask = nil
                self.endInteraction()
            }
        }

        /// Only the body text/rate (including final formatting) of an already
        /// fitted plain streaming row can wait for the gesture. Changed durable
        /// identity, tools, attachments and actions keep immediate presentation.
        private func shouldDeferStreamingRow(_ cell: UICollectionViewCell, id: String,
                                            next: StableViewportRowRevision) -> Bool {
            guard input.environment.usesMuseChatSurface,
                  !systemTopActive, !explicitLatestOwnsViewport, motionLink == nil,
                  streamingInteractionActive || collection.isDragging || collection.isDecelerating,
                  (collection.collectionViewLayout as? ColumnLayout)?.measured.contains(.row(id)) == true,
                  let stamp = (cell as? Cell)?.rowStamp,
                  stamp.key == rowStamp(for: id)?.key
            else { return false }
            return Self.isOnlyStreamingBodyChange(from: stamp.revision, to: next)
        }

        static func isOnlyStreamingBodyChange(from old: StableViewportRowRevision,
                                             to next: StableViewportRowRevision) -> Bool {
            let before = old.message.message
            let after = next.message.message
            guard old.hasActiveStream,
                  let streamID = old.streamingAssistantMessageID,
                  (next.hasActiveStream && next.streamingAssistantMessageID == streamID)
                    || (!next.hasActiveStream && next.streamingAssistantMessageID == nil),
                  before.messageId == streamID, after.messageId == streamID,
                  before.role == "assistant", after.role == "assistant",
                  before.contentParts == nil, after.contentParts == nil,
                  before.attachments == nil, after.attachments == nil else { return false }
            let unchangedBody = ChatMessage(role: after.role, content: before.content,
                timestamp: after.timestamp, messageId: after.messageId, name: after.name,
                toolCallId: after.toolCallId, toolUseId: after.toolUseId, toolCalls: after.toolCalls,
                contentParts: after.contentParts, reasoning: after.reasoning,
                attachments: after.attachments, turnTps: before.turnTps)
            let unchangedRow = TranscriptMessage(loadedIndex: next.message.loadedIndex,
                renderID: next.message.renderID, anchorID: next.message.anchorID,
                message: unchangedBody, attachmentDisplayContent: next.message.attachmentDisplayContent)
            let normalized = StableViewportRowRevision(message: unchangedRow,
                outgoingInsertionEvent: next.outgoingInsertionEvent, allowsOutgoingMotion: next.allowsOutgoingMotion,
                reasoningGroups: next.reasoningGroups, toolCallGroups: next.toolCallGroups,
                liveReasoningText: next.liveReasoningText, liveToolCalls: next.liveToolCalls,
                streamingAssistantMessageID: old.streamingAssistantMessageID,
                liveTokensPerSecond: old.liveTokensPerSecond,
                localAttachmentPreviews: next.localAttachmentPreviews,
                compressionReferenceCard: next.compressionReferenceCard, listeningMessageID: next.listeningMessageID,
                showsThinkingAndToolCards: next.showsThinkingAndToolCards, isViewingCachedData: next.isViewingCachedData,
                hasActiveStream: old.hasActiveStream, isRegeneratingMessage: next.isRegeneratingMessage,
                isEditingMessage: next.isEditingMessage, isForkingMessage: next.isForkingMessage,
                transcriptMediaCacheNamespace: next.transcriptMediaCacheNamespace)
            return normalized == old
        }

        private func flushDeferredStreamingRows() {
            guard !deferredStreamingRowIDs.isEmpty else { return }
            let current = !systemTopActive && !explicitLatestOwnsViewport && motionLink == nil
                ? currentAnchor() : nil
            let pending = deferredStreamingRowIDs
            deferredStreamingRowIDs.removeAll()
            let wasCorrecting = correcting
            correcting = true
            defer { correcting = wasCorrecting }
            for path in collection.indexPathsForVisibleItems {
                guard case .row(let id) = dataSource.itemIdentifier(for: path), pending.contains(id),
                      let cell = collection.cellForItem(at: path) else { continue }
                configure(cell, item: .row(id))
            }
            collection.layoutIfNeeded()
            if let current, indices[current.id] != nil {
                anchor = current
                _ = align(current)
                collection.layoutIfNeeded()
            }
        }

        func update(_ next: ChatNativeTranscriptViewport) {
            guard !stopped else { return }
            let old = input
            if old.scope != next.scope || !next.environment.usesMuseChatSurface {
                setStreamingInteraction(false)
                markdownPresentationInteraction.holdsCanonicalPresentation = false
                deferredStreamingRowIDs.removeAll()
            }
            if old.metricPublication !== next.metricPublication {
                old.metricPublication?.detachMeasuredViewport(source: ObjectIdentifier(self))
            }
            next.metricPublication?.bindMeasuredViewport(source: ObjectIdentifier(self),
                flush: { [weak self] in self?.flushForNavigation() },
                suspend: { [weak self] in self?.suspendPresentation() })
            // Capture the old reader position before changing row/scope inputs.
            let scopeChanged = old.scope != next.scope
            // onLatest synchronously asks the parent to clear restoration and
            // increment cancellation. Acknowledge exactly that echo, not a new
            // restore command or any subsequent cancellation.
            let latestEcho = !scopeChanged && latestEchoCancellationToken == next.cancellationToken
                && next.following && next.restoreRequest == nil && next.latestToken == old.latestToken
            let topEcho = !scopeChanged && systemTopEchoCancellationToken != nil
                && next.restoreRequest == nil && !next.explicitLatest
                && next.latestToken == old.latestToken
                && (next.cancellationToken == systemTopEchoCancellationToken
                    || (next.cancellationToken == old.cancellationToken && old.restoreRequest != nil))
            let rejoinCommand = !scopeChanged && old.latestToken != next.latestToken
                && next.restoreRequest == nil
            let olderEcho = !scopeChanged && olderTask != nil
                && olderEchoCancellationToken == next.cancellationToken
                && next.restoreRequest == nil && next.latestToken == old.latestToken
            let restoreChanged = old.restoreRequest != next.restoreRequest && !latestEcho && !topEcho && !olderEcho
            let cancelled = old.cancellationToken != next.cancellationToken && !latestEcho && !topEcho && !olderEcho
            if scopeChanged || old.cancellationToken != next.cancellationToken {
                olderEchoCancellationToken = nil
            }
            if scopeChanged || restoreChanged || old.cancellationToken != next.cancellationToken {
                systemTopEchoCancellationToken = nil
            }
            if scopeChanged || old.cancellationToken != next.cancellationToken {
                latestEchoCancellationToken = nil
            }
            if scopeChanged || restoreChanged { systemTopReaderIntent = false }
            if scopeChanged || restoreChanged || cancelled {
                cancelOlder()
                cancelSystemTop()
                cancelMotion()
                invalidatePublications()
                pendingRestore = nil
            }
            if latestEcho || topEcho, old.restoreRequest != next.restoreRequest {
                invalidatePublications()
                pendingRestore = nil
            }
            if scopeChanged { saveMemory(scope: old.scope, typeKey: old.typeKey) }
            if old.typeKey != next.typeKey || old.horizontalPadding != next.horizontalPadding
                || old.spacing != next.spacing || old.bottomInset != next.bottomInset
                || old.topInset != next.topInset {
                cancelFollow()
            }
            if followLink != nil && (old.revision != next.revision || old.isStreaming != next.isStreaming) {
                followContentChangedAt = CACurrentMediaTime()
            }
            lastSourceMutation = ChatTranscriptSourceMutation.classify(previous: old.ids, next: next.ids)
            if old.typeKey != next.typeKey || lastSourceMutation != .unchanged {
                invalidatePublications()
                pendingRestore = nil
                resetSettlement()
                if motionLink == nil, let request = next.restoreRequest, request != completedRequest {
                    ownership = requestedOwnership(next)
                }
            }
            if old.typeKey != next.typeKey {
                cancelMotion()
                if case .reading = ownership { anchor = currentAnchor() ?? anchor }
            }
            if let anchor, !next.ids.contains(anchor.id) { self.anchor = nil }
            let handoff: ReaderHandoff?
            if !scopeChanged, !restoreChanged, !cancelled, initialized,
               lastSourceMutation != .unchanged, case .reading = ownership,
               motionLink == nil, !collection.isTracking, !collection.isDragging,
               let current = currentAnchor(), next.ids.contains(current.id) {
                handoff = ReaderHandoff(anchor: current, scope: next.scope,
                    width: collection.bounds.width, revision: next.revision,
                    cancellation: next.cancellationToken, generation: generation,
                    presentation: presentationEpoch)
            } else { handoff = nil }
            input = next
            guard isViewLoaded else { return }
            // Use the same composer clearance as the legacy sibling control.
            latestBottomConstraint?.constant = -resolvedLatestBottomInset(next)
            if collection.contentInset.top != next.topInset {
                collection.contentInset.top = next.topInset
            }
            latest.backgroundColor = UIColor(SemrehVisualTheme.raisedPanel(for: next.environment.colorScheme,
                palette: next.environment.appColorPalette))
            latest.tintColor = UIColor(SemrehVisualTheme.primaryText(for: next.environment.colorScheme,
                palette: next.environment.appColorPalette))
            if old.scope != next.scope {
                generation += 1
                initialized = false
                immediateFollowRevision = nil
                completedRequest = nil
                resetSettlement()
                anchor = nil
                revisions.removeAll()
                lastPublished = nil
                cancelRefresh()
                ownership = requestedOwnership(next)
            } else if restoreChanged, let request = next.restoreRequest, request != completedRequest {
                resetSettlement()
                ownership = requestedOwnership(next)
            }
            if cancelled {
                ownership = .reading
                finishRestore(.cancelled)
            }
            // A new explicit command supersedes system-top motion, but never a
            // direct tracking/dragging. Inherited momentum yields to the command.
            let explicitEdge = !old.explicitLatest && next.explicitLatest
            if systemTopActive && explicitEdge && !scopeChanged && !restoreChanged && !cancelled
                && isPresentationActive && !presentationSuspended
                && !collection.isTracking && !collection.isDragging {
                cancelSystemTop()
            }
            // Rejoin is distinct from stale following input. It may accompany
            // cancellation/removal of the old restore, but never a new restore or
            // scope, and its consumed token cannot reclaim a later gesture.
            if rejoinCommand && isPresentationActive && !presentationSuspended
                && !collection.isTracking && !collection.isDragging {
                cancelSystemTop()
                cancelMotion()
                systemTopReaderIntent = false
                ownership = .following
                // Claim before stopping inherited momentum: UIKit may deliver
                // synchronous end callbacks, which must not reclaim this command.
                if collection.isDecelerating {
                    handingOffRejoinMomentum = true
                    defer { handingOffRejoinMomentum = false }
                    decelerationTakeovers += 1
                    collection.setContentOffset(collection.contentOffset, animated: false)
                }
            }
            // Consume command edges once; a retained true flag cannot reclaim a drag.
            // A same-tap echo only acknowledges input, even after motion cancellation.
            if isPresentationActive && !presentationSuspended && !collection.isTracking && !collection.isDragging && !scopeChanged && !restoreChanged && !cancelled && !latestEcho && !topEcho {
                if explicitEdge && initialized {
                    beginMotion()
                } else if !interacting && !systemTopReaderIntent && motionLink == nil && (!old.following && next.following) {
                    ownership = .following
                }
            }
            if old.horizontalPadding != next.horizontalPadding || old.spacing != next.spacing || old.bottomInset != next.bottomInset {
                if !(collection.collectionViewLayout is ColumnLayout) {
                    collection.setCollectionViewLayout(makeLayout(), animated: false)
                }
            }
            (collection.collectionViewLayout as? ColumnLayout)?.configure(input: next, width: collection.bounds.width)
            // Scroll/follow echoes and streamed content usually retain row identity.
            // Avoid rebuilding the history index and copying the diffable snapshot
            // on those updates; mounted row revisions are still checked below.
            if !reusesIdentitySnapshot || appliedIDs != next.ids {
                identityBuilds += 1
                indices = Dictionary(uniqueKeysWithValues: next.ids.enumerated().map { ($0.element, $0.offset) })
                let items: [Item] = [.header] + next.ids.map(Item.row) + [.footer]
                let previous = dataSource.snapshot().itemIdentifiers
                if previous != items {
                    var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
                    snapshot.appendSections([0]); snapshot.appendItems(items)
                    applying = true
                    let column = collection.collectionViewLayout as? ColumnLayout
                    column?.beginSnapshotTransition()
                    dataSource.apply(snapshot, animatingDifferences: false)
                    column?.commitSnapshot(dataSource.snapshot().itemIdentifiers)
                    applying = false
                    revisions = revisions.filter { indices[$0.key] != nil }
                }
                appliedIDs = next.ids
            }
            // Only mounted changed rows are reconfigured. Offscreen rows read fresh
            // inputs when dequeued; no eager hosts or all-row measurement pass.
            for path in collection.indexPathsForVisibleItems {
                guard let item = dataSource.itemIdentifier(for: path), let cell = collection.cellForItem(at: path) else { continue }
                switch item {
                case .row(let id):
                    if let index = indices[id], revisions[id] != next.revisionAt(index) || old.typeKey != next.typeKey
                        || old.horizontalPadding != next.horizontalPadding {
                        let nextRevision = next.revisionAt(index)
                        if !scopeChanged, !restoreChanged, !cancelled,
                           old.typeKey == next.typeKey, old.horizontalPadding == next.horizontalPadding,
                           shouldDeferStreamingRow(cell, id: id, next: nextRevision) {
                            deferredStreamingRowIDs.insert(id)
                        } else {
                            configure(cell, item: item)
                        }
                    }
                default:
                    if !reusesBoundaryConfigurations || boundaryStamp(for: item) == nil
                        || (cell as? Cell)?.boundaryStamp != boundaryStamp(for: item) {
                        configure(cell, item: item)
                    }
                }
            }
            collection.setNeedsLayout()
            if let handoff { commitReaderHandoff(handoff) }
        }

        // The handoff is synchronous, within one UIKit update. No queued proxy
        // alignment can outlive a touch, Back, Send or source/scope replacement.
        func commitReaderHandoff(_ sample: ReaderHandoff) {
            func isCurrent() -> Bool {
                !stopped && !presentationSuspended && input.scope == sample.scope
                    && input.revision == sample.revision && input.cancellationToken == sample.cancellation
                    && generation == sample.generation && presentationEpoch == sample.presentation
                    && collection.bounds.width == sample.width
                    && !collection.isTracking && !collection.isDragging
            }
            guard isCurrent() else { return }
            let wasCorrecting = correcting
            correcting = true
            defer { correcting = wasCorrecting }
            collection.layoutIfNeeded()
            guard isCurrent(), indices[sample.anchor.id] != nil else { return }
            anchor = sample.anchor
            _ = align(sample.anchor)
            collection.layoutIfNeeded()
        }

        // Choose the durable row before UIKit realizes its first cell set. Warm
        // estimates refine geometry, but never replace the requested source ID.
        func primeInitialViewport() {
            guard !initialized, !stopped, !presentationSuspended,
                  collection.bounds.width > 0, collection.bounds.height > 0,
                  let layout = collection.collectionViewLayout as? ColumnLayout else { return }
            layout.prepare()
            initialized = true
            ownership = requestedOwnership(input)
            switch ownership {
            case .restoring(let target):
                if let target { _ = align(target) }
                else { collection.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false) }
            case .following:
                collection.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
            case .reading: break
            }
        }

        /// Explicit navigation owns the target. Cached intra-row deltas refine only
        /// the same requested row; they can never override a latest/different-row request.
        func requestedOwnership(_ value: ChatNativeTranscriptViewport) -> Ownership {
            let key = "\(value.scope)|\(Int(collection.bounds.width.rounded()))|\(value.typeKey)"
            let saved = Self.memory[key]
            func row(_ id: String) -> Ownership {
                .restoring(saved?.anchor.id == id ? saved?.anchor : Anchor(id: id, delta: 0))
            }
            if let request = value.restoreRequest {
                switch request.target {
                case .latest: return .following
                case .message(let id): return row(id)
                }
            }
            if value.explicitLatest { return .following }
            if let id = value.initialID { return row(id) }
            if value.following { return .following }
            if let saved { return saved.following ? .following : .restoring(saved.anchor) }
            return .following
        }
        func resetSettlement() {
            settlementSample = nil
            confirmationPasses = 0
        }
        /// A measured native cell must agree on a subsequent layout, including
        /// after a width/configuration change. Existence alone is not settlement.
        /// At most four extra layout requests are issued; failure stays explicit.
        func confirmsSettlement(frame: CGRect, positioned: Bool) -> Bool {
            guard let request = input.restoreRequest, request != completedRequest else { return positioned }
            let sample = SettlementSample(request: request, width: width,
                contentSize: collection.contentSize, targetFrame: frame, offset: collection.contentOffset)
            if positioned, settlementSample == sample { return true }
            settlementSample = sample
            guard !confirmationQueued else { return false }
            guard confirmationPasses < 4 else {
                finishRestore(.exhausted)
                return false
            }
            confirmationQueued = true
            confirmationPasses += 1
            let epoch = generation, presentation = presentationEpoch
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, !self.presentationSuspended,
                      self.generation == epoch, self.presentationEpoch == presentation else { return }
                self.confirmationQueued = false
                guard self.input.restoreRequest == request, self.completedRequest != request else { return }
                self.collection.setNeedsLayout()
            }
            return false
        }
        var memoryKey: String { "\(input.scope)|\(Int(collection.bounds.width.rounded()))|\(input.typeKey)" }
        var bottomOffset: CGFloat { max(-collection.adjustedContentInset.top, collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom) }
        var interacting: Bool {
            ChatScrollPolicy.isEffectiveUserInteraction(
                isUserInteracting: systemTopActive || collection.isTracking || collection.isDragging || collection.isDecelerating,
                isDirectlyInteracting: systemTopActive || collection.isTracking || collection.isDragging,
                isDecelerating: collection.isDecelerating,
                isExplicitBottomScrollContext: explicitLatestOwnsViewport || handingOffRejoinMomentum)
        }
        var follows: Bool { if case .following = ownership { return true }; return false }
        func currentAnchor() -> Anchor? {
            let top = collection.contentOffset.y + collection.adjustedContentInset.top
            return collection.indexPathsForVisibleItems.sorted().compactMap { path -> Anchor? in
                guard case .row(let id) = dataSource.itemIdentifier(for: path),
                      let frame = collection.layoutAttributesForItem(at: path)?.frame, frame.maxY > top else { return nil }
                return Anchor(id: id, delta: top - frame.minY)
            }.first
        }
        func align(_ target: Anchor) -> Bool {
            guard let path = dataSource.indexPath(for: .row(target.id)),
                  let frame = collection.layoutAttributesForItem(at: path)?.frame else { return false }
            let y = min(bottomOffset, max(-collection.adjustedContentInset.top, frame.minY + target.delta - collection.adjustedContentInset.top))
            if abs(collection.contentOffset.y - y) > 0.5 { collection.setContentOffset(CGPoint(x: 0, y: y), animated: false) }
            return collection.cellForItem(at: path) != nil
                && ((collection.collectionViewLayout as? ColumnLayout)?.measured.contains(.row(target.id)) ?? true)
        }
        func disableNestedScrollToTop(in view: UIView) {
            guard !batchingMotionObservations else { needsMotionDescendantScan = true; return }
            descendantScanPasses += 1
            func visit(_ view: UIView) {
                for child in view.subviews {
                    if let scroll = child as? UIScrollView { scroll.scrollsToTop = false }
                    visit(child)
                }
            }
            visit(view)
        }
        func settleLayout() {
            guard !stopped, !presentationSuspended, !applying, !correcting, collection.bounds.width > 0, collection.bounds.height > 0 else { return }
            correcting = true
            defer { correcting = false }
            if !initialized {
                initialized = true
                ownership = requestedOwnership(input)
            }
            // Only descendants owned by this transcript are ineligible. Hosted
            // selectable text and horizontal code scroll views must not compete.
            disableNestedScrollToTop(in: collection)
            if viewportSize != collection.bounds.size || viewportInsets != collection.adjustedContentInset {
                if viewportSize != .zero { immediateFollowRevision = input.revision }
                cancelFollow()
                viewportSize = collection.bounds.size
                viewportInsets = collection.adjustedContentInset
            }
            let widthChanged = width != collection.bounds.width
            if widthChanged {
                resetSettlement()
                width = collection.bounds.width
                for path in collection.indexPathsForVisibleItems {
                    if let item = dataSource.itemIdentifier(for: path), let cell = collection.cellForItem(at: path) {
                        configure(cell, item: item)
                    }
                }
            }
            if !interacting && motionLink == nil {
                switch ownership {
                case .restoring(let target):
                    if let target {
                        if align(target), let path = dataSource.indexPath(for: .row(target.id)),
                           let cell = collection.cellForItem(at: path) {
                            let desired = min(bottomOffset, max(-collection.adjustedContentInset.top,
                                cell.frame.minY + target.delta - collection.adjustedContentInset.top))
                            if confirmsSettlement(frame: cell.frame,
                                positioned: !widthChanged && abs(collection.contentOffset.y - desired) <= 1) {
                                anchor = target
                                ownership = .reading
                                finishRestore(.success)
                            }
                        } else if indices[target.id] == nil {
                            ownership = .reading
                            finishRestore(.unavailable)
                        }
                    } else {
                        ownership = .following
                        collection.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
                        // Completion requires a realized tail, not estimated geometry.
                        if let tail = collection.cellForItem(at: IndexPath(item: input.ids.count + 1, section: 0)),
                           confirmsSettlement(frame: tail.frame, positioned: !widthChanged && realizedTailArrival) {
                            finishRestore(.success)
                        }
                    }
                case .following:
                    if canGlideFollow && (bottomOffset - collection.contentOffset.y > 0.5
                        || (followLink != nil && !realizedTailArrival)) {
                        beginFollow()
                    } else {
                        cancelFollow(resetEligibility: false)
                        if abs(collection.contentOffset.y - bottomOffset) > 0.5 {
                            collection.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
                        }
                    }
                    if let tail = collection.cellForItem(at: IndexPath(item: input.ids.count + 1, section: 0)),
                           confirmsSettlement(frame: tail.frame, positioned: !widthChanged && realizedTailArrival) {
                            finishRestore(.success)
                        }
                case .reading:
                    if let anchor { _ = align(anchor) }
                }
            }
            if follows && realizedTailArrival { realizedBottomEstablished = true }
            publish()
        }
        func finishRestore(_ outcome: ChatTranscriptRestoreOutcome) {
            guard let request = input.restoreRequest, request != completedRequest,
                  pendingRestore == nil else { return }
            pendingRestore = (request, outcome)
            guard !presentationSuspended else { return }
            let epoch = generation, presentation = presentationEpoch
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, !self.presentationSuspended,
                      self.generation == epoch, self.presentationEpoch == presentation,
                      self.input.restoreRequest == request,
                      self.pendingRestore?.request == request else { return }
                self.pendingRestore = nil
                self.completedRequest = request
                self.input.onRestore(request, outcome)
            }
        }
        // Scroll tickets are independent of onState tickets: an eager identical
        // publication must still allow its already queued onState delivery.
        private func enqueueScrollObservation() {
            guard !batchingMotionObservations else { return }
            guard coalescesScrollObservations else { publish(); return }
            guard pendingScrollObservation == nil else { return }
            scrollObservationTicket &+= 1
            let ticket = scrollObservationTicket
            let epoch = generation, presentation = presentationEpoch
            pendingScrollObservation = ticket
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingScrollObservation == ticket else { return }
                self.pendingScrollObservation = nil
                guard !self.stopped, !self.presentationSuspended,
                      !self.correcting, !self.applying, !self.batchingMotionObservations,
                      self.generation == epoch, self.presentationEpoch == presentation else { return }
                self.scrollObservationDrains += 1
                self.publish()
            }
        }

#if DEBUG
        // Read UIKit's completed keyboard transition, including the prediction
        // strip omitted by XCTest's Keyboard AX element. No layout is driven here.
        private func updateDebugProbe() {
            let mountedStreamingRows = collection.visibleCells.reduce(into: 0) { count, cell in
                guard let row = (cell as? Cell)?.rowStamp?.revision,
                      row.hasActiveStream,
                      row.streamingAssistantMessageID == row.message.message.messageId else { return }
                count += 1
            }
            probe.accessibilityLabel = "Native transcript v2"
            probe.accessibilityValue = "mounted=\(collection.visibleCells.count);logical=\(input.ids.count);state=\(follows ? "following" : "reading");motion=\(motionLink == nil ? "idle" : "animating");motionCompleted=\(motionCompleted);motionCancelled=\(motionCancelled);motionSamples=\(motionSamples);motionReceipt=\(debugMotionReceipt);decelerationTakeovers=\(decelerationTakeovers);topRequests=\(systemTopRequests);topCompleted=\(systemTopCompleted);topActive=\(systemTopActive);surfaceTop=\(input.topInset);surfaceBottom=\(input.bottomInset);keyboardTop=\(observedKeyboardFrame.minY);keyboardHeight=\(observedKeyboardFrame.height);streamInteraction=\(streamingInteractionActive);markdownInteraction=\(markdownPresentationInteraction.isInteracting);tracking=\(collection.isTracking);dragging=\(collection.isDragging);decelerating=\(collection.isDecelerating);deferredRows=\(deferredStreamingRowIDs.count);inputStreaming=\(input.isStreaming);mountedStreamingRows=\(mountedStreamingRows);dragEndCallbacks=\(debugDragEndCallbacks);decelerationEndCallbacks=\(debugDecelerationEndCallbacks);lastInteractionEndFlags=\(debugLastInteractionEndFlags)"
        }

        private func recordDebugMotion(_ reason: String, elapsed: CFTimeInterval) {
            let footer = dataSource.indexPath(for: .footer).flatMap { collection.cellForItem(at: $0) }
            debugMotionReceipt = "\(reason),elapsed:\(elapsed),tail:\(realizedTailArrival),gap:\(bottomOffset - collection.contentOffset.y),offset:\(collection.contentOffset.y),bottom:\(bottomOffset),previousTail:\(String(describing: motionTailSample)),footer:\(String(describing: footer?.frame))"
        }

        private func recordDebugInteractionEnd(_ kind: String) {
            debugLastInteractionEndFlags = "\(kind),tracking:\(collection.isTracking),dragging:\(collection.isDragging),decelerating:\(collection.isDecelerating),stopped:\(stopped),suspended:\(presentationSuspended)"
            updateDebugProbe()
        }
#endif

        func publish() {
            pendingScrollObservation = nil
            guard !stopped, !presentationSuspended, !batchingMotionObservations else { return }
            synchronizeCanonicalPresentationHold()
            publishComputations += 1
            let distance = max(0, bottomOffset - collection.contentOffset.y)
            let observedVisible = currentAnchor()?.id
            let visible: String?
            if case .restoring(let target) = ownership, let target,
               observedVisible != target.id { visible = nil }
            else { visible = observedVisible }
            let lastVisible = input.ids.last.map { id in collection.indexPathsForVisibleItems.contains { dataSource.itemIdentifier(for: $0) == .row(id) } } ?? false
            let metrics = ChatScrollMetrics(distanceFromBottom: distance, isUserInteracting: interacting, isDirectlyInteracting: systemTopActive || collection.isTracking || collection.isDragging, isDecelerating: collection.isDecelerating)
            let arrived = realizedTailArrival
            latest.isHidden = (arrived && motionLink == nil) || (followLink != nil && canGlideFollow)
#if DEBUG
            updateDebugProbe()
#endif
            let sample = Published(metrics: metrics, visible: visible, last: lastVisible, bottom: arrived)
            guard sample != lastPublished else { return }
            lastPublished = sample
            publication += 1
            let ticket = publication, epoch = generation, presentation = presentationEpoch
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, !self.presentationSuspended, self.presentationEpoch == presentation, self.generation == epoch, self.publication == ticket else { return }
                // A newer scroll can arrive before this older delivery. Observe
                // it first; equal geometry preserves this delivery, changed geometry
                // issues a new ticket instead of sending stale state to the parent.
                if self.pendingScrollObservation != nil {
                    self.scrollObservationDrains += 1
                    self.publish()
                    guard self.publication == ticket else { return }
                }
                self.input.onState(metrics, visible, lastVisible, arrived)
            }
        }
        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            guard scrollView === collection, isPresentationActive, !presentationSuspended else { return false }
            systemTopRequests += 1
            invalidatePublications()
            pendingRestore = nil
            resetSettlement()
            cancelMotion()
            systemTopActive = true
            systemTopReaderIntent = true
            flushDeferredStreamingRows()
            setStreamingInteraction(false)
            systemTopEchoCancellationToken = input.cancellationToken &+ 1
            ownership = .reading
            anchor = currentAnchor()
            finishRestore(.cancelled)
            publish()
            return true
        }
        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            guard scrollView === collection, systemTopActive, !stopped, !presentationSuspended else { return }
            systemTopActive = false
            systemTopCompleted += 1
            anchor = currentAnchor()
            ownership = .reading
            saveMemory(scope: input.scope)
            publish()
        }
        func cancelSystemTop() {
            guard systemTopActive else { return }
            systemTopActive = false
            // Stop UIKit's animation at the currently displayed reader position.
            let offset = collection.contentOffset
            collection.setContentOffset(offset, animated: false)
            anchor = currentAnchor()
            ownership = .reading
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard !stopped, !presentationSuspended else { return }
            cancelPendingInteractionEnd()
            setStreamingInteraction(input.environment.usesMuseChatSurface)
            cancelOlder()
            invalidatePublications()
            pendingRestore = nil
            cancelSystemTop()
            cancelMotion()
            ownership = .reading
            anchor = currentAnchor()
            finishRestore(.cancelled)
            publish()
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Native callback count is telemetry, never a frame-rate estimate.
            if motionLink != nil { motionSamples += 1 }
            guard !stopped, !presentationSuspended, !correcting, !applying else { return }
            if interacting { anchor = currentAnchor() }
            enqueueScrollObservation()
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
#if DEBUG
            debugDragEndCallbacks += 1
            recordDebugInteractionEnd("drag-end,willDecelerate:\(decelerate)")
#endif
            if !decelerate { endInteraction() } else { publish() }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
#if DEBUG
            debugDecelerationEndCallbacks += 1
            recordDebugInteractionEnd("deceleration-end")
#endif
            endInteraction()
        }
        func endInteraction() {
            guard !stopped, !presentationSuspended,
                  !collection.isDragging, !collection.isDecelerating else { return }
            if collection.isTracking {
                deferInteractionEndUntilTrackingSettles()
                return
            }
            flushDeferredStreamingRows()
            setStreamingInteraction(false)
            // A real drag moves ownership to reading before its end callback.
            // An obsolete momentum-end callback cannot revoke newer follow intent.
            guard !stopped, !presentationSuspended, !interacting, !follows,
                  !explicitLatestOwnsViewport, !handingOffRejoinMomentum else { return }
            anchor = currentAnchor()
            ownership = realizedTailArrival ? .following : .reading
            saveMemory(scope: input.scope)
            publish()
            loadOlderIfNeeded()
        }
        var realizedTailArrival: Bool {
            guard (collection.collectionViewLayout as? ColumnLayout)?.measured.contains(.footer) ?? true,
                  let path = dataSource.indexPath(for: .footer),
                  let tail = collection.cellForItem(at: path),
                  let frame = collection.layoutAttributesForItem(at: path)?.frame,
                  abs(tail.frame.maxY - frame.maxY) <= 1 else { return false }
            let visibleBottom = collection.contentOffset.y + collection.bounds.height - collection.adjustedContentInset.bottom
            return abs(collection.contentOffset.y - bottomOffset) <= 1 && tail.frame.maxY <= visibleBottom + 1
        }
        var canGlideFollow: Bool {
            isPresentationActive && !presentationSuspended && (input.isStreaming || followLink != nil)
                && follows && realizedBottomEstablished && immediateFollowRevision != input.revision
                && !interacting && motionLink == nil
                && !input.environment.accessibilityReduceMotion && !reduceMotionEnabled()
                && (input.restoreRequest == nil || input.restoreRequest == completedRequest)
        }
        func cancelFollow(resetEligibility: Bool = true) {
            followLink?.invalidate()
            followLink = nil
            if resetEligibility { realizedBottomEstablished = false }
        }
        private func beginFollow() {
            guard followLink == nil else { return }
            followTimestamp = CACurrentMediaTime()
            followContentChangedAt = followTimestamp
            let link = CADisplayLink(target: FollowTarget(self), selector: #selector(FollowTarget.tick(_:)))
            followLink = link
            link.add(to: .main, forMode: .common)
        }
        // Shared by both display-link owners. Suppression lives only on this
        // synchronous stack and is released before observing the final geometry.
        private func beginObservationBatch() -> () -> Void {
            let epoch = generation, presentation = presentationEpoch, scope = input.scope
            batchingMotionObservations = batchesMotionObservations
            needsMotionDescendantScan = false
            return { [self] in
                let needsScan = needsMotionDescendantScan
                batchingMotionObservations = false
                needsMotionDescendantScan = false
                guard batchesMotionObservations, !stopped, !presentationSuspended,
                      generation == epoch, presentationEpoch == presentation, input.scope == scope else { return }
                if needsScan { disableNestedScrollToTop(in: collection) }
                publish()
            }
        }
        func advanceFollow(_ link: CADisplayLink) {
            guard followLink === link else { return }
            guard canGlideFollow else {
                cancelFollow()
                collection.setNeedsLayout()
                return
            }
            let publicationsBefore = publishComputations, scansBefore = descendantScanPasses
            followObservationSteps += 1
            let finishObservations = beginObservationBatch()
            defer {
                finishObservations()
                followPublishComputations += publishComputations - publicationsBefore
                followDescendantScanPasses += descendantScanPasses - scansBefore
            }
            collection.layoutIfNeeded()
            guard followLink === link, canGlideFollow else { return }
            followTicks += 1
            let now = link.timestamp
            let elapsed = max(0, now - followTimestamp)
            followTimestamp = now
            let target = bottomOffset
            let current = collection.contentOffset.y
            let remaining = target - current
            // Self-sizing can move estimates without any new content. It must not
            // renew this deadline and keep the realized tail perpetually out of reach.
            let settle = remaining <= 0.5 || now - followContentChangedAt >= 0.5
            let y = settle ? target : current + remaining * CGFloat(1 - exp(-elapsed / 0.07))
            // Suppress recursive layout/scroll publication until this offset is applied.
            correcting = true
            collection.setContentOffset(CGPoint(x: collection.contentOffset.x,
                y: min(target, max(-collection.adjustedContentInset.top, y))), animated: false)
            collection.layoutIfNeeded()
            correcting = false
            guard followLink === link, canGlideFollow else { return }
            if settle && realizedTailArrival { cancelFollow(resetEligibility: false) }
            collection.setNeedsLayout()
            publish()
        }
        private func updateEdgeMask() {
            let edge = visualEdgeGeometry
            if #available(iOS 26.0, *) {
                collection.bottomEdgeEffect.isHidden = input.environment.usesMuseChatSurface
            }
            let edgeColor = input.environment.accessibilityReduceTransparency ? UIColor.black.cgColor : UIColor.clear.cgColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // A scroll layer's bounds origin moves with contentOffset. The mask
            // must move with that origin to remain fixed at the viewport edges.
            edgeMask.frame = collection.bounds
            edgeMask.colors = [edgeColor, UIColor.black.cgColor, UIColor.black.cgColor, edgeColor, edgeColor]
            edgeMask.locations = [0, NSNumber(value: Double(edge.topEnd)),
                NSNumber(value: Double(edge.bottomStart)), NSNumber(value: Double(edge.bottomEnd)), 1]
            CATransaction.commit()
        }

        var visualEdgeGeometry: ChatTranscriptEdgeGeometry {
            // Composer clearance remains in the layout. Muse content draws under
            // its floating controls and fades only at the physical viewport edge.
            ChatTranscriptEdgeGeometry(height: collection.bounds.height,
                bottomInset: input.environment.usesMuseChatSurface ? 32 : input.bottomInset)
        }

        func beginMotion() {
            cancelFollow()
            guard isPresentationActive, !presentationSuspended, motionLink == nil,
                  !systemTopActive, !collection.isTracking, !collection.isDragging else { return }
#if DEBUG
            // The optional call reads the mach clock only when the trace is opted
            // in, before opening the canonical gate or synchronously fitting rows.
            ChatPerformanceInvalidationProbe.shared?.record("native_latest_begin",
                a: input.ids.count, b: markdownPresentationInteraction.canonicalPreparationCount,
                c: markdownPresentationInteraction.canonicalCommitCount)
#endif
            explicitLatestOwnsViewport = true
            ownership = .following
            // Claim ownership before stopping UIKit: it can synchronously deliver
            // scroll/end callbacks. Count only the state actually observed here.
            if collection.isDecelerating {
                decelerationTakeovers += 1
                let visibleOffset = collection.contentOffset
                let wasCorrecting = correcting
                correcting = true
                collection.setContentOffset(visibleOffset, animated: false)
                correcting = wasCorrecting
            }
            flushDeferredStreamingRows()
            setStreamingInteraction(false)
            systemTopReaderIntent = false
            systemTopEchoCancellationToken = nil
            guard !input.environment.accessibilityReduceMotion, !reduceMotionEnabled() else {
                collection.setNeedsLayout()
#if DEBUG
                ChatPerformanceInvalidationProbe.shared?.record("native_latest_no_motion", a: 0)
#endif
                return
            }
            guard !realizedTailArrival else {
#if DEBUG
                ChatPerformanceInvalidationProbe.shared?.record("native_latest_no_motion", a: 1)
#endif
                return
            }
            motionStarted = CACurrentMediaTime()
            motionProgress = 0
            motionTailSample = nil
            motionTailOffset = nil
            motionDeadlineConfirmationPending = false
#if DEBUG
            debugMotionReceipt = "started"
#endif
            let link = CADisplayLink(target: MotionTarget(self), selector: #selector(MotionTarget.tick(_:)))
            motionLink = link
            link.add(to: .main, forMode: .common)
            publish()
        }
        func advanceMotion(_ link: CADisplayLink) {
            guard motionLink === link, isPresentationActive, !presentationSuspended else { return }
            // Only this synchronous invocation owns suppression. Clear before the
            // final observation, including cancellation and Reduce Motion exits.
            let epoch = generation, presentation = presentationEpoch, scope = input.scope
            let publicationsBefore = publishComputations, scansBefore = descendantScanPasses
            motionTicks += 1
            let finishObservations = beginObservationBatch()
#if DEBUG
            var completedLatestForProbe = false
#endif
            defer {
                finishObservations()
                motionPublishComputations += publishComputations - publicationsBefore
                motionDescendantScanPasses += descendantScanPasses - scansBefore
#if DEBUG
                if completedLatestForProbe {
                    // Timestamp after the final tick's fitting/publication work;
                    // link.timestamp would omit a synchronous stall inside it.
                    ChatPerformanceInvalidationProbe.shared?.record("native_latest_end",
                        a: motionCompleted, b: motionCancelled,
                        c: markdownPresentationInteraction.canonicalCommitCount)
                }
#endif
            }
            guard !interacting else { cancelMotion(reason: "interaction"); publish(); return }
            if input.environment.accessibilityReduceMotion || reduceMotionEnabled() {
                cancelMotion()
                explicitLatestOwnsViewport = true
                ownership = .following
                collection.setNeedsLayout()
                return
            }
            collection.layoutIfNeeded()
            guard motionLink === link, !stopped, !presentationSuspended,
                  generation == epoch, presentationEpoch == presentation, input.scope == scope else { return }
            let elapsed = max(0, link.timestamp - motionStarted)
            let t = min(1, CGFloat(elapsed / ChatMotion.scrollToLatestDuration))
            // Zero velocity at both ends avoids the abrupt cubic ease-out launch.
            let eased = t * t * (3 - 2 * t)
            let fraction = motionProgress < 1 ? min(1, (eased - motionProgress) / (1 - motionProgress)) : 1
            motionProgress = eased
            let current = collection.contentOffset.y
            let y = current + (bottomOffset - current) * fraction
            collection.setContentOffset(CGPoint(x: collection.contentOffset.x, y: y), animated: false)
            collection.layoutIfNeeded()
            guard motionLink === link, !stopped, !presentationSuspended,
                  generation == epoch, presentationEpoch == presentation, input.scope == scope else { return }
            let tail = dataSource.indexPath(for: .footer).flatMap { collection.cellForItem(at: $0) }
            // A second realized, unchanged sample proves arrival after self-sizing.
            if t == 1, realizedTailArrival, let tail,
               motionTailSample == tail.frame, motionTailOffset == collection.contentOffset.y {
                motionLink?.invalidate()
                motionLink = nil
                motionCompleted += 1
                motionDeadlineConfirmationPending = false
#if DEBUG
                recordDebugMotion("completed", elapsed: elapsed)
                completedLatestForProbe = true
#endif
                anchor = currentAnchor()
                ownership = .following
                finishRestore(.success)
                saveMemory(scope: input.scope)
                publish()
                return
            }
            motionTailSample = realizedTailArrival ? tail?.frame : nil
            motionTailOffset = realizedTailArrival ? collection.contentOffset.y : nil
            // A late self-sizing change can make the deadline-ending tick the
            // first actual tail arrival. Allow exactly one fresh confirmation
            // sample; it must pass the same unchanged-frame/offset check above.
            // An unrealized or changing tail still exhausts without a retry ladder.
            if elapsed >= 0.9 {
                if realizedTailArrival, !motionDeadlineConfirmationPending {
                    motionDeadlineConfirmationPending = true
#if DEBUG
                    recordDebugMotion("deadline-confirmation", elapsed: elapsed)
#endif
                } else {
                    cancelMotion(reason: "exhausted", elapsed: elapsed)
                    finishRestore(.exhausted)
                    saveMemory(scope: input.scope)
                }
            }
            publish()
        }
        func cancelMotion(reason: String = "superseded", elapsed: CFTimeInterval? = nil) {
            cancelFollow()
            explicitLatestOwnsViewport = false
            // Retain the token until its parent echo is consumed. Cancellation
            // must not turn that queued same-tap echo into a fresh follow command.
            guard let link = motionLink else { return }
#if DEBUG
            recordDebugMotion(reason, elapsed: elapsed ?? max(0, CACurrentMediaTime() - motionStarted))
#endif
            motionDeadlineConfirmationPending = false
            link.invalidate()
            motionLink = nil
            motionCancelled += 1
            anchor = currentAnchor()
            ownership = .reading
            motionTailSample = nil
            motionTailOffset = nil
#if DEBUG
            ChatPerformanceInvalidationProbe.shared?.record("native_latest_cancel",
                a: reason == "exhausted" ? 2 : (reason == "interaction" ? 1 : 0),
                b: motionCancelled, c: markdownPresentationInteraction.canonicalCommitCount)
#endif
        }
        @objc func jumpToLatest() {
            guard isPresentationActive, !presentationSuspended,
                  !collection.isTracking, !collection.isDragging else { return }
            // A visible button press is fresh intent, even during our own glide
            // or before SwiftUI has echoed the preceding command.
            let priorIssuedToken = latestEchoCancellationToken ?? input.cancellationToken
            cancelOlder()
            cancelMotion()
            // Drop old reader callbacks immediately; waiting for the SwiftUI
            // echo can publish restoration after this newer navigation intent.
            invalidatePublications()
            pendingRestore = nil
            resetSettlement()
            let replacingTop = systemTopActive
            // A tap is newer intent than the OS ascent. Cancel that owner rather
            // than discarding the visible button's action until ascent completes.
            if replacingTop {
                cancelSystemTop()
            }
            beginMotion()
            latestEchoCancellationToken = priorIssuedToken &+ 1
            input.onLatest()
            collection.setNeedsLayout()
        }
        func flushForNavigation() {
            guard !stopped, !presentationSuspended, isViewLoaded else { return }
            invalidatePublications()
            let current = currentAnchor()?.id
            let metrics = ChatScrollMetrics(distanceFromBottom: max(0, bottomOffset - collection.contentOffset.y),
                isUserInteracting: interacting,
                isDirectlyInteracting: systemTopActive || collection.isTracking || collection.isDragging,
                isDecelerating: collection.isDecelerating)
            let latestVisible = input.ids.last.map { id in
                collection.indexPathsForVisibleItems.contains { dataSource.itemIdentifier(for: $0) == .row(id) }
            } ?? false
            input.onState(metrics, current, latestVisible, realizedTailArrival)
        }

        func loadOlderIfNeeded() {
            guard input.allowsAutomaticPaging, !follows, !interacting, motionLink == nil,
                  input.restoreRequest == nil || input.restoreRequest == completedRequest,
                  let current = currentAnchor(), let index = indices[current.id], index < 8,
                  olderBoundary != input.ids.first else { return }
            loadOlder(intent: .automaticPrefetch)
        }
        func loadOlder(intent: ChatTranscriptOlderLoadIntent) {
            guard isPresentationActive, !presentationSuspended, olderTask == nil,
                  !collection.isTracking, !collection.isDragging else { return }
            if intent == .automaticPrefetch, !input.allowsAutomaticPaging { return }
            if intent.acceptsUserIntent {
                olderEchoCancellationToken = input.cancellationToken &+ 1
                cancelMotion()
                invalidatePublications()
                pendingRestore = nil
                anchor = currentAnchor()
                ownership = .reading
                finishRestore(.cancelled)
            }
            let scope = input.scope, epoch = generation
            let cancellation = input.cancellationToken, operation = olderGeneration
            let boundary = input.ids.first, load = input.onOlder
            olderBoundary = boundary
            olderTask = Task { [weak self] in
                let current: @MainActor () -> Bool = { [weak self] in
                    guard let self else { return false }
                    return !self.stopped && !self.presentationSuspended && !Task.isCancelled
                        && self.input.scope == scope && self.generation == epoch
                        && self.olderGeneration == operation
                        && (self.input.cancellationToken == cancellation
                            || (intent.acceptsUserIntent && self.input.cancellationToken == cancellation &+ 1))
                }
                guard current() else { return }
                let progressed = await load(intent, current)
                guard let self, current() else { return }
                self.olderTask = nil
                if !progressed { self.olderBoundary = boundary }
            }
        }
        func cancelOlder() {
            olderGeneration &+= 1
            if olderTask != nil { olderBoundary = nil }
            olderTask?.cancel()
            olderTask = nil
            olderEchoCancellationToken = nil
        }

        @objc func refreshHistory() {
            guard isPresentationActive, !presentationSuspended, refreshTask == nil else { return }
            invalidatePublications()
            pendingRestore = nil
            cancelSystemTop()
            cancelMotion()
            anchor = currentAnchor()
            ownership = .reading
            finishRestore(.cancelled)
            let epoch = generation
            // Bind work to the initiating chat, not whichever input exists when
            // the queued task runs. Cancellation can precede its first turn.
            let refresh = input.onRefresh
            refreshTask = Task { [weak self] in
                guard self?.stopped == false, self?.generation == epoch,
                      !Task.isCancelled else { return }
                // Do not retain the viewport while backend work is suspended.
                await refresh { [weak self] in
                    guard let self else { return false }
                    return !self.stopped && self.generation == epoch && !Task.isCancelled
                }
                // An old completion must not clear a newer chat's refresh owner.
                guard let self, !self.stopped, self.generation == epoch else { return }
                self.collection.refreshControl?.endRefreshing()
                self.refreshTask = nil
            }
        }
        func cancelRefresh() {
            refreshTask?.cancel()
            refreshTask = nil
            if isViewLoaded { collection.refreshControl?.endRefreshing() }
        }
        func saveMemory(scope: String, typeKey: String? = nil) {
            if case .restoring = ownership { return }
            guard initialized, let anchor = currentAnchor() else { return }
            let key = "\(scope)|\(Int(width.rounded()))|\(typeKey ?? input.typeKey)"
            Self.memory[key] = Memory(anchor: anchor, following: follows)
        }
        func stop() {
            guard !stopped else { return }
            setStreamingInteraction(false)
            deferredStreamingRowIDs.removeAll()
            input.metricPublication?.detachMeasuredViewport(source: ObjectIdentifier(self))
            cancelOlder()
            invalidatePublications()
            pendingRestore = nil
            lifecycleObserver = nil
            cancelSystemTop()
            cancelMotion()
            if isViewLoaded { saveMemory(scope: input.scope) }
            stopped = true
            markdownPresentationInteraction.holdsCanonicalPresentation = false
            generation += 1
            cancelRefresh()
            collection?.willLayout = nil
            collection?.didLayout = nil
        }
    }
}

extension Notification.Name {
    static let semrehTranscriptLoadOlder = Notification.Name("semreh.transcript.loadOlder")
}
