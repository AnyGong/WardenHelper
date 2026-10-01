import Cocoa

/// Keeps the app icon (About header, alerts) in step with light / dark mode. macOS has no
/// automatic dark variant for a classic `.icns`, so `AppIcon.icns` (light) is the bundle
/// default seen by Finder and Notification Center, and `AppIconDark.icns` is swapped in at
/// runtime while the system appearance is dark.
final class AppIconTheme: NSObject {
    static let shared = AppIconTheme()
    static let changedNotification = Notification.Name("AppIconThemeChanged")

    private var observation: NSKeyValueObservation?
    private lazy var lightIcon: NSImage? = Bundle.main.image(forResource: "AppIcon")
    private lazy var darkIcon: NSImage? = Bundle.main.image(forResource: "AppIconDark")

    /// Call once at launch.
    func start() {
        apply()
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.apply() }
        }
    }

    /// The icon for the current appearance.
    var current: NSImage? {
        let dark = Theme.isDark(NSApp.effectiveAppearance)
        return (dark ? darkIcon : lightIcon) ?? lightIcon
    }

    private func apply() {
        guard let image = current else { return }
        NSApp.applicationIconImage = image
        NotificationCenter.default.post(name: Self.changedNotification, object: image)
    }
}

/// An image view showing the app icon that swaps variants when the appearance changes.
final class AppIconImageView: NSImageView {
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = AppIconTheme.shared.current ?? NSApp.applicationIconImage
        observer = NotificationCenter.default.addObserver(
            forName: AppIconTheme.changedNotification, object: nil, queue: .main) { [weak self] note in
            if let icon = note.object as? NSImage { self?.image = icon }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
