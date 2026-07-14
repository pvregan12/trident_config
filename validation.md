# Pre-hardware config validation

Klipper's host process parses the full config, validates every
section/option against the real schema, and compiles all macro Jinja
BEFORE attempting MCU connection. Running klippy against the config
with fake serial paths therefore validates everything except pins-vs-
board and physical reality. "Error during identify" on the fake MCU is
the success condition -- it means config parsing completed.

## Harness setup (any Linux box, incl. the Pi before wiring)
```bash
git clone --depth 1 https://github.com/Klipper3d/klipper
git clone --depth 1 https://github.com/viesturz/klipper-toolchanger kt
# cartographer: NEW plugin is a pip package (see check.sh for the
# extras scaffolding link it needs)
pip install --break-system-packages cffi pyserial greenlet jinja2 markupsafe python-can numpy
ln -sf $PWD/kt/klipper/extras/*.py klipper/klippy/extras/
pip install cartographer3d-plugin   # then link its extra.py as klippy/extras/cartographer.py

mkdir cfgtest && cp config/*.cfg cfgtest/ && cd cfgtest
# stub mainsail.cfg (virtual_sdcard, display_status, pause_resume,
# PAUSE/RESUME/CANCEL_PRINT rename macros) and a gcodes/ dir
# point [save_variables] filename at a local path
python3 ../klipper/klippy/klippy.py printer.cfg -o /dev/null -d /dev/null -l klippy.log
grep -A14 "^Config error" klippy.log   # empty = pass
```

## What this catches / misses
Catches: invalid sections & options, include mistakes, duplicate
gcode command registrations (found the PROBE conflict), macro Jinja
syntax errors, missing required options, section ordering issues.
Misses: wrong-but-valid pins, polarity, geometry, anything physical.

## Validation status (last run, plugin/Klipper main as of this date)
- Full toolchanger config: PASSES to MCU-identify
- Phase 1-3 single-tool variant (per COMMISSIONING Phase 1 step 2):
  PASSES to MCU-identify
- Errors found & fixed by this harness:
  1. [tool_probe_endstop] vs the Cartographer plugin: both register
     the PROBE gcode command -> config error. Fixed by moving to the
     current plugin's native detection: detection_pin on each [tool]
     plus abort_on_tool_missing/tool_missing_delay on [toolchanger];
     removed [tool_probe T0/T1], [tool_probe_endstop], and the
     tool_probe-based init/crash macros. (r2pdx's config targets the
     older plugin API; this is the version-skew hazard in action.)
  2. [exhaust_fan] is not a Klipper section -> [fan_generic exhaust_fan].

Re-run after any config change, and especially after updating
klipper or klipper-toolchanger.

## Layer 2: deep_check.sh (batch-mode execution)
klippy batch mode (-i gcode -o serial, with compiled MCU data
dictionaries) EXECUTES gcode against simulated MCUs -- macros actually
evaluate, catching runtime Jinja errors (bad printer.* references,
logic blowups) that load-only validation passes. Requires
arm-none-eabi-gcc for the one-time dict builds (cached). The
Cartographer is stubbed out (vendor firmware, no public dict), so
scanner-dependent paths aren't exercised. Default smoke test runs
state-light macros (M104/M106/M107 overrides, CHECK_HOTEND_FANS,
SET_TOOL_PARAMETER); pass a custom gcode file as arg 2 to exercise
more. Demonstrated catch: a macro referencing the removed
tool_probe_endstop object -- PASS in check.sh, FAIL here with the
exact Jinja error and line.

## Plugin generation note (July 2026)
Config uses the NEW cartographer3d-plugin ([cartographer] section,
[mcu cartographer], Survey 5.0+ firmware). The older
cartographer-klipper repo used [scanner] and different options; the
two are not interchangeable by rename alone. check.sh validates
against the new plugin (v1.9.0b1 at last run): both variants PASS.