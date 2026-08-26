class_name VehicleController
extends VehicleBody3D

## The vehicle chassis: driving, stability, damage effects, and network sync.
##
## ============================================================================
## PHYSICS AUTHORITY
## ============================================================================
##
## The vehicle simulates on exactly one peer at a time — whichever peer is
## driving it — and every other peer freezes its rigid body and follows
## interpolated snapshots. See the long note in NetworkManager for why driving is
## client-authoritative while damage and health are not.
##
## Authority is tracked here as an explicit `physics_authority_peer` field rather
## than through `Node.set_multiplayer_authority()`. That is deliberate:
## `set_multiplayer_authority()` defaults to `recursive = true`, so using it here
## would silently drag the VehicleRig, the seats and the damage state over to the
## driver's client along with the chassis — handing a client authority over seat
## claims and health, which is exactly what the split authority model exists to
## prevent. An explicit field cannot make that mistake, and it reads unambiguously
## at the call site.
##
## ============================================================================
## HANDLING PHILOSOPHY
## ============================================================================
##
## This is an arcade model, not a simulator. In priority order: fun, predictable,
## network-friendly, stable enough that a crew member on the roof stays there,
## readable in combat. Concretely that means speed-scaled steering authority
## (so the vehicle cannot be flicked into a barrel roll at speed), real downforce
## (which does more for crew stability than any amount of attachment code), and
## self-righting (because a stranded upside-down vehicle is not interesting
## failure, it is just four players waiting).

## Emitted when this vehicle's driving peer changes. Mirrors VehicleRig.
signal physics_authority_changed(peer_id: int)

@export_group("Configuration")
## Stats, durability and crew capacity. Required.
@export var definition: VehicleDefinition = null

## The crew frame. Every crew member's position is an offset from this node.
@export_node_path("Node3D") var rig_path: NodePath = ^"CrewRig"

@export_group("Wheels")
## Mapped so that wheel damage can target a specific corner. Leave a path empty
## if the vehicle does not have that wheel.
@export_node_path("VehicleWheel3D") var wheel_front_left_path: NodePath = ^"Wheels/FrontLeft"
@export_node_path("VehicleWheel3D") var wheel_front_right_path: NodePath = ^"Wheels/FrontRight"
@export_node_path("VehicleWheel3D") var wheel_rear_left_path: NodePath = ^"Wheels/RearLeft"
@export_node_path("VehicleWheel3D") var wheel_rear_right_path: NodePath = ^"Wheels/RearRight"

@export_group("Local Control")
## Cleared while a menu is open, so driving input does not leak through the UI.
@export var local_input_enabled: bool = true

## Per-component health. Server-authoritative; clients receive snapshots.
var damage: VehicleDamageModel = VehicleDamageModel.new()

## The peer currently simulating this chassis. 1 (the server) when nobody drives.
var physics_authority_peer: int = 1

var _rig: VehicleRig = null
var _input: VehicleInputState = VehicleInputState.new()

var _buffer: SnapshotBuffer = SnapshotBuffer.new()
var _last_followed_transform: Transform3D = Transform3D.IDENTITY
var _has_followed_state: bool = false

var _snapshot_accumulator: float = 0.0
var _snapshot_sequence: int = 0
var _health_accumulator: float = 0.0
var _health_dirty: bool = false

## GameEnums.VehicleComponent -> VehicleWheel3D
var _wheels: Dictionary = {}
## GameEnums.VehicleComponent -> the wheel's authored friction, before damage.
var _wheel_base_friction: Dictionary = {}
## GameEnums.VehicleComponent -> position in the crew frame, taken from the
## vehicle's repair points. Used to decide which component a hit landed on.
var _component_positions: Dictionary = {}

var _inverted_time: float = 0.0

## Acceleration measured between physics frames, in world space. Derived rather
## than read from the physics server because RigidBody3D exposes no acceleration,
## and the crew stability system needs it every frame.
var _measured_acceleration: Vector3 = Vector3.ZERO
var _previous_velocity: Vector3 = Vector3.ZERO

const _REAR_WHEELS: Array = [
	GameEnums.VehicleComponent.WHEEL_REAR_LEFT,
	GameEnums.VehicleComponent.WHEEL_REAR_RIGHT,
]


