# MacBookPro12,1 — built-in keyboard & trackpad on Omarchy (applespi fix)

Reference for the 13" Early 2015 MacBook Pro (`MacBookPro12,1`). Omarchy 4.x, kernel `linux-omarchy` 7.x, systemd 261, Limine + LUKS + btrfs, busybox initramfs. Covers keyboard/trackpad, LUKS prompt, suspend and hibernation. Compiled 18–20 Sept 2026.

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

### 6.2 `/usr/lib/systemd/system-sleep/applespi`

Four things go wrong around sleep on this machine, all handled in one hook:

1. `applespi` wedges across sleep → unload in `pre`, reload in `post`.
2. `brcmfmac` refuses to enter D3 (`-5`) → suspend aborts and systemd retries in a loop ("lid logo blinks every few seconds") → unload in `pre`.
3. After **hibernate** the BCM43602 comes back dead: a plain driver reload leaves `wpa_supplicant` failing with `Failed to initialize driver interface` until NetworkManager gives up ("supplicant interface keeps failing, giving up"). Removing only the endpoint (`03:00.0`) is not enough; the **PCIe root port** above it (`00:1c.2`) must be removed and rescanned (real slot power cycle), then `wpa_supplicant` and `NetworkManager` restarted because they have already given up on the old interface.
4. The Omarchy shell (Quickshell) keeps its network widget bound to the old interface and shows "NOT CONNECTED" although `nmcli` is connected → `omarchy-refresh-shell`, run as the session user with the session's environment (the hook runs as root without a Wayland session).

```sh
#!/bin/sh
# MacBookPro12,1 sleep hook (Omarchy)
#  pre : detach applespi (wedges across sleep) and brcmfmac (refuses D3 with -5, which aborts suspend)
#  post: power-cycle the Wi-Fi PCIe slot (BCM43602 comes back dead after hibernate), reload brcmfmac,
#        restart wpa_supplicant + NetworkManager (they give up on the recreated interface),
#        refresh the Omarchy shell (its network widget stays bound to the old interface),
#        then reattach applespi
WIFI_CLASS=0x028000      # PCI class of the BCM43602 (network controller, other)

wifi_dev() { grep -lx "$WIFI_CLASS" /sys/bus/pci/devices/*/class 2>/dev/null | head -1 | xargs -r dirname; }
wifi_up()  { ls /sys/class/net 2>/dev/null | grep -q '^wl'; }

case "$1" in
    pre)
        modprobe -r applespi
        modprobe -r brcmfmac_wcc 2>/dev/null
        modprobe -r brcmfmac
        ;;
    post)
        dev=$(wifi_dev)
        if [ -n "$dev" ]; then
            port=$(readlink -f "$dev/..")          # PCIe root port above the card (0000:00:1c.2)
            echo 1 > "$port/remove"
            sleep 2
        fi
        echo 1 > /sys/bus/pci/rescan
        sleep 2
        modprobe brcmfmac
        i=0; while [ $i -lt 10 ] && ! wifi_up; do sleep 1; i=$((i+1)); done
        systemctl restart wpa_supplicant NetworkManager

        # Refresh the shell as the session user, borrowing the running Quickshell's environment
        qs_pid=$(pgrep -x quickshell | head -1)
        if [ -n "$qs_pid" ]; then
            qs_user=$(stat -c %U "/proc/$qs_pid")
            qs_env=$(tr '\0' '\n' < "/proc/$qs_pid/environ" \
                | grep -E '^(XDG_RUNTIME_DIR|WAYLAND_DISPLAY|HYPRLAND_INSTANCE_SIGNATURE|DBUS_SESSION_BUS_ADDRESS|HOME|USER|PATH|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP)=' \
                | tr '\n' ' ')
            ( sleep 4; env -i $qs_env runuser -u "$qs_user" -- /usr/bin/omarchy-refresh-shell ) >/dev/null 2>&1 &
        fi

        /usr/local/bin/applespi-force
        ;;
esac
```

```bash
sudo chmod 755 /usr/lib/systemd/system-sleep/applespi
systemctl suspend      # wake → nmcli device status → connected; bar icon correct
systemctl hibernate    # resume → same
sudo journalctl -b -o short-monotonic | grep -iE "PM: |brcmfmac|Failed to put" | tail -15
#   good: one "suspend entry (s2idle)" → "suspend exit", no "returns -5", Wi-Fi re-registers
```

