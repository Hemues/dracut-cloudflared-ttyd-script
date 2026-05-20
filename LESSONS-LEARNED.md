# Dracut Cloudflared TTYD Script — Lessons Learned

Reference for building a Dracut module that enables remote LUKS disk unlock via
Cloudflare tunnel + web terminal (ttyd).

Entries marked ✅ are verified in production. Entries marked ⏳ are pending verification.

---

## Table of Contents

1. [Initramfs Network Setup Without Kernel Parameters](#1--initramfs-network-setup-without-kernel-parameters)
2. [Adding WiFi Interface Support](#2--adding-wifi-interface-support)
3. [Initramfs Sysctl Hardening Breaks Networking](#3--initramfs-sysctl-hardening-breaks-networking)
4. [RPM/Dracut Module Integration](#4--rpmdracut-module-integration)
5. [Binary Fetch at Build Time vs Runtime](#5--binary-fetch-at-build-time-vs-runtime)
6. [Fedora 44 Upgrade Breaks WiFi in Initramfs](#6--fedora-44-upgrade-breaks-wifi-in-initramfs)

---

## General Design Lessons

### Dracut and mkinitcpio have fundamentally different hook models
Dracut uses module directories with `module-setup.sh` (install) and hook scripts.
mkinitcpio uses `build()` and `run_hook()`. Code from one system cannot be
copy-pasted to the other.

### Network in initramfs must work before systemd-networkd
The initramfs network stack runs before systemd. NetworkManager profiles must be
copied into the initramfs at build time so the dracut network module can establish
connectivity.

---

## #1 — Initramfs Network Setup Without Kernel Parameters

**Status:** ✅ VERIFIED (commit ed51247)

**Symptom:**
Network doesn't come up in the initramfs, preventing Cloudflare tunnel from
connecting.

**Root Cause:**
Traditional approach uses `rd.neednet=1` and `ip=` kernel parameters. This
module auto-detects network configuration from NetworkManager profiles instead,
but the detection logic wasn't pulling the right profiles into the initramfs.

**Fix:**
Copy NetworkManager connection profiles into the initramfs during `module-setup.sh`
install phase. The hook script then uses these profiles to bring up networking.

---

## #2 — Adding WiFi Interface Support

**Status:** ✅ VERIFIED (commits b08db9a, ec053c0, ec374e4)

**Symptom:**
WiFi-only machines fail to connect in the initramfs. Only wired interfaces worked.

**Root Cause:**
Initial implementation only handled Ethernet (`eth0`, `eno1`). WiFi requires
`wpa_supplicant`, firmware blobs, and additional kernel modules in the initramfs.

**Fix:**
Extended `module-setup.sh` to:
- Detect WiFi interfaces and their firmware requirements
- Include `wpa_supplicant` binary and config
- Copy wireless kernel modules and firmware
- Add WiFi bring-up retry logic in the hook script

**Key Lesson:** WiFi in initramfs needs the full stack: kernel module + firmware +
wpa_supplicant + DHCP. Missing any one piece causes silent failure.

---

## #3 — Initramfs Sysctl Hardening Breaks Networking

**Status:** ✅ VERIFIED (commit 1468181)

**Symptom:**
Network comes up but connections are refused or packets are dropped.

**Root Cause:**
Sysctl hardening rules copied into the initramfs (e.g., `rp_filter=1`,
`accept_redirects=0`) blocked traffic in the minimal initramfs environment
where routing tables are incomplete.

**Fix:**
Removed overly aggressive sysctl hardening from the initramfs network
module. Only apply hardening sysctls after full boot when routing is
properly configured. Also removed `local` variable declarations outside
functions (POSIX shell compatibility).

---

## #4 — RPM/Dracut Module Integration

**Status:** ✅ VERIFIED

**Symptom:**
Module doesn't appear in `dracut --list-modules` after RPM install.

**Root Cause:**
Dracut modules must be in `/usr/lib/dracut/modules.d/` with a specific
naming convention (`NN-modulename/`). The RPM spec file didn't install
to the correct path.

**Fix:**
RPM `configure` script sets the correct install paths. Module directory
follows the `90cloudflared-ttyd/` naming convention.

---

## #5 — Binary Fetch at Build Time vs Runtime

**Status:** ✅ VERIFIED

**Symptom:**
Initramfs build succeeds but `cloudflared` or `ttyd` binary is missing
at boot time.

**Root Cause:**
Binaries are downloaded during `module-setup.sh` (dracut build time).
If the build machine has no internet or the download URL changes, the
binary isn't included and the module silently does nothing at boot.

**Fix:**
`module-setup.sh` checks for binary existence and returns a non-zero
exit code if the download fails, preventing a broken initramfs from
being generated.

**Key Lesson:** Always validate that critical binaries are present in the
initramfs after build. Check the image size — a too-small image means
something was silently dropped.

---

## #6 — Fedora 44 Upgrade Breaks WiFi in Initramfs

**Status:** ✅ VERIFIED (2026-05-20)

**Symptom:**
After in-place upgrade from Fedora 43 to 44, the cloudflared tunnel fails to
establish in the initramfs on WiFi-only hosts. Wired hosts are unaffected.
The net-detect journal shows only wired profiles (e.g., `enp0s25.nmconnection`,
`lo.nmconnection`) with `wifi=0` — the WiFi profile is completely missing from
the initramfs.

**Root Cause (two issues):**

1. **WiFi profile excluded during upgrade rebuild:** When the F44 kernel is
   installed during the upgrade, dracut runs automatically to build the new
   kernel's initramfs. At that moment, NetworkManager is momentarily restarting
   (no default gateway). The `module-setup.sh` fallback path (triggered when
   `gw_iface` is empty) copied all profiles EXCEPT WiFi ones — by design it
   skipped `type=wifi` profiles in the fallback. On a WiFi-only host, this
   resulted in an initramfs with zero WiFi connectivity.

2. **Broken systemd service ordering:** The `net-detect.service` had
   `After=NetworkManager.service` and `Wants=NetworkManager.service`. However, in
   the initramfs the NM service is called `nm-initrd.service` (not
   `NetworkManager.service`). Systemd silently ignores ordering dependencies on
   non-existent units, so net-detect started without waiting for NM.

**Fix:**

1. Modified all fallback paths in `module-setup.sh` to include WiFi profiles
   when WiFi hardware is present on the host (`/sys/class/net/*/wireless`
   exists), regardless of whether a default gateway is currently active. This
   ensures WiFi profiles are always baked in on machines with WiFi hardware.

2. Updated `dracut-cloudflared-ttyd-net-detect.service` to use
   `After=nm-initrd.service NetworkManager-initrd.service` and
   `Wants=nm-initrd.service` — the correct service names used inside the
   initramfs.

**Key Lessons:**
- Never assume network is stable during dracut builds triggered by package
  install/upgrade. NM may be restarting → no default gateway → fallback logic.
- In the initramfs, NM runs as `nm-initrd.service`, NOT `NetworkManager.service`.
  Always verify systemd service names match what actually exists inside the
  initramfs (use `lsinitrd | grep service`).
- The daily updater timer eventually rebuilds the initramfs correctly (when the
  host is fully booted with WiFi), but the damage is done on first reboot after
  the kernel upgrade.
