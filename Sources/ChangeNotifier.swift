import Foundation
import UserNotifications

/// Native macOS notifications: VPN connect / disconnect, a launch card (subscription info only with VPN up), and the status card
/// after sleep / lock / screensaver. Every alert gets a unique identifier (a reused one is
/// shown silently); older cards of the same kind are removed once the new one is accepted,
/// and a failed post is retried. Text lives in `L10n`.
final class ChangeNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ChangeNotifier()

    private static let vpnPrefix = "warden-helper.vpn."
    private static let welcomePrefix = "warden-helper.welcome."
    private static let statusPrefix = "warden-helper.status."
    private static let subPrefix = "warden-helper.sub."
    private static let quotaPrefix = "warden-helper.quota."
    private static let aiPrefix = "warden-helper.ai."
    private static let aiThread = "warden-helper.ai"
    private static let vpnThread = "warden-helper.vpn"
    private static let subThread = "warden-helper.sub"
    private static let quotaThread = "warden-helper.quota"
    private static let welcomeThread = "warden-helper.welcome"
    private static let statusThread = "warden-helper.status"

    /// How long the welcome waits for the first VPN reading (offline at launch).
    private static let welcomeStatusWait: TimeInterval = 3

    /// Delivery attempts per alert, and the pause between them.
    private static let sendAttempts = 4
    private static let retryDelay: TimeInterval = 0.5

    // Launch-notification state (main thread only).
    private var authorized = false
    private var welcomeWanted = false
    private var welcomeVPN: Bool?            // VPN state at launch, once known
    private var welcomeWaitExpired = false

    private var isRunningAsAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private override init() { super.init() }

    // MARK: - Setup

    /// Sets the delegate and asks for permission. Safe to call repeatedly.
    func prepare() {
        guard isRunningAsAppBundle else { return } // UNUserNotificationCenter needs a bundle
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.authorized = granted
                if granted {
                    self.flushWelcome()
                } else {
                    // Denied: nothing shows until allowed in System Settings > Notifications.
                    self.welcomeWanted = false
                }
            }
        }
    }

    /// Call once at launch: arms the launch notification.
    func scheduleWelcome() {
        guard isRunningAsAppBundle else { return }
        welcomeWanted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.welcomeStatusWait) { [weak self] in
            self?.welcomeWaitExpired = true
            self?.flushWelcome()
        }
    }

    // MARK: - Input from VPNStateMonitor

    /// Main-thread update from VPNStateMonitor; only the first reading matters here.
    func vpnUpdate(_ state: VPNStatusDetector.State, changed: Bool) {
        guard !changed, welcomeVPN == nil else { return }
        welcomeVPN = state.active
        flushWelcome()
    }

    // MARK: - VPN change

    /// Delivers a VPN connect / disconnect alert. Safe from any thread.
    func notifyVPNChange(active: Bool, interface: String?) {
        guard Preferences.shared.notifyOnVPNChange else { return }

        func send(_ subscription: String?) {
            let base = active ? L10n.notifyVPNOnBody(interface) : L10n.notifyVPNOffBody(interface)
            deliver(title: active ? L10n.notifyVPNOnTitle : L10n.notifyVPNOffTitle,
                    subtitle: nil,
                    body: subscription.map { base + "\n" + $0 } ?? base,
                    prefix: Self.vpnPrefix,
                    thread: Self.vpnThread,
                    urgent: true,                   // breaks through scheduled summaries
                    sound: !active)                 // only a drop is worth a sound: it may mean unprotected traffic
        }
        if active {
            withSubscriptionBlock(send)             // a reconnect card carries the subscription's traffic info
        } else {
            send(nil)                               // a drop goes out at once
        }
    }

    /// The subscription block for a card. The subscription list belongs to the main thread, so
    /// this hops there when needed (one queue hop; nothing is read on the caller's thread).
    private func withSubscriptionBlock(_ body: @escaping (String?) -> Void) {
        if Thread.isMainThread {
            body(SubscriptionManager.shared.notificationBlock())
        } else {
            DispatchQueue.main.async { body(SubscriptionManager.shared.notificationBlock()) }
        }
    }

    // MARK: - Status after sleep / lock / screensaver

    /// Current VPN state once the user is back (`nil` = still no network). No sound, normal priority.
    func notifyStatusAfterResume(_ state: VPNStatusDetector.State?) {
        let prefs = Preferences.shared
        guard prefs.notifyOnVPNChange, prefs.notifyOnResume else { return }

        let title: String
        let body: String
        if let state = state {
            title = state.active ? L10n.vpnActive : L10n.vpnInactive
            body = state.active ? L10n.notifyVPNOnBody(state.interface) : L10n.resumeVPNOffBody(state.interface)
        } else {
            title = L10n.resumeOfflineTitle
            body = L10n.resumeOfflineBody
        }

        func send(_ subscription: String?) {
            deliver(title: title,
                    subtitle: nil,
                    body: subscription.map { body + "\n" + $0 } ?? body,
                    prefix: Self.statusPrefix,
                    thread: Self.statusThread,
                    urgent: false,
                    sound: false)
        }
        if state?.active == true {
            withSubscriptionBlock(send)             // VPN is up: add the subscription's traffic info
        } else {
            send(nil)
        }
    }

    // MARK: - Subscription update result

    /// Final result of one subscription refresh. Older cards are retired per subscription, so
    /// several subscriptions do not replace each other.
    func notifySubscriptionUpdate(id: String, name: String, success: Bool, message: String) {
        guard Preferences.shared.notifySubscriptionUpdate else { return }
        deliver(title: success ? L10n.notifySubOKTitle : L10n.notifySubFailTitle,
                subtitle: name,
                body: message,
                prefix: Self.subPrefix + id + ".",
                thread: Self.subThread,
                urgent: false,
                sound: false)
    }

    // MARK: - Subscription threshold crossed

    /// One alert per crossing (the caller decides when). `kind` is "traffic" or "expiry", so a
    /// newer card replaces the older one of the same subscription and kind only. Safe from any thread.
    func notifyQuota(id: String, kind: String, name: String, title: String, body: String, urgent: Bool) {
        guard Preferences.shared.notifyQuotaAlert else { return }
        deliver(title: title,
                subtitle: name,
                body: body,
                prefix: Self.quotaPrefix + id + "." + kind + ".",
                thread: Self.quotaThread,
                urgent: urgent,
                sound: false)
    }

    // MARK: - AI exit region changed

    /// One alert when a service's exit region differs from the last check. Cards are retired per
    /// service, so four services do not replace each other. Safe from any thread.
    func notifyAIRegionChange(vendor: AIVendor, from old: String, to new: String) {
        guard Preferences.shared.notifyAIRegionChange else { return }
        deliver(title: L10n.notifyAIRegionTitle,
                subtitle: vendor.displayName,
                body: L10n.notifyAIRegionBody(old, new),
                prefix: Self.aiPrefix + vendor.key + ".",
                thread: Self.aiThread,
                urgent: false,
                sound: false)
    }

    // MARK: - Shared delivery

    /// Posts one alert as a brand-new native notification.
    private func deliver(title: String,
                         subtitle: String?,
                         body: String,
                         prefix: String,
                         thread: String,
                         urgent: Bool,
                         sound: Bool) {
        // Needs an .app bundle.
        guard isRunningAsAppBundle else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle = subtitle { content.subtitle = subtitle }
        content.body = body
        content.threadIdentifier = thread
        if urgent {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        }
        content.sound = sound ? .default : nil

        let identifier = prefix + UUID().uuidString
        send(content, identifier: identifier, attemptsLeft: Self.sendAttempts) { [weak self] ok in
            // The new card is in; now retire older cards of this kind so they do not stack.
            if ok { self?.removeSuperseded(prefix: prefix, keeping: identifier) }
        }
    }

    // MARK: - Launch notification (every start)

    private func flushWelcome() {
        guard welcomeWanted, authorized,
              welcomeVPN != nil || welcomeWaitExpired,
              Preferences.shared.notifyOnVPNChange else { return }
        welcomeWanted = false

        let content = UNMutableNotificationContent()
        content.title = L10n.welcomeTitle
        if let vpn = welcomeVPN {
            content.subtitle = vpn ? L10n.welcomeVPNOn : L10n.welcomeVPNOff
            // Subscription traffic info only once the VPN is really connected.
            if vpn, let block = SubscriptionManager.shared.notificationBlock() {
                content.body = block
            }
        }
        content.threadIdentifier = Self.welcomeThread

        // Unique identifier, as for the other alerts.
        let identifier = Self.welcomePrefix + UUID().uuidString
        send(content, identifier: identifier, attemptsLeft: Self.sendAttempts) { [weak self] ok in
            if ok { self?.removeSuperseded(prefix: Self.welcomePrefix, keeping: identifier) }
        }
    }

    // MARK: - Delivery

    private func send(_ content: UNNotificationContent,
                      identifier: String,
                      attemptsLeft: Int,
                      completion: @escaping (Bool) -> Void) {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil) // nil = now
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error == nil {
                completion(true)
            } else if attemptsLeft > 1 {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.retryDelay) {
                    self?.send(content, identifier: identifier, attemptsLeft: attemptsLeft - 1, completion: completion)
                }
            } else {
                completion(false)
            }
        }
    }

    /// Removes delivered cards with this prefix except the newest.
    private func removeSuperseded(prefix: String, keeping identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let stale = delivered.map { $0.request.identifier }
                .filter { $0.hasPrefix(prefix) && $0 != identifier }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    // Show the banner even if the app is considered active.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
