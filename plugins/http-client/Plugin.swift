import AppKit
@testable import FlareStackIDE

final class HTTPClientPlugin: NativePlugin {
    static let pluginID = "http-client"
    let id = pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { HTTPSendAddon(code: code) }
    func windowAddon(for editor: EditorWindowController) -> WindowAddon? { HTTPFeedAddon(editor: editor) }
}

struct HTTPExchange {
    let title: String
    let status: String
    let summary: String
    let headers: String
    let body: String
    let failed: Bool
}

final class HTTPSendButton: NSButton {
    var request: HTTPRequestSpec?
}

final class HTTPSendAddon: NSObject, TextAddon, CommandProviding {
    private weak var code: CodeEditing?
    private var requests: [HTTPRequestSpec] = []
    private var variables: [String: String] = [:]
    private var buttons: [HTTPSendButton] = []
    private var work: DispatchWorkItem?
    private var monitor: Any?

    init(code: CodeEditing) {
        self.code = code
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(place), name: NSView.frameDidChangeNotification, object: code.textView)
        NotificationCenter.default.addObserver(self, selector: #selector(place), name: .settingsChanged, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] in self?.handle($0) ?? $0 }
        refresh()
    }

    private var active: Bool { code?.fileURL.map { HTTPFile.extensions.contains($0.pathExtension.lowercased()) } ?? false }

    private func refresh() {
        guard active, let textView = code?.textView else {
            requests = []
            return place()
        }
        (requests, variables) = HTTPFile.parse(textView.string as NSString)
        place()
    }

    @objc private func place() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        guard let textView = code?.textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let length = (textView.string as NSString).length
        let origin = textView.textContainerOrigin
        for request in requests where NSMaxRange(request.line) <= length {
            let glyphs = layout.glyphRange(forCharacterRange: request.line, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let button = HTTPSendButton(title: "▶ 送信", target: self, action: #selector(sendClicked(_:)))
            button.request = request
            button.controlSize = .mini
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 10)
            button.toolTip = "このリクエストを送信（⌘↩）"
            let size = button.fittingSize
            button.frame = NSRect(x: origin.x + used.maxX + 12, y: origin.y + rect.minY + (rect.height - size.height) / 2,
                                  width: size.width, height: size.height)
            textView.addSubview(button)
            buttons.append(button)
        }
    }

    @objc private func sendClicked(_ sender: HTTPSendButton) {
        if let request = sender.request { send(request) }
    }

    private func requestAtCaret() -> HTTPRequestSpec? {
        guard let caret = code?.textView.selectedRange().location else { return nil }
        return requests.last { $0.line.location <= caret } ?? requests.first
    }

    private func send(_ request: HTTPRequestSpec) {
        guard let window = code?.textView.window else { return }
        HTTPFeedAddon.owner(of: window)?.send(request, variables: variables)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard active, let textView = code?.textView, event.window === textView.window, textView.window?.firstResponder === textView,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command, event.keyCode == 36,
              let request = requestAtCaret() else { return event }
        send(request)
        return nil
    }

    var commands: [PaletteCommand] {
        guard active else { return [] }
        return [PaletteCommand(id: "http-client.send", title: "HTTP: カーソル位置のリクエストを送信", detail: "⌘↩") { [weak self] in
            guard let self, let request = self.requestAtCaret() else { return }
            self.send(request)
        }]
    }

    func textChanged() {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    func fileOpened() { refresh() }

    func detach() {
        work?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
    }
}

final class HTTPFeedAddon: NSObject, WindowAddon {
    private static let all = NSHashTable<HTTPFeedAddon>.weakObjects()
    private weak var editor: EditorWindowController?
    private var button: ToolStripButton!
    private var feed: FeedView?
    private let view = HTTPResponseView()
    private var task: URLSessionDataTask?

    static func owner(of window: NSWindow) -> HTTPFeedAddon? { all.allObjects.first { $0.editor?.window === window } }

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init()
        Self.all.add(self)
        button = ToolStripButton(symbol: "network", tip: "HTTP 応答", target: self, action: #selector(toggle))
        editor.addStripButton(button, id: HTTPClientPlugin.pluginID)
    }

    private func makeFeed(_ editor: EditorWindowController) -> FeedView {
        let made = FeedView(title: "HTTP 応答", content: view)
        made.onRemove = { [weak self] in self?.toggle() }
        editor.addFeed(made, button: button)
        feed = made
        return made
    }

    @objc private func toggle() {
        guard let editor else { return }
        editor.toggleBottom(feed ?? makeFeed(editor))
    }

    private func showFeed() {
        guard let editor else { return }
        let feed = self.feed ?? makeFeed(editor)
        if feed.isHidden { editor.showBottom(feed) }
    }

    private static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
    }

    private var timeout: TimeInterval {
        Double(PluginStore.setting(HTTPClientPlugin.pluginID, "timeout") ?? "") ?? 30
    }

