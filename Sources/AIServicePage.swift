import Cocoa

/// The AI settings, in two places:
///  - VPN 与网络 › AI 出口 (`build`): the manual check button, the time of the last check and one
///    two-line row per service (logo, name, flag / country / city, latency; exit IP, Cloudflare
///    node, owner of the address), then how the checking runs (background check, interval).
///  - 菜单栏 › AI 状态 (`addMenuBarSection`): the bar icon and the exit region it expects. They
///    belong with the rest of what the bar shows.
/// The checking itself is `AIServiceMonitor`; this file only shows it.
enum AIServicePage {

    static func build(_ page: SettingsPage) {
        page.addSection(nil, rows: [makeRefreshRow()])
        page.addSection(L10n.aiSectionServices, view: AIServiceListView(), note: L10n.aiLatencyNote)
        page.addSection(L10n.aiSectionSettings, rows: [makeBackgroundRow(), makeIntervalRow()])
    }

    static func addMenuBarSection(to page: SettingsPage) {
        page.addSection(L10n.sectionAIBar, rows: [makeBarIconRow(), makeRegionRow()])
    }

    // MARK: Settings rows

    private static func makeBackgroundRow() -> SettingRow {
        let toggle = ToggleSwitch(frame: .zero)
        toggle.controlSize = .regular
        toggle.isOn = Preferences.shared.aiBackgroundCheck
        toggle.onToggle = { Preferences.shared.aiBackgroundCheck = $0 }   // AppDelegate applies it
        toggle.setAccessibilityLabel(L10n.aiBackgroundCheck)
        toggle.setAccessibilityRole(.checkBox)
        return SettingRow(title: L10n.aiBackgroundCheck, description: L10n.aiBackgroundCheckDesc, control: toggle)
    }

    private static func makeBarIconRow() -> SettingRow {
        let toggle = ToggleSwitch(frame: .zero)
        toggle.controlSize = .regular
        toggle.isOn = Preferences.shared.showAIStatus
        toggle.onToggle = { Preferences.shared.showAIStatus = $0 }
        toggle.setAccessibilityLabel(L10n.aiShowBarIcon)
        toggle.setAccessibilityRole(.checkBox)
        return SettingRow(title: L10n.aiShowBarIcon, description: L10n.aiShowBarIconDesc, control: toggle)
    }

    /// The one region the icon expects, picked from `Preferences.aiRegionChoices` (default: Taiwan).
    private static func makeRegionRow() -> SettingRow {
        let choices = Preferences.aiRegionChoices
        let popup = ClosurePopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .regular
        popup.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        popup.addItems(withTitles: choices.map { L10n.regionName($0) })
        popup.selectItem(at: choices.firstIndex(of: Preferences.shared.aiExpectedRegion) ?? 0)
        popup.target = popup
        popup.action = #selector(ClosurePopUpButton.fire)
        popup.onChange = { index in
            guard choices.indices.contains(index) else { return }
            Preferences.shared.aiExpectedRegion = choices[index]
        }
        popup.setAccessibilityLabel(L10n.aiExpectedRegion)
        return SettingRow(title: L10n.aiExpectedRegion, description: L10n.aiExpectedRegionDesc,
                          control: popup, controlSize: NSSize(width: 150, height: 0))
    }

    private static func makeIntervalRow() -> SettingRow {
        let range = Preferences.aiStatusIntervalRange

        let field = ClosureTextField()
        field.configure(text: String(Preferences.shared.aiStatusRefreshSeconds),
                        placeholder: String(Preferences.aiStatusIntervalDefault))
        field.alignment = .right
        field.lineBreakMode = .byTruncatingTail
        field.widthAnchor.constraint(equalToConstant: 84).isActive = true
        field.setAccessibilityLabel(L10n.aiRefreshInterval)
        field.onCommit = { [weak field] text in
            // Digits only; an empty or unreadable entry means "back to the default"; out-of-range is clamped.
            let digits = String(text.filter { $0.isASCII && $0.isNumber }.prefix(6))
            let wanted = Int(digits) ?? Preferences.aiStatusIntervalDefault
            let value = min(max(wanted, range.lowerBound), range.upperBound)
            Preferences.shared.aiStatusRefreshSeconds = value
            field?.reset(to: String(value))
            AIServiceMonitor.shared.rescheduleIfRunning()
        }

        let unit = NSTextField(labelWithString: L10n.unitSecond)
        unit.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        unit.textColor = Theme.secondaryText

        let control = NSStackView(views: [field, unit])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = 6
        return SettingRow(title: L10n.aiRefreshInterval, description: L10n.aiRefreshIntervalDesc, control: control)
    }

