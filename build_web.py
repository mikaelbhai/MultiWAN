"""Builds the baytaar.com copies of the router panel from the MultiWAN repo.

    python build_web.py

Reads MultiWAN/package/{www,remote-app}; writes webapp/{panel.html,easy.html,
app.js,simple.js,app.css,simple.css}. The hand-written files in webapp/
(index.html, portal-theme.css, api.php, portal.php, manifest.json, icon.svg)
are left alone.

Differences from the copy the router serves to its own LAN:
  * API calls go to api.php/r/<router id> on this site (HTTPS, same origin),
    which relays them down that router's tunnel.
  * Signing in is the website account, so the panel's own password screen is
    never shown: anything that would show it returns to the home page instead.
  * Baytaar look: dim light theme by default, line icons in the top bar.
"""
import os, re, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'MultiWAN', 'package')
OUT = os.path.join(HERE, 'webapp')


def load(p):
    return open(p, encoding='utf-8', newline='').read().replace('\r\n', '\n')


def save(p, s):
    open(p, 'w', encoding='utf-8', newline='\n').write(s)


def one(pattern, repl, s, what, flags=0):
    s2, n = re.subn(pattern, lambda m: repl, s, count=1, flags=flags)
    assert n == 1, what
    return s2


def lit(old, new, s, what):
    assert s.count(old) == 1, what
    return s.replace(old, new)


def svg(paths):
    return '<svg viewBox="0 0 24 24" aria-hidden="true">' + paths + '</svg>'


I_GRID = svg('<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/>'
             '<rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>')
I_ZAP = svg('<path d="M13 2 3 14h9l-1 8 10-12h-9l1-8z"/>')
I_THEME = svg('<circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 1 0 18z" fill="currentColor" stroke="none"/>')
I_OUT = svg('<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5"/><path d="M21 12H9"/>')

for f in ('app.css', 'simple.css'):
    shutil.copy(os.path.join(SRC, 'www', f), os.path.join(OUT, f))

# scripts: the password screen becomes "go back to the home page"
for f in ('app.js', 'simple.js'):
    s = load(os.path.join(SRC, 'www', f))
    s = lit('function showLogin() {\n',
            "function showLogin() {\n  if (window.MW_PORTAL) { location.href = './'; return; }\n", s, f)
    save(os.path.join(OUT, f), s)

BOOT = """<script>
  // Served from baytaar.com over HTTPS. Which router this panel talks to is
  // chosen on the home page; api.php relays every call down that router's own
  // outbound tunnel after checking the signed-in account is assigned to it.
  window.MW_PORTAL = true;
  (function () {
    var id = (new URLSearchParams(location.search).get('r') || '').replace(/\\D/g, '');
    try { if (id) localStorage.setItem('bt-router', id); else id = localStorage.getItem('bt-router') || ''; } catch (e) {}
    if (!id) { location.replace('./'); return; }
    window.MW_API_BASE = 'api.php/r/' + id;
  })();
</script>"""

VIEWPORT = '<meta name="viewport" content="width=device-width, initial-scale=1">'

for src, dst in (('easy.html', 'easy.html'),):
    s = load(os.path.join(SRC, 'remote-app', src))
    s = one(r"<script>\s*//.*?window\.MW_API_BASE = '[^']*';\s*</script>", BOOT, s, src + ' base', re.S)
    s = one(r'<div id="https-notice".*?<script>\s*if \(location\.protocol === .https:.\).*?</script>\s*',
            '', s, src + ' https notice', re.S)
    s = one(r"<script>document\.getElementById\('target-addr'\)\.textContent = [^<]*</script>", '', s, src + ' target')
    s = lit(VIEWPORT, VIEWPORT + '\n<meta name="theme-color" content="#e8ebf0">\n<link rel="manifest" href="manifest.json">',
            s, src + ' viewport')

    # Baytaar look: dim light by default; the panel's dark theme stays one click away.
    s = lit('<html lang="en" data-theme="dark">', '<html lang="en" data-theme="light">', s, src + ' theme')
    s = lit('</head>', '<link rel="stylesheet" href="portal-theme.css">\n</head>', s, src + ' css')
    s = s.replace('MultiWAN', 'Baytaar')

    # navigation between the three pages
    s = s.replace('href="index.html"', 'href="panel.html"')
    if dst == 'panel.html':
        s = lit('<a class="btn btn-ghost btn-sm" href="easy.html">Easy setup</a>',
                '<a class="btn btn-ghost btn-sm" href="./" title="All routers">' + I_GRID + '<span class="lbl">All routers</span></a>\n'
                '      <a class="btn btn-ghost btn-sm" href="easy.html" title="Easy setup">' + I_ZAP + '<span class="lbl">Easy setup</span></a>',
                s, 'nav')
        s = lit('<button class="btn btn-ghost btn-sm" id="theme-toggle" title="Toggle theme">&#9680;</button>',
                '<button class="btn btn-ghost btn-sm" id="theme-toggle" title="Light / dark">' + I_THEME + '</button>', s, 'theme icon')
        s = lit('<button class="btn btn-ghost btn-sm" id="logout-btn">Sign out</button>',
                '<button class="btn btn-ghost btn-sm" id="logout-btn" title="Sign out">' + I_OUT + '<span class="lbl">Sign out</span></button>',
                s, 'logout icon')
    else:
        s = lit('<a href="panel.html">Advanced settings &rarr;</a>',
                '<a href="./">&larr; All routers</a> &nbsp;&middot;&nbsp; <a href="panel.html">Advanced settings &rarr;</a>', s, 'easy nav')
    save(os.path.join(OUT, dst), s)
    print('built', dst)

