import Foundation

/// The windows of the node statistics window. The short ones slide with the clock; day, week and
/// month are calendar periods (from 00:00 today, from the first day of this week per the system
/// calendar, from the 1st of this month 00:00).
enum StatsPeriod: Int, CaseIterable {
    case min15, min30, hour1, hour6, hour12, day, week, month

    var title: String { L10n.statsPeriodTitles[rawValue] }

    /// Calendar periods (from a fixed point on the calendar rather than a sliding window).
    var isCalendar: Bool { self == .day || self == .week || self == .month }

    func start(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .min15: return now.addingTimeInterval(-15 * 60)
        case .min30: return now.addingTimeInterval(-30 * 60)
        case .hour1: return now.addingTimeInterval(-3600)
        case .hour6: return now.addingTimeInterval(-6 * 3600)
        case .hour12: return now.addingTimeInterval(-12 * 3600)
        case .day: return calendar.startOfDay(for: now)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        case .month: return calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        }
    }
}

struct NodeTrafficRow: Equatable {
    let node: String
    let up: UInt64
    let down: UInt64
    var total: UInt64 { up &+ down }
}

/// Proxied traffic per outbound node over time, for the node statistics window.
///
/// `VPNTrafficTracker` adds the growth of every poll here, attributed to the node the connection
/// left through. Two resolutions are kept so any window can be summed without a huge file:
/// - minute buckets for the last 48 hours (15 min ... 12 h, and today), and
/// - hour buckets (local hours) older than that, kept for 40 days (this week / this month).
/// A minute bucket moves into its hour bucket when it gets older than 48 hours, never both, so
/// nothing is counted twice. Saved as JSON to `~/Library/Application Support/WardenHelper/node-traffic.json`
/// at most every 30 s and when the app quits. Thread-safe.
final class NodeTrafficStore {
    static let shared = NodeTrafficStore()

    private struct Pair { var up: UInt64 = 0; var down: UInt64 = 0 }
    private struct Entry: Codable { var k: Int; var n: [String: [UInt64]] }     // k = minute key, n = node -> [up, down]
    private struct FileModel: Codable { var version: Int; var minutes: [Entry]; var hours: [Entry] }

