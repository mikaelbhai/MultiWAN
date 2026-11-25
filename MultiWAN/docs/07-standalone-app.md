# 07 — The Standalone App at mikaelbhai.com/MultiWAN

This is a genuinely separate app from the router's own admin UI — a different origin, hosted on
your web hosting account, that talks to the router purely through its public JSON API (the same
one documented for your own future integrations). It is not a redirect and not a proxy: the page
itself, its CSS, and its JS all load from `mikaelbhai.com`; only the actual data calls (status,
WAN health, settings) go to the router.

## Why this needed a real change, not just a new page

Two constraints made "just point another page at the API" not work:

1. **Cookies don't cross origins here.** The router's session cookie is `SameSite=Strict` and
   cannot be upgraded to `SameSite=None` (that requires `Secure`, which requires HTTPS, which
   this plain-HTTP admin port doesn't have). A page on `mikaelbhai.com` was never going to be able
   to use it — confirmed live, not just theoretical.
2. **Mixed content.** `mikaelbhai.com` serves HTTPS; the router's API is plain HTTP. Browsers hard
   -block an HTTPS page from calling an HTTP endpoint (not a warning — it simply doesn't happen).

## What changed to fix it

- **`package/cgi-bin/mwadmin`**: the CGI now accepts the session token explicitly — as `_csrf` in
  a POST body (the existing CSRF field already carried this value; it just wasn't previously
  treated as the identity itself) or `session` in a GET's query string — whenever no cookie is
  present. When a cookie *is* present (the normal on-router case), nothing changes. It also
  answers CORS preflight (`OPTIONS`) requests and sends `Access-Control-Allow-Origin: *`, safe
  specifically because auth no longer depends on an ambient cookie for cross-origin callers — a
  browser reading the response doesn't grant it any credential it didn't already have from a real
  `/login`.
- **`package/www/app.js`**: `API` now reads `window.MW_API_BASE` if set, GET requests attach the
  session token as a query parameter (harmless no-op when a cookie already covers it), and a
  standalone deployment persists the token in that origin's own `localStorage` instead of a
  cookie, so reloading the page doesn't force a fresh login every time.
- **This page** (`package/remote-app/index.html`, deployed to `mikaelbhai.com/MultiWAN/index.html`
  — kept out of `package/www/` deliberately, so the router's own deploy scripts never ship it to
  the router itself, where it would be dead weight):
  sets `window.MW_API_BASE` to the router's current external address before loading the same
  `app.js`/`app.css` the router itself serves — full feature parity, one shared codebase.
- **Deliberately served over plain `http://mikaelbhai.com/MultiWAN/`, not `https://`** — the
  mixed-content rule above cuts both ways: this page has to match the router's scheme to be
  allowed to call it at all.

## If the router's external address changes

`window.MW_API_BASE` in `package/remote-app/index.html` is the one line to update (WAN1's public IP
changing, or moving to a different WAN, or switching to a DDNS hostname), then re-upload just that
file:

```
scp package/remote-app/index.html <ssh-user>@mikaelbhai.com:~/public_html/MultiWAN/index.html
```

## Security notes

- The router's root password is what protects this — same as the LAN UI, same as direct WAN
  access. This page adds no second credential and stores no password, only the session token
  `/login` returns, in your browser's own local storage for that origin.
- Traffic between this page and the router is plain HTTP end to end (page load and API calls
  alike) — the same posture as accessing `http://103.246.108.118:8443` directly. Anyone on the
  network path between you and the router can see it.
- `Access-Control-Allow-Origin: *` on the router's API is intentional, not an oversight — it makes
  the API usable from any future software you write, not just this one page, which was the whole
  point of exposing it. It does not weaken authentication in any way; it only affects which
  browser pages are allowed to *read* an already-authenticated response.
