import AppKit
import JavaScriptCore
@testable import FlareStackIDE

struct Diagnostic {
    enum Severity { case error, warning }
    let url: URL
    let range: NSRange
    let line: Int
    let column: Int
    let severity: Severity
    let message: String
    let snippet: String

    var color: NSColor { severity == .error ? .systemRed : .systemYellow }
}

final class CodeScanner {
    static let pluginID = "code-scanner"
    static let marksChanged = Notification.Name("FlareStackIDE.lineMarks")
    static let marksRequest = Notification.Name("FlareStackIDE.lineMarksRequest")
    private let context = JSContext()!
    private let checker: JSValue?
    private let diagnose: JSValue?
    private let parse: JSValue?
    private var generation: [URL: Int] = [:]

    init?(folder: URL) {
        let file = folder.appendingPathComponent("main.js")
        guard let script = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let exists: @convention(block) (String, String) -> Bool = { path, dir in
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: dir, isDirectory: true)).path)
        }
        context.setObject(exists, forKeyedSubscript: "fileExists" as NSString)
        context.evaluateScript(script, withSourceURL: file)
        guard context.exception == nil else { return nil }
        let fn = { [context] (name: String) in context.objectForKeyedSubscript(name).flatMap { $0.isObject ? $0 : nil } }
        checker = fn("checker")
        diagnose = fn("diagnose")
        parse = fn("parse")
    }

    static func make() -> CodeScanner? {
        PluginStore.isInstalled(pluginID) ? CodeScanner(folder: PluginStore.folder(pluginID)) : nil
    }

    private static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
        + (ProcessInfo.processInfo.environment["PATH"] ?? "")

    private func items(_ value: JSValue?) -> [[String: Any]] {
        guard context.exception == nil else { context.exception = nil; return [] }
        return value?.toArray() as? [[String: Any]] ?? []
    }

    func scan(_ text: String, url: URL, completion: @escaping ([Diagnostic]) -> Void) {
        let ext = url.pathExtension.lowercased(), name = url.lastPathComponent.lowercased()
        let token = (generation[url] ?? 0) + 1
        generation[url] = token
        context.exception = nil
        let local = items(diagnose?.call(withArguments: [text, ext, name, url.deletingLastPathComponent().path]))
        let spec = checker?.call(withArguments: [ext, name]).flatMap { $0.isObject ? $0.toDictionary() : nil }
        guard let args = spec?["args"] as? [String], !args.isEmpty else {
            return completion(Self.convert(local, text: text, url: url))
        }
        let format = spec?["format"] as? String ?? "gcc"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = Self.run(args, text: text, url: url)
            DispatchQueue.main.async {
                guard let self, self.generation[url] == token else { return }
                let parsed = output.map { self.items(self.parse?.call(withArguments: [$0, format, url.lastPathComponent])) } ?? []
                completion(Self.convert(local + parsed, text: text, url: url))
            }
        }
    }

    private static func run(_ args: [String], text: String, url: URL) -> String? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("\(appName)-scan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: file, atomically: false, encoding: .utf8)
        } catch { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args.map {
            $0.replacingOccurrences(of: "$FILE", with: file.path)
                .replacingOccurrences(of: "$DIR", with: url.deletingLastPathComponent().path)
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["LANG"] = "en_US.UTF-8"
        process.environment = env
        process.currentDirectoryURL = url.deletingLastPathComponent()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus != 127, process.terminationReason == .exit else { return nil }
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: file.path, with: url.path)
    }

    private static func convert(_ raw: [[String: Any]], text: String, url: URL) -> [Diagnostic] {
        let ns = text as NSString
        var starts = [0]
        var i = 0
        while i < ns.length {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: i, length: ns.length - i))
            if r.location == NSNotFound { break }
            starts.append(r.location + 1)
            i = r.location + 1
        }
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
        var seen = Set<String>()
        var result: [Diagnostic] = []
        for item in raw {
            let line = min(max((item["line"] as? NSNumber)?.intValue ?? 1, 1), starts.count)
            let column = max((item["column"] as? NSNumber)?.intValue ?? 0, 0)
            let message = item["message"] as? String ?? ""
            let severity: Diagnostic.Severity = (item["severity"] as? String) == "warning" ? .warning : .error
            guard !message.isEmpty, seen.insert("\(line):\(column):\(message)").inserted else { continue }
            let lineStart = starts[line - 1]
            var lineEnd = line < starts.count ? starts[line] - 1 : ns.length
            lineEnd = max(lineEnd, lineStart)
            let content = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            var range: NSRange
            if column > 0 {
                var start = min(lineStart + column - 1, lineEnd)
                if start == lineEnd, start > lineStart { start -= 1 }
                var end = start
                while end < lineEnd, let scalar = UnicodeScalar(ns.character(at: end)), word.contains(scalar) { end += 1 }
                range = NSRange(location: start, length: max(end - start, start < ns.length ? 1 : 0))
            } else {
                let lead = content.prefix { $0 == " " || $0 == "\t" }.utf16.count
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                range = NSRange(location: lineStart + lead, length: trimmed.utf16.count)
            }
            if range.length == 0, ns.length > 0 { range = NSRange(location: max(min(range.location, ns.length - 1), 0), length: 1) }
            result.append(Diagnostic(url: url, range: range, line: line, column: column, severity: severity, message: message,
                                     snippet: content.trimmingCharacters(in: .whitespaces)))
        }
        return result.sorted { ($0.severity == .error ? 0 : 1, $0.line) < ($1.severity == .error ? 0 : 1, $1.line) }
    }
}

