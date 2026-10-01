import Foundation
import SystemConfiguration

/// Decides whether public traffic currently leaves through a tunnel interface.
/// Order: kernel route lookup (UDP connect + getsockname, in-process, never stale), then
/// `route -n get` with a timeout, then configd's primary interface (lags the kernel).
/// Blocks for at most ~1 s; call from a background queue.
enum VPNStatusDetector {

    struct State {
        /// Public traffic leaves through a tunnel interface.
        let active: Bool
        /// The tunnel interface when `active`, otherwise the interface in use (if known).
        let interface: String?
        /// False when there is no route at all (offline); the reading is then meaningless.
        let online: Bool
        /// A system proxy (HTTP / HTTPS / SOCKS / PAC) is switched on while no tunnel is active,
        /// e.g. "HTTP 127.0.0.1:7890". nil = none. Filled in by VPNStateMonitor, not by `currentState()`.
        var proxy: String? = nil
    }

    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]

    private enum Lookup {
        case interface(String)
        case unreachable          // kernel says: no route to the public internet
        case unknown              // could not ask / could not map the answer
    }

    static func currentState() -> State {
        switch kernelLookup(to: "1.1.1.1") {
        case .interface(let name):
            return State(active: isTunnel(name), interface: name, online: true)
        case .unreachable:
            // No default route: offline.
            return State(active: false, interface: primaryInterfaces().first, online: false)
        case .unknown:
            break
        }

        // Kernel lookup unavailable: try `route`, then configd.
        if let routed = interfaceForRoute(to: "1.1.1.1") {
            return State(active: isTunnel(routed), interface: routed, online: true)
        }
        let primaries = primaryInterfaces()
        if let tunnel = primaries.first(where: isTunnel) {
            return State(active: true, interface: tunnel, online: true)
        }
        return State(active: false, interface: primaries.first, online: !primaries.isEmpty)
    }

    private static func isTunnel(_ name: String) -> Bool {
        tunnelPrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: - 1. Kernel route lookup

    private static func kernelLookup(to address: String) -> Lookup {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return .unknown }
        defer { close(fd) }

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, address, &dest.sin_addr) == 1 else { return .unknown }

        let rc = withUnsafePointer(to: &dest) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            switch errno {
            case ENETUNREACH, EHOSTUNREACH, EADDRNOTAVAIL, ENETDOWN, EHOSTDOWN: return .unreachable
            default: return .unknown
            }
        }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gs = withUnsafeMutablePointer(to: &local) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard gs == 0, local.sin_addr.s_addr != 0 else { return .unknown }

        guard let name = interfaceName(forIPv4: local.sin_addr.s_addr) else { return .unknown }
        return .interface(name)
    }

    /// The interface that owns the given IPv4 source address.
    private static func interfaceName(forIPv4 wanted: in_addr_t) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let value = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if value == wanted { return String(cString: ptr.pointee.ifa_name) }
        }
        return nil
    }

    // MARK: - 2. `route` fallback (hard timeout)

    private static func interfaceForRoute(to address: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", address]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }

        // A wedged `route` must not freeze the monitor queue.
        if done.wait(timeout: .now() + 1.0) == .timedOut {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                return trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - 3. configd fallback

    /// One shared store instead of creating one per reading (only used from VPNStateMonitor's queue).
    private static let store = SCDynamicStoreCreate(nil, "WardenHelper-VPN" as CFString, nil, nil)

    private static func primaryInterfaces() -> [String] {
        guard let store = store else { return [] }
        var names: [String] = []
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = dict["PrimaryInterface"] as? String {
                names.append(name)
            }
        }
        return names
    }
}


/// Reads the macOS system proxy settings (System Settings > Network > Proxies) from configd.
/// In-process and cheap, so it can run on every VPN check.
enum SystemProxyDetector {

    /// A short description of the first enabled proxy ("HTTP 127.0.0.1:7890", "SOCKS ...",
    /// "PAC"), or nil when none is switched on. An entry counts only when it names a host / URL.
    static func current() -> String? {
        guard let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return nil }

        func enabled(_ key: String) -> Bool {
            (settings[key] as? NSNumber)?.intValue == 1
        }
        func text(_ key: String) -> String? {
            guard let value = settings[key] as? String, !value.isEmpty else { return nil }
            return value
        }

        let kinds: [(label: String, enable: String, host: String, port: String)] = [
            ("HTTP", "HTTPEnable", "HTTPProxy", "HTTPPort"),
            ("HTTPS", "HTTPSEnable", "HTTPSProxy", "HTTPSPort"),
            ("SOCKS", "SOCKSEnable", "SOCKSProxy", "SOCKSPort"),
        ]
        for kind in kinds where enabled(kind.enable) {
            guard let host = text(kind.host) else { continue }
            if let port = (settings[kind.port] as? NSNumber)?.intValue {
                return "\(kind.label) \(host):\(port)"
            }
            return "\(kind.label) \(host)"
        }
        if enabled("ProxyAutoConfigEnable"), text("ProxyAutoConfigURLString") != nil {
            return "PAC"
        }
        return nil
    }
}
