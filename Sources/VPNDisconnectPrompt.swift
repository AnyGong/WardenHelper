import Cocoa

/// The pop-up window for the whole VPN life cycle: every launch, every connect / disconnect, and
/// the status check after wake / unlock (a warning without a VPN, a confirmation with one). Non-modal and floating, on every Space; a second show while it is open only
/// updates it, and it closes by itself when the VPN is back. Colors are dynamic, so it follows
/// light / dark mode live. Main thread only.
final class VPNDisconnectPrompt: NSObject, NSWindowDelegate {
    static let shared = VPNDisconnectPrompt()

    /// Why the window is shown; decides the wording and the accent color.
    enum Reason {
        case dropped              // the VPN was up and went down
        case reconnected          // the VPN came (back) up while WardenHelper was running
        case notConnectedAtLaunch // WardenHelper started and no VPN is connected
        case connectedAtLaunch    // WardenHelper started and the VPN is already connected
        case resumeConnected      // after wake / unlock: the VPN is connected
        case resumeDisconnected   // after wake / unlock: the VPN is not connected

        var isConnected: Bool {
            switch self {
            case .reconnected, .connectedAtLaunch, .resumeConnected: return true
            case .dropped, .notConnectedAtLaunch, .resumeDisconnected: return false
            }
        }
    }

    private static let panelWidth: CGFloat = 460
    private static let inset: CGFloat = 28
    private static var contentWidth: CGFloat { panelWidth - inset * 2 }

    private var panel: NSPanel?
    private var iconCircle: AdaptiveCard?
    private var iconView: NSImageView?
    private var titleLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var bodyLabel: NSTextField?
    private var tipCard: AdaptiveCard?
    private var tipLabel: NSTextField?
    private var settingsButton: ClosureButton?

    private override init() { super.init() }

