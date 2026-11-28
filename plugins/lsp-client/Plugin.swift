import AppKit
@testable import FlareStackIDE

final class LSPClientPlugin: NativePlugin {
    static let pluginID = "lsp-client"
    let id = pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { LSPTextAddon(code: code) }
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { LSPWindowAddon(editor: editor) }
}

enum LSPText {
    static func lineStarts(_ text: NSString) -> [Int] { LineIndex.starts(text) }

    static func offset(_ position: [String: Any]?, in text: NSString, starts: [Int]) -> Int {
        let line = (position?["line"] as? NSNumber)?.intValue ?? 0
        let character = (position?["character"] as? NSNumber)?.intValue ?? 0
        guard line < starts.count else { return text.length }
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : text.length
        return min(starts[max(line, 0)] + max(character, 0), max(end, starts[max(line, 0)]))
    }

    static func range(_ range: [String: Any]?, in text: NSString, starts: [Int]) -> NSRange {
        let start = offset(range?["start"] as? [String: Any], in: text, starts: starts)
        let end = max(offset(range?["end"] as? [String: Any], in: text, starts: starts), start)
        return NSRange(location: start, length: end - start)
    }

    static func position(_ offset: Int, in text: NSString) -> [String: Int] {
        let found = LineIndex.position(of: offset, in: text)
        return ["line": found.line, "character": found.character]
    }

    static func url(_ uri: String?) -> URL? {
        guard let uri, let url = URL(string: uri), url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    static func markdown(_ contents: Any?) -> String {
        if let text = contents as? String { return text }
        if let object = contents as? [String: Any] {
            let value = object["value"] as? String ?? ""
            if let language = object["language"] as? String { return "```\(language)\n\(value)\n```" }
            return value
        }
        if let list = contents as? [Any] { return list.map(markdown).filter { !$0.isEmpty }.joined(separator: "\n\n") }
        return ""
    }
}

final class LSPDocument {
    let url: URL
    let server: LSPServer
    var version = 1
    var text: String
    var refs = 1

    init(url: URL, server: LSPServer, text: String) {
        self.url = url
        self.server = server
        self.text = text
    }

    var uri: String { url.absoluteString }
}

enum LSPHub {
    static let completionItems = PluginEvent.completionItems
    static let diagnosticsChanged = Notification.Name("LSPClient.diagnosticsChanged")
    static let externalDiagnostics = PluginEvent.externalDiagnostics
    static let lspFiles = PluginEvent.lspFiles
    static let lspFilesRequest = PluginEvent.lspFilesRequest
    static let hoverShown = PluginEvent.hoverShown
    static let reopen = Notification.Name("LSPClient.reopen")
    private static var scannerCache: Bool?
    private static var servers: [String: LSPServer] = [:]
    private static var missing: Set<String> = []
    private(set) static var documents: [String: LSPDocument] = [:]
    private(set) static var diagnostics: [String: [(range: NSRange, severity: Int, message: String, source: String)]] = [:]
    private(set) static var rawDiagnostics: [String: [[String: Any]]] = [:]
    private static var installed = false
    private static let convertQueue = DispatchQueue(label: "\(appName).lsp.diagnostics", qos: .userInitiated)

