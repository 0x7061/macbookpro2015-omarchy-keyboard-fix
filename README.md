# MacBookPro12,1 — built-in keyboard & trackpad on Omarchy (applespi fix)

Reference for the 13" Early 2015 MacBook Pro (`MacBookPro12,1`). Omarchy 4.x, kernel `linux-omarchy` 7.x, systemd 261, Limine + LUKS + btrfs, busybox initramfs. Covers keyboard/trackpad, LUKS prompt, suspend and hibernation. State as of 22 Sept 2026.

---

## 0. Quick start — `mbp12-omarchy-fix.sh`

Everything in this document is automated by `mbp12-omarchy-fix.sh` (next to this file). It is idempotent (unchanged files are skipped), verifies after each step, stops at the first failure, and backs up every system file it changes to `/root/mbp12-fix-backups/<timestamp>/` (files under `$HOME` get a `.bak.<timestamp>` copy). Run it as your normal user — it calls `sudo` itself; the AUR helper refuses to run as root. The sections below are the manual equivalent and the explanation of *why*.

```bash
./mbp12-omarchy-fix.sh --dry-run            # show what would be written/run, change nothing
./mbp12-omarchy-fix.sh                      # all non-destructive phases (everything except hibernation)
sudo reboot                                 # keep a USB keyboard attached for this first reboot
./mbp12-omarchy-fix.sh --verify             # read-only checks; run after every reboot / change

sudo omarchy-hibernation-setup              # optional: hibernation (opt-in, recreates the swapfile)
./mbp12-omarchy-fix.sh --phase hibernation [--yes] [--swap-size 18g]
```

| Phase (`--phase <name>`) | Does | Section |
|---|---|---|
| `kernel-params` | `initcall_blacklist=dw_pci_driver_init mem_sleep_default=s2idle` in `/etc/default/limine`, rebuild | 3 |
| `acpi-call` | kernel headers + `acpi_call-dkms` (AUR) | 4.1 |
| `switch` | `/usr/local/bin/applespi-force` + `applespi-force.service` | 4.3–4.4 |
| `initramfs` | early hook so the keyboard works at the LUKS prompt, rebuild | 5 |
| `sleep` | s2idle drop-in, sleep hook, `shell-refresh-on-resume` user script + unit | 6 |
| `hibernation` | **opt-in, destructive for the swapfile:** move it to a top-level `@swap` subvolume, fix `resume_offset` | 7 |
| `verify` | same as `--verify` | — |

Other flags: `--force-model` skips the `MacBookPro12,1` check (e.g. to try it on a MacBook8,1), `--help` prints the usage header.

After changing the sleep hook or the user unit, `./mbp12-omarchy-fix.sh --phase sleep` re-installs just those files (no reboot needed); then `--verify`.

---

## 1. Root cause

The topcase (keyboard + trackpad) can be driven over **USB or SPI**; ACPI methods select the interface:

| Method | Meaning |
|---|---|
| `UIST` | USB Interface Status (1 = USB enabled) |
| `UIEN n` | USB Interface Enable (0 = off, 1 = on) |
| `SIST` | SPI Interface Status |
| `SIEN n` | SPI Interface Enable (1 = on, disables USB) |

The kernel `applespi` driver checks `UIST` at probe; if USB is enabled it backs off (`applespi: USB interface already enabled`) and leaves the device to `usbhid`. On this unit the USB path is electrically dead (`usb 1-5: device descriptor read/64, error -71`, `Device not responding to setup address`), so no driver ever gets the keyboard. macOS never noticed because it uses SPI on this model.

Forcing SPI mode exposes a second, platform-wide bug: the Broadwell LPSS DMA engine (`00:15.0`, `dw_dmac_pci`) never completes SPI transfers, so `applespi` logs `SPI transfer timed out` / `Error reading from device: -110` forever.

**Fix = three parts**

