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

CACHE="${HOME}/.cache/klipper-validate"
PY="$CACHE/venv/bin/python3"
RUN_SECS=15
CFG_SRC=""
for arg in "$@"; do case "$arg" in
    --fresh)  rm -rf "$CACHE";;
    --update) UPDATE=1;;
    --single) SINGLE=1;;
    --*)      echo "ERROR: unknown flag '$arg'"; exit 2;;
    *)        CFG_SRC="$arg";;
esac; done
CFG_SRC="${CFG_SRC:-./config}"

[[ -d "$CFG_SRC" ]] || { echo "ERROR: config dir '$CFG_SRC' not found"; exit 2; }
[[ -f "$CFG_SRC/printer.cfg" ]] || {
    echo "ERROR: no printer.cfg at top level of '$CFG_SRC'."
    echo "       If your configs live in the repo root, run:  ./check.sh ."
    exit 2
}

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
    cp -r "$CFG_SRC"/. "$T"/
    mkdir -p "$T/gcodes"
    # duplicate-macro guard: Klipper merges duplicate sections
    # SILENTLY (last include wins). INCLUDE-GRAPH-AWARE: only files
    # actually reachable via [include] from printer.cfg count --
    # archived/library .cfg files sitting in the tree are ignored,
    # exactly as Klipper ignores them. NOTE: runs BEFORE prep, so it
    # audits the repo's real (full toolchanger) include graph.
    local dups
    dups=$(python3 - "$T" <<'PYDUP'
import sys, os, re
root = sys.argv[1]
seen_files, sections = set(), []
def walk(path):
    if not os.path.exists(path) or path in seen_files: return
    seen_files.add(path)
    for line in open(path, errors="replace"):
        line = line.strip()
        m = re.match(r"\[include ([^]]+)\]", line)
        if m:
            walk(os.path.join(os.path.dirname(path), m.group(1)))
        elif re.match(r"\[(gcode_macro |homing_override\]|toolchanger\]|bed_mesh\])", line):
            sections.append(line)
walk(os.path.join(root, "printer.cfg"))
from collections import Counter
for sec, n in sorted(Counter(sections).items()):
    if n > 1: print(sec)
PYDUP
)
    [[ -n "$dups" ]] && { echo "FAIL [$label]: duplicate sections (silent-merge hazard):"; echo "$dups" | sed 's/^/    /'; return 1; }
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
    # auto-stub any include target missing from the repo (installer-
    # or KAMP-provided files, or a filename typo). Recurse the include
    # graph so subdir includes are covered.
    python3 - "$T" <<'PYSTUB'
import sys, os, re
root = sys.argv[1]
seen = set()
def walk(path):
    if not os.path.exists(path) or path in seen: return
    seen.add(path)
    for line in open(path, errors="replace"):
        m = re.match(r"\s*\[include ([^]]+)\]", line)
        if not m: continue
        inc = m.group(1)
        target = os.path.join(os.path.dirname(path), inc)
        if os.path.exists(target):
            walk(target)
        else:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            open(target, "w").write("# auto-stub by check.sh: %s missing from repo\n" % inc)
            print("    (stubbed missing include: %s)" % inc)
walk(os.path.join(root, "printer.cfg"))
PYSTUB
    # point save_variables at the temp dir
    # point [save_variables] at the copied tree (path-agnostic)
    SAVEFILE=$(find "$T" -name "offset_save_file.cfg" -o -name "variables.cfg" | head -1)
    [[ -z "$SAVEFILE" ]] && SAVEFILE="$T/offset_save_file.cfg"
    sed -i "s|^filename: .*|filename: $SAVEFILE|" "$T/printer.cfg"
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
    # path-agnostic: includes may live under a subdirectory (e.g.
    # klipper-toolchanger/toolchanger.cfg). tool_detection is dormant
    # in the r2pdx layout but harmless to comment as well.
    sed -i -E 's@^\[include ([^]]*/)?(toolhead-T1|toolchanger|nudge|tool_detection)\.cfg\]@#&@' "$T/printer.cfg"
    local T0FILE
    T0FILE=$(find "$T" -name "toolhead-T0.cfg" | head -1)
    [[ -z "$T0FILE" ]] && { echo "single-tool prep: no toolhead-T0.cfg found"; return 0; }
    python3 - "$T0FILE" <<'PYEOF2'
import sys
p = sys.argv[1]; s = open(p).read()
i = s.index('[gcode_macro T0]')
head, tail = s[:i], s[i:]
tail = '\n'.join(('#'+l if l.strip() and not l.startswith('#') else l) for l in tail.split('\n'))
# fan stays [fan_generic]: the phase-aware M106 override routes to it
open(p, 'w').write(head + tail)
PYEOF2
}

# ---------- run ----------
RC=0
validate "full toolchanger" || RC=1
if [[ "${SINGLE:-}" == 1 ]]; then
    validate "single-tool (Phase 1-3)" single_tool_prep || RC=1
fi
exit $RC