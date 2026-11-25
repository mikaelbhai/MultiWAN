/* MultiWAN admin UI.
   Vanilla JS, no dependencies, no build step. ~26 KB, ~7 KB gzipped. */
(function () {
'use strict';

// Sourcing this file from another origin — see docs/07-standalone-app.md —
// sets window.MW_API_BASE to the router's full external URL before this
// script loads (e.g. "http://203.0.113.5:8443/cgi-bin/mwadmin"); running on
// the router itself, the relative path is correct as-is.
var API = window.MW_API_BASE || 'cgi-bin/mwadmin';
var SELF_URL = (document.currentScript && document.currentScript.src) ? 'app.js' : (location.pathname || 'index.html');
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
  if (window.MW_PORTAL) { location.href = './'; return; }
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
      var actW = (s.wans || []).filter(function (w) { return w.name === actives[0]; })[0];
      chip.className = 'active-wan up';
      lbl.textContent = (actW && actW.label ? actW.label + ' (' + actives[0].toUpperCase() + ')' : actives[0].toUpperCase()) + ' carrying traffic';
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
    // never redraw under an open type picker
    if (body.contains(document.activeElement) && document.activeElement.tagName === 'SELECT') return;
    body.innerHTML = rows.map(function (n) {
      return '<tr' + (n.online ? '' : ' class="dev-offline"') + '>' +
        '<td>' + esc(n.name) + '</td>' +
        '<td><select data-kind-node="' + esc(n.id) + '" aria-label="Type">' +
          ['router', 'ap', 'other'].map(function (k) {
            return '<option value="' + k + '"' + ((n.kind || 'other') === k ? ' selected' : '') + '>' + NODE_KIND_LABEL[k] + '</option>';
          }).join('') + '</select></td>' +
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

    // change a node's type straight from the table (its name, address and link stay as they are)
    $$('[data-kind-node]').forEach(function (s) {
      s.onchange = function () {
        var n = rows.filter(function (x) { return x.id === s.getAttribute('data-kind-node'); })[0];
        if (!n) return;
        s.disabled = true;
        api('/nodes/add', { method: 'POST', body: { name: n.name, mac: n.mac, kind: s.value, admin_url: n.admin_url || '', reserve: '0' } })
          .then(function () { toast(n.name + ' is now: ' + NODE_KIND_LABEL[s.value], 'ok'); })
          .catch(function (e) { toast(e.message, 'error'); })
          .then(function () { s.disabled = false; s.blur(); pollNodes(); });
      };
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
      var what = (e.kind === 'wan' ? 'Internet line ' : '') + esc(e.label);
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
    '<div class="card" id="dash-site"></div>' +
    '<div class="card" id="dash-guests"></div>' +
    '<div class="card" id="dash-sites"></div>' +
    '<div class="grid c4" id="dash-stats"></div>' +
    '<div class="card"><div class="card-head"><div><h3>WAN priority</h3>' +
      '<p>Traffic follows the highest-priority link that is healthy.</p></div></div>' +
      '<div class="card-body tight" id="dash-wans"></div></div>' +
    '<div class="card"><div class="card-head"><h3>Throughput</h3></div>' +
      '<div class="card-body" id="dash-bw"></div></div>');
  renderStatusInto(s);
  renderBwPanels(s);
  loadSite();
  loadGuests();
  loadSites();
};

/* ======================= blocked sites (sites card) =======================
   The admin blocks a site for everyone. A person who opens it can press
   "Request access"; approving that request opens the site for their device
   only. */

var sitesTimer = null;

function loadSites() {
  if (!$('#dash-sites')) return;
  api('/sites').then(renderSites).catch(function () {});
  clearTimeout(sitesTimer);
  sitesTimer = setTimeout(function () { if (currentView === 'dashboard') loadSites(); }, 15000);
}

function renderSites(b) {
  var el = $('#dash-sites');
  if (!el) return;
  var a = document.activeElement;
  if (a && el.contains(a) && a.tagName === 'INPUT' && a.value) return;   // never redraw over typing

  function reqRow(q) {
    var p = q.status === 'pending', ok = q.status === 'approved';
    var btns = p ? '<button class="btn btn-primary btn-sm" data-site-dec="approve">Approve</button> <button class="btn btn-ghost btn-sm" data-site-dec="deny">Decline</button>'
             : ok ? '<button class="btn btn-ghost btn-sm" data-site-dec="remove">Take back</button>'
             : '<button class="btn btn-ghost btn-sm" data-site-dec="approve">Approve</button> <button class="btn btn-ghost btn-sm" data-site-dec="remove">Forget</button>';
    return '<div class="wan-row" data-site-mac="' + esc(q.mac) + '" data-site-dom="' + esc(q.domain) + '"><div class="wan-main">' +
      '<div class="wan-name">' + esc(q.name || q.host || 'Unknown device') + ' <span class="badge ' + (p ? 'warn' : (ok ? 'ok' : 'danger')) + '">' +
        (p ? 'asks for' : (ok ? 'can open' : 'declined for')) + '</span> ' + esc(q.label || q.domain) + '</div>' +
      '<div class="wan-meta">' + (q.phone ? '<span>' + esc(q.phone) + '</span>' : '') + '<span>' + esc(q.mac) + '</span>' +
        (q.ts ? '<span>' + esc(new Date(q.ts * 1000).toLocaleString()) + '</span>' : '') + '</div></div>' +
      '<div class="btn-row" style="margin:0">' + btns + '</div></div>';
  }
  var reqs = (b.requests || []).map(reqRow).join('');
  var sites = (b.sites || []).map(function (x) {
    return '<div class="wan-row"><div class="wan-main"><div class="wan-name">' + esc(x.label || x.domain) + '</div>' +
      '<div class="wan-meta"><span>' + (x.approved ? x.approved + ' device(s) allowed' : 'blocked for everyone') + '</span></div></div>' +
      '<button class="btn btn-ghost btn-sm" data-site-unblock="' + esc(x.domain) + '">Unblock</button></div>';
  }).join('');

  el.innerHTML =
    '<div class="card-head"><div><h3>Blocked sites and apps</h3>' +
      '<p>Block a site or mobile app for everyone, then approve the people who ask for it.</p></div>' +
      (b.pending ? '<span class="badge warn">' + b.pending + ' waiting</span>' : '') + '</div>' +
    '<div class="card-body">' +
      '<div class="btn-row"><input type="text" id="site-block-name" maxlength="100" placeholder="Site to block, e.g. tiktok.com" style="flex:1;min-width:0">' +
        '<button class="btn btn-primary" id="site-block-add">Block</button></div>' +
      '<div class="btn-row" style="margin-top:10px;flex-wrap:wrap">' + (b.apps || []).map(function (a) {
        return '<button class="btn btn-sm ' + (a.blocked ? 'btn-primary' : 'btn-ghost') + '" data-site-app="' + esc(a.id) + '" data-on="' + (a.blocked ? '1' : '') + '">' +
          (a.blocked ? 'Blocked: ' : 'Block ') + esc(a.name) + '</button>';
      }).join('') + '</div>' +
      '<p style="margin:10px 0 0;font-size:12.5px;opacity:.75">Sub-sites are included. Most sites use https, where the browser shows its own error instead of the block page. ' +
        'People can open ' + esc(b.page || 'http://192.168.1.1:8188') + ' to see the blocked sites and request access.</p>' +
    '</div>' +
    '<div class="card-body tight">' + (sites || '<div class="empty">No site is blocked.</div>') + reqs + '</div>';

  function send(path, body) {
    return api(path, { method: 'POST', body: body })
      .then(function (r) { toast(r.message || 'Saved.'); var i = $('#site-block-name'); if (i) i.value = ''; loadSites(); })
      .catch(function (e) { toast(e.message, 'error'); });
  }
  $('#site-block-add').onclick = function () {
    var v = $('#site-block-name').value.trim();
    if (v) send('/sites/block', { domain: v });
  };
  $('#site-block-name').onkeydown = function (e) { if (e.key === 'Enter') $('#site-block-add').click(); };
  $$('[data-site-app]', el).forEach(function (x) {
    x.onclick = function () { send(x.getAttribute('data-on') ? '/sites/unblock' : '/sites/block', { domain: x.getAttribute('data-site-app') }); };
  });
  $$('[data-site-unblock]', el).forEach(function (x) {
    x.onclick = function () { send('/sites/unblock', { domain: x.getAttribute('data-site-unblock') }); };
  });
  $$('[data-site-dec]', el).forEach(function (x) {
    x.onclick = function () {
      var row = x.closest('[data-site-mac]');
      send('/sites/decide', { mac: row.getAttribute('data-site-mac'), domain: row.getAttribute('data-site-dom'), decision: x.getAttribute('data-site-dec') });
    };
  });
}

/* ======================= network sign-in (guests card) =======================
   New devices must give a name and mobile number once before they get
   internet. From here the admin can switch that off for everyone for 30
   minutes, or let single devices (access points, TVs, printers) straight in. */

var guestTimer = null;

function loadGuests() {
  if (!$('#dash-guests')) return;
  api('/guests').then(renderGuests).catch(function () {});
  clearTimeout(guestTimer);
  guestTimer = setTimeout(function () { if (currentView === 'dashboard') loadGuests(); }, 15000);
}

function renderGuests(g) {
  var el = $('#dash-guests');
  if (!el) return;
  var left = g.paused_until ? Math.max(1, Math.ceil((g.paused_until - g.now) / 60)) : 0;
  var state = !g.enabled ? '<span class="badge">Off</span>'
            : left ? '<span class="badge warn">Off for ' + left + ' more min</span>'
            : '<span class="badge ok">On</span>';
  function row(d, allowed) {
    var title = allowed ? d.name : (d.host || 'Unknown device');
    return '<div class="wan-row"><div class="wan-main"><div class="wan-name">' + esc(title) +
        (d.online === false ? '' : ' <span class="badge ok">connected</span>') +
        (allowed ? '' : ' <span class="badge warn">must sign in</span>') + '</div>' +
      '<div class="wan-meta">' + (d.phone ? '<span>' + esc(d.phone) + '</span>' : '') +
        (allowed && d.host ? '<span>' + esc(d.host) + '</span>' : '') +
        '<span>' + esc(d.mac) + '</span>' + (d.ip ? '<span>' + esc(d.ip) + '</span>' : '') +
        (allowed && d.ts ? '<span>since ' + esc(new Date(d.ts * 1000).toLocaleDateString()) + '</span>' : '') + '</div></div>' +
      '<label class="switch" style="margin:0" title="Internet without sign-in for this device">' +
        '<input type="checkbox" data-guest-dev="' + esc(d.mac) + '" data-guest-host="' + esc(d.host || '') + '"' + (allowed ? ' checked' : '') + '>' +
        '<span class="track"></span><span>Allowed</span></label></div>';
  }
  var rows = (g.guests || []).map(function (d) { return row(d, true); }).join('') +
             (g.waiting || []).map(function (d) { return row(d, false); }).join('');

  el.innerHTML =
    '<div class="card-head"><div><h3>Network sign-in</h3>' +
      '<p>A new device enters a name and mobile number once, then it is remembered.</p></div>' + state + '</div>' +
    '<div class="card-body">' +
      '<label class="switch"><input type="checkbox" id="guest-on"' + (g.enabled ? ' checked' : '') + '>' +
        '<span class="track"></span><span>Ask new devices to sign in</span></label>' +
      '<div class="btn-row">' +
        (left ? '<button class="btn btn-primary" id="guest-resume">Turn sign-in back on now</button>'
              : '<button class="btn btn-ghost" id="guest-pause"' + (g.enabled ? '' : ' disabled') + '>Switch off for everyone for 30 minutes</button>') +
      '</div>' +
      '<p style="margin:10px 0 0;font-size:12.5px;opacity:.75">Setting up an access point? Either use the 30 minute switch while you work, or turn on ' +
        'Allowed for the access point below. An access point in router mode then lets everyone behind it straight in. ' +
        'In bridge mode each person behind it still signs in once.</p>' +
    '</div>' +
    '<div class="card-body tight">' + (rows || '<div class="empty">No devices seen yet.</div>') + '</div>';

  function send(path, body) {
    return api(path, { method: 'POST', body: body })
      .then(function (r) { toast(r.message || 'Saved.'); loadGuests(); })
      .catch(function (e) { toast(e.message, 'error'); loadGuests(); });
  }
  $('#guest-on').onchange = function () { send('/guests', { enabled: this.checked ? '1' : '0' }); };
  if ($('#guest-pause')) $('#guest-pause').onclick = function () { send('/guests', { pause: '30' }); };
  if ($('#guest-resume')) $('#guest-resume').onclick = function () { send('/guests', { pause: '0' }); };
  $$('[data-guest-dev]', el).forEach(function (c) {
    c.onchange = function () {
      var mac = c.getAttribute('data-guest-dev');
      if (c.checked) send('/guests/allow', { mac: mac, name: c.getAttribute('data-guest-host') });
      else send('/guests/remove', { mac: mac });
    };
  });
}

/* ======================= this router (site card) =======================
   Where the box is, whether it is online, which line is carrying traffic and
   what that line is called. A name belongs to the LINE (its gateway), not the
   socket, so it follows the cable if it is moved to another WAN port. */

var siteTimer = null;

function loadSite() {
  if (!$('#dash-site')) return;
  api('/site').then(function (d) { window.__site = d; renderSite(d); }).catch(function () {});
  clearTimeout(siteTimer);
  siteTimer = setTimeout(function () { if (currentView === 'dashboard') loadSite(); }, 15000);
}

function fmtMbps(v) { return (v === null || v === undefined) ? 'not measured' : (Math.round(v * 10) / 10) + ' Mbps'; }

function lineTitle(w) { return w.label || w.isp || w.iface.toUpperCase(); }

function renderSite(d) {
  var el = $('#dash-site');
  if (!el) return;
  // Never redraw over something being typed.
  var a = document.activeElement;
  if (a && el.contains(a) && a.tagName === 'INPUT' && a.type !== 'checkbox') return;

  var act = (d.wans || []).filter(function (w) { return w.active; })[0];
  var rows = (d.wans || []).slice().sort(function (x, y) { return (x.priority || 9) - (y.priority || 9); })
    .map(function (w) {
      var up = w.tracker === 'online';
      return '<div class="wan-row' + (w.active ? ' is-active' : '') + '">' +
        '<div class="wan-prio">' + esc(w.priority || '-') + '</div>' +
        '<div class="wan-main"><div class="wan-name">' + esc(lineTitle(w)) +
          (w.active ? ' <span class="badge ok">Carrying traffic</span>' : '') +
          ' <span class="badge ' + (up ? 'ok' : (w.connected ? 'warn' : 'danger')) + '">' +
            esc(w.connected ? w.tracker : 'not connected') + '</span></div>' +
          '<div class="wan-meta"><span>' + esc(w.iface.toUpperCase()) + ' &middot; port ' + esc(w.device) + '</span>' +
          (w.isp ? '<span>' + esc(w.isp) + '</span>' : '') +
          (w.public_ip ? '<span>' + esc(w.public_ip) + '</span>' : '') +
          (w.ip_location ? '<span>' + esc(w.ip_location) + '</span>' : '') +
          '<span>best ' + esc(fmtMbps(w.max_down_mbps)) + '</span></div>' +
          '<div class="btn-row" style="margin-top:8px">' +
            '<input type="text" maxlength="32" data-line-name="' + esc(w.iface) + '" value="' + esc(w.label) + '"' +
              ' placeholder="Name this line (e.g. Office Fibre)"' + (w.connected ? '' : ' disabled') +
              ' style="flex:1;min-width:0">' +
            '<button class="btn btn-ghost btn-sm" data-line-save="' + esc(w.iface) + '"' + (w.connected ? '' : ' disabled') + '>Save name</button>' +
          '</div></div></div>';
    }).join('');

  el.innerHTML =
    '<div class="card-head"><div><h3>' + esc(d.hostname || 'This router') + '</h3>' +
      '<p>' + esc(d.location || 'No location set') + (d.ip_location ? ' &middot; IP locates to ' + esc(d.ip_location) : '') + '</p></div>' +
      '<span class="badge ' + (d.internet ? 'ok' : 'danger') + '">' + (d.internet ? 'Online' : 'Offline') + '</span></div>' +
    '<div class="card-body">' +
      '<div class="grid c4">' +
        tile('In use', act ? lineTitle(act) : 'None', act ? act.iface.toUpperCase() + ' on port ' + act.device : 'no line is up', act ? 'ok' : 'danger') +
        tile('Provider', d.active_isp || 'unknown', d.public_ip || 'no public IP seen', '') +
        tile('Max download', fmtMbps(d.active_max_down_mbps), 'best ever measured on this line', '') +
        tile('IP location', d.ip_location || 'unknown', 'from the public IP', '') +
      '</div>' +
      '<div class="form-row" style="margin-top:14px;align-items:flex-end">' +
        '<label class="field" style="flex:1"><span>Router location</span>' +
          '<input type="text" id="site-location" maxlength="120" value="' + esc(d.location) + '" placeholder="e.g. Head office, 2nd floor server room"></label>' +
        '<button class="btn btn-primary" id="site-location-save">Save location</button>' +
      '</div>' +
      '<label class="switch" style="margin-top:12px"><input type="checkbox" id="site-auto"' + (d.auto_slot ? ' checked' : '') + '>' +
        '<span class="track"></span><span>Put the fastest measured line first automatically</span></label>' +
    '</div>' +
    '<div class="card-body tight">' + (rows || '<div class="empty">No WAN interfaces configured.</div>') + '</div>';

  $('#site-location-save').onclick = function () {
    api('/site', { method: 'POST', body: { location: $('#site-location').value } })
      .then(function (r) { toast(r.message || 'Saved.'); document.activeElement.blur(); loadSite(); })
      .catch(function (e) { toast(e.message, 'error'); });
  };
  $('#site-auto').onchange = function () {
    api('/site', { method: 'POST', body: { auto_slot: this.checked ? '1' : '0' } })
      .then(function () { toast('Saved.'); loadSite(); })
      .catch(function (e) { toast(e.message, 'error'); });
  };
  $$('[data-line-save]', el).forEach(function (b) {
    b.onclick = function () {
      var iface = b.getAttribute('data-line-save');
      var inp = $('[data-line-name="' + iface + '"]', el);
      api('/site/name', { method: 'POST', body: { iface: iface, name: inp.value } })
        .then(function (r) { toast(r.message || 'Saved.'); inp.blur(); loadSite(); })
        .catch(function (e) { toast(e.message, 'error'); });
    };
  });
}

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
          (x.label ? ' &middot; ' + esc(x.label) : '') +
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

    page('WAN & failover', 'Priority failover across three uplinks, managed by mwan3.',
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
        '</div></div>' +
      '<div class="card"><div class="card-head"><div><h3>Which line carries what</h3><p>Calls on one line, chosen devices on another.</p></div></div>' +
      '<div class="card-body" id="lines-card"><span class="spinner"></span></div></div>');
    loadLines();

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

/* what is plugged in behind a port: one device, or a switch / access point */
function portDevicesCell(p) {
  var d = p.devices || [];
  if (!d.length) return '<span style="opacity:.6">nothing seen</span>';
  var names = d.slice(0, 6).map(function (x) { return esc(x.name || x.ip || x.mac); }).join(', ') +
    (d.length > 6 ? ' +' + (d.length - 6) + ' more' : '');
  var many = d.length > 1, lan = p.role === 'lan';
  return '<span class="badge ' + (many && lan ? 'warn' : '') + '">' +
    (many && lan ? 'Switch / AP &middot; ' + d.length + ' devices' : (many ? d.length + ' on this line' : '1 device')) + '</span>' +
    '<div style="font-size:11.5px;margin-top:4px;max-width:260px">' + names + '</div>';
}

/* on/off switch for a socket; locked (with the reason) when switching it off
   would cut off the person using this page */
function portPowerCell(p) {
  var on = p.enabled !== false, lock = on && p.off_blocked;
  return '<label class="switch" title="' + esc(lock ? p.off_blocked : (on ? 'Switch this port off' : 'Switch this port on')) + '">' +
      '<input type="checkbox" data-power="' + esc(p.port) + '"' + (on ? ' checked' : '') + (lock ? ' disabled' : '') + '>' +
      '<span class="track"></span><span>' + (on ? 'On' : 'Off') + '</span></label>' +
    (p.yours ? '<div style="font-size:11.5px;margin-top:4px"><span class="badge accent">you are on this port</span></div>'
      : (lock ? '<div style="font-size:11.5px;margin-top:4px;max-width:220px;opacity:.75">' + esc(p.off_blocked) + '</div>' : ''));
}

views.ports = function () {
  api('/ports').then(function (r) {
    var rows = (r.ports || []).map(function (p) {
      var res = r.results && r.results[p.role];
      return '<tr><td><strong>' + esc(p.port) + '</strong></td>' +
        '<td><span class="badge ' + (p.role.indexOf('wan') === 0 ? 'accent' : (p.role === 'lan' ? '' : 'warn')) + '">' +
          esc(p.role) + '</span></td>' +
        '<td>' + portPowerCell(p) + '</td>' +
        '<td>' + (p.enabled === false ? '<span class="badge warn">switched off</span>' : speedBadge(p.speed_mbps, p.carrier)) + '</td>' +
        '<td>' + portDevicesCell(p) + '</td>' +
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
        '<thead><tr><th>Port</th><th>Role</th><th>Power</th><th>Link</th><th>Connected</th><th>Duplex</th><th>MAC</th><th>Last test</th></tr></thead>' +
        '<tbody>' + rows + '</tbody></table></div></div></div>' +
      '<div class="alert alert-info"><strong>Speed tests consume real bandwidth.</strong>' +
        'They run once automatically when a cable is plugged in, and otherwise only when you press Re-test. ' +
        'They never run on a schedule. On a gigabit line the measured figure is limited by this router\'s CPU, ' +
        'not by your connection.</div>' +
      tests +
      '<div class="card"><div class="card-head"><div><h3>Reassign port roles</h3>' +
        '<p>Choose which physical ports carry which role. At least one LAN port is required.</p></div></div>' +
        '<div class="card-body" id="assign-form"></div></div>');

    $$('[data-power]').forEach(function (cb) {
      cb.onchange = function () {
        var port = cb.getAttribute('data-power'), on = cb.checked;
        var p = (r.ports || []).filter(function (x) { return x.port === port; })[0] || {};
        cb.checked = !on;                       // stays as it was until confirmed
        var who = (p.devices || []).map(function (x) { return esc(x.name || x.ip || x.mac); });
        var body = on
          ? 'You are about to switch <strong>' + esc(port) + '</strong> back on. Whatever is plugged into it reconnects within a few seconds.'
          : 'You are about to switch <strong>' + esc(port) + '</strong> off.<br><br>' +
            (who.length ? 'These lose their connection: <strong>' + who.join(', ') + '</strong>.' : 'Nothing is seen on this port right now.') +
            (p.role && p.role.indexOf('wan') === 0 ? '<br><br>This is internet line ' + esc(p.role.toUpperCase()) + '; the other line takes over.' : '') +
            '<br><br>It stays off, even after a restart, until you switch it back on here.';
        // switching on is harmless: no question asked
        (on ? Promise.resolve(true) : confirmModal('Are you sure?', body, 'Yes, switch ' + port + ' off', true)).then(function (yes) {
          if (!yes) return;
          cb.disabled = true;
          api('/ports/power', { method: 'POST', body: { port: port, on: on ? '1' : '0' } })
            .then(function (j) { toast(j.message || 'Done', 'ok'); setTimeout(views.ports, 1500); })
            .catch(function (e) { toast(e.message, 'error'); cb.disabled = false; });
        });
      };
    });

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
    'always &mdash; a rate needs two samples a few seconds apart.</p>' +
    '<div class="card"><div class="card-head"><div><h3>Internet speed limits</h3><p>Cap how much of the connection one device can use. ' +
    'Transfers inside your home network stay at full speed.</p></div></div><div class="card-body" id="dev-limits"><span class="spinner"></span></div></div>' +
    '<div class="card"><div class="card-head"><div><h3>Never blocked</h3><p>Devices that skip every block, for example a teacher&rsquo;s laptop.</p></div></div>' +
    '<div class="card-body" id="exempt-card"><span class="spinner"></span></div></div>' +
    '<div class="card"><div class="card-head"><div><h3>Free time, break and groups</h3><p>When the blocked sites open for everyone, ' +
    'and how many minutes a day each device or group can unpause them. The 18+ filter is never paused.</p></div></div>' +
    '<div class="card-body" id="pause-card"><span class="spinner"></span></div></div>');
  pollDevices();
  loadDevLimits();
  loadExempt();
  loadPause();
};

/* ======================= Drives & storage (drive.sh) ======================= */

var DRIVE_FS = { hfsplus: 'Mac disk (HFS+)', exfat: 'exFAT', ntfs: 'Windows disk (NTFS)', ntfs3: 'Windows disk (NTFS)', vfat: 'FAT32', ext4: 'Linux (ext4)', ext3: 'Linux (ext3)', ext2: 'Linux (ext2)' };

views.drives = function () {
  page('Drives & storage',
    'USB drives plugged into the router, and which devices may open each one. Every device starts switched off &mdash; ' +
    'turn on <b>View</b> to let it open and copy files, or <b>Add</b> to also add, change and delete files.',
    '<div id="drives-box"><div class="empty"><span class="spinner"></span></div></div>');
  loadDrives();
};

function loadDrives() {
  var box = $('#drives-box'); if (!box) return;
  Promise.all([api('/drives'), api('/devices').catch(function () { return { devices: [] }; })]).then(function (r) {
    var d = r[0], devs = r[1].devices || [];
    if (!d.installed) {
      box.innerHTML = '<div class="card"><div class="card-body"><p class="hint" style="margin:0">Drive sharing is not installed on this router. ' +
        'Install the USB storage and file sharing packages (Packages page: <span class="mono">kmod-usb-storage ksmbd-server</span> and the drive formats), then come back here.</p></div></div>';
      return;
    }
    var login = {}; (d.logins || []).forEach(function (l) { login[l.mac] = l; });
    var byMac = {}; devs.forEach(function (x) { if (x.mac) byMac[String(x.mac).toLowerCase()] = x; });
    var html = '';
    if (!d.drives.length) {
      html += '<div class="card"><div class="card-body"><p class="hint" style="margin:0">No drive has been plugged in yet. ' +
        'Plug a USB drive into the router&rsquo;s USB port; it shows up here within a few seconds.</p></div></div>';
    }
    d.drives.forEach(function (dr) { html += driveCard(dr, d, devs, byMac); });
    html += driveHowTo(d, byMac);
    box.innerHTML = html;
    wireDrives(box);
  }).catch(function (e) { box.innerHTML = '<div class="card"><div class="card-body"><p class="hint" style="margin:0">' + esc(e.message) + '</p></div></div>'; });
}

function driveCard(dr, d, devs, byMac) {
  var lvl = {}; (dr.allow || []).forEach(function (a) { lvl[a.mac] = a.level; });
  // devices: the ones switched on first, then everything else the router knows
  var list = devs.filter(function (x) { return x.mac; }).map(function (x) { return { mac: String(x.mac).toLowerCase(), name: x.name, ip: x.ip, online: x.online }; });
  Object.keys(lvl).forEach(function (m) { if (!byMac[m]) list.push({ mac: m, name: m, ip: '', online: false }); });
  list.sort(function (a, b) {
    var oa = lvl[a.mac] ? 1 : 0, ob = lvl[b.mac] ? 1 : 0;
    if (oa !== ob) return ob - oa;
    if (a.online !== b.online) return a.online ? -1 : 1;
    return String(a.name).localeCompare(String(b.name));
  });
  var on = Object.keys(lvl).length;
  var state = !dr.present ? '<span class="badge">not plugged in</span>'
    : dr.ejected ? '<span class="badge warn">ejected &mdash; unplug it</span>'
    : !dr.mounted ? '<span class="badge warn">can&rsquo;t be read</span>'
    : on ? '<span class="badge ok">shared with ' + on + (on === 1 ? ' device' : ' devices') + '</span>'
    : '<span class="badge">nobody can open it</span>';
  var pct = dr.bytes && dr.used !== null ? Math.min(100, Math.round(dr.used / (dr.used + dr.free) * 100)) : 0;
  var meta = [dr.model, dr.port ? 'USB port ' + dr.port + (dr.speed >= 5000 ? ' (USB 3)' : dr.speed ? ' (USB 2)' : '') : '', DRIVE_FS[dr.type] || dr.type].filter(Boolean).join(' &middot; ');

  var rows = list.map(function (x) {
    var cur = lvl[x.mac] || 'off';
    function opt(v, label, dis) {
      return '<button type="button" class="drv-opt' + (cur === v ? ' on' : '') + '" data-dlvl="' + v + '"' + (dis ? ' disabled title="This drive can only be read"' : '') + '>' + label + '</button>';
    }
    return '<div class="drv-dev' + (x.online ? '' : ' off') + '">' +
      '<div class="drv-who"><b>' + esc(x.name || x.mac) + '</b><span class="hint mono">' + esc(x.ip || x.mac) + (x.online ? '' : ' &middot; offline') + '</span></div>' +
      '<div class="drv-seg" data-ddrive="' + esc(dr.id) + '" data-dmac="' + esc(x.mac) + '" data-dname="' + esc(x.name || '') + '">' +
        opt('off', 'Off') + opt('view', 'View') + opt('add', 'Add', dr.readonly) + '</div></div>';
  }).join('') || '<p class="hint">No devices known yet.</p>';

  return '<div class="card" data-drive-card="' + esc(dr.id) + '">' +
    '<div class="card-head"><div><h3>' + esc(dr.name) + '</h3><p>' + meta + '</p></div>' + state + '</div>' +
    '<div class="card-body">' +
      (dr.mounted ? '<div class="drv-bar" title="' + pct + '% full"><span style="width:' + pct + '%"></span></div>' +
        '<p class="hint" style="margin:6px 0 14px">' + fmtBytes(dr.used) + ' used of ' + fmtBytes(dr.used + dr.free) + ' &middot; <b>' + fmtBytes(dr.free) + ' free</b></p>' : '') +
      (dr.readonly && dr.mounted ? '<p class="hint drv-note">This is a Mac disk with a journal, so the router can only <b>read</b> it &mdash; devices can open and copy files, ' +
        'but nobody can add files to it. To add files from devices too, copy everything off and reformat it as <b>exFAT</b> (works on Mac, Windows and phones).</p>' : '') +
      '<div class="drv-list">' + rows + '</div>' +
      '<div class="btn-row" style="margin-top:14px">' +
        (dr.mounted ? '<button class="btn" data-deject="' + esc(dr.id) + '">Eject safely</button>' : '') +
        (!dr.present ? '<button class="btn btn-ghost" data-dforget="' + esc(dr.id) + '">Forget this drive</button>' : '') +
      '</div>' +
    '</div></div>';
}

function driveHowTo(d, byMac) {
  var shares = d.drives.filter(function (x) { return x.mounted && (x.allow || []).length; });
  var addr = d.address || 'the router';
  var share = shares.length ? shares[0].share : 'drive name';
  var logins = (d.logins || []).map(function (l) {
    var x = byMac[l.mac] || {};
    return '<div class="drv-login"><b>' + esc(x.name || l.mac) + '</b>' +
      '<span>Name <code>' + esc(l.user) + '</code></span>' +
      '<span>Password <code class="drv-pass" data-pass="' + esc(l.pass) + '">&bull;&bull;&bull;&bull;&bull;&bull;&bull;&bull;</code> ' +
        '<button class="btn btn-sm btn-ghost" data-dshow>Show</button> <button class="btn btn-sm btn-ghost" data-dcopy="' + esc(l.pass) + '">Copy</button></span></div>';
  }).join('');
  var pw = d.password !== false;
  return '<div class="card"><div class="card-head"><div><h3>How to open a drive</h3>' +
      '<p>' + (pw ? 'Each device that is switched on has its own name and password. Enter them once on that device and tick &ldquo;remember&rdquo;.'
                  : 'No password needed: a switched-on device just opens the drive. Devices that are switched off still can&rsquo;t reach it.') + '</p></div></div>' +
    '<div class="card-body">' +
      '<label class="switch"><input type="checkbox" id="drv-pw"' + (pw ? ' checked' : '') + '><span class="track"></span>' +
        '<span>Ask for a password</span></label>' +
      (pw ? '' : '<p class="hint drv-note">Without a password the router can&rsquo;t tell switched-on devices apart: each of them can open every drive, ' +
        'and can add files to a drive if any device has <b>Add</b> on it. Windows 11 also refuses password-free drives until ' +
        '&ldquo;insecure guest logons&rdquo; is allowed on that PC.</p>') +
      (logins ? (pw ? '' : '<p class="hint" style="margin:0 0 8px">Only needed on a computer that still asks for one:</p>') + '<div class="drv-logins">' + logins + '</div>'
              : (pw ? '<p class="hint">Switch a device on above and its sign-in appears here.</p>' : '')) +
      '<div class="drv-steps">' +
        '<div><b>Windows</b><span>File Explorer &rarr; address bar &rarr; <code>\\\\' + esc(addr) + '\\' + esc(share) + '</code></span></div>' +
        '<div><b>Mac</b><span>Finder &rarr; Go &rarr; Connect to Server &rarr; <code>smb://' + esc(addr) + '</code></span></div>' +
        '<div><b>iPhone / iPad</b><span>Files &rarr; &hellip; &rarr; Connect to Server &rarr; <code>smb://' + esc(addr) + '</code></span></div>' +
        '<div><b>Android</b><span>A file manager with &ldquo;SMB / LAN&rdquo; (e.g. CX File Explorer) &rarr; <code>' + esc(addr) + '</code></span></div>' +
      '</div>' +
      '<p class="hint" style="margin-bottom:0">Devices behind a Google Wifi or another access point all use that access point&rsquo;s name and password. ' +
        'A device that is switched off can&rsquo;t reach the drives at all, even with a password.</p>' +
    '</div></div>';
}

function wireDrives(box) {
  var pw = $('#drv-pw', box);
  if (pw) pw.onchange = function () {
    pw.disabled = true;
    post('/drives/password', { required: pw.checked ? 1 : 0 }).then(done).then(loadDrives).catch(function (e) { fail(e); loadDrives(); });
  };
  $$('.drv-seg', box).forEach(function (seg) {
    $$('[data-dlvl]', seg).forEach(function (b) {
      b.onclick = function () {
        if (b.classList.contains('on') || b.disabled) return;
        $$('[data-dlvl]', seg).forEach(function (o) { o.disabled = true; });
        post('/drives/access', { id: seg.getAttribute('data-ddrive'), mac: seg.getAttribute('data-dmac'),
          name: seg.getAttribute('data-dname'), level: b.getAttribute('data-dlvl') }).then(done).then(loadDrives).catch(function (e) { fail(e); loadDrives(); });
      };
    });
  });
  $$('[data-deject]', box).forEach(function (b) {
    b.onclick = function () {
      b.disabled = true;
      post('/drives/eject', { id: b.getAttribute('data-deject') }).then(done).then(loadDrives).catch(function (e) { fail(e); b.disabled = false; });
    };
  });
  $$('[data-dforget]', box).forEach(function (b) {
    b.onclick = function () { post('/drives/forget', { id: b.getAttribute('data-dforget') }).then(done).then(loadDrives).catch(fail); };
  });
  $$('[data-dshow]', box).forEach(function (b) {
    b.onclick = function () {
      var c = b.parentNode.querySelector('.drv-pass');
      var shown = c.textContent === c.getAttribute('data-pass');
      c.textContent = shown ? '••••••••' : c.getAttribute('data-pass');
      b.textContent = shown ? 'Show' : 'Hide';
    };
  });
  $$('[data-dcopy]', box).forEach(function (b) {
    b.onclick = function () {
      var t = b.getAttribute('data-dcopy');
      (navigator.clipboard ? navigator.clipboard.writeText(t) : Promise.reject()).then(function () { toast('Password copied.', 'ok'); })
        .catch(function () { toast('Copy it by hand: ' + t, 'ok'); });
    };
  });
}

/* ======================= Nodes & Networks ======================= */

views.nodes = function () {
  Promise.all([api('/nodes'), api('/devices')]).then(function (res) {
    var nodes = res[0].nodes || [];
    var devices = res[1].devices || [];
    var nodeMacs = {};
    nodes.forEach(function (n) { if (n.mac) nodeMacs[n.mac.toLowerCase()] = 1; });
    var candidates = devices.filter(function (d) { return d.mac && !nodeMacs[d.mac.toLowerCase()]; });

    page('Nodes & Networks',
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

      '<div class="card" id="hist-card" data-fold-default="shut">' +
      '<div class="card-head"><h3>Recent activity</h3></div>' +
      '<div class="card-body tight">' +
      '<div class="tbl-wrap"><table><thead><tr><th>When</th><th>What</th><th>Event</th></tr></thead>' +
      '<tbody id="history-tbody"><tr><td colspan="3" class="empty"><span class="spinner"></span></td></tr></tbody>' +
      '</table></div></div></div>' +
      '<p class="hint">Online/offline changes for the internet lines and every added node, most recent first.</p>' +

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
        f('nd-name', 'Name (the device is renamed to this)', '') + f('nd-mac', 'MAC address', '') +
        '<label class="field"><span>Type</span><select id="nd-kind">' +
        '<option value="router">Router</option><option value="ap">Access point</option>' +
        '<option value="other">Other</option></select></label></div>' +
      '<div class="form-row">' + f('nd-ip', 'IP address', '') +
        '<label class="field"><span>Admin panel URL (optional)</span>' +
        '<input type="text" id="nd-url" placeholder="http://192.168.10.50/ — leave blank to guess from its IP"></label></div>' +
      toggle('nd-reserve', 'Reserve this IP address for it, so it never changes', true) +
      '<div class="btn-row" style="margin-top:12px"><button class="btn btn-primary" id="nd-add">Save node</button></div>' +
      '<p class="hint">Saving an existing node again updates its name, type and address.</p></div></div>');


    $$('[data-pick-node]').forEach(function (b) {
      b.onclick = function () {
        var p = b.getAttribute('data-pick-node').split('|');
        $('#nd-mac').value = p[0];
        $('#nd-ip').value = p[1] || '';
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
        name: name, mac: $('#nd-mac').value.trim(), kind: $('#nd-kind').value, admin_url: $('#nd-url').value.trim(),
        ip: $('#nd-ip').value.trim(), reserve: $('#nd-reserve').checked ? '1' : '0'
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

    page('LAN & DHCP', 'Local network addressing and the DHCP server.',
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
        'use <a href="#/config">Config files</a> (network) for the initial setup, then manage it from this page.</p>' +
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
  Promise.all([api('/remote'), api('/firewall'), api('/status'), api('/connect').catch(function () { return {}; })]).then(function (results) {
    var r = results[0], fw = results[1], st = results[2], cn = results[3] || {};
    var cnLine = cn.connected
      ? '<div class="alert alert-info"><strong>Connected</strong> to <b>' + esc(cn.site || 'a website') + '</b>' +
        (cn.router_name ? ' as <b>' + esc(cn.router_name) + '</b>' : '') + '. The website can see this router and open this panel.' +
        (cn.uploads_failing ? ' <span class="badge warn">uploads are failing right now</span>' : '') + '</div>' +
        (cn.web_level !== null && cn.web_level !== undefined && Number(cn.web_level) < 1 ? '<div class="alert alert-warn"><strong>The website is older than this router\'s software.</strong> ' +
          'Some things may not show there. Please update the website.</div>' : '')
      : '<div class="alert alert-warn">Not connected to a website.</div>';
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
    page('Remote Access', 'Reach this admin panel from anywhere.',
      '<div class="page-head"><h3>Connect to your website account</h3></div>' +
      '<div class="card"><div class="card-body" id="cn-card">' + cnLine +
        '<p class="hint" style="margin-top:0">Sign in on your website, press <b>Add a router</b>, and copy the address and the key. ' +
        'The same key works on every router you own; each one joins your account on its own. Nothing else to set up.</p>' +
        '<div class="form-row">' + f('cn-site', 'Website address', cn.site || '') +
        '<label class="field"><span>API key</span><input type="password" id="cn-key" autocomplete="off" spellcheck="false" placeholder="bu…"></label></div>' +
        '<button class="btn btn-primary" id="cn-go">' + (cn.connected ? 'Connect to this website instead' : 'Connect') + '</button>' +
        '<p class="hint" id="cn-msg" style="margin-top:10px"></p>' +
      '</div></div>' +
      '<div class="page-head" style="margin-top:22px"><h3>Other ways in</h3></div>' +
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

    $('#cn-go').onclick = function () {
      var site = $('#cn-site').value.trim(), key = $('#cn-key').value.trim(), msg = $('#cn-msg'), btn = $('#cn-go');
      if (!site || !key) { msg.textContent = 'Enter the website address and the key.'; return; }
      var go = cn.connected ? confirmModal('Move this router to another website?',
        'It will stop reporting to <b>' + esc(cn.site || 'the current website') + '</b> and join the new one.', 'Move it', true) : Promise.resolve(true);
      go.then(function (ok) {
        if (!ok) return;
        btn.disabled = true; msg.textContent = 'Connecting…';
        api('/connect', { method: 'POST', body: { site: site, key: key, replace: cn.connected ? 'replace' : '' } })
          .then(function (rr) { toast(rr.message || 'Connected.', 'ok'); views.remote(); })
          .catch(function (e) { btn.disabled = false; msg.textContent = ''; toast(e.message, 'error'); });
      });
    };

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
  Promise.all([api('/system'), api('/software/check').catch(function (e) { return { error: e.message }; })])
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
        (u.notes && u.update_available ? '<p class="hint" style="margin-top:10px">What is new: ' + esc(u.notes) + '</p>' : '') +
        '<p class="hint" style="margin-top:10px">Checks ' + esc(u.source || 'the Baytaar website') + ' over verified HTTPS. The download ' +
        'must match its published fingerprint or nothing is changed. Settings are kept.</p></div></div>' +

      '<div class="card"><div class="card-head"><h3>Identity and time</h3></div><div class="card-body">' +
        '<div class="form-row">' + f('sy-host', 'Hostname', r.hostname) +
          '<label class="field"><span>Timezone</span><select id="sy-tz">' +
            (r.timezones || []).map(function (z) { return '<option' + (z === r.timezone ? ' selected' : '') + '>' + esc(z) + '</option>'; }).join('') +
            ((r.timezones || []).indexOf(r.timezone) < 0 ? '<option value="" selected>Choose your timezone</option>' : '') +
          '</select></label></div>' +
        '<p class="hint">Router time now: <b>' + esc(r.local_time || '') + '</b>. Break times and allowances follow this clock.</p>' +
        '<button class="btn" id="sy-save">Save</button></div></div>' +

      '<div class="card"><div class="card-head"><h3>Administrator password</h3></div><div class="card-body">' +
        '<p class="hint" style="margin-top:0">This is the router\'s <code>root</code> password. ' +
        'It is used for this panel and for SSH.</p>' +
        '<label class="field"><span>Current password</span><input type="password" id="pw-old"></label>' +
        '<label class="field"><span>New password</span><input type="password" id="pw-new"></label>' +
        '<label class="field"><span>Confirm new password</span><input type="password" id="pw-new2"></label>' +
        '<button class="btn btn-primary" id="pw-save">Change password</button></div></div>' +

      card('More', '', '<p class="hint" style="margin-top:0">Backup, restore, restart, firmware and factory reset are under ' +
        '<a href="#/maintenance">Backup &amp; firmware</a>. SSH keys are under <a href="#/access">SSH &amp; keys</a>.</p>'));

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


    $('#upd-check').onclick = function () { views.system(); };

    var updBtn = $('#upd-apply');
    if (updBtn) updBtn.onclick = function () {
      confirmModal('Install version ' + esc(u.latest) + '?',
        'Downloads the update, replaces the app\'s files, and restarts the admin service. Takes about ' +
        '15-30 seconds; this page briefly disconnects and reconnects on its own.', 'Install').then(function (go) {
        if (!go) return;
        updBtn.disabled = true;
        $('#upd-progress').textContent = 'Starting…';
        api('/software/upgrade', { method: 'POST', body: { version: u.latest, sha256: u.sha256 } }).then(function () {
          pollUpdate();
        }).catch(function (e) { toast(e.message, 'error'); updBtn.disabled = false; });
      });
    };
  }).catch(function (e) { toast(e.message, 'error'); });
};

function pollUpdate() {
  api('/software').then(function (j) {
    var el = $('#upd-progress');
    if (el) el.textContent = j.message || '';
    if (j.state === 'running') {
      setTimeout(pollUpdate, 1500);
    } else if (j.state === 'ok') {
      toast('Update installed.', 'ok');
      setTimeout(function () { location.reload(); }, 1500);
    } else if (j.state === 'failed') {
      toast(j.message, 'error');
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
/* ======================= navigation: search + phone menu ======================= */
(function () {
  var box = $('#nav-search');
  if (box) {
    box.addEventListener('input', function () {
      var q = box.value.trim().toLowerCase();
      $$('.sidebar .nav-group').forEach(function (g) {
        var any = false;
        $$('a', g).forEach(function (a) {
          var hit = !q || (a.textContent + ' ' + (a.getAttribute('data-k') || '')).toLowerCase().indexOf(q) !== -1;
          a.hidden = !hit; if (hit) any = true;
        });
        g.hidden = !any;
      });
    });
    box.addEventListener('keydown', function (e) {
      if (e.key !== 'Enter') return;
      var a = $$('.sidebar a').filter(function (x) { return !x.hidden; })[0];
      if (a) { location.hash = a.getAttribute('href'); box.value = ''; box.dispatchEvent(new Event('input')); }
    });
  }
  var t = $('#nav-toggle');
  if (t) t.addEventListener('click', function () { document.body.classList.toggle('nav-open'); });
  window.addEventListener('hashchange', function () { document.body.classList.remove('nav-open'); });
})();

function card(title, sub, body, id) {
  return '<div class="card"' + (id ? ' id="' + id + '"' : '') + '><div class="card-head"><div><h3>' + title + '</h3>' +
    (sub ? '<p>' + sub + '</p>' : '') + '</div></div><div class="card-body">' + body + '</div></div>';
}
function done(r) { toast(r.message || 'Done.', 'ok'); return r; }
function fail(e) { toast(e.message, 'error'); }
function post(path, body) { return api(path, { method: 'POST', body: body || {} }); }
function toggle(id, label, on) {
  return '<label class="check"><input type="checkbox" id="' + id + '"' + (on ? ' checked' : '') + '> ' + label + '</label>';
}

/* Follows the one background task (package install, firmware download). */
function watchJob(el, onDone) {
  function tick() {
    if (!document.body.contains(el)) return;
    api('/job').then(function (j) {
      if (!j.title) { el.innerHTML = ''; return; }
      el.innerHTML = '<div class="hint" style="margin:0 0 6px"><b>' + esc(j.title) + '</b> ' +
        (j.running ? '<span class="spinner"></span>' : (j.exit_code === 0 ? '&mdash; finished' : '&mdash; failed')) +
        '</div><pre class="pre">' + esc(j.log || '') + '</pre>';
      var pre = $('pre', el); if (pre) pre.scrollTop = pre.scrollHeight;
      if (j.running) setTimeout(tick, 1500); else if (onDone) onDone(j);
    }).catch(function () {});
  }
  tick();
}

/* ======================= devices: internet speed limits ======================= */
function loadDevLimits() {
  var el = $('#dev-limits');
  if (!el) return;
  Promise.all([api('/devices/limit'), api('/devices').catch(function () { return { devices: [] }; })]).then(function (r) {
    var lim = r[0].limits || [], devs = r[1].devices || [];
    el.innerHTML =
      (lim.length ? '<div class="tbl-wrap"><table><thead><tr><th>Device</th><th>Download</th><th>Upload</th><th></th></tr></thead><tbody>' +
        lim.map(function (l) {
          return '<tr><td>' + esc(l.name || l.mac) + '<div class="hint mono" style="margin:0">' + esc(l.mac) + '</div></td>' +
            '<td>' + (l.down_mbit ? l.down_mbit + ' Mb/s' : 'no limit') + '</td><td>' + (l.up_mbit ? l.up_mbit + ' Mb/s' : 'no limit') + '</td>' +
            '<td><button class="btn btn-sm" data-unlim="' + esc(l.mac) + '">Remove</button></td></tr>';
        }).join('') + '</tbody></table></div>'
        : '<p class="hint" style="margin-top:0">No limits. Every device can use the full connection.</p>') +
      '<div class="form-row" style="margin-top:12px"><label class="field"><span>Device</span><select id="lim-dev">' +
        devs.map(function (d) { return '<option value="' + esc(d.mac) + '" data-n="' + esc(d.name) + '">' + esc(d.name) + ' (' + esc(d.ip || d.mac) + ')</option>'; }).join('') +
      '</select></label>' + f('lim-down', 'Download limit, Mb/s', '', 'number') + f('lim-up', 'Upload limit, Mb/s', '', 'number') + '</div>' +
      '<button class="btn btn-primary" id="lim-save">Set limit</button>';
    $$('[data-unlim]', el).forEach(function (b) {
      b.onclick = function () { post('/devices/limit', { mac: b.getAttribute('data-unlim'), down_mbit: '0', up_mbit: '0' }).then(done).then(loadDevLimits).catch(fail); };
    });
    $('#lim-save').onclick = function () {
      var s = $('#lim-dev'); if (!s.value) return;
      post('/devices/limit', { mac: s.value, name: s.selectedOptions[0].getAttribute('data-n'),
        down_mbit: $('#lim-down').value, up_mbit: $('#lim-up').value }).then(done).then(loadDevLimits).catch(fail);
    };
  }).catch(function (e) { el.innerHTML = '<p class="hint">' + esc(e.message) + '</p>'; });
}

/* ======================= SSH & keys ======================= */
views.access = function () {
  api('/ssh').then(function (r) {
    page('SSH &amp; keys', 'Who can sign in to the router over SSH, and how.',
      card('Allowed keys', 'A key lets a computer sign in without a password.',
        (r.keys.length ? '<div class="tbl-wrap"><table><thead><tr><th>Name</th><th>Type</th><th>Ends with</th><th></th></tr></thead><tbody>' +
          r.keys.map(function (k) {
            return '<tr><td>' + esc(k.comment || '(no name)') + '</td><td class="mono">' + esc(k.type) + '</td>' +
              '<td class="mono">…' + esc(k.tail) + '</td><td><button class="btn btn-sm btn-danger" data-delkey="' + k.index + '">Remove</button></td></tr>';
          }).join('') + '</tbody></table></div>'
          : '<p class="hint" style="margin-top:0">No keys yet.</p>') +
        '<label class="field" style="margin-top:14px"><span>Add a key (paste the contents of a .pub file)</span>' +
        '<textarea id="key-add" rows="3" class="mono" placeholder="ssh-ed25519 AAAA… name@computer"></textarea></label>' +
        '<button class="btn btn-primary" id="key-add-btn">Add key</button>') +
      card('Replace all keys', 'Paste the complete list, one key per line. Leave it empty to remove every key.',
        '<textarea id="key-all" rows="5" class="mono" style="width:100%"></textarea>' +
        '<div class="btn-row" style="margin-top:10px"><button class="btn btn-danger" id="key-reset">Replace the list</button></div>') +
      card('SSH settings', 'Turning password sign-in off is safer, but only once a key works.',
        '<div class="form-row">' + f('ssh-port', 'Port', r.port, 'number') + '</div>' +
        toggle('ssh-pw', 'Allow signing in with a password', r.password_auth) + '<br>' +
        toggle('ssh-rootpw', 'Allow the root account to use a password', r.root_password_auth) +
        '<div class="btn-row" style="margin-top:12px"><button class="btn btn-primary" id="ssh-save">Save</button></div>'));
    $$('[data-delkey]').forEach(function (b) {
      b.onclick = function () {
        confirmModal('Remove this key?', 'That computer will no longer be able to sign in with it.', 'Remove').then(function (go) {
          if (go) post('/ssh/keys/del', { index: b.getAttribute('data-delkey') }).then(done).then(views.access).catch(fail);
        });
      };
    });
    $('#key-add-btn').onclick = function () { post('/ssh/keys/add', { key: $('#key-add').value }).then(done).then(views.access).catch(fail); };
    $('#key-reset').onclick = function () {
      confirmModal('Replace every SSH key?', 'Only the keys in the box will be allowed afterwards.', 'Replace').then(function (go) {
        if (go) post('/ssh/keys/reset', { keys: $('#key-all').value }).then(done).then(views.access).catch(fail);
      });
    };
    $('#ssh-save').onclick = function () {
      post('/ssh', { port: $('#ssh-port').value, password_auth: $('#ssh-pw').checked ? '1' : '0',
        root_password_auth: $('#ssh-rootpw').checked ? '1' : '0' }).then(done).catch(fail);
    };
  }).catch(fail);
};

/* ======================= status & logs ======================= */
views.status = function () {
  page('Status &amp; logs', 'What the router is doing right now.',
    '<div class="grid c3"><div id="st-load"></div><div id="st-mem"></div><div id="st-ct"></div></div>' +
    card('Interfaces', '', '<div id="st-if" class="tbl-wrap"></div>') +
    card('Running programs', 'Stop a program only if you know what it does.', '<input class="nav-search" id="ps-filter" placeholder="Filter…" style="margin-bottom:10px"><div id="st-ps" class="tbl-wrap"></div>') +
    card('Event log', 'Every line drop, cable change, restart and error, newest first. Copied to the website whenever the internet works.',
      '<div class="hint" id="ev-sync" style="margin:0 0 10px"></div><div class="tbl-wrap" id="ev-tbl" style="max-height:360px;overflow-y:auto"></div>') +
    card('Logs', '', '<div class="btn-row" style="margin-bottom:10px"><button class="btn btn-sm" data-log="syslog">System log</button>' +
      '<button class="btn btn-sm" data-log="dmesg">Kernel log</button><button class="btn btn-sm" data-log="routes">Routes</button>' +
      '<button class="btn btn-sm" data-log="neigh">Neighbours (ARP)</button></div><pre class="pre" id="st-log">Loading…</pre>'));
  var net = null;
  function showLog(which) {
    $$('[data-log]').forEach(function (b) { b.classList.toggle('btn-primary', b.getAttribute('data-log') === which); });
    var out = $('#st-log');
    if (which === 'syslog') api('/syslog?lines=300').then(function (r) { out.textContent = r.log || '(empty)'; out.scrollTop = out.scrollHeight; }).catch(fail);
    else if (which === 'dmesg') api('/dmesg').then(function (r) { out.textContent = r.log || '(empty)'; out.scrollTop = out.scrollHeight; }).catch(fail);
    else if (net) out.textContent = which === 'routes' ? (net.routes + '\n\nIPv6\n' + net.routes6) : net.neigh;
  }
  $$('[data-log]').forEach(function (b) { b.onclick = function () { showLog(b.getAttribute('data-log')); }; });
  api('/netstatus').then(function (r) {
    net = r;
    var rows = (r.interfaces.interface || []).map(function (i) {
      var ip = (i['ipv4-address'] || []).map(function (a) { return a.address + '/' + a.mask; }).join(', ');
      return '<tr><td><b>' + esc(i.interface) + '</b></td><td>' + (i.up ? '<span class="badge ok">up</span>' : '<span class="badge">down</span>') +
        '</td><td>' + esc(i.proto) + '</td><td class="mono">' + esc(i.l3_device || i.device || '') + '</td><td class="mono">' + esc(ip) +
        '</td><td>' + (i.up ? fmtUptime(i.uptime) : '—') + '</td></tr>';
    }).join('');
    $('#st-if').innerHTML = '<table><thead><tr><th>Name</th><th>State</th><th>Type</th><th>Device</th><th>Address</th><th>Up for</th></tr></thead><tbody>' + rows + '</tbody></table>';
    $('#st-ct').innerHTML = tile('Connections tracked', r.conntrack || '—', 'in use / maximum', '');
  }).catch(fail);
  function loadPs() {
    api('/processes').then(function (r) {
      var mem = {}; (r.mem || '').split('\n').forEach(function (l) { var p = l.split(' '); mem[p[0]] = +p[1]; });
      $('#st-load').innerHTML = tile('Load', r.load, '1 / 5 / 15 min', '');
      $('#st-mem').innerHTML = tile('Memory free', fmtBytes((mem['MemAvailable:'] || 0) * 1024), 'of ' + fmtBytes((mem['MemTotal:'] || 0) * 1024), '');
      var lines = (r.ps || '').split('\n').slice(1).filter(Boolean);
      window.__ps = lines.map(function (l) {
        var m = l.match(/^\s*(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.*)$/);
        return m ? { pid: m[1], user: m[2], vsz: m[3], stat: m[4], cmd: m[5] } : null;
      }).filter(Boolean);
      renderPs();
    }).catch(fail);
  }
  function renderPs() {
    var q = ($('#ps-filter').value || '').toLowerCase();
    $('#st-ps').innerHTML = '<table><thead><tr><th>PID</th><th>Program</th><th>Memory</th><th></th></tr></thead><tbody>' +
      window.__ps.filter(function (p) { return !q || p.cmd.toLowerCase().indexOf(q) !== -1; }).map(function (p) {
        return '<tr><td class="mono">' + p.pid + '</td><td class="mono" style="font-size:11.5px;word-break:break-all">' + esc(p.cmd) +
          '</td><td class="mono">' + esc(p.vsz) + '</td><td>' + (p.pid > 1 && p.cmd.charAt(0) !== '[' ?
          '<button class="btn btn-sm" data-kill="' + p.pid + '">Stop</button>' : '') + '</td></tr>';
      }).join('') + '</tbody></table>';
    $$('[data-kill]').forEach(function (b) {
      b.onclick = function () {
        confirmModal('Stop process ' + b.getAttribute('data-kill') + '?', 'If it is a service, it may start again by itself.', 'Stop').then(function (go) {
          if (go) post('/processes/kill', { pid: b.getAttribute('data-kill'), signal: 'TERM' }).then(done).then(loadPs).catch(fail);
        });
      };
    });
  }
  $('#ps-filter').oninput = renderPs;
  loadPs();
  showLog('syslog');
  api('/events?lines=400').then(function (r) {
    var kinds = { line: 'Internet line', wire: 'Cable', power: 'Power', error: 'Error', info: 'Info' };
    var rows = (r.log || '').split('\n').filter(Boolean).reverse().map(function (l) {
      var p = l.split('|'), ts = +p[0], sev = p[2];
      return '<tr><td class="mono" style="white-space:nowrap">' + esc(new Date(ts * 1000).toLocaleString()) + '</td><td><span class="badge ' +
        (sev === 'error' ? 'danger' : sev === 'warn' ? 'warn' : 'ok') + '">' + esc(kinds[p[1]] || p[1]) + '</span></td><td>' + esc(p.slice(3).join('|')) + '</td></tr>';
    }).join('');
    $('#ev-tbl').innerHTML = rows ? '<table><tbody>' + rows + '</tbody></table>' : '<p class="hint">Nothing recorded yet.</p>';
    $('#ev-sync').innerHTML = (r.sync_enabled ? 'Uploading to the website' : 'Upload is off') + ' &middot; ' + (r.uploaded || 0) + ' of ' + (r.total || 0) +
      ' events sent' + (r.last_push ? ' &middot; last upload ' + fmtAgo(r.last_push) : '') + ' &middot; site tracking ' + (r.track_sites ? 'on' : 'off');
  }).catch(function () {});
};

/* ======================= services & schedule ======================= */
views.services = function () {
  Promise.all([api('/services'), api('/cron')]).then(function (r) {
    var sv = r[0].services || [], cr = r[1];
    page('Services &amp; schedule', 'Programs that start with the router, tasks that run on a timetable, and your own startup commands.',
      card('Services', 'Switch "Start at boot" off to keep a service from starting with the router.',
        '<input class="nav-search" id="sv-filter" placeholder="Filter…" style="margin-bottom:10px"><div class="tbl-wrap" id="sv-tbl"></div>') +
      card('Scheduled tasks', 'One task per line: minute hour day month weekday command. Example: <code>0 4 * * * reboot</code> restarts every day at 04:00.',
        '<textarea id="cron" rows="7" class="mono" style="width:100%">' + esc(cr.cron) + '</textarea>') +
      card('Startup commands', 'Runs once at the end of every boot. Keep <code>exit 0</code> as the last line.',
        '<textarea id="rclocal" rows="7" class="mono" style="width:100%">' + esc(cr.rclocal) + '</textarea>' +
        '<div class="btn-row" style="margin-top:12px"><button class="btn btn-primary" id="cron-save">Save tasks and startup commands</button></div>'));
    function render() {
      var q = ($('#sv-filter').value || '').toLowerCase();
      $('#sv-tbl').innerHTML = '<table><thead><tr><th>Service</th><th>State</th><th>Start at boot</th><th></th></tr></thead><tbody>' +
        sv.filter(function (s) { return !q || s.name.indexOf(q) !== -1; }).map(function (s) {
          return '<tr><td><b>' + esc(s.name) + '</b></td><td>' + (s.running ? '<span class="badge ok">running</span>' : '<span class="badge">stopped</span>') +
            '</td><td><input type="checkbox" data-boot="' + esc(s.name) + '"' + (s.enabled ? ' checked' : '') + '></td><td class="btn-row" style="flex-wrap:nowrap">' +
            ['start', 'stop', 'restart'].map(function (a) { return '<button class="btn btn-sm" data-svc="' + esc(s.name) + '" data-act="' + a + '">' + a.charAt(0).toUpperCase() + a.slice(1) + '</button>'; }).join('') +
            '</td></tr>';
        }).join('') + '</tbody></table>';
      $$('[data-boot]').forEach(function (c) {
        c.onchange = function () { post('/services', { name: c.getAttribute('data-boot'), action: c.checked ? 'enable' : 'disable' }).then(done).catch(fail); };
      });
      $$('[data-svc]').forEach(function (b) {
        b.onclick = function () {
          var n = b.getAttribute('data-svc'), a = b.getAttribute('data-act');
          var risky = /^(network|uhttpd|mwadmin|firewall|dnsmasq|dropbear|rpcd)$/.test(n) && a !== 'start';
          (risky ? confirmModal(a + ' ' + n + '?', 'This can cut your connection to this page for a moment.', a) : Promise.resolve(true)).then(function (go) {
            if (go) post('/services', { name: n, action: a }).then(done).then(function () { setTimeout(views.services, 2500); }).catch(fail);
          });
        };
      });
    }
    $('#sv-filter').oninput = render;
    render();
    $('#cron-save').onclick = function () { post('/cron', { cron: $('#cron').value, rclocal: $('#rclocal').value }).then(done).catch(fail); };
  }).catch(fail);
};

/* ======================= packages ======================= */
views.packages = function () {
  api('/packages').then(function (r) {
    var inst = r.installed || [];
    var ups = inst.filter(function (p) { return p.upgradable; }).length;
    page('Packages', 'Add or remove software. Free space: <b>' + esc(r.free) + '</b>.',
      '<div id="pkg-job"></div>' +
      card('Find and install', 'Search the OpenWrt package list.',
        '<div class="form-row"><label class="field"><span>Package name</span><input id="pkg-q" placeholder="e.g. tcpdump"></label></div>' +
        '<div class="btn-row"><button class="btn btn-primary" id="pkg-search">Search</button><button class="btn" id="pkg-update">Refresh package lists</button></div>' +
        '<div id="pkg-results" style="margin-top:12px"></div>') +
      card('Installed (' + inst.length + ')', ups ? ups + ' can be upgraded.' : 'Everything is up to date as of the last refresh.',
        '<input class="nav-search" id="pkg-filter" placeholder="Filter…" style="margin-bottom:10px"><div class="tbl-wrap" id="pkg-tbl"></div>'));
    function act(action, name, then) {
      post('/packages', { action: action, name: name || '' }).then(function () {
        watchJob($('#pkg-job'), function () { if (then) then(); });
      }).catch(fail);
    }
    function render() {
      var q = ($('#pkg-filter').value || '').toLowerCase();
      $('#pkg-tbl').innerHTML = '<table><thead><tr><th>Package</th><th>Version</th><th></th></tr></thead><tbody>' +
        inst.filter(function (p) { return !q || p.name.indexOf(q) !== -1; }).map(function (p) {
          return '<tr><td>' + esc(p.name) + '</td><td class="mono" style="font-size:11.5px">' + esc(p.version) + '</td><td class="btn-row" style="flex-wrap:nowrap">' +
            (p.upgradable ? '<button class="btn btn-sm btn-primary" data-pup="' + esc(p.name) + '">Upgrade</button>' : '') +
            '<button class="btn btn-sm" data-prm="' + esc(p.name) + '">Remove</button></td></tr>';
        }).join('') + '</tbody></table>';
      $$('[data-pup]').forEach(function (b) { b.onclick = function () { act('upgrade', b.getAttribute('data-pup'), views.packages); }; });
      $$('[data-prm]').forEach(function (b) {
        b.onclick = function () {
          var n = b.getAttribute('data-prm');
          confirmModal('Remove ' + esc(n) + '?', 'Anything that depends on it stops working.', 'Remove').then(function (go) {
            if (go) act('remove', n, views.packages);
          });
        };
      });
    }
    $('#pkg-filter').oninput = render;
    render();
    $('#pkg-update').onclick = function () { act('update', '', views.packages); };
    function search() {
      var q = $('#pkg-q').value.trim(); if (!q) return;
      $('#pkg-results').innerHTML = '<span class="spinner"></span>';
      api('/packages?q=' + encodeURIComponent(q)).then(function (s) {
        var have = {}; inst.forEach(function (p) { have[p.name] = 1; });
        $('#pkg-results').innerHTML = (s.results || []).length ? '<div class="tbl-wrap"><table><tbody>' + s.results.map(function (p) {
          return '<tr><td>' + esc(p.name) + '</td><td class="mono" style="font-size:11.5px">' + esc(p.version) + '</td><td>' +
            (have[p.name] ? '<span class="badge ok">installed</span>' : '<button class="btn btn-sm btn-primary" data-pin="' + esc(p.name) + '">Install</button>') + '</td></tr>';
        }).join('') + '</tbody></table></div>' : '<p class="hint">Nothing found. Try "Refresh package lists" first.</p>';
        $$('[data-pin]').forEach(function (b) { b.onclick = function () { act('install', b.getAttribute('data-pin'), views.packages); }; });
      }).catch(fail);
    }
    $('#pkg-search').onclick = search;
    $('#pkg-q').onkeydown = function (e) { if (e.key === 'Enter') search(); };
    watchJob($('#pkg-job'));
  }).catch(fail);
};

/* ======================= backup & firmware ======================= */
views.maintenance = function () {
  page('Backup &amp; firmware', 'Save or restore your settings, restart, reset, or install new firmware.',
    card('Backup', 'Contains every setting, including Wi-Fi passwords and keys. Keep it private.',
      '<div class="btn-row"><a class="btn btn-primary" href="' + API + '/system/backup' + (session ? '?session=' + encodeURIComponent(session) : '') + '" download>Download backup</a></div>') +
    card('Restore', 'Choose a backup file made by this router. It restarts afterwards.',
      '<input type="file" id="rs-file" accept=".tar.gz,.tgz,application/gzip">' +
      '<div class="btn-row" style="margin-top:10px"><button class="btn btn-danger" id="rs-go">Restore and restart</button></div>') +
    card('Restart', 'Everything loses its connection for about a minute.', '<button class="btn btn-danger" id="mt-reboot">Restart now</button>') +
    card('Install firmware', 'Paste the link to an OpenWrt <b>sysupgrade</b> image for this exact model. It is checked before anything is written.',
      '<div class="form-row"><label class="field" style="flex:1"><span>Image link</span><input id="fw-url" placeholder="https://downloads.openwrt.org/…-sysupgrade.bin"></label></div>' +
      toggle('fw-keep', 'Keep my settings', true) +
      '<div class="btn-row" style="margin-top:10px"><button class="btn" id="fw-fetch">Download and check</button><button class="btn btn-danger" id="fw-apply" hidden>Install now</button></div>' +
      '<div id="fw-job" style="margin-top:10px"></div>') +
    card('Factory reset', 'Erases every setting and this software&rsquo;s data. The router comes back as fresh OpenWrt on 192.168.1.1.',
      '<div class="form-row"><label class="field"><span>Type RESET to confirm</span><input id="fr-confirm"></label></div>' +
      '<button class="btn btn-danger" id="fr-go">Erase everything</button>') +
    // deliberately tucked away: the 18+ filter lives here, behind a faint "More"
    '<details id="mt-more" style="margin-top:34px;font-size:12px;color:var(--text-dim);opacity:.5">' +
      '<summary style="cursor:pointer;list-style:none">More</summary><div id="mt-more-body" style="margin-top:12px"></div></details>');
  $('#mt-more').addEventListener('toggle', function () {
    var box = $('#mt-more-body');
    if (!this.open) return;
    this.style.opacity = '1';
    box.innerHTML = '<span class="spinner"></span>';
    api('/blocklist/adult').then(function (a) {
      box.innerHTML = card('Content filter', 'Blocks 18+ sites for every device on the network, including the never-blocked ones. ' +
        'Devices cannot get around it with their own DNS settings. Google and Bing searches use SafeSearch while it is on.',
        '<label class="switch"><input type="checkbox" id="ad-on"' + (a.enabled ? ' checked' : '') +
        '><span class="track"></span><span>18+ sites blocked</span></label>');
      $('#ad-on').onchange = function () {
        var cb = this, on = cb.checked;
        cb.checked = !on;
        (on ? Promise.resolve(true) : confirmModal('Are you sure?', 'Every device on the network will be able to open 18+ sites again.', 'Yes, turn the filter off'))
          .then(function (yes) {
            if (!yes) return;
            cb.disabled = true;
            post('/blocklist/adult', { enabled: on ? '1' : '0' })
              .then(function (j) { toast(j.message, 'ok'); cb.checked = on; cb.disabled = false; })
              .catch(function (e) { toast(e.message, 'error'); cb.disabled = false; });
          });
      };
    }).catch(function (e) { box.textContent = e.message; });
  });
  $('#mt-reboot').onclick = function () {
    confirmModal('Restart the router?', 'Every device loses its connection for about a minute.', 'Restart').then(function (go) {
      if (go) post('/system/reboot').then(done).catch(fail);
    });
  };
  $('#rs-go').onclick = function () {
    var file = $('#rs-file').files[0];
    if (!file) { toast('Choose a backup file first.', 'error'); return; }
    if (file.size > 180000) { toast('That file is too large to be a backup of this router.', 'error'); return; }
    confirmModal('Restore ' + esc(file.name) + '?', 'Your current settings are replaced and the router restarts.', 'Restore').then(function (go) {
      if (!go) return;
      var rd = new FileReader();
      rd.onload = function () { post('/system/restore', { data: String(rd.result).split(',')[1] || '' }).then(done).catch(fail); };
      rd.readAsDataURL(file);
    });
  };
  function fwWatch() {
    watchJob($('#fw-job'), function (j) { $('#fw-apply').hidden = !(j.exit_code === 0 && /IMAGE OK/.test(j.log || '')); });
  }
  $('#fw-fetch').onclick = function () { post('/system/flash/fetch', { url: $('#fw-url').value.trim() }).then(fwWatch).catch(fail); };
  $('#fw-apply').onclick = function () {
    confirmModal('Install this firmware?', 'Do not unplug the router. It restarts by itself in 2&ndash;4 minutes.' +
      ($('#fw-keep').checked ? '' : '<br><b>All settings will be erased.</b>'), 'Install').then(function (go) {
      if (go) post('/system/flash/apply', { keep: $('#fw-keep').checked ? '1' : '0' }).then(done).catch(fail);
    });
  };
  $('#fr-go').onclick = function () {
    confirmModal('Erase everything?', 'This cannot be undone. Download a backup first if you might want your settings back.', 'Erase').then(function (go) {
      if (go) post('/system/reset', { confirm: $('#fr-confirm').value.trim() }).then(done).catch(fail);
    });
  };
  fwWatch();
};

/* ======================= raw config files ======================= */
views.config = function () {
  api('/config').then(function (r) {
    page('Config files', 'For experts: edit any OpenWrt setting directly. The file is checked before it is saved, and applied straight away.',
      card('Edit', '', '<div class="form-row"><label class="field"><span>File</span><select id="cf-name">' +
        r.files.map(function (n) { return '<option>' + esc(n) + '</option>'; }).join('') + '</select></label></div>' +
        '<textarea id="cf-text" rows="22" class="mono" style="width:100%;font-size:12px" spellcheck="false"></textarea>' +
        '<div class="btn-row" style="margin-top:10px"><button class="btn btn-primary" id="cf-save">Save and apply</button><button class="btn" id="cf-reload">Discard changes</button></div>'));
    function load() {
      api('/config?name=' + encodeURIComponent($('#cf-name').value)).then(function (c) { $('#cf-text').value = c.text; }).catch(fail);
    }
    $('#cf-name').onchange = load;
    $('#cf-reload').onclick = load;
    $('#cf-save').onclick = function () {
      confirmModal('Save ' + esc($('#cf-name').value) + '?', 'A mistake here can cut off the network. The old version is kept until the next restart.', 'Save').then(function (go) {
        if (go) post('/config', { name: $('#cf-name').value, text: $('#cf-text').value }).then(done).catch(fail);
      });
    };
    load();
  }).catch(fail);
};

/* ======================= which line carries what ======================= */
var CALL_APPS = [['whatsapp', 'WhatsApp &amp; Messenger calls'], ['zoom', 'Zoom'], ['meet', 'Google Meet'], ['teams', 'Teams and other video calls']];
function loadLines() {
  var el = $('#lines-card'); if (!el) return;
  Promise.all([api('/lines'), api('/devices').catch(function () { return { devices: [] }; })]).then(function (r) {
    var L = r[0], devs = r[1].devices || [];
    var wname = function (w) { var x = (L.wans || []).filter(function (v) { return v.iface === w; })[0]; return (x && x.label ? x.label + ' (' + w.toUpperCase() + ')' : w.toUpperCase()) + (x && !x.online ? ' — offline' : ''); };
    var opts = function (cur, autoLabel) {
      return '<option value="auto"' + (cur === 'auto' || !cur ? ' selected' : '') + '>' + autoLabel + '</option>' +
        (L.wans || []).map(function (w) { return '<option value="' + w.iface + '"' + (cur === w.iface ? ' selected' : '') + '>' + esc(wname(w.iface)) + '</option>'; }).join('');
    };
    var apps = ' ' + (L.calls_apps || '') + ' ';
    var pinned = {}; (L.devices || []).forEach(function (d) { pinned[d.mac] = 1; });
    el.innerHTML =
      '<h4 style="margin:0 0 6px">Calls and meetings</h4>' +
      '<p class="hint" style="margin-top:0">Put voice and video calls on the steadiest line, and leave downloads and video streaming on the other. ' +
        'If that line fails, calls move to the next one by themselves. A call that is already running keeps its line.</p>' +
      '<div class="form-row"><label class="field"><span>Calls use</span><select id="ln-calls">' + opts(L.calls_wan, 'Automatic (normal line order)') + '</select></label></div>' +
      CALL_APPS.map(function (a) { return toggle('ln-app-' + a[0], a[1], apps.indexOf(' ' + a[0] + ' ') !== -1); }).join('<br>') +
      '<div class="btn-row" style="margin-top:10px"><button class="btn btn-primary" id="ln-calls-save">Save</button></div>' +
      '<h4 style="margin:22px 0 6px">Devices with their own line</h4>' +
      '<p class="hint" style="margin-top:0">Give one device a preferred line, for example a teacher&rsquo;s laptop. It falls back to the other lines if that one fails. ' +
        'Calls follow the setting above even on these devices. Choosing a line also gives the device a fixed address.</p>' +
      ((L.devices || []).length ? '<div class="tbl-wrap"><table><thead><tr><th>Device</th><th>Address</th><th>Line</th></tr></thead><tbody>' +
        L.devices.map(function (d) {
          return '<tr><td>' + esc(d.name || d.mac) + '<div class="hint mono" style="margin:0">' + esc(d.mac) + '</div></td><td class="mono">' + esc(d.ip || '—') +
            '</td><td><select data-devline="' + esc(d.mac) + '" data-n="' + esc(d.name) + '">' + opts(d.wan, 'Normal (remove)') + '</select></td></tr>';
        }).join('') + '</tbody></table></div>' : '') +
      '<div class="form-row" style="margin-top:10px"><label class="field"><span>Device</span><select id="ln-dev">' +
        devs.filter(function (d) { return d.mac && !pinned[String(d.mac).toLowerCase()]; }).map(function (d) {
          return '<option value="' + esc(d.mac) + '" data-n="' + esc(d.name) + '">' + esc(d.name) + ' (' + esc(d.ip || d.mac) + ')</option>'; }).join('') +
      '</select></label><label class="field"><span>Line</span><select id="ln-dev-wan">' + opts('', 'Choose…').replace('value="auto"', 'value="" disabled') + '</select></label></div>' +
      '<button class="btn" id="ln-dev-add">Add</button>';
    $('#ln-calls-save').onclick = function () {
      var picked = CALL_APPS.filter(function (a) { return $('#ln-app-' + a[0]).checked; }).map(function (a) { return a[0]; }).join(',');
      post('/lines/calls', { wan: $('#ln-calls').value, apps: picked }).then(done).then(function () { setTimeout(loadLines, 1500); }).catch(fail);
    };
    $$('[data-devline]').forEach(function (s) {
      s.onchange = function () { post('/lines/device', { mac: s.getAttribute('data-devline'), name: s.getAttribute('data-n'), wan: s.value }).then(done).then(function () { setTimeout(loadLines, 1500); }).catch(fail); };
    });
    $('#ln-dev-add').onclick = function () {
      var d = $('#ln-dev'), w = $('#ln-dev-wan').value;
      if (!d.value || !w) { toast('Choose a device and a line.', 'error'); return; }
      post('/lines/device', { mac: d.value, name: d.selectedOptions[0].getAttribute('data-n'), wan: w }).then(done).then(function () { setTimeout(loadLines, 1500); }).catch(fail);
    };
  }).catch(function (e) { el.innerHTML = '<p class="hint">' + esc(e.message) + '</p>'; });
}

/* ======================= never-blocked devices ======================= */
function loadExempt() {
  var el = $('#exempt-card'); if (!el) return;
  Promise.all([api('/exempt'), api('/devices').catch(function () { return { devices: [] }; })]).then(function (r) {
    var list = r[0].devices || [], devs = r[1].devices || [], on = {};
    list.forEach(function (d) { on[d.mac] = 1; });
    el.innerHTML =
      '<p class="hint" style="margin-top:0">These devices skip all blocking: blocked sites and apps, the games list, ' +
        'the ad blocker and the network sign-in page. Speed limits, line choices and the 18+ filter still apply.</p>' +
      (list.length ? '<div class="tbl-wrap"><table><tbody>' + list.map(function (d) {
        return '<tr><td><b>' + esc(d.name || d.mac) + '</b><div class="hint mono" style="margin:0">' + esc(d.mac) + (d.ip ? ' &middot; ' + esc(d.ip) : '') + '</div></td>' +
          '<td style="text-align:right"><button class="btn btn-sm" data-unexempt="' + esc(d.mac) + '">Remove</button></td></tr>';
      }).join('') + '</tbody></table></div>' : '<p class="hint">No devices on the list.</p>') +
      '<div class="form-row" style="margin-top:12px"><label class="field" style="flex:1"><span>Add a device</span><select id="exempt-dev">' +
        devs.filter(function (d) { return d.mac && !on[String(d.mac).toLowerCase()]; }).map(function (d) {
          return '<option value="' + esc(d.mac) + '" data-n="' + esc(d.name) + '">' + esc(d.name) + ' (' + esc(d.ip || d.mac) + ')</option>'; }).join('') +
      '</select></label></div><button class="btn btn-primary" id="exempt-add">Never block this device</button>';
    $$('[data-unexempt]', el).forEach(function (b) {
      b.onclick = function () { post('/exempt/del', { mac: b.getAttribute('data-unexempt') }).then(done).then(loadExempt).catch(fail); };
    });
    $('#exempt-add').onclick = function () {
      var s = $('#exempt-dev'); if (!s.value) { toast('Choose a device.', 'error'); return; }
      post('/exempt/add', { mac: s.value, name: s.selectedOptions[0].getAttribute('data-n') }).then(done).then(loadExempt).catch(fail);
    };
  }).catch(function (e) { el.innerHTML = '<p class="hint">' + esc(e.message) + '</p>'; });
}

/* ======================= free time, break time, groups (pause.sh) ======================= */
function fmtMin(s) { var m = Math.ceil((s || 0) / 60); return m + ' min'; }

function loadPause() {
  var el = $('#pause-card'); if (!el) return;
  Promise.all([api('/pause'), api('/devices').catch(function () { return { devices: [] }; })]).then(function (r) {
    var p = r[0], devs = r[1].devices || [], editing = el.getAttribute('data-edit') || '';
    var inGroup = {};
    (p.groups || []).forEach(function (g) { (g.devices || []).forEach(function (d) { inGroup[d.mac] = g.id; }); });

    function usageRow(u, title, sub, extra) {
      return '<tr><td><b>' + esc(title) + '</b>' + (sub ? '<div class="hint" style="margin:0">' + sub + '</div>' : '') + '</td>' +
        '<td>' + (u.running ? '<span class="badge ok">unpaused</span> ' : '') + esc(fmtMin(u.left_s)) + ' left</td>' +
        '<td style="text-align:right;white-space:nowrap">' +
          '<button class="btn btn-sm" data-ptog="' + esc(u.owner) + '" data-on="' + (u.running ? 0 : 1) + '">' + (u.running ? 'Pause' : 'Unpause') + '</button> ' +
          '<button class="btn btn-sm" data-preset="' + esc(u.owner) + '" title="Give the full time back for today">Reset</button>' + (extra || '') + '</td></tr>';
    }
    function groupForm(g) {
      var mine = {}; (g ? g.devices : []).forEach(function (d) { mine[d.mac] = 1; });
      return '<div class="pg-form" style="border:1px solid var(--border);border-radius:10px;padding:12px;margin-top:10px">' +
        '<label class="field"><span>Group name</span><input id="pg-name" maxlength="32" value="' + esc(g ? g.name : '') + '" placeholder="e.g. Ali"></label>' +
        '<div class="hint" style="margin:0 0 6px">Devices in a group share one allowance.</div>' +
        '<div style="max-height:220px;overflow:auto">' + devs.filter(function (d) { return d.mac; }).map(function (d) {
          var m = String(d.mac).toLowerCase(), other = inGroup[m] && (!g || inGroup[m] !== g.id);
          return '<label class="switch" style="display:flex;margin:4px 0"><input type="checkbox" data-pgmac="' + esc(m) + '"' + (mine[m] ? ' checked' : '') + '>' +
            '<span class="track"></span><span>' + esc(d.name || m) + ' <span class="hint mono">' + esc(d.ip || m) + '</span>' +
            (other ? ' <span class="badge warn">moves from another group</span>' : '') + '</span></label>';
        }).join('') + '</div>' +
        '<div class="btn-row" style="margin-top:10px"><button class="btn btn-primary" id="pg-save" data-id="' + esc(g ? g.id : '') + '">Save group</button>' +
        '<button class="btn" id="pg-cancel">Cancel</button></div></div>';
    }

    var groups = p.groups || [];
    el.innerHTML =
      '<div class="form-row">' +
        '<label class="field"><span>Free time per day (minutes)</span><input type="number" min="0" max="1440" id="pz-allow" value="' + esc(p.allow_min) + '"></label>' +
        '<label class="field"><span>Break starts</span><input type="time" id="pz-from" value="' + esc(p.break_from) + '"></label>' +
        '<label class="field"><span>Break ends</span><input type="time" id="pz-to" value="' + esc(p.break_to) + '"></label></div>' +
      '<p class="hint">Router time ' + esc(p.now) + '. ' + (p.in_break ? '<b>Break time now:</b> blocked sites are open for everyone.' :
        'During the break the blocked sites open for everyone and nobody&rsquo;s free time counts down. Leave both break times empty for no break.') +
        ' Free time resets at midnight. People pause and unpause it themselves at <b>sites.router</b>.</p>' +
      '<button class="btn" id="pz-save">Save</button>' +
      '<h4 style="margin:18px 0 8px">Groups</h4>' +
      (groups.length ? '<div class="tbl-wrap"><table><tbody>' + groups.map(function (g) {
        return usageRow(g.usage, g.name, (g.devices || []).map(function (d) { return esc(d.name || d.mac); }).join(', ') || 'no devices',
          ' <button class="btn btn-sm" data-pgedit="' + esc(g.id) + '">Edit</button> <button class="btn btn-sm" data-pgdel="' + esc(g.id) + '">Delete</button>');
      }).join('') + '</tbody></table></div>' : '<p class="hint">No groups yet. Every device has its own free time.</p>') +
      (editing === 'new' ? groupForm(null) : (editing ? groupForm(groups.filter(function (g) { return g.id === editing; })[0]) : '<button class="btn btn-sm" id="pg-new" style="margin-top:8px">New group</button>')) +
      ((p.devices || []).length ? '<h4 style="margin:18px 0 8px">Devices that used free time today</h4><div class="tbl-wrap"><table><tbody>' +
        p.devices.map(function (u) { return usageRow(u, u.name, '<span class="mono">' + esc(u.owner) + '</span>'); }).join('') + '</tbody></table></div>' : '');

    $('#pz-save').onclick = function () {
      post('/pause/settings', { allow_min: $('#pz-allow').value, break_from: $('#pz-from').value, break_to: $('#pz-to').value })
        .then(done).then(loadPause).catch(fail);
    };
    $$('[data-ptog]', el).forEach(function (b) {
      b.onclick = function () { post('/pause/toggle', { owner: b.getAttribute('data-ptog'), on: b.getAttribute('data-on') }).then(done).then(loadPause).catch(fail); };
    });
    $$('[data-preset]', el).forEach(function (b) {
      b.onclick = function () { post('/pause/reset', { owner: b.getAttribute('data-preset') }).then(done).then(loadPause).catch(fail); };
    });
    $$('[data-pgedit]', el).forEach(function (b) { b.onclick = function () { el.setAttribute('data-edit', b.getAttribute('data-pgedit')); loadPause(); }; });
    $$('[data-pgdel]', el).forEach(function (b) {
      b.onclick = function () {
        confirmModal('Delete this group?', 'Its devices go back to having their own free time each.', 'Delete').then(function (go) {
          if (go) post('/pause/group/delete', { id: b.getAttribute('data-pgdel') }).then(done).then(loadPause).catch(fail);
        });
      };
    });
    var nb = $('#pg-new'); if (nb) nb.onclick = function () { el.setAttribute('data-edit', 'new'); loadPause(); };
    var cb = $('#pg-cancel'); if (cb) cb.onclick = function () { el.setAttribute('data-edit', ''); loadPause(); };
    var sb = $('#pg-save');
    if (sb) sb.onclick = function () {
      var macs = $$('[data-pgmac]', el).filter(function (c) { return c.checked; }).map(function (c) { return c.getAttribute('data-pgmac'); });
      post('/pause/group', { id: sb.getAttribute('data-id'), name: $('#pg-name').value.trim(), macs: macs.join(',') })
        .then(function (j) { el.setAttribute('data-edit', ''); return j; }).then(done).then(loadPause).catch(fail);
    };
  }).catch(function (e) { el.innerHTML = '<p class="hint">' + esc(e.message) + '</p>'; });
}

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
    fetch(SELF_URL, { method: 'HEAD', cache: 'no-store' }).then(function (r) {
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

/* Every section folds away to its title bar: press the round arrow or the
   title. Remembered per section on this device. Sections that redraw keep
   their state because it is looked up again each time they appear. */
(function () {
  var HEADS = '.glass > .sec-h, .card > .card-head';
  var SVG = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 15l6-6 6 6"/></svg>';
  function store(k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } }
  function keyOf(box, head) {
    var k = box.id ? 'id=' + box.id : '';
    for (var i = 0; !k && i < box.attributes.length; i++) {
      var a = box.attributes[i];
      if (/^data-/.test(a.name) && !/^data-fold/.test(a.name)) k = a.name.slice(5) + '=' + a.value;
    }
    if (!k) { var t = head.querySelector('h2, h3'); k = t ? t.textContent.replace(/[\d,.]+/g, '').trim().slice(0, 40) : ''; }
    return k ? 'bt-fold:' + (location.pathname.split('/').pop() || 'index') + ':' + k : '';
  }
  function folded(box) {
    var v = store(box.getAttribute('data-fold-key'));
    return v === null ? box.getAttribute('data-fold-default') === 'shut' : v === '1';
  }
  function paint(box) {
    var shut = folded(box);
    box.classList.toggle('folded', shut);
    var b = box.querySelector(':scope > .sec-h > .fold-btn, :scope > .card-head > .fold-btn');
    if (b) { b.setAttribute('aria-expanded', shut ? 'false' : 'true'); b.title = shut ? 'Open' : 'Fold away'; }
  }
  function flip(box) {
    store(box.getAttribute('data-fold-key'), folded(box) ? '0' : '1');
    paint(box);
  }
  function setup(head) {
    var box = head.parentNode;
    if (!box || box.tagName === 'DETAILS' || box.hasAttribute('data-nofold')) return;
    if (!box.getAttribute('data-fold-key')) {
      var k = keyOf(box, head);
      if (!k) return;
      box.setAttribute('data-fold-key', k);
    }
    if (!head.querySelector(':scope > .fold-btn')) {
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'fold-btn'; b.innerHTML = SVG;
      b.setAttribute('aria-label', 'Fold away or open this section');
      head.appendChild(b);
      head.classList.add('has-fold');
      head.addEventListener('click', function (e) {
        if (e.target.closest('.fold-btn') || !e.target.closest('a, button, input, select, textarea, label, .seg, [data-copy]')) flip(box);
      });
    }
    paint(box);
  }
  function scan(root) {
    if (root.nodeType !== 1) return;
    if (root.matches && root.matches(HEADS)) setup(root);
    Array.prototype.forEach.call(root.querySelectorAll(HEADS), setup);
  }
  function start() {
    scan(document.body);
    new MutationObserver(function (ms) {
      ms.forEach(function (m) {
        Array.prototype.forEach.call(m.addedNodes, function (n) {
          if (n.nodeType !== 1) return;
          scan(n);
          // a section whose header was redrawn inside it
          var box = n.parentNode && n.parentNode.closest && n.parentNode.closest('[data-fold-key]');
          if (box) { var h = box.querySelector(':scope > .sec-h, :scope > .card-head'); if (h) setup(h); }
        });
      });
    }).observe(document.body, { childList: true, subtree: true });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();

/* Phones: every table turns into stacked rows. Each cell is tagged with its
   column title so the phone layout can show "IP   192.168.67.20" lines
   instead of a table you have to scroll sideways. */
(function () {
  function label(table) {
    var head = table.tHead && table.tHead.rows[0];
    if (!head) { table.classList.add('no-head'); return; }
    var names = [];
    Array.prototype.forEach.call(head.cells, function (th) {
      for (var i = 0; i < (th.colSpan || 1); i++) names.push(th.textContent.trim());
    });
    Array.prototype.forEach.call(table.tBodies, function (tb) {
      Array.prototype.forEach.call(tb.rows, function (tr) {
        var col = 0;
        Array.prototype.forEach.call(tr.cells, function (td) {
          var n = (td.colSpan || 1) === 1 ? names[col] : '';
          if (n) td.setAttribute('data-label', n); else td.removeAttribute('data-label');
          col += td.colSpan || 1;
        });
      });
    });
  }
  var queued = false;
  function run() {
    queued = false;
    Array.prototype.forEach.call(document.querySelectorAll('.content table'), label);
  }
  function start() {
    run();
    new MutationObserver(function () {
      if (!queued) { queued = true; requestAnimationFrame(run); }
    }).observe(document.body, { childList: true, subtree: true });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
