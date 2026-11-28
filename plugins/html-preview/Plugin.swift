import AppKit
import WebKit
@testable import FlareStackIDE

final class HTMLPreviewPlugin: NativePlugin, CodePreviewing {
    static let pluginID = "html-preview"
    let id = pluginID

    func preview(for url: URL, code: NSView) -> EditorExtension? {
        let ext = url.pathExtension.lowercased()
        guard PluginStore.installed(id)?.fileExtensions.contains(ext) == true else { return nil }
        return HTMLPreview(file: url, code: code)
    }
}

final class HTMLPreview: NSObject, EditorExtension, WKNavigationDelegate {
    private enum Mode: Int { case code, split, preview }

    private static let id = HTMLPreviewPlugin.pluginID
    private static let modeKey = "Plugin.\(id).Mode"
    private static let ruleID = "\(id).block"
    private static let rules = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp|file|blob):"},"action":{"type":"block"}}]"#
    private static var compiledRules: WKContentRuleList?
    private static let markers = [".git", "package.json"]

    let bar = NSView()
    private(set) var floating = true
    private(set) var corner = FloatCorner.bottomRight
    private var minimize = false
    private var hovering = false
    private let images: [NSImage]
    private let single: NSSegmentedControl
    private var barWidth: NSLayoutConstraint!
    private let barLine = NSBox()
    private let barTitle = NSTextField(labelWithString: "HTML Preview")
    private let file: URL
    private let directory: URL
    private let base: URL
    private let code: NSView
    private let split = NSSplitView()
    private let preview: WKWebView
    private let modes: NSSegmentedControl
    private var mode: Mode
    private var latest = ""
    private var shown: String?
    private var pending: DispatchWorkItem?
    private var scroll: [Double] = [0, 0]
    private var blocking: Bool?
    private var rulesReady = false
    private var stamps: [String: Date] = [:]
    private var watcher: Timer?

    var body: NSView { split }

    init(file: URL, code: NSView) {
        self.file = file
        self.code = code
        directory = file.deletingLastPathComponent()
        base = LocalFileScheme.url(for: directory)
        mode = Mode(rawValue: UserDefaults.standard.object(forKey: Self.modeKey) as? Int ?? Mode.split.rawValue) ?? .split
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(LocalFileScheme(root: Self.root(of: directory)), forURLScheme: LocalFileScheme.scheme)
        preview = WKWebView(frame: .zero, configuration: config)
        images = ["doc.plaintext", "rectangle.split.2x1", "eye"].map { PluginStore.symbol($0, size: 12) }
        modes = NSSegmentedControl(images: images, trackingMode: .selectOne, target: nil, action: nil)
        single = NSSegmentedControl(images: [images[0]], trackingMode: .selectOne, target: nil, action: nil)
        super.init()
        preview.navigationDelegate = self
        buildBar()
        code.removeFromSuperview()
        code.translatesAutoresizingMaskIntoConstraints = true
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(code)
        split.addArrangedSubview(preview)
        applySettings()
        apply(mode)
        watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.checkAssets()
        }
    }

    private static func root(of directory: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var current = directory.standardizedFileURL
        while current.path != "/" && current.path != home {
            if markers.contains(where: { FileManager.default.fileExists(atPath: current.appendingPathComponent($0).path) }) { return current }
            current = current.deletingLastPathComponent()
        }
        return directory
    }

    private func buildBar() {
        single.controlSize = .small
        single.setWidth(28, forSegment: 0)
        single.setImageScaling(.scaleProportionallyDown, forSegment: 0)
        single.selectedSegment = 0
        single.isHidden = true
        modes.controlSize = .small
        for (i, label) in ["コード", "コード＋プレビュー", "プレビュー"].enumerated() {
            modes.setToolTip(label, forSegment: i)
            modes.setWidth(28, forSegment: i)
            modes.setImageScaling(.scaleProportionallyDown, forSegment: i)
        }
        modes.target = self
        modes.action = #selector(modeChanged)
        barTitle.font = .systemFont(ofSize: 11, weight: .medium)
        barTitle.textColor = .secondaryLabelColor
        barLine.boxType = .separator
        [modes, single, barTitle, barLine].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview($0)
        }
        barWidth = bar.widthAnchor.constraint(equalToConstant: 100)
        bar.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        NSLayoutConstraint.activate([
            single.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            single.centerYAnchor.constraint(equalTo: modes.centerYAnchor),
            modes.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            modes.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: -1),
            barTitle.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            barTitle.centerYAnchor.constraint(equalTo: modes.centerYAnchor),
            barLine.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            barLine.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            barLine.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
    }

    private func setting(_ key: String) -> Bool { PluginStore.setting(Self.id, key) == "true" }

    func applySettings() {
        floating = setting("barTransparent")
        minimize = setting("barMinimize")
        corner = PluginStore.setting(Self.id, "barPosition").flatMap(FloatCorner.init) ?? .bottomRight
        barWidth.isActive = floating
        updateCollapsed()
        bar.wantsLayer = true
        bar.layer?.cornerRadius = floating ? 7 : 0
        bar.layer?.backgroundColor = floating ? nil : PluginStore.color(Self.id, "barColor")?.cgColor
        bar.appearance = floating ? nil : PluginStore.color(Self.id, "barColor").map { NSAppearance(named: $0.isDark ? .darkAqua : .aqua)! }
        barLine.isHidden = floating
        barTitle.isHidden = floating
        if !floating && PluginStore.color(Self.id, "barColor") == nil { bar.paint(.midTab) }
        let block = !setting("allowNetwork")
        if block != blocking {
            blocking = block
            prepareRules(block)
        } else {
            reload()
        }
    }

    private func prepareRules(_ block: Bool) {
        let controller = preview.configuration.userContentController
        controller.removeAllContentRuleLists()
        rulesReady = !block
        guard block else { return reload(force: true) }
        let finish = { [weak self] (list: WKContentRuleList?) in
            guard let self, self.blocking == true else { return }
            guard let list else {
                self.preview.loadHTMLString("<p style=\"color:#d33;font:13px -apple-system;padding:16px\">通信の遮断を準備できないため、表示を止めました。</p>", baseURL: nil)
                return
            }
            controller.add(list)
            self.rulesReady = true
            self.reload(force: true)
        }
        if let compiled = Self.compiledRules { return finish(compiled) }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: Self.ruleID, encodedContentRuleList: Self.rules) { list, _ in
            DispatchQueue.main.async {
                Self.compiledRules = list
                finish(list)
            }
        }
    }

    @objc func mouseEntered(with event: NSEvent) {
        hovering = true
        updateCollapsed()
    }

    @objc func mouseExited(with event: NSEvent) {
        hovering = false
        updateCollapsed()
    }

    private func updateCollapsed() {
        let collapsed = floating && minimize && !hovering
        modes.isHidden = collapsed
        single.isHidden = !collapsed
        single.setImage(images[mode.rawValue], forSegment: 0)
        barWidth.constant = collapsed ? 40 : 100
    }

    func update(text: String) {
        latest = text
        pending?.cancel()
        guard mode != .code else { return }
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reload(force: Bool = false) {
        pending?.cancel()
        guard mode != .code, rulesReady else { return }
        let html = compose(latest)
        guard force || html != shown else { return }
        shown = html
        preview.evaluateJavaScript("[window.scrollX, window.scrollY]") { [weak self] value, _ in
            guard let self else { return }
            if let point = value as? [Double], point.count == 2 { self.scroll = point }
            self.preview.loadHTMLString(html, baseURL: self.base)
        }
    }

    private func compose(_ text: String) -> String {
        guard setting("autoInclude") else { return text }
        let lower = text.lowercased()
        let names = siblings().map(\.lastPathComponent).filter { !lower.contains($0.lowercased()) }
        let styles = names.filter { $0.lowercased().hasSuffix(".css") }.map { "<link rel=\"stylesheet\" href=\"\(Self.attribute($0))\">" }
        let scripts = names.filter { $0.lowercased().hasSuffix(".js") }.map { "<script src=\"\(Self.attribute($0))\"></script>" }
        var html = text
        if !styles.isEmpty {
            let tag = styles.joined()
            if let head = html.range(of: "</head>", options: .caseInsensitive) { html.insert(contentsOf: tag, at: head.lowerBound) }
            else { html = tag + html }
        }
        if !scripts.isEmpty {
            let tag = scripts.joined()
            if let body = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) { html.insert(contentsOf: tag, at: body.lowerBound) }
            else { html += tag }
        }
        return html
    }

    private static func attribute(_ name: String) -> String {
        (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name).replacingOccurrences(of: "\"", with: "%22")
    }

    private func siblings() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return items.filter { ["css", "js"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func referenced() -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:src|href)\s*=\s*["']([^"'#?]+)"#, options: .caseInsensitive) else { return [] }
        let range = NSRange(latest.startIndex..., in: latest)
        return regex.matches(in: latest, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: latest) else { return nil }
            let path = String(latest[r])
            guard !path.contains(":"), !path.hasPrefix("//") else { return nil }
            let decoded = path.removingPercentEncoding ?? path
            return (decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : directory.appendingPathComponent(decoded)).standardizedFileURL
        }
    }

    private func checkAssets() {
        guard mode != .code, preview.window != nil else { return }
        var next: [String: Date] = [:]
        for url in Set(siblings() + referenced()) where url != file {
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { next[url.path] = date }
        }
        defer { stamps = next }
        if !stamps.isEmpty && next != stamps { reload(force: true) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame != false else { return decisionHandler(.allow) }
        if action.navigationType == .other, action.request.url?.absoluteString.hasPrefix(base.absoluteString) == true || action.request.url?.scheme == "about" {
            return decisionHandler(.allow)
        }
        if let url = action.request.url, url.scheme == LocalFileScheme.scheme, url.fragment != nil,
           url.absoluteString.hasPrefix(base.absoluteString) {
            return decisionHandler(.allow)
        }
        if action.navigationType == .linkActivated, let url = action.request.url {
            if url.scheme == LocalFileScheme.scheme,
               let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else if ["http", "https", "mailto"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard scroll != [0, 0] else { return }
        webView.evaluateJavaScript("window.scrollTo(\(scroll[0]), \(scroll[1]))", completionHandler: nil)
    }

    @objc private func modeChanged() {
        guard let next = Mode(rawValue: modes.selectedSegment) else { return }
        UserDefaults.standard.set(next.rawValue, forKey: Self.modeKey)
        apply(next)
    }

    private func apply(_ next: Mode) {
        mode = next
        modes.selectedSegment = next.rawValue
        updateCollapsed()
        code.isHidden = next == .preview
        preview.isHidden = next == .code
        split.adjustSubviews()
        reload()
        if next == .split {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.split.layoutSubtreeIfNeeded()
                self.split.setPosition(self.split.bounds.width / 2, ofDividerAt: 0)
            }
        }
        if next != .preview { code.window?.makeFirstResponder((code as? NSScrollView)?.documentView) }
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(HTMLPreviewPlugin()) }
