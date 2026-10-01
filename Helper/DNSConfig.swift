import Foundation
import Darwin
import SystemConfiguration

/// Points every network service's DNS at the sinkhole and puts the original settings back.
/// All `networksetup` calls are `Exec.run` with an argument array; service names come from
/// `networksetup` itself and the server addresses from the validated `inet_pton` round trip.
///
/// The original settings are written to `/var/db/warden-helper/dns-backup.json` BEFORE anything is
/// changed, so a crash or reboot in the middle can always be undone by `restore()`.
enum DNSConfig {

    struct Entry: Codable, Equatable {
        var service: String
        var servers: [String]              // empty = automatic (DHCP)
    }

    struct Backup: Codable {
        var entries: [Entry]
        var upstream: [String]             // the resolvers the sinkhole forwards to
    }

    private static let networksetup = "/usr/sbin/networksetup"
    private static var backupPath: String { BlockIPC.stateDirectory + "/dns-backup.json" }

    static var hasBackup: Bool { HelperFiles.exists(backupPath) }

    // MARK: Switching

    /// Points every enabled service at `sinkhole` (the addresses the sinkhole listens on) and
    /// returns the upstream resolvers to forward to. Safe to call again and again: a service
    /// that already points at the sinkhole is left alone, so a repeat call writes nothing.
    static func enable(sinkhole: [String]) -> [String] {
        var backup = loadBackup() ?? Backup(entries: [], upstream: [])
        var changed = false
        var toSwitch: [String] = []

        for service in listServices(includeDisabled: false) {
            guard let current = currentServers(service) else {
                helperLog("dns: cannot read the DNS of \"\(service)\"; skipped")
                continue
            }
            let known = backup.entries.contains { $0.service == service }
            let ours = !current.isEmpty && current.allSatisfy(isLoopback) && (current == sinkhole || known)
            if ours {
                if !known {                                     // switched earlier, backup lost
                    backup.entries.append(Entry(service: service, servers: []))
                    changed = true
                }
                continue
            }
            backup.entries.removeAll { $0.service == service }
            backup.entries.append(Entry(service: service, servers: current))
            toSwitch.append(service)
            changed = true
        }

        var upstream = resolveUpstreams(from: backup)
        if upstream.isEmpty { upstream = backup.upstream }
        if upstream != backup.upstream { backup.upstream = upstream; changed = true }
        if changed { saveBackup(backup) }                       // before the first change

        var switched = 0
        for service in toSwitch {
            if Exec.run(networksetup, ["-setdnsservers", service] + sinkhole).ok {
                switched += 1
            } else {
                helperLog("dns: could not switch \"\(service)\"")
            }
        }
        if switched > 0 {
            flushCache()
            helperLog("block-dns switched \(switched) service(s) to the sinkhole; upstream=\(upstream.joined(separator: ","))")
        }
        return upstream
    }

    /// Puts the saved settings back. A service whose DNS is no longer a loopback address was
    /// changed by someone else since, and is left as it is. Returns false if some service
    /// could not be restored (the backup keeps those entries for the next try).
    @discardableResult
    static func restore() -> Bool {
        guard var backup = loadBackup() else { return true }
        let known = Set(listServices(includeDisabled: true))
        if known.isEmpty && !backup.entries.isEmpty {
            helperLog("dns restore: cannot list network services")
            return false
        }

        var remaining: [Entry] = []
        var restored = 0
        for entry in backup.entries {
            guard known.contains(entry.service) else { continue }         // the service is gone
            guard let current = currentServers(entry.service) else { remaining.append(entry); continue }
            if current.isEmpty || !current.allSatisfy(isLoopback) { continue }
            let arguments = entry.servers.isEmpty ? ["Empty"] : entry.servers
            if Exec.run(networksetup, ["-setdnsservers", entry.service] + arguments).ok {
                restored += 1
            } else {
                remaining.append(entry)
            }
        }
        if restored > 0 {
            flushCache()
            helperLog("block-dns restored \(restored) service(s)")
        }
        if remaining.isEmpty {
            HelperFiles.remove(backupPath)
            return true
        }
        backup.entries = remaining
        saveBackup(backup)
        helperLog("dns restore incomplete: \(remaining.count) service(s) left")
        return false
    }

