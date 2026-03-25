#!/usr/bin/env bash
set -euo pipefail

KIOSK_USER="kiosk"

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  echo "User '$KIOSK_USER' does not exist."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y \
  rsync \
  sudo \
  util-linux \
  dosfstools \
  parted \
  beep

# =========================
# USB state runtime dirs
# =========================
cat > /etc/tmpfiles.d/kiosk-usb.conf <<'EOF'
d /run/kiosk-usb 0755 root root -
d /run/kiosk-usb-state 0755 root root -
d /run/kiosk-usb-state/by-devname 0755 root root -
EOF

systemd-tmpfiles --create /etc/tmpfiles.d/kiosk-usb.conf || true

mkdir -p /run/kiosk-usb
mkdir -p /run/kiosk-usb-state/by-devname

# =========================
# USB import / wipe / recovery
# =========================
cat > /usr/local/sbin/kiosk-import-usb.sh <<'EOF'
#!/bin/bash
set -u

DEV="${1:-}"
STATE_DIR="/run/kiosk-usb-state"
MAP_DIR="$STATE_DIR/by-devname"
LOCKFILE="/run/kiosk-usb/import.lock"
MOUNTROOT="/run/kiosk-usb"
DESTROOT="/home/kiosk"

log() {
    logger -t kiosk-usb "$*"
    echo "$*"
}

happy_beep() {
  command -v beep >/dev/null 2>&1 || return 0
  beep -f 523 -l 180 -D 90 -n \
       -f 659 -l 180 -D 90 -n \
       -f 784 -l 180 -D 90 -n \
       -f 1046 -l 350
}

wipe_beep() {
  command -v beep >/dev/null 2>&1 || return 0
  beep -f 700 -l 250 -D 120 -n \
       -f 400 -l 400
}

sadmac_beep() {
  command -v beep >/dev/null 2>&1 || return 0
  beep -f 659 -l 220 -D 120 -n \
       -f 587 -l 220 -D 120 -n \
       -f 523 -l 260 -D 180 -n \
       -f 440 -l 400 -D 220 -n \
       -f 95  -l 60 -D 20 -n \
       -f 95  -l 40 -D 20 -n \
       -f 95  -l 28 -D 140 -n \
       -f 72  -l 70 -D 20 -n \
       -f 72  -l 48 -D 20 -n \
       -f 72  -l 32
}

cleanup_mount() {
    local mnt="$1"
    if mountpoint -q "$mnt"; then
        umount "$mnt" >/dev/null 2>&1 || umount -l "$mnt" >/dev/null 2>&1 || true
    fi
    rmdir "$mnt" >/dev/null 2>&1 || true
}

get_uuid() {
    blkid -o value -s UUID "$1" 2>/dev/null || true
}

get_parent_disk() {
    local part="$1"
    local parent
    parent="$(lsblk -no pkname "$part" 2>/dev/null | head -n1)"
    [ -n "$parent" ] && echo "/dev/$parent"
}

is_usb_disk() {
    local disk="$1"
    local tran
    tran="$(lsblk -no TRAN "$disk" 2>/dev/null | head -n1)"
    [ "$tran" = "usb" ]
}

state_file_for() {
    local uuid="$1"
    echo "$STATE_DIR/$uuid"
}

read_state() {
    local uuid="$1"
    local sf
    sf="$(state_file_for "$uuid")"
    [ -f "$sf" ] && cat "$sf" || true
}

write_state() {
    local uuid="$1"
    local value="$2"
    printf '%s\n' "$value" > "$(state_file_for "$uuid")"
}

clear_state() {
    local uuid="$1"
    rm -f "$(state_file_for "$uuid")"
}

write_dev_map() {
    local devbase="$1"
    local uuid="$2"
    mkdir -p "$MAP_DIR"
    printf '%s\n' "$uuid" > "$MAP_DIR/$devbase"
}

clear_dev_map() {
    local devbase="$1"
    rm -f "$MAP_DIR/$devbase"
}

do_import() {
    local dev="$1"
    local uuid="$2"
    local mnt="$3"
    local dest

    dest="$DESTROOT"

    mkdir -p "$mnt" || return 1
    mount -o ro,nosuid,nodev "$dev" "$mnt" || return 1

    log "Importing from $dev to $dest"

    if rsync -a --protect-args "$mnt"/ "$dest"/; then
        chown -R kiosk:kiosk "$dest" || true
        chmod -R u+rwX,go-rwx "$dest" || true
        cleanup_mount "$mnt"
        sync
        return 0
    else
        cleanup_mount "$mnt"
        return 1
    fi
}

