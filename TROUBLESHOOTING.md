# Troubleshooting

## VPN traffic shows 不可用

| Message | Cause and fix |
| --- | --- |
| 未找到控制器 | The kernel's Clash API is not enabled or not on a known address. Enable `clash_api` (sing-box) or `external-controller` (mihomo), then set 控制器地址 or leave it empty for auto-detect |
| 需要密钥 / 密钥错误 | Set the same secret as the kernel's in 设置 › 流量 › 统计设置 › 密钥 |
| 无法连接 | Kernel not running, or a firewall blocks the port |
| 地址无效 | Use `host:port`, e.g. `127.0.0.1:9090` |
| 响应无法识别 | The address is not a Clash-compatible controller |
| Nothing counted in system-proxy mode | Counting needs a tunnel; system-proxy mode reads nothing |

To verify accuracy, enable 记录流量日志 and run `python3 tools/traffic_log_report.py`; the `missed` column should be near 0.

## Blocking

| Symptom | Check |
| --- | --- |
| Status shows 需要更新 | The installed helper is older than the bundled one. Update it on the 断开屏蔽 page (one admin prompt) |
| Rules not applied | The status line under 规则文件 shows the parse error with a line number; one bad entry rejects the file and the previous rules stay |
| Switch turned back on by itself | Intended: the master switch is forced to on when the VPN drops |
| A listed site still loads | DoH or an app-private resolver; or a CDN address cached before the first lookup. See [Blocking › Limits](BLOCKING.md#limits) |
| VPN cannot reconnect while armed | A listed domain is your proxy server's hostname. Remove it from the rules |
| DNS looks wrong after a crash | `sudo /Library/PrivilegedHelperTools/warden-helper-daemon --restore`, then `networksetup -getdnsservers Wi-Fi` |
| Need details | `~/Library/Logs/WardenHelper/block/` and `/var/log/warden-helper-daemon.log` |

## Notifications

If notifications do not appear, check System Settings › Notifications › WardenHelper. Ad-hoc signing gives the app a stable identity that macOS needs to register notifications; rebuilt copies placed in a different location can lose it. Only the VPN-disconnected notification plays a sound.

## Menu bar

| Symptom | Cause |
| --- | --- |
| Bar dimmed to 50 % with a slashed icon | VPN not connected (turn on 只显示状态图标 to hide the rest instead) |
| `network` glyph instead of the shield | System proxy active, no tunnel |
| Subscription shows `待更新` | The reset day has passed and the provider has not refreshed its info node |
| Remaining traffic shows `快照` | The provider sends no `subscription-userinfo` header, so the value comes from a node name and may be stale |
| AI icon slashed or hidden | A service exits outside 期望出口地区 or a check failed; hidden while checks are not running |

## Complete uninstall

1. 设置 › VPN 与网络 › 断开屏蔽 › uninstall the helper (runs `--restore`, then removes the daemon, binary and socket).
2. Quit WardenHelper and run `make uninstall` (or delete `/Applications/WardenHelper.app`).
3. Optional cleanup:

```bash
defaults delete com.warden-helper.app
rm -rf ~/Library/Application\ Support/WardenHelper ~/Library/Logs/WardenHelper
security delete-generic-password -s WardenHelper -a controller-secret
```
