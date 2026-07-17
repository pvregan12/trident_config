#!/usr/bin/env bash
# deep_check.sh -- LAYER 2 validation: execute gcode/macros in Klipper
# batch mode against simulated MCUs. Catches runtime macro errors
# (bad printer.* references, Jinja logic blowups) that check.sh's
# load-only validation cannot see.
#
# Usage:  ./deep_check.sh [config-dir] [test-gcode-file]
#         defaults: ./config  and a built-in smoke test
#
# Requirements beyond check.sh: an ARM cross-compiler to build the MCU
# data dictionaries (one-time, cached):
#   Fedora:  sudo dnf install arm-none-eabi-gcc-cs arm-none-eabi-newlib
#   Debian:  sudo apt install gcc-arm-none-eabi libnewlib-arm-none-eabi
#
# HONEST LIMITS:
#  - The Cartographer runs vendor firmware with no public dict, so the
#    batch variant stubs it out: cartographer.cfg include is disabled
#    and stepper_z gets a fake physical endstop. Anything touching the
#    scanner is NOT exercised here.
#  - Macros needing real state (homing, actual toolchanges, probing)
#    will error in simulation; test only state-light macros by default.
#  - This validates macro EVALUATION, not physical correctness.

set -euo pipefail
CFG_SRC="${1:-./config}"
CFG_SRC="$(realpath "$CFG_SRC")"
GCODE_IN="${2:-}"
CACHE="${HOME}/.cache/klipper-validate"
KLIPPER="$CACHE/klipper"
PY="$CACHE/venv/bin/python3"

[[ -x "$PY" ]] || { echo "ERROR: run check.sh once first (builds the cached toolchain)"; exit 2; }
[[ -f "$CFG_SRC/printer.cfg" ]] || { echo "ERROR: no printer.cfg at top level of '$CFG_SRC'"; exit 2; }

# ---------- MCU dictionaries (cached, one-time compile) ----------
build_dict () {  # $1 = name, $2 = kconfig lines
    local out="$CACHE/$1.dict"
    [[ -f "$out" ]] && return 0
    command -v arm-none-eabi-gcc >/dev/null || {
        echo "ERROR: arm-none-eabi-gcc not found (see header for install)"; exit 2; }
    echo ">> Building $1 MCU dictionary (one-time)"
    ( cd "$KLIPPER" && make clean >/dev/null 2>&1
      printf '%b\n' "$2" > .config
      make olddefconfig >/dev/null 2>&1
      make -j"$(nproc)" >/dev/null 2>&1
      cp out/klipper.dict "$out" )
}
build_dict stm32f446 "CONFIG_MACH_STM32=y\nCONFIG_MACH_STM32F446=y"
build_dict rp2040    "CONFIG_MACH_RPXXXX=y\nCONFIG_MACH_RP2040=y"

# ---------- batch-mode config variant ----------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp -r "$CFG_SRC"/. "$T"/ && mkdir -p "$T/gcodes"
[[ -f "$T/mainsail.cfg" ]] || cat > "$T/mainsail.cfg" <<'EOF'
[virtual_sdcard]
path: gcodes
[display_status]
[pause_resume]
[gcode_macro PAUSE]
rename_existing: BASE_PAUSE
gcode:
    BASE_PAUSE
[gcode_macro RESUME]
rename_existing: BASE_RESUME
gcode:
    BASE_RESUME
[gcode_macro CANCEL_PRINT]
rename_existing: BASE_CANCEL_PRINT
gcode:
    BASE_CANCEL_PRINT
EOF
SAVEFILE=$(find "$T" -name "offset_save_file.cfg" -o -name "variables.cfg" | head -1)
[[ -z "$SAVEFILE" ]] && SAVEFILE="$T/offset_save_file.cfg"
sed -i "s|^filename: .*|filename: $SAVEFILE|" "$T/printer.cfg"
# stub missing include targets (installer/KAMP-provided)
python3 - "$T" <<'PYSTUB'
import sys, os, re

root = sys.argv[1]
seen = set()

def walk(path):
    if not os.path.exists(path) or path in seen:
        return

    seen.add(path)

    for line in open(path, errors="replace"):
        m = re.match(r"\s*\[include ([^]]+)\]", line)
        if not m:
            continue

        inc = m.group(1)
        target = os.path.join(os.path.dirname(path), inc)

        if os.path.exists(target):
            walk(target)
        else:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            open(target, "w").write(
                "# auto-stub by deep_check.sh: missing include\n"
            )
            print(f"    (stubbed missing include: {inc})")

walk(os.path.join(root, "printer.cfg"))
PYSTUB
"$PY" - "$T/printer.cfg" <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("[include cartographer.cfg]",
"""#[include cartographer.cfg]   ; BATCH: cartographer stubbed (vendor fw, no dict)
[bed_mesh]
speed: 200
horizontal_move_z: 5
mesh_min: 30,30
mesh_max: 270,270
probe_count: 5,5
[probe]
pin: PA4
z_offset: 0""")
s = s.replace("endstop_pin: probe:z_virtual_endstop   # Cartographer",
"""endstop_pin: PA3                       # BATCH stub
position_endstop: 0                    # BATCH stub""")
open(p,'w').write(s)
PYEOF

# ---------- test gcode ----------
if [[ -n "$GCODE_IN" ]]; then
    cp "$GCODE_IN" "$T/test.gcode"
else
    cat > "$T/test.gcode" <<'EOF'
; default smoke test: state-light macros only
M104 S0
M140 S0
M106 S128
M107
CHECK_HOTEND_FANS
SET_TOOL_PARAMETER T=0 PARAMETER=params_park_x VALUE=-1000
_TOUCH_HOME_ACTIVE_TOOL
INITIALIZE_TOOLCHANGER
_CHANGE_TOOL
_TOUCH_HOME_ACTIVE_TOOL
PRIME_ACTIVE_TOOL
M115
EOF
fi

# ---------- run batch mode ----------
( cd "$T" && timeout 90 "$PY" "$KLIPPER/klippy/klippy.py" printer.cfg \
    -i test.gcode -o out.serial \
    -d "$CACHE/stm32f446.dict" -d nhk0="$CACHE/rp2040.dict" -d nhk1="$CACHE/rp2040.dict" \
    -l klippy.log >/dev/null 2>&1 ) || true

FAIL=0
if grep -q "^Config error" "$T/klippy.log"; then
    echo "FAIL (config stage -- run check.sh for detail):"
    grep -A14 "^Config error" "$T/klippy.log" | sed 's/^/    /'; FAIL=1
fi
if grep -q "Error evaluating\|CommandError\|Internal error" "$T/klippy.log"; then
    echo "FAIL (runtime -- macro/gcode errors during execution):"
    grep -B1 -A3 "Error evaluating\|CommandError\|Internal error" "$T/klippy.log" \
        | sed 's/^/    /' | head -30; FAIL=1
fi
if [[ $FAIL -eq 0 ]]; then
    if [[ -s "$T/out.serial" ]]; then
        echo "PASS -- test gcode executed cleanly ($(wc -c < "$T/out.serial") bytes of MCU commands generated)"
    else
        echo "INCONCLUSIVE -- no errors but no MCU output; check timeout/log"
        tail -5 "$T/klippy.log" | sed 's/^/    /'; FAIL=1
    fi
fi
exit $FAIL