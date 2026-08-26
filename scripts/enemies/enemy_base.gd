class_name EnemyBase
extends CharacterBody3D

## A ground enemy built around the vehicle, not around a corridor shooter.
##
## The one behaviour that matters for Phase 1: this enemy prefers to shoot crew
## members who are *exposed on the outside of the vehicle*, and only falls back
## to shooting the vehicle itself when nobody is. That single rule is what makes
## the whole traversal system a real decision — climbing onto the roof gets you a
## firing arc and gets you shot at, and staying in the cabin is safe and useless.
## Enemy design that ignores where crew are standing would make the vehicle a
## skin over an ordinary shooter.
##
## Authority: the server runs the AI and nothing else does. Clients receive
## interpolated transforms and play effects. An enemy on a client never decides
## to move, never decides to shoot, and never applies damage.
##
## Navigation: Phase 1 steers directly toward the target across a flat arena.
## Real pathfinding (NavigationAgent3D, cover, flanking) is Phase 8; the point
## here is to prove crew and vehicle can be threatened, not to ship an AI.

enum State {
	IDLE = 0,
	PURSUE = 1,
	ATTACK = 2,
}

@export_group("Stats")
@export var max_health: float = 60.0
@export_range(0.5, 15.0, 0.1) var move_speed: float = 4.2
@export_range(5.0, 120.0, 1.0) var detection_range: float = 70.0
@export_range(3.0, 80.0, 1.0) var attack_range: float = 26.0

@export_group("Weapon")
@export_range(0.5, 60.0, 0.5) var damage_per_shot: float = 7.0
@export_range(0.1, 6.0, 0.05) var fire_interval: float = 1.15
## Cone half-angle the enemy shoots within, in degrees. Higher misses more.
@export_range(0.0, 20.0, 0.1) var spread_degrees: float = 3.2
@export var tracer_color: Color = Color(1.0, 0.35, 0.25, 1.0)

@export_group("Targeting")
## How much closer an exposed crew member has to be than the vehicle before the
## enemy switches to shooting them. Above 1.0 the enemy actively prefers crew
## even at longer range, which is what makes riding on the roof dangerous.
@export_range(0.5, 4.0, 0.1) var crew_target_bias: float = 1.8

var state: State = State.IDLE

var _gravity: float = 9.8
var _fire_timer: float = 0.0
var _target: Node3D = null
var _retarget_timer: float = 0.0

var _buffer: SnapshotBuffer = SnapshotBuffer.new()
var _snapshot_accumulator: float = 0.0
var _snapshot_sequence: int = 0

@onready var health: HealthComponent = $Health
@onready var _muzzle: Node3D = $Muzzle

## How often the enemy re-evaluates who to shoot. Every frame would be wasted
## work and would also make it flip between targets distractingly.
const RETARGET_INTERVAL: float = 0.4


func _ready() -> void:
	add_to_group(&"enemies")
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	health.max_health = max_health
	health.current_health = max_health
	health.died.connect(_on_died)


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_server_think(delta)
		_broadcast_snapshot(delta)
	else:
		_follow_remote_state()


# ---------------------------------------------------------------------------
# Server AI
# ---------------------------------------------------------------------------

func _server_think(delta: float) -> void:
	if health.is_dead:
		return

	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = RETARGET_INTERVAL
		_target = _choose_target()

	if _target == null or not is_instance_valid(_target):
		state = State.IDLE
		_apply_movement(Vector3.ZERO, delta)
		return

	var to_target: Vector3 = _target.global_position - global_position
	var distance: float = to_target.length()

	if distance > detection_range:
		state = State.IDLE
		_apply_movement(Vector3.ZERO, delta)
		return

	if distance > attack_range:
		state = State.PURSUE
		var direction: Vector3 = Vector3(to_target.x, 0.0, to_target.z).normalized()
		_apply_movement(direction, delta)
	else:
		state = State.ATTACK
		_apply_movement(Vector3.ZERO, delta)
		_face(to_target)
		_fire_timer -= delta
		if _fire_timer <= 0.0:
			_fire_timer = fire_interval
			_server_fire_at(_target)


## Pick between the vehicle and any crew member riding on the outside of it.
##
## Crew inside the cabin are not considered: they are behind the vehicle's
## collision hull, so shooting at them would just be shooting the vehicle. Crew
## on an exterior surface are fair game and are weighted as closer than they are,
## so a roof gunner draws fire away from the chassis.
func _choose_target() -> Node3D:
	var best: Node3D = null
	var best_score: float = INF

	for vehicle: Node in get_tree().get_nodes_in_group(&"vehicles"):
		var vehicle_node: Node3D = vehicle as Node3D
		if vehicle_node == null:
			continue
		var score: float = global_position.distance_to(vehicle_node.global_position)
		if score < best_score:
			best_score = score
			best = vehicle_node

	for crew: Node in get_tree().get_nodes_in_group(&"crew"):
		var player: PlayerCharacter = crew as PlayerCharacter
		if player == null or player.health.is_dead:
			continue
		if not _is_exposed(player):
			continue
		var score: float = global_position.distance_to(player.global_position) / crew_target_bias
		if score < best_score:
			best_score = score
			best = player

	return best


