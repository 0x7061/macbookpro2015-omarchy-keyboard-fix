# MacBookPro12,1 on Omarchy: built-in keyboard, trackpad, suspend, hibernation

For the 13" Early 2015 MacBook Pro (`MacBookPro12,1`) on Omarchy 4.x (kernel `linux-omarchy` 7.x, Limine, LUKS, btrfs, busybox initramfs).

The keyboard and trackpad are dead out of the box: the firmware puts the topcase in USB mode, the USB path does not work on this model, and the SPI path hangs on the Broadwell DMA engine. The fix is to run SPI in PIO mode, switch the topcase to SPI at every boot (also in the initramfs, for the LUKS prompt) and reload the drivers around sleep.

## Automated

`mbp12-omarchy-fix.sh` does everything below. Run it as your normal user; it calls `sudo` itself, skips unchanged files and backs up what it changes to `/root/mbp12-fix-backups/<timestamp>/`.

```bash
./mbp12-omarchy-fix.sh --dry-run     # show what would change
./mbp12-omarchy-fix.sh               # steps 1-6
sudo reboot                          # keep a USB keyboard attached for this first reboot
./mbp12-omarchy-fix.sh --verify      # read-only checks

sudo omarchy-hibernation-setup       # optional, step 7: hibernation (recreates the swapfile)
./mbp12-omarchy-fix.sh --phase hibernation [--yes] [--swap-size 18g]
```

`--phase <name>` runs one step: `kernel-params`, `acpi-call`, `switch`, `initramfs`, `sleep`, `trackpad`, `hibernation`, `verify`.

## Manual steps

### 1. Kernel parameters

`initcall_blacklist=dw_pci_driver_init` makes the SPI controller use PIO; `mem_sleep_default=s2idle` because S3 sleep wedges the topcase until reboot.

Append to `/etc/default/limine`:

```
KERNEL_CMDLINE[default]+=" initcall_blacklist=dw_pci_driver_init mem_sleep_default=s2idle"
```

```bash
sudo limine-update
```

### 2. acpi_call

Needed to call the ACPI methods that switch the topcase to SPI.

```bash
sudo pacman -S --needed dkms base-devel linux-omarchy-headers
yay -S acpi_call-dkms
```

### 3. Switch to SPI at boot

`/usr/local/bin/applespi-force` (mode 755):

```sh
#!/bin/sh
P='\_SB_.PCI0.SPI1.SPIT'
modprobe acpi_call
echo "$P.UIEN 0" > /proc/acpi/call
echo "$P.SIEN 1" > /proc/acpi/call
modprobe -r applespi
modprobe applespi
```

`/etc/systemd/system/applespi-force.service`:

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
sudo chmod 755 /usr/local/bin/applespi-force
sudo systemctl enable --now applespi-force.service
```

### 4. Initramfs hook (keyboard at the LUKS prompt)

The hook does the same switch before the passphrase prompt, retries up to 3 times, and powers the machine off if the disk is not unlocked within 10 minutes.

`/etc/initcpio/install/applespi-force`:

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

`/etc/initcpio/hooks/applespi-force`:

```sh
#!/usr/bin/ash
# Switch the MacBookPro12,1 topcase to SPI before the LUKS prompt; retry if it does not answer.
# Also arms a watchdog: root not unlocked within APPLESPI_LUKS_TIMEOUT seconds -> power off, so a
# dead keyboard (or a self-wake after hibernate) cannot drain the battery at the prompt. Nothing is
# mounted yet at that point, so a pending hibernation image stays intact and the next boot resumes.
# Results go to /dev/kmsg ("applespi-force: ..." in the journal, cold boots only - a resume
# replaces this kernel's log with the image's).
APPLESPI_TRIES=3
APPLESPI_LUKS_TIMEOUT=600
APPLESPI_USB_PORT='/sys/bus/usb/devices/usb1/1-0:1.0/usb1-port5'

applespi_log() { echo "applespi-force: $*" > /dev/kmsg; }
# the touchpad input device is only registered once the topcase has answered over SPI
applespi_alive() { grep -qx 'Apple SPI Touchpad' /sys/class/input/input*/name 2>/dev/null; }

