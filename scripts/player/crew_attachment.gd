class_name CrewAttachment
extends RefCounted

## Where a crew member is, expressed entirely in the vehicle's own coordinate
## space, plus the arithmetic that turns that into a world transform.
##
## ============================================================================
## THE CENTRAL IDEA
## ============================================================================
##
## A crew member's position is never stored in world coordinates while they are
## on the vehicle. It is stored as one of:
##
##   SEATED     -> the name of an attachment point
##   ON_SURFACE -> a surface name plus a 2D coordinate on that surface
##   TRAVERSING -> a link name, a direction, and a progress value
##
## and the world transform is recomposed every frame as
##
##   world = vehicle_crew_frame * local_offset
##
## Everything good about this design follows from that one line:
##
##   * **Attachment cannot fail.** There is no contact, no friction, no
##     resolution step that can go wrong. If the vehicle barrel-rolls at 40 m/s,
##     the local offset is untouched and the crew member is exactly as attached
##     as they were. "Stay on the vehicle" stops being a physics problem the
##     engine might lose and becomes an invariant of the representation.
##
##   * **It is cheap to replicate.** Two of the three states carry no continuous
##     data at all — a seated crew member is fully described by a seat name, and
##     a traversing one by a link plus a start time, because the curve is
##     deterministic. Only surface walking needs streaming, and that is a
##     Vector2 and a float.
##
##   * **Every peer agrees.** Both factors of the product are replicated, so
##     each peer multiplies the same two things and gets the same answer. There
##     is no separate "player position" to drift out of sync with the vehicle.
##
## The cost is that crew members do not physically collide with the world while
## attached; driving under a low bridge will not sweep a roof gunner off. That is
## a mechanic to add deliberately (a swept test against world geometry that
## triggers a knock-off), not something to inherit by accident from a physics
## engine that was never going to get it right at speed.
##
## This class is deliberately free of nodes, input and networking so the
## composition maths can be reasoned about — and tested — on its own.

var state: int = GameEnums.CrewState.UNASSIGNED

## Occupied or destination attachment point (SEATED, and the target of a
## traversal in progress).
var point_name: StringName = &""

## Surface being walked on, and the position on it in metres.
var surface_name: StringName = &""
var surface_uv: Vector2 = Vector2.ZERO

## Facing within the vehicle's crew frame, in radians. Composed on top of the
## vehicle's own rotation, so a crew member holding still keeps facing the same
## way *relative to the vehicle* while the vehicle turns underneath them.
var local_yaw: float = 0.0

## Traversal in progress.
var link_name: StringName = &""
var link_forward: bool = true
var link_progress: float = 0.0

## World-space transform for the DISMOUNTED state, where the crew member is a
## normal character in the world and none of the above applies.
var world_transform: Transform3D = Transform3D.IDENTITY

var _vehicle: VehicleController = null
var _rig: VehicleRig = null


func bind_vehicle(vehicle: VehicleController) -> void:
	_vehicle = vehicle
	_rig = vehicle.rig() if vehicle != null else null


func vehicle() -> VehicleController:
	return _vehicle


func rig() -> VehicleRig:
	return _rig


func is_attached() -> bool:
	return state == GameEnums.CrewState.SEATED \
		or state == GameEnums.CrewState.ON_SURFACE \
		or state == GameEnums.CrewState.TRAVERSING


func current_point() -> VehicleAttachmentPoint:
	if _rig == null:
		return null
	return _rig.find_point(point_name)


func current_surface() -> VehicleSurface:
	if _rig == null:
		return null
	return _rig.find_surface(surface_name)


func current_link() -> VehicleTraversalLink:
	if _rig == null or String(link_name).is_empty():
		return null
	for link: VehicleTraversalLink in _rig.links:
		if link.link_name == link_name:
			return link
	return null


# ---------------------------------------------------------------------------
# Composition
# ---------------------------------------------------------------------------

## Position within the vehicle's crew frame for the current state.
func rig_local_position() -> Vector3:
	match state:
		GameEnums.CrewState.SEATED:
			var point: VehicleAttachmentPoint = current_point()
			return point.rig_local_transform.origin if point != null else Vector3.ZERO
		GameEnums.CrewState.ON_SURFACE:
			var surface: VehicleSurface = current_surface()
			return surface.uv_to_rig(surface_uv) if surface != null else Vector3.ZERO
		GameEnums.CrewState.TRAVERSING:
			var link: VehicleTraversalLink = current_link()
			return link.sample_rig_position(link_progress, link_forward) if link != null else Vector3.ZERO
		_:
			return Vector3.ZERO


## Facing within the vehicle's crew frame for the current state.
##
## While traversing, the link dictates facing — a crew member climbing through a
## window turns to face the way they are going, and cannot aim, which is what
## makes a traversal a real commitment rather than a free repositioning.
func rig_local_yaw() -> float:
	if state == GameEnums.CrewState.TRAVERSING:
		var link: VehicleTraversalLink = current_link()
		if link != null:
			return link.sample_rig_yaw(link_progress, link_forward)
	return local_yaw


