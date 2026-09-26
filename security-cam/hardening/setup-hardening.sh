#!/bin/bash
# Install the hardened security-camera stack on Debian 12 / BBB.
# Run as root from this project directory. Before running this script,
# confirm that at least one SSH key works for the debian account.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

require_root() {
    if (( EUID != 0 )); then
        echo "Run this script as root." >&2
        exit 1
    fi
}

require_root

if [[ ! -s /home/debian/.ssh/authorized_keys ]]; then
    echo "Refusing SSH hardening: /home/debian/.ssh/authorized_keys is missing or empty." >&2
    exit 1
fi

echo "== Installing packages =="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    motion ffmpeg wireguard-tools nftables fail2ban python3-systemd unattended-upgrades

echo "== Creating service users/storage =="
id motion >/dev/null 2>&1 || { echo "motion user not found after package install" >&2; exit 1; }
install -d -o motion -g motion -m 0750 /var/lib/security-cam
install -d -o motion -g motion -m 0750 /var/lib/security-cam/ring
install -d -o motion -g motion -m 0750 /var/lib/security-cam/saved_events
# Motion writes its own logfile here. Debian's package does not necessarily
# create this directory with permissions suitable for the motion service.
install -d -o motion -g motion -m 0750 /var/log/motion
install -d -o root -g root -m 0755 /opt/security-cam
install -d -o root -g root -m 0755 /etc/security-cam

cat >/etc/security-cam/storage.conf <<'STORAGE'
# Recording retention limits. Tune these for the size of the installed uSD.
# The minimum-free-space floor is an independent safety net.
MAX_EVENT_GIB=8
MAX_EVENT_AGE_DAYS=14
MIN_FREE_GIB=2
STORAGE
chmod 0644 /etc/security-cam/storage.conf

install -o root -g root -m 0644 "$PROJECT_ROOT/motion/motion.conf" /etc/motion/motion.conf
install -o root -g root -m 0755 "$PROJECT_ROOT/security-cam/segment-ring.sh" /opt/security-cam/segment-ring.sh
install -o root -g root -m 0755 "$PROJECT_ROOT/security-cam/save-event.sh" /opt/security-cam/save-event.sh
install -o root -g root -m 0755 "$PROJECT_ROOT/security-cam/prune-saved-events.sh" /opt/security-cam/prune-saved-events.sh
install -o root -g root -m 0755 "$PROJECT_ROOT/security-cam/security-cam-ctl" /usr/local/sbin/security-cam-ctl
install -o root -g root -m 0755 "$PROJECT_ROOT/security-cam/security-cam-ssh-control" /usr/local/sbin/security-cam-ssh-control

# Motion owns the footage and ring directories; root owns executables.
# If removable storage is already mounted here, these permissions are applied
# to that filesystem. If it is mounted later, re-run the documented storage
# permission commands after mounting it.
chown motion:motion /var/lib/security-cam
chown -R motion:motion /var/lib/security-cam/ring /var/lib/security-cam/saved_events
chmod 0750 /var/lib/security-cam /var/lib/security-cam/ring /var/lib/security-cam/saved_events

if ! mountpoint -q /var/lib/security-cam; then
    echo "WARNING: /var/lib/security-cam is not a separate mounted filesystem." >&2
    echo "The recorder scripts will refuse to write until removable storage is mounted there." >&2
fi

install -o root -g root -m 0644 "$PROJECT_ROOT/security-cam/segment-ring.service" /etc/systemd/system/segment-ring.service
install -o root -g root -m 0644 "$PROJECT_ROOT/security-cam/prune-saved-events.service" /etc/systemd/system/prune-saved-events.service
install -o root -g root -m 0644 "$PROJECT_ROOT/security-cam/prune-saved-events.timer" /etc/systemd/system/prune-saved-events.timer

install -o root -g root -m 0644 "$PROJECT_ROOT/hardening/nftables.conf" /etc/nftables.conf
install -o root -g root -m 0644 "$PROJECT_ROOT/hardening/sysctl-hardening.conf" /etc/sysctl.d/99-security-cam.conf
install -o root -g root -m 0644 "$PROJECT_ROOT/hardening/sshd-security.conf" /etc/ssh/sshd_config.d/90-security-cam.conf
install -o root -g root -m 0440 "$PROJECT_ROOT/hardening/sudoers-security-cam" /etc/sudoers.d/security-cam
install -o root -g root -m 0644 "$PROJECT_ROOT/hardening/fail2ban-security-cam.local" /etc/fail2ban/jail.d/security-cam.local

# Validate first; don't deliberately leave the box with a malformed firewall
# or SSH configuration.
echo "== Validating configuration =="
nft -c -f /etc/nftables.conf
/usr/sbin/sshd -t
visudo -cf /etc/sudoers.d/security-cam

# Apply kernel settings.
sysctl --system

# Apply firewall and services.
systemctl enable --now nftables
nft -f /etc/nftables.conf
systemctl enable --now fail2ban
systemctl enable --now unattended-upgrades
systemctl disable --now cockpit.socket cockpit.service 2>/dev/null || true
systemctl disable --now avahi-daemon.socket avahi-daemon.service 2>/dev/null || true
systemctl disable --now bluetooth.service 2>/dev/null || true

auto_update_note=""

# Validate and reload SSH rather than restarting it. A second existing SSH
# session should still be kept open while you test the key from another host.
systemctl reload ssh

echo "== Motion / ring services =="
systemctl daemon-reload
systemctl enable motion.service segment-ring.service prune-saved-events.timer
systemctl start motion.service
systemctl start segment-ring.service
systemctl start prune-saved-events.timer

# One immediate retention pass keeps an old installation from consuming the
# entire card while the new service is being enabled.
/opt/security-cam/prune-saved-events.sh || true

# Verify the kernel has WireGuard available.
if ! modprobe wireguard 2>/dev/null; then
    echo "WARNING: modprobe wireguard failed. Check the BBB vendor kernel/package support before relying on WireGuard." >&2
fi

cat <<'INFO'

== Installation complete ==

Camera control:
  sudo /usr/local/sbin/security-cam-ctl on
  sudo /usr/local/sbin/security-cam-ctl off
  sudo /usr/local/sbin/security-cam-ctl status

Remote access policy:
  - WireGuard UDP 51820 is the only WAN service exposed here.
  - SSH and the camera stream are accepted only from 10.10.10.0/24 on wg0.
  - Motion webcontrol is localhost-only.

Before relying on this host remotely, test a NEW SSH connection using your
key from each of the three WireGuard peers while keeping the existing session
open as a rollback path.
INFO
