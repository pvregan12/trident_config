#!/usr/bin/env bash
# config_audit.sh -- semantic greps over a Klipper config tree.
# Complements check.sh (load validity) and check_calls.py (reachability).
# These are things that LOAD fine but are wrong.
#
# Usage: ./config_audit.sh [config_dir]   (default ./config)

CFG="${1:-./config}"
[[ -f "$CFG/printer.cfg" ]] || { echo "no printer.cfg in $CFG"; exit 2; }

hdr () { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
note () { printf '   %s\n' "$1"; }

hdr "Sense resistors by driver family (5160=0.075, 2209=0.110, nhk=0.100)"
grep -rn -A6 "^\[tmc" "$CFG" --include=*.cfg | grep -E "^\S+[-:]\[tmc|sense_resistor" \
  | sed 's/.*config\///'

hdr "Run currents (XY~1.2, Z~0.8, extruder~0.5)"
grep -rn -B4 "run_current" "$CFG" --include=*.cfg | grep -E "\[tmc|run_current" \
  | sed 's/.*config\///'

hdr "PT1000 sections missing pullup_resistor (each should have 2200)"
for f in $(grep -rl "PT1000" "$CFG" --include=*.cfg); do
  pt=$(grep -c "sensor_type: *PT1000" "$f")
  pu=$(grep -c "pullup_resistor" "$f")
  [[ "$pt" != "$pu" ]] && note "MISMATCH $f: $pt PT1000 vs $pu pullup lines"
done
note "(no output above = every PT1000 has a pullup)"

hdr "Placeholder sentinels still unset (-1000 = must measure)"
grep -rn -- "-1000" "$CFG" --include=*.cfg | sed 's/.*config\///'

hdr "Unresolved markers"
grep -rn "<VERIFY>\|<MEASURE>\|TODO\|FIXME\|XXX" "$CFG" --include=*.cfg \
  | sed 's/.*config\///'

hdr "Duplicate section headers across the tree"
grep -rhoE "^\[[a-z_]+ ?[A-Za-z_0-9]*\]" "$CFG" --include=*.cfg | sort | uniq -d

hdr "Duplicate M-code macros (plugin conflict class)"
grep -rhoE "^\[gcode_macro [Mm][0-9]+\]" "$CFG" --include=*.cfg | sort | uniq -d
note "(also: does the toolchanger plugin already provide M106/M107?)"

hdr "Bare [fan] present? (conflicts with toolchanger fan routing)"
grep -rn "^\[fan\]" "$CFG" --include=*.cfg || note "none -- good for toolchanger mode"

hdr "Every [tool] has fan: and detection_pin:"
grep -rn -A12 "^\[tool " "$CFG" --include=*.cfg \
  | grep -E "\[tool |tool_number|fan:|detection_pin" | sed 's/.*config\///'

hdr "Pin reuse (same pin in two places -- klipper catches, but see context)"
grep -rhoE "pin: *!?\^?~?[A-Z]+[0-9]+" "$CFG" --include=*.cfg \
  | grep -oE "[A-Z]+[0-9]+$" | sort | uniq -d

hdr "Steppers: rotation_distance / microsteps / full_steps"
grep -rn -A8 "^\[stepper" "$CFG" --include=*.cfg \
  | grep -E "\[stepper|rotation_distance|microsteps|full_steps|homing_speed|position_endstop" \
  | sed 's/.*config\///'

hdr "Heaters: min/max temp and PID presence"
grep -rn -A20 "^\[extruder\|^\[heater_bed" "$CFG" --include=*.cfg \
  | grep -E "\[extruder|\[heater_bed|min_temp|max_temp|control:|max_power" \
  | sed 's/.*config\///'

hdr "Unguarded STATUS_* calls (will error without _sb_vars)"
grep -rn -B2 "STATUS_[A-Z_]*" "$CFG" --include=*.cfg \
  | grep -A1 -B1 "STATUS_" | grep -v "_sb_vars" | grep "STATUS_" \
  | grep -v "gcode_macro STATUS" | sed 's/.*config\///'
note "(review each: is it inside an {% if ... _sb_vars is defined %} block?)"

hdr "Stale file references in messages/comments"
grep -rn "\.cfg" "$CFG" --include=*.cfg | grep -E "RESPOND|MSG=|# *see|edit the" \
  | sed 's/.*config\///'

hdr "save_variables keys: read vs seeded"
SAVEFILE=$(grep -rhoE "^filename: *.*" "$CFG" --include=*.cfg | head -1 | awk '{print $2}')
note "save file: $SAVEFILE"
grep -rhoE "svf\[[^]]+\]|variables\.[a-z_0-9]+" "$CFG" --include=*.cfg \
  | grep -oE "[a-z_][a-z_0-9]*" | grep -vE "^(svf|variables|string|float|int|round)$" \
  | sort -u | head -20
note "(compare against the keys actually present in the save file)"