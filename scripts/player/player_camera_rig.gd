class_name PlayerCameraRig
extends Node3D

## Third-person camera that adapts to what the crew member is doing.
##
## ============================================================================
## WHY THIS NODE IS top_level
## ============================================================================
##
## A crew member's body inherits the vehicle's full orientation — stand on a hood
## pitched uphill and they lean with it, which is the correct look. The camera
## must *not* inherit that. A camera that rolls and pitches with a vehicle
## cornering hard is unreadable and quickly nauseating, and it makes aiming feel
## like the world is fighting you.
##
## So this rig sets `top_level = true`, detaching it from the parent transform
## entirely, and rebuilds its own global transform each frame from a world-space
## pivot plus a yaw and pitch it owns. The character tilts; the horizon does not.
##
## ============================================================================
## FRAMING
## ============================================================================
##
## Distance, height and field of view are chosen per crew state and eased
## between, so moving from a cramped rear seat out onto the roof opens the shot
## up instead of cutting. Field of view also widens with vehicle speed, which is
## the cheapest and most effective way to communicate how fast the vehicle is
## actually going in a third-person view.

@export_group("Look")
@export_range(0.0005, 0.02, 0.0001) var mouse_sensitivity: float = 0.0026
@export_range(-89.0, 0.0, 1.0) var min_pitch_degrees: float = -68.0
@export_range(0.0, 89.0, 1.0) var max_pitch_degrees: float = 52.0
@export var invert_pitch: bool = false

@export_group("Framing")
## Seconds to close half the gap when the framing changes. Long enough to read
## as a move, short enough not to lag behind a fast traversal.
@export_range(0.02, 0.8, 0.01) var framing_half_life: float = 0.16
## Seconds to close half the gap when following the pivot. Kept short: the
## camera should track the crew member, not trail them.
@export_range(0.0, 0.3, 0.005) var follow_half_life: float = 0.035
@export_range(0.0, 1.5, 0.05) var shoulder_offset: float = 0.5

@export_group("Distances")
@export_range(0.5, 10.0, 0.1) var seated_distance: float = 2.6
@export_range(0.0, 3.0, 0.05) var seated_height: float = 1.35
@export_range(0.5, 10.0, 0.1) var surface_distance: float = 3.5
@export_range(0.0, 3.0, 0.05) var surface_height: float = 1.6
@export_range(0.5, 10.0, 0.1) var traversing_distance: float = 3.1
@export_range(0.0, 3.0, 0.05) var traversing_height: float = 1.7
@export_range(0.5, 10.0, 0.1) var dismounted_distance: float = 3.3
@export_range(0.0, 3.0, 0.05) var dismounted_height: float = 1.5

@export_group("Field of View")
@export_range(40.0, 110.0, 1.0) var base_fov: float = 74.0
@export_range(30.0, 90.0, 1.0) var aim_fov: float = 52.0
## Extra degrees of FOV at the vehicle's top speed.
@export_range(0.0, 30.0, 0.5) var speed_fov_bonus: float = 11.0
## Distance multiplier while aiming, pulling the camera in over the shoulder.
@export_range(0.2, 1.0, 0.05) var aim_distance_scale: float = 0.6

## --- Written by PlayerCharacter before each follow() call --------------------
## GameEnums.CrewState the framing should reflect.
var target_state: int = GameEnums.CrewState.SEATED
## Per-attachment-point framing tweaks.
var extra_distance: float = 0.0
var extra_height: float = 0.0
var is_aiming: bool = false
## Vehicle speed as a fraction of its top speed, 0..1.
var speed_ratio: float = 0.0

var _yaw: float = 0.0
var _pitch: float = -0.12

var _current_distance: float = 3.0
var _current_height: float = 1.5
var _current_fov: float = 74.0
var _current_pivot: Vector3 = Vector3.ZERO
var _pivot_initialised: bool = false

@onready var _arm: SpringArm3D = $Arm
@onready var _camera: Camera3D = $Arm/Camera


func _ready() -> void:
	# Detach from the parent's transform; this rig positions itself.
	top_level = true
	_current_fov = base_fov
	if _camera != null:
		_camera.fov = base_fov


func camera() -> Camera3D:
	return _camera


## Make this the rendering camera. Only ever true for the locally controlled
## crew member.
func set_active(active: bool) -> void:
	if _camera != null:
		_camera.current = active
	set_process(active)


## Stop the spring arm colliding with a body — the crew member themselves, and
## the vehicle they are riding.
func exclude_body(body: CollisionObject3D) -> void:
	if _arm != null and body != null:
		_arm.add_excluded_object(body.get_rid())