run_earlyhook() {
    local P='\_SB_.PCI0.SPI1.SPIT' try=1 i port_off=0 root_dev="${root:-/dev/mapper/root}"
    modprobe acpi_call
    modprobe intel_lpss_pci
    modprobe spi_pxa2xx_pci
    modprobe spi_pxa2xx_platform
    # The kernel is enumerating the dead USB side of the topcase (usb 1-5) right about now. UIEN 0 in
    # the middle of that leaves the hub waiting for 3 x 5 s descriptor timeouts, and udev - and with
    # it the splash and the LUKS prompt - waits along (black screen). So power the port off first:
    # the write only returns once the hub is done with the port (early_stop: after one failed try).
    if [ -e "$APPLESPI_USB_PORT/disable" ]; then
        echo 1 2>/dev/null > "$APPLESPI_USB_PORT/early_stop"
        echo 1 2>/dev/null > "$APPLESPI_USB_PORT/disable" && port_off=1
    fi
    while :; do
        printf '%s\n' "$P.UIEN 0" > /proc/acpi/call
        printf '%s\n' "$P.SIEN 1" > /proc/acpi/call
        modprobe -r applespi 2>/dev/null
        modprobe applespi
        i=0; while [ $i -lt 30 ] && ! applespi_alive; do sleep 0.1; i=$((i+1)); done
        if applespi_alive; then applespi_log "topcase up (attempt $try)"; break; fi
        applespi_log "no answer from topcase (attempt $try of $APPLESPI_TRIES)"
        [ $try -ge $APPLESPI_TRIES ] && break
        # in case the topcase does depend on that port's power after all: the keyboard matters more
        if [ $port_off = 1 ]; then
            echo 0 2>/dev/null > "$APPLESPI_USB_PORT/disable"; port_off=0
            applespi_log "USB port powered back on"
        fi
        try=$((try+1)); sleep 1
    done

    (
        t=0
        while [ $t -lt $APPLESPI_LUKS_TIMEOUT ]; do
            [ -e "$root_dev" ] && exit 0
            sleep 5; t=$((t+5))
        done
        applespi_log "$root_dev not unlocked after ${APPLESPI_LUKS_TIMEOUT}s, powering off"
        sleep 1
        poweroff -f
    ) </dev/null >/dev/null 2>&1 &
    APPLESPI_WATCHDOG=$!
}

# the watchdog exits by itself once root is unlocked; make sure it never survives switch_root
run_cleanuphook() {
    [ -n "$APPLESPI_WATCHDOG" ] && kill "$APPLESPI_WATCHDOG" 2>/dev/null
    return 0
}
```

`/etc/mkinitcpio.conf.d/zz-applespi-force.conf` (the name must sort after `omarchy_hooks.conf`):

```
HOOKS+=(applespi-force)
```

```bash
sudo mkinitcpio -P      # must show: -> Running build hook: [applespi-force]
sudo limine-update
sudo reboot
```

### 5. Suspend and resume

`/etc/systemd/sleep.conf.d/mac-s2idle.conf`:

```ini
[Sleep]
MemorySleepMode=s2idle
```

The sleep hook unloads `applespi` and `brcmfmac` before sleep. After resume it reloads `applespi` and revives Wi-Fi in a detached unit: remove the card, rescan, reload `brcmfmac`. It must remove only the card, never the PCIe root port above it (`00:1c.2`), or the machine no longer stays off at the next power-off.

`/usr/lib/systemd/system-sleep/applespi` (mode 755):

```sh
#!/bin/sh
# MacBookPro12,1 sleep hook (Omarchy)
#  pre : detach applespi (wedges across sleep) and brcmfmac (refuses D3 with -5, which aborts suspend)
#  post: reattach applespi right away, then hand the slow Wi-Fi recovery to a detached unit.
#        user.slice (and with it the lock screen) stays frozen until this hook returns, so
#        nothing slow may run here or keyboard/trackpad/lock screen are dead for seconds.
#  wifi-resume (run detached via systemd-run): remove + rescan the Wi-Fi card (BCM43602 comes
#        back dead after hibernate) and reload brcmfmac. Only the card, not the root port above
#        it: removing 0000:00:1c.2 makes the next power-off bounce or hang dark-but-on.
#        NetworkManager normally treats that as a hot-plug and reconnects by itself; the bar
#        follows along. Only if NM does not get a working supplicant interface: restart
#        wpa_supplicant + NetworkManager, which in turn requires
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
        # a lid shut again right after a wake runs post -> pre back to back; don't race a running recovery
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
            echo 1 > "$dev/remove"
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