do_wipe() {
    local dev="$1"
    local disk
    local part

    disk="$(get_parent_disk "$dev")"
    [ -n "$disk" ] || return 1
    is_usb_disk "$disk" || return 1

    log "Wiping USB disk $disk for partition $dev"

    wipefs -a "$disk" >/dev/null 2>&1 || return 1
    parted -s "$disk" mklabel msdos >/dev/null 2>&1 || return 1
    parted -s "$disk" mkpart primary fat32 1MiB 100% >/dev/null 2>&1 || return 1

    partprobe "$disk" >/dev/null 2>&1 || true
    udevadm settle >/dev/null 2>&1 || true
    sleep 1

    case "$disk" in
      /dev/nvme*|/dev/mmcblk*)
        part="${disk}p1"
        ;;
      *)
        part="${disk}1"
        ;;
    esac

    [ -b "$part" ] || return 1

    mkfs.vfat -F 32 "$part" >/dev/null 2>&1 || return 1
    sync
    return 0
}

fail_exit() {
    local mnt="${1:-}"
    [ -n "$mnt" ] && cleanup_mount "$mnt"
    sadmac_beep
    exit 1
}

if [ -z "$DEV" ] || [ ! -b "$DEV" ]; then
    log "Invalid device: $DEV"
    sadmac_beep
    exit 1
fi

mkdir -p "$STATE_DIR" "$MAP_DIR" "$MOUNTROOT" "$DESTROOT"

UUID="$(get_uuid "$DEV")"
if [ -z "$UUID" ]; then
    log "No filesystem UUID found for $DEV, refusing to proceed"
    sadmac_beep
    exit 1
fi

STATE="$(read_state "$UUID")"
DEVBASE="$(basename "$DEV")"
MNT="$MOUNTROOT/$DEVBASE"

exec 9>"$LOCKFILE"
flock -w 5 9 || {
    log "Another USB action is already running, refusing $DEV"
    sadmac_beep
    exit 1
}

case "$STATE" in
    wipe)
        if do_wipe "$DEV"; then
            clear_state "$UUID"
            clear_dev_map "$DEVBASE"
            log "Wipe successful for $DEV ($UUID)"
            wipe_beep
            exit 0
        else
            log "Wipe failed for $DEV ($UUID)"
            sadmac_beep
            exit 1
        fi
        ;;
    ""|copied)
        if do_import "$DEV" "$UUID" "$MNT"; then
            write_state "$UUID" "copied"
            write_dev_map "$DEVBASE" "$UUID"
            log "Import successful for $DEV ($UUID)"
            happy_beep
            exit 0
        else
            log "Import failed for $DEV ($UUID)"
            fail_exit "$MNT"
        fi
        ;;
    *)
        log "Unknown state '$STATE' for $UUID"
        sadmac_beep
        exit 1
        ;;
esac
EOF
chmod 0755 /usr/local/sbin/kiosk-import-usb.sh

cat > /usr/local/sbin/kiosk-remove-usb.sh <<'EOF'
#!/bin/bash
set -u

STATE_DIR="/run/kiosk-usb-state"
MAP_DIR="$STATE_DIR/by-devname"

