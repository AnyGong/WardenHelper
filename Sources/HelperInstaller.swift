import Cocoa
import CryptoKit

/// Installs, updates and removes the root helper, and tells the rest of the app which of those
/// states it is in. Root is needed only here: one admin-password prompt (AppleScript
/// `with administrator privileges`, run through `osascript`) per install, update or uninstall.
final class HelperInstaller {
    static let shared = HelperInstaller()

    /// Posted on the main thread when `state`, `isBusy` or `lastError` changed.
    static let changedNotification = Notification.Name("WardenHelperHelperStateChanged")

    enum State: Equatable {
        case unknown            // not checked yet
        case notInstalled       // 未安装
        case installed          // 已安装: running, and not older than the bundled one
        case needsUpdate        // 需要更新: older, or installed but not answering
    }

    enum InstallError: Error, Equatable {
        case cancelled
        case missingHelper
        case failed(String)
    }

    private(set) var state: State = .unknown
    private(set) var isBusy = false
    /// The last install / update / uninstall failure; cleared by the next attempt or refresh.
    private(set) var lastError: String?

    private init() {}

    /// The helper binary inside the app (built by the Makefile). Nil when WardenHelper runs unbundled.
    var bundledHelperURL: URL? { Bundle.main.url(forResource: "warden-helper-daemon", withExtension: nil) }

    // MARK: State

    /// Asks the running helper (if any) for its version. Cheap; call when the settings page opens
    /// and after every install / update / uninstall.
    func refresh() {
        let binaryExists = FileManager.default.fileExists(atPath: BlockIPC.installedBinary)
        HelperClient.shared.status { [weak self] result in
            guard let self = self else { return }
            let new: State
            switch result {
            case .success(let reply):
                new = (reply.version ?? 0) >= BlockIPC.helperVersion ? .installed : .needsUpdate
            case .failure:
                new = binaryExists ? .needsUpdate : .notInstalled
            }
            self.setState(new)
        }
    }

    private func setState(_ new: State, error: String?? = nil, busy: Bool? = nil) {
        var changed = false
        if state != new { state = new; changed = true }
        if let error = error, lastError != error { lastError = error; changed = true }
        if let busy = busy, isBusy != busy { isBusy = busy; changed = true }
        if changed { NotificationCenter.default.post(name: Self.changedNotification, object: self) }
    }

    // MARK: Install / update / uninstall

    /// Install or update: the same steps, the bundled helper replaces whatever is there.
    func install() {
        guard !isBusy else { return }
        guard let source = bundledHelperURL, let hash = Self.sha256Hex(of: source) else {
            setState(state, error: .some(L10n.helperMissingBundled))
            return
        }
        setState(state, error: .some(nil), busy: true)
        let script = Self.installScript(source: source.path, sha256: hash, userID: getuid())
        Self.runPrivileged(script, prompt: L10n.helperInstallPrompt) { [weak self] result in
            self?.finish(result)
        }
    }

    func uninstall() {
        guard !isBusy else { return }
        setState(state, error: .some(nil), busy: true)
        Self.runPrivileged(Self.uninstallScript(), prompt: L10n.helperUninstallPrompt) { [weak self] result in
            self?.finish(result)
        }
    }

    private func finish(_ result: Result<Void, InstallError>) {
        switch result {
        case .success:
            setState(state, error: .some(nil), busy: false)
        case .failure(.cancelled):
            setState(state, error: .some(nil), busy: false)
        case .failure(.missingHelper):
            setState(state, error: .some(L10n.helperMissingBundled), busy: false)
        case .failure(.failed(let why)):
            setState(state, error: .some(L10n.helperFailed(why)), busy: false)
        }
        // The new daemon needs a moment to open its socket.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
    }

    // MARK: Scripts

