# BeagleBone Black Networked Security Camera

A hardened home security camera appliance built around a **BeagleBone Black** (BBB), a **USB UVC webcam**, and Debian Linux (version 12, v6.18.x).

The system provides:

- 720p live camera streaming @ 15fps
- Motion-triggered recording
- Rolling video buffering
- Six-minute post-trigger event capture
- Recording directly to removable microSD (uSD) storage
- Remote administration over encrypted WireGuard VPN
- SSH access restricted to trusted VPN peers
- nftables firewalling
- systemd-managed camera and recording services
- Automatic saved-event pruning and storage limits
- Hardened service permissions and filesystem access

The project was designed around the BeagleBone Black's limited AM335x CPU resources, so the video pipeline avoids unnecessary transcoding wherever possible.

---

## Hardware

Development hardware:

- BeagleBone Black
- Microsoft LifeCam Cinema USB webcam
- 32 GB uSD card for video storage
- Ethernet network connection

Camera configuration:

- Resolution: `1280x720`
- Frame rate: `15 FPS`
- Camera format: hardware MJPEG

The operating system and application stack run from the BBB's onboard eMMC, while camera recordings are written to the uSD card.

---

## Software

The appliance uses:

- Debian 12 Bookworm
- Motion
- FFmpeg
- WireGuard
- OpenSSH
- nftables
- fail2ban
- systemd
- Bash

---

# Architecture

The camera device is owned by Motion:

```text
USB Camera
    |
    v
 Motion
    |
    +---- Live MJPEG stream
    |
    +---- Motion detection
              |
              v
       Event collection
```

A separate FFmpeg process reads Motion's local MJPEG stream and maintains a rolling collection of video segments:

```text
Motion MJPEG stream
        |
        v
      FFmpeg
        |
        v
/var/lib/security-cam/ring/
```

When Motion detects activity, the event collector preserves recent pre-trigger segments and continues collecting video for at least six minutes after the event trigger.

Saved events are stored under:

```text
/var/lib/security-cam/saved_events/
```

The `/var/lib/security-cam` filesystem is mounted from removable storage so video recording does not consume the BBB's small eMMC filesystem.

---

# Security Model

The appliance is configured with a default-deny firewall. External access is intended to occur only through WireGuard.

After setting up WireGuard, the default VPN addresses are:

```text
BBB:           10.10.10.1
Computer 1:    10.10.10.2
Computer 2:    10.10.10.3
Computer 3:    10.10.10.4
```

SSH and the live camera stream are restricted to authenticated VPN peers.

The Motion control interface remains localhost-only.

---

# Project Layout

Repository layout:

```text
.
├── hardening/
│   ├── nftables.conf
│   ├── setup-hardening.sh
│   ├── sshd-security.conf
│   ├── sudoers-security-cam
│   └── sysctl-hardening.conf
│
├── motion/
│   └── motion.conf
│
├── security-cam/
│   ├── prune-saved-events.service
│   ├── prune-saved-events.sh
│   ├── prune-saved-events.timer
│   ├── save-event.sh
│   ├── security-cam-ctl
│   ├── security-cam-ssh-control
│   ├── segment-ring.service
│   └── segment-ring.sh
│
└── wireguard/
    ├── bbb_wg0.conf.example
    ├── computer_wg0.conf.example
    ├── laptop_wg0.conf.example
    └── phone_wg0.conf.example
```

---

# Camera Control

The main camera control utility is:

```bash
sudo /usr/local/sbin/security-cam-ctl {status|on|off|restart}
```

`status` reports the state of the segment-ring and motion.

`off` stops the camera/recording services.

`on` brings the camera system back online.

`restart` does what you expect it to.

---

# Recording Services

The primary recording-related services are:

```text
motion.service
segment-ring.service
prune-saved-events.timer
```

To stop/start all writing to the uSD card:

```bash
sudo systemctl {stop/start} segment-ring.service motion.service prune-saved-events.timer
```

Check service status:

```bash
systemctl --no-pager --full status \
  motion.service \
  segment-ring.service \
  prune-saved-events.timer
```

---

# Check Camera Status

If debugging, using systemctl status plainly provides additional systemd status information:

```bash
systemctl status motion
systemctl status segment-ring
```

Recent Motion logs:

```bash
journalctl -u motion -n 100 --no-pager
```

Recent rolling-buffer logs:

```bash
journalctl -u segment-ring -n 100 --no-pager
```

---

# Check Storage Space

Check free space on the recording uSD:

```bash
df -h /var/lib/security-cam
```

Inspect storage, saved-event, and ring buffer usage:

```bash
sudo du -h -d1 /var/lib/security-cam
sudo du -sh /var/lib/security-cam/saved_events
sudo du -sh /var/lib/security-cam/ring
```

