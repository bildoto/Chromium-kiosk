# Debian Trixie Browser Kiosk Script

This script creates a browser kiosk on top of Debian Trixie.

It securely wipes everything when the browser is closed, the computer is shut down, or the lid is closed on a laptop.

It assumes Debian 13 (Trixie), where the packages used are available under the expected names, including:

- chromium
- openbox
- xorg
- network-manager
- cups
- wmctrl

## Important Notes

This script is meant to be run as **root** on a fresh or minimal Debian installation.

It modifies several system files, including:

- `/etc/fstab`
- `/etc/systemd/logind.conf`
- `sudoers`
- `getty` override
- kiosk configuration files

The script locks the **kiosk account password**, so password login is disabled.  
However, it keeps a normal shell so **tty1 autologin still works**.

It installs and enables **CUPS**, but **does not configure a printer queue**.

It does **not include a secret rescue hotkey**, because the final setup relies on the Chromium watchdog instead.

## Final System Behavior

### Boot sequence

```
Boot
 ↓
tty1 autologin
 ↓
wipe RAM home
 ↓
copy /etc/kiosk-skel
 ↓
start X
 ↓
Openbox
 ↓
Chromium
```

### When the user closes the browser

```
browser closes
 ↓
X exits
 ↓
session loop restarts
 ↓
home wiped again
 ↓
fresh browser
```

### Reboot or shutdown

```
RAM wiped automatically
```
