import AppKit

enum HostAPI {
    static let version: Int32 = 1
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias WorkerReply = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    private typealias Load = @convention(c) (Int32) -> Int32

    struct Command {
        let plugin: String
        let id: String
        let title: String
        let callback: Callback
        let context: UnsafeMutableRawPointer?
    }

    private(set) static var commands: [Command] = []
    fileprivate static var loading: String?

    static func isCABI(_ manifest: [String: Any]?) -> Bool { manifest?["abi"] as? String == "c" }

    static func required(_ manifest: [String: Any]?) -> Int32 { Int32((manifest?["hostAPI"] as? NSNumber)?.intValue ?? 1) }

    static func load(_ file: URL, id: String, name: String) -> Bool {
        guard let handle = dlopen(file.path, RTLD_NOW | RTLD_LOCAL) else {
            Toasts.post("\(name) を読み込めませんでした", message: dlerror().map { String(cString: $0) } ?? "")
            return false
        }
        guard let symbol = dlsym(handle, "flarestack_plugin_load_c") else {
            Toasts.post("\(name) を読み込めませんでした", message: "flarestack_plugin_load_c がありません")
            return false
        }
        loading = id
        defer { loading = nil }
        let status = unsafeBitCast(symbol, to: Load.self)(version)
        guard status == 0 else {
            Toasts.post("\(name) を読み込めませんでした", message: "プラグインが初期化に失敗しました（\(status)）")
            commands.removeAll { $0.plugin == id }
            return false
        }
        return true
    }

    static var paletteCommands: [PaletteCommand] {
        commands.map { command in
            PaletteCommand(id: "capi.\(command.plugin).\(command.id)", title: command.title) { command.callback(command.context) }
        }
    }

    fileprivate static var editor: EditorWindowController? {
        (NSApp.keyWindow?.windowController as? EditorWindowController)
            ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? EditorWindowController }.first
    }

    fileprivate static func text(_ pointer: UnsafePointer<CChar>?) -> String? { pointer.map { String(cString: $0) } }

    fileprivate static func copy(_ text: String?) -> UnsafeMutablePointer<CChar>? { text.flatMap { strdup($0) } }

    fileprivate static func register(_ id: String, _ title: String, _ callback: Callback, _ context: UnsafeMutableRawPointer?) -> Int32 {
        guard let plugin = loading else { return -1 }
        commands.removeAll { $0.plugin == plugin && $0.id == id }
        commands.append(Command(plugin: plugin, id: id, title: title, callback: callback, context: context))
        return 0
    }
}

@_cdecl("flarestack_host_symbol")
func flarestackHostSymbol(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name = HostAPI.text(name), name.range(of: #"^[a-z_]+$"#, options: .regularExpression) != nil else { return nil }
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), "flarestack_host_" + name)
}

@_cdecl("flarestack_host_api_version")
func flarestackHostAPIVersion() -> Int32 { HostAPI.version }

@_cdecl("flarestack_host_free")
func flarestackHostFree(_ pointer: UnsafeMutableRawPointer?) { free(pointer) }

@_cdecl("flarestack_host_toast")
func flarestackHostToast(_ title: UnsafePointer<CChar>?, _ message: UnsafePointer<CChar>?) {
    guard let title = HostAPI.text(title) else { return }
    Toasts.post(title, message: HostAPI.text(message), in: HostAPI.editor?.window)
}

@_cdecl("flarestack_host_register_command")
func flarestackHostRegisterCommand(_ id: UnsafePointer<CChar>?, _ title: UnsafePointer<CChar>?,
                                   _ callback: HostAPI.Callback?, _ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let id = HostAPI.text(id), let title = HostAPI.text(title), let callback else { return -1 }
    return HostAPI.register(id, title, callback, context)
}

@_cdecl("flarestack_host_current_file")
func flarestackHostCurrentFile() -> UnsafeMutablePointer<CChar>? { HostAPI.copy(HostAPI.editor?.fileURL?.path) }

@_cdecl("flarestack_host_current_text")
func flarestackHostCurrentText() -> UnsafeMutablePointer<CChar>? {
    guard let editor = HostAPI.editor, editor.fileURL != nil else { return nil }
    return HostAPI.copy(editor.textView.string)
}

@_cdecl("flarestack_host_selected_text")
func flarestackHostSelectedText() -> UnsafeMutablePointer<CChar>? {
    guard let textView = HostAPI.editor?.textView else { return nil }
    return HostAPI.copy((textView.string as NSString).substring(with: textView.selectedRange()))
}

@_cdecl("flarestack_host_replace_selection")
func flarestackHostReplaceSelection(_ text: UnsafePointer<CChar>?) -> Int32 {
    guard let text = HostAPI.text(text), let editor = HostAPI.editor, editor.fileURL != nil else { return -1 }
    let textView = editor.textView
    let range = textView.selectedRange()
    guard textView.isEditable, textView.shouldChangeText(in: range, replacementString: text) else { return -1 }
    textView.replaceCharacters(in: range, with: text)
    textView.didChangeText()
    return 0
}

@_cdecl("flarestack_host_open_location")
func flarestackHostOpenLocation(_ path: UnsafePointer<CChar>?, _ line: Int32, _ column: Int32) {
    guard let path = HostAPI.text(path) else { return }
    HostAPI.editor?.openLocation(URL(fileURLWithPath: path), line: Int(max(line, 1)), column: column > 0 ? Int(column) : nil)
}

@_cdecl("flarestack_host_setting")
func flarestackHostSetting(_ plugin: UnsafePointer<CChar>?, _ key: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let plugin = HostAPI.text(plugin), let key = HostAPI.text(key) else { return nil }
    return HostAPI.copy(PluginStore.setting(plugin, key))
}

@_cdecl("flarestack_host_post_event")
func flarestackHostPostEvent(_ name: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?) {
    guard let name = HostAPI.text(name), name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return }
    let info = HostAPI.text(json).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    NotificationCenter.default.post(name: Notification.Name("FlareStackIDE." + name), object: nil, userInfo: info)
}

@_cdecl("flarestack_host_worker_call")
func flarestackHostWorkerCall(_ plugin: UnsafePointer<CChar>?, _ json: UnsafePointer<CChar>?,
                              _ reply: HostAPI.WorkerReply?, _ context: UnsafeMutableRawPointer?) {
    guard let plugin = HostAPI.text(plugin), let reply else { return }
    let request = HostAPI.text(json).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
    PluginWorker.call(plugin, request) { result in
        switch result {
        case .success(let value):
            let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
            String(decoding: data, as: UTF8.self).withCString { reply(context, $0, nil) }
        case .failure(let error):
            error.localizedDescription.withCString { reply(context, nil, $0) }
        }
    }
}