func yaw() -> float:
	return _yaw


func pitch() -> float:
	return _pitch


## Apply accumulated mouse motion.
func apply_look(pixel_delta: Vector2) -> void:
	if pixel_delta.is_zero_approx():
		return
	_yaw = wrapf(_yaw - pixel_delta.x * mouse_sensitivity, -PI, PI)
	var pitch_delta: float = pixel_delta.y * mouse_sensitivity
	if invert_pitch:
		pitch_delta = -pitch_delta
	_pitch = clampf(_pitch - pitch_delta,
		deg_to_rad(min_pitch_degrees), deg_to_rad(max_pitch_degrees))


## Place the rig for this frame. `pivot` is the crew member's eye position in
## world space.
func follow(pivot: Vector3, delta: float) -> void:
	var target_distance: float = _distance_for_state() + extra_distance
	var target_height: float = _height_for_state() + extra_height
	var target_fov: float = base_fov + speed_fov_bonus * clampf(speed_ratio, 0.0, 1.0)

	if is_aiming:
		target_distance *= aim_distance_scale
		target_fov = aim_fov

	_current_distance = MathUtil.damp(_current_distance, maxf(target_distance, 0.2),
		framing_half_life, delta)
	_current_height = MathUtil.damp(_current_height, target_height, framing_half_life, delta)
	_current_fov = MathUtil.damp(_current_fov, target_fov, framing_half_life, delta)

	# The pivot is followed with a very short damp rather than snapped. Crew
	# offsets update at the physics rate and the vehicle's suspension jitters at
	# small amplitudes; easing removes that from the camera without introducing
	# any perceptible lag.
	var desired_pivot: Vector3 = pivot + Vector3.UP * _current_height
	if not _pivot_initialised:
		_current_pivot = desired_pivot
		_pivot_initialised = true
	else:
		_current_pivot = MathUtil.damp_vector3(_current_pivot, desired_pivot,
			follow_half_life, delta)

	var basis: Basis = Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	# Over-the-shoulder framing is done by shifting the whole rig sideways rather
	# than offsetting the camera under the spring arm, because SpringArm3D
	# overwrites the transforms of its direct children every frame.
	var shoulder: Vector3 = basis.x * shoulder_offset
	global_transform = Transform3D(basis, _current_pivot + shoulder)

	if _arm != null:
		_arm.spring_length = _current_distance
	if _camera != null:
		_camera.fov = _current_fov


## Snap the camera to its target immediately. Use after a teleport or on spawn,
## so the camera does not sweep across the level to catch up.
func snap_to(pivot: Vector3) -> void:
	_pivot_initialised = false
	_current_distance = _distance_for_state() + extra_distance
	_current_height = _height_for_state() + extra_height
	follow(pivot, 1.0)


func _distance_for_state() -> float:
	match target_state:
		GameEnums.CrewState.SEATED:
			return seated_distance
		GameEnums.CrewState.ON_SURFACE:
			return surface_distance
		GameEnums.CrewState.TRAVERSING:
			return traversing_distance
		_:
			return dismounted_distance


func _height_for_state() -> float:
	match target_state:
		GameEnums.CrewState.SEATED:
			return seated_height
		GameEnums.CrewState.ON_SURFACE:
			return surface_height
		GameEnums.CrewState.TRAVERSING:
			return traversing_height
		_:
			return dismounted_height


# ---------------------------------------------------------------------------
# Aiming
# ---------------------------------------------------------------------------

func aim_origin() -> Vector3:
	if _camera == null:
		return global_position
	return _camera.global_position


func aim_direction() -> Vector3:
	if _camera == null:
		return -global_transform.basis.z
	return -_camera.global_transform.basis.z


## Where the crosshair is pointing in the world.
##
## Shots originate at the muzzle but must converge on what the crosshair covers,
## so the aim point is resolved from the camera first and the weapon then fires
## at it. Without this the muzzle's own line of sight diverges from the
## crosshair, and players miss things they are visibly aiming at.
func aim_point(max_distance: float, exclude: Array[RID] = []) -> Vector3:
	var origin: Vector3 = aim_origin()
	var target: Vector3 = origin + aim_direction() * max_distance
	var world: World3D = get_world_3d()
	if world == null:
		return target

	var query := PhysicsRayQueryParameters3D.create(origin, target,
		NetConfig.Layer.SHOOTABLE, exclude)
	query.collide_with_areas = false
	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return target
	return hit["position"]