    private static func makeRefreshRow() -> SettingRow {
        let button = ClosureButton(title: L10n.aiRefreshButton, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        button.target = button
        button.action = #selector(ClosureButton.fire)
        button.onPress = { AIServiceMonitor.shared.refresh(force: true) }
        // Keeps the button's title and enabled state in step with the monitor for as long as it lives.
        objc_setAssociatedObject(button, &AIRefreshButtonBinder.key, AIRefreshButtonBinder(button), .OBJC_ASSOCIATION_RETAIN)
        return SettingRow(title: L10n.aiRefreshNow, control: button)
    }
}

/// "立即检测" while idle; "检测中..." and disabled while a round runs.
private final class AIRefreshButtonBinder {
    static var key = 0
    private weak var button: ClosureButton?
    private var observer: NSObjectProtocol?

    init(_ button: ClosureButton) {
        self.button = button
        observer = NotificationCenter.default.addObserver(forName: AIServiceMonitor.changedNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.update() }
        update()
    }

    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }

    private func update() {
        guard let button = button else { return }
        let busy = AIServiceMonitor.shared.isRefreshing
        let title = busy ? L10n.aiRefreshing : L10n.aiRefreshButton
        if button.title != title { button.title = title }
        button.isEnabled = !busy
    }
}

// MARK: - The service rows

/// "Last checked" at the top, then one compact row per service with a thin line between them.
/// It listens to the monitor (and to the hide-IP setting) for as long as it lives.
final class AIServiceListView: NSStackView {
    private var cards: [AIVendor: AIServiceCard] = [:]
    /// The service rows in display order (the settings search points at them).
    var serviceCards: [AIServiceCard] { AIVendor.allCases.compactMap { cards[$0] } }
    private let statusLabel = NSTextField(labelWithString: " ")
    private var observers: [NSObjectProtocol] = []

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0

        // The check time sits above the rows, in the card's own first line.
        statusLabel.font = NSFont.systemFont(ofSize: SettingsFont.note)
        statusLabel.textColor = Theme.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let statusHolder = NSView()
        statusHolder.translatesAutoresizingMaskIntoConstraints = false
        statusHolder.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusHolder.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusHolder.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: statusHolder.topAnchor, constant: 10),
            statusLabel.bottomAnchor.constraint(equalTo: statusHolder.bottomAnchor, constant: -10),
        ])
        addArrangedSubview(statusHolder)
        statusHolder.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        for vendor in AIVendor.allCases {
            let line = DividerView()
            line.translatesAutoresizingMaskIntoConstraints = false
            addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

            let card = AIServiceCard(vendor: vendor)
            cards[vendor] = card
            addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AIServiceMonitor.changedNotification, object: nil,
                                            queue: .main) { [weak self] _ in self?.reload() })
        observers.append(center.addObserver(forName: Preferences.changedNotification, object: nil,
                                            queue: .main) { [weak self] _ in self?.reload() })
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private func reload() {
        let monitor = AIServiceMonitor.shared
        for (vendor, card) in cards {
            card.show(monitor.results[vendor] ?? AIServiceStatus(), loading: monitor.loading.contains(vendor))
        }
        if monitor.isRefreshing {
            statusLabel.stringValue = L10n.aiChecking
        } else if let last = monitor.lastRefresh {
            statusLabel.stringValue = L10n.aiUpdatedAt(Self.timeFormat.string(from: last))
        } else {
            statusLabel.stringValue = " "
        }
    }
}

