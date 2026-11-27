"""Fill openwrt/baytaar-multiwan/files/ (the package's root file tree) from the bundle build_fw.py made (fw/baytaar-fw.tar.gz),
placing every file where the bundle's files.txt says, plus the stage scripts and the setup wizard for first-time setup."""
import io, os, shutil, stat, sys, tarfile
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(HERE, "baytaar-multiwan", "files")
shutil.rmtree(OUT, ignore_errors=True)
tf = tarfile.open(os.path.join(ROOT, "fw", "baytaar-fw.tar.gz"))
members = {m.name.lstrip("./"): m for m in tf.getmembers() if m.isfile()}
listing = tf.extractfile(members["files.txt"]).read().decode().splitlines()
n = 0
for line in listing:
    if not line.strip(): continue
    src, dst, mode = line.split("|")
    data = tf.extractfile(members[src.lstrip("./")]).read()
    out = os.path.join(OUT, dst.lstrip("/"))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "wb").write(data)
    os.chmod(out, int(mode, 8) if not mode.startswith("0o") else int(mode[2:], 8))
    n += 1
# first-time setup on a plain OpenWrt: the stage scripts, their settings template, and the wizard
cfg = os.path.join(OUT, "usr", "share", "baytaar", "config"); os.makedirs(cfg, exist_ok=True)
for f in sorted(os.listdir(os.path.join(ROOT, "MultiWAN", "config"))):
    if (f.endswith(".sh") and f != "install.sh") or f == "mwan.env.example":
        d = open(os.path.join(ROOT, "MultiWAN", "config", f), "rb").read().replace(b"\r\n", b"\n")
        open(os.path.join(cfg, f), "wb").write(d); n += 1
sbin = os.path.join(OUT, "usr", "sbin"); os.makedirs(sbin, exist_ok=True)
open(os.path.join(sbin, "baytaar-setup"), "w", newline="\n").write("#!/bin/sh\nexec sh /usr/lib/mwadmin/baytaar-setup.sh \"$@\"\n")
os.chmod(os.path.join(sbin, "baytaar-setup"), 0o755)
print("staged", n + 1, "files into", OUT)
