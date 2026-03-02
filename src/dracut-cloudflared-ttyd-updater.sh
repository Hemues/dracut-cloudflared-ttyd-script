#!/usr/bin/bash
# dracut-cloudflared-ttyd-updater.sh
# Checks for cloudflared binary updates and rebuilds initramfs if updated.
#
# cloudflared update exit codes (from upstream source):
#   0  - Already up to date, no action needed
#   11 - Successfully updated to a new version
#   10 - Update failed
#
# SPDX-License-Identifier: MIT

set -euo pipefail

CLOUDFLARED_BIN="/usr/share/dracut-cloudflared-ttyd/cloudflared"
LOGPREFIX="dracut-cloudflared-ttyd-updater"

log_info()  { echo "${LOGPREFIX}: $*"; logger -t "${LOGPREFIX}" -p daemon.info  "$*" 2>/dev/null || true; }
log_error() { echo "${LOGPREFIX}: ERROR: $*" >&2; logger -t "${LOGPREFIX}" -p daemon.err "$*" 2>/dev/null || true; }

# Remove old kernels, keeping only the running kernel and the previous one.
# This frees up space in /boot before rebuilding the initramfs.
cleanup_old_kernels() {
    local running_kernel
    running_kernel=$(uname -r)
    log_info "Running kernel: ${running_kernel}"

    # Get all installed kernel packages sorted by version (oldest first)
    # rpm -q kernel --queryformat gives us version-release.arch entries
    local -a all_kernels
    mapfile -t all_kernels < <(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V)

    local total=${#all_kernels[@]}
    if [[ ${total} -le 2 ]]; then
        log_info "Only ${total} kernel(s) installed, no cleanup needed."
        return 0
    fi

    # Find the index of the running kernel
    local running_idx=-1
    for i in "${!all_kernels[@]}"; do
        if [[ "${all_kernels[$i]}" == "${running_kernel}" ]]; then
            running_idx=$i
            break
        fi
    done

    if [[ ${running_idx} -eq -1 ]]; then
        log_error "Running kernel ${running_kernel} not found in installed kernel list. Skipping cleanup."
        return 0
    fi

    # Determine which kernel is "previous" (the one right before running in sorted order)
    local prev_idx=-1
    if [[ ${running_idx} -gt 0 ]]; then
        prev_idx=$((running_idx - 1))
    fi

    # Build the list of kernels to remove (everything except running and previous)
    local -a to_remove
    for i in "${!all_kernels[@]}"; do
        if [[ $i -ne ${running_idx} ]] && [[ $i -ne ${prev_idx} ]]; then
            to_remove+=("kernel-${all_kernels[$i]}")
        fi
    done

    if [[ ${#to_remove[@]} -eq 0 ]]; then
        log_info "No old kernels to remove."
        return 0
    fi

    log_info "Removing ${#to_remove[@]} old kernel(s): ${to_remove[*]}"
    if dnf remove -y "${to_remove[@]}" 2>&1; then
        log_info "Old kernels removed successfully."
    else
        log_error "Failed to remove some old kernels. Continuing anyway."
    fi
}

# Detect if the network gateway has changed since the last dracut -f.
# module-setup.sh saves a fingerprint in /etc/dracut-cloudflared-ttyd/gateway.env
# with the interface name, NM connection name, and type (wired/wifi) that was
# used when the initramfs was last built.
gateway_changed() {
    local saved_fp="/etc/dracut-cloudflared-ttyd/gateway.env"
    if [[ ! -f "$saved_fp" ]]; then
        log_info "No saved gateway fingerprint found — will rebuild."
        return 0
    fi

    # Read saved values
    local saved_iface="" saved_conn="" saved_type=""
    # shellcheck disable=SC1090
    source "$saved_fp" 2>/dev/null
    saved_iface="${GW_IFACE:-}"
    saved_conn="${GW_CONN:-}"
    saved_type="${GW_TYPE:-}"

    # Determine current gateway
    local cur_iface cur_type
    cur_iface=$(ip -4 route show default 2>/dev/null | head -1 | sed -n 's/.*dev \([^ ]*\).*/\1/p')
    if [[ -z "$cur_iface" ]]; then
        cur_iface=$(ip -6 route show default 2>/dev/null | head -1 | sed -n 's/.*dev \([^ ]*\).*/\1/p')
    fi
    cur_type="wired"
    [[ -n "$cur_iface" ]] && [[ -d "/sys/class/net/${cur_iface}/wireless" ]] && cur_type="wifi"

    if [[ "$saved_iface" != "$cur_iface" ]] || [[ "$saved_type" != "$cur_type" ]]; then
        log_info "Gateway changed: was ${saved_type}/${saved_iface}, now ${cur_type}/${cur_iface}"
        return 0
    fi

    return 1
}

# Verify the binary exists
if [[ ! -x "${CLOUDFLARED_BIN}" ]]; then
    log_error "cloudflared binary not found or not executable at ${CLOUDFLARED_BIN}"
    exit 1
fi

# Record current version for logging
CURRENT_VERSION=$("${CLOUDFLARED_BIN}" version 2>/dev/null || echo "unknown")
log_info "Current cloudflared version: ${CURRENT_VERSION}"

# Attempt the update
# We need to capture the exit code without 'set -e' killing us
set +e
UPDATE_OUTPUT=$("${CLOUDFLARED_BIN}" update 2>&1)
UPDATE_EXIT_CODE=$?
set -e

log_info "Update command output: ${UPDATE_OUTPUT}"
log_info "Update command exit code: ${UPDATE_EXIT_CODE}"

case ${UPDATE_EXIT_CODE} in
    0)
        # Already up to date — but check if network gateway changed
        log_info "cloudflared is already up to date."
        if gateway_changed; then
            log_info "Network gateway has changed since last initramfs build. Rebuilding..."
            cleanup_old_kernels
            if dracut -f; then
                log_info "initramfs rebuilt successfully (gateway change)."
            else
                log_error "dracut -f failed during gateway-change rebuild!"
                exit 1
            fi
        else
            log_info "Gateway unchanged. No initramfs rebuild needed."
        fi
        ;;
    11)
        # Successfully updated
        NEW_VERSION=$("${CLOUDFLARED_BIN}" version 2>/dev/null || echo "unknown")
        log_info "cloudflared updated successfully: ${CURRENT_VERSION} -> ${NEW_VERSION}"

        # Store the new version info
        "${CLOUDFLARED_BIN}" version > /usr/share/dracut-cloudflared-ttyd/cloudflared.version 2>/dev/null || true

        # Clean up old kernels before rebuilding to ensure enough space in /boot
        cleanup_old_kernels

        # Rebuild the initramfs so the new binary is included at next boot
        log_info "Rebuilding initramfs with dracut -f ..."
        if dracut -f; then
            log_info "initramfs rebuilt successfully."
        else
            log_error "dracut -f failed! The initramfs may contain the old cloudflared binary."
            exit 1
        fi
        ;;
    10)
        # Update failed
        log_error "cloudflared update failed (exit code 10): ${UPDATE_OUTPUT}"
        exit 1
        ;;
    *)
        # Unexpected exit code
        log_error "cloudflared update returned unexpected exit code ${UPDATE_EXIT_CODE}: ${UPDATE_OUTPUT}"
        exit 1
        ;;
esac

exit 0
