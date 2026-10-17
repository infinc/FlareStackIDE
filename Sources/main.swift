import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var splash: NSWindow?
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showSplash()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.splash?.orderOut(nil)
            self?.splash = nil
            self?.showMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func showSplash() {
        guard let url = Bundle.main.url(forResource: "interpolate", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        let pixels = image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        let size = NSSize(width: pixels.width / 2, height: pixels.height / 2)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = view
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        splash = window
    }

    private func showMainWindow() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "FlareStackIDE v\(version)"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
