import Cocoa

/// A plain-text log that starts a new file at every full local hour:
/// `<directory>/2026-06-01_12:00-13:00.log` for 12:00 to 13:00. Lines are `stamp tag fields`.
///
/// With `volumeInName` the file is renamed when its hour is over (or, after a quit or crash,
/// the next time the app starts) to `2026-06-01_12:00-13:00_1.235GB.log`: the VPN traffic
/// counted during that hour, in GB (1 GB = 1000³ bytes). While the hour is running the file has
/// no size in its name, because the number is not known yet.
///
/// Files are readable by this user only (0600). Nothing is deleted here.
final class HourlyLog {

    let directory: URL

    private let volumeInName: Bool
    private let isEnabled: () -> Bool
    private let queue: DispatchQueue

    // `queue` only.
    private var handle: FileHandle?
    private var openStart: Date?
    private var openPrefix: String?
    private var volume: UInt64 = 0
    private var startedUp = false

    private let stamp: DateFormatter
    private let startFormat: DateFormatter
    private let endFormat: DateFormatter

    init(subfolder: String, volumeInName: Bool, label: String, isEnabled: @escaping () -> Bool) {
        self.directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WardenHelper/\(subfolder)", isDirectory: true)
        self.volumeInName = volumeInName
        self.isEnabled = isEnabled
        self.queue = DispatchQueue(label: "warden-helper.hourlylog.\(label)", qos: .utility)

        func formatter(_ pattern: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = pattern
            return f
        }
        stamp = formatter("yyyy-MM-dd HH:mm:ss.SSS")
        startFormat = formatter("yyyy-MM-dd_HH:mm")
        endFormat = formatter("HH:mm")
    }

    var enabled: Bool { isEnabled() }

    // MARK: - Public (any thread)

    /// Adds `tag fields` with a time stamp. `fields` is only built when logging is on.
    /// `date` is for lines that happened earlier (the helper's events); default is now. The line
    /// goes into the file of the hour it happened in.
    func log(_ tag: String, _ fields: @autoclosure () -> String = "", at date: Date? = nil) {
        guard isEnabled() else { return }
        let text = fields()
        let when = date ?? Date()
        queue.async { [self] in
            let line = stamp.string(from: when) + " " + tag + (text.isEmpty ? "" : " " + text) + "\n"
            append(line, at: when)
        }
    }

    /// VPN bytes counted just now; they end up in the size in the file name.
    func addVolume(_ bytes: UInt64) {
        guard volumeInName, bytes > 0, isEnabled() else { return }
        queue.async { [self] in
            startUpIfNeeded()
            let current = Self.hourStart(of: Date())
            rollIfNeeded(to: current)
            if handle == nil { openFile(for: current) }     // so the volume belongs to an open hour
            volume &+= bytes
        }
    }

