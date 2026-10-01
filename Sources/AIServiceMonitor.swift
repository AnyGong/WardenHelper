import Foundation
import Darwin

// MARK: - Vendors

/// The AI services whose egress is checked. Each one is probed on its own main domain, so the
/// proxy's per-domain routing rules apply to the probe exactly as they apply to the service.
enum AIVendor: CaseIterable, Hashable {
    case chatgpt, claude, grok, gemini

    var displayName: String {
        switch self {
        case .chatgpt: return "ChatGPT (OpenAI)"
        case .claude:  return "Claude (Anthropic)"
        case .grok:    return "Grok (xAI)"
        case .gemini:  return "Gemini (Google)"
        }
    }

    enum Probe {
        /// `/cdn-cgi/trace` on a Cloudflare-fronted domain: plain `key=value` lines (`ip`, `loc`, `colo`).
        case cloudflareTrace
        /// Google's DNS-over-HTTPS answer for `o-o.myaddr.l.google.com` TXT: the caller's address.
        case googleDNS
    }

    var probe: Probe { self == .gemini ? .googleDNS : .cloudflareTrace }

    /// Short name for tight spots (the dropdown menu row when the logo cannot be shown).
    var shortName: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .claude:  return "Claude"
        case .grok:    return "Grok"
        case .gemini:  return "Gemini"
        }
    }

    /// Stable key for stored values and notification identifiers.
    var key: String {
        switch self {
        case .chatgpt: return "chatgpt"
        case .claude:  return "claude"
        case .grok:    return "grok"
        case .gemini:  return "gemini"
        }
    }

    var probeURL: URL {
        switch self {
        case .chatgpt: return URL(string: "https://chatgpt.com/cdn-cgi/trace")!
        case .claude:  return URL(string: "https://claude.ai/cdn-cgi/trace")!
        case .grok:    return URL(string: "https://grok.com/cdn-cgi/trace")!
        case .gemini:  return URL(string: "https://dns.google/resolve?name=o-o.myaddr.l.google.com&type=TXT")!
        }
    }
}

// MARK: - Result

struct AIServiceStatus: Equatable {
    enum State: Equatable {
        case pending                    // never checked yet
        case ok
        case failed(String)             // short reason for the row
    }

    var state: State = .pending
    var ip = ""
    var countryCode = ""                // upper case, e.g. "JP"; empty when unknown
    var countryName = ""
    var city = ""
    var provider = ""                   // organisation, else ISP
    var colo = ""                       // Cloudflare data centre (Cloudflare probes only)
    var latencyMs: Int?                 // the whole probe request: connect, TLS, response

    /// The flag emoji of `countryCode`, or a globe when it is not known.
    var flag: String { AIServiceMonitor.flagEmoji(countryCode) }
}

// MARK: - Monitor

/// Runs the four probes in parallel and publishes each result as soon as it arrives.
///
/// - Probes go through the system's network settings (system proxy, VPN), like any app.
/// - Every round uses a fresh session, so no pooled connection keeps an old route alive and
///   the latency always includes the connection set-up (as `curl` in the original script does).
/// - Checking runs between `start()` and `stop()`. By default (`Preferences.aiBackgroundCheck`)
///   the app starts it at launch and it keeps going in the background, so the dropdown menu
///   always has a current answer; with that setting off, only the AI tab being on screen keeps
///   it running (`pageShown()` / `pageHidden()`).
/// - A changed exit country / region (compared with the last stored check) raises a notification.
///
/// Main thread only, apart from the probes themselves.
final class AIServiceMonitor: @unchecked Sendable {   // main-thread state; probes touch nothing shared
    static let shared = AIServiceMonitor()

    /// Posted on the main thread whenever a result or `isRefreshing` changed.
    static let changedNotification = Notification.Name("WardenHelperAIServiceChanged")

    private(set) var results: [AIVendor: AIServiceStatus] = {
        Dictionary(uniqueKeysWithValues: AIVendor.allCases.map { ($0, AIServiceStatus()) })
    }()
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Services whose answer of the current round has not been shown yet.
    private(set) var loading = Set<AIVendor>()

    /// A round shows its loading state for at least this long, so a fast answer is still seen.
    private static let minVisible: TimeInterval = 0.6
    private var roundStarted = Date()

    private var running = false
    private var pageOpen = false                    // the AI settings tab is on screen
    private var routeToken = 0                      // coalesces bursts of network / VPN events
    private var timer: DispatchSourceTimer?
    private var round: Task<Void, Never>?
    private var generation = 0                      // drops results of a superseded round
    private let geo = GeoResolver()

