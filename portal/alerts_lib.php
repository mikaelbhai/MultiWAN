<?php
// Outage alerts: shared by webapp/alerts.php (the phone app's calls),
// webapp/ingest.php (router uploads) and portal/alertd.php (the watcher).
//
// Alerts come from two places: the event log the routers upload every minute
// (a line going down or coming back, the router having been off), and the
// router going silent: no upload for 2.5 minutes means a power cut or every
// line down, which the router itself cannot report until it is back.
//
// Delivery: phones with a Firebase push token get each alert pushed by
// Google (no app running in the background); phones without one wait on
// alerts.php/poll as before.
require_once __DIR__ . '/activity_lib.php';

date_default_timezone_set('Asia/Karachi');
// A router counts as offline only when we hear nothing from it by ANY road for
// this long: its upload (every 60 s), its HTTPS poll (every ~20 s) and the SSH
// tunnel. One quiet road is not "offline": a slow upload used to raise a false
// "both lines are down" alert every few hours.
const OFFLINE_AFTER     = 180;
const LINE_MAIN_AFTER   = 20;   // seconds the main line must stay down before we alert
const LINE_BACKUP_AFTER = 60;   // seconds a backup line must stay down before we alert
const FCM_KEY_FILE = __DIR__ . '/firebase-key.json';         // service account key, never served
const FCM_CACHE    = __DIR__ . '/firebase-access.json';      // short-lived Google access token
const ALERTD_BEAT  = __DIR__ . '/alertd.beat';               // the watcher touches this every loop

function al_db(): PDO {
    static $ready = false;
    $pdo = act_db();
    if ($ready) return $pdo;
    $ready = true;
    $pdo->exec('CREATE TABLE IF NOT EXISTS app_devices (token_hash TEXT PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        label TEXT, created INTEGER NOT NULL, last_seen INTEGER)');
    $cols = array_column($pdo->query('PRAGMA table_info(app_devices)')->fetchAll(), 'name');
    if (!in_array('fcm', $cols, true)) $pdo->exec('ALTER TABLE app_devices ADD COLUMN fcm TEXT');
    if (!in_array('pushed_id', $cols, true)) $pdo->exec('ALTER TABLE app_devices ADD COLUMN pushed_id INTEGER NOT NULL DEFAULT 0');
    $pdo->exec('CREATE TABLE IF NOT EXISTS alerts (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL,
        router_id INTEGER, user_id INTEGER, kind TEXT, title TEXT, body TEXT)');
    $pdo->exec('CREATE INDEX IF NOT EXISTS al_router ON alerts (router_id, id)');
    // per router: is it offline right now, and how far the event log has been read
    $pdo->exec('CREATE TABLE IF NOT EXISTS router_watch (router_id INTEGER PRIMARY KEY,
        offline INTEGER NOT NULL DEFAULT 0, since INTEGER, ev_rowid INTEGER NOT NULL DEFAULT 0)');
    // per router and line (wan1, wan2 ...): is it down, since when, and did we tell the owner
    $pdo->exec('CREATE TABLE IF NOT EXISTS line_watch (router_id INTEGER NOT NULL, item TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT \'up\', since INTEGER, ts_state INTEGER NOT NULL DEFAULT 0,
        alerted INTEGER NOT NULL DEFAULT 0, reason TEXT, PRIMARY KEY (router_id, item))');
    return $pdo;
}

function token_user(string $tok): ?array {
    if (!preg_match('/^[a-f0-9]{64}$/', $tok)) return null;
    $st = al_db()->prepare('SELECT u.id, u.email, u.is_admin FROM app_devices d JOIN users u ON u.id = d.user_id WHERE d.token_hash = ?');
    $st->execute([hash('sha256', $tok)]);
    return $st->fetch() ?: null;
}

function hm(int $ts): string { return date('g:i A', $ts); }

function mins(int $s): string {
    $m = max(1, (int) round($s / 60));
    if ($m < 60) return $m . ' min';
    return intdiv($m, 60) . ' h ' . ($m % 60) . ' min';
}

