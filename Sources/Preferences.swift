import Foundation

class Preferences {
    static let shared = Preferences()
    
    // Notification name for when settings change
    static let changedNotification = Notification.Name("WardenHelperPreferencesChanged")
    
    private let defaults = UserDefaults.standard
    
    // Feature Toggles
    var showFlag: Bool {
        get { defaults.object(forKey: "showFlag") as? Bool ?? true }
        set { 
            defaults.set(newValue, forKey: "showFlag") 
            notify()
        }
    }
    
    var showArrows: Bool {
        get { defaults.object(forKey: "showArrows") as? Bool ?? true }
        set { 
            defaults.set(newValue, forKey: "showArrows")
            notify()
        }
    }
    
    // One layout for everything in the menu bar (icons, speeds, subscription):
    // false = side by side (one row), true = top and bottom (two rows).
    var stackedLayout: Bool {
        get { defaults.object(forKey: "menuBarStacked") as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: "menuBarStacked")
            notify()
        }
    }

    var showIPInsteadOfFlag: Bool {
        get { defaults.bool(forKey: "showIPInsteadOfFlag") } // Defaults to false
        set { 
            defaults.set(newValue, forKey: "showIPInsteadOfFlag")
            notify()
        }
    }
    
    /// Bar speed taken from the proxy kernel's controller (proxied traffic only) instead of the
    /// network interfaces. Falls back to the interfaces while no VPN / no controller reading.
    var speedFromProxy: Bool {
        get { defaults.object(forKey: "speedFromProxy") as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: "speedFromProxy")
            notify()
        }
    }

    var showVPNShield: Bool {
        get { defaults.object(forKey: "showVPNShield") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "showVPNShield")
            notify()
        }
    }
    
    // Remaining traffic + expiry date (with a status dot) left of the speeds.
    var showSubscription: Bool {
        get { defaults.object(forKey: "showSubscription") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "showSubscription")
            notify()
        }
    }

    // Which information blocks the dropdown menu lists (one switch per block, default on).
    // The rows that are not blocks (IP, VPN state, actions) always stay.
    func showsMenuBlock(_ block: MenuInfoBlock) -> Bool {
        defaults.object(forKey: block.preferenceKey) as? Bool ?? true
    }

    func setShowsMenuBlock(_ block: MenuInfoBlock, _ on: Bool) {
        defaults.set(on, forKey: block.preferenceKey)
        notify()
    }

    // Hide the public IP in the menu bar, the dropdown and the tooltip (screen sharing / recording).
    // Reopen the app after an unexpected crash (never after a normal quit).
    var restartOnCrash: Bool {
        get { defaults.object(forKey: "restartOnCrash") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "restartOnCrash")
            notify()
        }
    }

    var hideIP: Bool {
        get { defaults.bool(forKey: "hideIP") }
        set {
            defaults.set(newValue, forKey: "hideIP")
            notify()
        }
    }

    // Subscription warning thresholds. Orange when less than this much traffic (GB) / fewer than
    // this many days are left; 0 turns that warning off. Red (used up / expired) is fixed.
    var lowTrafficThresholdGB: Int {
        get { max(0, defaults.object(forKey: "lowTrafficThresholdGB") as? Int ?? 10) }
        set {
            defaults.set(max(0, newValue), forKey: "lowTrafficThresholdGB")
            notify()
        }
    }

    var expiryThresholdDays: Int {
        get { max(0, defaults.object(forKey: "expiryThresholdDays") as? Int ?? 3) }
        set {
            defaults.set(max(0, newValue), forKey: "expiryThresholdDays")
            notify()
        }
    }

    // One notification when a subscription crosses a threshold (see SubscriptionManager).
    var notifyQuotaAlert: Bool {
        get { defaults.object(forKey: "notifyQuotaAlert") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "notifyQuotaAlert")
            notify()
        }
    }

    // Which subscription the menu bar (and the dropdown row) shows.
    var barSubscription: SubscriptionBarChoice {
        get { SubscriptionBarChoice(stored: defaults.string(forKey: "barSubscription")) }
        set {
            defaults.set(newValue.stored, forKey: "barSubscription")
            notify()
        }
    }

    // VPN not connected: true = the bar shrinks to the slashed shield alone;
    // false = the normal bar stays (dimmed to 50%) and its shield is slashed.
    var vpnDownShowsOnlyIcon: Bool {
        get { defaults.object(forKey: "vpnDownShowsOnlyIcon") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "vpnDownShowsOnlyIcon")
            notify()
        }
    }

    // VPN connect / disconnect notifications. The stored key keeps its old name
    // ("notifyOnIPChange") so an existing user's choice survives the upgrade.
    var notifyOnVPNChange: Bool {
        get { defaults.object(forKey: "notifyOnIPChange") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "notifyOnIPChange")
            notify()
        }
    }

    // A pop-up window (besides the notification) when the VPN drops. Independent of `notifyOnVPNChange`.
    var popupOnVPNDisconnect: Bool {
        get { defaults.object(forKey: "popupOnVPNDisconnect") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "popupOnVPNDisconnect")
            notify()
        }
    }

    // Status card after sleep / lock; needs `notifyOnVPNChange`.
    var notifyOnResume: Bool {
        get { defaults.object(forKey: "notifyOnResume") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "notifyOnResume")
            notify()
        }
    }

    // Result card after a subscription update (manual or automatic).
    var notifySubscriptionUpdate: Bool {
        get { defaults.object(forKey: "notifySubscriptionUpdate") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "notifySubscriptionUpdate")
            notify()
        }
    }

    // Regular expressions that read traffic / reset / expiry from a subscription's info nodes.
    // Only patterns that passed verification are stored; anything else reads as the built-in
    // default. A pattern equal to its default is not stored, so an untouched rule follows the
    // default of a newer version.
    var subscriptionRules: SubscriptionRuleSet {
        get {
            var rules = SubscriptionRuleSet.defaults
            for field in SubscriptionRuleField.allCases {
                if let stored = defaults.string(forKey: field.storageKey),
                   case .success = field.compile(stored) {
                    rules[field] = stored
                }
            }
            return rules
        }
        set {
            for field in SubscriptionRuleField.allCases {
                if newValue[field] == SubscriptionRuleSet.defaults[field] {
                    defaults.removeObject(forKey: field.storageKey)
                } else {
                    defaults.set(newValue[field], forKey: field.storageKey)
                }
            }
        }
    }

    var refreshInterval: Double {
        get { defaults.object(forKey: "refreshInterval") as? Double ?? 1.0 }
        set { 
            defaults.set(newValue, forKey: "refreshInterval")
            notify()
        }
    }
    
    // Speed Display Mode: 0 = Both, 1 = Upload Only, 2 = Download Only
    var displayMode: Int {
        get { defaults.object(forKey: "displayMode") as? Int ?? 0 }
        set {
            defaults.set(newValue, forKey: "displayMode")
            notify()
        }
    }
    
    // Lock monitoring to a specific network interface (nil = all interfaces)
    var lockedInterface: String? {
        get { defaults.string(forKey: "lockedInterface") }
        set {
            defaults.set(newValue, forKey: "lockedInterface")
            notify()
        }
    }
    
    // Where the proxy kernel's controller listens ("127.0.0.1:9090"); empty = auto-detect.
    // The secret is not a preference: it lives in the Keychain (ControllerSecretStore).
    static let defaultControllerAddress = "127.0.0.1:9090"
    var controllerAddress: String {
        // Stored even when empty: an empty value is the user's choice of auto-detect.
        get { defaults.object(forKey: "controllerAddress") as? String ?? Self.defaultControllerAddress }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "controllerAddress")
            notify()
        }
    }

    // Write hourly traffic logs to ~/Library/Logs/WardenHelper/traffic/ (see TrafficLog).
    var logTraffic: Bool {
        get { defaults.object(forKey: "logTraffic") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "logTraffic")
            notify()
        }
    }

    // Block listed sites / processes / IPs while the VPN is off (see BlockRulesStore).
    var blockEnabled: Bool {
        get { defaults.object(forKey: "blockEnabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "blockEnabled")
            notify()
        }
    }

    /// The VPN dropped: the block switch goes back to its default (on). Callable from any thread.
    /// The value is written at once, so the arm decision that follows already sees it; the
    /// change notification (UI, settings window) is posted on the main thread.
    /// Returns true when the switch was off and has been turned on.
    @discardableResult
    func restoreBlockDefault() -> Bool {
        guard !blockEnabled else { return false }
        defaults.removeObject(forKey: "blockEnabled")            // absent = the default, on
        DispatchQueue.main.async { [weak self] in self?.notify() }
        return true
    }

    static var defaultBlockRulesPath: String {
        "~/Library/Application Support/WardenHelper/block-rules.json"
    }

    /// The rules file as the user typed it (may start with `~`); empty input = the default.
    var blockRulesPath: String {
        get {
            let stored = defaults.string(forKey: "blockRulesPath")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? Self.defaultBlockRulesPath : stored
        }
        set {
            let clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || clean == Self.defaultBlockRulesPath {
                defaults.removeObject(forKey: "blockRulesPath")
            } else {
                defaults.set(clean, forKey: "blockRulesPath")
            }
            notify()
        }
    }

    // Seconds between AI exit checks. They run in the background by default (`aiBackgroundCheck`),
    // so the default is gentler than when the check only ran with the AI page open.
    static let aiStatusIntervalRange = 3...3600
    static let aiStatusIntervalDefault = 60
    var aiStatusRefreshSeconds: Int {
        get {
            let stored = defaults.object(forKey: "aiStatusRefreshSeconds") as? Int ?? Self.aiStatusIntervalDefault
            return min(max(stored, Self.aiStatusIntervalRange.lowerBound), Self.aiStatusIntervalRange.upperBound)
        }
        set {
            defaults.set(min(max(newValue, Self.aiStatusIntervalRange.lowerBound), Self.aiStatusIntervalRange.upperBound),
                         forKey: "aiStatusRefreshSeconds")
        }
    }

    // AI exit checks keep running while the settings page is closed (default on); the dropdown
    // menu lists the result per service. Off = they run only while the AI 出口 page is open.
    var aiBackgroundCheck: Bool {
        get { defaults.object(forKey: "aiBackgroundCheck") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "aiBackgroundCheck")
            notify()
        }
    }

    // A notification when a service's exit country / region differs from the one of the last check.
    var notifyAIRegionChange: Bool {
        get { defaults.object(forKey: "notifyAIRegionChange") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "notifyAIRegionChange")
            notify()
        }
    }

    // The AI status icon in the menu bar (after the region): solid when every AI service exits in
    // `aiExpectedRegion`, slashed otherwise. Needs the AI checks to be running.
    var showAIStatus: Bool {
        get { defaults.object(forKey: "showAIStatus") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "showAIStatus")
            notify()
        }
    }

    // The one region all AI services should exit in, picked from a short list in Settings.
    // To offer another region, add its two-letter code to `aiRegionChoices`.
    static let aiRegionChoices = ["TW", "JP", "US"]
    static let aiExpectedRegionDefault = aiRegionChoices[0]
    var aiExpectedRegion: String {
        get {
            // An unknown stored value (an older version, a hand-edited backup) reads as the default.
            let stored = (defaults.string(forKey: "aiExpectedRegion") ?? "").uppercased()
            return Self.aiRegionChoices.contains(stored) ? stored : Self.aiExpectedRegionDefault
        }
        set {
            defaults.set(newValue.uppercased(), forKey: "aiExpectedRegion")
            notify()
        }
    }

    private init() {}
    
    private enum SettingKind { case bool, int, double, string }

    /// Every preference key with the type it holds. Reset removes exactly these; the VPN traffic
    /// totals (`vpnTraffic.*`, same UserDefaults) are data, not settings, and must survive it.
    private static let settingSchema: [String: SettingKind] = {
        var schema: [String: SettingKind] = [
            "showFlag": .bool, "showArrows": .bool, "menuBarStacked": .bool,
            "showIPInsteadOfFlag": .bool, "showVPNShield": .bool, "showSubscription": .bool,
            "vpnDownShowsOnlyIcon": .bool, "notifyOnIPChange": .bool, "notifyOnResume": .bool,
            "notifySubscriptionUpdate": .bool, "popupOnVPNDisconnect": .bool, "hideIP": .bool,
            "notifyQuotaAlert": .bool, "logTraffic": .bool, "blockEnabled": .bool,
            "speedFromProxy": .bool, "restartOnCrash": .bool,
            "aiBackgroundCheck": .bool, "notifyAIRegionChange": .bool, "showAIStatus": .bool,
            "refreshInterval": .double,
            "displayMode": .int, "lowTrafficThresholdGB": .int, "expiryThresholdDays": .int,
            "aiStatusRefreshSeconds": .int,
            "lockedInterface": .string, "barSubscription": .string, "controllerAddress": .string,
            "blockRulesPath": .string, "aiExpectedRegion": .string,
        ]
        for field in SubscriptionRuleField.allCases { schema[field.storageKey] = .string }
        for block in MenuInfoBlock.allCases { schema[block.preferenceKey] = .bool }
        return schema
    }()

    /// Settings that belong to this Mac and are neither exported nor imported.
    private static let deviceOnlyKeys: Set<String> = ["lockedInterface", "blockRulesPath"]

    func resetToDefaults() {
        for key in Self.settingSchema.keys { defaults.removeObject(forKey: key) }
        notify()
    }

    // MARK: Export / import

    /// The settings that differ from their defaults and make sense on another Mac.
    func portableSettings() -> [String: BackupValue] {
        var out: [String: BackupValue] = [:]
        for (key, kind) in Self.settingSchema where !Self.deviceOnlyKeys.contains(key) {
            guard let raw = defaults.object(forKey: key) else { continue }
            switch kind {
            case .bool:   if let v = raw as? Bool { out[key] = .bool(v) }
            case .int:    if let v = raw as? Int { out[key] = .int(v) }
            case .double: if let v = raw as? Double { out[key] = .double(v) }
            case .string: if let v = raw as? String { out[key] = .string(v) }
            }
        }
        return out
    }

    /// Makes the portable settings equal to `values`: a key that is missing, of the wrong type
    /// or out of range goes back to its default. The Mac-specific settings are left alone.
    func applyPortableSettings(_ values: [String: BackupValue]) {
        for (key, kind) in Self.settingSchema where !Self.deviceOnlyKeys.contains(key) {
            if let value = values[key], let clean = Self.sanitized(value, key: key, kind: kind) {
                defaults.set(clean, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        notify()
    }

    /// The value to store for `key`, or nil when the imported one is unusable.
    private static func sanitized(_ value: BackupValue, key: String, kind: SettingKind) -> Any? {
        switch kind {
        case .bool:
            return value.boolValue
        case .string:
            guard let text = value.stringValue else { return nil }
            if key == "aiExpectedRegion" {
                let code = text.uppercased()
                return aiRegionChoices.contains(code) ? code : nil
            }
            if key == "controllerAddress" {
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty || ControllerAddress.baseURL(from: clean) != nil ? clean : nil
            }
            // A rule that would not pass verification is dropped (it would read as the default).
            if let field = SubscriptionRuleField.allCases.first(where: { $0.storageKey == key }) {
                guard case .success = field.compile(text) else { return nil }
            }
            return text
        case .int:
            guard let n = value.intValue else { return nil }
            let range: ClosedRange<Int>
            switch key {
            case "displayMode":           range = 0...2
            case "lowTrafficThresholdGB": range = 0...9999
            case "expiryThresholdDays":   range = 0...365
            default:                      range = Int.min...Int.max
            }
            return range.contains(n) ? n : nil
        case .double:
            guard let d = value.doubleValue, [1.0, 2.0, 5.0].contains(d) else { return nil }   // the choices in 通用
            return d
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Preferences.changedNotification, object: nil)
    }
}
