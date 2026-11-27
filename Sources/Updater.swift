import AppKit

let appName = "FlareStackIDE"
let repositoryPath = "infinc/FlareStackIDE"
let releasesURL = URL(string: "https://api.github.com/repos/\(repositoryPath)/releases/latest")!

struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let body: String?
    let assets: [Asset]

    var dmg: Asset? { assets.first { $0.name.hasSuffix(".dmg") && !$0.name.hasSuffix("-debug.dmg") } }

    var dmgSignature: Asset? { dmg.flatMap { dmg in assets.first { $0.name == dmg.name + ".sig" } } }
}

func versionParts(_ s: String) -> [Int] {
    guard let range = s.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return [] }
    return s[range].split(separator: ".").map { Int($0) ?? 0 }
}

func preRelease(_ s: String) -> String? {
    guard let range = s.range(of: #"\d+(\.\d+)*-([0-9A-Za-z.-]+)"#, options: .regularExpression) else { return nil }
    let text = s[range]
    guard let dash = text.firstIndex(of: "-") else { return nil }
    var tag = String(text[text.index(after: dash)...])
    if tag == "debug" { return nil }
    if tag.hasSuffix("-debug") { tag.removeLast("-debug".count) }
    return tag
}

func isNewer(_ remote: String, than local: String) -> Bool {
    let r = versionParts(remote), l = versionParts(local)
    for i in 0..<max(r.count, l.count) {
        let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
        if a != b { return a > b }
    }
    switch (preRelease(remote), preRelease(local)) {
    case (nil, nil): return false
    case (nil, _): return true
    case (_, nil): return false
    case let (a?, b?): return a.compare(b, options: .numeric) == .orderedDescending
    }
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
        let fail = { (message: String) in
            completion(NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        }
        guard let asset = release.dmg else { return fail("リリースに .dmg が見つかりません") }
        guard let signatureAsset = release.dmgSignature else { return fail("リリースに \(asset.name).sig（署名）が見つかりません") }
        URLSession.shared.dataTask(with: signatureAsset.browser_download_url) { signature, response, error in
            guard let signature, error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else {
                return DispatchQueue.main.async { fail(error?.localizedDescription ?? "署名を取得できませんでした") }
            }
            URLSession.shared.downloadTask(with: asset.browser_download_url) { location, _, error in
                var failure = error
                if let location, failure == nil {
                    do {
                        let data = try Data(contentsOf: location, options: .mappedIfSafe)
                        guard PluginTrust.isSigned(data, signature: signature) else {
                            throw PluginTrust.error("\(asset.name) の署名を確認できませんでした。配布元が違うか、ファイルが改ざんされています")
                        }
                        try Self.replaceApp(fromDMG: location)
                    } catch {
                        failure = error
                    }
                }
                DispatchQueue.main.async { completion(failure) }
            }.resume()
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

extension Notification.Name {
    static let appUpdateChanged = Notification.Name("FlareStackIDE.appUpdateChanged")
}

final class AppUpdate {
    static let shared = AppUpdate()
    private(set) var latest: Release?
    private(set) var installing = false
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private lazy var updater = Updater(currentVersion: currentVersion)

    private func changed() { NotificationCenter.default.post(name: .appUpdateChanged, object: nil) }

    func check() {
        updater.checkLatest { [weak self] release in
            self?.latest = release
            self?.changed()
        }
    }

    func present(in window: NSWindow) {
        guard let release = latest, !installing else { return }
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
            if response == .alertFirstButtonReturn { self?.install(release, in: window) }
        }
    }

    private func install(_ release: Release, in window: NSWindow) {
        installing = true
        changed()
        let toast = Toasts.progress("\(appName) \(release.tag_name) をインストール中", in: window)
        toast?.update("ダウンロードしています…", 0.3)
        updater.install(release) { [weak self] error in
            guard let self else { return }
            self.installing = false
            let alert = NSAlert()
            if let error {
                toast?.finish("アップデートに失敗しました", failed: true)
                self.changed()
                alert.alertStyle = .warning
                alert.messageText = "アップデートに失敗しました"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
                return
            }
            toast?.finish("インストールが完了しました")
            self.latest = nil
            self.changed()
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
