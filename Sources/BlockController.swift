import Foundation

/// Decides when the root helper blocks, and keeps it told.
///
/// - VPN tunnel comes up: "disarm" is sent at once.
/// - VPN tunnel gone: "arm" is sent at once, from the thread that noticed it. No delay, no
///   waiting to see whether it comes back, no hop through the main thread.
/// - Master switch off: always disarmed.
/// - On launch, and whenever the helper (re)appears or restarts, the current state and rules
///   are sent again. A 2 s poll also catches drift (the helper reports another state or rule
///   count than intended) and fetches the helper's `block-*` events for the block log.
///
/// Everything that decides or sends is guarded by `lock` and runs on `sendQueue`, a serial queue
/// of its own (so requests reach the helper in order and never wait behind a status poll). A
/// failed send is repeated after 0.1 s, 0.2 s, 0.4 s ... The rest is main thread only.
final class BlockController {
    static let shared = BlockController()

    /// Posted on the main thread when `display` changed.
    static let changedNotification = Notification.Name("WardenHelperBlockControllerChanged")

    /// What the menu row shows.
    enum Display: Equatable {
        case off                    // not blocking (VPN on, switch off, no helper, nothing listed)
        case active(Int)            // blocking, N rules
        case failed                 // armed but the helper could not put the blocking in place
    }

    private(set) var display: Display = .off

    private enum Tunnel { case unknown, up, absent }

    private static let pollInterval: TimeInterval = 2.0
    private static let maxSendAttempts = 8

    // Guarded by `lock` (any thread).
    private let lock = NSLock()
    private var tunnel: Tunnel = .unknown
    private var desired: Bool?                     // nil until first decided
    private var latestRules: BlockRuleSet?         // what the rules store holds now
    private var confirmedRules: BlockRuleSet?      // what the helper acknowledged last
    private var pendingPushes = 0
    private var droppedAt: (date: Date, uptime: UInt64)?

    private let sendQueue = DispatchQueue(label: "warden-helper.block.send", qos: .userInteractive)

    // Main thread only.
    private var pollTimer: DispatchSourceTimer?
    private var pollInFlight = false
    private var reachable = false
    private var lastPID: Int32?
    private var lastSeq: Int?
    private var lastReply: HelperResponse?
    private var started = false

    private init() {}

    // MARK: - Public

