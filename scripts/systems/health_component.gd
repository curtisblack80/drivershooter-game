class_name HealthComponent
extends Node

## Server-authoritative health for a single entity.
##
## Attach as a child of anything that can be killed: a crew member, an enemy, a
## destructible obstacle. Damage is only ever applied on the server, and the
## result is replicated; clients call nothing on this except to read it.
##
## The node's multiplayer authority is irrelevant here and deliberately unused —
## health is always the server's, even on a crew member whose *movement* their
## own client owns. Splitting it that way is the whole point of the authority
## model: responsiveness where it is felt, authority where it is exploitable.

signal health_changed(current: float, maximum: float)
signal damaged(amount: float, source_peer_id: int)
signal died(source_peer_id: int)
signal revived()

@export var max_health: float = 100.0

## Damage taken while downed rather than dead. Below zero health the entity is
## DOWNED and revivable; a further `bleed_out_damage` finishes them. Set to 0 to
## make death immediate.
@export var downed_threshold: float = 0.0

var current_health: float = 0.0
var is_dead: bool = false

## Who landed the killing blow, for scoring and kill feed.
var last_attacker: int = 0


func _ready() -> void:
	current_health = max_health


func ratio() -> float:
	if max_health <= 0.0:
		return 0.0
	return clampf(current_health / max_health, 0.0, 1.0)


func is_alive() -> bool:
	return not is_dead


## Server-only. Apply damage; returns the amount actually taken.
func server_apply_damage(amount: float, source_peer_id: int = 0) -> float:
	if not multiplayer.is_server() or is_dead or amount <= 0.0:
		return 0.0

	var before: float = current_health
	current_health = maxf(current_health - amount, downed_threshold - 1.0)
	var taken: float = before - current_health
	last_attacker = source_peer_id

	var now_dead: bool = current_health <= downed_threshold
	_rpc_sync_health.rpc(current_health, now_dead, source_peer_id)
	_apply_local(current_health, now_dead, source_peer_id, taken)
	return taken


## Server-only. Restore health.
func server_heal(amount: float) -> float:
	if not multiplayer.is_server() or amount <= 0.0:
		return 0.0
	var before: float = current_health
	current_health = minf(current_health + amount, max_health)
	var restored: float = current_health - before
	if restored <= 0.0:
		return 0.0
	var still_dead: bool = is_dead and current_health <= downed_threshold
	_rpc_sync_health.rpc(current_health, still_dead, 0)
	_apply_local(current_health, still_dead, 0, 0.0)
	return restored


## Server-only. Full reset, for respawns.
func server_reset() -> void:
	if not multiplayer.is_server():
		return
	current_health = max_health
	is_dead = false
	last_attacker = 0
	_rpc_sync_health.rpc(current_health, false, 0)
	_apply_local(current_health, false, 0, 0.0)


## Sent by the server only.
##
## Annotated "any_peer" with an explicit server check rather than "authority",
## because a HealthComponent's node authority is inherited from its parent — and
## on a crew member that parent's authority is the *player's own client*, not the
## server. An "authority" annotation here would mean the server could not deliver
## health updates for players at all, while any client could. The check below is
## what "only the server" actually looks like on a node a client owns.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_sync_health(value: float, dead: bool, source_peer_id: int) -> void:
	if not NetGuard.is_from_server(self):
		return
	var delta: float = maxf(current_health - value, 0.0)
	_apply_local(value, dead, source_peer_id, delta)


func _apply_local(value: float, dead: bool, source_peer_id: int, taken: float) -> void:
	var was_dead: bool = is_dead
	current_health = value
	is_dead = dead

	health_changed.emit(current_health, max_health)
	if taken > 0.0:
		damaged.emit(taken, source_peer_id)

	if dead and not was_dead:
		died.emit(source_peer_id)
	elif was_dead and not dead:
		revived.emit()