    private init() {}

    // MARK: Control

    /// Checks now and then every `Preferences.aiStatusRefreshSeconds`.
    func start() {
        guard !running else { return }
        running = true
        schedule()
        refresh()
    }

    var isRunning: Bool { running }

    enum Overall: Equatable { case normal, abnormal }

    /// The state the menu bar icon shows. `nil` = no icon: checks are not running, or the first
    /// round has not finished (so the launch never flashes a false alarm).
    /// Normal = all four services answered with an exit in `Preferences.aiExpectedRegion`;
    /// anything else (a failed check, another region) = abnormal.
    var overall: Overall? {
        guard running else { return nil }
        let expected = Preferences.shared.aiExpectedRegion
        var waiting = false
        for vendor in AIVendor.allCases {
            let status = results[vendor] ?? AIServiceStatus()
            switch status.state {
            case .pending: waiting = true
            case .failed:  return .abnormal
            case .ok:      if status.countryCode != expected { return .abnormal }
            }
        }
        return waiting ? nil : .normal
    }

    /// At launch and whenever the background setting changes.
    func applyPreference() {
        if Preferences.shared.aiBackgroundCheck { start() }
        else if !pageOpen { stop() }
    }

    /// The AI settings tab came on screen: check now (or start, with background checks off).
    func pageShown() {
        pageOpen = true
        if running { refresh() } else { start() }
    }

    /// The AI tab (or the settings window) went away: stop unless checks run in the background.
    func pageHidden() {
        pageOpen = false
        if !Preferences.shared.aiBackgroundCheck { stop() }
    }

    /// The network or the VPN changed: look again once the new route has had time to settle.
    func routeChanged() {
        guard running else { return }
        routeToken += 1
        let token = routeToken
        for delay in [1.5, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.running, token == self.routeToken else { return }
                self.refresh(force: true)
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.cancel(); timer = nil
        round?.cancel(); round = nil
        generation += 1
        loading.removeAll()
        isRefreshing = false
        post()                                      // the menu / bar icon follow: nothing is checked now
    }

    /// The interval setting changed.
    func rescheduleIfRunning() {
        guard running else { return }
        schedule()
    }

    /// A round now. A round already in progress is left to finish unless `force` is set.
    func refresh(force: Bool = false) {
        if isRefreshing && !force { return }
        round?.cancel()
        generation += 1
        let mine = generation
        isRefreshing = true
        roundStarted = Date()
        loading = Set(AIVendor.allCases)
        post()

        let session = Self.makeSession()
        round = Task { [weak self] in
            await withTaskGroup(of: (AIVendor, AIServiceStatus).self) { group in
                for vendor in AIVendor.allCases {
                    group.addTask { [weak self] in
                        guard let self = self else { return (vendor, AIServiceStatus()) }
                        return (vendor, await self.check(vendor, session: session))
                    }
                }
                for await (vendor, status) in group {
                    DispatchQueue.main.async { self?.settle(vendor, status, generation: mine) }
                }
            }
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async { self?.settleFinish(generation: mine) }
        }
    }

    private func schedule() {
        timer?.cancel()
        let seconds = TimeInterval(Preferences.shared.aiStatusRefreshSeconds)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.refresh() }    // skipped while a round is running
        t.resume()
        timer = t
    }

    /// Holds an answer back until the round has been on screen for `minVisible`.
    private var remainingHold: TimeInterval {
        max(0, Self.minVisible - Date().timeIntervalSince(roundStarted))
    }

