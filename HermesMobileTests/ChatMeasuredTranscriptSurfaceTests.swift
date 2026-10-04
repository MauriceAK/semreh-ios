import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ChatMeasuredTranscriptSurfaceTests: XCTestCase {
    private typealias Owner = ChatNativeTranscriptViewport.Controller

    func testStreamingTailRefitsOnlyTheChangedSuffixOfTenThousandRows() throws {
        let fixture = layoutFixture(rowCount: 10_000)
        let before = try frame(8_000, in: fixture.layout)
        let lastBefore = try frame(10_001, in: fixture.layout)
        let sizeBefore = fixture.layout.collectionViewContentSize

        try fit(item: .row("row-9999"), at: 10_000, height: 241, layout: fixture.layout)

        XCTAssertEqual(try frame(8_000, in: fixture.layout), before)
        XCTAssertEqual(try frame(10_001, in: fixture.layout).minY, lastBefore.minY + 81, accuracy: 0.01)
        XCTAssertEqual(fixture.layout.collectionViewContentSize.height, sizeBefore.height + 81, accuracy: 0.01)
        XCTAssertEqual(fixture.layout.lastRebuiltFrameCount, 2,
            "Streaming the final row must not rebuild ten thousand earlier frames")
        withExtendedLifetime(fixture) {}
    }

    func testEarlierSelfSizingPreservesPrefixAndMovesTheFollowingRows() throws {
        let fixture = layoutFixture(rowCount: 40)
        let before = try frame(4, in: fixture.layout)
        let next = try frame(6, in: fixture.layout)
        try fit(item: .row("row-4"), at: 5, height: 73, layout: fixture.layout)

        XCTAssertEqual(try frame(4, in: fixture.layout), before)
        XCTAssertEqual(try frame(5, in: fixture.layout).height, 73, accuracy: 0.01)
        XCTAssertEqual(try frame(6, in: fixture.layout).minY, next.minY - 87, accuracy: 0.01)
        XCTAssertEqual(fixture.layout.lastRebuiltFrameCount, 37)
        withExtendedLifetime(fixture) {}
    }

    func testComposerClearanceChangesContentSizeWithoutRebuildingRows() throws {
        let fixture = layoutFixture(rowCount: 100)
        let before = try frame(60, in: fixture.layout)
        let height = fixture.layout.collectionViewContentSize.height
        var next = fixture.input
        // A new value models measured composer growth; no keyboard height enters it.
        next = viewport(ids: next.ids, scope: next.scope, bottom: 180)
        fixture.layout.configure(input: next, width: 390)

        XCTAssertEqual(fixture.layout.collectionViewContentSize.height, height + 180, accuracy: 0.01)
        XCTAssertEqual(try frame(60, in: fixture.layout), before)
        XCTAssertEqual(fixture.layout.lastRebuiltFrameCount, 0)
        withExtendedLifetime(fixture) {}
    }

    func testWidthChangeRebuildsEveryFrameAfterAnIncrementalFit() throws {
        let fixture = layoutFixture(rowCount: 40)
        try fit(item: .row("row-39"), at: 40, height: 240, layout: fixture.layout)
        _ = fixture.layout.collectionViewContentSize
        fixture.layout.configure(input: fixture.input, width: 430)

        XCTAssertEqual(try frame(0, in: fixture.layout).width, 406, accuracy: 0.01)
        XCTAssertEqual(try frame(41, in: fixture.layout).width, 406, accuracy: 0.01)
        XCTAssertEqual(fixture.layout.lastRebuiltFrameCount, 42)
        withExtendedLifetime(fixture) {}
    }

    func testLatestUsesItsOwnMeasuredClearanceAfterViewportResize() throws {
        let input = viewport(ids: ["row-0"], top: 72, bottom: 152, latest: 164)
        let controller = Owner(input: input)
        controller.loadViewIfNeeded()
        defer { controller.stop() }

        for height: CGFloat in [772, 437] {
            controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: height)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            XCTAssertEqual(controller.collection.contentInset.top, 72)
            XCTAssertEqual(controller.latest.frame.maxY, height - 164, accuracy: 0.5)
            XCTAssertEqual(controller.input.bottomInset, 152,
                "Keyboard-sized viewport changes must not add another keyboard reservation")
        }
    }

    func testTypedRestoreKeepsReaderBelowTheMeasuredHeader() async throws {
        let scope = UUID()
        let request = ChatTranscriptRestoreRequest(scope: scope, generation: 1, target: .message(id: "row-20"))
        var outcomes: [ChatTranscriptRestoreOutcome] = []
        let input = viewport(ids: (0..<40).map { "row-\($0)" }, scope: scope.uuidString,
            top: 82, bottom: 140, latest: 152, request: request,
            onRestore: { delivered, outcome in
                XCTAssertEqual(delivered, request)
                outcomes.append(outcome)
            })
        let controller = Owner(input: input)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        for _ in 0..<6 {
            controller.view.layoutIfNeeded()
            controller.collection.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let path = try XCTUnwrap(controller.dataSource.indexPath(for: .row("row-20")))
        let cell = try XCTUnwrap(controller.collection.cellForItem(at: path))
        XCTAssertEqual(cell.frame.minY - controller.collection.contentOffset.y, 82, accuracy: 1)
        XCTAssertEqual(controller.currentAnchor()?.id, "row-20")
        XCTAssertEqual(outcomes, [.success])
    }

    func testStationaryMountedRowReceivesDirectionAndDynamicTypeChanges() async throws {
        let receipt = EnvironmentReceipt()
        let scope = UUID().uuidString
        var environment = EnvironmentValues()
        environment.layoutDirection = .leftToRight
        environment.dynamicTypeSize = .large
        let makeRow: (Int) -> AnyView = { _ in AnyView(EnvironmentWitness(receipt: receipt).frame(height: 100)) }
        let input = viewport(ids: ["row-0"], scope: scope, environment: environment, makeRow: makeRow)
        let controller = Owner(input: input)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        let path = try XCTUnwrap(controller.dataSource.indexPath(for: .row("row-0")))
        let mountedCell = try XCTUnwrap(controller.collection.cellForItem(at: path))
        let offset = controller.collection.contentOffset
        let identityBuilds = controller.identityBuilds
        XCTAssertEqual(receipt.latest, PresentedEnvironment(environment))

        let changes: [(inout EnvironmentValues) -> Void] = [
            { $0.layoutDirection = .rightToLeft },
            { $0.dynamicTypeSize = .accessibility2 }
        ]
        for change in changes {
            let priorUpdates = receipt.updates
            change(&environment)
            controller.update(viewport(ids: ["row-0"], scope: scope, environment: environment, makeRow: makeRow))
            controller.view.layoutIfNeeded()
            controller.collection.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(receipt.latest, PresentedEnvironment(environment))
            XCTAssertGreaterThan(receipt.updates, priorUpdates,
                "A stationary mounted row must receive the new environment without new text or a swipe")
            XCTAssertTrue(controller.collection.cellForItem(at: path) === mountedCell)
            XCTAssertEqual(controller.identityBuilds, identityBuilds)
            XCTAssertEqual(controller.collection.contentOffset.y, offset.y, accuracy: 0.5)
        }
    }

    func testSystemAccessibilityFlagsParticipateInHostedRowIdentity() {
        // These environment properties are system-owned/read-only. Exercise the
        // explicit identity values without pretending to mutate system settings.
        typealias Signature = ChatMeasuredTranscriptView.EnvironmentSignature
        let baseline = Signature(layoutDirection: .leftToRight, dynamicTypeSize: .large,
            reducesMotion: false, reducesTransparency: false, increasesContrast: false,
            differentiatesWithoutColor: false)
        let changes: [(inout Signature) -> Void] = [
            { $0.reducesMotion = true },
            { $0.reducesTransparency = true },
            { $0.increasesContrast = true },
            { $0.differentiatesWithoutColor = true }
        ]
        for change in changes {
            var changed = baseline
            change(&changed)
            XCTAssertNotEqual(changed.description, baseline.description)
        }
    }

    private struct PresentedEnvironment: Equatable {
        let isRightToLeft: Bool
        let dynamicTypeSize: DynamicTypeSize
        let reducesMotion: Bool
        let reducesTransparency: Bool
        let increasesContrast: Bool
        let differentiatesWithoutColor: Bool

        init(_ environment: EnvironmentValues) {
            isRightToLeft = environment.layoutDirection == .rightToLeft
            dynamicTypeSize = environment.dynamicTypeSize
            reducesMotion = environment.accessibilityReduceMotion
            reducesTransparency = environment.accessibilityReduceTransparency
            increasesContrast = environment.colorSchemeContrast == .increased
            differentiatesWithoutColor = environment.accessibilityDifferentiateWithoutColor
        }
    }

    private final class EnvironmentReceipt {
        var latest: PresentedEnvironment?
        var updates = 0
    }

    private struct EnvironmentWitness: UIViewRepresentable {
        let receipt: EnvironmentReceipt
        func makeUIView(context: Context) -> UILabel { UILabel() }
        func updateUIView(_ label: UILabel, context: Context) {
            receipt.latest = PresentedEnvironment(context.environment)
            receipt.updates += 1
            label.text = context.environment.layoutDirection == .rightToLeft ? "RTL" : "LTR"
        }
    }

    private final class Items: NSObject, UICollectionViewDataSource {
        let count: Int
        init(count: Int) { self.count = count }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { count }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath)
        }
    }

    private struct LayoutFixture {
        let layout: Owner.ColumnLayout
        let collection: UICollectionView
        let source: Items
        let input: ChatNativeTranscriptViewport
    }

    private func layoutFixture(rowCount: Int) -> LayoutFixture {
        let input = viewport(ids: (0..<rowCount).map { "row-\($0)" })
        let layout = Owner.ColumnLayout()
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), collectionViewLayout: layout)
        let source = Items(count: rowCount + 2)
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "row")
        collection.dataSource = source
        collection.reloadData()
        layout.configure(input: input, width: 390)
        layout.commitSnapshot([.header] + input.ids.map(Owner.Item.row) + [.footer])
        layout.prepare()
        return LayoutFixture(layout: layout, collection: collection, source: source, input: input)
    }

    private func frame(_ index: Int, in layout: Owner.ColumnLayout) throws -> CGRect {
        try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).frame
    }

    private func fit(item: Owner.Item, at index: Int, height: CGFloat, layout: Owner.ColumnLayout) throws {
        let attributes = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0)))
        attributes.size.height = height
        layout.didFit(attributes, item: item, key: layout.key)
    }

    private func viewport(ids: [String], scope: String = UUID().uuidString,
                          top: CGFloat = 0, bottom: CGFloat = 0, latest: CGFloat? = nil,
                          environment: EnvironmentValues = EnvironmentValues(),
                          makeRow: ((Int) -> AnyView)? = nil,
                          request: ChatTranscriptRestoreRequest? = nil,
                          onRestore: @escaping (ChatTranscriptRestoreRequest, ChatTranscriptRestoreOutcome) -> Void = { _, _ in })
        -> ChatNativeTranscriptViewport {
        ChatNativeTranscriptViewport(ids: ids, revisionAt: { index in
            let message = ChatMessage(role: "assistant", content: "Measured row \(index)", timestamp: Double(index), messageId: ids[index])
            return StableViewportRowRevision(
                message: TranscriptMessage(loadedIndex: index, renderID: ids[index], anchorID: ids[index], message: message),
                latestCompletedAssistantRenderID: nil, outgoingInsertionEvent: nil, allowsOutgoingMotion: false,
                reasoningGroups: [], toolCallGroups: [], liveReasoningText: "", liveToolCalls: [],
                streamingAssistantMessageID: nil, liveTokensPerSecond: nil, localAttachmentPreviews: nil,
                compressionReferenceCard: nil, listeningMessageID: nil, showsThinkingAndToolCards: false,
                isViewingCachedData: false, hasActiveStream: false, isRegeneratingMessage: false,
                isEditingMessage: false, isForkingMessage: false, transcriptMediaCacheNamespace: scope)
        }, revision: 0, typeKey: "measured-surface-test|\(ChatMeasuredTranscriptView.environmentSignature(environment))", scope: scope, initialID: nil,
            restoreRequest: request, cancellationToken: 0, latestToken: 0,
            explicitLatest: false, following: false, horizontalPadding: 12, spacing: 10,
            bottomInset: bottom, topInset: top, latestBottomInset: latest, environment: environment,
            makeRow: makeRow ?? { index in AnyView(Text("Measured row \(index)").frame(height: 100)) },
            makeHeader: { AnyView(Color.clear.frame(height: 1)) },
            makeFooter: { AnyView(Color.clear.frame(height: 1)) },
            onLatest: {}, onState: { _, _, _, _ in }, onRestore: onRestore, onRefresh: { _ in })
    }
}
