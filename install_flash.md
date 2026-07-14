# Klipper Installation — Trident 300 MadMax Build

Target hardware: Raspberry Pi host (LDO kits ship a Pi or CB1 — steps
are the same, but flash the matching OS image), Leviathan v1.2 main
board, 2x Nitehawk36 (RP2040, USB), Cartographer (USB).

## 1. Host OS + Klipper stack

Easiest path: **MainsailOS** — a Raspberry Pi OS image with Klipper,
Moonraker, and Mainsail preinstalled.

1. Flash MainsailOS to an SD card with Raspberry Pi Imager
   (Other specific-purpose OS → 3D printing → MainsailOS).
   Set hostname, user, Wi-Fi, and enable SSH in the imager's settings
   gear before writing.
2. Boot, then browse to `http://<hostname>.local` — Mainsail should load.
3. SSH in for the rest: `ssh <user>@<hostname>.local`

Alternative: plain Raspberry Pi OS Lite + **KIAUH**
(`git clone https://github.com/dw-0/kiauh && ./kiauh/kiauh.sh`) and
install klipper, moonraker, mainsail from its menu. Same result, more
control.

If the kit shipped a BTT CB1 instead of a Pi, use the CB1 variant of
the OS image from BTT; everything after boot is identical.

## 2. Flash the Leviathan (main MCU)

Klipper firmware is compiled on the Pi, per-MCU:

```bash
cd ~/klipper
make menuconfig
```

Leviathan v1.2 settings (**verify against LDO's Leviathan docs — a
wrong bootloader offset bricks nothing but wastes an evening**):
- Micro-controller: STM32
- Processor: STM32F446
- Bootloader offset: 32KiB (Katapult/CanBoot preinstalled by LDO)
- Clock reference: 12 MHz crystal
- Communication: USB (on PA11/PA12)

Then:
```bash
make clean && make
```

LDO ships Leviathans with Katapult, so flash over USB:
```bash
# put board in Katapult mode (double-tap reset or it drops there
# automatically with no app), find it:
ls /dev/serial/by-id/
python3 ~/katapult/scripts/flashtool.py -d /dev/serial/by-id/<katapult-device> -f ~/klipper/out/klipper.bin
```
If Katapult isn't present, fall back to DFU: hold BOOT0, plug in USB,
`make flash FLASH_DEVICE=0483:df11`.

Confirm: `ls /dev/serial/by-id/` shows a `usb-Klipper_stm32f446xx_...`
device. That string goes in `[mcu]` in printer.cfg.

## 3. Flash both Nitehawk36 boards (one at a time!)

RP2040-based, USB. Boards ship from LDO with Klipper + Katapult
preloaded, so they enumerate as `usb-Klipper_rp2040_...` out of the
box and can be flashed with no button-pressing. Flash and label ONE
board fully before touching the second, or you will mix up serials.

```bash
cd ~/klipper
make menuconfig
```
- Micro-controller: Raspberry Pi RP2040
- Bootloader offset: 16KiB (Katapult is preinstalled by LDO)
- Communication: USB

```bash
make clean && make
```

Primary method (per LDO docs) — `make flash` over USB serial:
```bash
sudo apt install python3 python3-pip
pip install pyserial   # "externally managed environment" error = already installed, fine

ls /dev/serial/by-id/               # find usb-Klipper_rp2040_...
cd ~/klipper
sudo service klipper stop
make flash FLASH_DEVICE=/dev/serial/by-id/<your USB ID>
sudo service klipper start
```

Fallbacks, in order, if that fails:
1. Katapult (preinstalled):
   `python3 ~/katapult/scripts/flashtool.py -d /dev/serial/by-id/<katapult-device> -f ~/klipper/out/klipper.uf2`
2. ROM bootloader: hold the BOOT button while plugging in USB, board
   mounts as an `RPI-RP2` drive, copy `klipper.uf2` onto it. This
   path is burned into silicon and always works.

After each board: `ls /dev/serial/by-id/`, record the serial, write
T0/T1 on the board and both cable ends. The two serials go in
`[mcu nhk0]` and `[mcu nhk1]`.

MULTI-MCU CAUTION: `make flash` uploads whatever was last built in
~/klipper/out. With an STM32 Leviathan and two RP2040 Nitehawks on
one host, save each board's menuconfig (`cp .config
~/klipper-configs/<board>.config`) and restore + `make clean && make`
before flashing each board.

## 4. Cartographer (NEW plugin -- Survey 5.0+)

Install the current python-package plugin (the older
cartographer-klipper repo and its [scanner] section are superseded):
```bash
curl -s -L https://raw.githubusercontent.com/Cartographer3D/cartographer3d-plugin/refs/heads/main/scripts/install.sh \
  | bash -s -- --klipper ~/klipper --klippy-env ~/klippy-env
git clone https://github.com/Cartographer3D/cartographer_firmware.git ~/cartographer_firmware
```
`ls /dev/serial/by-id/` for the serial → `[mcu cartographer]`. Then
update the probe firmware to the latest per their docs BEFORE
calibration (Survey 5.0+ firmware pairs with this plugin; mismatched
firmware/plugin generations produce confusing errors).

## 5. klipper-toolchanger + KAMP + r2pdx files

```bash
cd ~
git clone https://github.com/viesturz/klipper-toolchanger
bash ~/klipper-toolchanger/install.sh

git clone https://github.com/kyleisah/Klipper-Adaptive-Meshing-Purging
ln -s ~/Klipper-Adaptive-Meshing-Purging/Configuration ~/printer_data/config/KAMP
```
KAMP also needs `[include KAMP_Settings.cfg]` in printer.cfg (copy
KAMP_Settings.cfg per its README) — plus the two r2pdx .cfg files
downloaded into ~/printer_data/config.

## 6. Config in place

Copy this package's config files into `~/printer_data/config/`, merge
the moonraker.conf update_manager entries into the generated
moonraker.conf, fill in the four serial paths, then work through every
`<VERIFY>` tag before applying power to motors/heaters.

## 7. First-boot sanity checks (before any motion)

- All four MCUs connect (no "mcu unable to connect" in klippy.log)
- `QUERY_ENDSTOPS` — press each XY switch by hand, verify open→TRIGGERED
- `TOOL_CALIBRATE_QUERY_PROBE` / query the Nudge pin — verify NC behavior
- Thermistors read room temp on bed + both extruders
- 50°C bed test, then brief hotend PID tests, watch both hotend fans
  spin at 60°C and report RPM
- Stepper direction checks at low current with STEPPER_BUZZ

Then proceed to the commissioning sequence in README.md.