// What the owner calls each line: "Connect 1Gb", else the provider, else WAN1.
function line_names(array $r): array {
    $names = [];
    $st = json_decode((string) ($r['last_state'] ?? ''), true);
    foreach ((array) ($st['wans'] ?? []) as $w) {
        if (!is_array($w) || empty($w['iface'])) continue;
        $n = trim((string) ($w['label'] ?? '')) ?: trim((string) ($w['isp'] ?? ''));
        $names[$w['iface']] = $n !== '' ? $n : strtoupper($w['iface']);
    }
    return $names;
}

function add_alert(PDO $pdo, ?int $rid, ?int $uid, string $kind, string $title, string $body, ?int $ts = null): void {
    $pdo->prepare('INSERT INTO alerts (ts, router_id, user_id, kind, title, body) VALUES (?, ?, ?, ?, ?, ?)')
        ->execute([$ts ?? time(), $rid, $uid, $kind, $title, $body]);
}

function all_routers(): array { return al_db()->query('SELECT * FROM routers')->fetchAll(); }

// ---------- lines ----------
// The main line is wan1; every other line is a backup.
function is_main_line(string $iface): bool { return $iface === 'wan1'; }
function line_label(array $names, string $iface): string { return $names[$iface] ?? strtoupper($iface); }
function dur(int $s): string { return $s < 90 ? max(1, $s) . ' s' : mins($s); }
function why_of(string $msg): string { return preg_match('/- reason: (.*)$/', $msg, $x) ? trim($x[1]) : ''; }

// A line went down or came back, from the router's event log (in time order).
// Events older than what is already known are ignored, so a late upload can
// not turn a line that is back into a "down" again.
function line_event(PDO $pdo, array $r, array $names, string $iface, bool $down, int $ts, string $why): void {
    $rid = (int) $r['id']; $name = $r['name']; $ln = line_label($names, $iface);
    $st = $pdo->prepare('SELECT * FROM line_watch WHERE router_id = ? AND item = ?');
    $st->execute([$rid, $iface]);
    $row = $st->fetch();
    if ($row && $ts < (int) $row['ts_state']) return;
    if ($down) {
        if ($row && $row['state'] === 'down') {
            if ($why !== '' && trim((string) $row['reason']) === '')
                $pdo->prepare('UPDATE line_watch SET reason = ? WHERE router_id = ? AND item = ?')->execute([$why, $rid, $iface]);
            return;
        }
        $pdo->prepare('INSERT INTO line_watch (router_id, item, state, since, ts_state, alerted, reason) VALUES (?, ?, \'down\', ?, ?, 0, ?)
            ON CONFLICT (router_id, item) DO UPDATE SET state = \'down\', since = excluded.since, ts_state = excluded.ts_state, alerted = 0, reason = excluded.reason')
            ->execute([$rid, $iface, $ts, $ts, $why]);
        return;
    }
    // back: only say so if the owner was told it was down
    if ($row && $row['state'] === 'down' && (int) $row['alerted']) {
        $gone = max(0, $ts - (int) $row['since']);
        $main = is_main_line($iface);
        add_alert($pdo, $rid, null, $main ? 'line_up' : 'backup_up',
            $main ? "$ln is back" : "Backup line $ln is back",
            "$name: " . ($main ? "your main line $ln" : "your backup line $ln") . " is working again after " . dur($gone) . ".", $ts);
    }
    $pdo->prepare('INSERT INTO line_watch (router_id, item, state, since, ts_state, alerted, reason) VALUES (?, ?, \'up\', NULL, ?, 0, NULL)
        ON CONFLICT (router_id, item) DO UPDATE SET state = \'up\', since = NULL, ts_state = excluded.ts_state, alerted = 0, reason = NULL')
        ->execute([$rid, $iface, $ts]);
}

