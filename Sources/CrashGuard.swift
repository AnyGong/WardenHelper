import Cocoa

/// Restarts the app after an unexpected exit (crash, kill -9), never after a normal quit.
///
/// While the setting is on, a tiny detached shell watcher waits for this process to disappear. If
/// the "clean exit" marker file for this pid exists (written on every orderly quit, including
/// log out / shut down and SIGTERM), it does nothing; otherwise it opens the app again. To avoid a
/// crash loop, it gives up after 3 restarts within 2 minutes.
final class CrashGuard {
    static let shared = CrashGuard()

    private var watcher: Process?
    private var termSource: DispatchSourceSignal?

    private var markerPath: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("warden-helper-clean-exit-\(getpid())")
    }
    private var historyPath: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("warden-helper-restarts.log")
    }

    private static let script = """
    pid="$1"; marker="$2"; app="$3"; hist="$4"
    while kill -0 "$pid" 2>/dev/null; do sleep 2; done
    if [ -e "$marker" ]; then rm -f "$marker"; exit 0; fi
    now=$(date +%s)
    echo "$now" >> "$hist"
    recent=$(awk -v n="$now" '$1 > n - 120' "$hist" | wc -l)
    tail -n 10 "$hist" > "$hist.tmp" && mv "$hist.tmp" "$hist"
    if [ "$recent" -le 3 ]; then sleep 1; /usr/bin/open "$app"; fi
    """

    /// Call once at launch: SIGTERM (`pkill`, `make run`) counts as a deliberate quit.
    func installTerminationHandler(_ onTerminate: @escaping () -> Void) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { onTerminate() }
        source.resume()
        termSource = source
    }

    /// Starts or stops the watcher to match the setting.
    func apply() {
        if Preferences.shared.restartOnCrash { start() } else { stop() }
    }

    private func start() {
        guard watcher?.isRunning != true else { return }
        try? FileManager.default.removeItem(atPath: markerPath)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", Self.script, "warden-helper-watch",
                       String(getpid()), markerPath, Bundle.main.bundlePath, historyPath]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); watcher = p } catch { watcher = nil }
    }

    private func stop() {
        if let w = watcher, w.isRunning { w.terminate() }
        watcher = nil
    }

    /// Every orderly exit: tells the watcher not to restart.
    func markCleanExit() {
        FileManager.default.createFile(atPath: markerPath, contents: Data())
    }
}
