#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configurable bits
# =========================
KIOSK_USER="kiosk"
SYSOP_USER="sysop"           # set to your admin account name
START_URL="about:blank"      # or e.g. https://www.google.com
HOME_TMPFS_SIZE="1G"

# =========================
# Sanity checks
# =========================
if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

if ! id "$SYSOP_USER" >/dev/null 2>&1; then
  echo "Warning: sysop user '$SYSOP_USER' does not exist yet."
  echo "Continuing anyway, but lpadmin membership and notes may not be applied."
fi

export DEBIAN_FRONTEND=noninteractive

# =========================
# Packages
# =========================
apt update
apt install -y \
  xorg \
  openbox \
  chromium \
  network-manager \
  cups \
  cups-client \
  wmctrl \
  rsync \
  sudo \
  libxml2-utils \
  beep \
  util-linux \
  dosfstools \
  python3

systemctl enable NetworkManager
systemctl enable cups

# =========================
# Kiosk user
# =========================
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "Kiosk User" "$KIOSK_USER"
fi

# Disable password login for kiosk, but keep shell usable for autologin
passwd -l "$KIOSK_USER" || true
usermod -s /bin/bash "$KIOSK_USER"

# Optional: sysop can manage printers
if id "$SYSOP_USER" >/dev/null 2>&1; then
  usermod -aG lpadmin "$SYSOP_USER" || true
fi

# =========================
# tmpfs home for kiosk
# =========================
mkdir -p "/home/$KIOSK_USER"

if ! grep -qE "^[^#].*\s/home/${KIOSK_USER}\s+tmpfs\s" /etc/fstab; then
  echo "tmpfs /home/${KIOSK_USER} tmpfs noatime,nodev,nosuid,size=${HOME_TMPFS_SIZE},uid=${KIOSK_USER},gid=${KIOSK_USER},mode=0700 0 0" >> /etc/fstab
fi

# Mount now if possible
if ! mountpoint -q "/home/$KIOSK_USER"; then
  mount "/home/$KIOSK_USER" || true
fi

chown "${KIOSK_USER}:${KIOSK_USER}" "/home/$KIOSK_USER"
chmod 0700 "/home/$KIOSK_USER"

# =========================
# Persistent skeleton
# =========================
mkdir -p /etc/kiosk-skel/.config/openbox
mkdir -p /etc/kiosk-skel/usb-imports

# =========================
# Reset scripts
# =========================
cat > /usr/local/sbin/kiosk-wipe-home.sh <<'EOF'
#!/bin/sh
set -e

DST="/home/kiosk"

[ "$DST" = "/home/kiosk" ] || exit 1
[ -d "$DST" ] || exit 1

find "$DST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
sync
EOF
chmod 0755 /usr/local/sbin/kiosk-wipe-home.sh

cat > /usr/local/sbin/kiosk-init-home.sh <<'EOF'
#!/bin/sh
set -e

SRC="/etc/kiosk-skel/"
DST="/home/kiosk/"

[ -d "$SRC" ] || exit 1
[ -d "$DST" ] || exit 1

/usr/bin/rsync -a --delete "$SRC" "$DST"
chown -R kiosk:kiosk "$DST"
EOF
chmod 0755 /usr/local/sbin/kiosk-init-home.sh

# =========================
# Chromium watchdog
# =========================
cat > /usr/local/bin/kiosk-focus-chromium.sh <<'EOF'
#!/bin/sh

while true; do
    wid=$(wmctrl -lx | awk 'BEGIN{IGNORECASE=1} /chromium/ {print $1; exit}')

    if [ -n "$wid" ]; then
        wmctrl -ia "$wid" 2>/dev/null || true
    fi

    sleep 1
done
EOF
chmod 0755 /usr/local/bin/kiosk-focus-chromium.sh

# =========================
# PC speaker support
# =========================
mkdir -p /etc/modules-load.d
echo pcspkr > /etc/modules-load.d/pcspkr.conf

# Remove blacklist entries if present
if grep -Rqs '^[[:space:]]*blacklist[[:space:]]\+pcspkr' /etc/modprobe.d 2>/dev/null; then
  grep -Rls '^[[:space:]]*blacklist[[:space:]]\+pcspkr' /etc/modprobe.d 2>/dev/null | while read -r f; do
    sed -i 's/^[[:space:]]*blacklist[[:space:]]\+pcspkr/# disabled by kiosk install: blacklist pcspkr/' "$f"
  done
