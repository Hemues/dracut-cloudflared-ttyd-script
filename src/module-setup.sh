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
    echo "systemd dbus systemd-resolved network-manager"
    return 0
}

# Helper: install WiFi dependencies (binaries, kernel modules, firmware)
_install_wifi_deps() {
    dinfo "dracut-cloudflared-ttyd: Including WiFi support (wpa_supplicant, drivers, firmware)"

    # Install NM WiFi plugin — without this NM treats WiFi devices as "Generic"
    # and will never attempt WiFi connections
    inst_multiple -o /usr/lib64/NetworkManager/*/libnm-device-plugin-wifi.so

    # Install wpa_supplicant and related binaries
    inst_multiple -o \
        /usr/sbin/wpa_supplicant \
        /usr/bin/wpa_cli \
        /usr/sbin/rfkill \
        /usr/sbin/iw

    # Install wpa_supplicant systemd service if present
    inst_multiple -o \
        "${systemdsystemunitdir}/wpa_supplicant.service" \
        "${systemdsystemunitdir}/wpa_supplicant@.service"

    # Install wpa_supplicant D-Bus activation file and policy — NM activates
    # wpa_supplicant via D-Bus (fi.w1.wpa_supplicant1). Without these files
    # NM fails with "Failed to D-Bus activate wpa_supplicant service".
    inst_multiple -o \
        /usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service \
        /etc/dbus-1/system.d/wpa_supplicant.conf \
        /usr/share/dbus-1/system.d/wpa_supplicant.conf

    # Ensure wpa_supplicant is started by NM when needed
    if [ -e "${systemdsystemunitdir}/wpa_supplicant.service" ]; then
        mkdir -p "${initdir}${systemdsystemunitdir}/wpa_supplicant.service.d"
        cat > "${initdir}${systemdsystemunitdir}/wpa_supplicant.service.d/initrd.conf" <<'SVCEOF'
[Unit]
DefaultDependencies=no
After=dbus.service dbus.socket
Before=NetworkManager.service

[Install]
WantedBy=sysinit.target
SVCEOF
        $SYSTEMCTL -q --root "$initdir" enable wpa_supplicant.service 2>/dev/null || true
    fi

    # Disable MAC randomization in the initramfs — random MACs cause
    # PREV_AUTH_NOT_VALID deauths on many access points.
    local nm_conf_dir="${initdir}/etc/NetworkManager/conf.d"
    mkdir -p "$nm_conf_dir"
    cat > "${nm_conf_dir}/dracut-wifi-stable-mac.conf" <<'NMCONF'
[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.cloned-mac-address=permanent
NMCONF
    dinfo "dracut-cloudflared-ttyd: Disabled WiFi MAC randomization in initramfs"

    # Set the WiFi regulatory domain — without this it defaults to WORLD which
    # blocks many 5GHz DFS channels, causing ASSOC-REJECT on those frequencies.
    local regdom
    regdom=$(iw reg get 2>/dev/null | sed -n 's/^country \([A-Z][A-Z]\):.*/\1/p' | sed -n '1p')
    if [ -z "$regdom" ]; then
        # Fallback: try to get from timezone-based config
        regdom=$(sed -n 's/^WIRELESS_REGDOM="\?\([A-Z][A-Z]\)"\?/\1/p' /etc/sysconfig/regdomain 2>/dev/null || true)
    fi
    if [ -n "$regdom" ] && [ "$regdom" != "00" ]; then
        dinfo "dracut-cloudflared-ttyd: Setting WiFi regulatory domain to '${regdom}'"
        mkdir -p "${initdir}/etc/modprobe.d"
        echo "options cfg80211 ieee80211_regdom=${regdom}" > "${initdir}/etc/modprobe.d/dracut-wifi-regdom.conf"
        # Also install CRDA/iw-based regdomain setting
        inst_multiple -o /usr/sbin/iw /usr/bin/iw
    fi

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

            # Include modules that load ON TOP of the WiFi driver (reverse deps).
            # Intel WiFi uses a split architecture: iwlwifi (PCI bus driver) +
            # iwlmvm (op-mode that creates the actual wlpXsY interface).
            # instmods only follows forward dependencies, so iwlmvm is missed.
            # Without it, iwlwifi detects hardware but no interface appears.
            #
            # We parse the kernel's modules.dep (not lsmod) so this works even
            # when the reverse-dep module is not currently loaded (e.g. broken
            # initramfs being rebuilt, or cross-kernel dracut --kver).
            local _rdep _rdeps="" _moddep
            _moddep="/lib/modules/${kernel}/modules.dep"
            if [ -f "$_moddep" ]; then
                while IFS= read -r _rdep; do
                    [ -z "$_rdep" ] && continue
                    dinfo "dracut-cloudflared-ttyd: Including WiFi reverse-dep '${_rdep}' (uses ${wifi_driver})"
                    instmods "$_rdep"
                    _rdeps="$_rdeps $_rdep"
                done < <(grep ":.*[/ ]${wifi_driver}\.ko" "$_moddep" | \
                         sed 's/:.*//; s|.*/||; s/\.ko\(\.xz\|\.gz\|\.zst\)\?$//')
            fi
        fi

        # Include firmware referenced by the WiFi driver, its reverse deps,
        # AND all their dependency modules.
        # USB WiFi drivers (e.g. rtw88_8822bu) are split: the bus-glue module may not
        # list firmware, but the chip-specific module (e.g. rtw88_8822b) does.
        if [ -n "$wifi_driver" ]; then
            local fw_file dep_mod
            # Collect firmware from the driver, its reverse deps, and all their dependencies
            local all_mods="$wifi_driver $_rdeps"
            local dep_mods
            dep_mods=$(modinfo -F depends "$wifi_driver" 2>/dev/null | tr ',' ' ')
            if [ -n "$dep_mods" ]; then
                all_mods="$all_mods $dep_mods"
                # Also check second-level dependencies (e.g. rtw88_8822b -> rtw88_core)
                for dep_mod in $dep_mods; do
                    local dep2
                    dep2=$(modinfo -F depends "$dep_mod" 2>/dev/null | tr ',' ' ')
                    [ -n "$dep2" ] && all_mods="$all_mods $dep2"
                done
            fi
            # Also scan dependencies of reverse-dep modules (e.g. iwlmvm -> mac80211)
            for dep_mod in $_rdeps; do
                local rdep_deps
                rdep_deps=$(modinfo -F depends "$dep_mod" 2>/dev/null | tr ',' ' ')
                [ -n "$rdep_deps" ] && all_mods="$all_mods $rdep_deps"
            done
            dinfo "dracut-cloudflared-ttyd: Checking firmware for modules: ${all_mods}"
            for dep_mod in $all_mods; do
                for fw_file in $(modinfo -F firmware "$dep_mod" 2>/dev/null); do
                    if [ -e "/lib/firmware/${fw_file}" ]; then
                        inst_simple "/lib/firmware/${fw_file}"
                        dinfo "dracut-cloudflared-ttyd: Including firmware '${fw_file}' (from ${dep_mod})"
                    fi
                done
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
    $SYSTEMCTL -q --root "$initdir" add-wants cryptsetup.target cloudflared.service

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
            dwarn "dracut-cloudflared-ttyd: No default gateway interface found, copying all profiles as fallback"
            # Check if WiFi hardware is present — if so, include WiFi profiles too
            local has_wifi_hw=0
            for _wif in /sys/class/net/*/wireless; do
                [ -e "$_wif" ] && has_wifi_hw=1 && break
            done
            local profile count=0
            for profile in "${nm_sys_conn_dir}"/*.nmconnection; do
                [ -e "$profile" ] || continue
                local prof_name
                prof_name=$(basename "$profile")
                if grep -q '^type=wifi' "$profile" 2>/dev/null; then
                    if [ "$has_wifi_hw" -eq 1 ]; then
                        inst_simple "$profile" "${nm_sys_conn_dir}/${prof_name}"
                        wifi_needed=1
                        count=$((count + 1))
                        dinfo "dracut-cloudflared-ttyd: Fallback — including WiFi profile '${prof_name}' (WiFi hardware present)"
                    fi
                    continue
                fi
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
                    # In fallback, skip WiFi unless gateway IS WiFi or WiFi hardware is present
                    if [ "$gw_is_wifi" -eq 0 ] && grep -q '^type=wifi' "$profile" 2>/dev/null; then
                        # Still include WiFi if hardware is present (for WiFi-only hosts)
                        local _has_wifi_hw=0
                        for _wif in /sys/class/net/*/wireless; do
                            [ -e "$_wif" ] && _has_wifi_hw=1 && break
                        done
                        if [ "$_has_wifi_hw" -eq 0 ]; then
                            continue
                        fi
                        wifi_needed=1
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

                    # Step 5: If VLAN, copy the parent interface profile and include VLAN kernel module
                    if [[ "$conn_type" == "vlan" ]]; then
                        dinfo "dracut-cloudflared-ttyd: Connection is type 'vlan', including 8021q kernel module"
                        instmods 8021q

                        local vlan_parent
                        vlan_parent=$(grep '^parent=' "$gw_profile_file" 2>/dev/null | head -1 | cut -d= -f2)
                        if [ -n "$vlan_parent" ]; then
                            dinfo "dracut-cloudflared-ttyd: VLAN parent reference: '${vlan_parent}'"
                            local parent_found=0
                            for profile in "${nm_sys_conn_dir}"/*.nmconnection; do
                                [ -e "$profile" ] || continue
                                # parent can be an interface name or a connection UUID
                                if grep -q "^interface-name=${vlan_parent}$" "$profile" 2>/dev/null || \
                                   grep -q "^uuid=${vlan_parent}$" "$profile" 2>/dev/null; then
                                    local pname
                                    pname=$(basename "$profile")
                                    inst_simple "$profile" "${nm_sys_conn_dir}/${pname}"
                                    dinfo "dracut-cloudflared-ttyd: Copied VLAN parent profile '${pname}'"
                                    parent_found=1

                                    # If the parent itself is a bond/bridge/team, also copy its member profiles
                                    local parent_conn_type
                                    parent_conn_type=$(grep '^type=' "$profile" 2>/dev/null | head -1 | cut -d= -f2)
                                    if [[ "$parent_conn_type" == "bond" || "$parent_conn_type" == "bridge" || "$parent_conn_type" == "team" ]]; then
                                        local parent_conn_id parent_if_name
                                        parent_conn_id=$(grep '^id=' "$profile" 2>/dev/null | head -1 | cut -d= -f2)
                                        parent_if_name=$(grep '^interface-name=' "$profile" 2>/dev/null | head -1 | cut -d= -f2)
                                        dinfo "dracut-cloudflared-ttyd: VLAN parent is type '${parent_conn_type}', looking for member profiles..."
                                        local member_profile member_name
                                        for member_profile in "${nm_sys_conn_dir}"/*.nmconnection; do
                                            [ -e "$member_profile" ] || continue
                                            if grep -qE "^(master|controller)=${parent_conn_id}$" "$member_profile" 2>/dev/null || \
                                               { [ -n "$parent_if_name" ] && grep -qE "^(master|controller)=${parent_if_name}$" "$member_profile" 2>/dev/null; }; then
                                                member_name=$(basename "$member_profile")
                                                inst_simple "$member_profile" "${nm_sys_conn_dir}/${member_name}"
                                                dinfo "dracut-cloudflared-ttyd: Copied VLAN parent's member profile '${member_name}'"
                                            fi
                                        done
                                    fi
                                    break
                                fi
                            done
                            if [ "$parent_found" -eq 0 ]; then
                                dwarn "dracut-cloudflared-ttyd: Could not find parent profile for VLAN parent '${vlan_parent}'"
                            fi
                        else
                            dwarn "dracut-cloudflared-ttyd: VLAN profile has no parent= field"
                        fi
                    fi
                else
                    dwarn "dracut-cloudflared-ttyd: Could not find profile file for '${gw_conn_name}', copying fallback profiles"
                    for profile in "${nm_sys_conn_dir}"/*.nmconnection; do
                        [ -e "$profile" ] || continue
                        if [ "$gw_is_wifi" -eq 0 ] && grep -q '^type=wifi' "$profile" 2>/dev/null; then
                            # Still include WiFi if hardware is present
                            local _has_wifi_hw=0
                            for _wif in /sys/class/net/*/wireless; do
                                [ -e "$_wif" ] && _has_wifi_hw=1 && break
                            done
                            if [ "$_has_wifi_hw" -eq 0 ]; then
                                continue
                            fi
                            wifi_needed=1
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

        # ---- Stabilize the host WiFi MAC to match initramfs ----
        # The initramfs uses cloned-mac-address=permanent (dracut-wifi-stable-mac.conf)
        # to prevent PREV_AUTH_NOT_VALID deauths. If the host's WiFi profile uses a
        # randomized MAC (Fedora default), the DHCP server sees two different clients
        # and assigns different IPs for initramfs vs real OS.
        # Fix: set cloned-mac-address=permanent on the host WiFi profile(s) that are
        # included in the initramfs, so both environments present the same MAC.
        local _wifi_prof _wifi_id _cur_mac
        for _wifi_prof in "${nm_sys_conn_dir}"/*.nmconnection; do
            [ -e "$_wifi_prof" ] || continue
            grep -q '^type=wifi' "$_wifi_prof" 2>/dev/null || continue
            # Only update profiles that were copied into the initramfs
            [ -e "${nm_initrd_dir}/$(basename "$_wifi_prof")" ] || continue
            _wifi_id=$(sed -n 's/^id=//p' "$_wifi_prof" 2>/dev/null | sed -n '1p')
            if [ -n "$_wifi_id" ]; then
                _cur_mac=$(nmcli -g 802-11-wireless.cloned-mac-address connection show "$_wifi_id" 2>/dev/null)
                if [ "$_cur_mac" != "permanent" ]; then
                    dinfo "dracut-cloudflared-ttyd: Setting cloned-mac-address=permanent on host WiFi profile '${_wifi_id}' (was '${_cur_mac:-default/random}')"
                    nmcli connection modify "$_wifi_id" wifi.cloned-mac-address permanent 2>/dev/null || true
                fi
            fi
        done
        # Also ensure the WIFI_SSID-based profile on the host uses stable MAC
        if [ -n "${WIFI_SSID:-}" ]; then
            _cur_mac=$(nmcli -g 802-11-wireless.cloned-mac-address connection show "$WIFI_SSID" 2>/dev/null || true)
            if [ -n "$_cur_mac" ] && [ "$_cur_mac" != "permanent" ]; then
                dinfo "dracut-cloudflared-ttyd: Setting cloned-mac-address=permanent on host WiFi '${WIFI_SSID}'"
                nmcli connection modify "$WIFI_SSID" wifi.cloned-mac-address permanent 2>/dev/null || true
            fi
        fi
    fi

    # ---- Always install the network detection script and service ----
    # This handles: waiting for default route, wired vs WiFi fallback,
    # multi-NIC default gateway selection at boot time
    inst_simple "$moddir/dracut-cloudflared-ttyd-net-detect.sh" /usr/bin/dracut-cloudflared-ttyd-net-detect.sh
    inst_simple "$moddir/dracut-cloudflared-ttyd-net-detect.service" "${systemdsystemunitdir}"/dracut-cloudflared-ttyd-net-detect.service
    $SYSTEMCTL -q --root "$initdir" add-wants cryptsetup.target dracut-cloudflared-ttyd-net-detect.service

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
