# 02 — Flashing OpenWrt, Stock Backup, and Recovery

For **TP-Link Archer C6 v3.20**, OpenWrt target `ramips/mt7621`, image id `tplink_archer-c6-v3`.

> **Read section 0 and section 4 before you flash.** Section 4 is the unbrick procedure. If you
> only read it after something goes wrong, you may not have the parts you need on hand.

---

## 0. Before you touch anything

### Confirm the model, one more time

Look at the label on the underside. It must read **`Ver: 3.20`** (or `3.0`/`3.2` — all the same
target). If it reads **`4.0`, `4.2`, or `Archer C6(IN)`**, **stop.** The v4 is different hardware
and the v3 image will brick it. Tell me and I will re-scope.

### Understand the one-way door

TP-Link's stock firmware will accept the OpenWrt factory image. Going *back* to stock later
requires either a TP-Link-signed stock image flashed from OpenWrt (sometimes rejected) or the
TFTP recovery path in section 4. **Assume returning to stock is difficult, not impossible.** If
the router is under warranty and that matters to you, flashing voids it.

### What you cannot back up, and why it matters

The `radio` partition at `0xff0000` holds **per-unit WiFi calibration data (ART)**. It is unique
to your device and cannot be downloaded from anywhere. If it is erased, WiFi is permanently
degraded or dead. Nothing in the normal flashing procedure touches it — but if you ever find
yourself typing `erase` commands in U-Boot, know exactly which partition you are erasing.

**Section 1 backs this partition up. Do not skip it.**

### Parts you may need for recovery

- An Ethernet cable and a computer you can set a static IP on. (Covers most cases.)
- **Optional but strongly recommended:** a **3.3 V USB-to-UART adapter** (CP2102, CH340, or
  FT232 set to 3.3 V) and jumper wires. This is the only recovery path that always works.
  **A 5 V adapter will damage the SoC.** They cost a few dollars; buy one before you flash, not
  after.

---

## 1. Back up stock firmware and calibration data

There are two levels of backup. Do both.

### 1a. Stock configuration backup (from stock firmware, 2 minutes)

1. Log into the stock TP-Link web UI (usually `http://192.168.0.1` or `http://tplinkwifi.net`).
2. **Advanced → System Tools → Backup & Restore → Backup**.
3. Save the `.bin` file somewhere safe.

This only restores settings onto stock firmware. It is not a firmware image. Still worth having.

### 1b. Full flash partition dump (after flashing OpenWrt, before configuring)

This is the backup that actually protects you. Do it **immediately after OpenWrt boots for the
first time**, before running any configuration.

SSH into the fresh OpenWrt install (`ssh root@192.168.1.1`, no password on first boot) and dump
every partition:

```sh
mkdir -p /tmp/backup
for mtd in $(awk -F: '/mtd/{print $1}' /proc/mtd); do
    name=$(grep "^$mtd:" /proc/mtd | sed 's/.*"\(.*\)"/\1/')
    echo "Dumping $mtd ($name)..."
    dd if=/dev/$mtd of=/tmp/backup/${mtd}-${name}.bin bs=64k 2>/dev/null
done
ls -l /tmp/backup/
```

Then pull them to this Windows machine (run from PowerShell in `E:\Coding\MultiWAN`):

```bash
scp -r root@192.168.1.1:/tmp/backup ./stock-backup
```

You now have `u-boot`, `firmware`, `config`, and `radio` images. **Archive
`*-radio.bin` and `*-config.bin` permanently** — those are the irreplaceable ones. `radio` holds
WiFi calibration; `config` holds your MAC addresses.

> `/tmp` is RAM. These files vanish on reboot. Copy them off the router before rebooting.

---

## 2. Download the correct image

