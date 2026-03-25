# Debian Trixie Browser Kiosk Script

This script creates a browser kiosk on top of Debian Trixie.

It uses a RAM-backed home directory for the kiosk user, resets the kiosk session whenever the browser is closed, powers off the machine when the lid is closed on a laptop, and includes automated USB import / wipe handling for scan sticks.

It assumes Debian 13 (Trixie), where the packages used are available under the expected names, including:

- chromium
- openbox
- xorg
- xinit
- network-manager
- cups
- wmctrl
- rsync
- beep
- dosfstools
- python3
- parted

---

## Important Notes

This script is meant to be run as **root** on a fresh or minimal Debian installation.

It modifies several system files, including:

- `/etc/fstab`
- `/etc/systemd/logind.conf`
- `/etc/sudoers.d/kiosk`
- `getty` override
- udev rules
- systemd unit files
- kiosk configuration files

The script locks the **kiosk account password**, so password login is disabled.  
However, it keeps a normal shell so **tty1 autologin still works**.

It installs and enables **CUPS**, but **does not configure a printer queue**.

It does **not include a secret rescue hotkey**, because the final setup relies on the Chromium watchdog instead.

It enables the **PC speaker** and uses `beep` for success/failure sounds.  
The current setup uses the `pcspkr` kernel module, a udev rule for the PC speaker input device, and `input` group membership instead of the old setuid `beep` approach.

It also installs a **USB workflow** with these behaviours:

- first insert of a USB stick: import files into the kiosk home
- browser/session restart with stick still inserted: re-import files
- remove the stick: arm it for wipe
- next insert of the same stick: wipe and reformat it

---

## Final System Behavior

### Boot sequence
