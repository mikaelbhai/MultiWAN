# Sharing routers, and signing the installer in with the browser

## Sharing (website)

The owner of a router can give other website accounts access to **a whole place** (every router in it) or **one router**.

| Access | Can do |
|---|---|
| **Owner** | Everything, and is the only one who can share, rename, regroup (places) or remove the router. |
| **Can manage** | See and change the router's settings (lines, Wi-Fi, devices, blocking, break times...). |
| **Can view** | See everything, change nothing. Every change goes through `api.php` as a POST, and POSTs are refused for view access. |

How to share: the place header has **Share** (whole place); the **This router** card has **Share** (one router).
Enter their email and choose *Can view* or *Can manage*.

- **They already have an account:** they get access at once and see it the next time they open the website.
- **No account yet:** the website makes an **invite link** for the owner to send. It works **once**, for **7 days**, and
  only for that email: the person creates an account (or signs in) with that email, and the routers appear.

The same dialog lists who has access, lets the owner change *view* / *manage*, remove someone, or cancel an unused invite.
People a router is shared with see "Shared with you" and a **Leave** button instead of Rename / Remove.
When the owner removes a router from the website, everyone it was shared with loses it too.

Server side (`portal/lib.php`, `webapp/portal.php`):

- `user_routers.role`: `owner` | `manage` | `view` (existing links became `owner`).
- `invites`: token hash (the link itself is never stored), inviter, email, role, router ids, expiry, used by / at.
- Routes: `GET /shares`, `POST /share`, `POST /share-remove`, `POST /invite-accept`. Only owners can share
  (`share_targets()` / `router_owned()`); at most 20 invites per owner per day.
- `enroll.php` hands a router's token only to its owner, so an account a router is shared with cannot take it over.

## "Sign in with your browser" (Windows installer)

Instead of copying an API key, the installer can join the account through the browser:

1. The installer asks `link.php` for a code (`start`). It gets a short code (shown in big letters) and a secret that
   never leaves the PC. Codes last 10 minutes; starts are limited per address.
2. It opens `https://<website>/router/#link=CODE` in the default browser (Chrome or any other).
3. The person signs in there (if not already), checks the code matches the installer, and presses **Connect**
   (`/link-info`, `/link-approve`).
4. The installer polls `link.php` with its secret and receives a **new API key valid for 24 hours**, exactly once.
   It then joins the new router to the account with that key, as with a pasted key.

The page forgets the `#link=` / `#invite=` part of the address at once (so it does not stay in the history) and keeps it
through sign-in or account creation.

## Any OpenWrt router in the installer

Besides the tested models, the installer's **Something else** searches OpenWrt's own list of supported routers
(`.overview.json` of the recommended release, about 2,000 models). The choice is checked against the image's
`supported_devices` before flashing; the installer opens OpenWrt's page for the model, since some routers need a special
first step. The router's ports are read from the router itself (`hwdetect.sh`), so any model gets its own port names.
