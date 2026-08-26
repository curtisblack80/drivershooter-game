# Testing

This project was written without a Godot install available, so it has been
validated structurally but never executed. This document is the first-run plan:
it works through the systems in dependency order, so that when something breaks
you are looking at one new system rather than five at once.

Work top to bottom. Do not skip ahead — a failure in step 2 will produce
confusing symptoms in step 6.

Run this first, and after every change to a scene:

```bash
python3 tools/validate_project.py .
```

---

## Step 0 — The project opens

**Do:** open the folder in Godot 4.3+ and let it import.

**Expect:** no errors in the Output panel. Some scripts are `@tool`, so
attachment points and surfaces run in the editor and will report configuration
warnings on nodes that are misconfigured — those warnings are the system working.

**If it fails:** the error names a file and line. The most likely causes are a
Godot version older than 4.3, or a `.tscn` property that this Godot version
spells differently.

---

## Step 1 — Single player, no networking

**Do:** press F5. Host Match → Ready → Start Match.

**Expect:**
- The lobby shows one player marked `[host]` and `← you`.
- The arena loads: grey ground, a few blocks, an olive SUV.
- You spawn seated in the SUV. The HUD shows your role, `Seated`, a health bar,
  ammo, and a vehicle status list on the right.
- Eight red enemies are scattered around and start closing in.

**Check first:** press **F3**. The debug panel shows the vehicle's physics
authority, whether it is frozen, your crew state, and your surface coordinate.
This is the fastest way to tell what any later failure actually is.

**If crew spawn at the world origin instead of in the vehicle:** seat assignment
did not reach them. Look at `VehicleRig.server_assign_initial_seats()` and
`CrewController._on_occupancy_changed()`.

**If the vehicle sinks or bounces:** wheel geometry. `wheel_rest_length` and the
wheel node heights in `tactical_suv.tscn` must place the contact point at ground
level — see the note in `docs/ARCHITECTURE.md` §4.

---

## Step 2 — Driving

**Do:** `W` `A` `S` `D` to drive, `Space` for the handbrake.

**Expect:** responsive acceleration, steering that tightens up at low speed and
loosens at high speed, and a vehicle that stays planted through hard turns. The
speed readout climbs toward ~118 km/h.

**Tuning lives in `resources/vehicles/tactical_suv.tres`**, not in code. The
knobs, in rough order of how much they change the feel:

| Symptom | Knob |
|---|---|
| Flips in corners | raise `downforce_per_speed`, lower `steer_authority_at_top_speed` |
| Steering feels vague | lower `steer_half_life` |
| Too slow to accelerate | raise `engine_force` |
| Will not stop | raise `brake_force` |
| Slides everywhere | raise `wheel_friction_slip` on the wheels in the scene |

**Do:** deliberately flip the vehicle and wait. After ~2.5 s stationary it should
right itself (`allow_self_right`).

---

## Step 3 — Crew traversal (the milestone)

This is the system the whole design rests on. Test it thoroughly.

**Do, while stationary:**
1. Press `E` — the prompt should offer "Stand up". You move to the cabin floor
   and your state becomes `On Surface`.
2. Press `Q` to cycle the offered interactions; the prompt shows `1/n`.
3. Find "Climb through window to the roof" and press `E`. You should arc up and
   over, not teleport, and land on the roof as `On Surface`.
4. Walk around the roof with `W` `A` `S` `D`. You should be clamped at the edges,
   never falling off.
5. Walk to the front of the roof and press `E` to drop onto the hood.
6. Work your way back to a seat.

**Then repeat every step while the vehicle is moving.** This is the actual test.
Have a second player drive, or set a link's `max_vehicle_speed_kph` aside and
drive yourself into a wall to get some motion.

**Expect:**
- You never come off the vehicle. Not while cornering, not on landings, not when
  the vehicle is hit, not when it flips. If you ever detach, that is a genuine
  architectural bug, not a tuning issue — start at `CrewAttachment`.
- Walking on the roof gets harder under acceleration: you slow down, and inertia
  pushes you toward the back under acceleration and the front under braking.
- Window climbs refuse above 70 km/h with "Too fast to climb".
- The camera stays level with the horizon while your character tilts with the
  vehicle. If the camera rolls with the chassis, `top_level` is not set on
  `PlayerCameraRig`.

**If a link never appears in the prompt:** you are probably not close enough to
its anchor point. Traversals are offered from `SURFACE_ANCHOR` points within
their `interaction_radius`; walk to the front or rear of the surface. F3 shows
your surface coordinate.

