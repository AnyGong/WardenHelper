import Cocoa

/// The settings window's palette, modelled on macOS System Settings. One set of surfaces, each a
/// step from the next, in both appearances (gray values; light → dark):
///
///     sidebar   0.965 → 0.175   the left list
///     page      1.000 → 0.125   the right pane: pure white in light mode, as in System Settings
///     card      0.973 → 0.215   a section's block of rows: a faint gray panel on the white page
///
/// In light mode the card is a flat, slightly darker panel with no outline or shadow (the contrast
/// with the white page is the edge); rows inside it are split by a soft solid line. In dark mode the
/// card is lifted a step above the page. Text is a charcoal / near-white primary and a mid-gray
/// secondary. Selection and accents use the system accent color.
enum Theme {
    // MARK: Text
    /// Titles and other primary text.
    static let text = dynamic(light: 0.17, dark: 0.95)
    /// Descriptions, section headers, units.
    static let secondaryText = dynamic(light: 0.50, dark: 0.68)

    // MARK: Surfaces
    static let sidebarFill = dynamic(light: 0.965, dark: 0.175)
    static let contentFill = dynamic(light: 1.0, dark: 0.125)
    static let groupFill = dynamic(light: 0.973, dark: 0.215)

    // MARK: Lines
    /// The line between two rows of a card (and under the page title): a soft solid gray that stays
    /// close to the card color.
    static let rowDivider = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0.933, alpha: 1)
    }
    /// The line between the sidebar and the page.
    static let sidebarDivider = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.10)
    }

    // MARK: Selection
    /// The selected sidebar row.
    static let selection = NSColor.controlAccentColor

    // MARK: Helpers
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func dynamic(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: isDark(appearance) ? dark : light, alpha: 1)
        }
    }
}

/// A one-point line in `Theme.rowDivider`; replaces the system separator, whose gray is
/// translucent and varies with whatever sits behind it.
final class DividerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.rowDivider.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Monochrome SF Symbol helper, now used only by the VPN pop-up buttons: template images, so they take the color of the
/// text or button they sit in. A name that does not exist on this macOS gives nil, and the
/// caller simply shows no icon.
enum Symbols {
    static func image(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = true
        return image
    }
}

extension ClosureButton {
    /// A monochrome SF Symbol left of the title (nil removes it).
    func setSymbol(_ name: String?) {
        guard let name = name, let icon = Symbols.image(name, size: 13) else {
            image = nil
            imagePosition = .noImage
            return
        }
        image = icon
        imagePosition = .imageLeading
    }
}

extension NSView {
    /// Keeps a control at least `height` tall, so it is easy to aim at and click.
    func pinMinHeight(_ height: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
    }
}

/// Size of the interactive controls in the settings window: the standard macOS "regular"
/// controls, with the same 13 pt text as System Settings.
enum ControlMetrics {
    static let height: CGFloat = 22
    /// Text size inside buttons, fields and pop-ups (`NSFont.systemFontSize`).
    static let fontSize: CGFloat = 13
    static let minButtonWidth: CGFloat = 64
}

/// The text sizes of the settings content area, as in System Settings.
enum SettingsFont {
    /// Row titles, field values, buttons.
    static let body: CGFloat = 13
    /// Descriptions and hints under a row (`NSFont.smallSystemFontSize`).
    static let note: CGFloat = 11
    /// Page title at the top of the right pane.
    static let title: CGFloat = 15
}

extension NSView {
    /// A short accent-colored flash over the view, used to point at a search result.
    func flashHighlight() {
        wantsLayer = true
        guard let layer = layer else { return }
        let overlay = CALayer()
        overlay.frame = bounds
        overlay.cornerRadius = 6
        effectiveAppearance.performAsCurrentDrawingAppearance {
            overlay.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        }
        overlay.opacity = 0
        layer.addSublayer(overlay)

        CATransaction.begin()
        CATransaction.setCompletionBlock { overlay.removeFromSuperlayer() }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.55, 1]
        fade.duration = 1.6
        overlay.add(fade, forKey: "flash")
        CATransaction.commit()
    }
}
