import AppKit

let appName = "FlareStackIDE"
let releasesURL = URL(string: "https://api.github.com/repos/infinc/FlareStackIDE/releases/latest")!

struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let body: String?
    let assets: [Asset]

    var dmg: Asset? { assets.first { $0.name.hasSuffix(".dmg") } }
}

func versionParts(_ s: String) -> [Int] {
    guard let range = s.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return [] }
    return s[range].split(separator: ".").map { Int($0) ?? 0 }
}

func isNewer(_ remote: String, than local: String) -> Bool {
    let r = versionParts(remote), l = versionParts(local)
    for i in 0..<max(r.count, l.count) {
        let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
        if a != b { return a > b }
    }
    return false
}

func renderInlineMarkdown(_ line: String, font base: NSFont) -> NSAttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    guard let parsed = try? AttributedString(markdown: line, options: options) else {
        return NSAttributedString(string: line, attributes: [.font: base, .foregroundColor: NSColor.labelColor])
    }
    let result = NSMutableAttributedString()
    let fm = NSFontManager.shared
    for run in parsed.runs {
        var font = base
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.code) {
            font = .monospacedSystemFont(ofSize: base.pointSize * 0.95, weight: .regular)
        } else {
            if intent.contains(.stronglyEmphasized) { font = fm.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = fm.convert(font, toHaveTrait: .italicFontMask) }
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if intent.contains(.code) { attrs[.backgroundColor] = NSColor.quaternaryLabelColor }
        if let link = run.link { attrs[.link] = link }
        result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
    }
    return result
}

func renderMarkdown(_ markdown: String) -> NSAttributedString {
    let size = NSFont.systemFontSize
    let body = NSFont.systemFont(ofSize: size)
    let output = NSMutableAttributedString()
    var inCode = false

    func paragraph(indent: CGFloat = 0, head: CGFloat = 0, spacing: CGFloat = 4) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent + head
        style.paragraphSpacing = spacing
        return style
    }

    func append(_ text: NSAttributedString, _ style: NSParagraphStyle) {
        let line = NSMutableAttributedString(attributedString: text)
        line.append(NSAttributedString(string: "\n"))
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        output.append(line)
    }

    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    for raw in lines {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { inCode.toggle(); continue }
        if inCode {
            let mono = NSFont.monospacedSystemFont(ofSize: size * 0.95, weight: .regular)
            append(NSAttributedString(string: raw, attributes: [.font: mono, .foregroundColor: NSColor.labelColor,
                                                                .backgroundColor: NSColor.quaternaryLabelColor]),
                   paragraph(indent: 8, spacing: 0))
            continue
        }
        if trimmed.isEmpty { continue }

        let depth = CGFloat(raw.prefix { $0 == " " || $0 == "\t" }.count / 2) * 16

        if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            let level = trimmed[m].filter { $0 == "#" }.count
            let font = NSFont.boldSystemFont(ofSize: size + CGFloat(max(0, 4 - level)) * 2)
            append(renderInlineMarkdown(String(trimmed[m.upperBound...]), font: font), paragraph(spacing: 6))
        } else if trimmed.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil {
            append(NSAttributedString(string: String(repeating: "─", count: 30),
                                      attributes: [.font: body, .foregroundColor: NSColor.separatorColor]), paragraph())
        } else if let m = trimmed.range(of: #"^[-*+]\s+(\[[ xX]\]\s+)?"#, options: .regularExpression) {
            let marker = trimmed[m]
            let bullet = marker.contains("[x]") || marker.contains("[X]") ? "☑︎ " : marker.contains("[ ]") ? "☐ " : "• "
            let line = NSMutableAttributedString(string: bullet, attributes: [.font: body, .foregroundColor: NSColor.labelColor])
            line.append(renderInlineMarkdown(String(trimmed[m.upperBound...]), font: body))
            append(line, paragraph(indent: depth + 8, head: 12))
        } else if let m = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            let number = trimmed[m].trimmingCharacters(in: .whitespaces)
            let line = NSMutableAttributedString(string: number + " ", attributes: [.font: body, .foregroundColor: NSColor.labelColor])
            line.append(renderInlineMarkdown(String(trimmed[m.upperBound...]), font: body))
            append(line, paragraph(indent: depth + 8, head: 18))
        } else if let m = trimmed.range(of: #"^>\s?"#, options: .regularExpression) {
            let line = NSMutableAttributedString(attributedString: renderInlineMarkdown(String(trimmed[m.upperBound...]), font: body))
            line.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: line.length))
            append(line, paragraph(indent: 12))
        } else {
            append(renderInlineMarkdown(trimmed, font: body), paragraph())
        }
    }
    return output
}

