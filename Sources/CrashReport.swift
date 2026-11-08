import AppKit

enum CrashReport {
    private static let autoKey = "CrashReport.Auto"
    private static let api = "https://api.github.com"

    static var automatic: Bool {
        get { UserDefaults.standard.bool(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    struct Crash {
        let id: String
        let name: String
        let version: String
        let count: Int
        let exception: String?
        let frames: [String]

        var title: String { "[Crash] \(name) v\(version) (\(id))" }
    }

    private static var pending: [String: Crash] = [:]

    static func collect(_ ids: [String]) {
        let report = latestDiagnostic()
        for id in ids {
            let info = PluginStore.info(id)
            let matched = report.flatMap { parse($0, id: id) }
            pending[id] = Crash(id: id, name: info?.name ?? id, version: info?.version ?? "?", count: PluginGuard.crashCount(id),
                                exception: matched?.exception, frames: matched?.frames ?? [])
        }
        guard automatic else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { ids.compactMap { pending[$0] }.forEach { submit($0, quiet: true) } }
    }

    static func actions(for id: String) -> [Toast.Action] {
        guard !automatic, pending[id] != nil else { return [] }
        return [("Issue に報告", { confirm(id) })]
    }

    private static func confirm(_ id: String) {
        guard let crash = pending[id] else { return }
        let alert = NSAlert()
        alert.messageText = "\(crash.name) のクラッシュを GitHub の Issue に報告しますか？"
        alert.informativeText = "\(repositoryPath) の公開の Issue に次の内容を送ります。ファイルの内容やパスは送りません。"
        let preview = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        preview.string = body(crash)
        preview.isEditable = false
        preview.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        scroll.documentView = preview
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "報告する")
        alert.addButton(withTitle: "キャンセル")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "次からは自動で報告する"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if alert.suppressionButton?.state == .on { automatic = true }
        submit(crash, quiet: false)
    }

    private static func submit(_ crash: Crash, quiet: Bool) {
        DispatchQueue.global(qos: .utility).async {
            guard let token = GitHub.token() else {
                DispatchQueue.main.async {
                    Toasts.post("クラッシュを報告できませんでした", message: "GitHub と連携していません。ブラウザで Issue を作成できます",
                                actions: [("ブラウザで開く", { openInBrowser(crash) })])
                }
                return
            }
            Task {
                let result: Result<URL?, Error>
                do { result = .success(try await send(crash, token: token)) } catch { result = .failure(error) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let url):
                        pending[crash.id] = nil
                        Toasts.post("\(crash.name) のクラッシュを Issue に報告しました", message: quiet ? "設定で自動の報告をオフにできます" : nil,
                                    actions: url.map { link in [("Issue を開く", { NSWorkspace.shared.open(link) })] } ?? [])
                    case .failure(let error):
                        Toasts.post("クラッシュを報告できませんでした", message: error.localizedDescription,
                                    actions: [("ブラウザで開く", { openInBrowser(crash) })])
                    }
                }
            }
        }
    }

    private static func request(_ path: String, token: String, method: String = "GET", json: [String: Any]? = nil) async throws -> Any {
        var request = URLRequest(url: URL(string: api + path)!)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = status == 401 ? "トークンが無効です" : status == 403 || status == 404 ? "Issue を作成する権限がありません (\(status))" : "GitHub API エラー (\(status))"
            throw NSError(domain: appName, code: status, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func send(_ crash: Crash, token: String) async throws -> URL? {
        let query = "repo:\(repositoryPath) is:issue is:open in:title \"\(crash.title)\""
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let search = try await request("/search/issues?" + (components.percentEncodedQuery ?? ""), token: token) as? [String: Any]
        let items = search?["items"] as? [[String: Any]] ?? []
        if let issue = items.first(where: { $0["title"] as? String == crash.title }), let number = issue["number"] as? Int {
            let comment = try await request("/repos/\(repositoryPath)/issues/\(number)/comments", token: token, method: "POST",
                                            json: ["body": body(crash)]) as? [String: Any]
            return (comment?["html_url"] as? String).flatMap(URL.init(string:))
        }
        let created = try await request("/repos/\(repositoryPath)/issues", token: token, method: "POST",
                                        json: ["title": crash.title, "body": body(crash)]) as? [String: Any]
        return (created?["html_url"] as? String).flatMap(URL.init(string:))
    }

    private static func openInBrowser(_ crash: Crash) {
        var components = URLComponents(string: "https://github.com/\(repositoryPath)/issues/new")!
        components.queryItems = [URLQueryItem(name: "title", value: crash.title), URLQueryItem(name: "body", value: body(crash, frames: 12))]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    static func body(_ crash: Crash, frames limit: Int = 30) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var lines = [
            "\(appName) が送ったクラッシュ報告です。",
            "",
            "| 項目 | 値 |",
            "|---|---|",
            "| プラグイン | \(crash.name) (`\(crash.id)`) v\(crash.version) |",
            "| \(appName) | v\(AppUpdate.shared.currentVersion) |",
            "| macOS | \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(arch)) |",
            "| 続けて終了した回数 | \(crash.count) |",
        ]
        if let exception = crash.exception { lines.append("| 例外 | \(exception) |") }
        if !crash.frames.isEmpty {
            lines += ["", "<details><summary>クラッシュしたスレッド</summary>", "", "```"]
            lines += crash.frames.prefix(limit).enumerated().map { "\($0.offset)  \($0.element)" }
            lines += ["```", "", "</details>"]
        }
        return lines.joined(separator: "\n")
    }

    private static func latestDiagnostic() -> String? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return nil }
        let limit = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let newest = files
            .filter { $0.lastPathComponent.hasPrefix(appName) && $0.pathExtension == "ips" }
            .compactMap { url in (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate).map { (url, $0) } }
            .filter { $0.1 > limit }
            .max { $0.1 < $1.1 }
        return newest.flatMap { try? String(contentsOf: $0.0, encoding: .utf8) }
    }

    private static func parse(_ text: String, id: String) -> (exception: String?, frames: [String])? {
        guard let newline = text.firstIndex(of: "\n"),
              let root = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any]
        else { return nil }
        let images = root["usedImages"] as? [[String: Any]] ?? []
        let marker = "/Plugins/\(id)/"
        guard images.contains(where: { ($0["path"] as? String)?.contains(marker) == true }) else { return nil }
        func imageName(_ index: Int?) -> String {
            guard let index, images.indices.contains(index) else { return "?" }
            let path = images[index]["path"] as? String ?? ""
            if let range = path.range(of: "/Plugins/") {
                return String(path[range.upperBound...])
            }
            return images[index]["name"] as? String ?? (path as NSString).lastPathComponent
        }
        let home = NSHomeDirectory()
        let threads = root["threads"] as? [[String: Any]] ?? []
        let crashed = threads.first { $0["triggered"] as? Bool == true } ?? threads.first
        let frames = (crashed?["frames"] as? [[String: Any]] ?? []).map { frame -> String in
            let image = imageName(frame["imageIndex"] as? Int)
            let symbol = (frame["symbol"] as? String).map { $0.replacingOccurrences(of: home, with: "~") }
                ?? String(format: "0x%llx", (frame["imageOffset"] as? NSNumber)?.uint64Value ?? 0)
            return "\(image)  \(symbol)"
        }
        var exception: String?
        if let info = root["exception"] as? [String: Any] {
            exception = [info["type"] as? String, (info["signal"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        }
        return (exception, frames)
    }
}
