import AppKit
import JavaScriptCore
import WebKit

extension Notification.Name {
    static let pluginsChanged = Notification.Name("FlareStackIDE.pluginsChanged")
}

struct PluginInfo: Codable {
    let id: String
    let name: String
    let version: String
    let author: String
    let symbol: String
    let summary: String
    let fileExtensions: [String]
    var files: [String]?
}

protocol EditorExtension: AnyObject {
    var bar: NSView { get }
    var body: NSView { get }
    func update(text: String)
    func applySettings()
}

enum PluginStore {
    private static let scheme = "flarestack-plugin"
    private static let defaultSource = "https://raw.githubusercontent.com/infinc/FlareStackIDE/main/plugins/"
    private(set) static var remote: [PluginInfo] = loadCache()
    private(set) static var loading = false
    private(set) static var catalogError: Error?
    private static var busy: Set<String> = []
    private static var detailsCache: [String: String] = [:]

    static var source: URL {
        var text = UserDefaults.standard.string(forKey: "Plugins.Source") ?? defaultSource
        if !text.hasSuffix("/") { text += "/" }
        return URL(string: text)!
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName).appendingPathComponent("Plugins")
    }

    private static var cacheURL: URL { directory.appendingPathComponent("index.json") }

    static func folder(_ id: String) -> URL { directory.appendingPathComponent(id) }

    private static func manifest(_ id: String) -> URL { folder(id).appendingPathComponent("plugin.json") }

    private static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
            && path.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil
    }

    private static func isValidID(_ id: String) -> Bool { id.range(of: #"^[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil }

    private static func loadCache() -> [PluginInfo] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return (try? JSONDecoder().decode([PluginInfo].self, from: data)) ?? []
    }

    private static func changed() { NotificationCenter.default.post(name: .pluginsChanged, object: nil) }

    private static func failure(_ message: String) -> Error {
        NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func fetch(_ path: String, _ completion: @escaping (Result<Data, Error>) -> Void) {
        let url = source.appendingPathComponent(path)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            let result: Result<Data, Error>
            if let data, error == nil, status == 200 {
                result = .success(data)
            } else {
                result = .failure(error ?? failure("取得できませんでした (\(status))\n\(url.absoluteString)"))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    static func installed(_ id: String) -> PluginInfo? {
        guard let data = try? Data(contentsOf: manifest(id)),
              let info = try? JSONDecoder().decode(PluginInfo.self, from: data),
              (info.files ?? ["main.js"]).allSatisfy({ FileManager.default.fileExists(atPath: folder(id).appendingPathComponent($0).path) })
        else { return nil }
        return info
    }

    static func isInstalled(_ id: String) -> Bool { installed(id) != nil }

    static func isBusy(_ id: String) -> Bool { busy.contains(id) }

    static var installedIDs: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { isValidID($0) && isInstalled($0) }.sorted()
    }

    static var catalog: [PluginInfo] {
        let ids = Set(remote.map(\.id))
        return remote + installedIDs.filter { !ids.contains($0) }.compactMap(installed)
    }

    static func info(_ id: String) -> PluginInfo? { installed(id) ?? remote.first { $0.id == id } }

    static func hasUpdate(_ id: String) -> Bool {
        guard let local = installed(id), let latest = remote.first(where: { $0.id == id }) else { return false }
        return isNewer(latest.version, than: local.version)
    }

    static func refreshCatalog() {
        guard !loading else { return }
        loading = true
        changed()
        fetch("index.json") { result in
            loading = false
            switch result {
            case .success(let data):
                if let list = try? JSONDecoder().decode([PluginInfo].self, from: data) {
                    remote = list.filter { isValidID($0.id) }
                    catalogError = nil
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? data.write(to: cacheURL, options: .atomic)
                } else {
                    catalogError = failure("プラグイン一覧の形式が正しくありません")
                }
            case .failure(let error):
                catalogError = error
            }
            changed()
        }
    }

    static func perform(_ id: String, completion: @escaping (Error?) -> Void) {
        if isInstalled(id) && !hasUpdate(id) {
            do { try uninstall(id); completion(nil) } catch { completion(error) }
        } else {
            install(id, completion: completion)
        }
    }

    static func install(_ id: String, completion: @escaping (Error?) -> Void) {
        guard isValidID(id), !busy.contains(id) else { return }
        busy.insert(id)
        changed()
        let finish: (Error?) -> Void = { error in
            busy.remove(id)
            detailsCache[id] = nil
            changed()
            completion(error)
        }
        fetch("\(id)/plugin.json") { result in
            let data: Data
            switch result {
            case .failure(let error): return finish(error)
            case .success(let d): data = d
            }
            guard let info = try? JSONDecoder().decode(PluginInfo.self, from: data), info.id == id else {
                return finish(failure("plugin.json の形式が正しくありません"))
            }
            let files = info.files ?? ["main.js"]
            guard files.allSatisfy(isSafe), !files.contains("plugin.json") else {
                return finish(failure("plugin.json の files に不正なパスがあります"))
            }
            let fm = FileManager.default
            let staging = fm.temporaryDirectory.appendingPathComponent("\(appName)-plugin-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                try data.write(to: staging.appendingPathComponent("plugin.json"))
            } catch {
                return finish(error)
            }
            let group = DispatchGroup()
            var firstError: Error?
            for file in files {
                group.enter()
                fetch("\(id)/\(file)") { result in
                    defer { group.leave() }
                    do {
                        let target = staging.appendingPathComponent(file)
                        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try result.get().write(to: target)
                    } catch {
                        if firstError == nil { firstError = error }
                    }
                }
            }
            group.notify(queue: .main) {
                defer { try? fm.removeItem(at: staging) }
                if let firstError { return finish(firstError) }
                do {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: folder(id).path) { try fm.removeItem(at: folder(id)) }
                    try fm.moveItem(at: staging, to: folder(id))
                    finish(nil)
                } catch {
                    finish(error)
                }
            }
        }
    }

    static func uninstall(_ id: String) throws {
        guard isValidID(id) else { return }
        try FileManager.default.removeItem(at: folder(id))
        detailsCache[id] = nil
        changed()
    }

    static func details(_ id: String, completion: @escaping (String) -> Void) {
        if let cached = detailsCache[id] { return completion(cached) }
        if isInstalled(id), let text = try? String(contentsOf: folder(id).appendingPathComponent("README.md"), encoding: .utf8) {
            detailsCache[id] = text
            return completion(text)
        }
        fetch("\(id)/README.md") { result in
            guard case .success(let data) = result, let text = String(data: data, encoding: .utf8) else {
                return completion(info(id)?.summary ?? "")
            }
            detailsCache[id] = text
            completion(text)
        }
    }

    static func search(_ query: String) -> [PluginInfo] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return catalog.filter { info in
            let text = [info.name, info.summary, info.author, info.fileExtensions.joined(separator: " ")]
                .joined(separator: " ").lowercased()
            return words.allSatisfy(text.contains)
        }
    }

    static func makeExtension(for url: URL, code: NSView) -> EditorExtension? {
        let ext = url.pathExtension.lowercased()
        return installedIDs.lazy
            .compactMap(installed)
            .filter { $0.fileExtensions.contains(ext) }
            .compactMap { ScriptExtension(info: $0, folder: folder($0.id), code: code) }
            .first
    }

    static func pageURL(_ id: String) -> URL { URL(string: "\(scheme)://\(id)")! }

    static func id(from url: URL) -> String? { url.scheme == scheme ? url.host : nil }

    static func symbol(_ name: String, size: CGFloat) -> NSImage {
        (NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "puzzlepiece", accessibilityDescription: nil)!)
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))!
    }

    static func actionTitle(_ id: String, long: Bool = false) -> String {
        if isBusy(id) { return "取得中…" }
        if hasUpdate(id) { return "更新" }
        if isInstalled(id) { return long ? "アンインストール" : "削除" }
        return "インストール"
    }
}