@discardableResult
func run(_ path: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    if p.terminationStatus != 0 {
        throw NSError(domain: appName, code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(path) \(args.joined(separator: " "))\n\(text)"])
    }
    return text
}

final class Updater {
    let currentVersion: String

    init(currentVersion: String) {
        self.currentVersion = currentVersion
    }

    func checkLatest(_ completion: @escaping (Release?) -> Void) {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [currentVersion] data, response, _ in
            var result: Release?
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let release = try? JSONDecoder().decode(Release.self, from: data),
               isNewer(release.tag_name, than: currentVersion) {
                result = release
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    func install(_ release: Release, completion: @escaping (Error?) -> Void) {
        guard let asset = release.dmg else {
            completion(NSError(domain: appName, code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "リリースに .dmg が見つかりません"]))
            return
        }
        URLSession.shared.downloadTask(with: asset.browser_download_url) { location, _, error in
            var failure = error
            if let location, failure == nil {
                do { try Self.replaceApp(fromDMG: location) } catch { failure = error }
            }
            DispatchQueue.main.async { completion(failure) }
        }.resume()
    }

    private static func replaceApp(fromDMG dmg: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("\(appName)-update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let source = mount.appendingPathComponent("\(appName).app")
        guard fm.fileExists(atPath: source.path) else {
            throw NSError(domain: appName, code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "dmg 内に \(appName).app が見つかりません"])
        }
        let target = Bundle.main.bundleURL
        let staged = target.deletingLastPathComponent().appendingPathComponent(".\(appName)-update.app")
        try? fm.removeItem(at: staged)
        defer { try? fm.removeItem(at: staged) }
        try run("/usr/bin/ditto", [source.path, staged.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        _ = try fm.replaceItemAt(target, withItemAt: staged)
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var splash: NSWindow?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var updateButton: NSButton?
    private var latestRelease: Release?
    private lazy var updater = Updater(currentVersion: currentVersion)

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showSplash()
        updater.checkLatest { [weak self] release in
            self?.latestRelease = release
            self?.updateButton?.isHidden = release == nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.splash?.orderOut(nil)
            self?.splash = nil
            self?.showMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func showSplash() {
        guard let url = Bundle.main.url(forResource: "interpolate", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        let pixels = image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        let size = NSSize(width: pixels.width / 2, height: pixels.height / 2)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = view
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        splash = window
    }

    private func showMainWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(appName) v\(currentVersion)"
        window.isReleasedWhenClosed = false
        window.addTitlebarAccessoryViewController(makeToolbarAccessory())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }

    private func makeToolbarAccessory() -> NSTitlebarAccessoryViewController {
        let update = NSButton(image: NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "アップデート")!,
                              target: self, action: #selector(updateClicked))
        update.bezelStyle = .texturedRounded
        update.isBordered = false
        update.toolTip = "アップデート"
        update.isHidden = latestRelease == nil
        updateButton = update

        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "設定")!,
                            target: self, action: #selector(settingsClicked))
        gear.bezelStyle = .texturedRounded
        gear.isBordered = false
        gear.toolTip = "設定"

        let stack = NSStackView()
        stack.addView(update, in: .trailing)
        stack.addView(gear, in: .trailing)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        stack.frame = NSRect(x: 0, y: 0, width: 150, height: 28)

        let controller = NSTitlebarAccessoryViewController()
        controller.view = stack
        controller.layoutAttribute = .trailing
        return controller
    }

    @objc private func settingsClicked() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "設定"
            window.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "\(appName) v\(currentVersion)")
            label.frame = NSRect(x: 20, y: 190, width: 380, height: 20)
            window.contentView?.addSubview(label)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func updateClicked() {
        guard let release = latestRelease, let window = mainWindow else { return }

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        text.textStorage?.setAttributedString(renderMarkdown(release.body ?? ""))
        text.isEditable = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let alert = NSAlert()
        alert.messageText = "\(appName) \(release.tag_name) が利用可能です"
        alert.informativeText = "現在のバージョン: v\(currentVersion)"
        alert.accessoryView = scroll
        alert.addButton(withTitle: "アップデートする")
        alert.addButton(withTitle: "しない")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.install(release) }
        }
    }

    private func install(_ release: Release) {
        guard let window = mainWindow else { return }
        updateButton?.isEnabled = false
        updateButton?.toolTip = "インストール中…"

        updater.install(release) { [weak self] error in
            guard let self else { return }
            let alert = NSAlert()
            if let error {
                self.updateButton?.isEnabled = true
                self.updateButton?.toolTip = "アップデート"
                alert.alertStyle = .warning
                alert.messageText = "アップデートに失敗しました"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
                return
            }
            self.updateButton?.isHidden = true
            alert.messageText = "\(release.tag_name) のインストールが完了しました"
            alert.informativeText = "今すぐ再起動しますか？"
            alert.addButton(withTitle: "再起動する")
            alert.addButton(withTitle: "しない")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { Updater.relaunch() }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