1. Kernel parameter `initcall_blacklist=dw_pci_driver_init` → GSPI controller (`00:15.4`) falls back to PIO.
2. At every boot: `UIEN 0`, `SIEN 1` via `acpi_call`, then (re)load `applespi`.
3. Do part 2 in the initramfs too (LUKS passphrase prompt) and around suspend/resume.

Constants: ACPI path `\_SB_.PCI0.SPI1.SPIT` (from `/sys/bus/spi/devices/spi-APP000D:00/firmware_node/path`), ACPI device `APP000D`.

---

## 2. Diagnosis commands

```bash
cat /sys/class/dmi/id/product_name                          # MacBookPro12,1
sudo dmesg | grep -iE "applespi|PIO|dw_dmac|spi1"
sudo dmesg | grep -iE "usb 1-|hid|bcm5974"                   # usb 1-5 error -71 = dead USB path
lsusb | grep -i apple                                        # needs: sudo pacman -Sy usbutils
sudo libinput list-devices | grep -iA3 apple
cat /sys/bus/spi/devices/spi-APP000D:00/firmware_node/path   # ACPI path for the script/hook
lspci -nn | grep -E "15\.0|15\.4"                            # LPSS DMA + GSPI controllers
```

---

## 3. Part 1 — kernel parameters

```bash
sudo nano /etc/default/limine
```

Append (leave existing `KERNEL_CMDLINE[default]=` lines untouched):

```
KERNEL_CMDLINE[default]+=" initcall_blacklist=dw_pci_driver_init mem_sleep_default=s2idle"
```

```bash
sudo limine-update
sudo reboot
grep -oE "initcall_blacklist=[^ ]*|mem_sleep_default=[^ ]*" /proc/cmdline
sudo dmesg | grep -i PIO        # pxa2xx_spi_pci 0000:00:15.4: no DMA channels available, using PIO
```

---

## 4. Part 2 — acpi_call + switch script + systemd unit

### 4.1 acpi_call (DKMS)

```bash
sudo pacman -S --needed dkms base-devel linux-omarchy-headers   # linux-headers for plain -arch kernel
yay -S acpi_call-dkms
sudo modprobe acpi_call
```

### 4.2 Manual test

```bash
P=$(cat /sys/bus/spi/devices/spi-APP000D:00/firmware_node/path)
echo "$P.UIEN 0" | sudo tee /proc/acpi/call
echo "$P.SIEN 1" | sudo tee /proc/acpi/call
sudo modprobe -r applespi && sudo modprobe applespi
sudo dmesg | grep -i applespi | tail -3        # → modeswitch done.
```

### 4.3 Script — `/usr/local/bin/applespi-force`

```sh
#!/bin/sh
P='\_SB_.PCI0.SPI1.SPIT'
modprobe acpi_call
echo "$P.UIEN 0" > /proc/acpi/call
echo "$P.SIEN 1" > /proc/acpi/call
modprobe -r applespi
modprobe applespi
```

```bash
sudo chmod 755 /usr/local/bin/applespi-force     # missing this → status=203/EXEC
```

### 4.4 Unit — `/etc/systemd/system/applespi-force.service`

```ini
[Unit]
Description=Force MacBookPro12,1 topcase to SPI
DefaultDependencies=no
After=systemd-modules-load.service
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/applespi-force

[Install]
WantedBy=sysinit.target
```

```bash
sudo systemctl enable --now applespi-force.service
systemctl status applespi-force.service --no-pager     # active (exited), status=0/SUCCESS
```

---

## 5. Part 3a — initramfs hook (keyboard at the LUKS prompt)

Omarchy's `/etc/mkinitcpio.conf.d/omarchy_hooks.conf` **replaces** `HOOKS` with a busybox set (`base udev plymouth … encrypt …`); the `systemd`/`sd-vconsole` line in `/etc/mkinitcpio.conf` is inert. Therefore: busybox-style `run_earlyhook`, and a drop-in named to sort *after* `omarchy_hooks.conf`.

### 5.1 `/etc/initcpio/install/applespi-force`

