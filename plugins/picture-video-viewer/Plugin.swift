import AppKit
import AVKit
import WebKit
@testable import FlareStackIDE

final class MediaViewerPlugin: NativePlugin, FileViewing {
    let id = "picture-video-viewer"
    private static let videos: Set<String> = ["mp4", "m4v", "mov", "avi"]

    func viewer(for url: URL) -> EditorExtension? {
        let ext = url.pathExtension.lowercased()
        guard PluginStore.installed(id)?.fileExtensions.contains(ext) == true else { return nil }
        return Self.videos.contains(ext) ? VideoViewer(file: url) : ImageViewer(file: url)
    }
}

class MediaViewer: NSObject, EditorExtension {
    let bar = NSView()
    let floating = false
    let corner = FloatCorner.bottomRight
    let file: URL
    private let info = NSTextField(labelWithString: "")
    private let size: String
    var body: NSView { bar }

    init(file: URL) {
        self.file = file
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        super.init()
        info.stringValue = size
        info.font = .systemFont(ofSize: 11, weight: .medium)
        info.textColor = .secondaryLabelColor
        info.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        [info, line].forEach(bar.addSubview)
        NSLayoutConstraint.activate([
            info.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            info.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
    }

    func showResolution(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        info.stringValue = "\(size)　\(width) × \(height)"
    }

    func update(text: String) {}
    func applySettings() {}
}

final class ImageViewer: MediaViewer, WKNavigationDelegate {
    private let web: WKWebView
    override var body: NSView { web }

    override init(file: URL) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(LocalFileScheme(), forURLScheme: LocalFileScheme.scheme)
        web = WKWebView(frame: .zero, configuration: config)
        web.allowsMagnification = true
        super.init(file: file)
        web.navigationDelegate = self
        load()
        NotificationCenter.default.addObserver(self, selector: #selector(load), name: .settingsChanged, object: nil)
    }

    @objc private func load() {
        let source = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let html = """
        <!doctype html><html style="height:100%"><body style="margin:0;height:100%;display:flex;align-items:center;\
        justify-content:center;background:\(Settings.background.hexString)">\
        <img src="\(source)" style="max-width:100%;max-height:100%"></body></html>
        """
        web.underPageBackgroundColor = Settings.background
        web.loadHTMLString(html, baseURL: LocalFileScheme.url(for: file.deletingLastPathComponent()))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("[document.images[0].naturalWidth, document.images[0].naturalHeight]") { [weak self] result, _ in
            guard let size = result as? [Int], size.count == 2 else { return }
            self?.showResolution(width: size[0], height: size[1])
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .linkActivated ? .cancel : .allow)
    }
}

private final class VideoBody: NSView {
    let player = AVPlayerView()
    private let message = NSTextField(labelWithString: "この形式の動画は再生できません")

    init() {
        super.init(frame: .zero)
        message.textColor = .secondaryLabelColor
        message.isHidden = true
        for view in [player, message] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            player.topAnchor.constraint(equalTo: topAnchor),
            player.leadingAnchor.constraint(equalTo: leadingAnchor),
            player.trailingAnchor.constraint(equalTo: trailingAnchor),
            player.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func showUnplayable() {
        player.isHidden = true
        message.isHidden = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { player.player?.pause() }
    }
}

final class VideoViewer: MediaViewer {
    private let video = VideoBody()
    override var body: NSView { video }

    override init(file: URL) {
        super.init(file: file)
        let asset = AVURLAsset(url: file)
        Task { @MainActor [weak self] in
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let track = try? await asset.loadTracks(withMediaType: .video).first
            guard let self else { return }
            guard playable else { return self.video.showUnplayable() }
            self.video.player.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            guard let track, let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return }
            let shown = size.applying(transform)
            self.showResolution(width: Int(abs(shown.width)), height: Int(abs(shown.height)))
        }
    }
}

@_cdecl("flarestack_plugin_load")
public func flarestackPluginLoad() { NativePlugins.register(MediaViewerPlugin()) }
