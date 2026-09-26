# BeagleBone Black Networked Security Camera

A hardened, low-CPU home security camera appliance built on a **BeagleBone Black**, Debian 12, a USB UVC camera, Motion, FFmpeg, WireGuard, nftables, and systemd.

The project was designed around the BBB's limited AM335x CPU resources. Motion is the only process that opens `/dev/video0`; FFmpeg consumes Motion's local MJPEG stream and remuxes it into 30-second AVI segments with `-c:v copy`, avoiding a second video encode.

## Features

- 1280x720 @ 15 FPS camera capture
- Motion-triggered event recording
- Rolling 30-second segment buffer
- Up to ~6 minutes of pre-trigger coverage
- At least 6 minutes of post-trigger coverage
- Hard-link based event preservation to avoid duplicate video writes
- Recordings stored on a dedicated microSD filesystem
- Recorder refuses to fall back to eMMC when the recording filesystem is absent
- SSH and live stream restricted to WireGuard peers
- Default-drop nftables firewall with silent drops
- Fail2Ban using the systemd journal backend
- systemd sandboxing for recording/pruning services
- Automated age/size/free-space pruning
- Narrow camera-control wrapper for on/off/restart/status

## Tested hardware/software

- BeagleBone Black
- Debian 12 Bookworm / BeagleBoard image
- Linux 6.18.x BBB kernel family
- Microsoft LifeCam Cinema USB UVC camera (`045e:075d`)
- 32 GB microSD recording storage
- Ethernet networking

## Repository layout

```text
.
├── hardening/
│   ├── authorized_keys.control.example
│   ├── fail2ban-security-cam.local
│   ├── nftables.conf
│   ├── setup-hardening.sh
│   ├── sshd-security.conf
│   ├── sudoers-security-cam
│   └── sysctl-hardening.conf
├── motion/
│   └── motion.conf
├── security-cam/
│   ├── prune-saved-events.service
│   ├── prune-saved-events.sh
│   ├── prune-saved-events.timer
│   ├── save-event.sh
│   ├── security-cam-ctl
│   ├── security-cam-ssh-control
│   ├── segment-ring.service
│   └── segment-ring.sh
├── wireguard/
│   ├── bbb_wg0.conf.example
│   ├── computer_wg0.conf.example
│   ├── laptop_wg0.conf.example
│   └── phone_wg0.conf.example
├── .gitignore
├── CHANGELOG.md
└── README.md
```

# Architecture

```text
Microsoft LifeCam
      │
      ▼
   /dev/video0
      │
      ▼
    Motion                 Motion detection
      │                         │
      │ local MJPEG             ▼
      ├──────────────► save-event.sh
      │                         │
      ▼                         │ hard links
    FFmpeg                      ▼
      │              /var/lib/security-cam/saved_events/
      ▼
/var/lib/security-cam/ring/
```

The rolling buffer uses unique immutable segment filenames. The event collector only links completed segments, avoiding races with an actively written FFmpeg file.

## Event capture behavior

The ring retains 13 completed 30-second segments plus the currently open segment filename. On a motion trigger, the collector hard-links up to 12 completed pre-trigger segments into a timestamped event directory, then retains the current segment after it closes plus the next 12 completed segments. Because the trigger can occur anywhere inside the current segment, 13 post-trigger files guarantee at least six full minutes after the trigger. A later trigger during an active collection window extends that window.

Hard links are intentional: `ring/` and `saved_events/` must stay on the same filesystem. Removing an old ring filename does not remove an event copy while the event hard link still exists.

# Installation

Before running the installer, make sure SSH public-key authentication already works for the `debian` user. Keep an existing SSH session open while testing the hardened configuration from a second terminal.

Run:

```bash
sudo ./hardening/setup-hardening.sh
```

The installer installs and configures Motion, FFmpeg, WireGuard tools, nftables, Fail2Ban, `python3-systemd`, unattended upgrades, SSH hardening, the camera scripts, and systemd units.

It also creates `/var/log/motion` with permissions that allow the `motion` service to write its logfile.

## Recording storage

The intended recording filesystem is mounted at:

```text
/var/lib/security-cam
```

Example `/etc/fstab` entry:

```fstab
UUID=<YOUR_SD_FILESYSTEM_UUID> /var/lib/security-cam ext4 defaults,noatime,nofail 0 2
```

After mounting the card:

```bash
sudo mount -a
findmnt /var/lib/security-cam
```

**Do not continue unless `findmnt` shows the removable recording filesystem mounted there.**

Create/fix the recording directories after the filesystem is mounted:

