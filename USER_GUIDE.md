# WardenHelper User Guide

## 1. The menu bar

Monochrome when fine; it changes only when something is wrong. **Colour = degree** (quota), **shape and opacity = state** (VPN).

`140 GB · 剩 25 天 │ ↑ 2.1 KB/s ↓ 3.1 KB/s │ 🛡 香港`

| Part | Behaviour |
| --- | --- |
| Subscription | Remaining traffic (rounded down) and days to the next reset (`剩 0 天` on the reset day, `待更新` when overdue). **Orange**: below the traffic threshold (default 10 GB) or expiry threshold (default 3 days). **Red**: expired or no traffic left |
| Speeds | Small bold arrows at their own width, fixed-width slots, tabular digits, decimal units. With arrows on, "/s" is dropped and the unit follows the number after a thin space |
| Connection | Solid `lock.icloud.fill` (white in dark mode, black in light) plus the exit country as a short Chinese name, or the IP |
| System proxy | A system HTTP / HTTPS / SOCKS / PAC proxy without a tunnel is not a fault; the shield slot shows a `network` glyph |
| VPN not connected | The same icon with a diagonal slash. With 菜单栏 › VPN 状态 › VPN 断开时只显示状态图标 off, the normal bar stays and dims to 50 % |
| AI status | A `sparkles` icon after the region: solid when all four AI services exit in the expected region, slashed otherwise or when a check fails. Hidden while checks are not running and when the bar shows only the slashed VPN icon |
| VoiceOver | The status button carries a spoken summary (VPN state, country, quota level); a hidden IP is never read |

Choose a single-row or two-row layout in 设置 › 显示 › 菜单栏 › 布局.

## 2. The dropdown menu

Top to bottom: status → what the network is doing → usage → actions. Tooltips explain each value and where it is configured.

| Group | Row | Notes |
| --- | --- | --- |
| Status | 公网 IP：address · country | Click to copy (even with Hide IP on, the real address is copied) |
| | VPN state | 已连接 / 系统代理已启用 / 未检测到 |
| | Tunnel · uptime | Only with a VPN, e.g. `隧道 utun4 · 已连接 2 小时 14 分` |
| | 屏蔽 | Shown while the helper is blocking or retrying |
| Network (block `AI 服务出口`) | One line per service | `ChatGPT · 台湾 · 440 ms`; click to re-check |
| Usage (block `订阅`) | 剩余流量, 下次重置, 到期 | Click to update now. `快照` marks a node-name value |
| Usage (block `VPN 流量`) | 今日 / 本月 / 本次启动 ↑ ↓ | Proxied traffic only; shows `不可用 · reason` when the controller is unreachable |
| | 节点流量报表… | Opens 设置 › 流量 › 流量报表 |
| Actions | 刷新公网 IP (⌘R) · 隐藏 IP 地址 | Hide IP shows `•••.•••.•••.•••` everywhere |
| | 设置… (⌘,) · 退出 (⌘Q) | |

Each information block has its own switch under 设置 › 显示 › 下拉菜单. The IP, VPN state and action rows always stay. 重置流量统计 is not in the menu (destructive and rare): it lives in 设置 › 流量 › 统计设置.

## 3. Settings

The window mirrors System Settings: a sidebar with grouped pages, the page on the right under its title. Width is fixed (956 pt); height is resizable.

**Search** (box above the sidebar) finds any text a page shows (titles, notes, button and pop-up labels, placeholders, service names; typed values and secrets are skipped). All words typed must match; case and full / half width are ignored. Click a result (or press Return for the first) to open the page, scroll to the match and flash it.

