#!/usr/bin/env bash
# =============================================================================
# mbp12-omarchy-fix.sh — built-in keyboard/trackpad, suspend and hibernation
# for the MacBook Pro 13" Early 2015 (MacBookPro12,1) on Omarchy (Arch/Limine/LUKS/btrfs)
#
# Implements, idempotently and with verification after every step:
#   kernel-params  initcall_blacklist=dw_pci_driver_init (SPI → PIO), mem_sleep_default=s2idle
#   acpi-call      acpi_call-dkms (AUR) + matching kernel headers
#   switch         /usr/local/bin/applespi-force (UIEN 0 / SIEN 1 / reload applespi) + systemd unit
#   initramfs      busybox early hook so the keyboard works at the LUKS passphrase prompt
#   sleep          s2idle drop-in + system-sleep hook (applespi/brcmfmac detach; on resume applespi is
#                  reattached immediately, Wi-Fi slot power-cycle + supplicant/NM restart run detached)
#                  + user unit that restarts the Omarchy shell once the session is unlocked
#   hibernation    (OPT-IN) move the btrfs swapfile to a top-level @swap subvolume, fix resume_offset
#   verify         read-only checks; run this after each reboot
#
# Usage:
#   ./mbp12-omarchy-fix.sh                 run all non-destructive phases (everything except hibernation)
#   ./mbp12-omarchy-fix.sh --verify        checks only, no changes
#   ./mbp12-omarchy-fix.sh --dry-run       show what would be written/run
#   ./mbp12-omarchy-fix.sh --phase sleep   run a single phase (preflight always runs first)
#   ./mbp12-omarchy-fix.sh --phase hibernation [--yes] [--swap-size 18g]
#   ./mbp12-omarchy-fix.sh --force-model   skip the MacBookPro12,1 check (e.g. MacBook8,1)
#
# Run as your normal user (needs sudo; the AUR helper refuses to run as root).
# Exits non-zero at the first failed step; nothing after a failed step is touched.
# Backups of every system file it modifies go to /root/mbp12-fix-backups/<timestamp>/
# (files under $HOME get a .bak.<timestamp> copy next to them)
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------- config
EXPECTED_MODEL="MacBookPro12,1"
KPARAMS=("initcall_blacklist=dw_pci_driver_init" "mem_sleep_default=s2idle")
SPI_NODE="/sys/bus/spi/devices/spi-APP000D:00"
SWITCH_SCRIPT="/usr/local/bin/applespi-force"
UNIT_FILE="/etc/systemd/system/applespi-force.service"
HOOK_INSTALL="/etc/initcpio/install/applespi-force"
HOOK_RUNTIME="/etc/initcpio/hooks/applespi-force"
HOOK_CONF="/etc/mkinitcpio.conf.d/zz-applespi-force.conf"
SLEEP_CONF="/etc/systemd/sleep.conf.d/mac-s2idle.conf"
HIBERNATE_CONF="/etc/systemd/sleep.conf.d/mac-hibernate-shutdown.conf"
SLEEP_HOOK="/usr/lib/systemd/system-sleep/applespi"
SHELL_REFRESH_SCRIPT="$HOME/.local/bin/shell-refresh-on-resume"
SHELL_REFRESH_UNIT="$HOME/.config/systemd/user/shell-refresh-on-resume.service"
LIMINE_CONF="/etc/default/limine"
RESUME_DROPIN="/etc/limine-entry-tool.d/resume.conf"
OMARCHY_RESUME_CONF="/etc/mkinitcpio.conf.d/omarchy_resume.conf"
SWAP_MNT="/swap"
SWAP_FILE="/swap/swapfile"
SWAP_SUBVOL="@swap"
BACKUP_ROOT="/root/mbp12-fix-backups"

