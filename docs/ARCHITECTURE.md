# Architecture

This document covers the decisions that shape everything else, why each was
made, and what each one costs. Per-file detail lives in the doc comments at the
top of each script; this is the map.

---

## 1. Crew attachment: the decision the whole game rests on

**The requirement.** Four players occupy one vehicle. They walk around on it
while it drives, climb between positions, and fight from wherever they are
standing. They must stay attached when the vehicle accelerates, brakes, corners
hard, jumps, collides, or flips.

**The obvious implementation, and why it was rejected.** Make the crew
`CharacterBody3D`s and let them walk on the vehicle's collision mesh, or reparent
them under the vehicle so they inherit its transform.

Both fail, for different reasons:

- *Physics walking* asks a character controller to resolve motion against a
  surface that is doing 30 m/s and changing orientation. Character controllers
  assume a roughly static world. The failure modes are well known from games
  that have tried it: sinking through the roof on a bump, launching on landings,
  sliding off during hard cornering because friction is not a contract. There is
  no tuning that makes this reliable, only tuning that moves the failures around.

- *Reparenting* works offline and breaks in multiplayer. A node's path **is** its
  network identity. Reparenting renames it mid-session, and every RPC and
  synchroniser addressed to the old path is silently lost. Debugging that is
  miserable, because nothing errors — features simply stop working for the player
  who moved.

**What this project does instead.** A crew member's position is never stored in
world coordinates while they are on the vehicle. It is stored as one of:

| State | Stored as |
|---|---|
| `SEATED` | an attachment point name |
| `ON_SURFACE` | a surface name plus a 2D coordinate on that surface |
| `TRAVERSING` | a link name, a direction, and a progress value |

and the world transform is recomposed every frame:

```
world_transform = vehicle_crew_frame_transform * local_offset
```

Crew nodes stay at fixed paths under the level and are never reparented. Their
transform is *written* by `CrewController`; `move_and_slide()` is not called
while attached.

**What this buys.**

- **Attachment cannot fail.** There is no contact, no friction, no resolution
  step to lose. If the vehicle barrel-rolls at 40 m/s, the local offset is
  untouched. "Stay on the vehicle" stops being a physics problem the engine might
  lose and becomes an invariant of the representation.
- **Replication is nearly free.** Two of the three states carry no continuous
  data at all: a seated crew member is fully described by a seat name, and a
  traversing one by a link plus a direction, because the curve is deterministic
  and every peer can advance it locally. Only surface walking streams anything,
  and that is a `Vector2` and a `float` at 20 Hz.
- **Every peer agrees automatically.** Both factors of the product are
  replicated, so each peer multiplies the same two things. There is no separate
  "player position" that can drift out of sync with the vehicle.
- **Node paths never change**, so nothing about the network layer has to cope
  with identity changing mid-match.

**What it costs.**

- Crew do not collide with world geometry while attached. Driving under a low
  bridge will not sweep a roof gunner off. That is a mechanic to add
  deliberately — a swept test against world geometry that triggers an explicit
  knock-off state — not something to inherit by accident.
- Crew cannot be pushed by physics while attached. Being thrown clear by an
  explosion has to be an explicit state transition.
- Movement is bounded by authored surfaces, so crew cannot stand somewhere a
  designer did not intend. In practice this is a feature.

Files: `scripts/player/crew_attachment.gd` (the maths, deliberately node-free
and testable on its own), `scripts/player/crew_controller.gd` (the state
machine), `scripts/vehicle/vehicle_surface.gd`, `vehicle_attachment_point.gd`,
`vehicle_traversal_link.gd`, `vehicle_rig.gd`.

---

## 2. Split authority: the driver owns the chassis, the server owns everything else

Most multiplayer advice says "make the server authoritative over everything."
This project deliberately does not, and the split is worth stating precisely.

**The server (host, peer 1) is authoritative over** component health, damage
application, deaths, enemy AI, seat occupancy, role assignment and match state.
Clients request; they never apply these locally.

**The driver's client is authoritative over the vehicle's rigid-body transform.**
The vehicle simulates on whichever peer is driving. Every other peer freezes its
rigid body (`freeze_mode = FREEZE_MODE_KINEMATIC`) and follows interpolated
snapshots.

**Why the vehicle is not server-authoritative.** Driving is the most
latency-sensitive input in the game. A server-authoritative vehicle gives the
driver a full round trip of lag on every steering correction; at 60–100 ms,
threading a vehicle between obstacles feels broken. Fixing that properly means
client prediction with rollback and reconciliation of a rigid body — large,
subtle, and famously fragile.

