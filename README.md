# BeagleBone Black Networked Security Camera

A hardened home security camera application built around a BeagleBone Black (BBB), a USB UVC-compliant webcam, and Debian (version 12, v6.18.x).

It provides:

- 720p live camera streaming @ 15fps
- Motion-triggered recording, 6-minute post-trigger event capture
- Recording directly to removable microSD (uSD)
- Remote administration over WireGuard, SSH restricted to WireGuard VPN peers
- nftables firewalling / [fail2ban](https://github.com/fail2ban/fail2ban) setup
- systemd-managed camera and recording services
- Auto saved event pruning and storage limits

The project was designed to run on limited resources, so video processing is avoided whenever possible.

For installation and initial configuration, see the project's setup guide.

**---**

## Hardware

Developed with:

- BeagleBone Black
- Microsoft LifeCam Cinema USB webcam
- 32 GB uSD card for video storage
- Ethernet network connection

Camera configuration:

- Resolution: `1280x720`
- Frame rate: `15 FPS`
- Camera format: hardware MJPG

The OS and application stack run from the BBB's onboard eMMC, while camera recordings are written to the uSD card.

**---**

## Software

This setup uses:

- [Debian 12 from BeagleBoard](https://www.beagleboard.org/distros/beaglebone-black-debian-12-15-2026-09-20-iot-v6-18-x)
- [Motion](https://motion-project.github.io/)
- [FFmpeg](https://ffmpeg.org/download.html)
- [WireGuard](https://www.wireguard.com/install/)
- [OpenSSH](https://www.openssh.org/)
- [nftables](https://wiki.nftables.org/wiki-nftables/index.php/Main_Page)
- [fail2ban](https://github.com/fail2ban/fail2ban)

**---**

# Architecture

The camera device is owned by Motion, which handles the video stream and motion detection.
A separate FFmpeg process reads Motion's local MJPG stream and maintains a rolling collection of 30-second video segments.
When Motion detects activity, the event collector preserves recent pre-trigger segments and continues collecting video for at least six minutes after the event trigger.

Saved events are stored under:

```text
/var/lib/security-cam/saved_events/
```

The rolling buffer is stored under:

```text
/var/lib/security-cam/ring/
```

The `/var/lib/security-cam` filesystem is mounted to the uSD so video recording does not consume the BBB's eMMC.

The system itself is designed to fit on the BBB's eMMC.

**---**

# Security Model

The system is configured with a default-deny firewall. External access is intended to occur only through WireGuard.

The default VPN addresses are:

```text
BBB:            10.10.10.1
Computer 1:     10.10.10.2
Computer 2:     10.10.10.3
Computer 3:     10.10.10.4
```

Additional peers can be configured as needed.
SSH and the live camera stream are restricted to authenticated WireGuard peers.
The Motion control interface remains localhost-only.

**---**

# Camera Control

The main camera control utility is:

```bash
sudo /usr/local/sbin/security-cam-ctl {status|on|off|restart}
```

`status` reports the state of the segment-ring and Motion services.

`off` stops the camera/recording services.

`on` brings the camera system back online.

`restart` runs `off` then `on`.

**---**

# Check Storage

Check free space on the recording uSD:
```bash
df -h /var/lib/security-cam
```

Inspect saved-event and rolling-buffer usage:
```bash
sudo du -sh /var/lib/security-cam/saved_events
sudo du -sh /var/lib/security-cam/ring
```

Confirm that the recording filesystem is actually mounted:
```bash
findmnt /var/lib/security-cam
```

**---**

# Export Saved Events to a PC

The event files are owned by the restricted `motion` account. To export them, stop camera activity and create an archive directly on the uSD:
```bash
sudo /usr/local/sbin/security-cam-ctl off
```

```bash
sudo tar -cf /var/lib/security-cam/saved_events.tar \
  -C /var/lib/security-cam saved_events
```

MJPG video is already compressed, so an uncompressed `.tar` avoids unnecessary CPU usage.

Make the archive accessible to the normal SSH user:
```bash
sudo chown debian:debian /var/lib/security-cam/saved_events.tar
sudo chmod 600 /var/lib/security-cam/saved_events.tar
sudo chmod 751 /var/lib/security-cam
```

From Windows PowerShell:
```powershell
scp bbb:/var/lib/security-cam/saved_events.tar "$env:USERPROFILE\Videos\"
```

After confirming the transfer:
```bash
sudo rm -f /var/lib/security-cam/.current_event
sudo rm -f /var/lib/security-cam/saved_events.tar
sudo chmod 750 /var/lib/security-cam
sudo /usr/local/sbin/security-cam-ctl on
```

**---**

# Clearing Saved Events

Stop the services that write to the uSD:
```bash
sudo systemctl stop segment-ring.service motion.service prune-saved-events.timer
```

Confirm that nothing is actively writing:
```bash
sudo fuser -vm \
  /var/lib/security-cam/saved_events \
  /var/lib/security-cam/ring
```

A kernel mount entry for `/var/lib/security-cam` is normal.

Remove all saved events while preserving the directory itself:
```bash
sudo find /var/lib/security-cam/saved_events \
  -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
```

Optionally clear the rolling buffer:
```bash
sudo find /var/lib/security-cam/ring \
  -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
```

And the created saved_events.tar if present:
```bash
sudo rm -f /var/lib/security-cam/saved_events.tar
```

Restore ownership and permissions:
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

Restart recording:
```bash
sudo systemctl start motion.service
sudo systemctl start segment-ring.service
sudo systemctl start prune-saved-events.timer
```

**---**

# Storage Retention

Saved-event retention is configured through:
```text
/etc/security-cam/storage.conf
```

Default:
```text
MAX_EVENT_GIB=8
MAX_EVENT_AGE_DAYS=14
MIN_FREE_GIB=2
```

The pruning service periodically removes old recordings according to these limits.

**---**

# Important Paths

```text
*Configuration:
/etc/motion/motion.conf
/etc/nftables.conf
/etc/security-cam/storage.conf
/etc/wireguard/wg0.conf

*Project:
/opt/security-cam/

*Camera control:
/usr/local/sbin/security-cam-ctl

*Video storage:
/var/lib/security-cam/ring/
/var/lib/security-cam/saved_events/
```

**---**

# Design Goals

The project prioritizes:

1. Low CPU usage
2. Minimal eMMC writes
3. Automatic recording to removable storage when motion is detected
4. Secure, hardened remote access
5. No publicly exposed camera or SSH interfaces
6. Automatic recovery after reboot
7. Service isolation using systemd
8. Simple maintenance through standard/builtin Linux utilities