# ----------------------------------------------------------------------------- flags
PHASE="all"; DRY_RUN=0; VERIFY_ONLY=0; FORCE_MODEL=0; ASSUME_YES=0; SWAP_SIZE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verify) VERIFY_ONLY=1; shift ;;
    --force-model) FORCE_MODEL=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --swap-size) SWAP_SIZE="$2"; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------- helpers
C_INFO=$'\e[1;34m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'; C_RST=$'\e[0m'
STEP=""; CHANGED=0; NEEDS_REBUILD=0; NEEDS_REBOOT=0; BACKUP_DIR=""
info() { echo "${C_INFO}==>${C_RST} $*"; }
ok()   { echo "${C_OK}  ✓${C_RST} $*"; }
warn() { echo "${C_WARN}  !${C_RST} $*"; }
die()  { echo "${C_ERR}  ✗ $*${C_RST}" >&2; exit 1; }
step() { STEP="$1"; info "$1"; }
on_err() {
  local rc=$?
  echo "${C_ERR}✗ Failed during step: ${STEP:-startup} (exit $rc, line $1)${C_RST}" >&2
  [[ -n $BACKUP_DIR ]] && echo "  Backups of modified files: $BACKUP_DIR" >&2
  echo "  Nothing after the failed step was applied. Re-run after fixing the cause; completed steps are skipped." >&2
  exit $rc
}
trap 'on_err $LINENO' ERR

# run a privileged command (echo only in dry-run)
run() {
  if (( DRY_RUN )); then echo "  [dry-run] sudo $*"; else sudo "$@"; fi
}
backup() {
  local f="$1"
  [[ -e $f ]] || return 0
  if [[ -z $BACKUP_DIR ]]; then
    BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    (( DRY_RUN )) || sudo mkdir -p "$BACKUP_DIR"
  fi
  (( DRY_RUN )) || sudo cp -a "$f" "$BACKUP_DIR/$(echo "$f" | tr / _)"
}
# write_file <path> <mode> <<content ; idempotent, backs up, diffs in dry-run
write_file() {
  local path="$1" mode="$2" tmp
  tmp=$(mktemp); cat > "$tmp"
  if [[ -e $path ]] && sudo cmp -s "$tmp" "$path" && [[ $(sudo stat -c %a "$path") == "$mode" ]]; then
    ok "$path up to date"; rm -f "$tmp"; return 0
  fi
  if (( DRY_RUN )); then
    echo "  [dry-run] would write $path (mode $mode):"
    if [[ -e $path ]]; then sudo diff -u "$path" "$tmp" | sed 's/^/      /' || true; else sed 's/^/      | /' "$tmp"; fi
  else
    backup "$path"
    sudo install -D -m "$mode" "$tmp" "$path"
    ok "wrote $path"
  fi
  rm -f "$tmp"; CHANGED=1
}
# write_user_file <path> <mode> <<content ; same as write_file but unprivileged (files under $HOME)
write_user_file() {
  local path="$1" mode="$2" tmp
  tmp=$(mktemp); cat > "$tmp"
  if [[ -e $path ]] && cmp -s "$tmp" "$path" && [[ $(stat -c %a "$path") == "$mode" ]]; then
    ok "$path up to date"; rm -f "$tmp"; return 0
  fi
  if (( DRY_RUN )); then
    echo "  [dry-run] would write $path (mode $mode):"
    if [[ -e $path ]]; then diff -u "$path" "$tmp" | sed 's/^/      /' || true; else sed 's/^/      | /' "$tmp"; fi
  else
    [[ -e $path ]] && cp -a "$path" "$path.bak.$(date +%Y%m%d-%H%M%S)"
    install -D -m "$mode" "$tmp" "$path"
    ok "wrote $path"
  fi
  rm -f "$tmp"; CHANGED=1
}
confirm() {
  (( ASSUME_YES )) && return 0
  read -r -p "  $1 [y/N] " ans; [[ $ans == [yY]* ]]
}
kernel_has() { grep -qw -- "$1" /proc/cmdline; }
limine_has() { grep -qF -- "$1" "$LIMINE_CONF"; }

