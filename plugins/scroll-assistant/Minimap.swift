import AppKit
import CoreText
@testable import FlareStackIDE

private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class Minimap: NSView {
    static let width: CGFloat = 96
    private static let lineHeight: CGFloat = 3
    private static let maxColumns = 110
    private static let font = CTFontCreateWithName("Menlo" as CFString, 2.4, nil)
    private static let marksChanged = Notification.Name("FlareStackIDE.lineMarks")
    private static let marksRequest = Notification.Name("FlareStackIDE.lineMarksRequest")
    private static let bookmarksChanged = Notification.Name("FlareStackIDE.bookmarks")
    private static let bookmarksRequest = Notification.Name("FlareStackIDE.bookmarksRequest")

    private weak var textView: NSTextView?
    private weak var scroll: NSScrollView?
    private let thumb = PassThroughView()
    private var starts = [0]
    private var cache: [Int: CTLine] = [:]
    private var errors: Set<Int> = []
    private var warnings: Set<Int> = []
    private var bookmarks: Set<Int> = []
    private var hovering = false
    private var dragging = false
    private var grab: CGFloat = 0
    private var offset: CGFloat = 0
    private var pending: DispatchWorkItem?

    init(textView: NSTextView, scroll: NSScrollView) {
        self.textView = textView
        self.scroll = scroll
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        wantsLayer = true
        thumb.wantsLayer = true
        thumb.isHidden = true
        addSubview(thumb)
        let center = NotificationCenter.default
        scroll.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(positionChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        center.addObserver(self, selector: #selector(positionChanged), name: NSView.frameDidChangeNotification, object: textView)
        center.addObserver(self, selector: #selector(contentChanged), name: .settingsChanged, object: nil)
        center.addObserver(self, selector: #selector(marksChanged(_:)), name: Self.marksChanged, object: textView)
        center.addObserver(self, selector: #selector(bookmarksChanged(_:)), name: Self.bookmarksChanged, object: textView)
        contentChanged()
        center.post(name: Self.marksRequest, object: textView)
        center.post(name: Self.bookmarksRequest, object: textView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyHover()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyHover()
    }

    private func applyHover() {
        let shown = hovering || dragging
        let tint = ButtonHover.tint(for: self)
        layer?.backgroundColor = shown ? tint.withAlphaComponent(0.06).cgColor : nil
        thumb.layer?.backgroundColor = tint.withAlphaComponent(0.18).cgColor
        thumb.isHidden = !shown
    }

    func textChanged() {
        positionChanged()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.contentChanged() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    @objc func contentChanged() {
        guard let text = textView?.string as NSString? else { return }
        var result = [0]
        var i = 0
        while i < text.length {
            let r = text.range(of: "\n", options: .literal, range: NSRange(location: i, length: text.length - i))
            if r.location == NSNotFound { break }
            result.append(r.location + 1)
            i = r.location + 1
        }
        starts = result
        cache = [:]
        needsDisplay = true
        positionChanged()
    }

    @objc private func marksChanged(_ note: Notification) {
        errors = note.userInfo?["errors"] as? Set<Int> ?? []
        warnings = note.userInfo?["warnings"] as? Set<Int> ?? []
        needsDisplay = true
    }

    @objc private func bookmarksChanged(_ note: Notification) {
        bookmarks = note.userInfo?["lines"] as? Set<Int> ?? []
        needsDisplay = true
    }

    private var metrics: (track: CGFloat, thumb: CGFloat, range: CGFloat, fraction: CGFloat, offset: CGFloat)? {
        guard let scroll, let textView else { return nil }
        let clip = scroll.contentView.bounds
        let document = textView.frame.height
        let map = CGFloat(starts.count) * Self.lineHeight
        let track = min(map, bounds.height)
        let size = min(max(map * min(clip.height / max(document, 1), 1), 14), max(track, 14))
        let range = max(document - clip.height, 0)
        let fraction = range > 0 ? min(max(clip.minY / range, 0), 1) : 0
        return (track, size, range, fraction, max(map - bounds.height, 0) * fraction)
    }

    @objc private func positionChanged() {
        guard let m = metrics else { return }
        thumb.frame = NSRect(x: 0, y: m.fraction * max(m.track - m.thumb, 0), width: bounds.width, height: m.thumb)
        if abs(m.offset - offset) >= 0.5 {
            offset = m.offset
            needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionChanged()
    }

    private func scroll(toThumbTop top: CGFloat) {
        guard let m = metrics, let scroll else { return }
        let travel = max(m.track - m.thumb, 1)
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(top / travel, 0), 1) * m.range))
        scroll.reflectScrolledClipView(clip)
    }

    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        dragging = true
        applyHover()
        grab = thumb.frame.minY...thumb.frame.maxY ~= y ? y - thumb.frame.minY : thumb.frame.height / 2
        scroll(toThumbTop: y - grab)
    }

    override func mouseDragged(with event: NSEvent) {
        scroll(toThumbTop: convert(event.locationInWindow, from: nil).y - grab)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        applyHover()
    }

    private func line(_ index: Int) -> CTLine? {
        if let cached = cache[index] { return cached }
        guard let textView, let layout = textView.layoutManager, index < starts.count else { return nil }
        let text = textView.string as NSString
        let start = starts[index]
        let end = index + 1 < starts.count ? starts[index + 1] - 1 : text.length
        let range = NSRange(location: start, length: max(min(end - start, Self.maxColumns), 0))
        guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        let content = text.substring(with: range).replacingOccurrences(of: "\t", with: " ")
        let plain = Settings.foreground.cgColor
        let attributed = NSMutableAttributedString(string: content, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: Self.font, kCTForegroundColorAttributeName as NSAttributedString.Key: plain])
        var i = range.location
        while i < NSMaxRange(range) {
            var run = NSRange()
            let color = layout.temporaryAttribute(.foregroundColor, atCharacterIndex: i, longestEffectiveRange: &run, in: range) as? NSColor
            if let color, run.length > 0, NSMaxRange(run) - start <= (content as NSString).length {
                attributed.addAttribute(kCTForegroundColorAttributeName as NSAttributedString.Key, value: color.cgColor,
                                        range: NSRange(location: run.location - start, length: run.length))
            }
            i = max(NSMaxRange(run), i + 1)
        }
        let made = CTLineCreateWithAttributedString(attributed)
        cache[index] = made
        return made
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let height = Self.lineHeight
        let first = max(Int(offset / height), 0)
        let last = min(Int((offset + bounds.height) / height) + 1, starts.count)
        guard first < last else { return }
        for index in first..<last {
            let y = CGFloat(index) * height - offset
            if errors.contains(index + 1) {
                NSColor.systemRed.withAlphaComponent(0.6).setFill()
            } else if warnings.contains(index + 1) {
                NSColor.systemYellow.withAlphaComponent(0.55).setFill()
            } else if bookmarks.contains(index + 1) {
                NSColor.systemBlue.withAlphaComponent(0.6).setFill()
            } else {
                continue
            }
            NSRect(x: 0, y: y, width: bounds.width, height: height).fill()
        }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for index in first..<last {
            guard let line = line(index) else { continue }
            context.textPosition = CGPoint(x: 4, y: CGFloat(index) * height - offset + height - 0.6)
            CTLineDraw(line, context)
        }
    }
}
