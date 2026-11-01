import AppKit
import JavaScriptCore
@testable import FlareStackIDE

final class CodeFoldingPlugin: NativePlugin {
    let id = CodeFoldingAddon.pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { FoldRegions.make().map { CodeFoldingAddon(code: code, finder: $0) } }
}

struct FoldRegion {
    let start: Int
    let end: Int
}

final class FoldRegions {
    private let context = JSContext()!
    private let regions: JSValue

    static func make() -> FoldRegions? {
        PluginStore.isInstalled(CodeFoldingAddon.pluginID) ? FoldRegions(folder: PluginStore.folder(CodeFoldingAddon.pluginID)) : nil
    }

    init?(folder: URL) {
        let file = folder.appendingPathComponent("main.js")
        guard let script = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        context.evaluateScript(script, withSourceURL: file)
        guard context.exception == nil, let function = context.objectForKeyedSubscript("regions"), function.isObject else { return nil }
        regions = function
    }

    func find(_ text: String, url: URL) -> [FoldRegion] {
        context.exception = nil
        let value = regions.call(withArguments: [text, url.pathExtension.lowercased(), url.lastPathComponent.lowercased()])
        guard context.exception == nil, let pairs = value?.toArray() as? [[Int]] else { return [] }
        return pairs.compactMap { $0.count == 2 ? FoldRegion(start: $0[0], end: $0[1]) : nil }
    }
}

final class FoldChip: NSButton {
    var fold = NSRange()

    convenience init(target: AnyObject, action: Selector) {
        self.init(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "展開")!, target: target, action: action)
        isBordered = false
        toolTip = "展開"
        wantsLayer = true
        layer?.cornerRadius = 4
    }
}

final class CodeFoldingAddon: NSObject, TextAddon {
    static let pluginID = "code-folding"
    private static let marks = Notification.Name("FlareStackIDE.foldMarks")
    private static let marksRequest = Notification.Name("FlareStackIDE.foldMarksRequest")
    private static let rulerClicked = Notification.Name("FlareStackIDE.rulerClicked")

    private weak var code: CodeEditing?
    private let finder: FoldRegions
    private var regions: [FoldRegion] = []
    private var folds: [NSRange] = []
    private var saved: [URL: [NSRange]] = [:]
    private var currentURL: URL?
    private var starts = [0]
    private var chips: [FoldChip] = []
    private var work: DispatchWorkItem?
    private var monitor: Any?

    init(code: CodeEditing, finder: FoldRegions) {
        self.code = code
        self.finder = finder
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(edited(_:)), name: NSTextStorage.didProcessEditingNotification, object: code.textView.textStorage)
        center.addObserver(self, selector: #selector(postMarks), name: Self.marksRequest, object: code.textView)
        center.addObserver(self, selector: #selector(rulerClicked(_:)), name: Self.rulerClicked, object: code.textView)
        center.addObserver(self, selector: #selector(placeChips), name: NSView.frameDidChangeNotification, object: code.textView)
        center.addObserver(self, selector: #selector(placeChips), name: .settingsChanged, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] in self?.handle($0) ?? $0 }
        fileOpened()
    }

    private func reloadStarts() {
        let text = (code?.textView.string ?? "") as NSString
        var result = [0]
        var i = 0
        while i < text.length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: i, length: text.length - i))
            if found.location == NSNotFound { break }
            result.append(found.location + 1)
            i = found.location + 1
        }
        starts = result
    }

