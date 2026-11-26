<?php
// Router <-> website compatibility. The router publishes what it can do (GET /capabilities, see
// MultiWAN lib/caps.sh); this file is the website's side of the same list.
//
// Each feature the website knows: id => [label, highest level it speaks, route prefixes it uses].
// A router's feature is usable when the router has it, reports it available, and its level is
// one the website speaks (1 .. max). Otherwise the call is refused with a message that says which
// side to update:
//   router lacks it / older level  -> "Please update the router"
//   router's level is newer        -> "Please update the website"
//   router hardware cannot do it   -> "This router can't do it: <reason>"
// A router too old to answer /capabilities at all is "legacy": nothing is refused up front, but
// any "No such endpoint" answer is turned into the same "please update the router" message.
require_once __DIR__ . '/lib.php';

const WEB_API_LEVEL   = 1;      // raise with any change a router would have to match
const CAPS_FRESH      = 900;    // seconds a router's answer is trusted
const CAPS_RETRY      = 60;     // seconds before asking again after a failed ask

function web_features(): array {
    return [
        'status'          => ['Live status',                           1, ['/status', '/site']],
        'lines'           => ['Internet lines',                        1, ['/lines', '/mwan', '/wan']],
        'force_line'      => ['Use only one line',                     1, ['/site/force']],
        'line_exceptions' => ['Send an address over one line',         1, ['/lines/exceptions']],
        'address_swaps'   => ['Address swaps',                         1, ['/lines/swaps']],
        'devices'         => ['Devices and device names',              1, ['/devices', '/site/name']],
        'device_limit'    => ['Device limits',                         1, ['/devices/limit']],
        'nodes'           => ['Switches and access points',            1, ['/nodes']],
        'ports'           => ['LAN ports',                             1, ['/ports']],
        'alerts'          => ['Outage alerts',                         1, ['/alerts', '/events']],
        'pause'           => ['Break times and pausing',               1, ['/pause']],
        'guests'          => ['Guest list',                            1, ['/guests']],
        'apps'            => ['App blocking',                          1, ['/apps']],
        'sites'           => ['Site blocking',                         1, ['/sites']],
        'exempt'          => ['Never-blocked list',                    1, ['/exempt']],
        'wifi'            => ['Wi-Fi settings',                        1, ['/wifi']],
        'drives'          => ['USB drive sharing',                     1, ['/drives']],
        'quality'         => ['Line quality test',                     1, ['/quality']],
        'connect'         => ['Connect to a website',                  1, ['/connect']],
        'shared_settings' => ['Settings shared between routers',       1, ['/policy', '/policy/sync']],
        'backup'          => ['Daily backup to the USB drive',         1, ['/archive/run']],
        'software'        => ['Software update',                       1, ['/software']],
    ];
}

// The feature a route belongs to (longest matching prefix), or null when the website does not gate it.
function feature_for_route(string $route): ?string {
    $best = null; $len = -1;
    foreach (web_features() as $id => $f) {
        foreach ($f[2] as $p) {
            if (($route === $p || strpos($route, $p . '/') === 0) && strlen($p) > $len) { $best = $id; $len = strlen($p); }
        }
    }
    return $best;
}

// What the router said it can do: ['legacy'=>true] for a router too old to say, or null when it
// cannot be reached (then nothing is decided). Cached in the routers table.
function router_caps(array $router, bool $force = false, bool $cacheOnly = false): ?array {
    $pdo = db();
    $now = time();
    $st = $pdo->prepare('SELECT caps_json, caps_at FROM routers WHERE id = ?');
    $st->execute([$router['id']]);
    $row = $st->fetch(); $st->closeCursor();
    $cached = ($row && $row['caps_json'] !== null && $row['caps_json'] !== '') ? json_decode($row['caps_json'], true) : null;
    $at = $row ? (int) $row['caps_at'] : 0;
    if ($cacheOnly) return is_array($cached) ? $cached : null;   // the relay never waits on a router just to decide
    if (!$force) {
        if (is_array($cached) && $now - $at < CAPS_FRESH) return $cached;
        if (!is_array($cached) && $at && $now - $at < CAPS_RETRY) return null;
    }
    $res = router_call($router, '/capabilities', 'GET', '', null, 12);
    $caps = null;
    if ($res && $res[0] === 200) {
        $j = json_decode($res[2], true);
        if (is_array($j) && !empty($j['ok']) && isset($j['features'])) {
            $caps = $j; $caps['legacy'] = false;
        } elseif (is_array($j) && (!empty($j['unsupported']) || strpos((string) ($j['error'] ?? ''), 'No such endpoint') !== false)) {
            $caps = ['legacy' => true];
        }
    }
    if ($caps === null) {                       // unreachable or an answer we cannot read: keep what we had
        $pdo->prepare('UPDATE routers SET caps_at = ? WHERE id = ?')->execute([$now, $router['id']]);
        return is_array($cached) ? $cached : null;
    }
    $pdo->prepare('UPDATE routers SET caps_json = ?, caps_at = ? WHERE id = ?')->execute([json_encode($caps), $now, $router['id']]);
    return $caps;
}

