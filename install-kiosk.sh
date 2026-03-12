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
  libxml2-utils

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
# Sudoers for kiosk session reset
# =========================
cat > /etc/sudoers.d/kiosk <<'EOF'
kiosk ALL=(root) NOPASSWD: /usr/local/sbin/kiosk-wipe-home.sh, /usr/local/sbin/kiosk-init-home.sh
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

def q(tag):
    return f"{{{ns_uri}}}{tag}"

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
Lid close poweroff: /etc/systemd/logind.conf
Printing (CUPS): http://localhost:631
Queue status: lpstat -t
Cancel all jobs: cancel -a
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
echo
