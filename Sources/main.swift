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
    s.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        .split(separator: ".")
        .map { Int($0.prefix { $0.isNumber }) ?? 0 }
}

func isNewer(_ remote: String, than local: String) -> Bool {
    let r = versionParts(remote), l = versionParts(local)
    for i in 0..<max(r.count, l.count) {
        let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
        if a != b { return a > b }
    }
    return false
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
        let update = NSButton(title: "アップデート", target: self, action: #selector(updateClicked))
        update.bezelStyle = .rounded
        update.controlSize = .small
        update.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "アップデート")
        update.imagePosition = .imageLeading
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
        text.string = release.body ?? ""
        text.isEditable = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
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
        updateButton?.title = "インストール中…"

        updater.install(release) { [weak self] error in
            guard let self else { return }
            let alert = NSAlert()
            if let error {
                self.updateButton?.isEnabled = true
                self.updateButton?.title = "アップデート"
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
