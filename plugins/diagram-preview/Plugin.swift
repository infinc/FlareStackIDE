import AppKit
import WebKit
@testable import FlareStackIDE

final class DiagramPreviewPlugin: NativePlugin, CodePreviewing {
    static let pluginID = "diagram-preview"
    let id = pluginID

    func preview(for url: URL, code: NSView) -> EditorExtension? {
        let ext = url.pathExtension.lowercased()
        guard PluginStore.installed(id)?.fileExtensions.contains(ext) == true else { return nil }
        return DiagramPreview(code: code)
    }
}

final class DiagramPreview: NSObject, EditorExtension, WKNavigationDelegate {
    private enum Mode: Int { case code, split, preview }

    private static let library = "mermaid.min.js"
    private static let modeKey = "Plugin.\(DiagramPreviewPlugin.pluginID).Mode"
    private static let ruleID = "\(DiagramPreviewPlugin.pluginID).block"
    private static let rules = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp|file|blob):"},"action":{"type":"block"}}]"#
    private static var compiledRules: WKContentRuleList?

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    html,body{margin:0;background:var(--bg);color:var(--fg);font:12px -apple-system,sans-serif}
    #err{display:none;margin:12px 16px 0;padding:8px 10px;border-radius:6px;background:rgba(220,50,50,.12);color:#d33;
    white-space:pre-wrap;font:12px ui-monospace,Menlo,monospace}
    #out{padding:16px;display:flex;justify-content:center}
    #out svg{max-width:100%;height:auto}
    #out.stale{opacity:.35}
    </style></head><body><div id="err"></div><div id="out"></div></body></html>
    """

    private static let renderer = """
    window.fsRender = async function(text, dark, bg, fg) {
      const root = document.documentElement.style;
      root.setProperty('--bg', bg);
      root.setProperty('--fg', fg);
      const out = document.getElementById('out'), err = document.getElementById('err');
      if (!text.trim()) { out.innerHTML = ''; err.style.display = 'none'; return ''; }
      try {
        mermaid.initialize({startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default'});
        window.fsCount = (window.fsCount || 0) + 1;
        const svg = (await mermaid.render('fs' + window.fsCount, text)).svg;
        out.innerHTML = svg;
        out.classList.remove('stale');
        err.style.display = 'none';
        return svg;
      } catch (e) {
        document.querySelectorAll('body > [id^="dfs"]').forEach(n => n.remove());
        out.classList.add('stale');
        err.textContent = String((e && e.message) || e);
        err.style.display = 'block';
        return null;
      }
    };
    """

    let bar = NSView()
    let floating = false
    let corner = FloatCorner.bottomRight
    private let code: NSView
    private let split = NSSplitView()
    private let preview: WKWebView
    private let modes: NSSegmentedControl
    private let copyButton: NSButton
    private var mode: Mode
    private var latest = ""
    private var pending: DispatchWorkItem?
    private var ready = false
    private var svg: String?
    private var failed = false

    var body: NSView { split }

    init(code: NSView) {
        self.code = code
        mode = Mode(rawValue: UserDefaults.standard.object(forKey: Self.modeKey) as? Int ?? Mode.split.rawValue) ?? .split
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if let library = try? String(contentsOf: PluginStore.folder(DiagramPreviewPlugin.pluginID).appendingPathComponent(Self.library), encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: library, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            config.userContentController.addUserScript(WKUserScript(source: Self.renderer, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        } else {
            failed = true
        }
        preview = WKWebView(frame: .zero, configuration: config)
        let images = ["doc.plaintext", "rectangle.split.2x1", "eye"].map { PluginStore.symbol($0, size: 12) }
        modes = NSSegmentedControl(images: images, trackingMode: .selectOne, target: nil, action: nil)
        copyButton = NSButton(title: "SVG をコピー", target: nil, action: nil)
        super.init()
        preview.navigationDelegate = self
        buildBar()
        code.removeFromSuperview()
        code.translatesAutoresizingMaskIntoConstraints = true
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(code)
        split.addArrangedSubview(preview)
        prepare()
        applySettings()
        apply(mode)
    }

    private func buildBar() {
        modes.controlSize = .small
        for (i, label) in ["コード", "コード＋図", "図"].enumerated() {
            modes.setToolTip(label, forSegment: i)
            modes.setWidth(28, forSegment: i)
            modes.setImageScaling(.scaleProportionallyDown, forSegment: i)
        }
        modes.target = self
        modes.action = #selector(modeChanged)
        copyButton.target = self
        copyButton.action = #selector(copySVG)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = .systemFont(ofSize: 11)
        let title = NSTextField(labelWithString: "Mermaid")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [modes, copyButton])
        stack.spacing = 8
        let line = NSBox()
        line.boxType = .separator
        [stack, title, line].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview($0)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: -1),
            title.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            title.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
    }

    private func prepare() {
        guard !failed else {
            preview.loadHTMLString("<p style=\"color:#d33;font:13px -apple-system;padding:16px\">\(Self.library) が見つかりません。プラグインを入れ直してください。</p>", baseURL: nil)
            return
        }
        let load = { [weak self] (list: WKContentRuleList?) in
            guard let self else { return }
            guard let list else {
                self.failed = true
                self.preview.loadHTMLString("<p style=\"color:#d33;font:13px -apple-system;padding:16px\">通信の遮断を準備できないため、表示を止めました。</p>", baseURL: nil)
                return
            }
            self.preview.configuration.userContentController.add(list)
            self.preview.loadHTMLString(Self.page, baseURL: nil)
        }
        if let compiled = Self.compiledRules { return load(compiled) }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: Self.ruleID, encodedContentRuleList: Self.rules) { list, _ in
            DispatchQueue.main.async {
                Self.compiledRules = list
                load(list)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let initial = !ready && action.navigationType == .other && (action.request.url?.absoluteString ?? "about:blank").hasPrefix("about:")
        decisionHandler(initial ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !failed else { return }
        ready = true
        render()
    }

    func update(text: String) {
        latest = text
        pending?.cancel()
        guard mode != .code else { return }
        let work = DispatchWorkItem { [weak self] in self?.render() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private static func css(_ color: NSColor) -> String {
        var rgb = color
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { rgb = color.usingColorSpace(.sRGB) ?? color }
        return String(format: "rgb(%d,%d,%d)", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    private func render() {
        pending?.cancel()
        guard ready, mode != .code else { return }
        let arguments: [String: Any] = ["text": latest, "dark": Settings.editorIsDark,
                                        "bg": Self.css(Settings.background), "fg": Self.css(Settings.foreground)]
        preview.callAsyncJavaScript("return await fsRender(text, dark, bg, fg)", arguments: arguments,
                                    in: nil, in: .page) { [weak self] result in
            guard let self, case .success(let value) = result else { return }
            if let svg = value as? String { self.svg = svg.isEmpty ? nil : svg }
            self.copyButton.isEnabled = self.svg != nil
        }
    }

    @objc private func copySVG() {
        guard let svg else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(svg, forType: .string)
        Toasts.post("SVG をコピーしました", in: bar.window)
    }

    func applySettings() {
        preview.underPageBackgroundColor = Settings.background
        bar.paint(.midTab)
        render()
    }

    @objc private func modeChanged() {
        guard let next = Mode(rawValue: modes.selectedSegment) else { return }
        UserDefaults.standard.set(next.rawValue, forKey: Self.modeKey)
        apply(next)
    }

    private func apply(_ next: Mode) {
        mode = next
        modes.selectedSegment = next.rawValue
        copyButton.isHidden = next == .code
        code.isHidden = next == .preview
        preview.isHidden = next == .code
        split.adjustSubviews()
        render()
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
public func flarestackPluginLoad() { NativePlugins.register(DiagramPreviewPlugin()) }
