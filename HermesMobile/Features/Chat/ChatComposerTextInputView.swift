import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Live state in the owning view/coordinator invalidates suspended presentation work.
struct ChatPresentationOwnership {
    private(set) var isActive = false
    private(set) var isSelected = true
    private(set) var generation = 0

    mutating func update(isActive: Bool, isSelected: Bool = true) {
        let isActive = isActive && isSelected
        guard self.isActive != isActive || self.isSelected != isSelected else { return }
        generation += 1
        self.isSelected = isSelected
        self.isActive = isActive
    }

    func owns(_ generation: Int) -> Bool {
        isActive && self.generation == generation
    }
}

struct ComposerTextInputView: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var inputHeight: CGFloat
    @Binding var measuredHeight: CGFloat

    let isDisabled: Bool
    var isAccessibilityHidden: Bool = false
    let isKeyboardSendEnabled: Bool
    let verticalPadding: CGFloat
    var horizontalPadding: CGFloat = 16
    let onKeyboardSend: () -> Void
    let onPasteFileProviders: ([NSItemProvider]) -> Void
    let onPasteFileURLs: ([URL]) -> Void
    let onPasteImageProviders: ([NSItemProvider]) -> Void
    let onPasteImages: ([UIImage]) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            ComposerTextView(
                text: $text,
                isFocused: $isFocused,
                isDisabled: isDisabled,
                isAccessibilityHidden: isAccessibilityHidden,
                isKeyboardSendEnabled: isKeyboardSendEnabled,
                onKeyboardSend: onKeyboardSend,
                onHeightChange: updateMeasuredHeight,
                onPasteFileProviders: onPasteFileProviders,
                onPasteFileURLs: onPasteFileURLs,
                onPasteImageProviders: onPasteImageProviders,
                onPasteImages: onPasteImages
            )
            .frame(height: inputHeight)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)

            if text.isEmpty {
                Text("Message")
                    .lineLimit(1)
                    .foregroundStyle(Color(.placeholderText))
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 42, alignment: .leading)
    }

    private func updateMeasuredHeight(_ newHeight: CGFloat) {
        guard inputHeight != newHeight || measuredHeight != newHeight else { return }

        DispatchQueue.main.async {
            guard inputHeight != newHeight || measuredHeight != newHeight else { return }
            inputHeight = newHeight
            measuredHeight = newHeight
        }
    }
}

struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isDisabled: Bool
    var isAccessibilityHidden: Bool = false
    let isKeyboardSendEnabled: Bool
    let onKeyboardSend: () -> Void
    let onHeightChange: (CGFloat) -> Void
    let onPasteFileProviders: ([NSItemProvider]) -> Void
    let onPasteFileURLs: ([URL]) -> Void
    let onPasteImageProviders: ([NSItemProvider]) -> Void
    let onPasteImages: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onHeightChange: onHeightChange)
    }

    func makeUIView(context: Context) -> PastingTextView {
        let textView = PastingTextView()
        textView.delegate = context.coordinator
        textView.onLayout = { [weak coordinator = context.coordinator] textView in
            coordinator?.reportHeight(for: textView)
        }
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        // Let the composer grow with the first few lines. If the text view
        // scrolls while its SwiftUI frame is still catching up, it can hide
        // the caret or clip a newly typed line inside the rounded surface.
        textView.isScrollEnabled = false
        textView.scrollsToTop = false // The surrounding transcript owns status-bar navigation.
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContentType = .none
        textView.accessibilityIdentifier = "chat-composer-input"
        textView.isAccessibilityElement = !isAccessibilityHidden
        textView.accessibilityElementsHidden = isAccessibilityHidden
        textView.isKeyboardSendEnabled = isKeyboardSendEnabled
        textView.onKeyboardSend = onKeyboardSend
        textView.pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [
                UTType.fileURL.identifier,
                UTType.image.identifier,
                UTType.text.identifier
            ]
        )
        textView.onPasteFileProviders = onPasteFileProviders
        textView.onPasteFileURLs = onPasteFileURLs
        textView.onPasteImageProviders = onPasteImageProviders
        textView.onPasteImages = onPasteImages
        context.coordinator.reportHeight(for: textView, force: true)
        return textView
    }

    // A non-scrolling UITextView's intrinsic width can grow with a restored
    // draft. SwiftUI owns the available width; measure wrapping at that width
    // without publishing state or forcing a layout during proposal evaluation.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PastingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width >= 0 else { return nil }
        return CGSize(width: width, height: Self.visibleHeight(context.coordinator.contentHeight(for: uiView, width: width)))
    }

    private static let maximumVisibleHeight: CGFloat = 120

    static func contentHeight(for textView: UITextView, width: CGFloat) -> CGFloat {
        ceil(textView.sizeThatFits(CGSize(width: max(1, width), height: .greatestFiniteMagnitude)).height)
    }

    private static func visibleHeight(_ contentHeight: CGFloat) -> CGFloat {
        min(maximumVisibleHeight, max(22, contentHeight))
    }

    static func dismantleUIView(_ textView: PastingTextView, coordinator: Coordinator) {
        textView.onLayout = nil
        coordinator.cancelFocus()
        textView.resignFirstResponder()
    }

    func updateUIView(_ textView: PastingTextView, context: Context) {
        context.coordinator.onHeightChange = onHeightChange
        // Opacity/SwiftUI AX hiding alone did not exclude the retained UIKit leaf.
        // Explicit root selection controls AX independently of offline editability.
        textView.isAccessibilityElement = !isAccessibilityHidden
        textView.accessibilityElementsHidden = isAccessibilityHidden
        let didChangeText = context.coordinator.synchronizeExternalText(text, in: textView)
        // Mirror the chat RTL toggle onto the text view itself (#259): SwiftUI's
        // layoutDirection environment does not propagate into a wrapped UITextView,
        // so set the base direction directly so the cursor/empty-field rests on the
        // trailing edge. `.natural` keeps the LTR default untouched, and per-run
        // bidi still resolves mixed Arabic+Latin/URL content within the line.
        let isRTL = context.environment.layoutDirection == .rightToLeft
        textView.semanticContentAttribute = isRTL ? .forceRightToLeft : .unspecified
        textView.textAlignment = isRTL ? .right : .natural
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        let scheme = context.environment.colorScheme
        let palette = context.environment.appColorPalette
        textView.textColor = UIColor(isDisabled
            ? SemrehVisualTheme.mutedText(for: scheme, palette: palette)
            : SemrehVisualTheme.primaryText(for: scheme, palette: palette))
        textView.isKeyboardSendEnabled = isKeyboardSendEnabled
        textView.onKeyboardSend = onKeyboardSend
        textView.onPasteFileProviders = onPasteFileProviders
        textView.onPasteFileURLs = onPasteFileURLs
        textView.onPasteImageProviders = onPasteImageProviders
        textView.onPasteImages = onPasteImages
        context.coordinator.syncFocus(for: textView, shouldFocus: isFocused, isDisabled: isDisabled)
        context.coordinator.reportHeight(for: textView, force: didChangeText)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var isFocused: Bool
        var onHeightChange: (CGFloat) -> Void
        private var pendingFocusTarget: Bool?
        private var focusGeneration = 0
        private var focusTask: Task<Void, Never>?
        private weak var measuredView: UITextView?
        private var measurements: [(key: MeasurementKey, height: CGFloat)] = []
        private let measurementCacheCapacity: Int
        var cachedMeasurementEntryCount: Int { measurements.count }
        private static let defaultMeasurementCacheCapacity: Int = {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--composer-single-measurement-cache") { return 1 }
            #endif
            return 4
        }()
        private weak var reportedView: UITextView?
        private var reportedHeight: CGFloat?
        // The injectable operation is ordinary UIKit sizing, also used by the tests.
        var measureContentHeight: (UITextView, CGFloat) -> CGFloat = ComposerTextView.contentHeight

        private struct MeasurementKey: Equatable {
            let text: NSAttributedString
            let font: UIFont?
            let width: CGFloat
            let inset: UIEdgeInsets
            let contentInset: UIEdgeInsets
            let padding: CGFloat
            let containerSize: CGSize
            let maximumLines: Int
            let lineBreakMode: NSLineBreakMode
            let widthTracksView: Bool
            let heightTracksView: Bool
            let alignment: NSTextAlignment
            let semantic: UISemanticContentAttribute
            let traits: UITraitCollection
            let scrollEnabled: Bool
            let adjustsFont: Bool

            init?(_ view: UITextView, width: CGFloat) {
                guard view.markedTextRange == nil, view.textContainer.exclusionPaths.isEmpty else { return nil }
                let source = view.attributedText ?? NSAttributedString(string: view.text ?? "")
                let snapshot = NSMutableAttributedString(attributedString: source)
                var supported = true
                source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
                    for (key, value) in attributes {
                        switch key {
                        case .font, .foregroundColor:
                            break
                        case .paragraphStyle:
                            guard let style = value as? NSParagraphStyle else { supported = false; continue }
                            snapshot.addAttribute(key, value: style.copy(), range: range)
                        default:
                            supported = false
                        }
                    }
                }
                guard supported else { return nil }
                text = NSAttributedString(attributedString: snapshot)
                font = view.font
                self.width = width
                inset = view.textContainerInset
                contentInset = view.adjustedContentInset
                padding = view.textContainer.lineFragmentPadding
                containerSize = view.textContainer.size
                maximumLines = view.textContainer.maximumNumberOfLines
                lineBreakMode = view.textContainer.lineBreakMode
                widthTracksView = view.textContainer.widthTracksTextView
                heightTracksView = view.textContainer.heightTracksTextView
                alignment = view.textAlignment
                semantic = view.semanticContentAttribute
                traits = view.traitCollection
                scrollEnabled = view.isScrollEnabled
                adjustsFont = view.adjustsFontForContentSizeCategory
            }
        }

        func contentHeight(for textView: UITextView, width: CGFloat) -> CGFloat {
            let key = MeasurementKey(textView, width: width)
            if measuredView !== textView || key == nil {
                measurements.removeAll(keepingCapacity: true)
            }
            measuredView = textView
            #if DEBUG
            if let probe = ChatPerformanceInvalidationProbe.shared {
                // Diagnostic-only normalization; the sizing key and operation keep exact widths.
                let finiteWidth = width.isFinite ? max(1, width) : 1
                let diagnosticWidth = finiteWidth >= CGFloat(Int.max) ? Int.max : Int(finiteWidth)
                probe.record("composer_sizing_request", a: diagnosticWidth,
                             b: textView.attributedText?.length ?? (textView.text ?? "").utf16.count,
                             c: key == nil ? 0 : 1)
            }
            #endif
            if let key, let index = measurements.firstIndex(where: { $0.key == key }) {
                let entry = measurements.remove(at: index)
                measurements.insert(entry, at: 0)
                #if DEBUG
                ChatPerformanceInvalidationProbe.shared?.record("composer_sizing_hit")
                #endif
                return entry.height
            }
            #if DEBUG
            ChatPerformanceInvalidationProbe.shared?.record("composer_sizing_measure")
            #endif
            let height = measureContentHeight(textView, width)
            if let key {
                measurements.insert((key, height), at: 0)
                if measurements.count > measurementCacheCapacity { measurements.removeLast() }
            }
            return height
        }

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            onHeightChange: @escaping (CGFloat) -> Void,
            measurementCacheCapacity: Int? = nil
        ) {
            _text = text
            _isFocused = isFocused
            self.onHeightChange = onHeightChange
            self.measurementCacheCapacity = min(4, max(1,
                measurementCacheCapacity ?? Self.defaultMeasurementCacheCapacity))
        }

        func cancelFocus() {
            focusGeneration += 1
            focusTask?.cancel()
            focusTask = nil
            pendingFocusTarget = nil
        }

        func syncFocus(for textView: UITextView, shouldFocus: Bool, isDisabled: Bool) {
            let target = shouldFocus && !isDisabled
            if pendingFocusTarget == target { return }
            focusGeneration += 1
            let generation = focusGeneration
            focusTask?.cancel()
            pendingFocusTarget = target
            // Resign synchronously: a retained hidden input stays in its window.
            if !target { textView.resignFirstResponder() }
            focusTask = Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard let self, let textView else { return }
                if target, textView.window == nil {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
                guard !Task.isCancelled, self.focusGeneration == generation else { return }
                self.pendingFocusTarget = nil
                if isDisabled { self.isFocused = false }
                if target {
                    guard self.isFocused, textView.isEditable, textView.window != nil else { return }
                    textView.becomeFirstResponder()
                }
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard textView.isEditable else { textView.resignFirstResponder(); return }
            if !isFocused {
                isFocused = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if isFocused {
                isFocused = false
            }
        }

        // A send/restored draft is an external edit, not an input-method callback.
        // Use UITextInput's document replacement for clearing so UIKit retires
        // autocorrection/composition decorations before the field collapses.
        private var isSynchronizingExternalText = false

        @discardableResult
        func synchronizeExternalText(_ value: String, in textView: UITextView) -> Bool {
            guard textView.text != value else { return false }
            isSynchronizingExternalText = true
            defer { isSynchronizingExternalText = false }
            textView.unmarkText()
            if value.isEmpty,
               let document = textView.textRange(from: textView.beginningOfDocument,
                                                 to: textView.endOfDocument) {
                textView.replace(document, withText: "")
                textView.selectedRange = NSRange(location: 0, length: 0)
                textView.setContentOffset(.zero, animated: false)
            } else {
                textView.text = value
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isSynchronizingExternalText else { return }
            text = textView.text
            reportHeight(for: textView, force: true)
        }

        func reportHeight(for textView: UITextView, force: Bool = false) {
            guard textView.bounds.width > 0 else { return }

            let height = contentHeight(for: textView, width: textView.bounds.width)
            let shouldScrollInternally = height > ComposerTextView.maximumVisibleHeight + 0.5
            if textView.isScrollEnabled != shouldScrollInternally {
                textView.isScrollEnabled = shouldScrollInternally
            }
            if !shouldScrollInternally, textView.contentOffset != .zero {
                textView.setContentOffset(.zero, animated: false)
            }
            let visibleHeight = ComposerTextView.visibleHeight(height)
            if force || reportedView !== textView || reportedHeight != visibleHeight {
                reportedView = textView
                reportedHeight = visibleHeight
                onHeightChange(visibleHeight)
            }
        }
    }

    final class PastingTextView: UITextView {
        var onLayout: ((PastingTextView) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            // Report only after UIKit receives its actual content viewport.
            // The coordinator reuses identical supported sizing inputs.
            onLayout?(self)
        }

        var isKeyboardSendEnabled = false
        var onKeyboardSend: () -> Void = {}
        var onPasteFileProviders: ([NSItemProvider]) -> Void = { _ in }
        var onPasteFileURLs: ([URL]) -> Void = { _ in }
        var onPasteImageProviders: ([NSItemProvider]) -> Void = { _ in }
        var onPasteImages: ([UIImage]) -> Void = { _ in }

        func canPasteItemProviders(_ itemProviders: [NSItemProvider]) -> Bool {
            itemProviders.contains {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                    || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                    || $0.hasItemConformingToTypeIdentifier(UTType.text.identifier)
            }
        }

        func pasteItemProviders(_ itemProviders: [NSItemProvider]) {
            let fileProviders = itemProviders.filter {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }

            if fileProviders.isEmpty {
                let imageProviders = itemProviders.filter {
                    $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                }

                if imageProviders.isEmpty {
                    paste(nil)
                } else {
                    onPasteImageProviders(imageProviders)
                }
                return
            }

            onPasteFileProviders(fileProviders)
        }

        override var keyCommands: [UIKeyCommand]? {
            let sendCommand = UIKeyCommand(
                title: ComposerKeyboardCommand.title,
                action: #selector(sendMessageFromKeyboard),
                input: ComposerKeyboardCommand.input,
                modifierFlags: ComposerKeyboardCommand.modifierFlags
            )
            return (super.keyCommands ?? []) + [sendCommand]
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(sendMessageFromKeyboard) {
                return isKeyboardSendEnabled
            }

            if action == #selector(paste(_:)), hasPasteboardContent {
                return true
            }

            return super.canPerformAction(action, withSender: sender)
        }

        @objc private func sendMessageFromKeyboard() {
            guard isKeyboardSendEnabled else { return }
            onKeyboardSend()
        }

        override func paste(_ sender: Any?) {
            let fileProviders = pasteboardFileProviders

            if !fileProviders.isEmpty {
                onPasteFileProviders(fileProviders)
                return
            }

            let fileURLs = pasteboardFileURLs
            if !fileURLs.isEmpty {
                onPasteFileURLs(fileURLs)
                return
            }

            let imageProviders = pasteboardImageProviders
            if !imageProviders.isEmpty {
                onPasteImageProviders(imageProviders)
                return
            }

            let images = UIPasteboard.general.images ?? []
            if !images.isEmpty {
                onPasteImages(images)
                return
            }

            super.paste(sender)
        }

        private var hasPasteboardContent: Bool {
            let pasteboard = UIPasteboard.general
            return pasteboard.hasStrings
                || !pasteboardFileProviders.isEmpty
                || !pasteboardFileURLs.isEmpty
                || !pasteboardImageProviders.isEmpty
                || !(pasteboard.images?.isEmpty ?? true)
        }

        private var pasteboardFileProviders: [NSItemProvider] {
            UIPasteboard.general.itemProviders.filter {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }
        }

        private var pasteboardFileURLs: [URL] {
            UIPasteboard.general.urls?.filter(\.isFileURL) ?? []
        }

        private var pasteboardImageProviders: [NSItemProvider] {
            UIPasteboard.general.itemProviders.filter {
                $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            }
        }
    }
}

enum ComposerKeyboardCommand {
    static let title = String(localized: "Send Message")
    static let input = "\r"
    static let modifierFlags: UIKeyModifierFlags = .command
}
