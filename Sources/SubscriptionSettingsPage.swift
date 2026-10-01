import Cocoa
import UniformTypeIdentifiers

/// The 订阅 tab: a pop-up picks the subscription (添加 / 删除 manage the list); the rows below edit
/// and show the selected one. Text fields save when editing ends; values follow
/// `SubscriptionManager` live.
final class SubscriptionSettingsPage: NSObject, NSTextFieldDelegate {

    private static let units: [SubscriptionIntervalUnit] = [.minutes, .hours, .days]
    private static let fieldWidth: CGFloat = 330
    private static let wideFieldWidth: CGFloat = 420   // fits the snapshot label and time
    private static let empty = "—"

    private let manager = SubscriptionManager.shared
    private var selectedID: String?
    private var observer: NSObjectProtocol?

    // Subscription list
    private let picker = ClosurePopUpButton(frame: .zero, pullsDown: false)
    private let removeButton = ClosureButton(title: L10n.subRemove, target: nil, action: nil)
    private let addButton = ClosureButton(title: L10n.subAdd, target: nil, action: nil)

    // Selected subscription
    private let enabledToggle = ToggleSwitch(frame: .zero)
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let intervalField = NSTextField()
    private let unitPopup = ClosurePopUpButton(frame: .zero, pullsDown: false)
    private let lastUpdatedLabel = SubscriptionSettingsPage.valueLabel()
    private let trafficLabel = SubscriptionSettingsPage.valueLabel()
    private let expiryLabel = SubscriptionSettingsPage.valueLabel()
    private let resetLabel = SubscriptionSettingsPage.valueLabel()
    private let statusLabel = NoteLabel("", width: 230)
    private let updateButton = ClosureButton(title: L10n.subUpdateNow, target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    // Update log (the latest refresh of the selected subscription, live)
    private let logScroll = NSTextView.scrollableTextView()
    private var logView: NSTextView? { logScroll.documentView as? NSTextView }
    private var renderedLogSignature = ""
    private let copyLogButton = ClosureButton(title: L10n.subLogCopy, target: nil, action: nil)
    private let exportLogButton = ClosureButton(title: L10n.subLogExport, target: nil, action: nil)
    private static let logHeight: CGFloat = 150
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    /// Full date for copied / exported text, where a log may be read days later.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Rows that only make sense while a subscription exists.
    private var detailRows: [SettingRow] = []

    init(page: SettingsPage) {
        super.init()

        // ── list controls ──
        picker.controlSize = .regular
        picker.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        picker.target = picker
        picker.action = #selector(ClosurePopUpButton.fire)
        picker.onChange = { [weak self] index in self?.pickerChanged(index) }

        style(removeButton) { [weak self] in self?.removeSelected() }
        style(addButton) { [weak self] in self?.addNew() }

        let pickerStack = NSStackView(views: [picker, removeButton, addButton])
        pickerStack.orientation = .horizontal
        pickerStack.alignment = .centerY
        pickerStack.spacing = 6
        picker.widthAnchor.constraint(equalToConstant: 210).isActive = true
        let pickerRow = SettingRow(title: L10n.subPickerTitle, control: pickerStack)

        // ── detail controls ──
        enabledToggle.controlSize = .regular
        enabledToggle.setAccessibilityLabel(L10n.subEnabled)
        enabledToggle.setAccessibilityRole(.checkBox)
        enabledToggle.onToggle = { [weak self] on in
            guard let self = self, let id = self.selectedID else { return }
            self.manager.setEnabled(id: id, on)
        }

        configure(nameField, placeholder: nil)
        configure(urlField, placeholder: L10n.subLinkPlaceholder)

        configure(intervalField, placeholder: nil)
        intervalField.alignment = .center

        unitPopup.controlSize = .regular
        unitPopup.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        unitPopup.addItems(withTitles: [L10n.subUnitMinutes, L10n.subUnitHours, L10n.subUnitDays])
        unitPopup.target = unitPopup
        unitPopup.action = #selector(ClosurePopUpButton.fire)
        unitPopup.onChange = { [weak self] index in self?.unitChanged(index) }

        let intervalStack = NSStackView(views: [intervalField, unitPopup])
        intervalStack.orientation = .horizontal
        intervalStack.alignment = .centerY
        intervalStack.spacing = 6
        intervalField.widthAnchor.constraint(equalToConstant: 84).isActive = true
        unitPopup.widthAnchor.constraint(equalToConstant: 112).isActive = true

        statusLabel.alignment = .right      // wraps over several lines rather than being cut
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        style(updateButton) { [weak self] in self?.updateNow() }

        // A small spinner beside the status while an update runs.
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let updateStack = NSStackView(views: [spinner, statusLabel, updateButton])
        updateStack.orientation = .horizontal
        updateStack.alignment = .centerY
        updateStack.spacing = 8
        statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true

        let size = NSSize(width: Self.fieldWidth, height: 0)
        detailRows = [
            SettingRow(title: L10n.subEnabled, description: L10n.subEnabledDesc, control: enabledToggle),
            SettingRow(title: L10n.subName, control: nameField, controlSize: size),
            SettingRow(title: L10n.subLink, control: urlField, controlSize: size),
            SettingRow(title: L10n.subInterval, control: intervalStack),
            SettingRow(title: L10n.subLastUpdated, control: lastUpdatedLabel, controlSize: size),
            SettingRow(title: L10n.subRemaining, control: trafficLabel,
                       controlSize: NSSize(width: Self.wideFieldWidth, height: 0)),
            SettingRow(title: L10n.subExpiry, control: expiryLabel, controlSize: size),
            SettingRow(title: L10n.subNextReset, control: resetLabel, controlSize: size),
            SettingRow(title: L10n.subUpdateRow, control: updateStack),
        ]

        // The first four rows are what the user edits; the rest is what WardenHelper read from the link.
        page.addSection(nil, rows: [pickerRow])
        page.addSection(L10n.subSectionConfig, rows: Array(detailRows.prefix(4)))
        page.addSection(L10n.subSectionStatus, rows: Array(detailRows.dropFirst(4)))
        page.addFullWidth(makeLogSection())

        observer = NotificationCenter.default.addObserver(
            forName: SubscriptionManager.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshUI()
        }
        refreshUI()
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Update log

    private func makeLogSection() -> NSView {
        let header = SettingsPage.makeHeader(L10n.subLogSection)

        if let tv = logView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 4, height: 6)
        }
        logScroll.borderType = .bezelBorder
        logScroll.hasVerticalScroller = true
        logScroll.autohidesScrollers = true

        style(copyLogButton) { [weak self] in self?.copyLog() }
        style(exportLogButton) { [weak self] in self?.exportLog() }
        copyLogButton.toolTip = L10n.subLogButtonTip
        exportLogButton.toolTip = L10n.subLogButtonTip

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let headerRow = NSStackView(views: [header, spacer, copyLogButton, exportLogButton])
        headerRow.orientation = .horizontal
        headerRow.distribution = .fill
        headerRow.alignment = .centerY
        headerRow.spacing = 6

        let box = NSStackView(views: [headerRow, logScroll])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerRow.widthAnchor.constraint(equalTo: box.widthAnchor),
            logScroll.widthAnchor.constraint(equalTo: box.widthAnchor),
            logScroll.heightAnchor.constraint(equalToConstant: Self.logHeight),
        ])
        return box
    }

    // MARK: - Copy / export the log

    /// Links keep only their host (the rest carries the access token); the home folder in cache
    /// paths becomes "~". Both make the text safe to paste into a bug report.
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"(https?://[^\s/?#<>\x22\x27]+)[^\s<>\x22\x27]*"#, options: [.caseInsensitive])

    static func sanitizedForSharing(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let noLinks = linkPattern.stringByReplacingMatches(in: text, options: [], range: range,
                                                           withTemplate: "$1/…")
        return noLinks.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// The whole log of the selected subscription as plain text; nil while it is empty.
    private func logText() -> String? {
        let lines = manager.log(for: selectedID)
        guard !lines.isEmpty, let item = manager.item(selectedID) else { return nil }
        let name = item.name.isEmpty ? L10n.subUnnamed : item.name
        var out = [L10n.subLogFileHeader(name),
                   L10n.subLogFileExported(Self.stampFormatter.string(from: Date())), ""]
        for line in lines {
            let level = line.level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
            out.append("\(Self.stampFormatter.string(from: line.date))  \(level)  \(Self.sanitizedForSharing(line.text))")
        }
        return out.joined(separator: "\n") + "\n"
    }

    private func copyLog() {
        guard let text = logText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyLogButton.title = L10n.subLogCopied
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyLogButton.title = L10n.subLogCopy
        }
    }

    private func exportLog() {
        guard let text = logText(), let item = manager.item(selectedID) else { return }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"

        let panel = NSSavePanel()
        panel.title = L10n.subLogExportTitle
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "WardenHelper-\(SubscriptionFetcher.cacheFilenameStem(item.name))-\(stamp.string(from: Date())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func color(for level: SubLogLevel) -> NSColor {
        switch level {
        case .debug, .note: return Theme.secondaryText
        case .success:      return NSColor.systemGreen
        case .warning:      return NSColor.systemOrange
        case .error:        return NSColor.systemRed
        }
    }

    /// Redraws only when the log changed; keeps the view scrolled to the newest line.
    private func renderLog(_ lines: [SubscriptionLogLine]) {
        let last = lines.last
        let signature = "\(selectedID ?? "")|\(lines.count)|\(last?.date.timeIntervalSince1970 ?? 0)|\(last?.text.count ?? 0)"
        guard signature != renderedLogSignature, let tv = logView else { return }
        renderedLogSignature = signature

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString()
        for (n, line) in lines.enumerated() {
            let text = "\(Self.timeFormatter.string(from: line.date))  \(line.text)" + (n == lines.count - 1 ? "" : "\n")
            out.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color(for: line.level),
            ]))
        }
        tv.textStorage?.setAttributedString(out)
        tv.scrollToEndOfDocument(nil)
    }

    // MARK: - Control setup

    private static func valueLabel() -> NSTextField {
        let l = NSTextField(labelWithString: empty)
        l.font = NSFont.monospacedDigitSystemFont(ofSize: SettingsFont.body, weight: .regular)
        l.textColor = Theme.text
        l.alignment = .right
        l.lineBreakMode = .byTruncatingTail
        l.isSelectable = true
        return l
    }

    private func configure(_ field: NSTextField, placeholder: String?) {
        field.placeholderString = placeholder
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true   // a long link scrolls instead of wrapping
        field.delegate = self
    }

    private func style(_ button: ClosureButton, onPress: @escaping () -> Void) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        button.target = button
        button.action = #selector(ClosureButton.fire)
        button.onPress = onPress
    }

    // MARK: - Showing the selected subscription

    private func refreshUI() {
        let items = manager.items
        if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
            selectedID = items.first?.id
        }
        let item = manager.item(selectedID)

        // Picker
        picker.menu?.removeAllItems()
        if items.isEmpty {
            picker.menu?.addItem(NSMenuItem(title: L10n.subNone, action: nil, keyEquivalent: ""))
        } else {
            for it in items {
                let title = (it.name.isEmpty ? L10n.subUnnamed : it.name)
                    + (it.enabled ? "" : L10n.subDisabledSuffix)
                let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                entry.representedObject = it.id
                picker.menu?.addItem(entry)
            }
            if let index = items.firstIndex(where: { $0.id == selectedID }) { picker.selectItem(at: index) }
        }
        picker.isEnabled = !items.isEmpty
        removeButton.isEnabled = item != nil

        // Rows
        let hasItem = item != nil
        detailRows.forEach { $0.setEnabled(hasItem) }
        let inner: [NSControl] = [intervalField, unitPopup]
        inner.forEach { $0.isEnabled = hasItem }

        enabledToggle.isOn = item?.enabled ?? false
        setText(nameField, item?.name ?? "")
        setText(urlField, item?.url ?? "")
        setText(intervalField, item.map { String($0.intervalValue) } ?? "")
        if let item = item, let index = Self.units.firstIndex(of: item.intervalUnit) {
            unitPopup.selectItem(at: index)
        }

        lastUpdatedLabel.stringValue = item?.lastUpdated.map(SubscriptionFormat.date) ?? Self.empty
        trafficLabel.stringValue = item.flatMap { SubscriptionFormat.trafficLine($0) } ?? Self.empty
        let isSnapshot = item.map { $0.realtimeRemainingGB == nil && $0.snapshotTrafficGB != nil } ?? false
        trafficLabel.textColor = isSnapshot ? NSColor.systemOrange : Theme.text
        trafficLabel.toolTip = item.flatMap { it -> String? in
            if it.realtimeRemainingGB != nil { return L10n.subTrafficTipRealtime }
            return it.snapshotTrafficGB != nil ? L10n.subTrafficTipSnapshot : nil
        }
        expiryLabel.stringValue = item?.expireDate.map { SubscriptionFormat.expiry($0) } ?? Self.empty
        resetLabel.stringValue = item.flatMap { SubscriptionFormat.reset($0) } ?? Self.empty
        resetLabel.toolTip = item?.nextResetDate == nil ? nil : L10n.subResetTip

        // Update button + status text
        let busy = item.map { manager.isRefreshing($0.id) } ?? false
        updateButton.title = busy ? L10n.subUpdating : L10n.subUpdateNow
        updateButton.isEnabled = hasItem && !busy && !(item?.trimmedURL.isEmpty ?? true)
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        if let item = item, let message = item.message, !busy {
            statusLabel.stringValue = message
            statusLabel.textColor = item.failed ? NSColor.systemRed : Theme.secondaryText
        } else {
            statusLabel.stringValue = ""
        }

        let logLines = manager.log(for: selectedID)
        copyLogButton.isEnabled = !logLines.isEmpty
        exportLogButton.isEnabled = !logLines.isEmpty
        renderLog(logLines)
    }

    /// Never overwrite a field the user is typing in.
    private func setText(_ field: NSTextField, _ value: String) {
        guard field.currentEditor() == nil, field.stringValue != value else { return }
        field.stringValue = value
    }

    /// Ends any edit in progress, which saves it through `controlTextDidEndEditing`.
    private func commitEditing() {
        picker.window?.makeFirstResponder(nil)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let id = selectedID else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if field === nameField {
            manager.update(id: id) { $0.name = text }
        } else if field === urlField {
            manager.setURL(id: id, text)
        } else if field === intervalField {
            if let value = Int(text), (1...9999).contains(value) {
                manager.update(id: id) { $0.intervalValue = value }
            }
        }
        // Show the saved (trimmed / reverted) text once the field editor has closed.
        DispatchQueue.main.async { [weak self] in self?.refreshUI() }
    }

    // MARK: - Actions

    private func pickerChanged(_ index: Int) {
        commitEditing()
        let items = manager.items
        guard index >= 0, index < items.count else { return }
        selectedID = items[index].id
        refreshUI()
    }

    private func unitChanged(_ index: Int) {
        guard let id = selectedID, index >= 0, index < Self.units.count else { return }
        let unit = Self.units[index]
        manager.update(id: id) { $0.intervalUnit = unit }
    }

    private func addNew() {
        commitEditing()
        let item = manager.add()
        selectedID = item.id
        refreshUI()
        urlField.window?.makeFirstResponder(urlField)   // the next thing to do is paste the link
    }

    private func removeSelected() {
        commitEditing()
        guard let item = manager.item(selectedID) else { return }

        let alert = NSAlert()
        alert.messageText = L10n.subRemoveTitle(item.name.isEmpty ? L10n.subUnnamed : item.name)
        alert.informativeText = L10n.subRemoveMessage
        alert.addButton(withTitle: L10n.subRemove)
        alert.addButton(withTitle: L10n.cancel)
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            manager.remove(id: item.id)   // the notification re-selects and redraws
        }
    }

    private func updateNow() {
        commitEditing()   // a link typed but not yet confirmed is saved (and refreshed) first
        if let id = selectedID { manager.refresh(id: id, manual: true) }
    }
}
