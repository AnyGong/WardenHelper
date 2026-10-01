# Blocking While the VPN Is Off

While no tunnel is up, WardenHelper blocks the sites, processes and IPs listed in a rules file. Blocking needs root, so it is done by the helper `warden-helper-daemon`, installed once with an administrator prompt. WardenHelper itself never runs as root.

Settings: 设置 › VPN 与网络 › 断开屏蔽. The page holds the master switch (**VPN 断开时屏蔽**, default on), the rules-file path with status (编辑 / 在访达中显示), the helper's install status and the block log.

## Rules file

A JSON array of objects. Each object has one or more of the keys below; values are a string or an array of strings. Default path: `~/Library/Application Support/WardenHelper/block-rules.json` (the path field accepts `~`; there is no import dialog). The file is watched: when it changes it is re-read. **One invalid entry rejects the whole file and the last good rules stay in force.** Limits: 1 MB, 5000 entries.

```json
[
  {"domain": ["www.google.com"]},
  {"domain_suffix": "baidu.com"},
  {"domain_keyword": ["tracker"]},
  {"process_name": ["QQ"]},
  {"process_path": ["/Applications/QQ.app"]},
  {"ip_cidr": ["1.193.217.37"]}
]
```

| Key | Meaning |
| --- | --- |
| `domain` | Exact name |
| `domain_suffix` | The name and all subdomains (`*.` prefix accepted) |
| `domain_keyword` | Any name containing the text (`a-z 0-9 - _ .`, at least 3 characters). Blocked by DNS only, and addresses are learned from queried names, so nothing is blocked before a first lookup |
| `process_name` | Exact, case-sensitive process name |
| `process_path` | Absolute program, folder or app bundle path (real path, e.g. `/private/tmp/x`). System paths, the helper and WardenHelper are rejected |
| `ip_cidr` | Address or network (`ip` is an alias). A bare address is /32 (/128); host bits are masked |

Always rejected: `/0` ranges, loopback addresses (they would cut the helper's own sinkhole) and protected system processes. Parsing is in `BlockRules.swift` and validation in `BlockProtocol.swift`, which the helper runs again on everything it receives.

Parse errors show in the status line with a line number when known, for example `第 12 行：JSON 格式错误`.

## When it blocks (`BlockController`)

- **Tunnel gone → arm at once**, with retries at 0.1 s, 0.2 s, 0.4 s … ×8, then a 2 s poll.
- **Tunnel up → disarm at once.**
- When the VPN drops, the master switch is **forced back to on** (`Preferences.restoreBlockDefault`), so a switch left off earlier cannot silently leave you unprotected.
- With the master switch off, the helper is always disarmed.
- A system proxy without a tunnel does not count as a VPN: blocking stays armed.
- On launch and whenever the helper reconnects, WardenHelper resends the state and rules. The helper keeps its saved rules until the rules file has been read.
- A 2 s poll detects drift (the helper reporting another state or rule count than intended) and fetches the helper's events for the block log.

## What is blocked while armed

| Target | Mechanism |
| --- | --- |
| Domains | `DNSSinkhole` listens on 127.0.0.1:53 and ::1:53 and `DNSConfig` points every network service's DNS at it. Listed names get `0.0.0.0` / `::`; other record types for them (including HTTPS/SVCB) get an empty answer; everything else is forwarded to the original resolvers. The original DNS settings are saved first and restored on disarm |
| Domain addresses | `AddressResolver` also resolves each listed domain (via the pre-switch resolvers, the system resolver, and names the sinkhole saw) and blocks the addresses in pf, so existing connections, browser DNS caches and DoH cannot bypass the sinkhole. Repeated every 5 minutes; addresses stay cached for 7 days (`AddressCache`). Shared CDN addresses can block other sites too |
| IP ranges | `PFRules`: anchor `com.apple/250.WardenHelper` with `block return out quick`. `/etc/pf.conf` is untouched; pf is enabled by reference token and released on disarm |
| Processes | `ProcessKiller`: 1 s timer, SIGTERM then SIGKILL after 2 s. Never PID 1, the helper, WardenHelper or protected names / paths |

## The helper

- Installed to `/Library/PrivilegedHelperTools/warden-helper-daemon` with a `KeepAlive` LaunchDaemon (`/Library/LaunchDaemons/com.warden-helper.helper.plist`, label `com.warden-helper.helper`), verified against the bundled SHA-256.
- Install, update and uninstall each need one administrator prompt (AppleScript `with administrator privileges` through `osascript`).
- IPC: Unix socket `/var/run/warden-helper-daemon.sock`, mode 0600, with a peer-uid check; one JSON line per request (`apply`, `status`, `events`), 4 MiB max.
- `BlockIPC.helperVersion` is bumped on behaviour changes; an older installed helper shows **需要更新**.
- State in `/var/db/warden-helper/`: `state.json`, `dns-backup.json`, `pf-token`, `pf-rules.conf`, `resolved-cache.json`. It is re-applied after a crash or reboot.
- Log: `/var/log/warden-helper-daemon.log`.
- Every rule is validated again in the helper, and no shell is ever used (`Exec.run` takes an absolute path and an argument array).

### Failure handling

| Situation | Result |
| --- | --- |
| Helper crash or `kill -9` | launchd restarts it; it re-applies saved state (or restores DNS if disarmed) |
| WardenHelper not running | The helper keeps its last state |
| Uninstall | Runs `warden-helper-daemon --restore` (DNS, pf anchor, token, state), then removes the daemon, binary and socket |
| Stuck system state | `sudo /Library/PrivilegedHelperTools/warden-helper-daemon --restore` |

## Block log

Always on. `~/Library/Logs/WardenHelper/block/2026-06-01_12:00-13:00.log`, one file per hour.

- WardenHelper lines: `vpn-down`, `vpn-up`, `block-send`, `block-sent`, `block-send-failed`, `block-helper`, `block-rules`.
- Helper events (merged in, fetched every 2 s so lines can be up to 2 s out of order): `block-apply`, `block-arm`, `block-disarm`, `block-step`, `block-armed`, `block-dns`, `block-pf`, `block-kill`, …
- Timing fields: `since_drop_ms` (tunnel drop → helper reply) and `start_ms` / `at_ms` / `total_ms` (since the helper received the request).

## Testing (VPN off)

| Check | Expected |
| --- | --- |
| `dig +short <listed domain>` | `0.0.0.0` |
| `curl` to a listed network | Fails; `sudo pfctl -a com.apple/250.WardenHelper -sr` shows the rules |
| Copy `/bin/sleep` to a listed process name and run it | Killed within about 2 s |
| VPN on, `networksetup -getdnsservers Wi-Fi` | Shows the original DNS |

## Limits

- About 1 s passes between the tunnel dropping and blocking starting.
- DoH and apps with their own resolver bypass the sinkhole; direct-IP connections are covered only by `ip_cidr` (and by resolved addresses of listed domains).
- If a listed domain is your proxy server's hostname, the VPN cannot reconnect while blocking is on.
