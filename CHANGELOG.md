# Changelog

All notable changes to this project are documented in this file.

## 0.1.0 - 2026-10-04

### Added

- Runtime bind-mount overlay for the TrueNAS `disk_class.py` SMART invocation.
- Rotational-disk detection through Linux sysfs.
- `smartctl -n standby` handling for rotational disks.
- Safety check that requires the expected TrueNAS source block to match exactly once.
- Python syntax validation before the overlay is mounted.
- Delayed post-boot `middlewared` restart through a transient systemd unit.
- Per-boot restart marker to prevent duplicate delayed restarts.
- Status, apply, boot, prepare, and unmount actions.
- Optional HDD wake logger for diagnosing disk activity without intentionally waking standby disks.
- Installation, verification, update, troubleshooting, and uninstall guidance.
- AI-assistance disclosure in the README.

### Verified on TrueNAS SCALE 25.10.7

- `apply` builds and mounts the overlay and restarts `middlewared`.
- `boot` mounts the overlay and schedules the delayed `middlewared` restart.
- `unmount` removes the bind mount and exposes the original TrueNAS source file again.
- A subsequent `apply` rebuilds and activates the overlay successfully.
- The HDD wake logger detects rotational disks automatically and reports standby without waking sleeping disks.
- The previous periodic SMART-related HDD wake-up pattern was not observed with the overlay active.