    func send(_ spec: HTTPRequestSpec, variables: [String: String]) {
        let rawURL = HTTPFile.substitute(spec.url, variables)
        let withScheme = rawURL.contains("://") ? rawURL : "http://" + rawURL
        guard let url = URL(string: withScheme), let host = url.host, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            Toasts.post("URL が正しくありません", message: rawURL, in: editor?.window)
            return
        }
        if url.scheme?.lowercased() == "http", !Self.isLocal(host), PluginStore.setting(HTTPClientPlugin.pluginID, "confirmInsecure") != "false" {
            let alert = NSAlert()
            alert.messageText = "暗号化されていない http で送信しますか？"
            alert.informativeText = "\(host) への通信は暗号化されません。パスワードやトークンを含む場合は https を使ってください。"
            alert.addButton(withTitle: "送信")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = spec.method
        for (key, value) in spec.headers { request.addValue(HTTPFile.substitute(value, variables), forHTTPHeaderField: key) }
        let body = HTTPFile.substitute(spec.body, variables)
        if !body.isEmpty { request.httpBody = Data(body.utf8) }
        let title = "\(spec.method) \(url.absoluteString)"
        task?.cancel()
        showFeed()
        view.showLoading(title)
        let started = Date()
        let session = URLSession(configuration: .ephemeral)
        task = session.dataTask(with: request) { [weak self] data, response, error in
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            let exchange = Self.exchange(title: title, data: data, response: response as? HTTPURLResponse, error: error, elapsed: elapsed)
            DispatchQueue.main.async {
                guard (error as? URLError)?.code != .cancelled else { return }
                self?.view.show(exchange)
            }
            session.finishTasksAndInvalidate()
        }
        task?.resume()
    }

    private static func exchange(title: String, data: Data?, response: HTTPURLResponse?, error: Error?, elapsed: Int) -> HTTPExchange {
        guard let response else {
            return HTTPExchange(title: title, status: "失敗", summary: "\(elapsed) ms", headers: "",
                                body: error?.localizedDescription ?? "応答がありませんでした", failed: true)
        }
        let data = data ?? Data()
        let status = "\(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))"
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let headers = response.allHeaderFields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        var body: String
        if type.contains("json"), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed]) {
            body = String(decoding: pretty, as: UTF8.self)
        } else if type.hasPrefix("image/") || type.hasPrefix("video/") || type.hasPrefix("audio/") {
            body = "（\(type) のため本文は表示しません）"
        } else if let text = String(data: data, encoding: .utf8) {
            body = text
        } else {
            body = "（バイナリ \(size)）"
        }
        if body.utf16.count > 500_000 { body = String(body.prefix(500_000)) + "\n…（以下省略）" }
        return HTTPExchange(title: title, status: status, summary: "\(elapsed) ms · \(size)", headers: headers, body: body,
                            failed: response.statusCode >= 400)
    }

    func detach() {
        task?.cancel()
        Self.all.remove(self)
        if let feed { editor?.removeFeed(feed) }
        feed = nil
        button.removeFromSuperview()
    }
}

final class HTTPResponseView: NSView {
    private let status = NSTextField(labelWithString: "リクエストを送信すると、ここに応答が表示されます")
    private let history = NSPopUpButton()
    private let mode = NSSegmentedControl(labels: ["本文", "ヘッダー"], trackingMode: .selectOne, target: nil, action: nil)
    private let text = NSTextView()
    private var items: [HTTPExchange] = []
    private var shown: HTTPExchange?

    init() {
        super.init(frame: .zero)
        status.font = .systemFont(ofSize: 11, weight: .semibold)
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        history.controlSize = .small
        history.font = .systemFont(ofSize: 11)
        history.target = self
        history.action = #selector(historyChosen)
        history.isHidden = true
        mode.controlSize = .small
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        let bar = NSStackView(views: [status, NSView(), history, mode])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false
        text.isEditable = false
        text.isRichText = false
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 4)
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func showLoading(_ title: String) {
        status.stringValue = "送信中…　\(title)"
        status.textColor = .secondaryLabelColor
    }

    func show(_ exchange: HTTPExchange) {
        items.insert(exchange, at: 0)
        if items.count > 20 { items.removeLast() }
        history.removeAllItems()
        history.addItems(withTitles: items.enumerated().map { "\($0.offset + 1). \($0.element.status)　\($0.element.title)" })
        history.isHidden = items.count < 2
        display(exchange)
    }

    private func display(_ exchange: HTTPExchange) {
        shown = exchange
        status.stringValue = "\(exchange.status)　·　\(exchange.summary)　·　\(exchange.title)"
        status.textColor = exchange.failed ? .systemRed : .systemGreen
        text.string = mode.selectedSegment == 0 ? exchange.body : exchange.headers
        text.textColor = .labelColor
        text.scrollToBeginningOfDocument(nil)
    }

    @objc private func historyChosen() {
        guard items.indices.contains(history.indexOfSelectedItem) else { return }
        display(items[history.indexOfSelectedItem])
    }

    @objc private func modeChanged() {
        if let shown { display(shown) }
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(HTTPClientPlugin()) }
