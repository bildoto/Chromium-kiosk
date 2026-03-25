# Debian Trixie Browser Kiosk Script

This script creates a browser kiosk on top of Debian Trixie.

It uses a RAM-backed home directory for the kiosk user, resets the kiosk session whenever the browser is closed, powers off the machine when the lid is closed on a laptop, and includes automated USB import / wipe handling for scan sticks.

---

## Debian Installation (Trixie)

This setup assumes a **minimal Debian 13 (Trixie) installation**.

Follow these steps in the Debian installer:

### Installer steps

- Choose **Install**
- Language: **English**
- Location:
  - Select **Other**
  - Select **Europe**
  - Select **Finland**
- Locale: **United States (US)**
- Keyboard: **Finnish**

### System identity

- Hostname: `asiakas1`
- Domain: leave empty

### Users and passwords

- Root password:
  - Press **Enter** to leave it empty
  - Press **Enter** again to confirm  
  → This disables the root account

- Create user:
  - Username: `sysop`
  - Full name: press **Enter**
  - Set a strong password
  - Record it somewhere safe
  - Repeat the password

### Disk setup

- Select **Guided - use entire disk**
- Select the **internal hard drive**, not the USB installer
- Select **All files in one partition**
- Select **Finish partitioning and write changes to disk**
- Confirm with **Yes**

### Package manager and mirror

- Scan extra installation media: **No**
- Mirror country: **Finland**
- Mirror: `www.nic.funet.fi`
- HTTP proxy: leave empty
- Participate in package survey: **No**

### Software selection

- **Deselect**:
  - Debian desktop environment
  - GNOME

- **Select only**:
  - SSH server
  - Standard system utilities

Use **spacebar** to toggle selections.

### Bootloader

- Install GRUB to the primary drive: **Yes**
- Select the hard drive

### Finish installation

- Reboot when prompted

After reboot, the system should boot into a **CLI login prompt**.

---

## Post-install setup

Log in as:

    sysop

Run:

    wget https://raw.githubusercontent.com/bildoto/Chromium-kiosk/refs/heads/main/install-kiosk.sh
    chmod +x install-kiosk.sh
    sudo ./install-kiosk.sh

Then reboot:

    sudo reboot

After reboot, Chromium should start automatically.

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

    Boot
     ↓
    tmpfs home mounted
     ↓
    kiosk tmpfs home initialized from /etc/kiosk-skel
     ↓
    tty1 autologin
     ↓
    wipe RAM home
     ↓
    copy /etc/kiosk-skel
     ↓
    recover USB imports if needed
     ↓
    start X
     ↓
    Openbox
     ↓
    Chromium

### When the user closes the browser

    browser closes
     ↓
    Openbox session ends
     ↓
    session loop restarts
     ↓
    home wiped again
     ↓
    copy /etc/kiosk-skel
     ↓
    recover USB imports if needed
     ↓
    fresh browser

### Reboot or shutdown

    RAM-backed kiosk home disappears automatically

### Lid close on laptop

    lid closes
     ↓
    system powers off

---

## USB Workflow

The script creates these handlers:

- USB add handler
- USB remove handler
- USB recovery handler

Imported files are copied into:

- `/home/kiosk`

USB state is tracked in:

- `/run/kiosk-usb-state`

### Fresh insert

    insert USB stick
     ↓
    mount read-only
     ↓
    copy files into /home/kiosk
     ↓
    play happy beep
     ↓
    mark stick as copied

### Remove stick

    remove USB stick
     ↓
    mark stick state as wipe

### Reinsert same stick

    insert same USB stick again
     ↓
    detect armed wipe state
     ↓
    wipe and reformat device as FAT32
     ↓
    play wipe tune

### Browser closed or session restarted while stick is still inserted

    session restarts
     ↓
    recovery handler scans inserted USB filesystems
     ↓
    previously copied stick is imported again
     ↓
    play happy beep

---

## Kiosk Home Behavior

The kiosk home directory is mounted as **tmpfs**, so it lives in RAM:

- `/home/kiosk`

Default content is stored persistently in:

- `/etc/kiosk-skel`

Before each kiosk session, the script:

1. wipes the current RAM home contents  
2. copies in the persistent skeleton  
3. restores USB imports if applicable  
4. starts X and Chromium  

This means browser-side state inside the kiosk home does not persist between sessions unless you deliberately add it to the skeleton.

---

## What the script sets up

The script creates or configures:

- dedicated kiosk user
- tty1 autologin
- RAM-backed kiosk home
- boot-time kiosk home initialization service
- kiosk home wipe script
- kiosk home init script
- Chromium focus watchdog
- Openbox configuration
- CUPS service
- PC speaker support
- PC speaker udev permission rule
- USB udev rules
- USB import systemd service
- USB remove handler script
- USB recovery handler script
- lid-close poweroff behaviour
- sysop notes file

---

## What it does not do

The script does not:

- configure Wi-Fi automatically
- configure a printer queue automatically
- harden Debian into a fully escape-proof kiosk
- securely erase all storage on shutdown
- preserve normal kiosk user data between sessions

---

## After running the script

Expected next steps:

1. Reboot the machine  
2. Verify tty1 autologins as kiosk  
3. Verify Chromium opens maximized  
4. Verify closing Chromium resets the session  
5. Configure Wi-Fi with `nmtui` or `nmcli`  
6. Configure USB printer in CUPS at `http://localhost:631` if needed  
7. Test PC speaker with `beep`  
8. Test USB workflow:
   - fresh insert → import + happy beep  
   - browser close with stick still inserted → auto re-import  
   - remove stick  
   - reinsert same stick → wipe + wipe tune  
