<?php
// Baytaar portal API: sign in / out, and the list of routers assigned to the
// signed-in account with each one's live state.
//
//   POST portal.php/login   {email, password}
//   POST portal.php/logout
//   GET  portal.php/me
//   GET  portal.php/routers
//   GET  portal.php/activity?r=ID[&mac=..][&q=..][&days=N]   who uses what, and site history
//   GET  portal.php/events?r=ID[&limit=N]                    the router's event log
//   GET  portal.php/sites?r=ID[&mac=..]                       every site ever used, whole network or one device
require __DIR__ . '/../portal/lib.php';
require __DIR__ . '/../portal/activity_lib.php';
require __DIR__ . '/../portal/caps_lib.php';

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$route  = $_SERVER['PATH_INFO'] ?? '';
if ($route === '') {
    $uri = strtok($_SERVER['REQUEST_URI'] ?? '', '?');
    $pos = strpos($uri, 'portal.php');
    $route = $pos === false ? '' : substr($uri, $pos + 10);
}
if ($method === 'POST') require_same_origin();

switch ("$method $route") {
    case 'POST /login':
        $b = read_json_body(4096);
        $u = login((string) ($b['email'] ?? ''), (string) ($b['password'] ?? ''));
        json_out(200, ['ok' => true, 'user' => $u]);

    case 'POST /logout':
        logout();
        json_out(200, ['ok' => true]);

    case 'GET /me':
        $u = require_user();
        json_out(200, ['ok' => true, 'user' => $u]);

    case 'POST /register':
        // Self-service sign-up. A hidden field only bots fill in is a cheap first filter.
        $b = read_json_body(4096);
        if (trim((string) ($b['website'] ?? '')) !== '') fail(400, 'Could not create the account.');
        $u = register_user((string) ($b['email'] ?? ''), (string) ($b['password'] ?? ''));
        json_out(200, ['ok' => true, 'user' => $u]);

    case 'GET /api-keys':
        $u = require_user();
        $st = db()->prepare('SELECT k.id, k.label, k.prefix, k.created, k.last_used, k.uses,
                                    (SELECT COUNT(*) FROM routers r WHERE r.api_key_id = k.id) AS routers
                             FROM api_keys k WHERE k.user_id = ? AND k.revoked = 0 AND (k.expires IS NULL OR k.expires > ?) ORDER BY k.id DESC');
        $st->execute([$u['id'], time()]);
        $site = strtolower(explode(':', $_SERVER['HTTP_HOST'] ?? '')[0]);
        json_out(200, ['ok' => true, 'keys' => $st->fetchAll(), 'site' => $site]);

    case 'POST /api-keys':
        // A reusable key: enter the website's address and this key on any number of routers.
        $u = require_user();
        $b = read_json_body(4096);
        $label = trim(mb_substr(preg_replace('/[\x00-\x1f\x7f]/u', '', (string) ($b['label'] ?? '')), 0, 40));
        if ($label === '') $label = 'My routers';
        [$kid, $key] = api_key_create($u, $label);
        $site = strtolower(explode(':', $_SERVER['HTTP_HOST'] ?? '')[0]);
        json_out(200, ['ok' => true, 'id' => $kid, 'key' => $key, 'label' => $label, 'site' => $site,
                       'command' => "sh /usr/lib/mwadmin/connect.sh join $site $key"]);

    case 'POST /api-keys/revoke':
        // Routers already connected keep working; the key just cannot connect new ones.
        $u = require_user();
        $b = read_json_body(4096);
        $st = db()->prepare('UPDATE api_keys SET revoked = 1 WHERE id = ? AND user_id = ?');
        $st->execute([(int) ($b['id'] ?? 0), $u['id']]);
        if (!$st->rowCount()) fail(404, 'No such key.');
        json_out(200, ['ok' => true]);

    // ---- sharing: the owner gives other accounts "view" or "manage" access to a whole place or one router ----
    case 'GET /shares':
        $u = require_user();
        [$label, $ids] = share_targets($u, $_GET);
        $pdo = db();
        $in = implode(',', array_fill(0, count($ids), '?'));
        $st = $pdo->prepare("SELECT u.id, u.email, ur.role, COUNT(*) AS n FROM user_routers ur JOIN users u ON u.id = ur.user_id
                             WHERE ur.router_id IN ($in) AND ur.role != 'owner' GROUP BY u.id, u.email, ur.role ORDER BY u.email");
        $st->execute($ids);
        $people = array_map(function ($x) use ($ids) { return ['user_id' => (int) $x['id'], 'email' => $x['email'], 'role' => $x['role'],
                                                               'partial' => (int) $x['n'] < count($ids)]; }, $st->fetchAll());
        $iv = $pdo->prepare('SELECT id, email, role, router_ids, expires FROM invites WHERE inviter = ? AND used_by IS NULL AND expires > ? ORDER BY id DESC');
        $iv->execute([$u['id'], time()]);
        $invites = [];
        foreach ($iv->fetchAll() as $x) {
            $rids = json_decode($x['router_ids'], true) ?: [];
            if (array_intersect($rids, $ids)) $invites[] = ['id' => (int) $x['id'], 'email' => $x['email'], 'role' => $x['role'], 'expires' => (int) $x['expires']];
        }
        json_out(200, ['ok' => true, 'label' => $label, 'people' => $people, 'invites' => $invites]);

    case 'POST /share':
        // {location_id | router_id, email, role: view | manage}. An existing account gets access at once (or a new role);
        // someone without an account gets an invite link (once, 7 days, only for that email) to send them.
        $u = require_user();
        $b = read_json_body(4096);
        [$label, $ids] = share_targets($u, $b);
        $role = (string) ($b['role'] ?? '');
        if (!in_array($role, ['view', 'manage'], true)) fail(400, 'Choose: can view, or can manage.');
        $email = strtolower(trim((string) ($b['email'] ?? '')));
        if (!filter_var($email, FILTER_VALIDATE_EMAIL) || strlen($email) > 120) fail(400, 'Enter their email address.');
        if ($email === strtolower((string) $u['email'])) fail(400, 'That is your own account.');
        $pdo = db();
        $q = $pdo->prepare('SELECT id FROM users WHERE lower(email) = ?'); $q->execute([$email]);
        $them = one($q);
        if ($them) {
            db_retry(function () use ($pdo, $ids, $them, $role) {
                foreach ($ids as $rid) {
                    $pdo->prepare("INSERT INTO user_routers (user_id, router_id, role) VALUES (?, ?, ?)
                                   ON CONFLICT(user_id, router_id) DO UPDATE SET role = excluded.role WHERE user_routers.role != 'owner'")
                        ->execute([(int) $them['id'], $rid, $role]);
                }
            });
            json_out(200, ['ok' => true, 'shared' => true, 'message' => $email . ' can now ' . ($role === 'view' ? 'view ' : 'manage ') . $label . '. They see it the next time they open the website.']);
        }
        $c = $pdo->prepare('SELECT COUNT(*) FROM invites WHERE inviter = ? AND created > ?'); $c->execute([$u['id'], time() - 86400]);
        $n = (int) $c->fetchColumn(); $c->closeCursor();
        if ($n >= 20) fail(429, 'You made 20 invites today. Try again tomorrow.');
        $token = 'bi' . bin2hex(random_bytes(20));
        db_retry(function () use ($pdo, $token, $u, $email, $role, $ids, $label) {
            $pdo->prepare('INSERT INTO invites (token_hash, inviter, email, role, router_ids, label, created, expires) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
                ->execute([hash('sha256', $token), $u['id'], $email, $role, json_encode(array_values($ids)), $label, time(), time() + 7 * 86400]);
        });
        $host = strtolower(explode(':', $_SERVER['HTTP_HOST'] ?? '')[0]);
        $dir = rtrim(str_replace('\\', '/', dirname($_SERVER['SCRIPT_NAME'] ?? '/')), '/');
        json_out(200, ['ok' => true, 'invite' => true, 'link' => 'https://' . $host . $dir . '/#invite=' . $token,
                       'message' => $email . ' has no account yet. Send them this link: they create an account with that email and get access. It works once, for 7 days.']);

    case 'POST /share-remove':
        // {location_id | router_id, user_id | invite_id}: their access to these routers ends (never the owner's)
        $u = require_user();
        $b = read_json_body(4096);
        [$label, $ids] = share_targets($u, $b);
        $pdo = db();
        if (!empty($b['invite_id'])) {
            $pdo->prepare('DELETE FROM invites WHERE id = ? AND inviter = ?')->execute([(int) $b['invite_id'], $u['id']]);
            json_out(200, ['ok' => true, 'message' => 'Invite cancelled.']);
        }
        $uid = (int) ($b['user_id'] ?? 0);
        db_retry(function () use ($pdo, $ids, $uid) {
            foreach ($ids as $rid) $pdo->prepare("DELETE FROM user_routers WHERE user_id = ? AND router_id = ? AND role != 'owner'")->execute([$uid, $rid]);
        });
        json_out(200, ['ok' => true, 'message' => 'Access removed.']);

    case 'POST /invite-accept':
        // the invited person, signed in with the email the invite was made for
        $u = require_user();
        $b = read_json_body(1024);
        $token = (string) ($b['token'] ?? '');
        if (!preg_match('/^bi[a-f0-9]{40}$/', $token)) fail(400, 'That invite link is not complete.');
        $pdo = db();
        $q = $pdo->prepare('SELECT * FROM invites WHERE token_hash = ?'); $q->execute([hash('sha256', $token)]);
        $iv = one($q);
        if (!$iv || $iv['used_by'] || (int) $iv['expires'] < time()) fail(404, 'This invite has expired or was already used. Ask for a new one.');
        if (strtolower((string) $u['email']) !== strtolower((string) $iv['email'])) fail(403, 'This invite is for ' . $iv['email'] . '. Sign in (or create an account) with that email.');
        $ids = array_map('intval', json_decode($iv['router_ids'], true) ?: []);
        db_retry(function () use ($pdo, $ids, $u, $iv) {
            foreach ($ids as $rid) {
                $ok = $pdo->prepare('SELECT 1 FROM routers WHERE id = ?'); $ok->execute([$rid]);
                if (!one($ok)) continue;
                $pdo->prepare("INSERT INTO user_routers (user_id, router_id, role) VALUES (?, ?, ?)
                               ON CONFLICT(user_id, router_id) DO UPDATE SET role = excluded.role WHERE user_routers.role != 'owner'")
                    ->execute([$u['id'], $rid, $iv['role']]);
            }
            $pdo->prepare('UPDATE invites SET used_by = ?, used_at = ? WHERE id = ?')->execute([$u['id'], time(), $iv['id']]);
        });
        json_out(200, ['ok' => true, 'message' => 'You can now ' . ($iv['role'] === 'view' ? 'view ' : 'manage ') . ($iv['label'] ?: 'the shared routers') . '.']);

    case 'GET /link-info':
        // The code the Windows installer shows: is it real, and still waiting? (Before the person presses Connect.)
        $u = require_user();
        $code = strtoupper(preg_replace('/[^A-Za-z0-9]/', '', (string) ($_GET['code'] ?? '')));
        $st = db()->prepare('SELECT created, expires, approved FROM link_requests WHERE code = ?'); $st->execute([$code]);
        $r = one($st);
        if (!$r || $r['approved'] || (int) $r['expires'] < time()) fail(404, 'That code has expired or was already used. Start again in the installer.');
        json_out(200, ['ok' => true, 'code' => substr($code, 0, 4) . '-' . substr($code, 4), 'minutes_left' => max(1, (int) ceil(((int) $r['expires'] - time()) / 60))]);

    case 'POST /link-approve':
        // The signed-in person connects the installer to their account: a new API key, valid 24 hours, handed to the
        // installer once on its next poll (link.php).
        $u = require_user();
        $b = read_json_body(1024);
        $code = strtoupper(preg_replace('/[^A-Za-z0-9]/', '', (string) ($b['code'] ?? '')));
        $pdo = db();
        $st = $pdo->prepare('SELECT * FROM link_requests WHERE code = ?'); $st->execute([$code]);
        $r = one($st);
        if (!$r || $r['approved'] || (int) $r['expires'] < time()) fail(404, 'That code has expired or was already used. Start again in the installer.');
        [$kid, $key] = api_key_create($u, 'Windows installer ' . date('j M H:i'), time() + 86400);
        db_retry(function () use ($pdo, $code, $u, $key) {
            $pdo->prepare('UPDATE link_requests SET approved = ?, user_id = ?, key_plain = ? WHERE code = ? AND approved IS NULL')
                ->execute([time(), $u['id'], $key, $code]);
        });
        json_out(200, ['ok' => true, 'message' => 'Connected. You can go back to the installer.']);

    case 'POST /router-rename':
        $u = require_user();
        $b = read_json_body(4096);
        $rid = (int) ($b['id'] ?? 0);
        router_owned($u, $rid);
        $nm = trim(mb_substr(preg_replace('/[\x00-\x1f\x7f]/u', '', (string) ($b['name'] ?? '')), 0, 60));
        if ($nm === '') fail(400, 'Give the router a name.');
        db()->prepare('UPDATE routers SET name = ? WHERE id = ?')->execute([$nm, $rid]);
        json_out(200, ['ok' => true]);

    case 'POST /location-save':
        // Put routers together as one location: one main router (the brain) and the routers that follow it.
        // {name, main: router id, branch: [router ids]}. Routers left out of the lists leave the location.
        $u = require_user();
        $b = read_json_body(4096);
        $nm = trim(mb_substr(preg_replace('/[\x00-\x1f\x7f]/u', '', (string) ($b['name'] ?? '')), 0, 60));
        if ($nm === '') fail(400, 'Give the location a name.');
        $main = (int) ($b['main'] ?? 0);
        $branch = array_values(array_unique(array_map('intval', (array) ($b['branch'] ?? []))));
        if (!$main) fail(403, 'Choose the main router.');
        router_owned($u, $main);
        if (count($branch) > 8) fail(400, 'At most 8 following routers.');
        foreach ($branch as $bid) { if ($bid === $main) fail(400, 'A router cannot follow itself.'); router_owned($u, $bid); }
        $pdo = db();
        db_retry(function () use ($pdo, $u, $nm, $main, $branch) {
            $cur = $pdo->prepare('SELECT location_id FROM routers WHERE id = ?'); $cur->execute([$main]);
            $lid = (int) (one($cur)['location_id'] ?? 0);
            if ($lid) {
                $own = $pdo->prepare('SELECT 1 FROM locations WHERE id = ? AND user_id = ?'); $own->execute([$lid, $u['id']]);
                if (!one($own)) $lid = 0;
            }
            if ($lid) $pdo->prepare('UPDATE locations SET name = ? WHERE id = ?')->execute([$nm, $lid]);
            else { $pdo->prepare('INSERT INTO locations (user_id, name) VALUES (?, ?)')->execute([$u['id'], $nm]); $lid = (int) $pdo->lastInsertId(); }
            // everything that was in this location and is not in the new lists leaves it
            $pdo->prepare('UPDATE routers SET location_id = NULL, role = NULL WHERE location_id = ?')->execute([$lid]);
            $pdo->prepare("UPDATE routers SET location_id = ?, role = 'main' WHERE id = ?")->execute([$lid, $main]);
            foreach ($branch as $bid) $pdo->prepare("UPDATE routers SET location_id = ?, role = 'branch' WHERE id = ?")->execute([$lid, $bid]);
        });
        json_out(200, ['ok' => true]);

    case 'POST /location-leave':
        $u = require_user();
        $b = read_json_body(4096);
        $rid = (int) ($b['id'] ?? 0);
        router_owned($u, $rid);
        db()->prepare('UPDATE routers SET location_id = NULL, role = NULL WHERE id = ?')->execute([$rid]);
        json_out(200, ['ok' => true]);

    case 'POST /router-remove':
        // Takes the router off this account. If nobody else has it, its record and history go too;
        // the router itself keeps working, it just stops reporting here (and stops being reachable from here).
        $u = require_user();
        $b = read_json_body(4096);
        $rid = (int) ($b['id'] ?? 0);
        $mine = router_for($u, $rid);
        if (!$mine) fail(403, 'This router is not assigned to your account.');
        $pdo = db();
        if (($mine['access'] ?? 'owner') !== 'owner') {
            // someone it was shared with only leaves; the router stays with its owner
            $pdo->prepare('DELETE FROM user_routers WHERE user_id = ? AND router_id = ?')->execute([$u['id'], $rid]);
            json_out(200, ['ok' => true, 'left' => true]);
        }
        // the owner removes it for everyone it was shared with too
        $pdo->prepare('DELETE FROM user_routers WHERE router_id = ?')->execute([$rid]);
        $st = $pdo->prepare('SELECT COUNT(*) FROM user_routers WHERE router_id = ?'); $st->execute([$rid]);
        if (!(int) $st->fetchColumn()) {
            foreach (['app_use', 'visits', 'site_totals', 'events', 'alerts', 'line_watch', 'router_watch', 'relay', 'relay_seen', 'enroll_keys', 'reports'] as $t) {
                try { $pdo->prepare("DELETE FROM $t WHERE router_id = ?")->execute([$rid]); } catch (Throwable $e) { /* table not created yet */ }
            }
            $pdo->prepare('DELETE FROM routers WHERE id = ?')->execute([$rid]);
        }
        json_out(200, ['ok' => true]);

    case 'GET /capabilities':
        // What this router can do and what this website can use of it, with the side to update named.
        $u = require_user();
        $rid = (int) ($_GET['r'] ?? 0);
        $r = router_for($u, $rid);
        if (!$r) fail(403, 'This router is not assigned to your account.');
        json_out(200, caps_report($r, !empty($_GET['refresh'])));

    case 'GET /routers':
        $u = require_user();
        $out = [];
        $locNames = [];
        // the names of the places of every router this account can see (a shared place keeps its owner's name)
        $lq = db()->prepare('SELECT DISTINCT l.id, l.name FROM locations l JOIN routers r ON r.location_id = l.id
                             JOIN user_routers ur ON ur.router_id = r.id WHERE ur.user_id = ?'); $lq->execute([$u['id']]);
        foreach ($lq->fetchAll() as $lr) $locNames[(int) $lr['id']] = $lr['name'];
        foreach (routers_of($u) as $r) {
            // Short timeout: an offline router answers "connection refused"
            // at once, and a slow one must not stall the whole dashboard.
            $res = router_call($r, '/site', 'GET', '', null, 8);
            $site = null;
            if ($res && $res[0] === 200) {
                $j = json_decode($res[2], true);
                if (is_array($j) && !empty($j['ok'])) $site = $j;
            }
            if ($site) {
                db()->prepare('UPDATE routers SET last_seen = ?, last_state = ? WHERE id = ?')
                    ->execute([time(), json_encode($site), $r['id']]);
            }
            // Remote SSH: the router forwards its SSH to tunnel_port + 1 here.
            $sshPort = (int) $r['tunnel_port'] + 1;
            $sshUp = false;
            foreach ([$sshPort, $sshPort + 2] as $try) {      // second pair: see tunnel_port()
                $fp = @fsockopen('127.0.0.1', $try, $en, $es, 1.5);
                if ($fp) { stream_set_timeout($fp, 2); $ok = strpos((string) fread($fp, 32), 'SSH-') === 0; fclose($fp);
                           if ($ok) { $sshUp = true; $sshPort = $try; break; } }
            }
            $relaySeen = relay_alive((int) $r['id']);
            // The tunnel can be down (a line just failed over) while the router is fine and
            // answering over the HTTPS channel. That channel takes 7-17 s a call, longer than the
            // 8 s this dashboard waits, so it used to show "Offline". The router polling the
            // channel within the last 75 s means it is there.
            $via = $site ? 'tunnel' : (($relaySeen && $relaySeen > time() - 75) ? 'https' : null);
            $out[] = [
                'via'       => $via,
                'ssh'       => ['port' => $sshPort, 'up' => $sshUp,
                                'jump' => get_current_user() . '@' . strtolower(explode(':', $_SERVER['HTTP_HOST'] ?? 'mikaelbhai.com')[0]),
                                'https_seen' => $relaySeen ?: null],
                'id'        => (int) $r['id'],
                'name'      => $r['name'],
                'location_id' => $r['location_id'] ? (int) $r['location_id'] : null,
                'location'  => ($r['location_id'] && isset($locNames[(int) $r['location_id']])) ? $locNames[(int) $r['location_id']] : null,
                'role'      => in_array($r['role'], ['main', 'branch'], true) ? $r['role'] : null,
                'reachable' => $via !== null,                     // the tunnel answers, or the HTTPS channel is polling
                'last_seen' => $site ? time() : ($r['last_seen'] ? (int) $r['last_seen'] : null),
                // when unreachable, the last state we saw — so the card still
                // says where the router is and what it was using
                'site'      => $site ?: ($r['last_state'] ? json_decode($r['last_state'], true) : null),
            ];
        }
        // what this account may do with each router; remote SSH details only for its owner
        foreach ($out as $i => $o) {
            $acc = 'owner';
            foreach (routers_of($u) as $rr) { if ((int) $rr['id'] === $o['id']) { $acc = $rr['access'] ?? 'owner'; break; } }
            $out[$i]['access'] = $acc;
            if ($acc !== 'owner') $out[$i]['ssh'] = null;
        }
        json_out(200, ['ok' => true, 'routers' => $out, 'now' => time()]);

    case 'GET /connected':
        // Devices connected right now, for the router asked about and every router in its location.
        // A device named on one router shows that name on the other too (matched by MAC address).
        $u = require_user();
        $rid = (int) ($_GET['r'] ?? 0);
        $r = router_for($u, $rid);
        if (!$r) fail(403, 'This router is not assigned to your account.');
        $pdo = db();
        if (!empty($r['location_id'])) {
            $q = $pdo->prepare('SELECT r.id, r.name, r.role FROM routers r JOIN user_routers ur ON ur.router_id = r.id
                                WHERE r.location_id = ? AND ur.user_id = ? ORDER BY (r.role = \'main\') DESC, r.id');
            $q->execute([$r['location_id'], $u['id']]);
        } else {
            $q = $pdo->prepare('SELECT id, name, role FROM routers WHERE id = ?'); $q->execute([$rid]);
        }
        $rs = $q->fetchAll();
        $names = [];
        $devs = [];
        foreach ($rs as $x) {
            $dq = $pdo->prepare('SELECT mac, ip, host, name, wifi, seen FROM devices_now WHERE router_id = ? AND seen > ? ORDER BY name = \'\', name, host, mac');
            $dq->execute([(int) $x['id'], time() - 300]);     // a router that stopped uploading shows nothing stale
            foreach ($dq->fetchAll() as $d) {
                if ($d['name'] !== '' && empty($names[$d['mac']])) $names[$d['mac']] = $d['name'];
                $devs[] = ['router_id' => (int) $x['id'], 'router' => $x['name'], 'role' => $x['role'],
                           'mac' => $d['mac'], 'ip' => $d['ip'], 'host' => $d['host'], 'name' => $d['name'],
                           'wifi' => (bool) $d['wifi'], 'seen' => (int) $d['seen']];
            }
        }
        foreach ($devs as &$d) { if ($d['name'] === '' && !empty($names[$d['mac']])) $d['name'] = $names[$d['mac']]; }
        unset($d);
        json_out(200, ['ok' => true, 'devices' => $devs, 'routers' => array_map(function ($x) { return ['id' => (int) $x['id'], 'name' => $x['name'], 'role' => $x['role']]; }, $rs), 'now' => time()]);

    case 'GET /activity':
        $u = require_user();
        $rid = (int) ($_GET['r'] ?? 0);
        if (!router_for($u, $rid)) fail(403, 'This router is not assigned to your account.');
        $pdo = act_db();
        $now = time();
        $days = max(1, min(KEEP_DAYS, (int) ($_GET['days'] ?? 1)));
        $since = $now - $days * 86400;
        $mac = strtolower(preg_replace('/[^0-9a-fA-F:]/', '', (string) ($_GET['mac'] ?? '')));
        $q = trim((string) ($_GET['q'] ?? ''));

        // Right now: the last three minutes of app use and lookups, per device
        $live = [];
        $st = $pdo->prepare('SELECT mac, ip, name, app, SUM(bytes) b, MAX(ts) t FROM app_use
                             WHERE router_id = ? AND ts >= ? GROUP BY mac, app ORDER BY b DESC');
        $st->execute([$rid, $now - 180]);
        foreach ($st as $row) {
            $k = $row['mac'] ?: $row['ip'];
            $live[$k] = $live[$k] ?? ['mac' => $row['mac'], 'ip' => $row['ip'], 'name' => $row['name'], 'apps' => [], 'sites' => [], 'last' => 0];
            $live[$k]['apps'][] = ['app' => $row['app'], 'bytes' => (int) $row['b']];
            $live[$k]['last'] = max($live[$k]['last'], (int) $row['t']);
        }
        $st = $pdo->prepare('SELECT mac, ip, name, domain, app, MAX(ts) t FROM visits
                             WHERE router_id = ? AND ts >= ? GROUP BY mac, domain ORDER BY t DESC');
        $st->execute([$rid, $now - 180]);
        foreach ($st as $row) {
            $k = $row['mac'] ?: $row['ip'];
            $live[$k] = $live[$k] ?? ['mac' => $row['mac'], 'ip' => $row['ip'], 'name' => $row['name'], 'apps' => [], 'sites' => [], 'last' => 0];
            if (count($live[$k]['sites']) < 12) $live[$k]['sites'][] = ['domain' => $row['domain'], 'app' => $row['app']];
            if (!$live[$k]['name'] && $row['name']) $live[$k]['name'] = $row['name'];
            $live[$k]['last'] = max($live[$k]['last'], (int) $row['t']);
        }

        // Every device seen in the period, for the filter
        $st = $pdo->prepare('SELECT mac, MAX(name) name, MAX(ip) ip, COUNT(*) n, MAX(ts) last FROM visits
                             WHERE router_id = ? AND ts >= ? GROUP BY mac ORDER BY last DESC');
        $st->execute([$rid, $since]);
        $devices = $st->fetchAll();

        // Site history, newest first
        $sql = 'SELECT ts, mac, ip, name, domain, app FROM visits WHERE router_id = ? AND ts >= ?';
        $args = [$rid, $since];
        if ($mac !== '') { $sql .= ' AND mac = ?'; $args[] = $mac; }
        if ($q !== '')   { $sql .= ' AND (domain LIKE ? OR app LIKE ? OR name LIKE ?)'; $like = '%' . $q . '%'; array_push($args, $like, $like, $like); }
        $st = $pdo->prepare($sql . ' ORDER BY ts DESC LIMIT 600');
        $st->execute($args);
        $visits = $st->fetchAll();

        // Most used apps in the period
        $sql = 'SELECT app, COUNT(*) n, COUNT(DISTINCT mac) devices FROM visits WHERE router_id = ? AND ts >= ?';
        $args = [$rid, $since];
        if ($mac !== '') { $sql .= ' AND mac = ?'; $args[] = $mac; }
        $st = $pdo->prepare($sql . ' GROUP BY app ORDER BY n DESC LIMIT 20');
        $st->execute($args);
        $top = $st->fetchAll();

        // Lookups over time for the chart: per hour for one day, else per day
        // (Pakistan time, which has no daylight saving)
        $bucket = $days === 1 ? 3600 : 86400;
        $tz = 18000;
        $sql = "SELECT ((ts + $tz) / $bucket) * $bucket - $tz AS t, COUNT(*) n, COUNT(DISTINCT mac) d FROM visits WHERE router_id = ? AND ts >= ?";
        $args = [$rid, $since];
        if ($mac !== '') { $sql .= ' AND mac = ?'; $args[] = $mac; }
        $st = $pdo->prepare($sql . ' GROUP BY t ORDER BY t');
        $st->execute($args);
        $timeline = array_map(function ($r) { return [(int) $r['t'], (int) $r['n'], (int) $r['d']]; }, $st->fetchAll());

        json_out(200, ['ok' => true, 'now' => $now, 'live' => array_values($live), 'devices' => $devices,
                       'visits' => $visits, 'top' => $top, 'days' => $days, 'bucket' => $bucket, 'timeline' => $timeline]);

    case 'GET /sites':
        $u = require_user();
        $rid = (int) ($_GET['r'] ?? 0);
        if (!router_for($u, $rid)) fail(403, 'This router is not assigned to your account.');
        $pdo = act_db();
        $mac = strtolower(preg_replace('/[^0-9a-fA-F:]/', '', (string) ($_GET['mac'] ?? '')));
        if ($mac !== '') {
            $st = $pdo->prepare('SELECT domain, app, n, first, last FROM site_totals WHERE router_id = ? AND mac = ? ORDER BY n DESC, last DESC LIMIT 5000');
            $st->execute([$rid, $mac]);
        } else {
            $st = $pdo->prepare('SELECT domain, MAX(app) app, SUM(n) n, COUNT(DISTINCT mac) devices, MIN(first) first, MAX(last) last
                                 FROM site_totals WHERE router_id = ? GROUP BY domain ORDER BY n DESC LIMIT 5000');
            $st->execute([$rid]);
        }
        $rows = $st->fetchAll();
        $since = $pdo->prepare('SELECT MIN(first) FROM site_totals WHERE router_id = ?');
        $since->execute([$rid]);
        $total = $pdo->prepare('SELECT COUNT(DISTINCT domain) FROM site_totals WHERE router_id = ?' . ($mac !== '' ? ' AND mac = ?' : ''));
        $total->execute($mac !== '' ? [$rid, $mac] : [$rid]);
        json_out(200, ['ok' => true, 'sites' => $rows, 'total' => (int) $total->fetchColumn(), 'since' => (int) $since->fetchColumn(), 'now' => time()]);

    case 'GET /events':
        $u = require_user();
        $rid = (int) ($_GET['r'] ?? 0);
        if (!router_for($u, $rid)) fail(403, 'This router is not assigned to your account.');
        $limit = max(1, min(3000, (int) ($_GET['limit'] ?? 500)));
        $st = act_db()->prepare('SELECT ts, kind, sev, msg FROM events WHERE router_id = ? ORDER BY ts DESC LIMIT ' . $limit);
        $st->execute([$rid]);
        $r = db()->prepare('SELECT last_seen FROM routers WHERE id = ?'); $r->execute([$rid]);
        json_out(200, ['ok' => true, 'events' => $st->fetchAll(), 'last_upload' => (int) ($r->fetch()['last_seen'] ?? 0), 'now' => time()]);
}
fail(404, 'No such endpoint.');
