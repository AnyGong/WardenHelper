import Cocoa

/// Plain-text log of how VPN traffic was counted, for checking the numbers afterwards.
/// One file per full hour in `~/Library/Logs/WardenHelper/traffic/` (see `HourlyLog`):
/// `2026-09-30_21:00-22:00_1.235GB.log`, the number being the VPN traffic counted in that hour
/// (the running hour has no number yet). One line per event:
/// `2026-09-30 21:04:05.123 poll dt=1.002 conns=12 proxy=+1200/+45000 ...` - `key=up/down` pairs
/// are bytes, `+` marks growth since the previous reading.
/// Off with 设置 > VPN > 记录流量日志.
final class TrafficLog {
    static let shared = TrafficLog()

    private let hourly = HourlyLog(subfolder: "traffic", volumeInName: true, label: "traffic") {
        Preferences.shared.logTraffic
    }

    private init() {}

    var enabled: Bool { hourly.enabled }

    /// Adds `tag fields` with a time stamp. `fields` is only built when logging is on.
    func log(_ tag: String, _ fields: @autoclosure () -> String = "", at date: Date? = nil) {
        hourly.log(tag, fields(), at: date)
    }

    /// VPN bytes that were just counted (up + down); they make up the GB in the file name.
    func addVolume(_ bytes: UInt64) { hourly.addVolume(bytes) }

    /// Everything queued so far is on disk when this returns (the app is quitting).
    func flush() { hourly.flush() }

    /// Show the newest file in Finder. Main thread.
    func reveal() { hourly.reveal() }
}

/// Log of the blocking: when the VPN dropped, when the helper was told, and when each kind of
/// blocking was in place, with the milliseconds in between. One file per full hour in
/// `~/Library/Logs/WardenHelper/block/` (`2026-09-30_21:00-22:00.log`). Always on: it is small, and it
/// is the record of whether the blocking was there in time.
final class BlockLog {
    static let shared = BlockLog()

    private let hourly = HourlyLog(subfolder: "block", volumeInName: false, label: "block") { true }

    private init() {}

    func log(_ tag: String, _ fields: @autoclosure () -> String = "", at date: Date? = nil) {
        hourly.log(tag, fields(), at: date)
    }

    func flush() { hourly.flush() }

    /// Show the newest file in Finder. Main thread.
    func reveal() { hourly.reveal() }
}