for map in "$MAP_DIR"/*; do
    [ -f "$map" ] || continue
    UUID="$(cat "$map" 2>/dev/null || true)"
    [ -n "$UUID" ] || continue
    STATE_FILE="$STATE_DIR/$UUID"
    STATE="$(cat "$STATE_FILE" 2>/dev/null || true)"
    if [ "$STATE" = "copied" ]; then
        printf '%s\n' "wipe" > "$STATE_FILE"
    fi
    rm -f "$map"
done

exit 0
EOF
chmod 0755 /usr/local/sbin/kiosk-remove-usb.sh

cat > /usr/local/sbin/kiosk-recover-usb.sh <<'EOF'
#!/bin/bash
set -u

STATE_DIR="/run/kiosk-usb-state"
MAP_DIR="$STATE_DIR/by-devname"
LOCKFILE="/run/kiosk-usb/import.lock"
MOUNTROOT="/run/kiosk-usb"
DESTROOT="/home/kiosk"

log() {
    logger -t kiosk-usb-recover "$*"
    echo "$*"
}

happy_beep() {
  command -v beep >/dev/null 2>&1 || return 0
  beep -f 523 -l 180 -D 90 -n \
       -f 659 -l 180 -D 90 -n \
       -f 784 -l 180 -D 90 -n \
       -f 1046 -l 350
}

do_import() {
    local dev="$1"
    local uuid="$2"
    local mnt="$3"
    local dest

    dest="$DESTROOT"

    mkdir -p "$mnt" || return 1
    mount -o ro,nosuid,nodev "$dev" "$mnt" || return 1

    if rsync -a --protect-args "$mnt"/ "$dest"/; then
        chown -R kiosk:kiosk "$dest" || true
        chmod -R u+rwX,go-rwx "$dest" || true
        if mountpoint -q "$mnt"; then umount "$mnt" || true; fi
        rmdir "$mnt" >/dev/null 2>&1 || true
        sync
        return 0
    else
        if mountpoint -q "$mnt"; then umount "$mnt" || true; fi
        rmdir "$mnt" >/dev/null 2>&1 || true
        return 1
    fi
}

mkdir -p "$STATE_DIR" "$MAP_DIR" "$MOUNTROOT" "$DESTROOT"

exec 9>"$LOCKFILE"
flock -n 9 || exit 0

for dev in /dev/disk/by-uuid/*; do
    [ -e "$dev" ] || continue
    UUID="$(basename "$dev")"
    STATE_FILE="$STATE_DIR/$UUID"
    [ -f "$STATE_FILE" ] || continue
    [ "$(cat "$STATE_FILE" 2>/dev/null)" = "copied" ] || continue

    REALDEV="$(readlink -f "$dev")"
    [ -b "$REALDEV" ] || continue

    DEVBASE="$(basename "$REALDEV")"
    MNT="$MOUNTROOT/$DEVBASE"

    log "Recovery import for $REALDEV ($UUID)"

    if do_import "$REALDEV" "$UUID" "$MNT"; then
        printf '%s\n' "$UUID" > "$MAP_DIR/$DEVBASE"
        happy_beep
    fi
done

exit 0
EOF
chmod 0755 /usr/local/sbin/kiosk-recover-usb.sh

# =========================
# USB import systemd unit
# =========================
cat > /etc/systemd/system/kiosk-usb-import@.service <<'EOF'
[Unit]
Description=Import or wipe files from USB device /dev/%I
After=local-fs.target
ConditionPathExists=/dev/%I

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kiosk-import-usb.sh /dev/%I
EOF

# =========================
# USB udev rules
# =========================
cat > /etc/udev/rules.d/99-kiosk-usb.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="partition", TAG+="systemd", ENV{SYSTEMD_WANTS}+="kiosk-usb-import@%k.service"
ACTION=="remove", RUN+="/usr/local/sbin/kiosk-remove-usb.sh"
EOF

# =========================
# Sudoers for recovery
# =========================
cat > /etc/sudoers.d/kiosk-usb-recover <<'EOF'
kiosk ALL=(root) NOPASSWD: /usr/local/sbin/kiosk-recover-usb.sh
EOF
chmod 0440 /etc/sudoers.d/kiosk-usb-recover
visudo -cf /etc/sudoers.d/kiosk-usb-recover

# =========================
# Add recovery hook to kiosk bash_profile
# =========================
if [ -f /etc/kiosk-skel/.bash_profile ]; then
  if ! grep -q 'kiosk-recover-usb.sh' /etc/kiosk-skel/.bash_profile; then
    awk '
      /startx/ && !done {
        print "        /usr/bin/sudo /usr/local/sbin/kiosk-recover-usb.sh"
        done=1
      }
      { print }
    ' /etc/kiosk-skel/.bash_profile > /etc/kiosk-skel/.bash_profile.new
    mv /etc/kiosk-skel/.bash_profile.new /etc/kiosk-skel/.bash_profile
    chown root:root /etc/kiosk-skel/.bash_profile
    chmod 0644 /etc/kiosk-skel/.bash_profile
  fi
else
  echo "Warning: /etc/kiosk-skel/.bash_profile not found. Add this line manually before startx:"
  echo "    /usr/bin/sudo /usr/local/sbin/kiosk-recover-usb.sh"
fi

systemctl daemon-reload
udevadm control --reload
systemd-tmpfiles --create /etc/tmpfiles.d/kiosk-usb.conf || true

echo
echo "USB handling installed."
echo
echo "What was added:"
echo " - /usr/local/sbin/kiosk-import-usb.sh"
echo " - /usr/local/sbin/kiosk-remove-usb.sh"
echo " - /usr/local/sbin/kiosk-recover-usb.sh"
echo " - /etc/systemd/system/kiosk-usb-import@.service"
echo " - /etc/udev/rules.d/99-kiosk-usb.rules"
echo " - /etc/sudoers.d/kiosk-usb-recover"
echo
echo "You should now:"
echo "1. Reboot or restart the kiosk session"
echo "2. Test fresh insert => import + happy beep"
echo "3. Test browser close with stick inserted => re-import"
echo "4. Test remove stick"
echo "5. Test reinsert same stick => wipe + wipe tune"
