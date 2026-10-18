import AppKit
import Security

struct GitHubRepo: Decodable {
    let full_name: String
    let name: String
    let clone_url: String
    let `private`: Bool
    let description: String?
}

struct GitHubUser: Decodable {
    let login: String
}

struct CloneRequest {
    let remote: String
    let name: String
    let destination: URL
    let token: String?
}

enum GitHub {
    private static let service = "\(appName).github"
    private static let ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    static var savedToken: String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(token: String) {
        forget()
        let attrs: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "token", kSecValueData as String: Data(token.utf8)]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func forget() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    static func ghToken() -> String? {
        for path in ghPaths where FileManager.default.isExecutableFile(atPath: path) {
            if let out = try? run(path, ["auth", "token"]) {
                let token = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty, !token.contains(" ") { return token }
            }
        }
        return nil
    }

    static func token() -> String? { savedToken ?? ghToken() }

    private static func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = http.statusCode == 401 ? "トークンが無効です。" : "GitHub API エラー (\(http.statusCode))"
            throw NSError(domain: appName, code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func user(token: String) async throws -> GitHubUser {
        try await get("/user", token: token)
    }

    static func repos(token: String) async throws -> [GitHubRepo] {
        var all: [GitHubRepo] = []
        for page in 1...10 {
            let batch: [GitHubRepo] = try await get(
                "/user/repos?per_page=100&page=\(page)&sort=updated&affiliation=owner,collaborator,organization_member",
                token: token)
            all += batch
            if batch.count < 100 { break }
        }
        return all
    }

    static func remote(from input: String) -> (remote: String, name: String)? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") || text.hasPrefix("git@") {
            let last = text.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
            let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
            return name.isEmpty ? nil : (text, name)
        }
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }) else { return nil }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return ("https://github.com/\(parts[0])/\(name).git", name)
    }
}

final class GitClone {
    private let process = Process()
    private var buffer = ""
    private var tail: [String] = []
    private static let phases: [(key: String, label: String, lo: Double, hi: Double)] = [
        ("Counting objects", "オブジェクトを数えています", 0, 0.05),
        ("Compressing objects", "オブジェクトを圧縮しています", 0.05, 0.1),
        ("Receiving objects", "受信しています", 0.1, 0.8),
        ("Resolving deltas", "差分を解決しています", 0.8, 0.95),
        ("Updating files", "ファイルを展開しています", 0.95, 1),
    ]

    init(_ request: CloneRequest, progress: @escaping (String, Double) -> Void, completion: @escaping (Error?) -> Void) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", "--progress", request.remote, request.destination.path]
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        if let token = request.token, request.remote.hasPrefix("https://github.com/") {
            let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
            env["GIT_CONFIG_COUNT"] = "1"
            env["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
            env["GIT_CONFIG_VALUE_0"] = "AUTHORIZATION: basic \(basic)"
        }
        process.environment = env
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(text, progress) }
        }
        process.terminationHandler = { [weak self] p in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                if p.terminationStatus == 0 {
                    progress("完了", 1)
                    completion(nil)
                } else {
                    let message = self.tail.suffix(6).joined(separator: "\n")
                    completion(NSError(domain: appName, code: Int(p.terminationStatus),
                                       userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "クローンに失敗しました。" : message]))
                }
            }
        }
        do {
            try process.run()
        } catch {
            completion(error)
        }
    }

    func cancel() { if process.isRunning { process.terminate() } }

    private func consume(_ text: String, _ progress: (String, Double) -> Void) {
        buffer += text
        let lines = buffer.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        buffer = lines.last ?? ""
        for line in lines.dropLast() where !line.isEmpty {
            if !line.contains("%") { tail.append(line) }
            guard let phase = Self.phases.first(where: { line.contains($0.key + ":") }),
                  let range = line.range(of: #"\d+(?=%)"#, options: .regularExpression),
                  let percent = Double(line[range]) else { continue }
            progress("\(phase.label) \(Int(percent))%", phase.lo + (phase.hi - phase.lo) * percent / 100)
        }
    }
}

final class ProgressToast: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "準備しています…")
    private let bar = NSProgressIndicator()

    init(title: String) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1

        let stack = NSStackView(views: [titleLabel, bar, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 300),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ status: String, _ value: Double) {
        statusLabel.stringValue = status
        bar.doubleValue = value
    }

    func finish(_ status: String, failed: Bool = false) {
        statusLabel.stringValue = status
        statusLabel.textColor = failed ? .systemRed : .systemGreen
        if !failed { bar.doubleValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + (failed ? 6 : 3)) { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self?.animator().alphaValue = 0 }) {
                self?.removeFromSuperview()
            }
        }
    }
}

