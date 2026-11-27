import AppKit
@testable import FlareStackIDE

final class CommentTogglePlugin: NativePlugin {
    let id = CommentToggleAddon.pluginID
    private var observer: Any?

    init() {
        observer = NotificationCenter.default.addObserver(forName: PluginEvent.commentKey, object: nil, queue: .main) { note in
            CommentToggleAddon.managed = note.userInfo?["managed"] as? Bool ?? false
        }
        NotificationCenter.default.post(name: PluginEvent.commentKeyRequest, object: nil)
    }

    func textAddon(for code: CodeEditing) -> TextAddon? { CommentToggleAddon(code: code) }
}

enum CommentSyntax: Equatable {
    case line(String)
    case block(String, String)

    private static let table: [(CommentSyntax, Set<String>)] = [
        (.line("//"), ["swift", "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts", "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "hxx",
                       "m", "mm", "cs", "go", "rs", "java", "kt", "kts", "scala", "dart", "php", "groovy", "gradle", "zig", "v",
                       "jsonc", "json5", "proto", "glsl", "metal", "sol"]),
        (.line("#"), ["py", "pyw", "pyi", "sh", "bash", "zsh", "ksh", "fish", "rb", "rake", "gemspec", "pl", "pm", "r", "yaml", "yml",
                      "toml", "conf", "cfg", "properties", "env", "dockerfile", "makefile", "mk", "cmake", "nim", "cr", "ex", "exs",
                      "jl", "tf", "ps1", "gitignore", "gitattributes", "editorconfig", "http", "rest"]),
        (.line("--"), ["lua", "sql", "hs", "elm", "ada"]),
        (.line("%"), ["tex", "sty", "erl", "m4"]),
        (.line(";"), ["ini", "lisp", "el", "clj", "cljs", "scm", "asm", "s"]),
        (.block("<!--", "-->"), ["html", "htm", "xhtml", "xml", "svg", "plist", "md", "markdown", "vue", "svelte", "storyboard", "xib"]),
        (.block("/*", "*/"), ["css", "scss", "less", "sass"]),
    ]

    private static let names: [String: String] = ["Dockerfile": "dockerfile", "Makefile": "makefile", "GNUmakefile": "makefile",
                                                  "Gemfile": "rb", "Rakefile": "rb", "Podfile": "rb", "CMakeLists.txt": "cmake"]

    static func of(_ url: URL?) -> CommentSyntax? {
        guard let url else { return nil }
        let name = url.lastPathComponent
        var key = names[name] ?? url.pathExtension.lowercased()
        if key.isEmpty, name.hasPrefix(".") { key = String(name.dropFirst()).lowercased() }
        if name.hasPrefix(".env") { key = "env" }
        return table.first { $0.1.contains(key) }?.0
    }
}

