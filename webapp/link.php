<?php
// "Sign in with your browser" for the Windows router installer (no key to copy).
//
//   POST link.php {action: "start"}            -> {ok, code, secret, url, expires_in}
//        the installer shows the code and opens url (this website, #link=CODE) in the browser
//   the person signs in there and presses Connect (portal.php /link-approve, checks the code is theirs to approve)
//   POST link.php {action: "poll", secret}     -> {ok, state: waiting | approved | expired, key?, account?}
//        once approved, the installer gets a NEW API key, valid 24 hours, exactly once; it then joins routers with it
//
// The secret never leaves the installer; the code alone cannot fetch the key. Codes live 10 minutes. Starts are
// limited per address. The key is kept in the table only between approval and the installer's next poll.
require __DIR__ . '/../portal/lib.php';

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') fail(405, 'POST only.');
$https = (($_SERVER['HTTPS'] ?? '') !== '' && ($_SERVER['HTTPS'] ?? '') !== 'off') || ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';
if (!$https) fail(400, 'Use https.');
$b = read_json_body(2048);
$pdo = db();
$now = time();
$pdo->prepare('DELETE FROM link_requests WHERE expires < ?')->execute([$now - 3600]);

if (($b['action'] ?? '') === 'start') {
    $ip = client_ip();
    $st = $pdo->prepare('SELECT COUNT(*) FROM link_requests WHERE ip = ? AND created > ?'); $st->execute([$ip, $now - 3600]);
    $n = (int) $st->fetchColumn(); $st->closeCursor();
    if ($n >= 20) fail(429, 'Too many sign-in attempts from here. Try again in an hour.');
    $alpha = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';      // no 0/O, 1/I: easy to compare by eye
    $code = '';
    for ($i = 0; $i < 8; $i++) $code .= $alpha[random_int(0, strlen($alpha) - 1)];
    $secret = bin2hex(random_bytes(24));
    db_retry(function () use ($pdo, $code, $secret, $now, $ip) {
        $pdo->prepare('INSERT INTO link_requests (code, secret_hash, created, expires, ip) VALUES (?, ?, ?, ?, ?)')
            ->execute([$code, hash('sha256', $secret), $now, $now + 600, $ip]);
    });
    $host = strtolower(explode(':', $_SERVER['HTTP_HOST'] ?? '')[0]);
    $dir = rtrim(str_replace('\\', '/', dirname($_SERVER['SCRIPT_NAME'] ?? '/')), '/');
    json_out(200, ['ok' => true, 'code' => substr($code, 0, 4) . '-' . substr($code, 4), 'secret' => $secret,
                   'url' => 'https://' . $host . $dir . '/#link=' . $code, 'expires_in' => 600]);
}

if (($b['action'] ?? '') === 'poll') {
    $secret = (string) ($b['secret'] ?? '');
    if (!preg_match('/^[a-f0-9]{48}$/', $secret)) fail(400, 'Bad request.');
    $st = $pdo->prepare('SELECT * FROM link_requests WHERE secret_hash = ?'); $st->execute([hash('sha256', $secret)]);
    $r = one($st);
    if (!$r || $r['delivered']) json_out(200, ['ok' => true, 'state' => 'expired']);
    if ($r['approved'] && $r['key_plain']) {
        $uq = $pdo->prepare('SELECT email FROM users WHERE id = ?'); $uq->execute([(int) $r['user_id']]);
        $e = (string) (one($uq)['email'] ?? ''); $at = strpos($e, '@');
        $key = $r['key_plain'];
        db_retry(function () use ($pdo, $r) {
            $pdo->prepare('UPDATE link_requests SET key_plain = NULL, delivered = 1 WHERE code = ?')->execute([$r['code']]);
        });
        json_out(200, ['ok' => true, 'state' => 'approved', 'key' => $key,
                       'account' => substr($e, 0, 1) . '...' . ($at !== false ? substr($e, $at) : '')]);
    }
    if ((int) $r['expires'] < $now) json_out(200, ['ok' => true, 'state' => 'expired']);
    json_out(200, ['ok' => true, 'state' => 'waiting']);
}

fail(400, 'Unknown action.');