    private func settle(_ vendor: AIVendor, _ status: AIServiceStatus, generation g: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingHold) { [weak self] in
            self?.apply(vendor, status, generation: g)
        }
    }

    private func settleFinish(generation g: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingHold) { [weak self] in
            self?.finish(generation: g)
        }
    }

    private func apply(_ vendor: AIVendor, _ status: AIServiceStatus, generation g: Int) {
        guard g == generation, running else { return }
        loading.remove(vendor)
        if status.state != .pending { results[vendor] = status }   // a cancelled probe keeps what is shown
        noteRegion(vendor, status)
        post()
    }

    /// Compares the country / region of a successful check with the one stored from the last
    /// successful check. A failed check changes nothing; the first ever check only records.
    private func noteRegion(_ vendor: AIVendor, _ status: AIServiceStatus) {
        guard status.state == .ok, !status.countryCode.isEmpty else { return }
        let storeKey = "aiLastRegion." + vendor.key
        let previous = UserDefaults.standard.string(forKey: storeKey) ?? ""
        guard previous != status.countryCode else { return }
        UserDefaults.standard.set(status.countryCode, forKey: storeKey)
        if !previous.isEmpty {
            ChangeNotifier.shared.notifyAIRegionChange(vendor: vendor, from: previous, to: status.countryCode)
        }
    }

    private func finish(generation g: Int) {
        guard g == generation else { return }
        loading.removeAll()
        isRefreshing = false
        lastRefresh = Date()
        post()
    }

    private func post() {
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    // MARK: Probing

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    /// One service: the probe (timed), then the location of the address it reported.
    private func check(_ vendor: AIVendor, session: URLSession, retried: Bool = false) async -> AIServiceStatus {
        var status = AIServiceStatus()
        let began = DispatchTime.now().uptimeNanoseconds
        let data: Data
        do {
            let (body, response) = try await session.data(for: Self.request(vendor.probeURL))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                status.state = .failed("HTTP \(http.statusCode)")
                return status
            }
            data = body
        } catch {
            status.state = (error as? URLError)?.code == .cancelled ? .pending : .failed(Self.reason(error))
            return status
        }
        status.latencyMs = Int(Double(DispatchTime.now().uptimeNanoseconds &- began) / 1_000_000)

        var cloudflareCountry = ""
        switch vendor.probe {
        case .cloudflareTrace:
            let fields = Self.parseTrace(data)
            status.ip = fields["ip"] ?? ""
            status.colo = fields["colo"] ?? ""
            cloudflareCountry = (fields["loc"] ?? "").uppercased()
        case .googleDNS:
            status.ip = Self.parseGoogleDNS(data) ?? ""
        }
        guard !status.ip.isEmpty else {
            status.state = .failed(vendor.probe == .googleDNS ? L10n.aiNoIPGoogle : L10n.aiNoIP)
            status.latencyMs = nil
            return status
        }
        guard Self.isPublicIP(status.ip) else {
            // A local/link-local address (e.g. fe80::...) is not an exit IP. Typical right after the
            // VPN drops or while the route is rebuilt, so look once more before reporting it.
            if !retried {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if !Task.isCancelled { return await check(vendor, session: session, retried: true) }
            }
            status.ip = ""
            status.colo = ""
            status.latencyMs = nil
            status.state = .failed(L10n.aiLocalIP)
            return status
        }

        if let place = await geo.lookup(ip: status.ip, session: session) {
            status.countryCode = place.countryCode
            status.countryName = place.country
            status.city = place.city
            status.provider = place.provider
        }
        // Only real ISO regions count: Cloudflare also reports "XX" (unknown) and "T1" (Tor).
        if !Self.validRegions.contains(status.countryCode) { status.countryCode = "" }
        if status.countryCode.isEmpty, Self.validRegions.contains(cloudflareCountry) {
            status.countryCode = cloudflareCountry
        }
        if !status.countryCode.isEmpty,
           let name = Locale(identifier: "zh_CN").localizedString(forRegionCode: status.countryCode) {
            status.countryName = name                      // always the Chinese name, never the bare code
        }
        status.state = .ok
        return status
    }

    // MARK: Parsing

    /// `ip=1.2.3.4` lines of a Cloudflare trace.
    static func parseTrace(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// The first TXT answer that is an IP address (`"203.0.113.7"`; the second record Google adds,
    /// `edns0-client-subnet …`, is not one).
    static func parseGoogleDNS(_ data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answers = json["Answer"] as? [[String: Any]] else { return nil }
        for answer in answers {
            guard let raw = answer["data"] as? String else { continue }
            let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if isIPAddress(text) { return text }
        }
        return nil
    }

    static func isIPAddress(_ text: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// True only for a globally routable address. A probe answered by a remote server can never
    /// report a link-local (`fe80::/10`, `169.254/16`), loopback, private, CGNAT, unique-local or
    /// fake-IP-pool address: when one shows up (VPN just dropped, route being rebuilt, a local
    /// gateway or VM answering in place of the server) it is the local side's address, not the
    /// exit IP, and must not be displayed or sent to the geo lookup.
    static func isPublicIP(_ raw: String) -> Bool {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }   // fe80::1%en0

        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let n = UInt32(bigEndian: v4.s_addr)
            let a = Int(n >> 24), b = Int((n >> 16) & 0xFF)
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && b == 168 { return false }
            if a == 100 && (64...127).contains(b) { return false }     // CGNAT / Tailscale
            if a == 198 && (b == 18 || b == 19) { return false }       // proxy fake-IP pool
            return true
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes.allSatisfy({ $0 == 0 }) { return false }                                    // ::
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return false }      // ::1
            if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false }                      // fe80::/10
            if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0xC0 { return false }                      // fec0::/10
            if bytes[0] & 0xFE == 0xFC { return false }                                          // fc00::/7
            if bytes[0] == 0xFF { return false }                                                 // multicast
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF { return false } // v4-mapped
            return true
        }
        return false
    }

    // MARK: Display helpers

    static func flagEmoji(_ code: String) -> String {
        let upper = code.uppercased()
        guard upper.unicodeScalars.count == 2,
              upper.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return "🌐" }
        var flag = ""
        for scalar in upper.unicodeScalars {                       // A-Z -> regional indicator letters
            if let indicator = Unicode.Scalar(127397 + scalar.value) { flag.unicodeScalars.append(indicator) }
        }
        return flag
    }

    static let validRegions = Set(NSLocale.isoCountryCodes)

    private static func reason(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .timedOut?:                                          return L10n.aiTimedOut
        case .cannotFindHost?, .dnsLookupFailed?:                 return L10n.aiCannotResolve
        case .notConnectedToInternet?, .networkConnectionLost?,
             .cannotConnectToHost?, .internationalRoamingOff?:    return L10n.aiCannotConnect
        case .secureConnectionFailed?, .serverCertificateUntrusted?,
             .serverCertificateHasBadDate?, .serverCertificateHasUnknownRoot?,
             .clientCertificateRejected?:                         return L10n.aiTLSFailed
        default:                                                  return L10n.aiRequestFailed
        }
    }
}

