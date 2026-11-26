<?php
// Settings shared between the routers of one location (docs/12).
//
// The main router (Router 1) is the brain: it sends the "policy" (settings and decisions), and takes in the
// "reports" of the routers that follow it. A following router (Router 2) takes the policy and sends its report.
// The website decides which router is which (portal.php /location-save); a router never has to be told.
//
//   GET  policy.php?have=<policy md5>&rhave=<reports md5>   -> {ok, role, version, newer, reports_version, reports_newer}
//   POST policy.php?kind=policy&version=<md5>  (body = text)   main router only
//   POST policy.php?kind=report&version=<md5>  (body = text)   following routers only
//   GET  policy.php?body=policy    the stored policy, for a following router
//   GET  policy.php?body=reports   every following router's report joined, for the main router
//
// The router proves who it is with its portal token, in the X-Router-Token header (not in the address, so it
// is not written to access logs). Bundles are plain text, never executed; the checksum is verified on arrival.
require __DIR__ . '/../portal/lib.php';

$tok = (string) ($_SERVER['HTTP_X_ROUTER_TOKEN'] ?? '');
if (!preg_match('/^[a-f0-9]{48,128}$/', $tok)) fail(401, 'Bad token.');

$pdo = db();
$st = $pdo->prepare('SELECT id, location_id, role, name FROM routers WHERE token = ?');
$st->execute([$tok]);
$r = one($st);
if (!$r) { usleep(300000); fail(401, 'Unknown router.'); }
$rid = (int) $r['id'];
$loc = (int) ($r['location_id'] ?? 0);
$role = ($loc > 0 && in_array($r['role'], ['main', 'branch'], true)) ? $r['role'] : 'none';

const POLICY_MAX = 400000;

