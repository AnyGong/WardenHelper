import Cocoa
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    var statusItem: NSStatusItem!
    var menuBarView: MenuBarView!
    var networkMonitor: NetworkMonitor!
    var ipFetcher: IPFlagFetcher!
    var ipMenuItem: NSMenuItem!
    var vpnMenuItem: NSMenuItem!
    var vpnDetailItem: NSMenuItem!
    var blockMenuItem: NSMenuItem!
    var trafficTodayItem: NSMenuItem!
    var trafficMonthItem: NSMenuItem!
    var trafficSessionItem: NSMenuItem!
    var subscriptionHeaderItem: NSMenuItem!
    var subscriptionTrafficItem: NSMenuItem!
    var subscriptionResetItem: NSMenuItem!
    var subscriptionExpiryItem: NSMenuItem!
    var subscriptionSeparator: NSMenuItem!
    var hideIPItem: NSMenuItem!
    /// The "AI 服务" block of the dropdown: header, one row per service, separator.
    private var aiMenuItems: [AIVendor: NSMenuItem] = [:]
    private var aiSectionItems: [NSMenuItem] = []
    /// Every row of every information block in the dropdown, in menu order, with the block it belongs
    /// to. Each block has its own switch in Settings (`MenuInfoBlock`); rows are added with `addInfoItem`.
    private var infoItems: [(item: NSMenuItem, block: MenuInfoBlock)] = []
    /// What each info row wants for itself (hidden because it has no data, ...), before its block's switch.
    private var infoOwnHidden: [ObjectIdentifier: Bool] = [:]
    /// What the bar's AI icon currently shows (nil = hidden).
    private var aiBarState: AIServiceMonitor.Overall?
    private var menuRefreshTimer: Timer?
    var settingsController: SettingsWindowController?
    var networkChangeDetector: NetworkChangeDetector!
    var vpnMonitor: VPNStateMonitor!
    var resumePrompter: ResumeStatusPrompter!
    private var activityToken: NSObjectProtocol?

    /// The address currently shown, or nil while it is unknown.
    private var currentIP: String?
    /// Two-letter country code of the address shown ("" = unknown).
    private var currentCountryCode: String = ""
    /// System proxy in use while no VPN is active, e.g. "HTTP 127.0.0.1:7890" (nil = none).
    private var currentProxy: String?
    /// Subscription the dropdown rows describe (what a click on them refreshes).
    private var subscriptionMenuID: String?
    /// Values the last preference change was compared with.
    private var appliedHideIP = false
    private var appliedThresholds = ""
    /// Exit country name and VPN state, kept for the VoiceOver summary.
    private var currentRegionName: String?
    private var vpnActive: Bool?
    /// Subscription pieces of the VoiceOver summary (nil while none is shown).
    private var subscriptionAX: [String]?
    /// Subscription details for the status-item tooltip (nil while none is shown).
    private var subscriptionTip: String?
    /// Refresh interval the speed monitor is currently running with.
    private var appliedInterval: Double = 0
    /// False until the first VPN reading after launch has been handled.
    private var launchVPNChecked = false

    /// True once quitting is settled (confirmed, SIGTERM, log out / shut down): no more prompts.
    private var quitApproved = false

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Crash guard: restart after unexpected exits (setting), SIGTERM = deliberate quit,
        // log out / shut down = deliberate quit without a prompt.
        CrashGuard.shared.installTerminationHandler { [weak self] in
            self?.quitApproved = true
            NSApp.terminate(nil)
        }
        CrashGuard.shared.apply()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            self?.quitApproved = true
        }
        AppIconTheme.shared.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuBarView = MenuBarView()

        if let button = statusItem.button {
            button.title = ""
            menuBarView.frame = button.bounds
            menuBarView.autoresizingMask = [.width, .height]
            button.addSubview(menuBarView)
        }

        // Menu
        let menu = NSMenu()

        // ── Public IP (click to copy) ──
        ipMenuItem = NSMenuItem(title: L10n.ipRow(L10n.ipLoading), action: nil, keyEquivalent: "")
        ipMenuItem.image = Self.menuSymbol("globe")
        ipMenuItem.toolTip = L10n.ipCopyTip
        menu.addItem(ipMenuItem)

        // ── VPN: state, plus tunnel + uptime once connected ──
        vpnMenuItem = NSMenuItem(title: L10n.vpnMenuStateOff, action: nil, keyEquivalent: "")
        vpnMenuItem.image = Self.vpnOffImage
        vpnMenuItem.isEnabled = false
        menu.addItem(vpnMenuItem)

        // Tunnel interface + uptime, combined into one line; only visible while connected.
        vpnDetailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        vpnDetailItem.image = Self.menuSymbol("clock")
        vpnDetailItem.isEnabled = false
        vpnDetailItem.indentationLevel = 1     // detail of the VPN state line above
        vpnDetailItem.isHidden = true
        menu.addItem(vpnDetailItem)

        // Blocking status; only visible while the helper is blocking (VPN off).
        blockMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        blockMenuItem.image = Self.menuSymbol("nosign")
        blockMenuItem.isEnabled = false
        blockMenuItem.indentationLevel = 1     // detail of the VPN state line above
        blockMenuItem.toolTip = L10n.blockMenuTip
        blockMenuItem.isHidden = true
        menu.addItem(blockMenuItem)
        menu.addItem(NSMenuItem.separator())

        // ── AI services: icon + exit region + latency, from the background checks ──
        let aiHeader = sectionHeaderItem(L10n.aiMenuHeader, tip: L10n.aiMenuHeaderTip)
        addInfoItem(aiHeader, block: .aiServices, to: menu)
        aiSectionItems = [aiHeader]
        for vendor in AIVendor.allCases {
            let item = NSMenuItem(title: "", action: #selector(refreshAIStatus), keyEquivalent: "")
            item.indentationLevel = 1
            aiMenuItems[vendor] = item
            aiSectionItems.append(item)
            addInfoItem(item, block: .aiServices, to: menu)
        }
        let aiSeparator = NSMenuItem.separator()
        aiSectionItems.append(aiSeparator)
        addInfoItem(aiSeparator, block: .aiServices, to: menu)
        refreshAIMenu()

        // ── Subscription: traffic, next reset, expiry; a click updates it ──
        subscriptionHeaderItem = sectionHeaderItem(L10n.subMenuHeader, tip: L10n.subMenuHeaderTip)
        addInfoItem(subscriptionHeaderItem, block: .subscription, to: menu)
        subscriptionTrafficItem = subscriptionRow(symbol: "chart.pie")
        subscriptionResetItem = subscriptionRow(symbol: "arrow.triangle.2.circlepath")
        subscriptionExpiryItem = subscriptionRow(symbol: "hourglass")
        for item in [subscriptionTrafficItem!, subscriptionResetItem!, subscriptionExpiryItem!] { addInfoItem(item, block: .subscription, to: menu) }
        subscriptionSeparator = NSMenuItem.separator()
        addInfoItem(subscriptionSeparator, block: .subscription, to: menu)
        setSubscriptionBlockHidden(true)   // shown once a subscription exists

        // ── VPN-only traffic totals ──
        addInfoItem(sectionHeaderItem(L10n.trafficHeader, tip: L10n.trafficHeaderTip), block: .vpnTraffic, to: menu)
        trafficTodayItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        trafficMonthItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        trafficSessionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        for (item, symbol, tip) in [(trafficTodayItem!, "sun.max", L10n.trafficTodayTip),
                                    (trafficMonthItem!, "calendar", L10n.trafficMonthTip),
                                    (trafficSessionItem!, "timer", L10n.trafficSessionTip)] {
            item.image = Self.menuSymbol(symbol)
            item.toolTip = tip
            item.isEnabled = false
            item.indentationLevel = 1          // under the 「VPN 流量」 header
            addInfoItem(item, block: .vpnTraffic, to: menu)
        }
        addInfoItem(menuItem(L10n.nodeStatsMenu, symbol: "chart.bar.xaxis", action: #selector(openNodeStats)), block: .vpnTraffic, to: menu)
        addInfoItem(NSMenuItem.separator(), block: .vpnTraffic, to: menu)

        // ── Actions ──
        let refreshIPItem = menuItem(L10n.refreshIP, symbol: "arrow.clockwise", action: #selector(refreshIP), key: "r")
        refreshIPItem.toolTip = L10n.refreshIPTip
        menu.addItem(refreshIPItem)
        hideIPItem = menuItem(L10n.hideIPMenu, symbol: "eye.slash", action: #selector(toggleHideIP))
        hideIPItem.toolTip = L10n.hideIPMenuTip
        hideIPItem.state = Preferences.shared.hideIP ? .on : .off
        menu.addItem(hideIPItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(L10n.settings, symbol: "gearshape", action: #selector(openSettings), key: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(L10n.quit, symbol: "power", action: #selector(quitApp), key: "q"))
        menu.delegate = self
        statusItem.menu = menu

        appliedHideIP = Preferences.shared.hideIP
        appliedThresholds = Self.thresholdSignature()

        // Core components
        ipFetcher = IPFlagFetcher()
        networkMonitor = NetworkMonitor()

        ChangeNotifier.shared.prepare()
        ChangeNotifier.shared.scheduleWelcome() // every launch
        TrafficLog.shared.log("start", "app=WardenHelper version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") controller=\(Preferences.shared.controllerAddress.isEmpty ? "auto" : Preferences.shared.controllerAddress)")

        // Opt out of App Nap so timers and alerts are not delayed.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Real-time network and VPN change alerts")

        // Callbacks
        networkMonitor.onSpeedUpdate = { [weak self] upload, download in
            self?.menuBarView.updateSpeeds(upload: upload, download: download)
        }
        networkMonitor.onTick = { VPNTrafficTracker.shared.sample() }

        ipFetcher.onUpdate = { [weak self] flag, ipString, country in
            self?.showIP(flag: flag, ip: ipString, country: country)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: Preferences.changedNotification, object: nil)
        BlockRulesStore.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(blockDisplayChanged),
                                               name: BlockController.changedNotification, object: nil)
        BlockController.shared.start()

        // VPN state: alerts go out from the monitor's queue, the UI updates on main.
        vpnMonitor = VPNStateMonitor()
        vpnMonitor.onTunnelChange = {
            BlockController.shared.tunnelChanged($0)      // first: arm / disarm at once, no delay
            VPNTrafficTracker.shared.tunnelChanged($0)
        }
        vpnMonitor.onFlip = { state in
            ChangeNotifier.shared.notifyVPNChange(active: state.active, interface: state.interface)
        }
        vpnMonitor.onUpdate = { [weak self] state, changed in
            guard let self = self else { return }
            // A system proxy switched on / off changes the exit address too (no VPN flip involved).
            let proxyChanged = self.vpnActive != nil && self.currentProxy != state.proxy
            self.vpnActive = state.active
            self.currentProxy = state.proxy
            self.menuBarView.setProxy(state.proxy != nil)
            self.menuBarView.setVPN(state.active)
            self.updateMenuBarWidth()   // VPN down: the bar shrinks to the fault icon alone
            if state.active {
                self.setTitle(self.vpnMenuItem, L10n.vpnMenuStateOn)
                self.vpnMenuItem.image = Self.vpnOnImage
            } else if state.proxy != nil {
                self.setTitle(self.vpnMenuItem, L10n.vpnMenuStateProxy)
                self.vpnMenuItem.image = Self.vpnProxyImage
            } else {
                self.setTitle(self.vpnMenuItem, L10n.vpnMenuStateOff)
                self.vpnMenuItem.image = Self.vpnOffImage
            }
            self.refreshVPNDetails()
            self.updateTooltip()
            let firstReading = !self.launchVPNChecked
            self.launchVPNChecked = true
            if firstReading {
                // Every launch shows the pop-up: a warning without a VPN, a confirmation with one.
                VPNDisconnectPrompt.shared.show(reason: state.active ? .connectedAtLaunch : .notConnectedAtLaunch,
                                                interface: state.interface)
            } else if changed {
                // Every flip shows the pop-up (one window, updated in place): connected or dropped.
                VPNDisconnectPrompt.shared.show(reason: state.active ? .reconnected : .dropped,
                                                interface: state.interface)
            }
            ChangeNotifier.shared.vpnUpdate(state, changed: changed)
            if changed || proxyChanged {
                self.ipFetcher.fetchWithRetry() // routes just changed: refresh the region / IP shown
                AIServiceMonitor.shared.routeChanged()
            }
        }
        vpnMonitor.start()

        // After sleep / lock / screensaver, once the user is back: show the current VPN status again.
        resumePrompter = ResumeStatusPrompter(monitor: vpnMonitor)
        resumePrompter.start()

        // Network change detector: follow-up VPN checks and IP refresh.
        networkChangeDetector = NetworkChangeDetector()
        networkChangeDetector.onNetworkChange = { [weak self] in
            self?.vpnMonitor.networkChanged()   // VPN check now + follow-ups while routes settle
            self?.ipFetcher.fetchWithRetry()    // refresh the address shown
            AIServiceMonitor.shared.routeChanged()
        }
        networkChangeDetector.start()

        // Re-check the VPN after wake / unlock.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.vpnMonitor.networkChanged()
            }
        }

        startNetworkMonitor()
        ipFetcher.fetch()
        updateMenuBarWidth()

        // AI exit checks run in the background by default; the dropdown follows them.
        NotificationCenter.default.addObserver(forName: AIServiceMonitor.changedNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.refreshAIMenu()
            self?.refreshAIBar()
        }
        AIServiceMonitor.shared.applyPreference()
        refreshAIBar()

        // Status dot + remaining traffic + expiry date: follows the subscription list, and is
        // re-evaluated every minute because "days left" changes with the calendar.
        NotificationCenter.default.addObserver(self, selector: #selector(subscriptionsChanged),
                                               name: SubscriptionManager.changedNotification, object: nil)
        refreshSubscriptionBar()
        let subscriptionBarTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshSubscriptionBar()
        }
        subscriptionBarTimer.tolerance = 10
        RunLoop.main.add(subscriptionBarTimer, forMode: .common)

        // Subscription links (Settings > 订阅): refresh whatever is due, then on each one's interval.
        SubscriptionManager.shared.start()

        // Every 15 s: catches exit-address changes that raise no network event.
        let pollTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.ipFetcher.poll()
        }
        pollTimer.tolerance = 2
        RunLoop.main.add(pollTimer, forMode: .common)
    }

    // MARK: - Display updates

    private func showIP(flag: String, ip: String, country: String) {
        let known = ip != IPFlagFetcher.unknownIP
        currentIP = known ? ip : nil
        currentCountryCode = known ? country : ""
        currentRegionName = (known && !country.isEmpty) ? L10n.regionName(country) : nil
        let shown = known ? ip : L10n.ipUnknown

        menuBarView.updateRegion(country, ip: shown)   // the bar masks the address itself
        renderIPRow()                                  // also ends a "refreshing…" title
        ipMenuItem.action = known ? #selector(copyIP) : nil
        updateMenuBarWidth()
        updateTooltip()
    }

    /// The dropdown's address row: "203.0.113.5 · 美国", with the address masked when hidden.
    private func renderIPRow() {
        guard let ip = currentIP else { setTitle(ipMenuItem, L10n.ipRow(L10n.ipUnknown)); return }
        let shown = IPMask.displayed(ip)
        // The same short Chinese name as the menu bar (not the two-letter code).
        let region = currentRegionName ?? ""
        setTitle(ipMenuItem, L10n.ipRow(region.isEmpty ? shown : "\(shown) · \(region)"))
    }

    /// Only touch a menu item when its text really changes.
    private func setTitle(_ item: NSMenuItem, _ title: String) {
        guard item.title != title else { return }
        item.title = title
        item.attributedTitle = MarkerText.attributed(title, font: NSFont.menuFont(ofSize: 0))
    }

    /// Small, disabled, secondary-colored section header.
    private func sectionHeaderItem(_ text: String, tip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.toolTip = tip
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor])
        item.isEnabled = false
        return item
    }

    private static let vpnOnImage = menuSymbol("lock.icloud.fill")
    private static let vpnOffImage = menuSymbol("lock.icloud.fill", color: .systemGray)
    private static let vpnProxyImage = menuSymbol("network", color: .systemBlue)
    private static let detailClockImage = menuSymbol("clock")
    private static let detailProxyImage = menuSymbol("arrow.left.arrow.right")

    /// SF Symbol for a menu row (a template image unless a color is given).
    private static func menuSymbol(_ name: String, color: NSColor? = nil) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let color = color {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        return base.withSymbolConfiguration(config)
    }

    private func menuItem(_ title: String, symbol: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.image = Self.menuSymbol(symbol)
        return item
    }

    private func updateTooltip() {
        let ip = currentIP.map(IPMask.displayed) ?? L10n.ipUnknown
        var tip = ip + " · " + vpnMenuItem.title
        if Preferences.shared.showSubscription, let sub = subscriptionTip { tip += "\n" + sub }
        if statusItem.button?.toolTip != tip { statusItem.button?.toolTip = tip }
        updateAccessibility()
    }

    /// The bar is drawn by hand, so VoiceOver gets a spoken summary instead. Slow-changing facts
    /// only (VPN state, exit country, quota); live speeds would make it chatter. When the bar
    /// shows just the slashed shield, the summary is just the VPN state.
    private func updateAccessibility() {
        guard let button = statusItem.button else { return }
        var parts: [String] = []
        if let active = vpnActive {
            parts.append(active ? L10n.axVPNOn : (currentProxy != nil ? L10n.axProxyOn : L10n.axVPNOff))
        }
        let onlyIcon = vpnActive == false && currentProxy == nil && Preferences.shared.vpnDownShowsOnlyIcon
        if !onlyIcon {
            if Preferences.shared.showFlag {
                if Preferences.shared.showIPInsteadOfFlag, let ip = currentIP {
                    if !Preferences.shared.hideIP { parts.append(ip) }   // never read a hidden address aloud
                }
                else if let name = currentRegionName { parts.append(L10n.axExit(name)) }
            }
            if Preferences.shared.showSubscription, let sub = subscriptionAX { parts += sub }
            if let ai = aiBarState {
                let region = L10n.regionName(Preferences.shared.aiExpectedRegion)
                parts.append(ai == .normal ? L10n.axAINormal : L10n.axAIAbnormal(region))
            }
        }
        let label = (["WardenHelper"] + parts).joined(separator: "，")
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
    }

    @objc private func blockDisplayChanged() {
        switch BlockController.shared.display {
        case .off:
            blockMenuItem.isHidden = true
        case .active(let count):
            setTitle(blockMenuItem, L10n.blockMenuActive(count))
            blockMenuItem.isHidden = false
        case .failed:
            setTitle(blockMenuItem, L10n.blockMenuFailed)
            blockMenuItem.isHidden = false
        }
    }

    @objc func preferencesChanged() {
        CrashGuard.shared.apply()
        // Restart the sampler only when the interval changed.
        if Preferences.shared.refreshInterval != appliedInterval { startNetworkMonitor() }
        let prefs = Preferences.shared
        if prefs.hideIP != appliedHideIP {
            appliedHideIP = prefs.hideIP
            renderIPRow()
        }
        hideIPItem.state = prefs.hideIP ? .on : .off
        applyInfoVisibility()   // the per-block switches for the dropdown's information blocks
        AIServiceMonitor.shared.applyPreference()
        refreshAIMenu()
        refreshAIBar()

        // New thresholds re-colour the bar at once; alerts only record the new baseline.
        let thresholds = Self.thresholdSignature()
        if thresholds != appliedThresholds {
            appliedThresholds = thresholds
            SubscriptionManager.shared.evaluateQuota(notify: false)
        }
        refreshSubscriptionBar()   // thresholds and the chosen subscription may have changed

        updateMenuBarWidth()
        updateTooltip()
        menuBarView.needsDisplay = true

        // Window not on screen: drop it so the next open rebuilds from the current preferences.
        if settingsController?.window?.isVisible != true {
            settingsController = nil
        }
    }

    private static func thresholdSignature() -> String {
        "\(Preferences.shared.lowTrafficThresholdGB)/\(Preferences.shared.expiryThresholdDays)"
    }

    @objc private func subscriptionsChanged() {
        refreshSubscriptionBar()
    }

    /// Redraws / resizes only when what the menu bar shows really changes.
    private func refreshSubscriptionBar() {
        let info = SubscriptionManager.shared.menuBarInfo()
        menuBarView.updateSubscription(info)
        subscriptionTip = info?.tooltip
        subscriptionAX = info.map { i -> [String] in
            var parts = [i.trafficText.map(L10n.axTraffic), i.resetText].compactMap { $0 }
            switch i.status {
            case .ok: break
            case .warning: parts.append(L10n.axQuotaWarning)
            case .critical: parts.append(L10n.axQuotaCritical)
            }
            return parts
        }
        refreshSubscriptionMenu()
        updateMenuBarWidth()
        updateTooltip()
    }

    // MARK: - Information blocks (one switch each)

    /// Adds a row of an information block. Every block row of the dropdown goes through here, so the
    /// block's own switch in Settings (「下拉菜单」) covers it. Later changes to the row's own
    /// visibility use `setInfoHidden`, never `item.isHidden`.
    private func addInfoItem(_ item: NSMenuItem, block: MenuInfoBlock, to menu: NSMenu) {
        infoItems.append((item, block))
        menu.addItem(item)
        applyInfoVisibility(item, block: block)
    }

    /// The row's own wish (no data, nothing running, ...); it is shown only while its block's switch is on too.
    private func setInfoHidden(_ item: NSMenuItem, _ hidden: Bool) {
        infoOwnHidden[ObjectIdentifier(item)] = hidden
        if let entry = infoItems.first(where: { $0.item === item }) {
            applyInfoVisibility(item, block: entry.block)
        }
    }

    private func applyInfoVisibility(_ item: NSMenuItem, block: MenuInfoBlock) {
        let hide = (infoOwnHidden[ObjectIdentifier(item)] ?? false) || !Preferences.shared.showsMenuBlock(block)
        if item.isHidden != hide { item.isHidden = hide }
    }

    /// A block's switch changed (or the menu is about to open): bring every info row in line.
    private func applyInfoVisibility() {
        for entry in infoItems { applyInfoVisibility(entry.item, block: entry.block) }
    }

    // MARK: - Subscription rows in the menu

    private func subscriptionRow(symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(refreshSubscription), keyEquivalent: "")
        item.image = Self.menuSymbol(symbol)
        item.toolTip = L10n.subMenuTip
        item.indentationLevel = 1              // under the 「订阅」 header
        return item
    }

    private func setSubscriptionBlockHidden(_ hidden: Bool) {
        for item in [subscriptionHeaderItem!, subscriptionTrafficItem!, subscriptionResetItem!,
                     subscriptionExpiryItem!, subscriptionSeparator!] {
            setInfoHidden(item, hidden)
        }
    }

    /// Traffic / next reset / expiry of the subscription shown in the bar, coloured like the bar.
    private func refreshSubscriptionMenu() {
        let manager = SubscriptionManager.shared
        guard let sub = manager.dropdownItem() else {
            subscriptionMenuID = nil
            setSubscriptionBlockHidden(true)
            return
        }
        subscriptionMenuID = sub.id
        let now = Date()
        let prefs = Preferences.shared

        var header = L10n.subMenuHeaderNamed(sub.name.isEmpty ? L10n.subUnnamed : sub.name)
        if manager.isRefreshing(sub.id) { header += " · " + L10n.subMenuUpdating }
        setHeader(subscriptionHeaderItem, header)

        var trafficText = sub.remainingGB.map {
            L10n.subMenuTraffic(SubscriptionFormat.traffic($0), snapshot: sub.realtimeRemainingGB == nil)
        }
        let resetText = SubscriptionFormat.reset(sub, now: now).map(L10n.subMenuReset)
        let expiryText = sub.expireDate.map { L10n.subMenuExpiry(SubscriptionFormat.expiry($0, now: now)) }
        if trafficText == nil, resetText == nil, expiryText == nil { trafficText = L10n.subMenuNoData }

        setSubscriptionRow(subscriptionTrafficItem, trafficText,
                           level: QuotaLevel.traffic(gb: sub.remainingGB, thresholdGB: prefs.lowTrafficThresholdGB),
                           tip: SubscriptionFormat.trafficLine(sub))
        setSubscriptionRow(subscriptionResetItem, resetText, level: .ok, tip: nil)
        setSubscriptionRow(subscriptionExpiryItem, expiryText,
                           level: QuotaLevel.expiry(days: sub.expiryDays(now: now), thresholdDays: prefs.expiryThresholdDays),
                           tip: nil)
        setSubscriptionBlockHidden(false)
        // Rows without a value stay hidden (the block header and separator remain).
        setInfoHidden(subscriptionTrafficItem, trafficText == nil)
        setInfoHidden(subscriptionResetItem, resetText == nil)
        setInfoHidden(subscriptionExpiryItem, expiryText == nil)
    }

    private func setHeader(_ item: NSMenuItem, _ text: String) {
        guard item.title != text else { return }
        item.title = text
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor])
    }

    /// Fixed-width digits; orange / red text like the menu bar when a threshold is crossed.
    /// The key in `representedObject` stops needless updates (level changes count too).
    private func setSubscriptionRow(_ item: NSMenuItem, _ text: String?, level: QuotaLevel, tip: String?) {
        guard let text = text else { return }
        let key = "\(level.rawValue)|\(text)"
        item.toolTip = tip.map { $0 + "\n" + L10n.subMenuTip } ?? L10n.subMenuTip
        guard item.representedObject as? String != key else { return }
        item.representedObject = key
        item.title = text
        let size = NSFont.menuFont(ofSize: 0).pointSize
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]
        switch level {
        case .ok: break
        case .warning: attributes[.foregroundColor] = NSColor.systemOrange
        case .critical: attributes[.foregroundColor] = NSColor.systemRed
        }
        item.attributedTitle = NSAttributedString(string: text, attributes: attributes)
    }

    private func updateMenuBarWidth() {
        // Resize only on a real change (avoids flicker).
        let optimalLength = menuBarView.calculateOptimalWidth()
        if abs(statusItem.length - optimalLength) > 0.5 {
            statusItem.length = optimalLength
        }
    }

    private func startNetworkMonitor() {
        appliedInterval = Preferences.shared.refreshInterval
        networkMonitor.start(interval: appliedInterval)
    }

    // MARK: - VPN details in the menu

    func menuWillOpen(_ menu: NSMenu) {
        hideIPItem.state = Preferences.shared.hideIP ? .on : .off
        applyInfoVisibility()
        refreshAIMenu()
        refreshVPNDetails()
        // Live uptime / totals while the menu is open (.common: menu tracking skips the default mode).
        menuRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshVPNDetails() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        menuRefreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
    }

    private func refreshVPNDetails() {
        let s = VPNTrafficTracker.shared.snapshot()

        if let tunnel = s.tunnel, let since = s.connectedSince {
            vpnDetailItem.isHidden = false
            vpnDetailItem.image = Self.detailClockImage
            let uptime = VPNInfoFormat.duration(Date().timeIntervalSince(since))
            setDetail(vpnDetailItem, L10n.vpnDetail(tunnel: tunnel, uptime: uptime))
        } else if vpnActive != true, let proxy = currentProxy {
            vpnDetailItem.isHidden = false
            vpnDetailItem.image = Self.detailProxyImage
            setDetail(vpnDetailItem, L10n.proxyDetail(proxy))
        } else {
            vpnDetailItem.isHidden = true
        }
        refreshSubscriptionMenu()   // "更新中…" and days left follow while the menu is open

        // While the controller cannot be read, one line says why; the totals (not stale) come back with it.
        if case .unavailable(let failure) = s.controller, s.tunnel != nil {
            setDetail(trafficTodayItem, L10n.trafficUnavailableReason(L10n.controllerFailure(failure)))
            setInfoHidden(trafficMonthItem, true)
            setInfoHidden(trafficSessionItem, true)
        } else {
            setInfoHidden(trafficMonthItem, false)
            setInfoHidden(trafficSessionItem, false)
            setDetail(trafficTodayItem, trafficText(L10n.trafficToday, s.today))
            setDetail(trafficMonthItem, trafficText(L10n.trafficMonth, s.month))
            setDetail(trafficSessionItem, trafficText(L10n.trafficSession, s.session))
        }
    }

    /// "今日：↑ 12.3 MB   ↓ 45.6 MB"
    private func trafficText(_ label: String, _ a: TrafficAmount) -> String {
        "\(label)：↑ \(VPNInfoFormat.bytes(a.up))   ↓ \(VPNInfoFormat.bytes(a.down))"
    }

    // MARK: - AI services in the menu

    /// One row:  "ChatGPT · 台湾 · 440 ms"  (vendor · region without flag · latency).
    /// A failed check reads "Claude · 检测失败 · —"; a pending one "Claude · ... · —".
    /// The latency follows the menu's "monochrome when normal" rule: plain secondary text, so it stays
    /// legible on the translucent menu background (saturated green / orange blow out against the
    /// vibrancy and the wallpaper behind it). Only a slow reading (>= 800 ms) turns red.
    private static func aiRow(_ vendor: AIVendor, _ status: AIServiceStatus, checking: Bool) -> (plain: String, styled: NSAttributedString) {
        let font = NSFont.menuFont(ofSize: 0)
        let separator = " · "

        var region: String
        var regionColor: NSColor? = nil
        var latency = "—"
        var latencyColor = NSColor.secondaryLabelColor

        switch status.state {
        case .pending:
            region = checking ? L10n.aiLoadingMark : "—"
            regionColor = .secondaryLabelColor
        case .failed:
            region = L10n.aiMenuFailed
            regionColor = .systemRed
        case .ok:
            region = status.countryCode.isEmpty
                ? (status.countryName.isEmpty ? L10n.aiUnknownPlace : status.countryName)
                : L10n.regionName(status.countryCode)
            if let ms = status.latencyMs {
                latency = "\(ms) ms"
                latencyColor = ms < 800 ? .secondaryLabelColor : .systemRed
            }
        }

        var base: [NSAttributedString.Key: Any] = [.font: font]
        let text = NSMutableAttributedString(string: vendor.shortName, attributes: base)
        var regionAttributes = base
        if let color = regionColor { regionAttributes[.foregroundColor] = color }
        base[.foregroundColor] = NSColor.secondaryLabelColor
        text.append(NSAttributedString(string: separator, attributes: base))
        text.append(NSAttributedString(string: region, attributes: regionAttributes))
        text.append(NSAttributedString(string: separator, attributes: base))
        text.append(NSAttributedString(string: latency, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
            .foregroundColor: latencyColor]))

        return ("\(vendor.shortName)\(separator)\(region)\(separator)\(latency)", text)
    }

    /// Fills the AI block from the monitor. The block is hidden while no check is running
    /// (background checks off and the AI page closed), so it never shows stale or empty rows.
    private func refreshAIMenu() {
        let monitor = AIServiceMonitor.shared
        let visible = monitor.isRunning
        for item in aiSectionItems { setInfoHidden(item, !visible) }
        guard visible else { return }

        let busy = monitor.isRefreshing
        for vendor in AIVendor.allCases {
            guard let item = aiMenuItems[vendor] else { continue }
            let status = monitor.results[vendor] ?? AIServiceStatus()
            let row = Self.aiRow(vendor, status, checking: busy || monitor.loading.contains(vendor))

            if item.title != row.plain { item.title = row.plain }
            if item.attributedTitle?.isEqual(to: row.styled) != true { item.attributedTitle = row.styled }

            var tip = vendor.displayName
            switch status.state {
            case .ok:
                tip += "\n" + L10n.aiLabelIP + "  " + IPMask.displayed(status.ip)
                if !status.city.isEmpty { tip += "\n" + status.city }
                if !status.provider.isEmpty { tip += "\n" + L10n.aiLabelOwner + "  " + status.provider }
            case .failed(let reason):
                tip += "\n" + L10n.aiFailedPrefix + reason
            case .pending:
                break
            }
            item.toolTip = tip + "\n" + L10n.aiMenuClickTip
        }
    }

    /// The bar's AI icon follows the monitor, the designated region and the show/hide setting.
    private func refreshAIBar() {
        let state = Preferences.shared.showAIStatus ? AIServiceMonitor.shared.overall : nil
        guard state != aiBarState else { return }
        aiBarState = state
        menuBarView.setAI(state)
        updateMenuBarWidth()
        updateAccessibility()
    }

    @objc private func refreshAIStatus() {
        AIServiceMonitor.shared.refresh(force: true)
    }

    /// Disabled info line with fixed-width digits, so a ticking value does not jitter.
    private func setDetail(_ item: NSMenuItem, _ text: String) {
        guard item.title != text else { return }
        item.title = text
        let size = NSFont.menuFont(ofSize: 0).pointSize
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)])
    }

    // MARK: - Actions

    @objc func resetTraffic() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.resetTrafficTitle
        alert.informativeText = L10n.resetTrafficMessage
        alert.addButton(withTitle: L10n.resetConfirm)
        alert.addButton(withTitle: L10n.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            VPNTrafficTracker.shared.reset()
            refreshVPNDetails()
        }
    }

    /// One confirmation for every way of quitting (menu, ⌘Q, Dock icon).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitApproved { return .terminateNow }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.quitConfirmTitle
        alert.informativeText = L10n.quitConfirmMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.quitConfirmButton)
        alert.addButton(withTitle: L10n.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            quitApproved = true
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        CrashGuard.shared.markCleanExit()
        VPNTrafficTracker.shared.flush()   // also saves the node statistics
        BlockLog.shared.flush()
    }

    /// 节点流量报表… opens the settings window on 流量 › 流量报表.
    @objc func openNodeStats() {
        showSettings(tab: SettingsWindowController.trafficReportTabID)
    }

    @objc func openSettings() {
        showSettings(tab: nil)
    }

    /// The settings window, on `tab` when given (otherwise on the page it was last showing).
    private func showSettings(tab: String?) {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        if let tab = tab { settingsController?.select(tabID: tab) }
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.window?.makeKeyAndOrderFront(nil)
        showInDock(settingsController?.window)
    }

    // MARK: Dock icon while a window is open

    /// Windows that currently keep the Dock icon alive, and the ones already being observed.
    private var dockWindows = Set<ObjectIdentifier>()
    private var observedWindows = Set<ObjectIdentifier>()

    /// The app has a Dock icon (LSUIElement hides it otherwise) while its settings window is
    /// open; it goes away when the window closes.
    private func showInDock(_ window: NSWindow?) {
        guard let window = window else { return }
        let id = ObjectIdentifier(window)
        dockWindows.insert(id)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if observedWindows.insert(id).inserted {
            NotificationCenter.default.addObserver(
                self, selector: #selector(dockWindowClosed(_:)),
                name: NSWindow.willCloseNotification, object: window)
        }
    }

    @objc private func dockWindowClosed(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        dockWindows.remove(ObjectIdentifier(window))
        if dockWindows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    /// Clicking the Dock icon brings the settings window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    /// Dock icon menu: Settings… (Quit is added by macOS and goes through the confirmation).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L10n.settings, action: #selector(openSettings), keyEquivalent: ""))
        return menu
    }

    @objc func copyIP() {
        guard let ip = currentIP else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }

    @objc func refreshIP() {
        // setTitle, not `.title =`: a stale attributedTitle would win.
        setTitle(ipMenuItem, L10n.ipRow(L10n.refreshing))
        ipFetcher.fetch()
    }

    @objc func refreshSubscription() {
        guard let id = subscriptionMenuID else { return }
        SubscriptionManager.shared.refresh(id: id, manual: true)
        refreshSubscriptionMenu()
    }

    @objc func toggleHideIP() {
        Preferences.shared.hideIP.toggle()   // preferencesChanged() updates the rows
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
