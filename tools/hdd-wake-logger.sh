#!/usr/bin/env bash

set -Eeuo pipefail

# Replace this demo path with a persistent directory on your own TrueNAS system.
# Do not use this placeholder unchanged.
LOG_BASE="/path/to/persistent-storage/truenas-smart-standby"

# Leave DISKS empty to detect non-USB rotational disks automatically.
# To monitor specific devices instead, use full device paths, for example:
# DISKS=(/dev/sda /dev/sdb)
DISKS=()

PLACEHOLDER_LOG_BASE="/path/to/persistent-storage/truenas-smart-standby"
LOG="$LOG_BASE/hdd-wake.log"
LOCK="$LOG_BASE/.hdd-wake-logger.lock"

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script as root." >&2
    exit 1
fi

if [[ "$LOG_BASE" == "$PLACEHOLDER_LOG_BASE" ]]; then
    echo "ERROR: LOG_BASE still contains the demo path." >&2
    echo "Edit the script and set LOG_BASE to a persistent directory on this TrueNAS system." >&2
    exit 1
fi

mkdir -p "$LOG_BASE"

# Prevent overlapping logger runs when this script is scheduled frequently.
exec 9>"$LOCK"
if ! flock -n 9; then
    exit 0
fi

if [[ "${#DISKS[@]}" -eq 0 ]]; then
    mapfile -t DISKS < <(
        lsblk -dnpo NAME,TYPE,ROTA,TRAN |
        awk '$2 == "disk" && $3 == 1 && $4 != "usb" {print $1}'
    )
fi

if [[ "${#DISKS[@]}" -eq 0 ]]; then
    echo "$(date '+%F %T %Z') no_rotational_disks_found" >> "$LOG"
    exit 0
fi

get_state() {
    local device="$1"
    local rc

    # The custom exit codes distinguish standby from other smartctl results.
    # -n standby tells smartctl not to spin up a sleeping disk.
    set +e
    smartctl -n standby,3,5 "$device" >/dev/null 2>&1
    rc=$?
    set -e

    case "$rc" in
        0)
            printf 'ACTIVE(rc=0)'
            ;;
        3)
            printf 'STANDBY(rc=3)'
            ;;
        5)
            printf 'POWER_UNKNOWN(rc=5)'
            ;;
        *)
            printf 'ERROR(rc=%s)' "$rc"
            ;;
    esac
}

BOOT_ID="$(cut -c1-8 /proc/sys/kernel/random/boot_id)"
UPTIME_SECONDS="$(cut -d. -f1 /proc/uptime)"
MIDDLEWARED_PID="$(systemctl show middlewared.service -p MainPID --value 2>/dev/null || true)"

line="$(date '+%F %T %Z') boot=$BOOT_ID uptime=${UPTIME_SECONDS}s middlewared_pid=${MIDDLEWARED_PID:-unknown}"

for device in "${DISKS[@]}"; do
    name="$(basename "$device")"
    state="$(get_state "$device")"
    line+=" ${name}=${state}"
done

echo "$line" >> "$LOG"
