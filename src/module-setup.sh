#!/usr/bin/bash
# This file is part of dracut-cloudflare-ttyd.
# SPDX-License-Identifier: MIT

# Prerequisite check(s) for module.
check() {
    # check the existence of the config file
    [ -e /etc/sysconfig/dracut-cloudflared-ttyd ] || return 1
    set -a
    source /etc/sysconfig/dracut-cloudflared-ttyd
    set +a
    # verify that the user has configured a tunnel already
    [ ! -z ${TUNNEL_TOKEN} ] || return 1

    # If the binary(s) requirements are not fulfilled the module can't be installed
    require_binaries \
        /usr/share/dracut-cloudflared-ttyd/ttyd \
        /usr/share/dracut-cloudflared-ttyd/cloudflared \
        || return 1
}

# Module dependency requirements.
depends() {
    local deps="systemd dbus systemd-resolved network-manager"

    set -a
    source /etc/sysconfig/dracut-cloudflared-ttyd 2>/dev/null
    set +a

    # Check if WiFi will be needed: either WIFI_SSID is set, or the default
    # gateway is currently on a wireless interface
    local need_wifi=0
    if [ -n "${WIFI_SSID:-}" ]; then
        need_wifi=1
    else
        local gw_iface
        gw_iface=$(ip -4 route show default 2>/dev/null | head -1 | sed -n 's/.*dev \([^ ]*\).*/\1/p')
        if [ -n "$gw_iface" ] && [ -d "/sys/class/net/${gw_iface}/wireless" ]; then
            need_wifi=1
        fi
    fi

    if [ "$need_wifi" -eq 1 ]; then
        deps="$deps wlan"
    fi

    echo $deps
    return 0
}