final class DiagnosticLayoutManager: NSLayoutManager {
    var marks: [(range: NSRange, color: NSColor)] = []

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let container = textContainers.first, let storage = textStorage else { return }
        for mark in marks where NSMaxRange(mark.range) <= storage.length {
            let glyphs = glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { continue }
            mark.color.setStroke()
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: container) { rect, _ in
                let font = (storage.attribute(.font, at: mark.range.location, effectiveRange: nil) as? NSFont) ?? Settings.font
                let y = origin.y + rect.minY + ceil(font.ascender - font.descender) + 1
                let path = NSBezierPath()
                path.lineWidth = 1
                var x = origin.x + rect.minX
                let end = origin.x + max(rect.maxX, rect.minX + 4)
                path.move(to: NSPoint(x: x, y: y))
                var up = true
                while x < end {
                    x += 2
                    path.line(to: NSPoint(x: x, y: y + (up ? -1.5 : 0)))
                    up.toggle()
                }
                path.stroke()
            }
        }
    }
}

final class ProblemBadge: NSView {
    var onClick: (() -> Void)?
    private let errorIcon = NSImageView()
    private let errorLabel = NSTextField(labelWithString: "0")
    private let warningIcon = NSImageView()
    private let warningLabel = NSTextField(labelWithString: "0")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        errorIcon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "エラー")?.withSymbolConfiguration(config)
        errorIcon.contentTintColor = .systemRed
        warningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "警告")?.withSymbolConfiguration(config)
        warningIcon.contentTintColor = .systemYellow
        for label in [errorLabel, warningLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
        }
        let stack = NSStackView(views: [errorIcon, errorLabel, warningIcon, warningLabel])
        stack.spacing = 3
        stack.setCustomSpacing(8, after: errorLabel)
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = "問題を表示"
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(errors: Int, warnings: Int) {
        errorLabel.stringValue = "\(errors)"
        warningLabel.stringValue = "\(warnings)"
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class ProblemsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Diagnostic) -> Void)?
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "問題はありません")
    private var items: [Diagnostic] = []

    init() {
        super.init(frame: .zero)
        for (id, title, width) in [("kind", "", 26.0), ("message", "内容", 340.0), ("code", "コード", 220.0), ("file", "ファイル", 140.0), ("line", "行", 60.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            if id == "kind" { column.minWidth = 26; column.maxWidth = 26 }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .small
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.target = self
        table.action = #selector(rowClicked)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.textColor = .tertiaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ diagnostics: [Diagnostic]) {
        items = diagnostics
        empty.isHidden = !items.isEmpty
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]
        if id == "kind" {
            let image = NSImageView(image: NSImage(systemSymbolName: item.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill",
                                                   accessibilityDescription: item.severity == .error ? "エラー" : "警告")!)
            image.contentTintColor = item.color
            return image
        }
        let text: String
        switch id {
        case "message": text = item.message
        case "code": text = item.snippet
        case "file": text = item.url.lastPathComponent
        default: text = item.column > 0 ? "\(item.line):\(item.column)" : "\(item.line)"
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.font = id == "code" ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
        label.textColor = id == "message" ? .labelColor : .secondaryLabelColor
        label.toolTip = id == "file" ? item.url.path : text
        return label
    }

    @objc private func rowClicked() {
        guard items.indices.contains(table.clickedRow) else { return }
        onSelect?(items[table.clickedRow])
    }
}