fi

modprobe pcspkr || true
chmod 4755 /usr/bin/beep || true

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
mkdir -p /home/kiosk/usb-imports
chown kiosk:kiosk /home/kiosk/usb-imports || true
chmod 700 /home/kiosk/usb-imports || true

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
DESTROOT="/home/kiosk/usb-imports"

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
    local label dest safe_label stamp

    label="$(blkid -o value -s LABEL "$dev" 2>/dev/null || true)"
    safe_label="$(printf '%s' "${label:-usb}" | tr -cs 'A-Za-z0-9._-' '_')"
    stamp="$(date +%Y%m%d-%H%M%S)"
    dest="$DESTROOT/${stamp}_${safe_label}_${uuid}"

    mkdir -p "$mnt" || return 1
    mount -o ro,nosuid,nodev "$dev" "$mnt" || return 1
    mkdir -p "$dest" || {
        cleanup_mount "$mnt"
        return 1
    }

    log "Importing from $dev to $dest"

    if rsync -a --protect-args "$mnt"/ "$dest"/; then
        chown -R kiosk:kiosk "$dest" || true
        chmod -R u+rwX,go-rwx "$dest" || true
        cleanup_mount "$mnt"
        sync
        return 0
    else
        rm -rf "$dest" >/dev/null 2>&1 || true
        cleanup_mount "$mnt"
        return 1
    fi
}