// every following router's report joined, in a fixed order, and its checksum
function reports_joined(PDO $pdo, int $loc): string {
    $st = $pdo->prepare("SELECT rp.body FROM reports rp JOIN routers r ON r.id = rp.router_id
                         WHERE r.location_id = ? AND r.role = 'branch' ORDER BY r.id");
    $st->execute([$loc]);
    $out = '';
    foreach ($st->fetchAll(PDO::FETCH_COLUMN) as $b) $out .= rtrim((string) $b, "\n") . "\n";
    return $out;
}

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

if ($method === 'POST') {
    $kind = (string) ($_GET['kind'] ?? '');
    $ver = (string) ($_GET['version'] ?? '');
    if ($kind === 'archive_ack') {
        // the main router has a day on its USB drive: the copy waiting here can go (its own, or a router of its location)
        $day = (string) ($_GET['day'] ?? ''); $of = (int) ($_GET['router'] ?? 0);
        if (!preg_match('/^20\d{6}$/', $day)) fail(400, 'Bad day.');
        $ok = $of === $rid;
        if (!$ok && $role === 'main') { $q = $pdo->prepare('SELECT 1 FROM routers WHERE id = ? AND location_id = ?'); $q->execute([$of, $loc]); $ok = (bool) one($q); }
        if (!$ok) fail(403, 'Not a router of this location.');
        db_retry(function () use ($pdo, $of, $day) { $pdo->prepare('DELETE FROM archives WHERE router_id = ? AND day = ?')->execute([$of, $day]); });
        json_out(200, ['ok' => true, 'deleted' => true]);
    }
    if (!preg_match('/^[a-f0-9]{32}$/', $ver)) fail(400, 'Bad version.');
    $body = file_get_contents('php://input', false, null, 0, POLICY_MAX + 1);
    if ($body === false || strlen($body) > POLICY_MAX) fail(413, 'Too large.');
    if (md5($body) !== $ver) fail(400, 'The checksum does not match.');
    $want = $kind === 'policy' ? "# baytaar-policy 2\n" : ($kind === 'archive' ? '# baytaar-archive 1 ' : "# baytaar-report 1\n");
    if ($kind === 'archive_ack') $want = '';
    if (strncmp($body, $want, strlen($want)) !== 0 || substr($body, -5) !== "@end\n") fail(400, 'Not a bundle this website understands.');

    if ($kind === 'policy' && $role === 'main') {
        db_retry(function () use ($pdo, $loc, $ver, $body, $rid) {
            $pdo->prepare('INSERT INTO policy (location_id, version, body, updated, from_router) VALUES (?, ?, ?, ?, ?)
                           ON CONFLICT(location_id) DO UPDATE SET version = excluded.version, body = excluded.body,
                           updated = excluded.updated, from_router = excluded.from_router')
                ->execute([$loc, $ver, $body, time(), $rid]);
        });
        json_out(200, ['ok' => true, 'role' => $role, 'stored' => true]);
    }
    if ($kind === 'archive') {
        // a day of this router's devices, lists and logs, kept until the main router has it on its USB drive
        $day = (string) ($_GET['day'] ?? '');
        if (!preg_match('/^20\d{6}$/', $day) || strpos($body, '# baytaar-archive 1 ' . $day . "\n") !== 0) fail(400, 'Bad day.');
        db_retry(function () use ($pdo, $rid, $day, $ver, $body) {
            $pdo->prepare('INSERT INTO archives (router_id, day, version, body, updated) VALUES (?, ?, ?, ?, ?)
                           ON CONFLICT(router_id, day) DO UPDATE SET version = excluded.version, body = excluded.body, updated = excluded.updated')
                ->execute([$rid, $day, $ver, $body, time()]);
            $pdo->prepare('DELETE FROM archives WHERE updated < ?')->execute([time() - 60 * 86400]);    // nothing waits here for ever
        });
        json_out(200, ['ok' => true, 'role' => $role, 'stored' => true]);
    }
    if ($kind === 'report' && $role === 'branch') {
        db_retry(function () use ($pdo, $rid, $ver, $body) {
            $pdo->prepare('INSERT INTO reports (router_id, version, body, updated) VALUES (?, ?, ?, ?)
                           ON CONFLICT(router_id) DO UPDATE SET version = excluded.version, body = excluded.body, updated = excluded.updated')
                ->execute([$rid, $ver, $body, time()]);
        });
        json_out(200, ['ok' => true, 'role' => $role, 'stored' => true]);
    }
    json_out(200, ['ok' => true, 'role' => $role, 'stored' => false]);     // not this router's job
}

// ---- GET ----
$what = (string) ($_GET['body'] ?? '');
if ($what === 'policy' && $role !== 'none') {
    $q = $pdo->prepare('SELECT body FROM policy WHERE location_id = ?'); $q->execute([$loc]);
    $row = one($q);
    if (!$row) fail(404, 'Nothing stored yet.');
    header('Content-Type: text/plain; charset=utf-8'); header('Cache-Control: no-store'); header('X-Content-Type-Options: nosniff');
    echo $row['body']; exit;
}
if ($what === 'reports' && $role === 'main') {
    header('Content-Type: text/plain; charset=utf-8'); header('Cache-Control: no-store'); header('X-Content-Type-Options: nosniff');
    echo reports_joined($pdo, $loc); exit;
}
if ($what !== '') fail(404, 'Nothing for this router.');

// backups waiting for the main router's USB drive: its own and those of its location's other routers
function archive_routers(PDO $pdo, int $rid, int $loc): array {
    if (!$loc) return [$rid];
    $q = $pdo->prepare('SELECT id FROM routers WHERE location_id = ?'); $q->execute([$loc]);
    return array_map('intval', $q->fetchAll(PDO::FETCH_COLUMN));
}
if (isset($_GET['archives'])) {
    if ($role !== 'main') json_out(200, ['ok' => true, 'archives' => []]);
    $ids = archive_routers($pdo, $rid, $loc);
    $in = implode(',', array_fill(0, count($ids), '?'));
    $q = $pdo->prepare("SELECT a.router_id, r.name AS router, a.day, a.version FROM archives a JOIN routers r ON r.id = a.router_id
                        WHERE a.router_id IN ($in) ORDER BY a.day, a.router_id LIMIT 100");
    $q->execute($ids);
    $list = array_map(function ($x) { return ['router_id' => (int) $x['router_id'], 'router' => $x['router'], 'day' => $x['day'], 'version' => $x['version']]; }, $q->fetchAll());
    json_out(200, ['ok' => true, 'archives' => $list]);
}
if (isset($_GET['archive'])) {
    $of = (int) $_GET['archive']; $day = (string) ($_GET['day'] ?? '');
    if ($role !== 'main' || !in_array($of, archive_routers($pdo, $rid, $loc), true)) fail(403, 'Not a router of this location.');
    $q = $pdo->prepare('SELECT body FROM archives WHERE router_id = ? AND day = ?'); $q->execute([$of, $day]);
    $row = one($q);
    if (!$row) fail(404, 'No such day.');
    header('Content-Type: text/plain; charset=utf-8'); header('Cache-Control: no-store'); header('X-Content-Type-Options: nosniff');
    echo $row['body']; exit;
}

$out = ['ok' => true, 'role' => $role, 'name' => $r['name']];
if ($role !== 'none') {
    $q = $pdo->prepare('SELECT version, updated FROM policy WHERE location_id = ?'); $q->execute([$loc]);
    $p = one($q);
    $out['version'] = $p ? $p['version'] : null;
    $have = (string) ($_GET['have'] ?? '');
    $out['newer'] = $role === 'branch' && $p && $p['version'] !== $have;
    if ($role === 'main') {
        $joined = reports_joined($pdo, $loc);
        $out['reports_version'] = $joined === '' ? null : md5($joined);
        $out['reports_newer'] = $joined !== '' && md5($joined) !== (string) ($_GET['rhave'] ?? '');
    }
}
json_out(200, $out);
