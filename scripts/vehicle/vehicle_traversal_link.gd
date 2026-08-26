@tool
class_name VehicleTraversalLink
extends Node3D

## A traversable edge between two VehicleAttachmentPoints.
##
## Links are what turn a pile of attachment points into a navigable vehicle. They
## are the authored answer to "can I get from the rear seat to the roof, and what
## does that look like?" — and because they are nodes in the vehicle scene,
## every vehicle answers that question differently without any code changing.
##
## Motion along a link is a quadratic Bezier evaluated in the vehicle's crew
## frame, lifted by `arc_height` so that climbing out of a window rises over the
## sill instead of shearing through the door. Because the curve is evaluated in
## *vehicle-local* space, the whole traversal is unaffected by what the vehicle is
## doing: a crew member halfway through a window climb during a hard left turn
## follows exactly the same local path they would at a standstill, and simply
## gets carried along with the chassis.
##
## The interpolated curve is a placeholder for authored animation, not a rejection
## of it. `animation_name` is already carried here; when real climbing animations
## exist, the traversal state plays the animation and reads root motion, and the
## curve stays as the fallback for links with no animation authored yet.

@export_group("Identity")
@export var link_name: StringName = &""

## The two attachment points this link joins. Both must be
## VehicleAttachmentPoint nodes on the same vehicle.
@export_node_path("Node3D") var from_point_path: NodePath = NodePath()
@export_node_path("Node3D") var to_point_path: NodePath = NodePath()

## When false, this link may only be used from `from_point` to `to_point`.
## A drop down from the roof to the ground is a good one-way link.
@export var bidirectional: bool = true

@export_group("Motion")
## Matches GameEnums.TraversalKind. Selects the animation and, later, the
## audio and the vulnerability profile of the transition.
@export_enum("Step", "Climb Window", "Vault", "Ladder", "Drop")
var kind: int = GameEnums.TraversalKind.STEP

## Seconds to cross. This is a real commitment window: the crew member cannot
## shoot and cannot change direction, so longer links are meaningfully riskier.
@export_range(0.1, 4.0, 0.05) var duration: float = 0.85

## How far the path bows along the vehicle's up axis, in metres. Set this to
## clear whatever the crew member is climbing over.
@export_range(-1.5, 2.5, 0.05) var arc_height: float = 0.4

## Optional animation to drive the transition once animations exist.
@export var animation_name: StringName = &""

@export_group("Conditions")
## Above this vehicle speed the link refuses to activate. Climbing out of a
## window at 120 km/h should not be free; -1 disables the check.
@export_range(-1.0, 300.0, 1.0) var max_vehicle_speed_kph: float = -1.0

## Shown in the HUD when this link is available.
@export var prompt_text: String = ""

## Resolved endpoints and their cached crew-frame poses.
var from_point: VehicleAttachmentPoint = null
var to_point: VehicleAttachmentPoint = null

var _from_rig_position: Vector3 = Vector3.ZERO
var _to_rig_position: Vector3 = Vector3.ZERO
var _from_yaw: float = 0.0
var _to_yaw: float = 0.0
var _control_forward: Vector3 = Vector3.ZERO
var _control_backward: Vector3 = Vector3.ZERO
var _resolved: bool = false


func _ready() -> void:
	if String(link_name).is_empty():
		link_name = StringName(name)


