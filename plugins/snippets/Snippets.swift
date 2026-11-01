import AppKit
@testable import FlareStackIDE

struct Snippet: Codable {
    var id = UUID().uuidString
    var trigger = ""
    var languages: [String] = []
    var body = ""

    private enum CodingKeys: String, CodingKey { case id, trigger, languages, body }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        trigger = try values.decode(String.self, forKey: .trigger)
        languages = try values.decodeIfPresent([String].self, forKey: .languages) ?? []
        body = try values.decode(String.self, forKey: .body)
    }
}

enum SnippetStore {
    static let pluginID = "snippets"
    private static let key = "Plugin.snippets.Items"

    static var builtin: [Snippet] = {
        let file = PluginStore.folder(pluginID).appendingPathComponent("snippets.json")
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
    }()

    static var items: [Snippet] {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static func available(for ext: String) -> [Snippet] {
        let user = items.filter { $0.languages.isEmpty || $0.languages.contains(ext) }
        let triggers = Set(user.map(\.trigger))
        return user + builtin.filter { ($0.languages.isEmpty || $0.languages.contains(ext)) && !triggers.contains($0.trigger) }
    }
}

enum SnippetBody {
    static func parse(_ body: String, indent: String) -> (text: String, stops: [NSRange]) {
        let source = body.replacingOccurrences(of: "\n", with: "\n" + indent) as NSString
        let pattern = try! NSRegularExpression(pattern: #"\$(\d+)|\$\{(\d+):([^}]*)\}"#)
        let output = NSMutableString()
        var found: [(number: Int, range: NSRange)] = []
        var cursor = 0
        for match in pattern.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
            output.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let plain = match.range(at: 1).location != NSNotFound
            let number = Int(source.substring(with: match.range(at: plain ? 1 : 2))) ?? 0
            let value = plain ? "" : source.substring(with: match.range(at: 3))
            found.append((number, NSRange(location: output.length, length: (value as NSString).length)))
            output.append(value)
            cursor = NSMaxRange(match.range)
        }
        output.append(source.substring(from: cursor))
        let ordered = found.sorted { ($0.number == 0 ? Int.max : $0.number) < ($1.number == 0 ? Int.max : $1.number) }
        return (output as String, ordered.map(\.range))
    }
}

final class SnippetSettingsView: NSStackView, NSTextFieldDelegate {
    private let rows = NSStackView()

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        let title = NSTextField(labelWithString: "自分のスニペット")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        let add = NSButton(title: "スニペットを追加", target: self, action: #selector(addClicked))
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        add.controlSize = .small
        let hint = NSTextField(wrappingLabelWithString: "左からトリガー・拡張子（カンマ区切り、空なら全ファイル）・本文。本文の \\n は改行、\\t はタブ、$1 や ${1:初期値} は Tab で移動する場所、$0 は最後の位置です。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.preferredMaxLayoutWidth = 380
        [title, rows, add, hint].forEach(addArrangedSubview)
        reload()
    }

    required init(coder: NSCoder) { fatalError() }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
    }

    private func field(_ value: String, width: CGFloat, placeholder: String, id: String, tag: Int) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.tag = tag
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func reload() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = SnippetStore.items
        if items.isEmpty {
            let none = NSTextField(labelWithString: "スニペットはまだありません。")
            none.textColor = .secondaryLabelColor
            rows.addArrangedSubview(none)
        }
        for item in items {
            let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "削除")!,
                                  target: self, action: #selector(removeClicked(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(item.id)
            remove.isBordered = false
            remove.toolTip = "削除"
            let row = NSStackView(views: [
                field(item.trigger, width: 80, placeholder: "for", id: item.id, tag: 0),
                field(item.languages.joined(separator: ","), width: 80, placeholder: "py,js", id: item.id, tag: 1),
                field(Self.escape(item.body), width: 200, placeholder: "for $1 in $2:\\n    $0", id: item.id, tag: 2),
                remove,
            ])
            row.spacing = 8
            rows.addArrangedSubview(row)
        }
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField, let id = field.identifier?.rawValue else { return }
        var items = SnippetStore.items
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch field.tag {
        case 0: items[index].trigger = field.stringValue.trimmingCharacters(in: .whitespaces)
        case 1: items[index].languages = field.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        default: items[index].body = Self.unescape(field.stringValue)
        }
        SnippetStore.items = items
    }

    @objc private func addClicked() {
        SnippetStore.items.append(Snippet())
        reload()
    }

    @objc private func removeClicked(_ sender: NSButton) {
        SnippetStore.items.removeAll { $0.id == sender.identifier?.rawValue }
        reload()
    }
}