    /// Every value put into these scripts is a constant of this program, an integer, a file
    /// path from the app bundle (single-quoted for the shell) or a SHA-256 hex string.
    /// Nothing typed by the user ever reaches a shell.
    private static func installScript(source: String, sha256: String, userID: uid_t) -> String {
        let bin = shellQuote(BlockIPC.installedBinary)
        let staged = shellQuote(BlockIPC.installedBinary + ".new")
        let plistPath = shellQuote(BlockIPC.launchDaemonPlist)
        let label = BlockIPC.label
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key>
        <array>
        <string>\(BlockIPC.installedBinary)</string>
        <string>--daemon</string>
        <string>--uid</string>
        <string>\(userID)</string>
        </array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>StandardOutPath</key><string>\(BlockIPC.logPath)</string>
        <key>StandardErrorPath</key><string>\(BlockIPC.logPath)</string>
        </dict>
        </plist>
        """
        return [
            "set -e",
            "/bin/mkdir -p /Library/PrivilegedHelperTools \(shellQuote(BlockIPC.stateDirectory))",
            "/bin/chmod 700 \(shellQuote(BlockIPC.stateDirectory))",
            // Copy next to the target, and check the copy is the file WardenHelper hashed before asking.
            "/usr/bin/install -m 755 -o root -g wheel \(shellQuote(source)) \(staged)",
            "if [ \"$(/usr/bin/shasum -a 256 \(staged) | /usr/bin/cut -d' ' -f1)\" != \(shellQuote(sha256)) ]; then "
                + "/bin/rm -f \(staged); echo 'checksum mismatch' >&2; exit 1; fi",
            "/bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true",
            "/bin/mv -f \(staged) \(bin)",
            "/bin/cat > \(plistPath) <<'WARDEN_HELPER_PLIST'",
            plist,
            "WARDEN_HELPER_PLIST",
            "/usr/sbin/chown root:wheel \(plistPath)",
            "/bin/chmod 644 \(plistPath)",
            "/bin/launchctl bootstrap system \(plistPath)",
            "/bin/launchctl kickstart -k system/\(label)",
        ].joined(separator: "\n")
    }

    /// The daemon is stopped first (so it cannot re-apply anything), then `--restore` puts back
    /// what it changed. If that fails, the daemon is started again and nothing is removed:
    /// better a helper still running than a Mac whose DNS points at nothing.
    private static func uninstallScript() -> String {
        let bin = shellQuote(BlockIPC.installedBinary)
        let plistPath = shellQuote(BlockIPC.launchDaemonPlist)
        let label = BlockIPC.label
        return [
            "/bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true",
            "if [ -x \(bin) ] && ! \(bin) --restore; then",
            "  /bin/launchctl bootstrap system \(plistPath) >/dev/null 2>&1 || true",
            "  echo 'restore failed' >&2",
            "  exit 1",
            "fi",
            "/bin/rm -f \(plistPath) \(bin) \(bin).new \(shellQuote(BlockIPC.socketPath))",
            "/bin/rm -rf \(shellQuote(BlockIPC.stateDirectory))",
        ].joined(separator: "\n")
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + escaped + "\""
    }

    private static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Running with administrator privileges

    /// `osascript` shows the system password dialog. It runs on a background thread, so the menu
    /// bar stays responsive; `completion` is called on the main thread.
    private static func runPrivileged(_ script: String, prompt: String,
                                      completion: @escaping (Result<Void, InstallError>) -> Void) {
        let source = "do shell script \(appleScriptQuote(script)) with prompt \(appleScriptQuote(prompt)) "
            + "with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            let result: Result<Void, InstallError>
            do {
                try process.run()
                let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                                       encoding: .utf8) ?? ""
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    result = .success(())
                } else if errorText.contains("(-128)") {
                    result = .failure(.cancelled)                   // the user closed the dialog
                } else {
                    result = .failure(.failed(summary(of: errorText)))
                }
            } catch {
                result = .failure(.failed(error.localizedDescription))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// `execution error: restore failed (1)` -> `restore failed`; long output is cut.
    private static func summary(of stderr: String) -> String {
        var text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "execution error: ") { text = String(text[range.upperBound...]) }
        if let range = text.range(of: " (", options: .backwards), text.hasSuffix(")") {
            text = String(text[..<range.lowerBound])
        }
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}
