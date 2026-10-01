import Cocoa
import Foundation

/// Shows the current VPN status once each time the user comes back to the Mac (wake, display wake,
/// unlock, screensaver end, session switch).
///
/// An "away" event arms it; a "back" event fires only when the display is awake and the screen is
/// unlocked, then the status is shown once after the routes settle. A new "away" event cancels a
/// pending prompt. Main thread only; the reading runs on VPNStateMonitor's queue.
final class ResumeStatusPrompter: NSObject {

    private let monitor: VPNStateMonitor
    private var armed = false
    private var evaluateWork: DispatchWorkItem?
    private var promptToken = 0

    /// A burst of "back" events (wake + screen wake + unlock ...) is merged into one check.
    private static let evaluateDelay: TimeInterval = 0.5
    /// Grace period for routes to settle after coming back, before the first reading.
    private static let settleDelay: TimeInterval = 1.5
    /// If there is no route yet, re-read once a second this many times before giving up.
    private static let maxReadings = 8

    // Names of the distributed (system-wide) notifications macOS posts for lock / screensaver.
    private static let screenLocked = "com.apple.screenIsLocked"
    private static let screenUnlocked = "com.apple.screenIsUnlocked"
    private static let screensaverStarted = "com.apple.screensaver.didstart"
    private static let screensaverStopped = "com.apple.screensaver.didstop"

    private static let awayNames: Set<String> = [
        NSWorkspace.willSleepNotification.rawValue,
        NSWorkspace.screensDidSleepNotification.rawValue,
        NSWorkspace.sessionDidResignActiveNotification.rawValue,
        screenLocked,
        screensaverStarted,
    ]
    private static let backNames: Set<String> = [
        NSWorkspace.didWakeNotification.rawValue,
        NSWorkspace.screensDidWakeNotification.rawValue,
        NSWorkspace.sessionDidBecomeActiveNotification.rawValue,
        screenUnlocked,
        screensaverStopped,
    ]

    init(monitor: VPNStateMonitor) {
        self.monitor = monitor
        super.init()
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(received(_:)), name: name, object: nil)
        }

        // .deliverImmediately: never let the system hold these back while WardenHelper is in the background.
        let distributed = DistributedNotificationCenter.default()
        for raw in [Self.screenLocked, Self.screenUnlocked,
                    Self.screensaverStarted, Self.screensaverStopped] {
            distributed.addObserver(self, selector: #selector(received(_:)),
                                    name: Notification.Name(raw), object: nil,
                                    suspensionBehavior: .deliverImmediately)
        }
    }

    // MARK: - Events

    @objc private func received(_ note: Notification) {
        let name = note.name.rawValue
        DispatchQueue.main.async { [weak self] in self?.handle(name) }
    }

    private func handle(_ name: String) {
        if Self.awayNames.contains(name) {
            armed = true
            evaluateWork?.cancel()      // a pending check is obsolete
            promptToken &+= 1           // ...and so is a prompt that is not on screen yet
        } else if Self.backNames.contains(name), armed {
            scheduleEvaluate()
        }
    }

    private func scheduleEvaluate() {
        evaluateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        evaluateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.evaluateDelay, execute: work)
    }

    /// Is the user really back? If not, stay armed: the next "back" event asks again.
    private func evaluate() {
        guard armed else { return }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return }   // display still off (dark wake)
        if Self.screenIsLocked() { return }                       // waiting for the unlock
        armed = false

        // Either the pop-up or the notification wants the status (each checks its own setting).
        let prefs = Preferences.shared
        guard prefs.popupOnVPNDisconnect || (prefs.notifyOnVPNChange && prefs.notifyOnResume) else { return }

        // Refresh the menu bar right away too (also runs quick follow-up checks).
        monitor.networkChanged()

        promptToken &+= 1
        showStatus(token: promptToken, delay: Self.settleDelay, readingsLeft: Self.maxReadings)
    }

    // MARK: - Reading and showing

    private func showStatus(token: Int, delay: TimeInterval, readingsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.promptToken == token else { return }
            self.monitor.readState { state in
                DispatchQueue.main.async {
                    guard self.promptToken == token else { return }
                    if state.online {
                        ChangeNotifier.shared.notifyStatusAfterResume(state)
                        VPNDisconnectPrompt.shared.show(reason: state.active ? .resumeConnected : .resumeDisconnected,
                                                        interface: state.interface)
                    } else if readingsLeft > 1 {
                        self.showStatus(token: token, delay: 1, readingsLeft: readingsLeft - 1)
                    } else {
                        ChangeNotifier.shared.notifyStatusAfterResume(nil)   // still offline
                    }
                }
            }
        }
    }

    /// Ask the window server whether the screen is locked (the lock screen / password prompt).
    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
