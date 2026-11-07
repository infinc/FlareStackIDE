import AppKit
@testable import FlareStackIDE

final class StickyScrollPlugin: NativePlugin {
    let id = "sticky-scroll"
    func textAddon(for code: CodeEditing) -> TextAddon? { StickyScrollAddon(code: code) }
}

final class StickyView: NSView {
    private static let maxLines = 5
    private weak var textView: NSTextView?
    private(set) var headers: [Int] = []
    private var rows: [NSAttributedString] = []
    var onClick: ((Int) -> Void)?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ lines: [(line: Int, text: NSAttributedString)], frame area: NSRect) {
        let shown = lines.suffix(Self.maxLines)
        headers = shown.map(\.line)
        rows = shown.map(\.text)
        isHidden = rows.isEmpty
        frame = NSRect(x: area.minX, y: area.minY, width: area.width, height: CGFloat(rows.count) * Settings.lineHeight + 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Settings.background.setFill()
        bounds.fill()
        let height = Settings.lineHeight
        let scrollX = textView?.enclosingScrollView?.contentView.bounds.minX ?? 0
        let x = (textView?.textContainerOrigin.x ?? 0) + (textView?.textContainer?.lineFragmentPadding ?? 0) - scrollX
        for (index, row) in rows.enumerated() {
            let y = CGFloat(index) * height + (height - Settings.font.ascender + Settings.font.descender) / 2
            row.draw(at: NSPoint(x: x, y: y))
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let index = Int(convert(event.locationInWindow, from: nil).y / Settings.lineHeight)
        if headers.indices.contains(index) { onClick?(headers[index]) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class StickyScrollAddon: NSObject, TextAddon {
    private weak var code: CodeEditing?
    private let view: StickyView
    private var scopes: [StickyScope] = []
    private var starts = [0]
    private var work: DispatchWorkItem?

    init(code: CodeEditing) {
        self.code = code
        view = StickyView(textView: code.textView)
        super.init()
        view.onClick = { [weak self] in self?.jump(to: $0) }
        code.scrollView.addSubview(view)
        let clip = code.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.frameDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .settingsChanged, object: nil)
        analyze()
    }

    private func analyze() {
        guard let textView = code?.textView else { return }
        let text = textView.string
        let ns = text as NSString
        starts = [0]
        scopes = []
        if ns.length <= Highlighter.limit {
            starts = LineIndex.starts(of: textView)
            scopes = StickyScopes.find(in: text)
        }
        refresh()
    }

    private func line(atY y: CGFloat) -> Int {
        guard let textView = code?.textView, let layout = textView.layoutManager, let container = textView.textContainer else { return 0 }
        let inner = NSPoint(x: 0, y: y - textView.textContainerOrigin.y)
        let index = layout.characterIndexForGlyph(at: layout.glyphIndex(for: inner, in: container))
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= index { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private func attributed(_ line: Int) -> NSAttributedString {
        guard let textView = code?.textView, let layout = textView.layoutManager else { return NSAttributedString() }
        let text = textView.string as NSString
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : text.length
        let range = NSRange(location: start, length: max(end - start, 0))
        let result = NSMutableAttributedString(string: text.substring(with: range), attributes: [.font: Settings.font, .foregroundColor: Settings.foreground])
        var index = range.location
        while index < NSMaxRange(range) {
            var run = NSRange()
            let color = layout.temporaryAttribute(.foregroundColor, atCharacterIndex: index, longestEffectiveRange: &run, in: range) as? NSColor
            if let color { result.addAttribute(.foregroundColor, value: color, range: NSRange(location: run.location - start, length: run.length)) }
            index = max(NSMaxRange(run), index + 1)
        }
        return result
    }

    @objc private func refresh() {
        guard let code else { return }
        let clip = code.scrollView.contentView
        let top = clip.bounds.minY
        guard !scopes.isEmpty, top > 0 else { return view.show([], frame: clip.frame) }
        var active: [StickyScope] = []
        for _ in 0..<3 {
            active = StickyScopes.active(scopes, line: line(atY: top + CGFloat(active.count) * Settings.lineHeight))
        }
        view.show(active.map { ($0.header, attributed($0.header)) }, frame: clip.frame)
    }

    private func jump(to line: Int) {
        guard let textView = code?.textView, starts.indices.contains(line) else { return }
        let range = NSRange(location: starts[line], length: 0)
        textView.setSelectedRange(range)
        CodeView.center(textView, on: range)
    }

    func fileOpened() { analyze() }

    func textChanged() {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.analyze() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    func detach() {
        work?.cancel()
        NotificationCenter.default.removeObserver(self)
        view.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(StickyScrollPlugin()) }
