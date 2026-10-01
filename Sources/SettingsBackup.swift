import Cocoa
import UniformTypeIdentifiers

// MARK: - File format

/// One setting in a backup file. Kept as a small typed enum instead of `Any`, so a hand-edited
/// or damaged file is checked value by value (see `Preferences.applyPortableSettings`).
enum BackupValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case unsupported   // an array, object or null: read as "not set"

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else { self = .unsupported }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v):   try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .unsupported:   try c.encodeNil()
        }
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// A whole number; a JSON `2.0` counts.
    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let d): return d == d.rounded() && abs(d) < 1e9 ? Int(d) : nil
        default: return nil
        }
    }

    /// JSON writes `1.0` as `1`, so an integer is a valid double too.
    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let n): return Double(n)
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}

/// The configuration of one subscription: what the user typed, not what was read from the link.
struct SubscriptionBackupItem: Codable {
    var id: String
    var name: String
    var url: String
    var intervalValue: Int
    var intervalUnit: SubscriptionIntervalUnit
    var enabled: Bool
    var ruleOverrides: [String: String]

    init(_ item: SubscriptionItem) {
        id = item.id
        name = item.name
        url = item.url
        intervalValue = item.intervalValue
        intervalUnit = item.intervalUnit
        enabled = item.enabled
        ruleOverrides = item.ruleOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, intervalValue, intervalUnit, enabled, ruleOverrides
    }

    /// Lenient: a missing or unreadable field takes its default, so one bad entry does not
    /// reject the whole file. The id is also the cache file name, so anything that is not a
    /// UUID is replaced by a new one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        id = UUID(uuidString: rawID) != nil ? rawID : UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        intervalValue = try c.decodeIfPresent(Int.self, forKey: .intervalValue) ?? 12
        intervalUnit = (try? c.decodeIfPresent(SubscriptionIntervalUnit.self, forKey: .intervalUnit)) ?? .hours
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        ruleOverrides = (try? c.decodeIfPresent([String: String].self, forKey: .ruleOverrides)) ?? [:]
    }

    /// The overrides that name a known rule and pass its checks; the rest are dropped.
    var validOverrides: [String: String] {
        var out: [String: String] = [:]
        for field in SubscriptionRuleField.allCases {
            guard let pattern = ruleOverrides[field.rawValue] else { continue }
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if case .success = field.compile(trimmed) { out[field.rawValue] = trimmed }
        }
        return out
    }
}

/// The whole file. Either part may be absent: settings only, or subscriptions only.
struct SettingsBackup: Codable {
    static let appID = "WardenHelper"
    static let currentFormat = 1

    var app: String
    var format: Int
    var exportedAt: Date
    var settings: [String: BackupValue]?
    var subscriptions: [SubscriptionBackupItem]?
}

// MARK: - Export / import UI

/// The save / open panels and confirmation dialogs around `SettingsBackup`.
enum SettingsBackupUI {

    private static let maxFileSize = 2_000_000   // a real backup is a few KB

    // MARK: Export

    static func exportBackup() {
        let manager = SubscriptionManager.shared

        let panel = NSSavePanel()
        panel.title = L10n.backupExportTitle
        panel.message = L10n.backupExportMessage
        panel.prompt = L10n.backupExportPrompt
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "WardenHelper-\(stamp(Date())).json"

        let includeSubscriptions = NSButton(checkboxWithTitle: L10n.backupIncludeSubscriptions,
                                            target: nil, action: nil)
        includeSubscriptions.state = manager.items.isEmpty ? .off : .on
        includeSubscriptions.isEnabled = !manager.items.isEmpty
        includeSubscriptions.frame = NSRect(x: 20, y: 8, width: 320, height: 20)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 36))
        accessory.addSubview(includeSubscriptions)
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let withSubscriptions = includeSubscriptions.state == .on
        let backup = SettingsBackup(
            app: SettingsBackup.appID,
            format: SettingsBackup.currentFormat,
            exportedAt: Date(),
            settings: Preferences.shared.portableSettings(),
            subscriptions: withSubscriptions ? manager.backupItems() : nil)

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(backup).write(to: url, options: .atomic)
            if withSubscriptions {
                // The links carry access tokens: keep the file private to this user.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            alert(L10n.backupExportFailed, error.localizedDescription, style: .warning)
        }
    }

    // MARK: Import

    /// Returns true when something was imported (the caller then redraws its pages).
    @discardableResult
    static func importBackup() -> Bool {
        let panel = NSOpenPanel()
        panel.title = L10n.backupImportTitle
        panel.prompt = L10n.backupImportPrompt
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxFileSize else {
            alert(L10n.backupImportFailed, L10n.backupTooLarge, style: .warning)
            return false
        }

        let backup: SettingsBackup
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            backup = try decoder.decode(SettingsBackup.self, from: Data(contentsOf: url))
        } catch {
            alert(L10n.backupImportFailed, L10n.backupNotReadable, style: .warning)
            return false
        }
        guard backup.app == SettingsBackup.appID else {
            alert(L10n.backupImportFailed, L10n.backupNotReadable, style: .warning)
            return false
        }
        guard backup.format <= SettingsBackup.currentFormat else {
            alert(L10n.backupImportFailed, L10n.backupTooNew, style: .warning)
            return false
        }
        let subscriptions = backup.subscriptions ?? []
        guard backup.settings != nil || !subscriptions.isEmpty else {
            alert(L10n.backupImportFailed, L10n.backupEmpty, style: .informational)
            return false
        }

        var will: [String] = []
        if backup.settings != nil { will.append(L10n.backupWillReplaceSettings) }
        if !subscriptions.isEmpty { will.append(L10n.backupWillMergeSubscriptions(subscriptions.count)) }

        let confirm = NSAlert()
        confirm.messageText = L10n.backupConfirmTitle
        confirm.informativeText = will.joined(separator: "\n")
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: L10n.backupConfirmButton)
        confirm.addButton(withTitle: L10n.cancel)
        guard confirm.runModal() == .alertFirstButtonReturn else { return false }

        if let settings = backup.settings {
            Preferences.shared.applyPortableSettings(settings)
            if subscriptions.isEmpty { SubscriptionManager.shared.reapplyRules() }   // the global rules may have changed
        }
        var counts: (added: Int, updated: Int)?
        if !subscriptions.isEmpty {
            counts = SubscriptionManager.shared.importBackup(subscriptions)
        }

        alert(L10n.backupDoneTitle,
              L10n.backupDoneMessage(settings: backup.settings != nil,
                                     added: counts?.added, updated: counts?.updated),
              style: .informational)
        return true
    }

    // MARK: Helpers

    private static func alert(_ title: String, _ message: String, style: NSAlert.Style) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = style
        a.addButton(withTitle: L10n.backupOK)
        a.runModal()
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
