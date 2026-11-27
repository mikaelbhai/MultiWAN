<?php
// A router joins this website with the website's name and an API key.
//
//   POST enroll.php   {key, device_id, hostname?, board?, version?}
//     -> {ok, router_id, name, token, base, new}     the router stores token and base
//
// Two kinds of key (both stored only as a hash):
//   * an account's reusable API key ("bu..."): any number of routers can join with it, each one
//     becomes its own router in that account. A router is recognised by its device_id, so joining
//     again (after a reset) gives back the same router and token instead of making a duplicate.
//   * a one-time key ("bk...") made with cli.php new-key, kept for scripts.
//
// Public on purpose (the router has no account yet), so it is strict: wrong keys are rate-limited per
// address, and the answer carries the router's secret token, so it is only given over HTTPS.
require __DIR__ . '/../portal/enroll_lib.php';
require __DIR__ . '/../portal/caps_lib.php';

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') fail(405, 'POST only.');
$https = (($_SERVER['HTTPS'] ?? '') !== '' && ($_SERVER['HTTPS'] ?? '') !== 'off') || ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';
if (!$https) fail(400, 'Use https.');
$b = read_json_body(4096);
$key = (string) ($b['key'] ?? '');
if (!preg_match('/^[A-Za-z0-9_-]{16,80}$/', $key)) fail(400, 'That key does not look right.');
$dev = (string) ($b['device_id'] ?? '');
if ($dev !== '' && !preg_match('/^[A-Za-z0-9:_-]{8,64}$/', $dev)) fail(400, 'Bad device id.');
$clean = function ($s, $n) { return trim(mb_substr(preg_replace('/[\x00-\x1f\x7f]/u', '', (string) $s), 0, $n)); };
$hostname = $clean($b['hostname'] ?? '', 40);
$hostname = preg_replace('/[^A-Za-z0-9 ._-]/', '', $hostname);

$pdo = enroll_db();
$ip = client_ip();
$now = time();
$pdo->prepare('DELETE FROM enroll_fails WHERE ts < ?')->execute([$now - 900]);
$st = $pdo->prepare('SELECT COUNT(*) FROM enroll_fails WHERE ip = ?');
$st->execute([$ip]);
if ((int) $st->fetchColumn() >= 8) fail(429, 'Too many wrong keys. Try again in 15 minutes.');

$hash = hash('sha256', $key);
$host = strtolower(explode(':', $_SERVER['HTTP_HOST'] ?? '')[0]);
if (!preg_match('/^[a-z0-9.-]{3,253}$/', $host)) fail(400, 'Bad host.');
$dir = rtrim(str_replace('\\', '/', dirname($_SERVER['SCRIPT_NAME'] ?? '/')), '/');
$base = 'https://' . $host . $dir . '/';

