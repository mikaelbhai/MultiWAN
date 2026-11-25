"""Build the router software bundle that the "Upgrade" button installs.

    python build_fw.py ["what changed"]

Writes fw/baytaar-fw.tar.gz and fw/version.json. Upload both to the website's
/fw/ folder; routers then show "Upgrade available".
"""
import hashlib, io, json, os, sys, tarfile, time

ROOT = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.join(ROOT, 'MultiWAN', 'package')
OUT = os.path.join(ROOT, 'fw')

# source (under MultiWAN/package) -> place on the router, mode
FILES = [
    # The whole admin panel is ONE file on the router: index.html with the
    # stylesheet and script inlined and comments stripped (see one_page()).
    ('www/index.html', '/www/mwadmin/index.html', 0o644),
    ('www/advanced.html', '/www/mwadmin/advanced.html', 0o644),
    ('cgi-bin/mwadmin', '/www/mwadmin/cgi-bin/mwadmin', 0o755),
    ('www-guest/cgi-bin/guest', '/www/mwguest/cgi-bin/guest', 0o755),
    ('init.d/mwadmin', '/etc/init.d/mwadmin', 0o755),
    ('init.d/mwremote', '/etc/init.d/mwremote', 0o755),
    ('init.d/mwsite', '/etc/init.d/mwsite', 0o755),
    ('init.d/mwblock', '/etc/init.d/mwblock', 0o755),
    ('init.d/mwevents', '/etc/init.d/mwevents', 0o755),
    ('init.d/mwrelay', '/etc/init.d/mwrelay', 0o755),
    ('init.d/mwexempt', '/etc/init.d/mwexempt', 0o755),
    ('init.d/mwdrive', '/etc/init.d/mwdrive', 0o755),
    # a USB drive plugged in or pulled out: mount it, update the shares
    ('hotplug/30-mwdrive', '/etc/hotplug.d/block/30-mwdrive', 0o644),
    # tests a line when its cable is plugged in (fills provider / public IP / location)
    ('hotplug/95-mwadmin-portdetect', '/etc/hotplug.d/iface/95-mwadmin-portdetect', 0o644),
    # line up/down: outage alerts and the line history
    ('etc/mwan3.user', '/etc/mwan3.user', 0o755),
    ('etc/le-intermediates.pem', '/usr/lib/mwadmin/le-intermediates.pem', 0o644),
]
for f in sorted(os.listdir(os.path.join(PKG, 'lib'))):
    if f.endswith('.sh'):
        FILES.append(('lib/' + f, '/usr/lib/mwadmin/' + f, 0o755))

