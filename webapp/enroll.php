<?php
// A router joins this website with a one-time key (see portal/enroll_lib.php).
//
//   POST enroll.php   {key, hostname?, board?, version?}
//     -> {ok, router_id, name, token, base}     the router stores token and base
//
// Public on purpose (the router has no account), so it is strict: one key,
// used once, expiring, stored hashed, and wrong keys are rate-limited per
// address. The answer carries the router's secret token, so it is only given
// over HTTPS.
require __DIR__ . '/../portal/enroll_lib.php';

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') fail(405, 'POST only.');
$https = (($_SERVER['HTTPS'] ?? '') !== '' && ($_SERVER['HTTPS'] ?? '') !== 'off') || ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';
if (!$https) fail(400, 'Use https.');
$b = read_json_body(4096);
$key = (string) ($b['key'] ?? '');
if (!preg_match('/^[A-Za-z0-9_-]{16,80}$/', $key)) fail(400, 'That key does not look right.');

$pdo = enroll_db();
$ip = client_ip();
$now = time();
$pdo->prepare('DELETE FROM enroll_fails WHERE ts < ?')->execute([$now - 900]);
$st = $pdo->prepare('SELECT COUNT(*) FROM enroll_fails WHERE ip = ?');
$st->execute([$ip]);
if ((int) $st->fetchColumn() >= 8) fail(429, 'Too many wrong keys. Try again in 15 minutes.');

$pdo->exec('BEGIN IMMEDIATE');
$st = $pdo->prepare('SELECT k.id, k.router_id, r.name, r.token FROM enroll_keys k JOIN routers r ON r.id = k.router_id
                     WHERE k.key_hash = ? AND k.used = 0 AND k.expires > ?');
$st->execute([hash('sha256', $key), $now]);
$row = $st->fetch();
if (!$row) {
    $pdo->exec('ROLLBACK');
    $pdo->prepare('INSERT INTO enroll_fails (ip, ts) VALUES (?, ?)')->execute([$ip, $now]);
    usleep(600000);
    fail(401, 'That key is wrong, already used, or has expired.');
}
$pdo->prepare('UPDATE enroll_keys SET used = 1, used_ip = ? WHERE id = ?')->execute([$ip, $row['id']]);
$pdo->exec('COMMIT');

$host = strtolower(explode(':', $_SERVER['HTTP_HOST'] ?? '')[0]);
if (!preg_match('/^[a-z0-9.-]{3,253}$/', $host)) fail(400, 'Bad host.');
$dir = rtrim(str_replace('\\', '/', dirname($_SERVER['SCRIPT_NAME'] ?? '/')), '/');
json_out(200, ['ok' => true, 'router_id' => (int) $row['router_id'], 'name' => $row['name'],
               'token' => $row['token'], 'base' => 'https://' . $host . $dir . '/']);