What authority buys is protection from a malicious driver. But this is
four-player co-op PvE: the only people a cheating driver can hurt are the three
friends who invited them. That is a bad trade, so the responsive option wins and
authority stays on the things that would actually ruin a session.

**This stays reversible.** All driving input flows through a single
`VehicleInputState`. Moving to a predicted server-authoritative model later means
shipping that struct to the server each tick and adding reconciliation — nothing
inside `VehicleController` restructures.

**Crew movement follows the same reasoning:** a crew member's own client owns
their movement, because the surface clamp bounds it. The worst a modified client
can do is stand somewhere on the vehicle it was already allowed to stand. Seats
are the exception, because they are exclusive — two players pressing interact on
the same seat in the same frame must not both get it — so a traversal *toward a
seat* asks the server first and only begins once the claim is confirmed. A
traversal toward a surface, which nothing else can hold, starts immediately.

### Two Godot-specific traps this creates

Both are easy to hit and produce silent, confusing failures. Both are checked by
`tools/validate_project.py`.

1. **`set_multiplayer_authority()` is recursive by default.** Using it to give
   the driver the chassis would drag the crew rig, the seats and the damage
   model along with it — handing a client authority over exactly what the split
   exists to protect. `VehicleController` therefore tracks an explicit
   `physics_authority_peer` field instead of using node authority at all.

2. **`@rpc("authority")` means "the node's authority", not "the server".** On any
   node a client owns — a crew member, their weapon, their health — the server
   *is not* the authority, so a server-sent `@rpc("authority")` method is
   rejected on arrival. Those RPCs are declared `@rpc("any_peer")` with an
   explicit `NetGuard.is_from_server()` check, which is what "only the server"
   actually looks like on a node a client owns.

A third trap, same family: **`rpc_id(1, …)` from the host targets the host**, and
Godot only executes a self-targeted RPC if the method is `call_local`. A
`call_remote` method is silently dropped, so the feature works for every client
and never for the host.

Files: `scripts/networking/network_manager.gd` (the full authority note lives at
the top), `net_guard.gd`, `snapshot_buffer.gd`, `net_config.gd`.

---

## 3. Deterministic spawning instead of MultiplayerSpawner

`MultiplayerSpawner` exists for objects that appear at unpredictable times. The
crew is the opposite: the roster is fixed and identical on every peer before the
level loads.

The match-start handshake makes that guarantee explicit:

```
host: request_start_match()
   -> _rpc_begin_match      (all peers)   state = LOADING
   -> every peer loads the level scene
   -> level _ready() calls notify_level_ready()
   -> _rpc_level_ready      (clients -> server)
   -> server waits for every connected peer
   -> _rpc_match_playing    (all peers)   state = PLAYING
   -> every peer spawns the identical crew from the identical roster
```

The two phases matter: spawning crew before a client has instantiated the level
would place nodes into a tree that does not exist yet on that peer.

Crew nodes are named `Crew_<peer_id>` and enemies `Enemy_<index>`, so node paths
— which are what RPCs are addressed by — match everywhere, with no spawn packets
and no ordering races. Enemy spawn *positions* are chosen by the server and sent
explicitly rather than derived from a shared RNG seed, because synchronised RNG
survives exactly until one peer consumes a random number the others do not.

This trade flips the moment mid-match joining is supported, which is when
`MultiplayerSpawner` starts earning its keep. Phase 1 rejects mid-match joins.

Files: `scripts/systems/crew_spawner.gd`, `enemy_spawner.gd`,
`scripts/networking/network_manager.gd`.

---

## 4. How the scenes connect

```
main.tscn                    Main + Screen (the slot SceneRouter swaps)
  └─ ui/main_menu.tscn       host / join
  └─ ui/lobby.tscn           roster, roles, ready check
  └─ maps/test_arena.tscn    the level
       ├─ Vehicle            = vehicles/tactical_suv.tscn
       │    └─ CrewRig       VehicleRig: scans and owns points/surfaces/links
       ├─ CrewSpawner        instantiates player/player_character.tscn per peer
       ├─ EnemySpawner       instantiates enemies/enemy_grunt.tscn
       └─ HUD                = ui/hud.tscn
```

The ENet peer lives in the `NetworkManager` autoload, *not* under the screen
slot, so swapping from lobby to level does not tear down the session.
`SceneRouter` swaps screens inside a container node rather than using
`change_scene_to_file()`, which would replace the whole tree root.

**Two ordering facts the code depends on**, both of which are load-bearing:

- Godot readies **children before parents**. `VehicleRig._ready()` therefore
  finishes scanning the vehicle before `VehicleController._ready()` connects to
  it, and before `TestArena._ready()` reports the level as ready.
