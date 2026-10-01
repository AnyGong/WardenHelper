// SubscriptionKit.swift
//
// Foundation-only subscription fetching and plan extraction: downloads a Clash-format
// subscription (retry, TTL cache, stale-cache fallback), parses it, and reads the remaining
// traffic and expiry date from the provider's info nodes.
//
// Providers put informational pseudo-nodes in the proxy list ("剩余流量：43.29GB",
// "距离下次重置剩余：5天", "套餐到期：2026-12-31"). The extractor finds those nodes by name
// and pulls the values out of the names. Traffic and reset days read this way are only a
// snapshot of the moment the subscription was generated; live traffic comes from the
// `subscription-userinfo` response header (SubscriptionUserInfo).
//
// The built-in YAML reader covers Clash subscriptions, not general YAML: no anchors,
// aliases or tags, no block scalars (| >), no multi-line flow collections or plain scalars.
// Unsupported input throws, and the base64 fallback is then tried.

import Foundation

// MARK: - Logging & errors

enum SubLogLevel: String, Sendable { case debug, note, success, warning, error }
typealias SubLogger = @Sendable (SubLogLevel, String) -> Void

let defaultSubLogger: SubLogger = { level, message in
    print("[\(level.rawValue.uppercased())] \(message)")
}

enum SubscriptionError: Error, CustomStringConvertible {
    case config(String)
    case fetch(String)
    case parse(String)

    var description: String {
        switch self {
        case .config(let m), .fetch(let m), .parse(let m): return m
        }
    }
}

private func describe(_ error: Error) -> String {
    (error as? SubscriptionError)?.description ?? error.localizedDescription
}

/// Timezone that `expir_date` values and the alert date math use (UTC+8).
let subscriptionTimeZone = TimeZone(secondsFromGMT: 8 * 3600)!

private func stripBOM(_ s: String) -> String {
    var t = Substring(s)
    while t.hasPrefix("\u{feff}") { t = t.dropFirst() }
    return String(t)
}

// MARK: - Minimal JSON tree (distinguishes Bool from numbers, unlike JSONSerialization)

private enum JSONValue: Decodable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value") }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}

// MARK: - Subscription config (config/subscriptions.json)

/// {"subscribe": [{"name", "url", "enable"?, "expir_date"?}]}
struct SubscriptionEntry: Sendable {
    var name: String
    var url: String
    /// Explicit `false` => loaded but never pulled.
    var enable: Bool = true
    var expirDateRaw: String?
    var expirDate: Date?
}

enum SubscriptionConfig {

    /// Loads and structurally validates the "subscribe" list. A missing or
    /// unparseable file is a hard error; malformed entries are dropped with a
    /// warning. Invalid `enable`/`expir_date` values fail open (enabled,
    /// non-expiring) with a warning.
    static func load(from fileURL: URL, log: SubLogger = defaultSubLogger) throws -> [SubscriptionEntry] {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw SubscriptionError.config("\(path) does not exist.")
        }
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fileURL))
        } catch {
            throw SubscriptionError.config("could not parse \(path) as JSON: \(error.localizedDescription)")
        }
        guard case .object(let obj) = root else {
            throw SubscriptionError.config("\(path) does not contain a JSON object at its top level")
        }

        let rawSubs: [JSONValue]
        switch obj["subscribe"] {
        case nil: rawSubs = []
        case .array(let a)?: rawSubs = a
        default: throw SubscriptionError.config("\(path)'s 'subscribe' key must be a JSON array")
        }

        var subs: [SubscriptionEntry] = []
        for (i, raw) in rawSubs.enumerated() {
            guard case .object(let e) = raw else {
                log(.warning, "\(path): dropping non-object 'subscribe' entry at index \(i)")
                continue
            }
            guard let name = e["name"]?.stringValue,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log(.warning, "\(path): dropping 'subscribe' entry at index \(i) with a missing/empty 'name'")
                continue
            }
            guard let url = e["url"]?.stringValue,
                  !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log(.warning, "\(path): dropping 'subscribe' entry '\(name)' with a missing/empty 'url'")
                continue
            }

            var entry = SubscriptionEntry(name: name, url: url)

            switch e["enable"] {
            case nil: break
            case .bool(let b)?: entry.enable = b
            default:
                log(.warning, "\(path): subscribe entry '\(name)' has a non-boolean 'enable'; treating as enabled")
            }

            switch e["expir_date"] {
            case nil, .null?: break
            case .string(let s)?:
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    log(.warning, "\(path): subscribe entry '\(name)' has an invalid 'expir_date' (\(s)); ignoring expiration")
                } else if let d = parseISODate(trimmed) {
                    entry.expirDateRaw = trimmed
                    entry.expirDate = d
                } else {
                    log(.warning, "\(path): subscribe entry '\(name)' has an unparseable 'expir_date' (\(s)); ignoring expiration")
                }
            default:
                log(.warning, "\(path): subscribe entry '\(name)' has an invalid 'expir_date'; ignoring expiration")
            }

            subs.append(entry)
        }

        if subs.isEmpty { log(.warning, "no usable 'subscribe' entries found in \(path)") }
        return subs
    }

    /// Drops entries that must not be pulled now: `enable == false`, or
    /// `expir_date` already in the past. Fetch only the returned list.
    static func filterActive(_ subs: [SubscriptionEntry], now: Date = Date(),
                             log: SubLogger = defaultSubLogger) -> [SubscriptionEntry] {
        var active: [SubscriptionEntry] = []
        for entry in subs {
            if !entry.enable {
                log(.warning, "[\(entry.name)] subscription disabled ('enable': false); skipping pull")
                continue
            }
            if let exp = entry.expirDate, exp < now {
                log(.warning, "[\(entry.name)] subscription expired (expir_date=\(entry.expirDateRaw ?? "?")); skipping pull")
                continue
            }
            active.append(entry)
        }
        log(.note, "\(active.count)/\(subs.count) subscription(s) remaining after enable/expiration filtering")
        return active
    }

    /// ISO-8601-ish parser; values without an explicit offset are UTC+8.
    static func parseISODate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = subscriptionTimeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                       "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = format
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - Fetching (retry, TTL cache, url sidecar, stale-cache fallback)

enum FetchStatus: String, Sendable { case live, cached, failed }

struct SubscriptionFetchOptions: Sendable {
    var userAgent = "mihomo.party/v2.0.0 (clash.meta)"
    var retries = 2
    var retryDelay: TimeInterval = 2.0
    var timeout: TimeInterval = 20
    var concurrency = 8
    /// 0 disables the local TTL cache.
    var cacheTTLMinutes = 10
    /// FORCE_REFRESH=1/true/yes bypasses the TTL cache.
    var forceRefresh = ["1", "true", "yes"].contains(
        (ProcessInfo.processInfo.environment["FORCE_REFRESH"] ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased())
    /// The TTL cache is never consulted under GitHub Actions.
    var runningInCI = (ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] ?? "")
        .trimmingCharacters(in: .whitespaces).lowercased() == "true"
}