```bash
#!/bin/bash
build() {
    add_module acpi_call
    add_module intel_lpss_pci
    add_module spi_pxa2xx_pci
    add_module spi_pxa2xx_platform
    add_module applespi
    add_runscript
}
help() {
    echo "Switch MacBookPro12,1 topcase to SPI before the LUKS prompt."
}
```

### 5.2 `/etc/initcpio/hooks/applespi-force`

```sh
#!/usr/bin/ash
run_earlyhook() {
    P='\_SB_.PCI0.SPI1.SPIT'
    modprobe acpi_call
    printf '%s\n' "$P.UIEN 0" > /proc/acpi/call
    printf '%s\n' "$P.SIEN 1" > /proc/acpi/call
    modprobe intel_lpss_pci
    modprobe spi_pxa2xx_pci
    modprobe spi_pxa2xx_platform
    modprobe -r applespi 2>/dev/null
    modprobe applespi
}
```

`run_earlyhook` runs for every hook before any `run_hook`; the `encrypt` passphrase prompt is a `run_hook`, so ordering in HOOKS doesn't matter.

### 5.3 `/etc/mkinitcpio.conf.d/zz-applespi-force.conf`

```
HOOKS+=(applespi-force)
```

### 5.4 Rebuild

```bash
sudo mkinitcpio -P 2>&1 | grep -E "Running build hook|applespi|acpi_call|ERROR|WARNING"
#   must show: -> Running build hook: [applespi-force]
sudo limine-update
sudo reboot
sudo dmesg | grep -iE "acpi_call|modeswitch"     # both at ~1–3 s, not ~12 s
```

---

## 6. Part 3b — suspend / resume

Deep (S3) sleep wedges the SPI device until reboot; s2idle works.

### 6.1 `/etc/systemd/sleep.conf.d/mac-s2idle.conf`

```ini
[Sleep]
MemorySleepMode=s2idle
```

(`mem_sleep_default=s2idle` on the kernel cmdline is set in section 3.) Verify: `cat /sys/power/mem_sleep` → `[s2idle] deep`.

### 6.2 Sleep hook + shell-restart user unit

Constraints the hook is built around:

1. `applespi` wedges across sleep → unload in `pre`, reload in `post`.
2. `brcmfmac` refuses to enter D3 (`-5`), which aborts the suspend and makes systemd retry in a loop (lid logo blinks every few seconds) → unload in `pre`.
3. After hibernate the BCM43602 comes back dead. A driver reload is not enough: the PCIe root port above it (`00:1c.2`, found via PCI class `0x028000`) must be removed and rescanned. NetworkManager then sees a hot-plug and reconnects on its own.
4. Restarting NetworkManager breaks the Omarchy shell's network widget (Quickshell's `Quickshell.Networking` D-Bus model does not re-attach; the bar shows "NOT CONNECTED" while `nmcli` is connected). The only repair is `omarchy-restart-shell`, which flickers the screen and refuses to run while the session is locked → restart NM + shell only as a fallback, and only after the unlock.
5. systemd keeps `user.slice`, including the lock screen, frozen until every sleep hook has returned → `post` does nothing slow; the Wi-Fi recovery runs detached via `systemd-run` (a `&` background job would be killed with `systemd-sleep`).
6. `suspend-then-hibernate` runs `post` → `pre` within ~300 ms at the s2idle → hibernate transition → `pre` stops a running Wi-Fi recovery and retries the `brcmfmac` unload (the module is "in use" while its firmware loads).
7. The shell restart runs as a user unit started with `systemctl --user --machine=<user>@.host`, because the user manager already carries the Hyprland environment. `omarchy-restart-shell`, not `omarchy-refresh-shell` (the latter resets `~/.config/omarchy/shell.json` to defaults first).

Resulting design (three pieces):

