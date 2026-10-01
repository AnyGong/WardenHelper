import Cocoa

/// The 规则 tab: the regular expressions that read remaining traffic, reset days and expiry
/// date from a subscription's info nodes. A pop-up at the top picks the scope: the global
/// rules, or one subscription's own rules (an empty box there follows the global rule).
///
/// Edits stay in the text boxes until 验证并保存 is pressed. Each pattern is tested against the
/// cached content of the subscriptions in scope (no download): one that is invalid, or extracts
/// nothing usable, is marked unavailable and its box goes back to the last usable pattern; the
/// ones that pass are saved and applied at once.
///
/// Below, 粘贴测试 runs the patterns in the boxes over pasted node names as you type. It needs
/// no subscription data, so a rule can be tried before anything has been downloaded.
final class SubscriptionRulesPage: NSObject, NSTextFieldDelegate, NSTextViewDelegate {

    private let manager = SubscriptionManager.shared

    /// nil = the global rules; otherwise the id of the subscription being edited.
    private var scopeID: String?
    private let scopePopup = ClosurePopUpButton(frame: .zero, pullsDown: false)
    private var scopeSignature = ""
    private var observer: NSObjectProtocol?

    private var fields: [SubscriptionRuleField: NSTextField] = [:]
    private var statusIcons: [SubscriptionRuleField: NSImageView] = [:]
    private var statusLabels: [SubscriptionRuleField: NSTextField] = [:]
    private var resultRows: [SubscriptionRuleField: NSStackView] = [:]

    private let summaryLabel = NoteLabel("", width: 440)
    private let verifyButton = ClosureButton(title: L10n.ruleVerify, target: nil, action: nil)
    private var testing = false

    // Paste test
    private let sampleInput = NSTextView.scrollableTextView()
    private let sampleOutput = NSTextView.scrollableTextView()
    private var inputView: NSTextView? { sampleInput.documentView as? NSTextView }
    private var outputView: NSTextView? { sampleOutput.documentView as? NSTextView }
    private static let sampleInputHeight: CGFloat = 68
    private static let sampleOutputHeight: CGFloat = 112

