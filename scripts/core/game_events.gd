extends Node

## Autoload: GameEvents
##
## A narrow, one-way signal bus: gameplay systems emit, presentation layers
## (HUD, audio, VFX) listen.
##
## The rule that keeps this from turning into a global mutable mess: **nothing
## that changes gameplay state may travel through here.** Gameplay talks to
## gameplay through direct references and RPCs, where authority is explicit. This
## bus exists so the HUD does not need a node path to the vehicle, and so the
## audio system does not need to know which script fired a weapon.
##
## Every signal here describes something that has *already happened* on this
## peer. Listeners must not assume they are on the server.


# --- Session / lobby -------------------------------------------------------

## Emitted when the mirrored match state changes. `state` is GameEnums.MatchState.
signal match_state_changed(state: int)

## Emitted whenever the player roster changes: someone joined, left, renamed,
## changed role, or toggled ready. Listeners should re-read NetworkManager.players.
signal player_roster_changed()

## Emitted on connection failure, unexpected disconnect, or version mismatch.
## `message` is already human-readable and safe to show in the UI.
signal network_error(message: String)

## Emitted on this peer once it has successfully joined a session.
signal session_started(is_server: bool)

## Emitted when the session ends for any reason, including a clean quit.
signal session_ended()


# --- Local player ----------------------------------------------------------

## Emitted once the locally controlled player node exists and is in the tree.
signal local_player_spawned(player: Node3D)

## Emitted just before the local player node leaves the tree.
signal local_player_despawned()

## The local crew member's state machine changed. `state` is GameEnums.CrewState.
signal local_crew_state_changed(state: int)

## The contextual interaction prompt changed. Empty string means "hide it".
signal interaction_prompt_changed(text: String)


# --- Vehicle ---------------------------------------------------------------

## A vehicle component's health changed. `ratio` is 0.0-1.0.
signal vehicle_component_health_changed(component: int, ratio: float)

## The crew member driving the vehicle changed. `peer_id` is 0 when nobody drives.
signal driver_changed(peer_id: int)

## A seat's occupancy changed. `peer_id` is 0 when the seat became free.
signal seat_occupancy_changed(point_name: StringName, peer_id: int)

## The vehicle was destroyed.
signal vehicle_destroyed()


# --- Combat ----------------------------------------------------------------

## A shot was resolved somewhere in the world. Presentation only: tracers,
## muzzle flash, impact decals. Never use this to apply damage.
signal shot_fired(shooter_peer_id: int, origin: Vector3, hit_point: Vector3, did_hit: bool)

## The local player dealt confirmed damage. Drives hit markers.
signal local_hit_confirmed(amount: float, was_lethal: bool)
