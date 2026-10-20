import AppKit
import WebKit

private final class WebTab {
    let tab: TabItemView
    var url: URL
    var title: String
    var view: WKWebView?
    var observers: [NSKeyValueObservation] = []

    init(tab: TabItemView, url: URL, title: String) {
        self.tab = tab
        self.url = url
        self.title = title
    }

    func unload() {
        observers = []
        view?.stopLoading()
        view?.removeFromSuperview()
        view = nil
    }
}

final class WebFeed: NSView, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    static let pluginID = "web-feed"
    private static let storeKey = "WebFeed.Tabs"
    private static let home = URL(string: "https://www.google.com/")!

    var onRemove: (() -> Void)?
    private let bar: TabStrip
    private let container = NSView()
    private let address = NSTextField()
    private var back: NSButton!
    private var forward: NSButton!
    private var plus: NSButton!
    private var tabs: [WebTab] = []
    private var selected: WebTab?
    private var pressure: DispatchSourceMemoryPressure?

    init() {
        let minus = FeedView.barButton(symbol: "minus", tip: "フィードを閉じる", target: nil, action: nil)
        bar = TabStrip(trailing: minus)
        super.init(frame: .zero)
        minus.target = self
        minus.action = #selector(minusClicked)
        plus = FeedView.barButton(symbol: "plus", tip: "新しいタブ", target: self, action: #selector(plusClicked))
        bar.stack.addArrangedSubview(plus)

        back = FeedView.barButton(symbol: "chevron.left", tip: "戻る", target: self, action: #selector(goBack))
        forward = FeedView.barButton(symbol: "chevron.right", tip: "進む", target: self, action: #selector(goForward))
        let reload = FeedView.barButton(symbol: "arrow.clockwise", tip: "再読み込み", target: self, action: #selector(reloadPage))
        let homeButton = FeedView.barButton(symbol: "house", tip: "Google", target: self, action: #selector(goHome))
        let external = FeedView.barButton(symbol: "safari", tip: "ブラウザで開く", target: self, action: #selector(openExternal))
        address.placeholderString = "検索ワードまたは URL"
        address.bezelStyle = .roundedBezel
        address.controlSize = .small
        address.font = .systemFont(ofSize: 12)
        address.lineBreakMode = .byTruncatingTail
        address.cell?.isScrollable = true
        address.delegate = self
        address.target = self
        address.action = #selector(addressEntered)
        let tools = NSStackView(views: [back, forward, reload, homeButton, address, external])
        tools.spacing = 4
        tools.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        tools.translatesAutoresizingMaskIntoConstraints = false
        address.setContentHuggingPriority(.init(1), for: .horizontal)

        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        addSubview(tools)
        addSubview(container)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tools.topAnchor.constraint(equalTo: bar.bottomAnchor),
            tools.leadingAnchor.constraint(equalTo: leadingAnchor),
            tools.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: tools.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(applyColors), name: .settingsChanged, object: nil)
        applyColors()
        restore()
        watchMemory()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { pressure?.cancel() }

    @objc private func applyColors() { paint(.feed) }

    private func restore() {
        let saved = UserDefaults.standard.array(forKey: Self.storeKey) as? [[String: String]] ?? []
        for item in saved {
            guard let text = item["url"], let url = URL(string: text) else { continue }
            add(url, title: item["title"] ?? url.host ?? "Web", select: false)
        }
        let index = UserDefaults.standard.integer(forKey: Self.storeKey + ".Selected")
        if tabs.isEmpty {
            add(Self.home, title: "Google", select: true)
        } else {
            select(tabs[min(max(index, 0), tabs.count - 1)])
        }
    }

    private func save() {
        let order = bar.stack.arrangedSubviews.compactMap { view in tabs.first { $0.tab === view } }
        UserDefaults.standard.set(order.map { ["url": $0.url.absoluteString, "title": $0.title] }, forKey: Self.storeKey)
        if let selected, let index = order.firstIndex(where: { $0 === selected }) {
            UserDefaults.standard.set(index, forKey: Self.storeKey + ".Selected")
        }
    }

    private func watchMemory() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            for item in self.tabs where item !== self.selected { item.unload() }
            if source.data.contains(.critical), !self.isVisibleInWindow { self.selected?.unload() }
        }
        source.resume()
        pressure = source
    }

    private var isVisibleInWindow: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    @discardableResult
    private func add(_ url: URL, title: String, select now: Bool) -> WebTab {
        let tab = TabItemView(title: title, closable: true)
        tab.draggable = true
        tab.toolTip = url.absoluteString
        let item = WebTab(tab: tab, url: url, title: title)
        tab.onSelect = { [weak self, weak item] in if let item { self?.select(item) } }
        tab.onClose = { [weak self, weak item] in if let item { self?.close(item) } }
        tab.onMove = { [weak self] in self?.save() }
        bar.stack.insertArrangedSubview(tab, at: bar.stack.arrangedSubviews.count - 1)
        tabs.append(item)
        if now { select(item) }
        save()
        return item
    }

    private func load(_ item: WebTab) -> WKWebView {
        if let view = item.view { return view }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: container.bounds, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        item.view = view
        item.observers = [
            view.observe(\.title, options: [.new]) { [weak self, weak item] view, _ in
                guard let self, let item, let title = view.title, !title.isEmpty else { return }
                item.title = title
                item.tab.title = String(title.prefix(24))
                item.tab.toolTip = title
                self.save()
            },
            view.observe(\.url, options: [.new]) { [weak self, weak item] view, _ in
                guard let self, let item, let url = view.url else { return }
                item.url = url
                if item === self.selected, self.window?.firstResponder !== self.address.currentEditor() {
                    self.address.stringValue = url.absoluteString
                }
                self.save()
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.updateButtons() },
            view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.updateButtons() },
        ]
        view.load(URLRequest(url: item.url))
        return view
    }

    private func select(_ item: WebTab) {
        selected = item
        let view = load(item)
        for other in tabs {
            other.tab.selected = other === item
            other.view?.isHidden = other !== item
        }
        view.isHidden = false
        bar.reveal(item.tab)
        address.stringValue = item.url.absoluteString
        updateButtons()
        save()
    }

    private func close(_ item: WebTab) {
        let order = bar.stack.arrangedSubviews.compactMap { view in tabs.first { $0.tab === view } }
        let position = order.firstIndex { $0 === item } ?? 0
        item.unload()
        item.tab.removeFromSuperview()
        tabs.removeAll { $0 === item }
        if tabs.isEmpty {
            selected = nil
            add(Self.home, title: "Google", select: true)
        } else if selected === item {
            let rest = order.filter { $0 !== item }
            select(rest[min(position, rest.count - 1)])
        }
        save()
    }

    private func updateButtons() {
        back.isEnabled = selected?.view?.canGoBack ?? false
        forward.isEnabled = selected?.view?.canGoForward ?? false
    }

    func focus() {
        guard let selected else { return }
        window?.makeFirstResponder(load(selected))
    }

    private func destination(_ text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if input.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil { return URL(string: input) }
        if !input.contains(" "), input.contains("."), let url = URL(string: "https://" + input), url.host != nil { return url }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: input)]
        return components.url
    }

    @objc private func addressEntered() {
        guard let url = destination(address.stringValue), let selected else { return }
        selected.url = url
        load(selected).load(URLRequest(url: url))
        window?.makeFirstResponder(selected.view)
    }

    @objc private func plusClicked() {
        add(Self.home, title: "Google", select: true)
        window?.makeFirstResponder(address)
    }

    @objc private func goBack() { selected?.view?.goBack() }
    @objc private func goForward() { selected?.view?.goForward() }
    @objc private func reloadPage() { selected.map { load($0) }?.reload() }

    @objc private func goHome() {
        guard let selected else { return }
        load(selected).load(URLRequest(url: Self.home))
    }

    @objc private func openExternal() {
        if let url = selected?.url { NSWorkspace.shared.open(url) }
    }

    @objc private func minusClicked() { onRemove?() }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { add(url, title: url.host ?? "Web", select: true) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, let scheme = url.scheme?.lowercased(), !["http", "https", "about", "data", "blob"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let item = tabs.first(where: { $0.view === webView }) else { return }
        item.unload()
        if item === selected { select(item) }
    }
}
