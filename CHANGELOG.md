# Changelog

All notable changes to this project are documented in this file.

## 0.1.0 - 2026-10-03

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
