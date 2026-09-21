import SwiftUI
import SemrehRemoteBrowserCore

#if canImport(UIKit)
import UIKit
import ImageIO

/// Image type the viewport can render on iOS.
public typealias DisplayableImage = UIImage

/// Decodes frame payloads off the main thread using ImageIO.
public final class UIKitFrameDecoder: FrameDecoder {
    public init() {}

    public func inspectDimensions(of payload: FramePayload) -> PixelDimensions? {
        guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { return nil }
        return PixelDimensions(width: width.intValue, height: height.intValue)
    }

    public func decode(_ payload: FramePayload) -> (any DecodedImage)? {
        let data = payload.data
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cgImage.width == payload.dimensions.width,
              cgImage.height == payload.dimensions.height
        else { return nil }
        return UIKitDecodedImage(image: UIImage(cgImage: cgImage))
    }
}

/// A decoded image backed by UIKit.
///
/// `unchecked Sendable`: the image is decoded off the main thread and handed
/// to the main thread for display exactly once. `UIImage` is safe to create
/// on a background thread and draw on the main thread; it is never mutated
/// after creation.
public struct UIKitDecodedImage: DecodedImage, @unchecked Sendable {
    public let image: UIImage

    public init(image: UIImage) {
        self.image = image
    }
}

#else

/// Compile shim so `swift test` on macOS builds the UI target.
/// This type is never used on iOS.
public struct DisplayableImage: Sendable, Equatable {
    public init() {}
}

#endif
