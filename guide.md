# BeagleBone Black Security Camera — Setup Guide

This guide assumes:

- BeagleBone Black running Debian 12 (setup on v6.18.x kernel) / BeagleBoard image
- Ethernet networking
- Microsoft LifeCam Cinema or another compatible UVC camera
- Separate microSD card for recording storage
- Windows PC used for initial setup
- Project archive: `security-cam.zip`

The intended final architecture is:

```text
BeagleBone eMMC holds:
├── Debian
├── Motion
├── FFmpeg
├── WireGuard
├── nftables
└── security-camera scripts

microSD holds:
└── /var/lib/security-cam
    ├── ring/
    └── saved_events/
```

The recording scripts deliberately refuse to write if `/var/lib/security-cam` is not a mounted filesystem, preventing recordings from accidentally filling the BBB's small eMMC. The project takes around 2GB of space, if you include debugging tools.

---

# 1. Connect to the BeagleBone

Connect the BBB to Ethernet and determine its LAN IP address.

From the BBB directly:

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

Make sure to not confuse router IP and BBB IP. Connect using Tera Term or another SSH client.

Typical SSH login:

```powershell
ssh debian@<BBB-LAN-IP>
```

Keep this initial terminal session open during the setup process.

---

# 2. Transfer the Project ZIP to the BBB

## Using Tera Term

Connect to the BBB over SSH first.

Then in Tera Term, use:

```text
File → SSH SCP
```

Zip the "security-cam" folder, and select security-cam.zip as the local file.

Use the remote destination:

```text
/home/debian/security-cam.zip
```

Send the file.

Afterward, verify from the BBB:

```bash
ls -lh ~/security-cam.zip
```

You should see the transferred archive.

---

## Alternative: SCP from PowerShell

Instead of Tera Term:

```powershell
scp .\security-cam.zip debian@<BBB-LAN-IP>:/home/debian/
```

For example:

```powershell
scp .\security-cam.zip debian@10.0.0.X:/home/debian/
OR
scp .\security-cam.zip debian@192.168.X.X:/home/debian/ 
```

---

# 3. Verify the Download

The expected SHA-256 for this release is:

```text
ec6b4edea422f25b4c90234cfd8802e1bd47c1364d8535c355459869e3e4672f
```

On the BBB:

```bash
sha256sum ~/security-cam.zip
```

The result should match one-to-one.

---

# 4. Extract the Project

Check whether `unzip` is installed:

```bash
command -v unzip
```

If necessary:

```bash
sudo apt update
sudo apt install unzip
```

Note: careful running 'sudo apt upgrade'. Upgrading the kernel has a high chance of messing up the BBB. Using -s as an argument can show you what is about to be changed, if you're uncertain.

Extract:

```bash
cd ~
unzip security-cam.zip
```

Enter the project directory:

```bash
cd ~/security-cam
```

Check the files:

```bash
ls
```

Expected top-level contents include:

```text
CHANGELOG.md
README.md
MANIFEST.sha256
hardening/
motion/
security-cam/
wireguard/
```

Optionally verify the included file manifest:

```bash
sha256sum -c MANIFEST.sha256
```

All files should report "OK".

---

# 5. Verify the Camera

Plug the USB camera into the BBB.

Check USB detection:

```bash
lsusb
```

For the Microsoft LifeCam Cinema, expect something similar to:

```text
12ab:34cd Microsoft Corp. LifeCam Cinema
```

Check for the video device:

```bash
ls -l /dev/video*
```

The primary camera should normally appear as:

```text
/dev/video0
```

Do not continue if the camera is not detected. Without a UVC-compliant video source, the rest will not work. Debug the camera first, or try with a different camera. This will likely work on any typical camera, so long as 720p @ 15fps (or lower) is an available format.

---

# 6. Configure the Recording microSD

Be careful here. The BBB eMMC and microSD may appear similar:

```text
mmcblk1   → BBB eMMC
mmcblk0   → microSD
```