final class PluginRow: NSView {
    var onOpen: (() -> Void)?
    var onAction: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }

    init(info: PluginInfo) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: PluginStore.symbol(info.symbol, size: 18))
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let name = NSTextField(labelWithString: info.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        let version = NSTextField(labelWithString: "v\(PluginStore.installed(info.id)?.version ?? info.version)")
        version.font = .systemFont(ofSize: 10)
        version.textColor = .tertiaryLabelColor
        let title = NSStackView(views: [name, version])
        title.spacing = 4
        let summary = NSTextField(labelWithString: info.summary)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [title, summary])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let button = NSButton(title: PluginStore.actionTitle(info.id), target: self, action: #selector(actionClicked))
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        button.isEnabled = !PluginStore.isBusy(info.id)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [icon, texts, button])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    @objc private func actionClicked() { onAction?() }
}

final class PluginList: NSView {
    var onOpen: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    private let search = NSSearchField()
    private let list = NSStackView()

    init() {
        super.init(frame: .zero)
        search.placeholderString = "プラグインを検索"
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(reload)
        search.translatesAutoresizingMaskIntoConstraints = false
        let refresh = NSButton(image: PluginStore.symbol("arrow.clockwise", size: 12), target: self, action: #selector(refreshClicked))
        refresh.isBordered = false
        refresh.toolTip = "プラグイン一覧を再取得"
        refresh.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search)
        addSubview(refresh)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            refresh.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 6),
            refresh.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            refresh.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        reload()
        PluginStore.refreshCatalog()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func header(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let wrap = NSStackView(views: [label])
        wrap.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 2, right: 12)
        return wrap
    }

    @objc private func refreshClicked() { PluginStore.refreshCatalog() }

    @objc func reload() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if PluginStore.loading { list.addArrangedSubview(header("プラグイン一覧を取得中…")) }
        if let error = PluginStore.catalogError {
            list.addArrangedSubview(header("プラグイン一覧を取得できませんでした: \(error.localizedDescription)"))
        }
        let found = PluginStore.search(search.stringValue)
        if found.isEmpty {
            if !PluginStore.loading { list.addArrangedSubview(header("一致するプラグインはありません")) }
            return
        }
        let installed = found.filter { PluginStore.isInstalled($0.id) }
        let available = found.filter { !PluginStore.isInstalled($0.id) }
        for (title, plugins) in [("インストール済み", installed), ("利用可能", available)] where !plugins.isEmpty {
            list.addArrangedSubview(header(title))
            for info in plugins {
                let row = PluginRow(info: info)
                row.onOpen = { [weak self] in self?.onOpen?(info.id) }
                row.onAction = { [weak self] in
                    PluginStore.perform(info.id) { error in if let error { self?.onError?(error) } }
                }
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
    }
}

