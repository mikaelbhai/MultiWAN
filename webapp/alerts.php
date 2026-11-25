<?php
// Outage alerts for the Baytaar phone app.
//
//   POST alerts.php/register   (signed in on the website: bt_session cookie)
//                              -> {token}: this phone's own key for alerts
//   POST alerts.php/push       {token, fcm}  this phone's Firebase push token:
//                              from now on alerts are pushed to it by Google
//   POST alerts.php/poll       {token, after, wait}  (phones without push)
//                              waits up to `wait` s for new alerts after id
//                              `after`; -1 means "just tell me the newest id"
//   POST alerts.php/test       {token}   sends a test alert to this account
//   POST alerts.php/unregister {token}
//
// How alerts are made and pushed: portal/alerts_lib.php.
// the portal code lives outside the web root: one level up here, two on the host
require is_file(__DIR__ . '/../portal/alerts_lib.php') ? __DIR__ . '/../portal/alerts_lib.php' : __DIR__ . '/../../portal/alerts_lib.php';

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$route  = $_SERVER['PATH_INFO'] ?? '';
if ($route === '') {
    $uri = strtok($_SERVER['REQUEST_URI'] ?? '', '?');
    $pos = strpos($uri, 'alerts.php');
    $route = $pos === false ? '' : substr($uri, $pos + 10);
}
if ($method !== 'POST') fail(405, 'POST only.');
require_same_origin();
al_db();   // tables exist before anything else looks at them
alertd_ensure();
$b = read_json_body(4096);

if ($route === '/register') {
    $u = require_user();   // the website session the app's sign-in created
    $tok = bin2hex(random_bytes(32));
    $label = mb_substr(preg_replace('/[\x00-\x1f]/', '', (string) ($b['label'] ?? 'Phone')), 0, 60);
    al_db()->prepare('INSERT INTO app_devices (token_hash, user_id, label, created, last_seen) VALUES (?, ?, ?, ?, ?)')
        ->execute([hash('sha256', $tok), $u['id'], $label, time(), time()]);
    json_out(200, ['ok' => true, 'token' => $tok, 'email' => $u['email'], 'last' => newest_id()]);
}

$tok = (string) ($b['token'] ?? '');
$u = token_user($tok);
if (!$u) { usleep(300000); fail(401, 'This phone is not signed up for alerts.'); }
$pdo = al_db();
$pdo->prepare('UPDATE app_devices SET last_seen = ? WHERE token_hash = ?')->execute([time(), hash('sha256', $tok)]);
$routers = routers_of($u);

switch ($route) {
    case '/poll':
        $after = (int) ($b['after'] ?? -1);
        $wait = max(0, min(50, (int) ($b['wait'] ?? 25)));
        set_time_limit($wait + 30);
        if ($after < 0) {   // a phone starting fresh: newest id only, no old news
            watch_routers($routers);
            json_out(200, ['ok' => true, 'alerts' => [], 'last' => newest_id(), 'routers' => router_status($routers)]);
        }
        $end = time() + $wait;
        $nextWatch = 0;
        do {
            if (time() >= $nextWatch) { watch_routers($routers); $nextWatch = time() + 10; }
            $list = alerts_for($u, $routers, $after);
            if ($list) break;
            if (connection_aborted()) exit;
            sleep(2);
        } while (time() < $end);
        $last = $list ? end($list)['id'] : $after;
        json_out(200, ['ok' => true, 'alerts' => $list, 'last' => $last, 'routers' => router_status($routers)]);

    case '/push':
        $fcm = (string) ($b['fcm'] ?? '');
        if (!fcm_ready()) fail(503, 'Push is not set up on the website yet.');
        if (!preg_match('/^[A-Za-z0-9:_-]{100,400}$/', $fcm)) fail(400, 'That is not a push token.');
        // the same phone signed up again: the old key stops getting pushes
        $pdo->prepare('UPDATE app_devices SET fcm = NULL WHERE fcm = ? AND token_hash != ?')->execute([$fcm, hash('sha256', $tok)]);
        $pdo->prepare('UPDATE app_devices SET fcm = ?, pushed_id = MAX(pushed_id, ?) WHERE token_hash = ?')
            ->execute([$fcm, newest_id(), hash('sha256', $tok)]);
        json_out(200, ['ok' => true]);

    case '/test':
        add_alert($pdo, null, (int) $u['id'], 'test', 'Test alert',
            'Outage alerts work on this phone. You will hear about lines going down, power cuts and the router going offline.');
        dispatch_pushes();
        json_out(200, ['ok' => true, 'message' => 'Test alert sent. It should arrive in a few seconds.']);

    case '/unregister':
        $pdo->prepare('DELETE FROM app_devices WHERE token_hash = ?')->execute([hash('sha256', $tok)]);
        json_out(200, ['ok' => true]);
}
fail(404, 'No such endpoint.');