final class CloneWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onClone: ((CloneRequest) -> Void)?

    private static let parentKey = "CloneParent"
    private let mode = NSSegmentedControl(labels: ["自分のリポジトリ", "URL / ユーザー名"], trackingMode: .selectOne, target: nil, action: nil)
    private let accountPane = NSView()
    private let manualPane = NSStackView()
    private let linkPane = NSStackView()
    private let repoPane = NSStackView()
    private let tokenField = NSSecureTextField()
    private let accountLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let search = NSSearchField()
    private let table = NSTableView()
    private let urlField = NSTextField()
    private let userField = NSTextField()
    private let repoField = NSTextField()
    private let parentLabel = NSTextField(labelWithString: "")
    private let nameField = NSTextField()
    private let cloneButton = NSButton(title: "クローン", target: nil, action: nil)
    private var token: String?
    private var repos: [GitHubRepo] = []
    private var shown: [GitHubRepo] = []
    private var lastSuggested = ""
    private var parent: URL

    init() {
        parent = UserDefaults.standard.string(forKey: Self.parentKey).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "GitHubからクローン"
        super.init(window: window)
        build()
        loadAccount()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: secondary ? 11 : 12)
        if secondary { field.textColor = .secondaryLabelColor }
        return field
    }

    private func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func vertical(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func build() {
        guard let content = window?.contentView else { return }
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)

        tokenField.placeholderString = "ghp_… / github_pat_…"
        let makeToken = NSButton(title: "トークンを作成…", target: self, action: #selector(createToken))
        let link = NSButton(title: "連携", target: self, action: #selector(linkClicked))
        let linkButtons = NSStackView(views: [makeToken, link])
        [linkPane, repoPane].forEach {
            $0.orientation = .vertical
            $0.alignment = .leading
            $0.spacing = 10
        }
        linkPane.setViews([
            label("GitHubと連携すると、自分のリポジトリから選んでクローンできます。"),
            label("Personal Access Token（repo 権限）を入力してください。トークンはキーチェーンに保存されます。gh CLI でログイン済みの場合は自動で連携します。", secondary: true),
            tokenField, linkButtons,
        ], in: .top)
        tokenField.widthAnchor.constraint(equalTo: linkPane.widthAnchor).isActive = true

        let unlink = NSButton(title: "連携解除", target: self, action: #selector(unlinkClicked))
        unlink.bezelStyle = .inline
        let accountRow = NSStackView(views: [accountLabel, unlink])
        search.placeholderString = "リポジトリを検索"
        search.delegate = self
        let column = NSTableColumn(identifier: .init("repo"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.target = self
        table.doubleAction = #selector(cloneClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        repoPane.setViews([accountRow, search, scroll], in: .top)
        search.widthAnchor.constraint(equalTo: repoPane.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: repoPane.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        statusLabel.textColor = .secondaryLabelColor
        let accountStack = vertical([statusLabel, linkPane, repoPane])
        pin(accountStack, in: accountPane)
        linkPane.widthAnchor.constraint(equalTo: accountStack.widthAnchor).isActive = true
        repoPane.widthAnchor.constraint(equalTo: accountStack.widthAnchor).isActive = true
        linkPane.isHidden = true
        repoPane.isHidden = true

        urlField.placeholderString = "https://github.com/owner/repo.git"
        userField.placeholderString = "ユーザー名"
        repoField.placeholderString = "リポジトリ名"
        [urlField, userField, repoField].forEach { $0.delegate = self }
        let slash = NSTextField(labelWithString: "/")
        let pair = NSStackView(views: [userField, slash, repoField])
        userField.widthAnchor.constraint(equalTo: repoField.widthAnchor).isActive = true
        manualPane.orientation = .vertical
        manualPane.alignment = .leading
        manualPane.spacing = 8
        manualPane.setViews([label("URL"), urlField, label("または ユーザー名 / リポジトリ", secondary: true), pair], in: .top)
        urlField.widthAnchor.constraint(equalTo: manualPane.widthAnchor).isActive = true
        pair.widthAnchor.constraint(equalTo: manualPane.widthAnchor).isActive = true
        manualPane.isHidden = true

        let panes = NSView()
        pin(accountPane, in: panes)
        pin(manualPane, in: panes)

        parentLabel.lineBreakMode = .byTruncatingMiddle
        parentLabel.textColor = .secondaryLabelColor
        parentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "変更…", target: self, action: #selector(chooseParent))
        let parentRow = NSStackView(views: [label("保存先"), parentLabel, choose])
        nameField.placeholderString = "フォルダ名"
        let nameRow = NSStackView(views: [label("フォルダ名"), nameField])

        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        cloneButton.target = self
        cloneButton.action = #selector(cloneClicked)
        cloneButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, cloneButton])

        let separator = NSBox()
        separator.boxType = .separator
        let root = vertical([mode, panes, separator, parentRow, nameRow, buttons], spacing: 12)
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        root.setCustomSpacing(16, after: mode)
        pin(root, in: content)
        for view in [panes, separator, parentRow, nameRow] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        }
        buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20).isActive = true
        mode.centerXAnchor.constraint(equalTo: root.centerXAnchor).isActive = true
        content.widthAnchor.constraint(equalToConstant: 560).isActive = true
        content.heightAnchor.constraint(equalToConstant: 500).isActive = true
        updateParent()
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
    }

    private func loadAccount() {
        setStatus("GitHubアカウントを確認しています…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let token = GitHub.token()
            DispatchQueue.main.async { self?.useToken(token, save: false) }
        }
    }

    private func useToken(_ token: String?, save: Bool) {
        guard let token else {
            setStatus("")
            linkPane.isHidden = false
            repoPane.isHidden = true
            return
        }
        setStatus("リポジトリを読み込んでいます…")
        linkPane.isHidden = true
        Task { [weak self] in
            do {
                let user = try await GitHub.user(token: token)
                let repos = try await GitHub.repos(token: token)
                if save { GitHub.save(token: token) }
                self?.showRepos(repos, token: token, login: user.login)
            } catch {
                self?.setStatus(error.localizedDescription)
                self?.linkPane.isHidden = false
            }
        }
    }

    private func showRepos(_ repos: [GitHubRepo], token: String, login: String) {
        self.token = token
        self.repos = repos
        setStatus("")
        accountLabel.stringValue = "@\(login) として連携中（\(repos.count) 件）"
        repoPane.isHidden = false
        filter()
    }

    private func filter() {
        let query = search.stringValue.lowercased()
        shown = query.isEmpty ? repos : repos.filter { $0.full_name.lowercased().contains(query) }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === search { filter() } else { manualChanged() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let repo = shown[row]
        let name = NSTextField(labelWithString: repo.full_name + (repo.private ? "  🔒" : ""))
        name.font = .systemFont(ofSize: 12, weight: .medium)
        let detail = NSTextField(labelWithString: repo.description ?? "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return vertical([name, detail], spacing: 1)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0 else { return }
        suggest(shown[table.selectedRow].name)
    }

    private func suggest(_ name: String) {
        if nameField.stringValue.isEmpty || nameField.stringValue == lastSuggested { nameField.stringValue = name }
        lastSuggested = name
    }

    @objc private func manualChanged() {
        if let target = manualTarget() { suggest(target.name) }
    }

    private func manualTarget() -> (remote: String, name: String)? {
        if let target = GitHub.remote(from: urlField.stringValue) { return target }
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let repo = repoField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !repo.isEmpty else { return nil }
        return GitHub.remote(from: "\(user)/\(repo)")
    }

    @objc private func modeChanged() {
        accountPane.isHidden = mode.selectedSegment != 0
        manualPane.isHidden = mode.selectedSegment != 1
        window?.makeFirstResponder(mode.selectedSegment == 0 ? search : urlField)
    }

    @objc private func createToken() {
        NSWorkspace.shared.open(URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=\(appName)")!)
    }

    @objc private func linkClicked() {
        let value = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        useToken(value, save: true)
    }

    @objc private func unlinkClicked() {
        GitHub.forget()
        token = nil
        repos = []
        shown = []
        table.reloadData()
        tokenField.stringValue = ""
        repoPane.isHidden = true
        linkPane.isHidden = false
        setStatus(GitHub.ghToken() == nil ? "" : "gh CLI のログインは gh auth logout で解除できます。")
    }

    private func updateParent() {
        parentLabel.stringValue = (parent.path as NSString).abbreviatingWithTildeInPath
    }

    @objc private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = parent
        panel.prompt = "選択"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.parent = url
            UserDefaults.standard.set(url.path, forKey: Self.parentKey)
            self.updateParent()
        }
    }

    private func alert(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    @objc private func cancelClicked() { close(nil) }

    @objc private func cloneClicked() {
        let target: (remote: String, name: String)?
        var auth: String?
        if mode.selectedSegment == 0 {
            target = table.selectedRow >= 0 ? (shown[table.selectedRow].clone_url, shown[table.selectedRow].name) : nil
            auth = token
        } else {
            target = manualTarget()
            auth = token ?? GitHub.savedToken
        }
        guard let target else {
            alert(mode.selectedSegment == 0 ? "リポジトリを選択してください。" : "URL または ユーザー名 / リポジトリ を入力してください。")
            return
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? target.name
            : nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.contains("/"), name != ".", name != ".." else {
            alert("そのフォルダ名は使用できません。")
            return
        }
        let destination = parent.appendingPathComponent(name)
        let existing = try? FileManager.default.contentsOfDirectory(atPath: destination.path)
        if FileManager.default.fileExists(atPath: destination.path), existing?.isEmpty != true {
            alert("「\(name)」は既に存在します。別のフォルダ名を指定してください。")
            return
        }
        close(CloneRequest(remote: target.remote, name: name, destination: destination, token: auth))
    }

    private func close(_ request: CloneRequest?) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        if let request { DispatchQueue.main.async { self.onClone?(request) } }
    }
}