func _ready() -> void:
	add_to_group(&"vehicles")

	# Children are ready before their parent in Godot, so the rig has already
	# scanned the scene by the time this runs and its registries are populated.
	_rig = get_node_or_null(rig_path) as VehicleRig
	if _rig == null:
		GameLog.error("vehicle", "VehicleController has no VehicleRig at '%s'" % rig_path)
	else:
		_rig.driver_changed.connect(_on_driver_changed)

	if definition == null:
		GameLog.error("vehicle", "VehicleController '%s' has no VehicleDefinition; using engine defaults" % name)
	else:
		mass = definition.mass
		for problem: String in definition.validate():
			GameLog.warn("vehicle", "%s: %s" % [definition.vehicle_id, problem])

	damage.configure(definition)
	damage.component_changed.connect(_on_component_changed)
	damage.vehicle_destroyed.connect(_on_vehicle_destroyed)

	_collect_wheels()
	_collect_component_positions()

	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_apply_freeze_state()


# ---------------------------------------------------------------------------
# Public accessors
# ---------------------------------------------------------------------------

func rig() -> VehicleRig:
	return _rig


## The transform crew offsets are composed against.
func crew_frame_transform() -> Transform3D:
	if _rig == null:
		return global_transform
	return _rig.global_transform


func speed_ms() -> float:
	return linear_velocity.length()


func speed_kph() -> float:
	return linear_velocity.length() * 3.6


## Signed speed along the vehicle's nose. Negative while reversing.
func forward_speed_ms() -> float:
	return (-global_transform.basis.z).dot(linear_velocity)


func is_operable() -> bool:
	return not damage.is_destroyed()


func has_physics_authority() -> bool:
	return physics_authority_peer == multiplayer.get_unique_id()


## Acceleration felt by the crew, in the vehicle's own axes. Drives the
## stability penalty for crew standing on exposed surfaces.
func local_acceleration() -> Vector3:
	return global_transform.basis.inverse() * _measured_acceleration


## Acceleration expressed in the crew frame, which is the space crew offsets
## live in. Crew stability must use this rather than local_acceleration(): the
## rig is usually identity relative to the chassis, but nothing guarantees it,
## and a vehicle whose crew frame is offset or rotated would otherwise shove its
## crew in the wrong direction.
func crew_frame_acceleration() -> Vector3:
	return crew_frame_transform().basis.inverse() * _measured_acceleration


# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if delta > 0.0:
		_measured_acceleration = (linear_velocity - _previous_velocity) / delta
		_previous_velocity = linear_velocity

	if has_physics_authority():
		_read_local_driver_input()
		_apply_driving(delta)
		_apply_stability(delta)
		_broadcast_snapshot(delta)
	else:
		_follow_remote_state()

	# Health replication is the server's job regardless of who is driving.
	if multiplayer.is_server():
		_tick_health_replication(delta)


func _read_local_driver_input() -> void:
	_input.reset()
	if _rig == null or not local_input_enabled:
		return
	if _rig.driver_peer_id == 0 or _rig.driver_peer_id != multiplayer.get_unique_id():
		return
	if damage.is_destroyed():
		return

	_input.throttle = Input.get_axis(&"drive_reverse", &"drive_throttle")
	_input.steer = Input.get_axis(&"drive_steer_left", &"drive_steer_right")
	_input.handbrake = Input.is_action_pressed(&"drive_handbrake")
	_input.sanitise()


