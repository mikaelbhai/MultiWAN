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

    case 'POST /enroll-key':
        // admins only: a one-time key so another router running the Baytaar software can join with it
        $u = require_user();
        if (!(int) $u['is_admin']) fail(403, 'Admins only.');
        require_once __DIR__ . '/../portal/enroll_lib.php';
        $b = read_json_body(4096);
        $nm = trim(mb_substr(preg_replace('/[\x00-\x1f]/', '', (string) ($b['name'] ?? '')), 0, 60));
        if ($nm === '') fail(400, 'Give the router a name.');
        [$rid, $key] = enroll_new_key($nm, 48);
        db()->prepare('INSERT OR IGNORE INTO user_routers (user_id, router_id) VALUES (?, ?)')->execute([$u['id'], $rid]);
        $site = strtolower(explode(':', $_SERVER['HTTP_HOST'] ?? '')[0]);
        json_out(200, ['ok' => true, 'router_id' => $rid, 'key' => $key, 'valid_hours' => 48,
                       'command' => "sh /usr/lib/mwadmin/connect.sh join $site $key"]);

    case 'GET /routers':
        $u = require_user();
        $out = [];
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
                'reachable' => $via !== null,                      // the tunnel answers, or the HTTPS channel is polling
                'last_seen' => $site ? time() : ($r['last_seen'] ? (int) $r['last_seen'] : null),
                // when unreachable, the last state we saw — so the card still
                // says where the router is and what it was using
                'site'      => $site ?: ($r['last_state'] ? json_decode($r['last_state'], true) : null),
            ];
        }
        json_out(200, ['ok' => true, 'routers' => $out, 'now' => time()]);

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
