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
    iface=$(ip -4 route show default 2>/dev/null | head -1 | sed -n 's/.*dev \([^ ]*\).*/\1/p')
    if [[ -z "$iface" ]]; then
        iface=$(ip -6 route show default 2>/dev/null | head -1 | sed -n 's/.*dev \([^ ]*\).*/\1/p')
    fi
    echo "$iface"
}

# Check if any wired (non-wireless) interface has carrier (cable plugged in)
has_wired_link() {
    local iface_name carrier
    for iface in /sys/class/net/*/; do
        iface_name=$(basename "$iface")
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
    local iface_name
    for iface in /sys/class/net/*/wireless; do
        [[ -e "$iface" ]] || continue
        iface_name=$(basename "$(dirname "$iface")")
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
if [ -d "$NM_CONN_DIR" ]; then
    for prof in "${NM_CONN_DIR}"/*.nmconnection; do
        [ -e "$prof" ] || continue
        if grep -q '^type=wifi' "$prof" 2>/dev/null; then
            HAS_WIFI_PROFILE=1
            log_info "Found WiFi NM profile: $(basename "$prof")"
        else
            HAS_WIRED_PROFILE=1
            log_info "Found wired/other NM profile: $(basename "$prof")"
        fi
    done
fi

log_info "Profiles in initramfs: wired=${HAS_WIRED_PROFILE} wifi=${HAS_WIFI_PROFILE}"

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
    exit 0
fi

log_info "No default route found yet."

# Step 3: If we have wired profiles, wait for wired to come up first
if [ "$HAS_WIRED_PROFILE" -eq 1 ] && has_wired_link; then
    log_info "Wired link detected and wired NM profile present. Waiting for NM to configure it..."
    if wait_for_default_route 30; then
        exit 0
    fi
    log_warn "Wired link present but no default route after 30s."
fi

# Step 4: If we have WiFi profiles (either copied from host or generated from WIFI_SSID),
# activate WiFi. This is the primary path when the host is WiFi-only.
if [ "$HAS_WIFI_PROFILE" -eq 1 ]; then
    WIFI_IFACES=$(get_wifi_interfaces)
    if [[ -n "$WIFI_IFACES" ]]; then
        log_info "WiFi interface(s) found: ${WIFI_IFACES}. Activating WiFi..."
        unblock_wifi_rfkill
        sleep 2

        # Try to activate each WiFi profile found
        for prof in "${NM_CONN_DIR}"/*.nmconnection; do
            [ -e "$prof" ] || continue
            grep -q '^type=wifi' "$prof" 2>/dev/null || continue
            prof_id=$(grep '^id=' "$prof" 2>/dev/null | head -1 | cut -d= -f2)
            if [ -n "$prof_id" ]; then
                log_info "Activating WiFi profile '${prof_id}'..."
                nmcli connection up "$prof_id" 2>&1 || true
            fi
        done

        if wait_for_default_route 90; then
            log_info "Network is ready via WiFi."
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
        exit 0
    fi
fi

log_error "Failed to establish a default route (internet access). Network may be unavailable."
exit 1
