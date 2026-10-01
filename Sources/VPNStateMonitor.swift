import Foundation
import Darwin

/// Reports every VPN flip as soon as it happens. All triggers feed one serial `check()`:
/// the routing socket (PF_ROUTE), `networkChanged()` plus follow-up checks, a 1 s safety
/// timer, and wake / session events. The first event of a burst is checked at once; further
/// events within 30 ms merge into one trailing check.
final class VPNStateMonitor {

    /// Main thread: the first reading (`changed == false`), every flip (`changed == true`), and
    /// a system-proxy switch on / off (`changed == false`, `state.proxy` differs from before).
    var onUpdate: ((VPNStatusDetector.State, Bool) -> Void)?

    /// Monitor queue, immediately on every flip (before the main-thread hop).
    var onFlip: ((VPNStatusDetector.State) -> Void)?

    /// Monitor queue: the tunnel carrying public traffic changed (`nil` = no VPN).
    var onTunnelChange: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "warden-helper.vpnstate", qos: .userInteractive)
    private var tunnelKnown = false                    // `queue` only
    private var lastTunnel: String?                    // `queue` only
    private var confirmedActive: Bool?                 // touched on `queue` only
    private var lastProxy: String?                     // `queue` only
    private var timer: DispatchSourceTimer?
    private var routeSource: DispatchSourceRead?

    private var lastRunUptime: UInt64 = 0              // `queue` only
    private var trailingPending = false                // `queue` only
    private var followUpToken = 0                      // `queue` only
    private static let coalesceWindow: UInt64 = 30_000_000 // 30 ms, in ns

    /// ADD, DELETE, CHANGE, NEWADDR, DELADDR, IFINFO, IFINFO2. RTM_GET (4) is excluded:
    /// our own `route -n get` lookups would echo back and loop.
    private static let relevantRouteTypes: Set<UInt8> = [1, 2, 3, 12, 13, 14, 18]
    /// Neighbour (ARP / NDP) and multicast entries: LAN noise.
    private static let ignoredRouteFlags: Int32 = 0x400 | 0x800000

    func start() {
        queue.async { [weak self] in self?.check() }
        startRouteSocket()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    /// Call right when the network configuration changed.
    func networkChanged() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.followUpToken &+= 1               // a newer burst supersedes older follow-ups
            let token = self.followUpToken
            self.requestCheck()
            for delay in [0.2, 0.6, 1.5, 3.0, 6.0] {
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, self.followUpToken == token else { return }
                    self.check()
                }
            }
        }
    }

    /// One-off reading on the monitor's queue; never raises an alert.
    func readState(_ completion: @escaping (VPNStatusDetector.State) -> Void) {
        queue.async { completion(VPNStatusDetector.currentState()) }
    }

    // MARK: - Routing socket

    private func startRouteSocket() {
        let fd = socket(17 /* PF_ROUTE */, SOCK_RAW, 0)
        guard fd >= 0 else { return } // the other layers still work
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        // Large buffer: a VPN connect plus ARP chatter can overflow the default one.
        var bufferSize: Int32 = 512 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainRouteSocket(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        routeSource = source
    }

    /// Reads everything queued, then runs one check.
    private func drainRouteSocket(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var relevant = false
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                // ENOBUFS / interrupted: something may have been missed, so check. EAGAIN = drained.
                if errno != EAGAIN && errno != EWOULDBLOCK { relevant = true }
                break
            }
            if n == 0 { break }
            guard n >= 4, Self.relevantRouteTypes.contains(buffer[3]) else { continue }
            // struct rt_msghdr: u_short msglen, u_char version, u_char type,
            // u_short index, (2 pad), int flags at offset 8.
            if buffer[3] <= 3, n >= 12 {
                let flags = buffer.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int32.self) }
                if flags & Self.ignoredRouteFlags != 0 { continue }
            }
            relevant = true
        }
        if relevant { requestCheck() }
    }

    // MARK: - Check

    /// First event runs at once; later ones in the window merge into one trailing check.
    private func requestCheck() {
        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastRunUptime >= Self.coalesceWindow {
            check()
        } else if !trailingPending {
            trailingPending = true
            queue.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
                self?.trailingPending = false
                self?.check()
            }
        }
    }

    private func check() {
        lastRunUptime = DispatchTime.now().uptimeNanoseconds
        var state = VPNStatusDetector.currentState()
        guard state.online else { return } // no route at all: keep the last known state

        // A system proxy only matters while no tunnel carries the traffic.
        state.proxy = state.active ? nil : SystemProxyDetector.current()

        let tunnel = state.active ? state.interface : nil
        if !tunnelKnown || tunnel != lastTunnel {
            tunnelKnown = true
            lastTunnel = tunnel
            onTunnelChange?(tunnel)
        }

        guard let confirmed = confirmedActive else {   // first reading after launch
            confirmedActive = state.active
            lastProxy = state.proxy
            DispatchQueue.main.async { [weak self] in self?.onUpdate?(state, false) }
            return
        }
        guard state.active != confirmed else {
            // No flip; the proxy setting may still have changed (display only, no alert).
            if state.proxy != lastProxy {
                lastProxy = state.proxy
                DispatchQueue.main.async { [weak self] in self?.onUpdate?(state, false) }
            }
            return
        }

        confirmedActive = state.active
        lastProxy = state.proxy
        onFlip?(state)                                  // notify NOW, on this queue
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(state, true) }
    }
}
