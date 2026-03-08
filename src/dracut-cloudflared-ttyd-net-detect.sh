#!/usr/bin/bash
# dracut-cloudflared-ttyd-net-detect.sh
# Network detection for initramfs: ensures the correct network connection
# (the one with internet access / default gateway) is active for cloudflared.
#
# Logic:
#   1. Wait briefly for NM to bring up connections
#   2. Check if a default route exists — if yes, we have internet, done
#   3. If no default route via wired, check for WiFi as fallback
#   4. If WiFi is available and configured, activate it
#   5. Verify a default route is established before handing off to cloudflared
#
# This script runs inside the initramfs, before cloudflared.
# SPDX-License-Identifier: MIT

LOGPREFIX="net-detect"

log_info()  { echo "${LOGPREFIX}: $*"; }
log_warn()  { echo "${LOGPREFIX}: WARN: $*" >&2; }
log_error() { echo "${LOGPREFIX}: ERROR: $*" >&2; }

# Ensure DNS resolution works after network is up.
# systemd-resolved (127.0.0.53) may not have upstream servers yet;
# try multiple sources: NM runtime -> nmcli -> profile -> public DNS fallback.
_ensure_dns_ready() {
    sleep 1

    _has_real_ns() {
        grep -q '^nameserver' /etc/resolv.conf 2>/dev/null &&
        grep '^nameserver' /etc/resolv.conf 2>/dev/null | grep -qv '127\.0\.0\.53'
    }

    if _has_real_ns; then
        log_info "DNS ready: resolv.conf has real nameserver(s)"
        return 0
    fi

    log_warn "No real nameserver in /etc/resolv.conf — attempting DNS fix"

    if [ -f /run/NetworkManager/resolv.conf ] &&
       grep -q "^nameserver" /run/NetworkManager/resolv.conf 2>/dev/null; then
        if grep "^nameserver" /run/NetworkManager/resolv.conf 2>/dev/null | grep -qv '127\.0\.0\.53'; then
            cp /run/NetworkManager/resolv.conf /etc/resolv.conf 2>/dev/null
            log_info "DNS fixed: using NM runtime resolv.conf"
            return 0
        fi
    fi

    if command -v nmcli &>/dev/null; then
        local nmcli_dns
        nmcli_dns=$(nmcli -t -f IP4.DNS device show 2>/dev/null | \
                    sed -n 's/^IP4\.DNS\[.*\]://p' | sed -n '1,3p')
        if [ -n "$nmcli_dns" ]; then
            : > /etc/resolv.conf
            echo "$nmcli_dns" | while read -r _s; do
                [ -n "$_s" ] && echo "nameserver $_s" >> /etc/resolv.conf
            done
            log_info "DNS fixed: using DNS from nmcli"
            return 0
        fi
    fi

    local dns_line=""
    for _prof in /etc/NetworkManager/system-connections/*.nmconnection; do
        [ -e "$_prof" ] || continue
        dns_line=$(grep '^dns=' "$_prof" 2>/dev/null | sed -n '1p' | cut -d= -f2)
        [ -n "$dns_line" ] && break
    done
    if [ -n "$dns_line" ]; then
        : > /etc/resolv.conf
        local IFS=';'
        for _s in $dns_line; do
            [ -n "$_s" ] && echo "nameserver $_s" >> /etc/resolv.conf
        done
        log_info "DNS fixed: using DNS from NM profile"
        return 0
    fi

    log_warn "No DNS from any NM source, falling back to public DNS (1.1.1.1, 8.8.8.8)"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
}

# Check if a default route (gateway to internet) exists
has_default_route() {
    if ip -4 route show default 2>/dev/null | grep -q "default"; then
        return 0
    fi
    if ip -6 route show default 2>/dev/null | grep -q "default"; then
        return 0
    fi
    return 1
}

# Get the interface that holds the default route
get_default_route_iface() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | sed -n '1s/.*dev \([^ ]*\).*/\1/p')
    if [[ -z "$iface" ]]; then
        iface=$(ip -6 route show default 2>/dev/null | sed -n '1s/.*dev \([^ ]*\).*/\1/p')
    fi
    echo "$iface"
}

# Check if any wired (non-wireless) interface has carrier (cable plugged in)
has_wired_link() {
    local iface_name carrier
    for iface in /sys/class/net/*/; do
        iface_name="${iface%/}"; iface_name="${iface_name##*/}"
        [[ "$iface_name" == "lo" ]] && continue
        [[ -d "/sys/class/net/${iface_name}/wireless" ]] && continue
        [[ ! -d "/sys/class/net/${iface_name}/device" ]] && continue
        carrier=$(cat "/sys/class/net/${iface_name}/carrier" 2>/dev/null || echo "0")
        if [[ "$carrier" == "1" ]]; then
            log_info "Wired interface ${iface_name} has carrier (link detected)."
            return 0
        fi
        log_info "Wired interface ${iface_name} present but no carrier."
    done
    return 1
}

