# Frame security

Read this when `security_scan.sh` reports `review` or `risk`, before VideoLoop goes
on the frame or the frame goes on the user's Wi-Fi.

Cheap Android frames usually ship with built-in root, SELinux permissive, security
patches from around 2016, and vendor updaters that can install firmware over Wi-Fi.
Some also ship a **hidden root agent** that phones home. VideoLoop needs no internet,
so the safest frame is one that's never on Wi-Fi. If it does need a network (for
network adb, or because the user keeps Frameo), deal with what the scan found first.

## Reading the scan

| Key | What it means |
|---|---|
| `agent_<name>` | `running(pid N)` or `installed`: a known hidden agent is on the frame → **risk**. `neutralized`: its launcher script is there but the program is gone (as left by the fix below). `absent`: not found. |
| `updaters_enabled`, `updaters_running` | Vendor over-the-air updaters (Adups FOTA, Rockchip `RKUpdateService`, ...). Frameo's own "Android update" screen hands off to them (its code reads `ro.fota.version`), and the Rockchip one also installs any `update.img` found on an inserted card or USB stick. Any enabled or running → **risk**: an update can replace `/system`, undo this setup or bring a removed agent back. Fix: `scripts/disable_updates.sh` (`--undo` re-enables exactly what it disabled). |
| `update_staged` | An update file waiting for the next reboot (`/cache/update.zip`, `/cache/recovery/command`, ...) → **risk**. Don't reboot; remove it as root first. |
| `ota_host` | Where the vendor updater would fetch from (e.g. `www.rockchip.com:2300`). Information only. |
| `frameo_version` | Frameo updates itself (as root, `pm install -r`), e.g. `v1.32.12 (self-updated from v1.23.11)`. That's an app update, not Android: reported, not blocked. It keeps running in the background after VideoLoop takes over the home screen; only a router firewall rule stops it going online. |
| `resolv_conf_dns` | DNS servers written into `/system/etc/resolv.conf`. Public ones (8.8.8.8, 1.1.1.1, OpenDNS) mean the frame ignores the router's DNS, so blocking a domain on the router does nothing. Only a firewall rule works. |
| `root_shells_held_by` | Apps keeping `su` root shells open. On Frameo frames this is usually `net.frameo.frame`, which is expected if the user keeps Frameo. Once VideoLoop is the home screen, Frameo usually stops running and these (and its open port) go away: rescan to confirm. |
| `listening` | TCP ports open beyond localhost, with who owns each: `root`, `system`, `adb` (network adb, see `adb_network_port`), or a uid; 10000 and up is an app: `dumpsys package <pkg> \| grep userId` says which one. |
| `outbound` | Live connections to internet addresses. Any from `root` → **risk**. Empty while `online=no`, so rerun once the frame is on an isolated network. |
| `adb_auth`, `adb_network_port` | adb listening on the network with key checks off means anyone on the LAN can get root on the frame. |
| `clock_days_behind` | These frames often have no clock battery and boot in the past, so HTTPS fails until they get network time. Harmless for VideoLoop. |

Present it to the user in plain words alongside the survey: what was found, what it
could do, and what you'd recommend. Don't change anything without their OK.

## Known hidden agents

