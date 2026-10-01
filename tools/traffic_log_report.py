#!/usr/bin/env python3
"""Summarise ~/Library/Logs/WardenHelper/traffic/ files (or any single hourly file) so the counted VPN traffic can be checked.

    python3 tools/traffic_log_report.py [logfile-or-folder] [--since "2026-09-30 21:00"] [--top 15]

Reads `poll` lines (growth per reading, `up/down` bytes) and `open` lines (one per new connection).
Prints, for the chosen period: bytes by route, the kernel's own totals, `missed` (bytes of
connections that closed between two readings), the tunnel interface growth, and the busiest hosts.
"""
import argparse, os, re, sys
from collections import defaultdict

PAIR = re.compile(r'(\w+)=([+-]?\d+)/([+-]?\d+)')
KV = re.compile(r'(\w+)=("[^"]*"|\S+)')

def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1000 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.2f} {unit}"
        n /= 1000

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?", default=os.path.expanduser("~/Library/Logs/WardenHelper/traffic"))
    ap.add_argument("--since", default="")
    ap.add_argument("--top", type=int, default=15)
    args = ap.parse_args()

    totals = defaultdict(lambda: [0, 0])
    polls = 0
    hosts = defaultdict(lambda: [0, 0, 0, "", ""])        # opens, first-seen up, first-seen down, route, chains
    states, first, last = [], None, None
    # A folder means every hourly file in it, oldest first (the names sort by time).
    if os.path.isdir(args.log):
        paths = sorted(os.path.join(args.log, n) for n in os.listdir(args.log) if n.endswith(".log"))
    else:
        paths = [args.log]
    for path in paths:
      with open(path, errors="replace") as f:
        for line in f:
            if len(line) < 24:
                continue
            stamp, rest = line[:23], line[24:].rstrip("\n")
            if args.since and stamp < args.since:
                continue
            tag, _, fields = rest.partition(" ")
            first = first or stamp
            last = stamp
            if tag == "poll":
                polls += 1
                for key, up, down in PAIR.findall(fields):
                    totals[key][0] += int(up)
                    totals[key][1] += int(down)
            elif tag == "open":
                kv = dict(KV.findall(fields))
                target = kv.get("target", '""').strip('"') or "(unknown)"
                host = target.rsplit(":", 1)[0]
                h = hosts[host]
                h[0] += 1
                h[1] += int(kv.get("up", 0))
                h[2] += int(kv.get("down", 0))
                h[3], h[4] = kv.get("route", ""), kv.get("chains", "").strip('"')
            elif tag in ("state", "tunnel", "baseline", "reset", "start"):
                states.append(f"{stamp}  {tag} {fields}")

    print(f"log: {args.log} ({len(paths)} file(s))\nperiod: {first} -> {last}   readings with traffic: {polls}\n")
    print(f"{'':<10}{'upload':>14}{'download':>14}")
    for key in ("proxy", "direct", "unknown", "kernel", "missed", "tun"):
        if key in totals:
            up, down = totals[key]
            print(f"{key:<10}{human(up):>14}{human(down):>14}")

    if "kernel" in totals:
        for i, name in ((0, "upload"), (1, "download")):
            k = totals["kernel"][i]
            seen = sum(totals[r][i] for r in ("proxy", "direct", "unknown"))
            if k > 0:
                print(f"\ncounted {name}: {seen / k * 100:.2f}% of the kernel's total "
                      f"({human(seen)} of {human(k)}; the rest closed between readings)")
    if "tun" in totals and "kernel" in totals:
        for i, name in ((0, "upload"), (1, "download")):
            t, k = totals["tun"][i], totals["kernel"][i]
            if t > 0 and k > 0:
                print(f"tunnel {name} vs kernel {name}: {t / k * 100:.1f}% (overhead + non-proxied packets)")
    if "unknown" in totals and sum(totals["unknown"]) > 0:
        print("\nWARNING: bytes on connections whose route could not be told were not counted.")

    if hosts:
        print(f"\nnew connections by host (bytes at first sight; long transfers grow after that):")
        ranked = sorted(hosts.items(), key=lambda kv: -(kv[1][1] + kv[1][2]))[: args.top]
        for host, (n, up, down, route, chains) in ranked:
            print(f"  {host:<40} opens={n:<5} route={route:<8} chains={chains}")
    if states:
        print("\nevents:")
        for s in states[-12:]:
            print("  " + s)

if __name__ == "__main__":
    sys.exit(main())