# Check if any WiFi interface exists
get_wifi_interfaces() {
    local -a wifi_ifaces=()
    local iface_name _dir
    for iface in /sys/class/net/*/wireless; do
        [[ -e "$iface" ]] || continue
        _dir="${iface%/*}"; iface_name="${_dir##*/}"
        wifi_ifaces+=("$iface_name")
    done
    echo "${wifi_ifaces[@]}"
}

# Unblock WiFi via rfkill if blocked
unblock_wifi_rfkill() {
    if command -v rfkill &>/dev/null; then
        log_info "Unblocking WiFi via rfkill..."
        rfkill unblock wifi 2>/dev/null || true
    fi
}

# Wait for a default route to appear (internet connectivity)
wait_for_default_route() {
    local timeout="${1:-60}"
    local elapsed=0

    log_info "Waiting up to ${timeout}s for a default route..."
    while [[ $elapsed -lt $timeout ]]; do
        if has_default_route; then
            local gw_iface
            gw_iface=$(get_default_route_iface)
            log_info "Default route established via '${gw_iface}' after ${elapsed}s."
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_warn "Timed out waiting for a default route after ${timeout}s."
    return 1
}

# ---- Main logic ----

log_info "Starting network detection..."

# Detect what types of NM profiles are present in the initramfs
NM_CONN_DIR="/etc/NetworkManager/system-connections"
HAS_WIRED_PROFILE=0
HAS_WIFI_PROFILE=0
HAS_VLAN_PROFILE=0
if [ -d "$NM_CONN_DIR" ]; then
    for prof in "${NM_CONN_DIR}"/*.nmconnection; do
        [ -e "$prof" ] || continue
        if grep -q '^type=wifi' "$prof" 2>/dev/null; then
            HAS_WIFI_PROFILE=1
            log_info "Found WiFi NM profile: ${prof##*/}"
        elif grep -q '^type=vlan' "$prof" 2>/dev/null; then
            HAS_VLAN_PROFILE=1
            HAS_WIRED_PROFILE=1
            log_info "Found VLAN NM profile: ${prof##*/}"
        else
            HAS_WIRED_PROFILE=1
            log_info "Found wired/other NM profile: ${prof##*/}"
        fi
    done
fi

log_info "Profiles in initramfs: wired=${HAS_WIRED_PROFILE} wifi=${HAS_WIFI_PROFILE} vlan=${HAS_VLAN_PROFILE}"

# Step 1: Give NetworkManager a moment to activate connections
sleep 5

# Step 2: Check if NM already established a default route
if has_default_route; then
    gw_iface=$(get_default_route_iface)
    log_info "Default route already active via '${gw_iface}'. Network is ready."
    if command -v nmcli &>/dev/null; then
        log_info "Active NM connections:"
        nmcli -t -f NAME,DEVICE,TYPE connection show --active 2>/dev/null | while IFS=: read -r name dev type; do
            log_info "  ${name} on ${dev} (${type})"
        done
    fi
    _ensure_dns_ready
    exit 0
fi

log_info "No default route found yet."

# Step 3: If we have wired profiles, wait for wired to come up first
# VLANs need longer: parent interface UP → VLAN creation → IP configuration
if [ "$HAS_WIRED_PROFILE" -eq 1 ] && has_wired_link; then
    wired_timeout=30
    if [ "$HAS_VLAN_PROFILE" -eq 1 ]; then
        wired_timeout=60
        log_info "VLAN profile detected; allowing ${wired_timeout}s for parent + VLAN setup..."
    else
        log_info "Wired link detected and wired NM profile present. Waiting for NM to configure it..."
    fi
    if wait_for_default_route "$wired_timeout"; then
        _ensure_dns_ready
        exit 0
    fi
    log_warn "Wired link present but no default route after ${wired_timeout}s."
fi

