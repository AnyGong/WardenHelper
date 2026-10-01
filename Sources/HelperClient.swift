import Foundation
import Darwin

/// Talks to the root helper over its Unix socket. One connection per request; every call runs
/// on a private serial queue and reports back on the main thread.
final class HelperClient {
    static let shared = HelperClient()

    enum Failure: Error, Equatable {
        case notRunning            // no socket, or nobody listening
        case timeout
        case badReply
        case rejected(String)      // the helper answered ok:false
    }

    private let queue = DispatchQueue(label: "warden-helper.helperclient", qos: .userInitiated)
    private static let ioTimeout: Int = 3      // seconds, connect excluded (a local socket is instant)

    private init() {}

    // MARK: Public

    func status(_ completion: @escaping (Result<HelperResponse, Failure>) -> Void) {
        send(HelperRequest(type: "status", armed: nil, rules: nil, since: nil), completion)
    }

    /// Like `status`, plus the helper's log lines after event number `since` (nil: none, only
    /// the current number).
    func events(since: Int?, _ completion: @escaping (Result<HelperResponse, Failure>) -> Void) {
        send(HelperRequest(type: "events", armed: nil, rules: nil, since: since), completion)
    }

    /// Sets the armed state; `rules == nil` keeps the helper's current rules.
    func apply(armed: Bool, rules: BlockRuleSet?,
               _ completion: @escaping (Result<HelperResponse, Failure>) -> Void) {
        send(HelperRequest(type: "apply", armed: armed, rules: rules?.rules, since: nil), completion)
    }

    /// The time-critical `apply`: blocks the calling thread until the helper has answered, and
    /// shares no queue with the status polls, so it never waits behind one. Any thread except main.
    static func applySync(armed: Bool, rules: BlockRuleSet?) -> Result<HelperResponse, Failure> {
        exchange(HelperRequest(type: "apply", armed: armed, rules: rules?.rules, since: nil))
    }

    private func send(_ request: HelperRequest,
                      _ completion: @escaping (Result<HelperResponse, Failure>) -> Void) {
        queue.async {
            let result = Self.exchange(request)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: Blocking exchange (client queue only)

    private static func exchange(_ request: HelperRequest) -> Result<HelperResponse, Failure> {
        guard var payload = try? JSONEncoder().encode(request) else { return .failure(.badReply) }
        payload.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.notRunning) }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: ioTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let name = Array(BlockIPC.socketPath.utf8CString)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: name.count) { dst in
                for (i, byte) in name.enumerated() { dst[i] = byte }
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .failure(.notRunning) }

        // Request
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            if written <= 0 { return .failure(errno == EAGAIN ? .timeout : .notRunning) }
            offset += written
        }

        // Reply: up to the first newline
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { return .failure(errno == EAGAIN ? .timeout : .badReply) }
            if n == 0 { break }
            reply.append(contentsOf: chunk[0..<n])
            if reply.count > 512 * 1024 { return .failure(.badReply) }
        }
        let line = reply.prefix(while: { $0 != 0x0A })
        guard let response = try? JSONDecoder().decode(HelperResponse.self, from: Data(line)) else {
            return .failure(.badReply)
        }
        return response.ok ? .success(response) : .failure(.rejected(response.error ?? ""))
    }
}