# ============================================================================= phases
phase_preflight() {
  step "Preflight"
  [[ $EUID -ne 0 ]] || die "run as your normal user, not root (the AUR helper refuses root)"
  sudo -v || die "sudo is required"
  local model; model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  if [[ $model != "$EXPECTED_MODEL" ]]; then
    (( FORCE_MODEL )) && warn "model is '$model', continuing because --force-model" \
      || die "model is '$model', expected $EXPECTED_MODEL (use --force-model to override)"
  else ok "model $model"; fi
  [[ -e $SPI_NODE/firmware_node/path ]] || die "SPI topcase device $SPI_NODE not found"
  ACPI_PATH=$(cat "$SPI_NODE/firmware_node/path"); ok "ACPI path $ACPI_PATH"
  [[ -f $LIMINE_CONF ]] || die "$LIMINE_CONF missing — is this Omarchy with Limine?"
  command -v limine-update >/dev/null || die "limine-update not found"
  command -v mkinitcpio  >/dev/null || die "mkinitcpio not found"
  grep -qE "^HOOKS=\(.*\bencrypt\b" /etc/mkinitcpio.conf.d/omarchy_hooks.conf 2>/dev/null \
    && ok "busybox initramfs (encrypt hook) confirmed" \
    || warn "could not confirm busybox 'encrypt' hook in omarchy_hooks.conf — the initramfs hook assumes it"
}

phase_kernel_params() {
  step "Kernel parameters"
  local missing=()
  for p in "${KPARAMS[@]}"; do limine_has "$p" || missing+=("$p"); done
  if (( ${#missing[@]} == 0 )); then ok "all present in $LIMINE_CONF"
  else
    backup "$LIMINE_CONF"
    local line="KERNEL_CMDLINE[default]+=\" ${missing[*]}\""
    if (( DRY_RUN )); then echo "  [dry-run] would append to $LIMINE_CONF: $line"
    else echo "$line" | sudo tee -a "$LIMINE_CONF" >/dev/null; ok "appended: $line"; fi
    CHANGED=1; NEEDS_REBUILD=1; NEEDS_REBOOT=1
  fi
  for p in "${KPARAMS[@]}"; do kernel_has "$p" || { warn "$p not active in the running kernel yet (reboot)"; NEEDS_REBOOT=1; }; done
}

phase_acpi_call() {
  step "acpi_call (DKMS) + kernel headers"
  local krel headers; krel=$(uname -r)
  case "$krel" in
    *omarchy*) headers=linux-omarchy-headers ;;
    *lts*)     headers=linux-lts-headers ;;
    *zen*)     headers=linux-zen-headers ;;
    *)         headers=linux-headers ;;
  esac
  run pacman -S --needed --noconfirm dkms base-devel "$headers"
  if modinfo acpi_call >/dev/null 2>&1; then ok "acpi_call module present"
  else
    local helper=""; for h in yay paru; do command -v $h >/dev/null && { helper=$h; break; }; done
    [[ -n $helper ]] || die "acpi_call missing and no AUR helper (yay/paru) found"
    if (( DRY_RUN )); then echo "  [dry-run] $helper -S --needed --noconfirm acpi_call-dkms"
    else $helper -S --needed --noconfirm acpi_call-dkms; fi
    (( DRY_RUN )) || modinfo acpi_call >/dev/null 2>&1 || die "acpi_call still not available after install — check 'sudo dkms status'"
    ok "acpi_call installed"; CHANGED=1
  fi
  run modprobe acpi_call
}