    /// Everything queued so far is on disk when this returns (the app is quitting). The open
    /// hour keeps its name; a later start names it.
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    /// Show the newest file in Finder (the folder when there is none yet). Main thread.
    func reveal() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let newest = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "log" }
            .max { $0.lastPathComponent < $1.lastPathComponent }
        if let newest = newest {
            NSWorkspace.shared.activateFileViewerSelecting([newest])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    // MARK: - Private (queue only)

    private static func hourStart(of date: Date) -> Date {
        Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
    }

    private func prefix(for start: Date) -> String {
        let end = Calendar.current.dateInterval(of: .hour, for: start)?.end ?? start.addingTimeInterval(3600)
        return startFormat.string(from: start) + "-" + endFormat.string(from: end)
    }

    private func append(_ line: String, at date: Date) {
        startUpIfNeeded()
        let start = Self.hourStart(of: date)
        let current = Self.hourStart(of: Date())
        let data = Data(line.utf8)

        if start < current {
            // A line of an earlier hour that arrived late (the helper's events come in batches).
            if start == openStart, let h = handle {
                try? h.write(contentsOf: data)              // that hour is still the open file
            } else {
                writeToEarlierHour(data, start: start)
            }
            return
        }
        rollIfNeeded(to: current)
        if handle == nil { openFile(for: current) }
        guard let h = handle else { return }
        do {
            try h.write(contentsOf: data)
        } catch {
            handle = nil                                  // reopened on the next line
        }
    }

    /// Closes the open hour (and names it) when the clock has moved on.
    private func rollIfNeeded(to current: Date) {
        guard let open = openStart, open < current else { return }
        finishOpenFile()
    }

    private func openFile(for start: Date) {
        let fm = FileManager.default
        let name = prefix(for: start)
        let url = directory.appendingPathComponent(name + ".log")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var reopened = true
            if !fm.fileExists(atPath: url.path) {
                reopened = false
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            handle = h
            openStart = start
            openPrefix = name
            // The app was restarted within this hour: carry on from what the file already says.
            volume = (volumeInName && reopened) ? Self.countedVolume(in: url) : 0
            scheduleRoll(after: start)
        } catch {
            handle = nil
        }
    }

    /// Names the file soon after its hour ends, even if nothing more is logged.
    private func scheduleRoll(after start: Date) {
        let end = Calendar.current.dateInterval(of: .hour, for: start)?.end ?? start.addingTimeInterval(3600)
        let wait = max(1, end.timeIntervalSinceNow + 1)
        queue.asyncAfter(deadline: .now() + wait) { [self] in
            rollIfNeeded(to: Self.hourStart(of: Date()))
        }
    }

    /// Closes the file of the hour that is over and puts the traffic volume into its name.
    private func finishOpenFile() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        if volumeInName, let name = openPrefix {
            Self.renameWithVolume(directory: directory, prefix: name, volume: volume)
        }
        openStart = nil
        openPrefix = nil
        volume = 0
    }

    private func writeToEarlierHour(_ data: Data, start: Date) {
        let fm = FileManager.default
        let name = prefix(for: start)
        // Already named with its volume? Then that file; otherwise the plain one (created if needed).
        let existing = (try? fm.contentsOfDirectory(atPath: directory.path))?
            .first { $0 == name + ".log" || $0.hasPrefix(name + "_") }
        let url = directory.appendingPathComponent(existing ?? name + ".log")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            try h.write(contentsOf: data)
            try h.close()
        } catch {
            // A late line is not worth more than this.
        }
    }

    /// Once per run: hours that were left open (quit, crash, sleep) get their volume in the name.
    private func startUpIfNeeded() {
        guard !startedUp else { return }
        startedUp = true
        guard volumeInName else { return }
        let fm = FileManager.default
        let currentName = prefix(for: Self.hourStart(of: Date()))
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for file in names where file.hasSuffix(".log") {
            let base = String(file.dropLast(4))
            // Plain hour files only: "2026-06-01_12:00-13:00" (22 characters).
            guard base.count == 22, base != currentName, base < currentName else { continue }
            let url = directory.appendingPathComponent(file)
            Self.renameWithVolume(directory: directory, prefix: base, volume: Self.countedVolume(in: url))
        }
    }

    // MARK: - Helpers

    /// `prefix.log` becomes `prefix_1.235GB.log`. Never overwrites a file.
    private static func renameWithVolume(directory: URL, prefix: String, volume: UInt64) {
        let fm = FileManager.default
        let from = directory.appendingPathComponent(prefix + ".log")
        guard fm.fileExists(atPath: from.path) else { return }
        let gb = String(format: "%.3f", Double(volume) / 1_000_000_000)
        let to = directory.appendingPathComponent("\(prefix)_\(gb)GB.log")
        guard !fm.fileExists(atPath: to.path) else { return }
        try? fm.moveItem(at: from, to: to)
    }

    /// VPN bytes (up + down) the file's `poll` lines say were counted: `proxy=+up/+down`.
    private static func countedVolume(in url: URL) -> UInt64 {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        let text = String(decoding: data, as: UTF8.self)
        var total: UInt64 = 0
        for line in text.split(separator: "\n") where line.contains(" poll ") {
            guard let range = line.range(of: " proxy=+") else { continue }
            let rest = line[range.upperBound...].prefix { $0 != " " }
            let parts = rest.split(separator: "/")
            guard parts.count == 2 else { continue }
            let up = UInt64(parts[0]) ?? 0
            let down = UInt64(parts[1].drop { $0 == "+" }) ?? 0
            total &+= up &+ down
        }
        return total
    }
}
