import Foundation
import Darwin

struct ExecResult {
    let status: Int32
    let output: String          // stdout and stderr together
    var ok: Bool { status == 0 }
}

/// The only way the helper starts another program: an absolute path and an argument array.
/// Nothing goes through a shell, so no rule value can ever be interpreted as a command.
enum Exec {
    @discardableResult
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> ExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ExecResult(status: 127, output: "\(error)")
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return ExecResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// Small file helpers for `/var/db/warden-helper` (root only, 0700; files 0600).
enum HelperFiles {
    static func ensureStateDirectory() {
        try? FileManager.default.createDirectory(atPath: BlockIPC.stateDirectory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    @discardableResult
    static func write(_ text: String, to path: String) -> Bool {
        ensureStateDirectory()
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            chmod(path, 0o600)
            return true
        } catch {
            helperLog("could not write \(path): \(error.localizedDescription)")
            return false
        }
    }

    static func read(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    static func remove(_ path: String) { try? FileManager.default.removeItem(atPath: path) }
}
