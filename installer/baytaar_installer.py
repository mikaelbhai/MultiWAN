"""Baytaar Router Installer (Windows).

Steps: 1 website account (address + API key, checked on the website), 2 router model, 3 OpenWrt (the recommended
version for that model, downloaded from openwrt.org and checked against OpenWrt's own checksum), 4 put OpenWrt on the
router (guided), 5 the essential settings, 6 install the Baytaar software (MultiWAN) and join the website, 7 done.

Talks to the router through OpenWrt's own web interface (/ubus JSON-RPC on port 80, the same one LuCI uses): log in,
write files, run commands. Needs nothing installed on the PC. Python standard library only.
"""
import base64, hashlib, json, os, queue, re, shlex, socket, subprocess, sys, threading, time, urllib.request, webbrowser
import tkinter as tk
from tkinter import ttk, messagebox

APP = "Baytaar Router Installer"
VERSION = "1.0.0"
DEFAULT_SITE = "mikaelbhai.com"
OPENWRT_IP = "192.168.1.1"                   # every freshly installed OpenWrt answers here
FALLBACK_OPENWRT = "25.12.6"                 # used when the website does not say which version to use
UA = {"User-Agent": "BaytaarInstaller/" + VERSION}

def res(rel):
    """A file shipped inside the .exe (PyInstaller) or next to this script."""
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, rel)

MODELS = [
    {"id": "linksys_ea8100-v1", "title": "Linksys EA8100 (version 1)", "board": "linksys,ea8100-v1", "target": "ramips/mt7621",
     "stock": "linksys", "usb": True, "status": "Tested: Router 1 and Router 2 are this model.",
     "label": "The sticker under the router says EA8100 and does not say v2."},
    {"id": "linksys_ea8100-v2", "title": "Linksys EA8100 (version 2)", "board": "linksys,ea8100-v2", "target": "ramips/mt7621",
     "stock": "linksys", "usb": True, "status": "Should work; not tested on this hardware version yet.",
     "label": "The sticker under the router says EA8100 v2."},
    {"id": "tplink_archer-c6-v3", "title": "TP-Link Archer C6 (version 3)", "board": "tplink,archer-c6-v3", "target": "ramips/mt7621",
     "stock": "tplink", "usb": False, "status": "The project's first router. Small storage (16 MB); this OpenWrt version is not tested on it yet.",
     "label": "The sticker says Archer C6 and Ver: 3.x (not V2, not V4)."},
]

FLASH_STEPS = {
    "linksys": [
        "Connect this PC to one of the router's LAN ports (not the internet port) with a network cable. Turn off this PC's Wi-Fi.",
        "Open the Linksys page: http://192.168.1.1 . Sign in (the default password is admin, or the one you set).",
        "Go to Connectivity, then Router Firmware Update, then Manual. Choose the file shown below and press Start.",
        "Accept the warnings. Do not unplug the router. After about 5 minutes the light stops blinking and the router restarts with OpenWrt.",
    ],
    "tplink": [
        "Connect this PC to one of the router's LAN ports (not the internet port) with a network cable. Turn off this PC's Wi-Fi.",
        "Open the TP-Link page: http://tplinkwifi.net (or http://192.168.0.1) and sign in.",
        "Go to Advanced, then System Tools, then Firmware Upgrade. Browse to the file shown below and press Upgrade.",
        "Do not unplug the router. After about 3 minutes it restarts with OpenWrt.",
    ],
    "openwrt": [
        "Connect this PC to one of the router's LAN ports with a network cable. Turn off this PC's Wi-Fi.",
        "Open http://192.168.1.1 (LuCI) and sign in.",
        "Go to System, then Backup / Flash Firmware, then Flash image. Choose the file shown below. UNTICK 'Keep settings' and press Continue.",
        "Do not unplug the router. After about 3 minutes it restarts with a clean OpenWrt.",
    ],
}

# ---------------------------------------------------------------------------------------------------------------------
def http_json(url, body=None, timeout=25):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=dict(UA, **({"Content-Type": "application/json"} if data else {})))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b"{}")
        except Exception: return e.code, {}

