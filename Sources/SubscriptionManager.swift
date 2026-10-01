import Cocoa

// MARK: - Model

enum SubscriptionIntervalUnit: String, Codable, CaseIterable {
    case minutes, hours, days

    var seconds: TimeInterval {
        switch self {
        case .minutes: return 60
        case .hours:   return 3600
        case .days:    return 86400
        }
    }
}

/// One subscription link and what was last read from it.
struct SubscriptionItem: Codable, Equatable {
    /// UUID; also SubscriptionKit's cache key (names may repeat or change).
    let id: String
    var name: String
    var url: String
    var intervalValue: Int
    var intervalUnit: SubscriptionIntervalUnit

    /// Last time the link was downloaded live and parsed successfully.
    var lastUpdated: Date?
    /// Last time a refresh was tried (successful or not). Drives the schedule.
    var lastAttempt: Date?
    /// "剩余流量" from the node name: a snapshot, not live. Persisted under its old JSON key.
    var snapshotTrafficGB: Double?
    /// "距离下次重置剩余" (days) from the node name, counted from `snapshotAt`.
    var resetDaysSnapshot: Int?
    /// When the node-name snapshot was taken: the download time, or the cache file's time
    /// when the result came from the stale-cache fallback.
    var snapshotAt: Date?
    /// Remaining traffic from the provider's API (`subscription-userinfo`) and when it was read.
    var realtimeRemainingGB: Double?
    var realtimeAt: Date?
    /// "yyyy-MM-dd" as found in the provider's info node.
    var expireDate: String?
    /// Failure reason, or a soft notice (e.g. "no traffic / expiry info found").
    var message: String?
    /// True when the last refresh did not fully succeed.
    var failed: Bool
    /// Off: never refreshed on the schedule and not shown in the menu bar ("Update now" still works).
    var enabled: Bool
    /// This subscription's own extraction patterns, keyed by `SubscriptionRuleField.rawValue`.
    /// A field that is absent follows the global rules (设置 > 规则).
    var ruleOverrides: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case id, name, url, intervalValue, intervalUnit, lastUpdated, lastAttempt
        case snapshotTrafficGB = "remainingTrafficGB"
        case resetDaysSnapshot, snapshotAt, realtimeRemainingGB, realtimeAt
        case expireDate, message, failed, enabled, ruleOverrides
    }

    /// Files saved by older versions have no `enabled` key: those subscriptions stay enabled.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        intervalValue = try c.decode(Int.self, forKey: .intervalValue)
        intervalUnit = try c.decode(SubscriptionIntervalUnit.self, forKey: .intervalUnit)
        lastUpdated = try c.decodeIfPresent(Date.self, forKey: .lastUpdated)
        lastAttempt = try c.decodeIfPresent(Date.self, forKey: .lastAttempt)
        snapshotTrafficGB = try c.decodeIfPresent(Double.self, forKey: .snapshotTrafficGB)
        resetDaysSnapshot = try c.decodeIfPresent(Int.self, forKey: .resetDaysSnapshot)
        snapshotAt = try c.decodeIfPresent(Date.self, forKey: .snapshotAt)
        realtimeRemainingGB = try c.decodeIfPresent(Double.self, forKey: .realtimeRemainingGB)
        realtimeAt = try c.decodeIfPresent(Date.self, forKey: .realtimeAt)
        expireDate = try c.decodeIfPresent(String.self, forKey: .expireDate)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        ruleOverrides = try c.decodeIfPresent([String: String].self, forKey: .ruleOverrides) ?? [:]
    }

    init(id: String = UUID().uuidString, name: String, url: String = "") {
        self.id = id
        self.name = name
        self.url = url
        self.intervalValue = 12
        self.intervalUnit = .hours
        self.failed = false
        self.enabled = true
    }

    var interval: TimeInterval { Double(max(1, intervalValue)) * intervalUnit.seconds }

    /// The rules this subscription is read with: `global`, with every usable override on top.
    /// An override that no longer compiles is ignored, so a damaged file cannot break a refresh.
    func effectiveRules(global: SubscriptionRuleSet) -> SubscriptionRuleSet {
        var rules = global
        for field in SubscriptionRuleField.allCases {
            if let pattern = ruleOverrides[field.rawValue], case .success = field.compile(pattern) {
                rules[field] = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return rules
    }

    /// Remaining traffic in GB: the provider's live value when there is one, else the node-name snapshot.
    var remainingGB: Double? { realtimeRemainingGB ?? snapshotTrafficGB }

    /// Calendar days until the plan expires (negative = expired), nil without an expiry date.
    func expiryDays(now: Date = Date()) -> Int? {
        expireDate.flatMap { SubscriptionPlanExtractor.daysUntil($0, from: now) }
    }
    var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Snapshot date + snapshot reset days ("yyyy-MM-dd"); never today + days.
    var nextResetDate: String? {
        guard let days = resetDaysSnapshot, let at = snapshotAt ?? lastUpdated else { return nil }
        return SubscriptionPlanExtractor.resetDateString(snapshot: at, afterDays: days)
    }
}

/// One line of a subscription's update log (kept in memory only).
struct SubscriptionLogLine {
    let date: Date
    let level: SubLogLevel
    let text: String
}

// MARK: - Display formatting

enum SubscriptionFormat {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func date(_ d: Date) -> String { dateFormatter.string(from: d) }

    /// GB (as SubscriptionKit reports it, 1 GB = 1024 MB) -> "43.29 GB" / "1.20 TB" / "512 MB".
    static func traffic(_ gb: Double) -> String {
        if gb >= 1024 { return String(format: "%.2f TB", gb / 1024) }
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.0f MB", gb * 1024)
    }

    /// Live traffic when the API gave it; otherwise the node-name value, marked as a snapshot
    /// with its time. nil when neither exists.
    static func trafficLine(_ item: SubscriptionItem) -> String? {
        if let gb = item.realtimeRemainingGB {
            var line = "\(traffic(gb)) · \(L10n.subRealtime)"
            if let at = item.realtimeAt { line += " · \(date(at))" }
            return line
        }
        guard let gb = item.snapshotTrafficGB else { return nil }
        let time = (item.snapshotAt ?? item.lastUpdated).map(date) ?? L10n.subSnapshotTimeUnknown
        return "\(traffic(gb)) · \(L10n.subSnapshotStale) · \(time)"
    }

    /// The subscription's traffic / reset / expiry as separate lines, the same wording as the
    /// dropdown rows; used for notifications. Empty when the subscription has no values.
    static func infoLines(_ item: SubscriptionItem, now: Date = Date()) -> [String] {
        var lines: [String] = []
        if let gb = item.remainingGB {
            lines.append(L10n.subMenuTraffic(traffic(gb), snapshot: item.realtimeRemainingGB == nil))
        }
        if let r = reset(item, now: now) { lines.append(L10n.subMenuReset(r)) }
        if let date = item.expireDate { lines.append(L10n.subMenuExpiry(expiry(date, now: now))) }
        return lines
    }

    /// "2026-10-01 · 剩余 2 天", counted from today.
    static func reset(_ item: SubscriptionItem, now: Date = Date()) -> String? {
        guard let dateString = item.nextResetDate else { return nil }
        guard let days = SubscriptionPlanExtractor.daysUntil(dateString, from: now) else { return dateString }
        if days < 0 { return "\(dateString) · \(L10n.subResetPassed)" }
        if days == 0 { return "\(dateString) · \(L10n.subResetsToday)" }
        return "\(dateString) · \(L10n.subDaysLeft(days))"
    }

    /// "2026-12-31 · 剩余 93 天". Days are counted by SubscriptionKit (calendar days, UTC+8).
    static func expiry(_ dateString: String, now: Date = Date()) -> String {
        guard let days = SubscriptionPlanExtractor.daysUntil(dateString, from: now) else { return dateString }
        if days < 0 { return "\(dateString) · \(L10n.subExpired)" }
        if days == 0 { return "\(dateString) · \(L10n.subExpiresToday)" }
        return "\(dateString) · \(L10n.subDaysLeft(days))"
    }
}

// MARK: - Quota levels

/// How urgent a subscription's traffic or expiry is.
enum QuotaLevel: Int {
    case ok = 0        // fine
    case warning = 1   // under the configured threshold
    case critical = 2  // traffic used up, or plan expired

    /// A threshold of 0 turns the warning off; critical always applies.
    static func traffic(gb: Double?, thresholdGB: Int) -> QuotaLevel {
        guard let gb = gb else { return .ok }
        if gb <= 0 { return .critical }
        if thresholdGB > 0, gb < Double(thresholdGB) { return .warning }
        return .ok
    }

    static func expiry(days: Int?, thresholdDays: Int) -> QuotaLevel {
        guard let days = days else { return .ok }
        if days < 0 { return .critical }
        if thresholdDays > 0, days < thresholdDays { return .warning }
        return .ok
    }
}

/// Which subscription the menu bar and the dropdown row show.
enum SubscriptionBarChoice: Equatable {
    case first                  // the first enabled one with data (the original behaviour)
    case leastTraffic           // the enabled one with the least traffic left
    case soonestExpiry          // the enabled one that expires first
    case specific(String)       // one subscription, by id

    private static let idPrefix = "id:"

    init(stored: String?) {
        switch stored {
        case "leastTraffic": self = .leastTraffic
        case "soonestExpiry": self = .soonestExpiry
        case let value? where value.hasPrefix(Self.idPrefix) && value.count > Self.idPrefix.count:
            self = .specific(String(value.dropFirst(Self.idPrefix.count)))
        default: self = .first
        }
    }

    var stored: String {
        switch self {
        case .first: return "first"
        case .leastTraffic: return "leastTraffic"
        case .soonestExpiry: return "soonestExpiry"
        case .specific(let id): return Self.idPrefix + id
        }
    }
}

// MARK: - Menu bar summary

/// What the menu bar shows for one subscription: a status dot, the remaining traffic and the
/// time left until the next traffic reset ("25d"). Either text may be missing when the provider
/// gives no value. The dot follows the plan's expiry; the expiry date itself is in the tooltip.
struct SubscriptionBarInfo: Equatable {
    /// Drives the menu bar text color: `.ok` stays monochrome (no colour when all is well).
    enum Status: Equatable {
        case ok        // normal: monochrome
        case warning   // orange: under the traffic or expiry threshold (settings)
        case critical  // red: plan expired, or no traffic left
    }

    var status: Status
    var trafficText: String?
    var resetText: String?
    var tooltip: String

    /// nil when the subscription has no traffic, reset or expiry value at all.
    static func make(from item: SubscriptionItem, now: Date = Date()) -> SubscriptionBarInfo? {
        let gb = item.remainingGB
        let expiryDays = item.expiryDays(now: now)

        var resetText: String?
        if let date = item.nextResetDate,
           let days = SubscriptionPlanExtractor.daysUntil(date, from: now) {
            resetText = days < 0 ? L10n.barResetPending
                : (days == 0 ? L10n.barResetToday : L10n.barDays(days))
        }
        let trafficText = gb.map(compactTraffic)
        guard trafficText != nil || resetText != nil || expiryDays != nil else { return nil }

        // The worse of the traffic level and the expiry level; thresholds are user settings.
        let prefs = Preferences.shared
        let level = max(QuotaLevel.traffic(gb: gb, thresholdGB: prefs.lowTrafficThresholdGB).rawValue,
                        QuotaLevel.expiry(days: expiryDays, thresholdDays: prefs.expiryThresholdDays).rawValue)
        let status: Status = level == QuotaLevel.critical.rawValue ? .critical
            : (level == QuotaLevel.warning.rawValue ? .warning : .ok)

        var lines = [item.name.isEmpty ? L10n.subUnnamed : item.name]
        if let gb = gb { lines.append("\(L10n.subRemaining)：\(SubscriptionFormat.traffic(gb))") }
        if let reset = SubscriptionFormat.reset(item, now: now) { lines.append("\(L10n.subNextReset)：\(reset)") }
        if let date = item.expireDate { lines.append("\(L10n.subExpiry)：\(SubscriptionFormat.expiry(date, now: now))") }

        return SubscriptionBarInfo(status: status, trafficText: trafficText, resetText: resetText,
                                   tooltip: lines.joined(separator: "\n"))
    }

    /// Short form for the menu bar, always rounded down (never promises more than is left):
    /// 1.5 TB, 139 GB (from 139.78), 43 GB, 8 GB, 512 MB. Settings and tooltip keep two decimals.
    static func compactTraffic(_ gb: Double) -> String {
        if gb >= 1024 { return String(format: "%.1f TB", (gb / 1024 * 10).rounded(.down) / 10) }
        if gb >= 1 { return "\(Int(gb.rounded(.down))) GB" }
        return "\(Int((gb * 1024).rounded(.down))) MB"
    }
}

// MARK: - Manager

/// The subscription list: storage, per-link schedule, refreshing. Download, cache and value
/// extraction come from SubscriptionKit (`SubscriptionFetcher`, `SubscriptionAnalyzer`).
/// Main thread only; network work runs in a detached task.
///
/// Files in ~/Library/Application Support/WardenHelper/: subscription-links.json, SubscriptionCache/.
final class SubscriptionManager {
    static let shared = SubscriptionManager()
    static let changedNotification = Notification.Name("WardenHelperSubscriptionsChanged")

    private(set) var items: [SubscriptionItem] = []
    private var refreshingIDs: Set<String> = []
    /// Log of the latest (or running) refresh per subscription id; replaced by the next refresh.
    private var logs: [String: [SubscriptionLogLine]] = [:]
    private static let maxLogLines = 300

    private let fileURL: URL
    private let cacheDir: URL
    private var timer: Timer?
    private var quietUntil = Date.distantPast

    /// Schedule check period.
    private static let tick: TimeInterval = 30
    /// A failed link is retried after this, or after its interval if shorter.
    private static let failedRetry: TimeInterval = 5 * 60
    /// Pause after wake so the network can come up.
    private static let wakeGrace: TimeInterval = 8

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("WardenHelper", isDirectory: true)
        fileURL = dir.appendingPathComponent("subscription-links.json")
        cacheDir = dir.appendingPathComponent("SubscriptionCache", isDirectory: true)
        load()
    }

    // MARK: Queries

    func item(_ id: String?) -> SubscriptionItem? {
        guard let id = id else { return nil }
        return items.first { $0.id == id }
    }

    func isRefreshing(_ id: String) -> Bool { refreshingIDs.contains(id) }

    /// The subscription the menu bar shows, with its summary. Which one follows
    /// `Preferences.barSubscription`; nil when nothing qualifies.
    func barSelection(now: Date = Date()) -> (item: SubscriptionItem, info: SubscriptionBarInfo)? {
        let choice = Preferences.shared.barSubscription
        var candidates: [(item: SubscriptionItem, info: SubscriptionBarInfo)] = []
        for item in items where item.enabled {
            if let info = SubscriptionBarInfo.make(from: item, now: now) { candidates.append((item: item, info: info)) }
        }
        switch choice {
        case .first:
            return candidates.first
        case .specific(let id):
            // A deleted subscription falls back to the first one; a disabled or empty one shows nothing.
            guard items.contains(where: { $0.id == id }) else { return candidates.first }
            return candidates.first { $0.item.id == id }
        case .leastTraffic:
            let withTraffic = candidates.filter { $0.item.remainingGB != nil }
            return withTraffic.min { $0.item.remainingGB! < $1.item.remainingGB! } ?? candidates.first
        case .soonestExpiry:
            let withExpiry = candidates.filter { $0.item.expiryDays(now: now) != nil }
            return withExpiry.min { $0.item.expiryDays(now: now)! < $1.item.expiryDays(now: now)! } ?? candidates.first
        }
    }

    func menuBarInfo(now: Date = Date()) -> SubscriptionBarInfo? {
        barSelection(now: now)?.info
    }

    /// The subscription the dropdown row describes: the one in the menu bar, or (when that has
    /// no data yet) the chosen / first enabled one, so the row can still offer "update".
    func dropdownItem(now: Date = Date()) -> SubscriptionItem? {
        if let selected = barSelection(now: now) { return selected.item }
        if case .specific(let id) = Preferences.shared.barSubscription,
           let chosen = item(id), chosen.enabled { return chosen }
        return items.first { $0.enabled }
    }

    /// Subscription block appended to VPN notifications: a name line, then traffic / reset /
    /// expiry on their own lines. nil when there is no enabled subscription with values.
    /// Main thread only.
    func notificationBlock(now: Date = Date()) -> String? {
        guard let item = dropdownItem(now: now) else { return nil }
        let lines = SubscriptionFormat.infoLines(item, now: now)
        guard !lines.isEmpty else { return nil }
        let name = item.name.isEmpty ? L10n.subUnnamed : item.name
        return ([L10n.subMenuHeaderNamed(name)] + lines).joined(separator: "\n")
    }

    func log(for id: String?) -> [SubscriptionLogLine] {
        id.flatMap { logs[$0] } ?? []
    }

    // MARK: Editing

    @discardableResult
    func add() -> SubscriptionItem {
        let item = SubscriptionItem(name: L10n.subDefaultName(items.count + 1))
        items.append(item)
        commit()
        return item
    }

    func remove(id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        logs[id] = nil
        forgetQuotaState(id: id)
        let stem = SubscriptionFetcher.cacheFilenameStem(id)
        for file in ["\(stem).yaml", "\(stem).yaml.url"] {
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(file))
        }
        commit()
    }

    func update(id: String, _ change: (inout SubscriptionItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let before = items[i]
        change(&items[i])
        if items[i] != before { commit() }
    }

    /// Turning a subscription off stops its scheduled refreshes; turning it on refreshes it
    /// right away when it is due.
    func setEnabled(id: String, _ enabled: Bool) {
        update(id: id) { $0.enabled = enabled }
        if enabled { checkDue() }
    }

    /// Changing the link drops everything read from the old one and refreshes at once.
    func setURL(id: String, _ url: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].url != url else { return }
        items[i].url = url
        items[i].lastUpdated = nil
        items[i].lastAttempt = nil
        items[i].snapshotTrafficGB = nil
        items[i].resetDaysSnapshot = nil
        items[i].snapshotAt = nil
        items[i].realtimeRemainingGB = nil
        items[i].realtimeAt = nil
        items[i].expireDate = nil
        items[i].message = nil
        items[i].failed = false
        commit()
        if items[i].enabled, !items[i].trimmedURL.isEmpty { refresh(id: id, manual: true) }
    }

    // MARK: Scheduling

    /// Call once at launch. Refreshes whatever is due now, then keeps checking.
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in self?.checkDue() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)   // common modes: keeps firing while a menu is open
        timer = t

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.quietUntil = Date().addingTimeInterval(Self.wakeGrace)
        }
        checkDue()
    }

    private func checkDue() {
        let now = Date()
        evaluateQuota(notify: true)   // days pass without any refresh, so the calendar is checked here too
        guard now >= quietUntil else { return }
        for item in items where !refreshingIDs.contains(item.id) && isDue(item, now: now) {
            refresh(id: item.id)
        }
    }

    private func isDue(_ item: SubscriptionItem, now: Date) -> Bool {
        guard item.enabled, !item.trimmedURL.isEmpty else { return false }
        guard let last = item.lastAttempt, last <= now else { return true }   // never tried / clock moved back
        let wait = item.failed ? min(item.interval, Self.failedRetry) : item.interval
        return now.timeIntervalSince(last) >= wait
    }

    // MARK: Refreshing

    /// Refreshes one subscription now; ignored while it is already refreshing. `manual` is true
    /// for "Update now" (and a just-edited link), false for the schedule. Either way the run
    /// writes an update log and ends with a result notification.
    func refresh(id: String, manual: Bool = false) {
        guard let item = item(id), !refreshingIDs.contains(id) else { return }

        let url = item.trimmedURL
        guard let parsed = URL(string: url), parsed.host != nil,
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            let wasFailed = item.failed
            update(id: id) {
                $0.lastAttempt = Date()
                $0.failed = true
                $0.message = url.isEmpty ? nil : L10n.subInvalidURL
            }
            if !url.isEmpty {
                logs[id] = []
                appendLog(id, .error, L10n.subInvalidURL)
                notifyResult(id: id, success: false, message: L10n.subInvalidURL,
                             manual: manual, wasFailed: wasFailed)
            }
            return
        }

        refreshingIDs.insert(id)
        logs[id] = []   // a new run replaces the previous log
        appendLog(id, .note, manual ? L10n.subLogStartManual : L10n.subLogStartAuto)

        let cacheDir = self.cacheDir
        let rules = item.effectiveRules(global: Preferences.shared.subscriptionRules)
        Task.detached(priority: .utility) {
            let outcome = await SubscriptionManager.fetch(id: id, url: url, cacheDir: cacheDir, rules: rules) { level, message in
                // Hops to the main thread in call order, so lines land before `finish`.
                DispatchQueue.main.async { SubscriptionManager.shared.appendLog(id, level, message) }
            }
            DispatchQueue.main.async {
                SubscriptionManager.shared.finish(id: id, url: url, outcome: outcome, manual: manual)
            }
        }
    }

    private func appendLog(_ id: String, _ level: SubLogLevel, _ text: String) {
        var lines = logs[id] ?? []
        lines.append(SubscriptionLogLine(date: Date(), level: level, text: text))
        if lines.count > Self.maxLogLines { lines.removeFirst(lines.count - Self.maxLogLines) }
        logs[id] = lines
        post()
    }

    /// Manual runs always notify. Scheduled runs notify on success, and on the first failure of
    /// a streak only, so a dead link retried every few minutes does not flood the notification list.
    private func notifyResult(id: String, success: Bool, message: String, manual: Bool, wasFailed: Bool) {
        guard manual || success || !wasFailed, let item = item(id) else { return }
        ChangeNotifier.shared.notifySubscriptionUpdate(
            id: id,
            name: item.name.isEmpty ? L10n.subUnnamed : item.name,
            success: success,
            message: message)
    }

    private static func successSummary(_ item: SubscriptionItem, notice: String?) -> String {
        var parts: [String] = []
        if let line = SubscriptionFormat.trafficLine(item) { parts.append("\(L10n.subRemaining) \(line)") }
        if let date = item.expireDate { parts.append("\(L10n.subExpiry) \(SubscriptionFormat.expiry(date))") }
        if let reset = SubscriptionFormat.reset(item) { parts.append("\(L10n.subNextReset) \(reset)") }
        return parts.isEmpty ? (notice ?? L10n.subUpdatedPlain) : parts.joined(separator: "；")
    }

    private func finish(id: String, url: String, outcome: Outcome, manual: Bool) {
        refreshingIDs.remove(id)
        guard let i = items.firstIndex(where: { $0.id == id }) else { post(); return }

        // The link was edited while this refresh was running: the result belongs to the old link.
        if items[i].trimmedURL != url {
            post()
            if items[i].enabled, !items[i].trimmedURL.isEmpty { refresh(id: id, manual: true) }
            return
        }

        let now = Date()
        let wasFailed = items[i].failed
        items[i].lastAttempt = now
        if outcome.parsed {
            items[i].snapshotTrafficGB = outcome.snapshotTrafficGB
            items[i].resetDaysSnapshot = outcome.resetDays
            items[i].expireDate = outcome.expireDate
            if let at = outcome.snapshotAt { items[i].snapshotAt = at }
        }
        if outcome.fetchedLive && outcome.parsed {
            items[i].lastUpdated = now
            // A live download that no longer reports usage clears the old API value; the
            // stale-cache fallback leaves it (and its timestamp) alone.
            items[i].realtimeRemainingGB = outcome.realtimeGB
            items[i].realtimeAt = outcome.realtimeGB == nil ? nil : now
        }
        items[i].failed = outcome.error != nil
        items[i].message = outcome.error ?? outcome.notice
        commit()
        evaluateQuota(notify: true)

        // Final line of the log, then the notification with the same text.
        let summary: String
        if let error = outcome.error {
            summary = error
            appendLog(id, .error, error)
        } else {
            summary = Self.successSummary(items[i], notice: outcome.notice)
            appendLog(id, .success, L10n.subLogDone(summary))
        }
        // The card lists the values one per line; the log keeps its single line.
        let cardText = outcome.error == nil
            ? (SubscriptionFormat.infoLines(items[i]).joined(separator: "\n").nilIfEmpty ?? summary)
            : summary
        notifyResult(id: id, success: outcome.error == nil, message: cardText,
                     manual: manual, wasFailed: wasFailed)
    }

    // MARK: SubscriptionKit bridge (runs off the main thread)

    private struct Outcome: Sendable {
        /// The text came from a live download (not from SubscriptionKit's stale-cache fallback).
        var fetchedLive = false
        var parsed = false
        var snapshotTrafficGB: Double?
        var resetDays: Int?
        var snapshotAt: Date?
        var realtimeGB: Double?
        var expireDate: String?
        var error: String?
        var notice: String?
    }

    /// Collects the reason of the last failed attempt from SubscriptionKit's log lines.
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var failure: String?

        func record(_ level: SubLogLevel, _ message: String) {
            guard level == .warning, message.contains("fetch attempt"),
                  let r = message.range(of: " failed: ", options: .backwards) else { return }
            lock.lock(); defer { lock.unlock() }
            failure = String(message[r.upperBound...])
        }

        var lastFailure: String? {
            lock.lock(); defer { lock.unlock() }
            return failure
        }
    }

    private static func cacheModificationDate(cacheDir: URL, id: String) -> Date? {
        let file = cacheDir.appendingPathComponent("\(SubscriptionFetcher.cacheFilenameStem(id)).yaml")
        return (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private static func errorText(_ error: Error) -> String {
        (error as? SubscriptionError)?.description ?? error.localizedDescription
    }

    private static func fetch(id: String, url: String, cacheDir: URL, rules: SubscriptionRuleSet,
                              onLog: @escaping SubLogger) async -> Outcome {
        var out = Outcome()
        let box = LogBox()
        let log: SubLogger = { level, message in
            box.record(level, message)   // remembers the failure reason for the status text
            onLog(level, message)        // and every line goes to the update log
        }

        var options = SubscriptionFetchOptions()
        options.cacheTTLMinutes = 0   // own schedule; a TTL cache would make "Update now" a no-op
        options.concurrency = 1

        let fetcher = SubscriptionFetcher(subsDir: cacheDir, options: options, log: log)
        let entry = SubscriptionEntry(name: id, url: url)   // id = cache key

        let text: String
        let fromCache: Bool
        let userInfo: SubscriptionUserInfo?
        do {
            let r = try await fetcher.fetchText(entry)
            text = r.text
            fromCache = r.fromCache
            userInfo = r.userInfo
        } catch {
            out.error = L10n.subFailed(box.lastFailure ?? errorText(error))
            return out
        }
        out.fetchedLive = !fromCache

        let analysis = SubscriptionAnalyzer.analyze(texts: [id: text],
                                                    extractor: SubscriptionPlanExtractor(rules: rules),
                                                    now: Date(), log: log)
        if let reason = analysis.errors[id] {
            out.error = L10n.subFailed(reason)
            return out
        }
        guard let plan = analysis.plans.first else {
            out.error = L10n.subFailed("empty subscription")
            return out
        }

        out.parsed = true
        out.snapshotTrafficGB = plan.remainingTrafficGB
        out.resetDays = plan.resetDays
        out.expireDate = plan.expireDateString
        out.realtimeGB = fromCache ? nil : userInfo?.remainingGB
        // The node names date from when the text was downloaded, not from now.
        out.snapshotAt = fromCache ? cacheModificationDate(cacheDir: cacheDir, id: id) : Date()
        if fromCache {
            out.error = L10n.subUsingCache(box.lastFailure)
        } else if plan.remainingTrafficGB == nil && plan.resetDays == nil
                    && plan.expireDateString == nil && out.realtimeGB == nil {
            out.notice = L10n.subNoInfo
        }
        return out
    }

    // MARK: Threshold alerts

    /// Last level a notification was sent for, per "<id>.traffic" / "<id>.expiry". Kept across
    /// launches so a restart does not repeat an alert; cleared when the value is fine again.
    private static let quotaStateKey = "quotaAlertLevels"

    private func loadQuotaState() -> [String: Int] {
        let stored = UserDefaults.standard.dictionary(forKey: Self.quotaStateKey) as? [String: Int]
        return stored ?? [:]
    }

    private func forgetQuotaState(id: String) {
        var state = loadQuotaState()
        let keys = ["\(id).traffic", "\(id).expiry"]
        guard keys.contains(where: { state[$0] != nil }) else { return }
        for key in keys { state[key] = nil }
        UserDefaults.standard.set(state, forKey: Self.quotaStateKey)
    }

    /// Compares every enabled subscription with the thresholds. A notification goes out only
    /// when a level gets worse than the one already reported (ok -> warning -> critical), so a
    /// refresh that finds the same low value stays quiet. `notify: false` only records the
    /// current levels (used when the thresholds are edited: the bar changes colour at once,
    /// but nothing is sent for a change the user just made).
    func evaluateQuota(notify: Bool, now: Date = Date()) {
        let prefs = Preferences.shared
        let old = loadQuotaState()
        var state = old

        for item in items where item.enabled {
            let trafficKey = "\(item.id).traffic"
            let expiryKey = "\(item.id).expiry"

            let gb = item.remainingGB
            let days = item.expiryDays(now: now)
            let traffic = QuotaLevel.traffic(gb: gb, thresholdGB: prefs.lowTrafficThresholdGB)
            let expiry = QuotaLevel.expiry(days: days, thresholdDays: prefs.expiryThresholdDays)

            if gb == nil {
                state[trafficKey] = nil
            } else {
                let reported = state[trafficKey] ?? 0
                if traffic.rawValue > reported, notify, prefs.notifyQuotaAlert {
                    let critical = traffic == .critical
                    var lines = SubscriptionFormat.infoLines(item, now: now)
                    if !critical { lines.append(L10n.quotaLowNote(limitGB: prefs.lowTrafficThresholdGB)) }
                    ChangeNotifier.shared.notifyQuota(
                        id: item.id, kind: "traffic", name: item.name.isEmpty ? L10n.subUnnamed : item.name,
                        title: critical ? L10n.quotaEmptyTitle : L10n.quotaLowTitle,
                        body: lines.joined(separator: "\n"),
                        urgent: critical)
                }
                state[trafficKey] = traffic == .ok ? nil : traffic.rawValue
            }

            if days == nil {
                state[expiryKey] = nil
            } else {
                let reported = state[expiryKey] ?? 0
                if expiry.rawValue > reported, notify, prefs.notifyQuotaAlert {
                    let critical = expiry == .critical
                    var lines = SubscriptionFormat.infoLines(item, now: now)
                    if !critical { lines.append(L10n.quotaExpiringNote(limitDays: prefs.expiryThresholdDays)) }
                    ChangeNotifier.shared.notifyQuota(
                        id: item.id, kind: "expiry", name: item.name.isEmpty ? L10n.subUnnamed : item.name,
                        title: critical ? L10n.quotaExpiredTitle : L10n.quotaExpiringTitle,
                        body: lines.joined(separator: "\n"),
                        urgent: critical)
                }
                state[expiryKey] = expiry == .ok ? nil : expiry.rawValue
            }
        }
        if state != old { UserDefaults.standard.set(state, forKey: Self.quotaStateKey) }
    }

    // MARK: Extraction rules

    private static func cachedText(id: String, cacheDir: URL) -> String? {
        let file = cacheDir.appendingPathComponent("\(SubscriptionFetcher.cacheFilenameStem(id)).yaml")
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// Runs `body` off the main thread with the parsed cache of every subscription that has one
    /// (id -> proxies), or only of `restrict` when given. No network; the result comes back on
    /// the main thread.
    private func withCachedProxies<T>(only restrict: [String]? = nil,
                                      _ body: @escaping ([String: [ClashProxy]]) -> T,
                                      completion: @escaping (T) -> Void) {
        let ids = restrict ?? items.map { $0.id }
        let dir = cacheDir
        DispatchQueue.global(qos: .userInitiated).async {
            var parsed: [String: [ClashProxy]] = [:]
            for id in ids {
                guard let text = SubscriptionManager.cachedText(id: id, cacheDir: dir),
                      let proxies = try? ClashSubscriptionParser.parse(text, log: { _, _ in }) else { continue }
                parsed[id] = proxies
            }
            let result = body(parsed)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The rules `id` is read with: the global ones plus its own overrides.
    func effectiveRules(for id: String?) -> SubscriptionRuleSet {
        let global = Preferences.shared.subscriptionRules
        return item(id)?.effectiveRules(global: global) ?? global
    }

    /// Tests `candidate` against cached content (no network): the cache of subscription
    /// `subscriptionID` only, or of every subscription when it is nil. For a subscription the
    /// fallback for a failing pattern is that subscription's current effective rule.
    func testRules(_ candidate: SubscriptionRuleSet, subscriptionID: String? = nil,
                   completion: @escaping (SubscriptionRuleReport) -> Void) {
        let previous = effectiveRules(for: subscriptionID)
        withCachedProxies(only: subscriptionID.map { [$0] }, { (parsed: [String: [ClashProxy]]) -> SubscriptionRuleReport in
            let names = parsed.values.flatMap { $0.map { $0.name } }
            return SubscriptionRuleTester.test(candidate: candidate, previous: previous, nodeNames: names)
        }, completion: completion)
    }

    /// Re-reads the cached content with the saved rules (global, plus each subscription's own
    /// overrides) and updates what every subscription shows; call after any rule changed.
    /// Nothing is downloaded.
    func reapplyRules() {
        let global = Preferences.shared.subscriptionRules
        var rulesByID: [String: SubscriptionRuleSet] = [:]
        for item in items { rulesByID[item.id] = item.effectiveRules(global: global) }
        withCachedProxies({ (parsed: [String: [ClashProxy]]) -> [String: SubscriptionPlan] in
            var plans: [String: SubscriptionPlan] = [:]
            for (id, proxies) in parsed {
                let extractor = SubscriptionPlanExtractor(rules: rulesByID[id] ?? global)
                plans[id] = extractor.extractPlan(name: "", proxies: proxies)
            }
            return plans
        }, completion: { [weak self] plans in
            self?.applyPlans(plans)
        })
    }

    private func applyPlans(_ plans: [String: SubscriptionPlan]) {
        var changed = false
        for i in items.indices {
            guard let plan = plans[items[i].id] else { continue }
            if items[i].snapshotTrafficGB != plan.remainingTrafficGB {
                items[i].snapshotTrafficGB = plan.remainingTrafficGB
                changed = true
            }
            if items[i].resetDaysSnapshot != plan.resetDays {
                items[i].resetDaysSnapshot = plan.resetDays
                changed = true
            }
            if items[i].expireDate != plan.expireDateString {
                items[i].expireDate = plan.expireDateString
                changed = true
            }
        }
        if changed { commit() }
    }

    // MARK: Backup (export / import)

    /// The configuration of every subscription (no traffic figures or timestamps: those are
    /// read again from the link after an import).
    func backupItems() -> [SubscriptionBackupItem] {
        items.map { SubscriptionBackupItem($0) }
    }

    /// Merges `incoming` into the list: an entry replaces the subscription with the same id (or,
    /// failing that, the same link); anything else is added. Subscriptions that are not in
    /// `incoming` are left alone. New and re-linked ones are refreshed right away.
    @discardableResult
    func importBackup(_ incoming: [SubscriptionBackupItem]) -> (added: Int, updated: Int) {
        var added = 0
        var updated = 0
        for entry in incoming {
            let url = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let interval = min(max(entry.intervalValue, 1), 9999)
            let overrides = entry.validOverrides

            var index = items.firstIndex(where: { $0.id == entry.id })
            if index == nil, !url.isEmpty {
                index = items.firstIndex(where: { $0.trimmedURL == url })
            }
            if let i = index {
                items[i].name = entry.name
                items[i].intervalValue = interval
                items[i].intervalUnit = entry.intervalUnit
                items[i].enabled = entry.enabled
                items[i].ruleOverrides = overrides
                commit()
                setURL(id: items[i].id, entry.url)   // a different link starts from a clean slate
                updated += 1
            } else {
                var item = SubscriptionItem(id: entry.id, name: entry.name, url: entry.url)
                item.intervalValue = interval
                item.intervalUnit = entry.intervalUnit
                item.enabled = entry.enabled
                item.ruleOverrides = overrides
                items.append(item)
                added += 1
            }
        }
        commit()
        reapplyRules()   // overrides may have changed how the cached content reads
        checkDue()       // new subscriptions have never been refreshed
        return (added, updated)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([SubscriptionItem].self, from: data) { items = decoded }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("WardenHelper: could not save subscriptions: %@", error.localizedDescription)
        }
    }

    private func commit() {
        save()
        post()
    }

    private func post() {
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }
}


private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
