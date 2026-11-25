<?php
// Account management, run on the server from a shell (never over the web):
//
//   php cli.php add-user  <email> <password|-> [admin]   (- asks for it)
//   php cli.php passwd    <email> <new-password>
//   php cli.php del-user  <email>
//   php cli.php add-router <name> <tunnel-port> <portal-token>
//   php cli.php assign    <email> <router-id>
//   php cli.php unassign  <email> <router-id>
//   php cli.php list
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require __DIR__ . '/lib.php';
$a = $argv; array_shift($a);
$cmd = array_shift($a) ?? '';
$pdo = db();

function uid(PDO $pdo, string $email): int {
    $st = $pdo->prepare('SELECT id FROM users WHERE email = ?');
    $st->execute([strtolower($email)]);
    $r = $st->fetch();
    if (!$r) { fwrite(STDERR, "no such user: $email\n"); exit(1); }
    return (int) $r['id'];
}

// Read a password without echoing it (use "-" in place of the password).
function ask_password(): string {
    fwrite(STDOUT, 'Password: ');  system('stty -echo');  $p = trim((string) fgets(STDIN));
    fwrite(STDOUT, "\nAgain: ");   $q = trim((string) fgets(STDIN));  system('stty echo');  fwrite(STDOUT, "\n");
    if ($p !== $q) { fwrite(STDERR, "passwords do not match\n"); exit(1); }
    return $p;
}

switch ($cmd) {
    case 'add-user':
        [$email, $pw] = [$a[0] ?? '', $a[1] ?? ''];
        if ($pw === '-') $pw = ask_password();
        if (!filter_var($email, FILTER_VALIDATE_EMAIL) || strlen($pw) < 10) { fwrite(STDERR, "need a valid email and a password of 10+ characters\n"); exit(1); }
        $pdo->prepare('INSERT INTO users (email, pass_hash, is_admin, created) VALUES (?, ?, ?, ?)
                       ON CONFLICT(email) DO UPDATE SET pass_hash = excluded.pass_hash, is_admin = excluded.is_admin')
            ->execute([strtolower($email), password_hash($pw, PASSWORD_BCRYPT, ['cost' => 12]), ($a[2] ?? '') === 'admin' ? 1 : 0, time()]);
        echo "user saved: $email\n"; break;
    case 'passwd':
        $id = uid($pdo, $a[0] ?? '');
        if (($a[1] ?? '') === '-') $a[1] = ask_password();
        if (strlen($a[1] ?? '') < 10) { fwrite(STDERR, "password must be 10+ characters\n"); exit(1); }
        $pdo->prepare('UPDATE users SET pass_hash = ? WHERE id = ?')->execute([password_hash($a[1], PASSWORD_BCRYPT, ['cost' => 12]), $id]);
        $pdo->prepare('DELETE FROM sessions WHERE user_id = ?')->execute([$id]);
        echo "password changed, existing sessions signed out\n"; break;
    case 'del-user':
        $pdo->prepare('DELETE FROM users WHERE id = ?')->execute([uid($pdo, $a[0] ?? '')]);
        echo "deleted\n"; break;
    case 'add-router':
        if (!preg_match('/^[a-f0-9]{48,128}$/', $a[2] ?? '') || (int) ($a[1] ?? 0) < 1024) { fwrite(STDERR, "usage: add-router <name> <tunnel-port> <portal-token>\n"); exit(1); }
        $pdo->prepare('INSERT INTO routers (name, tunnel_port, token) VALUES (?, ?, ?)
                       ON CONFLICT(tunnel_port) DO UPDATE SET name = excluded.name, token = excluded.token')
            ->execute([$a[0], (int) $a[1], $a[2]]);
        $st = $pdo->prepare('SELECT id FROM routers WHERE tunnel_port = ?'); $st->execute([(int) $a[1]]);
        echo "router saved, id " . $st->fetch()['id'] . "\n"; break;
    case 'new-key':
        // a router that has the Baytaar software joins with just the website name + this key
        require __DIR__ . '/enroll_lib.php';
        $nm = trim((string) ($a[0] ?? ''));
        if ($nm === '') { fwrite(STDERR, "usage: new-key <router name> [hours, default 48]\n"); exit(1); }
        [$rid, $key] = enroll_new_key($nm, (int) ($a[1] ?? 48));
        echo "router $rid created: $nm\n";
        echo "key (shown once; works once; valid " . (int) ($a[1] ?? 48) . " h):\n  $key\n\n";
        echo "On the router (SSH in, then):\n  sh /usr/lib/mwadmin/connect.sh join <this website's name> $key\n\n";
        echo "Then give someone access:  php cli.php assign <email> $rid\n";
        break;
    case 'assign':
        $pdo->prepare('INSERT OR IGNORE INTO user_routers (user_id, router_id) VALUES (?, ?)')->execute([uid($pdo, $a[0] ?? ''), (int) ($a[1] ?? 0)]);
        echo "assigned\n"; break;
    case 'unassign':
        $pdo->prepare('DELETE FROM user_routers WHERE user_id = ? AND router_id = ?')->execute([uid($pdo, $a[0] ?? ''), (int) ($a[1] ?? 0)]);
        echo "unassigned\n"; break;
    case 'list':
        foreach ($pdo->query('SELECT id, email, is_admin FROM users') as $u) echo "user {$u['id']}: {$u['email']}" . ($u['is_admin'] ? ' (admin)' : '') . "\n";
        foreach ($pdo->query('SELECT id, name, tunnel_port, last_seen FROM routers') as $r) echo "router {$r['id']}: {$r['name']} port {$r['tunnel_port']} last seen " . ($r['last_seen'] ? date('c', $r['last_seen']) : 'never') . "\n";
        foreach ($pdo->query('SELECT u.email, ur.router_id FROM user_routers ur JOIN users u ON u.id = ur.user_id') as $x) echo "assigned: {$x['email']} -> router {$x['router_id']}\n";
        break;
    default:
        fwrite(STDERR, "commands: add-user passwd del-user add-router new-key assign unassign list\n"); exit(1);
}
