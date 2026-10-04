# TrueNAS SMART Standby

Prevent periodic SMART polling from waking HDDs that are already in standby on TrueNAS SCALE.

This project applies a small runtime overlay to the TrueNAS `middlewared` SMART command. For rotational disks, the patched command adds:

```text
smartctl -n standby
```

If a disk is already sleeping, `smartctl` exits without spinning it up. If the disk is active, TrueNAS can continue reading SMART data normally.

## Status

Tested on:

- TrueNAS SCALE 25.10.7
- smartmontools 7.4
- SATA HDDs with TrueNAS standby enabled

Other TrueNAS releases are not confirmed. The script includes safety checks and stops instead of applying the overlay when the expected TrueNAS source code no longer matches.

## Why this exists

TrueNAS periodically reads SMART data. On some systems, the default SMART call can wake rotational disks even when they are configured to enter standby.

The overlay changes only the SMART invocation in:

```text
/usr/lib/python3/dist-packages/middlewared/utils/disks_/disk_class.py
```

The patch detects whether the device is rotational through Linux sysfs. It adds `-n standby` only for rotational disks.

SSDs and NVMe devices keep the normal SMART command.

## How the boot fix works

A bind mount alone is not enough if `middlewared` starts before the overlay is mounted. Python may already have imported the original module.

The `boot` action therefore:

1. Rebuilds the overlay from the TrueNAS file that is installed on the current system.
2. Verifies the generated Python file.
3. Bind-mounts the patched file over the TrueNAS file.
4. Schedules one delayed `middlewared` restart.
5. Lets the restarted `middlewared` process load the patched module.

The default restart delay is 300 seconds.

The restart runs through a transient systemd unit. The boot script does not sleep for five minutes and does not block the TrueNAS startup task.

## Important warning

This project modifies the runtime behavior of TrueNAS middleware and is not an official TrueNAS component.

Use it only if you understand how the overlay works and can recover from a failed startup customization.

Before applying the script:

- Keep access to the TrueNAS console.
- Keep a copy of the script outside the system root filesystem.
- Recheck the overlay after every TrueNAS update.
- Do not assume support for a TrueNAS release that is not listed as tested.

## Configure the storage path

The repository intentionally contains **no real TrueNAS pool, dataset, host, disk, application, or user paths**.

The scripts use placeholder paths such as:

```text
/path/to/persistent-storage/truenas-smart-standby
```

These are demo paths only. They are not expected to exist.

Before running a script, replace the placeholder with a persistent location on your own TrueNAS system.

Do not store the scripts only in the TrueNAS system root filesystem. The operating-system filesystem can be replaced during an update.

## Install the overlay

Command examples use GitHub's `console` syntax highlighting. GitHub controls the exact colors for commands, prompts, and arguments based on the selected site theme.


1. Copy `standby-smart-overlay.sh` to a persistent location.

2. Edit this line:

   ```bash
   BASE="/path/to/persistent-storage/truenas-smart-standby"
   ```

   Replace the demo path with the persistent directory you selected.

3. Make the script executable:

   ```console
   $ chmod +x /path/to/persistent-storage/truenas-smart-standby/standby-smart-overlay.sh
   ```

4. Check the shell syntax:

   ```console
   $ sudo bash -n /path/to/persistent-storage/truenas-smart-standby/standby-smart-overlay.sh
   ```

5. Apply the overlay to the currently running system:

   ```console
   $ sudo /path/to/persistent-storage/truenas-smart-standby/standby-smart-overlay.sh apply
   ```

   The `apply` action restarts `middlewared`. If you run it from the TrueNAS web shell, the shell session can disconnect. That is expected.

6. Check the result after reconnecting:

   ```console
   $ sudo /path/to/persistent-storage/truenas-smart-standby/standby-smart-overlay.sh status
   ```

   A working bind mount reports:

   ```text
   Overlay: ACTIVE
   ```

## Run the overlay after every boot

Create a TrueNAS Init/Shutdown Script task that runs the following command during post-init:

```console
$ /path/to/persistent-storage/truenas-smart-standby/standby-smart-overlay.sh boot
```

Replace the demo path with your configured persistent path.

UI labels can differ between TrueNAS releases. The important requirement is that the command runs once after the persistent storage containing the script is available.

