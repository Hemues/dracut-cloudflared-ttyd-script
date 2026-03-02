%define dracutlibdir %{_prefix}/lib/dracut
%global _missing_build_ids_terminate_build 0
%define _builddate %( date "+%%Y%%m%%d" )
%if 0%{?_auto_tool_versions}
%define _ttyd_version %(%{_sourcedir}/ttyd.x86_64 --version | cut -d' ' -f3- | sed 's/-/_/g')
%define _cfd_version %(%{_sourcedir}/cloudflared-linux-amd64 version -s)
%else
%define _ttyd_version unknown
%define _cfd_version unknown
%endif
Name:           dracut-cloudflared-ttyd
Version:        0.0.4
Release:        %autorelease -b %{_builddate} -e ttyd_%{_ttyd_version}_cf_%{_cfd_version}
Summary:        Creates configuration for dracut to include a web tty and cloudflared
Group:          System
ExclusiveArch:  x86_64

Source:         dracut-cloudflared-ttyd-%{version}.tar.gz
%define         sourcename %{Source}
%define  debug_package %{nil}

License:        Mixed
URL:            https://github.com/tamisoft/dracut-cloudflared-ttyd.git
%if 0%{?fedora} < 40
%define wget_progress --show-progress
%else
# Fedora 40 moved to wget2, with different command line options
%define wget_progress --force-progress
%endif
BuildRequires: wget
BuildRequires: gpg
BuildRequires: rpm-sign
BuildRequires: rpm-build
BuildRequires: coreutils
BuildRequires: sed

Requires:       dracut
Requires:       dracut-network
Requires:       grub2-tools
Requires:       grubby
Requires:       grep
Requires:       systemd
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
Recommends:     wpa_supplicant
Recommends:     NetworkManager-wifi

%description
This dracut module provides integration of the cloudflared and ttyd into the initram. This allow the user
to unlock luks encrypted devices remotely from a browser when the systemd-ask-password is prompting for it.

%prep
[ ! -e "$RPM_SOURCE_DIR" ] && mkdir -p "$RPM_SOURCE_DIR"
[ ! -e "$RPM_SOURCE_DIR/ttyd.x86_64" ] && wget -nc -q %{wget_progress} -O "$RPM_SOURCE_DIR/ttyd.x86_64" https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 && chmod +x "$RPM_SOURCE_DIR/ttyd.x86_64"
[ ! -e "$RPM_SOURCE_DIR/cloudflared-linux-amd64" ] && wget -nc -q %{wget_progress} -O "$RPM_SOURCE_DIR/cloudflared-linux-amd64" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && chmod +x "$RPM_SOURCE_DIR/cloudflared-linux-amd64"
[ ! -e "$RPM_SOURCE_DIR/%{SOURCEURL0}" ] && wget -nc -q %{wget_progress} -O "$RPM_SOURCE_DIR/%{SOURCEURL0}" https://github.com/tamisoft/dracut-cloudflared-ttyd/archive/refs/tags/%{version}.tar.gz
%setup -q

%install
mkdir -p %{buildroot}%{_datadir}/%{name}
install -Dm755 $RPM_SOURCE_DIR/ttyd.x86_64 %{buildroot}%{_datadir}/%{name}/ttyd
%{buildroot}%{_datadir}/%{name}/ttyd --version >%{buildroot}%{_datadir}/%{name}/ttyd.version
install -Dm755 $RPM_SOURCE_DIR/cloudflared-linux-amd64 %{buildroot}%{_datadir}/%{name}/cloudflared
%{buildroot}%{_datadir}/%{name}/cloudflared version >%{buildroot}%{_datadir}/%{name}/cloudflared.version
install -Dm755 src/module-setup.sh %{buildroot}%{dracutlibdir}/modules.d/50cloudflared-ttyd/module-setup.sh
install -Dm644 src/cloudflared.service %{buildroot}%{dracutlibdir}/modules.d/50cloudflared-ttyd/cloudflared.service
install -Dm644 src/ttyd.service %{buildroot}%{dracutlibdir}/modules.d/50cloudflared-ttyd/ttyd.service
install -Dm640 src/dracut-cloudflared-ttyd %{buildroot}%{_sysconfdir}/sysconfig/dracut-cloudflared-ttyd
install -Dm755 src/dracut-cloudflared-ttyd-updater.sh %{buildroot}%{_datadir}/%{name}/dracut-cloudflared-ttyd-updater.sh
install -Dm644 src/dracut-cloudflared-ttyd-updater.service %{buildroot}%{_unitdir}/dracut-cloudflared-ttyd-updater.service
install -Dm644 src/dracut-cloudflared-ttyd-updater.timer %{buildroot}%{_unitdir}/dracut-cloudflared-ttyd-updater.timer
install -Dm755 src/dracut-cloudflared-ttyd-net-detect.sh %{buildroot}%{dracutlibdir}/modules.d/50cloudflared-ttyd/dracut-cloudflared-ttyd-net-detect.sh
install -Dm644 src/dracut-cloudflared-ttyd-net-detect.service %{buildroot}%{dracutlibdir}/modules.d/50cloudflared-ttyd/dracut-cloudflared-ttyd-net-detect.service