func _apply_driving(delta: float) -> void:
	if definition == null:
		return

	var speed: float = speed_ms()
	var forward_speed: float = forward_speed_ms()
	var engine_scale: float = damage.engine_output_scale()

	# --- Steering -----------------------------------------------------------
	# VehicleBody3D.steering is an angle about +Y, and +Y rotation is
	# counter-clockwise, so a positive angle steers *left*. The input axis is
	# +1 for right, hence the negation.
	var authority: float = definition.steer_authority_at(speed)
	var target_steer: float = -_input.steer * definition.max_steer_angle_rad() * authority
	# Asymmetric wheel damage drags the vehicle toward the damaged side. The
	# driver has to hold a correction, which is what makes a blown tyre feel
	# like a blown tyre instead of a number going down.
	target_steer -= damage.steering_pull() * definition.max_steer_angle_rad() * 0.25
	steering = MathUtil.damp(steering, target_steer, definition.steer_half_life, delta)

	# --- Throttle and brakes ------------------------------------------------
	var drive: float = 0.0
	var brake_amount: float = 0.0
	var top_speed: float = definition.max_speed_ms()

	if _input.throttle > 0.01:
		if forward_speed < -0.5:
			# Still rolling backwards: throttle means "stop" first.
			brake_amount = definition.brake_force
		elif forward_speed < top_speed:
			drive = _input.throttle * definition.engine_force * engine_scale
	elif _input.throttle < -0.01:
		if forward_speed > 0.5:
			brake_amount = definition.brake_force
		elif forward_speed > -top_speed * 0.4:
			drive = _input.throttle * definition.reverse_force * engine_scale
	else:
		# Light engine braking so a released throttle actually slows down
		# instead of coasting for half a kilometre.
		brake_amount = definition.brake_force * 0.06

	if _input.handbrake:
		brake_amount = maxf(brake_amount, definition.brake_force * 1.4)

	engine_force = drive
	brake = brake_amount

	_apply_wheel_grip()


func _apply_wheel_grip() -> void:
	if definition == null:
		return
	for component: int in _wheels.keys():
		var wheel: VehicleWheel3D = _wheels[component]
		if wheel == null:
			continue
		var grip: float = damage.wheel_grip_scale(component)
		if _input.handbrake and _REAR_WHEELS.has(component):
			grip *= definition.handbrake_grip
		wheel.wheel_friction_slip = float(_wheel_base_friction[component]) * grip


func _apply_stability(delta: float) -> void:
	if definition == null:
		return

	# Speed-proportional downforce. This is the single most effective thing for
	# keeping the vehicle planted through jumps and hard cornering, which in turn
	# is what stops a roof gunner's world from turning upside down.
	var speed: float = speed_ms()
	if definition.downforce_per_speed > 0.0 and speed > 0.5:
		apply_central_force(-global_transform.basis.y * definition.downforce_per_speed * speed)

	_update_self_right(delta)


func _update_self_right(delta: float) -> void:
	if definition == null or not definition.allow_self_right:
		return

	var uprightness: float = global_transform.basis.y.dot(Vector3.UP)
	var nearly_stopped: bool = speed_ms() < 2.0
	if uprightness >= 0.1 or not nearly_stopped:
		_inverted_time = 0.0
		return

	_inverted_time += delta
	if _inverted_time < definition.self_right_delay:
		return

	# Torque about the axis that rotates the vehicle's up back toward world up.
	var axis: Vector3 = global_transform.basis.y.cross(Vector3.UP)
	if axis.length_squared() < 0.0001:
		# Exactly inverted: the cross product degenerates, so pick the roll axis.
		axis = global_transform.basis.z
	apply_torque(axis.normalized() * definition.self_right_torque * mass)


# ---------------------------------------------------------------------------
# Network: transform replication
# ---------------------------------------------------------------------------

func _network_time() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


func _broadcast_snapshot(delta: float) -> void:
	if not NetworkManager.is_session_active():
		return
	_snapshot_accumulator += delta
	if _snapshot_accumulator < NetConfig.SNAPSHOT_INTERVAL:
		return
	# Subtract rather than zero, so a long frame does not silently drop the
	# accumulated remainder and skew the send rate.
	_snapshot_accumulator -= NetConfig.SNAPSHOT_INTERVAL
	if multiplayer.get_peers().is_empty():
		return

	_snapshot_sequence += 1
	_rpc_snapshot.rpc(
		_snapshot_sequence,
		global_position,
		global_transform.basis.get_rotation_quaternion(),
		linear_velocity
	)


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_snapshot(sequence: int, position_value: Vector3, rotation_value: Quaternion,
		velocity_value: Vector3) -> void:
	# Only the peer that owns the chassis may say where it is. Without this
	# check any client could stream positions for a vehicle it is not driving.
	if multiplayer.get_remote_sender_id() != physics_authority_peer:
		return
	_buffer.push_sample(sequence, _network_time(), position_value, rotation_value, velocity_value)


