import AppKit
import UniformTypeIdentifiers
@testable import FlareStackIDE

final class HexViewerPlugin: NativePlugin, FileViewing {
    let id = "hex-viewer"

    func viewer(for url: URL) -> EditorExtension? {
        if let type = UTType(filenameExtension: url.pathExtension),
           [UTType.image, .audiovisualContent, .pdf].contains(where: type.conforms) { return nil }
        let listed = PluginStore.installed(id)?.fileExtensions.contains(url.pathExtension.lowercased()) == true
        guard listed || Self.isBinary(url), let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return HexViewer(data: data)
    }

    private static func isBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        guard !head.isEmpty else { return false }
        if TextFile.isBinary(head) { return true }
        return !(0...3).contains { head.count > $0 && TextFile.detect(head.dropLast($0)) != nil }
    }
}

final class HexViewer: NSObject, EditorExtension {
    let bar = NSView()
    let floating = false
    let corner = FloatCorner.bottomRight
    private let grid: HexGrid
    private let scroll = NSScrollView()
    private let info = NSTextField(labelWithString: "")
    private let jump = NSTextField()
    var body: NSView { scroll }

    init(data: Data) {
        grid = HexGrid(data: data)
        super.init()
        info.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        info.translatesAutoresizingMaskIntoConstraints = false
        jump.placeholderString = "オフセットへ移動（0x1F / 31）"
        jump.controlSize = .small
        jump.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        jump.target = self
        jump.action = #selector(jumpEntered)
        jump.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        [info, jump, line].forEach(bar.addSubview)
        NSLayoutConstraint.activate([
            info.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            info.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            info.trailingAnchor.constraint(lessThanOrEqualTo: jump.leadingAnchor, constant: -10),
            jump.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            jump.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            jump.widthAnchor.constraint(equalToConstant: 200),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        grid.onSelect = { [weak self] in self?.showInfo() }
        applySettings()
        showInfo()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
    }

    @objc private func settingsChanged() { applySettings() }

    func update(text: String) {}

    func applySettings() {
        scroll.backgroundColor = Settings.background
        grid.applySettings()
    }

    private func showInfo() {
        let size = ByteCountFormatter.string(fromByteCount: Int64(grid.data.count), countStyle: .file)
        guard let offset = grid.selected, grid.data.indices.contains(offset) else {
            info.stringValue = "\(size)（\(grid.data.count) バイト）"
            return
        }
        let byte = grid.data[grid.data.startIndex + offset]
        info.stringValue = String(format: "%@　オフセット 0x%X (%d)　値 0x%02X = %d", size, offset, offset, byte, byte)
    }

    @objc private func jumpEntered() {
        let text = jump.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let value = text.hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text)
        guard let value, grid.data.indices.contains(value) else { return NSSound.beep() }
        grid.select(value)
        grid.window?.makeFirstResponder(grid)
    }
}

final class HexGrid: NSView {
    let data: Data
    var onSelect: (() -> Void)?
    private(set) var selected: Int?
    private static let perRow = 16
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var rowHeight: CGFloat = 18
    private var charWidth: CGFloat = 7

    init(data: Data) {
        self.data = data
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var rows: Int { max((data.count + Self.perRow - 1) / Self.perRow, 1) }

    func applySettings() {
        font = NSFont.monospacedSystemFont(ofSize: Settings.fontSize, weight: .regular)
        charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        rowHeight = ceil(font.ascender - font.descender + font.leading) + 4
        let columns = 10 + Self.perRow * 3 + 2 + Self.perRow + 2
        setFrameSize(NSSize(width: CGFloat(columns) * charWidth + 24, height: CGFloat(rows) * rowHeight + 12))
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clip = superview as? NSClipView {
            setFrameSize(NSSize(width: max(frame.width, clip.bounds.width), height: max(frame.height, clip.bounds.height)))
        }
    }

    private func hexX(_ column: Int) -> CGFloat { 12 + CGFloat(10 + column * 3 + (column >= 8 ? 1 : 0)) * charWidth }
    private func asciiX(_ column: Int) -> CGFloat { 12 + CGFloat(10 + Self.perRow * 3 + 2 + column) * charWidth }

    override func draw(_ dirtyRect: NSRect) {
        Settings.background.setFill()
        dirtyRect.fill()
        let first = max(Int((dirtyRect.minY - 6) / rowHeight), 0)
        let last = min(Int((dirtyRect.maxY - 6) / rowHeight) + 1, rows)
        guard first < last else { return }
        let main: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Settings.foreground]
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Settings.foreground.withAlphaComponent(0.45)]
        let base = data.startIndex
        for row in first..<last {
            let y = 6 + CGFloat(row) * rowHeight
            let start = row * Self.perRow
            (String(format: "%08X", start) as NSString).draw(at: NSPoint(x: 12, y: y), withAttributes: dim)
            var ascii = ""
            for column in 0..<Self.perRow {
                let offset = start + column
                guard offset < data.count else { break }
                let byte = data[base + offset]
                if offset == selected {
                    NSColor.selectedContentBackgroundColor.withAlphaComponent(0.45).setFill()
                    NSRect(x: hexX(column) - 2, y: y - 1, width: charWidth * 2 + 4, height: rowHeight - 2).fill()
                    NSRect(x: asciiX(column), y: y - 1, width: charWidth, height: rowHeight - 2).fill()
                }
                (String(format: "%02X", byte) as NSString).draw(at: NSPoint(x: hexX(column), y: y), withAttributes: byte == 0 ? dim : main)
                ascii.append((0x20..<0x7F).contains(byte) ? Character(UnicodeScalar(byte)) : "·")
            }
            (ascii as NSString).draw(at: NSPoint(x: asciiX(0), y: y), withAttributes: main)
        }
    }

    private func offset(at point: NSPoint) -> Int? {
        let row = Int((point.y - 6) / rowHeight)
        guard row >= 0, row < rows else { return nil }
        for column in 0..<Self.perRow {
            let hex = NSRect(x: hexX(column) - 2, y: 0, width: charWidth * 2 + 4, height: 1)
            let ascii = NSRect(x: asciiX(column), y: 0, width: charWidth, height: 1)
            if (hex.minX..<hex.maxX).contains(point.x) || (ascii.minX..<ascii.maxX).contains(point.x) {
                let offset = row * Self.perRow + column
                return offset < data.count ? offset : nil
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        selected = offset(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
        onSelect?()
    }

    func select(_ offset: Int) {
        selected = offset
        let row = offset / Self.perRow
        scrollToVisible(NSRect(x: 0, y: CGFloat(row) * rowHeight, width: 1, height: rowHeight * 3).offsetBy(dx: 0, dy: -rowHeight))
        needsDisplay = true
        onSelect?()
    }

    override func keyDown(with event: NSEvent) {
        guard let current = selected else { return super.keyDown(with: event) }
        let moves: [UInt16: Int] = [123: -1, 124: 1, 125: Self.perRow, 126: -Self.perRow]
        guard let delta = moves[event.keyCode] else { return super.keyDown(with: event) }
        select(min(max(current + delta, 0), max(data.count - 1, 0)))
    }

    @objc func copy(_ sender: Any?) {
        guard let selected, data.indices.contains(selected) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(format: "%02X", data[data.startIndex + selected]), forType: .string)
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(HexViewerPlugin()) }
