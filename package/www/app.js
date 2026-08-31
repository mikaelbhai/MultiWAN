/* MultiWAN admin UI.
   Vanilla JS, no dependencies, no build step. ~26 KB, ~7 KB gzipped. */
(function () {
'use strict';

// Sourcing this file from another origin — see docs/07-standalone-app.md —
// sets window.MW_API_BASE to the router's full external URL before this
// script loads (e.g. "http://203.0.113.5:8443/cgi-bin/mwadmin"); running on
// the router itself, the relative path is correct as-is.
var API = window.MW_API_BASE || 'cgi-bin/mwadmin';
var session = null;
var statusTimer = null, bwTimer = null, devTimer = null, nodeTimer = null, remoteTimer = null;
var bwHistory = {};

/* ======================= helpers ======================= */

/* Everything rendered into innerHTML goes through this. Device hostnames,
   SSIDs, and detected ISP names are all attacker-influenced in principle —
   an SSID is 32 bytes of anything, and the ISP string comes off the network. */
function esc(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}

function $(sel, root) { return (root || document).querySelector(sel); }
function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

function api(path, opts) {
  opts = opts || {};
  var cfg = { method: opts.method || 'GET', headers: {}, credentials: 'same-origin' };
  if (cfg.method === 'POST') {
    // The CSRF token rides in the body as "_csrf", not a header: uhttpd's CGI
    // handler does not forward custom X-* headers into the script environment
    // at all, so a header-based token is silently dropped on every request —
    // not an edge case, every single one. The body is read directly off
    // stdin server-side and is how the login password already gets through.
    // This same field doubles as the bearer token for a cross-origin caller
    // (see MW_API_BASE above) — the server accepts it as the session
    // identifier itself when no cookie is present, which is always true
    // cross-origin (SameSite=Strict, and no HTTPS to allow SameSite=None).
    var body = opts.body || {};
    if (session) body._csrf = session;
    cfg.headers['Content-Type'] = 'application/json';
    cfg.body = JSON.stringify(body);
  } else {
    if (opts.body) {
      cfg.headers['Content-Type'] = 'application/json';
      cfg.body = JSON.stringify(opts.body);
    }
    // Same reasoning as the POST body field above, but GET has no body to
    // carry it in, so it rides in the query string instead. Harmless to
    // attach even when running on the router itself with a valid cookie —
    // the server only looks at this when no cookie is present.
    if (session) path += (path.indexOf('?') === -1 ? '?' : '&') + 'session=' + encodeURIComponent(session);
  }

  return fetch(API + path, cfg).then(function (r) {
    if (r.status === 401) { showLogin(); throw new Error('Session expired'); }
    return r.json().catch(function () { throw new Error('Malformed response from router'); });
  }).then(function (j) {
    if (j && j.ok === false) throw new Error(j.error || 'Request failed');
    return j;
  });
}

function toast(msg, kind) {
  var el = document.createElement('div');
  el.className = 'toast ' + (kind || '');
  el.textContent = msg;
  $('#toasts').appendChild(el);
  setTimeout(function () {
    el.style.opacity = '0';
    setTimeout(function () { el.remove(); }, 200);
  }, kind === 'error' ? 6000 : 3400);
}

// Polls `url` (cross-origin — this fires after a LAN IP change, so it's a
// different host:port than the page currently running this code) and
// navigates the browser there the moment it's reachable. `no-cors` mode
// still rejects on real network failures (DNS, connection refused, timeout);
// it only limits what we're allowed to read from the response, and we don't
// need to read anything — reachable is enough. Gives the router's background
// network reload + dnsmasq/uhttpd restart a few seconds before the first
// attempt, then retries for up to 30s before giving up quietly.
function redirectWhenReachable(url) {
  var deadline = Date.now() + 30000;
  function attempt() {
    fetch(url, { mode: 'no-cors', cache: 'no-store' }).then(function () {
      window.location.href = url;
    }).catch(function () {
      if (Date.now() < deadline) {
        setTimeout(attempt, 1500);
      } else {
        toast('Could not reach ' + url + ' automatically. The change may still be applying — try it manually in a moment.', 'error');
      }
    });
  }
  setTimeout(attempt, 3000);
}

function confirmModal(title, bodyHtml, okLabel, danger) {
  return new Promise(function (resolve) {
    $('#modal-title').textContent = title;
    $('#modal-body').innerHTML = '<div class="modal-body-text">' + bodyHtml + '</div>';
    var ok = $('#modal-ok');
    ok.textContent = okLabel || 'Confirm';
    ok.className = 'btn ' + (danger === false ? 'btn-primary' : 'btn-danger');
    $('#modal').hidden = false;

    function done(v) {
      $('#modal').hidden = true;
      ok.onclick = null; $('#modal-cancel').onclick = null;
      resolve(v);
    }
    ok.onclick = function () { done(true); };
    $('#modal-cancel').onclick = function () { done(false); };
  });
}

function fmtBytes(b) {
  if (!b && b !== 0) return '—';
  var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
  while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
  return b.toFixed(i ? 1 : 0) + ' ' + u[i];
}

function fmtBits(bps) {
  if (!bps && bps !== 0) return '—';
  var u = ['bit/s', 'kbit/s', 'Mbit/s', 'Gbit/s'], i = 0;
  while (bps >= 1000 && i < u.length - 1) { bps /= 1000; i++; }
  return bps.toFixed(i >= 2 ? 1 : 0) + ' ' + u[i];
}

function fmtUptime(s) {
  if (!s) return '—';
  var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
  return (d ? d + 'd ' : '') + (h ? h + 'h ' : '') + m + 'm';
}

function fmtAgo(ts) {
  if (!ts) return 'never';
  var s = Math.floor(Date.now() / 1000) - ts;
  if (s < 60) return s + 's ago';
  if (s < 3600) return Math.floor(s / 60) + 'm ago';
  if (s < 86400) return Math.floor(s / 3600) + 'h ago';
  return Math.floor(s / 86400) + 'd ago';
}

/* Renders a link speed with a warning when a port negotiated below gigabit.
   A WAN1 that quietly came up at 100 Mb because of a bad cable is exactly the
   failure this UI exists to make visible. */
// Classifies an IPv4 address as private (RFC1918) or carrier-grade-NAT
// (100.64.0.0/10) — either means port forwarding on THIS router alone won't
// make that WAN reachable from the internet; something further upstream
// (an ISP modem/router doing another layer of NAT) needs its own forward
// pointed at this router. Returns null for an address we can't parse (WAN
// not up yet).
function isPrivateIPv4(ip) {
  if (!ip) return null;
  var p = ip.split('.').map(Number);
  if (p.length !== 4 || p.some(function (n) { return isNaN(n); })) return null;
  if (p[0] === 10) return true;
  if (p[0] === 172 && p[1] >= 16 && p[1] <= 31) return true;
  if (p[0] === 192 && p[1] === 168) return true;
  if (p[0] === 100 && p[1] >= 64 && p[1] <= 127) return true; // CGNAT
  return false;
}

function speedBadge(mbps, carrier) {
  if (!carrier) return '<span class="badge">No link</span>';
  if (!mbps) return '<span class="badge warn">Link, speed unknown</span>';
  var cls = mbps >= 1000 ? 'ok' : (mbps >= 100 ? 'warn' : 'danger');
  return '<span class="badge ' + cls + '">' + mbps + ' Mb</span>';
}

/* ======================= auth ======================= */

function showLogin() {
  clearInterval(statusTimer); clearInterval(bwTimer); clearInterval(devTimer); clearInterval(nodeTimer); clearInterval(remoteTimer);
  session = null;
  $('#app').hidden = true;
  $('#login').hidden = false;
  $('#login-pass').value = '';
  setTimeout(function () { $('#login-pass').focus(); }, 50);
}

function showApp() {
  $('#login').hidden = true;
  $('#app').hidden = false;
  route();
  pollStatus();
  statusTimer = setInterval(pollStatus, 4000);
  bwTimer = setInterval(pollBandwidth, 2000);
  devTimer = setInterval(pollDevices, 3000);
  nodeTimer = setInterval(pollNodes, 3000);
  remoteTimer = setInterval(pollRemote, 5000);
}

var loginInFlight = false;
$('#login-form').addEventListener('submit', function (e) {
  e.preventDefault();
  // Disabling the button alone does not stop a second submit: pressing Enter
  // twice fires the form's 'submit' event again regardless of button state,
  // since that event doesn't go through the (disabled) button at all. Two
  // concurrent /login calls each mint their own session cookie, and if the
  // in-memory `session` variable ends up holding the token from the request
  // that ISN'T the one the browser kept, every later POST fails CSRF with
  // "Missing or invalid CSRF token." This flag is the actual fix; the
  // disabled button is just the visual echo of it.
  if (loginInFlight) return;
  loginInFlight = true;

  var btn = $('#login-btn'), err = $('#login-error');
  err.hidden = true;
  btn.disabled = true; btn.innerHTML = '<span class="spinner"></span> Signing in';

  api('/login', { method: 'POST', body: { username: 'root', password: $('#login-pass').value } })
    .then(function (r) { session = r.session; saveRemoteSession(session); showApp(); })
    .catch(function (e) { err.textContent = e.message; err.hidden = false; })
    .then(function () { loginInFlight = false; btn.disabled = false; btn.textContent = 'Sign in'; });
});

$('#logout-btn').addEventListener('click', function () {
  api('/logout', { method: 'POST' }).catch(function () {}).then(function () { saveRemoteSession(null); showLogin(); });
});

$('#theme-toggle').addEventListener('click', function () {
  var el = document.documentElement;
  var next = el.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
  el.setAttribute('data-theme', next);
  try { localStorage.setItem('mw-theme', next); } catch (e) {}
});
try {
  var saved = localStorage.getItem('mw-theme');
  if (saved) document.documentElement.setAttribute('data-theme', saved);
} catch (e) {}

/* ======================= global status ======================= */

function pollStatus() {
  api('/status').then(function (s) {
    var badge = $('#mode-badge');
    badge.textContent = s.mode === 'ap' ? 'Access Point' : 'Router';
    badge.className = 'mode-badge ' + (s.mode === 'ap' ? 'ap' : 'router');

    var chip = $('#active-wan-chip'), lbl = $('#active-wan-label');
    var actives = s.active_wans || (s.active_wan && s.active_wan !== 'none' ? [s.active_wan] : []);
    if (s.mode === 'ap') {
      chip.className = 'active-wan'; lbl.textContent = 'Bridged';
    } else if (actives.length > 1) {
      chip.className = 'active-wan up';
      lbl.textContent = actives.map(function (w) { return w.toUpperCase(); }).join(' + ') + ' sharing load';
    } else if (actives.length === 1) {
      chip.className = 'active-wan up'; lbl.textContent = actives[0].toUpperCase() + ' carrying traffic';
    } else {
      chip.className = 'active-wan down'; lbl.textContent = 'No uplink';
    }

    var rb = $('#rollback-bar');
    if (s.rollback && s.rollback.pending) {
      rb.hidden = false;
      $('#rb-target').textContent = s.rollback.revert_to === 'ap' ? 'Access Point mode' :
        s.rollback.revert_to === 'router' ? 'Router mode' : 'the previous LAN settings';
      $('#rb-seconds').textContent = s.rollback.seconds_remaining;
    } else { rb.hidden = true; }

    window.__status = s;
    if (currentView === 'dashboard' || currentView === 'wan') renderStatusInto(s);
  }).catch(function () {});
}

$('#rb-confirm').addEventListener('click', function () {
  api('/mode/confirm', { method: 'POST' })
    .then(function () { toast('Configuration kept. Rollback cancelled.', 'ok'); $('#rollback-bar').hidden = true; })
    .catch(function (e) { toast(e.message, 'error'); });
});

function pollBandwidth() {
  if (currentView !== 'dashboard') return;
  api('/bandwidth').then(function (r) {
    (r.interfaces || []).forEach(function (i) {
      var h = bwHistory[i.iface] || (bwHistory[i.iface] = { pts: [], last: null });
      if (h.last) {
        var dt = i.ts - h.last.ts;
        if (dt > 0) {
          h.pts.push({
            rx: Math.max(0, (i.rx_bytes - h.last.rx) / dt * 8),
            tx: Math.max(0, (i.tx_bytes - h.last.tx) / dt * 8)
          });
          if (h.pts.length > 60) h.pts.shift();
        }
      }
      h.last = { rx: i.rx_bytes, tx: i.tx_bytes, ts: i.ts };
      drawSpark(i.iface, h.pts);
    });
  }).catch(function () {});
}

function pollDevices() {
  if (currentView !== 'devices') return;
  api('/devices').then(function (r) {
    var body = $('#dev-tbody');
    if (!body) return;
    var rows = (r.devices || []).slice().sort(function (a, b) {
      // Online devices first (most useful at a glance), then alphabetical.
      if (a.online !== b.online) return a.online ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    body.innerHTML = rows.map(function (d) {
      var mbps = function (v) { return v === null || v === undefined ? '—' : v.toFixed(2); };
      return '<tr' + (d.online ? '' : ' class="dev-offline"') + '>' +
        '<td>' + esc(d.name) + '</td>' +
        '<td class="mono" style="font-size:11.5px">' + esc(d.mac) + '</td>' +
        '<td class="mono">' + esc(d.ip) + '</td>' +
        '<td>' + (d.online
          ? '<span class="badge ok">online</span>'
          : '<span class="badge">offline</span>') + '</td>' +
        '<td class="mono">' + (d.online ? mbps(d.down_mbps) : '—') + '</td>' +
        '<td class="mono">' + (d.online ? mbps(d.up_mbps) : '—') + '</td>' +
        '</tr>';
    }).join('') || '<tr><td colspan="6" class="empty">No devices known yet.</td></tr>';
  }).catch(function () {});
}

var NODE_KIND_LABEL = { router: 'Router', ap: 'Access point', other: 'Other' };

function pollNodes() {
  if (currentView !== 'nodes') return;
  api('/nodes').then(function (r) {
    var body = $('#node-tbody');
    if (!body) return;
    var rows = (r.nodes || []).slice().sort(function (a, b) {
      if (a.online !== b.online) return a.online ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    var mbps = function (v) { return v === null || v === undefined ? '—' : v.toFixed(2); };
    body.innerHTML = rows.map(function (n) {
      return '<tr' + (n.online ? '' : ' class="dev-offline"') + '>' +
        '<td>' + esc(n.name) + '</td>' +
        '<td>' + esc(NODE_KIND_LABEL[n.kind] || 'Other') + '</td>' +
        '<td class="mono">' + esc(n.ip || '—') + '</td>' +
        '<td>' + (n.online ? '<span class="badge ok">online</span>' : '<span class="badge">offline</span>') + '</td>' +
        '<td class="mono">' + (n.online ? mbps(n.down_mbps) : '—') + '</td>' +
        '<td class="mono">' + (n.online ? mbps(n.up_mbps) : '—') + '</td>' +
        '<td id="node-test-' + esc(n.id) + '">' +
          '<button class="btn btn-sm" data-test-node="' + esc(n.id) + '"' + (n.online ? '' : ' disabled') + '>Test</button></td>' +
        '<td style="white-space:nowrap">' +
          (n.admin_url ? '<a class="btn btn-sm" href="' + esc(n.admin_url) + '" target="_blank" rel="noopener">Open panel</a> ' : '') +
          '<button class="btn btn-sm btn-ghost" data-del-node="' + esc(n.id) + '">Remove</button></td></tr>';
    }).join('') || '<tr><td colspan="8" class="empty">No nodes added yet.</td></tr>';

    $$('[data-del-node]').forEach(function (b) {
      b.onclick = function () {
        var id = b.getAttribute('data-del-node');
        confirmModal('Remove this node?',
          'This only removes it from this page — it does not change any setting on the device itself.',
          'Remove', false).then(function (go) {
          if (!go) return;
          api('/nodes/del', { method: 'POST', body: { id: id } })
            .then(function (rr) { toast(rr.message, 'ok'); pollNodes(); })
            .catch(function (e) { toast(e.message, 'error'); });
        });
      };
    });

    $$('[data-test-node]').forEach(function (b) {
      b.onclick = function () { runNodeTest(b.getAttribute('data-test-node')); };
    });
    loadHistory();
  }).catch(function () {});
}

// Fire-and-poll: start the ping test, then check back every second (up to
// 15s — six pings at worst-case timeout is well under that) until it lands
// on a terminal status. The cell is looked up fresh each tick since the node
// table can re-render out from under a still-running test (currentView
// guard stops it once you've navigated away entirely).
function runNodeTest(id) {
  var cell = $('#node-test-' + id);
  if (!cell) return;
  cell.innerHTML = '<span class="badge">testing…</span>';
  api('/nodes/test', { method: 'POST', body: { id: id } }).then(function () {
    var tries = 0;
    (function poll() {
      if (currentView !== 'nodes') return;
      tries++;
      api('/nodes/test?id=' + encodeURIComponent(id)).then(function (r) {
        var c = $('#node-test-' + id);
        if (!c) return;
        if (r.status === 'done') {
          var lossBad = r.loss_pct === null || r.loss_pct >= 50;
          c.innerHTML = lossBad
            ? '<span class="badge danger">' + esc(r.loss_pct == null ? 'no reply' : r.loss_pct + '% loss') + '</span>'
            : '<span class="badge ' + (r.loss_pct > 0 ? 'warn' : 'ok') + '">' + esc(r.avg_ms) + ' ms' +
              (r.loss_pct > 0 ? ', ' + esc(r.loss_pct) + '% loss' : '') + '</span>';
        } else if (tries > 15) {
          c.innerHTML = '<button class="btn btn-sm" data-test-node="' + esc(id) + '">Test</button>';
          $$('[data-test-node="' + id + '"]').forEach(function (b) { b.onclick = function () { runNodeTest(id); }; });
        } else {
          setTimeout(poll, 1000);
        }
      }).catch(function () {});
    })();
  }).catch(function (e) {
    var c = $('#node-test-' + id);
    if (c) c.innerHTML = '<span class="badge danger">' + esc(e.message) + '</span>';
  });
}

function loadHistory() {
  var body = $('#history-tbody');
  if (!body) return;
  api('/history?limit=50').then(function (r) {
    var b = $('#history-tbody');
    if (!b) return;
    b.innerHTML = (r.events || []).map(function (e) {
      var when = new Date(e.ts * 1000).toLocaleString();
      var what = (e.kind === 'wan' ? 'WAN ' : '') + esc(e.label);
      var badge = e.event === 'up' ? '<span class="badge ok">online</span>' : '<span class="badge danger">offline</span>';
      return '<tr><td class="mono" style="font-size:12px">' + esc(when) + '</td><td>' + what + '</td><td>' + badge + '</td></tr>';
    }).join('') || '<tr><td colspan="3" class="empty">No events recorded yet.</td></tr>';
  }).catch(function () {});
}

function pollRemote() {
  if (currentView !== 'remote') return;
  var el = $('#remote-status');
  if (!el) return;
  api('/remote/status').then(function (r) {
    var box = $('#remote-status');
    if (!box) return; // view changed while the request was in flight
    if (!r.enabled) {
      box.innerHTML = '<span class="badge">disabled</span>';
    } else if (r.running) {
      box.innerHTML = '<span class="badge ok">connected</span>' +
        (r.since ? '<p class="hint" style="margin:6px 0 0">up since ' + esc(new Date(r.since * 1000).toLocaleString()) + '</p>' : '');
    } else {
      box.innerHTML = '<span class="badge danger">not connected</span>' +
        '<p class="hint" style="margin:6px 0 0">Enabled but the tunnel isn\'t up yet — check that the relay host is reachable and the public key was added to its authorized_keys.</p>';
    }
  }).catch(function () {});
}

function drawSpark(iface, pts) {
  var svg = $('#spark-' + iface);
  if (!svg || pts.length < 2) return;
  var W = 300, H = 46;
  var max = Math.max.apply(null, pts.map(function (p) { return Math.max(p.rx, p.tx); }).concat([1]));
  function path(key) {
    return pts.map(function (p, i) {
      return (i ? 'L' : 'M') + (i / (pts.length - 1) * W).toFixed(1) + ' ' + (H - p[key] / max * (H - 3)).toFixed(1);
    }).join(' ');
  }
  svg.innerHTML =
    '<path class="rx" d="' + path('rx') + ' L' + W + ' ' + H + ' L0 ' + H + ' Z"/>' +
    '<path class="rx-l" d="' + path('rx') + '"/>' +
    '<path class="tx-l" d="' + path('tx') + '"/>';
  var lbl = $('#spark-lbl-' + iface);
  if (lbl) {
    var last = pts[pts.length - 1];
    lbl.innerHTML = '<span class="badge accent">↓ ' + fmtBits(last.rx) + '</span> ' +
                    '<span class="badge ok">↑ ' + fmtBits(last.tx) + '</span>';
  }
}

/* ======================= router ======================= */

var currentView = null;
var views = {};

function route() {
  var hash = (location.hash || '#/dashboard').slice(2);
  var name = hash.split('/')[0] || 'dashboard';
  if (!views[name]) name = 'dashboard';
  currentView = name;
  $$('[data-nav]').forEach(function (a) {
    a.classList.toggle('active', a.getAttribute('href') === '#/' + name);
  });
  $('#view').innerHTML = '<div class="empty"><span class="spinner"></span></div>';
  views[name]();
}
window.addEventListener('hashchange', route);

function page(title, sub, html) {
  $('#view').innerHTML =
    '<div class="page-head"><h2>' + esc(title) + '</h2>' +
    (sub ? '<p>' + sub + '</p>' : '') + '</div>' + html;
}

/* ======================= dashboard ======================= */

views.dashboard = function () {
  var s = window.__status;
  if (!s) { setTimeout(views.dashboard, 400); return; }
  page('Dashboard', 'Live gateway status.',
    '<div class="grid c4" id="dash-stats"></div>' +
    '<div class="card"><div class="card-head"><div><h3>WAN priority</h3>' +
      '<p>Traffic follows the highest-priority link that is healthy.</p></div></div>' +
      '<div class="card-body tight" id="dash-wans"></div></div>' +
    '<div class="card"><div class="card-head"><h3>Throughput</h3></div>' +
      '<div class="card-body" id="dash-bw"></div></div>');
  renderStatusInto(s);
  renderBwPanels(s);
};

function renderStatusInto(s) {
  var st = $('#dash-stats');
  if (st) {
    var memUsed = s.mem_total_kb ? Math.round((1 - s.mem_avail_kb / s.mem_total_kb) * 100) : 0;
    var actives = s.active_wans || (s.active_wan && s.active_wan !== 'none' ? [s.active_wan] : []);
    var upVal, upSub, upTone;
    if (s.mode === 'ap') {
      upVal = 'Bridged'; upSub = 'Access Point mode'; upTone = '';
    } else if (actives.length > 1) {
      upVal = actives.map(function (w) { return w.toUpperCase(); }).join(' + ');
      upSub = 'sharing load across ' + actives.length + ' uplinks';
      upTone = 'ok';
    } else if (actives.length === 1) {
      upVal = actives[0].toUpperCase();
      upSub = 'carrying all new connections';
      upTone = actives[0] === 'wan1' ? 'ok' : 'warn';
    } else {
      upVal = 'NONE'; upSub = 'no uplink is currently reachable'; upTone = 'danger';
    }
    st.innerHTML =
      tile('Active uplink', upVal, upSub, upTone) +
      tile('Sharing mode', s.mwan_mode === 'balance' ? 'Load balance' : 'Priority failover',
           s.mwan_mode === 'balance' ? 'multiple WANs share traffic' : 'one WAN at a time', '') +
      tile('Mode', s.mode === 'ap' ? 'Access Point' : 'Router', s.mode === 'ap' ? 'routing disabled' : 'multi-WAN active', '') +
      tile('Uptime', fmtUptime(s.uptime_s), 'load ' + esc(s.load1), '') +
      tile('Memory', memUsed + '%', fmtBytes(s.mem_avail_kb * 1024) + ' available', memUsed > 85 ? 'warn' : '');
  }

  var w = $('#dash-wans');
  if (w) {
    if (s.mode === 'ap') {
      w.innerHTML = '<div class="empty">The device is in Access Point mode. WAN interfaces are not configured.</div>';
      return;
    }
    w.innerHTML = (s.wans || []).map(function (x, i) {
      var up = x.tracker === 'online';
      return '<div class="wan-row' + (x.active ? ' is-active' : '') + '">' +
        '<div class="wan-prio">' + (i + 1) + '</div>' +
        '<div class="wan-main"><div class="wan-name">' + esc(x.name.toUpperCase()) +
          (x.active ? ' <span class="badge ok">Carrying traffic</span>' : '') +
          ' <span class="badge ' + (up ? 'ok' : 'danger') + '">' + esc(x.tracker) + '</span>' +
          '</div><div class="wan-meta">' +
          '<span>' + esc(x.device) + '</span>' +
          '<span>' + esc(x.address || 'no address') + '</span>' +
          '<span>' + esc(x.proto) + '</span>' +
          '</div></div>' +
        '<div>' + speedBadge(x.link_speed_mbps, x.carrier) + '</div></div>';
    }).join('') || '<div class="empty">No WAN interfaces configured.</div>';
  }
}

function tile(k, v, s, cls) {
  return '<div class="stat"><div class="k">' + esc(k) + '</div>' +
    '<div class="v ' + (cls || '') + '">' + esc(v) + '</div>' +
    '<div class="s">' + esc(s) + '</div></div>';
}

function renderBwPanels(s) {
  var el = $('#dash-bw');
  if (!el) return;
  var list = (s.mode === 'ap') ? [{ name: 'lan' }] : (s.wans || []).concat([{ name: 'lan' }]);
  el.innerHTML = list.map(function (x) {
    return '<div style="margin-bottom:14px">' +
      '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:4px">' +
      '<strong style="font-size:12.5px">' + esc(x.name.toUpperCase()) + '</strong>' +
      '<span id="spark-lbl-' + esc(x.name) + '"></span></div>' +
      '<svg class="spark" id="spark-' + esc(x.name) + '" viewBox="0 0 300 46" preserveAspectRatio="none"></svg></div>';
  }).join('');
}

/* ======================= WAN & failover ======================= */

views.wan = function () {
  var s = window.__status || {};
  var ifaces = (s.wans || []).map(function (w) { return w.name; });
  if (!ifaces.length) ifaces = ['wan1', 'wan2', 'wan3'];

  Promise.all(ifaces.map(function (i) {
    return api('/wan?iface=' + i).catch(function () { return null; });
  }).concat([api('/mwan/protocol').catch(function () { return { udp_wan: 'auto', tcp_wan: 'auto' }; })]))
    .then(function (results) {
    var proto = results.pop();
    var editCards = ifaces.map(function (i, idx) {
      return wanEditCard(results[idx] || { iface: i, proto: '' });
    }).join('');

    function protoOptions(sel) {
      return ['auto'].concat(ifaces).map(function (v) {
        var label = v === 'auto' ? 'Automatic (use failover/balance mode above)' : v.toUpperCase();
        return '<option value="' + v + '"' + (v === sel ? ' selected' : '') + '>' + label + '</option>';
      }).join('');
    }

    page('WAN &amp; failover', 'Priority failover across three uplinks, managed by mwan3.',
      '<div class="alert alert-info"><strong>This is fast failover, not seamless failover.</strong>' +
        'When WAN1 drops, every in-flight connection bound to its address is lost — calls, downloads, ' +
        'SSH sessions. New connections move to WAN2 within roughly 4–10 seconds. ' +
        'Established sessions already on WAN2 stay there after WAN1 returns.</div>' +
      '<div class="card"><div class="card-head"><div><h3>Uplink state</h3>' +
        '<p>Health-check state from the mwan3 trackers.</p></div></div>' +
        '<div class="card-body tight" id="dash-wans"></div></div>' +
      editCards +
      '<div class="card"><div class="card-head"><h3>Protocol-based WAN split</h3></div><div class="card-body">' +
        '<p class="hint" style="margin-top:0">Pin all TCP or all UDP traffic to a specific uplink, independent of ' +
        'the failover/balance mode above — e.g. UDP-sensitive traffic (games, VoIP) on your lowest-latency line, ' +
        'everything else on the mode above. Each still automatically fails over to whichever other enabled WANs ' +
        'are healthy if its assigned uplink goes down; this only sets the preferred order, not a hard lock.</p>' +
        '<div class="form-row">' +
        '<label class="field"><span>TCP traffic</span><select id="proto-tcp">' + protoOptions(proto.tcp_wan) + '</select></label>' +
        '<label class="field"><span>UDP traffic</span><select id="proto-udp">' + protoOptions(proto.udp_wan) + '</select></label>' +
        '</div>' +
        '<button class="btn btn-primary" id="proto-save">Save</button>' +
        '</div></div>' +
      '<div class="card"><div class="card-head"><h3>Health-check tuning</h3></div><div class="card-body">' +
        '<div class="tbl-wrap"><table><thead><tr><th>Uplink</th><th>Interval</th><th>Timeout</th>' +
        '<th>Fail count</th><th>Recover count</th><th>Targets required</th></tr></thead><tbody>' +
        '<tr><td><strong>WAN1</strong></td><td>2 s</td><td>2 s</td><td>2</td><td>3</td><td>2 of 4</td></tr>' +
        '<tr><td>WAN2</td><td>5 s</td><td>3 s</td><td>3</td><td>3</td><td>1 of 3</td></tr>' +
        '<tr><td>WAN3</td><td>5 s</td><td>3 s</td><td>3</td><td>3</td><td>1 of 3</td></tr>' +
        '</tbody></table></div>' +
        '<p class="hint" style="margin-top:12px">Recovery is deliberately slower than failure detection. ' +
        'Failing over late costs you an outage; failing back late costs nothing, because traffic is ' +
        'already flowing. The asymmetry is what stops a flapping line from thrashing your connections.</p>' +
        '</div></div>');

    if (s.wans) renderStatusInto(s);
    wireWanEditCards(ifaces);

    $('#proto-save').onclick = function () {
      var body = { tcp_wan: $('#proto-tcp').value, udp_wan: $('#proto-udp').value };
      api('/mwan/protocol', { method: 'POST', body: body })
        .then(function (r) { toast(r.message, 'ok'); })
        .catch(function (e) { toast(e.message, 'error'); });
    };
  });
};

function wanEditCard(w) {
  var i = w.iface;
  var isStatic = w.proto === 'static';
  var isPppoe = w.proto === 'pppoe';
  return (
    '<div class="card" id="wan-edit-' + i + '"><div class="card-head"><div><h3>' + i.toUpperCase() + ' connection</h3>' +
      '<p>How this uplink gets its address.</p></div></div><div class="card-body">' +
      '<div class="form-row"><label class="field"><span>Type</span>' +
      '<select id="wan-proto-' + i + '">' +
        '<option value="dhcp"' + (w.proto === 'dhcp' ? ' selected' : '') + '>Automatic (DHCP)</option>' +
        '<option value="static"' + (isStatic ? ' selected' : '') + '>Static IP</option>' +
        '<option value="pppoe"' + (isPppoe ? ' selected' : '') + '>PPPoE</option>' +
      '</select></label></div>' +
      '<div id="wan-static-' + i + '" class="form-row"' + (isStatic ? '' : ' hidden') + '>' +
        f('wan-ip-' + i, 'IP address', w.ipaddr || '') +
        f('wan-mask-' + i, 'Netmask', w.netmask || '') +
        f('wan-gw-' + i, 'Gateway', w.gateway || '') +
      '</div>' +
      '<div id="wan-pppoe-' + i + '" class="form-row"' + (isPppoe ? '' : ' hidden') + '>' +
        f('wan-user-' + i, 'PPPoE username', w.pppoe_user || '') +
        f('wan-pass-' + i, 'PPPoE password', '', 'password') +
      '</div>' +
      '<div class="form-row">' + f('wan-dns-' + i, 'DNS servers (space-separated, optional)', w.dns || '') + '</div>' +
      (isPppoe && w.pppoe_has_password ? '<p class="hint">A password is already saved. Leave blank to keep it.</p>' : '') +
      '<button class="btn btn-primary" id="wan-save-' + i + '">Save ' + i.toUpperCase() + ' connection</button>' +
      '</div></div>'
  );
}

function wireWanEditCards(ifaces) {
  ifaces.forEach(function (i) {
    var sel = $('#wan-proto-' + i);
    if (!sel) return;
    sel.onchange = function () {
      $('#wan-static-' + i).hidden = sel.value !== 'static';
      $('#wan-pppoe-' + i).hidden = sel.value !== 'pppoe';
    };

    $('#wan-save-' + i).onclick = function () {
      var proto = sel.value;
      var body = { iface: i, proto: proto, dns: $('#wan-dns-' + i).value.trim() };
      if (proto === 'static') {
        body.ipaddr = $('#wan-ip-' + i).value.trim();
        body.netmask = $('#wan-mask-' + i).value.trim();
        body.gateway = $('#wan-gw-' + i).value.trim();
      } else if (proto === 'pppoe') {
        body.pppoe_user = $('#wan-user-' + i).value.trim();
        body.pppoe_password = $('#wan-pass-' + i).value;
      }

      confirmModal('Change ' + i.toUpperCase() + '\'s connection?',
        'This uplink will briefly drop while it reconnects with the new settings. ' +
        (i === 'wan1' ? 'Other WANs will carry traffic in the meantime if failover is active.' : ''),
        'Save', false).then(function (go) {
        if (!go) return;
        api('/wan', { method: 'POST', body: body })
          .then(function (r) { toast(r.message, 'ok'); })
          .catch(function (e) { toast(e.message, 'error'); });
      });
    };
  });
}

/* ======================= ports ======================= */

views.ports = function () {
  api('/ports').then(function (r) {
    var rows = (r.ports || []).map(function (p) {
      var res = r.results && r.results[p.role];
      return '<tr><td><strong>' + esc(p.port) + '</strong></td>' +
        '<td><span class="badge ' + (p.role.indexOf('wan') === 0 ? 'accent' : (p.role === 'lan' ? '' : 'warn')) + '">' +
          esc(p.role) + '</span></td>' +
        '<td>' + speedBadge(p.speed_mbps, p.carrier) + '</td>' +
        '<td>' + esc(p.duplex) + '</td>' +
        '<td class="mono" style="font-size:11.5px">' + esc(p.mac) + '</td>' +
        '<td>' + (res && res.tested_at ? esc(fmtAgo(res.tested_at)) : '—') + '</td></tr>';
    }).join('');

    var tests = ['wan1', 'wan2', 'wan3'].map(function (i) {
      var d = (r.results || {})[i] || {};
      var body;
      if (d.status === 'ok') {
        body = '<div class="grid c3" style="gap:10px">' +
          tile('Download', d.down_mbps ? d.down_mbps + ' Mb/s' : '—', 'measured', '') +
          tile('Upload', d.up_mbps ? d.up_mbps + ' Mb/s' : '—', 'measured', '') +
          tile('Latency', d.latency_ms ? d.latency_ms + ' ms' : '—', 'round trip', '') +
          '</div>' +
          '<div style="margin-top:12px;font-size:13px">' +
          kv('Provider', d.isp || 'not identified') +
          kv('ASN', d.asn || '—') +
          kv('Public IP', d.public_ip || '—') +
          kv('Gateway rDNS', d.gateway_rdns || '—') +
          kv('Tested', fmtAgo(d.tested_at)) + '</div>' +
          (d.note ? '<div class="alert alert-warn" style="margin-top:12px;margin-bottom:0">' + esc(d.note) + '</div>' : '');
      } else if (d.status === 'running') {
        body = '<div class="empty"><span class="spinner"></span> ' + esc(d.message || 'Testing…') + '</div>';
      } else if (d.status === 'nolink' || d.status === 'noaddr') {
        body = '<div class="alert alert-warn" style="margin-bottom:0">' + esc(d.message) + '</div>';
      } else {
        body = '<div class="empty">Not tested yet. Plug in a cable, or run a test manually.</div>';
      }
      return '<div class="card"><div class="card-head"><div><h3>' + i.toUpperCase() + '</h3></div>' +
        '<button class="btn btn-sm" data-test="' + i + '">Re-test</button></div>' +
        '<div class="card-body">' + body + '</div></div>';
    }).join('');

    page('Ports', 'Physical port roles and live negotiated link speed, read from the switch driver.',
      '<div class="card"><div class="card-head"><div><h3>Physical ports</h3>' +
        '<p>All five ports on this device are gigabit-capable. Speed shown is the actual negotiated rate.</p>' +
        '</div></div><div class="card-body tight"><div class="tbl-wrap"><table>' +
        '<thead><tr><th>Port</th><th>Role</th><th>Link</th><th>Duplex</th><th>MAC</th><th>Last test</th></tr></thead>' +
        '<tbody>' + rows + '</tbody></table></div></div></div>' +
      '<div class="alert alert-info"><strong>Speed tests consume real bandwidth.</strong>' +
        'They run once automatically when a cable is plugged in, and otherwise only when you press Re-test. ' +
        'They never run on a schedule. On a gigabit line the measured figure is limited by this router\'s CPU, ' +
        'not by your connection.</div>' +
      tests +
      '<div class="card"><div class="card-head"><div><h3>Reassign port roles</h3>' +
        '<p>Choose which physical ports carry which role. At least one LAN port is required.</p></div></div>' +
        '<div class="card-body" id="assign-form"></div></div>');

    $$('[data-test]').forEach(function (b) {
      b.onclick = function () {
        b.disabled = true; b.innerHTML = '<span class="spinner"></span>';
        api('/ports/test', { method: 'POST', body: { iface: b.getAttribute('data-test') } })
          .then(function () { toast('Test started.', 'ok'); setTimeout(views.ports, 2500); })
          .catch(function (e) { toast(e.message, 'error'); b.disabled = false; b.textContent = 'Re-test'; });
      };
    });

    renderAssignForm(r.ports);
  }).catch(function (e) { toast(e.message, 'error'); });
};

/* ======================= devices ======================= */

views.devices = function () {
  page('Devices', 'Every device this router knows about — named reservations plus anything currently on the network — with live throughput.',
    '<div class="card"><div class="card-body tight">' +
    '<div class="tbl-wrap"><table><thead><tr><th>Name</th><th>MAC</th><th>IP</th><th>Status</th>' +
    '<th>&darr; Mbps</th><th>&uarr; Mbps</th></tr></thead>' +
    '<tbody id="dev-tbody"><tr><td colspan="6" class="empty"><span class="spinner"></span></td></tr></tbody>' +
    '</table></div></div></div>' +
    '<p class="hint">Reserved devices show even while offline. Throughput is internet traffic only — ' +
    'device-to-device traffic on the LAN is not counted. The first reading after opening this page is ' +
    'always &mdash; a rate needs two samples a few seconds apart.</p>');
  pollDevices();
};

/* ======================= Nodes & Networks ======================= */

views.nodes = function () {
  Promise.all([api('/nodes'), api('/devices')]).then(function (res) {
    var nodes = res[0].nodes || [];
    var devices = res[1].devices || [];
    var nodeMacs = {};
    nodes.forEach(function (n) { if (n.mac) nodeMacs[n.mac.toLowerCase()] = 1; });
    var candidates = devices.filter(function (d) { return d.mac && !nodeMacs[d.mac.toLowerCase()]; });

    page('Nodes &amp; Networks',
      'The router and access points behind this box — status, current throughput, and a quick link into each one’s own admin panel.',
      '<div class="card"><div class="card-head"><h3>Nodes</h3></div><div class="card-body tight">' +
      '<div class="tbl-wrap"><table><thead><tr><th>Name</th><th>Type</th><th>IP</th><th>Status</th>' +
      '<th>&darr; Mbps</th><th>&uarr; Mbps</th><th>Reachability</th><th></th></tr></thead>' +
      '<tbody id="node-tbody"><tr><td colspan="8" class="empty"><span class="spinner"></span></td></tr></tbody>' +
      '</table></div></div></div>' +
      '<p class="hint">Throughput is internet traffic only, same as the Devices page — a node running as a plain ' +
      'access point (bridged) won’t show meaningful usage here since its own clients already appear individually ' +
      'on Devices; a node routing its own traffic (double-NAT) will. "Reachability" is a ping test (latency/loss) ' +
      'run on demand — real down/up throughput to an arbitrary node would need software this app can\'t assume ' +
      'is installed on it.</p>' +

      '<div class="card"><div class="card-head"><h3>Recent activity</h3></div><div class="card-body tight">' +
      '<div class="tbl-wrap"><table><thead><tr><th>When</th><th>What</th><th>Event</th></tr></thead>' +
      '<tbody id="history-tbody"><tr><td colspan="3" class="empty"><span class="spinner"></span></td></tr></tbody>' +
      '</table></div></div></div>' +
      '<p class="hint">Online/offline transitions for all three WAN lines and every added node, most recent first.</p>' +

      '<div class="card"><div class="card-head"><h3>Add a node</h3></div><div class="card-body">' +
      (candidates.length ?
        '<p class="hint" style="margin-top:0">Seen on the network now, not yet added as a node:</p>' +
        '<div class="tbl-wrap"><table><thead><tr><th>Name</th><th>MAC</th><th>IP</th><th></th></tr></thead><tbody>' +
        candidates.map(function (d) {
          return '<tr><td>' + esc(d.name) + '</td>' +
            '<td class="mono" style="font-size:11.5px">' + esc(d.mac) + '</td>' +
            '<td class="mono">' + esc(d.ip) + '</td>' +
            '<td><button class="btn btn-sm" data-pick-node="' + esc(d.mac) + '|' + esc(d.ip) + '|' + esc(d.name) + '">Add as node</button></td></tr>';
        }).join('') + '</tbody></table></div>' : '<p class="hint" style="margin-top:0">Nothing new seen on the ' +
        'network right now — you can still add one by hand below if it’s offline.</p>') +
      '<div class="form-row" style="margin-top:14px">' +
        f('nd-name', 'Name', '') + f('nd-mac', 'MAC address', '') +
        '<label class="field"><span>Type</span><select id="nd-kind">' +
        '<option value="router">Router</option><option value="ap">Access point</option>' +
        '<option value="other">Other</option></select></label></div>' +
      '<label class="field"><span>Admin panel URL (optional)</span>' +
      '<input type="text" id="nd-url" placeholder="http://192.168.10.50/ — leave blank to guess from its IP"></label>' +
      '<button class="btn" id="nd-add">Add node</button></div></div>');

    $$('[data-pick-node]').forEach(function (b) {
      b.onclick = function () {
        var p = b.getAttribute('data-pick-node').split('|');
        $('#nd-mac').value = p[0];
        $('#nd-url').value = p[1] ? 'http://' + p[1] + '/' : '';
        $('#nd-name').value = p[2] === 'unnamed' ? '' : p[2];
        $('#nd-name').scrollIntoView({ behavior: 'smooth', block: 'center' });
        $('#nd-name').focus();
      };
    });

    $('#nd-add').onclick = function () {
      var name = $('#nd-name').value.trim();
      if (!name) { toast('Give the node a name.', 'error'); return; }
      api('/nodes/add', { method: 'POST', body: {
        name: name, mac: $('#nd-mac').value.trim(), kind: $('#nd-kind').value, admin_url: $('#nd-url').value.trim()
      }}).then(function (r) {
        toast(r.message, 'ok');
        views.nodes();
      }).catch(function (e) { toast(e.message, 'error'); });
    };

    pollNodes();
  }).catch(function () {});
};

function kv(k, v) {
  return '<div style="display:flex;justify-content:space-between;padding:5px 0;border-bottom:1px solid var(--border)">' +
    '<span style="color:var(--text-dim)">' + esc(k) + '</span><span class="mono">' + esc(v) + '</span></div>';
}

function renderAssignForm(ports) {
  var names = ports.map(function (p) { return p.port; });
  function sel(id, label, cur) {
    return '<label class="field"><span>' + esc(label) + '</span><select id="' + id + '">' +
      names.map(function (n) {
        return '<option value="' + esc(n) + '"' + (n === cur ? ' selected' : '') + '>' + esc(n) + '</option>';
      }).join('') + '</select></label>';
  }
  function cur(role) { var p = ports.filter(function (x) { return x.role === role; })[0]; return p ? p.port : ''; }
  var lanPorts = ports.filter(function (p) { return p.role === 'lan'; }).map(function (p) { return p.port; });

  $('#assign-form').innerHTML =
    '<div class="form-row">' + sel('as-w1', 'WAN1 (priority)', cur('wan1')) +
      sel('as-w2', 'WAN2', cur('wan2')) + sel('as-w3', 'WAN3', cur('wan3')) + '</div>' +
    '<label class="field"><span>LAN ports</span><select id="as-lan" multiple size="5" style="height:auto">' +
      names.map(function (n) {
        return '<option value="' + esc(n) + '"' + (lanPorts.indexOf(n) >= 0 ? ' selected' : '') + '>' + esc(n) + '</option>';
      }).join('') + '</select></label>' +
    '<p class="hint">Hold Ctrl (Cmd on Mac) to select more than one.</p>' +
    '<button class="btn btn-primary" id="as-save">Apply port layout</button>';

  $('#as-save').onclick = function () {
    var lan = $$('#as-lan option').filter(function (o) { return o.selected; }).map(function (o) { return o.value; });
    if (!lan.length) { toast('Select at least one LAN port, or you will lose access to this page.', 'error'); return; }
    confirmModal('Reassign ports?',
      'The network will reload. If the port you are connected through changes role, ' +
      'your connection will drop and you will need to move the cable.',
      'Apply layout').then(function (go) {
      if (!go) return;
      api('/ports/assign', { method: 'POST', body: {
        wan1: $('#as-w1').value, wan2: $('#as-w2').value, wan3: $('#as-w3').value, lan: lan.join(' ')
      }}).then(function (r) { toast(r.message, 'ok'); })
        .catch(function (e) { toast(e.message, 'error'); });
    });
  };
}

/* ======================= LAN & DHCP ======================= */

views.lan = function () {
  Promise.all([api('/lan'), api('/dhcp/leases')]).then(function (res) {
    var l = res[0], d = res[1];
    var leases = (d.leases || []).map(function (x) {
      // from_lease=false means this row came from the kernel's ARP table,
      // not dnsmasq's lease file — a device that's genuinely on the network
      // but hasn't DHCP'd since dnsmasq last restarted. It has no recorded
      // hostname because that name only ever comes from the DHCP handshake
      // itself, so flag it rather than silently showing a blank as if the
      // device just has no name.
      var nameCell = x.hostname ? esc(x.hostname)
        : (x.from_lease ? '—' : '<span title="Seen on the network, but has not renewed its DHCP lease since the last restart — no hostname available yet.">unnamed &middot; seen on network</span>');
      return '<tr><td>' + nameCell + '</td><td class="mono">' + esc(x.ip) + '</td>' +
        '<td class="mono" style="font-size:11.5px">' + esc(x.mac) + '</td>' +
        '<td><button class="btn btn-sm" data-reserve="' + esc(x.mac) + '|' + esc(x.ip) + '|' + esc(x.hostname || 'device') + '">Reserve</button></td></tr>';
    }).join('') || '<tr><td colspan="4" class="empty">No active leases.</td></tr>';

    // Free IPs within the configured DHCP pool — offered as suggestions when
    // adding a new reservation, not a hard restriction: the Reserve button
    // needs to pre-fill an address that is very much already in use (the
    // device's current lease), so this stays a plain text field with a
    // <datalist> attached rather than a <select>, which could only ever
    // contain values that aren't already taken.
    var freeIps = (function () {
      var m = /^(\d+\.\d+\.\d+\.)(\d+)$/.exec(l.ipaddr || '');
      var start = parseInt(l.dhcp_start, 10), limit = parseInt(l.dhcp_limit, 10);
      if (!m || !start || !limit) return [];
      var base = m[1];
      var used = {}; used[l.ipaddr] = 1;
      (d.leases || []).forEach(function (x) { used[x.ip] = 1; });
      (d.static || []).forEach(function (x) { used[x.ip] = 1; });
      var free = [];
      for (var i = start; i < start + limit; i++) {
        var ip = base + i;
        if (!used[ip]) free.push(ip);
      }
      return free;
    })();

    var statics = (d.static || []).map(function (x) {
      return '<tr><td>' + esc(x.name) + '</td><td class="mono">' + esc(x.ip) + '</td>' +
        '<td class="mono" style="font-size:11.5px">' + esc(x.mac) + '</td>' +
        '<td style="white-space:nowrap">' +
        '<button class="btn btn-sm" data-rename="' + esc(x.mac) + '|' + esc(x.ip) + '|' + esc(x.name) + '">Rename</button> ' +
        '<button class="btn btn-sm btn-ghost" data-del-static="' + esc(x.id) + '">Remove</button></td></tr>';
    }).join('') || '<tr><td colspan="4" class="empty">No reservations.</td></tr>';

    page('LAN &amp; DHCP', 'Local network addressing and the DHCP server.',
      '<div class="card"><div class="card-head"><h3>LAN settings</h3></div><div class="card-body">' +
        (l.hostname_alias ?
          '<p class="hint" style="margin-top:0">Always reachable at <strong>http://' + esc(l.hostname_alias) +
          '</strong>, whatever the router IP below is set to — bookmark that instead of an address.</p>' : '') +
        '<div class="form-row">' +
        f('lan-ip', 'Router IP address', l.ipaddr) + f('lan-mask', 'Subnet mask', l.netmask) + '</div>' +
        '<div class="form-row">' +
        f('lan-start', 'DHCP start offset', l.dhcp_start) + f('lan-limit', 'Pool size', l.dhcp_limit) +
        f('lan-lease', 'Lease time', l.dhcp_lease) + '</div>' +
        '<label class="switch"><input type="checkbox" id="lan-dhcp"' + (l.dhcp_enabled ? ' checked' : '') +
          '><span class="track"></span><span>DHCP server enabled</span></label>' +
        '<button class="btn btn-primary" id="lan-save">Save LAN settings</button></div></div>' +
      '<div class="card"><div class="card-head"><h3>Active leases</h3></div><div class="card-body tight">' +
        '<div class="tbl-wrap"><table><thead><tr><th>Host</th><th>Address</th><th>MAC</th><th></th></tr></thead>' +
        '<tbody>' + leases + '</tbody></table></div></div></div>' +
      '<div class="card"><div class="card-head"><h3>Static reservations</h3></div><div class="card-body tight">' +
        '<div class="tbl-wrap"><table><thead><tr><th>Name</th><th>Address</th><th>MAC</th><th></th></tr></thead>' +
        '<tbody>' + statics + '</tbody></table></div></div>' +
        '<div class="card-body" style="border-top:1px solid var(--border)">' +
        '<div class="form-row">' + f('st-name', 'Name', '') + f('st-mac', 'MAC address', '') +
        '<label class="field"><span>IP address</span>' +
        '<input type="text" id="st-ip" list="st-ip-list" placeholder="' + (freeIps[0] || '') + '"></label>' +
        '<datalist id="st-ip-list">' + freeIps.map(function (ip) { return '<option value="' + ip + '">'; }).join('') + '</datalist>' +
        '</div>' +
        '<p class="hint" style="margin:2px 0 10px">' + freeIps.length + ' address' + (freeIps.length === 1 ? '' : 'es') +
        ' free in the DHCP pool — start typing in IP address for suggestions.</p>' +
        '<button class="btn" id="st-add">Add reservation</button></div></div>');

    $('#lan-save').onclick = function () {
      confirmModal('Change LAN settings?',
        'If the router address changes, this page will automatically reconnect you at the new ' +
        'address once the router is ready — your computer may still need to renew its DHCP lease ' +
        'first if it can\'t get there.', 'Save', false).then(function (go) {
        if (!go) return;
        api('/lan', { method: 'POST', body: {
          ipaddr: $('#lan-ip').value, netmask: $('#lan-mask').value,
          dhcp_start: $('#lan-start').value, dhcp_limit: $('#lan-limit').value,
          dhcp_lease: $('#lan-lease').value, dhcp_enabled: $('#lan-dhcp').checked ? '1' : '0'
        }}).then(function (r) {
          toast(r.message, 'ok');
          if (r.redirect_url) redirectWhenReachable(r.redirect_url);
        }).catch(function (e) { toast(e.message, 'error'); });
      });
    };

    $$('[data-reserve]').forEach(function (b) {
      b.onclick = function () {
        var p = b.getAttribute('data-reserve').split('|');
        $('#st-mac').value = p[0]; $('#st-ip').value = p[1]; $('#st-name').value = p[2];
        $('#st-name').scrollIntoView({ behavior: 'smooth', block: 'center' });
        $('#st-name').focus();
      };
    });

    // Same form, same trick: /dhcp/static/add keys its UCI section off the MAC
    // address, so resubmitting a MAC that already has a reservation overwrites
    // that entry in place rather than creating a second one. This button is
    // just a shortcut that pre-fills the existing values so you only have to
    // change the name.
    $$('[data-rename]').forEach(function (b) {
      b.onclick = function () {
        var p = b.getAttribute('data-rename').split('|');
        $('#st-mac').value = p[0]; $('#st-ip').value = p[1]; $('#st-name').value = p[2];
        $('#st-name').scrollIntoView({ behavior: 'smooth', block: 'center' });
        $('#st-name').focus();
        $('#st-name').select();
      };
    });

    $('#st-add').onclick = function () {
      api('/dhcp/static/add', { method: 'POST', body: {
        name: $('#st-name').value, mac: $('#st-mac').value, ip: $('#st-ip').value
      }}).then(function (r) { toast(r.message, 'ok'); views.lan(); })
        .catch(function (e) { toast(e.message, 'error'); });
    };

    $$('[data-del-static]').forEach(function (b) {
      b.onclick = function () {
        api('/dhcp/static/del', { method: 'POST', body: { id: b.getAttribute('data-del-static') } })
          .then(function (r) { toast(r.message, 'ok'); views.lan(); })
          .catch(function (e) { toast(e.message, 'error'); });
      };
    });
  }).catch(function (e) { toast(e.message, 'error'); });
};

function f(id, label, val, type) {
  return '<label class="field"><span>' + esc(label) + '</span>' +
    '<input type="' + (type || 'text') + '" id="' + id + '" value="' + esc(val) + '"></label>';
}

/* ======================= Wi-Fi ======================= */

views.wifi = function () {
  api('/wifi').then(function (r) {
    var radios = (r.radios || []).map(function (rd) {
      return '<div class="card"><div class="card-head"><div><h3>' + esc(rd.band || rd.id) + ' radio</h3>' +
        '<p>' + esc(rd.id) + '</p></div></div><div class="card-body">' +
        '<div class="form-row">' +
        '<label class="field"><span>Channel</span><input type="text" id="rc-' + esc(rd.id) + '" value="' + esc(rd.channel) + '"></label>' +
        '<label class="field"><span>Width</span><select id="rw-' + esc(rd.id) + '">' +
          ['HT20', 'HT40', 'VHT20', 'VHT40', 'VHT80'].map(function (m) {
            return '<option' + (m === rd.htmode ? ' selected' : '') + '>' + m + '</option>';
          }).join('') + '</select></label>' +
        '<label class="field"><span>Country</span><input type="text" id="rn-' + esc(rd.id) + '" value="' + esc(rd.country) + '"></label>' +
        '</div>' +
        '<label class="switch"><input type="checkbox" id="rd-' + esc(rd.id) + '"' + (rd.disabled ? '' : ' checked') +
          '><span class="track"></span><span>Radio enabled</span></label>' +
        '<button class="btn" data-radio="' + esc(rd.id) + '">Save radio</button></div></div>';
    }).join('');

    var nets = (r.networks || []).map(function (n) {
      return '<div class="card"><div class="card-head"><div><h3>' + esc(n.ssid) + '</h3>' +
        '<p>' + esc(n.device) + ' → ' + esc(n.network) + (n.isolate ? ' · client isolation on' : '') + '</p></div>' +
        '<span class="badge ' + (n.disabled ? '' : 'ok') + '">' + (n.disabled ? 'Disabled' : 'Broadcasting') + '</span>' +
        '</div><div class="card-body">' +
        '<div class="form-row">' +
        '<label class="field"><span>Network name (SSID)</span><input type="text" id="ws-' + esc(n.id) + '" value="' + esc(n.ssid) + '"></label>' +
        '<label class="field"><span>Security</span><select id="we-' + esc(n.id) + '">' +
          [['psk2', 'WPA2-PSK'], ['psk-mixed', 'WPA2/WPA mixed'], ['sae', 'WPA3-SAE'], ['sae-mixed', 'WPA2/WPA3 mixed'], ['none', 'Open (no password)']]
            .map(function (o) { return '<option value="' + o[0] + '"' + (o[0] === n.encryption ? ' selected' : '') + '>' + o[1] + '</option>'; }).join('') +
          '</select></label>' +
        '<label class="field"><span>Password</span><input type="password" id="wk-' + esc(n.id) + '" placeholder="unchanged"></label>' +
        '</div>' +
        '<label class="switch"><input type="checkbox" id="wd-' + esc(n.id) + '"' + (n.disabled ? '' : ' checked') +
          '><span class="track"></span><span>Broadcast this network</span></label>' +
        '<button class="btn btn-primary" data-wifi="' + esc(n.id) + '">Save network</button></div></div>';
    }).join('');

    var clients = (r.clients || []).map(function (c) {
      return '<tr><td class="mono">' + esc(c.mac) + '</td><td>' + esc(c.iface) + '</td>' +
        '<td>' + esc(c.signal_dbm) + ' dBm</td></tr>';
    }).join('') || '<tr><td colspan="3" class="empty">No wireless clients connected.</td></tr>';

    page('Wi-Fi', 'This device is AC1200 — 2.4 GHz and 5 GHz only. There is no 6 GHz radio.',
      '<div class="alert alert-warn"><strong>WPA3 needs a package change.</strong>' +
        'The stock image ships <code>wpad-basic-mbedtls</code>, which cannot do SAE. ' +
        'Install <code>wpad-mbedtls</code> in its place before selecting a WPA3 mode.</div>' +
      radios + nets +
      '<div class="card"><div class="card-head"><h3>Connected clients</h3></div><div class="card-body tight">' +
      '<div class="tbl-wrap"><table><thead><tr><th>MAC</th><th>Interface</th><th>Signal</th></tr></thead>' +
      '<tbody>' + clients + '</tbody></table></div></div></div>');

    $$('[data-radio]').forEach(function (b) {
      var id = b.getAttribute('data-radio');
      b.onclick = function () {
        api('/wifi/radio', { method: 'POST', body: {
          id: id, channel: $('#rc-' + id).value, htmode: $('#rw-' + id).value,
          country: $('#rn-' + id).value, disabled: $('#rd-' + id).checked ? '0' : '1'
        }}).then(function (r) { toast(r.message, 'ok'); }).catch(function (e) { toast(e.message, 'error'); });
      };
    });

    $$('[data-wifi]').forEach(function (b) {
      var id = b.getAttribute('data-wifi');
      b.onclick = function () {
        var body = { id: id, ssid: $('#ws-' + id).value, encryption: $('#we-' + id).value,
                     disabled: $('#wd-' + id).checked ? '0' : '1' };
        var k = $('#wk-' + id).value;
        if (k) body.key = k;
        api('/wifi', { method: 'POST', body: body })
          .then(function (r) { toast(r.message, 'ok'); })
          .catch(function (e) { toast(e.message, 'error'); });
      };
    });
  }).catch(function (e) { toast(e.message, 'error'); });
};

/* ======================= DNS ======================= */

views.dns = function () {
  Promise.all([api('/dns'), api('/adblock'), api('/blocklist'), api('/blocklist/adult'), api('/blocklist/games'), api('/nodes')])
    .then(function (res) {
    var r = res[0], ab = res[1], bl = res[2], adult = res[3], games = res[4], nodes = (res[5].nodes || []);
    var nodeLinks = nodes.filter(function (n) { return n.admin_url; }).map(function (n) {
      return '<div style="display:flex;justify-content:space-between;align-items:center;padding:5px 0;' +
        'border-bottom:1px solid var(--border)"><span style="color:var(--text-dim)">' + esc(n.name) +
        (n.ip ? ' <span class="mono">(' + esc(n.ip) + ')</span>' : '') + '</span>' +
        '<a class="btn btn-sm" href="' + esc(n.admin_url) + '" target="_blank" rel="noopener">Open admin panel</a></div>';
    }).join('');
    page('DNS', 'Resolvers used by every device on the LAN.',
      '<div class="alert alert-info"><strong>Why DNS is pinned centrally.</strong>' +
        'With three uplinks, letting each ISP inject its own resolvers would mean name resolution ' +
        'silently changing identity on every failover — a notoriously hard problem to diagnose. ' +
        'These servers are used regardless of which WAN is live.</div>' +
      '<div class="card"><div class="card-head"><h3>Resolvers</h3></div><div class="card-body">' +
      '<label class="field"><span>DNS servers (one per line)</span>' +
      '<textarea id="dns-list">' + esc((r.servers || []).join('\n')) + '</textarea></label>' +
      '<label class="switch"><input type="checkbox" id="dns-ignore"' + (r.ignore_isp_dns ? ' checked' : '') +
        '><span class="track"></span><span>Ignore DNS servers supplied by the ISPs</span></label>' +
      '<button class="btn btn-primary" id="dns-save">Save DNS settings</button></div></div>' +
      '<div class="card"><div class="card-head"><h3>Ad blocking</h3></div><div class="card-body">' +
      '<label class="switch"><input type="checkbox" id="ab-enabled"' + (ab.enabled ? ' checked' : '') +
        '><span class="track"></span><span>Block ads and trackers network-wide</span></label>' +
      '<p class="hint" style="margin:10px 0">DNS-based blocking, network-wide, no app or per-device setup — ' +
      'every device gets it automatically. This is the blocking engine only: no dashboard, no query history, ' +
      'no per-device rules, deliberately, to keep it under 200 KB on a 16 MB router.</p>' +
      '<div class="grid c3" style="gap:10px;margin-top:14px">' +
      tile('Status', ab.status, '', ab.status === 'enabled' ? 'ok' : '') +
      tile('Domains blocked', ab.blocked_domains, '', '') +
      tile('Last update', ab.last_run, '', '') +
      '</div></div></div>' +
      '<div class="card"><div class="card-head"><h3>Website blocking</h3></div><div class="card-body">' +
      '<label class="switch"><input type="checkbox" id="bl-enabled"' + (bl.enabled ? ' checked' : '') +
        '><span class="track"></span><span>Enable custom blocklist</span></label>' +
      '<p class="hint" style="margin:10px 0">Block specific sites by domain, network-wide, on top of the ' +
      'ad/tracker feeds above. Blocking a domain here blocks it and every subdomain of it.</p>' +
      '<div class="form-row"><label class="field" style="flex:1"><span>Domain</span>' +
      '<input type="text" id="bl-domain" placeholder="example.com"></label>' +
      '<button class="btn btn-primary" id="bl-add" style="align-self:flex-end">Block</button></div>' +
      '<div class="tbl-wrap" style="margin-top:12px"><table><tbody id="bl-tbody">' +
      (bl.domains || []).map(function (d) {
        return '<tr><td class="mono">' + esc(d) + '</td><td style="width:1%;white-space:nowrap">' +
          '<button class="btn btn-sm btn-ghost" data-del-bl="' + esc(d) + '">Remove</button></td></tr>';
      }).join('') +
      '</tbody></table></div>' +
      ((bl.domains || []).length ? '' : '<p class="empty">No sites blocked yet.</p>') +
      '</div></div>' +

      '<div class="card"><div class="card-head"><h3>18+ content</h3></div><div class="card-body">' +
      '<label class="switch"><input type="checkbox" id="cat-adult"' + (adult.enabled ? ' checked' : '') +
        '><span class="track"></span><span>Block adult content network-wide</span></label>' +
      '<p class="hint" style="margin-top:10px">One click, network-wide. Uses <code>oisd_nsfw_small</code>, a ' +
      'curated adult-content DNS feed (~21,000 domains) already available through the ad-blocking engine above — ' +
      'sized to actually run on this router, unlike the much larger raw lists some sites publish.</p>' +
      '</div></div>' +

      '<div class="card"><div class="card-head"><h3>Games</h3></div><div class="card-body">' +
      '<label class="switch"><input type="checkbox" id="cat-games"' + (games.enabled ? ' checked' : '') +
        '><span class="track"></span><span>Block gaming platforms network-wide</span></label>' +
      '<p class="hint" style="margin:10px 0">There is no equivalent ready-made public list for this the way there ' +
      'is for ads or adult content, so this is a starter list of common gaming platforms (Steam, Epic Games, ' +
      'Roblox, Xbox Live, PlayStation, Nintendo, Battle.net, Twitch, and a few browser game sites) that turns on ' +
      'when you enable this &mdash; edit it below like the custom list above.</p>' +
      '<div class="form-row"><label class="field" style="flex:1"><span>Domain</span>' +
      '<input type="text" id="cg-domain" placeholder="example.com"></label>' +
      '<button class="btn btn-primary" id="cg-add" style="align-self:flex-end">Block</button></div>' +
      '<div class="tbl-wrap" style="margin-top:12px"><table><tbody id="cg-tbody">' +
      (games.domains || []).map(function (d) {
        return '<tr><td class="mono">' + esc(d) + '</td><td style="width:1%;white-space:nowrap">' +
          '<button class="btn btn-sm btn-ghost" data-del-cg="' + esc(d) + '">Remove</button></td></tr>';
      }).join('') +
      '</tbody></table></div>' +
      ((games.domains || []).length ? '' : '<p class="empty">No sites blocked yet.</p>') +
      '</div></div>' +

      (nodeLinks ? '<div class="card"><div class="card-head"><h3>Downstream routers &amp; access points</h3></div>' +
        '<div class="card-body">' +
        '<p class="hint" style="margin-top:0">If a device on this list runs its own DHCP/DNS (common for a mesh ' +
        'node or a second router), the blocking above only covers clients using this router\'s DNS directly &mdash; ' +
        'open its own admin panel to apply the same blocking there.</p>' + nodeLinks + '</div></div>' : ''));

    $('#dns-save').onclick = function () {
      api('/dns', { method: 'POST', body: {
        servers: $('#dns-list').value.split(/\s+/).filter(Boolean).join(' '),
        ignore_isp_dns: $('#dns-ignore').checked ? '1' : '0'
      }}).then(function (r) { toast(r.message, 'ok'); }).catch(function (e) { toast(e.message, 'error'); });
    };

    $('#bl-enabled').onchange = function () {
      var cb = this;
      cb.disabled = true;
      api('/blocklist', { method: 'POST', body: { enabled: cb.checked ? '1' : '0' } })
        .then(function (r) { toast(r.message, 'ok'); cb.disabled = false; })
        .catch(function (e) { toast(e.message, 'error'); cb.checked = !cb.checked; cb.disabled = false; });
    };

    $('#bl-add').onclick = function () {
      var d = $('#bl-domain').value.trim();
      if (!d) return;
      api('/blocklist/add', { method: 'POST', body: { domain: d } })
        .then(function (r) { toast(r.message, 'ok'); views.dns(); })
        .catch(function (e) { toast(e.message, 'error'); });
    };

    $$('[data-del-bl]').forEach(function (b) {
      b.onclick = function () {
        api('/blocklist/del', { method: 'POST', body: { domain: b.getAttribute('data-del-bl') } })
          .then(function (r) { toast(r.message, 'ok'); views.dns(); })
          .catch(function (e) { toast(e.message, 'error'); });
      };
    });

    $('#ab-enabled').onchange = function () {
      var cb = this;
      cb.disabled = true;
      api('/adblock', { method: 'POST', body: { enabled: cb.checked ? '1' : '0' } })
        .then(function (r) { toast(r.message, 'ok'); setTimeout(views.dns, 1500); })
        .catch(function (e) { toast(e.message, 'error'); cb.checked = !cb.checked; cb.disabled = false; });
    };

    $('#cat-adult').onchange = function () {
      var cb = this;
      cb.disabled = true;
      api('/blocklist/adult', { method: 'POST', body: { enabled: cb.checked ? '1' : '0' } })
        .then(function (r) { toast(r.message, 'ok'); setTimeout(views.dns, 1500); })
        .catch(function (e) { toast(e.message, 'error'); cb.checked = !cb.checked; cb.disabled = false; });
    };

    $('#cat-games').onchange = function () {
      var cb = this;
      cb.disabled = true;
      api('/blocklist/games', { method: 'POST', body: { enabled: cb.checked ? '1' : '0' } })
        .then(function (r) { toast(r.message, 'ok'); views.dns(); })
        .catch(function (e) { toast(e.message, 'error'); cb.checked = !cb.checked; cb.disabled = false; });
    };

    $('#cg-add').onclick = function () {
      var d = $('#cg-domain').value.trim();
      if (!d) return;
      api('/blocklist/games/add', { method: 'POST', body: { domain: d } })
        .then(function (r) { toast(r.message, 'ok'); views.dns(); })
        .catch(function (e) { toast(e.message, 'error'); });
    };

    $$('[data-del-cg]').forEach(function (b) {
      b.onclick = function () {
        api('/blocklist/games/del', { method: 'POST', body: { domain: b.getAttribute('data-del-cg') } })
          .then(function (r) { toast(r.message, 'ok'); views.dns(); })
          .catch(function (e) { toast(e.message, 'error'); });
      };
    });
  }).catch(function (e) { toast(e.message, 'error'); });
};

/* ======================= firewall ======================= */

views.firewall = function () {
  api('/firewall').then(function (r) {
    // Group by mapping name so "Chowkidar" with three ports reads as one
    // entry with a disclosure, not three visually-identical rows — matching
    // how the ISP's own port-mapping UI presents a multi-port mapping.
    var groupOrder = [], groups = {};
    (r.forwards || []).forEach(function (x) {
      if (!groups[x.name]) { groups[x.name] = []; groupOrder.push(x.name); }
      groups[x.name].push(x);
    });

    function fwEditKey(x) {
      return [x.id, x.name, x.proto, x.src_dport, x.dest_ip, x.dest_port]
        .map(function (v) { return String(v).replace(/\|/g, ''); }).join('|');
    }

    var fwd = groupOrder.map(function (name, gi) {
      var items = groups[name];
      var ips = items.map(function (x) { return x.dest_ip; })
        .filter(function (v, i, a) { return a.indexOf(v) === i; });
      var ipSummary = ips.length === 1 ? ips[0] : ips.length + ' different IPs';
      var portSummary = items.map(function (x) { return x.src_dport; }).join(', ');

      var head =
        '<tr class="pf-group-row" data-group-toggle="' + gi + '" style="cursor:pointer">' +
        '<td><span data-group-chevron="' + gi + '" style="display:inline-block;width:14px">&#9656;</span>' +
          esc(name) + ' <span class="badge">' + items.length + (items.length > 1 ? ' ports' : ' port') + '</span></td>' +
        '<td class="mono">' + esc(portSummary) + '</td>' +
        '<td colspan="2" class="mono">' + esc(ipSummary) + '</td></tr>';

      var subRows = items.map(function (x) {
        return '<tr class="pf-sub-row" data-group="' + gi + '" hidden>' +
          '<td style="padding-left:26px">' + esc(x.proto) + '</td>' +
          '<td class="mono">' + esc(x.src_dport) + '</td>' +
          '<td class="mono">' + esc(x.dest_ip) + ':' + esc(x.dest_port) + '</td>' +
          '<td style="white-space:nowrap">' +
          '<button class="btn btn-sm" data-edit-fw="' + esc(fwEditKey(x)) + '">Edit</button> ' +
          '<button class="btn btn-sm btn-ghost" data-del-fw="' + esc(x.id) + '">Remove</button></td></tr>';
      }).join('');

      return head + subRows;
    }).join('') || '<tr><td colspan="4" class="empty">No port forwards.</td></tr>';

    page('Firewall', 'Port forwarding, DMZ, UPnP, and remote administration.',
      '<div class="card"><div class="card-head"><h3>Port forwards</h3></div><div class="card-body tight">' +
        '<div class="tbl-wrap"><table><thead><tr><th>Mapping / port</th><th>External</th><th>Internal</th><th></th></tr></thead>' +
        '<tbody>' + fwd + '</tbody></table></div></div>' +
        '<div class="card-body" style="border-top:1px solid var(--border)">' +
        '<div class="form-row">' + f('pf-name', 'Mapping name', '') + f('pf-dip', 'Internal IP', '') + '</div>' +
        '<p class="hint" style="margin:2px 0 10px">Add one port per row, or several — like the RTSP/HTTP/alt-HTTP ' +
        'ports a camera system needs — under this one mapping name in a single Save.</p>' +
        '<div id="pf-rows"></div>' +
        '<button class="btn btn-sm btn-ghost" id="pf-add-row" type="button" style="margin-bottom:12px">+ Add another port</button>' +
        '<div><button class="btn btn-primary" id="pf-add">Save mapping</button></div>' +
        '<p class="hint" style="margin-top:10px">Forwards apply to all three WAN uplinks. ' +
        'After a failover the public address changes, so anything reaching you by IP will need the new one — ' +
        'consider Dynamic DNS.</p></div></div>' +

      '<div class="card"><div class="card-head"><h3>Exposure</h3></div><div class="card-body">' +
        f('dmz-host', 'DMZ host (blank to disable)', r.dmz_host || '') +
        '<p class="hint">A DMZ host receives all unsolicited inbound traffic on every WAN. ' +
        'Use a specific port forward instead wherever you can.</p>' +
        '<label class="switch"><input type="checkbox" id="upnp"' + (r.upnp_enabled ? ' checked' : '') +
          '><span class="track"></span><span>UPnP (lets LAN devices open ports by themselves)</span></label>' +
        '<button class="btn" id="fw-save">Save</button></div></div>' +

      '<div class="card"><div class="card-head"><h3>Remote administration</h3></div><div class="card-body">' +
        (r.remote_admin
          ? '<div class="alert alert-error"><strong>This admin panel is currently reachable from the internet.</strong>' +
            'Anyone who can reach your WAN address can attempt to log in. This panel is served over plain HTTP, ' +
            'so your password crosses the internet unencrypted. Turn this off unless you are certain you need it.</div>'
          : '<div class="alert alert-info"><strong>The admin panel is LAN-only.</strong>' +
            'This is the correct setting. The web server binds only to the LAN address, and no WAN firewall rule exists.</div>') +
        '<label class="switch"><input type="checkbox" id="remote"' + (r.remote_admin ? ' checked' : '') +
          '><span class="track"></span><span>Allow administration from the internet</span></label>' +
        '<button class="btn ' + (r.remote_admin ? '' : 'btn-danger') + '" id="remote-save">Apply</button></div></div>' +

      '<div class="card"><div class="card-head"><h3>Acceleration</h3></div><div class="card-body">' +
        kv('Software flow offload', r.sw_offload ? 'enabled' : 'disabled') +
        kv('Hardware flow offload', r.hw_offload ? 'enabled' : 'disabled (required for mwan3)') +
        '<p class="hint" style="margin-top:12px">Hardware offload bypasses the packet marking that mwan3 uses to steer ' +
        'traffic, so failover silently stops working when it is on. It is deliberately disabled. ' +
        'This is why routed throughput peaks around 300–500 Mbps rather than gigabit.</p></div></div>');

    var pfRowN = 0;
    function pfAddRow(ext, intPort, proto, editId) {
      var n = pfRowN++;
      var row = document.createElement('div');
      row.className = 'form-row pf-row';
      row.dataset.row = n;
      if (editId) row.dataset.editId = editId;
      row.innerHTML =
        '<label class="field"><span>Protocol</span><select id="pf-proto-' + n + '">' +
        '<option value="tcp"' + (proto === 'tcp' ? ' selected' : '') + '>TCP</option>' +
        '<option value="udp"' + (proto === 'udp' ? ' selected' : '') + '>UDP</option>' +
        '<option value="tcp udp"' + (!proto || proto === 'tcp udp' ? ' selected' : '') + '>TCP + UDP</option>' +
        '</select></label>' +
        f('pf-ext-' + n, 'External port', ext || '') +
        f('pf-int-' + n, 'Internal port', intPort || ext || '') +
        '<button type="button" class="btn btn-sm btn-ghost pf-row-del" style="align-self:flex-end">Remove</button>';
      row.querySelector('.pf-row-del').onclick = function () { row.remove(); };
      $('#pf-rows').appendChild(row);
      return row;
    }
    $('#pf-add-row').onclick = function () { pfAddRow(); };
    pfAddRow(); // start with one row — most mappings need at least one port

    $$('[data-group-toggle]').forEach(function (row) {
      row.onclick = function () {
        var gi = row.getAttribute('data-group-toggle');
        var open = row.getAttribute('data-open') === '1';
        row.setAttribute('data-open', open ? '0' : '1');
        $('[data-group-chevron="' + gi + '"]').innerHTML = open ? '&#9656;' : '&#9662;';
        $$('[data-group="' + gi + '"]').forEach(function (sub) { sub.hidden = open; });
      };
    });

    // Editing an existing rule reuses the same add-form: it seeds the
    // mapping name/IP and a single row carrying the original rule's id.
    // Save then deletes that id before re-adding it with whatever values
    // are now in the row, so changing (say) the external port replaces the
    // rule instead of leaving the old port number behind as an orphan.
    $$('[data-edit-fw]').forEach(function (b) {
      b.onclick = function () {
        var p = b.getAttribute('data-edit-fw').split('|');
        var id = p[0], name = p[1], proto = p[2], sport = p[3], dip = p[4], dport = p[5];
        $('#pf-name').value = name;
        $('#pf-dip').value = dip;
        $('#pf-rows').innerHTML = '';
        pfAddRow(sport, dport, proto, id);
        $('#pf-name').scrollIntoView({ behavior: 'smooth', block: 'center' });
        toast('Editing "' + name + '". Change what you need, then Save.', 'ok');
      };
    });

    $('#pf-add').onclick = function () {
      var name = $('#pf-name').value.trim();
      var ip = $('#pf-dip').value.trim();
      var rows = $$('.pf-row');
      if (!name)  { toast('Mapping name is required.', 'error'); return; }
      if (!ip)    { toast('Internal IP is required.', 'error'); return; }
      if (!rows.length) { toast('Add at least one port.', 'error'); return; }

      var btn = $('#pf-add');
      btn.disabled = true; btn.textContent = 'Saving…';

      var jobs = rows.map(function (row) {
        var n = row.dataset.row;
        var addBody = {
          name: name,
          proto: $('#pf-proto-' + n).value,
          src_dport: $('#pf-ext-' + n).value,
          dest_ip: ip,
          dest_port: $('#pf-int-' + n).value
        };
        if (row.dataset.editId) {
          return api('/firewall/forward/del', { method: 'POST', body: { id: row.dataset.editId } })
            .then(function () { return api('/firewall/forward/add', { method: 'POST', body: addBody }); });
        }
        return api('/firewall/forward/add', { method: 'POST', body: addBody });
      });

      Promise.allSettled(jobs).then(function (results) {
        var failed = results.filter(function (r) { return r.status === 'rejected'; });
        if (failed.length) {
          toast(failed.length + ' of ' + rows.length + ' ports failed: ' + failed[0].reason.message, 'error');
        } else {
          toast(rows.length + ' port' + (rows.length > 1 ? 's' : '') + ' saved to "' + name + '".', 'ok');
        }
        views.firewall();
      });
    };

    $$('[data-del-fw]').forEach(function (b) {
      b.onclick = function () {
        api('/firewall/forward/del', { method: 'POST', body: { id: b.getAttribute('data-del-fw') } })
          .then(function (r) { toast(r.message, 'ok'); views.firewall(); })
          .catch(function (e) { toast(e.message, 'error'); });
      };
    });

    $('#fw-save').onclick = function () {
      api('/firewall/settings', { method: 'POST', body: {
        dmz_host: $('#dmz-host').value || 'none', upnp_enabled: $('#upnp').checked ? '1' : '0'
      }}).then(function (r) { toast(r.message, 'ok'); }).catch(function (e) { toast(e.message, 'error'); });
    };

    $('#remote-save').onclick = function () {
      var on = $('#remote').checked;
      var go = on ? confirmModal('Expose the admin panel to the internet?',
        '<p>This opens port ' + esc(r.admin_wan_port || '8443') + ' on all three WAN uplinks, forwarding to ' +
        'this admin panel.</p>' +
        '<p style="margin-top:10px"><strong>Understand what this means:</strong></p>' +
        '<ul style="margin:8px 0 0 18px"><li>The login page becomes reachable by anyone on the internet.</li>' +
        '<li>Traffic is plain HTTP — your password is sent unencrypted.</li>' +
        '<li>This device has no rate limiting or intrusion detection beyond a one-second delay on failed logins.</li></ul>' +
        '<p style="margin-top:10px">The <a href="#/remote">Remote Access</a> page\'s relay tunnel is a far safer way to reach this panel remotely.</p>',
        'I understand, expose it') : Promise.resolve(true);

      go.then(function (ok) {
        if (!ok) { $('#remote').checked = false; return; }
        api('/firewall/settings', { method: 'POST', body: { remote_admin: on ? '1' : '0' } })
          .then(function () { toast(on ? 'Remote access enabled.' : 'Remote access disabled.', on ? 'error' : 'ok'); views.firewall(); })
          .catch(function (e) { toast(e.message, 'error'); });
      });
    };
  }).catch(function (e) { toast(e.message, 'error'); });
};

/* ======================= WireGuard ======================= */

views.vpn = function () {
  api('/wireguard').then(function (r) {
    page('WireGuard', 'VPN tunnels.',
      '<div class="alert alert-warn"><strong>Throughput ceiling: roughly 90 Mbit/s.</strong>' +
        'WireGuard uses ChaCha20-Poly1305, which this MIPS CPU has no hardware acceleration for. ' +
        'Benchmarks on comparable MT7621 devices land between 82 and 99 Mbit/s. ' +
        'Fine for remote administration and file access; not suitable for routing all of a gigabit line.</div>' +
      (r.installed ? '' : '<div class="alert alert-error">WireGuard is not installed. ' +
        'Run <code>opkg install wireguard-tools kmod-wireguard</code>.</div>') +
      '<div class="card"><div class="card-head"><h3>Key pair</h3></div><div class="card-body">' +
        '<p class="hint" style="margin-top:0">Generate a key pair to use when configuring a tunnel. ' +
        'The private key is shown once and is not stored by this page.</p>' +
        '<button class="btn" id="wg-gen"' + (r.installed ? '' : ' disabled') + '>Generate key pair</button>' +
        '<div id="wg-keys" style="margin-top:14px"></div></div></div>' +
      '<div class="card"><div class="card-head"><h3>Recommended use</h3></div><div class="card-body">' +
        '<p style="font-size:13.5px;color:var(--text-dim)">The most valuable thing WireGuard does on this box is ' +
        'give you a safe way to reach this admin panel from outside, instead of exposing it to the WAN. ' +
        'Set up a tunnel, connect to it, and browse to the LAN address as though you were at home.</p>' +
        '<p class="hint" style="margin-top:10px">Tunnel and peer configuration is not exposed here yet — ' +
        'use LuCI or <code>/etc/config/network</code> for the initial setup, then manage it from this page.</p>' +
        '</div></div>');

    $('#wg-gen').onclick = function () {
      api('/wireguard/keygen', { method: 'POST' }).then(function (k) {
        $('#wg-keys').innerHTML =
          '<div class="alert alert-warn"><strong>Copy the private key now.</strong>It is not saved anywhere.</div>' +
          '<label class="field"><span>Private key</span><input type="text" readonly value="' + esc(k.private_key) + '"></label>' +
          '<label class="field"><span>Public key</span><input type="text" readonly value="' + esc(k.public_key) + '"></label>';
      }).catch(function (e) { toast(e.message, 'error'); });
    };
  }).catch(function (e) { toast(e.message, 'error'); });
};

/* ======================= Remote Access ======================= */

views.remote = function () {
  Promise.all([api('/remote'), api('/firewall'), api('/status')]).then(function (results) {
    var r = results[0], fw = results[1], st = results[2];
    var adminPort = fw.admin_wan_port || '8443';
    var wanRows = (st.wans || []).map(function (w) {
      var priv = isPrivateIPv4(w.address);
      var status = !w.address
        ? '<span class="badge">no address</span>'
        : priv === true
          ? '<span class="badge warn">behind another NAT</span>'
          : '<span class="badge ok">public — ready</span>';
      var action = !w.address
        ? '—'
        : priv === true
          ? 'Forward TCP port <b>' + esc(adminPort) + '</b> to <b>' + esc(w.address) + ':' + esc(adminPort) +
            '</b> on whatever router/modem this WAN plugs into.'
          : 'No extra setup needed — this address is already public.';
      return '<tr><td>' + esc(w.name.toUpperCase()) + '</td>' +
        '<td class="mono">' + esc(w.address || '—') + '</td>' +
        '<td>' + status + '</td>' +
        '<td style="font-size:12.5px">' + action + '</td></tr>';
    }).join('') || '<tr><td colspan="4" class="empty">No WAN addresses known yet.</td></tr>';
    page('Remote Access', 'Two ways to reach this admin panel over the internet.',
      '<div class="alert alert-info"><strong>Method 1 — relay tunnel (below): </strong>outbound-only, ' +
        'the router is never directly reachable, but needs a relay host and a one-time setup step there. ' +
        '<strong>Method 2 — direct port forward (bottom of this page): </strong>simpler, no relay host, but ' +
        'exposes this router directly to the internet and only works on a WAN with a real public IP.</div>' +
      (r.installed ? '' : '<div class="alert alert-error">No SSH client is available on this device. ' +
        'This should not happen on a normal install — check <code>logread</code>.</div>') +
      '<div class="page-head" style="margin-top:22px"><h3>Method 1 — Relay tunnel</h3></div>' +
      '<div class="alert alert-info"><strong>How this works.</strong> This router opens an outbound SSH ' +
        'connection to a relay host you control (a VPS, or a shared hosting account with SSH access) and asks ' +
        'it to forward one of its own loopback ports back to this admin panel. No inbound firewall rule is ' +
        'opened on this router or on any WAN — the connection is entirely outbound. Making the relay host\'s ' +
        'own web server proxy a public HTTPS address to that forwarded port is a separate, one-time step on ' +
        'the relay host itself.</div>' +
      '<div class="card"><div class="card-head"><h3>Status</h3></div><div class="card-body" id="remote-status">' +
        '<span class="badge">checking…</span></div></div>' +
      '<div class="card"><div class="card-head"><h3>Key pair</h3></div><div class="card-body">' +
        '<p class="hint" style="margin-top:0">Generated on this router and never leaves it. Paste the public ' +
        'key into the relay host\'s <code>~/.ssh/authorized_keys</code>.</p>' +
        '<button class="btn" id="remote-gen"' + (r.installed ? '' : ' disabled') + '>' +
        (r.has_key ? 'Regenerate key pair' : 'Generate key pair') + '</button>' +
        '<div style="margin-top:14px">' +
        (r.public_key ? '<label class="field"><span>Public key</span><textarea readonly rows="3" ' +
          'style="font-family:monospace;font-size:12px" onclick="this.select()">' + esc(r.public_key) +
          '</textarea></label>' : '') +
        '</div></div></div>' +
      '<div class="card"><div class="card-head"><h3>Relay host</h3></div><div class="card-body">' +
        '<div class="form-row">' + f('rm-host', 'Relay host', r.host || '') +
          f('rm-user', 'SSH username', r.user || '') + '</div>' +
        '<div class="form-row">' + f('rm-sshport', 'SSH port', r.ssh_port || '22') +
          f('rm-remoteport', 'Remote (loopback) port', r.remote_port || '') + '</div>' +
        '<label class="switch"><input type="checkbox" id="rm-enabled"' + (r.enabled ? ' checked' : '') +
          (r.installed && r.has_key ? '' : ' disabled') + '><span class="track"></span>' +
          '<span>Enable the relay tunnel</span></label>' +
        '<button class="btn btn-primary" id="remote-save" style="margin-top:10px">Save</button>' +
        '<p class="hint" style="margin-top:10px">The remote port is where the relay host will listen on its ' +
        'own loopback (127.0.0.1) — pick anything 1024 or above that\'s free there. Its own web server then ' +
        'needs to proxy a public HTTPS address to that port; this app cannot configure that side for you.</p>' +
        '</div></div>' +

      '<div class="page-head" style="margin-top:22px"><h3>Method 2 — Direct port forward</h3></div>' +
      '<div class="card"><div class="card-head"><h3>Per-WAN setup needed</h3></div><div class="card-body tight">' +
        '<div class="tbl-wrap"><table><thead><tr><th>WAN</th><th>Address</th><th>Status</th><th>What to do</th></tr></thead>' +
        '<tbody>' + wanRows + '</tbody></table></div></div>' +
        '<div class="card-body" style="border-top:1px solid var(--border)">' +
        '<p class="hint" style="margin:0">A WAN showing <b>public — ready</b> forwards through this router alone, ' +
        'nothing else to do. One showing <b>behind another NAT</b> means the address this router sees isn\'t the ' +
        'real internet-facing one — there\'s another router/modem upstream (common with some ISP setups) that ' +
        'needs its own port forward pointed at the address shown, before this router\'s own rule below can be ' +
        'reached from outside at all.</p></div></div>' +
      '<div class="card"><div class="card-body">' +
        '<p class="hint" style="margin-top:0">No relay host needed, and nothing to configure off-router — but ' +
        'this exposes the login page directly to the internet on plain HTTP, and only works at all if the WAN ' +
        'you\'re reached on has a real public IP (won\'t work behind carrier-grade NAT).</p>' +
        (fw.remote_admin
          ? '<div class="alert alert-error"><strong>This admin panel is currently reachable from the internet.</strong> ' +
            'Anyone who can reach your WAN address can attempt to log in.</div>'
          : '<div class="alert alert-info">Currently LAN-only — the correct default.</div>') +
        '<label class="switch"><input type="checkbox" id="pf-remote-enabled"' + (fw.remote_admin ? ' checked' : '') +
          '><span class="track"></span><span>Allow administration from the internet</span></label>' +
        '<button class="btn ' + (fw.remote_admin ? '' : 'btn-danger') + '" id="pf-remote-apply" style="margin-top:10px">Apply</button>' +
        '<p class="hint" style="margin-top:10px">Pair this with <a href="#/ddns">Dynamic DNS</a> so the address ' +
        'stays reachable by name as your WAN IP changes. Port forwards, DMZ, and UPnP live on the ' +
        '<a href="#/firewall">Firewall</a> page.</p>' +
        '</div></div>');

    pollRemote();

    $('#remote-gen').onclick = function () {
      var go = r.has_key ? confirmModal('Regenerate the key pair?',
        'The relay host\'s authorized_keys must be updated with the new public key, and the tunnel will need ' +
        'to reconnect. Only do this if you intend to update the relay host right after.',
        'Regenerate', true) : Promise.resolve(true);
      go.then(function (ok) {
        if (!ok) return;
        api('/remote/keygen', { method: 'POST' }).then(function () {
          toast('Key pair generated.', 'ok');
          views.remote();
        }).catch(function (e) { toast(e.message, 'error'); });
      });
    };

    $('#remote-save').onclick = function () {
      var on = $('#rm-enabled').checked;
      var go = on ? confirmModal('Enable internet remote access?',
        '<p>This starts an outbound tunnel from the router to <b>' + esc($('#rm-host').value) + '</b>. Whoever ' +
        'controls that host — and anyone who reaches the public address it exposes — can attempt to reach ' +
        'this admin panel\'s login page.</p>' +
        '<p style="margin-top:10px"><strong>Understand what this means:</strong></p>' +
        '<ul style="margin:8px 0 0 18px"><li>The router\'s own session login and CSRF protection still apply — ' +
        'this does not bypass authentication.</li>' +
        '<li>Protect the public URL with its own layer too (e.g. HTTP Basic Auth on the relay host).</li>' +
        '<li>Disable this again from this page at any time to close the tunnel.</li></ul>',
        'I understand, enable it') : Promise.resolve(true);

      go.then(function (ok) {
        if (!ok) { $('#rm-enabled').checked = false; return; }
        api('/remote', { method: 'POST', body: {
          enabled: on ? '1' : '0',
          host: $('#rm-host').value, user: $('#rm-user').value,
          ssh_port: $('#rm-sshport').value, remote_port: $('#rm-remoteport').value
        }}).then(function (rr) { toast(rr.message, 'ok'); views.remote(); })
          .catch(function (e) { toast(e.message, 'error'); });
      });
    };

    $('#pf-remote-apply').onclick = function () {
      var on = $('#pf-remote-enabled').checked;
      var go = on ? confirmModal('Expose the admin panel to the internet?',
        '<p>This opens port ' + esc(fw.admin_wan_port || '8443') + ' on all three WAN uplinks, forwarding to ' +
        'this admin panel.</p>' +
        '<p style="margin-top:10px"><strong>Understand what this means:</strong></p>' +
        '<ul style="margin:8px 0 0 18px"><li>The login page becomes reachable by anyone on the internet.</li>' +
        '<li>Traffic is plain HTTP — your password is sent unencrypted.</li>' +
        '<li>This device has no rate limiting or intrusion detection beyond a one-second delay on failed logins.</li></ul>' +
        '<p style="margin-top:10px">The relay tunnel above (Method 1) is a far safer way to reach this panel remotely.</p>',
        'I understand, expose it') : Promise.resolve(true);

      go.then(function (ok) {
        if (!ok) { $('#pf-remote-enabled').checked = false; return; }
        api('/firewall/settings', { method: 'POST', body: { remote_admin: on ? '1' : '0' } })
          .then(function () { toast(on ? 'Remote access enabled.' : 'Remote access disabled.', on ? 'error' : 'ok'); views.remote(); })
          .catch(function (e) { toast(e.message, 'error'); });
      });
    };
  }).catch(function (e) { toast(e.message, 'error'); });
};

/* ======================= QoS ======================= */

views.qos = function () {
  api('/qos').then(function (r) {
    page('QoS', 'Bandwidth shaping with SQM (cake).',
      '<div class="alert alert-warn"><strong>' + esc(r.note) + '</strong></div>' +
      '<div class="card"><div class="card-head"><h3>Configure shaping</h3></div><div class="card-body">' +
        '<label class="field"><span>Interface</span><select id="q-if">' +
        '<option value="wan2">WAN2 (recommended)</option><option value="wan3">WAN3 (recommended)</option>' +
        '<option value="wan1">WAN1 (not recommended)</option></select></label>' +
        '<div class="form-row">' + f('q-down', 'Download limit (kbit/s)', '95000') +
        f('q-up', 'Upload limit (kbit/s)', '95000') + '</div>' +
        '<label class="switch"><input type="checkbox" id="q-en" checked><span class="track"></span>' +
        '<span>Enable shaping on this interface</span></label>' +
        '<button class="btn btn-primary" id="q-save">Save QoS</button>' +
        '<p class="hint" style="margin-top:10px">Set limits to about 95% of the line\'s real capacity. ' +
        'Shaping only controls latency if the router, not the ISP, is the one dropping packets.</p>' +
        '</div></div>');

    $('#q-save').onclick = function () {
      api('/qos', { method: 'POST', body: {
        interface: $('#q-if').value, download: $('#q-down').value,
        upload: $('#q-up').value, enabled: $('#q-en').checked ? '1' : '0'
      }}).then(function (r) { toast(r.message, 'ok'); }).catch(function (e) { toast(e.message, 'error'); });
    };
  }).catch(function (e) { toast(e.message, 'error'); });
};

/* ======================= DDNS ======================= */

views.alerts = function () {
  api('/alerts').then(function (r) {
    if (!r.installed) {
      page('Alerts', 'Email notification when a WAN goes down.',
        '<div class="alert alert-warn"><strong>msmtp is not installed.</strong>' +
        'Set FEAT_ALERTS="1" in mwan.env and re-run 00-packages.sh, or install it manually, then reload this page.</div>');
      return;
    }
    page('Alerts', 'Email notification when a WAN goes down.',
      '<div class="alert alert-info"><strong>What triggers an email.</strong>' +
        'This uses mwan3\'s own tracking verdict, not just whether a cable is plugged in — a WAN whose line ' +
        'stays connected but whose upstream ISP has silently died still counts as down here, which is the ' +
        'scenario that actually matters. Sending happens over TLS; the password is written to a temp file in ' +
        'RAM only for the moment of sending, never kept on flash.</div>' +
      '<div class="card"><div class="card-head"><h3>SMTP server</h3></div><div class="card-body">' +
        '<div class="form-row">' + f('al-host', 'Server', r.smtp_host || '') + f('al-port', 'Port', r.smtp_port || '587') + '</div>' +
        '<div class="form-row">' + f('al-user', 'Username', r.smtp_user || '') +
        '<label class="field"><span>Password</span><input type="password" id="al-pass" placeholder="' +
        (r.smtp_has_password ? 'unchanged' : 'not set') + '"></label></div>' +
        '<div class="form-row">' + f('al-from', 'From address', r.smtp_from || '') + f('al-to', 'Send alerts to', r.alert_to || '') + '</div>' +
        '<p class="hint">Gmail and most providers need an app-specific password here, not your normal account password — ' +
        'your account\'s security settings will have an option to generate one.</p>' +
        '</div></div>' +
      '<div class="card"><div class="card-head"><h3>What to alert on</h3></div><div class="card-body">' +
        '<label class="switch"><input type="checkbox" id="al-enabled"' + (r.enabled ? ' checked' : '') +
        '><span class="track"></span><span>Enable email alerts</span></label>' +
        '<label class="switch"><input type="checkbox" id="al-wan1"' + (r.alert_wan1_down ? ' checked' : '') +
        '><span class="track"></span><span>WAN1 goes down (and recovers)</span></label>' +
        '<label class="switch"><input type="checkbox" id="al-all"' + (r.alert_all_down ? ' checked' : '') +
        '><span class="track"></span><span>Every uplink is down — no internet at all</span></label>' +
        '<div style="margin-top:14px"><button class="btn btn-primary" id="al-save">Save alert settings</button> ' +
        '<button class="btn btn-ghost" id="al-test">Send test email</button></div>' +
        '</div></div>');

    $('#al-save').onclick = function () {
      var body = {
        enabled: $('#al-enabled').checked ? '1' : '0',
        smtp_host: $('#al-host').value, smtp_port: $('#al-port').value,
        smtp_user: $('#al-user').value, smtp_from: $('#al-from').value,
        alert_to: $('#al-to').value,
        alert_wan1_down: $('#al-wan1').checked ? '1' : '0',
        alert_all_down: $('#al-all').checked ? '1' : '0'
      };
      if ($('#al-pass').value) body.smtp_pass = $('#al-pass').value;
      api('/alerts', { method: 'POST', body: body })
        .then(function (r) { toast(r.message, 'ok'); }).catch(function (e) { toast(e.message, 'error'); });
    };

    $('#al-test').onclick = function () {
      var btn = this;
      btn.disabled = true; btn.textContent = 'Sending…';
      api('/alerts/test', { method: 'POST' })
        .then(function (r) { toast(r.message, 'ok'); })
        .catch(function (e) { toast(e.message, 'error'); })
        .finally(function () { btn.disabled = false; btn.textContent = 'Send test email'; });
    };
  }).catch(function (e) { toast(e.message, 'error'); });
};

views.ddns = function () {
  api('/ddns').then(function (r) {
    var cur = (r.services || [])[0] || {};
    page('Dynamic DNS', 'Reach this network by hostname even when the address changes.',
      '<div class="alert alert-info"><strong>Especially useful here.</strong>' +
        'With three uplinks, your public address changes every time the gateway fails over. ' +
        'DDNS bound to WAN1 keeps a stable name pointing at whichever address is currently live.</div>' +
      '<div class="card"><div class="card-head"><h3>Provider</h3></div><div class="card-body">' +
        '<div class="form-row">' + f('dd-prov', 'Service name', cur.provider || 'duckdns.org') +
        f('dd-dom', 'Hostname', cur.domain || '') + '</div>' +
        '<div class="form-row">' + f('dd-user', 'Username', cur.username || '') +
        '<label class="field"><span>Password / token</span><input type="password" id="dd-pass" placeholder="unchanged"></label></div>' +
        '<label class="field"><span>Track which uplink</span><select id="dd-if">' +
        '<option value="wan1">WAN1</option><option value="wan2">WAN2</option><option value="wan3">WAN3</option>' +
        '</select></label>' +
        '<label class="switch"><input type="checkbox" id="dd-en"' + (cur.enabled ? ' checked' : '') +
        '><span class="track"></span><span>Enable Dynamic DNS</span></label>' +
        '<button class="btn btn-primary" id="dd-save">Save DDNS</button></div></div>');

    $('#dd-save').onclick = function () {
      var body = { provider: $('#dd-prov').value, domain: $('#dd-dom').value,
                   username: $('#dd-user').value, interface: $('#dd-if').value,
                   enabled: $('#dd-en').checked ? '1' : '0' };
      if ($('#dd-pass').value) body.password = $('#dd-pass').value;
      api('/ddns', { method: 'POST', body: body })
        .then(function (r) { toast(r.message, 'ok'); }).catch(function (e) { toast(e.message, 'error'); });
    };
  }).catch(function (e) { toast(e.message, 'error'); });
};

/* ======================= diagnostics ======================= */

views.diagnostics = function () {
  page('Diagnostics', 'Connectivity tools and the system log.',
    '<div class="card"><div class="card-head"><h3>Ping</h3></div><div class="card-body">' +
      '<div class="form-row">' + f('pg-host', 'Host or IP', '1.1.1.1') +
      '<label class="field"><span>Via uplink</span><select id="pg-if">' +
      '<option value="auto">Current route</option><option value="wan1">WAN1</option>' +
      '<option value="wan2">WAN2</option><option value="wan3">WAN3</option></select></label></div>' +
      '<button class="btn" id="pg-run">Run ping</button>' +
      '<p class="hint" style="margin-top:10px">Choosing a specific uplink forces the probe onto that link, ' +
      'which is how you verify a backup line works before you actually need it.</p>' +
      '<div id="pg-out" style="margin-top:14px"></div></div></div>' +
    '<div class="card"><div class="card-head"><h3>Traceroute</h3></div><div class="card-body">' +
      f('tr-host', 'Host or IP', '1.1.1.1') +
      '<button class="btn" id="tr-run">Run traceroute</button>' +
      '<div id="tr-out" style="margin-top:14px"></div></div></div>' +
    '<div class="card"><div class="card-head"><h3>System log</h3>' +
      '<button class="btn btn-sm" id="log-refresh">Refresh</button></div>' +
      '<div class="card-body"><div class="pre" id="log-out">Loading…</div></div></div>');

  function runner(btn, out, path, bodyFn) {
    $(btn).onclick = function () {
      var b = $(btn);
      b.disabled = true; b.innerHTML = '<span class="spinner"></span> Running';
      $(out).innerHTML = '';
      api(path, { method: 'POST', body: bodyFn() })
        .then(function (r) { $(out).innerHTML = '<div class="pre">' + esc(r.output) + '</div>'; })
        .catch(function (e) { $(out).innerHTML = '<div class="alert alert-error">' + esc(e.message) + '</div>'; })
        .then(function () { b.disabled = false; b.textContent = b.id === 'pg-run' ? 'Run ping' : 'Run traceroute'; });
    };
  }
  runner('#pg-run', '#pg-out', '/diag/ping', function () {
    return { host: $('#pg-host').value, iface: $('#pg-if').value };
  });
  runner('#tr-run', '#tr-out', '/diag/traceroute', function () {
    return { host: $('#tr-host').value };
  });

  function loadLog() {
    api('/syslog?lines=250').then(function (r) { $('#log-out').textContent = r.log || '(empty)'; })
      .catch(function (e) { $('#log-out').textContent = e.message; });
  }
  $('#log-refresh').onclick = loadLog;
  loadLog();
};

/* ======================= operating mode ======================= */

views.mode = function () {
  var s = window.__status || {};
  var isAp = s.mode === 'ap';

  page('Operating mode', 'Switch between full gateway and dumb access point.',
    '<div class="card"><div class="card-head"><div><h3>Current mode</h3></div>' +
      '<span class="mode-badge ' + (isAp ? 'ap' : 'router') + '">' + (isAp ? 'Access Point' : 'Router') + '</span>' +
      '</div><div class="card-body">' +
      (isAp
        ? '<p style="font-size:13.5px;color:var(--text-dim)">All ports are bridged together. The device does not ' +
          'route, does not run NAT or a firewall, and does not hand out addresses. Wired and wireless clients ' +
          'are ordinary hosts on the upstream router\'s network.</p>'
        : '<p style="font-size:13.5px;color:var(--text-dim)">Full multi-WAN gateway. Three uplinks with priority ' +
          'failover, NAT, firewall, and a DHCP server on the LAN.</p>') +
      '</div></div>' +

    '<div class="alert alert-info"><strong>Your configuration is preserved either way.</strong>' +
      'Switching to Access Point mode saves the entire multi-WAN setup to flash first. Switching back restores it ' +
      'exactly, with no reconfiguration.</div>' +

    '<div class="alert alert-warn"><strong>Every mode change is protected by a 90-second rollback.</strong>' +
      'After switching, you must reconnect and press <em>Keep this configuration</em> in the bar at the top of the ' +
      'page. If you do not — because the switch left the device unreachable — it restores the previous ' +
      'configuration and reboots on its own. You cannot lock yourself out with this button.</div>' +

    (isAp
      ? '<div class="card"><div class="card-head"><h3>Return to Router mode</h3></div><div class="card-body">' +
        '<p style="font-size:13.5px;color:var(--text-dim);margin-bottom:14px">Restores your saved multi-WAN ' +
        'configuration, re-enables the firewall and DHCP, and restarts failover tracking.</p>' +
        '<button class="btn btn-primary" id="to-router">Switch to Router mode</button></div></div>'
      : '<div class="card"><div class="card-head"><h3>Switch to Access Point mode</h3></div><div class="card-body">' +
        '<label class="switch"><input type="checkbox" id="ap-bridge-all" checked><span class="track"></span>' +
        '<span>Bridge all five ports, including the WAN ports</span></label>' +
        '<p class="hint">Leave this on to use every port as a LAN port. Turn it off to keep the WAN ports unused, ' +
        'which makes switching back simpler.</p>' +
        '<label class="field"><span>Address on the upstream network</span><select id="ap-proto">' +
        '<option value="dhcp">Obtain automatically (DHCP)</option>' +
        '<option value="static">Set manually</option></select></label>' +
        '<div id="ap-static" hidden><div class="form-row">' +
        f('ap-ip', 'IP address', '192.168.1.2') + f('ap-mask', 'Subnet mask', '255.255.255.0') +
        f('ap-gw', 'Upstream router', '192.168.1.1') + '</div></div>' +
        '<button class="btn btn-danger" id="to-ap">Switch to Access Point mode</button></div></div>'));

  if (!isAp) {
    $('#ap-proto').onchange = function () { $('#ap-static').hidden = this.value !== 'static'; };
    $('#to-ap').onclick = function () {
      confirmModal('Switch to Access Point mode?',
        '<p><strong>This stops the device routing entirely.</strong></p>' +
        '<ul style="margin:10px 0 0 18px">' +
        '<li>Multi-WAN failover stops. All three uplink configurations are saved, not deleted.</li>' +
        '<li>The firewall and NAT are disabled.</li>' +
        '<li>The DHCP server is switched off — the upstream router must provide one.</li>' +
        '<li>Wi-Fi keeps broadcasting, bridged onto the upstream network.</li>' +
        '<li>This device\'s address will change to whatever the upstream router assigns.</li></ul>' +
        '<p style="margin-top:12px">You have 90 seconds after the switch to reconnect and confirm, ' +
        'or it reverts automatically.</p>',
        'Switch to AP mode').then(function (go) {
        if (!go) return;
        api('/mode/ap', { method: 'POST', body: {
          bridge_all: $('#ap-bridge-all').checked ? '1' : '0',
          proto: $('#ap-proto').value, ipaddr: $('#ap-ip') ? $('#ap-ip').value : '',
          netmask: $('#ap-mask') ? $('#ap-mask').value : '', gateway: $('#ap-gw') ? $('#ap-gw').value : ''
        }}).then(function (r) {
          toast(r.message, 'ok');
          $('#view').innerHTML = '<div class="empty"><span class="spinner"></span><br><br>' +
            'Applying Access Point mode. Reconnect to the device at its new address, then confirm within 90 seconds.</div>';
        }).catch(function (e) { toast(e.message, 'error'); });
      });
    };
  } else {
    $('#to-router').onclick = function () {
      confirmModal('Return to Router mode?',
        '<p>Your saved multi-WAN configuration will be restored and failover tracking will restart.</p>' +
        '<p style="margin-top:10px">The device returns to its own LAN subnet, so you will need to reconnect ' +
        'and confirm within 90 seconds.</p>', 'Switch to Router mode', false).then(function (go) {
        if (!go) return;
        api('/mode/router', { method: 'POST' }).then(function (r) {
          toast(r.message, 'ok');
          $('#view').innerHTML = '<div class="empty"><span class="spinner"></span><br><br>' +
            'Restoring Router mode. Reconnect and confirm within 90 seconds.</div>';
        }).catch(function (e) { toast(e.message, 'error'); });
      });
    };
  }
};

/* ======================= system ======================= */

views.system = function () {
  Promise.all([api('/system'), api('/update/check').catch(function (e) { return { error: e.message }; })])
    .then(function (results) {
    var r = results[0], u = results[1];
    page('System', 'Device information, credentials, and maintenance.',
      '<div class="card"><div class="card-head"><h3>Device</h3></div><div class="card-body">' +
        kv('Model', r.model) + kv('Board', r.board) + kv('Firmware', r.firmware) +
        kv('Free flash', r.flash_free) + kv('Uptime', fmtUptime(r.uptime_s)) + '</div></div>' +

      '<div class="card"><div class="card-head"><h3>Software update</h3></div><div class="card-body" id="upd-body">' +
        (u.error
          ? '<p class="hint" style="margin-top:0">Could not check for updates: ' + esc(u.error) + '</p>'
          : u.update_available
            ? '<div class="alert alert-info">Version <b>' + esc(u.latest) + '</b> is available &mdash; you have <b>' +
              esc(u.current) + '</b>.</div>'
            : '<p class="hint" style="margin-top:0">Up to date (version ' + esc(u.current) + ').</p>') +
        '<div class="btn-row" style="margin-top:10px">' +
          '<button class="btn" id="upd-check">Check for updates</button>' +
          (u.update_available ? '<button class="btn btn-primary" id="upd-apply">Install update</button>' : '') +
        '</div>' +
        '<div class="hint" id="upd-progress" style="margin-top:10px"></div>' +
        '<p class="hint" style="margin-top:10px">Checks <code>github.com/mikaelbhai/MultiWAN</code> (main branch) ' +
        'over HTTPS. Installing downloads every app file fresh, verifies each one, and only replaces the running ' +
        'app if all of them check out &mdash; a failed check leaves the current install untouched.</p></div></div>' +

      '<div class="card"><div class="card-head"><h3>Identity and time</h3></div><div class="card-body">' +
        '<div class="form-row">' + f('sy-host', 'Hostname', r.hostname) + f('sy-tz', 'Timezone', r.timezone) + '</div>' +
        '<button class="btn" id="sy-save">Save</button></div></div>' +

      '<div class="card"><div class="card-head"><h3>Administrator password</h3></div><div class="card-body">' +
        '<p class="hint" style="margin-top:0">This is the router\'s <code>root</code> password. ' +
        'It is used for this panel and for SSH.</p>' +
        '<label class="field"><span>Current password</span><input type="password" id="pw-old"></label>' +
        '<label class="field"><span>New password</span><input type="password" id="pw-new"></label>' +
        '<label class="field"><span>Confirm new password</span><input type="password" id="pw-new2"></label>' +
        '<button class="btn btn-primary" id="pw-save">Change password</button></div></div>' +

      '<div class="card"><div class="card-head"><h3>Backup and restore</h3></div><div class="card-body">' +
        '<p class="hint" style="margin-top:0">The backup contains your entire configuration, including Wi-Fi ' +
        'passwords and any VPN keys. Store it somewhere private.</p>' +
        '<div class="btn-row"><a class="btn" href="' + API + '/system/backup' +
          (session ? '?session=' + encodeURIComponent(session) : '') + '" download>Download backup</a></div>' +
        '<p class="hint" style="margin-top:14px">To restore, upload the archive over SSH and run ' +
        '<code>sysupgrade -r &lt;file&gt; &amp;&amp; reboot</code>. Restore is deliberately not a one-click button here ' +
        'because a bad archive can leave the device unreachable.</p></div></div>' +

      '<div class="card"><div class="card-head"><h3>Reboot</h3></div><div class="card-body">' +
        '<p class="hint" style="margin-top:0">The device is unreachable for about a minute. ' +
        'All connections through it drop.</p>' +
        '<button class="btn btn-danger" id="sys-reboot">Reboot now</button></div></div>' +

      '<div class="card"><div class="card-head"><h3>Full system settings</h3></div><div class="card-body">' +
        '<p class="hint" style="margin-top:0">This app covers multi-WAN, LAN, wireless, and failover. For ' +
        'everything else OpenWrt exposes — package management, raw UCI, detailed diagnostics — use LuCI, ' +
        'the router\'s built-in admin interface. Same login as this app.</p>' +
        '<div class="btn-row"><a class="btn" href="http://' + esc(r.lan_ip) + '/" target="_blank" rel="noopener">Open LuCI</a></div>' +
        '</div></div>');

    $('#sy-save').onclick = function () {
      api('/system', { method: 'POST', body: { hostname: $('#sy-host').value, timezone: $('#sy-tz').value } })
        .then(function (r) { toast(r.message, 'ok'); }).catch(function (e) { toast(e.message, 'error'); });
    };

    $('#pw-save').onclick = function () {
      if ($('#pw-new').value !== $('#pw-new2').value) { toast('New passwords do not match.', 'error'); return; }
      api('/system/password', { method: 'POST', body: {
        old_password: $('#pw-old').value, new_password: $('#pw-new').value
      }}).then(function (r) {
        toast(r.message, 'ok');
        $('#pw-old').value = $('#pw-new').value = $('#pw-new2').value = '';
      }).catch(function (e) { toast(e.message, 'error'); });
    };

    $('#sys-reboot').onclick = function () {
      confirmModal('Reboot the router?',
        'Every device on the network loses its connection for about a minute.', 'Reboot').then(function (go) {
        if (!go) return;
        api('/system/reboot', { method: 'POST' })
          .then(function (r) { toast(r.message, 'ok'); }).catch(function (e) { toast(e.message, 'error'); });
      });
    };

    $('#upd-check').onclick = function () { views.system(); };

    var updBtn = $('#upd-apply');
    if (updBtn) updBtn.onclick = function () {
      confirmModal('Install version ' + esc(u.latest) + '?',
        'Downloads the update, replaces the app\'s files, and restarts the admin service. Takes about ' +
        '15-30 seconds; this page briefly disconnects and reconnects on its own.', 'Install').then(function (go) {
        if (!go) return;
        updBtn.disabled = true;
        $('#upd-progress').textContent = 'Starting…';
        api('/update/apply', { method: 'POST' }).then(function () {
          pollUpdate();
        }).catch(function (e) { toast(e.message, 'error'); updBtn.disabled = false; });
      });
    };
  }).catch(function (e) { toast(e.message, 'error'); });
};

function pollUpdate() {
  api('/update/status').then(function (j) {
    var el = $('#upd-progress');
    if (el) el.textContent =
      j.status === 'running' ? 'Working: ' + j.step + '…' :
      j.status === 'error'   ? 'Failed: ' + j.step :
      j.status === 'done'    ? j.step : '';
    if (j.status === 'running') {
      setTimeout(pollUpdate, 1500);
    } else if (j.status === 'done') {
      toast('Update installed.', 'ok');
      setTimeout(views.system, 800);
    } else if (j.status === 'error') {
      toast(j.step, 'error');
      var btn = $('#upd-apply'); if (btn) btn.disabled = false;
    }
  }).catch(function () {
    // The admin service is mid-restart — expected, keep polling.
    setTimeout(pollUpdate, 1500);
  });
}

/* ======================= boot ======================= */

// Running standalone (see MW_API_BASE above): there's no cookie to restore a
// session from, so the token itself is what's persisted, in this origin's
// own localStorage — private to whoever is using this specific copy of the
// page, never sent anywhere but back to the router as the existing "session"
// query param / "_csrf" body field already do.
var REMOTE = !!window.MW_API_BASE;
function saveRemoteSession(sid) {
  if (!REMOTE) return;
  try { sid ? localStorage.setItem('mw-remote-session', sid) : localStorage.removeItem('mw-remote-session'); } catch (e) {}
}

/* Restore an existing session on reload. On the router itself, the cookie is
   HttpOnly so the token cannot be read from script; /status returns it for a
   request that already authenticated by cookie. Standalone, there is no
   cookie at all, so the saved token (if any) is attached before this first
   call even goes out. */
if (REMOTE) {
  try { session = localStorage.getItem('mw-remote-session') || null; } catch (e) {}
}
api('/status').then(function (s) {
  if (!s.session) throw new Error('no session');
  session = s.session;
  saveRemoteSession(session);
  window.__status = s;
  showApp();
}).catch(function (e) { saveRemoteSession(null); showLogin(); });

/* ======================= auto-reload on new deploy ======================= */
/* This page is a single-page app: moving between sections only ever changes
   the URL hash, which never re-fetches app.js. An already-open tab keeps
   running whatever code it loaded when it was first opened — even long after
   a fix has been deployed to the router. That gap caused real, confusing
   bugs in this project (a CSRF fix that appeared "not to work" because the
   open tab was still running the old script). Polling this script's own
   Last-Modified header and reloading when it changes closes that gap so you
   never have to remember to hard-refresh again. */
(function watchForUpdates() {
  var known = null;
  function check() {
    fetch('app.js', { method: 'HEAD', cache: 'no-store' }).then(function (r) {
      var lm = r.headers.get('Last-Modified');
      if (!lm) return;
      if (known === null) { known = lm; return; }
      if (lm === known) return;
      // Don't yank the page out from under an in-progress edit — a focused
      // input/textarea/select means you're mid-typing (a WiFi password, a
      // device rename, a port-forward rule). Wait for the next check instead
      // of reloading over unsaved work.
      var el = document.activeElement;
      var busy = el && /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName);
      if (busy) return;
      location.reload();
    }).catch(function () {}); // a transient network blip isn't worth surfacing
  }
  setInterval(check, 20000);
})();

})();