```
systemd-sleep ─post─▶ hook "post":  applespi-force                       keyboard back ~30 ms after resume
                                    systemd-run --unit=applespi-wifi-resume "$0" wifi-resume   (detached, returns at once)
              ─thaw user.slice ───▶ lock screen responsive immediately

applespi-wifi-resume.service (root): remove root port → rescan → modprobe brcmfmac → poll for wl* → udevadm settle
                                     → wait ≤ 8 s for NM to report the Wi-Fi device as usable (not "unavailable")
                                       ├─ yes (normal): done. NM reconnects itself, bar icon follows. No flicker.
                                       └─ no (fallback): restart wpa_supplicant NetworkManager
                                                         → systemctl --user --machine=<user>@.host start shell-refresh-on-resume.service

shell-refresh-on-resume.service (user, fallback only): wait until unlocked (poll 0.2 s) → omarchy-restart-shell
```

**`/usr/lib/systemd/system-sleep/applespi`** (mode 755; systemd has no `/etc` equivalent for this directory):

```sh
#!/bin/sh
# MacBookPro12,1 sleep hook (Omarchy)
#  pre : detach applespi (wedges across sleep) and brcmfmac (refuses D3 with -5, which aborts suspend)
#  post: reattach applespi right away, then hand the slow Wi-Fi recovery to a detached unit.
#        user.slice (and with it the lock screen) stays frozen until this hook returns, so
#        nothing slow may run here or keyboard/trackpad/lock screen are dead for seconds.
#  wifi-resume (run detached via systemd-run): power-cycle the Wi-Fi PCIe slot (BCM43602 comes
#        back dead after hibernate) and reload brcmfmac. NetworkManager normally treats that as a
#        hot-plug and reconnects by itself; the bar follows along. Only if NM does not get a working
#        supplicant interface: restart wpa_supplicant + NetworkManager, which in turn requires
#        restarting the Omarchy shell (Quickshell's network model does not survive an NM restart,
#        and the restart flickers the whole screen - hence last resort)
WIFI_CLASS=0x028000      # PCI class of the BCM43602 (network controller, other)
WIFI_UNIT=applespi-wifi-resume

wifi_dev() { grep -lx "$WIFI_CLASS" /sys/bus/pci/devices/*/class 2>/dev/null | head -1 | xargs -r dirname; }
wifi_up()  { ls /sys/class/net 2>/dev/null | grep -q '^wl'; }
# NM keeps a Wi-Fi device "unavailable" until wpa_supplicant has a working interface for it
nm_wifi_ok() { nmcli -t -f TYPE,STATE device 2>/dev/null | grep -qE '^wifi:(disconnected|connecting|connected|need-auth)'; }

case "$1" in
    pre)
        # suspend-then-hibernate runs post -> pre within 300 ms at the s2idle -> hibernate transition;
        # don't race a running recovery
        systemctl stop "$WIFI_UNIT.service" 2>/dev/null
        modprobe -r applespi
        # brcmfmac is "in use" while its firmware is still loading (rescan autoloads it), so retry briefly
        i=0
        until { modprobe -r brcmfmac_wcc; modprobe -r brcmfmac; } 2>/dev/null || [ $i -ge 25 ]; do
            sleep 0.2; i=$((i+1))
        done
        ;;
    post)
        /usr/local/bin/applespi-force
        systemd-run --quiet --collect --no-block --unit="$WIFI_UNIT" "$0" wifi-resume
        ;;
    wifi-resume)
        dev=$(wifi_dev)
        if [ -n "$dev" ]; then
            port=$(readlink -f "$dev/..")          # PCIe root port above the card (0000:00:1c.2)
            echo 1 > "$port/remove"
            sleep 1
        fi
        echo 1 > /sys/bus/pci/rescan
        modprobe brcmfmac
        # firmware load takes ~1s; poll instead of sleeping, then let udev finish the wlan0 -> wlp3s0 rename
        i=0; while [ $i -lt 60 ] && ! wifi_up; do sleep 0.2; i=$((i+1)); done
        udevadm settle -t 3

        i=0; while [ $i -lt 40 ] && ! nm_wifi_ok; do sleep 0.2; i=$((i+1)); done
        if nm_wifi_ok; then
            echo "NetworkManager picked up the re-created Wi-Fi interface; no restart needed"
            exit 0
        fi

        echo "NetworkManager did not recover the Wi-Fi interface; restarting wpa_supplicant + NetworkManager"
        systemctl restart wpa_supplicant NetworkManager

        # The user unit waits for the unlock itself (omarchy-restart-shell refuses while locked)
        qs_pid=$(pgrep -x quickshell | head -1)
        if [ -n "$qs_pid" ]; then
            qs_user=$(stat -c %U "/proc/$qs_pid")
            systemctl --user --machine="$qs_user@.host" start --no-block shell-refresh-on-resume.service
        fi
        ;;
esac
```

