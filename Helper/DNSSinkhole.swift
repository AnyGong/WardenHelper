import Foundation
import Darwin

/// A small DNS server on 127.0.0.1:53 and ::1:53 (UDP and TCP). Names in the rules get
/// `0.0.0.0` for A and `::` for AAAA; every other record type for those names gets an empty
/// answer (NOERROR, no records - this includes HTTPS/SVCB, so a browser cannot learn an
/// address from there). Everything else is forwarded, untouched, to the resolvers that were
/// in use before the switch. A query the sinkhole cannot parse is forwarded too.
final class DNSSinkhole {

    struct StartError: Error, CustomStringConvertible {
        let description: String
    }

    /// The addresses actually bound; `DNSConfig` points the services at exactly these.
    private(set) var addresses: [String] = []

    private struct Names {
        var exact = Set<String>()
        var suffixes = Set<String>()
        var keywords: [String] = []

        func matches(_ name: String) -> Bool {
            if exact.contains(name) { return true }
            if keywords.contains(where: { name.contains($0) }) { return true }
            var rest = Substring(name)
            while true {
                if suffixes.contains(String(rest)) { return true }
                guard let dot = rest.firstIndex(of: ".") else { return false }
                rest = rest[rest.index(after: dot)...]
            }
        }
    }

    /// Called (any thread) with the name of every query that was answered with the sinkhole
    /// reply, so the enforcer can learn the addresses behind names the rules only match by suffix.
    var onMatch: ((String) -> Void)?

    private let lock = NSLock()
    private var names = Names()
    private var upstreams: [String] = []
    private var recentlyLogged: [String: Date] = [:]

    private let io = DispatchQueue(label: "warden-helper.daemon.dns.io")
    private let work = DispatchQueue(label: "warden-helper.daemon.dns.work", attributes: .concurrent)
    private var sources: [DispatchSourceRead] = []

    // MARK: Rules and upstreams

    func update(domains: [String], suffixes: [String], keywords: [String]) {
        lock.lock()
        names = Names(exact: Set(domains), suffixes: Set(suffixes), keywords: keywords)
        lock.unlock()
    }

    func setUpstreams(_ list: [String]) {
        lock.lock()
        upstreams = list
        lock.unlock()
    }

    // MARK: Start / stop