---

## Step 4 — Combat

**Do:** from the roof, shoot an enemy. Reload with `R`. Aim with right click.

**Expect:** a visible tracer to where the crosshair is pointing, enemies dying
after a few hits, ammo counting down and reloading.

**Expect specifically:** you cannot shoot your own vehicle. Aim down at the hood
and fire — the shot should pass through, because the ridden vehicle is excluded
from the ray. If it is not, `Weapon.shot_exclusions()` is not finding the vehicle.

**Do:** sit in the driver's seat and try to fire. Nothing should happen, and the
crosshair should be hidden. That is deliberate.

**Do:** stand on the roof and let enemies shoot at you. They should prefer you
over the vehicle while you are exposed — that is `crew_target_bias` in
`enemy_grunt.tscn`, and it is the mechanic that makes the roof a real trade.

**Do:** get back inside and watch the vehicle status list on the right. Component
health should drop, turn amber below 25%, and red at zero. Shoot out a front
wheel and drive — the vehicle should pull to that side and lose grip.

---

## Step 5 — Two players

**Do:** Debug → Run Multiple Instances → 2. Host in one, join in the other with
`127.0.0.1`.

**Expect:**
- Both appear in each other's lobby roster; role and ready changes show on both.
- Only the host sees Start Match.
- Both spawn in the same vehicle, in different seats.
- The driver's vehicle moves smoothly on their own screen and smoothly-with-a-
  small-delay on the other. About 120 ms of delay is correct and deliberate
  (`NetConfig.INTERPOLATION_DELAY`).

**Then, the important checks:**

1. **The passenger climbs onto the roof.** On the driver's screen they should
   move over the vehicle smoothly and stay glued to it while the driver corners
   hard. Watch this specifically during hard turns.
2. **Both players shoot.** Each should see the other's tracers.
3. **The passenger takes the driver seat** (the driver must leave it first with
   `F`). Press F3 on both machines: `veh authority` should move to the new
   driver's peer, and `veh frozen` should flip on both. The vehicle must keep its
   momentum through the handover rather than stopping dead.
4. **The client disconnects** (close the window). The host should see them leave
   the roster, their crew member should disappear, and their seat should free up.

**If remote crew jitter or lag behind the vehicle:** they are being placed in
world space instead of composed from the vehicle transform. That is
`CrewController.simulate()` and `CrewAttachment.compose_world_transform()`.

**If a client's shots do nothing:** check the host's Output for
`peer N shot origin is …m from their body; rejected` — the origin check in
`Weapon._rpc_request_fire` may be too tight for your latency; raise
`max_origin_error`.

---

## Step 6 — Four players

Run four instances and fill every seat. Watch for:

- Every peer showing the same vehicle position and the same crew positions.
- Seat contention: two players pressing `E` on the same seat in the same moment.
  Exactly one should get it; the other should see "Occupied".
- Frame rate on the host, which is running AI for eight enemies plus its own
  rendering.

---

## Reading the logs

Every log line is tagged with the peer that produced it and the subsystem:

```
[S ][vehicle][INF] physics authority -> peer 3 (mine=false)
[C2][crew   ][WRN] seat claim 'driver_seat' timed out
```

`S` is the host, `Cn` is client peer n. To see more, raise the verbosity in
`scripts/core/game_log.gd`:

```gdscript
GameLog.min_level = GameLog.Level.DEBUG
```

To silence a chatty subsystem while chasing something else, add its tag to
`GameLog.muted_tags`. Tags in use: `boot`, `net`, `router`, `vehicle`, `crew`,
`weapon`, `spawn`, `level`.

---

## What the validator does and does not cover

**Covered:** missing `res://` paths, undeclared `ExtResource`/`SubResource` ids,
nodes whose parent was never declared, relative `NodePath` properties that
resolve to nothing, `$Child` and `%Unique` lookups that do not exist in the
scene, input actions used from GDScript but never defined, duplicate
`class_name`s, autoload collisions, space indentation, and the
`rpc_id(1, …)`-without-`call_local` trap.

**Not covered:** anything about runtime behaviour. Type errors, wrong API usage,
bad maths, and every gameplay bug still need the editor and the steps above.

To confirm the validator is actually checking rather than vacuously passing,
break something on purpose — rename a node referenced by a `NodePath` — and
watch it fail.
