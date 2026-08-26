class_name PlayerCharacter
extends CharacterBody3D

## One crew member.
##
## Deliberately thin. It owns identity, input, and the order things happen in,
## and delegates the actual work:
##
##   CrewController   where the crew member is on the vehicle, and how they move
##                    and climb around it
##   PlayerCameraRig  framing and aim direction
##   Weapon           shooting
##   HealthComponent  damage and death
##
## ============================================================================
## TWO LOCOMOTION MODES
## ============================================================================
##
## While attached to a vehicle this node's transform is *written* by
## CrewController from vehicle-local coordinates, and `move_and_slide()` is never
## called. That is what makes attachment unbreakable — see CrewAttachment for the
## full argument. Once dismounted it becomes an ordinary CharacterBody3D with
## gravity and collision.
##
## The boundary between those two modes is the crew state, and it is the only
## place the two systems meet.

@export_group("Body")
## Eye height above the crew member's feet, used for the camera pivot.
@export_range(0.5, 2.5, 0.05) var eye_height: float = 1.55

@export_group("On Foot")
@export_range(1.0, 10.0, 0.1) var walk_speed: float = 4.4
@export_range(1.0, 14.0, 0.1) var sprint_speed: float = 6.8
@export_range(1.0, 12.0, 0.1) var jump_velocity: float = 5.2

## Identity. Set by the crew spawner before this node enters the tree.
var peer_id: int = 0
var role: int = GameEnums.CrewRole.NONE
var display_name: String = "Player"

var _input: PlayerInputState = PlayerInputState.new()
var _input_enabled: bool = true
var _gravity: float = 9.8

@onready var crew: CrewController = $Crew
@onready var camera_rig: PlayerCameraRig = $CameraRig
@onready var health: HealthComponent = $Health
@onready var weapon: Weapon = $WeaponPivot/Weapon


## Call before add_child(). The peer id has to be known before _ready() so that
## multiplayer authority is set the moment the node enters the tree — a node that
## spends even one frame with the wrong authority can drop the first RPC aimed
## at it.
func configure(owning_peer: int, crew_role: int, name_text: String) -> void:
	peer_id = owning_peer
	role = crew_role
	display_name = name_text


func _ready() -> void:
	add_to_group(&"crew")
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))

	# The whole player subtree belongs to its owning peer, so recursive authority
	# is correct here — unlike on the vehicle, where it would hand a client the
	# seat and damage state as well.
	set_multiplayer_authority(peer_id)

	crew.setup(self, peer_id, role)
	weapon.setup(self, crew, peer_id)

	health.died.connect(_on_died)

	if is_local_player():
		camera_rig.set_active(true)
		camera_rig.exclude_body(self)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		camera_rig.set_active(false)
		# Remote players never read input. _unhandled_input is gated by
		# set_process_unhandled_input, not set_process_input — disabling the
		# wrong one leaves the handler running.
		set_process_unhandled_input(false)


func _exit_tree() -> void:
	if is_local_player():
		GameEvents.local_player_despawned.emit()


func is_local_player() -> bool:
	return peer_id == multiplayer.get_unique_id()


## Part of the damage interface; see DamageRouter.
func owning_peer_id() -> int:
	return peer_id


## Bind this crew member to the vehicle they ride. Called after the node is in
## the tree, because CrewController needs the vehicle's rig to be scanned.
func bind_vehicle(vehicle: VehicleController) -> void:
	crew.attach_to_vehicle(vehicle)
	if not is_local_player():
		return
	if vehicle != null:
		camera_rig.exclude_body(vehicle)
		camera_rig.snap_to(eye_position())
	# Announced here rather than from _ready(), because this is the first moment
	# the player is actually complete. A HUD that listened at _ready() would read
	# a crew member with no vehicle and would show no speed or component health
	# for the whole match.
	GameEvents.local_player_spawned.emit(self)


