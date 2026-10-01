import Foundation

/// Samples interface byte counters and reports per-second up / down speeds, computed from the
/// real elapsed time, per interface, tolerating 32-bit counter wrap.
final class NetworkMonitor {

    /// Called on the main thread with formatted (upload, download) speeds, e.g. "12 KB/s".
    var onSpeedUpdate: ((String, String) -> Void)?

    /// Called on the monitor's queue once per timer tick (used to drive VPN traffic totals).
    var onTick: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "warden-helper.networkmonitor", qos: .utility)

    // Touched on `queue` only.
    private var last: [String: NetworkInterfaceReader.Counters] = [:]
    private var lastTime: UInt64 = 0
    private var lastShown: (up: String, down: String)?
    private var interval: Double = 1.0

    func start(interval: Double = 1.0) {
        stop()
        self.interval = interval
        queue.sync { // fresh baseline: the first sample must not span a pause
            last = [:]
            lastTime = 0
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        defer { onTick?() }
        let now = DispatchTime.now().uptimeNanoseconds
        let current = NetworkInterfaceReader.counters(locked: Preferences.shared.lockedInterface)

        // Proxy-node speed: while the switch is on and the controller gave a fresh reading, that
        // reading is shown. The interface baseline keeps moving, so switching back (or a missing
        // reading) shows a correct interface speed at once, never a spike.
        if Preferences.shared.speedFromProxy,
           let proxy = VPNTrafficTracker.shared.currentProxySpeed(maxAge: interval * 2 + 1) {
            last = current
            lastTime = now
            publish(up: proxy.up, down: proxy.down)
            return
        }

        guard lastTime != 0 else {           // first sample: baseline only
            last = current
            lastTime = now
            publish(up: 0, down: 0)
            return
        }

        let elapsed = Double(now - lastTime) / 1_000_000_000
        guard elapsed >= 0.05 else { return } // duplicate timer fire

        var deltaIn: UInt64 = 0
        var deltaOut: UInt64 = 0
        for (name, cur) in current {
            guard let prev = last[name] else { continue } // new interface: baseline only
            deltaIn &+= Self.delta(cur.bytesIn, prev.bytesIn, elapsed: elapsed)
            deltaOut &+= Self.delta(cur.bytesOut, prev.bytesOut, elapsed: elapsed)
        }

        last = current
        lastTime = now
        publish(up: UInt64((Double(deltaOut) / elapsed).rounded()),
                down: UInt64((Double(deltaIn) / elapsed).rounded()))
    }

    private static let counterWrap: UInt64 = 1 << 32

    /// Bytes moved since `prev`, tolerating 32-bit wrap-around and counter resets.
    static func delta(_ cur: UInt64, _ prev: UInt64, elapsed: Double) -> UInt64 {
        if cur >= prev { return cur - prev }
        // Wrapped or reset: a wrap is plausible only if `prev` was within one interval of traffic of the top.
        let maxPlausible = UInt64(1_500_000_000 * max(elapsed, 0.1))
        if prev < counterWrap, prev + maxPlausible >= counterWrap {
            return counterWrap - prev + cur
        }
        return cur
    }

    private func publish(up: UInt64, down: UInt64) {
        let upText = Self.formatSpeed(up)
        let downText = Self.formatSpeed(down)
        if let shown = lastShown, shown.up == upText, shown.down == downText { return } // nothing to redraw
        lastShown = (upText, downText)
        DispatchQueue.main.async { [weak self] in
            self?.onSpeedUpdate?(upText, downText)
        }
    }

    /// Compact format ("0 B/s", "9.9 KB/s", "123 MB/s") - at most 8 characters,
    /// which keeps the menu bar item narrow.
    private static func formatSpeed(_ bytes: UInt64) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = Double(bytes)
        var unit = 0
        while value >= 999.5 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let number = (unit == 0 || value >= 9.95) ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(number) \(units[unit])"
    }
}
