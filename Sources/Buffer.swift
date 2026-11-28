import AppKit

final class FileNode {
    let url: URL
    let isDirectory: Bool
    private var cached: [FileNode]?

    init(url: URL) {
        self.url = url
        isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static let hiddenNames: Set<String> = [".DS_Store", ".git"]

    var children: [FileNode] {
        if let cached { return cached }
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let nodes = urls.filter { !FileNode.hiddenNames.contains($0.lastPathComponent) }.map(FileNode.init).sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory
                : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        cached = nodes
        return nodes
    }

    func invalidate() { cached = nil }

    func loadedChild(_ name: String) -> FileNode? { cached?.first { $0.url.lastPathComponent == name } }

    var isLoaded: Bool { cached != nil }

    func refresh() {
        guard let old = cached else { return }
        let existing = Dictionary(old.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { a, _ in a })
        cached = nil
        cached = children.map { existing[$0.url.standardizedFileURL] ?? $0 }
        cached?.forEach { $0.refresh() }
    }
}

final class Buffer {
    let url: URL
    var text: String
    var dirty = false
    private(set) var editable: Bool
    var format = TextFormat()

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe), let file = TextFile.read(data) {
            text = file.text
            format = file.format
            editable = true
            if data.count <= LocalHistory.maxBytes { baseline = Data(data) }
        } else {
            text = "このファイルは表示できません。"
            editable = false
        }
    }

    func reopen(as encoding: TextEncoding) throws {
        guard let file = TextFile.read(url, encoding: encoding) else {
            throw TextFile.failure("\(encoding.title) として読み込めませんでした。")
        }
        text = file.text
        format = file.format
        editable = true
        dirty = false
    }

    private var baseline: Data?
    private var pendingSave: DispatchWorkItem?
    private var autosaveFailed = false

    func save(atomically: Bool = true) throws {
        pendingSave?.cancel()
        pendingSave = nil
        let data = try TextFile.write(text, to: url, format: format, atomically: atomically)
        dirty = false
        LocalHistory.record(url, data: data, previous: baseline)
        baseline = nil
    }

    func scheduleSave(_ done: @escaping () -> Void) {
        dirty = true
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingSave != nil else { return }
            do {
                try self.save()
                self.autosaveFailed = false
            } catch {
                self.dirty = true
                if !self.autosaveFailed {
                    Toasts.post("「\(self.url.lastPathComponent)」を自動保存できませんでした", message: error.localizedDescription)
                }
                self.autosaveFailed = true
            }
            done()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func diskText() -> String? { TextFile.read(url, encoding: format.encoding)?.text }
}

final class ToolStripButton: NSButton {
    var active = false { didSet { needsDisplay = true } }
    private var symbol = ""
    private var width: NSLayoutConstraint!
    private var height: NSLayoutConstraint!

    convenience init(symbol: String, tip: String, target: AnyObject, action: Selector) {
        self.init(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        self.symbol = symbol
        isBordered = false
        toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false
        width = widthAnchor.constraint(equalToConstant: 30)
        height = heightAnchor.constraint(equalToConstant: 30)
        NSLayoutConstraint.activate([width, height])
        applySize()
    }

    func applySize() {
        let side = max(Settings.bigTabWidth - 10, 22)
        width.constant = side
        height.constant = side
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Settings.bigTabIconSize, weight: .regular))
    }

    var onReorder: (() -> Void)?
    var groups: () -> [NSStackView] = { [] }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let window,
              let item = sequence(first: self as NSView, next: { $0.superview }).first(where: { $0.superview is NSStackView }) else {
            return super.mouseDown(with: event)
        }
        var reorder: DragReorder?
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            if reorder == nil {
                guard hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) > 3 else { continue }
                reorder = DragReorder(view: item, event: event, peers: groups())
            }
            reorder?.drag(next)
        }
        reorder?.end()
        if reorder != nil { onReorder?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if active {
            ButtonHover.activeFill(for: self).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}
