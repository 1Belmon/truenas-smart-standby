#!/usr/bin/env bash

set -Eeuo pipefail

# Replace this demo path with a persistent directory on your own TrueNAS system.
# Do not use this placeholder unchanged.
BASE="/path/to/persistent-storage/truenas-smart-standby"

# This is the TrueNAS middleware file patched at runtime.
# It is a system path, not a user or pool-specific path.
TARGET="/usr/lib/python3/dist-packages/middlewared/utils/disks_/disk_class.py"

WORK="$BASE/work"
OVERLAY="$BASE/overlay/disk_class.py"
LOG="$BASE/standby-smart-overlay.log"

SCRIPT_PATH="$(readlink -f "$0")"

RESTART_DELAY_SECONDS="${RESTART_DELAY_SECONDS:-300}"
RESTART_UNIT="truenas-smart-standby-middleware-restart"
RESTART_MARKER="/run/truenas-smart-standby-middleware-restart-scheduled"

PLACEHOLDER_BASE="/path/to/persistent-storage/truenas-smart-standby"

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script as root." >&2
    exit 1
fi

if [[ "$BASE" == "$PLACEHOLDER_BASE" ]]; then
    echo "ERROR: BASE still contains the demo path." >&2
    echo "Edit the script and set BASE to a persistent directory on this TrueNAS system." >&2
    exit 1
fi

mkdir -p "$WORK" "$(dirname "$OVERLAY")"
touch "$LOG"

log() {
    echo "$(date '+%F %T')  $*" | tee -a "$LOG"
    logger -t truenas-smart-standby -- "$*" 2>/dev/null || true
}

is_mounted() {
    findmnt -rn --mountpoint "$TARGET" >/dev/null 2>&1
}

unmount_overlay() {
    if is_mounted; then
        log "Removing existing bind mount."
        umount "$TARGET"
    fi
}

NEEDS_OVERLAY=1

build_overlay() {
    NEEDS_OVERLAY=1

    # Remove an existing overlay first so the source copy always comes from
    # the TrueNAS version that is currently installed.
    unmount_overlay

    rm -f \
        "$WORK/disk_class.py.stock" \
        "$WORK/disk_class.py.patched"

    cp -a "$TARGET" "$WORK/disk_class.py.stock"

    python3 - \
        "$WORK/disk_class.py.stock" \
        "$WORK/disk_class.py.patched" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

text = src.read_text()

old = '''        cmd = ["smartctl", "-x", self.devpath]
        if return_json:
            cmd.extend(["-jc"])

        stdout = self.__run_smartctl_cmd_impl(cmd, raise_alert)
'''

new = '''        rotational = False
        try:
            with open(f"/sys/block/{self.name}/queue/rotational") as f:
                rotational = f.read().strip() == "1"
        except OSError:
            pass

        cmd = ["smartctl"]
        if rotational:
            cmd.extend(["-n", "standby"])

        cmd.extend(["-x", self.devpath])

        if return_json:
            cmd.extend(["-jc"])

        stdout = self.__run_smartctl_cmd_impl(cmd, raise_alert)
'''

# If the installed TrueNAS code already contains this exact change,
# the overlay is no longer required.
if new in text and old not in text:
    dst.write_text(text)
    print("Standby-aware SMART behavior is already present.")
    sys.exit(0)

count = text.count(old)

if count != 1:
    print(
        f"ERROR: Expected TrueNAS source block was found {count} times; "
        "the patch will not be applied.",
        file=sys.stderr,
    )
    sys.exit(42)

dst.write_text(text.replace(old, new, 1))

print("SMART invocation was patched successfully.")
PY

    # Validate Python syntax before mounting anything over a TrueNAS file.
    python3 -m py_compile "$WORK/disk_class.py.patched"

    if cmp -s \
        "$WORK/disk_class.py.stock" \
        "$WORK/disk_class.py.patched"
    then
        log "The installed TrueNAS version does not require this overlay."
        rm -f "$OVERLAY"
        NEEDS_OVERLAY=0
        return 0
    fi

    install -m 0644 \
        "$WORK/disk_class.py.patched" \
        "$OVERLAY"

    log "Overlay was generated from the currently installed TrueNAS file."
}

