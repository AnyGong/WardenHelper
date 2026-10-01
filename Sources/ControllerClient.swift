import Foundation
import Security

// MARK: - States shown in the UI

enum ControllerFailure: Error, Equatable {
    case notFound                 // auto-detect found nothing
    case unauthorized             // 401 with a secret that is stored
    case secretMissing            // 401 and no secret is stored
    case badAddress               // the typed address does not parse
    case badResponse              // answered, but not in the expected shape
    case unreachable(String)      // the (typed or cached) address does not answer
}

enum ControllerState: Equatable {
    case idle                     // no tunnel, or nothing read yet
    case connected(String)        // the version string the controller reported
    case unavailable(ControllerFailure)
}

// MARK: - Address

enum ControllerAddress {
    /// "http://host:port" from what the user typed: "127.0.0.1:9090", "9090" (= this Mac),
    /// "http://host:9090", "[::1]:9090". A missing port means 9090. nil = unusable.
    static func baseURL(from raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.allSatisfy({ $0.isASCII && $0.isNumber }) { text = "127.0.0.1:" + text }
        if !text.contains("://") { text = "http://" + text }
        guard let parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = parts.host else { return nil }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }
        let port = parts.port ?? 9090
        guard (1...65535).contains(port) else { return nil }
        return "\(scheme)://\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    /// "127.0.0.1:9090" for messages.
    static func display(_ base: String) -> String {
        base.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
    }
}

// MARK: - Secret (macOS Keychain)

/// The controller secret lives in the login Keychain, never in UserDefaults, so it is not part of
/// 导出 / 导入 and is not touched by 恢复默认设置.
enum ControllerSecretStore {
    private static let service = "WardenHelper"
    private static let account = "controller-secret"

    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The secret a fresh install starts with (once; clearing it later leaves it cleared).
    static let defaultSecret = "0408"
    private static let seededKey = "controllerSecretSeeded"