**`~/.local/bin/shell-refresh-on-resume`** (mode 755):

```bash
#!/bin/bash
# Started by /usr/lib/systemd/system-sleep/applespi after resume, once NetworkManager is back.
# NetworkManager gets restarted there, which leaves the Omarchy shell's network
# widget bound to the dead NM instance, so the shell has to be restarted.
# omarchy-restart-shell refuses to run while the session is locked, so wait
# for the unlock first (exit 0 = locked, 1 = unlocked, 2 = undetermined).
# No need to wait for connectivity: the fresh shell tracks the new NM live.

while omarchy-hyprland-session-locked; do sleep 0.2; done

exec omarchy-restart-shell
```

**`~/.config/systemd/user/shell-refresh-on-resume.service`** (static, started by the hook; no `[Install]`):

```ini
[Unit]
Description=Restart Omarchy shell after resume (NetworkManager restarted, Wi-Fi interface recreated)

[Service]
Type=oneshot
ExecStart=%h/.local/bin/shell-refresh-on-resume
```

```bash
sudo chmod 755 /usr/lib/systemd/system-sleep/applespi
chmod 755 ~/.local/bin/shell-refresh-on-resume
systemctl --user daemon-reload
systemctl suspend      # wake → keyboard works at once on the lock screen; Wi-Fi reconnects by itself within a few seconds
systemctl hibernate    # resume → same
```

Logs:

```bash
sudo journalctl -b -o short-monotonic | grep -iE "PM: |brcmfmac|Failed to put" | tail -15   # good: one "suspend entry (s2idle)" → "suspend exit", no "returns -5"
sudo journalctl -b -u applespi-wifi-resume              # which path the Wi-Fi recovery took ("no restart needed" = normal)
journalctl -b --user-unit shell-refresh-on-resume       # shell restart (fallback only)
sudo journalctl -b -t systemd-sleep                     # hook errors
```

Tunable: `sleep 1` after removing the root port. If Wi-Fi ever stays dead after hibernate, raise it to `sleep 2`; it only delays Wi-Fi, not input.

Manual Wi-Fi recovery (same steps as the hook, including the shell restart): `sudo /usr/lib/systemd/system-sleep/applespi wifi-resume`.

Diagnosing sleep problems: `cat /proc/acpi/wakeup` (ACPI wake devices), `sudo cat /sys/kernel/debug/wakeup_sources` (event counts), and the journal grep above. `Some devices failed to suspend` / `Failed to put system to sleep` means a device refusing to suspend, not a wake source.

