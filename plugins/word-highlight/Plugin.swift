import AppKit
@testable import FlareStackIDE

final class WordHighlightPlugin: NativePlugin {
    let id = WordHighlightAddon.pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { WordHighlightAddon(code: code) }
}

enum WordFinder {
    private static let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))

    private static func isWord(_ unit: unichar) -> Bool { UnicodeScalar(unit).map(word.contains) ?? false }

    static func word(in text: NSString, at index: Int) -> String? {
        var start = min(index, text.length), end = start
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWord(text.character(at: end)) { end += 1 }
        return end > start ? text.substring(with: NSRange(location: start, length: end - start)) : nil
    }

    static func ranges(of target: String, in text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var position = 0
        while position < text.length {
            let found = text.range(of: target, options: .literal, range: NSRange(location: position, length: text.length - position))
            guard found.location != NSNotFound else { break }
            let before = found.location == 0 || !isWord(text.character(at: found.location - 1))
            let after = NSMaxRange(found) == text.length || !isWord(text.character(at: NSMaxRange(found)))
            if before && after { result.append(found) }
            position = NSMaxRange(found)
        }
        return result
    }

    static func lines(of ranges: [NSRange], in text: NSString) -> Set<Int> {
        var lines = Set<Int>()
        var line = 1, position = 0
        for range in ranges {
            while true {
                let next = text.range(of: "\n", options: .literal, range: NSRange(location: position, length: range.location - position))
                if next.location == NSNotFound { break }
                line += 1
                position = NSMaxRange(next)
            }
            lines.insert(line)
        }
        return lines
    }
}

final class WordHighlightAddon: NSObject, TextAddon {
    static let pluginID = "word-highlight"
    private static let linesChanged = PluginEvent.wordMarks
    private static let linesRequest = PluginEvent.wordMarksRequest
    private weak var code: CodeEditing?
    private var lines = Set<Int>()
    private var active = false

    init(code: CodeEditing) {
        self.code = code
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(publish), name: Self.linesRequest, object: code.textView)
    }

    private func clear() {
        guard active, let textView = code?.textView else { return }
        active = false
        lines = []
        CodeView.setBackgrounds([], owner: Self.pluginID, in: textView)
        publish()
    }

    @objc private func publish() {
        NotificationCenter.default.post(name: Self.linesChanged, object: code?.textView, userInfo: ["lines": lines])
    }

    func selectionChanged() {
        guard let textView = code?.textView, let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .leftMouseUp, event.window === textView.window else { return }
        let text = textView.string as NSString
        guard textView.selectedRange().length == 0, text.length <= Highlighter.limit,
              let target = WordFinder.word(in: text, at: textView.selectedRange().location) else { return clear() }
        let ranges = WordFinder.ranges(of: target, in: text)
        let color = (PluginStore.color(Self.pluginID, "highlightColor") ?? .systemBlue).withAlphaComponent(0.3)
        active = true
        lines = WordFinder.lines(of: ranges, in: text)
        CodeView.setBackgrounds(ranges.map { ($0, color) }, owner: Self.pluginID, in: textView)
        publish()
    }

    func textChanged() { clear() }

    func fileOpened() { clear() }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        clear()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(WordHighlightPlugin()) }