    func show(reason: Reason, interface: String?) {
        guard Preferences.shared.popupOnVPNDisconnect else { return }

        if let panel = panel {
            apply(reason: reason, interface: interface)
            if let content = panel.contentView { panel.setContentSize(content.fittingSize) }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        // Icon inside a tinted circle.
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconView = icon

        let circle = AdaptiveCard(radius: 30)
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(icon)
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 60),
            circle.heightAnchor.constraint(equalToConstant: 60),
            icon.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
        ])
        iconCircle = circle

        let title = NSTextField(labelWithString: "")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .labelColor
        titleLabel = title

        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        statusLabel = status

        let headTexts = NSStackView(views: [title, status])
        headTexts.orientation = .vertical
        headTexts.alignment = .leading
        headTexts.spacing = 4

        let head = NSStackView(views: [circle, headTexts])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 16

        // Main message.
        let body = NSTextField(wrappingLabelWithString: "")
        body.preferredMaxLayoutWidth = Self.contentWidth
        body.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        bodyLabel = body

        // Tip card: tinted, readable in both appearances.
        let tipText = NSTextField(wrappingLabelWithString: "")
        tipText.preferredMaxLayoutWidth = Self.contentWidth - 28
        tipText.translatesAutoresizingMaskIntoConstraints = false

        let tip = AdaptiveCard(radius: 10)
        tip.translatesAutoresizingMaskIntoConstraints = false
        tip.addSubview(tipText)
        NSLayoutConstraint.activate([
            tip.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            tipText.leadingAnchor.constraint(equalTo: tip.leadingAnchor, constant: 14),
            tipText.trailingAnchor.constraint(equalTo: tip.trailingAnchor, constant: -14),
            tipText.topAnchor.constraint(equalTo: tip.topAnchor, constant: 12),
            tipText.bottomAnchor.constraint(equalTo: tip.bottomAnchor, constant: -12),
        ])
        tipCard = tip
        tipLabel = tipText

        // Buttons: large hit areas, well apart.
        let settingsButton = Self.makeButton(L10n.vpnPopupOpenNetwork, symbol: "network", primary: false) { [weak self] in
            Self.openNetworkSettings()
            self?.dismiss()
        }
        self.settingsButton = settingsButton
        let okButton = Self.makeButton(L10n.vpnPopupDismiss, symbol: "checkmark", primary: true) { [weak self] in
            self?.dismiss()
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, settingsButton, okButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let root = NSStackView(views: [head, body, tip, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.setCustomSpacing(24, after: tip)
        // Extra room at the top: the title bar is transparent and the content runs under it.
        root.edgeInsets = NSEdgeInsets(top: 44, left: Self.inset, bottom: Self.inset - 4, right: Self.inset)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 300),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "WardenHelper"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor   // dynamic: follows light / dark
        panel.delegate = self
        panel.contentView = root
        self.panel = panel

        apply(reason: reason, interface: interface)
        panel.setContentSize(root.fittingSize)
        panel.center()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.close()   // windowWillClose clears the references
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        iconCircle = nil
        iconView = nil
        titleLabel = nil
        statusLabel = nil
        bodyLabel = nil
        tipCard = nil
        tipLabel = nil
        settingsButton = nil
    }

    // MARK: - Content

    /// Fills the window for `reason`; also used when it is already open.
    private func apply(reason: Reason, interface: String?) {
        let connected = reason.isConnected
        let accent: NSColor
        let title: String
        let bodyText: String
        switch reason {
        case .dropped:
            accent = .systemRed
            title = L10n.vpnPopupDroppedTitle
            bodyText = L10n.vpnPopupDroppedBody
        case .notConnectedAtLaunch:
            accent = .systemOrange
            title = L10n.vpnPopupLaunchTitle
            bodyText = L10n.vpnPopupLaunchBody
        case .connectedAtLaunch:
            accent = .systemGreen
            title = L10n.vpnPopupConnectedTitle
            bodyText = L10n.vpnPopupConnectedBody
        case .reconnected:
            accent = .systemGreen
            title = L10n.vpnPopupReconnectedTitle
            bodyText = L10n.vpnPopupReconnectedBody
        case .resumeConnected:
            accent = .systemGreen
            title = L10n.vpnPopupResumeOnTitle
            bodyText = L10n.vpnPopupResumeOnBody
        case .resumeDisconnected:
            accent = .systemRed
            title = L10n.vpnPopupResumeOffTitle
            bodyText = L10n.vpnPopupResumeOffBody
        }

        titleLabel?.stringValue = title
        statusLabel?.stringValue = connected ? L10n.vpnPopupStatusOn(interface) : L10n.vpnPopupStatus(interface)

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        bodyLabel?.attributedStringValue = NSAttributedString(string: bodyText, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style])

        let tipColor: NSColor = connected ? .systemGreen : .systemOrange
        iconCircle?.fill = accent.withAlphaComponent(0.16)
        tipCard?.fill = tipColor.withAlphaComponent(0.14)
        tipCard?.stroke = tipColor.withAlphaComponent(0.35)
        tipLabel?.attributedStringValue = Self.tipString(
            lead: connected ? L10n.vpnPopupConnectedTipLead : L10n.vpnPopupTipLead,
            text: connected ? L10n.vpnPopupConnectedTipText : L10n.vpnPopupTipText)

        // "Open network settings" only helps when there is no VPN.
        settingsButton?.isHidden = connected

        let symbol = connected ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [accent]))
            iconView?.image = base.withSymbolConfiguration(config)
        }
    }

    private static func tipString(lead: String, text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        let result = NSMutableAttributedString(
            string: lead,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: style])
        result.append(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: style]))
        return result
    }

    private static func makeButton(_ title: String, symbol: String, primary: Bool, action: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.setSymbol(symbol)
        button.font = NSFont.systemFont(ofSize: 14, weight: primary ? .semibold : .regular)
        if primary { button.keyEquivalent = "\r" }
        button.target = button
        button.action = #selector(ClosureButton.fire)
        button.onPress = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 116).isActive = true
        return button
    }

    private static func openNetworkSettings() {
        let candidates = ["x-apple.systempreferences:com.apple.Network-Settings.extension",
                          "x-apple.systempreferences:com.apple.preference.network"]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }
}

/// A rounded, tinted box whose colors are re-resolved on every appearance change, so the
/// layer follows light / dark mode without a restart.
private final class AdaptiveCard: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }

    init(radius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = stroke?.cgColor
            layer?.borderWidth = stroke == nil ? 0 : 1
        }
    }
}
