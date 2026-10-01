import Foundation

class IPFlagFetcher {
    /// Reported (instead of an address) until a lookup has succeeded.
    static let unknownIP = "Unknown IP"

    // Passes back (FlagEmoji, IPString, CountryCode e.g. "US" — empty if unknown)
    var onUpdate: ((String, String, String) -> Void)?

    // Cache last known
    private var lastFlag: String = "🌐"
    private var lastIP: String = IPFlagFetcher.unknownIP
    private var lastCountry: String = ""

    // Generation counter to discard stale in-flight responses
    private var fetchGeneration: Int = 0

    // Guards all mutable shared state (generation, last values, per-fetch bookkeeping).
    private let stateLock = NSLock()
    
    // Ephemeral session — zero URL caching, no cookies, no disk persistence
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForResource = 12
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    // Only touched from the main thread (fetch / fetchWithRetry / retry timers).
    private var session: URLSession = IPFlagFetcher.makeSession()

    /// Drops pooled connections, which point at the old route after a VPN change.
    private func resetSession() {
        let old = session
        session = IPFlagFetcher.makeSession()
        old.invalidateAndCancel()
    }

    // Several providers for redundancy; each has a URL and a parser for (ip, countryCode).
    private struct IPProvider {
        let url: String
        let parse: ([String: Any]) -> (ip: String, country: String)?
    }
    
    private let providers: [IPProvider] = [
        // ip-api.com — HTTP (avoids some VPN TLS issues)
        IPProvider(url: "http://ip-api.com/json/?fields=query,countryCode") { json in
            guard let ip = json["query"] as? String,
                  let code = json["countryCode"] as? String else { return nil }
            return (ip, code)
        },
        // ipapi.co — HTTPS
        IPProvider(url: "https://ipapi.co/json/") { json in
            guard let ip = json["ip"] as? String,
                  let code = json["country_code"] as? String else { return nil }
            return (ip, code)
        },
        // api.country.is — HTTPS
        IPProvider(url: "https://api.country.is/") { json in
            guard let ip = json["ip"] as? String,
                  let code = json["country"] as? String else { return nil }
            return (ip, code)
        },
        // ipinfo.io — HTTPS
        IPProvider(url: "https://ipinfo.io/json") { json in
            guard let ip = json["ip"] as? String,
                  let code = json["country"] as? String else { return nil }
            return (ip, code)
        },
        // ipwho.is — HTTPS
        IPProvider(url: "https://ipwho.is/") { json in
            guard let ip = json["ip"] as? String,
                  let code = json["country_code"] as? String else { return nil }
            return (ip, code)
        },
    ]

    // MARK: - Thread-safe state access

    /// Bump and return the new generation under the lock.
    private func bumpGeneration() -> Int {
        stateLock.lock()
        fetchGeneration += 1
        let gen = fetchGeneration
        stateLock.unlock()
        return gen
    }

    /// True if `gen` is still the current generation.
    private func isCurrentGeneration(_ gen: Int) -> Bool {
        stateLock.lock()
        let current = fetchGeneration
        stateLock.unlock()
        return gen == current
    }

    /// Snapshot lastIP under the lock.
    private func snapshotLastIP() -> String {
        stateLock.lock()
        let ip = lastIP
        stateLock.unlock()
        return ip
    }

    /// Snapshot (flag, ip, country) under the lock — used to dispatch onUpdate off-lock.
    private func snapshotCache() -> (flag: String, ip: String, country: String) {
        stateLock.lock()
        let flag = lastFlag
        let ip = lastIP
        let country = lastCountry
        stateLock.unlock()
        return (flag, ip, country)
    }

    /// Standard fetch — just get the current IP once.
    func fetch() {
        let gen = bumpGeneration()
        performFetch(generation: gen)
    }

    // Main-thread only.
    private var pollCursor = 0
    private var retryActiveUntil: Date = .distantPast
    // ip-api.com, api.country.is, ipwho.is: the providers with generous free limits.
    private let pollProviderIndices = [0, 2, 4]

    /// Periodic check; asks one rotating provider per call to spare the free quotas.
    func poll() {
        guard Date() >= retryActiveUntil else { return }
        let gen = bumpGeneration()
        let index = pollProviderIndices[pollCursor % pollProviderIndices.count]
        pollCursor += 1
        performFetch(generation: gen, using: [providers[index]])
    }

    /// Fetches now, then retries with growing delays until the address changes (after a VPN change).
    func fetchWithRetry(maxRetries: Int = 6) {
        let gen = bumpGeneration()
        let previousIP = snapshotLastIP()
        resetSession()
        retryActiveUntil = Date().addingTimeInterval(20)
        performFetchWithRetry(generation: gen, previousIP: previousIP, retriesLeft: maxRetries, delay: 0)
    }