    static func install() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        center.addObserver(forName: lspFilesRequest, object: nil, queue: .main) { _ in postFiles() }
        center.addObserver(forName: .pluginsChanged, object: nil, queue: .main) { _ in scannerCache = nil }
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            servers.values.forEach { $0.stop() }
        }
    }

    static var codeScannerActive: Bool {
        if let scannerCache { return scannerCache }
        let active = PluginStore.isInstalled("code-scanner")
        scannerCache = active
        return active
    }

    private static func key(_ root: URL, _ language: String) -> String { language + ":" + root.standardizedFileURL.path }

    private static func command(for spec: LSPServerSpec, custom: String?) -> [String]? {
        if let custom = custom?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            let parts = custom.split(separator: " ").map(String.init)
            return LoginShell.which(parts[0]).map { [$0] + parts.dropFirst() }
        }
        for candidate in spec.candidates {
            if let path = LoginShell.which(candidate[0]) { return [path] + candidate.dropFirst() }
        }
        return nil
    }

    static func server(for url: URL, root: URL) -> LSPServer? {
        guard let spec = LSPLanguage.server(for: url), let language = LSPLanguage.language(for: url) else { return nil }
        let id = key(root, spec.id)
        if let server = servers[id] { return server }
        guard !missing.contains(id) else { return nil }
        let custom = PluginStore.setting(LSPClientPlugin.pluginID, spec.setting)
        let server = LSPServer(root: root, language: language)
        server.onNotification = { [weak server] method, params in
            if method == "textDocument/publishDiagnostics", let server { publish(params, from: server) }
        }
        server.onFailure = { [weak server] in
            guard let server, servers[id] === server else { return }
            servers[id] = nil
            missing.insert(id)
            documents = documents.filter { $0.value.server !== server }
            postFiles()
            Toasts.post("\(spec.name) の言語サーバーが見つかりません", message: "ターミナルで \(spec.install) を実行してから、プロジェクトを開き直してください")
        }
        server.onApplyEdit = { edit in
            guard let editor = NSApp.keyWindow?.windowController as? EditorWindowController else { return false }
            return LSPEdits.apply(edit, editor: editor, message: "コードを変更しました")
        }
        server.onExit = { [weak server] in
            guard let server else { return }
            servers[id] = nil
            documents = documents.filter { $0.value.server !== server }
            postFiles()
            Toasts.post("\(server.displayName) が終了しました", message: "ファイルを開き直すと再起動します")
        }
        servers[id] = server
        let swift = spec.id == "swift"
        server.start {
            guard let command = command(for: spec, custom: custom) else { return nil }
            return swift ? command + SwiftWorkspace.arguments(root: root) : command
        }
        return server
    }

    static func open(_ url: URL, text: String, root: URL) -> LSPDocument? {
        let url = url.standardizedFileURL
        if let doc = documents[url.path] {
            doc.refs += 1
            return doc
        }
        guard let server = server(for: url, root: root), let language = LSPLanguage.language(for: url) else { return nil }
        let doc = LSPDocument(url: url, server: server, text: text)
        documents[url.path] = doc
        server.notify("textDocument/didOpen", ["textDocument": ["uri": doc.uri, "languageId": language, "version": doc.version, "text": text]])
        postFiles()
        return doc
    }

    static func change(_ doc: LSPDocument, text: String) {
        guard doc.text != text else { return }
        doc.text = text
        doc.version += 1
        doc.server.notify("textDocument/didChange", ["textDocument": ["uri": doc.uri, "version": doc.version], "contentChanges": [["text": text]]])
    }

    static func close(_ doc: LSPDocument) {
        doc.refs -= 1
        guard doc.refs <= 0 else { return }
        documents[doc.url.path] = nil
        diagnostics[doc.url.path] = nil
        rawDiagnostics[doc.url.path] = nil
        doc.server.notify("textDocument/didClose", ["textDocument": ["uri": doc.uri]])
        NotificationCenter.default.post(name: externalDiagnostics, object: doc.url, userInfo: ["items": [[String: Any]]()])
        postFiles()
    }

    static func stopServers(root: URL) {
        let path = root.standardizedFileURL.path
        for (id, server) in servers where server.root.standardizedFileURL.path == path {
            server.stop()
            servers[id] = nil
            documents = documents.filter { $0.value.server !== server }
        }
        missing = missing.filter { !$0.hasSuffix(":" + path) }
        postFiles()
    }

    static func postFiles() {
        NotificationCenter.default.post(name: lspFiles, object: nil, userInfo: ["urls": documents.values.map(\.url)])
    }

    private static func publish(_ params: [String: Any], from server: LSPServer) {
        guard let url = LSPText.url(params["uri"] as? String), let doc = documents[url.path], doc.server === server else { return }
        if let version = (params["version"] as? NSNumber)?.intValue, version < doc.version { return }
        let text = doc.text
        let version = doc.version
        let name = server.displayName
        let raw = params["diagnostics"] as? [[String: Any]] ?? []
        convertQueue.async {
            let ns = text as NSString
            let starts = LSPText.lineStarts(ns)
            let items = raw.compactMap { item -> (range: NSRange, severity: Int, message: String, source: String)? in
                guard let message = item["message"] as? String else { return nil }
                let severity = (item["severity"] as? NSNumber)?.intValue ?? 1
                guard severity <= 2 else { return nil }
                let range = LSPText.range(item["range"] as? [String: Any], in: ns, starts: starts)
                return (range, severity, message, item["source"] as? String ?? name)
            }
            let payload: [[String: Any]] = items.map {
                ["start": $0.range.location, "length": $0.range.length, "severity": $0.severity == 1 ? "error" : "warning",
                 "message": $0.message, "source": $0.source]
            }
            DispatchQueue.main.async {
                guard documents[url.path] === doc, doc.version == version else { return }
                diagnostics[url.path] = items
                rawDiagnostics[url.path] = raw
                NotificationCenter.default.post(name: externalDiagnostics, object: url, userInfo: ["items": payload, "version": version])
                NotificationCenter.default.post(name: diagnosticsChanged, object: url)
            }
        }
    }
}

enum LSPEdits {
    @discardableResult
    static func apply(_ edit: [String: Any]?, editor: EditorWindowController?, message: String) -> Bool {
        var changes: [URL: [[String: Any]]] = [:]
        for (uri, edits) in edit?["changes"] as? [String: [[String: Any]]] ?? [:] {
            if let url = LSPText.url(uri) { changes[url, default: []] += edits }
        }
        for change in edit?["documentChanges"] as? [[String: Any]] ?? [] {
            guard let url = LSPText.url((change["textDocument"] as? [String: Any])?["uri"] as? String) else { continue }
            changes[url, default: []] += change["edits"] as? [[String: Any]] ?? []
        }
        let window = editor?.window
        guard !changes.isEmpty else {
            Toasts.post("変更できる箇所がありませんでした", in: window)
            return false
        }
        if let editor, let error = editor.saveAll() {
            editor.showError(error)
            return false
        }
        var originals: [URL: String] = [:]
        var count = 0
        for (url, edits) in changes {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let ns = NSMutableString(string: text)
            let starts = LSPText.lineStarts(text as NSString)
            let ranges = edits.map { (LSPText.range($0["range"] as? [String: Any], in: text as NSString, starts: starts), $0["newText"] as? String ?? "") }
            for (range, replacement) in ranges.sorted(by: { $0.0.location > $1.0.location }) where NSMaxRange(range) <= ns.length {
                ns.replaceCharacters(in: range, with: replacement)
                count += 1
            }
            do {
                try (ns as String).write(to: url, atomically: false, encoding: .utf8)
                originals[url] = text
            } catch {
                Toasts.post("\(url.lastPathComponent) に書き込めませんでした", message: error.localizedDescription, in: window)
            }
        }
        editor?.reloadExternal(Set(originals.keys.map(\.path)))
        Toasts.post(message, message: "\(originals.count) ファイル・\(count) 箇所",
                    actions: [("元に戻す", { [weak editor] in restore(originals, editor: editor) })], in: window)
        return !originals.isEmpty
    }