```bash
sudo chown motion:motion /var/lib/security-cam
sudo chmod 750 /var/lib/security-cam
sudo install -d -o motion -g motion -m 0750 /var/lib/security-cam/ring
sudo install -d -o motion -g motion -m 0750 /var/lib/security-cam/saved_events
```

Verify Motion can write:

```bash
sudo -u motion touch /var/lib/security-cam/.write-test
sudo -u motion rm /var/lib/security-cam/.write-test
```

The ring writer, event collector, and pruning script additionally call `mountpoint` themselves and refuse to write if `/var/lib/security-cam` is not an actual mount point. This prevents a missing uSD from silently redirecting recordings to the eMMC.

# Camera control

Turn the camera stack on, off, restart it, or check status:

```bash
sudo /usr/local/sbin/security-cam-ctl status
sudo /usr/local/sbin/security-cam-ctl on
sudo /usr/local/sbin/security-cam-ctl off
sudo /usr/local/sbin/security-cam-ctl restart
```

Equivalent usage summary:

```bash
sudo /usr/local/sbin/security-cam-ctl {status|on|off|restart}
```

`off` stops Motion and the rolling-segment writer. The pruning timer is separate.

# Recording services

The three storage-related units are:

```text
motion.service
segment-ring.service
prune-saved-events.timer
```

To stop all recording/pruning activity:

```bash
sudo systemctl stop segment-ring.service motion.service prune-saved-events.timer
```

To start them again:

```bash
sudo systemctl start motion.service
sudo systemctl start segment-ring.service
sudo systemctl start prune-saved-events.timer
```

Check status:

```bash
systemctl --no-pager --full status \
  motion.service segment-ring.service prune-saved-events.timer
```

# Export saved events to a PC

For a consistent archive, stop camera writing and the pruning timer first:

```bash
sudo /usr/local/sbin/security-cam-ctl off
sudo systemctl stop prune-saved-events.timer
```

Create an **uncompressed tar** on the uSD. MJPEG/AVI footage is already compressed, so gzip/ZIP generally costs BBB CPU for little benefit.

```bash
sudo tar -cf /var/lib/security-cam/saved_events.tar \
  -C /var/lib/security-cam saved_events
```

Give the normal SSH user ownership of only the archive:

```bash
sudo chown debian:debian /var/lib/security-cam/saved_events.tar
sudo chmod 600 /var/lib/security-cam/saved_events.tar
```

The storage root is normally `0750 motion:motion`, so temporarily grant traversal permission without granting directory listing permission:

```bash
sudo chmod 751 /var/lib/security-cam
```

From **Windows PowerShell on the PC**, not from inside SSH:

```powershell
scp bbb:/var/lib/security-cam/saved_events.tar "$env:USERPROFILE\Videos\"
```

After confirming the transfer:

```bash
rm /var/lib/security-cam/saved_events.tar
sudo chmod 750 /var/lib/security-cam
sudo systemctl start prune-saved-events.timer
sudo /usr/local/sbin/security-cam-ctl on
```

# Clear saved events / rolling buffer

Stop all writers first:

```bash
sudo systemctl stop segment-ring.service motion.service prune-saved-events.timer
```

Check for active users of the recording directories:

```bash
sudo fuser -vm /var/lib/security-cam/saved_events /var/lib/security-cam/ring
```

A `root kernel mount /var/lib/security-cam` entry is normal. Motion/FFmpeg should not be listed before deleting recordings.

Delete **contents only**, preserving the directories themselves:

```bash
sudo find /var/lib/security-cam/saved_events \
  -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
```

Optionally clear the rolling buffer too:

```bash
sudo find /var/lib/security-cam/ring \
  -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
```

Verify the saved-event directory is empty:

```bash
sudo ls -la /var/lib/security-cam/saved_events
```

Restore expected ownership/permissions:

```bash
sudo chown motion:motion /var/lib/security-cam
sudo chown -R motion:motion /var/lib/security-cam/{ring,saved_events}
sudo chmod 750 /var/lib/security-cam /var/lib/security-cam/{ring,saved_events}
```

Restart:

```bash
sudo systemctl start motion.service
sudo systemctl start segment-ring.service
sudo systemctl start prune-saved-events.timer
```

# Storage checks

Check free space on the uSD:

```bash
df -h /var/lib/security-cam
```

Confirm the uSD is really mounted:

```bash
findmnt /var/lib/security-cam
```

Inspect usage:

```bash
sudo du -sh /var/lib/security-cam/ring
sudo du -sh /var/lib/security-cam/saved_events
```

Retention defaults live in:

```text
/etc/security-cam/storage.conf
```

Default values:

