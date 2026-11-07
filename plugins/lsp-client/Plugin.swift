import AppKit
@testable import FlareStackIDE

final class LSPClientPlugin: NativePlugin {
    static let pluginID = "lsp-client"
    let id = pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { LSPTextAddon(code: code) }
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { LSPWindowAddon(editor: editor) }
}

enum LSPText {
    static func lineStarts(_ text: NSString) -> [Int] {
        var starts = [0]
        var i = 0
        while i < text.length {
            let r = text.range(of: "\n", options: .literal, range: NSRange(location: i, length: text.length - i))
            if r.location == NSNotFound { break }
            starts.append(r.location + 1)
            i = r.location + 1
        }
        return starts
    }

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
        let starts = lineStarts(text)
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return ["line": low, "character": offset - starts[low]]
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
                NotificationCenter.default.post(name: externalDiagnostics, object: url, userInfo: ["items": payload, "version": version])
                NotificationCenter.default.post(name: diagnosticsChanged, object: url)
            }
        }
    }
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

    init(code: CodeEditing) {
        self.code = code
        super.init()
        LSPHub.install()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(diagnosticsChanged(_:)), name: LSPHub.diagnosticsChanged, object: nil)
        center.addObserver(self, selector: #selector(otherHover(_:)), name: LSPHub.hoverShown, object: code.textView)
        center.addObserver(self, selector: #selector(hideHover), name: NSView.boundsDidChangeNotification, object: code.scrollView.contentView)
        center.addObserver(self, selector: #selector(reopen), name: LSPHub.reopen, object: nil)
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
        if let doc, LSPHub.documents[doc.url.path] !== doc { self.doc = nil }
        if let doc, doc.url != code?.fileURL?.standardizedFileURL {
            LSPHub.close(doc)
            self.doc = nil
        }
        guard doc == nil, let code, let url = code.fileURL, LSPLanguage.language(for: url) != nil, let root else { return redraw() }
        doc = LSPHub.open(url, text: code.textView.string, root: root)
        redraw()
    }

    func shouldChange(_ range: NSRange, text: String) -> Bool {
        lastTyped = text
        return true
    }

    func textChanged() {
        hideHover()
        guard doc != nil else { return }
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
            switch (event.keyCode, flags) {
            case (111, []): goToDefinition()
            case (111, .shift): findReferences()
            case (120, []): rename()
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
            self?.apply(result as? [String: Any], name: name)
        }
    }

    private func apply(_ edit: [String: Any]?, name: String) {
        var changes: [URL: [[String: Any]]] = [:]
        for (uri, edits) in edit?["changes"] as? [String: [[String: Any]]] ?? [:] {
            if let url = LSPText.url(uri) { changes[url, default: []] += edits }
        }
        for change in edit?["documentChanges"] as? [[String: Any]] ?? [] {
            guard let url = LSPText.url((change["textDocument"] as? [String: Any])?["uri"] as? String) else { continue }
            changes[url, default: []] += change["edits"] as? [[String: Any]] ?? []
        }
        let window = code?.textView.window
        guard !changes.isEmpty else {
            Toasts.post("変更できる箇所がありませんでした", in: window)
            return
        }
        if let editor, let error = editor.saveAll() { return editor.showError(error) }
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
        Toasts.post("「\(name)」に \(count) 箇所を変更しました", message: "\(originals.count) ファイル",
                    actions: [("元に戻す", { [weak self] in self?.restore(originals) })], in: window)
    }

    private func restore(_ originals: [URL: String]) {
        if let editor, let error = editor.saveAll() { return editor.showError(error) }
        for (url, text) in originals { try? text.write(to: url, atomically: false, encoding: .utf8) }
        editor?.reloadExternal(Set(originals.keys.map(\.path)))
    }

    @objc private func diagnosticsChanged(_ note: Notification) {
        guard let url = note.object as? URL, url == doc?.url else { return }
        redraw()
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
            PaletteCommand(id: "lsp.restart", title: "LSP: 言語サーバーを再起動") { [weak self] in self?.restart() },
        ]
    }

    private func restart() {
        guard let root else { return }
        LSPHub.stopServers(root: root)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NotificationCenter.default.post(name: LSPHub.reopen, object: nil) }
    }

    func dismiss() { hideHover() }

    func detach() {
        hideHover()
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
