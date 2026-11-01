import AppKit
@testable import FlareStackIDE

final class SnippetsPlugin: NativePlugin, PluginSettingsProviding {
    let id = SnippetStore.pluginID
    func textAddon(for code: CodeEditing) -> TextAddon? { SnippetsAddon(code: code) }
    func settingsView() -> NSView? { SnippetSettingsView() }
}

final class SnippetsAddon: TextAddon {
    private struct Session {
        var stops: [NSRange]
        var index = 0
        var length: Int
    }

    private weak var code: CodeEditing?
    private var session: Session?

    init(code: CodeEditing) { self.code = code }

    var priority: Int { 20 }

    private func expand() -> Bool {
        guard let textView = code?.textView, let url = code?.fileURL, !textView.hasMarkedText() else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let text = textView.string as NSString
        let head = text.substring(to: selection.location)
        let candidates = SnippetStore.available(for: url.pathExtension.lowercased())
        guard let snippet = candidates.filter({ matches($0.trigger, head) }).max(by: { $0.trigger.count < $1.trigger.count }) else { return false }
        let start = selection.location - (snippet.trigger as NSString).length
        let line = text.lineRange(for: NSRange(location: start, length: 0))
        let leading = text.substring(with: NSRange(location: line.location, length: start - line.location))
        let indent = String(leading.prefix { $0 == " " || $0 == "\t" })
        let parsed = SnippetBody.parse(snippet.body, indent: indent)
        textView.insertText(parsed.text, replacementRange: NSRange(location: start, length: (snippet.trigger as NSString).length))
        let stops = parsed.stops.map { NSRange(location: $0.location + start, length: $0.length) }
        session = stops.isEmpty ? nil : Session(stops: stops, length: (textView.string as NSString).length)
        select(0)
        return true
    }

    private func matches(_ trigger: String, _ head: String) -> Bool {
        guard !trigger.isEmpty, head.hasSuffix(trigger) else { return false }
        guard let before = head.dropLast(trigger.count).last else { return true }
        return !(before.isLetter || before.isNumber || before == "_")
    }

    private func select(_ index: Int) {
        guard var current = session, let textView = code?.textView, current.stops.indices.contains(index) else { return }
        current.index = index
        session = index == current.stops.count - 1 ? nil : current
        textView.setSelectedRange(current.stops[index])
        textView.scrollRangeToVisible(current.stops[index])
    }

    func doCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            if let session {
                select(session.index + 1)
                return true
            }
            return expand()
        case #selector(NSResponder.insertBacktab(_:)):
            guard let session else { return false }
            select(max(session.index - 1, 0))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            session = nil
            return false
        default:
            return false
        }
    }

    func textChanged() {
        guard var current = session, let textView = code?.textView else { return }
        let length = (textView.string as NSString).length
        let delta = length - current.length
        var stop = current.stops[current.index]
        let caret = textView.selectedRange().location
        guard caret >= stop.location, caret <= NSMaxRange(stop) + delta else {
            session = nil
            return
        }
        stop.length += delta
        current.stops[current.index] = stop
        for i in current.stops.indices where i != current.index && current.stops[i].location > stop.location {
            current.stops[i].location += delta
        }
        current.length = length
        session = current
    }

    func selectionChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let session = self.session, let textView = self.code?.textView else { return }
            let selection = textView.selectedRange()
            let stop = session.stops[session.index]
            if selection.location < stop.location || NSMaxRange(selection) > NSMaxRange(stop) { self.session = nil }
        }
    }

    func fileOpened() { session = nil }

    func dismiss() { session = nil }

    func detach() { session = nil }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(SnippetsPlugin()) }