do_wipe() {
    local dev="$1"
    local disk

    disk="$(get_parent_disk "$dev")"
    [ -n "$disk" ] || return 1
    is_usb_disk "$disk" || return 1

    log "Wiping USB disk $disk for partition $dev"

    wipefs -a "$disk" >/dev/null 2>&1 || return 1
    mkfs.vfat -F 32 -I "$disk" >/dev/null 2>&1 || return 1
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
[ -n "$UUID" ] || UUID="$(basename "$DEV")"

STATE="$(read_state "$UUID")"
DEVBASE="$(basename "$DEV")"
MNT="$MOUNTROOT/$DEVBASE"

exec 9>"$LOCKFILE"
flock -n 9 || {
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

DEVBASE="${1:-}"
STATE_DIR="/run/kiosk-usb-state"
MAP_DIR="$STATE_DIR/by-devname"

log() {
    logger -t kiosk-usb "$*"
    echo "$*"
}

if [ -z "$DEVBASE" ]; then
    exit 0
fi

MAP_FILE="$MAP_DIR/$DEVBASE"
[ -f "$MAP_FILE" ] || exit 0

UUID="$(cat "$MAP_FILE" 2>/dev/null || true)"
[ -n "$UUID" ] || exit 0

STATE_FILE="$STATE_DIR/$UUID"
STATE="$(cat "$STATE_FILE" 2>/dev/null || true)"

if [ "$STATE" = "copied" ]; then
    printf '%s\n' "wipe" > "$STATE_FILE"
    log "Armed wipe for UUID $UUID after removal of $DEVBASE"
fi

rm -f "$MAP_FILE"
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
DESTROOT="/home/kiosk/usb-imports"

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
    local label dest safe_label stamp

    label="$(blkid -o value -s LABEL "$dev" 2>/dev/null || true)"
    safe_label="$(printf '%s' "${label:-usb}" | tr -cs 'A-Za-z0-9._-' '_')"
    stamp="$(date +%Y%m%d-%H%M%S)"
    dest="$DESTROOT/${stamp}_${safe_label}_${uuid}"

    mkdir -p "$mnt" || return 1
    mount -o ro,nosuid,nodev "$dev" "$mnt" || return 1
    mkdir -p "$dest" || {
        if mountpoint -q "$mnt"; then umount "$mnt" || true; fi
        rmdir "$mnt" >/dev/null 2>&1 || true
        return 1
    }

    if rsync -a --protect-args "$mnt"/ "$dest"/; then
        chown -R kiosk:kiosk "$dest" || true
        chmod -R u+rwX,go-rwx "$dest" || true
        if mountpoint -q "$mnt"; then umount "$mnt" || true; fi
        rmdir "$mnt" >/dev/null 2>&1 || true
        sync
        return 0
    else
        rm -rf "$dest" >/dev/null 2>&1 || true
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

cat > /etc/systemd/system/kiosk-usb-import@.service <<'EOF'
[Unit]
Description=Import or wipe files from USB device /dev/%I
After=local-fs.target
ConditionPathExists=/dev/%I

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kiosk-import-usb.sh /dev/%I
EOF

cat > /etc/systemd/system/kiosk-usb-remove@.service <<'EOF'
[Unit]
Description=Handle removal of USB device %I

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kiosk-remove-usb.sh %I
EOF

cat > /etc/udev/rules.d/99-kiosk-usb.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="partition", ENV{ID_FS_USAGE}=="filesystem", TAG+="systemd", ENV{SYSTEMD_WANTS}+="kiosk-usb-import@%k.service"
ACTION=="remove", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="partition", TAG+="systemd", ENV{SYSTEMD_WANTS}+="kiosk-usb-remove@%k.service"
EOF

# =========================
# Sudoers for kiosk session reset
# =========================
cat > /etc/sudoers.d/kiosk <<'EOF'
kiosk ALL=(root) NOPASSWD: /usr/local/sbin/kiosk-wipe-home.sh, /usr/local/sbin/kiosk-init-home.sh, /usr/local/sbin/kiosk-recover-usb.sh
EOF
chmod 0440 /etc/sudoers.d/kiosk
visudo -cf /etc/sudoers.d/kiosk

# =========================
# tty1 autologin
# =========================
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
EOF

# =========================
# Kiosk session loop
# =========================
cat > /etc/kiosk-skel/.bash_profile <<'EOF'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    while true; do
        /usr/bin/sudo /usr/local/sbin/kiosk-wipe-home.sh
        /usr/bin/sudo /usr/local/sbin/kiosk-init-home.sh
        /usr/bin/sudo /usr/local/sbin/kiosk-recover-usb.sh
        startx
    done
fi
EOF
chmod 0644 /etc/kiosk-skel/.bash_profile

cat > /etc/kiosk-skel/.xinitrc <<EOF
#!/bin/sh

openbox-session &
OBPID=\$!

/usr/local/bin/kiosk-focus-chromium.sh &
WATCHPID=\$!

sleep 2

chromium \\
  --incognito \\
  --start-maximized \\
  --no-first-run \\
  --disable-session-crashed-bubble \\
  --no-default-browser-check \\
  "${START_URL}"

if kill -0 "\$WATCHPID" 2>/dev/null; then
    kill "\$WATCHPID"
    wait "\$WATCHPID" 2>/dev/null || true
fi

if kill -0 "\$OBPID" 2>/dev/null; then
    kill "\$OBPID"
    wait "\$OBPID" 2>/dev/null || true
fi

exit 0
EOF
chmod 0755 /etc/kiosk-skel/.xinitrc

# =========================
# Openbox config
# Start from Debian default, then patch it
# =========================
cp /etc/xdg/openbox/rc.xml /etc/kiosk-skel/.config/openbox/rc.xml

python3 <<'PY'
import xml.etree.ElementTree as ET

path = "/etc/kiosk-skel/.config/openbox/rc.xml"
tree = ET.parse(path)
root = tree.getroot()

ns_uri = "http://openbox.org/3.4/rc"
ns = {"ob": ns_uri}
ET.register_namespace("", ns_uri)

# Set title layout to Name + Close
for tl in root.findall(".//ob:theme/ob:titleLayout", ns):
    tl.text = "NC"

# Empty keyboard bindings completely
for kb in root.findall(".//ob:keyboard", ns):
    for child in list(kb):
        kb.remove(child)

# Remove any mousebind that shows a menu
for mouse in root.findall(".//ob:mouse", ns):
    for context in mouse.findall("ob:context", ns):
        for mb in list(context.findall("ob:mousebind", ns)):
            remove = False
            for action in mb.findall(".//ob:action", ns):
                if action.attrib.get("name") == "ShowMenu":
                    remove = True
                    break
            if remove:
                context.remove(mb)

tree.write(path, encoding="utf-8", xml_declaration=True)
PY

xmllint --noout /etc/kiosk-skel/.config/openbox/rc.xml

# =========================
# logind: lid close = poweroff
# =========================
if grep -q '^#\?HandleLidSwitch=' /etc/systemd/logind.conf; then
  sed -i 's|^#\?HandleLidSwitch=.*|HandleLidSwitch=poweroff|' /etc/systemd/logind.conf
else
  echo 'HandleLidSwitch=poweroff' >> /etc/systemd/logind.conf
fi

if grep -q '^#\?HandleLidSwitchExternalPower=' /etc/systemd/logind.conf; then
  sed -i 's|^#\?HandleLidSwitchExternalPower=.*|HandleLidSwitchExternalPower=poweroff|' /etc/systemd/logind.conf
else
  echo 'HandleLidSwitchExternalPower=poweroff' >> /etc/systemd/logind.conf
fi

if grep -q '^#\?LidSwitchIgnoreInhibited=' /etc/systemd/logind.conf; then
  sed -i 's|^#\?LidSwitchIgnoreInhibited=.*|LidSwitchIgnoreInhibited=yes|' /etc/systemd/logind.conf
else
  echo 'LidSwitchIgnoreInhibited=yes' >> /etc/systemd/logind.conf
fi

# =========================
# Sysop notes
# =========================
cat > /etc/sysop-kiosk-notes.txt <<'EOF'
========== KIOSK ADMIN QUICK NOTES ==========
Home is tmpfs: /home/kiosk
Defaults are stored in: /etc/kiosk-skel/
Session loop: /etc/kiosk-skel/.bash_profile
X startup: /etc/kiosk-skel/.xinitrc
Openbox config: /etc/kiosk-skel/.config/openbox/rc.xml
Wipe script: /usr/local/sbin/kiosk-wipe-home.sh
Init script: /usr/local/sbin/kiosk-init-home.sh
Chromium watchdog: /usr/local/bin/kiosk-focus-chromium.sh
USB add handler: /usr/local/sbin/kiosk-import-usb.sh
USB remove handler: /usr/local/sbin/kiosk-remove-usb.sh
USB recovery handler: /usr/local/sbin/kiosk-recover-usb.sh
USB add service: /etc/systemd/system/kiosk-usb-import@.service
USB remove service: /etc/systemd/system/kiosk-usb-remove@.service
USB udev rules: /etc/udev/rules.d/99-kiosk-usb.rules
USB import destination: /home/kiosk/usb-imports
USB state dir (RAM): /run/kiosk-usb-state
USB workflow:
- Insert fresh stick: import + happy beep
- Restart with stick still inserted: re-import + happy beep
- Remove stick: arms wipe
- Next insert of same stick: wipe + wipe tune
PC speaker module: /etc/modules-load.d/pcspkr.conf
Lid close poweroff: /etc/systemd/logind.conf
Printing (CUPS): http://localhost:631
Queue status: lpstat -t
Cancel all jobs: cancel -a
USB logs: journalctl -f -t kiosk-usb
Recovery logs: journalctl -f -t kiosk-usb-recover
============================================
EOF
chmod 0644 /etc/sysop-kiosk-notes.txt

if id "$SYSOP_USER" >/dev/null 2>&1; then
  SYSOP_HOME="$(getent passwd "$SYSOP_USER" | cut -d: -f6)"
  if [[ -n "$SYSOP_HOME" && -d "$SYSOP_HOME" ]]; then
    touch "$SYSOP_HOME/.bashrc"
    if ! grep -q 'sysop-kiosk-notes.txt' "$SYSOP_HOME/.bashrc"; then
      {
        echo ''
        echo 'cat /etc/sysop-kiosk-notes.txt'
      } >> "$SYSOP_HOME/.bashrc"
    fi
    chown "$SYSOP_USER:$SYSOP_USER" "$SYSOP_HOME/.bashrc"
  fi
fi

# =========================
# Seed live RAM home now
# =========================
/usr/local/sbin/kiosk-init-home.sh || true

# =========================
# Reload services
# =========================
systemctl daemon-reload
systemctl restart systemd-logind || true
udevadm control --reload

echo
echo "Done."
echo
echo "Next steps:"
echo "1. Reboot the machine"
echo "2. Verify tty1 autologins as kiosk"
echo "3. Verify Chromium opens maximized"
echo "4. Verify closing Chromium resets the session"
echo "5. Configure Wi-Fi with nmtui or nmcli"
echo "6. Configure USB printer in CUPS at http://localhost:631 if needed"
echo "7. Test PC speaker with: beep"
echo "8. Test USB workflow:"
echo "   - fresh insert => import + happy beep"
echo "   - browser close with stick still inserted => auto re-import"
echo "   - remove stick"
echo "   - reinsert same stick => wipe + wipe tune"
