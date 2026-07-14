#!/usr/bin/env bash
# check.sh -- validate Klipper configs without hardware.
# Usage:  ./check.sh [path-to-config-dir]   (default: ./config)
# Flags:  --fresh     delete the cached toolchain and re-clone
#         --update    git pull klipper + plugins before validating
#         --single    also validate the Phase 1-3 single-tool variant
#
# The toolchain (klipper + plugins + venv) is cached in
# ~/.cache/klipper-validate so repeat runs take seconds, not minutes.
# The per-run test directory is a mktemp dir, removed on exit.

set -euo pipefail

CFG_SRC="${1:-./config}"; [[ "${CFG_SRC}" == --* ]] && CFG_SRC=./config
CACHE="${HOME}/.cache/klipper-validate"
RUN_SECS=15

for arg in "$@"; do case "$arg" in
    --fresh)  rm -rf "$CACHE";;
    --update) UPDATE=1;;
    --single) SINGLE=1;;
esac; done

[[ -d "$CFG_SRC" ]] || { echo "ERROR: config dir '$CFG_SRC' not found"; exit 2; }
compgen -G "$CFG_SRC/*.cfg" > /dev/null || {
    echo "ERROR: no .cfg files in '$CFG_SRC'."
    echo "       If your configs live in the repo root, run:  ./check.sh ."
    exit 2
}
[[ -f "$CFG_SRC/printer.cfg" ]] || { echo "ERROR: '$CFG_SRC' has .cfg files but no printer.cfg"; exit 2; }

# ---------- toolchain (cached) ----------
if [[ ! -d "$CACHE/klipper" ]]; then
    echo ">> First run: setting up toolchain in $CACHE (one-time, ~2 min)"
    mkdir -p "$CACHE" && cd "$CACHE"
    python3 -m venv venv
    ./venv/bin/pip -q install cffi pyserial greenlet jinja2 markupsafe python-can numpy
    git clone -q --depth 1 https://github.com/Klipper3d/klipper
    git clone -q --depth 1 https://github.com/viesturz/klipper-toolchanger kt
    ln -sf "$CACHE"/kt/klipper/extras/*.py klipper/klippy/extras/
    # NEW cartographer plugin: python package into the venv, plus the
    # extras scaffolding link its install.sh would create
    ./venv/bin/pip -q install "cartographer3d-plugin"
    CARTO_ENTRY=$(grep -rln "def load_config" venv/lib/python3*/site-packages/cartographer/ | head -1)
    ln -sf "$CACHE/$CARTO_ENTRY" klipper/klippy/extras/cartographer.py
fi
if [[ "${UPDATE:-}" == 1 ]]; then
    echo ">> Updating klipper + plugins"
    for d in klipper kt; do git -C "$CACHE/$d" pull -q; done
    ./venv/bin/pip -q install --upgrade "cartographer3d-plugin"
    # re-link in case plugins added new extras files
    ln -sf "$CACHE"/kt/klipper/extras/*.py "$CACHE"/klipper/klippy/extras/
fi

# ---------- one validation pass ----------
validate () {  # $1 = label, $2 = prep-function to mutate configs (or "")
    local label="$1" prep="${2:-}"
    local T; T=$(mktemp -d)
    trap 'rm -rf "$T"' RETURN
    cp "$CFG_SRC"/*.cfg "$T"/
    mkdir -p "$T/gcodes"
    # stub installer-provided mainsail.cfg if the repo doesn't carry one
    if [[ ! -f "$T/mainsail.cfg" ]]; then cat > "$T/mainsail.cfg" <<'EOF'
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
    fi
    # point save_variables at the temp dir
    sed -i "s|filename: .*offset_save_file.cfg|filename: $T/offset_save_file.cfg|" "$T/printer.cfg"
    [[ -n "$prep" ]] && "$prep" "$T"

    ( cd "$T" && timeout "$RUN_SECS" "$CACHE/venv/bin/python3" \
        "$CACHE/klipper/klippy/klippy.py" printer.cfg \
        -o /dev/null -d /dev/null -l klippy.log >/dev/null 2>&1 ) || true

    if grep -q "^Config error" "$T/klippy.log"; then
        echo "FAIL [$label]:"
        grep -A14 "^Config error" "$T/klippy.log" | sed 's/^/    /'
        return 1
    elif grep -q "Error during identify" "$T/klippy.log"; then
        echo "PASS [$label] -- config valid to MCU boundary"
    else
        echo "INCONCLUSIVE [$label] -- no config error but never reached MCU identify."
        echo "    Possible causes: timeout too short, python/dep failure. Tail of log:"
        tail -5 "$T/klippy.log" | sed 's/^/    /'
        return 1
    fi
}

# ---------- Phase 1-3 single-tool mutation (mirrors COMMISSIONING) ----------
single_tool_prep () {
    local T="$1"
    sed -i -E 's|^\[include (toolhead-T1\|toolchanger\|toolchanger_macros\|homing_toolchanger\|nudge)\.cfg\]|#&|' "$T/printer.cfg"
    python3 - "$T/toolhead-T0.cfg" <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
i = s.index('[gcode_macro T0]')
head, tail = s[:i], s[i:]
tail = '\n'.join(('#'+l if l.strip() and not l.startswith('#') else l) for l in tail.split('\n'))
s = (head + tail).replace('[fan_generic part_fan_t0]', '[fan]')
open(p, 'w').write(s)
PYEOF
}

# ---------- run ----------
RC=0
validate "full toolchanger" || RC=1
if [[ "${SINGLE:-}" == 1 ]]; then
    validate "single-tool (Phase 1-3)" single_tool_prep || RC=1
fi
exit $RC