If NetworkManager has to be restarted, the Omarchy shell's network widget loses it, so the hook starts this user unit, which restarts the shell once the session is unlocked.

`~/.local/bin/shell-refresh-on-resume` (mode 755):

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

`~/.config/systemd/user/shell-refresh-on-resume.service`:

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
```

### 6. Trackpad: ignore the palm while typing

libinput disables the trackpad while typing only if it knows the keyboard is built in. Its stock rule for this keyboard expects vendor `0x05AC`, but `applespi` reports vendor 0, so the keyboard has to be marked by hand.

`/etc/libinput/local-overrides.quirks`:

```ini
[Apple SPI Keyboard (applespi reports vendor 0)]
MatchUdevType=keyboard
MatchBus=spi
MatchName=Apple SPI Keyboard
AttrKeyboardIntegration=internal
```

Log out and back in (or reboot).

### 7. Hibernation (optional)

`omarchy-hibernation-setup` puts the swapfile in a subvolume nested under `@`, which systemd 259 and later refuses to hibernate into. Move it to a top-level `@swap` subvolume. This deletes and recreates the swapfile.

```bash
sudo omarchy-hibernation-setup
sudo swapoff /swap/swapfile
sudo mkdir -p /mnt/top
sudo mount -t btrfs -o subvolid=5 /dev/mapper/root /mnt/top
sudo btrfs subvolume delete /mnt/top/@/swap
sudo btrfs subvolume create /mnt/top/@swap
sudo chattr +C /mnt/top/@swap
sudo umount /mnt/top
sudo mkdir -p /swap
```

In `/etc/fstab`, with the mount line above the swapfile line:

```
/dev/mapper/root  /swap  btrfs  subvol=@swap,nodatacow,noatime  0 0
/swap/swapfile    none   swap   defaults,pri=0                  0 0
```

```bash
sudo systemctl daemon-reload
sudo mount /swap
sudo btrfs filesystem mkswapfile --size 18g /swap/swapfile      # RAM + 2 GB
sudo swapon -a
OFF=$(sudo btrfs inspect-internal map-swapfile -r /swap/swapfile)
sudo sed -i "s/resume_offset=[0-9]*/resume_offset=$OFF/" /etc/limine-entry-tool.d/resume.conf /etc/default/limine
```

`/etc/systemd/sleep.conf.d/mac-hibernate-shutdown.conf` (plain power-off after the image is written, instead of ACPI S4; hibernate after 30 minutes of suspend):

```ini
[Sleep]
HibernateMode=shutdown
HibernateDelaySec=30min
```

`/etc/systemd/logind.conf.d/30-mac-lid-hibernate.conf` (lid close suspends, then hibernates after the delay above):

```ini
[Login]
HandleLidSwitch=suspend-then-hibernate
```

`/etc/UPower/UPower.conf.d/60-mac-critical-hibernate.conf` (hibernate at 5 % battery while awake):

```ini
[UPower]
PercentageCritical=10.0
PercentageAction=5.0
CriticalPowerAction=Hibernate
```

```bash
sudo systemctl restart upower
sudo systemctl kill -s HUP systemd-logind
sudo limine-update
sudo reboot
```

## Verify

`./mbp12-omarchy-fix.sh --verify` runs these and more.

```bash
grep -oE "initcall_blacklist=[^ ]*|mem_sleep_default=[^ ]*" /proc/cmdline
sudo journalctl -k -b | grep -E "using PIO|modeswitch done|applespi-force:"   # want: "topcase up (attempt 1)"
systemctl is-active applespi-force.service
cat /sys/power/mem_sleep                                          # [s2idle] deep
grep -c 'port/remove' /usr/lib/systemd/system-sleep/applespi      # 0
sudo journalctl -b -u applespi-wifi-resume                        # after a resume: "no restart needed"
libinput quirks list /dev/input/event6                            # AttrKeyboardIntegration=internal (event number: see /proc/bus/input/devices)
```

Hibernation only:

```bash
busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate   # s "yes"
swapon --show                                                     # PRIO 0
sudo btrfs inspect-internal map-swapfile -r /swap/swapfile        # equals resume_offset in /proc/cmdline
cat /sys/power/disk                                               # [shutdown]
busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager HandleLidSwitch   # s "suspend-then-hibernate"
upower -d | grep critical-action                                  # Hibernate
```
