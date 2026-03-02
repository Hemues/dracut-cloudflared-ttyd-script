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
    # This module has external dependencies on the systemd and dbus modules.
    echo systemd dbus systemd-resolved network-manager
    # Return 0 to include the dependent modules in the initramfs.
    return 0
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
}
