# VPN Traffic Statistics

WardenHelper counts **only proxied traffic**. It reads the Clash-compatible controller of the proxy kernel (sing-box `clash_api`, mihomo) rather than an interface counter, so connections that leave through a Direct outbound are left out.

## Setup (设置 › 流量 › 统计设置)

1. Enable the controller in the kernel configuration.
2. Set the following in WardenHelper:

| Setting | Notes |
| --- | --- |
| 控制器地址 | Default `127.0.0.1:9090`. Empty = auto-detect (cached address, default, then loopback listeners) |
| 密钥 | Stored in the Keychain (`WardenHelper` / `controller-secret`). Never exported or reset. The first-launch default is a constant (`ControllerSecretStore.defaultSecret`) in the source: **change it, and do not publish the source unchanged** |
| 连接状态 / 测试连接 | 已连接, 密钥错误, 需要密钥, 未找到控制器, 无法连接, 地址无效, 响应无法识别 |

## How counting works

- `GET /proxies` gives the outbound types. A connection is direct if any tag in its `chains` is Direct.
- `GET /connections` is read on the speed timer; only the **growth per connection** (keyed by connection id) is added.
- The first reading after the tunnel or controller comes up is a **baseline** and adds nothing.
- Totals live in UserDefaults (`vpnTraffic.*`) and roll over at midnight and at month end. The dropdown shows 今日 / 本月 / 本次启动 (since WardenHelper started).

**Limits.** Connections that open and close between two readings lose their last bytes. System-proxy mode has no tunnel, so nothing is read. Nothing is counted while WardenHelper is not running.

## Bar speed

See [User Guide › Choosing the speed source](USER_GUIDE.md#choosing-the-speed-source).

## Node statistics (设置 › 流量 › 流量报表)

Proxied traffic per outbound node (for example `Taiwan 01`, `Japan 01`) in eight periods:

| Period | Kind |
| --- | --- |
| 15 分钟, 30 分钟, 1 小时, 6 小时, 12 小时 | Slide with the clock |
| 1 天 | Since 00:00 today |
| 本周 | Since the first day of this week per the system calendar |
| 本月 | Since the 1st, 00:00 |

Columns: 节点 · 上传 · 下载 · 合计. Click a header to sort ascending; click again for descending. Each period keeps its own sort (default 合计 descending). The table refreshes once a second while the page is on screen. Nodes with no traffic in a period are not listed. The summary at the top shows node count, ↑ / ↓ totals, the period covered and what is counted. The dropdown's 节点流量报表… opens this page.

**Naming.** `ControllerClient` names the node of a connection as the first tag in its `chains` that is not a group (selector, urltest, fallback, loadbalance, relay).

**Storage.** `NodeTrafficStore` adds each poll's per-node growth (the same bytes as the totals) to minute buckets kept for 48 hours; older minutes fold into local-hour buckets kept for 40 days. The data is saved to `~/Library/Application Support/WardenHelper/node-traffic.json` every 30 s and on quit. 重置流量统计 clears it as well.

## Traffic log

With 记录流量日志 on (default), `TrafficLog` writes one file per local hour to `~/Library/Logs/WardenHelper/traffic/`:

```
2026-06-01_12:00-13:00_1.235GB.log
```

The GB figure (1 GB = 1000³ bytes) is added when the hour ends, or at the next launch after a crash. Files are mode 0600. Nothing is deleted automatically.

Line format: `time tag key=value ...`. Pairs like `proxy=+1200/+45000` are `up/down` bytes, with `+` marking growth since the previous reading.

| Tag | Meaning |
| --- | --- |
| `start` | WardenHelper started |
| `tunnel` | Tunnel up / down |
| `state` | Controller state change |
| `baseline` | First reading, adds nothing |
| `open` | A new connection appeared |
| `poll` | One reading: `proxy` (counted), `direct`, `unknown`, `kernel` (kernel's own totals), `missed` (= kernel − counted; near 0 = complete), `tun` (interface counters) |
| `summary` | Hour or session summary |
| `reset` | Statistics reset |

### Report tool

```bash
python3 tools/traffic_log_report.py [logfile-or-folder] [--since "2026-09-30 21:00"] [--top 15]
```

Prints bytes by route, kernel totals, `missed`, tunnel growth and the busiest hosts. The default folder is `~/Library/Logs/WardenHelper/traffic`. Python 3, standard library only.
