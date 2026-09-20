import SwiftUI
import SemrehRemoteBrowserCore

#if canImport(UIKit)
import UIKit

/// Programmatic control handle for the viewport (Fit/zoom reset).
public final class ViewportControl: ObservableObject {
    fileprivate var fitHandler: (@MainActor () -> Void)?
    public init() {}
    /// Reset zoom to 1x and clear the pan offset.
    public func fit() { fitHandler?() }
}

/// SwiftUI wrapper around the gesture-driven viewport.
public struct RemoteViewportView: UIViewRepresentable {
    public var image: DisplayableImage?
    public var source: PixelDimensions?
    public var viewportSize: CGSize
    public var generation: UInt64
    public var mode: ViewportInputMode
    public var control: ViewportControl
    public var onRemoteAction: @MainActor (BrowserAdapterAction) -> Void

    public init(
        image: DisplayableImage?,
        source: PixelDimensions?,
        viewportSize: CGSize,
        generation: UInt64,
        mode: ViewportInputMode,
        control: ViewportControl,
        onRemoteAction: @escaping @MainActor (BrowserAdapterAction) -> Void
    ) {
        self.image = image
        self.source = source
        self.viewportSize = viewportSize
        self.generation = generation
        self.mode = mode
        self.control = control
        self.onRemoteAction = onRemoteAction
    }

    public func makeUIView(context: Context) -> RemoteViewportUIView {
        let view = RemoteViewportUIView()
        view.onRemoteAction = onRemoteAction
        view.mode = mode
        control.fitHandler = { [weak view] in view?.resetView() }
        return view
    }

    public func updateUIView(_ view: RemoteViewportUIView, context: Context) {
        view.onRemoteAction = onRemoteAction
        view.mode = mode
        view.setImage(image, source: source, viewportSize: viewportSize, generation: generation)
        control.fitHandler = { [weak view] in view?.resetView() }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {}
}

/// UIKit viewport: renders the latest decoded frame with aspect fit and
/// translates gestures into local view operations or remote human commands.
///
/// Gesture separation:
/// - watch: gestures never emit remote input. Two-finger drag pans the
///   zoomed image; pinch zooms. One-finger gestures do nothing.
/// - direct: tap and one-finger drag emit remote click/scroll at the tapped
///   point; two-finger drag pans locally; pinch zooms.
/// - trackpad: one-finger drag moves a visible cursor locally; two-finger
///   vertical movement emits a remote scroll at the cursor.
public final class RemoteViewportUIView: UIView {
    var onRemoteAction: (@MainActor (BrowserAdapterAction) -> Void)?
    var mode: ViewportInputMode = .watch {
        didSet { updateGestureEnablement() }
    }

    private let imageView = UIImageView()
    private let cursorView = UIView()

    private var baseSource: PixelDimensions?
    private var baseViewport: CGSize = .zero
    private var generation: UInt64 = 0
    private var zoom: Double = 1
    private var panOffset = CGPoint.zero
    private var transformState: ViewportTransform?

    private var tap: UITapGestureRecognizer!
    private var pan: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!
    private var lastPanPoint: CGPoint = .zero
    private var pinchStartZoom: Double = 1

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        // The image view's frame is driven by ViewportTransform.contentRect
        // (aspect fit, centered, zoomed, panned), so the rendered image and
        // the tap-mapping math always agree. Black bars are this view's
        // background: letterboxing reflects the aspect ratio.
        imageView.contentMode = .scaleToFill
        imageView.frame = bounds
        addSubview(imageView)

        cursorView.frame = CGRect(x: 0, y: 0, width: 18, height: 18)
        cursorView.layer.cornerRadius = 9
        cursorView.layer.borderWidth = 2
        cursorView.layer.borderColor = UIColor.white.cgColor
        cursorView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.4)
        cursorView.isHidden = true
        addSubview(cursorView)

        tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        tap.require(toFail: pan)
        tap.require(toFail: pinch)
        addGestureRecognizer(tap)
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
        updateGestureEnablement()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != baseViewport {
            baseViewport = bounds.size
            rebuildTransform()
        }
    }

    /// Deliver a new frame; a changed generation resets view state.
    func setImage(
        _ image: DisplayableImage?,
        source: PixelDimensions?,
        viewportSize: CGSize,
        generation: UInt64
    ) {
        if generation != self.generation {
            self.generation = generation
            resetViewState()
        }
        baseSource = source
        baseViewport = viewportSize
        imageView.image = image
        rebuildTransform()
    }

    /// Reset zoom to 1x and clear pan (the Fit button).
    func resetView() {
        resetViewState()
        rebuildTransform()
    }

    private func resetViewState() {
        zoom = 1
        panOffset = .zero
        cursorView.isHidden = true
    }

    private func rebuildTransform() {
        guard let source = baseSource,
              source.isValid,
              baseViewport.width > 0,
              baseViewport.height > 0
        else {
            transformState = nil
            imageView.frame = bounds
            return
        }
        var transform = ViewportTransform(
            source: source,
            viewportWidth: Double(baseViewport.width),
            viewportHeight: Double(baseViewport.height),
            zoom: zoom,
            panX: Double(panOffset.x),
            panY: Double(panOffset.y),
            generation: generation
        )
        // Clamp the pan so the content cannot be pushed entirely out of view.
        let fitWidth = Double(source.width) * transform.fitScale * transform.zoom
        let fitHeight = Double(source.height) * transform.fitScale * transform.zoom
        let clampedX = min(max(Double(panOffset.x),
                               -(fitWidth + Double(baseViewport.width)) / 2),
                           (fitWidth + Double(baseViewport.width)) / 2)
        let clampedY = min(max(Double(panOffset.y),
                               -(fitHeight + Double(baseViewport.height)) / 2),
                           (fitHeight + Double(baseViewport.height)) / 2)
        panOffset = CGPoint(x: clampedX, y: clampedY)
        transform = ViewportTransform(
            source: source,
            viewportWidth: Double(baseViewport.width),
            viewportHeight: Double(baseViewport.height),
            zoom: zoom,
            panX: clampedX,
            panY: clampedY,
            generation: generation
        )
        transformState = transform
        // Render exactly what the mapping math describes.
        let rect = transform.contentRect
        imageView.frame = CGRect(
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height
        )
    }

    private func updateGestureEnablement() {
        switch mode {
        case .watch:
            // Local viewing only; watch gestures never emit remote input.
            tap.isEnabled = false
            pan.isEnabled = true
            pinch.isEnabled = true
        case .direct, .trackpad:
            tap.isEnabled = true
            pan.isEnabled = true
            pinch.isEnabled = true
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .recognized,
              let transform = transformState
        else { return }
        let location: CGPoint
        switch mode {
        case .watch:
            return
        case .direct:
            location = recognizer.location(in: self)
        case .trackpad:
            // Click at the visible cursor; fall back to the tap location.
            location = cursorView.isHidden ? recognizer.location(in: self) : cursorView.center
        }
        guard let remote = transform.remotePoint(
            localX: Double(location.x),
            localY: Double(location.y)
        ) else { return }
        onRemoteAction?(.click(remote))
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let transform = transformState else { return }
        let touches = recognizer.numberOfTouches
        switch mode {
        case .watch:
            if touches == 2 { panLocally(recognizer) }
        case .direct:
            if touches == 1 {
                scrollRemotely(recognizer, transform: transform)
            } else if touches == 2 {
                panLocally(recognizer)
            }
        case .trackpad:
            if touches == 1 {
                moveCursor(recognizer)
            } else if touches == 2 {
                scrollRemotely(recognizer, transform: transform)
            }
        }
    }

    /// One-finger drag scrolls the remote page: normalized deltas so the
    /// content follows the finger.
    private func scrollRemotely(_ recognizer: UIPanGestureRecognizer, transform: ViewportTransform) {
        let scale = transform.effectiveScale
        guard scale > 0 else { return }
        if recognizer.state == .began {
            lastPanPoint = recognizer.location(in: self)
        } else if recognizer.state == .changed {
            let point = recognizer.location(in: self)
            let dx = Double(point.x - lastPanPoint.x)
            let dy = Double(point.y - lastPanPoint.y)
            lastPanPoint = point
            let remoteDX = -dx / (Double(transform.source.width) * scale)
            let remoteDY = -dy / (Double(transform.source.height) * scale)
            if remoteDX != 0 || remoteDY != 0 {
                onRemoteAction?(.scroll(dx: remoteDX, dy: remoteDY))
            }
        }
    }

    /// Two-finger drag pans the zoomed image locally; never remote.
    private func panLocally(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began {
            lastPanPoint = recognizer.location(in: self)
        } else if recognizer.state == .changed {
            let point = recognizer.location(in: self)
            panOffset.x += point.x - lastPanPoint.x
            panOffset.y += point.y - lastPanPoint.y
            lastPanPoint = point
            rebuildTransform()
        }
    }

    /// One-finger drag in trackpad mode moves the visible cursor locally.
    private func moveCursor(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began || recognizer.state == .changed {
            let point = recognizer.location(in: self)
            cursorView.isHidden = false
            cursorView.center = point
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .began {
            pinchStartZoom = zoom
        } else if recognizer.state == .changed {
            // Zoom bounds (1x-4x) are enforced by ViewportTransform itself.
            zoom = pinchStartZoom * Double(recognizer.scale)
            rebuildTransform()
        }
    }
}

#else

/// Compile shim so `swift test` on macOS builds the UI target.
/// Gesture behavior is iOS-only and never runs here.
public final class ViewportControl: ObservableObject {
    public init() {}
    public func fit() {}
}

public struct RemoteViewportView: View {
    public var image: DisplayableImage?
    public var source: PixelDimensions?
    public var viewportSize: CGSize
    public var generation: UInt64
    public var mode: ViewportInputMode
    public var control: ViewportControl
    public var onRemoteAction: @MainActor (BrowserAdapterAction) -> Void

    public init(
        image: DisplayableImage?,
        source: PixelDimensions?,
        viewportSize: CGSize,
        generation: UInt64,
        mode: ViewportInputMode,
        control: ViewportControl,
        onRemoteAction: @escaping @MainActor (BrowserAdapterAction) -> Void
    ) {
        self.image = image
        self.source = source
        self.viewportSize = viewportSize
        self.generation = generation
        self.mode = mode
        self.control = control
        self.onRemoteAction = onRemoteAction
    }

    public var body: some View {
        Color.clear
    }
}

#endif
