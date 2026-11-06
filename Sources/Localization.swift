import AppKit
import ObjectiveC

enum AppLanguage: String, CaseIterable {
    case auto, ja, en

    var title: String {
        switch self {
        case .auto: return "システムに合わせる"
        case .ja: return "日本語"
        case .en: return "English"
        }
    }
}

func L(_ text: String) -> String { L10n.translate(text) }

enum L10n {
    private static let key = "App.Language"
    private(set) static var english = false
    private static var exact: [String: String] = [:]
    private static var reverse: [String: String] = [:]
    private static var templates: [(regex: NSRegularExpression, value: String)] = []
    private static var cache: [String: String] = [:]
    private static let japanese = try! NSRegularExpression(pattern: "[\\u3001\\u3002\\u3040-\\u30FF\\u3400-\\u9FFF\\uFF01-\\uFF5E]")
    private static let separators = ["\n", "　·　", " · ", "：", ": ", "、"]

    static var language: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            guard resolved(newValue) != english else { return }
            Toasts.post("表示の言語は再起動後に切り替わります", actions: [("今すぐ再起動", { Updater.relaunch() })])
        }
    }

    private static func resolved(_ language: AppLanguage) -> Bool {
        switch language {
        case .ja: return false
        case .en: return true
        case .auto: return !(Locale.preferredLanguages.first ?? "ja").hasPrefix("ja")
        }
    }

    static func install() {
        english = resolved(language)
        guard english else { return }
        load(EnglishTable.text)
        swizzle(NSTextField.self, #selector(setter: NSTextField.stringValue), #selector(NSTextField.l10n_setStringValue(_:)))
        swizzle(NSTextField.self, #selector(setter: NSTextField.placeholderString), #selector(NSTextField.l10n_setPlaceholderString(_:)))
        swizzle(NSButton.self, #selector(setter: NSButton.title), #selector(NSButton.l10n_setTitle(_:)))
        swizzle(NSMenuItem.self, #selector(setter: NSMenuItem.title), #selector(NSMenuItem.l10n_setTitle(_:)))
        swizzle(NSMenu.self, #selector(NSMenu.insertItem(_:at:)), #selector(NSMenu.l10n_insertItem(_:at:)))
        swizzle(NSAlert.self, #selector(NSAlert.runModal), #selector(NSAlert.l10n_runModal))
        swizzle(NSAlert.self, #selector(NSAlert.beginSheetModal(for:completionHandler:)), #selector(NSAlert.l10n_beginSheetModal(for:completionHandler:)))
        swizzle(NSView.self, #selector(setter: NSView.toolTip), #selector(NSView.l10n_setToolTip(_:)))
        swizzle(NSWindow.self, #selector(setter: NSWindow.title), #selector(NSWindow.l10n_setTitle(_:)))
        swizzle(NSAlert.self, #selector(setter: NSAlert.messageText), #selector(NSAlert.l10n_setMessageText(_:)))
        swizzle(NSAlert.self, #selector(setter: NSAlert.informativeText), #selector(NSAlert.l10n_setInformativeText(_:)))
        swizzle(NSAlert.self, #selector(NSAlert.addButton(withTitle:)), #selector(NSAlert.l10n_addButton(withTitle:)))
        swizzle(NSSegmentedControl.self, #selector(NSSegmentedControl.setLabel(_:forSegment:)), #selector(NSSegmentedControl.l10n_setLabel(_:forSegment:)))
        swizzle(NSSegmentedControl.self, #selector(NSSegmentedControl.setToolTip(_:forSegment:)), #selector(NSSegmentedControl.l10n_setToolTip(_:forSegment:)))
        swizzle(NSTabViewItem.self, #selector(setter: NSTabViewItem.label), #selector(NSTabViewItem.l10n_setLabel(_:)))
        swizzle(NSTableColumn.self, #selector(setter: NSTableColumn.title), #selector(NSTableColumn.l10n_setTitle(_:)))
    }

    private static func swizzle(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(type, original), let b = class_getInstanceMethod(type, replacement) else { return }
        if class_addMethod(type, original, method_getImplementation(b), method_getTypeEncoding(b)) {
            class_replaceMethod(type, replacement, method_getImplementation(a), method_getTypeEncoding(a))
        } else {
            method_exchangeImplementations(a, b)
        }
    }

    static func load(_ table: String) {
        for line in table.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.components(separatedBy: " => ")
            guard parts.count == 2 else { continue }
            let source = unescape(parts[0]), target = unescape(parts[1])
            if source.contains("{}") {
                let pattern = source.components(separatedBy: "{}").map(NSRegularExpression.escapedPattern).joined(separator: "(.+?)")
                if let regex = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.dotMatchesLineSeparators]) {
                    templates.append((regex, target))
                }
            } else {
                exact[source] = target
                reverse[target] = source
            }
        }
        templates.sort { $0.regex.pattern.count > $1.regex.pattern.count }
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
    }

    static func original(_ text: String?) -> String? { text.map { reverse[$0] ?? $0 } }

    private static func hasJapanese(_ text: String) -> Bool {
        japanese.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func translate(_ text: String) -> String {
        guard english, !text.isEmpty, hasJapanese(text) else { return text }
        if let cached = cache[text] { return cached }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var result = trimmed == text ? lookup(text) : text.replacingOccurrences(of: trimmed, with: lookup(trimmed))
        if result == text { result = split(text) }
        if cache.count > 4000 { cache.removeAll() }
        cache[text] = result
        return result
    }

    private static func lookup(_ text: String) -> String {
        if let found = exact[text] { return found }
        let range = NSRange(location: 0, length: (text as NSString).length)
        for (regex, value) in templates {
            guard let match = regex.firstMatch(in: text, range: range) else { continue }
            let groups = (1..<match.numberOfRanges).map { (text as NSString).substring(with: match.range(at: $0)) }
            var output = value
            for (i, group) in groups.enumerated() {
                output = output.replacingOccurrences(of: "{\(i + 1)}", with: translate(group))
            }
            var index = 0
            while let marker = output.range(of: "{}"), index < groups.count {
                output.replaceSubrange(marker, with: translate(groups[index]))
                index += 1
            }
            return output
        }
        return text
    }

    private static func split(_ text: String) -> String {
        for separator in separators where text.contains(separator) {
            let parts = text.components(separatedBy: separator)
            let translated = parts.map(translate)
            if translated != parts || separator == "、" || separator == "：" {
                return translated.joined(separator: separator == "、" ? ", " : separator == "：" ? ": " : separator)
            }
        }
        return text
    }
}

extension NSTextField {
    @objc fileprivate func l10n_setStringValue(_ value: String) {
        l10n_setStringValue(isEditable || isKind(of: NSSearchField.self) ? value : L10n.translate(value))
    }

    @objc fileprivate func l10n_setPlaceholderString(_ value: String?) { l10n_setPlaceholderString(value.map(L10n.translate)) }
}

extension NSButton {
    @objc fileprivate func l10n_setTitle(_ value: String) { l10n_setTitle(L10n.translate(value)) }
}

extension NSMenuItem {
    @objc fileprivate func l10n_setTitle(_ value: String) { l10n_setTitle(L10n.translate(value)) }
}

extension NSMenu {
    @objc fileprivate func l10n_insertItem(_ item: NSMenuItem, at index: Int) {
        if !item.isSeparatorItem, item.attributedTitle == nil { item.title = item.title }
        item.toolTip = item.toolTip
        l10n_insertItem(item, at: index)
    }
}

extension NSView {
    @objc fileprivate func l10n_setToolTip(_ value: String?) { l10n_setToolTip(value.map(L10n.translate)) }
}

extension NSWindow {
    @objc fileprivate func l10n_setTitle(_ value: String) { l10n_setTitle(L10n.translate(value)) }
}

extension NSAlert {
    @objc fileprivate func l10n_setMessageText(_ value: String) { l10n_setMessageText(L10n.translate(value)) }
    @objc fileprivate func l10n_setInformativeText(_ value: String) { l10n_setInformativeText(L10n.translate(value)) }
    @objc fileprivate func l10n_addButton(withTitle title: String) -> NSButton { l10n_addButton(withTitle: L10n.translate(title)) }

    private func translateTexts() {
        messageText = messageText
        informativeText = informativeText
    }

    @objc fileprivate func l10n_runModal() -> NSApplication.ModalResponse {
        translateTexts()
        return l10n_runModal()
    }

    @objc fileprivate func l10n_beginSheetModal(for window: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)?) {
        translateTexts()
        l10n_beginSheetModal(for: window, completionHandler: handler)
    }
}

extension NSSegmentedControl {
    @objc fileprivate func l10n_setLabel(_ label: String, forSegment segment: Int) { l10n_setLabel(L10n.translate(label), forSegment: segment) }
    @objc fileprivate func l10n_setToolTip(_ tip: String?, forSegment segment: Int) { l10n_setToolTip(tip.map(L10n.translate), forSegment: segment) }
}

extension NSTableColumn {
    @objc fileprivate func l10n_setTitle(_ value: String) { l10n_setTitle(L10n.translate(value)) }
}

extension NSTabViewItem {
    @objc fileprivate func l10n_setLabel(_ value: String) { l10n_setLabel(L10n.translate(value)) }
}