/// One service on two lines: logo; name, place and latency on the first; address, Cloudflare
/// node and owner on the second. Every label is a single line (long text is cut with an
/// ellipsis), so a row keeps its height from one refresh to the next and more services fit.
final class AIServiceCard: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let placeLabel = NSTextField(labelWithString: "")
    private let latencyLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    /// The service's name, for the settings search.
    let vendorName: String

    /// Space above and below the two lines of a row, and between the lines.
    private static let verticalPadding: CGFloat = 13
    private static let lineSpacing: CGFloat = 4

    init(vendor: AIVendor) {
        vendorName = vendor.displayName
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = AIIcons.image(for: vendor)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        if iconView.image?.isTemplate == true { iconView.contentTintColor = Theme.text }   // follows light / dark
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        nameLabel.stringValue = vendor.displayName
        nameLabel.font = NSFont.systemFont(ofSize: SettingsFont.body, weight: .semibold)
        nameLabel.textColor = Theme.text
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        placeLabel.font = NSFont.systemFont(ofSize: SettingsFont.body)
        placeLabel.textColor = Theme.text
        placeLabel.lineBreakMode = .byTruncatingTail
        placeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        latencyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: SettingsFont.body, weight: .medium)
        latencyLabel.alignment = .right
        latencyLabel.setContentHuggingPriority(.required, for: .horizontal)
        latencyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let titleRow = NSStackView(views: [nameLabel, placeLabel, spacer, latencyLabel])
        titleRow.orientation = .horizontal
        titleRow.distribution = .fill
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 10

        detailLabel.font = NSFont.systemFont(ofSize: SettingsFont.note)
        detailLabel.textColor = Theme.secondaryText
        detailLabel.lineBreakMode = .byTruncatingTail

        let column = NSStackView(views: [titleRow, detailLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Self.lineSpacing
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        titleRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        detailLabel.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            column.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
        ])
        show(AIServiceStatus(), loading: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `loading`: a check is under way. The last answer stays visible but dimmed and the latency
    /// reads "..."; with no answer yet the lines read "...".
    func show(_ status: AIServiceStatus, loading: Bool) {
        let dash = loading ? L10n.aiLoadingMark : "—"
        for label in [placeLabel, detailLabel] { label.alphaValue = loading ? 0.5 : 1 }
        defer {
            if loading {
                latencyLabel.stringValue = L10n.aiLoadingMark
                latencyLabel.textColor = Theme.secondaryText
            }
        }
        switch status.state {
        case .pending:
            placeLabel.stringValue = L10n.aiLoadingMark
            placeLabel.textColor = Theme.secondaryText
            detailLabel.stringValue = dash
            setLatency(nil)

        case .failed(let reason):
            placeLabel.stringValue = L10n.aiFailedPrefix + reason
            placeLabel.textColor = .systemRed
            detailLabel.stringValue = dash
            setLatency(nil)

        case .ok:
            var place = status.countryName.isEmpty ? L10n.aiUnknownPlace : status.countryName
            if !status.city.isEmpty { place += " · " + status.city }
            placeLabel.stringValue = status.flag + "  " + place
            placeLabel.textColor = Theme.text

            var parts = ["\(L10n.aiLabelIP) \(IPMask.displayed(status.ip))"]
            if !status.colo.isEmpty { parts.append("\(L10n.aiLabelNode) \(status.colo)") }
            parts.append("\(L10n.aiLabelOwner) \(status.provider.isEmpty ? dash : status.provider)")
            detailLabel.stringValue = parts.joined(separator: "   ·   ")
            setLatency(status.latencyMs)
        }
    }

    private func setLatency(_ ms: Int?) {
        guard let ms = ms else {
            latencyLabel.stringValue = ""
            return
        }
        latencyLabel.stringValue = "\(ms) ms"
        latencyLabel.textColor = ms < 300 ? .systemGreen : ms < 800 ? .systemOrange : .systemRed
    }
}