# Step 4: If we have WiFi profiles (either copied from host or generated from WIFI_SSID),
# activate WiFi. This is the primary path when the host is WiFi-only.
if [ "$HAS_WIFI_PROFILE" -eq 1 ]; then
    WIFI_IFACES=$(get_wifi_interfaces)

    # USB WiFi adapters may not have been probed yet — wait for the interface to appear
    if [[ -z "$WIFI_IFACES" ]]; then
        log_info "WiFi profiles present but no WiFi interface yet — waiting for USB WiFi probe..."
        usb_wait=0
        while [[ $usb_wait -lt 30 ]]; do
            WIFI_IFACES=$(get_wifi_interfaces)
            [[ -n "$WIFI_IFACES" ]] && break
            sleep 2
            usb_wait=$((usb_wait + 2))
        done
        if [[ -n "$WIFI_IFACES" ]]; then
            log_info "WiFi interface(s) appeared after ${usb_wait}s: ${WIFI_IFACES}"
        fi
    fi

    if [[ -n "$WIFI_IFACES" ]]; then
        log_info "WiFi interface(s) found: ${WIFI_IFACES}. Activating WiFi..."
        unblock_wifi_rfkill
        sleep 2

        # Wait for wpa_supplicant to be reachable via D-Bus before asking NM to connect.
        # NM activates wpa_supplicant via D-Bus — if it's not ready, activation fails.
        wpa_wait=0
        while [[ $wpa_wait -lt 20 ]]; do
            if busctl status fi.w1.wpa_supplicant1 &>/dev/null 2>&1; then
                log_info "wpa_supplicant is available on D-Bus (after ${wpa_wait}s)"
                break
            fi
            # Fallback: check if the process is running
            if pgrep -x wpa_supplicant &>/dev/null; then
                log_info "wpa_supplicant process is running (after ${wpa_wait}s), giving it 3s to register on D-Bus..."
                sleep 3
                break
            fi
            sleep 2
            wpa_wait=$((wpa_wait + 2))
        done
        if [[ $wpa_wait -ge 20 ]]; then
            log_warn "wpa_supplicant not detected after 20s, attempting WiFi activation anyway..."
        fi

        # Give NM time to detect the WiFi device via wpa_supplicant and transition
        # from 'unavailable' to 'disconnected' before we attempt activation.
        nm_wifi_ready=0
        i=0
        while [[ $i -lt 15 ]]; do
            i=$((i + 1))
            nm_dev_state=$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep ':wifi:' | sed -n '1s/.*://p')
            if [[ "$nm_dev_state" == "disconnected" || "$nm_dev_state" == "connected" ]]; then
                log_info "NM WiFi device state: '${nm_dev_state}' (ready after ${i}s)"
                nm_wifi_ready=1
                break
            fi
            log_info "NM WiFi device state: '${nm_dev_state:-unknown}', waiting..."
            sleep 1
        done
        if [[ $nm_wifi_ready -eq 0 ]]; then
            log_warn "NM WiFi device not in 'disconnected' state after 15s, attempting activation anyway..."
        fi

        # Try to activate each WiFi profile found
        for prof in "${NM_CONN_DIR}"/*.nmconnection; do
            [ -e "$prof" ] || continue
            grep -q '^type=wifi' "$prof" 2>/dev/null || continue
            prof_id=$(sed -n 's/^id=//p' "$prof" 2>/dev/null | sed -n '1p')
            if [ -n "$prof_id" ]; then
                log_info "Activating WiFi profile '${prof_id}'..."
                nmcli connection up "$prof_id" 2>&1 || true
            fi
        done

        if wait_for_default_route 90; then
            log_info "Network is ready via WiFi."
            # Disable WiFi power save — the rtl88x2bu (and similar USB adapters) drop
            # incoming ICMP/ARP packets in power save mode, making the host unpingable.
            for _wif in $WIFI_IFACES; do
                if command -v iw &>/dev/null; then
                    iw dev "$_wif" set power_save off 2>/dev/null && \
                        log_info "Disabled power save on ${_wif}" || true
                fi

                # Fix kernel network sysctls for WiFi in the initramfs.
                # The initramfs minimal environment may have restrictive defaults
                # that prevent incoming ICMP (ping) from working on WiFi interfaces
                # while outbound traffic (cloudflared) works fine.
                if [ -d "/proc/sys/net/ipv4/conf/${_wif}" ]; then
                    # Disable reverse path filtering (strict mode drops
                    # packets on WiFi where the source routing doesn't match)
                    echo 0 > "/proc/sys/net/ipv4/conf/${_wif}/rp_filter" 2>/dev/null
                    echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null
                    # Ensure ARP replies go out on the WiFi interface
                    echo 0 > "/proc/sys/net/ipv4/conf/${_wif}/arp_filter" 2>/dev/null
                    echo 0 > "/proc/sys/net/ipv4/conf/${_wif}/arp_ignore" 2>/dev/null
                    log_info "Applied network sysctls for ${_wif}"
                fi
            done
            # Ensure ICMP echo is not globally disabled
            echo 0 > /proc/sys/net/ipv4/icmp_echo_ignore_all 2>/dev/null
            _ensure_dns_ready
            exit 0
        fi
        log_warn "WiFi profiles activated but no default route after 90s."
    else
        log_warn "WiFi profiles present but no WiFi hardware found."
    fi
fi

# Step 5: Last resort — if no default route yet but any link exists, wait longer
if has_wired_link; then
    log_info "Last resort: wired link exists, waiting 60s more for DHCP/static..."
    if wait_for_default_route 60; then
        _ensure_dns_ready
        exit 0
    fi
fi

log_error "Failed to establish a default route (internet access). Network may be unavailable."
exit 1