Use the [OpenWrt Firmware Selector](https://firmware-selector.openwrt.org/?target=ramips%2Fmt7621&id=tplink_archer-c6-v3)
and search for **`Archer C6 v3`**.

You need **two** files:

| File | Used for | Filename pattern |
|---|---|---|
| **FACTORY** | First flash, from stock TP-Link firmware | `...-tplink_archer-c6-v3-squashfs-factory.bin` |
| **SYSUPGRADE** | All later upgrades, from OpenWrt | `...-tplink_archer-c6-v3-squashfs-sysupgrade.bin` |

Pick the **latest stable release** (not SNAPSHOT — snapshots ship without LuCI and change daily).

**Verify the download.** The selector page shows a SHA256 for each image. On Windows:

```bash
certutil -hashfile "openwrt-...-factory.bin" SHA256
```

Compare it character-for-character with the site. A corrupted image is one of the more common
causes of a brick, and this check takes ten seconds.

---

## 3. Flash it

### Method A — stock web UI (recommended, lowest risk)

> **Known state of this unit (checked 2026-08-19):**
> Hardware Version `Archer C6 v3.20`, Firmware Version `1.1.1 Build 20250716 Rel. 74574(5553)`,
> web UI reachable at `https://192.168.100.1` (non-default LAN subnet).
>
> **That firmware is from July 2025 — newer than most flashing write-ups assume.** Community
> guides for this family report that newer stock builds can reject third-party images with an
> *"invalid file type"* error. If that happens, do **not** force it. Use the downgrade path in
> section 3c, which works because you already have the 2021 stock image locally.

1. Disconnect the router from the internet. Connect **only** your computer, by cable, to a
   **LAN** port. Do not do this over WiFi.
2. Set your computer to DHCP.
3. Log into the stock UI. **On this unit that is `https://192.168.100.1`**, not the
   `192.168.0.1` default — the LAN subnet has been changed at some point.
4. **Back up the current configuration first:** *Advanced → System Tools → Backup & Restore →
   Backup*. This is the only copy of the present settings.
5. Go to **Advanced → System Tools → Firmware Upgrade → Local Upgrade**.
6. Browse to the OpenWrt **FACTORY** `.bin`. **Not** the sysupgrade one, and **not** the
   `a6c6_v3-up-...bin` stock image in this repo — that one is the rollback image for section 5.
7. Upload and confirm. **Do not power off.** The unit reboots on its own.
8. Wait a full **3 minutes** after the LEDs settle. Resist the urge to intervene.

If the stock UI rejects the file (*"invalid file type"*, *"firmware version error"*), do not
force it. Go to 3c.

### Method B — TFTP flash via U-Boot

Use this if both the web UI and the downgrade path reject the image. Details in section 4 (the
procedure is identical to recovery).

### 3c. Downgrade-first path (use when the 2025 firmware rejects OpenWrt)

Newer TP-Link builds are progressively stricter about what the web upgrader will accept. You are
in an unusually good position here: **the 2021 stock image in this repository predates that
tightening**, and stock-to-stock flashing is exactly what the vendor upgrader is designed to do.

1. In the same **Local Upgrade** box, upload
   `Archer C6(EU)_V3.20_211118/a6c6_v3-up-ver1-0-14-P1[...].bin`.
2. Let it reboot and settle. The LAN address will likely revert to `192.168.0.1` — reconnect
   accordingly.
3. Log back in and repeat Method A with the OpenWrt factory image.

> If the router refuses the *downgrade* as well ("version too old"), stop using the web UI
> entirely and go to Method B. Do not look for a modified image that "unlocks" the upgrader —
> those circulate for TP-Link devices, are unsigned binaries from strangers, and are a far better
> way to lose the router than TFTP is.

### After first boot

> **Plug into LAN3 or LAN4 — not LAN1 or LAN2.**
>
> This matters for the configuration stage that follows, not for the flash itself.
> [`config/10-network.sh`](../config/10-network.sh) reassigns `lan1` → WAN2 and `lan2` → WAN3.
> If you are connected through LAN1 when `install.sh` reaches that stage, the port stops being
> part of the LAN bridge and your session dies mid-install. LAN3 and LAN4 stay in the bridge
> throughout.

1. Set your computer back to DHCP and reconnect to **LAN3 or LAN4**. You should get `192.168.1.x`.
   Note the change from `192.168.100.x` — OpenWrt does not inherit the stock LAN subnet.
2. Browse to `http://192.168.1.1` (LuCI) or SSH: `ssh root@192.168.1.1`. **No password initially.**
3. **Immediately set a root password** — this is also your admin UI password later:
   ```sh
   passwd
   ```
4. **Now go do the section 1b partition dump.** Before anything else.
5. Confirm you are on the right device and image:
   ```sh
   cat /tmp/sysinfo/board_name        # expect: tplink,archer-c6-v3
   cat /etc/openwrt_release
   free -m ; df -h /overlay
   ip -br link                        # expect: wan, lan1..lan4, br-lan
   ```

If `board_name` is anything other than `tplink,archer-c6-v3`, stop and tell me before configuring.

---

## 4. Recovery / unbrick

> **Honest warning specific to this model.** TFTP recovery on the Archer C6 v3 is reported as
> unreliable — there is a
> [forum thread](https://forum.openwrt.org/t/tp-link-archer-c6-v3-not-booting-after-install-and-lan-ports-not-working-for-tftp-recovery/118970)
> from a user whose LAN ports were unresponsive during recovery, leaving TFTP unusable. Community
> reports also disagree on the exact recovery IP (`192.168.0.66` vs `192.168.0.225`) and filename,
> because these differ between stock U-Boot and hardware sub-revisions.
>
> **Serial UART (section 4b) is the only recovery path that reliably works on this device.** Treat
> TFTP as the convenient attempt and serial as the real answer.

### 4a. TFTP recovery (try this first — it costs nothing)

You need a TFTP server on this Windows machine. `tftpd64` is the usual choice.

1. Set your Ethernet adapter to a **static IP**. Try **`192.168.0.66`**, netmask `255.255.255.0`,
   no gateway. (If that fails, retry the whole procedure with **`192.168.0.225`** — reports
   differ, and it depends on your U-Boot build.)
2. Copy the **factory** image into your TFTP root directory and rename it to:
   ```
   tp_recovery.bin
   ```
   If that is not picked up, try `ArcherC6v3_tp_recovery.bin`. **Section 4b tells you the exact
   filename your bootloader wants** — if you have serial, read it there instead of guessing.
3. Start the TFTP server. Allow it through Windows Firewall (UDP 69). Temporarily disabling the
   firewall for this test removes a common failure cause.
4. Power off the router. Connect your computer by cable to a **LAN** port (try **LAN1** first;
   some builds only listen on the WAN port — try both).
5. Hold the **Reset** button, power on, keep holding **8–10 seconds**, then release.
6. Watch the TFTP server log. If it serves the file, the router flashes and reboots in 2–3 minutes.

If the TFTP server log shows nothing after two attempts on both port types and both IPs, TFTP is
not going to work. Go to 4b.

### 4b. Serial UART recovery (the reliable path)

**Requires a 3.3 V USB-to-UART adapter. A 5 V adapter will destroy the SoC.**

**Console settings: 115200 baud, 8N1, 3.3 V logic.**

1. Open the case. The UART header is a 4-pin pad on the PCB (commonly labelled `GND`, `TX`, `RX`,
   `VCC` or `J1`). **Connect GND, TX, and RX only. Do NOT connect VCC.** The router powers itself;
   connecting VCC risks backfeeding and damage.
   - Adapter **RX** → router **TX**
   - Adapter **TX** → router **RX**
   - Adapter **GND** → router **GND**
2. Open a serial terminal (PuTTY on Windows) at 115200 8N1 on the adapter's COM port.
3. Power on the router and watch the boot log. **This log tells you everything the guesswork
   above was trying to infer** — the recovery IP, the expected filename, and the U-Boot prompt key.
4. Interrupt U-Boot when prompted (usually a specific key within ~2 seconds — the log says which).
5. At the U-Boot prompt, set up and flash. **Read your own boot log for the correct addresses
   rather than copying these blindly** — they vary by U-Boot build:
   ```
   setenv ipaddr 192.168.0.1
   setenv serverip 192.168.0.66
   tftpboot 0x80800000 openwrt-factory.bin
   erase 0x40000 +0xf60000
   cp.b 0x80800000 0x40000 $filesize
   reset
   ```

> **What each command does, because getting this wrong is how devices die permanently:**
> `erase 0x40000 +0xf60000` erases **only the `firmware` partition**. The offset `0x40000` starts
> *after* `u-boot`, and the length `0xf60000` stops *before* the `config` and `radio` partitions
> at `0xfa0000`. **Never erase from `0x0`** — that destroys U-Boot and leaves you needing an SPI
> flash programmer. **Never erase past `0xfa0000`** — that destroys your WiFi calibration.

### 4c. Last resort — SPI flash programmer

If U-Boot itself is gone, you need a CH341A programmer and an SOIC-8 test clip to reflash the
W25Q128 directly, using the `u-boot` dump you took in section 1b. This is why section 1b matters.
Without that dump you would need a matching image from someone else's identical unit.

---

## 5. Rollback: returning to stock TP-Link firmware

**You already have the stock image.** It is in this repository:

```
Archer C6(EU)_V3.20_211118/
  a6c6_v3-up-ver1-0-14-P1[20211118-rel43110]_2021-11-18_12.04.37.bin   (14.9 MB)
Archer C6(EU)_V3.20_211118.zip
GPL_Archer A6&C6.tar.gz
```

Two useful things this confirms:

- **Your unit is the EU region variant of v3.20.** The OpenWrt ToH entry explicitly covers the EU
  variant with identical specifications, so `tplink_archer-c6-v3` remains the correct target.
- The `a6c6_v3` filename prefix reflects that TP-Link ships one firmware line for both the
  **Archer A6 v3 and C6 v3** — they are the same board. Seeing A6 in the filename is expected and
  is not a sign you have the wrong file.

**Archive this `.bin` somewhere outside this repository.** It is your rollback image, and TP-Link
does rotate old firmware off its download pages.

### Procedure

1. Use the `.bin` above (already region-correct for your unit).
2. TP-Link images carry a header OpenWrt's `sysupgrade` refuses by default. The usual path is
   TFTP recovery (section 4a) with this image renamed to `tp_recovery.bin`.
3. Flashing stock from OpenWrt with `sysupgrade -F` (force) is possible but **`-F` disables the
   safety checks that stop you flashing the wrong image**. Use it only with serial recovery
   available as a fallback.

> The `GPL_Archer A6&C6.tar.gz` archive is TP-Link's GPL source drop. It is not needed for
> flashing or recovery — it is the vendor kernel source, useful only if you ever need to compare
> a driver against the stock build.

---

## 6. Pre-configuration checklist

Confirm all of these before moving on to `config/install.sh`:

- [ ] Label confirmed as `Ver: 3.20` (not v4)
- [ ] Stock firmware `.bin` (already in this repo) archived somewhere outside it
- [ ] Stock config backup saved (1a)
- [ ] **All four MTD partitions dumped and copied off the router** (1b)
- [ ] `radio` and `config` dumps archived somewhere you will still have in five years
- [ ] Image SHA256 verified against the firmware selector
- [ ] OpenWrt boots, `board_name` reads `tplink,archer-c6-v3`
- [ ] Root password set
- [ ] `ip -br link` shows `wan`, `lan1`, `lan2`, `lan3`, `lan4`
- [ ] 3.3 V USB-UART adapter on hand (or accepted risk of not having one)

Next: [`../config/install.sh`](../config/install.sh), then
[`03-failover-expectations.md`](03-failover-expectations.md).

---

## Sources

- [OpenWrt Firmware Selector — Archer C6 v3](https://firmware-selector.openwrt.org/?target=ramips%2Fmt7621&id=tplink_archer-c6-v3)
- [OpenWrt commit — device tree / flash layout](https://git.openwrt.org/openwrt%2Fopenwrt/commit/?id=d22fb7f4fd833c420bc2ab34384862da0a6688b5)
- [OpenWrt forum — C6 v3 not booting, LAN ports not working for TFTP recovery](https://forum.openwrt.org/t/tp-link-archer-c6-v3-not-booting-after-install-and-lan-ports-not-working-for-tftp-recovery/118970)
- [TP-Link — Router bricked, firmware recovery steps](https://www.tp-link.com/us/support/faq/1482/)
- [OpenWrt forum — Is Archer C6 v3.2 supported](https://forum.openwrt.org/t/is-archer-c6-v3-2-supported-by-openwrt/147209)