phase_switch() {
  step "Switch script + systemd unit"
  write_file "$SWITCH_SCRIPT" 755 <<EOF
#!/bin/sh
# MacBookPro12,1: force the topcase from (dead) USB to SPI, then (re)load applespi
P='$ACPI_PATH'
modprobe acpi_call
echo "\$P.UIEN 0" > /proc/acpi/call
echo "\$P.SIEN 1" > /proc/acpi/call
modprobe -r applespi
modprobe applespi
EOF
  write_file "$UNIT_FILE" 644 <<'EOF'
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
EOF
  run systemctl daemon-reload
  run systemctl enable applespi-force.service >/dev/null 2>&1 || true
  if kernel_has "initcall_blacklist=dw_pci_driver_init"; then
    run systemctl restart applespi-force.service
    (( DRY_RUN )) || { sleep 2; sudo dmesg | grep -i applespi | tail -1 | grep -q "modeswitch done" \
      && ok "applespi modeswitch done" || warn "no 'modeswitch done' in dmesg yet — check: sudo dmesg | grep -i applespi"; }
  else
    warn "PIO kernel param not active yet; not starting the switch now (would time out). It runs on next boot."
  fi
}

phase_initramfs() {
  step "Initramfs early hook (LUKS prompt)"
  local changed_before=$CHANGED
  [[ -e /etc/initcpio/applespi-force-initrd.service ]] && { backup /etc/initcpio/applespi-force-initrd.service; run rm -f /etc/initcpio/applespi-force-initrd.service; }
  write_file "$HOOK_INSTALL" 644 <<'EOF'
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
EOF
  write_file "$HOOK_RUNTIME" 644 <<EOF
#!/usr/bin/ash
run_earlyhook() {
    P='$ACPI_PATH'
    modprobe acpi_call
    printf '%s\n' "\$P.UIEN 0" > /proc/acpi/call
    printf '%s\n' "\$P.SIEN 1" > /proc/acpi/call
    modprobe intel_lpss_pci
    modprobe spi_pxa2xx_pci
    modprobe spi_pxa2xx_platform
    modprobe -r applespi 2>/dev/null
    modprobe applespi
}
EOF
  # "zz-" so it sorts after omarchy_hooks.conf, which reassigns HOOKS=(...) and would clobber a += that loads earlier
  write_file "$HOOK_CONF" 644 <<'EOF'
HOOKS+=(applespi-force)
EOF
  (( changed_before != CHANGED )) && NEEDS_REBUILD=1 || true
}

phase_sleep() {
  step "Suspend: s2idle + sleep hook"
  write_file "$SLEEP_CONF" 644 <<'EOF'
[Sleep]
MemorySleepMode=s2idle
EOF
  write_file "$SLEEP_HOOK" 755 <<'EOF'
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
EOF
  # user side: the hook starts this unit in the session user's manager once NetworkManager is back
  write_user_file "$SHELL_REFRESH_SCRIPT" 755 <<'EOF'
#!/bin/bash
# Started by /usr/lib/systemd/system-sleep/applespi after resume, once NetworkManager is back.
# NetworkManager gets restarted there, which leaves the Omarchy shell's network
# widget bound to the dead NM instance, so the shell has to be restarted.
# omarchy-restart-shell refuses to run while the session is locked, so wait
# for the unlock first (exit 0 = locked, 1 = unlocked, 2 = undetermined).
# No need to wait for connectivity: the fresh shell tracks the new NM live.

while omarchy-hyprland-session-locked; do sleep 0.2; done

exec omarchy-restart-shell
EOF
  write_user_file "$SHELL_REFRESH_UNIT" 644 <<'EOF'
[Unit]
Description=Restart Omarchy shell after resume (NetworkManager restarted, Wi-Fi interface recreated)

[Service]
Type=oneshot
ExecStart=%h/.local/bin/shell-refresh-on-resume
EOF
  if (( DRY_RUN )); then echo "  [dry-run] systemctl --user daemon-reload"; else systemctl --user daemon-reload; fi
  local ms; ms=$(cat /sys/power/mem_sleep 2>/dev/null || true)
  [[ $ms == *"[s2idle]"* ]] && ok "mem_sleep: $ms" || warn "mem_sleep is '$ms' — becomes [s2idle] after reboot"
}