    static func flushCache() {
        Exec.run("/usr/bin/dscacheutil", ["-flushcache"])
        Exec.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    // MARK: networksetup

    /// Enabled network services (a leading `*` marks a disabled one).
    static func listServices(includeDisabled: Bool) -> [String] {
        let r = Exec.run(networksetup, ["-listallnetworkservices"])
        guard r.ok else { return [] }
        var out: [String] = []
        for raw in r.output.split(separator: "\n") {
            var line = String(raw)
            if line.hasPrefix("An asterisk") || line.isEmpty { continue }
            if line.hasPrefix("*") {
                guard includeDisabled else { continue }
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            out.append(line)
        }
        return out
    }

    /// The manually set DNS servers of a service; `[]` when it uses DHCP; nil if unreadable.
    static func currentServers(_ service: String) -> [String]? {
        let r = Exec.run(networksetup, ["-getdnsservers", service])
        guard r.ok else { return nil }
        let lines = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                                                    .filter { !$0.isEmpty }
        let addresses = lines.filter(isIP)
        if !addresses.isEmpty && addresses.count == lines.count { return addresses }
        if addresses.isEmpty && lines.first?.hasPrefix("There aren't any DNS Servers") == true { return [] }
        return nil
    }

    // MARK: Upstream resolvers

    /// Manual servers of the services first, then what the network hands out (configd's view
    /// and the DHCP option). The sinkhole's own address is never an upstream.
    private static func resolveUpstreams(from backup: Backup) -> [String] {
        var list: [String] = []
        for entry in backup.entries { list += entry.servers }
        list += dynamicResolvers()
        var seen = Set<String>()
        return list.filter { usableUpstream($0) && seen.insert($0).inserted }
    }

    /// The resolvers to ask directly, without changing any setting: what the saved backup says
    /// was in use before the switch (so it stays right while the services already point at the
    /// sinkhole), else what configd and DHCP report now.
    static func knownUpstreams() -> [String] {
        let backup = loadBackup()
        var list = backup.map { resolveUpstreams(from: $0) } ?? []
        if list.isEmpty { list = dynamicResolvers().filter(usableUpstream) }
        list += backup?.upstream ?? []
        var seen = Set<String>()
        return list.filter { usableUpstream($0) && seen.insert($0).inserted }
    }

    private static func dynamicResolvers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "warden-helper-daemon" as CFString, nil, nil) else { return [] }
        var out: [String] = []

        let dnsKeys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/DNS" as CFString) as? [String] ?? []
        for key in dnsKeys.sorted() {
            if let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let addresses = value["ServerAddresses"] as? [String] { out += addresses }
        }

        // With a manual DNS set, configd shows that instead of what DHCP offered: ask for the lease.
        let v4Keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []
        var interfaces: [String] = []
        for key in v4Keys.sorted() {
            if let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = value["InterfaceName"] as? String,
               !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
               !interfaces.contains(name) { interfaces.append(name) }
        }
        for name in interfaces {
            let r = Exec.run("/usr/sbin/ipconfig", ["getoption", name, "domain_name_server"], timeout: 3)
            guard r.ok else { continue }
            out += r.output.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).map(String.init)
        }
        return out
    }

    // MARK: Address helpers

    static func isIP(_ text: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    static func isLoopback(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return (UInt32(bigEndian: v4.s_addr) >> 24) == 127 }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { $0.dropLast().allSatisfy { $0 == 0 } && $0.last == 1 }
        }
        return false
    }

    /// Something the sinkhole can forward to: a real, non-loopback, non-link-local address.
    static func usableUpstream(_ text: String) -> Bool {
        guard isIP(text), !isLoopback(text) else { return false }
        let lower = text.lowercased()
        return !lower.hasPrefix("fe80") && text != "0.0.0.0" && text != "::"
    }

    // MARK: Backup file

    private static func loadBackup() -> Backup? {
        guard let data = FileManager.default.contents(atPath: backupPath) else { return nil }
        return try? JSONDecoder().decode(Backup.self, from: data)
    }

    private static func saveBackup(_ backup: Backup) {
        guard let data = try? JSONEncoder().encode(backup) else { return }
        HelperFiles.write(String(decoding: data, as: UTF8.self), to: backupPath)
    }
}

/// Tells the enforcer that the network changed (a new Wi-Fi, a lease renewal, a service
/// added). Changes are debounced by 1 s. The enforcer's reaction is idempotent - a service
/// already pointing at the sinkhole is not written again - so the helper's own edits settle
/// after one extra round instead of looping.
final class NetworkWatcher {

    private let queue = DispatchQueue(label: "warden-helper.daemon.netwatch")
    private var store: SCDynamicStore?
    private var pending: DispatchWorkItem?
    private var handler: (() -> Void)?

    func start(_ onChange: @escaping () -> Void) {
        queue.async {
            self.handler = onChange
            guard self.store == nil else { return }
            var context = SCDynamicStoreContext(version: 0,
                                                info: Unmanaged.passUnretained(self).toOpaque(),
                                                retain: nil, release: nil, copyDescription: nil)
            let callback: SCDynamicStoreCallBack = { _, _, info in
                guard let info else { return }
                Unmanaged<NetworkWatcher>.fromOpaque(info).takeUnretainedValue().changed()
            }
            guard let store = SCDynamicStoreCreate(nil, "warden-helper-daemon-watch" as CFString, callback, &context) else {
                helperLog("dns: cannot watch network changes")
                return
            }
            let patterns = ["State:/Network/Global/.*", "State:/Network/Service/[^/]+/DNS",
                            "Setup:/Network/Global/IPv4", "Setup:/Network/Service/[^/]+/DNS"]
            SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray)
            SCDynamicStoreSetDispatchQueue(store, self.queue)
            self.store = store
        }
    }

    func stop() {
        queue.async {
            self.pending?.cancel()
            self.pending = nil
            self.handler = nil
            if let store = self.store { SCDynamicStoreSetDispatchQueue(store, nil) }
            self.store = nil
        }
    }

    private func changed() {                                   // on `queue`
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.handler?() }
        pending = item
        queue.asyncAfter(deadline: .now() + 1.0, execute: item)
    }
}