APPLY = r'''#!/bin/sh
# apply.sh — put the unpacked Baytaar software in place. Run from the unpack
# directory as: sh ./apply.sh <version>.  Safe to run again.
set -e
VER="$1"
[ -n "$VER" ] || { echo "usage: apply.sh <version>"; exit 1; }

# 1. every file must parse before anything is replaced
while IFS='|' read -r src dst mode; do
    [ -f "$src" ] || { echo "missing $src"; exit 1; }
    case "$dst" in *.sh|*/cgi-bin/*|/etc/init.d/*) sh -n "$src" || { echo "bad script $src"; exit 1; } ;; esac
done < files.txt

# 2. copy, each file swapped in whole
while IFS='|' read -r src dst mode; do
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst.new"
    chmod "$mode" "$dst.new"
    mv "$dst.new" "$dst"
done < files.txt
mkdir -p /etc/mwadmin
set +e

# pages and scripts from older versions; the panel is now index.html alone
rm -f /www/mwadmin/app.js /www/mwadmin/app.css /www/mwadmin/simple.js /www/mwadmin/simple.css /www/mwadmin/easy.html /www/mwadmin/setup.html

# 3. the sign-in / block page listens on its own port
if [ "$(uci -q get uhttpd.mwguest)" != "uhttpd" ] || [ "$(uci -q get uhttpd.mwguest.index_page)" != "cgi-bin/guest" ]; then
    uci set uhttpd.mwguest=uhttpd
    uci set uhttpd.mwguest.home=/www/mwguest
    uci set uhttpd.mwguest.cgi_prefix=/cgi-bin
    uci set uhttpd.mwguest.error_page=/cgi-bin/guest
    uci set uhttpd.mwguest.no_dirlists=1
    uci set uhttpd.mwguest.max_requests=8
    uci set uhttpd.mwguest.script_timeout=20
    uci -q delete uhttpd.mwguest.index_page
    uci add_list uhttpd.mwguest.index_page=cgi-bin/guest
    uci -q delete uhttpd.mwguest.listen_http
    uci add_list uhttpd.mwguest.listen_http=0.0.0.0:8188
    uci add_list uhttpd.mwguest.listen_http='[::]:8188'
    uci commit uhttpd
    /etc/init.d/uhttpd restart >/dev/null 2>&1
fi

# 4. the token the management website presents instead of the router password
[ -s /etc/mwadmin/portal_token ] || { head -c 32 /dev/urandom | hexdump -ve '1/1 "%02x"' > /etc/mwadmin/portal_token; chmod 600 /etc/mwadmin/portal_token; }

# 5. helpers the features need (only fetched when missing)
command -v conntrack >/dev/null 2>&1 || { apk add conntrack >/dev/null 2>&1 || true; }

# the website tunnel uses Dropbear's client; convert an OpenSSH-format key
# once (same key, so the website's access list does not change)
if [ -f /etc/mwadmin/remote_id_ed25519 ] && [ ! -s /etc/mwadmin/remote_id_dropbear ]; then
    had=0; command -v dropbearconvert >/dev/null 2>&1 && had=1
    [ $had -eq 1 ] || apk add dropbearconvert >/dev/null 2>&1
    dropbearconvert openssh dropbear /etc/mwadmin/remote_id_ed25519 /etc/mwadmin/remote_id_dropbear >/dev/null 2>&1 && chmod 600 /etc/mwadmin/remote_id_dropbear
    [ $had -eq 1 ] || apk del dropbearconvert >/dev/null 2>&1
    [ "$(uci -q get mwadmin.remote.enabled)" = "1" ] && /etc/init.d/mwremote restart >/dev/null 2>&1
fi

# 6. background services
/etc/init.d/mwsite enable >/dev/null 2>&1
/etc/init.d/mwblock enable >/dev/null 2>&1
/etc/init.d/mwsite restart >/dev/null 2>&1
/etc/init.d/mwblock restart >/dev/null 2>&1
/etc/init.d/mwevents enable >/dev/null 2>&1
/etc/init.d/mwevents restart >/dev/null 2>&1
# the "this site is blocked" page gets its own LAN address (.253), separate
# from the admin panel's .254 alias, so http://multiwan.router keeps working
if [ -z "$(uci -q get network.lan_block)" ]; then
    lanip=$(uci -q get network.lan.ipaddr | cut -d/ -f1)
    if [ -n "$lanip" ]; then
        uci set network.lan_block=interface
        uci set network.lan_block.device=br-lan
        uci set network.lan_block.proto=static
        uci set network.lan_block.ipaddr="${lanip%.*}.253"
        uci set network.lan_block.netmask=255.255.255.255
        uci commit network
        /etc/init.d/network reload >/dev/null 2>&1
        sleep 3
        sh -c '. /usr/lib/mwadmin/common.sh; . /usr/lib/mwadmin/block.sh; block_apply' >/dev/null 2>&1
    fi
fi

# routes on an unplugged port (a static WAN with no cable) must not be used,
# or the router's own traffic leaves with that port's address and is dropped
printf 'net.ipv4.conf.all.ignore_routes_with_linkdown=1
net.ipv4.conf.default.ignore_routes_with_linkdown=1
' > /etc/sysctl.d/90-mwadmin-linkdown.conf
sysctl -p /etc/sysctl.d/90-mwadmin-linkdown.conf >/dev/null 2>&1
/etc/init.d/mwrelay enable >/dev/null 2>&1
[ "$(uci -q get mwadmin.remote.enabled)" = "1" ] && /etc/init.d/mwremote restart >/dev/null 2>&1
echo 'net.core.rmem_max=524288' > /etc/sysctl.d/91-mwadmin-nlbwmon.conf
sysctl -p /etc/sysctl.d/91-mwadmin-nlbwmon.conf >/dev/null 2>&1
/etc/init.d/mwexempt enable >/dev/null 2>&1
/etc/init.d/mwexempt restart >/dev/null 2>&1
# shared USB drives (only does anything once drive support is installed)
/etc/init.d/mwdrive enable >/dev/null 2>&1
[ -x /usr/sbin/ksmbd.mountd ] && sh /usr/lib/mwadmin/drive.sh boot >/dev/null 2>&1
# the short-lived site whitelist is gone; never-blocked devices replace it
rm -f /etc/mwadmin/allowed_sites
[ -f /etc/adblock/adblock.allowlist ] && sed -i '/^# mwadmin-allowed$/,$d' /etc/adblock/adblock.allowlist
/etc/init.d/mwrelay restart >/dev/null 2>&1
sh /usr/lib/mwadmin/guest.sh tick >/dev/null 2>&1
# 18+ filter for every device (on unless turned off); the old adblock-feed
# version of it never applied to never-blocked devices
uci -q del_list adblock.global.adb_feed='oisd_nsfw_small' && uci commit adblock
sh /usr/lib/mwadmin/adult.sh apply >/dev/null 2>&1
# free time / break time (pause.sh): defaults 60 min a day, break 13:00-14:00;
# reload the blocker so its table has the "free" set
sh -c '. /usr/lib/mwadmin/block.sh; pause_ensure; pause_portal; block_apply; pause_tick' >/dev/null 2>&1

# the website certificate bundle is rebuilt from le-intermediates.pem on next use
rm -f /tmp/mwadmin-cabundle.pem

echo "$VER" > /etc/mwadmin/fw_version
echo "applied $VER"
'''



