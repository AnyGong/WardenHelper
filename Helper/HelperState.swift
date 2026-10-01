import Foundation
import Darwin

/// One line to stderr; launchd sends it to `BlockIPC.logPath`.
func helperLog(_ message: String) {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    fputs("\(f.string(from: Date())) \(message)\n", stderr)
    if message.hasPrefix("block-") { EventLog.record(message) }
}

/// The `block-*` log lines of this run, kept in memory (newest 500) so WardenHelper can fetch them
/// with an `events` request and write them into the block log.
enum EventLog {
    private static let lock = NSLock()
    private static var items: [HelperEvent] = []
    private static var nextSeq = 1
    private static let capacity = 500

    static func record(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        items.append(HelperEvent(seq: nextSeq, ms: ms, text: String(text.prefix(300))))
        nextSeq += 1
        if items.count > capacity { items.removeFirst(items.count - capacity) }
    }

    static var lastSeq: Int {
        lock.lock(); defer { lock.unlock() }
        return nextSeq - 1
    }

    static func since(_ seq: Int, limit: Int = 100) -> [HelperEvent] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.filter { $0.seq > seq }.prefix(limit))
    }
}

/// The helper's state: armed or not, and the rules. Everything runs on one serial queue.
/// The state is kept and persisted here; the blocking itself (DNS sinkhole, pf anchor,
/// process killer) is done by `Enforcer`, off this queue.
final class Engine {

    private let queue = DispatchQueue(label: "warden-helper.daemon.engine")
    private var armed = false
    private var rules = BlockRuleSet.empty
    private let enforcer = Enforcer()

    private struct Saved: Codable {
        var armed: Bool
        var rules: [BlockRule]
    }

    private static var statePath: String { BlockIPC.stateDirectory + "/state.json" }

    // MARK: Lifecycle

    /// Loads what the previous run saved and applies it again (a reboot or a crash restores
    /// the same state).
    func start() {
        queue.sync {
            loadSaved()
            helperLog("start armed=\(armed) rules=\(rules.count)")
            enforce(reason: "start")
        }
    }

    /// `warden-helper-daemon --restore`: put back everything the helper changed (DNS settings, pf
    /// anchor and token) and forget the saved state.
    static func restoreAll() -> Bool {
        let ok = Enforcer.restoreAll()
        helperLog("restore: \(ok ? "done" : "incomplete")")
        return ok
    }

    // MARK: Requests

    func handle(_ request: HelperRequest) -> HelperResponse {
        return queue.sync { () -> HelperResponse in
            switch request.type {
            case "status":
                return statusReply()
            case "events":
                var reply = statusReply()
                if let since = request.since { reply.events = EventLog.since(max(0, since)) }
                return reply
            case "apply":
                guard let wantArmed = request.armed else {
                    return HelperResponse(ok: false, error: "apply needs \"armed\"")
                }
                var newRules = rules
                if let incoming = request.rules {
                    switch Self.validated(incoming) {
                    case .success(let set): newRules = set
                    case .failure(let why):
                        helperLog("apply rejected: \(why.message)")
                        return HelperResponse(ok: false, error: why.message)   // nothing changed
                    }
                }
                let changed = wantArmed != armed || newRules != rules
                armed = wantArmed
                rules = newRules
                if changed {
                    helperLog("block-apply armed=\(armed) rules=\(rules.count)")
                    enforce(reason: "apply")                  // blocking first, saving after
                    save()
                } else if enforcer.needsRetry {
                    enforce(reason: "resend")             // the last attempt did not fully work
                }
                return statusReply()
            default:
                return HelperResponse(ok: false, error: "unknown request type")
            }
        }
    }

    private func statusReply() -> HelperResponse {
        HelperResponse(ok: true, error: nil, version: BlockIPC.helperVersion,
                       armed: armed, ruleCount: rules.count, pid: getpid(),
                       enforcement: enforcer.status, seq: EventLog.lastSeq, events: nil)
    }

    // MARK: Validation (again, whatever WardenHelper already checked)

    /// The helper trusts nothing it is sent: every rule goes through the same validator WardenHelper
    /// uses, and the normalised value is what is kept. One bad rule rejects the whole message.
    private struct Rejection: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static func validated(_ list: [BlockRule]) -> Result<BlockRuleSet, Rejection> {
        guard list.count <= BlockLimits.maxEntries else { return .failure(Rejection("too many rules")) }
        var out: [BlockRule] = []
        out.reserveCapacity(list.count)
        for rule in list {
            switch BlockRuleValidator.normalize(rule.value, kind: rule.kind) {
            case .success(let value): out.append(BlockRule(kind: rule.kind, value: value))
            case .failure(let issue): return .failure(Rejection("invalid \(rule.kind.rawValue) rule: \(issue)"))
            }
        }
        return .success(BlockRuleSet(rules: out))
    }

    // MARK: Enforcement

    private func enforce(reason: String) {
        enforcer.apply(armed: armed, rules: rules, reason: reason)
    }

    // MARK: Persistence (/var/db/warden-helper/state.json, root only)

    private func loadSaved() {
        guard let data = FileManager.default.contents(atPath: Self.statePath) else { return }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data),
              case .success(let set) = Self.validated(saved.rules) else {
            helperLog("saved state is unreadable; starting disarmed with no rules")
            return
        }
        armed = saved.armed
        rules = set
    }

    private func save() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: BlockIPC.stateDirectory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Saved(armed: armed, rules: rules.rules))
            try data.write(to: URL(fileURLWithPath: Self.statePath), options: .atomic)
            chmod(Self.statePath, 0o600)
        } catch {
            helperLog("could not save state: \(error.localizedDescription)")
        }
    }
}
