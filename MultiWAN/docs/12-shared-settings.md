# 12: One settings system for two routers (2026-11-26)

**Router 1 (main) is the brain. Router 2 enforces what Router 1 decided and reports what it sees.**
Both talk only to the management website; the website knows which router is which (a *location* with one main
router and the routers that follow it). Nothing is configured on the routers by hand.

Set up on the website: open a router, **Group routers as one location**, pick the main router and the followers
(or `php cli.php group <email> <name> <main id> <following id>...`). The routers find out within a minute.

## What goes which way

| | Down: Router 1 to Router 2 (the "policy") | Up: Router 2 to Router 1 (the "report") |
|---|---|---|
| Blocked sites and apps | the list (Router 1's list is the list) | |
| Free-time groups, allowance, break times | all of it | |
| Never-blocked devices | the list | |
| Sign-in list | Router 1's list, plus anyone who signed in on Router 2 in the last 10 minutes | people who signed in on Router 2 |
| Access requests | the whole table **with Router 1's decisions** (approve / deny) | new requests made on Router 2 (arrive as pending) |
| Free-time use today | the larger number per person | the larger number per person |

**Never shared:** Wi-Fi name and password, addresses, DHCP, ports, line setup, admin password, keys, tokens.
Device names travel inside the sign-in list and the never-blocked list; DHCP reservations (which hold addresses) do not.

## Rules that keep the two in step

- Decisions are made on Router 1 (its panel or the website). A decision on Router 2's own panel for a shared item is
  replaced by Router 1's next policy (within about a minute); the panel says so on Remote Access.
- A request made on Router 2 reaches Router 1 as *pending*; when Router 1 approves it, the approval comes down and
  Router 2 opens the site for that device. A request Router 1 already decided keeps Router 1's decision.
- Sign-ins: someone who signs in on Router 2 is added on Router 1 (never one already there). Someone removed on
  Router 1 is removed from Router 2 at the next policy, and an old report entry does not bring them back (Router 1 only
  takes in entries newer than the last it merged).
- Free-time use: the larger number wins, so joining the other router's Wi-Fi does not give a second allowance.
- Applying the same policy twice changes nothing and restarts nothing. A bundle that is cut short, damaged (checksum),
  too large or in an unknown format is refused whole.
- If the website or Router 1 is down, Router 2 keeps enforcing the last policy it applied (it is on flash).

## How it works

`lib/policy.sh`, run once a minute by the events watcher (`policy.sh tick`). The router asks `policy.php`
who it is (main / branch / none) and:
- **main:** takes in the reports (merge), then sends its policy when it changed (and once an hour);
- **branch:** takes the policy when it is newer (apply), then sends its report when it changed (and once an hour);
- **none:** asks again only every 15 minutes.

Bundles are plain text with a checksum (`policy.sh build` and `policy.sh report` print them); the website stores one
policy per location and one report per following router. The router proves who it is with its portal token in a
header. Router panel: Remote Access, "Settings shared with your other router" (role, last sent / applied, Sync now).
API: `GET /policy`, `POST /policy/sync`; capability `shared_settings`.

## What was tested, and what was not

Tested: the merge and apply rules, 16 checks in a sandbox copy of the script on Router 2 (all paths moved, nothing real
touched): valid-only lists, sign-in keep/drop, decisions kept, larger use wins, re-applying changes nothing, damaged
bundles refused, a removed person not re-added. The website side: `policy.php` answers Router 2 with its real token
(role none before grouping, branch after).

**Not tested: the whole loop on the two real routers** (Router 1 sending, Router 2 applying and the blocking actually
working on Router 2's network, an approval coming down, a person signing in on Router 2). The routers must both run
this software first.

## Known limits

- Router 2's own panel does not yet refuse edits to shared items; they are replaced at the next policy.
- The 18+ filter and DHCP-reservation names are not shared (the first changes DNS servers, the second holds addresses).
- Router 1 sends the sign-in list, which holds phone numbers, through your own website. Nothing else leaves your two routers
  and your website.
- The device-count cap (20+5, 70+5+25) is still not built.