mount_overlay() {
    if [[ "$NEEDS_OVERLAY" -eq 0 ]]; then
        return 0
    fi

    mount --bind "$OVERLAY" "$TARGET"

    if ! is_mounted; then
        log "ERROR: Bind mount could not be verified."
        exit 1
    fi

    log "Standby-aware disk_class.py is active."
}

schedule_delayed_middleware_restart() {
    if [[ "$NEEDS_OVERLAY" -eq 0 ]]; then
        log "No overlay is required; no middlewared restart was scheduled."
        return 0
    fi

    # If middlewared has not started yet, it will load the mounted file when
    # it starts later, so a restart is not required.
    if ! systemctl is-active --quiet middlewared.service; then
        log "middlewared is not active yet; no restart is required."
        return 0
    fi

    # /run is recreated on every boot. This marker prevents multiple delayed
    # restarts from being scheduled during the same boot.
    if [[ -e "$RESTART_MARKER" ]]; then
        log "A delayed middlewared restart was already scheduled for this boot."
        return 0
    fi

    log "middlewared is already active; scheduling restart in ${RESTART_DELAY_SECONDS} seconds."

    if /usr/bin/systemd-run \
        --unit="$RESTART_UNIT" \
        --on-active="${RESTART_DELAY_SECONDS}s" \
        --collect \
        /usr/bin/env bash "$SCRIPT_PATH" delayed-restart \
        >/dev/null
    then
        touch "$RESTART_MARKER"
        log "Delayed middlewared restart was scheduled."
    else
        log "ERROR: Delayed middlewared restart could not be scheduled."
        exit 1
    fi
}

delayed_restart_middleware() {
    if ! is_mounted; then
        log "ERROR: Overlay is not active before the delayed middlewared restart."
        exit 1
    fi

    log "Executing delayed middlewared restart."

    if systemctl restart middlewared.service; then
        if systemctl is-active --quiet middlewared.service; then
            log "middlewared is active after the delayed restart."
        else
            log "ERROR: middlewared is not active after the restart."
            exit 1
        fi
    else
        log "ERROR: middlewared restart failed."
        exit 1
    fi
}

show_status() {
    echo
    echo "TrueNAS file:"
    echo "  $TARGET"
    echo

    echo "SMART invocation:"
    grep -n 'cmd = \["smartctl"' "$TARGET" || true
    echo

    if is_mounted; then
        echo "Overlay: ACTIVE"
        findmnt -rn --mountpoint "$TARGET" -o TARGET,SOURCE,FSTYPE,OPTIONS
    else
        echo "Overlay: NOT ACTIVE"
    fi

    echo
    echo "Recent log entries:"
    tail -20 "$LOG" 2>/dev/null || true
}

case "${1:-}" in
    prepare)
        log "Generating and validating overlay."
        build_overlay
        log "Preparation completed."
        ;;

    boot)
        log "Boot application started."
        build_overlay
        mount_overlay
        schedule_delayed_middleware_restart
        log "Boot application completed."
        ;;

    apply)
        log "Live application started."
        build_overlay
        mount_overlay

        log "Restarting middlewared."
        systemctl restart middlewared.service

        # When this command is run from the TrueNAS web shell, restarting
        # middlewared can terminate the shell session before this line runs.
        log "Live application completed."
        ;;

    delayed-restart)
        delayed_restart_middleware
        ;;

    status)
        show_status
        ;;

    unmount)
        unmount_overlay
        log "Overlay removed."
        ;;

    *)
        echo "Usage:"
        echo "  $0 prepare"
        echo "  $0 boot"
        echo "  $0 apply"
        echo "  $0 delayed-restart"
        echo "  $0 status"
        echo "  $0 unmount"
        exit 1
        ;;
esac