// A line that has stayed down long enough gets its alert: the main line after
// LINE_MAIN_AFTER s, a backup line after LINE_BACKUP_AFTER s. A shorter blip
// is never reported, and so is never followed by a "back" alert either.
function lines_due(PDO $pdo, array $r, array $names, int $now): void {
    $rid = (int) $r['id']; $name = $r['name'];
    $st = $pdo->prepare('SELECT * FROM line_watch WHERE router_id = ? AND state = \'down\' AND alerted = 0 AND item LIKE \'wan%\'');
    $st->execute([$rid]);
    foreach ($st->fetchAll() as $row) {
        $iface = (string) $row['item']; $main = is_main_line($iface);
        $since = (int) $row['since'];
        if ($now - $since < ($main ? LINE_MAIN_AFTER : LINE_BACKUP_AFTER)) continue;
        $ln = line_label($names, $iface);
        $why = trim((string) $row['reason']);
        $o = $pdo->prepare('SELECT COUNT(*) FROM line_watch WHERE router_id = ? AND item LIKE \'wan%\' AND item != ? AND state = \'down\'');
        $o->execute([$rid, $iface]);
        $both = (int) $o->fetchColumn() > 0;
        $for = dur($now - $since) . ($now - $since > 300 ? ' (since ' . hm($since) . ')' : '');
        $opinion = $why !== '' ? " The router's opinion: $why." : '';
        if ($main) {
            add_alert($pdo, $rid, null, 'line_down', "$ln is down",
                "$name: your main line $ln has been down for $for.$opinion" .
                ($both ? ' The backup line is down too, so there is no internet.' : ' Traffic moved to the backup line.'), $now);
        } else {
            add_alert($pdo, $rid, null, 'backup_down', "Backup line $ln is down",
                "$name: your backup line $ln has been down for $for.$opinion" .
                ($both ? ' The main line is down too, so there is no internet.'
                       : ' Your internet is fine right now (the main line is carrying it), but you have no backup until this is fixed.'), $now);
        }
        $pdo->prepare('UPDATE line_watch SET alerted = 1 WHERE router_id = ? AND item = ?')->execute([$rid, $iface]);
    }
}

// ---------- is the router there? ----------
function tunnel_ping(int $port): bool {
    $ch = curl_init('http://127.0.0.1:' . $port . '/cgi-bin/mwadmin/ping');
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 2, CURLOPT_TIMEOUT => 3, CURLOPT_PROXY => '']);
    $r = curl_exec($ch);
    curl_close($ch);
    return is_string($r) && strpos($r, '"ok":true') !== false;
}

// The latest moment we heard from the router by any road: its upload, its
// HTTPS poll, or (when both are quiet) the SSH tunnel answering right now.
function router_heard(int $rid, int $port, int $now): int {
    $last = (int) (al_db()->query('SELECT last_seen FROM routers WHERE id = ' . $rid)->fetchColumn() ?: 0);
    $heard = max($last, relay_alive($rid));
    if ($heard > 0 && $now - $heard > 90 && $port > 0 && (tunnel_ping($port) || tunnel_ping($port + 2))) $heard = $now;
    return $heard;
}

// What the router logged while the website could not hear it.
function gap_summary(PDO $pdo, int $rid, int $from, int $to): string {
    $st = $pdo->prepare('SELECT kind, msg FROM events WHERE router_id = ? AND ts BETWEEN ? AND ? ORDER BY ts');
    $st->execute([$rid, $from - 60, $to]);
    $restart = false; $down = [];
    foreach ($st as $e) {
        if ($e['kind'] === 'power' && (strpos($e['msg'], 'was off or restarting') !== false || strpos($e['msg'], 'Router started') !== false)) $restart = true;
        if ($e['kind'] === 'line' && strpos($e['msg'], 'went down') !== false) $down[] = preg_replace('/^Internet line /', '', $e['msg']);
    }
    if ($restart) return ' The router had restarted (a power cut or a reboot).';
    if ($down) return ' The router stayed on and logged: ' . implode('; ', array_slice($down, 0, 3)) . '.';
    return ' The router stayed on and logged no restart and no line failure, so the internet lines were probably fine and the website simply could not hear it for a while.';
}

