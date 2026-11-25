<?php
// Router event log and site activity: storage and app naming.
// Fed by ingest.php (routers upload every minute), read by portal.php.
require_once __DIR__ . '/lib.php';

const KEEP_DAYS = 90;

function act_db(): PDO {
    static $ready = false;
    $pdo = db();
    if ($ready) return $pdo;
    $ready = true;
    $pdo->exec('CREATE TABLE IF NOT EXISTS events (router_id INTEGER NOT NULL, ts INTEGER NOT NULL,
        kind TEXT, sev TEXT, msg TEXT, UNIQUE (router_id, ts, kind, msg))');
    $pdo->exec('CREATE INDEX IF NOT EXISTS ev_r_ts ON events (router_id, ts)');
    $pdo->exec('CREATE TABLE IF NOT EXISTS visits (router_id INTEGER NOT NULL, ts INTEGER NOT NULL,
        mac TEXT, ip TEXT, name TEXT, domain TEXT, app TEXT)');
    $pdo->exec('CREATE INDEX IF NOT EXISTS vi_r_ts ON visits (router_id, ts)');
    $pdo->exec('CREATE INDEX IF NOT EXISTS vi_r_mac ON visits (router_id, mac, ts)');
    $pdo->exec('CREATE TABLE IF NOT EXISTS app_use (router_id INTEGER NOT NULL, ts INTEGER NOT NULL,
        mac TEXT, ip TEXT, name TEXT, app TEXT, bytes INTEGER)');
    $pdo->exec('CREATE INDEX IF NOT EXISTS au_r_ts ON app_use (router_id, ts)');
    $fresh = !$pdo->query("SELECT 1 FROM sqlite_master WHERE name = 'site_totals'")->fetchColumn();
    $pdo->exec('CREATE TABLE IF NOT EXISTS site_totals (router_id INTEGER NOT NULL, mac TEXT NOT NULL, domain TEXT NOT NULL,
        app TEXT, name TEXT, n INTEGER NOT NULL, first INTEGER, last INTEGER, PRIMARY KEY (router_id, mac, domain))');
    if ($fresh) {   // first run: build totals from the history already stored
        $pdo->exec('INSERT OR IGNORE INTO site_totals SELECT router_id, mac, domain, MAX(app), MAX(name), COUNT(*), MIN(ts), MAX(ts)
                    FROM visits GROUP BY router_id, mac, domain');
    }
    return $pdo;
}

function site_total_add(PDO $pdo, int $rid, string $mac, string $domain, string $app, string $name, int $ts): void {
    static $st = null;
    $st = $st ?? $pdo->prepare('INSERT INTO site_totals (router_id, mac, domain, app, name, n, first, last) VALUES (?, ?, ?, ?, ?, 1, ?, ?)
        ON CONFLICT (router_id, mac, domain) DO UPDATE SET n = n + 1, app = excluded.app,
        name = CASE WHEN excluded.name <> \'\' THEN excluded.name ELSE name END,
        first = MIN(first, excluded.first), last = MAX(last, excluded.last)');
    $st->execute([$rid, $mac, $domain, $app, $name, $ts, $ts]);
}

function act_prune(PDO $pdo): void {
    $cut = time() - KEEP_DAYS * 86400;
    foreach (['visits', 'app_use', 'events'] as $t) $pdo->prepare("DELETE FROM $t WHERE ts < ?")->execute([$cut]);
}

// Same names the router uses for its per-app byte counts.
function app_of(string $d): string {
    static $map = [
        'whatsapp' => 'WhatsApp', 'wa.me' => 'WhatsApp', 'zoom.us' => 'Zoom', 'zoom.com' => 'Zoom',
        'googlevideo' => 'YouTube', 'youtube' => 'YouTube', 'ytimg' => 'YouTube', 'youtu.be' => 'YouTube',
        'meet.google' => 'Google Meet', 'teams.microsoft' => 'Microsoft Teams', 'teams.live' => 'Microsoft Teams', 'skype' => 'Microsoft Teams',
        'instagram' => 'Instagram', 'cdninstagram' => 'Instagram',
        'tiktok' => 'TikTok', 'byteoversea' => 'TikTok', 'ibytedtos' => 'TikTok', 'musical.ly' => 'TikTok', 'ttwstatic' => 'TikTok',
        'netflix' => 'Netflix', 'nflx' => 'Netflix',
        'facebook' => 'Facebook', 'fbcdn' => 'Facebook', 'fbsbx' => 'Facebook', 'messenger' => 'Facebook', 'fb.com' => 'Facebook',
        'telegram' => 'Telegram', 't.me' => 'Telegram', 'snapchat' => 'Snapchat', 'sc-cdn' => 'Snapchat',
        'twitter' => 'X (Twitter)', 'twimg' => 'X (Twitter)', 'x.com' => 'X (Twitter)',
        'spotify' => 'Spotify', 'scdn.co' => 'Spotify', 'twitch' => 'Twitch', 'ttvnw' => 'Twitch',
        'discord' => 'Discord', 'linkedin' => 'LinkedIn', 'licdn' => 'LinkedIn',
        'openai' => 'ChatGPT', 'chatgpt' => 'ChatGPT', 'oaiusercontent' => 'ChatGPT', 'anthropic' => 'Claude', 'claude.ai' => 'Claude',
        'gemini.google' => 'Gemini', 'speedtest' => 'Speed test', 'ookla' => 'Speed test', 'fast.com' => 'Speed test',
        'steam' => 'Steam', 'epicgames' => 'Epic Games', 'pubg' => 'PUBG', 'roblox' => 'Roblox', 'rbxcdn' => 'Roblox',
        'minecraft' => 'Minecraft', 'freefire' => 'Free Fire', 'garena' => 'Free Fire',
        'primevideo' => 'Prime Video', 'aiv-cdn' => 'Prime Video', 'github' => 'GitHub',
        'icloud' => 'Apple', 'apple.com' => 'Apple', 'mzstatic' => 'Apple', 'aaplimg' => 'Apple',
        'windowsupdate' => 'Windows Update', 'update.microsoft' => 'Windows Update', 'delivery.mp.microsoft' => 'Windows Update',
        'office' => 'Microsoft 365', 'sharepoint' => 'Microsoft 365', 'onedrive' => 'Microsoft 365', 'live.com' => 'Microsoft 365',
        'microsoft' => 'Microsoft', 'msedge' => 'Microsoft', 'azure' => 'Microsoft', 'bing.com' => 'Microsoft',
        'gstatic' => 'Google', 'googleapis' => 'Google', 'google' => 'Google', 'gvt1' => 'Google', 'ggpht' => 'Google',
        'amazonaws' => 'Amazon cloud', 'cloudfront' => 'Amazon cloud', 'amazon' => 'Amazon',
        'akamai' => 'Akamai CDN', 'cloudflare' => 'Cloudflare', 'fastly' => 'Fastly CDN',
        'daraz' => 'Daraz', 'jazz.com.pk' => 'Jazz', 'easypaisa' => 'Easypaisa', 'jazzcash' => 'JazzCash',
    ];
    $d = strtolower($d);
    foreach ($map as $p => $n) {
        $i = strpos($d, $p);
        if ($i === false) continue;
        if (strpos($p, '.') === false || $i === 0 || $d[$i - 1] === '.') return $n;
    }
    $parts = explode('.', $d);
    $n = count($parts);
    if ($n >= 3 && in_array($parts[$n - 2], ['com', 'co', 'org', 'net', 'gov', 'edu', 'ac'], true)) return implode('.', array_slice($parts, -3));
    return $n >= 2 ? $parts[$n - 2] . '.' . $parts[$n - 1] : $d;
}