Confirm that the recording filesystem is actually mounted:

```bash
findmnt /var/lib/security-cam
```

---

# Export Saved Events to a PC

The event files are owned by the restricted `motion` account, so the easiest export method is to create an archive on the uSD and copy that archive over SSH.

## 1. Stop camera activity

```bash
sudo /usr/local/sbin/security-cam-ctl off
```

This prevents event files from changing while the archive is being created.

---

## 2. Create an archive on the uSD

```bash
sudo tar -cf /var/lib/security-cam/saved_events.tar \
  -C /var/lib/security-cam saved_events
```

MJPEG video is already compressed, so an uncompressed `.tar` is preferred over gzip or ZIP on the BBB's limited CPU. Processing may take a few minutes depending on how many files were saved.

Check the archive:

```bash
sudo ls -lh /var/lib/security-cam/saved_events.tar
```

Optionally inspect its contents:

```bash
sudo tar -tf /var/lib/security-cam/saved_events.tar | head
```

---

## 3. Make the archive accessible to the SSH user

Assign ownership of the archive to the normal Debian user:

```bash
sudo chown debian:debian /var/lib/security-cam/saved_events.tar
sudo chmod 600 /var/lib/security-cam/saved_events.tar
```

The storage root is normally:

motion:motion
0750

so temporarily allow directory traversal:

```bash
sudo chmod 751 /var/lib/security-cam
```

Don't change the perms of `~/saved_events/` itself.

---

## 4. Copy to Windows

Run this from Windows PowerShell, (not from the SSH session):

```powershell
scp bbb:/var/lib/security-cam/saved_events.tar "$env:USERPROFILE\Videos\"
```

The `bbb` hostname may be defined on Windows, in the user folder:

```text
~/.ssh/config
```

For example:

```text
Host bbb
    HostName 10.10.10.1
    User debian
    IdentityFile ~/.ssh/bbb_security_cam
    PasswordAuthentication no
```

---

## 5. Restore permissions

After confirming that the archive copied successfully:

```bash
rm /var/lib/security-cam/saved_events.tar
sudo chmod 750 /var/lib/security-cam
```

Restart the camera:

```bash
sudo /usr/local/sbin/security-cam-ctl on
```

---

# Clearing Saved Events

If the saved recordings are no longer needed, stop all writers before deleting them.

## 1. Stop recording services

```bash
sudo systemctl stop segment-ring.service motion.service prune-saved-events.timer
```

---

## 2. Confirm nothing is writing

```bash
sudo fuser -vm \
  /var/lib/security-cam/saved_events \
  /var/lib/security-cam/ring
```

A result similar to:

```text
root   kernel   mount   /var/lib/security-cam
```

is normal because the uSD filesystem itself is mounted there. There should not be active Motion or FFmpeg processes using those directories.

---

## 3. Remove saved events

Use `find` so hidden files and directories are also handled:

```bash
sudo find /var/lib/security-cam/saved_events \
  -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
```

Verify:

```bash
sudo ls -la /var/lib/security-cam/saved_events
```

Nothing should remain other than the folder itself.

---

## 4. Optionally clear the rolling buffer

```bash
sudo find /var/lib/security-cam/ring \
  -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
```

---

## 5. Restore ownership and permissions

```bash
sudo chown motion:motion \
  /var/lib/security-cam/ring \
  /var/lib/security-cam/saved_events
```

```bash
sudo chmod 750 \
  /var/lib/security-cam/ring \
  /var/lib/security-cam/saved_events \
  /var/lib/security-cam
```

---

## 6. Restart recording

```bash
sudo systemctl start motion.service
sudo systemctl start segment-ring.service
sudo systemctl start prune-saved-events.timer
```

Check for errors:

```bash
systemctl --no-pager --full status motion segment-ring
```

---

# WireGuard

Check WireGuard status:

```bash
sudo wg show
```

A functioning peer should show:

```text
latest handshake: ...
transfer: ... received, ... sent
```

Check the BBB interface:

```bash
ip addr show wg0
```

Port forwarding, UPnP, or a VPS may be needed to connect off-network devices to the BBB (due to things like CGNAT and typical default firewall rules). Default listening port is 51820.
---

# Debugging Remote WireGuard Traffic

To verify that WireGuard packets are reaching the BBB:

```bash
sudo tcpdump -ni eth0 udp port 51820
```

To inspect decrypted VPN traffic:

```bash
sudo tcpdump -ni wg0
```

To exclude a known LAN desktop from the packet capture:

```bash
sudo tcpdump -ni eth0 \
  'udp dst port 51820 and not src host DESKTOP_LAN_IP'
```

If packets reach `eth0` but `wg show` never reports a handshake, check WireGuard keys and peer configuration.