- In `test_arena.tscn` the `Vehicle` node is declared **before** `CrewSpawner`,
  so the whole vehicle subtree is ready when the spawner resolves
  `NodePath("../Vehicle")`. Reordering those nodes would break spawning.

---

## 5. Data flow

**Gameplay talks to gameplay directly**, through references and RPCs, where
authority is explicit. **Presentation listens on `GameEvents`**, a one-way signal
bus: gameplay emits, the HUD and audio listen. Nothing that changes gameplay
state travels through the bus, which is what stops it becoming a global mutable
mess.

Damage is delivered through one duck-typed method:

```gdscript
server_take_damage(amount, damage_type, source_peer_id, hit_point) -> float
```

`DamageRouter` walks up from whatever a raycast hit until it finds the first node
implementing it. A crew member, an enemy, the vehicle — anything that implements
that method can be hurt by every weapon in the game without weapons knowing what
they hit.

---

## 6. Known limitations

Ordered roughly by how likely they are to bite.

- **The project has never been run.** No Godot install was available while it was
  written. Structure is validated; behaviour is not.
- **No mid-match joining.** A client that connects after the match starts is
  rejected with a readable message. This is what makes deterministic spawning
  safe, and undoing it means adopting `MultiplayerSpawner` for crew.
- **No repair interaction yet.** Repair points are authored on the vehicle and
  already double as component hit locations, and the damage model supports
  `apply_repair` with a cap ratio for field repairs. The Engineer's actual
  interaction is Phase 4.
- **Projectile weapons are unimplemented.** `WeaponFireMode.PROJECTILE` exists in
  the data model; a weapon set to it logs an error and refuses to fire rather
  than silently behaving like a rifle.
- **Weapon spread is rolled client-side** and the server trusts the direction,
  because it has no replicated aim vector to check against. Origin distance and
  rate of fire *are* enforced. Closing this fully is Phase 6.
- **Snapshot interpolation uses arrival time, not sender timestamps**, which
  avoids needing clock synchronisation. A change in one-way latency shows up as a
  brief speed-up or slow-down of remote objects rather than a position
  correction. Invisible in co-op; a competitive build would want real clock sync.
- **Crew do not collide with the world while attached** (see §1).
- **The vehicle does not collide with crew**, so a dismounted player standing in
  front of it will not be run over.
- **Death is terminal for the match.** No downed state, no revive, no respawn.
  `HealthComponent` already models a downed threshold; the flow is Phase 7.
- **Enemies steer straight at their target** with no pathfinding or cover.
- **Placeholder everything** for art, animation and audio. Traversal is a
  Bezier arc rather than an authored climb; `VehicleTraversalLink` already
  carries an `animation_name` for when real animations exist.

---

## 7. Roadmap

Phase 1 is done. Nothing below it has been started, deliberately — the milestone
that had to be proven first was *four players on one moving vehicle, fighting
from it and moving around it without detaching*.

| Phase | Scope | State |
|---|---|---|
| 1 | Prototype: map, vehicle, 4 players, movement, attachment, traversal, basic weapons, basic enemy | **done** |
| 2 | Traversal polish: authored animations, more link kinds, enter/exit framing | groundwork in place |
| 3 | Damage: full component model, destruction, visual damage states | model built, effects partial |
| 4 | Repair: Engineer gameplay, repair interactions, interruption | points authored, no interaction |
| 5 | Combat: projectiles, vehicle-mounted weapons, more enemy types | not started |
| 6 | Multiplayer hardening: aim validation, mid-match join, reconnection | not started |
| 7 | Progression: upgrades with tradeoffs, unlocks, missions | not started |
| 8 | Production: vehicles, maps, AI, audio, VFX, UI, optimisation | not started |

---

## 8. Adding things

**A vehicle class.** Author a `VehicleDefinition` resource and a scene whose root
extends `VehicleController`. Place `VehicleSurface` nodes for anything walkable,
`VehicleAttachmentPoint` nodes for seats, surface anchors, repair hatches, entries
and exits, and `VehicleTraversalLink` nodes to connect them. No controller code
changes. Leave the definition's `scene` field empty when the vehicle scene
references the definition, or the two resources form a load cycle.

**A weapon.** Author a `WeaponDefinition` resource and point a `Weapon` node at
it. `Weapon.gd` holds no per-weapon constants.

**An enemy type.** Extend `EnemyBase` and override its targeting. The interesting
axis is *what it aims at* — crew on exposed surfaces, a specific vehicle
component, the driver — because that is what makes crew positioning a decision.

After any of these, run `python3 tools/validate_project.py .` — hand-authored
scenes are exactly where a mistyped `NodePath` hides.