    private func line(of location: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    private func range(of region: FoldRegion) -> NSRange? {
        guard let textView = code?.textView, region.start < region.end, region.end <= starts.count else { return nil }
        let length = (textView.string as NSString).length
        let from = starts[region.start] - 1
        let to = region.end < starts.count ? starts[region.end] - 1 : length
        return to > from ? NSRange(location: from, length: to - from) : nil
    }

    private func recompute() {
        work?.cancel()
        work = nil
        reloadStarts()
        guard let textView = code?.textView, let url = code?.fileURL, (textView.string as NSString).length <= Highlighter.limit else {
            regions = []
            return
        }
        regions = finder.find(textView.string, url: url)
    }

    private func schedule() {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.recompute()
            self?.postMarks()
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private var outer: [NSRange] {
        folds.filter { fold in !folds.contains { $0 != fold && NSLocationInRange(fold.location, $0) && NSMaxRange(fold) <= NSMaxRange($0) } }
            .sorted { $0.location < $1.location }
    }

    private func apply() {
        guard let textView = code?.textView else { return }
        CodeView.lineHeights.setHidden(outer, for: textView)
        placeChips()
        postMarks()
    }

    @objc private func postMarks() {
        guard let textView = code?.textView else { return }
        let closed = Set(folds.map { line(of: $0.location) })
        let open = Set(regions.map(\.start)).subtracting(closed)
        NotificationCenter.default.post(name: Self.marks, object: textView, userInfo: ["open": open, "closed": closed])
    }

    @objc private func placeChips() {
        guard let textView = code?.textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let targets = outer
        while chips.count > targets.count { chips.removeLast().removeFromSuperview() }
        while chips.count < targets.count {
            let chip = FoldChip(target: self, action: #selector(chipClicked(_:)))
            textView.addSubview(chip)
            chips.append(chip)
        }
        let height = max(Settings.lineHeight - 2, 12)
        let origin = textView.textContainerOrigin
        for (chip, fold) in zip(chips, targets) where fold.location > 0 {
            let glyph = layout.glyphIndexForCharacter(at: fold.location - 1)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            chip.fold = fold
            chip.layer?.backgroundColor = ButtonHover.activeFill(for: textView).cgColor
            chip.frame = NSRect(x: origin.x + rect.maxX + 6, y: origin.y + rect.minY + (Settings.lineHeight - height) / 2, width: 26, height: height)
        }
    }

    @objc private func chipClicked(_ sender: FoldChip) { unfold(sender.fold) }

    private func unfold(_ fold: NSRange) {
        folds.removeAll { $0 == fold }
        apply()
    }

    private func fold(_ region: FoldRegion) {
        guard let target = range(of: region), !folds.contains(target) else { return }
        folds.append(target)
    }

    private func region(at line: Int) -> FoldRegion? {
        regions.first { $0.start == line } ?? regions.filter { $0.start < line && line <= $0.end }.max { $0.start < $1.start }
    }

    private func foldAtCaret() {
        guard let textView = code?.textView else { return }
        recompute()
        guard let found = region(at: line(of: textView.selectedRange().location)), let target = range(of: found) else { return }
        fold(found)
        textView.setSelectedRange(NSRange(location: target.location, length: 0))
        apply()
    }

    private func unfoldAtCaret() {
        guard let textView = code?.textView else { return }
        let here = line(of: textView.selectedRange().location)
        guard let target = folds.first(where: { line(of: $0.location) == here }) else { return }
        unfold(target)
    }

    private func foldAll() {
        recompute()
        regions.forEach(fold)
        if let textView = code?.textView, let hidden = outer.first(where: { NSLocationInRange(textView.selectedRange().location, $0) }) {
            textView.setSelectedRange(NSRange(location: hidden.location, length: 0))
        }
        apply()
    }

    private func unfoldAll() {
        folds = []
        apply()
    }

    @objc private func rulerClicked(_ note: Notification) {
        guard note.userInfo?["zone"] as? String == "fold", let line = note.userInfo?["line"] as? Int else { return }
        if let target = folds.first(where: { self.line(of: $0.location) == line }) { return unfold(target) }
        recompute()
        guard let found = regions.first(where: { $0.start == line }) else { return }
        fold(found)
        apply()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let textView = code?.textView, event.window === textView.window, event.window?.firstResponder === textView else { return event }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        switch (event.keyCode, flags) {
        case (123, [.command, .option]): foldAtCaret()
        case (124, [.command, .option]): unfoldAtCaret()
        case (123, [.command, .option, .shift]): foldAll()
        case (124, [.command, .option, .shift]): unfoldAll()
        default: return event
        }
        return nil
    }

    @objc private func edited(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters),
              let textView = code?.textView else { return }
        let range = storage.editedRange
        let delta = storage.changeInLength
        let oldCount = range.length - delta
        let oldEnd = range.location + oldCount
        if range.location == 0, oldCount >= storage.length - delta {
            if let currentURL { saved[currentURL] = folds }
            folds = []
            CodeView.lineHeights.setHidden([], for: textView, invalidating: false)
            return
        }
        guard !folds.isEmpty else { return }
        var opened: [NSRange] = []
        folds = folds.compactMap { fold in
            let insideInsert = oldCount == 0 && range.location > fold.location && range.location < NSMaxRange(fold)
            if insideInsert || (oldCount > 0 && range.location < NSMaxRange(fold) && oldEnd > fold.location) {
                opened.append(fold)
                return nil
            }
            return range.location <= fold.location ? NSRange(location: fold.location + delta, length: fold.length) : fold
        }
        CodeView.lineHeights.setHidden(outer, for: textView, invalidating: false)
        guard !opened.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let textView = self?.code?.textView else { return }
            CodeView.lineHeights.invalidate(opened, in: textView)
            self?.placeChips()
        }
    }

    func selectionChanged() {
        guard let textView = code?.textView, !folds.isEmpty else { return }
        let selection = textView.selectedRange()
        let edges = [selection.location, NSMaxRange(selection)]
        let entered = folds.filter { fold in edges.contains { $0 > fold.location && $0 < NSMaxRange(fold) } }
        guard !entered.isEmpty else { return }
        folds.removeAll { entered.contains($0) }
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    func textChanged() {
        reloadStarts()
        placeChips()
        postMarks()
        schedule()
    }

    func fileOpened() {
        let url = code?.fileURL
        recompute()
        let valid = regions.compactMap(range(of:))
        folds = url.flatMap { saved[$0] }?.filter { valid.contains($0) } ?? []
        currentURL = url
        apply()
    }

    func detach() {
        work?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        chips.forEach { $0.removeFromSuperview() }
        chips = []
        guard let textView = code?.textView else { return }
        CodeView.lineHeights.setHidden([], for: textView)
        NotificationCenter.default.post(name: Self.marks, object: textView)
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(CodeFoldingPlugin()) }