// Turn new router events, long-enough line outages and silences into alerts.
// Safe to run from many places at once: each router is checked inside one
// write transaction.
function watch_routers(array $routers): void {
    $pdo = al_db();
    $now = time();
    foreach ($routers as $r) {
        $rid = (int) $r['id'];
        $name = $r['name'];
        // asked before the write lock is taken: the tunnel check can take seconds
        $heard = router_heard($rid, (int) $r['tunnel_port'], $now);
        $pdo->exec('BEGIN IMMEDIATE');
        try {
            $st = $pdo->prepare('SELECT * FROM router_watch WHERE router_id = ?');
            $st->execute([$rid]);
            $w = $st->fetch();
            $maxRow = (int) $pdo->query('SELECT COALESCE(MAX(rowid), 0) FROM events WHERE router_id = ' . $rid)->fetchColumn();
            $last = (int) ($pdo->query('SELECT last_seen FROM routers WHERE id = ' . $rid)->fetchColumn() ?: 0);
            $silent = $heard > 0 && $now - $heard > OFFLINE_AFTER;
            if (!$w) {   // first look at this router: start from now, no old news
                $pdo->prepare('INSERT INTO router_watch (router_id, offline, since, ev_rowid) VALUES (?, ?, ?, ?)')
                    ->execute([$rid, $silent ? 1 : 0, $silent ? $heard : null, $maxRow]);
                $pdo->exec('COMMIT');
                continue;
            }
            $names = line_names($r);
            // new events from the router's log
            if ($maxRow > (int) $w['ev_rowid']) {
                $ev = $pdo->prepare('SELECT ts, kind, sev, msg FROM events WHERE router_id = ? AND rowid > ? ORDER BY ts');
                $ev->execute([$rid, (int) $w['ev_rowid']]);
                foreach ($ev as $e) {
                    $msg = (string) $e['msg']; $ts = (int) $e['ts'];
                    $old = $now - $ts > 86400;                  // day-old news is not alerted
                    if ($e['kind'] === 'line' && preg_match('/line (wan\d) (went down|is back)/', $msg, $m)) {
                        line_event($pdo, $r, $names, $m[1], $m[2] === 'went down', $ts, why_of($msg));
                    } elseif ($e['kind'] === 'node' && !$old && preg_match('/^Node (.+?) \((\w+)\) (went down|is back)/', $msg, $m)) {
                        if ($m[3] === 'went down') {
                            $why = why_of($msg);
                            add_alert($pdo, $rid, null, 'node_down', "{$m[1]} is offline",
                                "$name: {$m[1]} ({$m[2]}) stopped answering." . ($why !== '' ? " $why." : ''), $ts);
                        } else {
                            add_alert($pdo, $rid, null, 'node_up', "{$m[1]} is back", "$name: {$m[1]} ({$m[2]}) is answering again.", $ts);
                        }
                    } elseif ($e['kind'] === 'force' && !$old && strpos($msg, 'switched off automatically') !== false) {
                        add_alert($pdo, $rid, null, 'force', 'Line forcing was switched off', "$name: $msg", $ts);
                    } elseif ($e['kind'] === 'power' && !$old && strpos($msg, 'was off or restarting') !== false) {
                        add_alert($pdo, $rid, null, 'power', "$name restarted",
                            preg_replace('/^Router was/', 'The router was', $msg) . '.', $ts);
                    }
                }
                $pdo->prepare('UPDATE router_watch SET ev_rowid = ? WHERE router_id = ?')->execute([$maxRow, $rid]);
            }
            // a line that has now been down long enough
            lines_due($pdo, $r, $names, $now);
            // silence: offline / back online
            if ($silent && !(int) $w['offline']) {
                add_alert($pdo, $rid, null, 'offline', "$name is offline",
                    "No contact from the router since " . hm($heard) . ": no upload, no HTTPS poll and no tunnel answer. " .
                    "Power cut, or both internet lines are down.", $now);
                $pdo->prepare('UPDATE router_watch SET offline = 1, since = ? WHERE router_id = ?')->execute([$heard, $rid]);
            } elseif (!$silent && (int) $w['offline']) {
                $since = (int) ($w['since'] ?: $now);
                $gone = $now - $since;
                // only describe the gap once the router has uploaded its own log of it
                $detail = $last > $since ? gap_summary($pdo, $rid, $since, $now) : '';
                add_alert($pdo, $rid, null, 'online', "$name is back online",
                    "The router was unreachable for about " . mins($gone) . ".$detail", $now);
                $pdo->prepare('UPDATE router_watch SET offline = 0, since = NULL WHERE router_id = ?')->execute([$rid]);
            }
            $pdo->exec('COMMIT');
        } catch (Throwable $t) {
            $pdo->exec('ROLLBACK');
            throw $t;
        }
    }
}