/// Live usage reported by the provider's subscription endpoint in the `subscription-userinfo`
/// response header, e.g. `upload=1; download=2; total=3; expire=4` (bytes, unix seconds).
struct SubscriptionUserInfo: Sendable, Equatable {
    var upload: Double?
    var download: Double?
    var total: Double?

    /// Remaining traffic in GB (1 GB = 1024³ bytes). nil without a positive `total` and at
    /// least one usage counter.
    var remainingGB: Double? {
        guard let total = total, total > 0, upload != nil || download != nil else { return nil }
        return max(0, total - (upload ?? 0) - (download ?? 0)) / 1_073_741_824
    }

    /// nil when the header does not describe a usable quota.
    static func parse(_ header: String) -> SubscriptionUserInfo? {
        var info = SubscriptionUserInfo()
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let value = Double(kv[1]) else { continue }
            switch kv[0].lowercased() {
            case "upload": info.upload = value
            case "download": info.download = value
            case "total": info.total = value
            default: break
            }
        }
        return info.remainingGB == nil ? nil : info
    }
}

/// Cache layout:
///   <subsDir>/<stem>.yaml       raw subscription text
///   <subsDir>/<stem>.yaml.url   url that produced it (a changed url invalidates the cache)
final class SubscriptionFetcher: Sendable {
    let subsDir: URL
    let options: SubscriptionFetchOptions
    private let log: SubLogger
    private let session: URLSession

    init(subsDir: URL, options: SubscriptionFetchOptions = .init(), log: @escaping SubLogger = defaultSubLogger) {
        self.subsDir = subsDir
        self.options = options
        self.log = log
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = options.timeout
        cfg.httpMaximumConnectionsPerHost = max(10, options.concurrency)
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    /// Turns a subscription name into a safe cache-file stem: runs of
    /// `\ / : * ? " < > |` become "-", surrounding whitespace and dots are
    /// trimmed, empty becomes "unnamed".
    static func cacheFilenameStem(_ name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "\\/:*?\"<>|")
        var out = ""
        var inRun = false
        for scalar in name.unicodeScalars {
            if unsafe.contains(scalar) {
                if !inRun { out.append("-"); inRun = true }
            } else {
                out.unicodeScalars.append(scalar)
                inRun = false
            }
        }
        let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "unnamed" : cleaned
    }

    // MARK: single subscription

    /// Fetches one subscription's raw text. Returns `(text, fromCache, userInfo)`; `userInfo`
    /// is only present for a live download whose response carried a usable header.
    /// Order: fresh-enough TTL cache -> live download with retries -> stale
    /// cache (only if it came from the same url). Throws only when the live
    /// fetch fails and no usable cache exists.
    func fetchText(_ entry: SubscriptionEntry) async throws
        -> (text: String, fromCache: Bool, userInfo: SubscriptionUserInfo?) {
        let name = entry.name, url = entry.url
        let stem = Self.cacheFilenameStem(name)
        let cachePath = subsDir.appendingPathComponent("\(stem).yaml")
        let fm = FileManager.default
        let ttl = TimeInterval(options.cacheTTLMinutes * 60)
        var lastError: Error?

        if ttl > 0, !options.forceRefresh, !options.runningInCI, fm.fileExists(atPath: cachePath.path) {
            if let cachedURL = readCachedURL(stem), cachedURL != url {
                log(.note, "[\(name)] cached copy was fetched from a different url than the one now configured; fetching live")
            } else if let mtime = modificationDate(cachePath),
                      Date().timeIntervalSince(mtime) < ttl,
                      let text = try? readCache(cachePath) {
                log(.note, "[\(name)] cache is \(cacheAge(cachePath)) (ttl \(options.cacheTTLMinutes)m); reusing without a network fetch")
                return (text, true, nil)
            }
        }

        let attempts = max(1, options.retries)
        for attempt in 1...attempts {
            do {
                log(.note, "[\(name)] fetching (attempt \(attempt)/\(attempts), User-Agent: \(options.userAgent))")
                let downloaded = try await download(url)
                let text = downloaded.text
                try fm.createDirectory(at: subsDir, withIntermediateDirectories: true)
                try text.write(to: cachePath, atomically: true, encoding: .utf8)
                try url.write(to: sidecar(stem), atomically: true, encoding: .utf8)
                log(.success, "[\(name)] saved raw subscription to \(cachePath.path)")
                if let gb = downloaded.userInfo?.remainingGB {
                    log(.note, "[\(name)] subscription-userinfo header: \(String(format: "%.2f", gb)) GB remaining")
                }
                return (text, false, downloaded.userInfo)
            } catch {
                lastError = error
                log(.warning, "[\(name)] fetch attempt \(attempt)/\(attempts) failed: \(describe(error))")
            }
            if attempt < attempts {
                // Linear backoff + jitter so concurrent workers don't retry in lockstep.
                let delay = options.retryDelay * Double(attempt) + Double.random(in: 0...(options.retryDelay * 0.5))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        let why = lastError.map(describe) ?? "unknown error"
        if fm.fileExists(atPath: cachePath.path) {
            if let cachedURL = readCachedURL(stem), cachedURL != url {
                throw SubscriptionError.fetch(
                    "live fetch failed (\(why)) and the only cache on disk (\(cachePath.path)) was fetched from a different url")
            }
            log(.warning, "[\(name)] live fetch failed (\(why)); using cached copy from \(cachePath.path) (\(cacheAge(cachePath)))")
            return (try readCache(cachePath), true, nil)
        }
        throw SubscriptionError.fetch("live fetch failed (\(why)) and no cached copy exists at \(cachePath.path)")
    }

    // MARK: all subscriptions

    /// Fetches every entry concurrently (bounded by `options.concurrency`).
    /// `subs` must already be the active list. `texts` only has entries that
    /// succeeded (live or cached).
    func fetchAll(_ subs: [SubscriptionEntry]) async -> (texts: [String: String], summary: [String: FetchStatus]) {
        struct Outcome: Sendable { let name: String; let text: String?; let fromCache: Bool; let error: String? }

        var texts: [String: String] = [:]
        var summary: [String: FetchStatus] = [:]
        let limit = max(1, min(options.concurrency, max(subs.count, 1)))

        await withTaskGroup(of: Outcome.self) { group in
            var next = 0
            func work(_ entry: SubscriptionEntry) -> (@Sendable () async -> Outcome) {
                return { [self] in
                    do {
                        let r = try await self.fetchText(entry)
                        return Outcome(name: entry.name, text: r.text, fromCache: r.fromCache, error: nil)
                    } catch {
                        return Outcome(name: entry.name, text: nil, fromCache: false, error: describe(error))
                    }
                }
            }
            while next < min(limit, subs.count) {
                group.addTask(operation: work(subs[next])); next += 1
            }
            while let done = await group.next() {
                if let text = done.text {
                    texts[done.name] = text
                    summary[done.name] = done.fromCache ? .cached : .live
                } else {
                    log(.error, "could not load subscription '\(done.name)': \(done.error ?? "unknown error")")
                    summary[done.name] = .failed
                }
                if next < subs.count {
                    group.addTask(operation: work(subs[next])); next += 1
                }
            }
        }
        return (texts, summary)
    }

    // MARK: private helpers

    private func download(_ urlString: String) async throws -> (text: String, userInfo: SubscriptionUserInfo?) {
        guard let url = URL(string: urlString) else {
            throw SubscriptionError.fetch("invalid url")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: options.timeout)
        req.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        var userInfo: SubscriptionUserInfo?
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                throw SubscriptionError.fetch("HTTP \(http.statusCode)")
            }
            userInfo = http.value(forHTTPHeaderField: "subscription-userinfo").flatMap(SubscriptionUserInfo.parse)
        }
        return (stripBOM(String(decoding: data, as: UTF8.self)), userInfo)
    }

