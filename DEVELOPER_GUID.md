# WardenHelper Developer Guide

For anyone changing WardenHelper's code. Users should start with [README.md](README.md) and [docs/USER_GUIDE.md](docs/USER_GUIDE.md).

Version described: app `1.0.0` (build 13), helper protocol `BlockIPC.helperVersion = 9`.

## Contents

1. [Project at a glance](#1-project-at-a-glance)
2. [Repository layout](#2-repository-layout)
3. [Architecture](#3-architecture)
4. [Module reference](#4-module-reference)
5. [Key flows](#5-key-flows)
6. [Development process](#6-development-process)
7. [Development rules](#7-development-rules)
8. [Recipes: common changes](#8-recipes-common-changes)
9. [Debugging and verification](#9-debugging-and-verification)
10. [Release and packaging](#10-release-and-packaging)

---

## 1. Project at a glance

WardenHelper is a macOS menu-bar agent (`LSUIElement`, no Dock icon) that shows live network speed, public IP and country, VPN state, VPN-only traffic, subscription quota and AI-service exit regions. Optionally, while the VPN is off, it blocks listed domains, processes and IP ranges through a small root helper.

| Property | Value |
| --- | --- |
| Language | Swift, AppKit (no SwiftUI, no storyboards/xibs) |
| Build system | `make` + `swiftc` (no Xcode project, no SwiftPM) |
| Minimum macOS | 13.0 (`MIN_MACOS` in Makefile, `LSMinimumSystemVersion` in Info.plist) |
| Third-party dependencies | None. Logos embedded from Lobe Icons (MIT) |
| Signing | Ad-hoc (`codesign --sign -`); no Apple Developer account, so no NetworkExtension / SMAppService privileged helper |
| UI language | Simplified Chinese only; every string lives in `Sources/Strings.swift` (`L10n`) |
| Executables | `WardenHelper` (the app) and `warden-helper-daemon` (root daemon, bundled in `Contents/Resources/`) |
| Size | about 17,000 lines: app 13.4k, helper 2.2k, Python tool 100 |

### Design constraints that shape the code

- **Local use, no paid developer account.** Root work is done by a self-installed LaunchDaemon, installed through one `osascript ... with administrator privileges` prompt.
- **WardenHelper never runs as root.** Everything privileged is in `Helper/`, and it re-validates every rule it receives.
- **Monochrome until something is wrong.** The bar uses colour for degree (quota) and shape/opacity for state (VPN).
- **Fast reaction to VPN loss.** The path from "tunnel gone" to "arm the helper" skips the main thread and any confirmation delay.

---

## 2. Repository layout

```
WardenHelper/
├── Makefile                  build, run, install, release, zip
├── README.md                 user-facing overview
├── DEVELOPER_GUID.md         this file
├── docs/                     user guide, blocking, traffic, subscriptions, data, security, troubleshooting
├── Resources/
│   ├── Info.plist            bundle id com.warden-helper.app, version, ATS exception for ip-api.com
│   ├── AppIcon.icns          light icon (bundle default: Finder, notifications)
│   └── AppIconDark.icns      dark variant, swapped in at runtime by AppIconTheme
├── Sources/                  the app: every *.swift here is compiled into WardenHelper
│   └── BlockProtocol.swift   ALSO compiled into the helper (Foundation / Darwin only!)
├── Helper/                   the root helper: every *.swift here + BlockProtocol.swift
└── tools/
    └── traffic_log_report.py summarises the hourly traffic logs
```

Build inputs are wildcards (`Sources/*.swift`, `Helper/*.swift`), so adding a file needs no build-file edit. The two targets are separate `swiftc` invocations. Consequently:

- A type in `Sources/` is **not** visible to the helper, except `BlockProtocol.swift`.
- `BlockProtocol.swift` may import only `Foundation` / `Darwin`. Do not reference AppKit, `L10n` or `Preferences` there.
- `Sources/main.swift` is the app entry point (it creates `AppDelegate` and runs). `Helper/main.swift` is the helper's own, with `--daemon --uid N`, `--restore` and `--version`.

---

## 3. Architecture

### 3.1 Process model

```
┌──────────────────────────────── WardenHelper.app (user, LSUIElement) ───────────────────────────────┐
│  AppDelegate  ── owns status item, dropdown menu, wires everything                              │
│     ├─ Observation:   NetworkMonitor, NetworkChangeDetector, VPNStateMonitor, VPNStatusDetector │
│     ├─ Data sources:  IPFlagFetcher, AIServiceMonitor, SubscriptionManager (+ SubscriptionKit)  │
│     ├─ Traffic:       ControllerClient → VPNTrafficTracker → NodeTrafficStore, TrafficLog       │
│     ├─ Blocking:      BlockRulesStore → BlockController → HelperClient / HelperInstaller        │
│     ├─ Presentation:  MenuBarView, MenuInfoBlock, ChangeNotifier, VPNDisconnectPrompt,          │
│     │                 ResumeStatusPrompter                                                      │
│     └─ Settings UI:   SettingsWindowController + *Page files, Preferences, Theme, L10n          │
└───────────────┬─────────────────────────────────────────────────────────────────────────────────┘
                │ Unix socket /var/run/warden-helper-daemon.sock (0600, peer-uid check)
                │ one JSON line per request: apply | status | events
┌───────────────▼──────────────── warden-helper-daemon (root LaunchDaemon, KeepAlive) ───────────────────┐
│  IPCServer → Engine (HelperState) → Enforcer ─┬─ DNSSinkhole + DNSConfig  (names)               │
│                                               ├─ AddressResolver + AddressCache (name→IPs)      │
│                                               ├─ PFRules                  (IP drop via pf anchor)│
│                                               └─ ProcessKiller            (process rules)       │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
        external: proxy kernel controller (sing-box clash_api / mihomo) on 127.0.0.1:9090
                  IP lookup APIs, AI service probes, subscription URLs (https)
```

### 3.2 Layers

| Layer | Responsibility | Typical files |
| --- | --- | --- |
| Entry / composition | Create objects, connect callbacks, own the status item | `main.swift`, `AppDelegate` |
| Observation | Detect network and VPN changes, sample interface counters | `NetworkMonitor`, `NetworkChangeDetector`, `VPNStatusDetector`, `VPNStateMonitor`, `NetworkInterfaceReader` |
| Data services | Fetch or compute information | `IPFlagFetcher`, `AIServiceMonitor`, `SubscriptionManager`, `SubscriptionKit`, `ControllerClient`, `VPNTrafficTracker`, `NodeTrafficStore` |
| Blocking (app side) | Parse rules, decide when to arm, talk to the helper | `BlockRules`, `BlockRulesStore`, `BlockController`, `HelperClient`, `HelperInstaller`, `BlockProtocol` |
| Blocking (helper) | Enforce, persist, recover | `Helper/*` |
| Presentation | Draw the bar, menu, notifications, pop-ups | `MenuBarView`, `AppDelegate`, `ChangeNotifier`, `VPNDisconnectPrompt`, `ResumeStatusPrompter`, `MarkerText`, `IPMask` |
| Settings | Window, pages, preferences, backup | `SettingsWindowController`, `*Page`, `Preferences`, `Theme`, `SettingsBackup`, `Strings` |
| Support | Logging, crash restart | `HourlyLog`, `TrafficLog` (also holds `BlockLog`), `CrashGuard` |

### 3.3 Communication patterns

- **Singletons** (`.shared`) for services: `Preferences`, `BlockController`, `BlockRulesStore`, `VPNTrafficTracker`, `SubscriptionManager`, `AIServiceMonitor`, `ChangeNotifier`, `VPNDisconnectPrompt`, `CrashGuard`.
- **`NotificationCenter`** for "state changed, re-read it" (always posted on the main thread):

  | Name | Source |
  | --- | --- |
  | `WardenHelperPreferencesChanged` | `Preferences` (every setter calls `notify()`) |
  | `WardenHelperSubscriptionsChanged` | `SubscriptionManager` |
  | `WardenHelperAIServiceChanged` | `AIServiceMonitor` |
  | `WardenHelperBlockRulesChanged` | `BlockRulesStore` |
  | `WardenHelperBlockControllerChanged` | `BlockController` |
  | `WardenHelperHelperStateChanged` | `HelperInstaller` |
  | `WardenHelperSettingsContentChanged` | `SettingsPage` (page refits its height) |

- **Closures** for push events from detectors: `vpnMonitor.onTunnelChange / onFlip / onUpdate`, `networkMonitor.onTick`, `networkChangeDetector.onNetworkChange`.
- **No shared mutable state across threads** except through each class's own serial queue.

### 3.4 Threading

| Queue (label) | Owner | Notes |
| --- | --- | --- |
| main | AppKit, `AppDelegate`, UI, `Preferences` notifications | Most model classes are "main thread only" except where documented |
| `warden-helper.vpnstate` (userInteractive) | `VPNStateMonitor` | Serial `check()`; first event of a burst checked at once, others merge within 30 ms |
| `warden-helper.block.send` (userInteractive) | `BlockController` | Arm/disarm is sent from the thread that noticed the tunnel change |
| `warden-helper.helperclient` | `HelperClient` | One connection per request, results delivered on main |
| `warden-helper.networkmonitor` | `NetworkMonitor` | 1-timer; `onTick` drives `VPNTrafficTracker.sample()` |
| `warden-helper.controller`, `warden-helper.vpntraffic` | `ControllerClient`, `VPNTrafficTracker` | Controller polling and totals |
| `warden-helper.nodetraffic.io`, `warden-helper.hourlylog.*`, `warden-helper.blockrules` | Persistence / file parse | Utility QoS |
| helper: `warden-helper.daemon.engine`, `.enforcer`, `.resolve`, `.killer`, `.dns.io/.dns.work`, `.connections`, `.netwatch` | `Engine`, `Enforcer`, … | `Enforcer` is single-queue; only the newest request is carried out |

Rule of thumb: anything that shells out, resolves DNS, or does file I/O stays off the main queue and reports back with `DispatchQueue.main.async`.

---

## 4. Module reference

### 4.1 Application shell

| File | Function |
| --- | --- |
| `main.swift` | Creates `NSApplication`, assigns `AppDelegate`, runs |
| `AppDelegate.swift` | `applicationDidFinishLaunching` builds the status item and the whole dropdown menu, starts every service (order matters: see 5.1), handles quit approval (`quitApproved`), Dock presence while a window is open, and refreshes menu rows from live state |
| `AppIconTheme` | Swaps `AppIcon.icns` / `AppIconDark.icns` into `NSApp.applicationIconImage` when the system appearance changes; `AppIconImageView` (About header) follows it |
| `CrashGuard.swift` | With `restartOnCrash` on, spawns a tiny detached shell watcher that reopens the app if the process dies without its "clean exit" marker. Gives up after 3 restarts in 2 min |

### 4.2 Network and VPN observation

| File | Function |
| --- | --- |
| `NetworkInterfaceReader` | One `getifaddrs` loop: cumulative counters per interface (physical `en*`, `pdp_ip*`; `utun*` excluded), interface enumeration for the settings pop-up |
| `NetworkMonitor` | Samples counters on a timer, computes per-second up/down speed from real elapsed time, handles 32-bit wrap. With `speedFromProxy` and a fresh controller reading it reports proxied speed instead |
| `NetworkChangeDetector` | SCDynamicStore + `NWPathMonitor` + 1 s interface poll, debounced; fires `onNetworkChange` |
| `VPNStatusDetector` | Decides if public traffic leaves via a tunnel (`utun`, `ipsec`, `ppp`, `tun`, `tap`): kernel route lookup → `route -n get` → configd primary interface. Also `SystemProxyDetector` (HTTP/HTTPS/SOCKS/PAC proxy). Blocks up to about 1 s: call from a background queue |
| `VPNStateMonitor` | All triggers (routing socket, network change, wake/unlock, 1 s safety timer) feed one serial `check()`. Emits `onTunnelChange` (first), `onFlip`, `onUpdate` |
| `ResumeStatusPrompter` | Arms on "away" events (sleep, lock, screensaver), fires once when the display is awake and unlocked, then shows the status after routes settle |
| `VPNDisconnectPrompt` | Non-modal floating window for the whole VPN life cycle; closes itself when the VPN returns |
| `ChangeNotifier` | `UserNotifications` cards: VPN connect/disconnect, launch card, post-resume card. Unique identifiers per alert, retry up to 4 times, removes older cards of the same kind |

### 4.3 Data services

| File | Function |
| --- | --- |
| `IPFlagFetcher` | Public IP + country flag. Tries ip-api.com, ipapi.co, api.country.is, ipinfo.io, ipwho.is in order (next raced after 0.7 s). Caches last known value |
| `AIServiceMonitor` | Probes ChatGPT, Claude, Grok, Gemini on their own main domain so the proxy's per-domain rules apply; reports exit IP/region/city, Cloudflare node, owner, latency; rejects non-public exit addresses and retries; notifies on region change |
| `AIIcons` | Vendor logos embedded as PNG data |
| `SubscriptionKit` | Foundation-only: download with retry and TTL cache, stale-cache fallback, `subscription-userinfo` header, Clash YAML (`MiniYAMLParser`) / base64 parsing, plan-info extraction (`SubscriptionPlanExtractor`), rule set + testers |
| `SubscriptionManager` | The subscription list (`subscription-links.json`), scheduling, per-link cache keyed by UUID, quota levels (`QuotaLevel`), what the bar shows (`SubscriptionBarChoice`), update log |
| `ControllerClient` | Clash-compatible controller API: address resolution/auto-detect, secret in Keychain (`ControllerSecretStore`), `GET /proxies`, `GET /connections`, failure classification (`ControllerFailure`) |
| `VPNTrafficTracker` | Turns controller polls into proxied-only totals (today / month / session), per-connection growth, midnight and month rollover, proxy speed |
| `NodeTrafficStore` | Per-node traffic: minute buckets (48 h) folded into hour buckets (40 days); `StatsPeriod`; saved to `node-traffic.json` every 30 s and on quit |
| `HourlyLog`, `TrafficLog`, `BlockLog` | Plain-text logs, one file per local hour, mode 0600. `TrafficLog` renames the file with the hour's GB total |

### 4.4 Blocking, app side

| File | Function |
| --- | --- |
| `BlockProtocol.swift` | **Shared with helper.** `BlockRule`, `BlockRuleKind`, `BlockRuleSet`, `BlockRuleValidator` (the single validator), `BlockLimits`, `BlockIPC` constants, `HelperRequest/Response/Event` |
| `BlockRules.swift` | `BlockRulesParser`: JSON array → rules, with line-numbered errors (`BlockRulesParseError`) |
| `BlockRulesStore` | Reads/watches the rules file, keeps the last good set; parse runs on a utility queue; status for Settings |
| `BlockController` | Decides arm/disarm, owns retries, drift detection, 2 s poll that also fetches helper events into the block log. Exposes `Display` for the menu |
| `HelperClient` | Unix-socket client, one request per connection |
| `HelperInstaller` | Install / update / uninstall via `osascript` admin prompt; verifies against bundled SHA-256; reports `State` (`需要更新` when running version < bundled) |
| `Preferences.restoreBlockDefault()` | When the VPN drops, forces the block switch back to on |

### 4.5 Blocking, helper side (`Helper/`)

| File | Function |
| --- | --- |
| `main.swift` | `--daemon --uid N`, `--restore`, `--version` |
| `IPCServer` | Socket 0600 owned by the WardenHelper user + `LOCAL_PEERCRED` check; one JSON line in/out; max 4 MiB |
| `HelperState` (`Engine`, `EventLog`) | Holds armed flag and rules, persists `state.json`, serves `apply` / `status` / `events`, re-applies after crash or reboot |
| `Enforcer` | Turns "armed + rules" into reality on one serial queue; only the newest request is carried out; failed steps retry with growing delay |
| `DNSSinkhole` | UDP+TCP DNS on 127.0.0.1:53 and ::1:53. Listed names → `0.0.0.0` / `::`, other record types empty (NOERROR), everything else forwarded to the original resolvers |
| `DNSConfig` | Points each network service's DNS at the sinkhole; writes `dns-backup.json` BEFORE changing anything; `NetworkWatcher` reacts to service changes; `restore()` |
| `AddressResolver` | Hand-built raw UDP/TCP lookups straight to the pre-switch resolvers (never through the sinkhole) |
| `AddressCache` | `resolved-cache.json`; addresses stay blocked 7 days; applied first on arm |
| `PFRules` | Anchor `com.apple/250.WardenHelper`, `block return out quick`; `pfctl -E` reference token, released on disarm; `/etc/pf.conf` untouched |
| `ProcessKiller` | 1 s libproc scan; `process_name` exact match or `process_path` prefix; SIGTERM then SIGKILL after 2 s; never PID 1, the helper, WardenHelper or protected paths |
| `Exec` | The only way the helper starts programs: absolute path + argv array, never a shell. `HelperFiles` holds paths |

### 4.6 Presentation and settings

| File | Function |
| --- | --- |
| `MenuBarView` | Custom `NSView` inside the status button. One layout flag (`stackedLayout`): single row or two rows. Draws subscription text, speed slots (fixed width, tabular digits), shield (`lock.icloud.fill`, slashed when down), region/IP, AI icon. Down state dims to 50 % |
| `MenuInfoBlock` | `enum` of dropdown blocks in menu order: `aiServices`, subscription usage, VPN traffic. Each has a switch + preference key |
| `MarkerText` | Draws a leading status emoji smaller than the text |
| `IPMask` | Hide-IP rendering (`•••.•••.•••.•••`) |
| `SettingsWindowController` | Window, sidebar, `Tab` list, shared controls (`ToggleSwitch`, `Closure*` controls, `NumberStepper`, `NoteLabel`, `SettingRow`, `GroupBox`), search, and the `build…Page` functions |
| `AIServicePage`, `SubscriptionSettingsPage`, `SubscriptionRulesPage`, `TrafficReportPage`, `BarSubscriptionPicker` | Pages large enough to live in their own file |
| `Theme` | Palette (sidebar 0.965→0.175, page 1.0→0.125, card 0.973→0.215), `DividerView`, `Symbols`, `ControlMetrics`, `SettingsFont` |
| `Preferences` | Typed wrapper over UserDefaults; `settingSchema` (key → type) drives reset, export, import |
| `SettingsBackup` | JSON export/import with typed `BackupValue` validation; optional subscription list |
| `Strings.swift` (`L10n`) | All user-facing text |

### 4.7 Tooling

`tools/traffic_log_report.py` reads `poll` and `open` lines from the traffic logs and prints bytes by route, kernel totals, `missed`, tunnel growth and top hosts. Options: `[logfile-or-folder] [--since "YYYY-MM-DD HH:MM"] [--top N]`. Python 3, standard library only.

---

## 5. Key flows

### 5.1 Startup (`AppDelegate.applicationDidFinishLaunching`)

1. `CrashGuard` termination handler and `apply()`; power-off observer.
2. Status item, `MenuBarView`, then the whole dropdown (IP, VPN rows, blocking row, AI block, subscription block, VPN-traffic block, actions).
3. `networkMonitor.onTick → VPNTrafficTracker.sample()`; preferences observer.
4. `BlockRulesStore.start()`, then `BlockController.start()`.
5. `VPNStateMonitor` callbacks: `onTunnelChange` calls `BlockController.tunnelChanged` **first** (arm/disarm without delay), then `VPNTrafficTracker.tunnelChanged`. `onFlip` posts the VPN notification. `onUpdate` drives the pop-up, status cards and AI re-check.
6. `ResumeStatusPrompter`, `NetworkChangeDetector`, workspace wake/session observers.
7. `startNetworkMonitor()`, AI monitor, `SubscriptionManager.start()`.

Keep step 5's order: blocking must not wait on anything else.

### 5.2 VPN goes down

```
routing socket / network change / 1 s timer
  → VPNStateMonitor.check() (own queue)
  → onTunnelChange(false)
      → BlockController.tunnelChanged: Preferences.restoreBlockDefault(); send "arm" (retry 0.1, 0.2, 0.4 s … ×8, then 2 s poll)
      → VPNTrafficTracker.tunnelChanged: stop polling
  → onFlip: notification; onUpdate: pop-up
  helper: Engine.apply → Enforcer → DNS sinkhole + DNS config, resolve addresses, pf anchor, process killer
```

### 5.3 VPN traffic counting

`NetworkMonitor` tick → `VPNTrafficTracker.sample()` → `ControllerClient` polls `/connections` → per-connection growth (keyed by connection id) is added to totals if no tag in `chains` is Direct → `NodeTrafficStore` gets the same bytes per node (first non-group tag in `chains`) → `TrafficLog` records `poll` lines. The first reading after the tunnel or controller comes up is a baseline only.

### 5.4 Subscription refresh

`SubscriptionManager` (30 s schedule; due links at launch; paused 8 s after wake; failures retry in 5 min) → `SubscriptionFetcher` (retry, cache) → `ClashSubscriptionParser` → `SubscriptionPlanExtractor` with the effective rules (`SubscriptionItem.effectiveRules`) → quota level → `WardenHelperSubscriptionsChanged` → bar, menu, notifications on level worsening.

### 5.5 Settings change

Setter in `Preferences` → `notify()` → `AppDelegate.preferencesChanged` re-renders the bar/menu; the settings window rebuilds only what it must. New preference keys must be added to `settingSchema` (see 8.1).

---

## 6. Development process

### 6.1 Environment

- macOS 13+, Xcode Command Line Tools (`xcode-select --install`). No Xcode project is needed.
- Optional: Python 3 for `tools/traffic_log_report.py`.
- A proxy kernel with the Clash API enabled (sing-box `clash_api` or mihomo) to exercise traffic counting.

### 6.2 Daily loop

```bash
make run          # native-arch build, kills the running WardenHelper, launches the new one
make clean        # remove build/
make help         # list targets
```

`make` compiles all of `Sources/*.swift` in one `swiftc` call (whole-module `-O`), then the helper, signs both ad-hoc, and assembles `build/WardenHelper.app`. There is no incremental build, no unit-test target and no linter.

### 6.3 Working with the helper

The helper installed in `/Library/PrivilegedHelperTools/` is a copy. After changing anything in `Helper/` or `BlockProtocol.swift`:

1. Bump `BlockIPC.helperVersion` (behaviour change) so the app shows 需要更新.
2. `make run`, open 设置 › VPN 与网络 › 断开屏蔽 and use the update button (one admin prompt).
3. Watch `/var/log/warden-helper-daemon.log` and the block log.

Always test the uninstall path too (`warden-helper-daemon --restore` must put DNS and pf back).

### 6.4 Suggested workflow for a change

1. Identify the layer (observation, service, presentation, settings, helper).
2. Make the change inside that layer; put text in `Strings.swift`.
3. If it adds a setting, follow 8.1; if it adds a menu block, follow 8.2.
4. `make run`; exercise light and dark mode, VPN on / off / system-proxy, and wake/unlock where relevant.
5. If it touches counting, compare the traffic log `missed` values (see 9.1).
6. If it touches the helper, bump the version and run the manual checks in [docs/BLOCKING.md](docs/BLOCKING.md#testing-vpn-off).
7. Update README / docs in the same change.

### 6.5 Versioning

`CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` are the only version source (the Makefile reads it for the release zip name). Helper compatibility is separate: `BlockIPC.helperVersion`.

---

## 7. Development rules

Project rules (kept from the original README):

1. **Native first.** AppKit controls and system colours; a custom control or colour only when none exists, minimal and dynamic (no fixed hex).
2. **No icons, custom backgrounds or decorative lines** in the settings window.
3. **Keep descriptions rare**: only where they say something the title does not.
4. **All text goes in `Strings.swift`.**

Additional conventions observed in the code:

- **Settings placement.** What the bar or dropdown shows → 显示. Data behind a feature → that feature's group. Every notification and pop-up → 通知提醒. Whole-app matters → 通用. Dangerous, rare or pure-preference items stay in Settings, not the dropdown. Notes name the page they depend on.
- **Menu order.** Status → network → usage → actions. Anything display-only gets a `MenuInfoBlock` with its own switch; `MenuInfoBlock` cases are declared in menu order.
- **Shared code.** `BlockProtocol.swift` is the contract with the helper: keep it dependency-free.
- **Never shell out with user data.** In the helper, only `Exec.run(absolutePath, [args])`. Service names come from `networksetup`, addresses pass an `inet_pton` round trip.
- **Validate twice.** Rules are validated in the app on read and again in the helper on receipt (`BlockRuleValidator`).
- **Fail safe.** Restoring system state (DNS, pf) must be possible after a crash at any step: write the backup first, then change.
- **Logs.** Hourly files, mode 0600, `time tag key=value ...` lines; never log subscription tokens (the update-log export keeps only link hosts and replaces the home folder with `~`).
- **Secrets.** Controller secret lives in the Keychain, never in UserDefaults, never exported or reset.
- **Comments.** Types start with a `///` paragraph saying what and why, not how. Keep comments in the same style.
- **Threading.** Document "Main thread only" on classes that require it; mark cross-queue work explicitly.

---

## 8. Recipes: common changes

### 8.1 Add a setting

1. Add a typed property to `Preferences` (get with default, set → `notify()`). Use the key name once.
2. Register the key in `Preferences.settingSchema` (reset, export and import follow from this). Add to `deviceOnlyKeys` if it should not move between Macs.
3. Add strings to `L10n`.
4. Add a row in the matching `build…Page` of `SettingsWindowController` (`toggleRow`, `SettingRow`, …). Search picks it up automatically.
5. React in `AppDelegate.preferencesChanged` or the consuming class.

### 8.2 Add a dropdown information block

1. Add a case to `MenuInfoBlock` (key, title, description) **in menu order**.
2. Add its rows in `AppDelegate.applicationDidFinishLaunching` using `addInfoItem(_:block:to:)`.
3. The Settings switch, stored preference, reset and export/import follow from the enum.

### 8.3 Add a settings page

Add one `Tab(id:group:title:heading:…)` entry (with its sidebar symbol) to the tab list and a `build…Page`. Large pages go in their own `…Page.swift`. Search indexes the new page by itself.

### 8.4 Add a block rule kind

1. Add a case to `BlockRuleKind` and validation to `BlockRuleValidator` in `BlockProtocol.swift`.
2. Enforce it in the helper (`Enforcer` and the component that applies it).
3. Document it in [docs/BLOCKING.md](docs/BLOCKING.md); bump `helperVersion`.

### 8.5 Add an AI vendor

Add a case to `AIVendor` (domain, `Probe`), a logo in `AIIcons`, and strings. The menu rows iterate `AIVendor.allCases`.

### 8.6 Add a notification

Text in `L10n`; post through `ChangeNotifier` so identifiers, retries and de-duplication apply. If it is user-controllable, add a preference and put its row under 通知提醒.

### 8.7 Add a subscription-info rule field

Add a case to `SubscriptionRuleField` (storage key, default pattern, group requirement), extend `SubscriptionPlanExtractor` and the tester, and the 解析规则 page.

---

## 9. Debugging and verification

### 9.1 VPN traffic accuracy

Enable 设置 › 流量 › 统计设置 › 记录流量日志, then:

```bash
python3 tools/traffic_log_report.py --since "2026-09-30 21:00"
```

`missed` (kernel total minus counted) near 0 means complete counting. Remaining under-count comes from connections that open and close between two readings.

### 9.2 Blocking

- App log: `~/Library/Logs/WardenHelper/block/<hour>.log`; helper log `/var/log/warden-helper-daemon.log`.
- Helper events are fetched every 2 s, so lines can be up to 2 s out of order. `since_drop_ms` measures drop → helper reply.
- `sudo pfctl -a com.apple/250.WardenHelper -sr` shows the active rules. `networksetup -getdnsservers Wi-Fi` should show the original DNS when disarmed.
- If the system is left in a bad state: `sudo /Library/PrivilegedHelperTools/warden-helper-daemon --restore`.

### 9.3 UI

- Test light and dark mode, both bar layouts, VPN up / down / system proxy, "only icon when down" on and off.
- VoiceOver: the status button carries a spoken summary (`updateAccessibility`); it never reads a hidden IP.

### 9.4 Known limits to keep in mind

See each docs page; the main ones: about 1 s between tunnel loss and arming, DoH and apps with their own resolver bypass the sinkhole, short-lived connections lose their last bytes in counting, no counting while WardenHelper is not running.

---

## 10. Release and packaging

| Command | Result |
| --- | --- |
| `make` | Native build to `build/WardenHelper.app` |
| `make universal` | arm64 + x86_64 slices merged with `lipo` |
| `make install` | Universal build copied to `/Applications` |
| `make release` | `build/WardenHelper-<version>.zip` (ditto, quarantine attributes cleared) + SHA-256 for a Homebrew cask |
| `make zip` | Source zip of `Helper tools Makefile README.md Resources Sources` to `~/Downloads` |
| `make uninstall` | Quit the app, remove `/Applications/WardenHelper.app` (the helper is removed from Settings, which runs `--restore`) |

Packaging notes:

- The helper is signed on its own first with the fixed identifier `com.warden-helper.helper`; the copy installed to `/Library` keeps that signature. Then the whole bundle is signed ad-hoc (needed for notifications to register).
- Release zips are ad-hoc signed, not notarized: users must clear quarantine or approve the app on first launch.
- `make zip` lists `Helper` and `tools` twice in its argument list and should also include `docs` and `DEVELOPER_GUID.md`; update it when you adopt this documentation set.
