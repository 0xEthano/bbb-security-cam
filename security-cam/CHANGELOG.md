# Changelog

## v3 — hardware-tested cleanup

- Create `/var/log/motion` as `motion:motion` mode `0750` during installation so Motion can open `/var/log/motion/motion.log`
- Use the corrected FFmpeg `segment_start_number` based on Unix seconds instead of an oversized millisecond-derived value
- Configure Fail2Ban with the `systemd` backend and install `python3-systemd`
- Remove `nft-drop` packet logging. The default-deny firewall still counts and drops unmatched traffic silently, avoiding continuous journal/eMMC writes
- Add removable-storage safety guards to the ring writer, event collector, and pruning script. They refuse to write if `/var/lib/security-cam` is not an actual mount point
- Add `RequiresMountsFor=` and `ConditionPathIsMountPoint=` to recording/pruning systemd units
- Document the microSD mount/ownership procedure and the post-mount `motion:motion` ownership requirement
- Add operating procedures for exporting saved events, clearing recordings, checking storage, and troubleshooting WireGuard/MMC detection