    private func sidecar(_ stem: String) -> URL { subsDir.appendingPathComponent("\(stem).yaml.url") }

    private func readCachedURL(_ stem: String) -> String? {
        guard let s = try? String(contentsOf: sidecar(stem), encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func readCache(_ url: URL) throws -> String {
        stripBOM(try String(contentsOf: url, encoding: .utf8))
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func cacheAge(_ url: URL) -> String {
        guard let m = modificationDate(url) else { return "unknown age" }
        let secs = Int(Date().timeIntervalSince(m))
        if secs < 3600 { return "\(secs / 60) min old" }
        if secs < 86400 { return "\(secs / 3600) h old" }
        return "\(secs / 86400) d old"
    }
}

// MARK: - Clash subscription parsing

enum YAMLValue: Equatable, Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String)
    case array([YAMLValue]), map([String: YAMLValue])

    /// String form of scalars (numbers/bools included); nil for null/collections.
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
}

struct ClashProxy: Sendable, Equatable {
    let name: String
    let fields: [String: YAMLValue]
    var type: String? { fields["type"]?.stringValue }
    var server: String? { fields["server"]?.stringValue }
    var port: Int? {
        switch fields["port"] {
        case .int(let i)?: return i
        case .string(let s)?: return Int(s)
        default: return nil
        }
    }
}

enum ClashSubscriptionParser {

    /// Raw subscription text -> proxy list. Handles: UTF-8 BOM, a `proxies:`
    /// key, a bare top-level list, `proxy:`/`proxys:` spellings, and a
    /// base64-wrapped body. Entries that aren't maps or lack a name are dropped.
    static func parse(_ text: String, log: SubLogger = defaultSubLogger) throws -> [ClashProxy] {
        let cleaned = stripBOM(text)
        var data: YAMLValue?
        var yamlError: String?

        do { data = try MiniYAMLParser.parse(cleaned) }
        catch { yamlError = describe(error); log(.debug, "YAML parsing failed (\(describe(error))); trying base64 decode") }

        // A base64 blob parses as a plain YAML scalar, so a bare string result also
        // triggers the base64 fallback.
        var needsFallback = data == nil
        if case .string(_)? = data { needsFallback = true }
        if needsFallback, let decoded = decodeBase64(cleaned), let inner = try? MiniYAMLParser.parse(decoded) {
            log(.note, "base64-decoded subscription body")
            data = inner
        }

        guard let value = data else {
            throw SubscriptionError.parse("failed to parse YAML subscription: \(yamlError ?? "empty")")
        }

        switch value {
        case .map(let dict):
            if let list = dict["proxies"] {
                if case .array(let a) = list { return proxies(from: a) }
                return []
            }
            for key in dict.keys.sorted() where ["proxies", "proxy", "proxys"].contains(key.lowercased()) {
                if case .array(let a)? = dict[key] {
                    log(.note, "subscription has no 'proxies:' key, but found '\(key):'; using that as the proxy list")
                    return proxies(from: a)
                }
            }
        case .array(let a):
            log(.note, "subscription appears to be a bare proxy list; treating the whole YAML as proxies")
            return proxies(from: a)
        default:
            break
        }
        throw SubscriptionError.parse(
            "subscription does not look like a Clash config (missing top-level 'proxies:' key). preview: \(String(describing: value).prefix(200))")
    }

    private static func proxies(from list: [YAMLValue]) -> [ClashProxy] {
        list.compactMap { item in
            guard case .map(let m) = item, let name = m["name"]?.stringValue, !name.isEmpty else { return nil }
            return ClashProxy(name: name, fields: m)
        }
    }

    private static func decodeBase64(_ text: String) -> String? {
        var s = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !s.isEmpty else { return nil }
        while s.count % 4 != 0 { s.append("=") }
        guard let data = Data(base64Encoded: s), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Minimal YAML subset reader

struct YAMLParseError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private let quoteOpeners: Set<Character> = [" ", "\t", "{", "[", ",", ":"]

/// Cuts a trailing `# comment` (a `#` at line start or after whitespace,
/// outside quotes).
private func stripComment(_ s: String) -> String {
    let chars = Array(s)
    var quote: Character?
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if let q = quote {
            if q == "\"", c == "\\" { i += 2; continue }
            if c == q {
                if q == "'", i + 1 < chars.count, chars[i + 1] == "'" { i += 2; continue }
                quote = nil
            }
        } else if (c == "\"" || c == "'"), i == 0 || quoteOpeners.contains(chars[i - 1]) {
            quote = c
        } else if c == "#", i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t" {
            return String(chars[..<i])
        }
        i += 1
    }
    return s
}

/// Splits `key: value` at the first top-level ": " (or trailing ":") that is
/// outside quotes and brackets. nil when the text isn't a mapping entry.
private func splitKey(_ text: String) -> (key: String, value: String)? {
    let chars = Array(text)
    var quote: Character?
    var depth = 0
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if let q = quote {
            if q == "\"", c == "\\" { i += 2; continue }
            if c == q {
                if q == "'", i + 1 < chars.count, chars[i + 1] == "'" { i += 2; continue }
                quote = nil
            }
        } else if (c == "\"" || c == "'"), i == 0 || quoteOpeners.contains(chars[i - 1]) {
            quote = c
        } else if c == "{" || c == "[" {
            depth += 1
        } else if c == "}" || c == "]" {
            depth = max(0, depth - 1)
        } else if c == ":", depth == 0, i + 1 == chars.count || chars[i + 1] == " " || chars[i + 1] == "\t" {
            let key = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
            let value = String(chars[min(i + 1, chars.count)...]).trimmingCharacters(in: .whitespaces)
            return (key, value)
        }
        i += 1
    }
    return nil
}