Verify before formatting anything:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS
```

On my tested system:

```text
mmcblk1        ~3.6G     BBB eMMC
mmcblk0        ~29.2G    recording microSD
```

Never blindly copy device names / formatting commands from this guide without verifying them on your own board.

---

## 6.1 Format the microSD

If the card already contains the desired ext4 filesystem, skip this step.

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

# 7. Configure the Permanent Storage Mount

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

Save and exit. (Ctrl+S then Ctrl+X)

Mount it:

```bash
sudo mount -a
```

Verify:

```bash
findmnt /var/lib/security-cam
```

Also check:

```bash
df -h /var/lib/security-cam
```

You should see the microSD filesystem, not the eMMC root filesystem. Don't continue until this is correct. 
If you accidentally overwrote your eMMC, reflashing is likely required.

---

# 8. Set Up SSH Public-Key Authentication

Keep the original SSH session open while testing.

The hardening installer should refuse to proceed unless the `debian` account already has an SSH authorized key, but, be safe rather than sorry.

On Windows PowerShell, generate a dedicated key:

```powershell
ssh-keygen -t ed25519 -a 100 -f "$env:USERPROFILE\.ssh\bbb_security_cam"
```

This creates:

```text
bbb_security_cam
bbb_security_cam.pub
```

The private file:

```text
bbb_security_cam
```

must stay on your PC. Only the `.pub` file goes onto the BBB.

While password SSH still works, run from Windows PowerShell:

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

Do not run the hardening installer until this works.

If you ran the hardening and have no access: you may be able to use a serial COM port connection by plugging the BBB directly into your PC, and using Tera Term. Make sure to change Tera Terms default rate from 9600 to 115200.

---

# 9. Run the Installer

From the extracted project directory:

```bash
cd ~/security-cam
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

# 10. Fix Recording-Storage Ownership

Because the storage is a separate filesystem, verify ownership after installation:

```bash
sudo chown motion:motion /var/lib/security-cam
sudo chmod 750 /var/lib/security-cam
```

Create/fix the required directories:

```bash
sudo install -d -o motion -g motion -m 0750 \
  /var/lib/security-cam/ring
```

```bash
sudo install -d -o motion -g motion -m 0750 \
  /var/lib/security-cam/saved_events
```

Verify Motion can write:

```bash
sudo -u motion touch /var/lib/security-cam/.write-test
```

Then:

```bash
sudo -u motion rm /var/lib/security-cam/.write-test
```

If both commands succeed silently, permissions are correct.

---

# 11. Verify Camera Services

Check:

```bash
sudo /usr/local/sbin/security-cam-ctl status
```

Also:

```bash
systemctl --no-pager --full status motion
systemctl --no-pager --full status segment-ring
systemctl status prune-saved-events.timer
```

If necessary:

```bash
sudo /usr/local/sbin/security-cam-ctl restart
```

---

# 12. Verify the Rolling Buffer

Wait roughly one minute, then inspect:

```bash
sudo ls -lh /var/lib/security-cam/ring
```

You should begin seeing AVI segment files.

Check disk activity:

```bash
df -h /var/lib/security-cam
```

The files should be consuming space from the microSD rather than `/`.

Compare:

```bash
df -h /
df -h /var/lib/security-cam
```

The root filesystem should remain essentially unchanged while video is being written. ('df -h /' may report ~50MB being used then deleted, this is ok).

---

# 13. Test Motion Detection

Move in front of the camera for a few seconds, do a little dance. At the home stretch now!

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

The preserved segments are hard links to completed ring-buffer files. They write in 30s segments to not overfill the RAM, so wait a minute or two to see if they're writing correctly.

A link count greater than one is therefore expected:

```bash
sudo ls -l /var/lib/security-cam/saved_events/*/*
```

---

# 14. Configure WireGuard Keys

Note: These are your secrets, keep them safe, if you upload them online do not use them. Does not matter if it's seemingly private, do not upload them. DO NOT UPLOAD THEM. 
Each device needs a unique:

```text
Private key
Public key
Preshared key shared with the BBB
```

The intended VPN addresses are:

```text
BBB       10.10.10.1
iPhone    10.10.10.2
Desktop   10.10.10.3
Laptop    10.10.10.4
```

---

# 15. BBB WireGuard Configuration

Start with:

```text
wireguard/bbb_wg0.conf.example
```

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
PublicKey = <IPHONE_PUBLIC_KEY>
PresharedKey = <IPHONE_PSK>
AllowedIPs = 10.10.10.2/32

[Peer]
# Desktop
PublicKey = <DESKTOP_PUBLIC_KEY>
PresharedKey = <DESKTOP_PSK>
AllowedIPs = 10.10.10.3/32

[Peer]
# Laptop
PublicKey = <LAPTOP_PUBLIC_KEY>
PresharedKey = <LAPTOP_PSK>
AllowedIPs = 10.10.10.4/32
```

The BBB receives each client's **public** key. Never put a client's private key on the BBB. Don't share them using an online service. Use an ssh session or similar to directly upload them from your PC to the BBB.

---

# 16. Client WireGuard Configuration

Each client gets:

```text
A unique private key
The BBB public key
A unique shared PSK (shared with the BBB)
BBB endpoint
```

Example desktop:

```ini
[Interface]
PrivateKey = <DESKTOP_PRIVATE_KEY>
Address = 10.10.10.2/32

