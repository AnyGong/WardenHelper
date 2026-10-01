import Foundation

/// Turns "armed + rules" into real blocking: the DNS sinkhole (with the DNS settings of the
/// network services), the pf anchor and the process killer. Everything runs on one serial
/// queue, off the IPC path, because `networksetup` and `pfctl` can take a second or two and
/// WardenHelper waits only 3 s for its reply. Only the newest request is carried out: an older one
/// that is still queued is dropped. A step that fails is retried with a growing delay.
final class Enforcer {

    private let queue = DispatchQueue(label: "warden-helper.daemon.enforcer")
    private let lock = NSLock()
    private var generation = 0
    private var stateText = "ok"                 // pending / ok / failed, under `lock`
    private var requestedAt: UInt64 = 0           // when the newest request arrived, under `lock`

    private let sinkhole = DNSSinkhole()
    private let pf = PFRules()
    private let killer = ProcessKiller()
    private let watcher = NetworkWatcher()
    private let cache = AddressCache()
    private let resolveQueue = DispatchQueue(label: "warden-helper.daemon.resolve", qos: .utility)

    // Touched on `queue` only.
    private var sinkholeUp = false
    private var dnsActive = false
    private var retryDelay: TimeInterval = 10
    private var currentRules: BlockRuleSet?             // the rules being enforced; nil when disarmed
    private var refreshEpoch = 0                        // a newer schedule or a disarm voids older lookups
    private var refreshFailures = 0
    private var appliedNetworks = Set<String>()         // what the pf anchor holds now
    private var lastUpstreams: [String] = []            // the resolvers the sinkhole forwards to
    private var refreshPass = 0                         // 0... since the last arm; early passes come fast

    // Names the sinkhole answered, waiting to be resolved (any thread, under `learnLock`).
    private let learnLock = NSLock()
    private var learnPending = Set<String>()
    private var learnScheduled = false
    private var learnedAt: [String: Date] = [:]

    init() {
        sinkhole.onMatch = { [weak self] name in self?.noteBlockedName(name) }
    }

    /// `pending` while a request is being carried out, then `ok` or `failed`.
    var status: String {
        lock.lock(); defer { lock.unlock() }
        return stateText
    }

    /// True while the last attempt did not fully succeed.
    var needsRetry: Bool { status == "failed" }

