"""Build BaytaarInstaller.exe (one file, no console) with PyInstaller.
Ships: the router-side runner and the stage scripts from MultiWAN/config (with mwan.env.example, never a real mwan.env)."""
import os, shutil, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CFG = os.path.join(ROOT, "MultiWAN", "config")
STAGE = os.path.join(HERE, "build", "data")
shutil.rmtree(os.path.join(HERE, "build"), ignore_errors=True)
os.makedirs(os.path.join(STAGE, "config"))
for f in sorted(os.listdir(CFG)):
    if (f.endswith(".sh") and f != "install.sh") or f == "mwan.env.example":
        shutil.copy(os.path.join(CFG, f), os.path.join(STAGE, "config", f))
shutil.copy(os.path.join(HERE, "router_runner.sh"), STAGE)
sep = ";"
cmd = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--onefile", "--windowed", "--name", "BaytaarInstaller",
       "--distpath", os.path.join(HERE, "dist"), "--workpath", os.path.join(HERE, "build", "work"), "--specpath", os.path.join(HERE, "build"),
       "--add-data", os.path.join(STAGE, "config") + sep + "config",
       "--add-data", os.path.join(STAGE, "router_runner.sh") + sep + ".",
       os.path.join(HERE, "baytaar_installer.py")]
print(" ".join(cmd[:6]), "...")
subprocess.run(cmd, check=True)
exe = os.path.join(HERE, "dist", "BaytaarInstaller.exe")
print("built:", exe, os.path.getsize(exe), "bytes")
