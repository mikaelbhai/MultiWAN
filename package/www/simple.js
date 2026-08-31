/* MultiWAN "Easy Setup" — the dumbed-down view. Same backend as the advanced
   app (app.js), same auth model, deliberately kept as its own small,
   self-contained script rather than sharing app.js's internals, so this page
   stays simple to read on its own. */
(function () {
'use strict';

// See app.js for the full story — set by a standalone deployment (e.g. the
// remote-app copy hosted off-router) before this script loads.
var API = window.MW_API_BASE || 'cgi-bin/mwadmin';
var session = null;
var wanPollTimers = {};

function $(sel, root) { return (root || document).querySelector(sel); }
function esc(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}

function api(path, opts) {
  opts = opts || {};
  var cfg = { method: opts.method || 'GET', headers: {}, credentials: 'same-origin' };
  if (cfg.method === 'POST') {
    // The CSRF token rides in the body as "_csrf", not a header: uhttpd's CGI
    // handler does not forward custom X-* headers into the script environment
    // at all, so a header-based token is silently dropped on every request.
    // The body is read directly off stdin server-side, same as the login
    // password, and is known to arrive intact. Standalone (no cookie ever
    // reaches this router cross-origin), this same field is what the server
    // treats as the bearer session token — see app.js/docs/07 for the full
    // explanation.
    var body = opts.body || {};
    if (session) body._csrf = session;
    cfg.headers['Content-Type'] = 'application/json';
    cfg.body = JSON.stringify(body);
  } else {
    if (opts.body) {
      cfg.headers['Content-Type'] = 'application/json';
      cfg.body = JSON.stringify(opts.body);
    }
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

/* ======================= auth ======================= */

var REMOTE = !!window.MW_API_BASE;
function saveRemoteSession(sid) {
  if (!REMOTE) return;
  try { sid ? localStorage.setItem('mw-remote-session', sid) : localStorage.removeItem('mw-remote-session'); } catch (e) {}
}

function showLogin() {
  saveRemoteSession(null);
  session = null;
  $('#app').hidden = true;
  $('#login').hidden = false;
  $('#login-pass').value = '';
  $('#login-pass').focus();
}

function showApp() {
  $('#login').hidden = true;
  $('#app').hidden = false;
  loadAll();
}

var loginInFlight = false;
$('#login-form').addEventListener('submit', function (e) {
  e.preventDefault();
  // See app.js for why this flag (not just the disabled button) matters: a
  // second Enter-triggered submit while the first login is still in flight
  // can win the browser's cookie while losing the in-memory session token,
  // and every later POST then fails CSRF.
  if (loginInFlight) return;
  loginInFlight = true;

  var pass = $('#login-pass').value;
  var btn = $('#login-btn'), err = $('#login-error');
  err.hidden = true;
  btn.disabled = true; btn.textContent = 'Signing in…';
  api('/login', { method: 'POST', body: { password: pass } }).then(function (j) {
    session = j.session;
    saveRemoteSession(session);
    showApp();
  }).catch(function (e) {
    err.textContent = e.message || 'Sign in failed.';
    err.hidden = false;
  }).finally(function () {
    loginInFlight = false;
    btn.disabled = false; btn.textContent = 'Sign in';
  });
});

/* ======================= speed test ======================= */

var WAN_LABEL = { wan1: 'Internet 1', wan2: 'Internet 2', wan3: 'Internet 3' };

function renderWanCard(w) {
  var carrier = w.carrier;
  var dot = carrier ? 'up' : 'down';
  var statLine = carrier
    ? (w.address ? 'Connected &middot; ' + esc(w.address) : 'Cable plugged in, waiting for an address')
    : 'No cable plugged in';
  return (
    '<div class="ez-wan-row" data-iface="' + w.name + '">' +
      '<span class="ez-dot ' + dot + '"></span>' +
      '<span class="ez-wan-name">' + esc(WAN_LABEL[w.name] || w.name) + '</span>' +
      '<span class="ez-wan-stat" data-stat>' + statLine + '</span>' +
      '<button class="ez-btn" data-test ' + (carrier ? '' : 'disabled') + '>Test speed</button>' +
    '</div>' +
    '<div data-result></div>'
  );
}

function resultHtml(r) {
  if (!r || r.status === 'never_tested') return '';
  if (r.status === 'nolink') return '<div class="ez-note">No cable detected.</div>';
  if (r.status === 'noaddr') return '<div class="ez-note">Cable is in, but this line has not gotten an address yet. Try again in a moment.</div>';
  if (r.status === 'running') return '<div class="ez-note">' + esc(r.message || 'Testing…') + '</div>';
  if (r.status !== 'ok') return '';
  return (
    '<div class="ez-result-grid">' +
      '<div><b>' + (r.down_mbps != null ? r.down_mbps : '—') + '</b><span>Mbps down</span></div>' +
      '<div><b>' + (r.up_mbps != null ? r.up_mbps : '—') + '</b><span>Mbps up</span></div>' +
      '<div><b>' + (r.latency_ms != null ? r.latency_ms : '—') + '</b><span>ms ping</span></div>' +
      '<div><b>' + esc(r.isp || '—') + '</b><span>Provider</span></div>' +
    '</div>' +
    (r.note ? '<div class="ez-note">' + esc(r.note) + '</div>' : '')
  );
}

function loadWans() {
  return api('/status').then(function (j) {
    var wraps = j.wans.map(renderWanCard).join('');
    $('#ez-wans').innerHTML = wraps;
    j.wans.forEach(function (w) {
      var row = $('.ez-wan-row[data-iface="' + w.name + '"]');
      var btn = row.querySelector('[data-test]');
      btn.addEventListener('click', function () { startTest(w.name); });
    });
    return api('/ports');
  }).then(function (j) {
    Object.keys(j.results).forEach(function (iface) {
      showResult(iface, j.results[iface]);
    });
  });
}

function showResult(iface, r) {
  var row = $('.ez-wan-row[data-iface="' + iface + '"]');
  if (!row) return;
  var out = row.nextElementSibling;
  out.innerHTML = resultHtml(r);
}

function startTest(iface) {
  var row = $('.ez-wan-row[data-iface="' + iface + '"]');
  row.querySelector('[data-test]').disabled = true;
  showResult(iface, { status: 'running', message: 'Starting…' });
  api('/ports/test', { method: 'POST', body: { iface: iface } }).then(function () {
    pollTest(iface);
  }).catch(function (e) {
    toast(e.message, 'error');
    row.querySelector('[data-test]').disabled = false;
  });
}

function pollTest(iface) {
  clearTimeout(wanPollTimers[iface]);
  api('/ports').then(function (j) {
    var r = j.results[iface];
    showResult(iface, r);
    var row = $('.ez-wan-row[data-iface="' + iface + '"]');
    if (r && r.status === 'running') {
      wanPollTimers[iface] = setTimeout(function () { pollTest(iface); }, 1500);
    } else {
      row.querySelector('[data-test]').disabled = false;
    }
  }).catch(function () {
    var row = $('.ez-wan-row[data-iface="' + iface + '"]');
    if (row) row.querySelector('[data-test]').disabled = false;
  });
}

/* ======================= sharing mode + per-WAN toggles ======================= */

function renderMode(mode) {
  document.querySelectorAll('.ez-mode-card').forEach(function (c) {
    c.classList.toggle('sel', c.dataset.mode === mode);
  });
}

function renderWanToggles(wans) {
  var html = wans.map(function (w) {
    return (
      '<div class="ez-switch-row">' +
        '<div>' +
          '<div class="ez-switch-label">' + esc(WAN_LABEL[w.iface] || w.iface) + '</div>' +
          '<div class="ez-switch-desc">' + (w.enabled ? 'In use' : 'Turned off — never used, even as backup') + '</div>' +
        '</div>' +
        '<button type="button" class="ez-switch ' + (w.enabled ? 'on' : '') + '" data-toggle="' + w.iface + '"></button>' +
      '</div>'
    );
  }).join('');
  $('#ez-wan-toggles').innerHTML = html;
  document.querySelectorAll('[data-toggle]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var iface = btn.dataset.toggle;
      var turnOn = !btn.classList.contains('on');
      btn.disabled = true;
      api('/mwan/wan/toggle', { method: 'POST', body: { iface: iface, enabled: turnOn ? '1' : '0' } })
        .then(function (j) { toast(j.message || 'Saved.'); return loadMwan(); })
        .catch(function (e) { toast(e.message, 'error'); })
        .finally(function () { btn.disabled = false; });
    });
  });
}

function loadMwan() {
  return api('/mwan').then(function (j) {
    renderMode(j.mode);
    renderWanToggles(j.wans);
  });
}

document.querySelectorAll('.ez-mode-card').forEach(function (card) {
  card.addEventListener('click', function () {
    var mode = card.dataset.mode;
    renderMode(mode);
    api('/mwan/mode', { method: 'POST', body: { mode: mode } })
      .then(function (j) { toast(j.message || 'Saved.'); })
      .catch(function (e) { toast(e.message, 'error'); loadMwan(); });
  });
});

/* ======================= port roles ======================= */

var PORT_LABEL = { wan: 'WAN', lan1: 'LAN 1', lan2: 'LAN 2', lan3: 'LAN 3', lan4: 'LAN 4' };
var ROLE_OPTIONS = [
  ['wan1', 'Internet 1 (main)'],
  ['wan2', 'Internet 2 (backup)'],
  ['wan3', 'Internet 3 (backup)'],
  ['lan', 'Home devices'],
  ['unassigned', 'Not used']
];

function renderPorts(ports) {
  var html = ports.map(function (p) {
    var link = p.carrier ? (p.speed_mbps ? p.speed_mbps + ' Mb' : 'Connected') : 'No cable';
    var opts = ROLE_OPTIONS.map(function (o) {
      return '<option value="' + o[0] + '"' + (o[0] === p.role ? ' selected' : '') + '>' + o[1] + '</option>';
    }).join('');
    return (
      '<div class="ez-port-row" data-port="' + p.port + '">' +
        '<span class="ez-port-tag">' + esc(PORT_LABEL[p.port] || p.port) + '</span>' +
        '<select class="ez-port-select">' + opts + '</select>' +
        '<span class="ez-port-link">' + link + '</span>' +
      '</div>'
    );
  }).join('');
  $('#ez-ports').innerHTML = html;
}

function loadPorts() {
  return api('/ports').then(function (j) { renderPorts(j.ports); });
}

$('#ez-ports-save').addEventListener('click', function () {
  var rows = document.querySelectorAll('.ez-port-row');
  var byRole = { wan1: [], wan2: [], wan3: [], lan: [] };
  rows.forEach(function (row) {
    var port = row.dataset.port;
    var role = row.querySelector('select').value;
    if (byRole[role]) byRole[role].push(port);
  });
  if (byRole.wan1.length !== 1) { toast('Pick exactly one port for Internet 1.', 'error'); return; }
  if (byRole.wan2.length > 1)   { toast('Internet 2 can only use one port.', 'error'); return; }
  if (byRole.wan3.length > 1)   { toast('Internet 3 can only use one port.', 'error'); return; }
  if (byRole.lan.length < 1)    { toast('Pick at least one port for Home devices, or you will lose access.', 'error'); return; }

  var btn = $('#ez-ports-save');
  btn.disabled = true; btn.textContent = 'Saving…';
  api('/ports/assign', { method: 'POST', body: {
    wan1: byRole.wan1[0] || '',
    wan2: byRole.wan2[0] || '',
    wan3: byRole.wan3[0] || '',
    lan: byRole.lan.join(' ')
  }}).then(function (j) {
    toast(j.message || 'Saved.');
  }).catch(function (e) {
    toast(e.message, 'error');
  }).finally(function () {
    btn.disabled = false; btn.textContent = 'Save port setup';
  });
});

/* ======================= wi-fi ======================= */

var wifiIds = []; /* the wifi-iface ids sharing the main SSID (2.4GHz + 5GHz) */
var wifiHidden = false;
var radioIds = []; /* the wifi-device ids (radio0, radio1) — toggled together for on/off */

$('#ez-key-show').addEventListener('click', function () {
  var f = $('#ez-key');
  var show = f.type === 'password';
  f.type = show ? 'text' : 'password';
  this.textContent = show ? 'Hide' : 'Show';
});

$('#ez-hidden-toggle').addEventListener('click', function () {
  wifiHidden = !wifiHidden;
  this.classList.toggle('on', wifiHidden);
});

function loadWifi() {
  return api('/wifi').then(function (j) {
    var main = j.networks.filter(function (n) { return n.network === 'lan'; });
    wifiIds = main.map(function (n) { return n.id; });
    if (main.length) {
      $('#ez-ssid').value = main[0].ssid || '';
      wifiHidden = !!main[0].hidden;
      $('#ez-hidden-toggle').classList.toggle('on', wifiHidden);
    }
    /* Password is never sent back by the API (by design) — the field starts
       blank and is only sent on save if the user actually types something. */
    $('#ez-key').value = '';
    $('#ez-key').placeholder = 'Leave blank to keep the current password';

    radioIds = (j.radios || []).map(function (r) { return r.id; });
    // Wi-Fi is "on" if at least one radio is enabled — if either radio is
    // still broadcasting, the network is up from a user's point of view.
    var anyOn = (j.radios || []).some(function (r) { return !r.disabled; });
    $('#ez-wifi-onoff').classList.toggle('on', anyOn);
    // Editing SSID/password only makes sense with the radios on — hide that
    // part of the form rather than let you configure a network that isn't
    // broadcasting, which reads as "I saved it but nothing changed."
    $('#ez-wifi-fields').hidden = !anyOn;
  });
}

$('#ez-wifi-onoff').addEventListener('click', function () {
  var sw = this;
  var turnOn = !sw.classList.contains('on');
  sw.disabled = true;
  Promise.all(radioIds.map(function (id) {
    return api('/wifi/radio', { method: 'POST', body: { id: id, disabled: turnOn ? '0' : '1' } });
  })).then(function () {
    toast(turnOn ? 'Wi-Fi turned on.' : 'Wi-Fi turned off.', 'ok');
    sw.classList.toggle('on', turnOn);
    $('#ez-wifi-fields').hidden = !turnOn;
  }).catch(function (e) {
    toast(e.message, 'error');
  }).finally(function () {
    sw.disabled = false;
  });
});

$('#ez-wifi-save').addEventListener('click', function () {
  var ssid = $('#ez-ssid').value.trim();
  var key = $('#ez-key').value;
  if (!ssid) { toast('Network name cannot be empty.', 'error'); return; }
  if (key && key.length < 8) { toast('Password must be at least 8 characters.', 'error'); return; }
  if (!wifiIds.length) { toast('No Wi-Fi radio found on this router.', 'error'); return; }

  var btn = $('#ez-wifi-save');
  btn.disabled = true; btn.textContent = 'Saving…';

  var reqs = wifiIds.map(function (id) {
    var body = { id: id, ssid: ssid, hidden: wifiHidden ? '1' : '0' };
    if (key) body.key = key;
    return api('/wifi', { method: 'POST', body: body });
  });

  Promise.all(reqs).then(function () {
    toast('Wi-Fi settings saved. Devices may need to reconnect.');
    $('#ez-key').value = '';
  }).catch(function (e) {
    toast(e.message, 'error');
  }).finally(function () {
    btn.disabled = false; btn.textContent = 'Save Wi-Fi settings';
  });
});

/* ======================= boot ======================= */

function loadAll() {
  loadWans().catch(function (e) { toast(e.message, 'error'); });
  loadMwan().catch(function (e) { toast(e.message, 'error'); });
  loadPorts().catch(function (e) { toast(e.message, 'error'); });
  loadWifi().catch(function (e) { toast(e.message, 'error'); });
  loadAdblock().catch(function (e) { toast(e.message, 'error'); });
  checkUpdate().catch(function () {});
}

/* ======================= software update ======================= */
/* Checks this project's public GitHub repo for a newer version and, if
   found, can fetch + install it directly onto the router. See app.js for
   the identical Advanced-page version of this — same API, same flow. */

var updateLatest = null;

function checkUpdate() {
  return api('/update/check').then(function (j) {
    if (j.update_available) {
      updateLatest = j.latest;
      $('#ez-update-sub').textContent = 'Version ' + j.latest + ' is available (you have ' + j.current + ').';
      $('#ez-update-apply').hidden = false;
    } else {
      $('#ez-update-sub').textContent = 'Up to date (version ' + j.current + ').';
      $('#ez-update-apply').hidden = true;
    }
  }).catch(function (e) {
    $('#ez-update-sub').textContent = 'Could not check for updates: ' + e.message;
  });
}

$('#ez-update-check').addEventListener('click', function () {
  $('#ez-update-sub').textContent = 'Checking…';
  checkUpdate();
});

$('#ez-update-apply').addEventListener('click', function () {
  if (!window.confirm(
    'Install version ' + (updateLatest || '') + '?\n\n' +
    'This downloads the update, replaces the app\'s files, and restarts the admin service. ' +
    'It takes about 15-30 seconds; this page will briefly disconnect and then work again.'
  )) return;

  var btn = $('#ez-update-apply');
  btn.disabled = true;
  $('#ez-update-progress').hidden = false;
  $('#ez-update-progress').textContent = 'Starting…';

  api('/update/apply', { method: 'POST' }).then(function () {
    pollUpdate();
  }).catch(function (e) {
    toast(e.message, 'error');
    btn.disabled = false;
  });
});

function pollUpdate() {
  api('/update/status').then(function (j) {
    $('#ez-update-progress').textContent =
      j.status === 'running' ? 'Working: ' + j.step + '…' :
      j.status === 'error'   ? 'Failed: ' + j.step :
      j.status === 'done'    ? j.step : '';
    if (j.status === 'running') {
      setTimeout(pollUpdate, 1500);
    } else {
      $('#ez-update-apply').disabled = false;
      if (j.status === 'done') { toast('Update installed.', 'ok'); setTimeout(checkUpdate, 500); }
      if (j.status === 'error') toast(j.step, 'error');
    }
  }).catch(function () {
    // The service is restarting mid-poll — expected, just try again shortly.
    setTimeout(pollUpdate, 1500);
  });
}

/* ======================= ad blocking ======================= */

function loadAdblock() {
  return api('/adblock').then(function (j) {
    $('#ez-adblock-toggle').classList.toggle('on', j.enabled);
    $('#ez-adblock-desc').textContent = j.enabled
      ? j.blocked_domains + ' domains blocked'
      : 'Off';
  });
}

$('#ez-adblock-toggle').addEventListener('click', function () {
  var sw = this;
  var turnOn = !sw.classList.contains('on');
  sw.disabled = true;
  api('/adblock', { method: 'POST', body: { enabled: turnOn ? '1' : '0' } })
    .then(function (r) {
      toast(r.message, 'ok');
      setTimeout(loadAdblock, 1500);
    })
    .catch(function (e) { toast(e.message, 'error'); })
    .finally(function () { sw.disabled = false; });
});

/* A page reload has no in-memory session. On the router, the cookie is
   still valid server-side (HttpOnly, so we can't read it — we just try an
   authenticated call and let a 401 send us back to the login screen).
   Standalone, there is no cookie at all, so the token saved in this
   origin's own localStorage (if any) is attached before this first call. */
if (REMOTE) {
  try { session = localStorage.getItem('mw-remote-session') || null; } catch (e) {}
}
api('/status').then(function (j) {
  session = j.session;
  saveRemoteSession(session);
  showApp();
}).catch(function () {
  showLogin();
});

/* ======================= auto-reload on new deploy ======================= */
/* See app.js for the full story — an already-open tab never re-fetches this
   script on its own, so it can keep running old code long after a fix has
   been deployed. Polling this file's own Last-Modified header and reloading
   when it changes means you never have to remember to hard-refresh. */
(function watchForUpdates() {
  var known = null;
  function check() {
    fetch('simple.js', { method: 'HEAD', cache: 'no-store' }).then(function (r) {
      var lm = r.headers.get('Last-Modified');
      if (!lm) return;
      if (known === null) { known = lm; return; }
      if (lm === known) return;
      // Don't reload over an in-progress edit (typing a WiFi password, a
      // device rename) — wait for the next check instead.
      var el = document.activeElement;
      var busy = el && /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName);
      if (busy) return;
      location.reload();
    }).catch(function () {});
  }
  setInterval(check, 20000);
})();

})();