func eye_position() -> Vector3:
	return global_position + global_transform.basis.y.normalized() * eye_height


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not is_local_player():
		return
	_input.handle_event(event)

	if event.is_action_pressed(&"ui_toggle_mouse"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if is_local_player():
		# Input is only live while the pointer is captured, so clicking through a
		# menu never reaches the weapon.
		_input_enabled = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		_input.poll(_input_enabled)
		camera_rig.apply_look(_input.take_look_delta())

		crew.move_input = _input.move
		crew.aim_yaw = camera_rig.yaw()
		crew.input_enabled = _input_enabled
		_apply_actions()

	# Crew simulation is driven explicitly, after input and the camera yaw are
	# settled, so the ordering is visible here rather than implied by tree order.
	crew.simulate(delta)

	if crew.state() == GameEnums.CrewState.DISMOUNTED:
		_simulate_on_foot(delta)

	if is_local_player():
		_update_camera(delta)


func _apply_actions() -> void:
	var vehicle: VehicleController = crew.vehicle()
	if vehicle != null and crew.is_driving():
		vehicle.local_input_enabled = _input_enabled

	if not _input_enabled or crew.is_action_locked():
		return

	if _input.interact_pressed:
		crew.activate_interaction()
	if _input.cycle_pressed:
		crew.cycle_interaction()
	if _input.leave_seat_pressed:
		crew.leave_seat()
	if _input.reload_pressed:
		weapon.start_reload()

	# Hands on the wheel: the driver cannot use a personal weapon. Fighting while
	# driving is what the vehicle-mounted weapons are for, and forcing the choice
	# is what makes handing over the wheel a real decision.
	if crew.is_driving():
		return

	if weapon.definition != null:
		var wants_fire: bool = _input.fire_held if weapon.definition.automatic else _input.fire_pressed
		if wants_fire:
			weapon.try_fire(_aim_target(), _input.aim_held)


func _aim_target() -> Vector3:
	var range_limit: float = 180.0
	if weapon.definition != null:
		range_limit = weapon.definition.max_range
	return camera_rig.aim_point(range_limit, weapon.shot_exclusions())


# ---------------------------------------------------------------------------
# On-foot locomotion (DISMOUNTED only)
# ---------------------------------------------------------------------------

func _simulate_on_foot(delta: float) -> void:
	if not is_local_player():
		# Remote dismounted crew are positioned by CrewController from streamed
		# world poses; running physics for them here would fight that.
		return

	var yaw: float = camera_rig.yaw()
	var forward: Vector3 = Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right: Vector3 = Vector3(cos(yaw), 0.0, -sin(yaw))
	var direction: Vector3 = Vector3.ZERO
	if _input_enabled:
		direction = right * _input.move.x + forward * _input.move.y

	var speed: float = sprint_speed if _input.sprint_held else walk_speed
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed

	if is_on_floor():
		if _input_enabled and _input.jump_pressed:
			velocity.y = jump_velocity
		else:
			# A small downward bias keeps the controller in contact with slopes
			# instead of skipping down them.
			velocity.y = -0.1
	else:
		velocity.y -= _gravity * delta

	move_and_slide()

	# Face the camera while on foot, and keep the crew attachment's world
	# transform current so it replicates and so re-boarding starts from the
	# right place.
	rotation = Vector3(0.0, yaw, 0.0)
	crew.attachment.world_transform = global_transform


# ---------------------------------------------------------------------------
# Camera
# ---------------------------------------------------------------------------

func _update_camera(delta: float) -> void:
	camera_rig.target_state = crew.state()
	camera_rig.is_aiming = _input.aim_held

	var point: VehicleAttachmentPoint = crew.attachment.current_point()
	if point != null and crew.state() == GameEnums.CrewState.SEATED:
		camera_rig.extra_distance = point.camera_distance_bonus
		camera_rig.extra_height = point.camera_height_bonus
	else:
		camera_rig.extra_distance = 0.0
		camera_rig.extra_height = 0.0

	var vehicle: VehicleController = crew.vehicle()
	if vehicle != null and vehicle.definition != null and crew.is_attached():
		camera_rig.extra_distance += vehicle.definition.camera_distance_bonus
		camera_rig.speed_ratio = clampf(
			vehicle.speed_ms() / maxf(vehicle.definition.max_speed_ms(), 0.001), 0.0, 1.0)
	else:
		camera_rig.speed_ratio = 0.0

	camera_rig.follow(eye_position(), delta)


# ---------------------------------------------------------------------------
# Damage
# ---------------------------------------------------------------------------

## Damage interface; see DamageRouter. Server-only.
func server_take_damage(amount: float, _damage_type: int, source_peer_id: int,
		_hit_point: Vector3) -> float:
	if not multiplayer.is_server():
		return 0.0
	return health.server_apply_damage(amount, source_peer_id)


func _on_died(source_peer_id: int) -> void:
	GameLog.info("crew", "peer %d died (killer %d)" % [peer_id, source_peer_id])
	# Phase 1 has no respawn flow yet: the crew member stays in place and stops
	# acting. Downed/revive and respawn land in Phase 7 alongside the mission
	# structure that gives dying a consequence.
	if is_local_player():
		GameEvents.local_crew_state_changed.emit(GameEnums.CrewState.DEAD)