    private static func restore(_ originals: [URL: String], editor: EditorWindowController?) {
        if let editor, let error = editor.saveAll() { return editor.showError(error) }
        for (url, text) in originals { try? text.write(to: url, atomically: false, encoding: .utf8) }
        editor?.reloadExternal(Set(originals.keys.map(\.path)))
    }
}

final class LSPHintLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class LSPPopup: NSView {
    private static let maxWidth: CGFloat = 520

    init(_ text: NSAttributedString) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 6, height: 4)
        view.textStorage?.setAttributedString(text)
        view.textContainer?.containerSize = NSSize(width: Self.maxWidth - 12, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let used = view.layoutManager?.usedRect(for: view.textContainer!).size ?? .zero
        let size = NSSize(width: min(ceil(used.width) + 14, Self.maxWidth), height: min(ceil(used.height) + 10, 320))
        view.frame = NSRect(origin: .zero, size: size)
        frame.size = size
        let scroll = NSScrollView(frame: bounds)
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = used.height + 10 > 320
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class LSPTextAddon: NSObject, TextAddon, TextDecorating, CommandProviding {
    private static let hoverDelay: TimeInterval = 1.0
    private weak var code: CodeEditing?
    private var doc: LSPDocument?
    private var changeWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var hoverRequest: Int?
    private var completionRequest: Int?
    private var popup: NSView?
    private var hoverIndex: Int?
    private var monitors: [Any] = []
    private var lastTyped: String?
    private var bulb: NSButton?
    private var signaturePopup: NSView?
    private var signatureRequest: Int?
    private var hintWork: DispatchWorkItem?
    private var hintRequest: Int?
    private var hintLabels: [NSTextField] = []

    init(code: CodeEditing) {
        self.code = code
        super.init()
        LSPHub.install()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(diagnosticsChanged(_:)), name: LSPHub.diagnosticsChanged, object: nil)
        center.addObserver(self, selector: #selector(otherHover(_:)), name: LSPHub.hoverShown, object: code.textView)
        center.addObserver(self, selector: #selector(hideHover), name: NSView.boundsDidChangeNotification, object: code.scrollView.contentView)
        center.addObserver(self, selector: #selector(reopen), name: LSPHub.reopen, object: nil)
        center.addObserver(self, selector: #selector(updateBulb), name: NSView.boundsDidChangeNotification, object: code.scrollView.contentView)
        center.addObserver(self, selector: #selector(symbolsRequested(_:)), name: PluginEvent.symbolsRequest, object: nil)
        center.addObserver(self, selector: #selector(hideSignature), name: NSView.boundsDidChangeNotification, object: code.scrollView.contentView)
        center.addObserver(self, selector: #selector(scheduleHints), name: NSView.boundsDidChangeNotification, object: code.scrollView.contentView)
        center.addObserver(self, selector: #selector(scheduleHints), name: .settingsChanged, object: nil)
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel, .keyDown, .leftMouseDown], handler: { [weak self] in
            self?.handle($0) ?? $0
        }) { monitors.append(monitor) }
        fileOpened()
    }

    private var editor: EditorWindowController? { code?.textView.window?.windowController as? EditorWindowController }

    private var root: URL? {
        code?.projectDirectory ?? editor?.baseDirectory ?? code?.fileURL?.deletingLastPathComponent()
    }

    @objc private func reopen() {
        doc = nil
        fileOpened()
    }

    func fileOpened() {
        hideHover()
        removeBulb()
        if let doc, LSPHub.documents[doc.url.path] !== doc { self.doc = nil }
        if let doc, doc.url != code?.fileURL?.standardizedFileURL {
            LSPHub.close(doc)
            self.doc = nil
        }
        guard doc == nil, let code, let url = code.fileURL, LSPLanguage.language(for: url) != nil, let root else { return redraw() }
        doc = LSPHub.open(url, text: code.textView.string, root: root)
        redraw()
        scheduleHints()
    }

    func shouldChange(_ range: NSRange, text: String) -> Bool {
        lastTyped = text
        return true
    }

    func textChanged() {
        hideHover()
        guard doc != nil else { return }
        scheduleHints()
        if let typed = lastTyped {
            if typed == "(" || typed == "()" || typed == "," {
                DispatchQueue.main.async { [weak self] in self?.requestSignature() }
            } else if typed == ")" || typed.contains("\n") {
                hideSignature()
            }
        }
        changeWork?.cancel()
        let typed = lastTyped
        lastTyped = nil
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        changeWork = item
        if let typed, typed.utf16.count == 1, typed.range(of: #"^[A-Za-z0-9_.]$"#, options: .regularExpression) != nil {
            flush()
            requestCompletion()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
        }
    }

    private func flush() {
        changeWork?.cancel()
        guard let doc, let text = code?.textView.string else { return }
        LSPHub.change(doc, text: text)
    }

    private func params(at offset: Int) -> [String: Any]? {
        guard let doc else { return nil }
        flush()
        return ["textDocument": ["uri": doc.uri], "position": LSPText.position(offset, in: doc.text as NSString)]
    }

    private func requestCompletion() {
        guard let doc, let textView = code?.textView else { return }
        let caret = textView.selectedRange().location
        guard let params = params(at: caret) else { return }
        if let completionRequest { doc.server.cancel(completionRequest) }
        completionRequest = doc.server.request("textDocument/completion", params) { [weak self, weak textView] result in
            guard let self, let textView, textView.selectedRange().location == caret else { return }
            self.completionRequest = nil
            let list = (result as? [[String: Any]]) ?? ((result as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            let words = list.compactMap { item -> String? in
                let word = (item["insertText"] as? String) ?? (item["label"] as? String) ?? ""
                return word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil ? word : nil
            }
            NotificationCenter.default.post(name: LSPHub.completionItems, object: textView,
                                            userInfo: ["items": Array(words.prefix(200)), "location": caret])
        }
    }

    private func index(at event: NSEvent) -> Int? {
        guard let textView = code?.textView, event.window === textView.window, let scroll = textView.enclosingScrollView,
              let layout = textView.layoutManager, let container = textView.textContainer,
              scroll.contentView.bounds.contains(scroll.contentView.convert(event.locationInWindow, from: nil)) else { return nil }
        let point = textView.convert(event.locationInWindow, from: nil)
        let inner = NSPoint(x: point.x - textView.textContainerOrigin.x, y: point.y - textView.textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: inner, in: container)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -1, dy: -1).contains(inner) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard doc != nil, let textView = code?.textView, event.window === textView.window else { return event }
        switch event.type {
        case .mouseMoved:
            mouseMoved(event)
        case .leftMouseDown:
            hideHover()
            hideSignature()
            if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command, let index = index(at: event) {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: index, length: 0))
                goToDefinition()
                return nil
            }
        case .keyDown:
            hideHover()
            guard textView.window?.firstResponder === textView else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53, signaturePopup != nil {
                hideSignature()
                return nil
            }
            switch (event.keyCode, flags) {
            case (111, []): goToDefinition()
            case (111, .shift): findReferences()
            case (120, []): rename()
            case (36, .option): quickFix()
            default: return event
            }
            return nil
        default:
            hideHover()
        }
        return event
    }

    private func mouseMoved(_ event: NSEvent) {
        let found = index(at: event)
        guard found != hoverIndex || popup == nil else { return }
        if let found, let hoverIndex, popup != nil, wordRange(at: found) == wordRange(at: hoverIndex) { return }
        hideHover()
        guard let found else { return }
        hoverIndex = found
        let item = DispatchWorkItem { [weak self] in self?.requestHover(found) }
        hoverWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: item)
    }

    private func wordRange(at index: Int) -> NSRange? {
        guard let text = code?.textView.string as NSString?, index < text.length else { return nil }
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let isWord = { (i: Int) in UnicodeScalar(text.character(at: i)).map(word.contains) ?? false }
        guard isWord(index) else { return NSRange(location: index, length: 1) }
        var start = index, end = index
        while start > 0, isWord(start - 1) { start -= 1 }
        while end < text.length, isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private func diagnostics(at index: Int) -> [(range: NSRange, severity: Int, message: String, source: String)] {
        guard let doc else { return [] }
        return (LSPHub.diagnostics[doc.url.path] ?? []).filter { NSLocationInRange(index, $0.range) || ($0.range.length == 0 && $0.range.location == index) }
    }

    private func requestHover(_ index: Int) {
        guard let doc, let params = params(at: index) else { return }
        let issues = diagnostics(at: index)
        hoverRequest = doc.server.request("textDocument/hover", params) { [weak self] result in
            guard let self, self.hoverIndex == index else { return }
            self.hoverRequest = nil
            let markdown = LSPText.markdown((result as? [String: Any])?["contents"])
            self.showHover(at: index, issues: issues, markdown: markdown)
        }
    }

    private func showHover(at index: Int, issues: [(range: NSRange, severity: Int, message: String, source: String)], markdown: String) {
        guard !issues.isEmpty || !markdown.isEmpty, let textView = code?.textView, let content = textView.window?.contentView,
              let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 11)
        for issue in issues {
            let label = issue.severity == 1 ? "エラー" : "警告"
            text.append(NSAttributedString(string: "\(label): \(issue.message)（\(issue.source)）\n", attributes: [
                .font: font, .foregroundColor: issue.severity == 1 ? NSColor.systemRed : NSColor.systemOrange]))
        }
        if !markdown.isEmpty {
            if !issues.isEmpty { text.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            text.append(renderMarkdown(markdown))
        }
        while text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        let range = wordRange(at: index) ?? NSRange(location: index, length: 1)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let anchor = textView.convert(rect, to: content)
        let view = LSPPopup(text)
        var y = anchor.minY - view.frame.height - 3
        if y < 4 { y = anchor.maxY + 3 }
        view.setFrameOrigin(NSPoint(x: max(min(anchor.minX, content.bounds.maxX - view.frame.width - 6), 6), y: y))
        content.addSubview(view, positioned: .above, relativeTo: nil)
        popup = view
        NotificationCenter.default.post(name: LSPHub.hoverShown, object: textView, userInfo: ["from": LSPClientPlugin.pluginID])
    }

    @objc private func otherHover(_ note: Notification) {
        if note.userInfo?["from"] as? String != LSPClientPlugin.pluginID { hideHover() }
    }

    @objc private func hideHover() {
        hoverWork?.cancel()
        hoverWork = nil
        if let hoverRequest { doc?.server.cancel(hoverRequest) }
        hoverRequest = nil
        hoverIndex = nil
        popup?.removeFromSuperview()
        popup = nil
    }

    private static func locations(_ result: Any?) -> [(url: URL, range: [String: Any])] {
        let list: [[String: Any]] = (result as? [[String: Any]]) ?? ((result as? [String: Any]).map { [$0] } ?? [])
        return list.compactMap { item in
            let uri = (item["uri"] as? String) ?? (item["targetUri"] as? String)
            let range = (item["range"] as? [String: Any]) ?? (item["targetSelectionRange"] as? [String: Any]) ?? (item["targetRange"] as? [String: Any])
            guard let url = LSPText.url(uri), let range else { return nil }
            return (url, range)
        }
    }

    private func requestSignature() {
        guard let doc, let textView = code?.textView, doc.server.capabilities["signatureHelpProvider"] != nil else { return }
        let caret = textView.selectedRange().location
        guard let params = params(at: caret) else { return }
        if let signatureRequest { doc.server.cancel(signatureRequest) }
        signatureRequest = doc.server.request("textDocument/signatureHelp", params) { [weak self, weak textView] result in
            guard let self, let textView, textView.selectedRange().location == caret else { return }
            self.signatureRequest = nil
            self.showSignature(result as? [String: Any], at: caret)
        }
    }

    private func signatureText(_ help: [String: Any]) -> NSAttributedString? {
        guard let signatures = help["signatures"] as? [[String: Any]], !signatures.isEmpty else { return nil }
        let active = min(max(help["activeSignature"] as? Int ?? 0, 0), signatures.count - 1)
        let signature = signatures[active]
        guard let label = signature["label"] as? String else { return nil }
        let font = NSFont.monospacedSystemFont(ofSize: max(Settings.fontSize - 1, 10), weight: .regular)
        let text = NSMutableAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let parameters = signature["parameters"] as? [[String: Any]] ?? []
        let index = signature["activeParameter"] as? Int ?? help["activeParameter"] as? Int ?? 0
        if parameters.indices.contains(index) {
            var range: NSRange?
            if let offsets = parameters[index]["label"] as? [Int], offsets.count == 2 {
                range = NSRange(location: offsets[0], length: offsets[1] - offsets[0])
            } else if let name = parameters[index]["label"] as? String {
                let found = (label as NSString).range(of: name)
                range = found.location == NSNotFound ? nil : found
            }
            if let range, NSMaxRange(range) <= text.length {
                text.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold),
                                    .foregroundColor: NSColor.controlAccentColor], range: range)
            }
        }
        if signatures.count > 1 {
            text.append(NSAttributedString(string: "  (\(active + 1)/\(signatures.count))",
                                           attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return text
    }

    private func showSignature(_ help: [String: Any]?, at caret: Int) {
        hideSignature()
        guard let help, let text = signatureText(help), let textView = code?.textView, let content = textView.window?.contentView,
              let layout = textView.layoutManager, let container = textView.textContainer, caret <= (textView.string as NSString).length else { return }
        let glyph = layout.glyphIndexForCharacter(at: max(caret - 1, 0))
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let anchor = textView.convert(rect, to: content)
        let view = LSPPopup(text)
        var y = anchor.maxY + 3
        if y + view.frame.height > content.bounds.maxY - 4 { y = anchor.minY - view.frame.height - 3 }
        view.setFrameOrigin(NSPoint(x: max(min(anchor.minX, content.bounds.maxX - view.frame.width - 6), 6), y: y))
        content.addSubview(view, positioned: .above, relativeTo: nil)
        signaturePopup = view
    }

    @objc private func hideSignature() {
        if let signatureRequest { doc?.server.cancel(signatureRequest) }
        signatureRequest = nil
        signaturePopup?.removeFromSuperview()
        signaturePopup = nil
    }

    private var hintsEnabled: Bool { PluginStore.setting(LSPClientPlugin.pluginID, "inlayHints") == "true" }

    @objc private func scheduleHints() {
        hintWork?.cancel()
        guard hintsEnabled, doc != nil else { return clearHints() }
        let item = DispatchWorkItem { [weak self] in self?.requestHints() }
        hintWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func requestHints() {
        guard let doc, let textView = code?.textView, let layout = textView.layoutManager, let container = textView.textContainer,
              doc.server.capabilities["inlayHintProvider"] != nil else { return clearHints() }
        flush()
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let text = doc.text as NSString
        guard NSMaxRange(chars) <= text.length else { return }
        let params: [String: Any] = ["textDocument": ["uri": doc.uri],
                                     "range": ["start": LSPText.position(chars.location, in: text),
                                               "end": LSPText.position(NSMaxRange(chars), in: text)]]
        if let hintRequest { doc.server.cancel(hintRequest) }
        let version = doc.version
        hintRequest = doc.server.request("textDocument/inlayHint", params) { [weak self] result in
            guard let self, let doc = self.doc, doc.version == version else { return }
            self.hintRequest = nil
            self.showHints(result as? [[String: Any]] ?? [], in: doc.text as NSString)
        }
    }

    private static func hintLabel(_ hint: [String: Any]) -> String {
        if let label = hint["label"] as? String { return label.trimmingCharacters(in: .whitespaces) }
        let parts = hint["label"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["value"] as? String }.joined().trimmingCharacters(in: .whitespaces)
    }

    private func showHints(_ hints: [[String: Any]], in text: NSString) {
        clearHints()
        guard hintsEnabled, let textView = code?.textView, let layout = textView.layoutManager,
              (textView.string as NSString).length == text.length else { return }
        let starts = LSPText.lineStarts(text)
        var lines: [Int: [String]] = [:]
        for hint in hints {
            let offset = LSPText.offset(hint["position"] as? [String: Any], in: text, starts: starts)
            let label = Self.hintLabel(hint)
            guard !label.isEmpty, offset <= text.length else { continue }
            let line = text.lineRange(for: NSRange(location: min(offset, max(text.length - 1, 0)), length: 0))
            lines[line.location, default: []].append(label)
        }
        let font = NSFont.monospacedSystemFont(ofSize: max(Settings.fontSize - 1, 9), weight: .regular)
        let origin = textView.textContainerOrigin
        for (start, labels) in lines {
            var content = text.lineRange(for: NSRange(location: start, length: 0))
            while content.length > 0, "\r\n".contains(text.substring(with: NSRange(location: NSMaxRange(content) - 1, length: 1))) { content.length -= 1 }
            let last = max(NSMaxRange(content) - 1, content.location)
            guard last < text.length else { continue }
            let glyph = layout.glyphIndexForCharacter(at: last)
            guard layout.propertyForGlyph(at: glyph) != .null else { continue }
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let label = LSPHintLabel(labelWithString: labels.joined(separator: "  "))
            label.font = font
            label.textColor = .tertiaryLabelColor
            label.sizeToFit()
            label.frame.origin = NSPoint(x: origin.x + used.maxX + 16, y: origin.y + used.minY + (used.height - label.frame.height) / 2)
            textView.addSubview(label)
            hintLabels.append(label)
        }
    }

    private func clearHints() {
        hintLabels.forEach { $0.removeFromSuperview() }
        hintLabels = []
    }

    private func text(of url: URL) -> String? {
        if let doc = LSPHub.documents[url.path] { return doc.text }
        if let open = code?.openTexts.first(where: { $0.url.standardizedFileURL == url }) { return open.text }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func resolve(_ location: (url: URL, range: [String: Any])) -> (url: URL, range: NSRange, line: Int, snippet: String)? {
        guard let text = text(of: location.url) as NSString? else { return nil }
        let starts = LSPText.lineStarts(text)
        let range = LSPText.range(location.range, in: text, starts: starts)
        let line = ((location.range["start"] as? [String: Any])?["line"] as? NSNumber)?.intValue ?? 0
        let snippet = text.substring(with: text.lineRange(for: NSRange(location: range.location, length: 0))).trimmingCharacters(in: .whitespacesAndNewlines)
        return (location.url, range, line + 1, snippet)
    }

    private func reveal(_ url: URL, _ range: NSRange) {
        if let code, code.fileURL?.standardizedFileURL == url {
            code.textView.window?.makeFirstResponder(code.textView)
            code.textView.setSelectedRange(range)
            CodeView.center(code.textView, on: range)
            code.textView.showFindIndicator(for: range)
        } else {
            editor?.reveal(url, range: range)
        }
    }

    private func goToDefinition() {
        guard let doc, let caret = code?.textView.selectedRange().location, let params = params(at: caret) else { return }
        doc.server.request("textDocument/definition", params) { [weak self] result in
            guard let self else { return }
            guard let target = Self.locations(result).first.flatMap(self.resolve) else {
                Toasts.post("定義が見つかりませんでした", in: self.code?.textView.window)
                return
            }
            self.reveal(target.url, target.range)
        }
    }

    private func findReferences() {
        guard let doc, let textView = code?.textView, let params = params(at: textView.selectedRange().location) else { return }
        var request = params
        request["context"] = ["includeDeclaration": true]
        doc.server.request("textDocument/references", request) { [weak self, weak textView] result in
            guard let self, let textView else { return }
            let found = Self.locations(result).compactMap(self.resolve)
            guard !found.isEmpty else {
                Toasts.post("参照が見つかりませんでした", in: textView.window)
                return
            }
            let menu = NSMenu()
            let header = NSMenuItem(title: "参照 \(found.count) 件", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for item in found.prefix(100) {
                let title = "\(item.url.lastPathComponent):\(item.line)　\(item.snippet.prefix(80))"
                let entry = NSMenuItem(title: title, action: #selector(self.referenceChosen(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = [item.url, NSValue(range: item.range)]
                menu.addItem(entry)
            }
            let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
            let point = textView.window?.convertPoint(fromScreen: NSPoint(x: caret.minX, y: caret.minY)) ?? .zero
            menu.popUp(positioning: nil, at: textView.convert(point, from: nil), in: textView)
        }
    }

    @objc private func referenceChosen(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], let url = pair.first as? URL, let range = (pair.last as? NSValue)?.rangeValue else { return }
        reveal(url, range)
    }

    private func rename() {
        guard let doc, let textView = code?.textView else { return }
        let caret = textView.selectedRange().location
        guard let word = wordRange(at: caret > 0 && wordRange(at: caret)?.length == 1 ? caret - 1 : caret), word.length > 0 else { return }
        let old = (textView.string as NSString).substring(with: word)
        let alert = NSAlert()
        alert.messageText = "名前の変更"
        alert.informativeText = "「\(old)」をプロジェクト全体で変更します。開いているファイルは先に保存します。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = old
        alert.accessoryView = field
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old, var params = params(at: word.location) else { return }
        params["newName"] = name
        doc.server.request("textDocument/rename", params) { [weak self] result in
            guard let self else { return }
            LSPEdits.apply(result as? [String: Any], editor: self.editor, message: "「\(name)」に名前を変更しました")
        }
    }

    @objc private func diagnosticsChanged(_ note: Notification) {
        guard let url = note.object as? URL, url == doc?.url else { return }
        redraw()
        updateBulb()
    }

    func selectionChanged() { updateBulb() }

    @objc private func updateBulb() {
        guard let doc, let textView = code?.textView, let layout = textView.layoutManager, layout.numberOfGlyphs > 0 else { return removeBulb() }
        let text = textView.string as NSString
        let caret = min(textView.selectedRange().location, text.length)
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let hit = (LSPHub.diagnostics[doc.url.path] ?? []).contains {
            NSIntersectionRange($0.range, line).length > 0 || NSLocationInRange($0.range.location, line)
        }
        guard hit, line.location < text.length else { return removeBulb() }
        let glyph = layout.glyphIndexForCharacter(at: line.location)
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let button = bulb ?? makeBulb()
        let size: CGFloat = 16
        button.frame = NSRect(x: textView.visibleRect.maxX - size - 6, y: rect.midY - size / 2, width: size, height: size)
        if button.superview !== textView { textView.addSubview(button) }
    }

    private func makeBulb() -> NSButton {
        let image = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: "クイックフィックス") ?? NSImage()
        let button = NSButton(image: image, target: self, action: #selector(bulbClicked))
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .systemYellow
        button.toolTip = "クイックフィックス（⌥↩）"
        bulb = button
        return button
    }

    private func removeBulb() { bulb?.removeFromSuperview() }

    @objc private func bulbClicked() {
        code?.textView.window?.makeFirstResponder(code?.textView)
        quickFix()
    }

    private func quickFix() {
        guard let doc, let textView = code?.textView else { return }
        flush()
        let text = doc.text as NSString
        let selection = textView.selectedRange()
        var range = selection
        if range.length == 0 {
            let line = text.lineRange(for: NSRange(location: min(selection.location, text.length), length: 0))
            range = NSRange(location: line.location, length: line.length - (text.substring(with: line).hasSuffix("\n") ? 1 : 0))
        }
        let starts = LSPText.lineStarts(text)
        let related = (LSPHub.rawDiagnostics[doc.url.path] ?? []).filter { item in
            let found = LSPText.range(item["range"] as? [String: Any], in: text, starts: starts)
            return NSIntersectionRange(found, range).length > 0 || NSLocationInRange(found.location, range) || found.location == NSMaxRange(range)
        }
        let params: [String: Any] = [
            "textDocument": ["uri": doc.uri],
            "range": ["start": LSPText.position(range.location, in: text), "end": LSPText.position(NSMaxRange(range), in: text)],
            "context": ["diagnostics": related, "triggerKind": 1] as [String: Any],
        ]
        doc.server.request("textDocument/codeAction", params) { [weak self, weak textView] result in
            guard let self, let textView else { return }
            let actions = (result as? [[String: Any]] ?? []).filter { $0["disabled"] == nil && $0["title"] is String }
            let preferred = actions.filter { $0["isPreferred"] as? Bool == true }
            let ordered = preferred + actions.filter { $0["isPreferred"] as? Bool != true }
            guard !ordered.isEmpty else {
                Toasts.post("修正の候補はありません", in: textView.window)
                return
            }
            let menu = NSMenu()
            let header = NSMenuItem(title: "クイックフィックス", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for action in ordered.prefix(50) {
                let item = NSMenuItem(title: action["title"] as? String ?? "", action: #selector(self.actionChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action
                if action["isPreferred"] as? Bool == true { item.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil) }
                menu.addItem(item)
            }
            let caret = textView.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
            let point = textView.window?.convertPoint(fromScreen: NSPoint(x: caret.minX, y: caret.minY)) ?? .zero
            menu.popUp(positioning: nil, at: textView.convert(point, from: nil), in: textView)
        }
    }

    @objc private func actionChosen(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? [String: Any], let server = doc?.server else { return }
        perform(action, server: server, resolved: false)
    }

    private func perform(_ action: [String: Any], server: LSPServer, resolved: Bool) {
        if let command = action["command"] as? String {
            return execute(["command": command, "arguments": action["arguments"] ?? []], server: server)
        }
        let title = action["title"] as? String ?? ""
        if let edit = action["edit"] as? [String: Any] {
            LSPEdits.apply(edit, editor: editor, message: "「\(title)」を適用しました")
        } else if !resolved, action["data"] != nil,
                  (server.capabilities["codeActionProvider"] as? [String: Any])?["resolveProvider"] as? Bool == true {
            server.request("codeAction/resolve", action) { [weak self] result in
                guard let self, let resolved = result as? [String: Any] else { return }
                self.perform(resolved, server: server, resolved: true)
            }
            return
        }
        if let command = action["command"] as? [String: Any] { execute(command, server: server) }
    }

    private func execute(_ command: [String: Any], server: LSPServer) {
        server.request("workspace/executeCommand", ["command": command["command"] ?? "", "arguments": command["arguments"] ?? []]) { _ in }
    }

    @objc private func symbolsRequested(_ note: Notification) {
        guard let doc, let url = note.object as? URL, url.standardizedFileURL == doc.url else { return }
        flush()
        let text = doc.text as NSString
        let version = doc.version
        doc.server.request("textDocument/documentSymbol", ["textDocument": ["uri": doc.uri]]) { result in
            let starts = LSPText.lineStarts(text)
            func convert(_ item: [String: Any]) -> [String: Any]? {
                guard let name = item["name"] as? String else { return nil }
                let raw = (item["range"] as? [String: Any]) ?? ((item["location"] as? [String: Any])?["range"] as? [String: Any])
                let range = LSPText.range(raw, in: text, starts: starts)
                let selection = (item["selectionRange"] as? [String: Any]).map { LSPText.range($0, in: text, starts: starts).location } ?? range.location
                return ["name": name, "kind": (item["kind"] as? NSNumber)?.intValue ?? 0,
                        "detail": item["detail"] as? String ?? item["containerName"] as? String ?? "",
                        "start": range.location, "length": range.length, "selection": selection,
                        "children": (item["children"] as? [[String: Any]] ?? []).compactMap(convert)]
            }
            let items = (result as? [[String: Any]] ?? []).compactMap(convert)
            NotificationCenter.default.post(name: PluginEvent.symbols, object: doc.url, userInfo: ["items": items, "version": version])
        }
    }

    private func redraw() {
        guard let textView = code?.textView, let layout = textView.layoutManager else { return }
        decorate(layout)
        textView.needsDisplay = true
    }

    func decorate(_ layout: NSLayoutManager) {
        guard let storage = layout.textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: all)
        guard let doc, !LSPHub.codeScannerActive else { return }
        for item in LSPHub.diagnostics[doc.url.path] ?? [] {
            let range = item.range.length == 0 ? NSRange(location: item.range.location, length: 1) : item.range
            guard NSMaxRange(range) <= storage.length else { continue }
            layout.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                           .underlineColor: item.severity == 1 ? NSColor.systemRed : NSColor.systemYellow], forCharacterRange: range)
        }
    }

    var commands: [PaletteCommand] {
        guard doc != nil else { return [] }
        return [
            PaletteCommand(id: "lsp.definition", title: "LSP: 定義へ移動", detail: "F12 / ⌘クリック") { [weak self] in self?.goToDefinition() },
            PaletteCommand(id: "lsp.references", title: "LSP: 参照を検索", detail: "⇧F12") { [weak self] in self?.findReferences() },
            PaletteCommand(id: "lsp.rename", title: "LSP: 名前の変更", detail: "F2") { [weak self] in self?.rename() },
            PaletteCommand(id: "lsp.quickfix", title: "LSP: クイックフィックス", detail: "⌥↩") { [weak self] in self?.quickFix() },
            PaletteCommand(id: "lsp.restart", title: "LSP: 言語サーバーを再起動") { [weak self] in self?.restart() },
        ]
    }

    private func restart() {
        guard let root else { return }
        LSPHub.stopServers(root: root)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NotificationCenter.default.post(name: LSPHub.reopen, object: nil) }
    }

    func dismiss() {
        hideHover()
        hideSignature()
    }

    func detach() {
        hideHover()
        hideSignature()
        hintWork?.cancel()
        clearHints()
        removeBulb()
        changeWork?.cancel()
        NotificationCenter.default.removeObserver(self)
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let doc { LSPHub.close(doc) }
        doc = nil
        if let layout = code?.textView.layoutManager, let length = layout.textStorage?.length {
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: length))
            layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: NSRange(location: 0, length: length))
        }
    }
}

final class LSPWindowAddon: NSObject, WindowAddon {
    private static var windows: [String: Int] = [:]
    private let root: URL

    init(editor: EditorWindowController) {
        root = editor.baseDirectory.standardizedFileURL
        super.init()
        LSPHub.install()
        Self.windows[root.path, default: 0] += 1
    }

    func detach() {
        Self.windows[root.path, default: 1] -= 1
        guard Self.windows[root.path] ?? 0 <= 0 else { return }
        Self.windows[root.path] = nil
        let root = root
        DispatchQueue.main.async { LSPHub.stopServers(root: root) }
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(LSPClientPlugin()) }
