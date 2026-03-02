[![CI](https://github.com/tamisoft/dracut-cloudflared-ttyd/actions/workflows/main.yml/badge.svg)](https://github.com/tamisoft/dracut-cloudflared-ttyd/actions/workflows/main.yml)

## Install using dnf
Configure dnf to use the pre-built binaries. [Instructions](https://rpm-repo.tamisoft.com)

## Add cloudflared and web tty to dracut
Building this package will fetch the latest version of cloudflared and ttyd binaries from their respective repos, then installs the module to dracut.
This allow the user to answer encrypted disk password prompts remotely from a web browser.

### Build the rpm
- install build dependencies: `sudo dnf install wget dnf-plugin-builddep rpm-build`
- `sudo dnf builddep dracut-cloudflared-ttyd.spec`
- `rpmbuild -bp dracut-cloudflared-ttyd.spec`
- `rpmbuild -ba --define '_auto_tool_versions 1' dracut-cloudflared-ttyd.spec`

### Install the rpm
- `sudo dnf install ~/rpmbuild/RPMS/x86_64/dracut-cloudflared-ttyd*`

### Prerequisites
- a configured Cloudflare tunnel, saved token
- configured url that will prompt for the disk keys (default: `UNIX:///run/ttyd-cf.socket`)
- optional, but recommended: protect the url with authentication by adding a self-hosted app on Cloudflare's Zero Trust dashboard / Access / Applications

### Usage
- edit `/etc/sysconfig/dracut-cloudflared-ttyd` and add your `TUNNEL_TOKEN` acquired in the prerequisites
- rebuild the initram: `dracut -f`
- after reboot, when the device password is prompted, you can access the prompt from the URL added on Cloudflare

> **Note:** The `ip=dhcp` kernel parameter is **no longer required**. The module automatically copies your host's NetworkManager connection profiles into the initramfs during `dracut -f`. This means whatever network configuration you have on the host (DHCP, static/manual IP, VLAN, bond, bridge, etc.) is used automatically in the initramfs. Only `rd.neednet=1` is added as a kernel parameter (done automatically on install).

---

## Network configuration

The module automatically detects and uses your existing network setup. No extra kernel boot parameters are needed beyond `rd.neednet=1` (added automatically on install).

### Default gateway detection (build time)

During `dracut -f`, the module inspects the host's routing table to find which interface carries the **default gateway** (the route to the internet). Only the NetworkManager connection profile for that interface is copied into the initramfs. This means:

- If you have multiple NICs (e.g., management + data), only the one with the default route is used in the initramfs
- For **bond/bridge/team** interfaces, the master profile and all its member (slave) profiles are automatically included
- For **VLAN** interfaces, the VLAN profile and its parent interface profile are included
- If no default gateway is found (e.g., the system is offline during `dracut -f`), all non-WiFi profiles are copied as a fallback

### Network detection (boot time)

At boot inside the initramfs, a detection service runs before cloudflared:

1. Waits for NetworkManager to activate the copied connection profile
2. Checks for a **default route** — if present, the network is ready and cloudflared starts
3. If no default route appears via wired, waits up to 30s for DHCP/static negotiation
4. If still no route and WiFi is configured, activates WiFi as a fallback
5. Verifies a default route is established before allowing cloudflared to proceed

### Supported configurations

| Type | How it works |
|------|-------------|
| **DHCP (wired)** | Default gateway profile is copied, interface gets IP via DHCP |
| **Static/Manual IP** | Profile with `method=manual` and `address`/`gateway`/`dns` is copied as-is |
| **VLAN** | VLAN profile + parent interface profile are both copied |
| **Bond / Bridge / Team** | Master + all member profiles are copied, NM assembles them in initramfs |
| **Multiple NICs** | Only the NIC with the default gateway is included |
| **WiFi (DHCP)** | Auto-detected if WiFi is the default gateway; or set `WIFI_SSID`/`WIFI_PSK` — see [WiFi support](#wifi-support) |

### Example: static IP via nmcli

If your server uses a static IP configured with nmcli:
```bash
# This is your normal host-level config — nothing special needed
sudo nmcli connection modify "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses 192.168.1.100/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns "8.8.8.8 8.8.4.4"
sudo nmcli connection up "Wired connection 1"

# Just rebuild the initramfs — the static config is picked up automatically
sudo dracut -f
```

### Upgrading from older versions

If you previously had `ip=dhcp` in your kernel parameters, the RPM post-install script will remove it automatically. You can also remove it manually:
```bash
sudo grubby --update-kernel=ALL --remove-args="ip=dhcp"
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

---

## Automatic cloudflared updates

A systemd timer (`dracut-cloudflared-ttyd-updater.timer`) is installed and enabled automatically. It runs once a day and performs the following:

1. Runs `cloudflared update` on the binary at `/usr/share/dracut-cloudflared-ttyd/cloudflared`
2. Checks the exit code:
   - **Exit 0** — already up to date
   - **Exit 11** — updated successfully → old kernels are cleaned up (keeping running + previous), then `dracut -f` rebuilds the initramfs with the new binary
   - **Exit 10** — update failed, logged as error
3. **Gateway change detection:** even when cloudflared is already up to date (exit 0), the updater compares the current default gateway against a fingerprint saved during the last `dracut -f`. If the gateway interface or type (wired ↔ WiFi) has changed, the initramfs is rebuilt automatically. This means switching from wired to WiFi (or vice versa) is picked up within 24 hours without manual intervention.
4. All output is logged to the systemd journal under `dracut-cloudflared-ttyd-updater`

### Manual network re-detection
If you've changed your network setup (e.g., moved from wired to WiFi) and don't want to wait for the daily timer, you can trigger a rebuild manually:
```bash
# Option 1: run the updater (checks for cloudflared update + gateway change)
sudo systemctl start dracut-cloudflared-ttyd-updater.service

# Option 2: rebuild the initramfs directly (always re-detects the gateway)
sudo dracut -f
```

### Check updater logs
```bash
sudo systemctl start dracut-cloudflared-ttyd-updater.service
journalctl -u dracut-cloudflared-ttyd-updater.service -e
```

### Kernel cleanup
Before every initramfs rebuild (both in the updater and during RPM upgrades), old kernels are automatically removed. Only the currently running kernel and one previous version are kept. This ensures `/boot` has enough space for the new initramfs.

---

## WiFi support

WiFi is supported automatically. The module detects your network setup at build time and does the right thing:

### Scenario 1: WiFi is the default gateway (WiFi-only system)

If your host's default gateway is on a WiFi interface when you run `dracut -f`:
- The existing WiFi NM connection profile is **copied automatically** into the initramfs
- WiFi drivers, firmware, `wpa_supplicant`, and kernel modules are included
- **No `WIFI_SSID` configuration needed** — it just works

At boot, NM activates the WiFi profile directly (no wired fallback attempted unless wired profiles also exist).

### Scenario 2: Wired host, WiFi fallback for boot

If your host uses wired at build time, but the machine may boot in a WiFi-only environment:
- Set `WIFI_SSID` and `WIFI_PSK` in `/etc/sysconfig/dracut-cloudflared-ttyd`
- At boot, wired is tried first; if no wired link, WiFi is activated as fallback

### Scenario 3: Both wired and WiFi available

The network detection service at boot:
1. Checks if NM already established a default route via the copied profile
2. If wired link exists but no route yet, waits 30s for wired DHCP/static
3. If still no route, activates any WiFi profiles present
4. Wired is always preferred (WiFi profiles use lower `autoconnect-priority`)

### WiFi configuration

Edit `/etc/sysconfig/dracut-cloudflared-ttyd` and uncomment/set the WiFi parameters:

```bash
# Required
WIFI_SSID="YourNetworkName"
WIFI_PSK="YourWiFiPassword"

# Optional (defaults shown)
WIFI_SECURITY="wpa-psk"      # wpa-psk, sae (WPA3), wpa-eap, etc.
WIFI_HIDDEN=false             # set to true for hidden networks
WIFI_BAND=""                  # "a" for 5GHz, "bg" for 2.4GHz, empty for auto
WIFI_BSSID=""                 # lock to specific access point MAC
```

Then rebuild the initramfs:
```bash
sudo dracut -f
```

### What gets included in the initramfs

When WiFi support is needed (either auto-detected from the default gateway, or via `WIFI_SSID`), `dracut -f` will automatically:
- Include `wpa_supplicant` and `rfkill` binaries
- Detect the WiFi hardware on the build host and include the correct kernel driver and firmware
- Include the `cfg80211`, `mac80211`, and `rfkill` kernel modules
- Generate a NetworkManager WiFi connection profile inside the initramfs

### WiFi prerequisites

Install WiFi support packages:
```bash
sudo dnf install wpa_supplicant NetworkManager-wifi
```

These are listed as `Recommends` in the RPM and will be installed by default on most Fedora systems.