final class PluginPage: NSView {
    var onError: ((Error) -> Void)?
    private(set) var pluginID: String?
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let remove = NSButton(title: "アンインストール", target: nil, action: nil)
    private let text = NSTextView()

    init() {
        super.init(frame: .zero)
        icon.contentTintColor = .controlAccentColor
        name.font = .systemFont(ofSize: 22, weight: .bold)
        meta.textColor = .secondaryLabelColor
        for b in [button, remove] {
            b.bezelStyle = .rounded
            b.controlSize = .large
            b.target = self
        }
        button.action = #selector(actionClicked)
        remove.action = #selector(removeClicked)
        let buttons = NSStackView(views: [button, remove])
        buttons.spacing = 8
        let titles = NSStackView(views: [name, meta, buttons])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 6
        let header = NSStackView(views: [icon, titles])
        header.alignment = .top
        header.spacing = 16
        header.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        [header, line, scroll].forEach(addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            line.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ id: String) {
        pluginID = id
        refresh()
    }

    func refresh() {
        guard let id = pluginID, let info = PluginStore.info(id) else { return }
        let installed = PluginStore.isInstalled(id)
        let state = PluginStore.hasUpdate(id) ? "更新あり" : installed ? "インストール済み" : "未インストール"
        icon.image = PluginStore.symbol(info.symbol, size: 40)
        name.stringValue = info.name
        meta.stringValue = "v\(info.version)　·　\(info.author)　·　\(state)"
        button.title = PluginStore.actionTitle(id, long: true)
        button.isEnabled = !PluginStore.isBusy(id)
        remove.isHidden = !PluginStore.hasUpdate(id)
        remove.isEnabled = button.isEnabled
        PluginStore.details(id) { [weak self] markdown in
            guard let self, self.pluginID == id else { return }
            self.text.textStorage?.setAttributedString(renderMarkdown(markdown))
        }
    }

    @objc private func actionClicked() {
        guard let id = pluginID else { return }
        PluginStore.perform(id) { [weak self] error in if let error { self?.onError?(error) } }
    }

    @objc private func removeClicked() {
        guard let id = pluginID else { return }
        do { try PluginStore.uninstall(id) } catch { onError?(error) }
    }
}

final class ScriptExtension: NSObject, EditorExtension, WKNavigationDelegate {
    private enum Mode: Int { case code, split, preview }

