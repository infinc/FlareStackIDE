import AppKit
@testable import FlareStackIDE

final class BracketColorizerPlugin: NativePlugin {
    let id = BracketColorizerAddon.pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { BracketColorizerAddon(code: code) }
}

struct BracketScan {
    struct Bracket {
        let location: Int
        let depth: Int
        var pair: Int?
    }

    private(set) var brackets: [Bracket] = []
    private(set) var index: [Int: Int] = [:]

    private static let opens: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
    private static let closes: [unichar: unichar] = [41: 40, 93: 91, 125: 123]

    private static func comments(for ext: String) -> (line: [String], block: Bool) {
        switch ext {
        case "py", "pyw", "pyi", "sh", "bash", "zsh", "rb", "yaml", "yml", "toml", "r", "pl", "makefile", "mk", "dockerfile", "conf", "ini", "cfg", "env":
            return (["#"], false)
        case "sql", "lua", "hs":
            return (["--"], ext != "hs")
        case "md", "markdown", "mdown", "mkd", "txt", "csv", "tsv", "":
            return ([], false)
        case "html", "htm", "xml", "svg", "vue", "svelte":
            return ([], true)
        default:
            return (["//"], true)
        }
    }

    init(_ text: NSString, ext: String) {
        let style = Self.comments(for: ext)
        let prose = ["md", "markdown", "mdown", "mkd", "txt", "csv", "tsv", ""].contains(ext)
        let length = text.length
        var stack: [(position: Int, char: unichar)] = []
        var i = 0
        func starts(_ token: String, at position: Int) -> Bool {
            let units = Array(token.utf16)
            guard position + units.count <= length else { return false }
            for (k, unit) in units.enumerated() where text.character(at: position + k) != unit { return false }
            return true
        }
        func lineEnd(from position: Int) -> Int {
            var j = position
            while j < length, text.character(at: j) != 10 { j += 1 }
            return j
        }
        while i < length {
            let c = text.character(at: i)
            if !prose {
                if style.line.contains(where: { starts($0, at: i) }) {
                    i = lineEnd(from: i)
                    continue
                }
                if style.block, starts("/*", at: i) {
                    let found = text.range(of: "*/", options: .literal, range: NSRange(location: i + 2, length: length - i - 2))
                    i = found.location == NSNotFound ? length : NSMaxRange(found)
                    continue
                }
                if c == 34 || c == 39 || c == 96 {
                    var j = i + 1
                    var closed = false
                    while j < length {
                        let d = text.character(at: j)
                        if d == 92 { j += 2; continue }
                        if d == c { closed = true; break }
                        if d == 10 && c != 96 { break }
                        j += 1
                    }
                    if closed, ext != "rs" || c != 39 || j - i <= 2 || text.character(at: i + 1) == 92 {
                        i = j + 1
                        continue
                    }
                }
            }
            if Self.opens[c] != nil {
                index[i] = brackets.count
                brackets.append(Bracket(location: i, depth: stack.count, pair: nil))
                stack.append((i, c))
            } else if let open = Self.closes[c] {
                if let top = stack.last, top.char == open {
                    stack.removeLast()
                    let opener = index[top.position]!
                    index[i] = brackets.count
                    brackets.append(Bracket(location: i, depth: stack.count, pair: top.position))
                    brackets[opener].pair = i
                } else {
                    index[i] = brackets.count
                    brackets.append(Bracket(location: i, depth: stack.count, pair: nil))
                }
            }
            i += 1
        }
    }

    func bracket(at location: Int) -> Bracket? { index[location].map { brackets[$0] } }
}

final class BracketColorizerAddon: TextAddon, TextDecorating {
    static let pluginID = "bracket-colorizer"
    private weak var code: CodeEditing?
    private var scan: BracketScan?
    private var work: DispatchWorkItem?

    init(code: CodeEditing) {
        self.code = code
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private var palette: [NSColor] {
        [("color1", NSColor.systemYellow), ("color2", NSColor.systemPurple), ("color3", NSColor.systemBlue)]
            .map { PluginStore.color(Self.pluginID, $0.0) ?? $0.1 }
    }

    @objc private func settingsChanged() { refresh() }

    private func refresh() {
        guard let layout = code?.textView.layoutManager else { return }
        decorate(layout)
    }

    func decorate(_ layout: NSLayoutManager) {
        guard let textView = code?.textView, textView.layoutManager === layout else { return }
        let text = textView.string as NSString
        guard text.length <= Highlighter.limit, code?.fileURL != nil else {
            scan = nil
            CodeView.setBackgrounds([], owner: Self.pluginID, in: textView)
            return
        }
        let ext = code?.fileURL.map { $0.pathExtension.isEmpty ? $0.lastPathComponent.lowercased() : $0.pathExtension.lowercased() } ?? ""
        let result = BracketScan(text, ext: ext)
        scan = result
        let colors = palette
        let red = PluginStore.setting(Self.pluginID, "unmatched") != "false"
        for bracket in result.brackets {
            let color: NSColor
            if bracket.pair == nil {
                guard red else { continue }
                color = .systemRed
            } else {
                color = colors[bracket.depth % colors.count]
            }
            layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: NSRange(location: bracket.location, length: 1))
        }
        highlightMatch()
    }

    private func highlightMatch() {
        guard let textView = code?.textView else { return }
        let selection = textView.selectedRange()
        var marks: [(range: NSRange, color: NSColor)] = []
        if selection.length == 0, let scan {
            let found = scan.bracket(at: selection.location).flatMap { b in b.pair.map { (b.location, $0) } }
                ?? (selection.location > 0 ? scan.bracket(at: selection.location - 1).flatMap { b in b.pair.map { (b.location, $0) } } : nil)
            if let (a, b) = found {
                let color = (PluginStore.color(Self.pluginID, "matchColor") ?? .systemGray).withAlphaComponent(0.35)
                marks = [(NSRange(location: a, length: 1), color), (NSRange(location: b, length: 1), color)]
            }
        }
        CodeView.setBackgrounds(marks, owner: Self.pluginID, in: textView)
    }

    func selectionChanged() { highlightMatch() }

    func fileOpened() {
        scan = nil
        refresh()
    }

    func textChanged() {
        scan = nil
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    func detach() {
        work?.cancel()
        NotificationCenter.default.removeObserver(self)
        guard let textView = code?.textView else { return }
        CodeView.setBackgrounds([], owner: Self.pluginID, in: textView)
        if let layout = textView.layoutManager, let scan {
            for bracket in scan.brackets where bracket.location < (textView.string as NSString).length {
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: bracket.location, length: 1))
            }
        }
        (textView.window?.windowController as? EditorWindowController)?.recolor()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(BracketColorizerPlugin()) }
