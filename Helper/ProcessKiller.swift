import Foundation
import Darwin

/// Ends the processes named in the rules while the helper is armed. A 1 s timer lists the
/// running processes with libproc (not `ps`) and matches the name exactly, or the executable
/// path (`process_path`: the path itself, or anything running from inside that folder / app
/// bundle). A match gets SIGTERM, and SIGKILL if it is still there 2 s later. PID 1, the helper
/// itself, every name in `BlockRuleValidator.protectedProcessNames` (WardenHelper included) and every
/// program under `protectedPaths` are never touched.
final class ProcessKiller {

    private enum Stage {
        case terminated(Date)
        case killed(Date)
    }

    private let queue = DispatchQueue(label: "warden-helper.daemon.killer")
    private var timer: DispatchSourceTimer?
    private var names = Set<String>()
    private var paths: [String] = []
    private var needsPath = false                 // path rules, or a name longer than proc_name reports
    private var stages: [pid_t: Stage] = [:]

    // MARK: Control

    func start(names newNames: [String], paths newPaths: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.names = Set(newNames)
            self.paths = newPaths
            // proc_name reports at most 31 characters; longer names are compared with the
            // last component of the executable path instead.
            self.needsPath = !newPaths.isEmpty || newNames.contains { $0.utf8.count > 31 }
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
            helperLog("block-kill watching \(newNames.count) name(s), \(newPaths.count) path(s)")
        }
    }

    func stop() {
        queue.async {
            guard let t = self.timer else { return }
            t.cancel()
            self.timer = nil
            self.names = []
            self.paths = []
            self.stages = [:]
            helperLog("block-kill stopped")
        }
    }

    // MARK: One pass

    private func tick() {
        let now = Date()
        let me = getpid()
        var present = Set<pid_t>()

        for pid in Self.allPIDs() where pid > 1 && pid != me {
            guard let matched = match(pid) else { continue }
            if BlockRuleValidator.protectedProcessNames.contains(matched.lowercased()) { continue }
            present.insert(pid)

            switch stages[pid] {
            case nil:
                deliver(pid, SIGTERM, name: matched)
                stages[pid] = .terminated(now)
            case .terminated(let at)? where now.timeIntervalSince(at) >= 2:
                deliver(pid, SIGKILL, name: matched)
                stages[pid] = .killed(now)
            case .killed(let at)? where now.timeIntervalSince(at) >= 5:
                deliver(pid, SIGKILL, name: matched)          // still there: try again
                stages[pid] = .killed(now)
            default:
                break
            }
        }
        // Gone (or the pid was reused by something else): forget it.
        stages = stages.filter { present.contains($0.key) }
    }

    /// The name to report when this process is covered by a rule, nil when it is not.
    private func match(_ pid: pid_t) -> String? {
        if let name = Self.name(of: pid), names.contains(name) { return name }
        guard needsPath, let path = Self.path(of: pid) else { return nil }
        let base = (path as NSString).lastPathComponent
        if names.contains(base) { return base }
        if BlockRuleValidator.isProtectedPath(path) { return nil }
        for rule in paths where path == rule || path.hasPrefix(rule + "/") { return base }
        return nil
    }

    private func deliver(_ pid: pid_t, _ sig: Int32, name: String) {
        let label = sig == SIGKILL ? "KILL" : "TERM"
        if kill(pid, sig) == 0 {
            helperLog("block-kill name=\(name) pid=\(pid) signal=\(label)")
        } else {
            helperLog("block-kill-failed name=\(name) pid=\(pid) signal=\(label) error=\(String(cString: strerror(errno)))")
        }
    }

    // MARK: libproc

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)                  // a count of pids
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        return pids.prefix(Int(got)).filter { $0 > 0 }
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
