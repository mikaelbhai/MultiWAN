# 13: Daily backup to the USB drive (2026-11-26)

Every router's devices, lists and logs are backed up **every hour, one folder per day**, onto **Router 1's USB drive**,
in the folder `Baytaar backup` (a `READ ME.txt` there explains the files). Routers keep only **3 days** themselves.
Nothing is forgotten: the sign-in list is never trimmed, it is copied every day.

```
Baytaar backup/
  READ ME.txt
  Router 1/2026-11-26/  events.log  line-history.log  devices.tsv  sign-ins.tsv  access-requests.tsv  free-time.tsv  rules.txt
  Router 2/2026-11-26/  (the same)
```

| File | What |
|---|---|
| `events.log` | what happened that day (lines, cables, alerts, sign-ins), readable times |
| `line-history.log` | internet lines and access points going up and down |
| `devices.tsv` | every device seen that day: first and last time, address, host name, name, Wi-Fi or cable |
| `sign-ins.tsv` | the whole sign-in list as it was that day |
| `access-requests.tsv` | requests to open a blocked site, and the decisions |
| `free-time.tsv` | free time used that day |
| `rules.txt` | the shared rules (blocked sites, free time, never-blocked devices, speed limits) |

The `.tsv` files open in Excel.

## How the days get there

- **Router 1 (has the drive):** writes its own days straight to the drive.
- **Router 2 (no drive):** sends its days to the website (`policy.php`, `kind=archive`); Router 1 takes them from there
  every hour, writes them to the drive under `Router 2/`, and then the website deletes every finished day (today stays
  there until tomorrow, refreshed every hour).
- **Drive unplugged or full on Router 1:** Router 1 sends its own days to the website too; when the drive is back it
  writes everything waiting there. The website never keeps a day longer than 60 days.
- A day leaves a router only after it is safely on the drive or on the website.

What stays on the router: today and the 2 days before of the event log, line history and free-time use; today's devices
seen are in RAM (a reboot loses at most the hour since the last backup). The sign-in list, the blocked sites and the
other settings are never trimmed.

Code: `lib/archive.sh` (`seen` every minute, `tick` every hour from the events watcher; `status`), `events.sh` (devices
list as TSV, 3-day event log), website `policy.php` (`kind=archive`, `archives=1`, `archive=<router>&day=`,
`kind=archive_ack`), table `archives`. Router panel: Remote Access, under the shared-settings card ("Back up now").

## Tested (2026-11-26)

On both real routers: Router 2 sent 24, 25 and 26 Nov to the website; Router 1 wrote its own and Router 2's days to the
drive (21 files each), the website then held only Router 2's current day. Both routers' snapshots were unchanged after
the upgrade. Not tested yet: the drive unplugged (website fallback for Router 1), and the 3-day trim on a day that is
actually 3 days old (it runs every hour; the first real trim happens on 29 Nov).