private func isSeqItem(_ text: String) -> Bool {
    text == "-" || text.hasPrefix("- ") || text.hasPrefix("-\t")
}

/// Plain (unquoted) scalar or already-extracted token -> typed value.
private func yamlScalar(_ s: String) throws -> YAMLValue {
    if s.hasPrefix("\"") || s.hasPrefix("'") {
        var fp = FlowParser(s)
        let str = try fp.parseQuoted()
        fp.skipWS()
        guard fp.atEnd else { throw YAMLParseError("unexpected text after quoted string") }
        return .string(str)
    }
    if let f = s.first, "&*|>!@`".contains(f) {
        throw YAMLParseError("unsupported YAML construct (anchor/alias/tag/block scalar): \(s.prefix(20))")
    }
    switch s {
    case "", "~", "null", "Null", "NULL": return .null
    case "true", "True", "TRUE": return .bool(true)
    case "false", "False", "FALSE": return .bool(false)
    default: break
    }
    if let first = s.first, let last = s.last, last.isNumber,
       first.isNumber || "+-.".contains(first),
       s.allSatisfy({ "0123456789+-.eE".contains($0) }) {
        if let i = Int(s) { return .int(i) }
        if let d = Double(s) { return .double(d) }
    }
    return .string(s)
}

private struct FlowParser {
    let chars: [Character]
    var i = 0

    init(_ s: String) { chars = Array(s) }

    var atEnd: Bool { i >= chars.count }

    mutating func skipWS() {
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
    }

    mutating func parseValue() throws -> YAMLValue {
        skipWS()
        guard i < chars.count else { return .null }
        switch chars[i] {
        case "{": return try parseMap()
        case "[": return try parseSeq()
        case "\"", "'": return .string(try parseQuoted())
        default: return try parsePlain()
        }
    }

    mutating func parseMap() throws -> YAMLValue {
        i += 1
        var d: [String: YAMLValue] = [:]
        while true {
            skipWS()
            guard i < chars.count else { throw YAMLParseError("unterminated flow mapping") }
            if chars[i] == "}" { i += 1; break }
            let key = try parseKey()
            skipWS()
            var value: YAMLValue = .null
            if i < chars.count, chars[i] == ":" { i += 1; value = try parseValue() }
            d[key] = value
            skipWS()
            guard i < chars.count else { throw YAMLParseError("unterminated flow mapping") }
            if chars[i] == "," { i += 1 }
            else if chars[i] != "}" { throw YAMLParseError("expected ',' or '}' in flow mapping") }
        }
        return .map(d)
    }

    mutating func parseSeq() throws -> YAMLValue {
        i += 1
        var a: [YAMLValue] = []
        while true {
            skipWS()
            guard i < chars.count else { throw YAMLParseError("unterminated flow sequence") }
            if chars[i] == "]" { i += 1; break }
            a.append(try parseValue())
            skipWS()
            guard i < chars.count else { throw YAMLParseError("unterminated flow sequence") }
            if chars[i] == "," { i += 1 }
            else if chars[i] != "]" { throw YAMLParseError("expected ',' or ']' in flow sequence") }
        }
        return .array(a)
    }

    mutating func parseKey() throws -> String {
        skipWS()
        if i < chars.count, chars[i] == "\"" || chars[i] == "'" { return try parseQuoted() }
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if c == "," || c == "}" { break }
            if c == ":", i + 1 >= chars.count || chars[i + 1] == " " || chars[i + 1] == "\t" { break }
            out.append(c)
            i += 1
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    mutating func parsePlain() throws -> YAMLValue {
        var out = ""
        while i < chars.count, !",}]".contains(chars[i]) {
            out.append(chars[i])
            i += 1
        }
        return try yamlScalar(out.trimmingCharacters(in: .whitespaces))
    }

    mutating func parseQuoted() throws -> String {
        let q = chars[i]
        i += 1
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if q == "'" {
                if c == "'" {
                    if i + 1 < chars.count, chars[i + 1] == "'" { out.append("'"); i += 2; continue }
                    i += 1
                    return out
                }
                out.append(c)
                i += 1
            } else {
                if c == "\"" { i += 1; return out }
                if c == "\\" {
                    i += 1
                    guard i < chars.count else { break }
                    let e = chars[i]
                    i += 1
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "0": out.append("\0")
                    case "u":
                        var code = try readHex(4)
                        if (0xD800...0xDBFF).contains(code), i + 1 < chars.count, chars[i] == "\\", chars[i + 1] == "u" {
                            i += 2
                            let low = try readHex(4)
                            code = 0x10000 + ((code - 0xD800) << 10) + (low &- 0xDC00)
                        }
                        if let scalar = Unicode.Scalar(code) { out.unicodeScalars.append(scalar) }
                    case "x":
                        if let scalar = Unicode.Scalar(try readHex(2)) { out.unicodeScalars.append(scalar) }
                    case "U":
                        if let scalar = Unicode.Scalar(try readHex(8)) { out.unicodeScalars.append(scalar) }
                    default: out.append(e)    // \" \\ \/ and anything else: the char itself
                    }
                } else {
                    out.append(c)
                    i += 1
                }
            }
        }
        throw YAMLParseError("unterminated quoted string")
    }

    private mutating func readHex(_ n: Int) throws -> UInt32 {
        guard i + n <= chars.count, let v = UInt32(String(chars[i..<(i + n)]), radix: 16) else {
            throw YAMLParseError("bad hex escape")
        }
        i += n
        return v
    }
}

/// Indentation-based block parser for the YAML subset Clash subscriptions use.
struct MiniYAMLParser {
    private struct Line { var indent: Int; var text: String }
    private var lines: [Line] = []
    private var pos = 0

    static func parse(_ text: String) throws -> YAMLValue {
        var p = try MiniYAMLParser(text)
        return try p.parseDocument()
    }

    private init(_ text: String) throws {
        for raw in text.components(separatedBy: .newlines) {
            var indent = 0
            var idx = raw.startIndex
            while idx < raw.endIndex, raw[idx] == " " { indent += 1; idx = raw.index(after: idx) }
            if idx < raw.endIndex, raw[idx] == "\t" {
                if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                throw YAMLParseError("tab indentation is not allowed in YAML")
            }
            let body = stripComment(String(raw[idx...])).trimmingCharacters(in: .whitespaces)
            if body.isEmpty || body == "---" || body == "..." { continue }
            if indent == 0, body.hasPrefix("%") { continue }
            lines.append(Line(indent: indent, text: body))
        }
    }

