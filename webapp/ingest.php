<?php
// Uploads from routers: their event log and site activity, once a minute or
// in one batch after the internet comes back. The router proves who it is
// with its portal token (the same secret this site uses to reach it).
require __DIR__ . '/../portal/activity_lib.php';

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') fail(405, 'POST only.');
$b = read_json_body(4000000);
$tok = (string) ($b['token'] ?? '');
if (!preg_match('/^[a-f0-9]{48,128}$/', $tok)) fail(401, 'Bad token.');

$pdo = act_db();
$st = $pdo->prepare('SELECT id FROM routers WHERE token = ?');
$st->execute([$tok]);
$r = $st->fetch();
// A half-read SELECT keeps a read snapshot open. If anything else writes to the database before
// this upload does, the upload's own write then fails at once with "database is locked" (found
// 2026-11-25: a failed upload every few minutes, which looked like the router going silent).
$st->closeCursor();
if (!$r) { usleep(300000); fail(401, 'Unknown router.'); }
$rid = (int) $r['id'];

// A router whose clock is off (no time sync yet after a power cut) still
// lands its records at the right time.
$skew = isset($b['now']) ? time() - (int) $b['now'] : 0;
if (abs($skew) < 120) $skew = 0;

$clip = function ($v, int $n): string { return mb_substr(preg_replace('/[\x00-\x1f]/', '', (string) $v), 0, $n); };

// A failed upload used to be a bare HTTP 500 with no trace anywhere, and the router would
// retry blind. Now the reason is written to ingest_errors.log next to the portal code,
// and the router is told to retry (503). The router keeps the upload until one is accepted.
function ingest_log(string $m): void {
    $dir = is_dir(__DIR__ . '/../../portal') ? __DIR__ . '/../../portal' : __DIR__ . '/../portal';
    $f = $dir . '/ingest_errors.log';
    if (is_file($f) && filesize($f) > 200000) @rename($f, $f . '.old');
    @file_put_contents($f, date('Y-m-d H:i:s ') . $m . "\n", FILE_APPEND);
}
$t0 = microtime(true);
for ($attempt = 1; ; $attempt++) {
try {
$pdo->exec('BEGIN IMMEDIATE');     // take the write lock now and wait for it, rather than failing at the first write
$ie = $pdo->prepare('INSERT OR IGNORE INTO events (router_id, ts, kind, sev, msg) VALUES (?, ?, ?, ?, ?)');
$ne = 0;
foreach (array_slice((array) ($b['events'] ?? []), 0, 2000) as $e) {
    if (!is_array($e) || count($e) < 4) continue;
    $ie->execute([$rid, (int) $e[0] + $skew, $clip($e[1], 16), $clip($e[2], 8), $clip($e[3], 400)]);
    $ne++;
}
$iv = $pdo->prepare('INSERT INTO visits (router_id, ts, mac, ip, name, domain, app) VALUES (?, ?, ?, ?, ?, ?, ?)');
$iu = $pdo->prepare('INSERT INTO app_use (router_id, ts, mac, ip, name, app, bytes) VALUES (?, ?, ?, ?, ?, ?, ?)');
$na = 0;
foreach (array_slice((array) ($b['activity'] ?? []), 0, 60000) as $a) {
    if (!is_array($a) || count($a) < 7) continue;
    $ts = (int) $a[1] + $skew;
    $mac = strtolower($clip($a[2], 17)); $ip = $clip($a[3], 45); $name = $clip($a[4], 64); $val = strtolower($clip($a[5], 253));
    if ($a[0] === 'v' && $val !== '') {
        $app = app_of($val);
        $iv->execute([$rid, $ts, $mac, $ip, $name, $val, $app]);
        site_total_add($pdo, $rid, $mac, $val, $app, $name, $ts);
        $na++;
    }
    elseif ($a[0] === 'u')            { $iu->execute([$rid, $ts, $mac, $ip, $name, $clip($a[5], 64), (int) $a[6]]); $na++; }
}
$pdo->prepare('UPDATE routers SET last_seen = ? WHERE id = ?')->execute([time(), $rid]);
$pdo->exec('COMMIT');
break;
} catch (Throwable $t) {
    try { if ($pdo->inTransaction()) $pdo->exec('ROLLBACK'); } catch (Throwable $x) {}
    if ($attempt < 4 && stripos($t->getMessage(), 'locked') !== false) { usleep(250000 * $attempt); continue; }
    ingest_log(sprintf('router %d: %s: %s (at %s:%d) after %.1f s; upload had %d events, %d activity rows',
        $rid, get_class($t), $t->getMessage(), basename($t->getFile()), $t->getLine(), microtime(true) - $t0,
        count((array) ($b['events'] ?? [])), count((array) ($b['activity'] ?? []))));
    fail(503, 'Could not store that upload. The router keeps it and tries again.');
}
}
if (microtime(true) - $t0 > 10) ingest_log(sprintf('router %d: slow upload, %.1f s (%d events, %d activity rows)', $rid, microtime(true) - $t0, $ne, $na));
if (random_int(1, 300) === 1) act_prune($pdo);

// keep the outage watcher running (the host has no scheduled jobs)
require_once is_file(__DIR__ . '/../portal/alerts_lib.php') ? __DIR__ . '/../portal/alerts_lib.php' : __DIR__ . '/../../portal/alerts_lib.php';
alertd_ensure();

json_out(200, ['ok' => true, 'events' => $ne, 'activity' => $na]);