Manual recovery if Wi-Fi is ever dead after a resume (same steps the hook performs):

```bash
sudo modprobe -r brcmfmac
echo 1 | sudo tee /sys/bus/pci/devices/0000:00:1c.2/remove; sleep 2
echo 1 | sudo tee /sys/bus/pci/rescan; sleep 2
sudo modprobe brcmfmac; sleep 3
sudo systemctl restart wpa_supplicant NetworkManager
omarchy-refresh-shell
```

Diagnosing sleep problems: `cat /proc/acpi/wakeup` (ACPI wake devices), `sudo cat /sys/kernel/debug/wakeup_sources` (event counts), and the journal grep above. If the journal shows `Some devices failed to suspend` / `Failed to put system to sleep`, it is a device refusing to suspend, not a wake source.

Trade-off: s2idle drains ~10 %/day closed. Shut down for long stretches, or set up hibernation (needs a disk-backed swapfile with non-negative priority; zram alone won't hibernate — see the matthiasjg gist for suspend-then-hibernate).

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
systemctl hibernate        # machine powers off; power on → LUKS prompt (built-in keyboard works) → session restored
sudo journalctl -b -o short-iso --no-pager | grep -iE "hibernation entry|hibernation exit" | tail -2
```

A resumed system keeps the *same boot ID* and its log is the memory snapshot taken **before** the image was written, so `journalctl -b -1` is empty and you will not see "Image saving" or "Image restored" lines. Success is: a wall-clock gap of tens of seconds between `hibernation entry` and `hibernation exit` while monotonic time barely moves, followed by `modeswitch done` and `brcmfmac` re-registering (the sleep hook's `post` phase). An abort shows a ~1 s gap and an error between the two lines.

### 7.4 Optional: suspend-then-hibernate on lid close

```ini
# /etc/systemd/sleep.conf.d/hibernate-delay.conf
[Sleep]
HibernateDelaySec=2h

# /etc/systemd/logind.conf.d/lid.conf
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
```

`sudo systemctl restart systemd-logind` (logs you out) or reboot. The sleep hook runs `pre` once at the start and `post` once at the final wake, so applespi and brcmfmac are handled across the s2idle → hibernate transition. `rtc_cmos.use_acpi_alarm=1` (added by Omarchy's setup) lets the timer fire while asleep.

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
| `/usr/lib/systemd/system-sleep/applespi` | around sleep: detach/reattach `applespi`; unload `brcmfmac`, root-port power cycle, restart supplicant/NM, refresh shell |
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
- Omarchy 4 tooling lives in `/usr/bin/omarchy-*` (no `~/.local/share/omarchy/bin`); the bar is Quickshell (`quickshell -p /usr/share/omarchy/shell`), `omarchy-bar` is only its config CLI, and `omarchy-refresh-shell` reloads it.
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
| bar shows "NOT CONNECTED" but `nmcli` connected | Quickshell widget bound to old interface | `omarchy-refresh-shell` (automated in 6.2) |
| `CanHibernate` = "na"/empty, `systemctl hibernate` does nothing | swapfile on nested `@/swap` subvolume, or swap PRIO < 0 | top-level `@swap` (7.2); activate swap via fstab |
| `resume_offset` wrong after recreating swapfile | offset not recomputed | `btrfs inspect-internal map-swapfile -r`, update resume.conf, `limine-update` |

---

## 11. Sources

- Omarchy manual, Mac support — `omarchy.org/manual/mac-support/`
- Omarchy issue #1954 (MacBook8,1 applespi timeouts, DMA root cause) · PR #9735 (PIO switch for 8,1)
- `openwebcraft.com/archive/2026/omarchy-4-on-12-macbook8-1` · `gist.github.com/matthiasjg/78aaf7802146f0b89be3da9e4feb111f`
- Kernel `drivers/input/keyboard/applespi.c` (UIEN/UIST/SIEN/SIST)

Worth reporting in issue #1954: the 12,1 needs the PIO fix **and** a forced `SIEN` (dead USB path), so it can be added to the installer's automatic Mac fixes.
