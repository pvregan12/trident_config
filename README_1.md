# Voron Trident 300 + MadMax: Klipper Config Guide

A resource and skeleton config set for an LDO 300 CUBE Trident with two identical toolheads on a MadMax toolchanger, Nitehawk36 toolhead boards, XY microswitch homing, and Cartographer Z.

## Software stack

1. **Klipper + Moonraker + Mainsail** — standard install (KIAUH is fine).
2. **cartographer3d-plugin (NEW)** — installed into klippy-env via their install.sh one-liner (see INSTALL.md §4). Adds the `[cartographer]` section and probe commands; pairs with Survey 5.0+ firmware. (Supersedes the cartographer-klipper repo and its `[scanner]` section.)
3. **viesturz/klipper-toolchanger** — the framework MadMax's sample configs target. `git clone https://github.com/viesturz/klipper-toolchanger && ./install.sh`. Adds `[toolchanger]`, `[tool ...]`, `[tool_probe]` sections. (Fan routing and T0/T1 commands come from r2pdx-derived toolchanger_macros.cfg in this package, not the plugin.) Add both plugins to `moonraker.conf` update_manager so they stay current.
4. **MadMax repo `/Configs`** — copy the sample dropoff/pickup path params from there; they encode the actual keyslot geometry. Treat this package's coordinates as placeholders.
5. **Nudge + r2pdx auto-offset calibration** (now included via `nudge.cfg`). `[tools_calibrate]` is part of klipper-toolchanger (no extra plugin). Download `offset_save_file.cfg` and `tc_offset_calibration_macros.cfg` from https://github.com/joseph-greiner/klipper_tc_automatic_offset_calibration into the config dir and uncomment their includes in `nudge.cfg`. Wire the Nudge to a spare MAIN-board endstop input (normally closed, no inversion) so it works regardless of attached tool. Consider 64x microsteps on X/Y for calibration resolution.

## File layout

```
printer.cfg          main MCU, kinematics, XY/Z steppers, bed, misc
cartographer.cfg     cartographer MCU, [cartographer], [bed_mesh]
nudge.cfg            [tools_calibrate], Nudge wrapper macros,
                     hooks for r2pdx's auto-offset files
toolchanger.cfg      [toolchanger], [tool T0], [tool T1], safety
toolhead-T0.cfg      nhk0 MCU, [extruder], fans, LEDs, ADXL
toolhead-T1.cfg      nhk1 MCU, [extruder1], fans, LEDs, ADXL
macros.cfg           homing_override, PRINT_START/END, test cycle
```

## Key design decisions & gotchas

**Two USB Nitehawks.** Each RP2040 enumerates with a unique serial — flash both, label physically, and pin each `[mcu]` to its `/dev/serial/by-id/` path. USB umbilicals for two tools need careful routing so the docked tool's cable doesn't foul the moving gantry; this is one of the fussier physical parts of a MadMax 2-tool build.

**Second extruder must be `extruder1`** (Klipper convention). All per-tool objects get a tool-prefixed name (`T0_partfan`, `T1_hotend_fan`) and are mapped through `[tool]` sections so `M106`, `M104 T1`, etc. route to the active tool.

**Cartographer placement.** Best MadMax practice is mounting the probe where it survives toolchanges — either on the core carriage or accept that it rides on T0 and force T0 active for all Z operations (`G28 Z`, `Z_TILT_ADJUST`, `BED_MESH_CALIBRATE`). The macros in this package assume the probe is always present; if it's T0-mounted, add `SELECT_TOOL T=0` guards.

**MadMax coupling-as-probe.** The Maxwell coupling can serve as tool-detect and even as a Tap-style probe. With Cartographer you don't need it for Z, but wire the detect circuit anyway: klipper-toolchanger's crash detection uses it to `M112` if a head detaches mid-print — important because MadMax holds tools magnetically with no positive lock.

**XY-only dock path.** MadMax needs no liftbar on a Trident; the pickup/dropoff paths are pure XY moves through the keyslots. Slow (`params_path_speed` ~600–1200 mm/min) through the dock, fast between. A known pitfall from Trident builders: the stock sample `toolchanger.cfg` path code may look up a Z component in the path params — strip Z from paths or provide `params_park_z` to keep the templates happy.

**Dock keep-out.** Reserve the dock zone in Y. Either shrink `position_max` (loses the zone entirely) or keep full travel and enforce keep-out in macros (what the MissChanger/MadMax crowd does). Never `G28 Z` or mesh near the docks.

**Homing order.** X and Y home to microswitches normally. Z homes via Cartographer *touch* at bed center — `homing_retract_dist: 0` on `[stepper_z]` is required, and Z homing must happen after XY (handled in `homing_override`).

## Commissioning sequence

1. Flash Leviathan/Octopus, both Nitehawks, Cartographer. Verify all four MCUs connect.
2. Single-tool bring-up first: run the printer as a normal Trident with T0 only. Verify endstops, stepper directions, PID both heaters, scan calibration, then touch calibration (per current Cartographer docs), z_tilt, bed mesh, input shaper (T0 ADXL).
3. Install docks + T1. Measure dock park positions by jogging: seat the tool by hand, `GET_POSITION`, record.
4. Tune dropoff/pickup paths at low speed with `params_path_speed` slow and hand on the E-stop. `DOCK_SEQUENCE REPS=100` until zero faults.
5. Calibrate tool offsets: coarse manually (print a calibration cross with each tool), fine with Nudge + auto-offset macros. Offsets persist via `[save_variables]` / `gcode_x/y/z_offset`.
6. Verify T1 input shaper matches T0 (identical heads should be close; confirm with the T1 ADXL).
7. Slicer: PrusaSlicer/OrcaSlicer multi-extruder profile, 2 extruders, tool change G-code = just `T[next_extruder]`; pass both temps to `PRINT_START`.

## Every `<VERIFY>` / `<MEASURE>` tag

Pins are representative, not gospel — check the LDO CUBE wiring guide for your exact main board revision, the Nitehawk36 pinout doc, and measure all dock/park/safe-Y coordinates on the physical machine. The config is structured so all machine-specific numbers are flagged inline.