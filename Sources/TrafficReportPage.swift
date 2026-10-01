import Cocoa

/// 流量 › 流量报表: proxied traffic per node over 15 min / 30 min / 1 h / 6 h / 12 h (sliding) and
/// 1 day / this week / this month (calendar). One period at a time; every period remembers its own
/// sort (click a column header: ascending, click again: descending). The numbers come from
/// `NodeTrafficStore` and are refreshed once a second while the page is on screen
/// (`setActive`). This used to be a window of its own (`NodeStatsWindowController`); the dropdown
/// menu's 节点流量报表… now opens the settings window on this page.
final class TrafficReportPage: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private enum Key {
        static let name = "name"
        static let up = "up"
        static let down = "down"
        static let total = "total"
    }
    private static let defaultSort = NSSortDescriptor(key: Key.total, ascending: false)

    /// Height of the node table inside its card (about eleven rows); the table scrolls beyond it.
    private static let tableHeight: CGFloat = 310
    private static let rowHeight: CGFloat = 26
    private static let fontSize: CGFloat = SettingsFont.body

    private let rangeLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: L10n.nodeStatsEmpty)
    private let scrollView = NSScrollView()
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private var periodControl: ClosureSegmentedControl?

    /// What is typed in the search box, trimmed; empty = show every node.
    private var query: String { searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var period: StatsPeriod = .min15
    private var rows: [NodeTrafficRow] = []
    private var sortByPeriod: [StatsPeriod: NSSortDescriptor] = [:]
    private var applyingSort = false
    private var timer: Timer?

    private lazy var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    init(page: SettingsPage) {
        super.init()
        build(in: page)
        select(.min15)
    }

    deinit { timer?.invalidate() }

    // MARK: - Showing

    /// Called by the settings window: refresh once a second while this page is visible.
    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        reload(force: true)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Layout

    private func build(in page: SettingsPage) {
        // ── 统计概览 (top): the totals, the period they cover, and what is counted ──
        footerLabel.font = .monospacedDigitSystemFont(ofSize: SettingsFont.body, weight: .semibold)
        footerLabel.textColor = Theme.text
        footerLabel.lineBreakMode = .byTruncatingTail

        rangeLabel.font = .systemFont(ofSize: SettingsFont.note)
        rangeLabel.textColor = Theme.secondaryText
        rangeLabel.lineBreakMode = .byTruncatingTail

        let note = NoteLabel(L10n.nodeStatsNote, width: SettingRow.descriptionWidth)
        let summary = NSStackView(views: [footerLabel, rangeLabel, note])
        summary.orientation = .vertical
        summary.alignment = .leading
        summary.spacing = 4
        page.addSection(L10n.sectionReportSummary, view: Self.wrap(summary, vertical: 12))

        // ── 统计周期: one segment per period ──
        let control = ClosureSegmentedControl(labels: StatsPeriod.allCases.map { $0.title },
                                              trackingMode: .selectOne, target: nil, action: nil)
        control.target = control
        control.action = #selector(ClosureSegmentedControl.fire)
        control.controlSize = .regular
        control.segmentDistribution = .fillEqually
        control.onChange = { [weak self] index in
            guard let p = StatsPeriod(rawValue: index) else { return }
            self?.select(p)
        }
        periodControl = control
        page.addSection(L10n.sectionReportPeriod, view: Self.wrap(control, vertical: 10))

        // ── 节点明细: the search box and the table ──
        searchField.placeholderString = L10n.nodeStatsSearchPlaceholder
        searchField.sendsSearchStringImmediately = true
        searchField.toolTip = L10n.nodeStatsSearchTip
        searchField.setAccessibilityLabel(L10n.nodeStatsSearchPlaceholder)
        searchField.target = self
        searchField.action = #selector(searchChanged)

        addColumn(Key.name, L10n.nodeColumnName, width: 336, minWidth: 140, ascending: true, numeric: false)
        addColumn(Key.up, L10n.nodeColumnUp, width: 100, minWidth: 80, ascending: false, numeric: true)
        addColumn(Key.down, L10n.nodeColumnDown, width: 100, minWidth: 80, ascending: false, numeric: true)
        addColumn(Key.total, L10n.nodeColumnTotal, width: 100, minWidth: 80, ascending: false, numeric: true)
        table.style = .plain
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = false
        table.selectionHighlightStyle = .none
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = Theme.rowDivider
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.dataSource = self
        table.delegate = self

        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: SettingsFont.body)
        emptyLabel.textColor = Theme.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let tableHolder = NSView()
        tableHolder.addSubview(scrollView)
        tableHolder.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: tableHolder.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tableHolder.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: tableHolder.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: tableHolder.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Self.tableHeight),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: 12),
        ])

        page.addSection(L10n.sectionReportNodes, blocks: [
            Self.wrap(searchField, vertical: 10),
            Self.wrap(tableHolder, vertical: 0),
        ])
    }

    /// `content` pinned inside an otherwise empty view with `vertical` points above and below.
    private static func wrap(_ content: NSView, vertical: CGFloat) -> NSView {
        let holder = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: holder.topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -vertical),
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
        ])
        return holder
    }

    private func addColumn(_ key: String, _ title: String, width: CGFloat, minWidth: CGFloat,
                           ascending: Bool, numeric: Bool) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: ascending)
        column.headerCell.alignment = numeric ? .right : .left
        table.addTableColumn(column)
    }

    // MARK: - Periods, sorting, data

    @objc private func searchChanged() { reload(force: true) }

    /// Fuzzy match of a node name against what was typed. Case, accents and full / half width are
    /// ignored. The text is split at spaces; every part must appear in the name, its characters in
    /// order but not necessarily next to each other ("hk01" finds "HK-香港 01 IPLC", "日本东京" finds
    /// "日本 东京 02").
    static func fuzzyMatch(_ name: String, _ query: String) -> Bool {
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        let haystack = Array(fold(name))
        let parts = fold(query).split(whereSeparator: { $0.isWhitespace })
        guard !parts.isEmpty else { return true }
        for part in parts {
            var index = haystack.startIndex
            for ch in part {
                guard let found = haystack[index...].firstIndex(of: ch) else { return false }
                index = haystack.index(after: found)
            }
        }
        return true
    }

    private func select(_ p: StatsPeriod) {
        period = p
        periodControl?.selectedSegment = p.rawValue
        // Every period keeps its own sort: put this one's back on the header.
        applyingSort = true
        table.sortDescriptors = [sortByPeriod[p] ?? Self.defaultSort]
        applyingSort = false
        reload(force: true)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applyingSort, let sort = tableView.sortDescriptors.first else { return }
        sortByPeriod[period] = sort
        reload(force: true)
    }

    private func reload(force: Bool = false) {
        let now = Date()
        let result = NodeTrafficStore.shared.rows(for: period, now: now)
        let sort = table.sortDescriptors.first ?? Self.defaultSort
        let text = query
        let filtered = text.isEmpty ? result.rows : result.rows.filter { Self.fuzzyMatch($0.node, text) }
        let sorted = Self.sorted(filtered, by: sort)

        if force || sorted != rows {
            rows = sorted
            table.reloadData()
        }
        emptyLabel.stringValue = (!text.isEmpty && !result.rows.isEmpty) ? L10n.nodeStatsNoMatch : L10n.nodeStatsEmpty
        emptyLabel.isHidden = !rows.isEmpty
        rangeLabel.stringValue = L10n.nodeStatsRange(period, since: timeFormatter.string(from: result.since))

        var up: UInt64 = 0, down: UInt64 = 0
        for r in rows { up &+= r.up; down &+= r.down }
        footerLabel.stringValue = text.isEmpty
            ? L10n.nodeStatsFooter(count: rows.count, up: VPNInfoFormat.bytes(up), down: VPNInfoFormat.bytes(down))
            : L10n.nodeStatsFooterFiltered(count: rows.count, total: result.rows.count,
                                           up: VPNInfoFormat.bytes(up), down: VPNInfoFormat.bytes(down))
    }

    /// Ascending or descending by the header's column; equal values fall back to the node name so
    /// the order never flickers between refreshes.
    private static func sorted(_ list: [NodeTrafficRow], by sort: NSSortDescriptor) -> [NodeTrafficRow] {
        func byName(_ a: NodeTrafficRow, _ b: NodeTrafficRow) -> Bool {
            a.node.localizedStandardCompare(b.node) == .orderedAscending
        }
        let column = sort.key ?? Key.total
        func value(_ r: NodeTrafficRow) -> UInt64 {
            switch column {
            case Key.up: return r.up
            case Key.down: return r.down
            default: return r.total
            }
        }
        let ascending = sort.ascending
        return list.sorted { a, b in
            if column == Key.name {
                return ascending ? byName(a, b) : byName(b, a)
            }
            let x = value(a), y = value(b)
            if x != y { return ascending ? x < y : x > y }
            return byName(a, b)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, rows.indices.contains(row) else { return nil }
        let key = column.identifier.rawValue
        let id = NSUserInterfaceItemIdentifier("cell.\(key)")

        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            // The label sits in a cell view and is centred on the row, so text and row line up
            // whatever the row height.
            cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            label.lineBreakMode = .byTruncatingTail
            label.font = key == Key.name ? .systemFont(ofSize: Self.fontSize)
                                         : .monospacedDigitSystemFont(ofSize: Self.fontSize, weight: .regular)
            label.alignment = key == Key.name ? .left : .right
        }

        guard let field = cell.textField else { return nil }
        let r = rows[row]
        switch key {
        case Key.name:
            field.stringValue = r.node
            field.toolTip = r.node
        case Key.up: field.stringValue = VPNInfoFormat.bytes(r.up)
        case Key.down: field.stringValue = VPNInfoFormat.bytes(r.down)
        default: field.stringValue = VPNInfoFormat.bytes(r.total)
        }
        return cell
    }
}