    private mutating func parseDocument() throws -> YAMLValue {
        guard !lines.isEmpty else { return .null }
        let value = try parseBlock(indent: lines[0].indent)
        guard pos >= lines.count else {
            throw YAMLParseError("unexpected content at line \(pos + 1) of the document")
        }
        return value
    }

    private mutating func parseBlock(indent: Int) throws -> YAMLValue {
        let text = lines[pos].text
        if isSeqItem(text) { return try parseSequence(indent: indent) }
        if splitKey(text) != nil { return try parseMapping(indent: indent) }
        pos += 1
        return try parseInline(text)
    }

    private mutating func parseSequence(indent: Int) throws -> YAMLValue {
        var items: [YAMLValue] = []
        while pos < lines.count, lines[pos].indent == indent, isSeqItem(lines[pos].text) {
            let text = lines[pos].text
            let rest = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                pos += 1
                if pos < lines.count, lines[pos].indent > indent {
                    items.append(try parseBlock(indent: lines[pos].indent))
                } else {
                    items.append(.null)
                }
            } else if isSeqItem(rest) || splitKey(rest) != nil {
                // "- key: v" / "- - x": re-seat the remainder as a deeper block line.
                let offset = text.count - rest.count
                lines[pos] = Line(indent: indent + offset, text: rest)
                items.append(try parseBlock(indent: indent + offset))
            } else {
                pos += 1
                items.append(try parseInline(rest))
            }
        }
        return .array(items)
    }

    private mutating func parseMapping(indent: Int) throws -> YAMLValue {
        var dict: [String: YAMLValue] = [:]
        while pos < lines.count, lines[pos].indent == indent, !isSeqItem(lines[pos].text) {
            guard let parts = splitKey(lines[pos].text) else {
                throw YAMLParseError("expected 'key: value' at line \(pos + 1)")
            }
            let key = try parseKey(parts.key)
            pos += 1
            if parts.value.isEmpty {
                if pos < lines.count {
                    let next = lines[pos]
                    if next.indent > indent {
                        dict[key] = try parseBlock(indent: next.indent)
                    } else if next.indent == indent, isSeqItem(next.text) {
                        dict[key] = try parseSequence(indent: indent)   // "key:\n- item" at the same indent
                    } else {
                        dict[key] = .null
                    }
                } else {
                    dict[key] = .null
                }
            } else {
                dict[key] = try parseInline(parts.value)
            }
        }
        return .map(dict)
    }

    private func parseKey(_ raw: String) throws -> String {
        if raw.hasPrefix("\"") || raw.hasPrefix("'") {
            return try yamlScalar(raw).stringValue ?? raw
        }
        return raw
    }

    private func parseInline(_ text: String) throws -> YAMLValue {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("{") || t.hasPrefix("[") {
            var fp = FlowParser(t)
            let v = try fp.parseValue()
            fp.skipWS()
            guard fp.atEnd else { throw YAMLParseError("unexpected text after flow collection") }
            return v
        }
        return try yamlScalar(t)
    }
}

// MARK: - Plan extraction (traffic / expiry from provider info nodes)

struct SubscriptionPlan: Sendable, Equatable {
    let subscriptionName: String
    var infoNodeNames: [String] = []
    /// "剩余流量" from the node name: a snapshot of when the subscription was generated.
    var remainingTrafficGB: Double?
    /// "距离下次重置剩余" from the node name, in days: a snapshot, not a countdown.
    var resetDays: Int?
    /// "yyyy-MM-dd" exactly as found in the node name.
    var expireDateString: String?
    /// Calendar days from today to the expiry date, in UTC+8 (negative = expired).
    var daysLeft: Int?
}

// MARK: - Extraction rules (user-editable regular expressions)

/// The four patterns that read a provider's info nodes. Each one has a built-in default.
enum SubscriptionRuleField: String, CaseIterable, Sendable {
    /// Which node names carry plan info at all; the other three only read the nodes it selects.
    case infoNode
    /// Remaining traffic: group 1 = number, group 2 = unit (K / M / G / T).
    case traffic
    /// Days until the next reset: group 1 = number of days.
    case reset
    /// Expiry date: group 1 = "yyyy-MM-dd".
    case expire

    /// Capture groups the pattern must have for the extractor to read it.
    var requiredGroups: Int {
        switch self {
        case .infoNode:       return 0
        case .traffic:        return 2
        case .reset, .expire: return 1
        }
    }

    var options: NSRegularExpression.Options {
        self == .traffic ? [.caseInsensitive] : []
    }

    /// UserDefaults key of the stored pattern.
    var storageKey: String { "subscriptionRule.\(rawValue)" }

    /// Trims the pattern and checks it: not empty, valid syntax, enough capture groups.
    func compile(_ pattern: String) -> Result<NSRegularExpression, SubscriptionRuleIssue> {
        let text = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        let re: NSRegularExpression
        do { re = try NSRegularExpression(pattern: text, options: options) }
        catch { return .failure(.syntax) }
        guard re.numberOfCaptureGroups >= requiredGroups else {
            return .failure(.groups(need: requiredGroups, have: re.numberOfCaptureGroups))
        }
        return .success(re)
    }

    /// The compiled pattern, or the built-in default when it does not pass `compile`.
    func compileOrDefault(_ pattern: String) -> NSRegularExpression {
        if case .success(let re) = compile(pattern) { return re }
        return try! NSRegularExpression(pattern: SubscriptionRuleSet.defaults[self], options: options)
    }
}

struct SubscriptionRuleSet: Equatable, Sendable {
    var infoNode: String
    var traffic: String
    var reset: String
    var expire: String

