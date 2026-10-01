import Foundation

/// Interface byte counters and enumeration (one `getifaddrs` loop shared by the speed monitor
/// and the settings pop-up; `counter(for:)` also feeds the traffic log's cross-check).
enum NetworkInterfaceReader {

    typealias Counters = (bytesIn: UInt64, bytesOut: UInt64)

    /// Cumulative counters per interface: the `locked` one if it is active, otherwise every
    /// active `en*` / `pdp_ip*` interface. `utun*` is left out so VPN traffic is not counted twice.
    static func counters(locked: String?) -> [String: Counters] {
        var all: [String: Counters] = [:]
        collect { name, bytesIn, bytesOut in
            all[name] = (bytesIn, bytesOut)
        }
        if let locked = locked, let entry = all[locked] {
            return [locked: entry]
        }
        return all.filter { !$0.key.hasPrefix("utun") }
    }

    /// Counters of one named interface, or nil. Only used to cross-check the controller's numbers
    /// in the traffic log.
    static func counter(for name: String) -> Counters? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let namePtr = ptr.pointee.ifa_name, String(cString: namePtr) == name else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let data = ptr.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            return (UInt64(data.pointee.ifi_ibytes), UInt64(data.pointee.ifi_obytes))
        }
        return nil
    }

    /// Interfaces for the settings pop-up; the first entry is "auto". An inactive locked interface is still listed.
    static func activeInterfaces(locked: String? = nil) -> [(displayName: String, rawName: String?)] {
        var interfaces: [(String, String?)] = []
        var seen = Set<String>()

        collect { name, _, _ in
            guard seen.insert(name).inserted else { return }
            interfaces.append((friendlyName(for: name), name))
        }

        if let locked = locked, !seen.contains(locked) {
            interfaces.append((L10n.interfaceOffline(friendlyName(for: locked)), locked))
        }

        interfaces.sort { ($0.1 ?? "") < ($1.1 ?? "") }
        interfaces.insert((L10n.autoAllInterfaces, nil), at: 0)
        return interfaces
    }

    // MARK: - Private

    /// Calls `body` per active `en*` / `utun*` / `pdp_ip*` interface with its cumulative byte counts.
    private static func collect(_ body: (String, UInt64, UInt64) -> Void) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let namePtr = ptr.pointee.ifa_name else { continue }

            let relevant = strncmp(namePtr, "en", 2) == 0 ||
                strncmp(namePtr, "utun", 4) == 0 ||
                strncmp(namePtr, "pdp_ip", 6) == 0
            guard relevant else { continue }

            if let networkData = ptr.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                body(String(cString: namePtr),
                     UInt64(networkData.pointee.ifi_ibytes),
                     UInt64(networkData.pointee.ifi_obytes))
            }
        }
    }

    private static func friendlyName(for name: String) -> String {
        if name.hasPrefix("en") { return L10n.network(name) }
        if name.hasPrefix("utun") { return L10n.vpnTunnel(name) }
        if name.hasPrefix("pdp_ip") { return L10n.cellular(name) }
        return name
    }
}