Trade-off: s2idle drains ~10 %/day closed. Shut down for long stretches, or use hibernation (section 7; needs a disk-backed swapfile with non-negative priority, zram alone won't hibernate).

---

## 7. Hibernation (btrfs swapfile on a top-level `@swap` subvolume)

Omarchy's `omarchy-hibernation-setup` creates the swapfile in a subvolume **nested under `@`** (`@/swap`). systemd ≥ 259 refuses to hibernate into that (`CanHibernate` reports unavailable, `systemctl hibernate` silently does nothing). Fix: move it to a top-level `@swap` subvolume mounted at `/swap` (same layout as Omarchy PR #12176).

### 7.1 Diagnose

```bash
busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate   # want: s "yes"
# NOTE: `systemctl show -p CanHibernate` prints nothing either way — it is a logind property, not a PID-1 one.
swapon --show                                          # PRIO must be >= 0 (negative priority swap is ignored for hibernation)
sudo btrfs subvolume list / | grep -i swap             # want: "top level 5 path @swap"; "top level 256 path swap" = nested (bad)
findmnt /swap                                          # want: subvol=/@swap
grep -oE "resume=[^ ]*|resume_offset=[^ ]*" /proc/cmdline
sudo btrfs inspect-internal map-swapfile -r /swap/swapfile   # must equal resume_offset
```

### 7.2 Move the swapfile to a top-level subvolume

```bash
sudo swapoff /swap/swapfile
sudo mkdir -p /mnt/top
sudo mount -t btrfs -o subvolid=5 /dev/mapper/root /mnt/top
sudo btrfs subvolume delete /mnt/top/@/swap
sudo btrfs subvolume create /mnt/top/@swap
sudo chattr +C /mnt/top/@swap
sudo umount /mnt/top
sudo mkdir -p /swap
```

`sudo nano /etc/fstab` — mount line **above** the swapfile line:

```
/dev/mapper/root  /swap  btrfs  subvol=@swap,nodatacow,noatime  0 0
/swap/swapfile    none   swap   defaults,pri=0                  0 0
```

```bash
sudo systemctl daemon-reload
sudo mount /swap
sudo btrfs filesystem mkswapfile --size 18g /swap/swapfile      # RAM (16 GB) + 2 GB headroom
sudo swapon -a                                                  # via fstab, so it gets pri=0 (a bare `swapon` gives -1)
OFF=$(sudo btrfs inspect-internal map-swapfile -r /swap/swapfile); echo $OFF
sudo sed -i "s/resume_offset=[0-9]*/resume_offset=$OFF/" /etc/limine-entry-tool.d/resume.conf /etc/default/limine
sudo limine-update
```

The `resume` initramfs hook and `resume=/dev/mapper/root resume_offset=…` kernel parameters were already in place from `omarchy-hibernation-setup` (`/etc/mkinitcpio.conf.d/omarchy_resume.conf`, `/etc/limine-entry-tool.d/resume.conf`).

### 7.3 Test and read the log correctly

```bash
systemctl hibernate        # machine powers off; power button → LUKS prompt (built-in keyboard works) → session restored
sudo journalctl -b -o short-iso --no-pager | grep -iE "hibernation entry|hibernation exit" | tail -2
```

A resumed system keeps the same boot ID, and its journal is the snapshot taken *before* the image was written: `journalctl -b -1` is empty and there are no "Image saving/restored" lines. Success = a wall-clock gap of tens of seconds between `hibernation entry` and `hibernation exit` with monotonic time barely moving, then `modeswitch done` and `brcmfmac` re-registering. An abort = ~1 s gap with an error in between.

### 7.4 `HibernateMode=shutdown` (power off instead of ACPI S4)

```ini
# /etc/systemd/sleep.conf.d/mac-hibernate-shutdown.conf
[Sleep]
HibernateMode=shutdown
```

The default (`platform`) enters ACPI S4 after writing the image, which keeps wake sources armed (`/proc/acpi/wakeup`: `LID0` and `ARPT` are S4-capable). `shutdown` does a plain power-off after the image is written. Verify: `cat /sys/power/disk` → `[shutdown]`. Takes effect on the next sleep (`systemd-sleep` reads the config each time). The installer's `hibernation` phase writes this file.

### 7.5 Mac does not stay off after hibernate → SMC reset

Symptom: the image is written fine, but the machine restarts itself within about a minute of the power-off and is found at the LUKS prompt (Apple logo lit with the lid shut). Entering the passphrase restores the session, so hibernation itself is not the problem. Not caused by ACPI wake sources or the sleep path.

**Fix: SMC reset** (22 Sept 2026). Shut down, hold left Shift + Control + Option together with the power button for 10 s, release, then power on. Every hibernate since has stayed off. If it ever comes back, the next step is an NVRAM reset (Cmd + Option + P + R held through two chimes).

To test a cycle: `sudo systemctl hibernate`, touch nothing for 2 minutes and watch. Back at the LUKS prompt by itself = failure; still dark = good. The power-off is never logged (see 7.3), so only watched cycles count; `mbp-hib-report` (`~/.local/bin`) lists the cycles of the current boot with their entry→resume gap.

### 7.6 Optional: suspend-then-hibernate on lid close

```ini
# /etc/systemd/sleep.conf.d/hibernate-delay.conf
[Sleep]
HibernateDelaySec=2h

# /etc/systemd/logind.conf.d/lid.conf
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
```

`sudo systemctl restart systemd-logind` (logs you out) or reboot. The sleep hooks run around **both** sleep operations: `pre` → s2idle → `post` → (RTC wake after `HibernateDelaySec`) → `pre` again within ~300 ms → hibernate → `post`; the hook's `pre` handles that (6.2). The RTC wake needs `cat /sys/module/rtc_cmos/parameters/use_acpi_alarm` → `Y`; on this machine the driver enables it by itself. Only add `rtc_cmos.use_acpi_alarm=1` to the cmdline if it reads `N`.

---

## 8. Files touched (summary)

| File | Purpose |
|---|---|
| `/etc/default/limine` | `initcall_blacklist=dw_pci_driver_init mem_sleep_default=s2idle` |
| `/usr/local/bin/applespi-force` | UIEN 0 / SIEN 1 / reload applespi |
| `/etc/systemd/system/applespi-force.service` | runs the script at boot (main system) |
| `/etc/initcpio/install/applespi-force` | adds modules + runscript to initramfs |
| `/etc/initcpio/hooks/applespi-force` | early hook: switch to SPI before LUKS prompt |
| `/etc/mkinitcpio.conf.d/zz-applespi-force.conf` | `HOOKS+=(applespi-force)` |
| `/etc/systemd/sleep.conf.d/mac-s2idle.conf` | force s2idle |
| `/etc/systemd/sleep.conf.d/mac-hibernate-shutdown.conf` | `HibernateMode=shutdown`: plain power-off after hibernate instead of ACPI S4 (7.4) |
| `/usr/lib/systemd/system-sleep/applespi` | `pre`: detach `applespi` + `brcmfmac`; `post`: reattach `applespi`, spawn detached `applespi-wifi-resume` unit (root-port power cycle; only if NM doesn't recover: restart supplicant/NM + trigger the user unit) |
| `~/.local/bin/shell-refresh-on-resume` | fallback only: wait for unlock, then `omarchy-restart-shell` |
| `~/.config/systemd/user/shell-refresh-on-resume.service` | user unit wrapping the script; started by the hook via `systemctl --user --machine=` |
| `/etc/fstab` | `@swap` subvolume mounted at `/swap` + swapfile with `pri=0` |
| `/etc/limine-entry-tool.d/resume.conf` | `resume=/dev/mapper/root resume_offset=<from map-swapfile>` (written by Omarchy, offset updated) |

---

## 9. Maintenance & quirks

- `acpi_call` is DKMS: rebuilds on kernel updates as long as `linux-omarchy-headers` stays installed. Check `sudo dkms status`, `ls /lib/modules/$(uname -r)/updates/dkms/`.
- `mkinitcpio -P` runs on kernel updates and picks the hook up automatically.
- If the ACPI path ever changes, re-read `firmware_node/path` and update the script (4.3) and hook (5.2).
- Harmless dmesg: `Unknown touchpad model 3 – falling back to MB8 touchpad` (no geometry table for the 12,1); one `crc mismatch` during the mode switch.
- Trackpad tuning: Super + Space → Setup → Input, or `omarchy-trackpad-plus`.
- The `rfkill`/`iw` PHY index (`phy0` → `phy3`…) climbs by one on every resume because the card is re-enumerated; harmless.
- The bar is Quickshell (`quickshell -p /usr/share/omarchy/shell`); `omarchy-restart-shell` restarts it (refuses while locked). `omarchy-refresh-shell` also resets `~/.config/omarchy/shell.json` to defaults; don't automate that one.
- The `dmesg | grep` checks in sections 3–5 only work shortly after boot (ring buffer). Later use `sudo journalctl -k -b | grep …`; early-boot lines there all carry the journald start time, so judge the initramfs hook by order (`acpi_call: loading` before `BTRFS info … first mount`), which is what `--verify` does.
- `journalctl` for system units needs `sudo`; `/boot` is root-only; the UKI is an `.efi`, readable with `lsinitcpio`.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `applespi: USB interface already enabled` | firmware set USB mode | run/enable `applespi-force.service` |
| `usb 1-5: … error -71` | dead USB path on topcase | expected; use SPI mode |
| `applespi: SPI transfer timed out` / `-110` | LPSS DMA bug | `initcall_blacklist=dw_pci_driver_init` |
| unit `status=203/EXEC` "Permission denied" | script not executable | `chmod 755 /usr/local/bin/applespi-force` |
| `acpi_call` first loads at ~12 s, keyboard dead at LUKS | hook not in initramfs (drop-in clobbered) | `zz-` drop-in name, rebuild, check for build-hook line |
| keyboard dead after wake | S3 sleep or driver not reattached | s2idle + sleep hook; `sudo systemctl restart applespi-force` |
| lid closed → logo lights up every few seconds | `brcmfmac` fails D3 (`-5`), suspend aborts, systemd retries | unload/reload `brcmfmac` in the sleep hook (6.2) |
| Wi-Fi dead after hibernate: `wpa_supplicant: Failed to initialize driver interface`, NM `unavailable` then "giving up" | card not really reset by driver reload | root-port remove/rescan + restart `wpa_supplicant NetworkManager` (6.2) |
| bar shows "NOT CONNECTED" but `nmcli` connected | Quickshell network widget lost NetworkManager when it was restarted | `omarchy-restart-shell` (automated as fallback, 6.2); check `sudo journalctl -b -u applespi-wifi-resume` |
| `modprobe: FATAL: Module brcmfmac is in use` at the s2idle → hibernate transition | `post` → `pre` back-to-back, driver still loading firmware | `pre` stops `applespi-wifi-resume` and retries the unload (6.2) |
| `CanHibernate` = "na"/empty, `systemctl hibernate` does nothing | swapfile on nested `@/swap` subvolume, or swap PRIO < 0 | top-level `@swap` (7.2); activate swap via fstab |
| hibernated Mac found powered on at the LUKS prompt (Apple logo lit with the lid shut) | power-off after the image write did not stick (SMC state, not a wake source or the sleep path) | SMC reset (7.5); NVRAM reset if it recurs |
| `resume_offset` wrong after recreating swapfile | offset not recomputed | `btrfs inspect-internal map-swapfile -r`, update resume.conf, `limine-update` |

---

## 11. Sources

- Omarchy manual, Mac support — `omarchy.org/manual/mac-support/`
- Omarchy issue #1954 (MacBook8,1 applespi timeouts, DMA root cause) · PR #9735 (PIO switch for 8,1)
- `openwebcraft.com/archive/2026/omarchy-4-on-12-macbook8-1` · `gist.github.com/matthiasjg/78aaf7802146f0b89be3da9e4feb111f`
- Kernel `drivers/input/keyboard/applespi.c` (UIEN/UIST/SIEN/SIST)

Worth reporting in issue #1954: the 12,1 needs the PIO fix **and** a forced `SIEN` (dead USB path), so it can be added to the installer's automatic Mac fixes.
