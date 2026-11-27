<?php
// Relay between this website and a router's admin API.
//
//   api.php/r/<router-id>/<route>     e.g.  api.php/r/1/status
//
// Each router dials OUT to this server over SSH and exposes its admin port on
// this server's loopback only. Nothing on the router is reachable from the
// internet directly, and it needs no public or static IP, so it keeps working
// whichever WAN link is up.
//
// Authority comes from the website account: the caller must be signed in AND
// assigned to that router. The router's own password is never asked for here;
// this relay presents the router's portal token on the caller's behalf.
require __DIR__ . '/../portal/lib.php';
require __DIR__ . '/../portal/caps_lib.php';

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
if ($method === 'OPTIONS') { http_response_code(204); exit; }
if ($method !== 'GET' && $method !== 'POST') fail(405, 'Method not allowed.');
if ($method === 'POST') require_same_origin();

$path = $_SERVER['PATH_INFO'] ?? '';
if ($path === '') {
    $uri = strtok($_SERVER['REQUEST_URI'] ?? '', '?');
    $pos = strpos($uri, 'api.php');
    $path = $pos === false ? '' : substr($uri, $pos + 7);
}
if (!preg_match('#^/r/(\d{1,9})(/[A-Za-z0-9_/\-]{0,120})$#', $path, $m)) fail(400, 'Bad route.');
$routerId = (int) $m[1];
$route    = $m[2];

$user = require_user();

// Signing out of the panel signs out of the website account.
if ($route === '/logout') { logout(); json_out(200, ['ok' => true]); }
// The router's own password login is not offered through the website.
if ($route === '/login') fail(403, 'Sign in at the Baytaar home page.');

$router = router_for($user, $routerId);
if (!$router) fail(403, 'This router is not assigned to your account.');
// Shared as "can view": everything can be looked at, nothing can be changed (every change to a router is a POST).
if (($router['access'] ?? 'owner') === 'view' && $method !== 'GET') fail(403, 'You can view this router but not change it. Ask its owner for "can manage".');

$query = clean_query($_SERVER['QUERY_STRING'] ?? '');
$body  = $method === 'POST' ? read_json_body() : null;

// A call the router's software or hardware cannot take is refused here, with the side to update named.
// (Uses what the router last said it can do; the dashboard refreshes that. Routers too old to say are not gated.)
if ($route !== '/capabilities') {
    $refuse = caps_gate($router, $route);
    if ($refuse) json_out(200, $refuse);
}

$res = router_call($router, $route, $method, $query, $body);
if ($res === null) {
    fail(502, 'The router is offline, or its tunnel to this server is not connected.');
}
[$code, $ctype, $payload, $disp] = $res;
// An old router answers a route it lacks with a bare "No such endpoint": say what that means.
if (stripos($ctype, 'json') !== false && ($t = caps_translate_reply($payload)) !== null) { $payload = $t; $code = 200; }

header('Cache-Control: no-store, no-cache, must-revalidate');
header('X-Content-Type-Options: nosniff');
http_response_code($code ?: 502);
header('Content-Type: ' . $ctype);
if ($disp !== '') header('Content-Disposition: ' . $disp);
echo $payload;
