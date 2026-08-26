class_name EnemySpawner
extends Node3D

## Places enemies for a match.
##
## The server picks the positions and sends them explicitly, rather than every
## peer seeding a shared RNG. Synchronised RNG is a classic source of
## hard-to-reproduce desync: it survives exactly until one peer consumes a random
## number the others do not, and then the worlds quietly diverge. Sending the
## positions costs a few bytes once per match and cannot drift.
##
## Spawn positions come from Marker3D children when there are any, so a level
## designer can place ambushes deliberately; otherwise enemies are scattered on a
## ring for a bare test arena.

@export var enemy_scene: PackedScene = null
@export_range(0, 64, 1) var spawn_count: int = 8
## Used only when no Marker3D children are present.
@export_range(5.0, 200.0, 1.0) var fallback_radius: float = 45.0

## index -> EnemyBase
var _enemies: Dictionary = {}
var _next_index: int = 0


func _ready() -> void:
	if enemy_scene == null:
		GameLog.error("spawn", "EnemySpawner has no enemy_scene assigned")
	GameEvents.match_state_changed.connect(_on_match_state_changed)


func _on_match_state_changed(state: int) -> void:
	if state == GameEnums.MatchState.PLAYING:
		if multiplayer.is_server():
			_server_spawn_wave()
	elif state == GameEnums.MatchState.LOBBY or state == GameEnums.MatchState.IDLE:
		_despawn_all()


func _server_spawn_wave() -> void:
	if enemy_scene == null or not _enemies.is_empty():
		return

	for position_value: Vector3 in _spawn_positions():
		_rpc_spawn_enemy.rpc(_next_index, position_value)
		_next_index += 1


func _spawn_positions() -> Array[Vector3]:
	var positions: Array[Vector3] = []

	var markers: Array[Marker3D] = []
	for child in get_children():
		if child is Marker3D:
			markers.append(child)

	if not markers.is_empty():
		for index in spawn_count:
			positions.append(markers[index % markers.size()].global_position)
		return positions

	# No authored spawn points: scatter on a ring around this node.
	for index in spawn_count:
		var angle: float = TAU * float(index) / float(maxi(spawn_count, 1))
		positions.append(global_position
			+ Vector3(cos(angle), 0.0, sin(angle)) * fallback_radius)
	return positions


@rpc("authority", "call_local", "reliable")
func _rpc_spawn_enemy(index: int, position_value: Vector3) -> void:
	if enemy_scene == null or _enemies.has(index):
		return
	var enemy: EnemyBase = enemy_scene.instantiate() as EnemyBase
	if enemy == null:
		GameLog.error("spawn", "enemy_scene's root is not an EnemyBase")
		return

	# Deterministic name so RPCs addressed to this enemy resolve on every peer.
	enemy.name = "Enemy_%d" % index
	add_child(enemy)
	enemy.global_position = position_value
	_enemies[index] = enemy


func _despawn_all() -> void:
	for enemy: EnemyBase in _enemies.values():
		if is_instance_valid(enemy):
			enemy.queue_free()
	_enemies.clear()
	_next_index = 0


func living_enemy_count() -> int:
	var count: int = 0
	for enemy: EnemyBase in _enemies.values():
		if is_instance_valid(enemy) and not enemy.health.is_dead:
			count += 1
	return count
