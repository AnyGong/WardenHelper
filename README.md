# WardenHelper

A macOS menu-bar network monitor: live speed, public IP and country, VPN state with alerts, VPN-only traffic totals, proxy-subscription quota, AI-service exit regions, and optional blocking of listed sites, processes and IPs while the VPN is off.

`140 GB · 剩 25 天 │ ↑ 2.1 KB/s ↓ 3.1 KB/s │ 🛡 香港`

- Requires **macOS 27+ on Apple silicon (Mac mini M4)** and Xcode Command Line Tools (to build).
- Native Swift / AppKit, no third-party dependencies, no Xcode project (`make` only).
- UI language: **Simplified Chinese** (all text in `Sources/Strings.swift`).
- Runs as an ad-hoc signed menu-bar agent (no Dock icon). No paid Apple Developer account is needed.

## Features

| Area | What you get |
| --- | --- |
| Speed | Up / down speed from physical interfaces, or proxied-only speed from the proxy kernel |
| VPN state | Detects a tunnel (`utun`, `ipsec`, `ppp`, `tun`, `tap`), system-proxy mode, notifications, a disconnect pop-up, and a status card after sleep / lock / screensaver |
| Public IP | Address and country flag from five fallback APIs; one-click copy; hide-IP mode for screen sharing |
| VPN traffic | Proxied-only totals (today / month / since launch) and per-node reports, counted from the Clash-compatible controller of sing-box or mihomo |
| Subscriptions | Remaining traffic, next reset and expiry from any number of subscription links, with orange / red warnings and notifications |
| AI exits | Exit region and latency for ChatGPT, Claude, Grok and Gemini, with a bar icon and change alerts |
| Blocking | While the VPN is off, block domains, processes and IP ranges from a JSON rules file (needs the optional root helper) |
| Settings | System-Settings-style window with search, export / import, and light / dark support |

## Quick start

```bash
make run        # build for this Mac and launch
make install    # build -> /Applications
```

1. Launch WardenHelper. A menu-bar item appears; click it for the dropdown, or press ⌘, for Settings.
2. **Subscriptions (optional):** 设置 › 订阅 › 订阅管理, add an `https://` link.
3. **VPN traffic (optional):** enable the Clash API in your proxy kernel, then check 设置 › 流量 › 统计设置 (default controller `127.0.0.1:9090`).
4. **Blocking (optional):** write a rules file, set its path in 设置 › VPN 与网络 › 断开屏蔽, and install the helper from the same page (one administrator prompt).

See the [User Guide](USER_GUIDE.md) for the full walkthrough.

## Build targets

| Command | Result |
| --- | --- |
| `make` / `make run` | Build for this Mac (and launch) |
| `make install` / `make uninstall` | Install to / remove from `/Applications` |
| `make release` | `build/WardenHelper-<version>.zip` + SHA-256 |
| `make zip` | Source zip to `~/Downloads` |
| `make clean` | Remove `build/` |

The build also compiles the root helper `warden-helper-daemon` (`Helper/*.swift` + `Sources/BlockProtocol.swift`, identifier `com.warden-helper.helper`) into `WardenHelper.app/Contents/Resources/`. It is used only for blocking.

## Project layout

```
Sources/     the app (every .swift file is compiled in)
Helper/      the root helper for blocking
Resources/   Info.plist, AppIcon.icns (light), AppIconDark.icns
tools/       traffic_log_report.py
*.md         detailed documentation (USER_GUIDE, BLOCKING, ...)
Makefile
```

## Documentation

| Document | For | Contents |
| --- | --- | --- |
| [User Guide](USER_GUIDE.md) | Users | Menu bar, dropdown, every Settings page, notifications, export / import |
| [Subscriptions](SUBSCRIPTIONS.md) | Users | Adding links, how values are read, schedule, matching rules |
| [VPN Traffic](VPN_TRAFFIC.md) | Users, developers | Controller setup, counting rules, node reports, traffic log and report tool |
| [Blocking](BLOCKING.md) | Users, developers | Rules file format, when it blocks, the helper, testing, limits |
| [Data and Logs](DATA_AND_LOGS.md) | Users, developers | Every file, default and Keychain item WardenHelper creates; log formats |
| [Security and Privacy](SECURITY.md) | Users, reviewers | Privilege model, network requests, secrets, hardening notes |
| [Troubleshooting](TROUBLESHOOTING.md) | Users | Symptoms, causes, fixes, how to uninstall completely |
| [Developer Guide](DEVELOPER_GUID.md) | Contributors | Architecture, modules, flows, workflow, rules, recipes |

## Privacy and security in brief

- WardenHelper itself never runs as root; only the optional helper does, and it re-validates every rule it receives.
- Public IP and AI checks contact third-party services (listed in [Security and Privacy](SECURITY.md#network-requests)).
- Subscription links carry access tokens: exported backups contain them, so keep the file private.
- The controller secret defaults to a constant in the source. **Change it and do not publish the source unchanged.**

## Contributing

Read the [Developer Guide](DEVELOPER_GUID.md) first. In short: native AppKit controls and system colours, no decorative elements in Settings, all text in `Strings.swift`, and update the docs in the same change.

## Credits

AI vendor logos from [Lobe Icons](https://icons.lobehub.com) (MIT).