## True when a crew member is somewhere an enemy can actually shoot them.
func _is_exposed(player: PlayerCharacter) -> bool:
	var crew_state: int = player.crew.state()
	if crew_state == GameEnums.CrewState.DISMOUNTED:
		return true
	if crew_state == GameEnums.CrewState.TRAVERSING:
		return true
	if crew_state != GameEnums.CrewState.ON_SURFACE:
		return false
	var surface: VehicleSurface = player.crew.attachment.current_surface()
	return surface != null and not surface.is_interior


func _apply_movement(direction: Vector3, delta: float) -> void:
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	if is_on_floor():
		velocity.y = -0.1
	else:
		velocity.y -= _gravity * delta
	move_and_slide()
	if not direction.is_zero_approx():
		_face(direction)


func _face(direction: Vector3) -> void:
	var flat: Vector3 = Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() < 0.0001:
		return
	rotation.y = MathUtil.yaw_from_direction(flat.normalized())


func _server_fire_at(target: Node3D) -> void:
	var origin: Vector3 = _muzzle.global_position if _muzzle != null else global_position
	# Aim at centre mass. Both a character's origin and a vehicle's origin sit
	# near the ground, so aiming at them directly puts every shot into the dirt.
	var aim_point: Vector3 = target.global_position
	if target is PlayerCharacter:
		aim_point += Vector3.UP * 1.0
	elif target is VehicleController:
		aim_point += Vector3.UP * 0.9

	var direction: Vector3 = (aim_point - origin)
	if direction.length_squared() < 0.0001:
		return
	direction = _apply_spread(direction.normalized())

	var world: World3D = get_world_3d()
	if world == null:
		return

	var far_point: Vector3 = origin + direction * detection_range
	var exclusions: Array[RID] = [get_rid()]
	var query := PhysicsRayQueryParameters3D.create(origin, far_point,
		NetConfig.Layer.SHOOTABLE, exclusions)
	query.collide_with_areas = false
	var hit: Dictionary = world.direct_space_state.intersect_ray(query)

	var end_point: Vector3 = far_point
	if not hit.is_empty():
		end_point = hit["position"]
		var collider: Object = hit.get("collider")
		# peer id 0 marks the attacker as "the world", not a player.
		DamageRouter.apply(collider, end_point, damage_per_shot, GameEnums.DamageType.BALLISTIC, 0)

	_rpc_play_shot.rpc(origin, end_point)
	_play_shot_effect(origin, end_point)


func _apply_spread(direction: Vector3) -> Vector3:
	var cone: float = deg_to_rad(spread_degrees)
	if cone <= 0.0001:
		return direction
	var angle: float = randf() * TAU
	var radius: float = sqrt(randf()) * cone
	var reference: Vector3 = Vector3.UP
	if absf(direction.dot(reference)) > 0.95:
		reference = Vector3.RIGHT
	var right: Vector3 = direction.cross(reference).normalized()
	var up: Vector3 = right.cross(direction).normalized()
	var offset: float = tan(radius)
	return (direction + right * (cos(angle) * offset) + up * (sin(angle) * offset)).normalized()


# ---------------------------------------------------------------------------
# Damage
# ---------------------------------------------------------------------------

## Damage interface; see DamageRouter. Server-only.
func server_take_damage(amount: float, _damage_type: int, source_peer_id: int,
		_hit_point: Vector3) -> float:
	if not multiplayer.is_server():
		return 0.0
	return health.server_apply_damage(amount, source_peer_id)


func _on_died(_source_peer_id: int) -> void:
	state = State.IDLE
	velocity = Vector3.ZERO
	# Stop being shootable so bullets pass through the body instead of being
	# absorbed by a corpse. _server_think() already returns early once dead, so
	# physics processing is left alone — clients still need it to keep following
	# the final replicated pose.
	collision_layer = 0
	# Phase 1 leaves the body in place: no ragdoll, no despawn, no loot. That is
	# Phase 8 presentation work.


# ---------------------------------------------------------------------------
# Replication
# ---------------------------------------------------------------------------

func _broadcast_snapshot(delta: float) -> void:
	if not NetworkManager.is_session_active():
		return
	_snapshot_accumulator += delta
	if _snapshot_accumulator < NetConfig.SNAPSHOT_INTERVAL:
		return
	_snapshot_accumulator -= NetConfig.SNAPSHOT_INTERVAL
	if multiplayer.get_peers().is_empty():
		return
	_snapshot_sequence += 1
	_rpc_snapshot.rpc(_snapshot_sequence, global_position,
		global_transform.basis.get_rotation_quaternion(), velocity)


@rpc("authority", "call_remote", "unreliable")
func _rpc_snapshot(sequence: int, position_value: Vector3, rotation_value: Quaternion,
		velocity_value: Vector3) -> void:
	_buffer.push_sample(sequence, float(Time.get_ticks_msec()) / 1000.0,
		position_value, rotation_value, velocity_value)


func _follow_remote_state() -> void:
	var render_time: float = float(Time.get_ticks_msec()) / 1000.0 - NetConfig.INTERPOLATION_DELAY
	if not _buffer.sample_at(render_time):
		return
	global_transform = Transform3D(Basis(_buffer.out_rotation), _buffer.out_position)


@rpc("authority", "call_remote", "reliable")
func _rpc_play_shot(origin: Vector3, end_point: Vector3) -> void:
	_play_shot_effect(origin, end_point)


func _play_shot_effect(origin: Vector3, end_point: Vector3) -> void:
	TracerEffect.spawn(self, origin, end_point, tracer_color, 0.05)
	GameEvents.shot_fired.emit(0, origin, end_point, true)