### `iotv`
A root daemon found on RK3126 `F606C`/`rk915` Frameo builds. Documented in the
community repo [wesbos/photo-frame-dashboard](https://github.com/wesbos/photo-frame-dashboard):
the [Runxion ZN-DP1002 doc](https://github.com/wesbos/photo-frame-dashboard/blob/main/docs/runxion-zn-dp1002-rk3126.md#hidden-root-agent-iotv)
and issue [#205](https://github.com/wesbos/photo-frame-dashboard/issues/205). Also found
on an MQQC AST01 (SciShion `P200`, firmware built 2026-04-07), with a newer `iotv` build.

- **How it starts:** `/init.rk30board.rc` (in the boot image) has a `run_iotv` service
  that runs `/system/bin/run_iotv.sh` once `sys.boot_completed=1`. That ~113-byte script
  starts `/system/bin/iotv` as root and passes it the Wi-Fi MAC. The same init block
  locks down `/system/etc/resolv.conf` with the public DNS servers.
- **What it did on the Runxion:** kept a connection to a rented cloud server (port 8086)
  and moved about 60 MB an hour in each direction. As root, it can read everything on
  the frame, including the user's photos and videos.
- **`pidof` lies on this firmware:** it returns every PID on the system. `killall`/`pidof`
  based kills took out the root daemon on the Runxion. Kill by the PID from `ps`.

When you find a new agent, add it to `AGENTS` in `scripts/security_scan.sh` and a
section here.

## Options, least to most invasive

1. **Isolate it on the router** (nothing changes on the frame). A guest network or
   VLAN, plus a firewall rule for the frame's MAC that blocks outbound traffic except
   what's needed (at least outbound port 8086, and DNS to anything but the router).
   Only protects networks the user controls, and the agent keeps running.
2. **Make the launcher script a no-op.** The boot image still calls it, but nothing
   starts. Undo: put the original script back.
3. **Delete the agent's binary.** Cleaner. Combined with 2, the boot stays quiet.
4. **A firewall allowlist on the frame**, set up at every boot from the same script
   (only DNS, DHCP, NTP and chosen apps go out). It catches anything else that phones
   home too, but it's hard to get right if Frameo has to keep working.

**Recommended:** 2 + 3, disable the updaters, reboot and rescan; add 1 if the frame
will be on Wi-Fi. Never disable or uninstall the original home app (often Frameo):
VideoLoop's revert puts it back in charge.

## Neutralizing an agent (root needed)

Ask the user first: this writes to `/system`. Use USB if you can (about 6 MB/s,
compared with about 0.1 MB/s over these frames' Wi-Fi). The commands below are for
`root=su`. For `su0` use `su 0 sh -c "..."`, and for `adbd` drop the wrapper.

1. **Offer a backup with `system`** (the user's choice):
   `scripts/backup.sh -s <serial> --with-system`, which should end with
   `Backup verified`. Without it, the saved originals in step 2 still undo this fix,
   but nothing recovers a `/system` write that goes wrong.
2. **Keep the originals** in `frames/<frame-id>/security-<date>/`: `adb pull` the
   binary and the launcher script, and compare each one's md5 with `md5sum` on the frame.
3. **Stop it:** `adb shell ps | grep iotv`, then `su -c "kill <pid>"` with that PID.
4. **Neutralize:**
   ```
   adb push noop.sh /data/local/tmp/noop.sh     # "#!/system/bin/sh" + "exit 0"
   su -c "mount -o remount,rw /system"
   su -c "cat /data/local/tmp/noop.sh > /system/bin/run_iotv.sh"   # keeps owner and mode
   su -c "rm /system/bin/iotv"
   su -c "mount -o remount,ro /system"
   ```
   Then check that `/proc/mounts` shows `/system` as `ro` again.
5. **Turn off Android updates:** `scripts/disable_updates.sh -s <serial>`. Android
   writes package state to disk lazily (a reboot before that lost the setting on the
   Runxion), so the script waits until `package-restrictions.xml` has it.
6. **Write `README.md`** in the security folder: what was changed, the hashes, and the
   undo steps below.
7. **With OK, reboot**, find the frame again, and rerun `security_scan.sh`. You want
   `agent_iotv=neutralized`, the updaters under `updaters_disabled`, and `security`
   no worse than `review`. Then rerun `survey.sh` to check that root and the home
   screen are as before.

**Undo:** remount `/system` read-write, copy the saved originals back the same way
(`cat` over the file via `/data/local/tmp`), `chmod 0755` them, remount read-only, run
`scripts/disable_updates.sh -s <serial> --undo` if the user wants updates back, and reboot.

## Network adb and VideoLoop

`scripts/network_adb.sh` (SKILL.md step 6) leaves adb open on the user's Wi-Fi. If the scan
shows `adb_auth=off`, or the frame is on a shared network, recommend against it: on a
rooted frame it hands root to anyone on the LAN. Managing the frame over USB works too.

## Reporting a new finding upstream

A new agent build or a new frame model carrying one is worth a device doc in
wesbos/photo-frame-dashboard. Only with the user's OK, since the PR is published
under their GitHub account. Leave out the serial number, MAC address, IP address and
the user's name. Firmware strings and file hashes are fine.