// MARK: - Where an address is

/// `ip-api.com` (already allowed for plain HTTP in Info.plist), asked once per address: the
/// result is kept for 30 minutes and requests for the same address in flight are shared, so
/// three services behind one exit cost one lookup, and a 10 s refresh stays far below the
/// service's rate limit.
private final class GeoResolver: @unchecked Sendable {   // all state is under `lock`
    struct Place {
        let country: String
        let countryCode: String
        let city: String
        let provider: String
    }

    private let lock = NSLock()
    private var cache: [String: (place: Place, at: Date)] = [:]
    private var inflight: [String: Task<Place?, Never>] = [:]
    private static let lifetime: TimeInterval = 30 * 60

    func lookup(ip: String, session: URLSession) async -> Place? {
        enum Step { case hit(Place), wait(Task<Place?, Never>) }

        // Scoped locking only: a plain lock()/unlock() pair is not allowed across an `await`.
        let step: Step = lock.withLock {
            if let hit = cache[ip], Date().timeIntervalSince(hit.at) < Self.lifetime { return .hit(hit.place) }
            if let running = inflight[ip] { return .wait(running) }
            let task = Task { await Self.fetch(ip, session: session) }
            inflight[ip] = task
            return .wait(task)
        }
        let task: Task<Place?, Never>
        switch step {
        case .hit(let place): return place
        case .wait(let running): task = running
        }

        var place = await task.value
        if place == nil {                                   // one more try, then the last known answer
            place = await Self.fetch(ip, session: session)
        }
        let fresh = place != nil
        if place == nil {
            place = lock.withLock { cache[ip]?.place }
        }
        let answer = place

        lock.withLock {
            inflight[ip] = nil
            guard fresh, let place = answer else { return }
            cache[ip] = (place, Date())
            if cache.count > 32 {
                let oldest = cache.sorted { $0.value.at < $1.value.at }.prefix(cache.count - 32)
                for (key, _) in oldest { cache[key] = nil }
            }
        }
        return answer
    }

    private static func fetch(_ ip: String, session: URLSession) async -> Place? {
        guard AIServiceMonitor.isPublicIP(ip),
              let url = URL(string: "http://ip-api.com/json/\(ip)?fields=status,country,countryCode,city,isp,org&lang=zh-CN") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await session.data(for: request),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json["status"] as? String) == "success" else { return nil }
        func text(_ key: String) -> String { (json[key] as? String) ?? "" }
        let org = text("org")
        return Place(country: text("country"), countryCode: text("countryCode").uppercased(),
                     city: text("city"), provider: org.isEmpty ? text("isp") : org)
    }
}
