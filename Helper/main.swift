import Foundation
import Darwin

// warden-helper-daemon: the root half of WardenHelper's VPN-off blocking.
//   --daemon --uid N   run (started by launchd); only user N may talk to it
//   --restore          put back what the helper changed, then exit (used by uninstall)
//   --version          print the helper version

let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print(BlockIPC.helperVersion)
    exit(0)
}

if arguments.contains("--restore") {
    exit(Engine.restoreAll() ? 0 : 1)
}

guard arguments.contains("--daemon"),
      let uidFlag = arguments.firstIndex(of: "--uid"), uidFlag + 1 < arguments.count,
      let userID = UInt32(arguments[uidFlag + 1]), userID > 0 else {
    fputs("usage: warden-helper-daemon --daemon --uid <user id> | --restore | --version\n", stderr)
    exit(2)
}
guard getuid() == 0 else {
    fputs("warden-helper-daemon must run as root\n", stderr)
    exit(2)
}

signal(SIGPIPE, SIG_IGN)

let engine = Engine()
let server = IPCServer(path: BlockIPC.socketPath, allowedUID: uid_t(userID)) { engine.handle($0) }

// launchd stops the helper with SIGTERM (update, uninstall): close the socket and go.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        helperLog("stopping (signal \(sig))")
        server.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

engine.start()
do {
    try server.start()
} catch {
    helperLog("cannot start: \(error)")
    exit(1)                                   // launchd retries
}
helperLog("ready version=\(BlockIPC.helperVersion) uid=\(userID) pid=\(getpid())")
dispatchMain()
