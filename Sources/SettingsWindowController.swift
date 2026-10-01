import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Native toggle switch

/// The system NSSwitch, with a closure and an `isOn` convenience.
final class ToggleSwitch: NSSwitch {
    var onToggle: ((Bool) -> Void)?

    var isOn: Bool {
        get { state == .on }
        set { state = newValue ? .on : .off }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onToggle?(isOn) }
}

// MARK: - Controls that report through a closure

final class ClosureSegmentedControl: NSSegmentedControl {
    var onChange: ((Int) -> Void)?
    @objc func fire() { onChange?(selectedSegment) }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = max(size.height, ControlMetrics.height)
        return size
    }
}

final class ClosurePopUpButton: NSPopUpButton {
    var onChange: ((Int) -> Void)?
    @objc func fire() { onChange?(indexOfSelectedItem) }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = max(size.height, ControlMetrics.height)
        return size
    }
}

final class ClosureButton: NSButton {
    var onPress: (() -> Void)?
    @objc func fire() { onPress?() }

    /// A standard regular button, at least `minButtonWidth` wide.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = max(size.width, ControlMetrics.minButtonWidth)
        size.height = max(size.height, ControlMetrics.height)
        return size
    }
}

/// A text field that reports its text on Return, Tab and when editing ends (only if it changed).
final class ClosureTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    private var committed = ""

    func configure(text: String, placeholder: String) {
        stringValue = text
        committed = text
        placeholderString = placeholder
        lineBreakMode = .byTruncatingHead
        usesSingleLineMode = true
        delegate = self
        target = self
        action = #selector(commitNow)
    }

    @objc private func commitNow() { commit() }
    func controlTextDidEndEditing(_ obj: Notification) { commit() }

    /// Shows `text` and counts it as already committed (used when the callback corrected the entry).
    func reset(to text: String) {
        stringValue = text
        committed = text
    }

    private func commit() {
        let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != stringValue { stringValue = text }
        guard text != committed else { return }
        committed = text
        onCommit?(text)
    }
}

/// The same for a secret: dots on screen, no copy of the text kept anywhere but the callback.
final class ClosureSecureField: NSSecureTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    private var committed = ""

    func configure(text: String, placeholder: String) {
        stringValue = text
        committed = text
        placeholderString = placeholder
        usesSingleLineMode = true
        delegate = self
        target = self
        action = #selector(commitNow)
    }

    @objc private func commitNow() { commit() }
    func controlTextDidEndEditing(_ obj: Notification) { commit() }

    private func commit() {
        let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != stringValue { stringValue = text }
        guard text != committed else { return }
        committed = text
        onCommit?(text)
    }
}

/// A whole-number field with a native stepper (and an optional unit label) that reports the
/// clamped value through a closure. The value is applied on Return, Tab and when editing ends.
final class NumberStepper: NSStackView, NSTextFieldDelegate {
    var onChange: ((Int) -> Void)?
    private(set) var value: Int
    private let range: ClosedRange<Int>
    private let field = NSTextField()
    private let stepper = NSStepper()

    init(value: Int, range: ClosedRange<Int>, unit: String) {
        self.range = range
        self.value = min(max(value, range.lowerBound), range.upperBound)
        super.init(frame: .zero)

        orientation = .horizontal
        alignment = .centerY
        spacing = 4

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        field.formatter = formatter
        field.alignment = .right
        field.integerValue = self.value
        field.delegate = self
        field.target = self
        field.action = #selector(fieldCommitted)
        field.widthAnchor.constraint(equalToConstant: 76).isActive = true

        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.integerValue = self.value
        stepper.target = self
        stepper.action = #selector(stepperMoved)

        let unitLabel = NSTextField(labelWithString: unit)
        unitLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        unitLabel.textColor = Theme.secondaryText
        unitLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true

        addArrangedSubview(field)
        addArrangedSubview(stepper)
        addArrangedSubview(unitLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func stepperMoved() { commit(stepper.integerValue) }
    @objc private func fieldCommitted() { commit(field.integerValue) }

    func controlTextDidEndEditing(_ obj: Notification) { commit(field.integerValue) }

    private func commit(_ raw: Int) {
        let clamped = min(max(raw, range.lowerBound), range.upperBound)
        field.integerValue = clamped       // also repairs an invalid or out-of-range entry
        stepper.integerValue = clamped
        guard clamped != value else { return }
        value = clamped
        onChange?(clamped)
    }
}

// MARK: - Note text

/// Small secondary text that is always shown in full: it wraps onto more lines instead of
/// ending in an ellipsis. `width` is the width it wraps at. A change of text asks the settings
/// window to fit itself to the new height.
final class NoteLabel: NSTextField {
    override var stringValue: String {
        didSet { if oldValue != stringValue { SettingsPage.contentChanged() } }
    }

    init(_ text: String = "", width: CGFloat) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        usesSingleLineMode = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        cell?.wraps = true
        cell?.isScrollable = false
        font = NSFont.systemFont(ofSize: SettingsFont.note)
        textColor = Theme.secondaryText
        preferredMaxLayoutWidth = width
        super.stringValue = text
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Row

/// One setting: the title on the left and one control on the right, both on the first line;
/// the optional description sits below and wraps over as many lines as it needs.
final class SettingRow: NSView {
    /// Padding between the edge of the section card and the row's content.
    static let inset: CGFloat = 12
    /// Where a description wraps: the page width minus the page margins and the row padding.
    static var descriptionWidth: CGFloat {
        SettingsPage.contentWidth - SettingsPage.inset * 2 - inset * 2
    }
    /// Empty space between a control (switch, button, field) and the description under it.
    static let controlGap: CGFloat = 4

    let control: NSView?
    private let titleLabel: NSTextField
    private let descLabel: NoteLabel?

    /// `controlSize`: a width and / or height > 0 is pinned; 0 leaves that side to the control.
    init(title: String, description: String? = nil, control: NSView?,
         controlSize: NSSize = .zero) {
        self.control = control

        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: SettingsFont.body)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        descLabel = description.map { NoteLabel($0, width: Self.descriptionWidth) }

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset).isActive = true

        if let desc = descLabel {
            // Title line on top, the description under it; the row is as tall as its text.
            desc.translatesAutoresizingMaskIntoConstraints = false
            addSubview(desc)
            // Tight under the title (preferred); see below for the clearance from the control.
            let tight = desc.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1)
            tight.priority = NSLayoutConstraint.Priority(750)
            tight.isActive = true
            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
                desc.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
                desc.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.inset),
                desc.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            ])
        } else {
            NSLayoutConstraint.activate([
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            ])
        }

        if let control = control {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            NSLayoutConstraint.activate([
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
                control.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            ])
            if let desc = descLabel {
                // However long the text is, its first line stays `controlGap` below the control.
                desc.topAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor,
                                          constant: Self.controlGap).isActive = true
            } else {
                // A control taller than one line (a wrapping status text) makes the row grow.
                control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6).isActive = true
                control.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6).isActive = true
            }
            if controlSize.width > 0 {
                control.widthAnchor.constraint(equalToConstant: controlSize.width).isActive = true
            }
            if controlSize.height > 0 {
                control.heightAnchor.constraint(equalToConstant: controlSize.height).isActive = true
            }
        } else {
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.inset).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setDescription(_ text: String) { descLabel?.stringValue = text }

    /// The row's title, shown for it in the settings search results.
    var titleText: String { titleLabel.stringValue }

    /// Dims the whole row and disables its control.
    func setEnabled(_ enabled: Bool) {
        titleLabel.alphaValue = enabled ? 1 : 0.4
        descLabel?.alphaValue = enabled ? 1 : 0.4
        (control as? NSControl)?.isEnabled = enabled
    }
}

// MARK: - Grouped card