%files
%{_datadir}/%{name}/*
%{dracutlibdir}/modules.d/50cloudflared-ttyd/*
%{_unitdir}/dracut-cloudflared-ttyd-updater.service
%{_unitdir}/dracut-cloudflared-ttyd-updater.timer
%config(noreplace) %{_sysconfdir}/sysconfig/dracut-cloudflared-ttyd
%license LICENSE

%post
# Enable and start the daily updater timer
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now dracut-cloudflared-ttyd-updater.timer >/dev/null 2>&1 || true

if [ $1 -gt 1 ] ; then
    echo "*******************************************************"
    echo "Upgrading previous version... cleaning old kernels"
    echo "*******************************************************"
    # Keep only running kernel + previous, remove the rest
    RUNNING_KERN=$(uname -r)
    mapfile -t ALL_KERNS < <(rpm -q kernel --queryformat '%%{VERSION}-%%{RELEASE}.%%{ARCH}\n' 2>/dev/null | sort -V)
    TOTAL=${#ALL_KERNS[@]}
    if [ "$TOTAL" -gt 2 ]; then
        RUNNING_IDX=-1
        for i in "${!ALL_KERNS[@]}"; do
            [ "${ALL_KERNS[$i]}" = "$RUNNING_KERN" ] && RUNNING_IDX=$i && break
        done
        if [ "$RUNNING_IDX" -ge 0 ]; then
            PREV_IDX=-1
            [ "$RUNNING_IDX" -gt 0 ] && PREV_IDX=$((RUNNING_IDX - 1))
            REMOVE_LIST=()
            for i in "${!ALL_KERNS[@]}"; do
                [ "$i" -ne "$RUNNING_IDX" ] && [ "$i" -ne "$PREV_IDX" ] && REMOVE_LIST+=("kernel-${ALL_KERNS[$i]}")
            done
            if [ ${#REMOVE_LIST[@]} -gt 0 ]; then
                echo "Removing old kernels: ${REMOVE_LIST[*]}"
                dnf remove -y "${REMOVE_LIST[@]}" 2>&1 || true
            fi
        fi
    fi
    echo "*******************************************************"
    echo "Rebuilding initramfs..."
    echo "*******************************************************"
    dracut -f
else
    echo "*******************************************************"
    echo "Edit /etc/sysconfig/dracut-cloudflared-ttyd file first."
    echo "*******************************************************"
    echo "Checking for neccessary kernel arguments..."
    if [ -e /etc/default/grub ]; then
        if ! grep -qe "[ \"]rd.neednet=1" /etc/default/grub ; then
            echo "Adding rd.neednet=1 to kernel arguments..."
            grubby --update-kernel=ALL --args="rd.neednet=1"
        fi
        # Remove legacy ip=dhcp if present — NM profiles handle networking now
        if grep -qe "[ \"]ip=dhcp" /etc/default/grub ; then
            echo "Removing ip=dhcp from kernel arguments (NetworkManager profiles are used instead)..."
            grubby --update-kernel=ALL --remove-args="ip=dhcp" || true
        fi
        echo "Done. If you'll customize /etc/default/grub, don't"
        echo "forget to run grub2-mkconfig -o /boot/grub2/grub.cfg"
    else
        echo "No /etc/default/grub found. Please update grub manually."
    fi
    echo "*******************************************************"
    if [ -e /boot/grub2/grub.cfg ]; then
        echo "Updating grub2 configuration..."
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 >/dev/null || true
    else
        echo "No /boot/grub2/grub.cfg found. Please update grub manually."
    fi
fi

%preun
if [ $1 -eq 0 ] ; then
    # Package removal, not upgrade
    systemctl disable --now dracut-cloudflared-ttyd-updater.timer >/dev/null 2>&1 || true
    systemctl stop dracut-cloudflared-ttyd-updater.service >/dev/null 2>&1 || true
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || true

%changelog
* Sun Mar 02 2026 GitHub Copilot - 0.0.4
- copy host NM connection profiles into initramfs (supports DHCP, static IP, VLAN, bond, etc.)
- remove ip=dhcp kernel parameter requirement — NetworkManager handles networking
- add WiFi support: automatic wired/wireless network detection in initramfs
- add daily cloudflared auto-updater service and timer
- rebuild initramfs automatically when cloudflared is updated
* Web Jan 22 2024 Levente Tamas <levi@tamisoft.com> - 0.0.4
- fix missing build dependencies
- add automatic kernel argument check
- add post install message
- add grub2-mkconfig call

* Thu Dec 26 2024 Levente Tamas <levi@tamisoft.com> - 0.0.3
- disable rpm debug_package

* Tue Feb 13 2024 Levente Tamas <levi@tamisoft.com> - 0.0.4
- initial release.
