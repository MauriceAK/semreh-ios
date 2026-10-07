import Foundation
import XCTest
@testable import SemrehRemoteBrowserCore
@testable import SemrehRemoteBrowserUI

private struct TestDecodedImage: DecodedImage {}

private final class TestFrameDecoder: FrameDecoder {
    func inspectDimensions(of payload: FramePayload) -> PixelDimensions? {
        payload.dimensions
    }

    func decode(_ payload: FramePayload) -> (any DecodedImage)? {
        TestDecodedImage()
    }
}

private final class TextTestAdapter: BrowserAdapter {
    let capabilities = RemoteBrowserCapabilities(
        controlSupported: true,
        stopTaskSupported: false
    )
    var onEvent: ((BrowserAdapterEvent) -> Void)?
    private(set) var performed: [(BrowserAdapterAction, CommandID)] = []

    func connect() {}
    func disconnect() {}

    func perform(_ action: BrowserAdapterAction, commandID: CommandID) {
        performed.append((action, commandID))
        if case .requestControl = action {
            onEvent?(.quiescent)
        }
    }
}

@MainActor
final class RemoteBrowserViewModelTextTests: XCTestCase {
    func testOldSameEpochAcknowledgementCannotClearNewDraft() async {
        let adapter = TextTestAdapter()
        let viewModel = RemoteBrowserViewModel(
            adapter: adapter,
            decoder: TestFrameDecoder()
        )
        let descriptor = RemoteSurfaceDescriptor(
            connection: ConnectionEpoch(generation: 1),
            surface: SurfaceIdentity(generation: 1),
            sourceDimensions: PixelDimensions(width: 390, height: 844),
            hostDisplayName: "fixture.local"
        )
        viewModel.controller.handle(.connected(descriptor, adapter.capabilities))
        let requestID = viewModel.controller.requestControl()!
        await drainMainQueue()
        viewModel.controller.handle(.controlGranted(ControlGrant(
            requestID: requestID,
            connection: descriptor.connection,
            surface: descriptor.surface,
            revision: 1
        )))

        viewModel.draftText = "old ambiguous draft"
        viewModel.commitDraft()
        let oldCommandID = adapter.performed.last!.1
        viewModel.controller.handle(.acknowledgementLost(oldCommandID))
        await drainMainQueue()
        XCTAssertEqual(viewModel.draft.delivery, .unconfirmed)

        viewModel.draftText = "new current draft"
        viewModel.commitDraft()
        let newCommandID = adapter.performed.last!.1
        XCTAssertNotEqual(oldCommandID, newCommandID)
        XCTAssertEqual(viewModel.draft.delivery, .sending)

        viewModel.controller.handle(.commandAcknowledged(oldCommandID))
        await drainMainQueue()
        XCTAssertEqual(viewModel.draft.text, "new current draft")
        XCTAssertEqual(viewModel.draft.delivery, .sending)

        viewModel.controller.handle(.commandAcknowledged(newCommandID))
        await drainMainQueue()
        XCTAssertEqual(viewModel.draft.text, "")
        XCTAssertEqual(viewModel.draft.delivery, .idle)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
