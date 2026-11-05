import AppKit
import UniformTypeIdentifiers

struct UserTheme: Codable, Equatable {
    var name: String
    var colors: [String]
    var foreground: String
    var palette: [String]
}

final class ThemeImport: NSObject {
    static let shared = ThemeImport()

    private static let tokens: [[String]] = [
        ["comment.line", "comment"],
        ["string.quoted.double", "string"],
        ["constant.numeric"],
        ["keyword.control", "keyword", "storage.modifier", "storage"],
        ["entity.name.type.class", "entity.name.type", "support.type", "storage.type"],
        ["entity.name.function", "support.function", "meta.function-call"],
        ["entity.name.tag"],
        ["entity.other.attribute-name"],
        ["markup.heading", "entity.name.section"],
        ["markup.bold", "markup.italic"],
        ["markup.underline.link", "string.other.link"],
        ["markup.inline.raw", "markup.raw", "markup.fenced_code"],
        ["meta.preprocessor", "keyword.control.directive", "meta.decorator", "entity.name.function.decorator"],
        ["variable.other.readwrite", "variable.other", "variable", "variable.parameter"],
        ["constant.language", "constant.character", "support.constant", "constant"],
        ["variable.other.property", "support.type.property-name", "meta.object-literal.key"],
        ["markup.list", "punctuation.definition.list", "keyword.operator"],
    ]

    private static let surfaceKeys: [[String]] = [
        ["editor.background"],
        ["sideBar.background", "panel.background", "editor.background"],
        ["tab.inactiveBackground", "editorGroupHeader.tabsBackground", "sideBar.background", "editor.background"],
        ["activityBar.background", "titleBar.activeBackground", "sideBar.background", "editor.background"],
    ]

    @objc func importClicked(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "VS Code テーマを読み込む"
        panel.message = "VS Code のテーマ（.json）を選んでください。拡張機能の themes フォルダにあります"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        let window = NSApp.keyWindow
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let theme = try Self.load(url)
                Settings.addUserTheme(theme)
                Toasts.post("テーマ「\(theme.name)」を読み込みました", in: window)
            } catch {
                Toasts.post("テーマを読み込めませんでした", message: error.localizedDescription, in: window)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    static func load(_ url: URL) throws -> UserTheme {
        let root = try object(url, depth: 0)
        let colors = root["colors"] as? [String: Any] ?? [:]
        let rules = (root["tokenColors"] as? [[String: Any]] ?? []).compactMap(rule)
        let surfaces = surfaceKeys.map { keys in keys.lazy.compactMap { colors[$0] as? String }.compactMap(normalize).first ?? "" }
        guard !surfaces[0].isEmpty || !rules.isEmpty else { throw failure("テーマの色が見つかりませんでした") }
        let foreground = (colors["editor.foreground"] as? String).flatMap(normalize) ?? ""
        let palette = tokens.map { candidates in candidates.lazy.compactMap { color(for: $0, in: rules) }.first ?? "" }
        let name = root["name"] as? String ?? url.deletingPathExtension().lastPathComponent
        return UserTheme(name: name, colors: surfaces, foreground: foreground, palette: palette)
    }

    private static func failure(_ message: String) -> Error {
        NSError(domain: appName, code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func object(_ url: URL, depth: Int) throws -> [String: Any] {
        guard depth < 5 else { throw failure("include が深すぎます") }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let parsed = try JSONSerialization.jsonObject(with: Data(stripJSONC(text).utf8)) as? [String: Any] else {
            throw failure("JSON の形式が正しくありません")
        }
        guard let include = parsed["include"] as? String else { return parsed }
        var base = (try? object(url.deletingLastPathComponent().appendingPathComponent(include), depth: depth + 1)) ?? [:]
        let baseColors = base["colors"] as? [String: Any] ?? [:]
        let baseTokens = base["tokenColors"] as? [[String: Any]] ?? []
        for (key, value) in parsed { base[key] = value }
        base["colors"] = baseColors.merging(parsed["colors"] as? [String: Any] ?? [:]) { $1 }
        base["tokenColors"] = baseTokens + (parsed["tokenColors"] as? [[String: Any]] ?? [])
        return base
    }

    static func stripJSONC(_ text: String) -> String {
        var out = ""
        var chars = Array(text)[...]
        var inString = false
        while let c = chars.popFirst() {
            if inString {
                out.append(c)
                if c == "\\", let next = chars.popFirst() { out.append(next) } else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
            } else if c == "/", chars.first == "/" {
                while let next = chars.first, next != "\n" { chars.removeFirst() }
            } else if c == "/", chars.first == "*" {
                chars.removeFirst()
                while let next = chars.popFirst(), !(next == "*" && chars.first == "/") {}
                _ = chars.popFirst()
            } else if c == "," {
                let rest = chars.drop { $0.isWhitespace }
                if let next = rest.first, next == "}" || next == "]" { continue }
                out.append(c)
            } else {
                out.append(c)
            }
        }
        return out
    }

    private static func normalize(_ hex: String) -> String? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 || digits.count == 4 { digits = String(digits.prefix(3).flatMap { [$0, $0] }) }
        guard digits.count == 6 || digits.count == 8, UInt32(digits.prefix(6), radix: 16) != nil else { return nil }
        return "#" + digits.prefix(6).uppercased()
    }

    private static func rule(_ entry: [String: Any]) -> (scopes: [String], color: String)? {
        guard let settings = entry["settings"] as? [String: Any],
              let color = (settings["foreground"] as? String).flatMap(normalize) else { return nil }
        let raw: [String]
        if let list = entry["scope"] as? [String] {
            raw = list
        } else if let text = entry["scope"] as? String {
            raw = text.split(separator: ",").map(String.init)
        } else {
            return nil
        }
        let scopes = raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains(" ") }
        return scopes.isEmpty ? nil : (scopes, color)
    }

    private static func color(for token: String, in rules: [(scopes: [String], color: String)]) -> String? {
        var best: (length: Int, color: String)?
        for rule in rules {
            for scope in rule.scopes where token == scope || token.hasPrefix(scope + ".") {
                if scope.count >= (best?.length ?? 0) { best = (scope.count, rule.color) }
            }
        }
        return best?.color
    }
}