| Sidebar entry | Contents |
| --- | --- |
| 显示 › 菜单栏 | 布局 · 订阅用量 (which subscription, thresholds) · 网速 (arrows, 刷新频率, 显示代理节点速度, 监测网卡) · VPN 状态 · 地区与 IP · AI 状态 (icon, 期望出口地区) |
| 显示 › 下拉菜单 | One switch per information block (default on): AI 服务出口 / 订阅用量 / VPN 流量 |
| 订阅 › 订阅管理 | The list, per-link settings, usage, update log. See [Subscriptions](SUBSCRIPTIONS.md) |
| 订阅 › 解析规则 | Regexes that read plan info, with validation and a paste test |
| 流量 › 流量报表 | Per-node 上传 / 下载 / 合计 over eight periods |
| 流量 › 统计设置 | Controller address and secret, connection status, traffic log, reset. See [VPN Traffic](VPN_TRAFFIC.md) |
| VPN 与网络 › 断开屏蔽 | Switch, rules file, helper install state, block log. See [Blocking](BLOCKING.md) |
| VPN 与网络 › AI 出口 | Manual check, per-service exit details, background-check switch and interval (default 60 s, range 3–3600) |
| 应用 › 通知提醒 | VPN status, subscription update result, quota warnings, AI region change |
| 应用 › 通用 | Launch at login, restart after a crash, hide IP, export / import, reset to defaults |

### Choosing the speed source

By default the bar speed comes from physical interfaces (`en*`, `pdp_ip*`; `utun*` excluded). With 菜单栏 › 网速 › 显示代理节点速度 on and a VPN up, it shows the speed of proxied traffic from the controller, and falls back to interface speed when no fresh controller reading exists.

### AI exit checks

Four services are probed on their own main domains, so your proxy's per-domain routing applies. Checks run in the background by default and again 1.5 s and 6 s after a network or VPN change. Expected region: 台湾 (default), 日本 or 美国. Non-public exit addresses (e.g. `fe80::…`) are rejected and retried. A change in exit country or region versus the last successful check raises a notification (通知提醒 › AI 服务).

## 4. VPN state and notifications

A VPN is active when public traffic leaves through a tunnel interface (`utun`, `ipsec`, `ppp`, `tun`, `tap`). A tunnel always wins over a system proxy. Split tunnels (e.g. Tailscale without an exit node) are not a VPN.

| Event | What you see |
| --- | --- |
| Launch | A launch card at every start (subscription info only with VPN up) |
| VPN connected | 🟢 notification |
| VPN disconnected | 🔴 notification (the only one with sound) and a floating pop-up that stays until the VPN returns (setting: 通知提醒 › 弹窗提醒; the pop-up also appears at launch, on reconnect and after wake / unlock) |
| No VPN | ⚪️ notification |
| After sleep, lock or screensaver | One status card once the display is awake and unlocked (a warning without a VPN, a confirmation with one) |
| Subscription update | 更新结果通知: a manual update always notifies; an automatic update notifies on success; after repeated failures only the first failure notifies |
| Quota worsens | One notification when traffic or expiry goes ok → orange → red, per subscription. Restarts and same-level refreshes stay quiet |

Cards for a connected VPN end with the bar subscription's 剩余流量 / 下次重置 / 到期. Notifications use unique identifiers and are retried up to four times if macOS refuses them.

## 5. Public IP

`IPFlagFetcher` tries ip-api.com, ipapi.co, api.country.is, ipinfo.io and ipwho.is in order, racing the next one after 0.7 s if slow. It refreshes on every network change and every 15 s.

## 6. Export, import and reset (设置 › 应用 › 通用)

- **导出…** writes one JSON file: every preference that differs from its default (except 监测网卡 and the rules-file path, which are per-Mac) and, optionally, the subscription list (name, link, interval, enabled, rule overrides). The controller secret is never exported. **Subscription links carry access tokens**; the file is readable by the current user only, so keep it private.
- **导入…** replaces settings (missing, wrong-type or out-of-range keys revert to defaults) and merges subscriptions (same id, else same link; changed or new ones refresh immediately). VPN traffic totals and quota alert levels are untouched.
- **恢复默认设置** removes only the known setting keys; traffic totals and alert levels survive.

## 7. Launch at login and crash restart

- 通用 › 启动 › **开机自动启动** launches WardenHelper at login.
- **异常退出后自动重启** (default on) reopens WardenHelper after an unexpected exit, never after a normal quit, log out, shut down or SIGTERM. It gives up after 3 restarts within 2 minutes to avoid a crash loop.

## 8. Quitting and uninstalling

Quit from the dropdown (⌘Q). To remove everything, see [Troubleshooting › Complete uninstall](TROUBLESHOOTING.md#complete-uninstall).
