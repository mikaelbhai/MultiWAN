<?php
// Router side of the HTTPS fallback channel (see relay_call in lib.php).
//   GET  relay.php?token=T                 wait up to 20 s for queued calls
//   POST relay.php?token=T&id=N&code=..    the answer to call N (raw body)
// The router proves who it is with its portal token. It only ever replays
// calls against its own admin API; nothing else can be asked of it here.
require __DIR__ . '/../portal/lib.php';

$tok = (string) ($_GET['token'] ?? '');
if (!preg_match('/^[a-f0-9]{48,128}$/', $tok)) fail(401, 'Bad token.');
$st = db()->prepare('SELECT id FROM routers WHERE token = ?');
$st->execute([$tok]);
$rid = (int) ($st->fetchColumn() ?: 0);
$st->closeCursor();   // a half-read SELECT would keep a read snapshot open and make later writes fail with "database is locked"
if (!$rid) { usleep(300000); fail(401, 'Unknown router.'); }
$pdo = relay_db();
$seen = $pdo->prepare('INSERT INTO relay_seen (router_id, ts) VALUES (?, ?) ON CONFLICT (router_id) DO UPDATE SET ts = excluded.ts');

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    $id = (int) ($_GET['id'] ?? 0);
    $body = file_get_contents('php://input', false, null, 0, 16 * 1024 * 1024);
    $pdo->prepare('UPDATE relay SET state = \'done\', code = ?, ctype = ?, disp = ?, resp = ? WHERE id = ? AND router_id = ?')
        ->execute([(int) ($_GET['code'] ?? 502), substr((string) ($_GET['ctype'] ?? ''), 0, 100),
                   substr((string) ($_GET['disp'] ?? ''), 0, 200), $body, $id, $rid]);
    $seen->execute([$rid, time()]);
    json_out(200, ['ok' => true]);
}

@set_time_limit(40);
ignore_user_abort(false);
$until = time() + 20;
$take = $pdo->prepare('SELECT id, method, path, body FROM relay WHERE router_id = ? AND state = \'new\' ORDER BY id LIMIT 5');
do {
    $seen->execute([$rid, time()]);
    $take->execute([$rid]);
    $rows = $take->fetchAll();
    if ($rows) {
        $mark = $pdo->prepare('UPDATE relay SET state = \'taken\' WHERE id = ?');
        foreach ($rows as $r) $mark->execute([$r['id']]);
        json_out(200, ['ok' => true, 'calls' => array_map(function ($r) {
            return ['id' => (int) $r['id'], 'method' => $r['method'], 'path' => $r['path'], 'body' => (string) $r['body']];
        }, $rows)]);
    }
    usleep(300000);
} while (time() < $until && !connection_aborted());
json_out(200, ['ok' => true, 'calls' => []]);