    func apply(armed: Bool, rules: BlockRuleSet, reason: String) {
        lock.lock()
        generation += 1
        let mine = generation
        stateText = "pending"
        requestedAt = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let newest = generation
            lock.unlock()
            guard mine == newest else { return }
            run(armed: armed, rules: rules, reason: reason, generation: mine)
        }
    }

    // MARK: One pass

    private func run(armed: Bool, rules: BlockRuleSet, reason: String, generation mine: Int) {
        let ok: Bool
        lock.lock()
        let began = requestedAt
        lock.unlock()
        func elapsed() -> String {
            String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds &- began) / 1_000_000)
        }
        if armed && !rules.isEmpty {
            helperLog("block-arm reason=\(reason) domains=\(rules.domains.count) suffixes=\(rules.domainSuffixes.count) keywords=\(rules.domainKeywords.count) cidrs=\(rules.cidrs.count) processes=\(rules.processNames.count) paths=\(rules.processPaths.count) start_ms=\(elapsed())")
            ok = arm(rules, elapsed: elapsed)
            helperLog("block-armed ok=\(ok) total_ms=\(elapsed())")
        } else {
            helperLog("block-disarm reason=\(reason) start_ms=\(elapsed())")
            ok = disarm()
            helperLog("block-disarmed ok=\(ok) total_ms=\(elapsed())")
        }

        lock.lock()
        if generation == mine { stateText = ok ? "ok" : "failed" }     // a newer request owns it otherwise
        lock.unlock()
        if ok {
            retryDelay = 10
        } else {
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 120)
            helperLog("block-retry in \(Int(delay)) s")
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                lock.lock()
                let newest = generation
                lock.unlock()
                guard newest == mine else { return }         // a newer request took over
                run(armed: armed, rules: rules, reason: "retry", generation: mine)
            }
        }
    }

    /// The three kinds of blocking are started together, so the slow one (the DNS settings go
    /// through `networksetup`, seconds) never holds back the fast ones: the process killer is
    /// started first (its first pass runs at once), the pf rules load on another thread while
    /// this one switches the DNS.
    private func arm(_ rules: BlockRuleSet, elapsed: @escaping () -> String) -> Bool {
        if rules.processNames.isEmpty && rules.processPaths.isEmpty {
            killer.stop()
        } else {
            killer.start(names: rules.processNames, paths: rules.processPaths)
            helperLog("block-step processes started at_ms=\(elapsed())")
        }

        // Networks = the listed ones plus every address the domain rules resolved to earlier
        // (the cache on disk), so blocking by address is in force before any lookup is made.
        currentRules = rules
        refreshPass = 0
        let names = allNames(rules)
        let cached = names.isEmpty ? [] : cache.cidrs(for: names)
        let networks = Self.merged(rules.cidrs, cached)
        if !names.isEmpty { helperLog("block-addr cached=\(cached.count) names=\(names.count)") }

        // What the applications were given while blocking was off sits in the system resolver's
        // cache until the DNS switch flushes it: read it now, in parallel with the switch.
        if !names.isEmpty {
            let armed = rules
            let exclude = Set(lastUpstreams)
            resolveQueue.async { [self] in
                let found = AddressResolver.systemLookup(names: names, exclude: exclude)
                queue.async { [self] in commit(armed, found: found, source: "system") }
            }
        }

        let group = DispatchGroup()
        var pfOK = true
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            pfOK = networks.isEmpty ? pf.remove() : pf.apply(cidrs: networks)
            if !networks.isEmpty { helperLog("block-step networks done ok=\(pfOK) count=\(networks.count) at_ms=\(elapsed())") }
            group.leave()
        }

        var dnsOK = true
        if rules.domains.isEmpty && rules.domainSuffixes.isEmpty && rules.domainKeywords.isEmpty {
            dnsOK = disableDNS()
        } else {
            dnsOK = enableDNS(rules)
            helperLog("block-step dns done ok=\(dnsOK) at_ms=\(elapsed())")
        }
        group.wait()
        appliedNetworks = pfOK ? Set(networks) : []
        // Blocking by address does not depend on the sinkhole, so this runs whatever `dnsOK` is.
        scheduleRefresh(rules, after: 0.2)
        return pfOK && dnsOK
    }

    private func disarm() -> Bool {
        refreshEpoch += 1                               // voids any lookup still running
        currentRules = nil
        appliedNetworks = []
        killer.stop()
        var ok = pf.remove()
        ok = disableDNS() && ok
        return ok
    }

    // MARK: DNS

    private func enableDNS(_ rules: BlockRuleSet) -> Bool {
        sinkhole.update(domains: rules.domains, suffixes: rules.domainSuffixes, keywords: rules.domainKeywords)
        if !sinkholeUp {
            do {
                try sinkhole.start()
                sinkholeUp = true
            } catch {
                // Nothing listens, so the services must not be pointed here.
                helperLog("block-dns cannot start: \(error)")
                return false
            }
        }
        let upstream = DNSConfig.enable(sinkhole: sinkhole.addresses)
        sinkhole.setUpstreams(upstream)
        lastUpstreams = upstream
        dnsActive = true
        watcher.start { [weak self] in
            self?.queue.async { self?.reconcileDNS() }
        }
        return true
    }

    /// The network changed: point any new or reset service at the sinkhole again and refresh
    /// the upstream list. `DNSConfig.enable` writes nothing when nothing differs.
    private func reconcileDNS() {
        guard dnsActive, sinkholeUp else { return }
        let upstream = DNSConfig.enable(sinkhole: sinkhole.addresses)
        sinkhole.setUpstreams(upstream)
        if !upstream.isEmpty { lastUpstreams = upstream }
        if let rules = currentRules { scheduleRefresh(rules, after: 2) }    // the resolvers may have changed
    }

    private func disableDNS() -> Bool {
        watcher.stop()
        dnsActive = false
        // Settings first, sinkhole second: until every service is back the sinkhole must still
        // answer. If a service cannot be restored the sinkhole stays up and this is retried.
        guard DNSConfig.restore() else { return false }
        if sinkholeUp {
            sinkhole.stop()
            sinkholeUp = false
        }
        return true
    }

    // MARK: Address blocking (domains resolved to addresses)

    private static func merged(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0).inserted }
    }

    /// The resolvers to ask: the ones the sinkhole forwards to (a snapshot taken before the DNS
    /// switch, so a switch in progress cannot change them), else whatever is known, else two
    /// public ones so that blocking by address still works with no usable resolver.
    private func resolverUpstreams() -> [String] {
        if !lastUpstreams.isEmpty { return lastUpstreams }
        let known = DNSConfig.knownUpstreams()
        return known.isEmpty ? ["1.1.1.1", "8.8.8.8"] : known
    }

    /// Rule names plus the names clients were seen asking for (the sinkhole reports them).
    private func allNames(_ rules: BlockRuleSet) -> [String] {
        AddressResolver.names(for: rules, seen: cache.recentSeen(limit: 120))
    }

    /// Looks the names up after `delay` and again later while armed: quickly a few times right
    /// after arming (CDN answers rotate), then every few minutes. The lookups run on their own
    /// queue, so a disarm is never held back by a slow resolver.
    private func scheduleRefresh(_ rules: BlockRuleSet, after delay: TimeInterval) {
        refreshEpoch += 1
        let epoch = refreshEpoch
        guard !AddressResolver.names(for: rules).isEmpty else { return }
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard epoch == refreshEpoch, currentRules == rules else { return }
            let upstreams = resolverUpstreams()
            let names = allNames(rules)
            var exclude = Set(upstreams)
            for address in AddressResolver.extraResolvers { exclude.insert(address) }
            for address in sinkhole.addresses { exclude.insert(address) }
            resolveQueue.async { [self] in
                var outcome = AddressResolver.resolve(names: names, upstreams: upstreams, exclude: exclude)
                for (name, list) in AddressResolver.systemLookup(names: names, exclude: exclude, timeout: 3) {
                    outcome.found[name, default: []] += list
                }
                queue.async { [self] in
                    finishRefresh(rules, epoch: epoch, outcome: outcome)
                }
            }
        }
    }

    /// Adds `found` to the cache and reloads pf when the address set really changed. Also used
    /// for a pass that arrives too late to be applied: what was learned is kept regardless.
    @discardableResult
    private func commit(_ rules: BlockRuleSet, found: [String: [String]], source: String) -> Bool {
        let isNew = cache.merge(found)
        cache.saveIfNeeded()
        guard currentRules == rules else { return true }                      // disarmed or superseded
        let networks = Self.merged(rules.cidrs, cache.cidrs(for: allNames(rules)))
        if Set(networks) == appliedNetworks { return true }                   // nothing to reload
        let ok = networks.isEmpty ? pf.remove() : pf.apply(cidrs: networks)
        if ok { appliedNetworks = Set(networks) }
        helperLog("block-addr applied count=\(networks.count) new=\(isNew) source=\(source) ok=\(ok)")
        return ok
    }

    private func finishRefresh(_ rules: BlockRuleSet, epoch: Int, outcome: AddressResolver.Outcome) {
        let applied = commit(rules, found: outcome.found, source: "dns")
        guard epoch == refreshEpoch, currentRules == rules else { return }

        let warm: [TimeInterval] = [2, 6, 20]
        var interval: TimeInterval = refreshPass < warm.count ? warm[refreshPass] : 300
        refreshPass += 1
        if outcome.answered == 0 {
            refreshFailures += 1
            interval = min(15 * Double(1 << min(refreshFailures, 4)), 120)
            helperLog("block-addr no answer to \(outcome.asked) query(ies); retry in \(Int(interval)) s")
        } else {
            refreshFailures = 0
        }
        if !applied { interval = min(interval, 30) }
        scheduleRefresh(rules, after: interval)
    }

    // MARK: Learning from the sinkhole

    /// The sinkhole answered a query for `name`: some client is about to use that name, and
    /// its addresses go into pf at once. Any thread. A name is looked at once a minute at most.
    private func noteBlockedName(_ name: String) {
        learnLock.lock(); defer { learnLock.unlock() }
        let now = Date()
        if let last = learnedAt[name], now.timeIntervalSince(last) < 60 { return }
        learnedAt[name] = now
        if learnedAt.count > 2000 { learnedAt = learnedAt.filter { now.timeIntervalSince($0.value) < 60 } }
        learnPending.insert(name)
        guard !learnScheduled else { return }
        learnScheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) { [self] in drainLearned() }
    }

    private func drainLearned() {                                             // on `queue`
        learnLock.lock()
        let names = Array(learnPending.prefix(50))
        learnPending.removeAll()
        learnScheduled = false
        learnLock.unlock()
        guard let rules = currentRules, !names.isEmpty else { return }
        cache.noteSeen(names)
        let upstreams = resolverUpstreams()
        var exclude = Set(upstreams)
        for address in AddressResolver.extraResolvers { exclude.insert(address) }
        for address in sinkhole.addresses { exclude.insert(address) }
        resolveQueue.async { [self] in
            var outcome = AddressResolver.resolve(names: names, upstreams: upstreams, exclude: exclude)
            for (name, list) in AddressResolver.systemLookup(names: names, exclude: exclude, timeout: 2) {
                outcome.found[name, default: []] += list
            }
            queue.async { [self] in
                if commit(rules, found: outcome.found, source: "query") == false { helperLog("block-addr query pass could not reload pf") }
            }
        }
    }

    // MARK: Uninstall

    /// `warden-helper-daemon --restore`, run with the daemon stopped.
    static func restoreAll() -> Bool {
        var ok = DNSConfig.restore()
        ok = PFRules().remove() && ok
        if ok {
            HelperFiles.remove(BlockIPC.stateDirectory + "/state.json")
            HelperFiles.remove(AddressCache.path)
        }
        return ok
    }
}
