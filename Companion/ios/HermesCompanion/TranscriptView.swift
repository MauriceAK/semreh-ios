import SwiftUI
import UIKit

struct TranscriptView: UIViewControllerRepresentable {
    let messages: [ChatMessage]
    let hasMore: Bool
    let loading: Bool
    let latestRevision: UUID
    let onOlder: () -> Void
    let onReadingHistory: (Bool) -> Void

    func makeUIViewController(context: Context) -> TranscriptController { TranscriptController() }
    func updateUIViewController(_ controller: TranscriptController, context: Context) {
        controller.onOlder = onOlder
        controller.onReadingHistory = onReadingHistory
        controller.update(messages: messages, hasMore: hasMore, loading: loading, latestRevision: latestRevision)
    }
}

@MainActor
final class TranscriptController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private let older = UIButton(type: .system)
    private var messages: [ChatMessage] = []
    private var firstLayout = true
    private var applying = false
    private var followingLatest = true
    private var latestRevision: UUID?
    private var scrollSpan: ChatPerformance.Token?
    private var sizingTask: Task<Void, Never>?
    var onOlder: (() -> Void)?
    var onReadingHistory: ((Bool) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.055, alpha: 1)
        table.backgroundColor = view.backgroundColor
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
    }
    @objc private func loadEarlier() { onOlder?() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if firstLayout && !messages.isEmpty && table.bounds.height > 0 {
            table.layoutIfNeeded()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--fixture-top") { followingLatest = false; table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false) }
            else { scrollToBottom() }
            #else
            scrollToBottom()
            #endif
            firstLayout = false
        } else if followingLatest && !messages.isEmpty { scrollToBottom() }
    }
    func update(messages newMessages: [ChatMessage], hasMore: Bool, loading: Bool, latestRevision: UUID) {
        loadViewIfNeeded()
        older.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: hasMore ? 48 : 0)
        older.setTitle(loading ? "Loading earlier messages…" : "Load earlier messages", for: .normal)
        older.isEnabled = !loading
        if hasMore { table.tableHeaderView = older } else { table.tableHeaderView = nil }
        let requestedLatest = self.latestRevision != nil && self.latestRevision != latestRevision
        self.latestRevision = latestRevision
        if requestedLatest { followingLatest = true }
        guard messages != newMessages else {
            if requestedLatest {
                scrollToBottom()
                table.layoutIfNeeded()
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
        if oldMessages.map(\.id) == messages.map(\.id) {
            let changed = messages.indices.filter { oldMessages[$0] != messages[$0] }.map { IndexPath(row: $0, section: 0) }
            if !changed.isEmpty {
                UIView.performWithoutAnimation { table.reloadRows(at: changed, with: .none); table.layoutIfNeeded() }
            }
        } else {
            UIView.performWithoutAnimation { table.reloadData(); table.layoutIfNeeded() }
        }
        let prepended = messages.first?.id != oldMessages.first?.id && messages.last?.id == oldMessages.last?.id
        if prepended && !oldMessages.isEmpty && !requestedLatest { followingLatest = false; onReadingHistory?(true) }
        if requestedLatest || (wasAtBottom && !prepended) {
            scrollToBottom()
        } else if let anchor, let index = messages.firstIndex(where: { $0.id == anchor.id }) {
            restoreAnchor(anchor, at: index)
        }
        if oldMessages.isEmpty { firstLayout = true; view.setNeedsLayout() }
    }
    private func restoreAnchor(_ anchor: (id: String, offset: CGFloat), at index: Int) {
        let path = IndexPath(row: index, section: 0)
        table.scrollToRow(at: path, at: .top, animated: false)
        table.layoutIfNeeded()
        table.contentOffset.y = table.rectForRow(at: path).minY - anchor.offset
        table.layoutIfNeeded()
    }
    private var isAtBottom: Bool { table.contentSize.height - table.contentOffset.y - table.bounds.height + table.adjustedContentInset.bottom < 100 }
    private func visibleAnchor() -> (id: String, offset: CGFloat)? {
        guard let index = table.indexPathsForVisibleRows?.first, messages.indices.contains(index.row) else { return nil }
        return (messages[index.row].id, table.rectForRow(at: index).minY - table.contentOffset.y)
    }
    private func scrollToBottom() {
        followingLatest = true
        let offset = max(-table.adjustedContentInset.top, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        table.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        ChatPerformance.shared.end(scrollSpan)
        scrollSpan = ChatPerformance.shared.begin(.scroll)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { ChatPerformance.shared.end(scrollSpan); scrollSpan = nil }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        ChatPerformance.shared.end(scrollSpan); scrollSpan = nil
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !applying, !firstLayout, table.isDragging || table.isDecelerating else { return }
        followingLatest = isAtBottom
        onReadingHistory?(!followingLatest)
    }
    private func scheduleSizing() {
        guard sizingTask == nil else { return }
        sizingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self else { return }
            let anchor = self.visibleAnchor()
            let atBottom = self.followingLatest
            let layoutSpan = ChatPerformance.shared.begin(.markdownLayout, count: self.messages.count)
            self.applying = true
            UIView.performWithoutAnimation {
                self.table.performBatchUpdates(nil) { [weak self] _ in
                    guard let self else { return }
                    self.table.layoutIfNeeded()
                    if atBottom && self.followingLatest { self.scrollToBottom() }
                    else if let anchor, let index = self.messages.firstIndex(where: { $0.id == anchor.id }) {
                        self.restoreAnchor(anchor, at: index)
                    }
                    self.applying = false
                    self.sizingTask = nil
                    ChatPerformance.shared.end(layoutSpan)
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
        cell.onFormattingChanged = { [weak self] in self?.scheduleSizing() }
        cell.configure(messages[indexPath.row])
        return cell
    }
}

@MainActor
final class BubbleCell: UITableViewCell {
    private let bubble = UIView()
    private let textView = UITextView()
    private var left: NSLayoutConstraint!
    private var right: NSLayoutConstraint!
    private var formatTask: Task<Void, Never>?
    private var messageID: String?
    var onFormattingChanged: (() -> Void)?
    private static let formatting = MarkdownCache()
    private static let renderedCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
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
    private static let measuringText = UITextView()
    private static func cacheKey(_ message: ChatMessage, font: UIFont) -> NSString {
        (font.fontName + "|" + String(describing: font.pointSize) + "|" + message.displayText) as NSString
    }
    static func height(_ message: ChatMessage, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: message.role == "tool" ? .footnote : .body, compatibleWith: traits)
        let key = cacheKey(message, font: font)
        let formatted = message.provisional ? nil : renderedCache.object(forKey: key)
        let sizeKey = (String(describing: width) + "|" + (formatted == nil ? "plain|" : "formatted|") + (key as String)) as NSString
        if let height = heightCache.object(forKey: sizeKey) { return CGFloat(height.doubleValue) }
        measuringText.isScrollEnabled = false
        measuringText.textContainerInset = UIEdgeInsets(top: 11, left: 10, bottom: 11, right: 10)
        measuringText.textContainer.lineFragmentPadding = 0
        measuringText.font = font
        if let formatted { measuringText.attributedText = formatted }
        else { measuringText.text = message.displayText }
        let height = ceil(measuringText.sizeThatFits(CGSize(width: width * 0.91, height: .greatestFiniteMagnitude)).height) + 10
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
        textView.textContainerInset = UIEdgeInsets(top: 11, left: 10, bottom: 11, right: 10)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.dataDetectorTypes = .link
        textView.linkTextAttributes = [.foregroundColor: UIColor.systemCyan]
        contentView.addSubview(bubble)
        bubble.addSubview(textView)
        left = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        right = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        left.priority = .defaultHigh
        right.priority = .defaultHigh
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5), bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.91),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: bubble.topAnchor), textView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor), textView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func prepareForReuse() { super.prepareForReuse(); formatTask?.cancel(); messageID = nil }
    func configure(_ message: ChatMessage) {
        formatTask?.cancel()
        messageID = message.id
        let user = message.role == "user"
        left.isActive = !user
        right.isActive = user
        bubble.backgroundColor = user ? UIColor(red: 0.04, green: 0.36, blue: 0.82, alpha: 1) : UIColor(white: 0.13, alpha: 1)
        let font = UIFont.preferredFont(forTextStyle: message.role == "tool" ? .footnote : .body, compatibleWith: traitCollection)
        textView.font = font
        textView.textColor = .white
        textView.text = message.displayText
        textView.accessibilityLabel = (user ? "You. " : "Hermes. ") + message.displayText
        textView.accessibilityIdentifier = "message-" + message.id
        guard !message.provisional else { return }
        let cacheKey = Self.cacheKey(message, font: font)
        if let cached = Self.renderedCache.object(forKey: cacheKey) {
            textView.attributedText = cached
            return
        }
        formatTask = Task { [weak self] in
            let formatted = await Self.formatting.format(message.displayText)
            guard !Task.isCancelled, let self, self.messageID == message.id else { return }
            let layoutSpan = ChatPerformance.shared.begin(.markdownLayout, count: message.displayText.utf8.count)
            defer { ChatPerformance.shared.end(layoutSpan) }
            let attributed = NSMutableAttributedString(formatted)
            attributed.addAttributes([.font: font, .foregroundColor: UIColor.white], range: NSRange(location: 0, length: attributed.length))
            for run in formatted.runs {
                guard let intent = run.inlinePresentationIntent else { continue }
                let location = String(formatted.characters[..<run.range.lowerBound]).utf16.count
                let length = String(formatted.characters[run.range]).utf16.count
                var runFont = font
                if intent.contains(.code) { runFont = UIFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
                else if intent.contains(.stronglyEmphasized), let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) { runFont = UIFont(descriptor: descriptor, size: font.pointSize) }
                else if intent.contains(.emphasized), let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) { runFont = UIFont(descriptor: descriptor, size: font.pointSize) }
                attributed.addAttribute(.font, value: runFont, range: NSRange(location: location, length: length))
            }
            Self.renderedCache.setObject(attributed, forKey: cacheKey, cost: message.displayText.utf8.count)
            self.textView.attributedText = attributed
            self.onFormattingChanged?()
        }
    }
}

actor MarkdownCache {
    private var values: [String: AttributedString] = [:]
    private var order: [String] = []
    private var bytes = 0
    func format(_ text: String) -> AttributedString {
        if let value = values[text] { return value }
        var result = AttributedString()
        let blocks = text.components(separatedBy: "```")
        for (index, block) in blocks.enumerated() {
            if index.isMultiple(of: 2) {
                result.append((try? AttributedString(markdown: block, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block))
            } else {
                var source = block
                if let newline = source.firstIndex(of: "\n"), source[..<newline].count < 24 { source = String(source[source.index(after: newline)...]) }
                var code = AttributedString(source)
                code.inlinePresentationIntent = .code
                result.append(code)
            }
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
