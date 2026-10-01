import Foundation

struct TrafficAmount {
    var up: UInt64 = 0
    var down: UInt64 = 0
}

/// Counts proxied traffic from the kernel's controller (`GET /connections`) instead of an
/// interface counter, so connections that leave through a Direct outbound are not counted.
/// Each poll adds only the growth of every connection's upload / download, keyed by connection
/// id. The tunnel state (`tunnelChanged`) decides when polling runs. Today / month totals are
/// saved to UserDefaults and roll over by calendar day / month; "session" is everything since
/// launch. State lives on one serial queue.
final class VPNTrafficTracker {
    static let shared = VPNTrafficTracker()

    struct Snapshot {
        let tunnel: String?
        let connectedSince: Date?
        let today: TrafficAmount
        let month: TrafficAmount
        let session: TrafficAmount
        let controller: ControllerState
    }

    private let queue = DispatchQueue(label: "warden-helper.vpntraffic", qos: .utility)
    private let defaults = UserDefaults.standard
    private static let prefix = "vpnTraffic."
    /// Bumped when the meaning of the stored totals changes; older totals are cleared once.
    private static let sourceVersion = 2

    private var tunnel: String?
    private var connectedSince: Date?

    private var controller: ControllerState = .idle
    private var seen: [String: (up: UInt64, down: UInt64)] = [:]   // last reading per connection id
    private var needBaseline = true       // the next good reading only records, it adds nothing
    private var speedReading: (up: Double, down: Double, at: UInt64)?   // proxied bytes per second, newest reading
    private var pollInFlight = false
    private var epoch = 0                 // bumped when the tunnel changes; stale replies are dropped

    // Diagnostics for the traffic log (queue only). None of it is saved or shown in the menu.
    private var lastPollTime: UInt64 = 0
    private var kernelPrev: (up: UInt64, down: UInt64)?
    private var tunPrev: (rx: UInt64, tx: UInt64)?
    private var diagDirect = TrafficAmount()
    private var diagUnknown = TrafficAmount()
    private var diagTun = TrafficAmount()
    private var diagMissed: (up: Int64, down: Int64) = (0, 0)
    private var lastSummary: UInt64 = 0
    private var lastLoggedState: ControllerState?
    private static let summaryInterval: UInt64 = 60_000_000_000 // 60 s, in ns

    private var session = TrafficAmount()
    private var today = TrafficAmount()
    private var month = TrafficAmount()
    private var dayKey = 0
    private var monthKey = 0
    private var dirty = false
    private var lastSave: UInt64 = 0
    private static let saveInterval: UInt64 = 30_000_000_000 // 30 s, in ns

    private init() {
        dayKey = defaults.integer(forKey: Self.prefix + "dayKey")
        monthKey = defaults.integer(forKey: Self.prefix + "monthKey")
        today = load("today")
        month = load("month")
        if defaults.integer(forKey: Self.prefix + "source") != Self.sourceVersion {
            // Totals from the interface counter also held direct traffic: start again once.
            today = TrafficAmount()
            month = TrafficAmount()
            defaults.set(Self.sourceVersion, forKey: Self.prefix + "source")
            dirty = true
            save()
        }
        rollover()
    }

    // MARK: - Inputs

    /// The tunnel carrying public traffic changed (nil = no VPN). Called by VPNStateMonitor.
    func tunnelChanged(_ name: String?) {
        queue.async { [self] in
            let wasUp = tunnel != nil
            if let name = name {
                if connectedSince == nil { connectedSince = Date() }
                if tunnel != name { restartReading() }
                if tunnel != name { TrafficLog.shared.log("tunnel", "up name=\(name)") }
                tunnel = name
                if !wasUp { ControllerClient.shared.tunnelChanged() }
            } else {
                if wasUp { logSummary(reason: "tunnel-down"); TrafficLog.shared.log("tunnel", "down") }
                tunnel = nil
                connectedSince = nil
                restartReading()
                controller = .idle
            }
        }
    }

    /// Ask the controller for one reading. Driven by NetworkMonitor's timer, so there is no extra
    /// wake-up; a reading that is still in flight is not asked for twice.
    func sample() {
        queue.async { [self] in
            guard tunnel != nil, !pollInFlight else { return }
            pollInFlight = true
            let mine = epoch
            ControllerClient.shared.poll { [weak self] result in
                self?.queue.async { self?.handle(result, epoch: mine) }
            }
        }
    }