phase_hibernation() {
  step "Hibernation: top-level @swap subvolume"
  [[ -f $RESUME_DROPIN && -f $OMARCHY_RESUME_CONF ]] \
    || die "run 'sudo omarchy-hibernation-setup' first (resume hook / resume= params missing)"
  local root_src root_dev; root_src=$(findmnt -no SOURCE /); root_dev=${root_src%%\[*}
  [[ $(findmnt -no FSTYPE /) == btrfs ]] || die "root is not btrfs"
  ok "root device $root_dev"

  # ACPI S4 ("platform") leaves lid/Wi-Fi/AC wake armed; the Mac powers itself back on and sits at the LUKS prompt
  write_file "$HIBERNATE_CONF" 644 <<'EOF'
[Sleep]
HibernateMode=shutdown
EOF

  local mem_kb size; mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  size=${SWAP_SIZE:-"$(( (mem_kb + 1048575) / 1048576 + 2 ))g"}; size=${size,,}
  [[ $size =~ ^[0-9]+g$ ]] || die "--swap-size must look like 18g"
  local free_gb; free_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
  (( free_gb > ${size%g} + 1 )) || die "not enough free space for a ${size} swapfile (free: ${free_gb}G)"

  local nested top mounted
  nested=$(sudo btrfs subvolume list / | awk '$NF=="swap" && $7!="5"{print 1}')
  top=$(sudo btrfs subvolume list / | awk -v s="$SWAP_SUBVOL" '$NF==s && $7=="5"{print 1}')
  mounted=$(findmnt -no OPTIONS "$SWAP_MNT" 2>/dev/null | grep -o "subvol=/$SWAP_SUBVOL" || true)

  if [[ -n $top && -n $mounted && -f $SWAP_FILE ]]; then
    ok "already migrated: $SWAP_SUBVOL mounted at $SWAP_MNT, swapfile present"
  else
    warn "this deletes the nested swap subvolume (@/swap) and recreates the swapfile (${size})"
    confirm "Proceed with the swap migration?" || die "aborted by user"
    if swapon --show=NAME --noheadings | grep -qx "$SWAP_FILE"; then run swapoff "$SWAP_FILE"; fi
    run mkdir -p /mnt/top
    run mount -t btrfs -o subvolid=5 "$root_dev" /mnt/top
    [[ -n $nested ]] && run btrfs subvolume delete /mnt/top/@/swap
    [[ -z $top ]] && { run btrfs subvolume create "/mnt/top/$SWAP_SUBVOL"; run chattr +C "/mnt/top/$SWAP_SUBVOL"; }
    run umount /mnt/top
    run mkdir -p "$SWAP_MNT"
    # fstab: replace any existing /swap lines with ours
    backup /etc/fstab
    local tmp; tmp=$(mktemp)
    grep -vE "^\S+\s+$SWAP_MNT\s+btrfs|^$SWAP_FILE\s" /etc/fstab > "$tmp" || true
    printf '%s  %s  btrfs  subvol=%s,nodatacow,noatime  0 0\n%s  none  swap  defaults,pri=0  0 0\n' \
      "$root_dev" "$SWAP_MNT" "$SWAP_SUBVOL" "$SWAP_FILE" >> "$tmp"
    if (( DRY_RUN )); then echo "  [dry-run] new /etc/fstab:"; diff -u /etc/fstab "$tmp" | sed 's/^/      /' || true
    else sudo install -m 644 "$tmp" /etc/fstab; ok "fstab updated"; fi
    rm -f "$tmp"
    run systemctl daemon-reload
    [[ -n $mounted ]] || run mount "$SWAP_MNT"
    (( DRY_RUN )) || [[ -f $SWAP_FILE ]] || sudo btrfs filesystem mkswapfile --size "$size" "$SWAP_FILE"
    run swapon -a
    CHANGED=1
  fi

  # priority check (bare `swapon` gives -1, which systemd ignores for hibernation)
  local prio; prio=$(swapon --show=NAME,PRIO --noheadings | awk -v f="$SWAP_FILE" '$1==f{print $2}')
  if [[ -n $prio && $prio -lt 0 ]]; then run swapoff "$SWAP_FILE"; run swapon -a; fi

  # resume_offset
  if (( ! DRY_RUN )); then
    local off cur; off=$(sudo btrfs inspect-internal map-swapfile -r "$SWAP_FILE")
    cur=$(grep -oE "resume_offset=[0-9]+" "$RESUME_DROPIN" | cut -d= -f2 || true)
    if [[ $off != "$cur" ]]; then
      backup "$RESUME_DROPIN"; backup "$LIMINE_CONF"
      sudo sed -i "s/resume_offset=[0-9]*/resume_offset=$off/" "$RESUME_DROPIN" "$LIMINE_CONF"
      ok "resume_offset updated $cur → $off"; CHANGED=1; NEEDS_REBUILD=1
    else ok "resume_offset $off matches"; fi
  fi
  local can; can=$(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate 2>/dev/null | awk '{print $2}')
  [[ $can == '"yes"' ]] && ok "logind CanHibernate = yes" || warn "logind CanHibernate = ${can:-?} (re-check after reboot)"
}

phase_rebuild() {
  (( NEEDS_REBUILD )) || { ok "no initramfs/bootloader rebuild needed"; return 0; }
  step "Rebuilding UKI + Limine entries"
  if (( DRY_RUN )); then echo "  [dry-run] sudo limine-update"; return 0; fi
  local log; log=$(mktemp)
  if ! sudo limine-update >"$log" 2>&1; then cat "$log"; die "limine-update failed"; fi
  grep -E "Running build hook: \[(applespi-force|resume|encrypt)\]|ERROR|WARNING" "$log" | sed 's/^/    /' || true
  if [[ -f $HOOK_CONF ]] && ! grep -q "Running build hook: \[applespi-force\]" "$log"; then
    die "applespi-force hook did not run during rebuild — check $HOOK_CONF sorts after omarchy_hooks.conf"
  fi
  rm -f "$log"; ok "rebuild complete"; NEEDS_REBOOT=1
}

phase_verify() {
  step "Verify (read-only)"
  local fail=0
  chk() { if eval "$2"; then ok "$1"; else echo "${C_ERR}  ✗${C_RST} $1"; fail=1; fi; }
  # Kernel log of this boot from the journal: dmesg is a ring buffer and loses the boot-time lines after
  # a day or a few suspend cycles; the journal keeps them (also across hibernation: same boot ID).
  # Dumped to a file because `journalctl | grep -q` dies of SIGPIPE under `set -o pipefail` on an early match.
  local klog; klog=$(mktemp)
  sudo journalctl -k -b -o cat --no-pager > "$klog"
  for p in "${KPARAMS[@]}"; do chk "cmdline has $p" "kernel_has $p"; done
  chk "SPI controller in PIO mode"        "grep -q 'no DMA channels available, using PIO' $klog"
  chk "acpi_call module available"        "modinfo acpi_call >/dev/null 2>&1"
  chk "switch script executable"          "[[ -x $SWITCH_SCRIPT ]]"
  chk "applespi-force.service enabled"    "systemctl is-enabled -q applespi-force.service"
  chk "applespi modeswitch done"          "grep -qi 'applespi.*modeswitch done' $klog"
  chk "no applespi -110 timeouts"         "! grep -q 'applespi.*-110' $klog"
  chk "initramfs hook files present"      "[[ -f $HOOK_INSTALL && -f $HOOK_RUNTIME && -f $HOOK_CONF ]]"
  # early-boot journal timestamps are all the journald start time, so compare order instead:
  # acpi_call must load before the root filesystem is mounted (= inside the initramfs, before the LUKS prompt)
  chk "hook ran in initrd (acpi_call before root mount)" "awk '/acpi_call: loading/{if(!a)a=NR} /BTRFS info .*first mount of filesystem/{if(!b)b=NR} END{exit !(a && b && a<b)}' $klog"
  chk "mem_sleep is s2idle"               "grep -q '\\[s2idle\\]' /sys/power/mem_sleep"
  chk "sleep hook executable"             "[[ -x $SLEEP_HOOK ]]"
  chk "Wi-Fi card visible on PCI (class 0x028000)" "grep -lxq 0x028000 /sys/bus/pci/devices/*/class"
  chk "sleep hook is the detached-recovery version" "grep -q 'wifi-resume)' $SLEEP_HOOK"
  chk "shell-refresh script executable"   "[[ -x $SHELL_REFRESH_SCRIPT ]]"
  chk "shell-refresh user unit loaded"    "[[ \$(systemctl --user show -p LoadState --value shell-refresh-on-resume.service) == loaded ]]"
  chk "omarchy-restart-shell available"   "command -v omarchy-restart-shell >/dev/null"
  chk "omarchy-hyprland-session-locked available" "command -v omarchy-hyprland-session-locked >/dev/null"
  chk "last Wi-Fi recovery did not fail"  "! systemctl is-failed -q applespi-wifi-resume.service"
  if [[ -f $RESUME_DROPIN ]]; then
    chk "swap subvolume is top-level @swap" "sudo btrfs subvolume list / | awk -v s=$SWAP_SUBVOL '\$NF==s && \$7==\"5\"{f=1} END{exit !f}'"
    chk "swapfile active with PRIO >= 0"    "swapon --show=NAME,PRIO --noheadings | awk -v f=$SWAP_FILE '\$1==f && \$2>=0{f2=1} END{exit !f2}'"
    chk "resume_offset matches swapfile"    "[[ \$(sudo btrfs inspect-internal map-swapfile -r $SWAP_FILE) == \$(grep -oE 'resume_offset=[0-9]+' /proc/cmdline | cut -d= -f2) ]]"
    chk "hibernate powers off (no S4 wake)" "systemd-analyze cat-config systemd/sleep.conf | grep -qx 'HibernateMode=shutdown'"
    chk "logind CanHibernate = yes"         "busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate | grep -q '\"yes\"'"
  else
    warn "hibernation not configured (no $RESUME_DROPIN) — run 'sudo omarchy-hibernation-setup', then --phase hibernation"
  fi
  rm -f "$klog"
  (( fail )) && { warn "some checks failed — if you have not rebooted since the last change, reboot and re-run --verify"; return 1; }
  ok "all checks passed"
}

# ============================================================================= main
(( DRY_RUN )) && warn "DRY RUN — nothing will be changed"
phase_preflight
if (( VERIFY_ONLY )); then phase_verify && exit 0 || exit 1; fi

case "$PHASE" in
  all)          phase_kernel_params; phase_acpi_call; phase_switch; phase_initramfs; phase_sleep; phase_rebuild ;;
  kernel-params) phase_kernel_params; phase_rebuild ;;
  acpi-call)    phase_acpi_call ;;
  switch)       phase_acpi_call; phase_switch ;;
  initramfs)    phase_initramfs; phase_rebuild ;;
  sleep)        phase_sleep ;;
  hibernation)  phase_hibernation; phase_rebuild ;;
  verify)       phase_verify && exit 0 || exit 1 ;;
  *) die "unknown phase '$PHASE' (all|kernel-params|acpi-call|switch|initramfs|sleep|hibernation|verify)" ;;
esac

echo
if (( NEEDS_REBOOT )); then
  warn "Reboot required. Keep a USB keyboard attached for this one, then run: $0 --verify"
  [[ $PHASE == all ]] && warn "Hibernation is opt-in: after a clean --verify, run 'sudo omarchy-hibernation-setup' (if not done) then: $0 --phase hibernation"
else
  ok "Done. Run: $0 --verify"
fi
