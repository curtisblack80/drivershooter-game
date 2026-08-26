class_name NetConfig
extends RefCounted

## Network-wide constants.
##
## Anything that has to match between a host and a client belongs here, so that
## a mismatch is a one-line diff rather than a bug hunt.

## Default ENet port. Chosen outside the common ephemeral range so a client that
## forgets to port-forward gets a clean refusal rather than hitting something else.
const DEFAULT_PORT: int = 27015

## Hard cap on crew size. The vehicle layouts are authored around four.
const MAX_PLAYERS: int = 4

## Bumped whenever the shape of any RPC payload or enum changes. The server
## rejects a client whose protocol version differs, with a readable message.
## This is the cheapest possible defence against the "it desyncs weirdly and
## nobody knows why" class of bug that mixed builds cause.
const PROTOCOL_VERSION: int = 1

## How often an authority peer broadcasts continuous state (vehicle transform,
## crew offsets). Kept well below the 60 Hz physics rate: crew offsets are small
## and slow, and the vehicle is smoothed by interpolation on the receiving side.
const SNAPSHOT_HZ: float = 20.0
const SNAPSHOT_INTERVAL: float = 1.0 / SNAPSHOT_HZ

## Receivers render remote state this far in the past. Two and a bit snapshot
## intervals, which absorbs one dropped packet and ordinary jitter without ever
## running out of buffered samples to interpolate between.
const INTERPOLATION_DELAY: float = 0.12

## If the buffer runs dry (a real network stall), extrapolate forward from the
## last known velocity for at most this long before freezing in place.
## Extrapolating further looks worse than stopping: a vehicle that keeps
## ploughing forward through a wall is more jarring than one that pauses.
const MAX_EXTRAPOLATION: float = 0.15

## Samples retained per synchronised object. At 20 Hz this is ~1.6s of history,
## far more than INTERPOLATION_DELAY needs, but cheap and useful when debugging.
const SNAPSHOT_BUFFER_SIZE: int = 32

## A client is dropped if it has not been heard from in this long.
const PEER_TIMEOUT: float = 15.0

## Maximum accepted length of a player-chosen display name, in characters.
## Names are also stripped of control characters and BBCode brackets before
## being shown; see PlayerInfo.clean_name().
const MAX_NAME_LENGTH: int = 20


## Physics collision layers. These mirror the [layer_names] block in
## project.godot; keeping them as named bits stops raycast masks from turning
## into unreadable magic numbers scattered across the combat code.
class Layer:
	const WORLD: int = 1 << 0        # 1
	const VEHICLE: int = 1 << 1      # 2
	const PLAYER: int = 1 << 2       # 4
	const ENEMY: int = 1 << 3        # 8
	const PROJECTILE: int = 1 << 4   # 16
	const INTERACTION: int = 1 << 5  # 32
	const HITBOX: int = 1 << 6       # 64

	## What a bullet is allowed to hit.
	const SHOOTABLE: int = WORLD | VEHICLE | PLAYER | ENEMY | HITBOX

	## What blocks line of sight for AI.
	const SIGHT_BLOCKING: int = WORLD | VEHICLE