    // MARK: - Outputs

    /// Proxied bytes per second from the newest controller reading, or nil when there is none
    /// (no tunnel, controller unavailable, first reading, or older than `maxAge` seconds).
    func currentProxySpeed(maxAge: Double) -> (up: UInt64, down: UInt64)? {
        queue.sync { () -> (up: UInt64, down: UInt64)? in
            guard tunnel != nil, let r = speedReading else { return nil }
            let age = Double(DispatchTime.now().uptimeNanoseconds &- r.at) / 1_000_000_000
            guard age <= maxAge else { return nil }
            return (UInt64(r.up.rounded()), UInt64(r.down.rounded()))
        }
    }

    func snapshot() -> Snapshot {
        queue.sync { () -> Snapshot in
            rollover()
            return Snapshot(tunnel: tunnel, connectedSince: connectedSince,
                            today: today, month: month, session: session, controller: controller)
        }
    }

    func reset() {
        queue.sync {
            today = TrafficAmount()
            month = TrafficAmount()
            session = TrafficAmount()
            diagDirect = TrafficAmount(); diagUnknown = TrafficAmount(); diagTun = TrafficAmount()
            diagMissed = (0, 0)
            dirty = true
            save()
            NodeTrafficStore.shared.clear()
            TrafficLog.shared.log("reset", "totals cleared by user")
        }
    }

    /// Write pending totals now (app is quitting).
    func flush() {
        queue.sync {
            rollover()
            save()
            NodeTrafficStore.shared.save(wait: true)
            if tunnel != nil { logSummary(reason: "quit") }
        }
        TrafficLog.shared.flush()
    }

    // MARK: - Private (queue only)

    private func restartReading() {
        epoch &+= 1
        seen = [:]
        needBaseline = true
        pollInFlight = false
        lastPollTime = 0
        kernelPrev = nil
        tunPrev = nil
        speedReading = nil
    }

    private func handle(_ result: Result<ControllerClient.PollData, ControllerFailure>, epoch mine: Int) {
        guard mine == epoch else { return }          // the tunnel changed while this was in flight
        pollInFlight = false
        guard tunnel != nil else { return }

        switch result {
        case .failure(let failure):
            controller = .unavailable(failure)
            logStateIfChanged()
            seen = [:]                               // long-lived connections must not be counted
            needBaseline = true                      // in full when the controller comes back
            speedReading = nil
            lastPollTime = 0
            kernelPrev = nil
            tunPrev = nil
        case .success(let data):
            controller = .connected(data.version)
            logStateIfChanged()
            let now = DispatchTime.now().uptimeNanoseconds
            let baselinePoll = needBaseline
            let elapsed = lastPollTime == 0 ? 1 : Double(now &- lastPollTime) / 1_000_000_000
            lastPollTime = now

            var proxy = TrafficAmount(), direct = TrafficAmount(), unknown = TrafficAmount()
            var perNode: [String: TrafficAmount] = [:]       // this reading's proxied growth, by node
            var opened: [ControllerClient.Sample] = []
            var next: [String: (up: UInt64, down: UInt64)] = [:]
            next.reserveCapacity(data.samples.count)
            for s in data.samples {
                next[s.id] = (s.upload, s.download)
                guard !baselinePoll else { continue }
                var du = s.upload, dd = s.download           // a connection opened since the last reading
                if let prev = seen[s.id] {
                    du = s.upload >= prev.up ? s.upload - prev.up : s.upload       // smaller = counter restarted
                    dd = s.download >= prev.down ? s.download - prev.down : s.download
                } else {
                    opened.append(s)
                }
                switch s.route {
                case .proxy:
                    proxy.up &+= du;   proxy.down &+= dd
                    let node = s.node.isEmpty ? L10n.nodeUnknown : s.node
                    var amount = perNode[node] ?? TrafficAmount()
                    amount.up &+= du;  amount.down &+= dd
                    perNode[node] = amount
                case .direct:  direct.up &+= du;  direct.down &+= dd
                case .unknown: unknown.up &+= du; unknown.down &+= dd
                }
            }
            let closed = baselinePoll ? 0 : seen.keys.filter { next[$0] == nil }.count
            seen = next
            needBaseline = false
            add(up: proxy.up, down: proxy.down, now: now)
            NodeTrafficStore.shared.add(perNode)             // same bytes as above, split by node
            if baselinePoll || elapsed <= 0 {
                speedReading = nil
            } else {
                speedReading = (Double(proxy.up) / elapsed, Double(proxy.down) / elapsed, now)
            }

            diagnose(data, baselinePoll: baselinePoll, elapsed: elapsed, now: now,
                     proxy: proxy, direct: direct, unknown: unknown, opened: opened, closed: closed)
        }
    }