// {key, check: true}: the Windows installer asks "is this key good?" before it touches a router. Nothing is created;
// a wrong key counts against the same limit as a wrong join.
if (!empty($b['check'])) {
    $st = $pdo->prepare('SELECT k.label, u.email, (SELECT COUNT(*) FROM user_routers ur WHERE ur.user_id = k.user_id) AS n
                         FROM api_keys k JOIN users u ON u.id = k.user_id WHERE k.key_hash = ? AND k.revoked = 0');
    $st->execute([$hash]);
    $k = $st->fetch();
    $st->closeCursor();
    if (!$k) {
        $pdo->prepare('INSERT INTO enroll_fails (ip, ts) VALUES (?, ?)')->execute([$ip, $now]);
        usleep(300000);
        fail(401, 'That key is wrong or has been revoked. Copy it again from "Add a router" on the website.');
    }
    $e = (string) $k['email']; $at = strpos($e, '@');
    json_out(200, ['ok' => true, 'valid' => true, 'account' => substr($e, 0, 1) . '...' . ($at !== false ? substr($e, $at) : ''),
                   'routers' => (int) $k['n'], 'label' => $k['label']]);
}

$pdo->exec('BEGIN IMMEDIATE');
try {
    // ---- the account's reusable key
    $st = $pdo->prepare('SELECT id, user_id, label FROM api_keys WHERE key_hash = ? AND revoked = 0');
    $st->execute([$hash]);
    $k = $st->fetch();
    $st->closeCursor();
    if ($k) {
        if ($dev === '') { $pdo->exec('ROLLBACK'); fail(400, 'This router did not send an id of its own. Update the router software and try again.'); }
        $st = $pdo->prepare('SELECT r.id, r.name, r.token FROM routers r JOIN user_routers ur ON ur.router_id = r.id
                             WHERE ur.user_id = ? AND r.device_id = ?');
        $st->execute([$k['user_id'], $dev]);
        $r = $st->fetch();
        $st->closeCursor();
        $new = false;
        if (!$r) {
            $st = $pdo->prepare('SELECT COUNT(*) FROM user_routers WHERE user_id = ?');
            $st->execute([$k['user_id']]);
            $n = (int) $st->fetchColumn();
            $st->closeCursor();
            if ($n >= MAX_ROUTERS_PER_USER) { $pdo->exec('ROLLBACK'); fail(400, 'This account already has ' . MAX_ROUTERS_PER_USER . ' routers. Remove one first.'); }
            $name = $hostname !== '' ? $hostname : ($k['label'] . ' ' . ($n + 1));
            $max = (int) $pdo->query('SELECT COALESCE(MAX(tunnel_port), 22081) FROM routers')->fetchColumn();
            $token = bin2hex(random_bytes(32));
            $pdo->prepare('INSERT INTO routers (name, tunnel_port, token, device_id, api_key_id) VALUES (?, ?, ?, ?, ?)')
                ->execute([$name, $max + 4, $token, $dev, $k['id']]);
            $rid = (int) $pdo->lastInsertId();
            $pdo->prepare('INSERT OR IGNORE INTO user_routers (user_id, router_id) VALUES (?, ?)')->execute([$k['user_id'], $rid]);
            $r = ['id' => $rid, 'name' => $name, 'token' => $token];
            $new = true;
        }
        $pdo->prepare('UPDATE api_keys SET uses = uses + 1, last_used = ? WHERE id = ?')->execute([$now, $k['id']]);
        $pdo->exec('COMMIT');
        json_out(200, ['ok' => true, 'router_id' => (int) $r['id'], 'name' => $r['name'], 'token' => $r['token'], 'base' => $base, 'new' => $new, 'web_level' => WEB_API_LEVEL]);
    }

    // ---- a one-time key
    $st = $pdo->prepare('SELECT k.id, k.router_id, r.name, r.token FROM enroll_keys k JOIN routers r ON r.id = k.router_id
                         WHERE k.key_hash = ? AND k.used = 0 AND k.expires > ?');
    $st->execute([$hash, $now]);
    $row = $st->fetch();
    $st->closeCursor();
    if (!$row) {
        $pdo->exec('ROLLBACK');
        $pdo->prepare('INSERT INTO enroll_fails (ip, ts) VALUES (?, ?)')->execute([$ip, $now]);
        usleep(600000);
        fail(401, 'That key is wrong, revoked, already used, or has expired.');
    }
    $pdo->prepare('UPDATE enroll_keys SET used = 1, used_ip = ? WHERE id = ?')->execute([$ip, $row['id']]);
    if ($dev !== '') $pdo->prepare('UPDATE routers SET device_id = ? WHERE id = ?')->execute([$dev, $row['router_id']]);
    $pdo->exec('COMMIT');
    json_out(200, ['ok' => true, 'router_id' => (int) $row['router_id'], 'name' => $row['name'], 'token' => $row['token'], 'base' => $base, 'new' => true, 'web_level' => WEB_API_LEVEL]);
} catch (Throwable $t) {
    try { $pdo->exec('ROLLBACK'); } catch (Throwable $e) {}
    fail(503, 'The website is busy. Try again in a moment.');
}
