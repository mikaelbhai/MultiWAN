#!/usr/bin/env python3
"""bandwidth_totals.py — runs on the relay host, invoked over SSH by the
router's bandwidth_offload.sh cron job. This is the durable, authoritative
store for all-time per-device bandwidth totals: the router itself only ever
holds a transient diffing snapshot on tmpfs (wiped on reboot), never a real
history, so this file is the one place a running total actually persists.

Usage:
    bandwidth_totals.py add     — read a JSON array of deltas from stdin:
                                   [{"mac": "...", "name": "...",
                                     "rx_bytes": N, "tx_bytes": N}, ...]
                                   and add them to the running totals.
    bandwidth_totals.py totals  — print the current totals as JSON to stdout.

Deliberately a single dependency-free script (no pip installs on a shared
host you may not control) using only the standard library, with a plain JSON
file as storage — this data is per-device counters for a home network, not
something that needs a real database.
"""
import fcntl
import json
import os
import sys
import time

STORE = os.path.expanduser("~/mwadmin-history/bandwidth_totals.json")
LOCK = STORE + ".lock"


def load():
    try:
        with open(STORE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save(data):
    os.makedirs(os.path.dirname(STORE), exist_ok=True)
    tmp = STORE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, STORE)  # atomic on POSIX — no reader ever sees a partial file


def with_lock(fn):
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    with open(LOCK, "w") as lockfile:
        fcntl.flock(lockfile, fcntl.LOCK_EX)
        try:
            return fn()
        finally:
            fcntl.flock(lockfile, fcntl.LOCK_UN)


def cmd_add():
    try:
        deltas = json.load(sys.stdin)
    except json.JSONDecodeError:
        print("invalid JSON on stdin", file=sys.stderr)
        sys.exit(1)

    def apply():
        totals = load()
        now = int(time.time())
        for d in deltas:
            mac = d.get("mac")
            if not mac:
                continue
            entry = totals.setdefault(mac, {"rx_bytes": 0, "tx_bytes": 0, "name": "", "last_seen": 0})
            entry["rx_bytes"] += max(0, int(d.get("rx_bytes", 0)))
            entry["tx_bytes"] += max(0, int(d.get("tx_bytes", 0)))
            if d.get("name"):
                entry["name"] = d["name"]
            entry["last_seen"] = now
        save(totals)

    with_lock(apply)


def cmd_totals():
    print(json.dumps(with_lock(load)))


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action == "add":
        cmd_add()
    elif action == "totals":
        cmd_totals()
    else:
        print("usage: bandwidth_totals.py {add|totals}", file=sys.stderr)
        sys.exit(2)
