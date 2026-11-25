# 10: Accounts, API keys, and router/website compatibility (2026-11-26)

There is no administrator. Every person who registers owns their own routers.

## Register and sign in

`portal.php/register {email, password}` (the home page's "Create an account"): password of 10+ characters,
bcrypt, 5 new accounts per address per hour and 300 per day for the whole site, a hidden form field only bots
fill. It signs the new account in. Emails are **not verified** and there is **no password reset** yet (the site
has no way to send mail); the host owner can set one with `php portal/cli.php passwd <email> -`.

## API key: connect any number of routers

On the website: **Add a router** makes a key (`bu...`, shown in full once, only its SHA-256 is stored). The
same key works on every router that person owns:

1. router panel, **Remote Access > Connect to your website account**: enter the website address and the key; or
   `sh /usr/lib/mwadmin/connect.sh join <website> <key>` over SSH;
2. the router sends the key and a stable `device_id` (md5 of its LAN MAC, not the MAC itself) to `enroll.php`;
3. the website makes a router in that person's account (named after the router's hostname) and answers with the
   router's own token, upload address and `web_level`. The same router joining again gets the same router and
   token back (matched by `device_id` within that account), so a reset never makes a duplicate.

Limits: 10 active keys and 25 routers per account. A revoked key cannot connect new routers; routers already
connected keep working. Wrong keys are rate-limited (8 per address per 15 minutes). The answer carries the
router's secret, so `enroll.php` only answers over HTTPS. A router can also be renamed or removed from the
account (removing the last owner deletes the router's record and history here; the router keeps working).

Tables: `api_keys`, `register_log`; `routers` gained `device_id`, `api_key_id`, `caps_json`, `caps_at`.
One-time keys from `cli.php new-key` still work.

## Compatibility: each side says what it can do

Router: `GET /capabilities` (lib/caps.sh) returns `api_level`, `software`, and one line per feature:
`id`, `level`, `available`, `reason` (why this hardware cannot do it). Website: `portal/caps_lib.php`
(`web_features()`) lists the features the website speaks and the highest level of each.

For a feature a call belongs to (longest route prefix), the relay (`api.php`) answers, without bothering the router:

| Situation | Message |
|---|---|
| router lacks the feature, or is older | "...does not have X. Please update the router (Settings > Software update)." |
| router's level is newer than the website's | "...newer version of X than this website understands. Please update the website." |
| the router cannot do it (no radio, no mwan3, ...) | "This router can't do X: <reason>." |
| router too old to answer `/capabilities` | not blocked up front; a bare "No such endpoint" reply is turned into the "update the router" message |

The dashboard's **This router** block shows the result per router (and a "Check again" button). The relay decides
from the router's last answer (cached 15 min, refreshed by the dashboard); it never waits on a router to decide.
Adding a feature: add one line to `caps_list()` in caps.sh **and** one to `web_features()`; raise a feature's
`level` (router) and the website's maximum together when its requests or answers change shape; raise
`CAPS_API_LEVEL` / `WEB_API_LEVEL` for breaking changes.

## Not built

Syncing settings between routers (the two-router plan, docs/08) is still a plan: this work only makes routers
join an account and lets each side say what it supports.