def slim(text, kind):
    """Drop whole-line comments, blank lines and indentation. Line-level only,
    so code is never cut in the middle of a line; a block comment that does
    not end its line is an error instead of a guess."""
    out, inblock = [], False
    for line in text.replace('\r\n', '\n').split('\n'):
        t = line.strip()
        if inblock:
            if '*/' in t:
                assert t.endswith('*/'), 'code after */ in: ' + t
                inblock = False
            continue
        if kind in ('js', 'css') and t.startswith('/*'):
            if not t.endswith('*/'):
                inblock = True
            continue
        if kind == 'js' and t.startswith('//'):
            continue
        if kind == 'html' and t.startswith('<!--') and t.endswith('-->'):
            continue
        if t:
            out.append(t)
    return '\n'.join(out) + '\n'


def one_page():
    www = os.path.join(PKG, 'www')
    rd = lambda f: open(os.path.join(www, f), encoding='utf-8').read()
    css, js, html = slim(rd('app.css'), 'css'), slim(rd('app.js'), 'js'), slim(rd('index.html'), 'html')
    assert '</script' not in js and '</style' not in css
    try:
        import subprocess, tempfile
        with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False, encoding='utf-8') as t:
            t.write(js)
        subprocess.run(['node', '--check', t.name], check=True)
        os.unlink(t.name)
    except FileNotFoundError:
        print('node not found; slimmed script not syntax-checked')
    link, tag = '<link rel="stylesheet" href="app.css">', '<script src="app.js"></script>'
    assert html.count(link) == 1 and html.count(tag) == 1
    html = html.replace(link, '<style>\n' + css + '</style>').replace(tag, '<script>\n' + js + '</script>')
    return {
        'www/index.html': html.encode('utf-8'),
        'www/advanced.html': b'<!DOCTYPE html><meta http-equiv="refresh" content="0;url=./"><a href="./">Open the admin panel</a>\n',
    }


def add(tar, name, data, mode=0o644):
    ti = tarfile.TarInfo(name)
    ti.size = len(data); ti.mode = mode; ti.mtime = int(time.time())
    tar.addfile(ti, io.BytesIO(data))


def main():
    notes = sys.argv[1] if len(sys.argv) > 1 else ''
    base = open(os.path.join(ROOT, 'MultiWAN', 'VERSION')).read().strip()
    version = base + '.' + time.strftime('%Y%m%d%H%M')
    os.makedirs(OUT, exist_ok=True)
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz') as tar:
        lines = []
        gen = one_page()
        for src, dst, mode in FILES:
            data = gen.get(src) or open(os.path.join(PKG, *src.split('/')), 'rb').read().replace(b'\r\n', b'\n')
            add(tar, src, data, mode)
            lines.append('%s|%s|%o' % (src, dst, mode))
        add(tar, 'files.txt', ('\n'.join(lines) + '\n').encode())
        add(tar, 'apply.sh', APPLY.replace('\r\n', '\n').encode(), 0o755)
    blob = buf.getvalue()
    open(os.path.join(OUT, 'baytaar-fw.tar.gz'), 'wb').write(blob)
    info = {'version': version, 'sha256': hashlib.sha256(blob).hexdigest(), 'size': len(blob), 'built': int(time.time()), 'notes': notes}
    open(os.path.join(OUT, 'version.json'), 'w', newline='\n').write(json.dumps(info) + '\n')
    print(version, len(blob), 'bytes')


main()