    // MARK: - Traffic log (queue only)

    private func pair(_ a: TrafficAmount) -> String { "+\(a.up)/+\(a.down)" }
    private func total(_ a: TrafficAmount) -> String { "\(a.up)/\(a.down)" }
    private func signed(_ up: Int64, _ down: Int64) -> String { String(format: "%+lld/%+lld", up, down) }
    private func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "'") + "\"" }

    private func logStateIfChanged() {
        guard lastLoggedState != controller else { return }
        lastLoggedState = controller
        switch controller {
        case .connected(let version): TrafficLog.shared.log("state", "connected version=\(quoted(version))")
        case .unavailable(let failure): TrafficLog.shared.log("state", "unavailable reason=\(quoted(String(describing: failure)))")
        case .idle: TrafficLog.shared.log("state", "idle")
        }
    }

    /// Cross-checks one reading and writes it down. Three independent numbers per reading:
    /// - `proxy` / `direct` / `unknown`: what the per-connection growth said, split by route.
    /// - `kernel`: growth of the kernel's own totals (all connections, closed ones too).
    ///   `missed` = kernel - (proxy + direct + unknown): bytes of connections that closed between
    ///   two readings and so were never seen. Small = the count is complete.
    /// - `tun`: growth of the tunnel interface counters (with protocol overhead, so a few percent
    ///   above the payload numbers is normal).
    private func diagnose(_ data: ControllerClient.PollData, baselinePoll: Bool, elapsed: Double, now: UInt64,
                          proxy: TrafficAmount, direct: TrafficAmount, unknown: TrafficAmount,
                          opened: [ControllerClient.Sample], closed: Int) {
        guard TrafficLog.shared.enabled else { return }

        var kernel: (up: UInt64, down: UInt64)?
        var missed: (up: Int64, down: Int64)?
        if let ku = data.kernelUpload, let kd = data.kernelDownload {
            if !baselinePoll, let prev = kernelPrev, ku >= prev.up, kd >= prev.down {
                kernel = (ku - prev.up, kd - prev.down)
                let allUp = proxy.up &+ direct.up &+ unknown.up
                let allDown = proxy.down &+ direct.down &+ unknown.down
                missed = (Int64(clamping: kernel!.up) - Int64(clamping: allUp),
                          Int64(clamping: kernel!.down) - Int64(clamping: allDown))
            }
            kernelPrev = (ku, kd)
        } else {
            kernelPrev = nil
        }

        var tun: TrafficAmount?
        if let name = tunnel, let cur = NetworkInterfaceReader.counter(for: name) {
            if !baselinePoll, let prev = tunPrev {
                tun = TrafficAmount(up: NetworkMonitor.delta(cur.bytesOut, prev.tx, elapsed: elapsed),
                                    down: NetworkMonitor.delta(cur.bytesIn, prev.rx, elapsed: elapsed))
            }
            tunPrev = (cur.bytesIn, cur.bytesOut)
        } else {
            tunPrev = nil
        }

        let byRoute = Dictionary(grouping: data.samples, by: { $0.route }).mapValues { $0.count }
        if baselinePoll {
            TrafficLog.shared.log("baseline", "conns=\(data.samples.count) proxy=\(byRoute[.proxy] ?? 0) direct=\(byRoute[.direct] ?? 0) unknown=\(byRoute[.unknown] ?? 0) outbounds=\(data.outbounds) kernel_totals=\(data.kernelUpload != nil ? "yes" : "no") note=\"existing connections are not counted\"")
            lastSummary = now
            return
        }

        diagDirect.up &+= direct.up; diagDirect.down &+= direct.down
        diagUnknown.up &+= unknown.up; diagUnknown.down &+= unknown.down
        if let t = tun { diagTun.up &+= t.up; diagTun.down &+= t.down }
        if let m = missed { diagMissed.up += m.up; diagMissed.down += m.down }

        for s in opened {
            TrafficLog.shared.log("open", "id=\(s.id.prefix(8)) route=\(s.route.label) chains=\(quoted(s.chains.joined(separator: ">"))) target=\(quoted(s.target)) net=\(s.network) rule=\(quoted(s.rule)) up=\(s.upload) down=\(s.download)")
        }

        let quiet = proxy.up == 0 && proxy.down == 0 && direct.up == 0 && direct.down == 0
            && unknown.up == 0 && unknown.down == 0 && (kernel?.up ?? 0) == 0 && (kernel?.down ?? 0) == 0
            && opened.isEmpty && closed == 0
        if !quiet {
            var line = "dt=\(String(format: "%.3f", elapsed)) conns=\(data.samples.count) proxy=\(pair(proxy)) direct=\(pair(direct)) unknown=\(pair(unknown))"
            if let k = kernel { line += " kernel=\(pair(TrafficAmount(up: k.up, down: k.down)))" }
            if let m = missed { line += " missed=\(signed(m.up, m.down))" }
            if let t = tun { line += " tun=\(pair(t))" }
            line += " opened=\(opened.count) closed=\(closed)"
            TrafficLog.shared.log("poll", line)
        }

        if now &- lastSummary >= Self.summaryInterval { logSummary(reason: "60s") }
    }

    /// Running totals since launch, one line, so a long log can be read from its summaries.
    private func logSummary(reason: String) {
        lastSummary = DispatchTime.now().uptimeNanoseconds
        TrafficLog.shared.log("summary", "reason=\(reason) session_proxy=\(total(session)) session_direct=\(total(diagDirect)) session_unknown=\(total(diagUnknown)) session_missed=\(diagMissed.up)/\(diagMissed.down) session_tun=\(total(diagTun)) today=\(total(today)) month=\(total(month))")
    }

    private func add(up: UInt64, down: UInt64, now: UInt64) {
        guard up > 0 || down > 0 else { return }
        rollover()
        TrafficLog.shared.addVolume(up &+ down)          // the GB in this hour's log file name
        session.up &+= up;  session.down &+= down
        today.up &+= up;    today.down &+= down
        month.up &+= up;    month.down &+= down
        dirty = true
        if now &- lastSave >= Self.saveInterval { save() }
    }

    private func rollover() {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        guard let y = c.year, let m = c.month, let d = c.day else { return }
        let newDay = y * 10000 + m * 100 + d
        let newMonth = y * 100 + m
        if newDay != dayKey { dayKey = newDay; today = TrafficAmount(); dirty = true }
        if newMonth != monthKey { monthKey = newMonth; month = TrafficAmount(); dirty = true }
    }

    private func save() {
        lastSave = DispatchTime.now().uptimeNanoseconds
        guard dirty else { return }
        dirty = false
        defaults.set(dayKey, forKey: Self.prefix + "dayKey")
        defaults.set(monthKey, forKey: Self.prefix + "monthKey")
        store(today, "today")
        store(month, "month")
    }

    private func store(_ a: TrafficAmount, _ name: String) {
        defaults.set(Int(clamping: a.up), forKey: Self.prefix + name + ".up")
        defaults.set(Int(clamping: a.down), forKey: Self.prefix + name + ".down")
    }

    private func load(_ name: String) -> TrafficAmount {
        TrafficAmount(up: UInt64(max(0, defaults.integer(forKey: Self.prefix + name + ".up"))),
                      down: UInt64(max(0, defaults.integer(forKey: Self.prefix + name + ".down"))))
    }
}

/// Text helpers for the menu.
enum VPNInfoFormat {
    /// "0 B", "12.3 KB", "1.23 GB" (decimal units, like the speed display).
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var u = 0
        while v >= 999.5 && u < units.count - 1 { v /= 1000; u += 1 }
        let format = u == 0 ? "%.0f" : (v >= 99.95 ? "%.0f" : (v >= 9.995 ? "%.1f" : "%.2f"))
        return String(format: format, v) + " " + units[u]
    }

    /// "12 分 05 秒", "2 小时 14 分", "3 天 4 小时".
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let d = total / 86_400, h = (total % 86_400) / 3600
        let m = (total % 3600) / 60, s = total % 60
        if d > 0 { return "\(d) \(L10n.unitDay) \(h) \(L10n.unitHour)" }
        if h > 0 { return "\(h) \(L10n.unitHour) \(m) \(L10n.unitMinute)" }
        return "\(m) \(L10n.unitMinute) \(String(format: "%02d", s)) \(L10n.unitSecond)"
    }
}