def download(url, dest, sha256, progress=None, timeout=60):
    """Download to dest and refuse it unless its sha256 matches. Returns dest."""
    tmp = dest + ".part"
    h = hashlib.sha256(); got = 0
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r, open(tmp, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        while True:
            b = r.read(65536)
            if not b: break
            f.write(b); h.update(b); got += len(b)
            if progress and total: progress(got / total)
    if h.hexdigest().lower() != sha256.lower():
        os.remove(tmp)
        raise RuntimeError("The download did not match its published checksum, so it was thrown away. Try again.")
    os.replace(tmp, dest)
    return dest

def sh_q(v):
    """A value for a shell file that is sourced: single-quoted, so nothing in it is ever run."""
    return "'" + str(v).replace("'", "'\\''") + "'"

class Ubus:
    """OpenWrt's web JSON-RPC (/ubus): the same interface LuCI uses."""
    def __init__(self, host):
        self.host, self.sid, self.n = host, "00000000000000000000000000000000", 0
    def _rpc(self, method, params, timeout=30):
        self.n += 1
        body = {"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}
        st, j = http_json("http://%s/ubus" % self.host, body, timeout)
        if st != 200: raise RuntimeError("the router answered HTTP %s" % st)
        if "error" in j: raise RuntimeError(j["error"].get("message", "error"))
        r = j.get("result") or [None]
        if r[0] != 0: raise PermissionError("ubus status %s" % r[0])
        return r[1] if len(r) > 1 else {}
    def login(self, password):
        r = self._rpc("call", [self.sid, "session", "login", {"username": "root", "password": password}])
        self.sid = r["ubus_rpc_session"]
    def call(self, obj, method, args=None, timeout=60):
        return self._rpc("call", [self.sid, obj, method, args or {}], timeout)
    def run(self, cmd, timeout=120):
        r = self.call("file", "exec", {"command": "/bin/sh", "params": ["-c", cmd]}, timeout)
        return r.get("code", 0), r.get("stdout", ""), r.get("stderr", "")
    def write(self, path, data):
        chunk = 24000
        for i in range(0, max(1, len(data)), chunk):
            self.call("file", "write", {"path": path, "data": base64.b64encode(data[i:i + chunk]).decode(), "base64": True,
                                        "append": i > 0, "mode": 0o600})
    def read(self, path):
        try: return self.call("file", "read", {"path": path}).get("data", "")
        except Exception: return ""

def port_open(host, port, t=2.0):
    try:
        with socket.create_connection((host, port), t): return True
    except OSError: return False

# ---------------------------------------------------------------------------------------------------------------------
class App(tk.Tk):
    STEPS = ["Your website account", "Router model", "OpenWrt", "Put OpenWrt on the router", "Settings", "Install", "Done"]

    def __init__(self):
        super().__init__()
        self.title(APP); self.geometry("900x640"); self.minsize(820, 600)
        self.configure(bg="#eef1f6")
        self.q = queue.Queue()
        self.state_ = {"site": DEFAULT_SITE, "key": "", "account": "", "model": None, "ow_ver": "", "image": "", "image_kind": "",
                       "router_pw_old": "", "ubus": None, "fw": None}
        self.dl_dir = os.path.join(os.path.expanduser("~"), "Downloads", "Baytaar Installer")
        os.makedirs(self.dl_dir, exist_ok=True)
        self._style()
        side = tk.Frame(self, bg="#0f172a", width=230); side.pack(side="left", fill="y"); side.pack_propagate(False)
        tk.Label(side, text="Baytaar", fg="white", bg="#0f172a", font=("Segoe UI Semibold", 18)).pack(anchor="w", padx=20, pady=(22, 0))
        tk.Label(side, text="Router installer " + VERSION, fg="#94a3b8", bg="#0f172a", font=("Segoe UI", 9)).pack(anchor="w", padx=20, pady=(0, 20))
        self.step_lbls = []
        for i, s in enumerate(self.STEPS):
            l = tk.Label(side, text="%d  %s" % (i + 1, s), fg="#94a3b8", bg="#0f172a", font=("Segoe UI", 10), anchor="w")
            l.pack(fill="x", padx=20, pady=5); self.step_lbls.append(l)
        main = tk.Frame(self, bg="#eef1f6"); main.pack(side="left", fill="both", expand=True)
        self.body = tk.Frame(main, bg="white", highlightthickness=1, highlightbackground="#d7dce5")
        self.body.pack(fill="both", expand=True, padx=22, pady=(22, 10))
        nav = tk.Frame(main, bg="#eef1f6"); nav.pack(fill="x", padx=22, pady=(0, 18))
        self.back_b = ttk.Button(nav, text="Back", command=self.back); self.back_b.pack(side="left")
        self.next_b = ttk.Button(nav, text="Next", style="Primary.TButton", command=self.next); self.next_b.pack(side="right")
        self.page = 0
        self.after(100, self._pump)
        self.show(0)

    def _style(self):
        s = ttk.Style(self)
        try: s.theme_use("vista")
        except tk.TclError: pass
        s.configure("TLabel", font=("Segoe UI", 10), background="white")
        s.configure("H.TLabel", font=("Segoe UI Semibold", 16), background="white")
        s.configure("Sub.TLabel", font=("Segoe UI", 10), foreground="#475569", background="white")
        s.configure("Bad.TLabel", font=("Segoe UI", 10), foreground="#b91c1c", background="white")
        s.configure("Ok.TLabel", font=("Segoe UI", 10), foreground="#047857", background="white")
        s.configure("TRadiobutton", background="white", font=("Segoe UI", 10))
        s.configure("TCheckbutton", background="white", font=("Segoe UI", 10))
        s.configure("Primary.TButton", font=("Segoe UI Semibold", 10))

    # ---- plumbing -----------------------------------------------------------------------------------------------
    def _pump(self):
        try:
            while True:
                fn = self.q.get_nowait(); fn()
        except queue.Empty: pass
        self.after(100, self._pump)
    def ui(self, fn): self.q.put(fn)
    def bg(self, fn): threading.Thread(target=fn, daemon=True).start()

    def clear(self):
        for w in self.body.winfo_children(): w.destroy()
        f = tk.Frame(self.body, bg="white"); f.pack(fill="both", expand=True, padx=26, pady=22)
        return f

    def head(self, f, title, sub=None):
        ttk.Label(f, text=title, style="H.TLabel").pack(anchor="w")
        if sub: ttk.Label(f, text=sub, style="Sub.TLabel", wraplength=540, justify="left").pack(anchor="w", pady=(4, 14))

    def field(self, f, label, var, show=None, width=44):
        r = tk.Frame(f, bg="white"); r.pack(anchor="w", fill="x", pady=4)
        ttk.Label(r, text=label, width=24).pack(side="left")
        e = ttk.Entry(r, textvariable=var, width=width, show=show or ""); e.pack(side="left")
        return e

    def show(self, i):
        self.page = i
        for n, l in enumerate(self.step_lbls):
            l.configure(fg="white" if n == i else ("#64748b" if n > i else "#94a3b8"),
                        font=("Segoe UI Semibold", 10) if n == i else ("Segoe UI", 10))
        self.back_b.configure(state="normal" if 0 < i < 5 else "disabled")
        self.next_b.configure(text="Next", state="normal")
        [self.p_account, self.p_model, self.p_openwrt, self.p_flash, self.p_settings, self.p_install, self.p_done][i]()

    def back(self): self.show(self.page - 1)
    def next(self): getattr(self, "n%d" % self.page)()

    # ---- 1 account -----------------------------------------------------------------------------------------------
    def p_account(self):
        f = self.clear()
        self.head(f, "Your website account", "The router joins your account on the website when it is installed. Sign in on the website, "
                  "press Add a router, and copy the website address and the API key here. You can also skip this and connect the router later.")
        self.v_site = tk.StringVar(value=self.state_["site"]); self.v_key = tk.StringVar(value=self.state_["key"])
        self.field(f, "Website address", self.v_site); self.field(f, "API key", self.v_key, width=50)
        self.v_skip = tk.BooleanVar(value=False)
        ttk.Checkbutton(f, text="Skip: install without joining a website", variable=self.v_skip).pack(anchor="w", pady=(10, 0))
        self.acc_msg = ttk.Label(f, text="", style="Sub.TLabel", wraplength=540); self.acc_msg.pack(anchor="w", pady=12)

    def n0(self):
        if self.v_skip.get():
            self.state_.update(site="", key="", account=""); return self.show(1)
        site = self.v_site.get().strip().replace("https://", "").replace("http://", "").strip("/")
        key = self.v_key.get().strip()
        if not site or not key: return self.acc_msg.configure(text="Enter both, or tick Skip.", style="Bad.TLabel")
        self.next_b.configure(state="disabled"); self.acc_msg.configure(text="Checking the key on the website...", style="Sub.TLabel")
        def work():
            try:
                st, j = http_json("https://%s/router/enroll.php" % site, {"key": key, "check": True})
                if st == 404: st, j = http_json("https://%s/enroll.php" % site, {"key": key, "check": True})
                if st == 200 and j.get("valid"):
                    self.state_.update(site=site, key=key, account=j.get("account", ""))
                    self.ui(lambda: (self.acc_msg.configure(text="Key accepted: account %s." % j.get("account", ""), style="Ok.TLabel"), self.after(700, lambda: self.show(1))))
                else:
                    msg = j.get("error") or "The website did not accept the key (HTTP %s)." % st
                    self.ui(lambda: (self.acc_msg.configure(text=msg, style="Bad.TLabel"), self.next_b.configure(state="normal")))
            except Exception as e:
                self.ui(lambda: (self.acc_msg.configure(text="Could not reach %s: %s" % (site, e), style="Bad.TLabel"), self.next_b.configure(state="normal")))
        self.bg(work)

    # ---- 2 model -------------------------------------------------------------------------------------------------
    def p_model(self):
        f = self.clear()
        self.head(f, "Which router is it, exactly?", "Look at the sticker under the router: the model and its hardware version both matter. "
                  "A wrong choice can make the router unusable.")
        self.v_model = tk.StringVar(value=(self.state_["model"] or {}).get("id", ""))
        for m in MODELS:
            box = tk.Frame(f, bg="white", highlightthickness=1, highlightbackground="#d7dce5"); box.pack(fill="x", pady=5)
            ttk.Radiobutton(box, text=m["title"], value=m["id"], variable=self.v_model).pack(anchor="w", padx=10, pady=(8, 0))
            ttk.Label(box, text=m["label"] + "  " + m["status"], style="Sub.TLabel", wraplength=500).pack(anchor="w", padx=34, pady=(0, 8))
        ttk.Radiobutton(f, text="Something else", value="other", variable=self.v_model).pack(anchor="w", pady=(8, 0))
        self.model_msg = ttk.Label(f, text="", style="Bad.TLabel", wraplength=540); self.model_msg.pack(anchor="w", pady=8)

    def n1(self):
        v = self.v_model.get()
        if v == "other": return self.model_msg.configure(text="Other routers are not supported yet. Nothing was changed.")
        m = next((x for x in MODELS if x["id"] == v), None)
        if not m: return self.model_msg.configure(text="Pick the model on the sticker.")
        self.state_["model"] = m; self.show(2)

    # ---- 3 OpenWrt ---------------------------------------------------------------------------------------------------
    def p_openwrt(self):
        f = self.clear(); m = self.state_["model"]
        self.head(f, "OpenWrt for the %s" % m["title"], "OpenWrt is the open router system the Baytaar software runs on. "
                  "The installer gets the version recommended for this model, from openwrt.org, and checks it against OpenWrt's own checksum.")
        self.v_now = tk.StringVar(value="stock")
        ttk.Label(f, text="What is on the router now?").pack(anchor="w", pady=(4, 2))
        ttk.Radiobutton(f, text="Its original %s software" % ("Linksys" if m["stock"] == "linksys" else "TP-Link"), value="stock", variable=self.v_now).pack(anchor="w")
        ttk.Radiobutton(f, text="OpenWrt already (it will be replaced with a clean copy)", value="openwrt", variable=self.v_now).pack(anchor="w")
        ttk.Radiobutton(f, text="OpenWrt %s already, freshly installed: skip this step" % FALLBACK_OPENWRT, value="skip", variable=self.v_now).pack(anchor="w")
        self.pb = ttk.Progressbar(f, length=520, mode="determinate"); self.pb.pack(anchor="w", pady=(18, 4))
        self.ow_msg = ttk.Label(f, text="", style="Sub.TLabel", wraplength=540); self.ow_msg.pack(anchor="w")
        self.next_b.configure(text="Download")

    def n2(self):
        m = self.state_["model"]; now = self.v_now.get()
        if now == "skip": self.state_.update(image="", image_kind="skip"); return self.show(4)
        kind = "factory" if now == "stock" else "sysupgrade"
        self.next_b.configure(state="disabled")
        def work():
            try:
                ver = ""
                if self.state_["site"]:
                    st, j = http_json("https://%s/router/fw/openwrt.json" % self.state_["site"])
                    if st == 200: ver = (j.get("models") or {}).get(m["id"]) or j.get("default", "")
                if not ver:
                    st, j = http_json("https://downloads.openwrt.org/.versions.json"); ver = FALLBACK_OPENWRT
                base = "https://downloads.openwrt.org/releases/%s/targets/%s/" % (ver, m["target"])
                self.ui(lambda: self.ow_msg.configure(text="Looking up OpenWrt %s for this model..." % ver))
                st, prof = http_json(base + "profiles.json")
                p = (prof.get("profiles") or {}).get(m["id"])
                if st != 200 or not p: raise RuntimeError("OpenWrt %s has no image for this model." % ver)
                if m["board"] not in p.get("supported_devices", [m["board"]]): raise RuntimeError("OpenWrt's image does not list this board.")
                img = next((i for i in p["images"] if i["type"] == kind), None)
                if not img: raise RuntimeError("No %s image for this model." % kind)
                dest = os.path.join(self.dl_dir, img["name"])
                if os.path.exists(dest) and hashlib.sha256(open(dest, "rb").read()).hexdigest() == img["sha256"]:
                    pass
                else:
                    self.ui(lambda: self.ow_msg.configure(text="Downloading %s ..." % img["name"]))
                    download(base + img["name"], dest, img["sha256"], lambda x: self.ui(lambda: self.pb.configure(value=x * 100)))
                self.state_.update(ow_ver=ver, image=dest, image_kind=now)
                self.ui(lambda: (self.pb.configure(value=100), self.ow_msg.configure(text="OpenWrt %s downloaded and checked: %s" % (ver, dest), style="Ok.TLabel"),
                                 self.after(900, lambda: self.show(3))))
            except Exception as e:
                self.ui(lambda: (self.ow_msg.configure(text=str(e), style="Bad.TLabel"), self.next_b.configure(state="normal")))
        self.bg(work)

    # ---- 4 flash -------------------------------------------------------------------------------------------------------
    def p_flash(self):
        f = self.clear(); m = self.state_["model"]
        steps = FLASH_STEPS["openwrt" if self.state_["image_kind"] == "openwrt" else m["stock"]]
        self.head(f, "Put OpenWrt on the router", "Follow these steps, then press Next. The installer waits for the router to come back with OpenWrt.")
        for i, s in enumerate(steps):
            ttk.Label(f, text="%d.  %s" % (i + 1, s), wraplength=540, justify="left").pack(anchor="w", pady=3)
        r = tk.Frame(f, bg="white"); r.pack(anchor="w", pady=10)
        ttk.Label(r, text="File:").pack(side="left")
        e = ttk.Entry(r, width=62); e.insert(0, self.state_["image"]); e.configure(state="readonly"); e.pack(side="left", padx=6)
        b = tk.Frame(f, bg="white"); b.pack(anchor="w")
        url = "http://192.168.1.1" if m["stock"] == "linksys" or self.state_["image_kind"] == "openwrt" else "http://tplinkwifi.net"
        ttk.Button(b, text="Open the router page", command=lambda: webbrowser.open(url)).pack(side="left")
        ttk.Button(b, text="Show the file", command=lambda: subprocess.Popen(["explorer", "/select,", self.state_["image"]])).pack(side="left", padx=8)
        ttk.Label(f, text="If something goes wrong: unplug the router's power, plug it back in and hold the Reset button while it starts; "
                  "OpenWrt then starts in safe mode at 192.168.1.1.", style="Sub.TLabel", wraplength=540).pack(anchor="w", pady=(14, 0))
        self.next_b.configure(text="It is updating: wait for it")

    def n3(self): self.show(4)

    # ---- 5 settings ------------------------------------------------------------------------------------------------------
    def p_settings(self):
        f = self.clear(); m = self.state_["model"]
        self.head(f, "Settings", "Only the essentials. Everything else can be changed later in the router's panel.")
        self.v = {k: tk.StringVar(value=d) for k, d in [("name", "Router-%d" % (int(time.time()) % 1000)), ("pw", ""), ("pw2", ""),
                  ("ssid", "Baytaar"), ("wkey", ""), ("country", "PK"), ("wan", "dhcp"), ("ip", ""), ("mask", "255.255.255.0"), ("gw", ""),
                  ("dns", "1.1.1.1 8.8.8.8"), ("puser", ""), ("ppass", ""), ("lan", "192.168.20.1"), ("old", "")]}
        self.v_l2 = tk.BooleanVar(value=True); self.v_l3 = tk.BooleanVar(value=False)
        self.field(f, "Router name", self.v["name"])
        self.field(f, "Router password", self.v["pw"], show="*"); self.field(f, "Password again", self.v["pw2"], show="*")
        self.field(f, "Wi-Fi name", self.v["ssid"]); self.field(f, "Wi-Fi password", self.v["wkey"], show="*")
        self.field(f, "Country (2 letters)", self.v["country"], width=6)
        ttk.Label(f, text="Main internet line (router's internet port):").pack(anchor="w", pady=(10, 2))
        r = tk.Frame(f, bg="white"); r.pack(anchor="w")
        for t, v in [("Automatic (most modems)", "dhcp"), ("Fixed address", "static"), ("PPPoE (username and password)", "pppoe")]:
            ttk.Radiobutton(r, text=t, value=v, variable=self.v["wan"], command=self._wan_fields).pack(side="left", padx=(0, 12))
        self.wanbox = tk.Frame(f, bg="white"); self.wanbox.pack(anchor="w", fill="x")
        self._wan_fields()
        ttk.Checkbutton(f, text="A second internet line, on LAN port 1", variable=self.v_l2).pack(anchor="w", pady=(8, 0))
        ttk.Checkbutton(f, text="A third internet line, on LAN port 2", variable=self.v_l3).pack(anchor="w")
        self.field(f, "Router address", self.v["lan"], width=18)
        if self.state_["image_kind"] in ("openwrt", "skip"):
            self.field(f, "Current OpenWrt password", self.v["old"], show="*")
            ttk.Label(f, text="(empty for a freshly installed OpenWrt)", style="Sub.TLabel").pack(anchor="w")
        self.set_msg = ttk.Label(f, text="", style="Bad.TLabel", wraplength=540); self.set_msg.pack(anchor="w", pady=6)
        self.next_b.configure(text="Install")

    def _wan_fields(self):
        for w in self.wanbox.winfo_children(): w.destroy()
        if self.v["wan"].get() == "static":
            self.field(self.wanbox, "Address", self.v["ip"], width=18); self.field(self.wanbox, "Netmask", self.v["mask"], width=18)
            self.field(self.wanbox, "Gateway", self.v["gw"], width=18); self.field(self.wanbox, "DNS servers", self.v["dns"], width=30)
        elif self.v["wan"].get() == "pppoe":
            self.field(self.wanbox, "PPPoE username", self.v["puser"]); self.field(self.wanbox, "PPPoE password", self.v["ppass"], show="*")

    def _ipv4(self, s): return re.fullmatch(r"(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}", s or "") is not None

    def n4(self):
        g = {k: v.get().strip() for k, v in self.v.items()}
        err = None
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,30}", g["name"]): err = "Router name: letters, digits and - only."
        elif len(g["pw"]) < 10: err = "The router password needs at least 10 characters."
        elif g["pw"] != g["pw2"]: err = "The two router passwords are not the same."
        elif not g["ssid"] or len(g["ssid"]) > 32: err = "Give the Wi-Fi a name (up to 32 characters)."
        elif not 8 <= len(g["wkey"]) <= 63: err = "The Wi-Fi password needs 8 to 63 characters."
        elif not re.fullmatch(r"[A-Z]{2}", g["country"].upper()): err = "Country: two letters, e.g. PK."
        elif g["wan"] == "static" and not (self._ipv4(g["ip"]) and self._ipv4(g["mask"]) and self._ipv4(g["gw"])): err = "Fill in the fixed address, netmask and gateway."
        elif g["wan"] == "pppoe" and not (g["puser"] and g["ppass"]): err = "Fill in the PPPoE username and password."
        elif not self._ipv4(g["lan"]) or not g["lan"].endswith(".1"): err = "Router address: something like 192.168.20.1."
        if err: return self.set_msg.configure(text=err)
        g["l2"], g["l3"], g["country"] = self.v_l2.get(), self.v_l3.get(), g["country"].upper()
        self.state_["settings"] = g
        self.show(5)

    # ---- 6 install ---------------------------------------------------------------------------------------------------
    def p_install(self):
        f = self.clear()
        self.head(f, "Installing", "Leave the cable in and the router on. This takes about 10 minutes; the router restarts at the end.")
        self.steps_v = ttk.Label(f, text="", font=("Segoe UI Semibold", 11)); self.steps_v.pack(anchor="w", pady=(0, 6))
        self.pb2 = ttk.Progressbar(f, length=560, mode="determinate", maximum=13); self.pb2.pack(anchor="w")
        self.logbox = tk.Text(f, height=18, width=86, font=("Consolas", 9), bg="#0f172a", fg="#e2e8f0", relief="flat"); self.logbox.pack(anchor="w", pady=10, fill="both", expand=True)
        self.next_b.configure(state="disabled", text="Installing...")
        self.bg(self.install)

    def log(self, s): self.ui(lambda: (self.logbox.insert("end", s + "\n"), self.logbox.see("end")))
    def phase(self, n, s): self.ui(lambda: (self.pb2.configure(value=n), self.steps_v.configure(text=s)))

    def install(self):
        try: self._install()
        except Exception as e:
            self.log("STOPPED: %s" % e)
            self.ui(lambda: (self.steps_v.configure(text="Stopped: %s" % e), self.next_b.configure(state="normal", text="Back to settings", command=lambda: (self.next_b.configure(command=self.next), self.show(4)))))

    def _find_openwrt(self, password):
        self.phase(1, "Waiting for the router with OpenWrt at %s" % OPENWRT_IP)
        t0 = time.time()
        while time.time() - t0 < 900:
            if port_open(OPENWRT_IP, 80):
                u = Ubus(OPENWRT_IP)
                for pw in [password, ""] if password else [""]:
                    try:
                        u.login(pw); return u
                    except PermissionError: continue
                    except Exception: break
                else:
                    raise RuntimeError("The router at %s did not accept the password. Enter its current OpenWrt password in Settings." % OPENWRT_IP)
            time.sleep(4)
        raise RuntimeError("No OpenWrt router appeared at %s in 15 minutes. Is the cable in a LAN port, and did the update finish?" % OPENWRT_IP)

    def _install(self):
        m, g = self.state_["model"], self.state_["settings"]
        # 1. the router
        u = self._find_openwrt(g.get("old", ""))
        board = (u.call("system", "board") or {})
        bn, rel = board.get("board_name", "?"), (board.get("release") or {}).get("version", "?")
        self.log("Found OpenWrt %s on %s." % (rel, bn))
        if bn != m["board"]: raise RuntimeError("This router reports '%s', not the %s you chose. Nothing was changed." % (bn, m["title"]))
        if not rel.startswith(("25.", "26.")): raise RuntimeError("OpenWrt %s is too old for the Baytaar software; put OpenWrt %s on it first." % (rel, self.state_["ow_ver"] or FALLBACK_OPENWRT))
        code, out, _ = u.run("df -k /overlay | awk 'NR==2{print $4}'")
        self.log("Free storage: %s KB." % out.strip())
        # 2. the Baytaar software, from the website (or the default website when skipped)
        self.phase(2, "Getting the Baytaar software")
        site = self.state_["site"] or DEFAULT_SITE
        st, vj = http_json("https://%s/router/fw/version.json" % site)
        if st != 200 or not vj.get("sha256"): raise RuntimeError("Could not read the software version from %s." % site)
        fwp = os.path.join(self.dl_dir, "baytaar-fw-%s.tar.gz" % vj["version"])
        download("https://%s/router/fw/baytaar-fw.tar.gz" % site, fwp, vj["sha256"])
        self.log("Baytaar software %s downloaded and checked." % vj["version"])
        # 3. settings file for the stage scripts
        self.phase(3, "Writing the settings")
        env = self._mwan_env(m, g)
        ienv = "\n".join("%s=%s" % (k, sh_q(v)) for k, v in [("WEB_SITE", self.state_["site"]), ("WEB_KEY", self.state_["key"]),
                       ("ROUTER_PASSWORD", g["pw"]), ("ROUTER_NAME", g["name"]), ("FW_VERSION", vj["version"])]) + "\n"
        u.run("rm -rf /tmp/baytaar-install; mkdir -p /tmp/baytaar-install/config")
        for fn in sorted(os.listdir(res("config"))):
            if fn.endswith(".sh"):
                u.write("/tmp/baytaar-install/config/" + fn, open(os.path.join(res("config"), fn), "rb").read().replace(b"\r\n", b"\n"))
        u.write("/tmp/baytaar-install/config/mwan.env", env.encode())
        u.write("/tmp/baytaar-install/install.env", ienv.encode())
        u.write("/tmp/baytaar-install/run.sh", open(res("router_runner.sh"), "rb").read().replace(b"\r\n", b"\n"))
        self.phase(4, "Sending the software to the router")
        u.write("/tmp/baytaar-install/fw.tar.gz", open(fwp, "rb").read())
        code, out, err = u.run("cd /tmp/baytaar-install && md5sum fw.tar.gz | cut -d' ' -f1")
        if out.strip() != hashlib.md5(open(fwp, "rb").read()).hexdigest(): raise RuntimeError("The software did not arrive intact on the router.")
        # 4. start the router-side run, detached
        u.run("cd /tmp/baytaar-install && (nohup sh run.sh </dev/null >/dev/null 2>&1 &) ; sleep 1; echo started")
        self.log("Installing on the router...")
        names = ["internet", "packages", "software", "website", "network", "firewall", "dhcp", "wifi", "lines", "password", "done"]
        words = {"internet": "Checking the router's internet", "packages": "Installing packages (a few minutes)", "software": "Installing the Baytaar software",
                 "website": "Joining your website account", "network": "Network settings (the connection drops here, that is expected)",
                 "firewall": "Firewall", "dhcp": "Addresses and names", "wifi": "Wi-Fi", "lines": "Internet lines and failover",
                 "password": "Router password", "done": "Finished: the router restarts"}
        last, lost_at, t0 = "", None, time.time()
        new_ip = g["lan"]
        while time.time() - t0 < 1800:
            s = ""
            # while LuCI's interface is up, read the router's status file; the Baytaar panel replaces LuCI when the
            # software is installed, and from then on publishes the status itself (old address first, new one after
            # the network step)
            if u is not None:
                s = u.read("/tmp/baytaar-install/status").strip()
                if not s and last in ("software", "website", "network"): u = None
            if not s:
                for host in (OPENWRT_IP, new_ip):
                    try:
                        with urllib.request.urlopen("http://%s:8080/install-status.txt?t=%d" % (host, time.time()), timeout=4) as r:
                            s = r.read().decode(errors="replace").strip()
                        if s: lost_at = None; break
                    except Exception: pass
            if not s:
                if lost_at is None: lost_at = time.time(); self.log("Waiting for the router (it may be moving to %s)..." % new_ip)
                if time.time() - lost_at > 60 and not getattr(self, "_renewed", False):
                    self._renewed = True; subprocess.run(["ipconfig", "/renew"], capture_output=True, timeout=90, creationflags=0x08000000)
                    self.log("Asked Windows for a new address.")
            first = s.split("\n")[0] if s else ""
            if first and first != last:
                last = first
                if first.startswith("failed:"): raise RuntimeError("On the router: " + first[7:].strip())
                if first in names: self.phase(4 + names.index(first) - 0 if first != "done" else 13, words.get(first, first)); self.log(words.get(first, first))
                if "website=joined" in s: self.state_["joined"] = True
                if first == "done": break
            time.sleep(3)
        else:
            raise RuntimeError("The install did not finish in 30 minutes. The log is on the router at /tmp/baytaar-install/log.")
        self.log("The router is restarting at http://%s:8080 ..." % new_ip)
        t1 = time.time()
        while time.time() - t1 < 300 and not port_open(new_ip, 8080): time.sleep(5)
        self.state_["new_ip"] = new_ip
        self.ui(lambda: (self.next_b.configure(state="normal", text="Next"), self.steps_v.configure(text="Installed.")))

    def _mwan_env(self, m, g):
        txt = open(res(os.path.join("config", "mwan.env.example")), encoding="utf-8").read().replace("\r\n", "\n")
        ports = ["lan1", "lan2", "lan3", "lan4"]
        w2 = "lan1" if g["l2"] else ""; w3 = ("lan2" if g["l3"] else "")
        if g["l3"] and not g["l2"]: w2, w3 = "lan1", ""          # a third line only makes sense with a second one
        lan = [p for p in ports if p not in (w2, w3)]
        set_ = {"PORT_WAN1": "wan", "PORT_WAN2": w2, "PORT_WAN3": w3, "PORTS_LAN": " ".join(lan),
                "WAN1_PROTO": g["wan"], "WAN1_IPADDR": g["ip"], "WAN1_NETMASK": g["mask"], "WAN1_GATEWAY": g["gw"], "WAN1_DNS": g["dns"] or "1.1.1.1 8.8.8.8",
                "WAN1_PPPOE_USER": g["puser"], "WAN1_PPPOE_PASS": g["ppass"],
                "LAN_IPADDR": g["lan"], "LAN_NETMASK": "255.255.255.0",
                "WIFI_SSID_24": g["ssid"], "WIFI_SSID_5": g["ssid"], "WIFI_KEY": g["wkey"], "WIFI_COUNTRY": g["country"],
                "WIFI_GUEST_ENABLE": "0", "WAN2_ENABLED": "1" if w2 else "0", "WAN3_ENABLED": "1" if w3 else "0",
                "FEAT_SPEEDTEST": "1", "FEAT_DRIVES": "1" if m["usb"] else "0"}
        out, seen = [], set()
        for line in txt.split("\n"):
            mm = re.match(r"^([A-Z][A-Z0-9_]*)=", line)
            if mm and mm.group(1) in set_:
                out.append("%s=%s" % (mm.group(1), sh_q(set_[mm.group(1)]))); seen.add(mm.group(1))
            else: out.append(line)
        for k, v in set_.items():
            if k not in seen: out.append("%s=%s" % (k, sh_q(v)))
        return "\n".join(out) + "\n"

    # ---- 7 done --------------------------------------------------------------------------------------------------------
    def p_done(self):
        f = self.clear(); ip = self.state_.get("new_ip", "192.168.20.1")
        self.head(f, "Your router is ready", "It runs OpenWrt with the Baytaar software.")
        ttk.Label(f, text="Panel: http://%s:8080  (sign in with the router password you chose)" % ip).pack(anchor="w", pady=4)
        if self.state_.get("site"):
            ttk.Label(f, text=("It joined your account on %s; it shows up there within about a minute." if self.state_.get("joined") else
                               "It could not join %s during the install. Open the panel, Remote Access, and connect it there with your key.") % self.state_["site"],
                      style="Ok.TLabel" if self.state_.get("joined") else "Bad.TLabel", wraplength=540).pack(anchor="w", pady=4)
        ttk.Label(f, text="Plug the modem of each internet line into its port: the main line into the internet port, the second into LAN port 1.",
                  style="Sub.TLabel", wraplength=540).pack(anchor="w", pady=8)
        b = tk.Frame(f, bg="white"); b.pack(anchor="w", pady=10)
        ttk.Button(b, text="Open the panel", command=lambda: webbrowser.open("http://%s:8080" % ip)).pack(side="left")
        if self.state_.get("site"):
            ttk.Button(b, text="Open the website", command=lambda: webbrowser.open("https://%s/router/" % self.state_["site"])).pack(side="left", padx=8)
        self.next_b.configure(text="Close", command=self.destroy)
        self.back_b.configure(state="disabled")

if __name__ == "__main__":
    App().mainloop()