If no packets reach `eth0`, investigate router port forwarding, the public IP/DDNS endpoint, or upstream NAT. A good test for this is to put that device on the same LAN as the BBB and see if it connects to the BBB without issues.

---

# nftables

View the firewall:

```bash
sudo nft list ruleset
```

Validate the persistent configuration:

```bash
sudo nft -c -f /etc/nftables.conf
```

Reload it:

```bash
sudo nft -f /etc/nftables.conf
```

The firewall uses a default-drop input policy.

The final drop rule intentionally does not log rejected traffic in order to avoid unnecessary journal/eMMC writes:

```text
counter drop
```

---

# SSH

SSH is configured for public-key authentication.

Example Windows SSH key generation:

```powershell
ssh-keygen -t ed25519 -a 100 -f "$env:USERPROFILE\.ssh\bbb_security_cam"
```

Highly recommended to add a password to the key. Assuming the SSH key was generated on Windows as shown above, this creates:

```text
bbb_security_cam       # Private key — keep this on the PC
bbb_security_cam.pub   # Public key — copy this to the BBB
```

You must share the generated .pub to the BBB. While password-based SSH access to the BBB is still available, run this from PowerShell (change BBB-IP accordingly):

```powershell
Get-Content "$env:USERPROFILE\.ssh\bbb_security_cam.pub" |
ssh debian@<BBB-IP> 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'
```

Then test public-key authentication:

```powershell
ssh -i "$env:USERPROFILE\.ssh\bbb_security_cam" -o PasswordAuthentication=no debian@10.10.10.1
```

If the key has a passphrase, SSH will prompt for the **SSH key passphrase**, not the BBB user's password.

Once this succeeds, the BBB can safely be configured to disable password-based SSH authentication.
Example connection:

```powershell
ssh bbb
```

Once you run the hardening script, SSH access is intended to be available only through pre-trusted VPN peers. 
Don't close the SSH session if youre doubtful it was setup correctly, as you would have to use a serial COM connection (through SW like PuTTY, Tera Term) to fix this, with the BBB plugged directly into your Windows PC.

---

# Camera Device Debugging

List video devices:

```bash
ls -l /dev/video*
```

Check camera USB detection:

```bash
lsusb
```

For the Microsoft LifeCam Cinema:

```text
1234:abcd Microsoft Corp. LifeCam Cinema
```

Inspect supported formats (replace /dev/video0 to your reported camera endpoint if required):

```bash
v4l2-ctl --device=/dev/video0 --list-formats-ext
```

Check Motion's access:

```bash
id motion
```

The `motion` user should have access to the `video` group.

---

# uSD Debugging

List storage devices:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
```

Check MMC-related kernel messages:

```bash
dmesg | grep -Ei 'mmc|sdhci'
```

nft-drop may spam the log. Use this to clear the output then restart, checking for "mmc0"/"blk0" (mmc1 is typically the eMMC):

```bash
sudo dmesg -C
sudo restart now
```

Confirm the security-camera filesystem:

```bash
findmnt /var/lib/security-cam
```

---

# Storage Retention

Saved-event pruning is controlled through:

```text
/etc/security-cam/storage.conf
```

Example:

```text
MAX_EVENT_GIB=8
MAX_EVENT_AGE_DAYS=14
MIN_FREE_GIB=2
```

The pruning service periodically removes old recordings according to these limits.

Check timer status:

```bash
systemctl status prune-saved-events.timer
```

List upcoming timer runs:

```bash
systemctl list-timers prune-saved-events.timer
```

---

# Important Paths

```text
*Configuration:
/etc/motion/motion.conf
/etc/nftables.conf
/etc/security-cam/storage.conf
/etc/wireguard/wg0.conf

/opt/security-cam/

*Camera control:
/usr/local/sbin/security-cam-ctl

*Video storage:
/var/lib/security-cam/ring/
/var/lib/security-cam/saved_events/
```

---

# Useful Health Check

For a quick system check:

```bash
echo "=== CAMERA ==="
sudo /usr/local/sbin/security-cam-ctl status

echo "=== STORAGE ==="
findmnt /var/lib/security-cam
df -h /var/lib/security-cam

echo "=== WIREGUARD ==="
sudo wg show

echo "=== SERVICES ==="
systemctl --no-pager --full status \
  motion \
  segment-ring \
  prune-saved-events.timer
```

---

# Design Goals

The project prioritizes:

1. Low CPU usage
2. Minimal eMMC writes
3. Automatic recording to removable storage when motion is detected
4. Secure, hardened remote access
5. No publicly exposed camera or SSH interfaces
6. Automatic recovery after reboot
7. Service isolation using systemd
8. Simple maintenance through standard Linux utilities

The result is a compact embedded Linux security-camera appliance built almost entirely from standard open-source Linux components.