// One feature of one router, as the website sees it.
// Returns ['state' => ok|update_router|update_website|unavailable|unknown, 'message' => ...].
function feature_state(?array $caps, string $id): array {
    $f = web_features()[$id] ?? null;
    if (!$f) return ['state' => 'ok', 'message' => ''];
    $label = $f[0];
    if ($caps === null) return ['state' => 'unknown', 'message' => ''];
    if (!empty($caps['legacy'])) return ['state' => 'unknown', 'message' => ''];
    $rf = null;
    foreach ($caps['features'] ?? [] as $x) if (($x['id'] ?? '') === $id) { $rf = $x; break; }
    if (!$rf) return ['state' => 'update_router', 'message' => "This router's software does not have \"$label\". Please update the router (Settings > Software update)."];
    if (empty($rf['available'])) {
        $why = trim((string) ($rf['reason'] ?? ''));
        return ['state' => 'unavailable', 'message' => "This router can't do \"$label\"" . ($why !== '' ? ": $why." : '.')];
    }
    $lvl = (int) ($rf['level'] ?? 1);
    if ($lvl > $f[1]) return ['state' => 'update_website', 'message' => "This router has a newer version of \"$label\" than this website understands. Please update the website (reload the page; if it still says this, the website needs updating)."];
    return ['state' => 'ok', 'message' => ''];
}

// Refusal for a call the router cannot take, or null to let it through.
function caps_gate(array $router, string $route): ?array {
    $id = feature_for_route($route);
    if ($id === null) return null;
    $caps = router_caps($router, false, true);
    $s = feature_state($caps, $id);
    if ($s['state'] === 'ok' || $s['state'] === 'unknown') return null;
    return ['ok' => false, 'unsupported' => true, 'feature' => $id, 'needs' => $s['state'], 'error' => $s['message']];
}

// The whole picture for the dashboard.
function caps_report(array $router, bool $force = false): array {
    $caps = router_caps($router, $force);
    if ($caps === null) return ['ok' => true, 'known' => false, 'message' => 'The router is not reachable right now, so what it can do is not known yet.'];
    if (!empty($caps['legacy'])) {
        return ['ok' => true, 'known' => true, 'legacy' => true, 'compatible' => false, 'website_level' => WEB_API_LEVEL,
                'message' => "This router runs older software that cannot say what it supports. Please update the router (Settings > Software update); until then some options may refuse to work.",
                'features' => []];
    }
    $out = []; $known = [];
    foreach (web_features() as $id => $f) {
        $s = feature_state($caps, $id);
        $out[] = ['id' => $id, 'label' => $f[0], 'state' => $s['state'], 'message' => $s['message']];
        $known[$id] = true;
    }
    $extra = [];
    foreach ($caps['features'] ?? [] as $x) {
        if (!isset($known[$x['id'] ?? ''])) $extra[] = ['id' => $x['id'], 'label' => $x['label'] ?? $x['id'], 'state' => 'update_website',
            'message' => "The router offers \"" . ($x['label'] ?? $x['id']) . "\", which this website does not have yet. Please update the website."];
    }
    $bad = 0; foreach (array_merge($out, $extra) as $o) if ($o['state'] !== 'ok') $bad++;
    $needsWeb = (int) ($caps['needs_website_level'] ?? 1) > WEB_API_LEVEL;
    $msg = $needsWeb ? 'This router needs a newer website than this one. Please update the website.' : ($bad ? "$bad option(s) are limited, see below." : 'Everything this website offers works with this router.');
    return ['ok' => true, 'known' => true, 'legacy' => false, 'compatible' => !$bad && !$needsWeb, 'message' => $msg,
            'software' => (string) ($caps['software'] ?? ''), 'board' => (string) ($caps['board'] ?? ''),
            'router_level' => (int) ($caps['api_level'] ?? 0), 'website_level' => WEB_API_LEVEL,
            'features' => array_merge($out, $extra)];
}

// An old router answers an unknown route with a plain "No such endpoint" error: say what it means.
function caps_translate_reply(string $payload): ?string {
    if (strpos($payload, 'No such endpoint') === false) return null;
    $j = json_decode($payload, true);
    if (!is_array($j) || !empty($j['unsupported'])) return null;
    if (strpos((string) ($j['error'] ?? ''), 'No such endpoint') !== 0) return null;
    return json_encode(['ok' => false, 'unsupported' => true, 'needs' => 'update_router',
        'error' => "This router's software does not have this option. Please update the router (Settings > Software update)."]);
}
