import AppKit

/// Keeps the Dock / app icon in sync with the system light/dark appearance.
final class DockIconController {
    static let shared = DockIconController()

    private var kvo: NSKeyValueObservation?
    private var observer: NSObjectProtocol?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        update()
        kvo = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.update()
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.update()
        }
    }

    private func update() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let name = dark ? "AppIconDark" : "AppIconLight"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }

    deinit {
        if let observer = observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