enum CommentEdit {
    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    static func toggle(_ block: String, syntax: CommentSyntax) -> String {
        var lines = block.components(separatedBy: "\n")
        let trailing = block.hasSuffix("\n")
        if trailing { lines.removeLast() }
        let filled = lines.indices.filter { !isBlank(lines[$0]) }
        guard !filled.isEmpty else { return block }
        let result: [String]
        switch syntax {
        case .line(let token):
            let commented = filled.allSatisfy { lines[$0].dropFirst(indent(lines[$0])).hasPrefix(token) }
            if commented {
                result = lines.map { line in
                    guard !isBlank(line) else { return line }
                    let head = line.prefix(indent(line))
                    var rest = line.dropFirst(head.count).dropFirst(token.count)
                    if rest.first == " " { rest = rest.dropFirst() }
                    return String(head) + rest
                }
            } else {
                let column = filled.map { indent(lines[$0]) }.min() ?? 0
                result = lines.map { line in
                    isBlank(line) ? line : String(line.prefix(column)) + token + " " + line.dropFirst(column)
                }
            }
        case .block(let open, let close):
            let first = filled.first!, last = filled.last!
            var start = lines[first], end = lines[last]
            let head = start.prefix(indent(start))
            let trimmedEnd = end.reversed().drop { $0 == " " || $0 == "\t" }
            if start.dropFirst(head.count).hasPrefix(open), String(trimmedEnd.reversed()).hasSuffix(close),
               first != last || start.trimmingCharacters(in: .whitespaces).count >= open.count + close.count {
                var body = start.dropFirst(head.count).dropFirst(open.count)
                if body.first == " " { body = body.dropFirst() }
                start = String(head) + body
                lines[first] = start
                end = lines[last]
                let tail = end.reversed().prefix { $0 == " " || $0 == "\t" }.count
                var content = end.dropLast(tail).dropLast(close.count)
                if content.last == " " { content = content.dropLast() }
                lines[last] = String(content) + String(end.suffix(tail))
            } else {
                lines[first] = String(head) + open + " " + start.dropFirst(head.count)
                end = lines[last]
                let tail = end.reversed().prefix { $0 == " " || $0 == "\t" }.count
                lines[last] = String(end.dropLast(tail)) + " " + close + String(end.suffix(tail))
            }
            result = lines
        }
        return result.joined(separator: "\n") + (trailing ? "\n" : "")
    }
}

final class CommentToggleAddon: TextAddon, CommandProviding {
    static let pluginID = "comment-toggle"
    static var managed = false
    private weak var code: CodeEditing?
    private var monitor: Any?
    private var observer: Any?

    init(code: CodeEditing) {
        self.code = code
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !(Self.managed && event.window?.windowController is EditorWindowController), self.isFocused(in: event.window),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  event.charactersIgnoringModifiers == "/" || event.keyCode == 44 else { return event }
            self.toggle()
            return nil
        }
        observer = NotificationCenter.default.addObserver(forName: PluginEvent.toggleComment, object: nil, queue: .main) { [weak self] note in
            guard let self, self.isFocused(in: note.object as? NSWindow ?? NSApp.keyWindow) else { return }
            self.toggle()
        }
    }

    private func isFocused(in window: NSWindow?) -> Bool {
        guard let textView = code?.textView, let window, textView.window === window else { return false }
        return window.firstResponder === textView
    }

    var commands: [PaletteCommand] {
        [PaletteCommand(id: "comment-toggle.toggle", title: "コメントの切り替え", detail: "⌘/") { [weak self] in
            NotificationCenter.default.post(name: PluginEvent.toggleComment, object: self?.code?.textView.window)
        }]
    }

    private func toggle() {
        guard let code, code.textView.isEditable else { return }
        let textView = code.textView
        guard let syntax = CommentSyntax.of(code.fileURL) else { return NSSound.beep() }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        var covered = selection
        if covered.length > 0, text.character(at: NSMaxRange(covered) - 1) == 0x0A { covered.length -= 1 }
        let range = text.lineRange(for: covered)
        let old = text.substring(with: range)
        let new = CommentEdit.toggle(old, syntax: syntax)
        guard new != old, textView.shouldChangeText(in: range, replacementString: new) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: new)
        textView.didChangeText()
        textView.undoManager?.setActionName("コメントの切り替え")
        let length = (new as NSString).length
        if selection.length == 0 {
            let firstOld = (old as NSString).lineRange(for: NSRange(location: 0, length: 0)).length
            let firstNew = (new as NSString).lineRange(for: NSRange(location: 0, length: 0)).length
            let content = firstNew - ((new as NSString).substring(to: firstNew).hasSuffix("\n") ? 1 : 0)
            let moved = max(0, min(selection.location - range.location + firstNew - firstOld, content))
            textView.setSelectedRange(NSRange(location: range.location + moved, length: 0))
        } else {
            let trailing = new.hasSuffix("\n") && !(text.substring(with: selection) as String).hasSuffix("\n") ? 1 : 0
            textView.setSelectedRange(NSRange(location: range.location, length: length - trailing))
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        monitor = nil
        observer = nil
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(CommentTogglePlugin()) }