function alerts_for(array $u, array $routers, int $after): array {
    $ids = array_map(function ($r) { return (int) $r['id']; }, $routers);
    $in = $ids ? implode(',', $ids) : '0';
    $st = al_db()->prepare("SELECT a.id, a.ts, a.kind, a.title, a.body, a.router_id FROM alerts a
        WHERE a.id > ? AND (a.router_id IN ($in) OR a.user_id = ?) ORDER BY a.id LIMIT 20");
    $st->execute([$after, (int) $u['id']]);
    return array_map(function ($a) {
        return ['id' => (int) $a['id'], 'ts' => (int) $a['ts'], 'kind' => $a['kind'], 'title' => $a['title'],
                'body' => $a['body'], 'router' => $a['router_id'] === null ? null : (int) $a['router_id']];
    }, $st->fetchAll());
}

function newest_id(): int { return (int) al_db()->query('SELECT COALESCE(MAX(id), 0) FROM alerts')->fetchColumn(); }

function router_status(array $routers): array {
    $pdo = al_db(); $now = time(); $out = [];
    foreach ($routers as $r) {
        $last = (int) ($pdo->query('SELECT last_seen FROM routers WHERE id = ' . (int) $r['id'])->fetchColumn() ?: 0);
        $last = max($last, relay_alive((int) $r['id']));
        $out[] = ['id' => (int) $r['id'], 'name' => $r['name'], 'online' => $last > 0 && $now - $last <= OFFLINE_AFTER, 'last_seen' => $last];
    }
    return $out;
}

/* ---------- Firebase push (FCM HTTP v1) ---------- */

function fcm_ready(): bool { return is_readable(FCM_KEY_FILE); }

function b64url(string $s): string { return rtrim(strtr(base64_encode($s), '+/', '-_'), '='); }

function fcm_key(): ?array {
    static $k = null;
    if ($k === null) $k = fcm_ready() ? (json_decode((string) file_get_contents(FCM_KEY_FILE), true) ?: []) : [];
    return !empty($k['private_key']) && !empty($k['client_email']) && !empty($k['project_id']) ? $k : null;
}

function http_post(string $url, string $body, array $headers, int $timeout = 15): array {
    $c = curl_init($url);
    curl_setopt_array($c, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => $body, CURLOPT_HTTPHEADER => $headers,
        CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => $timeout, CURLOPT_CONNECTTIMEOUT => 8]);
    $out = curl_exec($c);
    $code = (int) curl_getinfo($c, CURLINFO_RESPONSE_CODE);
    curl_close($c);
    return [$code, $out === false ? '' : $out];
}