/// The rounded block behind a section: rows (or blocks) stacked inside it, thin lines between
/// them. Its colours are re-resolved on every appearance change, so it follows light / dark.
final class GroupBox: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.groupFill.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The right-hand pane's background; follows light / dark.
final class ContentBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.contentFill.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The left pane's background: a solid surface of the palette, light or dark.
final class SidebarBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.sidebarFill.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A sidebar cell: gray icon and normal text, or white on the selected (accent-colored) row.
/// A search result also has a small second line (`detailField`), which follows the selection too.
/// The row view tells the cell when its selection changes (`SidebarRowView`).
final class SidebarCellView: NSTableCellView {
    var detailField: NSTextField?

    func applySelected(_ selected: Bool) {
        imageView?.contentTintColor = selected ? .white : Theme.secondaryText
        textField?.textColor = selected ? .white : Theme.text
        detailField?.textColor = selected ? NSColor.white.withAlphaComponent(0.85) : Theme.secondaryText
    }
}

/// A sidebar row: no background of its own, and a rounded accent-colored pill when selected (also
/// while the search box has the keyboard focus, as in System Settings).
final class SidebarRowView: NSTableRowView {
    override var isSelected: Bool { didSet { applySelection() } }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        applySelection()
    }

    private func applySelection() {
        for case let cell as SidebarCellView in subviews { cell.applySelected(isSelected) }
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    /// The cells set their own colors; the table's automatic light-on-dark switching stays out.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// A view whose origin is at the top-left, so a short page sits at the top of the scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - One page of the settings window

/// A vertical stack of sections, each a rounded card of rows. The right pane scrolls when a
/// page is taller than the window.
final class SettingsPage {
    /// Margin around the sections.
    static let inset: CGFloat = 20
    /// Width of the content pane: the window minus the sidebar.
    static let contentWidth: CGFloat = 700

    /// Posted when a note changes its text (and so maybe its height); the window refits.
    static let contentChangedNotification = Notification.Name("WardenHelperSettingsContentChanged")
    static func contentChanged() {
        NotificationCenter.default.post(name: contentChangedNotification, object: nil)
    }

    let view: NSView
    private let stack = NSStackView()

    init(width: CGFloat) {
        view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.inset),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.inset),
            stack.widthAnchor.constraint(equalToConstant: width - Self.inset * 2),
        ])
    }

    var contentHeight: CGFloat {
        ceil(stack.fittingSize.height) + Self.inset * 2
    }

    /// An optional header and a card of rows below it. `note` is a few lines of small text under
    /// the card, for what holds for the whole section rather than for one row.
    func addSection(_ title: String?, rows: [SettingRow], note: String? = nil) {
        addGroup(title, items: rows, note: note)
    }

    /// Like `addSection`, but the card holds any view (padded like a row).
    func addSection(_ title: String?, view content: NSView, note: String? = nil) {
        addGroup(title, items: [Self.padded(content)], note: note)
    }

    /// A card of several custom blocks, with a thin line between them.
    func addSection(_ title: String?, blocks: [NSView], note: String? = nil) {
        addGroup(title, items: blocks.map { Self.padded($0) }, note: note)
    }

    private func addGroup(_ title: String?, items: [NSView], note: String? = nil) {
        if let title = title {
            let header = Self.makeHeader(title)
            header.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(6, after: header)
        }

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 0
        inner.translatesAutoresizingMaskIntoConstraints = false

        for (index, item) in items.enumerated() {
            if index > 0 {
                let line = Self.makeSeparator()
                inner.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
            }
            item.translatesAutoresizingMaskIntoConstraints = false
            inner.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }

        let box = GroupBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])

        addFullWidth(box)
        guard let note = note else {
            stack.setCustomSpacing(20, after: box)
            return
        }

        // The note starts at the same x as the rows' text.
        let label = NoteLabel(note, width: SettingRow.descriptionWidth)
        label.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: holder.topAnchor),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: SettingRow.inset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -SettingRow.inset),
        ])
        addFullWidth(holder)
        stack.setCustomSpacing(6, after: box)
        stack.setCustomSpacing(20, after: holder)
    }

    /// Gives a custom view the same side padding as a row.
    private static func padded(_ content: NSView) -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: holder.topAnchor),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: SettingRow.inset),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -SettingRow.inset),
        ])
        return holder
    }

    /// A one-point line between two rows, starting at the row's text and running to the card edge.
    private static func makeSeparator() -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        let line = DividerView()
        line.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: SettingRow.inset),
            line.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    /// Section header: 13 pt semibold, above its card.
    static func makeHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: SettingsFont.body, weight: .semibold)
        label.textColor = Theme.text
        return label
    }

    /// Any custom view, stretched to the page width (its own content decides its height).
    func addFullWidth(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

// MARK: - Settings Window Controller
//
// Sidebar on the left, one page on the right (the macOS System Settings layout). The sidebar is
// a native source list (translucent `.sidebar` material, monochrome icons, group headers); the right
// pane shows the page title and the page, which scrolls when it is taller than the window.
// Each entry is one `SettingsPage`: a few titled sections, each a card of rows.
//
//   显示         菜单栏      what the bar shows, section by section in the order the bar reads left to right:
//                            layout, subscription, speed (with how it is measured), VPN icon, region & IP, AI icon
//                下拉菜单    which information blocks the dropdown shows
//   订阅         订阅管理    the subscription list, one subscription's settings, its usage and update, the update log
//                解析规则    the rules that read traffic and expiry from node names
//   流量         流量报表    proxied traffic per node over 15 min ... this month (TrafficReportPage)
//                统计设置    where the traffic is read from (the kernel's controller) and the traffic log
//   VPN 与网络   断开屏蔽    blocking while the VPN is down: switch, rules file, helper, block log
//                AI 出口     egress IP, region and latency of ChatGPT / Claude / Grok / Gemini, and how they are checked
//   应用         通知提醒    every notification and pop-up, with the warning thresholds
//                通用        launch, privacy, backup and reset
//
// Where a setting lives: what is shown in the bar or the dropdown is under 显示, in the order it
// appears; the data behind it is under the group of that feature (订阅, 流量, VPN 与网络), and a
// page says in its notes which other page it depends on; every notification and pop-up is under
// 通知提醒; what concerns the whole app (launch, privacy, backup, reset) is under 通用.
//
// The search box above the sidebar looks through every text the pages show (section titles, row
// titles, notes, button and pop-up labels, placeholders) and lists the matches; a click opens the
// page, scrolls to the match and flashes it. Nothing needs registering: it reads the built views.
//
// Add a setting: append a row in the matching `build…Page`. Add a page: add a `Tab` (its group
// header appears when the group changes) and a `build…Page`.

class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                NSSearchFieldDelegate {

    /// The page the dropdown's 节点流量报表… opens.
    static let trafficReportTabID = "trafficReport"

    private struct Tab {
        let id: String
        let group: String           // the sidebar header it sits under
        let title: String           // the sidebar label
        let heading: String         // the page title in the right pane
        let symbol: String          // SF Symbol shown in the sidebar (monochrome)
        let build: (SettingsPage) -> Void
    }

    /// One line of the sidebar: a group header, or a page (an index into `tabs`).
    private enum SidebarEntry {
        case group(String)
        case tab(Int)
    }

    /// Sizes of the sidebar, in one place. The rows are larger than in a stock source list on
    /// purpose (15 pt text); the left insets decide how far a page is indented under its group.
    private enum SidebarMetrics {
        static let width: CGFloat = 256
        static let fontSize: CGFloat = 15
        static let groupFontSize: CGFloat = 12
        static let searchFontSize: CGFloat = 14
        static let rowHeight: CGFloat = 34
        static let groupHeight: CGFloat = 32
        static let hitHeight: CGFloat = 48
        static let iconPoint: CGFloat = 16
        static let iconBox: CGFloat = 22
        static let iconGap: CGFloat = 8
        /// Space between the window's left edge (and the sidebar's right edge) and the list and
        /// search box. The selected pill spans the list.
        static let sideMargin: CGFloat = 18
        /// Inside a row: where its icon starts, measured from the pill's left edge. A group's title
        /// starts at the same x, so a page is not indented any further than its header.
        static let iconLeading: CGFloat = 10
        static let groupLeading: CGFloat = 10
        /// Search box: below the traffic lights.
        static let searchTop: CGFloat = 42
    }

    /// One line of the search results.
    private struct SearchHit {
        let tabID: String
        let title: String            // the row's title, or the text that matched
        let path: String             // "group › page"
        let symbol: String
        weak var target: NSView?     // what to scroll to and flash; nil = just open the page
    }

    private static let sidebarWidth: CGFloat = SidebarMetrics.width
    private static let windowWidth: CGFloat = sidebarWidth + SettingsPage.contentWidth
    private static let windowHeight: CGFloat = 760
    private static let minHeight: CGFloat = 480
    private static let maxHeight: CGFloat = 1400
    /// Height of the title area above the page: the traffic lights on the left, the title on the right.
    private static let headerHeight: CGFloat = 52

    private lazy var tabs: [Tab] = [
        Tab(id: "menubar", group: L10n.groupDisplay, title: L10n.tabMenuBar, heading: L10n.headingMenuBar,
            symbol: "menubar.rectangle",
            build: { [unowned self] page in self.buildMenuBarPage(page) }),
        Tab(id: "dropdown", group: L10n.groupDisplay, title: L10n.tabDropdown, heading: L10n.headingDropdown,
            symbol: "list.bullet.rectangle",
            build: { [unowned self] page in self.buildDropdownPage(page) }),
        Tab(id: "subscription", group: L10n.groupSubscription, title: L10n.tabSubscription, heading: L10n.headingSubscription,
            symbol: "link",
            build: { [unowned self] page in self.buildSubscriptionPage(page) }),
        Tab(id: "rules", group: L10n.groupSubscription, title: L10n.tabRules, heading: L10n.headingRules,
            symbol: "text.magnifyingglass",
            build: { [unowned self] page in self.buildRulesPage(page) }),
        Tab(id: SettingsWindowController.trafficReportTabID, group: L10n.groupTraffic, title: L10n.tabTrafficReport,
            heading: L10n.headingTrafficReport, symbol: "chart.bar.xaxis",
            build: { [unowned self] page in self.buildTrafficReportPage(page) }),
        Tab(id: "trafficSettings", group: L10n.groupTraffic, title: L10n.tabTrafficSettings,
            heading: L10n.headingTrafficSettings, symbol: "slider.horizontal.3",
            build: { [unowned self] page in self.buildVPNTrafficPage(page) }),
        Tab(id: "block", group: L10n.groupNetwork, title: L10n.tabBlock, heading: L10n.headingBlock,
            symbol: "hand.raised",
            build: { [unowned self] page in self.buildVPNBlockPage(page) }),
        Tab(id: "aiEgress", group: L10n.groupNetwork, title: L10n.tabAIEgress, heading: L10n.headingAIEgress,
            symbol: "sparkles",
            build: { page in AIServicePage.build(page) }),
        Tab(id: "alerts", group: L10n.groupApp, title: L10n.tabAlerts, heading: L10n.headingAlerts,
            symbol: "bell.badge",
            build: { [unowned self] page in self.buildAlertsPage(page) }),
        Tab(id: "general", group: L10n.groupApp, title: L10n.tabGeneral, heading: L10n.headingGeneral,
            symbol: "gearshape",
            build: { [unowned self] page in self.buildGeneralPage(page) }),
    ]

    /// The sidebar lines: each page, with a header whenever the group changes.
    private lazy var sidebarEntries: [SidebarEntry] = {
        var entries: [SidebarEntry] = []
        var lastGroup: String?
        for (index, tab) in tabs.enumerated() {
            if tab.group != lastGroup {
                entries.append(.group(tab.group))
                lastGroup = tab.group
            }
            entries.append(.tab(index))
        }
        return entries
    }()

    private var pages: [String: SettingsPage] = [:]
    private let root = NSView()
    private let sidebarTable = NSTableView()
    private let searchField = NSSearchField()
    private var sidebarDivider: NSView?
    /// The search results shown in place of the page list (nil = no search under way).
    private var searchHits: [SearchHit]?
    private var isSearching: Bool { searchHits != nil }
    private var trafficReport: TrafficReportPage?
    private let headingLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let docView = FlippedView()
    private var pageView: NSView?
    private var currentTabID = "menubar"
    private var pagesStale = false
    private var currentPage: SettingsPage?
    private var pageHeightConstraint: NSLayoutConstraint?
    private var contentObserver: NSObjectProtocol?
    private var refitPending = false

    // Rows / controls other code needs to reach after they are built.
    private var ipRow: SettingRow?
    private var resumeRow: SettingRow?
    private var loginToggle: ToggleSwitch?
    private var subscriptionPage: SubscriptionSettingsPage?
    private var rulesPage: SubscriptionRulesPage?
    private var barPicker: BarSubscriptionPicker?
    private var blockStatusRow: SettingRow?
    private var blockObserver: NSObjectProtocol?
    private var blockToggleObserver: NSObjectProtocol?
    private weak var blockToggle: ToggleSwitch?
    private var helperRow: SettingRow?
    private var helperObserver: NSObjectProtocol?
    private var helperInstallButton: ClosureButton?
    private var helperUninstallButton: ClosureButton?

    convenience init() {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? Self.windowHeight + 80
        let height = min(Self.windowHeight, max(Self.minHeight, screenHeight - 80))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.level = .floating
        // The sidebar runs up under the title bar, as in System Settings; the page title is drawn
        // in the right pane. Only the height can be changed: the pages are laid out for one width.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: Self.windowWidth, height: Self.minHeight)
        window.contentMaxSize = NSSize(width: Self.windowWidth, height: Self.maxHeight)

        self.init(window: window)
        window.delegate = self

        buildLayout(in: window)
        window.initialFirstResponder = sidebarTable     // the search box does not grab the cursor on open
        show(tab: currentTabID)
        window.center()

        contentObserver = NotificationCenter.default.addObserver(
            forName: SettingsPage.contentChangedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRefit()
        }
    }

    deinit {
        if let contentObserver = contentObserver { NotificationCenter.default.removeObserver(contentObserver) }
    }

    // MARK: - Layout

    private func buildLayout(in window: NSWindow) {
        // ── Left: a search box, then the native source list on the translucent sidebar material ──
        let sidebar = SidebarBackgroundView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = L10n.settingsSearchPlaceholder
        searchField.controlSize = .large
        searchField.font = NSFont.systemFont(ofSize: SidebarMetrics.searchFontSize)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setAccessibilityLabel(L10n.settingsSearchPlaceholder)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(searchField)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        sidebarTable.addTableColumn(column)
        sidebarTable.headerView = nil
        // Plain style: no inset of its own, so the margins below are the only ones (a source list
        // adds an extra indent for its items). The rows draw their own pill (`SidebarRowView`).
        sidebarTable.style = .plain
        sidebarTable.floatsGroupRows = false
        sidebarTable.selectionHighlightStyle = .regular
        sidebarTable.rowSizeStyle = .custom
        sidebarTable.rowHeight = SidebarMetrics.rowHeight
        sidebarTable.intercellSpacing = NSSize(width: 0, height: 2)
        sidebarTable.gridStyleMask = []
        sidebarTable.backgroundColor = .clear
        sidebarTable.allowsEmptySelection = true      // a search result list starts with nothing selected
        sidebarTable.allowsMultipleSelection = false
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        sidebarTable.target = self
        sidebarTable.action = #selector(sidebarClicked)

        let sidebarScroll = NSScrollView()
        sidebarScroll.drawsBackground = false
        sidebarScroll.borderType = .noBorder
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.documentView = sidebarTable
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarScroll)

        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(divider)
        sidebarDivider = divider
        applyDividerColor()

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: SidebarMetrics.searchTop),
            searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: SidebarMetrics.sideMargin),
            searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -SidebarMetrics.sideMargin),
            sidebarScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: SidebarMetrics.sideMargin),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -SidebarMetrics.sideMargin),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            divider.topAnchor.constraint(equalTo: sidebar.topAnchor),
            divider.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])

        // ── Right: the page title, a thin line, and the scrolling page ──
        let content = ContentBackgroundView()
        content.translatesAutoresizingMaskIntoConstraints = false

        headingLabel.font = NSFont.systemFont(ofSize: SettingsFont.title, weight: .semibold)
        headingLabel.textColor = Theme.text
        headingLabel.lineBreakMode = .byTruncatingTail
        headingLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(headingLabel)

        let headerLine = DividerView()
        headerLine.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(headerLine)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false      // pages are laid out for the pane width
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        docView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headingLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SettingsPage.inset),
            headingLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -SettingsPage.inset),
            headingLabel.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight / 2),
            headerLine.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight),
            headerLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // The page hangs from the top of the scroll view and is as wide as it.
            docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])

        root.addSubview(sidebar)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
    }

    private func applyDividerColor() {
        guard let divider = sidebarDivider else { return }
        divider.effectiveAppearance.performAsCurrentDrawingAppearance {
            divider.layer?.backgroundColor = Theme.sidebarDivider.cgColor
        }
    }

    func windowDidChangeEffectiveAppearance(_ notification: Notification) {
        applyDividerColor()
    }

    // MARK: - Pages

    private func show(tab id: String) {
        guard let window = window, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        currentTabID = id
        selectSidebarRow(forTab: index)
        window.title = tab.heading
        headingLabel.stringValue = tab.heading

        let page = self.page(for: tab)
        pageView?.removeFromSuperview()
        let v = page.view
        v.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(v)
        let height = v.heightAnchor.constraint(equalToConstant: page.contentHeight)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: docView.topAnchor),
            v.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
            height,
        ])
        pageView = v
        currentPage = page
        pageHeightConstraint = height
        docView.scroll(.zero)       // every page opens at its top
        // Background checks keep going; with them off the egress page checks only while it is on screen.
        if id == "aiEgress" { AIServiceMonitor.shared.pageShown() } else { AIServiceMonitor.shared.pageHidden() }
        trafficReport?.setActive(id == Self.trafficReportTabID)     // one-second refresh only while visible
    }

    /// Opens a page by its id (the dropdown's 节点流量报表… uses it); a running search is cleared.
    func select(tabID id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if isSearching {
            searchField.stringValue = ""
            searchChanged()
        }
        show(tab: id)
    }

    private func selectSidebarRow(forTab index: Int) {
        guard !isSearching else { return }
        let row = sidebarEntries.firstIndex { entry in
            if case .tab(let i) = entry { return i == index }
            return false
        }
        guard let row = row, sidebarTable.selectedRow != row else { return }
        sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// A note changed its text: fit the page to the new height, once per pass.
    private func scheduleRefit() {
        guard !refitPending else { return }
        refitPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.refitPending = false
            guard let page = self.currentPage, let constraint = self.pageHeightConstraint else { return }
            page.view.layoutSubtreeIfNeeded()
            let height = page.contentHeight
            guard abs(constraint.constant - height) > 0.5 else { return }
            constraint.constant = height
        }
    }

    private func page(for tab: Tab) -> SettingsPage {
        if let cached = pages[tab.id] { return cached }
        let page = SettingsPage(width: SettingsPage.contentWidth)
        tab.build(page)
        pages[tab.id] = page
        return page
    }

    /// Rebuilds every page from the stored preferences (after a reset or when reopened).
    private func rebuildPages() {
        trafficReport?.setActive(false)
        trafficReport = nil
        if isSearching {                       // the results point at views that are about to go
            searchField.stringValue = ""
            searchHits = nil
            sidebarTable.reloadData()
        }
        pages.removeAll()
        ipRow = nil
        resumeRow = nil
        loginToggle = nil
        subscriptionPage = nil
        rulesPage = nil
        barPicker = nil
        blockStatusRow = nil
        helperRow = nil
        helperInstallButton = nil
        helperUninstallButton = nil
        show(tab: currentTabID)
    }

    // MARK: - Sidebar (NSTableViewDataSource / NSTableViewDelegate)

    func numberOfRows(in tableView: NSTableView) -> Int {
        if let hits = searchHits { return max(hits.count, 1) }     // one line for "no results"
        return sidebarEntries.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if isSearching { return false }
        if case .group = sidebarEntries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if let hits = searchHits { return hits.indices.contains(row) }
        if case .tab = sidebarEntries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if isSearching { return SidebarMetrics.hitHeight }
        if case .group = sidebarEntries[row] { return SidebarMetrics.groupHeight }
        return SidebarMetrics.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let hits = searchHits {
            return hits.indices.contains(row) ? Self.makeHitCell(hits[row]) : Self.makeNoResultsCell()
        }
        switch sidebarEntries[row] {
        case .group(let title): return Self.makeGroupCell(title)
        case .tab(let index):   return Self.makeTabCell(tabs[index])
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSearching else { return }      // results open on click (`sidebarClicked`)
        let row = sidebarTable.selectedRow
        guard row >= 0, case .tab(let index) = sidebarEntries[row] else {
            if row < 0, let current = tabs.firstIndex(where: { $0.id == currentTabID }) {
                selectSidebarRow(forTab: current)       // never leave the list without a page selected
            }
            return
        }
        let id = tabs[index].id
        guard id != currentTabID else { return }
        show(tab: id)
    }

    /// A click on a search result.
    @objc private func sidebarClicked() {
        let row = sidebarTable.clickedRow
        guard let hits = searchHits, hits.indices.contains(row) else { return }
        open(hits[row])
    }

    private static func makeGroupCell(_ title: String) -> NSView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: SidebarMetrics.groupFontSize, weight: .semibold)
        label.textColor = Theme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: SidebarMetrics.groupLeading),
            label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
        ])
        return cell
    }

    private static func makeIconView(_ symbol: String) -> NSImageView {
        let icon = NSImageView()
        icon.image = Symbols.image(symbol, size: SidebarMetrics.iconPoint, weight: .regular)
        icon.contentTintColor = Theme.secondaryText
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: SidebarMetrics.iconBox).isActive = true
        icon.heightAnchor.constraint(equalToConstant: SidebarMetrics.iconBox).isActive = true
        return icon
    }

    private static func makeTabCell(_ tab: Tab) -> NSView {
        let cell = SidebarCellView()

        let icon = makeIconView(tab.symbol)
        let label = NSTextField(labelWithString: tab.title)
        label.font = NSFont.systemFont(ofSize: SidebarMetrics.fontSize)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(icon)
        cell.addSubview(label)
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: SidebarMetrics.iconLeading),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: SidebarMetrics.iconGap),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// A search result: the page's icon, the matching title, and where it lives.
    private static func makeHitCell(_ hit: SearchHit) -> NSView {
        let cell = SidebarCellView()

        let icon = makeIconView(hit.symbol)
        let title = NSTextField(labelWithString: hit.title)
        title.font = NSFont.systemFont(ofSize: SidebarMetrics.searchFontSize)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        let path = NSTextField(labelWithString: hit.path)
        path.font = NSFont.systemFont(ofSize: SettingsFont.note)
        path.textColor = Theme.secondaryText
        path.lineBreakMode = .byTruncatingTail

        let lines = NSStackView(views: [title, path])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        lines.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(icon)
        cell.addSubview(lines)
        cell.imageView = icon
        cell.textField = title
        cell.detailField = path
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: SidebarMetrics.iconLeading),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            lines.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: SidebarMetrics.iconGap),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            lines.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static func makeNoResultsCell() -> NSView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: L10n.settingsSearchNoResults)
        label.font = NSFont.systemFont(ofSize: SidebarMetrics.searchFontSize)
        label.textColor = Theme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: SidebarMetrics.iconLeading),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Search

    @objc private func searchChanged() {
        let text = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            guard searchHits != nil else { return }
            searchHits = nil
            sidebarTable.reloadData()
            if let current = tabs.firstIndex(where: { $0.id == currentTabID }) {
                selectSidebarRow(forTab: current)
            }
        } else {
            searchHits = search(for: text)
            sidebarTable.reloadData()
            sidebarTable.deselectAll(nil)
        }
    }

    /// Return in the search box opens the first result.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if let first = searchHits?.first { open(first) }
        return true
    }

    /// Every text of every page that contains all the words typed (case, accents and full / half
    /// width ignored), one result per row or control. The pages are built on the first search.
    private func search(for query: String) -> [SearchHit] {
        var hits: [SearchHit] = []
        for tab in tabs {
            let page = self.page(for: tab)
            let path = "\(tab.group) › \(tab.title)"

            // The names of the page and its group: open the page itself.
            if Self.matches(tab.title, query) || Self.matches(tab.heading, query) || Self.matches(tab.group, query) {
                hits.append(SearchHit(tabID: tab.id, title: tab.title, path: tab.group, symbol: tab.symbol, target: nil))
            }

            var seen = Set<ObjectIdentifier>()
            for (text, view) in Self.texts(in: page.view) where Self.matches(text, query) {
                let target = Self.searchTarget(of: view, within: page.view)
                guard seen.insert(ObjectIdentifier(target)).inserted else { continue }
                let title = (target as? SettingRow)?.titleText ?? text
                hits.append(SearchHit(tabID: tab.id, title: title, path: path, symbol: tab.symbol, target: target))
            }
        }
        return hits
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// True when every space-separated word of `query` appears in `text`.
    private static func matches(_ text: String, _ query: String) -> Bool {
        let haystack = fold(text)
        let words = fold(query).split(whereSeparator: { $0.isWhitespace })
        return !words.isEmpty && words.allSatisfy { haystack.contains($0) }
    }

    /// The row (or service row) a text belongs to; a text outside any row (a section title) is its own target.
    private static func searchTarget(of view: NSView, within root: NSView) -> NSView {
        var current: NSView? = view
        while let v = current, v !== root {
            if v is SettingRow || v is AIServiceCard { return v }
            current = v.superview
        }
        return view
    }

    /// All the text a page shows, each with the view it is in: labels, notes, button and
    /// segment titles, pop-up items, placeholders. Typed values (paths, addresses) and secrets are
    /// left out, and so are hidden views and the changing contents of tables and the status line.
    private static func texts(in root: NSView) -> [(String, NSView)] {
        var found: [(String, NSView)] = []
        func visit(_ view: NSView) {
            for sub in view.subviews where !sub.isHidden {
                switch sub {
                case is NSSecureTextField:
                    break
                case let list as AIServiceListView:
                    for card in list.serviceCards { found.append((card.vendorName, card)) }
                case is NSTableView:
                    break
                case let field as NSTextField:
                    if field.isEditable {
                        if let hint = field.placeholderString, !hint.isEmpty { found.append((hint, field)) }
                    } else if !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                        found.append((field.stringValue, field))
                    }
                case let popup as NSPopUpButton:
                    for title in popup.itemTitles where !title.isEmpty { found.append((title, popup)) }
                case let button as NSButton:
                    if !button.title.isEmpty { found.append((button.title, button)) }
                case let segmented as NSSegmentedControl:
                    for index in 0..<segmented.segmentCount {
                        if let label = segmented.label(forSegment: index), !label.isEmpty {
                            found.append((label, segmented))
                        }
                    }
                default:
                    visit(sub)
                }
            }
        }
        visit(root)
        return found
    }

    /// Opens a result: its page, scrolled so the match is near the top, with a short flash.
    private func open(_ hit: SearchHit) {
        if hit.tabID != currentTabID { show(tab: hit.tabID) }
        guard let target = hit.target, target.window != nil else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        let rect = target.convert(target.bounds, to: docView)
        let clip = scrollView.contentView
        let maxY = max(0, docView.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, rect.minY - 60), maxY)))
        scrollView.reflectScrolledClipView(clip)
        DispatchQueue.main.async { target.flashHighlight() }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)   // saves a text field that is still being edited
        AIServiceMonitor.shared.pageHidden()
        trafficReport?.setActive(false)
        pagesStale = true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard pagesStale else { return }
        pagesStale = false
        rebuildPages()
    }

    // MARK: - Page contents

    /// 菜单栏: what the bar shows. The sections follow the bar from left to right (subscription,
    /// speed, VPN icon, region / IP, AI icon); the dropdown has its own page.
    private func buildMenuBarPage(_ page: SettingsPage) {
        let prefs = Preferences.shared

        // One switch for the whole bar: every group is side by side or stacked.
        let layout = segmentedRow(L10n.menuBarLayout, L10n.menuBarLayoutDesc,
                                  labels: [L10n.layoutHorizontal, L10n.layoutVertical],
                                  selected: prefs.stackedLayout ? 1 : 0) { index in
            prefs.stackedLayout = (index == 1)
        }
        page.addSection(L10n.sectionLayout, rows: [layout])

        let subscriptionInfo = toggleRow(L10n.showSubscriptionInfo, L10n.showSubscriptionInfoDesc,
                                         isOn: prefs.showSubscription) {
            prefs.showSubscription = $0
        }
        let picker = BarSubscriptionPicker()
        barPicker = picker
        page.addSection(L10n.sectionSubscription, rows: [subscriptionInfo, picker.row])

        let arrows = toggleRow(L10n.showArrows, L10n.showArrowsDesc, isOn: prefs.showArrows) {
            prefs.showArrows = $0
        }
        let proxySpeed = toggleRow(L10n.speedFromProxy, L10n.speedFromProxyDesc,
                                   isOn: prefs.speedFromProxy) {
            prefs.speedFromProxy = $0
        }
        page.addSection(L10n.sectionSpeed, rows: [arrows, makeRefreshRateRow(), proxySpeed, makeInterfaceRow()])

        let shield = toggleRow(L10n.showShield, L10n.showShieldDesc,
                               isOn: prefs.showVPNShield) {
            prefs.showVPNShield = $0
        }
        let onlyIcon = toggleRow(L10n.vpnDownOnlyIcon, L10n.vpnDownOnlyIconDesc,
                                 isOn: prefs.vpnDownShowsOnlyIcon) {
            prefs.vpnDownShowsOnlyIcon = $0
        }
        page.addSection(L10n.sectionVPNState, rows: [shield, onlyIcon])

        let flag = toggleRow(L10n.showFlag, L10n.showFlagDesc, isOn: prefs.showFlag) { [weak self] on in
            prefs.showFlag = on
            self?.ipRow?.setEnabled(on)   // "IP instead of name" only makes sense while the region slot is shown
        }
        let ip = toggleRow(L10n.showIPInstead, L10n.showIPInsteadDesc, isOn: prefs.showIPInsteadOfFlag) {
            prefs.showIPInsteadOfFlag = $0
        }
        ip.setEnabled(prefs.showFlag)
        ipRow = ip
        page.addSection(L10n.sectionRegionIP, rows: [flag, ip])

        AIServicePage.addMenuBarSection(to: page)
    }

    /// 下拉菜单: one switch per information block of the dropdown (see MenuInfoBlock).
    private func buildDropdownPage(_ page: SettingsPage) {
        let prefs = Preferences.shared
        let menuBlocks = MenuInfoBlock.allCases.map { block in
            toggleRow(block.title, block.detail, isOn: prefs.showsMenuBlock(block)) {
                prefs.setShowsMenuBlock(block, $0)
            }
        }
        page.addSection(L10n.sectionMenuInfo, rows: menuBlocks, note: L10n.sectionMenuInfoNote)
    }

    /// 订阅: the list, the selected subscription's details, the update log.
    private func buildSubscriptionPage(_ page: SettingsPage) {
        subscriptionPage = SubscriptionSettingsPage(page: page)
    }

    /// 解析: the regular expressions that read traffic and expiry from node names.
    private func buildRulesPage(_ page: SettingsPage) {
        rulesPage = SubscriptionRulesPage(page: page)
    }

    /// 流量 › 统计设置: the kernel controller the traffic is read from, and the traffic log.
    private func buildVPNTrafficPage(_ page: SettingsPage) {
        let rows = makeControllerRows()
        page.addSection(L10n.sectionController, rows: rows.connection, note: L10n.sectionControllerNote)
        page.addSection(L10n.sectionTrafficLog, rows: rows.log)
        let reset = buttonRow(L10n.resetTrafficRowTitle, L10n.resetTrafficRowDesc,
                              button: L10n.resetTrafficButton) {
            (NSApp.delegate as? AppDelegate)?.resetTraffic()
        }
        page.addSection(L10n.sectionTrafficData, rows: [reset])
    }

    /// 流量报表: proxied traffic per node (see TrafficReportPage).
    private func buildTrafficReportPage(_ page: SettingsPage) {
        trafficReport = TrafficReportPage(page: page)
    }

    /// 断开屏蔽: the switch; the rules file and its status; the helper; the block log.
    private func buildVPNBlockPage(_ page: SettingsPage) {
        let rows = makeBlockRows()
        page.addSection(nil, rows: [rows.enable])
        page.addSection(L10n.sectionBlockFile, rows: rows.file, note: L10n.blockFileNote)
        page.addSection(L10n.sectionBlockHelper, rows: [rows.helper], note: L10n.blockHelperNote)
        page.addSection(L10n.sectionBlockLog, rows: [rows.log])
    }

    /// 通知提醒: every notification and pop-up, grouped by what they report. The warning
    /// thresholds sit with the quota alert they trigger (they also set the colors in the bar).
    private func buildAlertsPage(_ page: SettingsPage) {
        let prefs = Preferences.shared

        // VPN state: the notification, its wake / unlock variant (needs the first), then the pop-up.
        let notify = toggleRow(L10n.notifyOnVPNChange, L10n.notifyOnVPNChangeDesc,
                               isOn: prefs.notifyOnVPNChange) { [weak self] on in
            prefs.notifyOnVPNChange = on
            if on { ChangeNotifier.shared.prepare() }
            self?.resumeRow?.setEnabled(on)   // the resume prompt is a VPN notification too
        }
        let resume = toggleRow(L10n.notifyOnResume, L10n.notifyOnResumeDesc,
                               isOn: prefs.notifyOnResume) {
            prefs.notifyOnResume = $0
        }
        resume.setEnabled(prefs.notifyOnVPNChange)
        resumeRow = resume
        let popup = toggleRow(L10n.popupOnDisconnect, L10n.popupOnDisconnectDesc,
                              isOn: prefs.popupOnVPNDisconnect) {
            prefs.popupOnVPNDisconnect = $0
            if !$0 { VPNDisconnectPrompt.shared.dismiss() }
        }
        page.addSection(L10n.vpnAlertsSection, rows: [notify, resume, popup])

        let subscription = toggleRow(L10n.notifyOnSubscription, L10n.notifyOnSubscriptionDesc,
                                     isOn: prefs.notifySubscriptionUpdate) { on in
            prefs.notifySubscriptionUpdate = on
            if on { ChangeNotifier.shared.prepare() }
        }
        page.addSection(L10n.sectionSubUpdate, rows: [subscription])

        let lowTraffic = numberRow(L10n.lowTrafficThreshold, L10n.lowTrafficThresholdDesc,
                                   value: prefs.lowTrafficThresholdGB, range: 0...9999, unit: L10n.unitGB) {
            prefs.lowTrafficThresholdGB = $0
        }
        let expiry = numberRow(L10n.expiryThreshold, L10n.expiryThresholdDesc,
                               value: prefs.expiryThresholdDays, range: 0...365, unit: L10n.unitDays) {
            prefs.expiryThresholdDays = $0
        }
        let quota = toggleRow(L10n.notifyOnQuota, L10n.notifyOnQuotaDesc, isOn: prefs.notifyQuotaAlert) { on in
            prefs.notifyQuotaAlert = on
            if on { ChangeNotifier.shared.prepare() }
        }
        page.addSection(L10n.sectionQuotaAlert, rows: [lowTraffic, expiry, quota], note: L10n.sectionQuotaAlertNote)

        let aiRegion = toggleRow(L10n.notifyOnAIRegion, L10n.notifyOnAIRegionDesc,
                                 isOn: prefs.notifyAIRegionChange) { on in
            prefs.notifyAIRegionChange = on
            if on { ChangeNotifier.shared.prepare() }
        }
        page.addSection(L10n.sectionAIAlerts, rows: [aiRegion])
    }

    /// 通用: the app's identity, then what concerns the whole app: launch, privacy, data management.
    private func buildGeneralPage(_ page: SettingsPage) {
        let prefs = Preferences.shared

        let login = toggleRow(L10n.launchAtLogin,
                              isOn: SMAppService.mainApp.status == .enabled) { [weak self] on in
            self?.handleLoginToggle(on)
        }
        loginToggle = login.control as? ToggleSwitch

        let crashRestart = toggleRow(L10n.restartOnCrash, L10n.restartOnCrashDesc,
                                     isOn: prefs.restartOnCrash) { on in
            prefs.restartOnCrash = on   // AppDelegate starts / stops the watcher
        }

        let hideIP = toggleRow(L10n.hideIP, L10n.hideIPDesc, isOn: prefs.hideIP) {
            prefs.hideIP = $0
        }

        let reset = buttonRow(L10n.resetRowTitle, L10n.resetRowDesc,
                              button: L10n.resetButton) { [weak self] in
            self?.resetDefaults()
        }

        page.addFullWidth(makeIdentityHeader())
        page.addSection(L10n.sectionLaunch, rows: [login, crashRestart])
        page.addSection(L10n.sectionPrivacy, rows: [hideIP])
        page.addSection(L10n.sectionData, rows: [makeBackupRow(), reset])
    }

    /// 菜单栏 › 网速 › 刷新频率: how often the speed is read.
    private func makeRefreshRateRow() -> SettingRow {
        let prefs = Preferences.shared
        let selected = prefs.refreshInterval == 2.0 ? 1 : prefs.refreshInterval == 5.0 ? 2 : 0
        return popupRow(L10n.refreshRate,
                        items: [L10n.seconds1, L10n.seconds2, L10n.seconds5],
                        selected: selected, width: 150) { index in
            prefs.refreshInterval = index == 1 ? 2.0 : index == 2 ? 5.0 : 1.0
        }
    }

    /// 菜单栏 › 网速 › 监测网卡 (the list is read fresh every time the window is opened).
    private func makeInterfaceRow() -> SettingRow {
        let prefs = Preferences.shared
        let popup = ClosurePopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .regular
        popup.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        for (displayName, rawName) in getMonitoredInterfaces() {
            let item = NSMenuItem(title: displayName, action: nil, keyEquivalent: "")
            item.representedObject = rawName
            popup.menu?.addItem(item)
        }
        if let locked = prefs.lockedInterface {
            for (i, item) in (popup.menu?.items ?? []).enumerated() where item.representedObject as? String == locked {
                popup.selectItem(at: i)
                break
            }
        } else {
            popup.selectItem(at: 0)
        }
        popup.target = popup
        popup.action = #selector(ClosurePopUpButton.fire)
        popup.onChange = { [weak popup] _ in
            Preferences.shared.lockedInterface = popup?.selectedItem?.representedObject as? String
        }
        return SettingRow(title: L10n.lockInterface, description: L10n.lockInterfaceDesc,
                          control: popup, controlSize: NSSize(width: 210, height: 0))
    }

    /// App icon and name, at the top of 通用.
    private func makeIdentityHeader() -> NSView {
        let icon = AppIconImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageFrameStyle = .none
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let name = NSTextField(labelWithString: "WardenHelper")
        name.font = NSFont.systemFont(ofSize: SettingsFont.title, weight: .semibold)
        name.textColor = Theme.text

        var texts: [NSView] = [name]
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            let versionLabel = NSTextField(labelWithString: L10n.aboutVersion(version))
            versionLabel.font = NSFont.systemFont(ofSize: SettingsFont.note)
            versionLabel.textColor = Theme.secondaryText
            texts.append(versionLabel)
        }
        let textStack = NSStackView(views: texts)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(row)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 60),   // 40 + 20 below
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        return container
    }

    /// 断开屏蔽: `enable` = the master switch; `file` = rules file and its load status;
    /// `helper` = the root helper; `log` = the block log.
    private func makeBlockRows() -> (enable: SettingRow, file: [SettingRow], helper: SettingRow, log: SettingRow) {
        let prefs = Preferences.shared
        let store = BlockRulesStore.shared

        let enabledRow = toggleRow(L10n.blockEnabled, L10n.blockEnabledDesc, isOn: prefs.blockEnabled) { on in
            Preferences.shared.blockEnabled = on
        }
        if let toggle = enabledRow.control as? ToggleSwitch {
            blockToggle = toggle
            if blockToggleObserver == nil {
                blockToggleObserver = NotificationCenter.default.addObserver(
                    forName: Preferences.changedNotification, object: nil, queue: .main) { [weak self] _ in
                    guard let toggle = self?.blockToggle else { return }
                    let on = Preferences.shared.blockEnabled
                    if toggle.isOn != on { toggle.isOn = on }     // the VPN dropped and forced it on
                }
            }
        }

        let field = ClosureTextField()
        field.configure(text: prefs.blockRulesPath, placeholder: Preferences.defaultBlockRulesPath)
        field.setAccessibilityLabel(L10n.blockPath)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        field.onCommit = { text in
            Preferences.shared.blockRulesPath = text        // the store notices the change by itself
        }

        let choose = ClosureButton(title: L10n.blockChoose, target: nil, action: nil)
        choose.bezelStyle = .rounded
        choose.controlSize = .regular
        choose.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        choose.target = choose
        choose.action = #selector(ClosureButton.fire)
        choose.onPress = { [weak self, weak field] in
            guard let self = self, let field = field else { return }
            self.window?.makeFirstResponder(nil)
            let panel = NSOpenPanel()
            panel.title = L10n.blockChooseTitle
            panel.prompt = L10n.blockChoosePrompt
            panel.allowedContentTypes = [.json]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if let current = BlockRulesStore.shared.currentFileURL {
                panel.directoryURL = current.deletingLastPathComponent()
            }
            let apply: (NSApplication.ModalResponse) -> Void = { [weak field] response in
                guard response == .OK, let url = panel.url else { return }
                let typed = (url.path as NSString).abbreviatingWithTildeInPath
                field?.stringValue = typed
                Preferences.shared.blockRulesPath = typed
            }
            if let window = self.window {
                panel.beginSheetModal(for: window, completionHandler: apply)
            } else {
                apply(panel.runModal())
            }
        }

        let pathControls = NSStackView(views: [field, choose])
        pathControls.orientation = .horizontal
        pathControls.alignment = .centerY
        pathControls.spacing = 6
        let pathRow = SettingRow(title: L10n.blockPath, control: pathControls)

        let edit = ClosureButton(title: L10n.blockEdit, target: nil, action: nil)
        edit.bezelStyle = .rounded
        edit.controlSize = .regular
        edit.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        edit.target = edit
        edit.action = #selector(ClosureButton.fire)
        edit.onPress = { [weak self] in
            self?.window?.makeFirstResponder(nil)
            Self.openRulesFileInEditor()
        }

        let reveal = ClosureButton(title: L10n.blockShowFile, target: nil, action: nil)
        reveal.bezelStyle = .rounded
        reveal.controlSize = .regular
        reveal.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        reveal.target = reveal
        reveal.action = #selector(ClosureButton.fire)
        reveal.onPress = {
            guard let url = BlockRulesStore.shared.currentFileURL else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                let folder = url.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            }
        }
        let statusControls = NSStackView(views: [edit, reveal])
        statusControls.orientation = .horizontal
        statusControls.alignment = .centerY
        statusControls.spacing = 6
        let statusRow = SettingRow(title: L10n.blockStatus, description: store.statusText, control: statusControls)
        statusRow.setDescription(store.statusText)
        blockStatusRow = statusRow

        if blockObserver == nil {
            blockObserver = NotificationCenter.default.addObserver(
                forName: BlockRulesStore.changedNotification, object: nil, queue: .main) { [weak self] _ in
                guard let row = self?.blockStatusRow else { return }
                let text = BlockRulesStore.shared.statusText
                row.setDescription(text)
            }
        }
        let showBlockLog = buttonRow(L10n.blockLogRow, button: L10n.logShowButton) {
            BlockLog.shared.reveal()
        }
        return (enable: enabledRow, file: [pathRow, statusRow], helper: makeHelperRow(), log: showBlockLog)
    }

    /// The rules file in the system's default editor (created empty when it does not exist yet).
    /// The rules store watches the file, so a saved edit is loaded and checked at once.
    private static func openRulesFileInEditor() {
        guard let url = BlockRulesStore.shared.currentFileURL else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "[]\n".write(to: url, atomically: true, encoding: .utf8)   // an empty list blocks nothing
        }
        let workspace = NSWorkspace.shared
        // A browser may be the default for .json; an editor is what is wanted here.
        let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
                                     "com.microsoft.edgemac", "company.thebrowser.Browser"]
        var app = workspace.urlForApplication(toOpen: url)
        if let found = app, let id = Bundle(url: found)?.bundleIdentifier, browsers.contains(id) { app = nil }
        if app == nil { app = workspace.urlForApplication(toOpen: .plainText) }
        if let app = app {
            workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.activateFileViewerSelecting([url])
        }
    }

    /// 断开屏蔽 > 特权助手: 未安装 / 已安装 / 需要更新, with the matching buttons.
    private func makeHelperRow() -> SettingRow {
        func button(_ title: String, _ onPress: @escaping () -> Void) -> ClosureButton {
            let b = ClosureButton(title: title, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
            b.target = b
            b.action = #selector(ClosureButton.fire)
            b.onPress = onPress
            return b
        }
        let install = button(L10n.helperInstall) {
            HelperInstaller.shared.install()
        }
        let uninstall = button(L10n.helperUninstall) {
            HelperInstaller.shared.uninstall()
        }
        helperInstallButton = install
        helperUninstallButton = uninstall

        let controls = NSStackView(views: [install, uninstall])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 6

        let row = SettingRow(title: L10n.helperTitle, description: L10n.helperChecking, control: controls)
        helperRow = row

        if helperObserver == nil {
            helperObserver = NotificationCenter.default.addObserver(
                forName: HelperInstaller.changedNotification, object: nil, queue: .main) { [weak self] _ in
                self?.updateHelperRow()
            }
        }
        updateHelperRow()
        HelperInstaller.shared.refresh()
        return row
    }

    private func updateHelperRow() {
        guard let row = helperRow, let install = helperInstallButton, let uninstall = helperUninstallButton else { return }
        let installer = HelperInstaller.shared

        var text: String
        switch installer.state {
        case .unknown:       text = L10n.helperChecking
        case .notInstalled:  text = L10n.helperNotInstalled
        case .installed:     text = L10n.helperInstalled
        case .needsUpdate:   text = L10n.helperNeedsUpdate
        }
        if installer.isBusy {
            text = installer.state == .notInstalled ? L10n.helperInstalling : L10n.helperUninstalling
        } else if let error = installer.lastError {
            text = error
        }
        row.setDescription(text)

        // 未安装: install. 已安装: uninstall. 需要更新: update and uninstall.
        install.title = installer.state == .needsUpdate ? L10n.helperUpdate : L10n.helperInstall
        install.isHidden = installer.state == .installed || installer.state == .unknown
        uninstall.isHidden = installer.state == .notInstalled || installer.state == .unknown
        install.isEnabled = !installer.isBusy && installer.bundledHelperURL != nil
        uninstall.isEnabled = !installer.isBusy
    }

    /// 流量: `connection` = where the kernel's controller is, its secret and a status
    /// line; `log` = the traffic log switch and its file.
    private func makeControllerRows() -> (connection: [SettingRow], log: [SettingRow]) {
        let address = ClosureTextField()
        address.configure(text: Preferences.shared.controllerAddress, placeholder: L10n.controllerAddressAuto)
        address.setAccessibilityLabel(L10n.controllerAddress)

        let secret = ClosureSecureField()
        secret.configure(text: ControllerSecretStore.load() ?? "", placeholder: L10n.controllerSecretPlaceholder)
        secret.setAccessibilityLabel(L10n.controllerSecret)

        let test = ClosureButton(title: L10n.controllerTest, target: nil, action: nil)
        test.bezelStyle = .rounded
        test.controlSize = .regular
        test.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        test.target = test
        test.action = #selector(ClosureButton.fire)

        let addressRow = SettingRow(title: L10n.controllerAddress, description: L10n.controllerAddressDesc,
                                    control: address, controlSize: NSSize(width: 260, height: 0))
        let secretRow = SettingRow(title: L10n.controllerSecret, description: L10n.controllerSecretDesc,
                                   control: secret, controlSize: NSSize(width: 260, height: 0))
        let statusRow = SettingRow(title: L10n.controllerStatus,
                                   description: Self.statusText(VPNTrafficTracker.shared.snapshot()),
                                   control: test)

        address.onCommit = { text in
            Preferences.shared.controllerAddress = text     // the client notices the change by itself
        }
        secret.onCommit = { text in
            ControllerSecretStore.save(text)
            ControllerClient.shared.secretChanged()
        }
        test.onPress = { [weak self, weak statusRow, weak test] in
            self?.window?.makeFirstResponder(nil)           // commits a field that is still being edited
            statusRow?.setDescription(L10n.controllerTesting)
            test?.isEnabled = false
            ControllerClient.shared.test { result in
                test?.isEnabled = true
                switch result {
                case .success(let d):
                    statusRow?.setDescription(d.parsed < d.total
                        ? L10n.controllerTestPartial(version: d.version, parsed: d.parsed, total: d.total)
                        : L10n.controllerTestOK(version: d.version, parsed: d.parsed, total: d.total,
                                                outbounds: d.outbounds))
                case .failure(let failure):
                    statusRow?.setDescription(L10n.controllerFailure(failure))
                }
            }
        }
        let logRow = toggleRow(L10n.logTraffic, L10n.logTrafficDesc, isOn: Preferences.shared.logTraffic) { on in
            Preferences.shared.logTraffic = on
        }
        let showRow = buttonRow(L10n.logShowRow, button: L10n.logShowButton) {
            TrafficLog.shared.reveal()
        }
        return (connection: [addressRow, secretRow, statusRow], log: [logRow, showRow])
    }

    private static func statusText(_ s: VPNTrafficTracker.Snapshot) -> String {
        switch s.controller {
        case .connected(let version): return L10n.controllerConnected(version)
        case .unavailable(let failure): return L10n.controllerFailure(failure)
        case .idle: return L10n.controllerWaitingVPN
        }
    }

    /// 导出 / 导入: settings and the subscription list, as one JSON file (see SettingsBackup).
    private func makeBackupRow() -> SettingRow {
        func button(_ title: String, _ onPress: @escaping () -> Void) -> ClosureButton {
            let b = ClosureButton(title: title, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
            b.target = b
            b.action = #selector(ClosureButton.fire)
            b.onPress = onPress
            return b
        }
        let exportButton = button(L10n.backupExportButton) { SettingsBackupUI.exportBackup() }
        let importButton = button(L10n.backupImportButton) { [weak self] in
            guard SettingsBackupUI.importBackup() else { return }
            // Redraw every page from what was imported, once this button's action has returned.
            DispatchQueue.main.async { self?.rebuildPages() }
        }
        let stack = NSStackView(views: [exportButton, importButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return SettingRow(title: L10n.backupRowTitle, description: L10n.backupRowDesc, control: stack)
    }

    // MARK: - Row helpers

    private func toggleRow(_ title: String, _ description: String? = nil, isOn: Bool,
                           onChange: @escaping (Bool) -> Void) -> SettingRow {
        let toggle = ToggleSwitch(frame: .zero)
        toggle.controlSize = .regular
        toggle.isOn = isOn
        toggle.onToggle = onChange
        toggle.setAccessibilityLabel(title)
        toggle.setAccessibilityRole(.checkBox)
        return SettingRow(title: title, description: description, control: toggle)
    }

    private func numberRow(_ title: String, _ description: String? = nil, value: Int, range: ClosedRange<Int>,
                           unit: String, onChange: @escaping (Int) -> Void) -> SettingRow {
        let control = NumberStepper(value: value, range: range, unit: unit)
        control.onChange = onChange
        control.setAccessibilityLabel(title)
        return SettingRow(title: title, description: description, control: control)
    }

    /// A two-way choice shown as a native segmented control with text labels.
    private func segmentedRow(_ title: String, _ description: String? = nil, labels: [String], selected: Int,
                              onChange: @escaping (Int) -> Void) -> SettingRow {
        let seg = ClosureSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        seg.target = seg
        seg.action = #selector(ClosureSegmentedControl.fire)
        seg.controlSize = .regular
        seg.selectedSegment = selected
        seg.onChange = onChange
        return SettingRow(title: title, description: description, control: seg)
    }

    private func popupRow(_ title: String, _ description: String? = nil, items: [String],
                          selected: Int, width: CGFloat, onChange: @escaping (Int) -> Void) -> SettingRow {
        let popup = ClosurePopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .regular
        popup.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        popup.addItems(withTitles: items)
        popup.selectItem(at: selected)
        popup.target = popup
        popup.action = #selector(ClosurePopUpButton.fire)
        popup.onChange = onChange
        return SettingRow(title: title, description: description, control: popup,
                          controlSize: NSSize(width: width, height: 0))
    }

    private func buttonRow(_ title: String, _ description: String? = nil, button label: String,
                           onPress: @escaping () -> Void) -> SettingRow {
        let button = ClosureButton(title: label, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        button.target = button
        button.action = #selector(ClosureButton.fire)
        button.onPress = onPress
        return SettingRow(title: title, description: description, control: button)
    }

    // MARK: - Actions

    // Interface list (delegates to NetworkInterfaceReader)
    private func getMonitoredInterfaces() -> [(String, String?)] {
        NetworkInterfaceReader.activeInterfaces(locked: Preferences.shared.lockedInterface)
    }

    private func handleLoginToggle(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginToggle?.isOn = SMAppService.mainApp.status == .enabled
        }
    }

    @objc func resetDefaults() {
        let alert = NSAlert()
        alert.messageText = L10n.resetTitle
        alert.informativeText = L10n.resetMessage
        alert.addButton(withTitle: L10n.resetConfirm)
        alert.addButton(withTitle: L10n.cancel)
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            Preferences.shared.resetToDefaults()
            SubscriptionManager.shared.reapplyRules()   // the extraction rules are back to their defaults
            self.window?.close()   // pages are rebuilt from the defaults when it is reopened
        }
    }
}
