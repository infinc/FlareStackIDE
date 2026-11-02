import AppKit
import PDFKit
@testable import FlareStackIDE

final class PDFViewerPlugin: NativePlugin, FileViewing {
    let id = "pdf-viewer"

    func viewer(for url: URL) -> EditorExtension? {
        guard PluginStore.installed(id)?.fileExtensions.contains(url.pathExtension.lowercased()) == true else { return nil }
        return PDFViewer(file: url)
    }
}

final class PDFViewer: NSObject, EditorExtension {
    let bar = NSView()
    let floating = true
    let corner = FloatCorner.bottomRight
    private let view = PDFView()
    var body: NSView { view }

    init?(file: URL) {
        guard let document = PDFDocument(url: file) else { return nil }
        super.init()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        applySettings()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
    }

    @objc private func settingsChanged() { applySettings() }

    func update(text: String) {}
    func applySettings() { view.backgroundColor = Settings.background }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(PDFViewerPlugin()) }
