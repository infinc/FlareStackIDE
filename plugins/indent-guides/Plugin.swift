import AppKit
@testable import FlareStackIDE

final class IndentGuidesPlugin: NativePlugin {
    let id = IndentGuidesAddon.pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { IndentGuidesAddon(code: code) }
}

enum IndentMeasure {
    static func unitSpaces(_ text: NSString, setting: String?) -> Int? {
        if let setting, let value = Int(setting), value > 0 { return value }
        var counts: [Int: Int] = [:]
        var previous = 0
        var index = 0
        var lines = 0
        let length = min(text.length, 200_000)
        while index < length, lines < 2000 {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            var spaces = 0
            var position = range.location
            while position < NSMaxRange(range), text.character(at: position) == 0x20 { spaces += 1; position += 1 }
            let blank = position >= NSMaxRange(range) || [0x0A, 0x0D].contains(text.character(at: position))
            if !blank, position < NSMaxRange(range), text.character(at: position) != 0x09 {
                let delta = abs(spaces - previous)
                if delta > 0 { counts[delta, default: 0] += 1 }
                previous = spaces
            }
            index = NSMaxRange(range)
            lines += 1
        }
        return counts.filter { (2...8).contains($0.key) }.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }
}

private final class GuideView: NSView {
    weak var textView: NSTextView?
    var unit: CGFloat = 0
    var spaceWidth: CGFloat = 7
    var tabWidth: CGFloat = 28
    var color = NSColor.secondaryLabelColor
    var activeColor = NSColor.labelColor
    var activeLevel: (line: Int, level: Int, range: ClosedRange<Int>)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func indent(_ text: NSString, _ range: NSRange) -> (width: CGFloat, blank: Bool) {
        var x: CGFloat = 0
        var position = range.location
        while position < NSMaxRange(range) {
            let c = text.character(at: position)
            if c == 0x20 { x += spaceWidth } else if c == 0x09 { x = (floor(x / tabWidth) + 1) * tabWidth } else { break }
            position += 1
        }
        let blank = position >= NSMaxRange(range) || [0x0A, 0x0D].contains(text.character(at: position))
        return (x, blank)
    }

    func levels(_ text: NSString, line range: NSRange) -> Int {
        guard unit > 0 else { return 0 }
        let own = indent(text, range)
        if !own.blank { return Int((own.width + 0.5) / unit) }
        var before = 0, after = 0
        var cursor = range.location
        for _ in 0..<200 where cursor > 0 {
            let previous = text.lineRange(for: NSRange(location: cursor - 1, length: 0))
            let value = indent(text, previous)
            if !value.blank { before = Int((value.width + 0.5) / unit); break }
            cursor = previous.location
        }
        cursor = NSMaxRange(range)
        for _ in 0..<200 where cursor < text.length {
            let next = text.lineRange(for: NSRange(location: cursor, length: 0))
            let value = indent(text, next)
            if !value.blank { after = Int((value.width + 0.5) / unit); break }
            cursor = NSMaxRange(next)
        }
        return min(before, after)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, unit > 0, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        guard text.length > 0 else { return }
        let origin = textView.textContainerOrigin
        let padding = container.lineFragmentPadding
        let rect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        guard glyphs.length > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        var lineCache: (location: Int, levels: Int)?
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            guard fragment.height > 0 else { return }
            let characters = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let line = text.lineRange(for: NSRange(location: characters.location, length: 0))
            let count: Int
            if let lineCache, lineCache.location == line.location {
                count = lineCache.levels
            } else {
                count = self.levels(text, line: line)
                lineCache = (line.location, count)
            }
            guard count > 0 else { return }
            for level in 0..<count {
                let x = (origin.x + padding + CGFloat(level) * self.unit).rounded(.down) + 0.5 / scale
                let active = self.activeLevel.map { $0.level == level && $0.range.contains(line.location) } ?? false
                (active ? self.activeColor : self.color).setFill()
                NSRect(x: x, y: origin.y + fragment.minY, width: 1 / scale * (active ? 2 : 1), height: fragment.height).fill()
            }
        }
    }
}

final class IndentGuidesAddon: NSObject, TextAddon {
    static let pluginID = "indent-guides"
    private weak var code: CodeEditing?
    private let guides = GuideView()
    private var work: DispatchWorkItem?

    init(code: CodeEditing) {
        self.code = code
        super.init()
        guides.textView = code.textView
        guides.autoresizingMask = [.width, .height]
        guides.frame = code.textView.bounds
        code.textView.addSubview(guides)
        code.textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: code.textView)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        settingsChanged()
    }

    @objc private func resized() {
        guard let textView = code?.textView else { return }
        if guides.frame != textView.bounds { guides.frame = textView.bounds }
    }

    @objc private func settingsChanged() {
        let base = PluginStore.color(Self.pluginID, "color") ?? Settings.foreground
        guides.color = base.withAlphaComponent(0.18)
        guides.activeColor = (PluginStore.color(Self.pluginID, "activeColor") ?? Settings.foreground).withAlphaComponent(0.45)
        guides.spaceWidth = (" " as NSString).size(withAttributes: [.font: Settings.font]).width
        guides.tabWidth = (code?.textView.defaultParagraphStyle ?? .default).defaultTabInterval
        measure()
    }

    private func measure() {
        guard let textView = code?.textView else { return }
        let text = textView.string as NSString
        let setting = PluginStore.setting(Self.pluginID, "size")
        let fixed = setting.flatMap { Int($0) }
        let tabs = text.length > 0 && text.range(of: "\n\t").location != NSNotFound && text.range(of: "\n  ").location == NSNotFound
        if tabs && fixed == nil {
            guides.unit = guides.tabWidth
        } else {
            guides.unit = CGFloat(IndentMeasure.unitSpaces(text, setting: fixed.map(String.init)) ?? 4) * guides.spaceWidth
        }
        updateActive()
        guides.needsDisplay = true
    }

    private func updateActive() {
        guard PluginStore.setting(Self.pluginID, "highlightActive") != "false", let textView = code?.textView, guides.unit > 0 else {
            guides.activeLevel = nil
            return
        }
        let text = textView.string as NSString
        let caret = min(textView.selectedRange().location, text.length)
        guard text.length > 0 else { guides.activeLevel = nil; return }
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let level = guides.levels(text, line: line)
        guard level > 0 else { guides.activeLevel = nil; return }
        var start = line.location
        var steps = 0
        while start > 0, steps < 3000 {
            steps += 1
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            if guides.levels(text, line: previous) < level { break }
            start = previous.location
        }
        var end = line.location
        steps = 0
        while NSMaxRange(text.lineRange(for: NSRange(location: end, length: 0))) < text.length, steps < 3000 {
            steps += 1
            let next = text.lineRange(for: NSRange(location: NSMaxRange(text.lineRange(for: NSRange(location: end, length: 0))), length: 0))
            if guides.levels(text, line: next) < level { break }
            end = next.location
        }
        let previous = guides.activeLevel
        guides.activeLevel = (line.location, level - 1, start...end)
        if previous?.range != start...end || previous?.level != level - 1 { guides.needsDisplay = true }
    }

    private func schedule(_ full: Bool) {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if full { self.measure() } else { self.updateActive() }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (full ? 0.15 : 0.05), execute: item)
    }

    func textChanged() {
        guides.needsDisplay = true
        schedule(true)
    }

    func selectionChanged() { schedule(false) }

    func fileOpened() {
        resized()
        measure()
    }

    func detach() {
        work?.cancel()
        NotificationCenter.default.removeObserver(self)
        guides.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(IndentGuidesPlugin()) }
