# Security and Privacy

## Privilege model

| Component | Runs as | Can do |
| --- | --- | --- |
| `WardenHelper.app` | Current user | Everything except enforcement. Never root |
| `warden-helper-daemon` | root (LaunchDaemon) | Change DNS, load a pf anchor, kill processes |

Because the project is for local use without a paid Apple Developer account, the helper is self-installed through an administrator prompt (`osascript`), not through `SMAppService` or a NetworkExtension.

### Helper hardening

- The socket `/var/run/warden-helper-daemon.sock` is mode 0600 and owned by the WardenHelper user. Each connection is also checked with the kernel's peer credentials, so a process of another user is dropped even if the permissions are changed.
- The helper accepts one JSON line per request, 4 MiB at most, and re-validates every rule (`BlockRuleValidator`).
- No shell is used. Programs are started with an absolute path and an argument array. Network-service names come from `networksetup`; DNS server addresses pass an `inet_pton` round trip.
- Dangerous rules are refused: `/0` ranges, loopback, protected processes and paths (system folders, the helper, WardenHelper).
- The installed binary is verified against the bundled SHA-256.
- Backup before change: the original DNS settings are written to disk before they are modified; `--restore` undoes everything the helper changed.

### What an attacker with the user account could do

Anyone who can run as the WardenHelper user can talk to the helper, so can change which rules are active. They cannot run arbitrary commands through it. Keep the rules file in a location writable only by you.

## Network requests

| Purpose | Destination | Notes |
| --- | --- | --- |
| Public IP and country | ip-api.com (HTTP, ATS exception in `Info.plist`), ipapi.co, api.country.is, ipinfo.io, ipwho.is | Tried in order; every 15 s and on network change. These services see your exit IP |
| AI exit checks | chatgpt.com, claude.ai, grok.com (`/cdn-cgi/trace`), dns.google (TXT lookup), ip-api.com for the owner of the address | Each service sees a lightweight request from your exit IP |
| Subscriptions | The `https://` links you add | Links contain access tokens |
| VPN traffic | Local controller (default `127.0.0.1:9090`) | Loopback only; secret sent in the request |

Nothing is uploaded to the project author; there is no telemetry or update check. Turn on **隐藏 IP 地址** before screen sharing; it masks the address in the bar, the dropdown and the tooltip (copy still copies the real address).

## Secrets

- **Controller secret**: Keychain, never exported, never reset. The first-launch default is a constant in `ControllerSecretStore.defaultSecret`. **Change this default before publishing or distributing builds, and do not publish the source unchanged.**
- **Subscription links**: stored in `subscription-links.json` (user-readable). Exported backups include them. The update-log export keeps only link hosts.
- **Logs** are mode 0600 and never contain subscription tokens.

## Signing and distribution

Builds are ad-hoc signed, not notarized. A downloaded release zip may need quarantine cleared (`xattr -cr WardenHelper.app`) or approval in System Settings › Privacy & Security on first launch. The release target clears extended attributes before zipping.

## Reporting

Report vulnerabilities privately to the maintainer rather than in a public issue.
