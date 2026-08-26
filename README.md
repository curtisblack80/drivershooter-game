# Driver Shooter

A four-player cooperative vehicle-based third-person shooter in Godot 4.

The vehicle is not transport between fights. It is the fight: the crew's base,
their cover, their weapon platform and their most fragile asset, all while it is
moving. Players sit in it, climb out of its windows onto the hood and roof, fight
from wherever they are standing, and patch it up mid-drive.

**Status: Phase 1 complete — the vertical slice is built and validated
structurally, but it has never been run.** See
[Honest status](#honest-status) before you judge it.

---

## Requirements

- **Godot 4.3 or newer** (4.4 and 4.5 are fine). No C#, no plugins, no
  external assets — the whole project is GDScript and primitive meshes.
- Python 3.10+ if you want to run the project validator.

## Running it

1. Open the project folder in Godot and let it import.
2. Press **F5**.

### Testing multiplayer on one machine

This is the normal way to work on this project:

1. **Debug → Run Multiple Instances → 2 (or 4) instances**.
2. Press F5. Several game windows appear.
3. In one window press **Host Match**.
4. In the others press **Join Match** (the address defaults to `127.0.0.1`).
5. Everyone picks a role and presses **Ready**; the host presses **Start Match**.

Each window gets a different default callsign so the lobby stays readable.

## Controls

| Input | On foot / on the vehicle | While driving |
|---|---|---|
| `W` `A` `S` `D` | Move | Throttle, steer, reverse |
| `Space` | Jump (dismounted) | Handbrake |
| `Shift` | Sprint (dismounted) | — |
| Mouse | Look and aim | Look |
| Left click | Fire | — (hands on the wheel) |
| Right click | Aim down sights | — |
| `R` | Reload | — |
| `E` | Use the highlighted interaction | — |
| `Q` | Cycle to the next interaction | — |
| `F` | Get out of your seat | Get out of your seat |
| `F3` | Toggle the network debug panel | |
| `Alt`+`Esc` | Release / recapture the mouse | |
| `Esc` | Leave the match | |

The driver cannot use a personal weapon. That is deliberate: it makes handing
over the wheel a real decision rather than a formality.

## What is in the build

- Host/join over ENet, a lobby with role selection and a ready check, and a
  two-phase match-start handshake.
- One vehicle (Tactical SUV) with arcade handling, speed-scaled steering,
  downforce, and self-righting when it ends up on its roof.
- Four seats, four walkable surfaces (cabin, hood, roof, cargo bed) and nine
  authored traversal links between them, including window climbs.
- Crew who stay attached to the vehicle **by construction** — see
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Hitscan weapons with client prediction and server-authoritative resolution.
- Per-component vehicle damage (engine, wheels, armour, radiator, fuel tank …)
  where damage changes how the vehicle drives.
- An enemy that prefers to shoot crew who are exposed on the outside of the
  vehicle, which is what makes climbing onto the roof an actual decision.

## Project layout

```
scripts/
  core/         enums, logging, the signal bus, scene routing, maths
  networking/   ENet session, roster, snapshot interpolation, RPC guards
  vehicle/      chassis, crew rig, attachment points, surfaces, links, damage
  player/       crew state machine, attachment maths, camera, input
  weapons/      weapon definitions and firing
  combat/       damage routing, tracers
  enemies/      enemy AI
  systems/      health, spawners
  ui/           menu, lobby, HUD
scenes/         one scene per script that needs one, mirroring the above
resources/      .tres data for vehicles and weapons
tools/          the project validator
docs/           architecture and testing notes
```

The rule: **behaviour lives in `scripts/`, data lives in `resources/`, and
`scenes/` wires them together.** Adding a vehicle class or a weapon means
authoring a resource and a scene, never editing a controller.

## Validating the project

```bash
python3 tools/validate_project.py .
```

This checks every `res://` path, every `ExtResource`/`SubResource` id, every
node parent, every relative `NodePath`, every `$Child` and `%Unique` lookup,
every input action used from GDScript, `class_name` collisions, and a
Godot-specific RPC trap (a `rpc_id(1, …)` on a method that is not `call_local`,
which silently does nothing on the host).

It exists because most of these mistakes are invisible until the exact moment
the broken code path runs — often in the middle of a four-player playtest. It is
not a substitute for opening the editor; it proves that things *refer to things
that exist*, not that the code is correct.

## Honest status

Everything here was written without a Godot install available, so:

- **It has never been executed.** The validator proves structural integrity —
  no dangling references, no mistyped node paths, no undefined input actions —
  and the code sticks to documented Godot 4 APIs. It cannot prove the game runs.
- Expect first-run work: tuning numbers, and possibly a handful of small fixes
  the editor will point at immediately.
- [docs/TESTING.md](docs/TESTING.md) is written for exactly this: it walks
  through each system in dependency order, with the specific thing to look for
  and what it means when it is wrong.

## What comes next

Phase 1 was the milestone that had to be proven first: *four players can occupy
one moving vehicle, fight from it, and physically move around it without ever
coming detached.* The systems that follow build on that and are deliberately not
started yet — the repair loop (Phase 4) has its data model and its repair points
in place but no interaction, and vehicle-mounted weapons, progression and
additional vehicle classes are untouched.

The full roadmap and the known limitations of each system are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