## The up direction a crew member stands along, in the crew frame. Following the
## surface normal is what makes standing on a sloped hood look deliberate rather
## than like the character is sunk into it.
func rig_local_up() -> Vector3:
	if state == GameEnums.CrewState.ON_SURFACE:
		var surface: VehicleSurface = current_surface()
		if surface != null:
			return surface.up_in_rig()
	return Vector3.UP


## The crew member's world transform.
##
## Orientation deliberately inherits the vehicle's: a crew member on a hood
## pitched 20 degrees uphill leans with it. The camera does *not* inherit that
## roll — see PlayerCameraRig — because a camera that rolls with the chassis is
## unreadable and unpleasant, while a character that does not is obviously wrong.
func compose_world_transform() -> Transform3D:
	if not is_attached() or _vehicle == null:
		return world_transform

	var frame: Transform3D = _vehicle.crew_frame_transform()
	var up: Vector3 = rig_local_up()
	var yaw: float = rig_local_yaw()

	# Build an orthonormal basis whose Y is the surface normal and whose yaw
	# about that normal is `yaw`. Starting from the yawed forward direction and
	# orthogonalising against `up` keeps the character upright on the surface
	# without the basis shearing when the surface is not level.
	var forward: Vector3 = Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right: Vector3 = forward.cross(up)
	if right.length_squared() < 0.000001:
		# Facing straight along the surface normal (a vertical wall surface with
		# a degenerate yaw); pick any perpendicular so the basis stays valid.
		right = Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD
		right = right.cross(up)
	right = right.normalized()
	var corrected_forward: Vector3 = up.cross(right).normalized()

	var local_basis: Basis = Basis(right, up.normalized(), -corrected_forward)
	var local: Transform3D = Transform3D(local_basis, rig_local_position())
	return frame * local


## World position of the crew member's eyes, for camera pivots and shot origins.
func eye_position(eye_height: float) -> Vector3:
	var transform: Transform3D = compose_world_transform()
	return transform.origin + transform.basis.y.normalized() * eye_height


# ---------------------------------------------------------------------------
# State transitions
# ---------------------------------------------------------------------------

func enter_seat(point: VehicleAttachmentPoint) -> void:
	state = GameEnums.CrewState.SEATED
	point_name = point.point_name
	surface_name = &""
	link_name = &""
	link_progress = 0.0
	local_yaw = point.rig_local_yaw


func enter_surface(surface: VehicleSurface, uv: Vector2, yaw: float) -> void:
	state = GameEnums.CrewState.ON_SURFACE
	surface_name = surface.surface_name
	surface_uv = surface.clamp_uv(uv)
	local_yaw = yaw
	link_name = &""
	link_progress = 0.0


func enter_traversal(link: VehicleTraversalLink, forward: bool) -> void:
	state = GameEnums.CrewState.TRAVERSING
	link_name = link.link_name
	link_forward = forward
	link_progress = 0.0
	# Remember where we are heading so the arrival can be resolved without
	# re-deriving the direction.
	var destination: VehicleAttachmentPoint = link.to_point if forward else link.from_point
	point_name = destination.point_name if destination != null else &""


func enter_dismounted(transform: Transform3D) -> void:
	state = GameEnums.CrewState.DISMOUNTED
	world_transform = transform
	point_name = &""
	surface_name = &""
	link_name = &""
	link_progress = 0.0


# ---------------------------------------------------------------------------
# Replication payloads
# ---------------------------------------------------------------------------

## Full discrete state, sent reliably whenever it changes. Continuous surface
## motion is streamed separately and unreliably.
func to_state_dict() -> Dictionary:
	return {
		"st": state,
		"pt": String(point_name),
		"sf": String(surface_name),
		"uv": surface_uv,
		"yw": local_yaw,
		"lk": String(link_name),
		"lf": link_forward,
		"wt": world_transform,
	}


func apply_state_dict(data: Dictionary) -> void:
	state = clampi(int(data.get("st", GameEnums.CrewState.UNASSIGNED)),
		GameEnums.CrewState.UNASSIGNED, GameEnums.CrewState.DEAD)
	point_name = StringName(String(data.get("pt", "")))
	surface_name = StringName(String(data.get("sf", "")))
	local_yaw = float(data.get("yw", 0.0))
	link_name = StringName(String(data.get("lk", "")))
	link_forward = bool(data.get("lf", true))

	# Structured values are type-checked rather than assigned straight through:
	# a Dictionary from the network can hold anything, and assigning a mistyped
	# Variant into a typed field raises at runtime.
	var uv_value: Variant = data.get("uv", Vector2.ZERO)
	surface_uv = uv_value if uv_value is Vector2 else Vector2.ZERO
	var transform_value: Variant = data.get("wt", Transform3D.IDENTITY)
	world_transform = transform_value if transform_value is Transform3D else Transform3D.IDENTITY
	# A received traversal always restarts from the beginning: the sender only
	# announces a traversal at the moment it starts, and both peers advance the
	# same deterministic curve from there.
	if state == GameEnums.CrewState.TRAVERSING:
		link_progress = 0.0