    /// IPv4 is required; IPv6 is optional and left out of `addresses` if it cannot be bound.
    func start() throws {
        guard sources.isEmpty else { return }
        var fds: [(fd: Int32, stream: Bool)] = []

        for stream in [false, true] {
            switch Self.bound(v6: false, stream: stream) {
            case .success(let fd): fds.append((fd, stream))
            case .failure(let why):
                for item in fds { close(item.fd) }
                throw StartError(description: "cannot listen on 127.0.0.1:53 \(stream ? "tcp" : "udp"): \(why.description)")
            }
        }
        addresses = ["127.0.0.1"]

        var v6: [(fd: Int32, stream: Bool)] = []
        for stream in [false, true] {
            if case .success(let fd) = Self.bound(v6: true, stream: stream) { v6.append((fd, stream)) }
        }
        if v6.count == 2 {
            fds += v6
            addresses.append("::1")
        } else {
            for item in v6 { close(item.fd) }
            helperLog("dns: ::1:53 is not available; IPv4 only")
        }

        for item in fds {
            let source = DispatchSource.makeReadSource(fileDescriptor: item.fd, queue: io)
            let fd = item.fd
            if item.stream {
                source.setEventHandler { [weak self] in self?.acceptTCP(fd) }
            } else {
                source.setEventHandler { [weak self] in self?.readUDP(fd) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
        helperLog("block-dns sinkhole listening on \(addresses.joined(separator: ", ")) port 53")
    }

    /// Returns only after every socket is really closed. Cancelling alone closes them later, on
    /// the io queue; a switch-off followed at once by a switch-on would then try to bind port 53
    /// while the old UDP socket still holds it, and the sinkhole could not start.
    func stop() {
        let closed = DispatchGroup()
        for source in sources {
            let fd = Int32(source.handle)
            closed.enter()
            source.setCancelHandler { close(fd); closed.leave() }
            source.cancel()
        }
        if closed.wait(timeout: .now() + 2) == .timedOut {
            helperLog("block-dns sinkhole: sockets did not close within 2 s")
        }
        sources = []
        addresses = []
        helperLog("block-dns sinkhole stopped")
    }

    // MARK: Sockets

    private static func bound(v6: Bool, stream: Bool) -> Result<Int32, StartError> {
        let fd = socket(v6 ? AF_INET6 : AF_INET, stream ? SOCK_STREAM : SOCK_DGRAM, 0)
        guard fd >= 0 else { return .failure(StartError(description: "socket: \(errnoText())")) }
        var one: Int32 = 1
        if stream { setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) }
        if v6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) }

        let rc: Int32
        if v6 {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = UInt16(53).bigEndian
            inet_pton(AF_INET6, "::1", &a.sin6_addr)
            rc = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = UInt16(53).bigEndian
            a.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
            rc = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard rc == 0 else {
            let why = errnoText()
            close(fd)
            return .failure(StartError(description: "bind: \(why)"))
        }
        if stream && listen(fd, 16) != 0 {
            let why = errnoText()
            close(fd)
            return .failure(StartError(description: "listen: \(why)"))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return .success(fd)
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }

    // MARK: Serving

    private func readUDP(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &peerLength)
                }
            }
            if n < 0 { return }                                   // EAGAIN: nothing more queued
            if n < 12 { continue }
            let query = Array(buffer[0..<n])
            let target = peer
            let targetLength = peerLength
            work.async { [weak self] in
                guard let self, let reply = self.answer(query, overTCP: false) else { return }
                var to = target
                _ = withUnsafePointer(to: &to) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        reply.withUnsafeBytes { sendto(fd, $0.baseAddress, reply.count, 0, sa, targetLength) }
                    }
                }
            }
        }
    }

    private func acceptTCP(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            work.async { [weak self] in self?.serveTCP(client) }
        }
    }

    private func serveTCP(_ fd: Int32) {
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        Self.setTimeout(fd, seconds: 5)
        while true {
            guard let head = Self.readExactly(fd, 2) else { return }
            let length = Int(head[0]) << 8 | Int(head[1])
            guard length >= 12, let query = Self.readExactly(fd, length),
                  let reply = answer(query, overTCP: true) else { return }
            let framed = [UInt8(reply.count >> 8), UInt8(reply.count & 0xFF)] + reply
            if !Self.writeAll(fd, framed) { return }
        }
    }

    // MARK: Answering

    private func answer(_ query: [UInt8], overTCP: Bool) -> [UInt8]? {
        lock.lock()
        let current = names
        lock.unlock()

        if let question = Self.parseQuestion(query), current.matches(question.name) {
            noteBlocked(question.name, type: question.type)
            onMatch?(question.name)
            return Self.sinkholeReply(query, questionEnd: question.end, type: question.type, cls: question.cls)
        }
        return forward(query, overTCP: overTCP) ?? Self.servfail(query)
    }

    private struct Question {
        let name: String            // lower case, no trailing dot
        let type: UInt16
        let cls: UInt16
        let end: Int                // offset just after the question section
    }

    /// One plain question (no compression pointers in the name). Anything else returns nil
    /// and the query is forwarded unchanged.
    private static func parseQuestion(_ q: [UInt8]) -> Question? {
        guard q.count >= 17 else { return nil }
        let flags = UInt16(q[2]) << 8 | UInt16(q[3])
        guard flags & 0x8000 == 0, (flags >> 11) & 0xF == 0 else { return nil }     // a standard query
        guard q[4] == 0, q[5] == 1 else { return nil }                              // exactly one question

        var i = 12
        var labels: [String] = []
        var total = 0
        while true {
            guard i < q.count else { return nil }
            let length = Int(q[i])
            i += 1
            if length == 0 { break }
            guard length & 0xC0 == 0, i + length <= q.count else { return nil }
            labels.append(String(decoding: q[i..<(i + length)], as: UTF8.self).lowercased())
            i += length
            total += length + 1
            guard total <= 253 else { return nil }
        }
        guard i + 4 <= q.count else { return nil }
        let type = UInt16(q[i]) << 8 | UInt16(q[i + 1])
        let cls = UInt16(q[i + 2]) << 8 | UInt16(q[i + 3])
        return Question(name: labels.joined(separator: "."), type: type, cls: cls, end: i + 4)
    }

    /// Header + the original question + at most one answer record.
    private static func sinkholeReply(_ q: [UInt8], questionEnd: Int, type: UInt16, cls: UInt16) -> [UInt8] {
        var r = Array(q[0..<questionEnd])
        r[2] = 0x80 | (q[2] & 0x01)                 // QR, opcode 0, RD copied
        r[3] = 0x80                                 // RA, NOERROR
        r[6] = 0; r[7] = 0                          // answers: set below
        r[8] = 0; r[9] = 0; r[10] = 0; r[11] = 0    // no authority, no additional (no OPT echo)

        let ttl: [UInt8] = [0, 0, 0, 10]
        if cls == 1 && (type == 1 || type == 28) {
            r[7] = 1
            r += [0xC0, 0x0C]                       // the name, by pointer to the question
            r += [UInt8(type >> 8), UInt8(type & 0xFF), 0x00, 0x01]
            r += ttl
            if type == 1 {
                r += [0x00, 0x04, 0, 0, 0, 0]                                   // 0.0.0.0
            } else {
                r += [0x00, 0x10] + [UInt8](repeating: 0, count: 16)            // ::
            }
        }
        return r
    }

    private static func servfail(_ q: [UInt8]) -> [UInt8] {
        var r = Array(q.prefix(12))
        guard r.count == 12 else { return r }
        r[2] = 0x80 | (q[2] & 0x01)
        r[3] = 0x82                                 // RA, SERVFAIL
        for i in 4..<12 { r[i] = 0 }
        return r
    }

    private func noteBlocked(_ name: String, type: UInt16) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        if let last = recentlyLogged[name], now.timeIntervalSince(last) < 10 { return }
        recentlyLogged[name] = now
        if recentlyLogged.count > 512 { recentlyLogged = recentlyLogged.filter { now.timeIntervalSince($0.value) < 10 } }
        let label: String
        switch type {
        case 1: label = "A"
        case 28: label = "AAAA"
        case 65: label = "HTTPS"
        default: label = String(type)
        }
        helperLog("block-dns name=\(name) type=\(label)")
    }

    // MARK: Forwarding

    private func forward(_ query: [UInt8], overTCP: Bool) -> [UInt8]? {
        lock.lock()
        let servers = Array(upstreams.prefix(3))
        lock.unlock()
        for server in servers {
            let reply = overTCP ? Self.exchangeTCP(query, server: server) : Self.exchangeUDP(query, server: server)
            if let reply { return reply }
        }
        return nil
    }

    private struct Remote {
        var family: Int32
        var storage: sockaddr_storage
        var length: socklen_t
    }

    private static func remote(_ ip: String) -> Remote? {
        var storage = sockaddr_storage()
        if ip.contains(":") {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = UInt16(53).bigEndian
            guard inet_pton(AF_INET6, ip, &a.sin6_addr) == 1 else { return nil }
            withUnsafeBytes(of: a) { src in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) } }
            return Remote(family: AF_INET6, storage: storage, length: socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { return nil }
        withUnsafeBytes(of: a) { src in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: src) } }
        return Remote(family: AF_INET, storage: storage, length: socklen_t(MemoryLayout<sockaddr_in>.size))
    }

    static func exchangeUDP(_ query: [UInt8], server: String) -> [UInt8]? {
        guard var target = remote(server) else { return nil }
        let fd = socket(target.family, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let length = target.length
        let connected = withUnsafePointer(to: &target.storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connected == 0, send(fd, query, query.count, 0) == query.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 16_384)
        for _ in 0..<3 {                                        // skip stray packets with another id
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 12 { return nil }                            // timeout or error
            if buffer[0] == query[0] && buffer[1] == query[1] { return Array(buffer[0..<n]) }
        }
        return nil
    }

    static func exchangeTCP(_ query: [UInt8], server: String) -> [UInt8]? {
        guard var target = remote(server) else { return nil }
        let fd = socket(target.family, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard connectWithTimeout(fd, &target, milliseconds: 2000) else { return nil }
        setTimeout(fd, seconds: 3)

        let framed = [UInt8(query.count >> 8), UInt8(query.count & 0xFF)] + query
        guard writeAll(fd, framed), let head = readExactly(fd, 2) else { return nil }
        let length = Int(head[0]) << 8 | Int(head[1])
        guard length >= 12, let reply = readExactly(fd, length),
              reply[0] == query[0], reply[1] == query[1] else { return nil }
        return reply
    }

    /// A connect that gives up after `timeoutMilliseconds`.
    private static func connectWithTimeout(_ fd: Int32, _ target: inout Remote, milliseconds: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let length = target.length
        let rc = withUnsafePointer(to: &target.storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, milliseconds) == 1 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size)
        return error == 0
    }

    // MARK: Small I/O helpers

    private static func setTimeout(_ fd: Int32, seconds: Int) {
        var t = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = out.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: got), count - got) }
            if n <= 0 { return nil }
            got += n
        }
        return out
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: sent), bytes.count - sent) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}
