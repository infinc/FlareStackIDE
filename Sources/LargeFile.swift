import AppKit

extension Notification.Name {
    static let largeFileAllowed = Notification.Name("FlareStackIDE.largeFileAllowed")
}

enum LargeFile {
    private static var allowed: Set<URL> = []
    private static var notices: [URL: Toast] = [:]

    static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func isLimited(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let key = url.standardizedFileURL
        return !allowed.contains(key) && size(key) > Settings.largeFileLimit
    }

    static func allow(_ url: URL) {
        let key = url.standardizedFileURL
        allowed.insert(key)
        notices.removeValue(forKey: key)?.dismiss()
        NotificationCenter.default.post(name: .largeFileAllowed, object: key)
    }

    static func notify(_ url: URL, in window: NSWindow?) {
        let key = url.standardizedFileURL
        notices = notices.filter { $0.value.superview != nil }
        guard notices[key] == nil else { return }
        let size = ByteCountFormatter.string(fromByteCount: Int64(size(key)), countStyle: .file)
        let limit = ByteCountFormatter.string(fromByteCount: Int64(Settings.largeFileLimit), countStyle: .file)
        notices[key] = Toasts.notice("「\(key.lastPathComponent)」は大きなファイルです",
                                     message: "\(size)（\(limit) 超）のため、プラグインを止めて文字だけを表示しています。",
                                     actions: [("それでも編集する", { allow(key) })], in: window)
    }
}