```text
MAX_EVENT_GIB=8
MAX_EVENT_AGE_DAYS=14
MIN_FREE_GIB=2
```

# WireGuard

The example topology is:

```text
BBB       10.10.10.1
Phone     10.10.10.2
Desktop   10.10.10.3
Laptop    10.10.10.4
```

On the BBB, a client peer contains the **client's public key**, the shared PSK, and that client's VPN address:

```ini
[Peer]
PublicKey = <CLIENT_PUBLIC_KEY>
PresharedKey = <SHARED_PSK>
AllowedIPs = 10.10.10.2/32
```

On the client, the peer contains the **BBB's public key**:

```ini
[Peer]
PublicKey = <BBB_PUBLIC_KEY>
PresharedKey = <SAME_SHARED_PSK>
Endpoint = <PUBLIC_IP_OR_DDNS>:51820
AllowedIPs = 10.10.10.1/32
```

Never commit real private keys or PSKs.

Check live WireGuard status:

```bash
sudo wg show
```

A working peer should show a recent handshake and nonzero transfer counts.

## Troubleshooting WireGuard traffic

Watch encrypted WireGuard packets arriving over Ethernet:

```bash
sudo tcpdump -ni eth0 udp port 51820
```

Watch decrypted VPN traffic:

```bash
sudo tcpdump -ni wg0
```

To exclude a known desktop LAN address while testing another peer:

```bash
sudo tcpdump -ni eth0 \
  'udp dst port 51820 and not src host <DESKTOP_LAN_IP>'
```

If the phone works when its endpoint is the BBB's LAN address but no packets reach `eth0` when the phone is on cellular, the problem is upstream of the BBB (router port forwarding, public endpoint/DDNS, or carrier/ISP NAT), not the WireGuard keys on the BBB.

# Firewall

View the live nftables rules:

```bash
sudo nft -a list ruleset
```

Validate the persistent configuration:

```bash
sudo nft -c -f /etc/nftables.conf
```

Reload it:

```bash
sudo nft -f /etc/nftables.conf
```

The input chain uses a default-drop policy. Unmatched traffic is silently counted and dropped; it is intentionally **not logged** to avoid continuous `dmesg`/journal writes on the eMMC.

# Camera / Motion diagnostics

Check the camera USB device:

```bash
lsusb
```

Expected LifeCam identifier:

```text
045e:075d Microsoft Corp. LifeCam Cinema
```

Check video-device permissions:

```bash
ls -l /dev/video0
id motion
```

Check supported camera formats if `v4l2-ctl` is installed:

```bash
v4l2-ctl --device=/dev/video0 --list-formats-ext
```

Recent logs:

```bash
journalctl -u motion.service -n 100 --no-pager
journalctl -u segment-ring.service -n 100 --no-pager
```

# microSD / MMC diagnostics

List storage:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
```

Check MMC-related kernel messages:

```bash
dmesg | grep -Ei 'mmc|sdhci'
```

The MMC host appearing as `mmc0` only confirms that the controller driver loaded. Successful card detection should also produce an `mmc0:<card>` device and `/dev/mmcblk0` (device numbering can differ by system).

# Security notes

- SSH password authentication is disabled by the provided hardening configuration.
- SSH and the live camera stream are allowed only from the WireGuard interface/subnet.
- Motion web control is localhost-only.
- Only UDP 51820 is intended to be exposed through a router when using direct WireGuard access.
- The camera-control sudo rule grants only the allow-listed control wrapper, not arbitrary `systemctl` access.
- Service scripts use a restrictive `umask`.
- The recorder refuses to use the eMMC as an accidental recording fallback.
- Firewall drop logging is disabled to reduce unnecessary journal writes.

# GitHub hygiene

Do **not** commit:

- WireGuard private keys
- WireGuard PSKs
- SSH private keys
- live `wg0.conf`
- `authorized_keys`
- recordings or exported archives

The included `.gitignore` blocks common secret/data filenames, but always inspect the staged diff before pushing:

```bash
git status
git diff --cached
```

# Quick health check

```bash
echo '=== CAMERA ==='
sudo /usr/local/sbin/security-cam-ctl status

echo '=== STORAGE ==='
findmnt /var/lib/security-cam
df -h /var/lib/security-cam

echo '=== WIREGUARD ==='
sudo wg show

echo '=== SERVICES ==='
systemctl --no-pager --full status \
  motion.service segment-ring.service prune-saved-events.timer
```

# Version history

See [`CHANGELOG.md`](CHANGELOG.md). This package incorporates the fixes discovered during deployment and hardware testing. Tailscale/ZeroTier were evaluated as possible NAT-traversal alternatives but are not part of the deployed configuration in this release.