    static let defaults = SubscriptionRuleSet(
        infoNode: "剩余|到期|套餐|流量|重置|时间|有效期",
        // Full labels only ("剩余流量" and "距离下次重置剩余" are different fields); the colon
        // is ':' or '：' with optional spaces around it.
        traffic: #"剩余流量\s*[:：]\s*(\d+(?:\.\d+)?)\s*(GB|MB|TB|KB)"#,
        reset: #"距离下次重置剩余\s*[:：]\s*(\d+)\s*天"#,
        expire: #"套餐到期\s*[:：]\s*(\d{4}-\d{2}-\d{2})"#)

    subscript(field: SubscriptionRuleField) -> String {
        get {
            switch field {
            case .infoNode: return infoNode
            case .traffic:  return traffic
            case .reset:    return reset
            case .expire:   return expire
            }
        }
        set {
            switch field {
            case .infoNode: infoNode = newValue
            case .traffic:  traffic = newValue
            case .reset:    reset = newValue
            case .expire:   expire = newValue
            }
        }
    }
}

/// Why a pattern is unusable.
enum SubscriptionRuleIssue: Error, Equatable, Sendable {
    case empty
    case syntax
    case groups(need: Int, have: Int)
    /// There is no cached subscription content to test against.
    case noSample
    /// Valid, but nothing in the subscription matches it.
    case noMatch
    /// It matches, but the captured text is not the expected number / unit / date.
    case badCapture
}

/// What a passing pattern found in the sample.
enum SubscriptionRuleFound: Equatable, Sendable {
    case nodes(Int)
    case trafficGB(Double)
    case resetDays(Int)
    case expire(date: String, daysLeft: Int)
}

struct SubscriptionRuleReport: Sendable {
    var outcomes: [SubscriptionRuleField: Result<SubscriptionRuleFound, SubscriptionRuleIssue>]
    /// The candidate for every pattern that passed, the previous pattern for the rest.
    var accepted: SubscriptionRuleSet
    var allPassed: Bool {
        outcomes.count == SubscriptionRuleField.allCases.count
            && outcomes.values.allSatisfy { (try? $0.get()) != nil }
    }
}

enum SubscriptionRuleTester {
    /// Tests every candidate pattern on its own against `nodeNames` (all node names of the
    /// cached subscriptions). A pattern passes when it is valid and extracts something usable.
    /// The three value patterns read the nodes picked by the info-node pattern: the candidate
    /// when it passed, otherwise the previous one.
    static func test(candidate: SubscriptionRuleSet, previous: SubscriptionRuleSet,
                     nodeNames: [String], now: Date = Date()) -> SubscriptionRuleReport {
        let names = nodeNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var outcomes: [SubscriptionRuleField: Result<SubscriptionRuleFound, SubscriptionRuleIssue>] = [:]
        var accepted = previous
        var infoRegex = SubscriptionRuleField.infoNode.compileOrDefault(previous.infoNode)

        switch SubscriptionRuleField.infoNode.compile(candidate.infoNode) {
        case .failure(let issue):
            outcomes[.infoNode] = .failure(issue)
        case .success(let re):
            let hits = names.filter { matches(re, $0) }.count
            if names.isEmpty {
                outcomes[.infoNode] = .failure(.noSample)
            } else if hits == 0 {
                outcomes[.infoNode] = .failure(.noMatch)
            } else {
                outcomes[.infoNode] = .success(.nodes(hits))
                accepted.infoNode = candidate.infoNode.trimmingCharacters(in: .whitespacesAndNewlines)
                infoRegex = re
            }
        }
        let infoNames = names.filter { matches(infoRegex, $0) }

        for field in [SubscriptionRuleField.traffic, .reset, .expire] {
            switch field.compile(candidate[field]) {
            case .failure(let issue):
                outcomes[field] = .failure(issue)
            case .success(let re):
                if names.isEmpty { outcomes[field] = .failure(.noSample); continue }
                var matched = false
                var found: SubscriptionRuleFound?
                for name in infoNames {
                    guard let m = SubscriptionPlanExtractor.captures(re, in: name) else { continue }
                    matched = true
                    if let f = SubscriptionPlanExtractor.found(field, captures: m, now: now) {
                        found = f
                        break
                    }
                }
                if let found = found {
                    outcomes[field] = .success(found)
                    accepted[field] = candidate[field].trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    outcomes[field] = .failure(matched ? .badCapture : .noMatch)
                }
            }
        }
        return SubscriptionRuleReport(outcomes: outcomes, accepted: accepted)
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..<s.endIndex, in: s)) != nil
    }
}

/// One pasted node name and what the three value patterns captured from it.
struct SubscriptionRuleSampleLine: Sendable {
    let text: String
    /// Whether the info-node pattern selects this line; nil when that pattern is unusable
    /// (the value patterns then read every line, so they can still be tried).
    let isInfoNode: Bool?
    /// Only the value patterns that matched are present. `.success` = usable capture,
    /// `.failure(.badCapture)` = matched, but the captured text is not a number / unit / date.
    let results: [SubscriptionRuleField: Result<SubscriptionRuleFound, SubscriptionRuleIssue>]
}

struct SubscriptionRuleSampleReport: Sendable {
    /// Patterns that cannot be used at all (empty, bad syntax, too few capture groups).
    var issues: [SubscriptionRuleField: SubscriptionRuleIssue]
    var lines: [SubscriptionRuleSampleLine]
    var infoNodeCount: Int { lines.filter { $0.isInfoNode == true }.count }
}

/// Runs patterns over pasted text (one node name per line) with no subscription involved, so a
/// rule can be tried before anything has been downloaded. Patterns are used exactly as typed:
/// an unusable one is reported in `issues`, never replaced by a default.
enum SubscriptionRuleSampleTester {
    static let maxLines = 200

    static func evaluate(text: String, rules: SubscriptionRuleSet, now: Date = Date()) -> SubscriptionRuleSampleReport {
        var issues: [SubscriptionRuleField: SubscriptionRuleIssue] = [:]
        var compiled: [SubscriptionRuleField: NSRegularExpression] = [:]
        for field in SubscriptionRuleField.allCases {
            switch field.compile(rules[field]) {
            case .success(let re):     compiled[field] = re
            case .failure(let issue):  issues[field] = issue
            }
        }

        let names = text.split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxLines)

        var lines: [SubscriptionRuleSampleLine] = []
        for name in names {
            let isInfo: Bool? = compiled[.infoNode].map { matches($0, name) }
            var results: [SubscriptionRuleField: Result<SubscriptionRuleFound, SubscriptionRuleIssue>] = [:]
            if isInfo != false {
                for field in [SubscriptionRuleField.traffic, .reset, .expire] {
                    guard let re = compiled[field],
                          let m = SubscriptionPlanExtractor.captures(re, in: name) else { continue }
                    if let found = SubscriptionPlanExtractor.found(field, captures: m, now: now) {
                        results[field] = .success(found)
                    } else {
                        results[field] = .failure(.badCapture)
                    }
                }
            }
            lines.append(SubscriptionRuleSampleLine(text: name, isInfoNode: isInfo, results: results))
        }
        return SubscriptionRuleSampleReport(issues: issues, lines: lines)
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..<s.endIndex, in: s)) != nil
    }
}

struct SubscriptionPlanExtractor {
    static let defaultInfoNodePattern = SubscriptionRuleSet.defaults.infoNode

    /// A node whose name matches any of these is an info node, not a real proxy.
    var infoNodePatterns: [NSRegularExpression]
    private let trafficRegex: NSRegularExpression
    private let resetRegex: NSRegularExpression
    private let expireRegex: NSRegularExpression

    private static let unitToGB: [String: Double] = ["KB": 1.0 / (1024 * 1024), "MB": 1.0 / 1024, "GB": 1, "TB": 1024]