# Helper: install WiFi dependencies (binaries, kernel modules, firmware)
_install_wifi_deps() {
    dinfo "dracut-cloudflared-ttyd: Including WiFi support (wpa_supplicant, drivers, firmware)"

    # Install wpa_supplicant and related binaries
    inst_multiple -o \
        /usr/sbin/wpa_supplicant \
        /usr/bin/wpa_cli \
        /usr/sbin/rfkill

    # Install wpa_supplicant systemd service if present
    inst_multiple -o \
        "${systemdsystemunitdir}/wpa_supplicant.service" \
        "${systemdsystemunitdir}/wpa_supplicant@.service"

    # Install WiFi kernel modules: generic wireless stack
    instmods cfg80211 mac80211 rfkill

    # Detect WiFi hardware on the build host and include its specific driver + firmware
    local wifi_driver
    for wif in /sys/class/net/*/wireless; do
        [ -e "$wif" ] || continue
        local ifname
        ifname=$(basename "$(dirname "$wif")")
        wifi_driver=$(basename "$(readlink -f "/sys/class/net/${ifname}/device/driver/module")" 2>/dev/null || true)
        if [ -n "$wifi_driver" ]; then
            dinfo "dracut-cloudflared-ttyd: Including WiFi driver '${wifi_driver}' for interface '${ifname}'"
            instmods "$wifi_driver"
        fi

        # Include firmware referenced by the WiFi device via modinfo
        if [ -n "$wifi_driver" ]; then
            local fw_file
            for fw_file in $(modinfo -F firmware "$wifi_driver" 2>/dev/null); do
                if [ -e "/lib/firmware/${fw_file}" ]; then
                    inst_simple "/lib/firmware/${fw_file}"
                    dinfo "dracut-cloudflared-ttyd: Including firmware '${fw_file}'"
                fi
            done
        fi
    done
}

# Install the required file(s) for the module in the initramfs.
install() {
    # shellcheck disable=SC2064
    trap "$(shopt -p globstar)" RETURN
    shopt -q -s globstar
    local -a var_lib_files

    inst /usr/share/dracut-cloudflared-ttyd/ttyd /usr/bin/ttyd
    inst /usr/share/dracut-cloudflared-ttyd/cloudflared /usr/bin/cloudflared

    inst_simple "$moddir/cloudflared.service" "${systemdsystemunitdir}"/cloudflared.service
    inst_simple "$moddir/ttyd.service" "${systemdsystemunitdir}"/ttyd.service

    $SYSTEMCTL -q --root "$initdir" add-wants cryptsetup.target ttyd.service

    mkdir -p "$initdir/etc/sysconfig"
    inst /etc/sysconfig/dracut-cloudflared-ttyd

    # Track whether we need WiFi support in the initramfs
    local wifi_needed=0

    # ---- Copy the default-gateway NetworkManager connection profile into initramfs ----
    # When multiple connections are active, we identify which one carries the
    # default route (internet access) and only include that profile. This ensures
    # the tunnel is built through the correct interface.
    # If the default gateway is on WiFi, we copy that WiFi profile and include
    # all WiFi dependencies automatically — no need to set WIFI_SSID separately.
    local nm_sys_conn_dir="/etc/NetworkManager/system-connections"
    local nm_initrd_dir="${initdir}${nm_sys_conn_dir}"
    mkdir -p "$nm_initrd_dir"

    if [ -d "$nm_sys_conn_dir" ]; then
        # Step 1: Find the interface that holds the default route
        local gw_iface
        gw_iface=$(ip -4 route show default 2>/dev/null | head -1 | sed -n 's/.*dev \([^ ]*\).*/\1/p')
        if [ -z "$gw_iface" ]; then
            gw_iface=$(ip -6 route show default 2>/dev/null | head -1 | sed -n 's/.*dev \([^ ]*\).*/\1/p')
        fi

        # Check if the default gateway interface is wireless
        local gw_is_wifi=0
        if [ -n "$gw_iface" ] && [ -d "/sys/class/net/${gw_iface}/wireless" ]; then
            gw_is_wifi=1
            wifi_needed=1
            dinfo "dracut-cloudflared-ttyd: Default gateway is on WiFi interface '${gw_iface}'"
        fi

        if [ -z "$gw_iface" ]; then
            dwarn "dracut-cloudflared-ttyd: No default gateway interface found, copying all wired profiles as fallback"
            local profile count=0
            for profile in "${nm_sys_conn_dir}"/*.nmconnection; do
                [ -e "$profile" ] || continue
                local prof_name
                prof_name=$(basename "$profile")
                grep -q '^type=wifi' "$profile" 2>/dev/null && continue
                inst_simple "$profile" "${nm_sys_conn_dir}/${prof_name}"
                count=$((count + 1))
            done
            dinfo "dracut-cloudflared-ttyd: Fallback — copied ${count} NM profile(s) into initramfs"
        else
            dinfo "dracut-cloudflared-ttyd: Default gateway is on interface '${gw_iface}'"

            # Step 2: Find the NM connection name active on that interface
            local gw_conn_name
            gw_conn_name=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | \
                           awk -F: -v dev="$gw_iface" '$NF == dev {print substr($0, 1, length($0)-length($NF)-1); exit}')

            if [ -z "$gw_conn_name" ]; then
                dwarn "dracut-cloudflared-ttyd: Could not determine NM connection for '${gw_iface}', copying all profiles"
                for profile in "${nm_sys_conn_dir}"/*.nmconnection; do
                    [ -e "$profile" ] || continue
                    local prof_name
                    prof_name=$(basename "$profile")
                    # In fallback, skip WiFi unless gateway IS WiFi
                    if [ "$gw_is_wifi" -eq 0 ] && grep -q '^type=wifi' "$profile" 2>/dev/null; then
                        continue
                    fi
                    inst_simple "$profile" "${nm_sys_conn_dir}/${prof_name}"
                done
            else
                dinfo "dracut-cloudflared-ttyd: Default gateway connection: '${gw_conn_name}' on '${gw_iface}'"

                # Step 3: Find and copy the profile file for this connection
                local gw_profile_file=""
                local profile prof_name
                for profile in "${nm_sys_conn_dir}"/*.nmconnection; do
                    [ -e "$profile" ] || continue
                    prof_name=$(basename "$profile")
                    if grep -q "^id=${gw_conn_name}$" "$profile" 2>/dev/null; then
                        gw_profile_file="$profile"
                        break
                    fi
                done

                if [ -z "$gw_profile_file" ]; then
                    for profile in "${nm_sys_conn_dir}"/*.nmconnection; do
                        [ -e "$profile" ] || continue
                        if grep -q "^interface-name=${gw_iface}$" "$profile" 2>/dev/null; then
                            gw_profile_file="$profile"
                            break
                        fi
                    done
                fi

                if [ -n "$gw_profile_file" ]; then
                    prof_name=$(basename "$gw_profile_file")
                    inst_simple "$gw_profile_file" "${nm_sys_conn_dir}/${prof_name}"
                    dinfo "dracut-cloudflared-ttyd: Copied default gateway profile '${prof_name}'"

                    local conn_type
                    conn_type=$(grep '^type=' "$gw_profile_file" 2>/dev/null | head -1 | cut -d= -f2)

                    # Step 4: If bond/bridge/team, copy member profiles
                    if [[ "$conn_type" == "bond" || "$conn_type" == "bridge" || "$conn_type" == "team" ]]; then
                        dinfo "dracut-cloudflared-ttyd: Connection is type '${conn_type}', looking for member profiles..."
                        local slave_profile slave_name
                        for slave_profile in "${nm_sys_conn_dir}"/*.nmconnection; do
                            [ -e "$slave_profile" ] || continue
                            if grep -qE "^(master|controller)=${gw_conn_name}$" "$slave_profile" 2>/dev/null || \
                               grep -qE "^(master|controller)=${gw_iface}$" "$slave_profile" 2>/dev/null; then
                                slave_name=$(basename "$slave_profile")
                                inst_simple "$slave_profile" "${nm_sys_conn_dir}/${slave_name}"
                                dinfo "dracut-cloudflared-ttyd: Copied member profile '${slave_name}'"
                            fi
                        done
                    fi

                    # Step 5: If VLAN, copy the parent interface profile
                    if [[ "$conn_type" == "vlan" ]]; then
                        local parent_iface
                        parent_iface=$(grep '^parent=' "$gw_profile_file" 2>/dev/null | head -1 | cut -d= -f2)
                        if [ -n "$parent_iface" ]; then
                            for profile in "${nm_sys_conn_dir}"/*.nmconnection; do
                                [ -e "$profile" ] || continue
                                if grep -q "^interface-name=${parent_iface}$" "$profile" 2>/dev/null; then
                                    local pname
                                    pname=$(basename "$profile")
                                    inst_simple "$profile" "${nm_sys_conn_dir}/${pname}"
                                    dinfo "dracut-cloudflared-ttyd: Copied VLAN parent profile '${pname}'"
                                    break
                                fi
                            done
                        fi
                    fi
                else
                    dwarn "dracut-cloudflared-ttyd: Could not find profile file for '${gw_conn_name}', copying fallback profiles"
                    for profile in "${nm_sys_conn_dir}"/*.nmconnection; do
                        [ -e "$profile" ] || continue
                        if [ "$gw_is_wifi" -eq 0 ] && grep -q '^type=wifi' "$profile" 2>/dev/null; then
                            continue
                        fi
                        inst_simple "$profile" "${nm_sys_conn_dir}/$(basename "$profile")"
                    done
                fi
            fi
        fi
    else
        dwarn "dracut-cloudflared-ttyd: No NetworkManager system-connections directory found"
    fi

    # ---- WiFi SSID override / fallback profile (from sysconfig) ----
    set -a
    source /etc/sysconfig/dracut-cloudflared-ttyd
    set +a

    if [ -n "${WIFI_SSID:-}" ]; then
        wifi_needed=1
        dinfo "dracut-cloudflared-ttyd: WIFI_SSID set, generating fallback WiFi profile (SSID: ${WIFI_SSID})"

        local nm_conn_dir="${initdir}/etc/NetworkManager/system-connections"
        mkdir -p "$nm_conn_dir"

        local wifi_security="${WIFI_SECURITY:-wpa-psk}"
        local wifi_hidden="${WIFI_HIDDEN:-false}"

        # Use low autoconnect-priority so the gateway profile (if wired) takes precedence.
        # If the gateway IS WiFi and was already copied above, this acts as an extra fallback.
        cat > "${nm_conn_dir}/dracut-wifi.nmconnection" <<NMWIFI
[connection]
id=dracut-wifi
type=wifi
autoconnect=true
autoconnect-priority=-1

[wifi]
ssid=${WIFI_SSID}
mode=infrastructure
hidden=${wifi_hidden}
NMWIFI

        [ -n "${WIFI_BAND:-}" ] && echo "band=${WIFI_BAND}" >> "${nm_conn_dir}/dracut-wifi.nmconnection"
        [ -n "${WIFI_BSSID:-}" ] && echo "bssid=${WIFI_BSSID}" >> "${nm_conn_dir}/dracut-wifi.nmconnection"

        cat >> "${nm_conn_dir}/dracut-wifi.nmconnection" <<NMWIFI

[wifi-security]
key-mgmt=${wifi_security}
psk=${WIFI_PSK}

[ipv4]
method=auto

[ipv6]
method=auto
NMWIFI

        chmod 600 "${nm_conn_dir}/dracut-wifi.nmconnection"
    fi

    # ---- Include WiFi dependencies if any WiFi profile will be in the initramfs ----
    if [ "$wifi_needed" -eq 1 ]; then
        _install_wifi_deps
    fi

    # ---- Always install the network detection script and service ----
    # This handles: waiting for default route, wired vs WiFi fallback,
    # multi-NIC default gateway selection at boot time
    inst_simple "$moddir/dracut-cloudflared-ttyd-net-detect.sh" /usr/bin/dracut-cloudflared-ttyd-net-detect.sh
    inst_simple "$moddir/dracut-cloudflared-ttyd-net-detect.service" "${systemdsystemunitdir}"/dracut-cloudflared-ttyd-net-detect.service
    $SYSTEMCTL -q --root "$initdir" add-wants basic.target dracut-cloudflared-ttyd-net-detect.service

    # ---- Save a gateway fingerprint so the updater can detect network changes ----
    local fingerprint_dir="${initdir}/etc/dracut-cloudflared-ttyd"
    mkdir -p "$fingerprint_dir"
    local fp_iface fp_conn fp_type
    fp_iface=$(ip -4 route show default 2>/dev/null | head -1 | sed -n 's/.*dev \([^ ]*\).*/\1/p')
    fp_conn=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | \
              awk -F: -v dev="$fp_iface" '$NF == dev {print substr($0, 1, length($0)-length($NF)-1); exit}')
    fp_type="wired"
    [ -n "$fp_iface" ] && [ -d "/sys/class/net/${fp_iface}/wireless" ] && fp_type="wifi"
    echo "GW_IFACE=${fp_iface}" > "${fingerprint_dir}/gateway.env"
    echo "GW_CONN=${fp_conn}" >> "${fingerprint_dir}/gateway.env"
    echo "GW_TYPE=${fp_type}" >> "${fingerprint_dir}/gateway.env"
    # Also keep a copy on the host filesystem for the updater to compare against
    mkdir -p /etc/dracut-cloudflared-ttyd
    cp "${fingerprint_dir}/gateway.env" /etc/dracut-cloudflared-ttyd/gateway.env
    dinfo "dracut-cloudflared-ttyd: Gateway fingerprint: iface=${fp_iface} conn=${fp_conn} type=${fp_type}"

    dinfo "dracut-cloudflared-ttyd: Module installation complete (wifi_needed=${wifi_needed})"
}