func _follow_remote_state() -> void:
	var render_time: float = _network_time() - NetConfig.INTERPOLATION_DELAY
	if not _buffer.sample_at(render_time):
		return
	_last_followed_transform = Transform3D(Basis(_buffer.out_rotation), _buffer.out_position)
	_has_followed_state = true
	global_transform = _last_followed_transform


# ---------------------------------------------------------------------------
# Network: authority handover
# ---------------------------------------------------------------------------

func _on_driver_changed(peer_id: int) -> void:
	# Only the server decides who simulates, and it decides from the seat state
	# it already owns.
	if not multiplayer.is_server():
		return
	server_set_physics_authority(peer_id if peer_id != 0 else 1)


## Server-only. Move chassis simulation to `peer_id`.
func server_set_physics_authority(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if peer_id == physics_authority_peer:
		return
	_rpc_set_physics_authority.rpc(peer_id)


@rpc("any_peer", "call_local", "reliable")
func _rpc_set_physics_authority(peer_id: int) -> void:
	if not NetGuard.is_from_server(self):
		return
	_set_physics_authority_local(peer_id)


func _set_physics_authority_local(peer_id: int) -> void:
	var was_authority: bool = has_physics_authority()
	physics_authority_peer = peer_id
	var is_authority: bool = has_physics_authority()

	if is_authority and not was_authority:
		# Taking over: adopt the last pose and velocity we were shown, so the
		# vehicle continues from where the previous driver left it instead of
		# snapping back to wherever this peer's frozen body happened to sit.
		var adopted_velocity: Vector3 = _buffer.latest_velocity()
		if _has_followed_state:
			global_transform = _last_followed_transform
		_apply_freeze_state()
		linear_velocity = adopted_velocity
		angular_velocity = Vector3.ZERO
		_buffer.clear()
		_has_followed_state = false
	elif not is_authority and was_authority:
		# Handing off: discard stale history so the first snapshot from the new
		# driver is not interpolated against our own old positions.
		_buffer.clear()
		_has_followed_state = false
		_apply_freeze_state()
	else:
		_apply_freeze_state()

	GameLog.info("vehicle", "physics authority -> peer %d (mine=%s)" % [peer_id, is_authority])
	physics_authority_changed.emit(peer_id)


func _apply_freeze_state() -> void:
	# Non-authority peers keep the body kinematic: it still collides with and
	# pushes the world, but the solver does not integrate it, so it cannot fight
	# the transforms we write from the snapshot buffer.
	freeze = not has_physics_authority()


# ---------------------------------------------------------------------------
# Damage (server-authoritative)
# ---------------------------------------------------------------------------

## Server-only. Apply damage to a specific component.
func server_apply_damage(component: int, amount: float,
		damage_type: int = GameEnums.DamageType.BALLISTIC) -> float:
	if not multiplayer.is_server():
		return 0.0
	var applied: float = damage.apply_damage(component, amount, damage_type)
	if applied > 0.0:
		_health_dirty = true
	return applied


## Server-only. Apply damage at a world position, resolving which component was
## hit from where the shot landed.
##
## A share always goes to the armour: plating spreads impact, and it means armour
## degrades from taking fire generally rather than only from shots that happen to
## strike an armour marker.
func server_apply_damage_at(global_point: Vector3, amount: float,
		damage_type: int = GameEnums.DamageType.BALLISTIC) -> void:
	if not multiplayer.is_server() or amount <= 0.0:
		return

	var component: int = component_nearest_to(global_point)
	if damage.has_component(GameEnums.VehicleComponent.ARMOR) \
			and component != GameEnums.VehicleComponent.ARMOR:
		server_apply_damage(GameEnums.VehicleComponent.ARMOR, amount * 0.4, damage_type)
		server_apply_damage(component, amount * 0.6, damage_type)
	else:
		server_apply_damage(component, amount, damage_type)


## The generic damage interface every weapon and enemy goes through; see
## DamageRouter. Without this method the router would walk straight past the
## chassis looking for something damageable and find nothing, and the vehicle
## would be quietly invulnerable to everything.
##
## Returns the total damage applied, so callers can show a hit marker.
func server_take_damage(amount: float, damage_type: int, _source_peer_id: int,
		hit_point: Vector3) -> float:
	if not multiplayer.is_server() or amount <= 0.0:
		return 0.0
	var before: float = _total_health()
	server_apply_damage_at(hit_point, amount, damage_type)
	return maxf(before - _total_health(), 0.0)


func _total_health() -> float:
	var total: float = 0.0
	for component: int in damage.components():
		total += damage.health_of(component)
	return total


## Server-only. Repair a component.
func server_apply_repair(component: int, amount: float, cap_ratio: float = 1.0) -> float:
	if not multiplayer.is_server():
		return 0.0
	var restored: float = damage.apply_repair(component, amount, cap_ratio)
	if restored > 0.0:
		_health_dirty = true
	return restored


## Which component sits closest to `global_point`. Falls back to armour, then to
## the engine, so a hit always lands somewhere rather than being dropped.
func component_nearest_to(global_point: Vector3) -> int:
	if _component_positions.is_empty() or _rig == null:
		if damage.has_component(GameEnums.VehicleComponent.ARMOR):
			return GameEnums.VehicleComponent.ARMOR
		return GameEnums.VehicleComponent.ENGINE

	var local_point: Vector3 = _rig.global_transform.affine_inverse() * global_point
	var best_component: int = GameEnums.VehicleComponent.ARMOR
	var best_distance: float = INF
	for component: int in _component_positions.keys():
		var distance: float = local_point.distance_squared_to(_component_positions[component])
		if distance < best_distance:
			best_distance = distance
			best_component = component
	return best_component


func _tick_health_replication(delta: float) -> void:
	if not _health_dirty:
		return
	_health_accumulator += delta
	if _health_accumulator < NetConfig.SNAPSHOT_INTERVAL:
		return
	_health_accumulator = 0.0
	_health_dirty = false
	if multiplayer.get_peers().is_empty():
		return
	_rpc_sync_health.rpc(damage.to_dict(), damage.is_destroyed())


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_health(payload: Dictionary, destroyed: bool) -> void:
	damage.apply_snapshot(payload, destroyed)


func _on_component_changed(component: int, ratio: float) -> void:
	GameEvents.vehicle_component_health_changed.emit(component, ratio)


func _on_vehicle_destroyed() -> void:
	GameLog.info("vehicle", "vehicle destroyed")
	GameEvents.vehicle_destroyed.emit()


# ---------------------------------------------------------------------------
# Setup helpers
# ---------------------------------------------------------------------------

func _collect_wheels() -> void:
	var mapping: Dictionary = {
		GameEnums.VehicleComponent.WHEEL_FRONT_LEFT: wheel_front_left_path,
		GameEnums.VehicleComponent.WHEEL_FRONT_RIGHT: wheel_front_right_path,
		GameEnums.VehicleComponent.WHEEL_REAR_LEFT: wheel_rear_left_path,
		GameEnums.VehicleComponent.WHEEL_REAR_RIGHT: wheel_rear_right_path,
	}
	for component: int in mapping.keys():
		var path: NodePath = mapping[component]
		if path.is_empty():
			continue
		var wheel: VehicleWheel3D = get_node_or_null(path) as VehicleWheel3D
		if wheel == null:
			GameLog.warn("vehicle", "wheel path '%s' did not resolve to a VehicleWheel3D" % path)
			continue
		_wheels[component] = wheel
		_wheel_base_friction[component] = wheel.wheel_friction_slip


## Component locations are read from the vehicle's repair points, which already
## have to sit on the part they service. Reusing them here means a vehicle
## author places the engine hatch once and both repair interaction and
## hit-location resolution follow from it.
func _collect_component_positions() -> void:
	if _rig == null:
		return
	for point: VehicleAttachmentPoint in _rig.points.values():
		if point.point_type != GameEnums.AttachmentType.REPAIR:
			continue
		_component_positions[point.repair_component] = point.rig_local_transform.origin
