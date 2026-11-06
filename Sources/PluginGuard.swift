import AppKit
import Darwin

enum PluginGuard {
    private static let capacity = 128
    private static let markers = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: capacity)
    private static let lines = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: capacity)
    private static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 256)
    private static var count = 0
    private static var fd: Int32 = -1
    private static let disabledKey = "Plugins.Disabled"
    private static let threshold = 2
    private static var notified: Set<String> = []
    private(set) static var crashedLastTime: [String] = []

    private static var logURL: URL { PluginStore.directory.appendingPathComponent("crash.log") }

    private static func countKey(_ id: String) -> String { "Plugins.Crashes.\(id)" }

    static var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: disabledKey) }
    }

    static func isDisabled(_ id: String) -> Bool { disabled.contains(id) }

    static func enable(_ id: String) {
        disabled.remove(id)
        UserDefaults.standard.removeObject(forKey: countKey(id))
        notified.remove(id)
        NotificationCenter.default.post(name: .pluginsChanged, object: nil)
    }

    static func install() {
        let previous = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let ids = Array(Set(previous.split(separator: "\n").map(String.init))).sorted()
        crashedLastTime = ids
        for id in ids {
            let crashes = UserDefaults.standard.integer(forKey: countKey(id)) + 1
            UserDefaults.standard.set(crashes, forKey: countKey(id))
            if crashes >= threshold { disabled.insert(id) }
        }
        _ = (markers, lines, frames, count)
        try? FileManager.default.createDirectory(at: PluginStore.directory, withIntermediateDirectories: true)
        fd = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o644)
        for signal in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            Darwin.signal(signal) { number in
                PluginGuard.record()
                Darwin.signal(number, SIG_DFL)
                raise(number)
            }
        }
        NSSetUncaughtExceptionHandler { exception in
            PluginGuard.record(exception.callStackReturnAddresses.map { UnsafeMutableRawPointer(bitPattern: $0.uintValue) })
        }
        guard !ids.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reportPrevious(ids) }
    }

    private static func reportPrevious(_ ids: [String]) {
        for id in ids where !isDisabled(id) {
            let name = PluginStore.info(id)?.name ?? id
            Toasts.post("前回 \(name) が原因で \(appName) が終了しました", message: "もう一度終了すると、このプラグインを自動で止めます")
        }
    }

    static func loaded(_ id: String) {
        let marker = "/Plugins/\(id)/\(NativePlugins.binary)"
        let known = UnsafeBufferPointer(start: markers, count: count).contains { $0.map { String(cString: $0) } == marker }
        guard count < capacity, !known else { return }
        markers[count] = strdup(marker)
        lines[count] = strdup(id + "\n")
        count += 1
    }

    static func cleanExit() {
        for i in 0..<count {
            guard let line = lines[i] else { continue }
            UserDefaults.standard.removeObject(forKey: countKey(String(cString: line).trimmingCharacters(in: .newlines)))
        }
        if fd >= 0 { ftruncate(fd, 0) }
    }

    static func notifyDisabled(_ info: PluginInfo) {
        guard !notified.contains(info.id) else { return }
        notified.insert(info.id)
        Toasts.post("\(info.name) を止めています", message: "このプラグインが原因で \(appName) が続けて終了したため、読み込んでいません",
                    actions: [("有効にする", { enable(info.id) })])
    }

    private static func match(_ frame: UnsafeMutableRawPointer?) -> Bool {
        var info = Dl_info()
        guard let frame, dladdr(frame, &info) != 0, let name = info.dli_fname else { return false }
        for i in 0..<count {
            guard let marker = markers[i], strstr(name, marker) != nil, let line = lines[i] else { continue }
            _ = write(fd, line, strlen(line))
            return true
        }
        return false
    }

    fileprivate static func record() {
        guard fd >= 0, count > 0 else { return }
        let depth = backtrace(frames, 256)
        for i in 0..<Int(depth) where match(frames[i]) { return }
    }

    fileprivate static func record(_ addresses: [UnsafeMutableRawPointer?]) {
        guard fd >= 0, count > 0 else { return }
        for address in addresses where match(address) { return }
    }
}