    private static let fileVersion = 1
    private static let minuteRetention = 48 * 60            // minutes
    private static let hourRetention = 40 * 24 * 60         // minutes
    private static let saveInterval: TimeInterval = 30

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "warden-helper.nodetraffic.io", qos: .utility)
    private let fileURL: URL

    private var minutes: [Int: [String: Pair]] = [:]       // minute key -> node -> bytes
    private var hours: [Int: [String: Pair]] = [:]         // minute key of the local hour start -> node -> bytes
    private var dirty = false
    private var lastSave = Date()
    private var lastCompactKey = 0

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support", isDirectory: true)
        fileURL = base.appendingPathComponent("WardenHelper", isDirectory: true)
            .appendingPathComponent("node-traffic.json")
        load()
        lock.lock()
        compactLocked(nowKey: Self.minuteKey(Date()))
        lock.unlock()
    }

    // MARK: - Input

    /// Bytes that just went through each node (growth since the previous reading).
    func add(_ deltas: [String: TrafficAmount], at date: Date = Date()) {
        guard !deltas.isEmpty else { return }
        let key = Self.minuteKey(date)
        lock.lock()
        var bucket = minutes[key] ?? [:]
        for (node, amount) in deltas {
            var pair = bucket[node] ?? Pair()
            pair.up &+= amount.up
            pair.down &+= amount.down
            bucket[node] = pair
        }
        minutes[key] = bucket
        dirty = true
        if key != lastCompactKey {
            lastCompactKey = key
            compactLocked(nowKey: key)
        }
        let due = Date().timeIntervalSince(lastSave) >= Self.saveInterval
        lock.unlock()
        if due { save() }
    }

    /// Forget everything (重置流量统计).
    func clear() {
        lock.lock()
        minutes = [:]
        hours = [:]
        dirty = true
        lock.unlock()
        save(wait: true)
    }

    // MARK: - Output

    /// Every node that carried traffic in `period` with its up / download, unsorted, and the moment
    /// the window starts (minute precision).
    func rows(for period: StatsPeriod, now: Date = Date()) -> (rows: [NodeTrafficRow], since: Date) {
        let since = period.start(now: now)
        let startKey = Self.minuteKey(since)
        var sums: [String: Pair] = [:]

        lock.lock()
        for (key, bucket) in minutes where key >= startKey {
            for (node, pair) in bucket {
                var sum = sums[node] ?? Pair()
                sum.up &+= pair.up
                sum.down &+= pair.down
                sums[node] = sum
            }
        }
        for (key, bucket) in hours where key >= startKey {
            for (node, pair) in bucket {
                var sum = sums[node] ?? Pair()
                sum.up &+= pair.up
                sum.down &+= pair.down
                sums[node] = sum
            }
        }
        lock.unlock()

        let rows = sums.compactMap { node, pair -> NodeTrafficRow? in
            (pair.up == 0 && pair.down == 0) ? nil : NodeTrafficRow(node: node, up: pair.up, down: pair.down)
        }
        return (rows, since)
    }

    // MARK: - Compaction (lock held)

    private static func minuteKey(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    /// Minute key of the start of the local hour that contains `key` (a half-hour time zone keeps
    /// its hours aligned with the local clock, so midnight is always an hour boundary).
    private static func hourStartKey(of key: Int) -> Int {
        let date = Date(timeIntervalSince1970: Double(key) * 60)
        let start = Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
        return minuteKey(start)
    }

    private func compactLocked(nowKey: Int) {
        let minuteCutoff = nowKey - Self.minuteRetention
        let old = minutes.keys.filter { $0 < minuteCutoff }
        for key in old {
            guard let bucket = minutes.removeValue(forKey: key) else { continue }
            let hourKey = Self.hourStartKey(of: key)
            var target = hours[hourKey] ?? [:]
            for (node, pair) in bucket {
                var sum = target[node] ?? Pair()
                sum.up &+= pair.up
                sum.down &+= pair.down
                target[node] = sum
            }
            hours[hourKey] = target
            dirty = true
        }
        let hourCutoff = nowKey - Self.hourRetention
        let expired = hours.keys.filter { $0 < hourCutoff }
        for key in expired { hours.removeValue(forKey: key); dirty = true }
    }

    // MARK: - Persistence

    /// Writes the buckets if anything changed. `wait` = on this thread (the app is quitting).
    func save(wait: Bool = false) {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        dirty = false
        lastSave = Date()
        let model = FileModel(version: Self.fileVersion,
                              minutes: Self.entries(minutes),
                              hours: Self.entries(hours))
        lock.unlock()

        let work = { [self] in
            if !write(model) {
                lock.lock(); dirty = true; lock.unlock()        // try again at the next save
            }
        }
        if wait { ioQueue.sync(execute: work) } else { ioQueue.async(execute: work) }
    }

    private static func entries(_ buckets: [Int: [String: Pair]]) -> [Entry] {
        buckets.map { key, bucket in
            var n: [String: [UInt64]] = [:]
            n.reserveCapacity(bucket.count)
            for (node, pair) in bucket { n[node] = [pair.up, pair.down] }
            return Entry(k: key, n: n)
        }
    }

    private func write(_ model: FileModel) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(model)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let model = try? JSONDecoder().decode(FileModel.self, from: data),
              model.version == Self.fileVersion else { return }
        func restore(_ list: [Entry]) -> [Int: [String: Pair]] {
            var out: [Int: [String: Pair]] = [:]
            out.reserveCapacity(list.count)
            for entry in list {
                var bucket: [String: Pair] = [:]
                for (node, values) in entry.n where values.count == 2 {
                    bucket[node] = Pair(up: values[0], down: values[1])
                }
                if !bucket.isEmpty { out[entry.k] = bucket }
            }
            return out
        }
        minutes = restore(model.minutes)
        hours = restore(model.hours)
    }
}