[Peer]
PublicKey = <BBB_PUBLIC_KEY>
PresharedKey = <DESKTOP_PSK>
Endpoint = <PUBLIC-IP-OR-DDNS>:51820
AllowedIPs = 10.10.10.1/32
PersistentKeepalive = 25
```

Desktop:

```text
10.10.10.3/32
```

Laptop:

```text
10.10.10.4/32
```

For a desktop that permanently remains on the same LAN, the endpoint can also be the BBB's LAN address:

```ini
Endpoint = <BBB-LAN-IP>:51820
```

Remote cellular/laptop connections normally require a public endpoint or NAT-traversal solution. If you want less devices, remove peers, if you want more, add them.

---

# 17. Enable WireGuard

Once `/etc/wireguard/wg0.conf` is complete:

```bash
sudo systemctl enable --now wg-quick@wg0
```

Check:

```bash
sudo wg show
```

and:

```bash
ip addr show wg0
```

The BBB should have:

```text
10.10.10.1/24
```

---

# 18. Test WireGuard Before Relying on It

Activate one client by uploading its corresponding .conf to WireGuard. LAN tests are recommended so you don't have to deal with port forwarding.

On the BBB:

```bash
sudo wg show
```

A functioning peer should show:

```text
latest handshake: ...
transfer: ... received, ... sent
```

From a client:

```text
ping 10.10.10.1
```

If SSH is configured:

```bash
ssh debian@10.10.10.1
```

---

# 19. Configure the Windows SSH Shortcut

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

Once this works, later commands such as:

```powershell
scp bbb:/path/to/file .
```

will use the same VPN address and SSH key automatically. You can also use `ssh bbb` instead of the longer ssh command.

---

# 20. Test the Live Camera Stream

With WireGuard connected, access the Motion stream using:

```text
http://10.10.10.1:8081/
```

Port `8081` is permitted only from the WireGuard interface by the nftables configuration.

The Motion administrative/control interface on port `8080` remains localhost-only.

---

# 21. Verify nftables

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

The final rule should silently drop unwanted traffic:

```text
counter drop
```

There should not be an:

```text
nft-drop:
```

logging rule. If there is, I would recommend removing it, as it spams your dmesg output. However, it can be nice for ensuring only verified peers are talking to the BBB.

Validate the stored firewall configuration:

```bash
sudo nft -c -f /etc/nftables.conf
```

---

# 22. Verify Fail2Ban

Check:

```bash
sudo systemctl status fail2ban
```

Then:

```bash
sudo fail2ban-client status
```

And:

```bash
sudo fail2ban-client status sshd
```

The project uses the systemd journal backend rather than a traditional SSH logfile.

---

# 23. Verify Automatic Startup

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

# 24. Reboot Test

A security appliance must recover correctly after a power loss.

Reboot:

```bash
sudo reboot
```

Wait for the BBB to return.

Reconnect:

```powershell
ssh bbb
```

Then check:

```bash
sudo /usr/local/sbin/security-cam-ctl status
```

```bash
findmnt /var/lib/security-cam
```

```bash
sudo wg show
```

```bash
systemctl --no-pager --full status motion segment-ring
```

Verify new files are appearing:

```bash
sudo ls -lh /var/lib/security-cam/ring
```

And test the stream again:

```text
http://10.10.10.1:8081/
```

---

# 25. Critical Missing-microSD Test

The project is specifically designed not to fall back to the eMMC.

A useful final test is to boot without the recording microSD available.

Check:

```bash
findmnt /var/lib/security-cam
```

If the card is absent, it should not report a mounted recording filesystem. The recording scripts should refuse to write.

Check:

```bash
systemctl status segment-ring
```

and:

```bash
journalctl -u segment-ring -n 50 --no-pager
```

The root filesystem should not begin filling with video data. A buffer may be getting filled an emptied, however (roughly 50MB).

Before recording again, restore the microSD and verify:

```bash
findmnt /var/lib/security-cam
```

---

# 26. Useful Final Health Check

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

At this point the BBB and services should be fully operational.

---

# Important Security Notes

Never upload any of the following online:

```text
WireGuard private keys
WireGuard preshared keys
SSH private keys
passwords
real exported camera recordings
```

Public keys are not secret, but private keys and PSKs are.

---

# Common Administration Commands

Camera:

```bash
sudo /usr/local/sbin/security-cam-ctl {status|on|off|restart}
```

Stop/start all recording activity:

```bash
sudo systemctl {stop/start} segment-ring motion prune-saved-events.timer
```

Check recording storage:

```bash
df -h /var/lib/security-cam
```

Check mount:

```bash
findmnt /var/lib/security-cam
```

WireGuard:

```bash
sudo wg show
```

Motion logs:

```bash
journalctl -u motion -n 100 --no-pager
```

Ring-buffer logs:

```bash
journalctl -u segment-ring -n 100 --no-pager
```

Firewall:

```bash
sudo nft list ruleset
```

Checking drive storage sizes first eMMC then the uSD:

```bash
sudo df -h /
sudo df -h /var/lib/security-cam
```