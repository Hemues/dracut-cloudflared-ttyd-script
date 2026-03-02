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
- in `/etc/default/grub` add `ip=dhcp rd.neednet=1` to `GRUB_CMDLINE_LINUX`
- rebuild the grub entries: `grub2-mkconfig -o /boot/grub2/grub.cfg`
- edit `/etc/sysconfig/dracut-cloudflared-ttyd` and add your `TUNNEL_TOKEN` acquired in the prerequisites
- rebuild the initram: `dracut -f`
- after reboot, when the device password is prompted, you can access the prompt from the URL added on Cloudflare