// A Google access token for sending pushes, kept for its hour.
function fcm_access(bool $fresh = false): ?string {
    $k = fcm_key();
    if (!$k) return null;
    if (!$fresh && is_readable(FCM_CACHE)) {
        $c = json_decode((string) file_get_contents(FCM_CACHE), true);
        if (!empty($c['token']) && (int) ($c['exp'] ?? 0) > time() + 120) return $c['token'];
    }
    $now = time();
    $aud = $k['token_uri'] ?? 'https://oauth2.googleapis.com/token';
    $jwt = b64url(json_encode(['alg' => 'RS256', 'typ' => 'JWT'])) . '.' . b64url(json_encode([
        'iss' => $k['client_email'], 'scope' => 'https://www.googleapis.com/auth/firebase.messaging',
        'aud' => $aud, 'iat' => $now, 'exp' => $now + 3600]));
    if (!openssl_sign($jwt, $sig, $k['private_key'], OPENSSL_ALGO_SHA256)) return null;
    [$code, $out] = http_post($aud, http_build_query([
        'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'assertion' => $jwt . '.' . b64url($sig)]),
        ['Content-Type: application/x-www-form-urlencoded']);
    $j = json_decode($out, true);
    if ($code !== 200 || empty($j['access_token'])) { alertd_log("Google sign-in for push failed: HTTP $code"); return null; }
    $tmp = FCM_CACHE . '.' . getmypid();
    file_put_contents($tmp, json_encode(['token' => $j['access_token'], 'exp' => $now + (int) ($j['expires_in'] ?? 3600)]));
    chmod($tmp, 0600);
    rename($tmp, FCM_CACHE);
    return $j['access_token'];
}

// Send one alert to one phone. 'ok', 'gone' (that phone's push token is no
// longer valid) or 'retry'.
function fcm_send(string $fcm, array $a): string {
    $k = fcm_key();
    if (!$k) return 'retry';
    $msg = json_encode(['message' => [
        'token' => $fcm,
        'data' => ['id' => (string) $a['id'], 'kind' => (string) $a['kind'], 'title' => (string) $a['title'],
                   'body' => (string) $a['body'], 'ts' => (string) $a['ts']],
        'android' => ['priority' => 'HIGH', 'ttl' => '86400s'],
    ]]);
    $url = 'https://fcm.googleapis.com/v1/projects/' . rawurlencode($k['project_id']) . '/messages:send';
    for ($try = 0; $try < 2; $try++) {
        $acc = fcm_access($try > 0);
        if (!$acc) return 'retry';
        [$code, $out] = http_post($url, $msg, ['Content-Type: application/json', 'Authorization: Bearer ' . $acc]);
        if ($code === 200) return 'ok';
        if ($code === 401) continue;
        if ($code === 404 || ($code === 400 && strpos($out, 'registration token') !== false)
            || strpos($out, 'UNREGISTERED') !== false) return 'gone';
        alertd_log("push failed: HTTP $code " . substr(preg_replace('/\s+/', ' ', $out), 0, 200));
        return 'retry';
    }
    return 'retry';
}

// Push every alert each phone has not had yet. One sender at a time.
function dispatch_pushes(): int {
    if (!fcm_key()) return 0;
    $lock = fopen(__DIR__ . '/push.lock', 'c');
    if (!$lock || !flock($lock, LOCK_EX)) return 0;
    $pdo = al_db();
    $sent = 0;
    $devs = $pdo->query('SELECT d.token_hash, d.fcm, d.pushed_id, u.id, u.email, u.is_admin
        FROM app_devices d JOIN users u ON u.id = d.user_id WHERE d.fcm IS NOT NULL AND d.fcm != \'\'')->fetchAll();
    $mark = $pdo->prepare('UPDATE app_devices SET pushed_id = ? WHERE token_hash = ?');
    $drop = $pdo->prepare('UPDATE app_devices SET fcm = NULL WHERE token_hash = ?');
    foreach ($devs as $d) {
        $list = alerts_for($d, routers_of($d), (int) $d['pushed_id']);
        foreach ($list as $a) {
            $r = time() - $a['ts'] > 86400 ? 'ok' : fcm_send($d['fcm'], $a);   // day-old news is skipped
            if ($r === 'gone') { $drop->execute([$d['token_hash']]); break; }
            if ($r === 'retry') break;
            $mark->execute([$a['id'], $d['token_hash']]);
            $sent++;
        }
    }
    flock($lock, LOCK_UN);
    fclose($lock);
    return $sent;
}

/* ---------- the watcher (portal/alertd.php) ---------- */

function alertd_log(string $m): void {
    $f = __DIR__ . '/alertd.log';
    if (is_file($f) && filesize($f) > 200000) rename($f, $f . '.old');
    file_put_contents($f, date('Y-m-d H:i:s ') . $m . "\n", FILE_APPEND);
}

// Start the watcher if it is not running. The host has no scheduled jobs,
// so router uploads and app calls keep it alive instead.
function alertd_ensure(): void {
    clearstatcache(true, ALERTD_BEAT);
    if (is_file(ALERTD_BEAT) && time() - filemtime(ALERTD_BEAT) < 45) return;
    if (!function_exists('exec')) return;
    $php = is_executable('/usr/bin/php') ? '/usr/bin/php' : 'php';
    @exec('nohup ' . escapeshellarg($php) . ' ' . escapeshellarg(__DIR__ . '/alertd.php') . ' > /dev/null 2>&1 &');
}