    /// `infoNodePatterns` (from a settings file) replaces `rules.infoNode` when given. A rule
    /// that does not compile falls back to its built-in default.
    init(infoNodePatterns: [NSRegularExpression]? = nil, rules: SubscriptionRuleSet = .defaults) {
        self.infoNodePatterns = infoNodePatterns
            ?? [SubscriptionRuleField.infoNode.compileOrDefault(rules.infoNode)]
        trafficRegex = SubscriptionRuleField.traffic.compileOrDefault(rules.traffic)
        resetRegex = SubscriptionRuleField.reset.compileOrDefault(rules.reset)
        expireRegex = SubscriptionRuleField.expire.compileOrDefault(rules.expire)
    }

    /// Reads `invalid_proxy_node.subscribe` (a regex string or a list of them) from a
    /// settings JSON file. Invalid patterns are skipped with a warning; [] when absent.
    static func loadInfoNodePatterns(fromSettings url: URL,
                                     log: SubLogger = defaultSubLogger) -> [NSRegularExpression] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let invalid = root.objectValue?["invalid_proxy_node"] else { return [] }
        guard let map = invalid.objectValue else {
            log(.warning, "\(url.path): 'invalid_proxy_node' is not a JSON object; ignoring")
            return []
        }
        var raw: [String] = []
        switch map["subscribe"] {
        case .string(let s)?: raw = [s]
        case .array(let a)?: raw = a.compactMap { $0.stringValue }
        default: break
        }
        return raw.compactMap { pattern in
            guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            do { return try NSRegularExpression(pattern: pattern) }
            catch { log(.warning, "invalid_proxy_node[subscribe] pattern '\(pattern)' is not a valid regex; skipping"); return nil }
        }
    }

    /// Traffic value + unit ("KB/MB/GB/TB") -> GB.
    static func toGB(_ value: Double, unit: String) -> Double {
        value * (unitToGB[unit.uppercased()] ?? 1)
    }

    func isInfoNode(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return infoNodePatterns.contains { $0.firstMatch(in: name, options: [], range: range) != nil }
    }

    /// Scans `proxies` for info nodes and pulls the first remaining-traffic
    /// value and the first expiry date out of their names.
    func extractPlan(name: String, proxies: [ClashProxy], now: Date = Date()) -> SubscriptionPlan {
        var plan = SubscriptionPlan(subscriptionName: name)
        for proxy in proxies {
            let nodeName = proxy.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isInfoNode(nodeName) else { continue }
            plan.infoNodeNames.append(nodeName)

            if plan.remainingTrafficGB == nil,
               let m = Self.captures(trafficRegex, in: nodeName),
               let gb = Self.trafficGB(from: m) {
                plan.remainingTrafficGB = gb
            }
            if plan.resetDays == nil,
               let m = Self.captures(resetRegex, in: nodeName),
               let days = Self.resetDays(from: m) {
                plan.resetDays = days
            }
            if plan.expireDateString == nil,
               let m = Self.captures(expireRegex, in: nodeName),
               let date = Self.expireDate(from: m, now: now) {
                plan.expireDateString = date
                plan.daysLeft = Self.daysUntil(date, from: now)
            }
        }
        return plan
    }

    /// Next reset date ("yyyy-MM-dd", UTC+8) = the snapshot's date + the snapshot's reset days.
    /// Never derive it from today's date: the days were counted from the snapshot.
    static func resetDateString(snapshot: Date, afterDays days: Int) -> String? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = subscriptionTimeZone
        guard let date = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: snapshot)) else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = subscriptionTimeZone
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    /// Whole calendar days from `now`'s date to `dateString` (yyyy-MM-dd), in UTC+8.
    static func daysUntil(_ dateString: String, from now: Date) -> Int? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = subscriptionTimeZone
        df.dateFormat = "yyyy-MM-dd"
        guard let expiry = df.date(from: dateString) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = subscriptionTimeZone
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: expiry)).day
    }

    // What a match means, per field. `m` is `captures(...)`: [whole match, group 1, group 2, ...].

    /// Group 1 = number, group 2 = unit; only the unit's first letter counts (G, GB, GiB).
    static func trafficGB(from m: [String]) -> Double? {
        guard m.count >= 3, let value = Double(m[1]),
              let factor = unitToGB[String(m[2].uppercased().prefix(1)) + "B"] else { return nil }
        return value * factor
    }

    /// Group 1 = whole days.
    static func resetDays(from m: [String]) -> Int? {
        m.count >= 2 ? Int(m[1]) : nil
    }

    /// Group 1 = a real calendar date, "yyyy-MM-dd".
    static func expireDate(from m: [String], now: Date) -> String? {
        guard m.count >= 2, daysUntil(m[1], from: now) != nil else { return nil }
        return m[1]
    }

    /// What `field`'s pattern found, or nil when the captured text is not usable.
    static func found(_ field: SubscriptionRuleField, captures m: [String], now: Date) -> SubscriptionRuleFound? {
        switch field {
        case .infoNode:
            return nil
        case .traffic:
            return trafficGB(from: m).map { SubscriptionRuleFound.trafficGB($0) }
        case .reset:
            return resetDays(from: m).map { SubscriptionRuleFound.resetDays($0) }
        case .expire:
            guard let date = expireDate(from: m, now: now),
                  let days = daysUntil(date, from: now) else { return nil }
            return .expire(date: date, daysLeft: days)
        }
    }

    static func captures(_ re: NSRegularExpression, in s: String) -> [String]? {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, options: [], range: range) else { return nil }
        return (0..<m.numberOfRanges).map { idx in
            Range(m.range(at: idx), in: s).map { String(s[$0]) } ?? ""
        }
    }
}

// MARK: - Health alerts

struct SubscriptionHealthThresholds: Sendable {
    var trafficGB = 1.0
    var expiryDays = 1
}

enum SubscriptionAlert: Sendable, Equatable {
    case fetchFailed(name: String)
    case lowTraffic(name: String, remainingGB: Double, thresholdGB: Double)
    case expiring(name: String, dateString: String, daysLeft: Int)

    var message: String {
        switch self {
        case .fetchFailed(let name):
            return "⚠️ 订阅 [\(name)] 本次抓取失败且无可用缓存，已从本次生成的配置中跳过"
        case .lowTraffic(let name, let gb, let threshold):
            return "⚠️ 订阅 [\(name)] 剩余流量低于 \(String(format: "%.0f", threshold)) GB (当前剩余: \(String(format: "%.2f", gb)) GB)"
        case .expiring(let name, let date, let days):
            return "⚠️ 订阅 [\(name)] 套餐即将到期或已到期 (到期时间: \(date), 剩余 \(days) 天)"
        }
    }
}

