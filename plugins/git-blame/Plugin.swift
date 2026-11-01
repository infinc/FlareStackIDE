import AppKit
@testable import FlareStackIDE

final class GitBlamePlugin: NativePlugin {
    let id = GitBlameAddon.pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { GitBlameAddon(code: code) }
}

struct BlameLine {
    let hash: String
    let author: String
    let time: Date
    let summary: String

    var uncommitted: Bool { hash.allSatisfy { $0 == "0" } }
}

enum GitBlame {
    static func run(text: String, url: URL) -> [Int: BlameLine]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["blame", "--porcelain", "--contents", "-", "--", url.lastPathComponent]
        process.currentDirectoryURL = url.deletingLastPathComponent()
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global(qos: .utility).async {
            try? input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try? input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    private static func parse(_ output: String) -> [Int: BlameLine] {
        var commits: [String: (author: String, time: Double, summary: String)] = [:]
        var result: [Int: BlameLine] = [:]
        var hash = ""
        var line = 0
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("\t") {
                if let info = commits[hash] {
                    result[line] = BlameLine(hash: hash, author: info.author, time: Date(timeIntervalSince1970: info.time), summary: info.summary)
                }
                continue
            }
            let parts = raw.split(separator: " ", maxSplits: 3)
            if parts.count >= 3, parts[0].count >= 40, parts[0].allSatisfy(\.isHexDigit), let final = Int(parts[2]) {
                hash = String(parts[0])
                line = final
                if commits[hash] == nil { commits[hash] = ("", 0, "") }
            } else if raw.hasPrefix("author ") {
                commits[hash]?.author = String(raw.dropFirst(7))
            } else if raw.hasPrefix("author-time ") {
                commits[hash]?.time = Double(raw.dropFirst(12)) ?? 0
            } else if raw.hasPrefix("summary ") {
                commits[hash]?.summary = String(raw.dropFirst(8))
            }
        }
        return result
    }
}

private final class BlameLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class GitBlameAddon: NSObject, TextAddon {
    static let pluginID = "git-blame"
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()

    private weak var code: CodeEditing?
    private let label = BlameLabel(labelWithString: "")
    private var lines: [Int: BlameLine] = [:]
    private var work: DispatchWorkItem?
    private var generation = 0

    init(code: CodeEditing) {
        self.code = code
        super.init()
        label.isHidden = true
        label.lineBreakMode = .byTruncatingTail
        code.textView.addSubview(label)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
        schedule(delay: 0)
    }

    @objc private func settingsChanged() {
        if !Settings.gitEnabled { lines = [:] }
        update()
    }

    private func schedule(delay: TimeInterval) {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.load() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func load() {
        generation += 1
        let token = generation
        guard Settings.gitEnabled, let code, let url = code.fileURL else { return }
        let text = code.textView.string
        guard (text as NSString).length <= Highlighter.limit else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = GitBlame.run(text: text, url: url) ?? [:]
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.lines = found
                self.update()
            }
        }
    }

    private func message(_ line: BlameLine) -> String {
        if line.uncommitted { return "未コミット" }
        return "\(line.author), \(Self.relative.localizedString(for: line.time, relativeTo: Date())) • \(line.summary)"
    }

    private func update() {
        guard let textView = code?.textView, let layout = textView.layoutManager else { return }
        label.isHidden = true
        let selection = textView.selectedRange()
        let text = textView.string as NSString
        guard selection.length == 0, selection.location <= text.length, !lines.isEmpty else { return }
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let number = text.substring(to: lineRange.location).utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }
        guard let line = lines[number], lineRange.location < text.length else { return }
        var content = lineRange
        while content.length > 0, "\r\n".contains(text.substring(with: NSRange(location: NSMaxRange(content) - 1, length: 1))) { content.length -= 1 }
        let last = max(NSMaxRange(content) - 1, content.location)
        let glyph = layout.glyphIndexForCharacter(at: last)
        guard layout.propertyForGlyph(at: glyph) != .null else { return }
        let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        label.stringValue = message(line)
        label.font = .systemFont(ofSize: max(Settings.fontSize - 1, 9))
        label.textColor = PluginStore.color(Self.pluginID, "textColor") ?? .tertiaryLabelColor
        label.sizeToFit()
        let origin = textView.textContainerOrigin
        let x = origin.x + used.maxX + 24
        if Settings.wrapLines, x + label.frame.width > textView.bounds.width { return }
        label.frame.origin = NSPoint(x: x, y: origin.y + used.minY + (Settings.lineHeight - label.frame.height) / 2)
        label.isHidden = false
    }

    func selectionChanged() { update() }

    func textChanged() {
        lines = [:]
        label.isHidden = true
        schedule(delay: 1)
    }

    func fileOpened() {
        lines = [:]
        label.isHidden = true
        schedule(delay: 0)
    }

    func detach() {
        work?.cancel()
        generation += 1
        NotificationCenter.default.removeObserver(self)
        label.removeFromSuperview()
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(GitBlamePlugin()) }
