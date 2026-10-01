import Foundation
import Darwin

/// Turns the domain rules into IP addresses, so they can be blocked by address in pf as well
/// as by name in the DNS sinkhole. A name block alone only stops NEW lookups: a connection
/// that is already open, an address a browser cached, a DoH or hard-coded resolver all keep
/// working. Blocking the addresses closes those gaps.
///
/// The lookups are built and sent by hand (raw UDP, TCP when a reply is truncated) straight to
/// the resolvers that were in use before the DNS switch. They never go through the system
/// resolver, so the sinkhole cannot answer them with 0.0.0.0, and a change of the system DNS
/// in the middle of a lookup cannot redirect them.
enum AddressResolver {

    struct Outcome {
        var found: [String: [String]] = [:]     // name -> host CIDRs (`1.2.3.4/32`, `::1/128`)
        var asked = 0                           // queries sent
        var answered = 0                        // queries that got a usable reply
    }

    /// Never more names than this per pass (the rules file allows 5000 entries).
    static let maxNames = 1000
    private static let maxParallel = 24
    private static let budget: TimeInterval = 25

    // MARK: Names

    /// The names to look up: every `domain`, and for every `domain_suffix` the apex and its
    /// `www.` form. Subdomains of a suffix and names matching a keyword cannot be listed; the
    /// sinkhole covers those by name (`seen`).
    static func names(for rules: BlockRuleSet, seen extra: [String] = []) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ name: String) { if seen.insert(name).inserted { out.append(name) } }
        for d in rules.domains { add(d) }
        for s in rules.domainSuffixes { add(s); add("www." + s) }
        // Names clients asked for are only kept while the CURRENT rules still match them; a name
        // learned under an earlier rules file must not keep being looked up and blocked.
        let exact = Set(rules.domains), suffixes = Set(rules.domainSuffixes), keywords = rules.domainKeywords
        for n in extra where matches(n, exact: exact, suffixes: suffixes, keywords: keywords) { add(n) }
        return Array(out.prefix(maxNames))
    }

    /// Same matching as the DNS sinkhole: exact name, any parent suffix, or keyword substring.
    static func matches(_ name: String, exact: Set<String>, suffixes: Set<String>, keywords: [String]) -> Bool {
        if exact.contains(name) { return true }
        if keywords.contains(where: { name.contains($0) }) { return true }
        var rest = Substring(name)
        while true {
            if suffixes.contains(String(rest)) { return true }
            guard let dot = rest.firstIndex(of: ".") else { return false }
            rest = rest[rest.index(after: dot)...]
        }
    }

    // MARK: Resolving

    /// A and AAAA for every name, run in parallel. `exclude` holds addresses that must never be
    /// blocked (the resolvers themselves, the sinkhole).
    /// Public resolvers asked in addition to the system's, as a second source of addresses.
    static let extraResolvers = ["1.1.1.1", "8.8.8.8"]

    static func resolve(names: [String], upstreams: [String], exclude: Set<String>) -> Outcome {
        guard !names.isEmpty, !upstreams.isEmpty else { return Outcome() }
        var servers = Array(upstreams.prefix(3))
        for extra in extraResolvers where !servers.contains(extra) { servers.append(extra) }
        let deadline = Date().addingTimeInterval(budget)
        let lock = NSLock()
        var outcome = Outcome()
        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: maxParallel)

        for name in names {
            for type in [UInt16(1), UInt16(28)] {
                if Date() > deadline { break }
                gate.wait()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { gate.signal(); group.leave() }
                    let result = lookup(name, type: type, servers: servers)
                    lock.lock()
                    defer { lock.unlock() }
                    outcome.asked += 1
                    guard let addresses = result else { return }
                    outcome.answered += 1
                    let usable = addresses.filter { blockable($0, exclude: exclude) }
                                          .map { $0 + ($0.contains(":") ? "/128" : "/32") }
                    if !usable.isEmpty { outcome.found[name, default: []] += usable }
                }
            }
        }
        group.wait()
        for (name, list) in outcome.found {                     // one entry per address
            var seen = Set<String>()
            outcome.found[name] = list.filter { seen.insert($0).inserted }
        }
        return outcome
    }

    /// Every server is asked and the answers are joined: CDNs give different addresses to
    /// different resolvers, and the application may have used any of them.
    /// nil: no server gave a usable reply. An empty list is a real answer (no such record).
    private static func lookup(_ name: String, type: UInt16, servers: [String]) -> [String]? {
        var all: [String] = []
        var answered = false
        for server in servers {
            let id = UInt16.random(in: 1...UInt16.max)
            guard let query = buildQuery(name: name, type: type, id: id),
                  let udp = DNSSinkhole.exchangeUDP(query, server: server) else { continue }
            var parsed = parseAnswer(udp, id: id)
            if parsed?.truncated == true, let tcp = DNSSinkhole.exchangeTCP(query, server: server) {
                parsed = parseAnswer(tcp, id: id)
            }
            if let parsed { answered = true; all += parsed.addresses }
        }
        return answered ? all : nil
    }

    // MARK: The system resolver's view

    /// What the applications were given: `getaddrinfo` goes through mDNSResponder, whose cache
    /// holds the very answers the browser or app got while blocking was off. Run this BEFORE the
    /// DNS cache is flushed and the services are switched; answers of the sinkhole (0.0.0.0, ::)
    /// are dropped by `blockable`. Bounded: returns after `timeout` with what is in.
    static func systemLookup(names: [String], exclude: Set<String>, timeout: TimeInterval = 4) -> [String: [String]] {
        guard !names.isEmpty else { return [:] }
        let lock = NSLock()
        var found: [String: [String]] = [:]
        let group = DispatchGroup()
        let gate = DispatchSemaphore(value: 16)
        for name in names {
            gate.wait()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { gate.signal(); group.leave() }
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return }
                defer { freeaddrinfo(first) }
                var out: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let node = cursor {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if let addr = node.pointee.ai_addr,
                       getnameinfo(addr, node.pointee.ai_addrlen, &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let text = String(cString: host)
                        if blockable(text, exclude: exclude) { out.append(text + (text.contains(":") ? "/128" : "/32")) }
                    }
                    cursor = node.pointee.ai_next
                }
                if !out.isEmpty { lock.lock(); found[name, default: []] += out; lock.unlock() }
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return found
    }

    // MARK: Query packet

    /// One standard recursive query, class IN, no EDNS (so replies fit 512 bytes or come
    /// back truncated and are repeated over TCP).
    static func buildQuery(name: String, type: UInt16, id: UInt16) -> [UInt8]? {
        var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF),
                          0x01, 0x00,                 // RD
                          0x00, 0x01,                 // one question
                          0, 0, 0, 0, 0, 0]
        var total = 0
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count) else { return nil }
            total += bytes.count + 1
            guard total <= 253 else { return nil }
            q.append(UInt8(bytes.count))
            q += bytes
        }
        q.append(0)
        q += [UInt8(type >> 8), UInt8(type & 0xFF), 0x00, 0x01]
        return q
    }

    // MARK: Reply parsing

    /// The A / AAAA records of the answer section, whatever their owner name is (that also
    /// covers the target of a CNAME chain). nil for a reply that is malformed, has another id,
    /// or carries an error other than "no such name".
    static func parseAnswer(_ r: [UInt8], id: UInt16) -> (addresses: [String], truncated: Bool)? {
        guard r.count >= 12, r[0] == UInt8(id >> 8), r[1] == UInt8(id & 0xFF) else { return nil }
        guard r[2] & 0x80 != 0 else { return nil }                       // must be a response
        let truncated = r[2] & 0x02 != 0
        let rcode = r[3] & 0x0F
        guard rcode == 0 || rcode == 3 else { return nil }               // NOERROR or NXDOMAIN
        let questions = Int(r[4]) << 8 | Int(r[5])
        let answers = Int(r[6]) << 8 | Int(r[7])

        var i = 12
        for _ in 0..<questions {
            guard skipName(r, &i), i + 4 <= r.count else { return nil }
            i += 4
        }
        var out: [String] = []
        for _ in 0..<answers {
            guard skipName(r, &i), i + 10 <= r.count else { break }
            let type = Int(r[i]) << 8 | Int(r[i + 1])
            let cls = Int(r[i + 2]) << 8 | Int(r[i + 3])
            let length = Int(r[i + 8]) << 8 | Int(r[i + 9])
            i += 10
            guard i + length <= r.count else { break }
            if cls == 1 {
                if type == 1, length == 4, let text = text(Array(r[i..<(i + 4)]), v6: false) { out.append(text) }
                if type == 28, length == 16, let text = text(Array(r[i..<(i + 16)]), v6: true) { out.append(text) }
            }
            i += length
        }
        return (out, truncated)
    }

    /// Moves `i` past a (possibly compressed) name.
    private static func skipName(_ r: [UInt8], _ i: inout Int) -> Bool {
        var hops = 0
        while i < r.count {
            let length = Int(r[i])
            if length == 0 { i += 1; return true }
            if length & 0xC0 == 0xC0 { i += 2; return i <= r.count }    // a pointer ends the name
            if length & 0xC0 != 0 { return false }
            i += 1 + length
            hops += 1
            if hops > 128 { return false }
        }
        return false
    }

    private static func text(_ bytes: [UInt8], v6: Bool) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let printed = bytes.withUnsafeBytes {
            inet_ntop(v6 ? AF_INET6 : AF_INET, $0.baseAddress, &buffer, socklen_t(buffer.count))
        }
        return printed == nil ? nil : String(cString: buffer)
    }

    // MARK: Which addresses may be blocked

    /// False for everything that must never be cut: the resolvers and the sinkhole (`exclude`),
    /// the placeholder answers of a sinkhole or a proxy's fake-IP pool (`198.18.0.0/15`), and
    /// any address that is not a public destination (loopback, private, link-local, CGNAT,
    /// multicast, reserved). Blocking one of those would break the LAN, the VPN or DNS itself.
    static func blockable(_ ip: String, exclude: Set<String>) -> Bool {
        if exclude.contains(ip) { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let n = UInt32(bigEndian: v4.s_addr)
            let a = Int(n >> 24), b = Int((n >> 16) & 0xFF)
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && b == 168 { return false }
            if a == 100 && (64...127).contains(b) { return false }      // CGNAT / Tailscale
            if a == 198 && (b == 18 || b == 19) { return false }        // fake-IP pool
            return true
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, ip, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes.allSatisfy({ $0 == 0 }) { return false }                                    // ::
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false }      // ::1
            if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false }                      // fe80::/10
            if bytes[0] & 0xFE == 0xFC { return false }                                          // fc00::/7
            if bytes[0] == 0xFF { return false }                                                 // multicast
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF { return false } // v4-mapped
            return true
        }
        return false
    }
}
