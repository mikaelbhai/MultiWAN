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
| `sites-visited.tsv` | the sites each device opened that day: first and last time, how many times |
| `app-usage.tsv` | how much each device used each app that day (MB) |
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

## 2026-11-27: the minute jobs had stopped

Router 1's RAM disk filled up (the DNS query log reached 120 MB) and its uploads stopped. Cause: the once-a-minute jobs
(site tracking, sign-in upkeep, blocking and break times) are skipped while the previous run is alive, checked with
`kill -0 $(cat minute.pid)`; with the pid file missing (after a reboot, or with /tmp full) BusyBox's `kill -0` with no pid
succeeds, so they never ran again: on Router 1 since 25 Nov 21:53, on Router 2 since its reboot. Fixed in `site.sh` (a pid
counts only if `/proc/<pid>` exists); the DNS log is now capped at 8 MB by the sampler and at 16 MB by the events loop.
Sites visited and app use (already uploaded to the website) are also summarised per device and day into the backup.

## Everything that grows, and where it goes (2026-11-27)

| Data | On the router | Leaves the router to |
|---|---|---|
| Event log (`events.log`, flash) | 3 days | website (every minute), USB backup (every hour) |
| Line and access point history (`history/*.log`, flash) | 3 days (500 lines at most) | USB backup |
| Devices seen (RAM) | 3 days | website (every minute, connected now), USB backup (`devices.tsv`) |
| Sites visited, app use (RAM) | the DNS query log is emptied every minute (8 MB cap, 16 MB second cap); summaries 3 days | website (every minute), USB backup |
| Activity records waiting to upload (RAM) | up to 3 MB, kept only until the website takes them | website |
| App details for the panel (RAM) | 4000 rows, 6000 address names | (not kept anywhere: live view) |
| Free-time use (flash) | 3 days | shared with the other router, USB backup |
| Access requests (flash) | 400 rows | shared with the other router, USB backup |
| Sign-in list (flash) | **never trimmed** (nobody is forgotten) | shared with the other router, USB backup every day |
| Traffic totals (`nlbwmon`, RAM) | its own limit (10000 entries a month) | (not kept: live view) |
| System log (`logread`, RAM) | 128 KB ring | (not kept) |

Safety net (`archive.sh guard`, every 10 minutes): package lists and stray temporary files older than a day are removed;
when the RAM disk passes 60 % the known caches (package lists, failed-upload copies, DNS query log, old activity records,
app details) are emptied and an event says how full it was; flash above 80 % raises a warning once a day.