    private func performFetchWithRetry(generation: Int, previousIP: String, retriesLeft: Int, delay: TimeInterval) {
        // Bail if a newer fetch has been started
        guard isCurrentGeneration(generation) else { return }

        let work = { [weak self] in
            guard let self = self, self.isCurrentGeneration(generation) else { return }
            self.performFetch(generation: generation) { [weak self] newIP in
                guard let self = self, self.isCurrentGeneration(generation) else { return }

                if newIP != previousIP || retriesLeft <= 0 {
                    return
                }

                // Unchanged: routing may not have settled yet, retry.
                let nextDelay = min(delay * 1.5 + 0.5, 4.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + nextDelay) { [weak self] in
                    guard let self = self, self.isCurrentGeneration(generation) else { return }
                    self.performFetchWithRetry(generation: generation, previousIP: previousIP, retriesLeft: retriesLeft - 1, delay: nextDelay)
                }
            }
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            work()
        }
    }

    /// One lookup attempt across the provider list.
    private final class FetchRound {
        var finished = false   // guarded by stateLock
        var failures = 0       // guarded by stateLock
        var next = 0           // guarded by stateLock
    }

    /// Delay before a slower provider is raced against the one still pending.
    private static let hedgeDelay: TimeInterval = 0.7

    /// Asks the first provider at once; on failure asks the next immediately, if merely slow
    /// races the next after `hedgeDelay`. First success wins.
    private func performFetch(generation: Int, using list: [IPProvider]? = nil, completion: ((String) -> Void)? = nil) {
        launchNext(FetchRound(), providers: list ?? providers, generation: generation, completion: completion)
    }

    /// Main thread only (it touches `session`).
    private func launchNext(_ round: FetchRound, providers active: [IPProvider], generation: Int,
                            completion: ((String) -> Void)?) {
        guard isCurrentGeneration(generation) else { return }

        stateLock.lock()
        guard !round.finished, round.next < active.count else { stateLock.unlock(); return }
        let provider = active[round.next]
        round.next += 1
        let hasMore = round.next < active.count
        stateLock.unlock()

        if hasMore {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hedgeDelay) { [weak self] in
                self?.launchNext(round, providers: active, generation: generation, completion: completion)
            }
        }

        guard let url = URL(string: provider.url) else {
            handleFailure(round, providers: active, generation: generation, completion: completion)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("WardenHelper/1.2", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.timeoutInterval = 8

        session.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, self.isCurrentGeneration(generation) else { return }

            var parsed: (ip: String, country: String)?
            if error == nil, let data = data,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let result = provider.parse(json), AIServiceMonitor.isPublicIP(result.ip) {
                parsed = result
            }

            guard let result = parsed else {
                self.handleFailure(round, providers: active, generation: generation, completion: completion)
                return
            }

            self.stateLock.lock()
            if round.finished { self.stateLock.unlock(); return }
            round.finished = true
            self.lastIP = result.ip
            self.lastFlag = self.countryCodeToEmoji(result.country)
            self.lastCountry = result.country.uppercased()
            let flag = self.lastFlag
            let ip = self.lastIP
            let country = self.lastCountry
            self.stateLock.unlock()

            self.dispatchUpdate(flag: flag, ip: ip, country: country)
            completion?(ip)
        }.resume()
    }

    /// Tries the next provider, or reports the cached values after the last failure.
    private func handleFailure(_ round: FetchRound, providers active: [IPProvider], generation: Int,
                               completion: ((String) -> Void)?) {
        stateLock.lock()
        round.failures += 1
        let allFailed = !round.finished && round.failures >= active.count
        if allFailed { round.finished = true }
        let done = round.finished
        stateLock.unlock()

        if allFailed {
            let cached = snapshotCache()
            dispatchUpdate(flag: cached.flag, ip: cached.ip, country: cached.country)
            completion?(cached.ip)
        } else if !done {
            DispatchQueue.main.async { [weak self] in
                self?.launchNext(round, providers: active, generation: generation, completion: completion)
            }
        }
    }

    private func dispatchUpdate(flag: String, ip: String, country: String) {
        let capturedFlag = flag
        let capturedIP = ip
        let capturedCountry = country
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(capturedFlag, capturedIP, capturedCountry)
        }
    }
    
    private func countryCodeToEmoji(_ code: String) -> String {
        let base: UInt32 = 127397
        var scalarView = String.UnicodeScalarView()
        let safeCode = String(code.prefix(2))
        for scalar in safeCode.uppercased().unicodeScalars {
            if let newScalar = UnicodeScalar(base + scalar.value) {
                scalarView.append(newScalar)
            }
        }
        return String(scalarView)
    }
}
