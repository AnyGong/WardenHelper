import Foundation

/// The addresses the domain rules resolved to, kept on disk (`/var/db/warden-helper/resolved-cache.json`,
/// root only). Arming applies these first, before any lookup, so blocking by address is in
/// force at once after a VPN drop, a toggle or a reboot. Every lookup adds what it finds:
/// CDNs rotate their addresses, so an address seen recently stays blocked for a week.
final class AddressCache {

    private struct File: Codable {
        var version: Int
        var entries: [String: [String: Double]]      // name -> host CIDR -> last seen (Unix time)
        var seen: [String: Double]?                  // names clients asked for that a rule matched
    }

    static var path: String { BlockIPC.stateDirectory + "/resolved-cache.json" }
    static let maxAge: TimeInterval = 7 * 24 * 3600
    static let maxPerName = 64
    private static let resaveInterval: TimeInterval = 3600

    private let lock = NSLock()
    private var entries: [String: [String: Double]] = [:]
    private var seenNames: [String: Double] = [:]
    static let maxSeen = 300
    private var dirty = false
    private var lastSaved: Double = 0

    init() { load() }

    // MARK: Load

    /// Everything read from disk is checked again; a damaged or foreign file is ignored.
    private func load() {
        guard let data = FileManager.default.contents(atPath: Self.path) else { return }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 else {
            helperLog("block-addr cache is unreadable; starting empty")
            return
        }
        let oldest = Date().timeIntervalSince1970 - Self.maxAge
        var clean: [String: [String: Double]] = [:]
        var count = 0
        for (name, addresses) in file.entries {
            guard case .success(let valid) = BlockRuleValidator.domain(name, allowWildcard: false) else { continue }
            var kept: [String: Double] = [:]
            for (cidr, seen) in addresses where seen >= oldest {
                if case .success(let canonical) = BlockRuleValidator.cidr(cidr), canonical == cidr { kept[cidr] = seen }
            }
            if !kept.isEmpty { clean[valid] = kept; count += kept.count }
        }
        entries = clean
        for (name, t) in file.seen ?? [:] where t >= oldest {
            if case .success(let valid) = BlockRuleValidator.domain(name, allowWildcard: false) { seenNames[valid] = t }
        }
        lastSaved = Date().timeIntervalSince1970
        helperLog("block-addr cache loaded names=\(clean.count) addresses=\(count)")
    }

    // MARK: Read

    /// Host CIDRs still fresh for the given names, sorted.
    func cidrs(for names: [String], now: Date = Date()) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let oldest = now.timeIntervalSince1970 - Self.maxAge
        var out = Set<String>()
        for name in names {
            for (cidr, seen) in entries[name] ?? [:] where seen >= oldest { out.insert(cidr) }
        }
        return out.sorted()
    }

    /// The most recently asked names first.
    func recentSeen(limit: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return seenNames.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }

    func noteSeen(_ names: [String], now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let t = now.timeIntervalSince1970
        var isNew = false
        for name in names {
            if seenNames[name] == nil { isNew = true }
            seenNames[name] = t
        }
        if seenNames.count > Self.maxSeen {
            let newest = seenNames.sorted { $0.value > $1.value }.prefix(Self.maxSeen)
            seenNames = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        if isNew { dirty = true }
    }

    // MARK: Update

    /// Adds what a lookup found. True when an address was new (a refreshed time stamp alone is
    /// not a change and only reaches the disk about once an hour).
    @discardableResult
    func merge(_ found: [String: [String]], now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let t = now.timeIntervalSince1970
        var changed = false
        for (name, list) in found {
            var current = entries[name] ?? [:]
            for cidr in list {
                if current[cidr] == nil { changed = true }
                current[cidr] = t
            }
            if current.count > Self.maxPerName {                 // keep the most recently seen
                let newest = current.sorted { $0.value > $1.value }.prefix(Self.maxPerName)
                current = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
            }
            entries[name] = current
        }
        for (name, addresses) in entries {                       // drop what expired
            let fresh = addresses.filter { $0.value >= t - Self.maxAge }
            if fresh.count != addresses.count {
                entries[name] = fresh.isEmpty ? nil : fresh
                changed = true
            }
        }
        if changed || t - lastSaved > Self.resaveInterval { dirty = true }
        return changed
    }

    // MARK: Save

    func saveIfNeeded() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = entries
        let seenSnapshot = seenNames
        dirty = false
        lock.unlock()

        guard let data = try? JSONEncoder().encode(File(version: 1, entries: snapshot, seen: seenSnapshot)) else { return }
        if HelperFiles.write(String(decoding: data, as: UTF8.self), to: Self.path) {
            lock.lock(); lastSaved = Date().timeIntervalSince1970; lock.unlock()
        } else {
            lock.lock(); dirty = true; lock.unlock()             // try again next time
        }
    }
}
