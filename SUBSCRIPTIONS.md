# Subscriptions

WardenHelper tracks the remaining traffic, next reset and expiry of proxy subscriptions (设置 › 订阅 › 订阅管理). It supports any number of `https://` links.

## Per-link settings

| Field | Notes |
| --- | --- |
| 名称 | Display name |
| 链接 | `https://` URL. Editing a link clears its values and refreshes at once |
| 刷新间隔 | 1–9999 minutes / hours / days; default 12 h |
| 启用 | Disabled links are neither refreshed nor shown |
| 立即更新 | Refresh now |

The page also shows the last update time, remaining traffic, expiry, next reset and an update log.

## Where the values come from

Providers put informational pseudo-nodes in the proxy list. WardenHelper finds them by name and reads the numbers (`SubscriptionPlanExtractor`). Full labels, with `:` or `：` and optional spaces:

| Label | Meaning |
| --- | --- |
| `剩余流量：43.29GB` | Remaining traffic |
| `距离下次重置剩余：5天` | Days to next reset |
| `套餐到期：2026-12-31` | Expiry date |

No matching node gives `—`.

- **Remaining traffic** is `实时` (live) when the response carries a `subscription-userinfo` header. Otherwise the node-name value is a `快照，可能过期` (snapshot, may be stale) with its time.
- **Next reset** = snapshot time + days from `距离下次重置剩余`. Days are calendar days in UTC+8.
- **Last updated** moves only on a live download. On fallback to the cache, the cached values stay and a red note appears.

## Schedule

- Due links run at launch.
- Links are checked every 30 s, paused for 8 s after wake.
- Failures retry after 5 minutes.
- Downloads retry internally; `SubscriptionManager` keys each link's cache by its UUID and uses `cacheTTLMinutes = 0` (always try live first, stale cache only as fallback).

## In the menu bar

Choose which subscription the bar shows (设置 › 显示 › 菜单栏 › 订阅用量 › 显示的订阅): first enabled with data (default), least traffic, soonest expiry, or a specific link. Thresholds 流量预警 (GB) and 到期预警 (days); `0` turns a warning off. The dropdown uses the same colours. Warning notifications are set in 设置 › 应用 › 通知提醒 › 用量预警.

## Update log

The log (订阅 tab) shows the last refresh. **复制** and **导出…** keep only the host of each link and replace the home folder with `~`, so the log is safe to share.

## Matching rules (设置 › 订阅 › 解析规则)

Four regular expressions read the info nodes (defaults in `SubscriptionRuleSet.defaults`):

| Rule | Reads | Needs |
| --- | --- | --- |
| 信息节点 | Which nodes carry plan info | any pattern |
| 剩余流量 | Remaining traffic | group 1 = number, group 2 = unit (K / M / G / T) |
| 重置天数 | Days to next reset | group 1 = days |
| 到期日期 | Expiry date | group 1 = `yyyy-MM-dd` |

- **适用范围**: 全局默认 or one subscription. Inside a subscription, an empty box follows the global rule and a filled box overrides it (`ruleOverrides` in `subscription-links.json`, read through `SubscriptionItem.effectiveRules`).
- **验证并保存**: tests each pattern against cached content (valid, enough groups, usable value). Passing patterns are saved and applied immediately; failing ones show why and revert. 恢复默认设置 restores the defaults. Global rules are stored as `subscriptionRule.<name>` in UserDefaults, only when they differ from the default.
- **粘贴测试**: paste node names, one per line, to see what each rule captures. It uses the unsaved box contents (`SubscriptionRuleSampleTester`).

## Supported formats

`SubscriptionKit` (Foundation-only, no dependencies) downloads and parses Clash YAML (with its own small YAML parser) and base64 subscriptions.