enum SubscriptionHealth {
    /// Fetch failures first, then per plan: low traffic (`< trafficGB`) and
    /// near/past expiry (`daysLeft <= expiryDays`).
    static func evaluate(plans: [SubscriptionPlan],
                         fetchSummary: [String: FetchStatus]? = nil,
                         thresholds: SubscriptionHealthThresholds = .init()) -> [SubscriptionAlert] {
        var alerts: [SubscriptionAlert] = []
        for (name, status) in (fetchSummary ?? [:]).sorted(by: { $0.key < $1.key }) where status == .failed {
            alerts.append(.fetchFailed(name: name))
        }
        for plan in plans {
            if let gb = plan.remainingTrafficGB, gb < thresholds.trafficGB {
                alerts.append(.lowTraffic(name: plan.subscriptionName, remainingGB: gb, thresholdGB: thresholds.trafficGB))
            }
            if let date = plan.expireDateString, let days = plan.daysLeft, days <= thresholds.expiryDays {
                alerts.append(.expiring(name: plan.subscriptionName, dateString: date, daysLeft: days))
            }
        }
        return alerts
    }

    /// Alert messages joined by newlines, or nil when there is nothing to report.
    static func alertText(_ alerts: [SubscriptionAlert]) -> String? {
        alerts.isEmpty ? nil : alerts.map(\.message).joined(separator: "\n") + "\n"
    }
}

// MARK: - Analysis over fetched text / cache directory

struct SubscriptionAnalysis {
    var proxies: [String: [ClashProxy]] = [:]
    /// Sorted by subscription name.
    var plans: [SubscriptionPlan] = []
    /// Subscriptions whose text could not be parsed -> reason.
    var errors: [String: String] = [:]
}

enum SubscriptionAnalyzer {

    static func analyze(texts: [String: String],
                        extractor: SubscriptionPlanExtractor = .init(),
                        now: Date = Date(),
                        log: SubLogger = defaultSubLogger) -> SubscriptionAnalysis {
        var result = SubscriptionAnalysis()
        if extractor.infoNodePatterns.isEmpty {
            log(.warning, "no info-node pattern configured -- cannot tell subscription-info nodes from real proxies, skipping the traffic/expiry scan")
        }
        for name in texts.keys.sorted() {
            do {
                let proxies = try ClashSubscriptionParser.parse(texts[name] ?? "", log: log)
                result.proxies[name] = proxies
                let plan = extractor.extractPlan(name: name, proxies: proxies, now: now)
                if let gb = plan.remainingTrafficGB {
                    log(.debug, "[\(name)] 剩余流量（节点名快照）: \(String(format: "%.2f", gb)) GB")
                }
                if let days = plan.resetDays {
                    log(.debug, "[\(name)] 距离下次重置剩余（节点名快照）: \(days) 天")
                }
                if let date = plan.expireDateString {
                    log(.debug, "[\(name)] 套餐到期时间: \(date) (剩余 \(plan.daysLeft.map(String.init) ?? "?") 天)")
                }
                result.plans.append(plan)
            } catch {
                log(.error, "[\(name)] failed to parse subscription: \(describe(error))")
                result.errors[name] = describe(error)
            }
        }
        return result
    }

    /// Same as `analyze(texts:)` but reads every `*.yaml` in the fetch cache
    /// directory (the subscription name is the file stem).
    static func analyzeCacheDirectory(_ dir: URL,
                                      extractor: SubscriptionPlanExtractor = .init(),
                                      now: Date = Date(),
                                      log: SubLogger = defaultSubLogger) -> SubscriptionAnalysis {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var texts: [String: String] = [:]
        for file in files.filter({ $0.pathExtension == "yaml" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                texts[file.deletingPathExtension().lastPathComponent] =
                    stripBOM(try String(contentsOf: file, encoding: .utf8))
            } catch {
                log(.error, "failed to read \(file.path): \(error.localizedDescription)")
            }
        }
        return analyze(texts: texts, extractor: extractor, now: now, log: log)
    }
}

// MARK: - One-call pipeline: config -> filter -> fetch -> parse -> plans -> alerts

struct SubscriptionRefreshResult {
    var entries: [SubscriptionEntry]
    var fetchSummary: [String: FetchStatus]
    var analysis: SubscriptionAnalysis
    var alerts: [SubscriptionAlert]
    /// True when at least one subscription was downloaded live (not served from cache).
    var fetchedFreshContent: Bool { fetchSummary.values.contains(.live) }
}

enum SubscriptionService {
    static func refresh(configURL: URL,
                        subsDir: URL,
                        options: SubscriptionFetchOptions = .init(),
                        extractor: SubscriptionPlanExtractor = .init(),
                        thresholds: SubscriptionHealthThresholds = .init(),
                        now: Date = Date(),
                        log: @escaping SubLogger = defaultSubLogger) async throws -> SubscriptionRefreshResult {
        let all = try SubscriptionConfig.load(from: configURL, log: log)
        guard !all.isEmpty else { throw SubscriptionError.config("no usable 'subscribe' entries in \(configURL.path)") }

        let active = SubscriptionConfig.filterActive(all, now: now, log: log)
        guard !active.isEmpty else {
            throw SubscriptionError.config("no subscription is both enabled and unexpired -- nothing to fetch")
        }

        log(.note, "fetching \(active.count) subscription(s) (up to \(options.concurrency) concurrent)")
        let fetcher = SubscriptionFetcher(subsDir: subsDir, options: options, log: log)
        let (texts, summary) = await fetcher.fetchAll(active)
        log(.note, "subscription fetch summary: " +
            summary.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" }.joined(separator: ", "))

        let analysis = SubscriptionAnalyzer.analyze(texts: texts, extractor: extractor, now: now, log: log)
        let alerts = SubscriptionHealth.evaluate(plans: analysis.plans, fetchSummary: summary, thresholds: thresholds)
        return SubscriptionRefreshResult(entries: active, fetchSummary: summary, analysis: analysis, alerts: alerts)
    }
}

// MARK: - Optional CLI (compile with -D SUBSCRIPTION_TOOL_MAIN)

#if SUBSCRIPTION_TOOL_MAIN
@main
struct SubscriptionTool {
    static func main() async {
        let args = CommandLine.arguments
        let config = URL(fileURLWithPath: args.count > 1 ? args[1] : "config/subscriptions.json")
        let dir = URL(fileURLWithPath: args.count > 2 ? args[2] : "generated/subscriptions", isDirectory: true)
        do {
            let r = try await SubscriptionService.refresh(configURL: config, subsDir: dir)
            for plan in r.analysis.plans {
                let traffic = plan.remainingTrafficGB.map { String(format: "%.2f GB", $0) } ?? "-"
                print("[\(plan.subscriptionName)] nodes=\(r.analysis.proxies[plan.subscriptionName]?.count ?? 0)"
                      + " traffic=\(traffic) expire=\(plan.expireDateString ?? "-") daysLeft=\(plan.daysLeft.map(String.init) ?? "-")")
            }
            for alert in r.alerts { print(alert.message) }
            exit(r.fetchSummary.values.contains(.failed) ? 1 : 0)
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }
}
#endif
