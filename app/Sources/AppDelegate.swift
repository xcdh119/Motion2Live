import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard args.contains("--snapshot") || args.contains("--snapshot-empty") else { return }

        let model = AppModel.shared
        if args.contains("--snapshot") { model.loadDemo() }
        let light = args.contains("--light")
        let empty = args.contains("--snapshot-empty")
        let path = empty
            ? (light ? "/tmp/livephoto_app_empty_light.png" : "/tmp/livephoto_app_empty.png")
            : (light ? "/tmp/livephoto_app_light.png" : "/tmp/livephoto_app.png")
        if light { NSApp.appearance = NSAppearance(named: .aqua) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            SnapshotRenderer.render(model: model, to: path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showExistingOrCreateMainWindow()
        return false
    }

    static func configureMainWindow(_ window: NSWindow) {
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = NSSize(width: 1020, height: 680)
        window.maxSize = NSSize(width: 1600, height: CGFloat.greatestFiniteMagnitude)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = L10n.appName
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.titlebarSeparatorStyle = .none
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.isEnabled = true
            let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: "放大窗口")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))
            plus?.isTemplate = true
            zoomButton.image = plus
            zoomButton.alternateImage = plus
        }
        window.collectionBehavior.insert(.fullScreenNone)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
    }

    private func findMainWindow() -> NSWindow? {
        let aux = [L10n.settings, L10n.conversionLog, L10n.history]
        return NSApp.windows.first {
            $0.canBecomeMain && !$0.title.isEmpty && !aux.contains($0.title)
        }
    }

    private func showExistingOrCreateMainWindow() {
        if let window = Self.mainWindow ?? findMainWindow() {
            Self.mainWindow = window
            if window.isMiniaturized { window.deminiaturize(nil) }
            Self.configureMainWindow(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            createMainWindow()
        }
    }

    private func createMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 692),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.appName
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(model: AppModel.shared))
        host.frame = NSRect(x: 0, y: 0, width: 1060, height: 692)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.center()
        Self.configureMainWindow(window)
        Self.mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
