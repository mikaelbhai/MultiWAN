<?php
// Router enrollment: how a router running the Baytaar software joins this
// website with nothing but the website's name and a one-time key.
//
//   admin:   php cli.php new-key "Router name"        (or POST portal.php/enroll-key)
//            -> a key, shown once
//   router:  sh /usr/lib/mwadmin/connect.sh join <website> <key>
//            -> POST enroll.php {key} -> this router's own token + addresses
//
// The key is single-use, expires, and is stored only as a hash. The router
// then talks to the website with its token (uploads, HTTPS channel). No SSH
// tunnel is needed for a router enrolled this way: every panel call goes
// through the HTTPS channel (relay.php), so no key is ever written into the
// host's authorized_keys by web code.
require_once __DIR__ . '/lib.php';

function enroll_db(): PDO {
    static $ready = false;
    $pdo = db();
    if (!$ready) {
        $ready = true;
        $pdo->exec('CREATE TABLE IF NOT EXISTS enroll_keys (id INTEGER PRIMARY KEY AUTOINCREMENT, key_hash TEXT UNIQUE NOT NULL,
            router_id INTEGER NOT NULL REFERENCES routers(id) ON DELETE CASCADE, created INTEGER NOT NULL,
            expires INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0, used_ip TEXT)');
        $pdo->exec('CREATE TABLE IF NOT EXISTS enroll_fails (ip TEXT NOT NULL, ts INTEGER NOT NULL)');
    }
    return $pdo;
}

// A new router row (with its own token) and a one-time key for it.
// Returns [router_id, key]. The key is never stored, only its hash.
function enroll_new_key(string $name, int $hours = 48): array {
    $pdo = enroll_db();
    $hours = max(1, min(24 * 14, $hours));
    $pdo->exec('BEGIN IMMEDIATE');
    try {
        // routers.tunnel_port must be unique; a router without a tunnel still gets its own slot
        $max = (int) $pdo->query('SELECT COALESCE(MAX(tunnel_port), 22081) FROM routers')->fetchColumn();
        $port = $max + 4;
        $token = bin2hex(random_bytes(32));
        $pdo->prepare('INSERT INTO routers (name, tunnel_port, token) VALUES (?, ?, ?)')->execute([$name, $port, $token]);
        $rid = (int) $pdo->lastInsertId();
        $key = 'bk' . bin2hex(random_bytes(20));
        $pdo->prepare('INSERT INTO enroll_keys (key_hash, router_id, created, expires) VALUES (?, ?, ?, ?)')
            ->execute([hash('sha256', $key), $rid, time(), time() + $hours * 3600]);
        $pdo->exec('COMMIT');
        return [$rid, $key];
    } catch (Throwable $t) {
        $pdo->exec('ROLLBACK');
        throw $t;
    }
}
