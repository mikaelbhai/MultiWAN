<?php
// Baytaar portal — shared library. Lives OUTSIDE the web root; the public
// scripts (portal.php, api.php) include it. Holds the account database:
// who can log in, which routers exist, and who is assigned to which router.

const DB_FILE        = __DIR__ . '/portal.sqlite';
const COOKIE         = 'bt_session';
const SESSION_HOURS  = 24 * 14;
const MAX_FAILS      = 8;      // failed logins per address ...
const FAIL_WINDOW    = 900;    // ... within this many seconds

function db(): PDO {
    static $pdo = null;
    if ($pdo) return $pdo;
    $pdo = new PDO('sqlite:' . DB_FILE, null, null, [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
    $pdo->exec('PRAGMA journal_mode = WAL');
    $pdo->exec('PRAGMA busy_timeout = 4000');
    $pdo->exec('PRAGMA foreign_keys = ON');
    $pdo->exec('CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL, pass_hash TEXT NOT NULL,
        is_admin INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL)');
    $pdo->exec('CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        expires INTEGER NOT NULL)');
    // tunnel_port: the loopback port this router\'s outbound tunnel lands on.
    // token: the router\'s portal token (/etc/mwadmin/portal_token on the router).
    $pdo->exec('CREATE TABLE IF NOT EXISTS routers (
        id INTEGER PRIMARY KEY, name TEXT NOT NULL, tunnel_port INTEGER UNIQUE NOT NULL,
        token TEXT NOT NULL, last_seen INTEGER, last_state TEXT)');
    $pdo->exec('CREATE TABLE IF NOT EXISTS user_routers (
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        router_id INTEGER NOT NULL REFERENCES routers(id) ON DELETE CASCADE,
        PRIMARY KEY (user_id, router_id))');
    $pdo->exec('CREATE TABLE IF NOT EXISTS login_fails (ip TEXT NOT NULL, ts INTEGER NOT NULL)');
    return $pdo;
}

function json_out(int $code, array $data): void {
    http_response_code($code);
    header('Content-Type: application/json');
    header('Cache-Control: no-store, no-cache, must-revalidate');
    header('X-Content-Type-Options: nosniff');
    echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function fail(int $code, string $msg): void {
    json_out($code, ['ok' => false, 'error' => $msg]);
}

function client_ip(): string {
    return $_SERVER['REMOTE_ADDR'] ?? 'unknown';
}

// Cross-site request forgery: the session cookie is SameSite=Strict, and on
// top of that any state-changing request must come from this site itself.
function require_same_origin(): void {
    $origin = $_SERVER['HTTP_ORIGIN'] ?? '';
    if ($origin === '') return;                    // same-origin GETs and non-browser clients
    $host = parse_url($origin, PHP_URL_HOST);
    $mine = strtolower(explode(':', $_SERVER['HTTP_HOST'] ?? '')[0]);
    if (strtolower((string) $host) !== $mine) fail(403, 'Cross-site request refused.');
}

function read_json_body(int $max = 262144): array {
    $raw = file_get_contents('php://input', false, null, 0, $max + 1);
    if ($raw === false || strlen($raw) > $max) fail(413, 'Request body too large.');
    if ($raw === '') return [];
    $j = json_decode($raw, true);
    if (!is_array($j)) fail(400, 'Malformed request.');
    return $j;
}

function current_user(): ?array {
    $tok = $_COOKIE[COOKIE] ?? '';
    if (!preg_match('/^[a-f0-9]{64}$/', $tok)) return null;
    $st = db()->prepare('SELECT u.id, u.email, u.is_admin FROM sessions s JOIN users u ON u.id = s.user_id
                         WHERE s.token_hash = ? AND s.expires > ?');
    $st->execute([hash('sha256', $tok), time()]);
    return $st->fetch() ?: null;
}

function require_user(): array {
    $u = current_user();
    if (!$u) fail(401, 'Not signed in.');
    return $u;
}

function set_session_cookie(string $value, int $expires): void {
    setcookie(COOKIE, $value, [
        'expires'  => $expires,
        'path'     => '/',
        'secure'   => true,
        'httponly' => true,
        'samesite' => 'Strict',
    ]);
}

function login(string $email, string $password): array {
    $pdo = db();
    $ip = client_ip();
    $pdo->prepare('DELETE FROM login_fails WHERE ts < ?')->execute([time() - FAIL_WINDOW]);
    $st = $pdo->prepare('SELECT COUNT(*) c FROM login_fails WHERE ip = ?');
    $st->execute([$ip]);
    if ((int) $st->fetch()['c'] >= MAX_FAILS) fail(429, 'Too many failed attempts. Try again in 15 minutes.');

    $st = $pdo->prepare('SELECT * FROM users WHERE email = ?');
    $st->execute([strtolower(trim($email))]);
    $u = $st->fetch();
    // Do the same amount of hashing work when the account does not exist, so
    // a wrong email and a wrong password take the same time to answer.
    $good = false;
    if ($u) $good = password_verify($password, $u['pass_hash']);
    else    password_hash($password, PASSWORD_BCRYPT, ['cost' => 12]);
    if (!$good) {
        $pdo->prepare('INSERT INTO login_fails (ip, ts) VALUES (?, ?)')->execute([$ip, time()]);
        usleep(600000);
        fail(401, 'Wrong email or password.');
    }
    $tok = bin2hex(random_bytes(32));
    $exp = time() + SESSION_HOURS * 3600;
    $pdo->prepare('DELETE FROM sessions WHERE expires < ?')->execute([time()]);
    $pdo->prepare('INSERT INTO sessions (token_hash, user_id, expires) VALUES (?, ?, ?)')
        ->execute([hash('sha256', $tok), $u['id'], $exp]);
    set_session_cookie($tok, $exp);
    return ['id' => $u['id'], 'email' => $u['email'], 'is_admin' => (int) $u['is_admin']];
}

function logout(): void {
    $tok = $_COOKIE[COOKIE] ?? '';
    if (preg_match('/^[a-f0-9]{64}$/', $tok)) {
        db()->prepare('DELETE FROM sessions WHERE token_hash = ?')->execute([hash('sha256', $tok)]);
    }
    set_session_cookie('', time() - 3600);
}

// The router row, but only if this user is assigned to it.
function router_for(array $user, int $routerId): ?array {
    $st = db()->prepare('SELECT r.* FROM routers r JOIN user_routers ur ON ur.router_id = r.id
                         WHERE r.id = ? AND ur.user_id = ?');
    $st->execute([$routerId, $user['id']]);
    return $st->fetch() ?: null;
}

function routers_of(array $user): array {
    $st = db()->prepare('SELECT r.* FROM routers r JOIN user_routers ur ON ur.router_id = r.id
                         WHERE ur.user_id = ? ORDER BY r.name');
    $st->execute([$user['id']]);
    return $st->fetchAll();
}

// One call down a router's tunnel. Returns [httpCode, contentType, body, disposition]
// or null when the tunnel is not connected (router offline).
// Is the SSH tunnel to this router really answering? A tunnel whose router
// end vanished can leave its port open here, accepting and then hanging, so
// this asks for /ping with a short limit. Remembered for this request.
function tunnel_ok(int $port): bool {
    static $seen = [];
    if (isset($seen[$port])) return $seen[$port];
    $ch = curl_init('http://127.0.0.1:' . $port . '/cgi-bin/mwadmin/ping');
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 2, CURLOPT_TIMEOUT => 3, CURLOPT_PROXY => '']);
    $r = curl_exec($ch);
    curl_close($ch);
    return $seen[$port] = (is_string($r) && strpos($r, '"ok":true') !== false);
}

// The router uses port pair tunnel_port (+1 SSH) or, when the server still
// holds that pair from an old session, tunnel_port + 2 (+3 SSH).
function tunnel_port(array $router): int {
    $p = (int) $router['tunnel_port'];
    if (tunnel_ok($p)) return $p;
    if (tunnel_ok($p + 2)) return $p + 2;
    return 0;
}

function router_call(array $router, string $route, string $method = 'GET',
                     string $query = '', ?array $body = null, int $timeout = 130): ?array {
    $tp = tunnel_port($router);
    $base = 'http://127.0.0.1:' . ($tp ?: (int) $router['tunnel_port']) . '/cgi-bin/mwadmin' . $route;
    $headers = ['Expect:'];
    $ch = curl_init();
    if ($method === 'POST') {
        $body = $body ?? [];
        unset($body['_csrf']);
        $body['_portal'] = $router['token'];
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
        $headers[] = 'Content-Type: application/json';
        $url = $base . ($query !== '' ? '?' . $query : '');
    } else {
        $url = $base . '?' . ($query !== '' ? $query . '&' : '') . '_portal=' . $router['token'];
    }
    curl_setopt_array($ch, [
        CURLOPT_URL            => $url,
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HEADER         => true,
        CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_CONNECTTIMEOUT => 4,
        CURLOPT_TIMEOUT        => $timeout,
        CURLOPT_PROXY          => '',
    ]);
    $resp = $tp ? curl_exec($ch) : false;
    if ($resp === false) {
        curl_close($ch);
        // The SSH tunnel is not connected (some networks block port 22).
        // Fall back to the router's HTTPS channel, if it has checked in lately.
        $path = '/cgi-bin/mwadmin' . $route . '?' . parse_url($url, PHP_URL_QUERY);
        return relay_call((int) $router['id'], $method, $path, $method === 'POST' ? json_encode($body) : '', $timeout);
    }
    $code  = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    $hsize = (int) curl_getinfo($ch, CURLINFO_HEADER_SIZE);
    curl_close($ch);
    $ctype = 'application/json'; $disp = '';
    foreach (explode("\r\n", substr($resp, 0, $hsize)) as $line) {
        if (stripos($line, 'Content-Type:') === 0)        $ctype = trim(substr($line, 13));
        if (stripos($line, 'Content-Disposition:') === 0) $disp  = trim(substr($line, 20));
    }
    return [$code, $ctype, substr($resp, $hsize), $disp];
}

// Strip anything a browser must not be able to choose for itself.
function clean_query(string $qs): string {
    parse_str($qs, $q);
    unset($q['_portal'], $q['session']);
    return http_build_query($q);
}


// ---------------------------------------------------------------------------
// HTTPS fallback channel. The router keeps one HTTPS request open to
// relay.php; a call that cannot go through the SSH tunnel is queued here,
// handed to the router on that request, and its answer posted back.
function relay_db(): PDO {
    static $ready = false;
    $pdo = db();
    if (!$ready) {
        $ready = true;
        $pdo->exec('CREATE TABLE IF NOT EXISTS relay (id INTEGER PRIMARY KEY AUTOINCREMENT, router_id INTEGER NOT NULL,
            created INTEGER NOT NULL, method TEXT, path TEXT, body BLOB, state TEXT NOT NULL DEFAULT \'new\',
            code INTEGER, ctype TEXT, disp TEXT, resp BLOB)');
        $pdo->exec('CREATE TABLE IF NOT EXISTS relay_seen (router_id INTEGER PRIMARY KEY, ts INTEGER NOT NULL)');
    }
    return $pdo;
}

function relay_alive(int $routerId): int {
    $st = relay_db()->prepare('SELECT ts FROM relay_seen WHERE router_id = ?');
    $st->execute([$routerId]);
    return (int) ($st->fetchColumn() ?: 0);
}

function relay_call(int $routerId, string $method, string $path, string $body, int $timeout): ?array {
    if (relay_alive($routerId) < time() - 75) return null;      // router is not polling: offline
    $pdo = relay_db();
    $pdo->prepare('DELETE FROM relay WHERE created < ?')->execute([time() - 600]);
    $pdo->prepare('INSERT INTO relay (router_id, created, method, path, body) VALUES (?, ?, ?, ?, ?)')
        ->execute([$routerId, time(), $method, $path, $body]);
    $id = (int) $pdo->lastInsertId();
    $until = microtime(true) + min($timeout, 40);
    $st = $pdo->prepare('SELECT state, code, ctype, disp, resp FROM relay WHERE id = ?');
    while (microtime(true) < $until) {
        usleep(250000);
        $st->execute([$id]);
        $r = $st->fetch();
        if ($r && $r['state'] === 'done') {
            $pdo->prepare('DELETE FROM relay WHERE id = ?')->execute([$id]);
            return [(int) $r['code'], $r['ctype'] ?: 'application/json', (string) $r['resp'], (string) $r['disp']];
        }
    }
    $pdo->prepare('DELETE FROM relay WHERE id = ?')->execute([$id]);
    return null;
}
