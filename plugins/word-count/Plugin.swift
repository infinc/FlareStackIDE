import Foundation

private let pluginID = "word-count"

private func count(_ text: String) -> [String: Any] {
    let characters = text.filter { !$0.isNewline }.count
    let visible = text.filter { !$0.isWhitespace }.count
    let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    var words = 0
    text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { _, _, _, _ in words += 1 }
    return ["characters": characters, "visible": visible, "lines": lines, "words": words, "bytes": text.utf8.count]
}

private let reply: Host.WorkerReply = { context, result, error in
    let title = context.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? "文字数"
    if let error { return Host.toast("\(title)を数えられませんでした", String(cString: error)) }
    guard let result else { return }
    let value = WorkerJSON.decode(result)
    let number = { (key: String) in (value[key] as? NSNumber)?.intValue ?? 0 }
    Host.toast("\(title): \(number("characters")) 文字",
               "空白を除く \(number("visible")) 文字 · \(number("words")) 語 · \(number("lines")) 行 · \(number("bytes")) バイト")
}

private let fileTitle = strdup("ファイルの文字数")
private let selectionTitle = strdup("選択範囲の文字数")

private func request(_ text: String?, title: UnsafeMutablePointer<CChar>?) {
    guard let text else { return Host.toast("数えるファイルを開いてください") }
    let json = WorkerJSON.encode(["text": text]).map { pointer -> String in
        defer { free(pointer) }
        return String(cString: pointer)
    } ?? "{}"
    Host.workerCall(pluginID, json, context: UnsafeMutableRawPointer(title), reply)
}

@_cdecl("flarestack_plugin_load_c")
public func flarestackPluginLoadC(_ hostVersion: Int32) -> Int32 {
    guard hostVersion >= 1 else { return 1 }
    Host.registerCommand("count-file", "文字数: 今のファイルを数える") { _ in request(Host.currentText, title: fileTitle) }
    Host.registerCommand("count-selection", "文字数: 選択範囲を数える") { _ in
        let selected = Host.selectedText
        request(selected?.isEmpty == false ? selected : nil, title: selectionTitle)
    }
    return 0
}

@_cdecl("flarestack_worker")
public func flarestackWorker(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    let value = WorkerJSON.decode(request)
    return WorkerJSON.encode(count(value["text"] as? String ?? ""))
}
