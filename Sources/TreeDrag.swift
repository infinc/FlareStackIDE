import AppKit

private final class DropHighlight: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class TreeOutline: NSOutlineView {
    var onMove: ((FileNode, FileNode) -> Void)?
    private let highlight = DropHighlight()

    override func mouseDown(with event: NSEvent) {
        let press = convert(event.locationInWindow, from: nil)
        let row = self.row(at: press)
        guard let window, row > 0, event.clickCount == 1, let node = item(atRow: row) as? FileNode,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              !frameOfOutlineCell(atRow: row).contains(press) else { return super.mouseDown(with: event) }
        var lift: DragLift?
        var target: FileNode?
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if lift != nil { break }
                window.postEvent(next, atStart: true)
                return super.mouseDown(with: event)
            }
            if lift == nil {
                guard hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) > 4 else { continue }
                lift = begin(row: row, event: event)
                if lift == nil { continue }
            }
            lift?.move(next)
            autoscroll(with: next)
            target = folder(under: next, moving: node)
            show(target)
        }
        show(nil)
        let source = rowView(atRow: row, makeIfNecessary: false)
        let done: () -> Void = { source?.alphaValue = 1 }
        if let target, let area = sourceRect(target) {
            lift?.land(on: self, rect: area, absorb: true) { [weak self] in
                done()
                DispatchQueue.main.async { self?.onMove?(node, target) }
            }
        } else {
            lift?.land(on: self, rect: rect(ofRow: row), done: done)
        }
    }

    private func begin(row: Int, event: NSEvent) -> DragLift? {
        guard let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return nil }
        let text = cell.textField?.intrinsicContentSize.width ?? 0
        let rect = NSRect(x: 0, y: 0, width: min(cell.bounds.width, 16 + 5 + text + 6), height: cell.bounds.height)
        let lift = DragLift(view: cell, rect: rect, event: event, axis: .free,
                            background: NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35))
        rowView(atRow: row, makeIfNecessary: false)?.alphaValue = 0
        return lift
    }

    private func folder(under event: NSEvent, moving node: FileNode) -> FileNode? {
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point) else { return nil }
        let row = self.row(at: point)
        var found = item(atRow: max(row, 0)) as? FileNode
        if let item = found, !item.isDirectory { found = parent(forItem: item) as? FileNode }
        guard let folder = found else { return nil }
        let path = node.url.standardizedFileURL.path, into = folder.url.standardizedFileURL.path
        let parentPath = node.url.deletingLastPathComponent().standardizedFileURL.path
        return into == parentPath || into == path || into.hasPrefix(path + "/") ? nil : folder
    }

    private func sourceRect(_ folder: FileNode) -> NSRect? {
        let row = self.row(forItem: folder)
        return row >= 0 ? rect(ofRow: row) : nil
    }

    private func show(_ folder: FileNode?) {
        guard let folder, case let first = row(forItem: folder), first >= 0 else {
            highlight.removeFromSuperview()
            return
        }
        var area = rect(ofRow: first)
        var next = first + 1
        while next < numberOfRows, level(forRow: next) > level(forRow: first) {
            area = area.union(rect(ofRow: next))
            next += 1
        }
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 5
        highlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        highlight.frame = area
        if highlight.superview == nil { addSubview(highlight) }
    }
}
