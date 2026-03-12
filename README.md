This script creates a browser kiosk on top of Debian Trixie. 

It securely wipes everything when browser is closed, the computer is shut down, or the lid is closed on a laptop.

It assumes Debian 13 / Trixie, where the packages you used are available under the expected names, including chromium, openbox, xorg, network-manager, cups, and wmctrl.

A couple of important notes before the script:

This script is meant to be run as root on a fresh-ish minimal Debian install.

It modifies system files like /etc/fstab, /etc/systemd/logind.conf, sudoers, getty override, and kiosk config files.

It locks the kiosk account password so password login is disabled, but keeps a normal shell so tty1 autologin still works.

It does not configure an actual printer queue in CUPS; it only installs and enables CUPS.

It does not add a secret rescue hotkey, because your final setup used the Chromium watchdog instead.




Final System Behavior



Boot:



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





User closes browser:

browser closes

↓

X exits

↓

session loop restarts

↓

home wiped again

↓

fresh browser






Reboot or poweroff:

RAM wiped automatically