# The full panel is the router's own one-page admin (package/www/index.html),
# dressed in the Baytaar look and pointed at this site's relay.
s = load(os.path.join(SRC, 'www', 'index.html'))
s = lit('<script src="app.js"></script>', BOOT + '\n<script src="app.js"></script>', s, 'panel boot')
s = lit(VIEWPORT, VIEWPORT + '\n<meta name="theme-color" content="#e8ebf0">\n<link rel="manifest" href="manifest.json">', s, 'panel viewport')
s = lit('<html lang="en" data-theme="dark">', '<html lang="en" data-theme="light">', s, 'panel theme')
s = lit('</head>', '<link rel="stylesheet" href="portal-theme.css">\n</head>', s, 'panel css')
s = lit('<button class="btn btn-ghost btn-sm" id="theme-toggle" title="Light / dark">&#9680;</button>',
        '<a class="btn btn-ghost btn-sm" href="./" title="All routers">' + I_GRID + '<span class="lbl">All routers</span></a>\n'
        '      <button class="btn btn-ghost btn-sm" id="theme-toggle" title="Light / dark">' + I_THEME + '</button>', s, 'panel nav')
s = lit('<button class="btn btn-ghost btn-sm" id="logout-btn">Sign out</button>',
        '<button class="btn btn-ghost btn-sm" id="logout-btn" title="Sign out">' + I_OUT + '<span class="lbl">Sign out</span></button>',
        s, 'panel logout')
save(os.path.join(OUT, 'panel.html'), s)
print('built panel.html')
print('done')


# ---- keep phones and browsers on the newest copy ----------------------------
# This host can't send "check for updates" headers (its server ignores them in
# .htaccess), so: every page checks itself once and reloads if the server has
# a newer copy, and local scripts/styles carry ?v=<content hash> so a changed
# file is always fetched fresh. Runs over every page in webapp/, idempotent.
import hashlib, glob
FRESH = ('<!--bt-fresh--><script>(function(){try{if(!window.fetch)return;'
         'var here=Date.parse(document.lastModified)||0;'
         'fetch(location.pathname+location.search,{cache:"no-cache",credentials:"same-origin"}).then(function(r){'
         'var lm=Date.parse(r.headers.get("Last-Modified")||"")||0;'
         'if(!here||!lm||lm<=here+1000)return;'
         'var k="bt-upd:"+location.pathname;if(sessionStorage.getItem(k)===String(lm))return;'
         'sessionStorage.setItem(k,String(lm));location.reload();});}catch(e){}})();</script><!--/bt-fresh-->')
for page in sorted(glob.glob(os.path.join(OUT, '*.html'))):
    s = load(page)
    s = re.sub(r'<!--bt-fresh-->.*?<!--/bt-fresh-->\n?', '', s, flags=re.S)
    s = lit('<meta charset="utf-8">', '<meta charset="utf-8">\n' + FRESH, s, 'fresh ' + page)
    def stamp(m):
        f = os.path.join(OUT, m.group(2))
        if not os.path.isfile(f):
            return m.group(0)
        v = hashlib.md5(open(f, 'rb').read()).hexdigest()[:10]
        return m.group(1) + m.group(2) + '?v=' + v + '"'
    s = re.sub(r'((?:href|src)=")([A-Za-z0-9_-]+\.(?:css|js))(?:\?v=[0-9a-f]+)?"', stamp, s)
    save(page, s)
    print('fresh-checked', os.path.basename(page))