    private static func seedIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        if !exists() { save(defaultSecret) }
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    static func load() -> String? {
        seedIfNeeded()
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether an entry exists (attributes only, so no access prompt).
    static func exists() -> Bool {
        var query = identity
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// An empty secret removes the entry. Returns false when the Keychain refused.
    @discardableResult
    static func save(_ secret: String) -> Bool {
        if secret.isEmpty {
            let status = SecItemDelete(identity as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(secret.utf8)
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = identity
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Client

/// Talks to the proxy kernel's Clash-compatible controller (sing-box `clash_api`, mihomo).
/// All state lives on one serial queue; requests are blocking and short (2-3 s timeouts), so the
/// callers never wait on it.
///
/// Every request to a confirmed controller carries `Authorization: Bearer <secret>`. In
/// auto-detect mode the secret is NOT sent while probing: candidates get an unauthenticated
/// `GET /version` first, and only the one that identifies itself as a controller (200 with a
/// version, or 401) is asked again with the secret.
final class ControllerClient {
    static let shared = ControllerClient()

    enum Route {
        case direct, proxy, unknown
        var label: String {
            switch self { case .direct: return "direct"; case .proxy: return "proxy"; case .unknown: return "unknown" }
        }
    }

    struct Sample {
        let id: String
        let upload: UInt64
        let download: UInt64
        let route: Route
        let chains: [String]
        let node: String        // the outbound node the traffic leaves through ("Taiwan 01"), not a group
        let target: String      // "host:port" when the controller says (best effort), else ""
        let network: String     // "tcp" / "udp" when given
        let rule: String        // matched rule, when given
    }

    struct PollData {
        let version: String
        let samples: [Sample]
        /// Entries in the `connections` array, and how many of them had id / upload / download / chains.
        let total: Int
        let parsed: Int
        /// Entries in the `/proxies` table.
        let outbounds: Int
        /// The kernel's own running totals over every connection ever seen, closed ones included
        /// (`uploadTotal` / `downloadTotal`), when the reply has them.
        let kernelUpload: UInt64?
        let kernelDownload: UInt64?
    }

    private struct Item {
        let id: String
        let upload: UInt64
        let download: UInt64
        let chains: [String]
        let target: String
        let network: String
        let rule: String
    }

    private struct Found {
        let base: String
        let version: String
    }

    private enum Probe {
        case none
        case needsSecret
        case controller(String)
    }

    private struct Reply {
        let status: Int
        let body: Data
    }

    private let q = DispatchQueue(label: "warden-helper.controller", qos: .utility)
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]       // the controller is local: never via a system proxy
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // Touched on `q` only.
    private var address: String?                     // the working base URL
    private var lastGood: String?                    // tried first when re-probing
    private var version = ""
    private var secret = ""
    private var secretLoaded = false
    private var stopped: ControllerFailure?          // a 401: no more requests until something changes
    private var lastFailure: ControllerFailure?
    private var nextAttempt: UInt64 = 0
    private var appliedManual: String?
    private var proxyTypes: [String: String] = [:]   // outbound tag -> lower-cased type
    private var proxyTypesTriedAt: UInt64 = 0

    private static let commonPorts = [9090, 9097, 9091, 8080, 2080]
    private static let maxCandidates = 24

    private init() {}

    // MARK: - Public

    /// One reading of `/connections`, classified. `completion` runs on the client's queue.
    func poll(_ completion: @escaping (Result<PollData, ControllerFailure>) -> Void) {
        q.async { [self] in completion(runPoll()) }
    }

    /// Forget everything cached and read once from scratch (the 测试连接 button). Main thread.
    func test(_ completion: @escaping (Result<PollData, ControllerFailure>) -> Void) {
        q.async { [self] in
            resetLocked()
            let result = runPoll()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The secret was edited in the settings window.
    func secretChanged() {
        q.async { [self] in
            secretLoaded = false
            stopped = nil
            lastFailure = nil
            nextAttempt = 0
        }
    }

    /// A tunnel came up: a stopped (401) client tries again.
    func tunnelChanged() {
        q.async { [self] in
            stopped = nil
            nextAttempt = 0
        }
    }

    // MARK: - Poll (queue only)

    private func runPoll() -> Result<PollData, ControllerFailure> {
        applyConfiguration()
        if let stopped = stopped { return .failure(stopped) }

        if address == nil {
            if DispatchTime.now().uptimeNanoseconds < nextAttempt, let failure = lastFailure {
                return .failure(failure)               // backing off: no network, no process
            }
            switch discover() {
            case .success(let found):
                address = found.base
                lastGood = found.base
                version = found.version
                lastFailure = nil
            case .failure(let failure):
                let manual = !Preferences.shared.controllerAddress.isEmpty
                fail(failure, retryAfter: manual ? 5 : 10)
                return .failure(failure)
            }
        }
        guard let base = address else { return .failure(.notFound) }

        refreshProxyTypes(minAgeSeconds: proxyTypes.isEmpty ? 3 : 300)

        guard let reply = get(base, "/connections", withSecret: true, timeout: 3) else {
            address = nil                              // probe again after a short pause
            let failure = ControllerFailure.unreachable(ControllerAddress.display(base))
            fail(failure, retryAfter: 2)
            return .failure(failure)
        }
        if reply.status == 401 {
            let failure: ControllerFailure = secret.isEmpty ? .secretMissing : .unauthorized
            fail(failure, retryAfter: 0)
            return .failure(failure)
        }
        guard reply.status == 200, let parsed = Self.parseConnections(reply.body) else {
            lastFailure = .badResponse
            return .failure(.badResponse)
        }

        if parsed.total > 0, parsed.items.isEmpty {   // entries came, none had the fields we need
            lastFailure = .badResponse
            return .failure(.badResponse)
        }

        var routes = parsed.items.map { classify($0.chains) }
        if routes.contains(.unknown), refreshProxyTypes(minAgeSeconds: 3) {
            routes = parsed.items.map { classify($0.chains) }
        }
        let samples = zip(parsed.items, routes).map { item, route in
            Sample(id: item.id, upload: item.upload, download: item.download, route: route,
                   chains: item.chains, node: leafNode(item.chains), target: item.target,
                   network: item.network, rule: item.rule)
        }
        lastFailure = nil
        return .success(PollData(version: version, samples: samples, total: parsed.total,
                                 parsed: parsed.items.count, outbounds: proxyTypes.count,
                                 kernelUpload: parsed.kernelUp, kernelDownload: parsed.kernelDown))
    }

    private func fail(_ failure: ControllerFailure, retryAfter seconds: Double) {
        lastFailure = failure
        if failure == .unauthorized || failure == .secretMissing { stopped = failure }
        nextAttempt = DispatchTime.now().uptimeNanoseconds &+ UInt64(seconds * 1_000_000_000)
    }

    private func resetLocked() {
        address = nil
        stopped = nil
        lastFailure = nil
        nextAttempt = 0
        proxyTypes = [:]
        proxyTypesTriedAt = 0
        secretLoaded = false
    }

    /// Picks up a changed controller address (import, reset, typing) and loads the secret once.
    private func applyConfiguration() {
        let manual = Preferences.shared.controllerAddress
        if appliedManual != manual {
            if appliedManual != nil { resetLocked() }
            appliedManual = manual
        }
        if !secretLoaded {
            secret = ControllerSecretStore.load() ?? ""
            secretLoaded = true
        }
    }

    // MARK: - Direct or proxy

    /// Direct when any tag in the chain is an outbound of type Direct. Unknown when some tag is
    /// not in the table (yet) and none is a known Direct one.
    private func classify(_ chains: [String]) -> Route {
        if chains.isEmpty { return .unknown }
        var missing = false
        for tag in chains {
            guard let type = proxyTypes[tag] else { missing = true; continue }
            if type == "direct" { return .direct }
        }
        return missing ? .unknown : .proxy
    }

    /// Outbound types that only pick another outbound (策略组): never the node itself.
    private static let groupTypes: Set<String> = [
        "selector", "urltest", "url-test", "fallback", "loadbalance", "load-balance", "relay"
    ]

    /// The node a connection really leaves through: the first tag in the chain that is not a group
    /// (kernels list the chain leaf-first or group-first; a chain holds one leaf, so the order does
    /// not matter). Falls back to the first tag while the outbound table is not known yet.
    private func leafNode(_ chains: [String]) -> String {
        for tag in chains {
            if let type = proxyTypes[tag], !Self.groupTypes.contains(type) { return tag }
        }
        return chains.first ?? ""
    }

    /// Reloads `GET /proxies`, at most once per `minAgeSeconds`. True when the table was replaced.
    @discardableResult
    private func refreshProxyTypes(minAgeSeconds: Double) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if proxyTypesTriedAt != 0, Double(now &- proxyTypesTriedAt) / 1_000_000_000 < minAgeSeconds { return false }
        proxyTypesTriedAt = now
        guard let base = address,
              let reply = get(base, "/proxies", withSecret: true, timeout: 3),
              reply.status == 200,
              let table = Self.parseProxyTypes(reply.body) else { return false }
        proxyTypes = table
        return true
    }

    // MARK: - Discovery

    private func discover() -> Result<Found, ControllerFailure> {
        let manual = Preferences.shared.controllerAddress
        if !manual.isEmpty {
            guard let base = ControllerAddress.baseURL(from: manual) else { return .failure(.badAddress) }
            return verify(base)                        // the user named it: the secret goes there
        }

        let bases = candidateBases()
        var outcomes = [Probe](repeating: .none, count: bases.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: bases.count) { i in
            let outcome = self.probe(bases[i])
            lock.lock()
            outcomes[i] = outcome
            lock.unlock()
        }

        for (i, outcome) in outcomes.enumerated() {
            if case .controller(let v) = outcome { return .success(Found(base: bases[i], version: v)) }
        }
        for (i, outcome) in outcomes.enumerated() {
            if case .needsSecret = outcome { return verify(bases[i]) }
        }
        return .failure(.notFound)
    }

    /// Unauthenticated `GET /version`: never sends the secret to something that is not a controller.
    private func probe(_ base: String) -> Probe {
        guard let reply = get(base, "/version", withSecret: false, timeout: 1.5) else { return .none }
        if reply.status == 401 { return .needsSecret }
        if reply.status == 200, let v = Self.versionString(reply.body) { return .controller(v) }
        return .none
    }

    /// `GET /version` with the secret.
    private func verify(_ base: String) -> Result<Found, ControllerFailure> {
        guard let reply = get(base, "/version", withSecret: true, timeout: 2) else {
            return .failure(.unreachable(ControllerAddress.display(base)))
        }
        switch reply.status {
        case 200:
            guard let v = Self.versionString(reply.body) else { return .failure(.badResponse) }
            return .success(Found(base: base, version: v))
        case 401:
            return .failure(secret.isEmpty ? .secretMissing : .unauthorized)
        default:
            return .failure(.badResponse)
        }
    }

    /// Cached address, 127.0.0.1:9090, then every port that listens on the loopback (or on all
    /// addresses) according to `netstat`, the usual controller ports first.
    private func candidateBases() -> [String] {
        var out: [String] = []
        func add(_ base: String) { if !out.contains(base) { out.append(base) } }
        if let good = lastGood { add(good) }
        add("http://127.0.0.1:9090")
        for base in Self.loopbackListeners() { add(base) }
        return Array(out.prefix(Self.maxCandidates))
    }

    private static func loopbackListeners() -> [String] {
        guard let text = run("/usr/sbin/netstat", ["-an", "-p", "tcp"], timeout: 1.5) else { return [] }
        var byPort: [Int: String] = [:]
        for line in text.split(separator: "\n") where line.contains("LISTEN") {
            // tcp4  0  0  127.0.0.1.9090  *.*  LISTEN     (columns: proto recv-q send-q local ...)
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 4 else { continue }
            let local = String(cols[3])
            guard let dot = local.lastIndex(of: "."),
                  let port = Int(local[local.index(after: dot)...]), (1...65535).contains(port) else { continue }
            switch String(local[..<dot]) {
            case "127.0.0.1", "*", "localhost": byPort[port] = "http://127.0.0.1:\(port)"
            case "::1": if byPort[port] == nil { byPort[port] = "http://[::1]:\(port)" }
            default: continue
            }
        }
        func rank(_ port: Int) -> Int { commonPorts.firstIndex(of: port) ?? commonPorts.count }
        return byPort.keys.sorted { (rank($0), $0) < (rank($1), $1) }.compactMap { byPort[$0] }
    }

    /// Runs a tool and returns its output; killed after `timeout`. Output is read while the tool
    /// runs, so a long listing cannot fill the pipe and stall it.
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        killer.cancel()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - HTTP

    private func get(_ base: String, _ path: String, withSecret: Bool, timeout: TimeInterval) -> Reply? {
        guard let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if withSecret, !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        let done = DispatchSemaphore(value: 0)
        var reply: Reply?
        let task = session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                reply = Reply(status: http.statusCode, body: data ?? Data())
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            return nil
        }
        return reply
    }

    // MARK: - Parsing (defensive: a missing field is "not parsed", never a crash)

    private static func versionString(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = object["version"] as? String else { return nil }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseProxyTypes(_ data: Data) -> [String: String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = object["proxies"] as? [String: Any] else { return nil }
        var table: [String: String] = [:]
        for (tag, value) in proxies {
            if let entry = value as? [String: Any], let type = entry["type"] as? String {
                table[tag] = type.lowercased()
            }
        }
        return table
    }

    private static func parseConnections(_ data: Data)
        -> (items: [Item], total: Int, kernelUp: UInt64?, kernelDown: UInt64?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["connections"] else { return nil }

        func bytes(_ value: Any?) -> UInt64? {
            guard let n = value as? NSNumber else { return nil }
            return UInt64(max(0, n.int64Value))
        }
        func text(_ value: Any?) -> String? {
            if let s = value as? String, !s.isEmpty { return s }
            if let n = value as? NSNumber { return n.stringValue }
            return nil
        }
        let kernelUp = bytes(object["uploadTotal"])
        let kernelDown = bytes(object["downloadTotal"])

        if raw is NSNull { return ([], 0, kernelUp, kernelDown) }   // an empty list may come as null
        guard let list = raw as? [Any] else { return nil }
        var items: [Item] = []
        items.reserveCapacity(list.count)
        for element in list {
            guard let c = element as? [String: Any],
                  let id = c["id"] as? String,
                  let up = bytes(c["upload"]), let down = bytes(c["download"]),
                  let chains = c["chains"] as? [Any] else { continue }
            let meta = c["metadata"] as? [String: Any] ?? [:]
            var target = text(meta["host"]) ?? text(meta["destinationIP"]) ?? ""
            if !target.isEmpty, let port = text(meta["destinationPort"]) { target += ":" + port }
            items.append(Item(id: id, upload: up, download: down,
                              chains: chains.compactMap { $0 as? String },
                              target: target, network: text(meta["network"]) ?? "",
                              rule: text(c["rule"]) ?? ""))
        }
        return (items, list.count, kernelUp, kernelDown)
    }
}
