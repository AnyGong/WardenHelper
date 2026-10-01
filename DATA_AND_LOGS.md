# Data and Logs

Everything WardenHelper stores, and where.

## Storage locations

| Where | What |
| --- | --- |
| UserDefaults (`com.warden-helper.app`) | Preferences; `vpnTraffic.*` totals; `quotaAlertLevels`; global matching rules (`subscriptionRule.<name>`, only when changed); `showMenuBlock.<name>` |
| Keychain (service `WardenHelper`, account `controller-secret`) | The controller secret |
| `~/Library/Application Support/WardenHelper/block-rules.json` | Default rules file (path configurable) |
| `~/Library/Application Support/WardenHelper/subscription-links.json` | Subscription list incl. `ruleOverrides` |
| `~/Library/Application Support/WardenHelper/SubscriptionCache/` | Downloaded subscription content, keyed by link UUID |
| `~/Library/Application Support/WardenHelper/node-traffic.json` | Per-node traffic buckets |
| `~/Library/Logs/WardenHelper/traffic/` | Hourly traffic logs |
| `~/Library/Logs/WardenHelper/block/` | Hourly block logs |
| `/var/db/warden-helper/` (root) | Helper state: `state.json`, `dns-backup.json`, `pf-token`, `pf-rules.conf`, `resolved-cache.json` |
| `/var/log/warden-helper-daemon.log` (root) | Helper log |
| `/Library/PrivilegedHelperTools/warden-helper-daemon` | Installed helper |
| `/Library/LaunchDaemons/com.warden-helper.helper.plist` | Helper LaunchDaemon |
| `/var/run/warden-helper-daemon.sock` | Helper socket (mode 0600) |

## Reset behaviour

| Action | Removes | Keeps |
| --- | --- | --- |
| 恢复默认设置 (通用) | Only the keys in `Preferences.settingSchema` | `vpnTraffic.*`, `quotaAlertLevels`, subscriptions, secret |
| 重置流量统计 (流量 › 统计设置) | VPN totals and `node-traffic.json` | Settings, logs |
| Export / import | Preferences that differ from the default; optional subscription list | Never the controller secret; never `lockedInterface` or `blockRulesPath` (per-Mac) |

## Log format

Both log kinds are plain text, one file per local hour, mode 0600, never deleted by WardenHelper (clean them yourself).

```
<yyyy-MM-dd HH:mm:ss.SSS> <tag> key=value key=value ...
```

- **Traffic log**: file name gets the hour's counted traffic once the hour is over, `2026-06-01_12:00-13:00_1.235GB.log` (GB = 1000³). Tags are described in [VPN Traffic](VPN_TRAFFIC.md#traffic-log).
- **Block log**: `2026-06-01_12:00-13:00.log`. Tags are described in [Blocking](BLOCKING.md#block-log).

## Backup file

A single JSON document (`SettingsBackup`). Values are typed (`BackupValue`: bool / int / double / string) and checked one by one on import, so hand-edited or damaged files cannot inject wrong types. Subscription entries carry name, link (with token), interval, enabled and rule overrides.