    let bar = NSView()
    private let modeKey: String
    private let folder: URL
    private let context = JSContext()!
    private let renderer: JSValue
    private let split = NSSplitView()
    private let code: NSView
    private let preview: WKWebView
    private let modes: NSSegmentedControl
    private var pending: DispatchWorkItem?
    private var latest = ""
    private var mode: Mode
    private var ready = false
    private var queued: String?

    var body: NSView { split }

    init?(info: PluginInfo, folder: URL, code: NSView) {
        guard let script = try? String(contentsOf: folder.appendingPathComponent("main.js"), encoding: .utf8) else { return nil }
        context.evaluateScript(script, withSourceURL: folder.appendingPathComponent("main.js"))
        guard context.exception == nil, let render = context.objectForKeyedSubscript("render"), render.isObject else { return nil }
        renderer = render
        self.folder = folder
        self.code = code
        modeKey = "Plugin.\(info.id).Mode"
        mode = Mode(rawValue: UserDefaults.standard.integer(forKey: modeKey)) ?? .code

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        preview = WKWebView(frame: .zero, configuration: config)

        let images = ["doc.plaintext", "rectangle.split.2x1", "eye"].map { PluginStore.symbol($0, size: 12) }
        modes = NSSegmentedControl(images: images, trackingMode: .selectOne, target: nil, action: nil)
        super.init()
        modes.controlSize = .small
        for (i, label) in ["コード", "コード＋プレビュー", "プレビュー"].enumerated() {
            modes.setLabel(label, forSegment: i)
            modes.setToolTip(label, forSegment: i)
            modes.setImageScaling(.scaleProportionallyDown, forSegment: i)
        }
        modes.target = self
        modes.action = #selector(modeChanged)
        modes.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: info.name)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        [modes, title, line].forEach(bar.addSubview)
        NSLayoutConstraint.activate([
            modes.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            modes.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: -1),
            title.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            title.centerYAnchor.constraint(equalTo: modes.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])

        preview.navigationDelegate = self
        code.removeFromSuperview()
        code.translatesAutoresizingMaskIntoConstraints = true
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(code)
        split.addArrangedSubview(preview)
        applySettings()
        apply(mode)
    }

    func update(text: String) {
        latest = text
        pending?.cancel()
        guard mode != .code else { return }
        let work = DispatchWorkItem { [weak self] in self?.render() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func applySettings() {
        preview.underPageBackgroundColor = Settings.background
        render()
    }

    private static func css(_ color: NSColor) -> String {
        var rgb = color
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { rgb = color.usingColorSpace(.sRGB) ?? color }
        return String(format: "rgba(%d,%d,%d,%.3f)", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255), rgb.alphaComponent)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func render() {
        guard mode != .code else { return }
        let settings: [String: Any] = [
            "background": Self.css(Settings.background),
            "foreground": Self.css(Settings.foreground),
            "fontSize": Double(max(Settings.fontSize, 12)),
            "fontName": Settings.font.familyName ?? "",
            "dark": Settings.background.isDark,
        ]
        context.exception = nil
        let result = renderer.call(withArguments: [latest, settings])
        let html: String
        if let exception = context.exception {
            html = "<pre style=\"color:#d33;white-space:pre-wrap\">\(Self.escape(exception.toString()))</pre>"
        } else {
            html = result?.toString() ?? ""
        }
        show(html)
    }

    private func show(_ html: String) {
        guard ready else {
            if queued == nil { preview.loadHTMLString(html, baseURL: folder) }
            queued = html
            return
        }
        preview.callAsyncJavaScript("document.documentElement.innerHTML = html", arguments: ["html": html],
                                    in: nil, in: .defaultClient, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if let html = queued {
            queued = nil
            show(html)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    @objc private func modeChanged() {
        guard let next = Mode(rawValue: modes.selectedSegment) else { return }
        UserDefaults.standard.set(next.rawValue, forKey: modeKey)
        apply(next)
    }

    private func apply(_ next: Mode) {
        mode = next
        modes.selectedSegment = next.rawValue
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