    private static let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private static let sampleFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    init(page: SettingsPage) {
        super.init()

        scopePopup.controlSize = .regular
        scopePopup.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        scopePopup.target = scopePopup
        scopePopup.action = #selector(ClosurePopUpButton.fire)
        scopePopup.onChange = { [weak self] _ in self?.scopeChanged() }
        page.addSection(nil, rows: [
            SettingRow(title: L10n.ruleScope, description: L10n.ruleScopeDesc, control: scopePopup,
                       controlSize: NSSize(width: 220, height: 0)),
        ])

        page.addSection(L10n.ruleSectionPatterns, blocks: SubscriptionRuleField.allCases.map { makeBlock(for: $0) })
        page.addFullWidth(makeFooter())
        page.addFullWidth(makeSampleSection())

        rebuildScopeMenu()
        loadFields()

        observer = NotificationCenter.default.addObserver(
            forName: SubscriptionManager.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.subscriptionsChanged()
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Layout

    private static func title(_ field: SubscriptionRuleField) -> (String, String) {
        switch field {
        case .infoNode: return (L10n.ruleInfoNode, L10n.ruleInfoNodeHint)
        case .traffic:  return (L10n.ruleTraffic, L10n.ruleTrafficHint)
        case .reset:    return (L10n.ruleReset, L10n.ruleResetHint)
        case .expire:   return (L10n.ruleExpire, L10n.ruleExpireHint)
        }
    }

    /// Title + hint on the left, the test result on the right, the pattern box below.
    private func makeBlock(for field: SubscriptionRuleField) -> NSView {
        let (titleText, hintText) = Self.title(field)

        let title = NSTextField(labelWithString: titleText)
        title.font = NSFont.systemFont(ofSize: SettingsFont.body)
        title.textColor = Theme.text
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let hint = NSTextField(labelWithString: hintText)
        hint.font = NSFont.systemFont(ofSize: SettingsFont.note)
        hint.textColor = Theme.secondaryText
        hint.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let icon = NSImageView()
        icon.isHidden = true
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true

        // The test result gets its own line under the title, wrapped in full.
        let status = NoteLabel("", width: SettingRow.descriptionWidth - 20)
        status.alignment = .left

        let header = NSStackView(views: [title, hint, spacer])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 6

        let result = NSStackView(views: [icon, status])
        result.orientation = .horizontal
        result.alignment = .top
        result.spacing = 6
        result.isHidden = true

        let box = NSTextField()
        box.font = Self.mono
        box.isBezeled = true
        box.bezelStyle = .roundedBezel
        box.usesSingleLineMode = true
        box.lineBreakMode = .byTruncatingTail
        box.cell?.isScrollable = true   // a long pattern scrolls instead of wrapping
        box.delegate = self

        let block = NSStackView(views: [header, result, box])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 6
        block.edgeInsets = NSEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
        header.translatesAutoresizingMaskIntoConstraints = false
        box.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        box.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true

        fields[field] = box
        statusIcons[field] = icon
        statusLabels[field] = status
        resultRows[field] = result
        return block
    }

    private func makeFooter() -> NSView {
        summaryLabel.font = NSFont.systemFont(ofSize: SettingsFont.note)
        summaryLabel.textColor = Theme.secondaryText
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        verifyButton.bezelStyle = .rounded
        verifyButton.controlSize = .regular
        verifyButton.font = NSFont.systemFont(ofSize: ControlMetrics.fontSize)
        verifyButton.target = verifyButton
        verifyButton.action = #selector(ClosureButton.fire)
        verifyButton.onPress = { [weak self] in self?.verify() }

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let footer = NSStackView(views: [summaryLabel, spacer, verifyButton])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.alignment = .centerY
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        return footer
    }

    /// 粘贴测试: an input box for node names and a read-only box with what each rule captured.
    private func makeSampleSection() -> NSView {
        let title = SettingsPage.makeHeader(L10n.ruleSampleTitle)

        let hint = NSTextField(labelWithString: L10n.ruleSampleHint)
        hint.font = NSFont.systemFont(ofSize: SettingsFont.note)
        hint.textColor = Theme.secondaryText

        let head = NSStackView(views: [title, hint])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = 8

        if let tv = inputView {
            tv.isEditable = true
            tv.isSelectable = true
            tv.isRichText = false
            tv.allowsUndo = true
            tv.font = Self.sampleFont
            tv.textColor = Theme.text
            tv.drawsBackground = true
            tv.backgroundColor = NSColor.textBackgroundColor
            tv.textContainerInset = NSSize(width: 4, height: 6)
            // Pasted names must reach the patterns exactly as they are.
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.isAutomaticSpellingCorrectionEnabled = false
            tv.isContinuousSpellCheckingEnabled = false
            tv.delegate = self
        }
        if let tv = outputView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 4, height: 6)
        }
        for scroll in [sampleInput, sampleOutput] {
            scroll.borderType = .bezelBorder
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
        }

        let box = NSStackView(views: [head, sampleInput, sampleOutput])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        head.translatesAutoresizingMaskIntoConstraints = false
        sampleInput.translatesAutoresizingMaskIntoConstraints = false
        sampleOutput.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            head.widthAnchor.constraint(equalTo: box.widthAnchor),
            sampleInput.widthAnchor.constraint(equalTo: box.widthAnchor),
            sampleInput.heightAnchor.constraint(equalToConstant: Self.sampleInputHeight),
            sampleOutput.widthAnchor.constraint(equalTo: box.widthAnchor),
            sampleOutput.heightAnchor.constraint(equalToConstant: Self.sampleOutputHeight),
        ])
        return box
    }

    // MARK: - Scope

    private func rebuildScopeMenu() {
        let items = manager.items
        let signature = items.map { "\($0.id)|\($0.name)|\($0.enabled)" }.joined(separator: "\n")
        guard signature != scopeSignature else { return }
        scopeSignature = signature

        scopePopup.menu?.removeAllItems()
        scopePopup.menu?.addItem(NSMenuItem(title: L10n.ruleScopeGlobal, action: nil, keyEquivalent: ""))
        if !items.isEmpty { scopePopup.menu?.addItem(.separator()) }
        for it in items {
            let title = (it.name.isEmpty ? L10n.subUnnamed : it.name) + (it.enabled ? "" : L10n.subDisabledSuffix)
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.representedObject = it.id
            scopePopup.menu?.addItem(entry)
        }
        if let id = scopeID,
           let entry = scopePopup.menu?.items.first(where: { $0.representedObject as? String == id }) {
            scopePopup.select(entry)
        } else {
            scopePopup.selectItem(at: 0)
        }
    }

    private func scopeChanged() {
        guard !testing else { return }
        scopePopup.window?.makeFirstResponder(nil)
        scopeID = scopePopup.selectedItem?.representedObject as? String
        loadFields()
    }

    /// The subscription list changed (also fires for every update-log line, hence the signature).
    private func subscriptionsChanged() {
        if scopeID != nil, manager.item(scopeID) == nil {   // the subscription being edited was deleted
            scopeID = nil
            loadFields()
        }
        rebuildScopeMenu()
    }

    /// Fills the boxes for the current scope. Global: the saved rules. A subscription: its own
    /// patterns, and the global pattern as placeholder in the boxes that follow it.
    private func loadFields() {
        let global = Preferences.shared.subscriptionRules
        let overrides = manager.item(scopeID)?.ruleOverrides ?? [:]
        for field in SubscriptionRuleField.allCases {
            guard let box = fields[field] else { continue }
            if scopeID == nil {
                box.stringValue = global[field]
                box.placeholderString = nil
            } else {
                box.stringValue = overrides[field.rawValue] ?? ""
                box.placeholderString = global[field]
            }
            clearStatus(field)
        }
        renderSample()
    }

    private func typed(_ field: SubscriptionRuleField) -> String {
        (fields[field]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Verify and test

    private func verify() {
        guard !testing else { return }
        verifyButton.window?.makeFirstResponder(nil)   // ends any edit in progress

        var candidate = Preferences.shared.subscriptionRules
        for field in SubscriptionRuleField.allCases {
            let text = typed(field)
            // A subscription's empty box follows the global rule, which then gets tested too.
            if scopeID == nil || !text.isEmpty { candidate[field] = text }
        }

        let scope = scopeID
        testing = true
        scopePopup.isEnabled = false
        verifyButton.isEnabled = false
        verifyButton.title = L10n.ruleTesting
        manager.testRules(candidate, subscriptionID: scope) { [weak self] report in
            self?.finish(report, scope: scope)
        }
    }

    private func finish(_ report: SubscriptionRuleReport, scope: String?) {
        testing = false
        scopePopup.isEnabled = true
        verifyButton.isEnabled = true
        verifyButton.title = L10n.ruleVerify
        guard scope == scopeID else { return }   // the subscription was deleted meanwhile

        if let id = scope {
            finishScoped(report, id: id)
        } else {
            finishGlobal(report)
        }
        renderSample()
    }

    private func finishGlobal(_ report: SubscriptionRuleReport) {
        var failed = 0
        for field in SubscriptionRuleField.allCases {
            switch report.outcomes[field] {
            case .success(let found)?:
                show(field, ok: true, text: Self.describe(found))
            case .failure(let issue)?:
                failed += 1
                show(field, ok: false, text: Self.describe(issue))
            case nil:
                break
            }
            // A pattern that failed goes back to the last usable one.
            fields[field]?.stringValue = report.accepted[field]
        }

        if report.accepted != Preferences.shared.subscriptionRules {
            Preferences.shared.subscriptionRules = report.accepted
            manager.reapplyRules()   // what the subscriptions show follows the new rules now
        }
        summarize(failed: failed, message: L10n.ruleSomeFailed(failed))
    }

    /// One subscription's rules. A filled box that passed becomes an override (unless it equals
    /// the global rule); one that failed goes back to its previous override, or to empty. An
    /// empty box stays empty: its global rule is tested and shown, but never copied into the
    /// subscription.
    private func finishScoped(_ report: SubscriptionRuleReport, id: String) {
        guard let item = manager.item(id) else { return }
        let global = Preferences.shared.subscriptionRules
        var overrides: [String: String] = [:]
        var reverted = 0
        var inheritedFailed = 0

        for field in SubscriptionRuleField.allCases {
            let text = typed(field)
            let outcome = report.outcomes[field]
            switch outcome {
            case .success(let found)?: show(field, ok: true, text: Self.describe(found))
            case .failure(let issue)?: show(field, ok: false, text: Self.describe(issue))
            case nil: break
            }
            let passed = Self.passed(outcome)

            if text.isEmpty {
                fields[field]?.stringValue = ""
                if !passed { inheritedFailed += 1 }
            } else if passed {
                if text == global[field] {
                    fields[field]?.stringValue = ""   // same as the global rule: nothing to override
                } else {
                    overrides[field.rawValue] = text
                    fields[field]?.stringValue = text
                }
            } else {
                reverted += 1
                let old = item.ruleOverrides[field.rawValue] ?? ""
                fields[field]?.stringValue = old
                if !old.isEmpty { overrides[field.rawValue] = old }
            }
        }

        if overrides != item.ruleOverrides {
            manager.update(id: id) { $0.ruleOverrides = overrides }
            manager.reapplyRules()
        }

        if reverted > 0 {
            summarize(failed: reverted, message: L10n.ruleSomeFailed(reverted))
        } else {
            summarize(failed: inheritedFailed, message: L10n.ruleInheritFailed(inheritedFailed))
        }
    }

    private func summarize(failed: Int, message: String) {
        if failed == 0 {
            summaryLabel.stringValue = L10n.ruleAllOK
            summaryLabel.textColor = NSColor.systemGreen
        } else {
            summaryLabel.stringValue = message
            summaryLabel.textColor = NSColor.systemOrange
        }
    }

    private static func passed(_ outcome: Result<SubscriptionRuleFound, SubscriptionRuleIssue>?) -> Bool {
        if case .success? = outcome { return true }
        return false
    }

    private func show(_ field: SubscriptionRuleField, ok: Bool, text: String) {
        guard let icon = statusIcons[field], let label = statusLabels[field] else { return }
        let color = ok ? NSColor.systemGreen : NSColor.systemRed
        icon.isHidden = true            // plain text marker instead of a symbol
        label.stringValue = (ok ? "✓ " : "✗ ") + text
        label.textColor = color
        resultRows[field]?.isHidden = false
        SettingsPage.contentChanged()
    }

    private func clearStatus(_ field: SubscriptionRuleField) {
        statusIcons[field]?.isHidden = true
        statusLabels[field]?.stringValue = ""
        resultRows[field]?.isHidden = true
        SettingsPage.contentChanged()
        summaryLabel.stringValue = ""
    }

    // MARK: - Paste test

    /// The patterns as they stand in the boxes. Global scope: a box is used as typed (an empty
    /// one is reported). A subscription: an empty box uses the saved global pattern.
    private func candidateRules() -> SubscriptionRuleSet {
        var rules = scopeID == nil
            ? SubscriptionRuleSet(infoNode: "", traffic: "", reset: "", expire: "")
            : Preferences.shared.subscriptionRules
        for field in SubscriptionRuleField.allCases {
            let text = typed(field)
            if !text.isEmpty { rules[field] = text }
        }
        return rules
    }

    private func renderSample() {
        guard let input = inputView, let out = outputView else { return }
        let result = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor) {
            result.append(NSAttributedString(string: text, attributes: [
                .font: Self.sampleFont,
                .foregroundColor: color,
            ]))
        }

        if input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(L10n.ruleSampleEmpty, Theme.secondaryText)
            out.textStorage?.setAttributedString(result)
            return
        }

        let report = SubscriptionRuleSampleTester.evaluate(text: input.string, rules: candidateRules())

        for field in SubscriptionRuleField.allCases {
            if let issue = report.issues[field] {
                add("✗ \(Self.title(field).0)：\(Self.describe(issue))\n", NSColor.systemRed)
            }
        }
        add(L10n.ruleSampleSummary(lines: report.lines.count, info: report.infoNodeCount) + "\n",
            Theme.secondaryText)

        for line in report.lines {
            if line.isInfoNode == false {
                add("○ \(line.text) · \(L10n.ruleSampleNotInfo)\n", Theme.secondaryText)
                continue
            }
            add("● \(line.text)\n", Theme.text)
            var found = false
            for field in [SubscriptionRuleField.traffic, .reset, .expire] {
                switch line.results[field] {
                case .success(let value)?:
                    found = true
                    add("    \(Self.title(field).0) → \(Self.describe(value))\n", NSColor.systemGreen)
                case .failure(let issue)?:
                    found = true
                    add("    \(Self.title(field).0) → \(Self.describe(issue))\n", NSColor.systemOrange)
                case nil:
                    break
                }
            }
            if !found { add("    \(L10n.ruleSampleNothing)\n", Theme.secondaryText) }
        }
        out.textStorage?.setAttributedString(result)
        out.scrollToBeginningOfDocument(nil)
    }

    // MARK: - Wording

    private static func describe(_ found: SubscriptionRuleFound) -> String {
        switch found {
        case .nodes(let n):
            return L10n.ruleFoundNodes(n)
        case .trafficGB(let gb):
            return SubscriptionFormat.traffic(gb)
        case .resetDays(let days):
            return L10n.ruleFoundDays(days)
        case .expire(let date, _):
            return SubscriptionFormat.expiry(date)
        }
    }

    private static func describe(_ issue: SubscriptionRuleIssue) -> String {
        switch issue {
        case .empty:                      return L10n.ruleEmpty
        case .syntax:                     return L10n.ruleSyntax
        case .groups(let need, let have): return L10n.ruleGroups(need: need, have: have)
        case .noSample:                   return L10n.ruleNoSample
        case .noMatch:                    return L10n.ruleNoMatch
        case .badCapture:                 return L10n.ruleBadCapture
        }
    }

    // MARK: - NSTextFieldDelegate / NSTextViewDelegate

    /// Editing a box drops its old result: it no longer describes what is typed.
    func controlTextDidChange(_ obj: Notification) {
        guard let box = obj.object as? NSTextField,
              let field = fields.first(where: { $0.value === box })?.key else { return }
        clearStatus(field)
        renderSample()
    }

    /// The pasted text changed.
    func textDidChange(_ notification: Notification) {
        renderSample()
    }
}