    func start() {
        guard !started else { return }
        started = true
        lock.lock()
        latestRules = BlockRulesStore.shared.rules
        lock.unlock()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Preferences.changedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rulesChanged),
                                               name: BlockRulesStore.changedNotification, object: nil)
        evaluate("launch")                          // a switched-off setting is decided right away
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: Self.pollInterval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    /// The tunnel carrying public traffic changed (`nil` = no VPN). Any queue; sends the change to
    /// the helper before it returns.
    func tunnelChanged(_ interface: String?) {
        // No VPN: the switch is forced back to on before anything is decided, so the arm that
        // follows is not held back by a switch that was left off.
        if interface == nil, Preferences.shared.restoreBlockDefault() {
            BlockLog.shared.log("block-switch", "forced on (vpn-down)")
        }
        lock.lock()
        tunnel = interface != nil ? .up : .absent
        if interface == nil {
            droppedAt = (date: Date(), uptime: DispatchTime.now().uptimeNanoseconds)
        } else {
            droppedAt = nil
        }
        lock.unlock()
        if let interface = interface {
            BlockLog.shared.log("vpn-up", "interface=\(interface)")
            evaluate("vpn-up")
        } else {
            BlockLog.shared.log("vpn-down", "detected")
            evaluate("vpn-absent")
        }
    }

    // MARK: - Decision

    /// What the helper should be doing now; nil while it cannot be told yet. Under `lock`.
    private func computeDesiredLocked() -> Bool? {
        guard Preferences.shared.blockEnabled else { return false }
        switch tunnel {
        case .unknown: return nil
        case .up:      return false
        case .absent:  return true
        }
    }

    private func evaluate(_ reason: String) {
        lock.lock()
        guard let next = computeDesiredLocked(), next != desired else { lock.unlock(); return }
        desired = next
        pendingPushes += 1
        lock.unlock()
        send(reason, attempt: 0)
    }

    @objc private func settingsChanged() { evaluate("setting") }

    @objc private func rulesChanged() {
        let rules = BlockRulesStore.shared.rules
        lock.lock()
        latestRules = rules
        let needed = desired != nil && rules != confirmedRules
        if needed { pendingPushes += 1 }
        lock.unlock()
        if needed { send("rules", attempt: 0) }
    }

    private var currentDesired: Bool? {
        lock.lock(); defer { lock.unlock() }
        return desired
    }

    // MARK: - Sending

    /// One request to the helper. The state is read when the job runs, so a job that finds a newer
    /// decision simply sends that one. The caller has already counted it in `pendingPushes`.
    private func send(_ reason: String, attempt: Int) {
        sendQueue.async { [self] in
            lock.lock()
            guard let armed = desired else { pendingPushes -= 1; lock.unlock(); return }
            let latest = latestRules
            let rules: BlockRuleSet? = (latest == confirmedRules) ? nil : latest   // nil: helper keeps its own
            let dropped = droppedAt
            lock.unlock()

            let began = DispatchTime.now().uptimeNanoseconds
            BlockLog.shared.log("block-send", "armed=\(armed) rules=\(rules.map { String($0.count) } ?? "keep") reason=\(reason) attempt=\(attempt + 1)\(Self.since(dropped, armed: armed))")
            let result = HelperClient.applySync(armed: armed, rules: rules)
            let took = Double(DispatchTime.now().uptimeNanoseconds &- began) / 1_000_000

            switch result {
            case .success(let reply):
                lock.lock()
                if let rules = rules { confirmedRules = rules }
                pendingPushes -= 1
                lock.unlock()
                BlockLog.shared.log("block-sent", "armed=\(armed) helper_ms=\(String(format: "%.1f", took)) enforcement=\(reply.enforcement ?? "?")\(Self.since(dropped, armed: armed))")
                DispatchQueue.main.async { [self] in
                    lastReply = reply
                    recomputeDisplay()
                }
            case .failure(let failure):
                BlockLog.shared.log("block-send-failed", "reason=\(reason) attempt=\(attempt + 1) error=\(failure)")
                if armed && attempt + 1 < Self.maxSendAttempts {          // blocking is time-critical; a failed disarm waits for the poll
                    let delay = min(0.1 * Double(1 << attempt), 1.0)
                    sendQueue.asyncAfter(deadline: .now() + delay) { [self] in send(reason, attempt: attempt + 1) }
                } else {
                    lock.lock(); pendingPushes -= 1; lock.unlock()      // the 2 s poll takes over
                }
            }
        }
    }

    /// ` since_drop_ms=12.3` for an arm that follows a detected drop, else nothing.
    private static func since(_ dropped: (date: Date, uptime: UInt64)?, armed: Bool) -> String {
        guard armed, let dropped = dropped else { return "" }
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- dropped.uptime) / 1_000_000
        return " since_drop_ms=\(String(format: "%.1f", ms))"
    }

    // MARK: - Polling

    private func poll() {
        guard !pollInFlight else { return }
        pollInFlight = true
        let wantEvents = lastSeq != nil
        HelperClient.shared.events(since: wantEvents ? lastSeq : nil) { [weak self] result in
            guard let self = self else { return }
            self.pollInFlight = false
            switch result {
            case .failure:
                self.helperLost()
            case .success(let reply):
                self.helperAnswered(reply, askedForEvents: wantEvents)
            }
        }
    }

    private func helperLost() {
        guard reachable else { return }
        reachable = false
        lastReply = nil
        BlockLog.shared.log("block-helper", "lost")
        recomputeDisplay()
        HelperInstaller.shared.refresh()
    }

    private func helperAnswered(_ reply: HelperResponse, askedForEvents: Bool) {
        let appeared = !reachable
        reachable = true
        let restarted = lastPID != nil && reply.pid != lastPID
        let firstContact = lastPID == nil

        if appeared {
            BlockLog.shared.log("block-helper", "connected pid=\(reply.pid.map { String($0) } ?? "?") version=\(reply.version ?? 0) armed=\(reply.armed ?? false)")
            HelperInstaller.shared.refresh()
        }

        if restarted {
            // New process, new event numbers: start from its first event, on the next poll.
            BlockLog.shared.log("block-helper", "restarted pid=\(reply.pid.map { String($0) } ?? "?")")
            lastSeq = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.poll() }
        } else if askedForEvents, let events = reply.events {
            for event in events {
                let parts = event.text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard let tag = parts.first else { continue }
                let fields = parts.count > 1 ? String(parts[1]) : ""
                BlockLog.shared.log(String(tag), fields, at: Date(timeIntervalSince1970: Double(event.ms) / 1000))
            }
            if let last = events.last { lastSeq = last.seq }
        } else {
            lastSeq = reply.seq                      // first contact or logging off: no history
        }
        lastPID = reply.pid
        lastReply = reply

        // Tell the helper the state again when it (re)appeared, or when it disagrees.
        lock.lock()
        let armed = desired
        let idle = pendingPushes == 0
        if armed != nil && idle { pendingPushes += 1 }
        lock.unlock()
        if let armed = armed, idle {
            if appeared || restarted {
                forgetConfirmedRules()                  // send everything again
                send(firstContact ? "connect" : "reconnect", attempt: 0)
            } else if reply.armed != armed || Self.ruleCountDiffers(reply) {
                forgetConfirmedRules()
                send("drift", attempt: 0)
            } else {
                lock.lock(); pendingPushes -= 1; lock.unlock()
            }
        }
        recomputeDisplay()
    }

    private func forgetConfirmedRules() {
        lock.lock(); confirmedRules = nil; lock.unlock()
    }

    private static func ruleCountDiffers(_ reply: HelperResponse) -> Bool {
        guard let known = BlockRulesStore.shared.rules else { return false }
        return reply.ruleCount != known.count
    }

    // MARK: - Menu row

    private func recomputeDisplay() {
        var new: Display = .off
        if reachable, currentDesired == true, let reply = lastReply, reply.armed == true, (reply.ruleCount ?? 0) > 0 {
            switch reply.enforcement {
            case "failed": new = .failed
            case "pending": return                    // a moment; keep what is shown
            default: new = .active(reply.ruleCount ?? 0)
            }
        }
        guard new != display else { return }
        display = new
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }
}