## Called by VehicleRig after every attachment point has been bound, so that the
## endpoints' cached crew-frame transforms are already valid.
func bind_to_rig(rig: Node3D) -> void:
	if String(link_name).is_empty():
		link_name = StringName(name)

	from_point = get_node_or_null(from_point_path) as VehicleAttachmentPoint
	to_point = get_node_or_null(to_point_path) as VehicleAttachmentPoint
	_resolved = from_point != null and to_point != null

	if not _resolved:
		GameLog.warn("vehicle", "traversal link '%s' has unresolved endpoints (from=%s to=%s)"
			% [link_name, from_point_path, to_point_path])
		return

	_from_rig_position = from_point.rig_local_transform.origin
	_to_rig_position = to_point.rig_local_transform.origin
	_from_yaw = from_point.rig_local_yaw
	_to_yaw = to_point.rig_local_yaw

	# One control point per direction. They are mirrored about the midpoint so
	# that travelling back along a link retraces the same arc rather than
	# describing a different one, which would look like two separate routes.
	# Both endpoints are already expressed in the crew frame, so "up" here is the
	# crew frame's own +Y — not the rig node's basis, which would be the rig's
	# orientation within the *vehicle* and is the identity in practice.
	var midpoint: Vector3 = (_from_rig_position + _to_rig_position) * 0.5
	_control_forward = midpoint + Vector3.UP * arc_height
	_control_backward = _control_forward


func is_resolved() -> bool:
	return _resolved


## True when this link touches `point_name` at an end it can be entered from.
func can_start_at(point_name: StringName) -> bool:
	if not _resolved:
		return false
	if from_point.point_name == point_name:
		return true
	return bidirectional and to_point.point_name == point_name


## The endpoint reached by entering at `point_name`, or null if this link cannot
## be entered there.
func destination_from(point_name: StringName) -> VehicleAttachmentPoint:
	if not _resolved:
		return null
	if from_point.point_name == point_name:
		return to_point
	if bidirectional and to_point.point_name == point_name:
		return from_point
	return null


## True when entering at `point_name` means travelling from -> to.
func is_forward_from(point_name: StringName) -> bool:
	return _resolved and from_point.point_name == point_name


## Whether the link may be used at the vehicle's current speed.
func is_allowed_at_speed(speed_kph: float) -> bool:
	if max_vehicle_speed_kph < 0.0:
		return true
	return speed_kph <= max_vehicle_speed_kph


## Position along the traversal, in the vehicle's crew frame.
## `t` is 0..1; `forward` selects the direction of travel.
func sample_rig_position(t: float, forward: bool) -> Vector3:
	if not _resolved:
		return Vector3.ZERO
	# Smootherstep removes the velocity discontinuity at both ends, so a crew
	# member eases out of the seat and settles onto the roof instead of snapping
	# into motion and stopping dead.
	var eased: float = MathUtil.smoother_step(t)
	if forward:
		return MathUtil.quadratic_bezier(_from_rig_position, _control_forward, _to_rig_position, eased)
	return MathUtil.quadratic_bezier(_to_rig_position, _control_backward, _from_rig_position, eased)


## Facing along the traversal, in the vehicle's crew frame.
func sample_rig_yaw(t: float, forward: bool) -> float:
	if not _resolved:
		return 0.0
	var eased: float = MathUtil.smoother_step(t)
	var start_yaw: float = _from_yaw if forward else _to_yaw
	var end_yaw: float = _to_yaw if forward else _from_yaw
	return lerp_angle(start_yaw, end_yaw, eased)


## Straight-line length in metres. Used to sanity-check authored links and to
## scale traversal audio.
func span_length() -> float:
	if not _resolved:
		return 0.0
	return _from_rig_position.distance_to(_to_rig_position)


func effective_prompt() -> String:
	if not prompt_text.is_empty():
		return prompt_text
	match kind:
		GameEnums.TraversalKind.CLIMB_WINDOW:
			return "Climb through window"
		GameEnums.TraversalKind.VAULT:
			return "Vault"
		GameEnums.TraversalKind.LADDER:
			return "Climb"
		GameEnums.TraversalKind.DROP:
			return "Drop down"
		_:
			return "Move"


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = PackedStringArray()
	if from_point_path.is_empty() or to_point_path.is_empty():
		warnings.append("Both from_point_path and to_point_path must be set.")
	elif from_point_path == to_point_path:
		warnings.append("A link's two endpoints must be different points.")
	if duration <= 0.0:
		warnings.append("duration must be greater than zero.")
	return warnings