The `boot` action schedules the delayed `middlewared` restart automatically.

## Verify the delayed restart

After a reboot, check:

````console
$ sudo /path/to/persistent-storage/truenas-smart-standby/standby-smart-overlay.sh status
```

The log should contain messages similar to:

```text
Boot application started.
Overlay was generated from the currently installed TrueNAS file.
Standby-aware disk_class.py is active.
middlewared is already active; scheduling restart in 300 seconds.
Delayed middlewared restart was scheduled.
Boot application completed.
...
Executing delayed middlewared restart.
middlewared is active after the delayed restart.
```

You can also confirm that `middlewared` restarted:

````console
$ sudo systemctl show middlewared.service \
    -p MainPID \
    -p ActiveEnterTimestamp
```

## Check the patched SMART command

The active TrueNAS file should contain the standby-aware command construction:

````console
$ sudo grep -n 'cmd = \["smartctl"' \
    /usr/lib/python3/dist-packages/middlewared/utils/disks_/disk_class.py
```

The script also checks the bind mount with `findmnt`.

## Optional HDD wake logger

`tools/hdd-wake-logger.sh` is a diagnostic tool. It records whether rotational disks are active or in standby without intentionally waking a disk that is already asleep.

The logger records:

- Timestamp
- Boot ID
- `middlewared` PID
- Per-disk `ACTIVE`, `STANDBY`, `POWER_UNKNOWN`, or `ERROR` state

Before using it, edit its demo log path:

```bash
LOG_BASE="/path/to/persistent-storage/truenas-smart-standby"
```

Run it manually:

````console
$ sudo /path/to/persistent-storage/truenas-smart-standby/tools/hdd-wake-logger.sh
```

Or schedule it once per minute temporarily while diagnosing wake-ups.

Do not keep high-frequency diagnostic logging enabled unless you need it.

## Commands

`standby-smart-overlay.sh` supports:

```text
prepare          Build and validate the overlay without mounting it.
boot             Build, mount, and schedule the delayed middlewared restart.
apply            Build, mount, and restart middlewared immediately.
delayed-restart  Internal action used by the transient systemd unit.
status           Show the active SMART command, bind mount, and recent log entries.
unmount          Remove the bind mount.
```

## Behavior after a TrueNAS update

The script does not keep a permanently modified copy of the TrueNAS Python module.

On each `boot` or `apply` action, it:

1. Removes an existing bind mount.
2. Copies the file from the currently installed TrueNAS release.
3. Looks for the exact source block that the patch expects.
4. Refuses to patch if the expected block is not found exactly once.
5. Runs `python3 -m py_compile` on the generated file.
6. Mounts the overlay only after validation succeeds.

This design prevents an old copied middleware file from being blindly placed over a newer TrueNAS release.

If a TrueNAS update changes the relevant code, the script can stop with an error. Review the new TrueNAS implementation before adapting the patch.

## Scope

This project intentionally stays narrow.

It does not:

- Change the TrueNAS SMART polling interval.
- Disable SMART monitoring.
- Disable scheduled SMART tests.
- Change temperature monitoring.
- Disable encryption-key synchronization or other middleware jobs.
- Change HDD standby timers.
- Modify SSD or NVMe SMART behavior.

The goal is to prevent a SMART query from spinning up a rotational disk that is already in standby.

## Scheduled SMART tests

Intentional SMART short and long self-tests can wake disks and keep them active. This project does not suppress them.

If low-power operation is important, schedule maintenance, replication, backups, and SMART tests in a shared activity window where practical. This reduces unnecessary spin-up and spin-down cycles without disabling health checks.

## Uninstall

Remove the startup task, then run:

````console
$ sudo /path/to/persistent-storage/truenas-smart-standby/standby-smart-overlay.sh unmount
```

Restart `middlewared` or reboot TrueNAS so the original module is loaded again.

## License

MIT. See [LICENSE](LICENSE).

---

### AI disclosure

Parts of this project's code and documentation were developed and reviewed with assistance from OpenAI ChatGPT.

The maintainer tested the resulting scripts on the supported TrueNAS version before release. AI-assisted output can contain errors, so review the code and understand the changes before using it on your own system.
