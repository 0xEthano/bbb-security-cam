# BeagleBone Black (BBB) Security Camera Setup Guide

This guide assumes:

- BBB running Debian 12 (setup tested on v6.18.x kernel) / [Tested BBB image](https://www.beagleboard.org/distros/beaglebone-black-debian-12-15-2026-09-20-iot-v6-18-x)
- Ethernet networking
- Microsoft LifeCam Cinema or another compatible UVC camera
- Separate microSD (uSD) card for recording storage
- Windows PC used for initial setup
- The provided micro USB cable for the BBB

The intended final architecture is:

```text
BBB eMMC holds:
 Debian install
 Motion
 FFmpeg
 WireGuard
 nftables
 security-camera scripts

uSD holds:
/var/lib/security-cam
which contains the rolling buffer and saved events.
```

The recording scripts deliberately refuse to write if `/var/lib/security-cam` is not a mounted filesystem, i.e. if the uSD is not detected, to prevent recordings from accidentally filling the BBB's eMMC.

---

# 1. Connect to the BBB

Connect the BBB to Ethernet, plug it into your PC with the micro USB cable, and determine its LAN IP address.

I recommend using Tera Term, it is automatically setup correctly except for the speed. Go to `Setup > Serial port >` in the window, change `Speed:` from `9600` to `115200`.

Log into the BBB. It should prompt for a new debian password if you did not set it pre-flash.

Once logged in, run:
```bash
ip -4 addr show eth0
```

Look for:
```text
inet 192.168.x.x/24
OR
inet 10.x.x.x/24
OR similar
```

Make sure not to confuse the router IP with the BBB IP.

From Windows PowerShell, log in through SSH:
```powershell
ssh debian@<BBB-LAN-IP>
```
You can disconnect the BBB from your PC and move it to it's desired location. 

Open a new SSH session. Keep this initial terminal session open during setup, especially while changing SSH or firewall settings.

---

# 2. Download the Project

## Recommended: Clone from GitHub

With the BBB connected to Ethernet, install Git if needed:
```bash
sudo apt update
sudo apt install -y git
```

Clone the repository:
```bash
cd ~
git clone https://github.com/0xEthano/bbb-security-cam.git bbb-security-cam
```

Enter the project:
```bash
cd ~/bbb-security-cam
```

Check the files:
```bash
ls
```

Expected top-level contents include:
```text
README.md
guide.md
appliance/
    hardening/
    motion/
    security-cam/
    wireguard/
```

Optionally verify the included file manifest:
```bash
sha256sum -c MANIFEST.sha256
```

All files should report `OK`.

---

A note before proceeding: be careful with running `sudo apt upgrade` on the BBB. Kernel updates in particular can occasionally introduce board-specific issues, typically forcing a reflash. If uncertain, simulate first:
```bash
sudo apt-get -s upgrade
```

---

# 3. Verify the Camera

Plug the USB camera into the BBB.

Check USB detection:
```bash
lsusb
```

For the Microsoft LifeCam Cinema, expect something similar to:
```text
045e:075d Microsoft Corp. LifeCam Cinema
```

Check for the video device:
```bash
ls -l /dev/video*
```

The primary camera should normally appear as:
```text
/dev/video0
```

Check its supported formats:
```bash
v4l2-ctl --device=/dev/video0 --list-formats-ext
```

The tested LifeCam configuration is MJPEG at `1280x720`, 15 FPS. You will need to change it if that is not available. Avoid formats that are uncompresed as they may use more bandwith than necessary, slowing the system down.

Do not continue if the camera is not detected. Without a UVC-compatible video source, the rest of the system will not work correctly.

---

# 4. Configure the Recording uSD

Be careful here. The BBB eMMC and uSD may appear similar:
```text
mmcblk1  (typically) → BBB eMMC
mmcblk0  (typically) → uSD
```

Verify before formatting anything:
```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
```

On my tested system:
```text
mmcblk1        ~3.6G     BBB eMMC
mmcblk0        ~29.2G    recording uSD
```

Never blindly copy device names or formatting commands from this guide without verifying them on your own board.

---

## 4.1 Format the uSD

If the card already contains the desired ext4 filesystem, or you have data on it you'd like to save, skip this step.

Otherwise, assuming the recording partition is `/dev/mmcblk0p1`:
```bash
sudo mkfs.ext4 -L SECURITY_CAM /dev/mmcblk0p1
```

This destroys everything currently on that partition.

Get its UUID:
```bash
sudo blkid /dev/mmcblk0p1
```

Example:
```text
UUID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
TYPE="ext4"
```

Copy the UUID.

---

# 5. Configure the Permanent Storage Mount

Create the mount point:
```bash
sudo mkdir -p /var/lib/security-cam
```

Edit:
```bash
sudo nano /etc/fstab
```

Add:
```fstab
UUID=<YOUR_SD_UUID> /var/lib/security-cam ext4 defaults,noatime,nofail 0 2
```

For example:
```fstab
UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx /var/lib/security-cam ext4 defaults,noatime,nofail 0 2
```

Save and exit.

Mount it, verify the mount, and check:
```bash
sudo mount -a

findmnt /var/lib/security-cam

df -h /var/lib/security-cam
```

You should see the uSD filesystem, not the eMMC root filesystem. Do not continue until this is correct.

Be careful with `mkfs` and `/etc/fstab`; using the wrong device will simply not work in the long-run.

---

# 6. Set Up SSH Public-Key Authentication

Keep the original SSH session open while testing.

The hardening installer should refuse to proceed unless the `debian` account already has an SSH authorized key, but verify it yourself before continuing.

On Windows PowerShell, generate a dedicated key:
```powershell
ssh-keygen -t ed25519 -a 100 -f "$env:USERPROFILE\.ssh\bbb_security_cam"
```

This creates:
```text
bbb_security_cam       # Private key
bbb_security_cam.pub   # Public key
```

The private file must stay on your PC. Only the `.pub` file goes onto the BBB. Don't upload private keys anywhere.

While password-based SSH still works, run from Windows PowerShell:
```powershell
Get-Content "$env:USERPROFILE\.ssh\bbb_security_cam.pub" |
ssh debian@<BBB-LAN-IP> 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys'
```

Test the key:
```powershell
ssh -i "$env:USERPROFILE\.ssh\bbb_security_cam" `
    -o PasswordAuthentication=no `
    debian@<BBB-LAN-IP>
```

If the key has a passphrase, this will ask for the SSH key passphrase.

Do not run the hardening installer until this works.

If SSH hardening is accidentally applied before working key authentication is confirmed, recovery may require connecting to the BBB through its serial console. Tera Term can be used for this; the serial baud rate/ "Speed" is `115200`.

---

# 7. Run the Installer

From the extracted project directory:
```bash
cd appliance/
```

Run:
```bash
sudo ./hardening/setup-hardening.sh
```

The installer installs and configures:
```text
Motion
FFmpeg
WireGuard tools
nftables
Fail2Ban
python3-systemd
unattended-upgrades
SSH hardening
camera scripts
systemd units
```

It also creates:
```text
/opt/security-cam/
/etc/security-cam/
/var/log/motion/
/usr/local/sbin/security-cam-ctl
```

and applies the project's firewall and service configuration.

---

# 8. Fix Recording-Storage Ownership

Because the storage is a separate filesystem, verify ownership after installation:
```bash
sudo chown motion:motion /var/lib/security-cam
sudo chmod 750 /var/lib/security-cam
```

Create/fix the required directories:
```bash
sudo install -d -o motion -g motion -m 0750 \
  /var/lib/security-cam/ring

sudo install -d -o motion -g motion -m 0750 \
  /var/lib/security-cam/saved_events
```

Verify Motion can write:
```bash
sudo -u motion touch /var/lib/security-cam/.write-test
sudo -u motion rm /var/lib/security-cam/.write-test
```

If both commands succeed silently, permissions are correct.

---

# 9. Verify Camera Services

Check:
```bash
sudo /usr/local/sbin/security-cam-ctl status
```

For a more in-depth check:
```bash
systemctl --no-pager --full status motion
systemctl --no-pager --full status segment-ring
systemctl status prune-saved-events.timer
```

If necessary, restart the services:
```bash
sudo /usr/local/sbin/security-cam-ctl restart
```

---

# 10. Verify the Rolling Buffer

Wait roughly one minute, then inspect:
```bash
sudo ls -lh /var/lib/security-cam/ring
```

Or simply check that storage is being used, then discarded (so long as motion was not triggered):
```bash
sudo df -h /var/lib/security-cam/
```

You should begin seeing AVI segment files or storage being used, then discarded.

Check disk usage:
```bash
df -h /var/lib/security-cam
```

The files should be consuming space from the uSD rather than `/`.

Compare:
```bash
df -h /
df -h /var/lib/security-cam
```

The root filesystem should remain essentially unchanged while video is being written.

A small amount of temporary variation on `/` is normal due to the buffer, but continuous growth is not. If it is, run the stop command to prevent filling the eMMC.
```bash
sudo /usr/local/sbin/security-cam-ctl stop
```

---

# 11. Test Motion Detection

Move in front of the camera for a few seconds. Do a little dance. It's the home stretch now

Check Motion logs:
```bash
journalctl -u motion -n 100 --no-pager
```

Check event directories:
```bash
sudo find /var/lib/security-cam/saved_events \
  -maxdepth 2 -type f -ls
```

A triggered event should create a timestamped directory under:
```text
/var/lib/security-cam/saved_events/
```

The event collector writes in 30-second segments, so give it a minute or two before assuming it failed.

The preserved segments are initially hard links to completed rolling-buffer files. While the corresponding file still exists in the ring buffer, a link count greater than one is expected:
```bash
sudo ls -l /var/lib/security-cam/saved_events/*/*
```

After the source ring-buffer entry is eventually removed, the saved event file may correctly show a link count of `1`.

---

# 12. Configure WireGuard Keys

These are secrets. Keep them safe. Do not upload private keys or preshared keys anywhere.

Each device needs:
```text
A unique private key
A matching public key
A unique preshared key shared with the BBB
```

The intended VPN addresses are:
```text
BBB        10.10.10.1
iPhone     10.10.10.2
Desktop    10.10.10.3
Laptop     10.10.10.4
```

Public keys are safe to share when needed. Private keys and PSKs are not.

---

# 13. BBB WireGuard Configuration

Start with setting up the BBB's conf.
Copy it:
```bash
sudo cp wireguard/bbb_wg0.conf.example /etc/wireguard/wg0.conf
```

Secure it:
```bash
sudo chmod 600 /etc/wireguard/wg0.conf
```

Edit:
```bash
sudo nano /etc/wireguard/wg0.conf
```

The layout is:
```ini
[Interface]
Address = 10.10.10.1/24
ListenPort = 51820
PrivateKey = <BBB_PRIVATE_KEY>

[Peer]
# iPhone
PublicKey = <COMPUTER1_PUBLIC_KEY>
PresharedKey = <COMPUTER1_PSK>
AllowedIPs = 10.10.10.2/32

[Peer]
# Desktop
PublicKey = <COMPUTER2_PUBLIC_KEY>
PresharedKey = <COMPUTER2_PSK>
AllowedIPs = 10.10.10.3/32

[Peer]
# Laptop
PublicKey = <COMPUTER3_PUBLIC_KEY>
PresharedKey = <COMPUTER3_PSK>
AllowedIPs = 10.10.10.4/32
```

The BBB receives each client's **public** key. Don't put a client's private key on the BBB.

---

# 14. Client WireGuard Configuration

Each client gets:
```text
Its own private key
The BBB public key
Its own PSK shared with the BBB
The BBB endpoint, for a LAN connection, the LAN IP can be used (recommended for initial setup).
```

Example desktop:
```ini
[Interface]
PrivateKey = <DESKTOP_PRIVATE_KEY>
Address = 10.10.10.3/32

[Peer]
PublicKey = <BBB_PUBLIC_KEY>
PresharedKey = <DESKTOP_PSK>
Endpoint = <BBB-ENDPOINT>:51820
AllowedIPs = 10.10.10.1/32
PersistentKeepalive = 25
```

iPhone:
```text
10.10.10.2/32
```

Desktop:
```text
10.10.10.3/32
```

Laptop:
```text
10.10.10.4/32
```

Remote cellular or laptop connections normally require a public endpoint and UDP port forwarding, or another NAT-traversal solution such as Tailscale/ZeroTier.

If fewer peers are needed, remove them. If more are needed, add additional unique addresses and keys.

You can upload the .conf's directly to Windows' WireGuard GUI client.

---

# 15. Enable WireGuard

Once `/etc/wireguard/wg0.conf` is complete:
```bash
sudo systemctl enable --now wg-quick@wg0
```

Check:
```bash
sudo wg show
ip addr show wg0
```

The BBB should have:
```text
10.10.10.1/24
```

---

# 16. Test WireGuard Before Relying on It

Activate one client using its corresponding WireGuard configuration.

Testing on the same LAN first is recommended because it separates WireGuard configuration problems from router/port-forwarding problems.

On the BBB:
```bash
sudo wg show
```

A functioning peer should show:
```text
latest handshake: ...
transfer: ... received, ... sent
```

From the client:
```text
ping 10.10.10.1
```

If SSH is configured:
```bash
ssh debian@10.10.10.1
```

If the tunnel works over LAN but not from cellular/off-LAN, WireGuard itself is probably configured correctly. Check the public endpoint, router UDP forwarding, upstream NAT, or CGNAT. Make router changes as necessary, just don't expose more than you need to.

---

# 17. Configure the Windows SSH Shortcut

On Windows, edit:
```text
%USERPROFILE%\.ssh\config
```

Add:
```text
Host bbb
    HostName 10.10.10.1
    User debian
    IdentityFile ~/.ssh/bbb_security_cam
    PasswordAuthentication no
```

Then test:
```powershell
ssh bbb
```

Once this works, commands such as:
```powershell
scp bbb:/path/to/file .
```

will use the same VPN address and SSH key automatically.

---

# 18. Test the Live Camera Stream

With WireGuard connected, access the Motion stream using `http://10.10.10.1:8081/`. This can be input to a browser, and you should receive a camera feed.

Port `8081` is permitted only from the WireGuard interface by the nftables configuration.

The Motion administrative/control interface on port `8080` remains localhost-only.

---

# 19. Verify nftables

Check the firewall:
```bash
sudo nft -a list ruleset
```

The input chain should follow a default-drop policy.

Expected permitted traffic includes:
```text
loopback
established/related traffic
WireGuard UDP 51820
SSH from wg0
camera stream from wg0
limited ICMP
```

The final unmatched traffic rule should silently drop traffic rather than continuously logging it.

Validate the stored firewall configuration:
```bash
sudo nft -c -f /etc/nftables.conf
```

No output means the configuration parsed successfully.

---

# 20. Verify Fail2Ban

Check:
```bash
sudo systemctl status fail2ban
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

This project uses the systemd journal backend rather than a traditional SSH logfile.

---

# 21. Verify Automatic Startup

The following should be enabled:
```bash
systemctl is-enabled motion.service
systemctl is-enabled segment-ring.service
systemctl is-enabled prune-saved-events.timer
systemctl is-enabled nftables
systemctl is-enabled fail2ban
```

Once WireGuard is configured:
```bash
systemctl is-enabled wg-quick@wg0
```

---

# 22. Reboot Test

Naturally, the application needs to recover correctly after a power loss.

Reboot:
```bash
sudo reboot now
```

Wait for the BBB to boot and reconnect to the network.

Reconnect:
```powershell
ssh bbb
```

If you have issues reconnecting / you're getting "Connection refused", try restarting your PC. For some reason that fixed `ssh bbb` for me.

Then check:
```bash
sudo /usr/local/sbin/security-cam-ctl status
findmnt /var/lib/security-cam
sudo wg show
systemctl --no-pager --full status motion segment-ring
```

Verify new rolling-buffer files are appearing:
```bash
sudo ls -lh /var/lib/security-cam/ring
```

Test the stream again, on a browser. `http://10.10.10.1:8081/`

---

# 23. Critical Missing-uSD Test

The project is specifically designed not to silently fall back to the eMMC.

A useful final test is to boot with the uSD removed from the BBB.

Check:
```bash
findmnt /var/lib/security-cam
```

If the card is absent, it should not report a mounted recording filesystem. The recording scripts should refuse to write.

Check:
```bash
systemctl status segment-ring
journalctl -u segment-ring -n 50 --no-pager
```

The eMMC filesystem should not begin filling with video files.

Before recording again, plug in the the uSD and verify:
```bash
findmnt /var/lib/security-cam
```

Then restart the camera services if needed:
```bash
sudo /usr/local/sbin/security-cam-ctl restart
```

---

# 24. Final Health Check

Run:
```bash
echo "=== STORAGE ==="
findmnt /var/lib/security-cam
df -h /
df -h /var/lib/security-cam

echo
echo "=== CAMERA ==="
sudo /usr/local/sbin/security-cam-ctl status

echo
echo "=== WIREGUARD ==="
sudo wg show

echo
echo "=== FIREWALL ==="
sudo nft list chain inet filter input

echo
echo "=== SERVICES ==="
systemctl --no-pager --full status \
  motion \
  segment-ring \
  prune-saved-events.timer
```

At this point the BBB and its services should be fully operational.

For normal operation, exporting recordings, clearing saved events, storage checks, and other day-to-day commands, see `README.md`.
