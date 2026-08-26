class_name CrewController
extends Node

## The crew state machine: how a player sits, walks the vehicle, and climbs
## between positions on it.
##
## Drives a CrewAttachment (the "where am I on the vehicle" maths) from input,
## and replicates the result. Attached to a PlayerCharacter as a child node so
## that it has a stable network path for its RPCs.
##
## ============================================================================
## REPLICATION
## ============================================================================
##
## Falls out of the attachment representation, and is unusually cheap because of
## it:
##
##   SEATED     nothing continuous. A seat name plus an aim yaw fully describes
##              the crew member, so this costs one reliable packet on entry.
##   TRAVERSING nothing continuous. The curve is a pure function of (link,
##              direction, progress), so peers are told the traversal *started*
##              and then each advances the identical curve locally. This is both
##              cheaper and smoother than streaming positions would be.
##   ON_SURFACE a Vector2 and a float at NetConfig.SNAPSHOT_HZ.
##
## Authority: a crew member's own client owns their movement, for the same
## responsiveness reason the driver owns the chassis. It is safe because the
## surface clamp bounds it — the worst a modified client can do is stand
## somewhere on the vehicle it was already allowed to stand.
##
## Seats are the exception and are server-authoritative, because they are
## exclusive: two players pressing interact on the same seat in the same frame
## must not both believe they got it. So a traversal *toward a seat* asks the
## server first and only begins once the claim is confirmed. A traversal toward
## a surface, which nothing else can be holding, begins immediately.
##
## ============================================================================
## PROCESS ORDER
## ============================================================================
##
## This node has no _physics_process of its own. PlayerCharacter calls
## simulate() explicitly after it has gathered input and updated the camera, so
## the "input -> crew -> transform" order is stated in code rather than inherited
## from tree order.

## Emitted on this peer when the crew state changes.
signal state_changed(state: int)

## Emitted when the set of offered interactions changes, with the prompt for the
## currently selected one ("" when there is nothing to do).
signal prompt_changed(text: String)

## One thing the crew member could do right now.
class Interaction extends RefCounted:
	enum Kind { TRAVERSE, TAKE_SEAT, DISMOUNT, BOARD }
	var kind: int = Kind.TRAVERSE
	var link: VehicleTraversalLink = null
	var point: VehicleAttachmentPoint = null
	var prompt: String = ""
	var distance: float = 0.0

@export_group("Movement")
## Walking speed on vehicle surfaces, in metres per second. Deliberately slow:
## the vehicle is small, and a crew member sprinting across a roof at 6 m/s
## reads as sliding rather than walking.
@export_range(0.5, 6.0, 0.1) var surface_walk_speed: float = 2.1

## How strongly vehicle acceleration shoves a crew member around while they are
## standing on an exposed surface, in metres per (m/s^2).
@export_range(0.0, 0.4, 0.005) var stability_shove: float = 0.055

## Minimum fraction of walk speed retained under heavy acceleration.
@export_range(0.1, 1.0, 0.05) var min_stability_scale: float = 0.35

@export_group("Interaction")
## How often the interaction scan runs, in seconds. Once every few frames is
## plenty for a prompt and keeps a per-frame loop over every attachment point
## off the profile.
@export_range(0.02, 0.5, 0.01) var scan_interval: float = 0.1

## How long a pending seat claim waits for the server before giving up.
@export_range(0.2, 5.0, 0.1) var seat_claim_timeout: float = 1.5

## Where this crew member is on the vehicle, and the maths to place them.
var attachment: CrewAttachment = CrewAttachment.new()

## Owning peer. Set by the spawner; never changes for the life of the node.
var peer_id: int = 0
var role: int = GameEnums.CrewRole.NONE

## Written by PlayerCharacter each frame before simulate().
## x is strafe (+right), y is forward (+forward).
var move_input: Vector2 = Vector2.ZERO
## World-space yaw the player is looking along.
var aim_yaw: float = 0.0
## Set false while a menu has focus.
var input_enabled: bool = true

var _body: CharacterBody3D = null
var _vehicle: VehicleController = null
var _rig: VehicleRig = null

var _interactions: Array = []
var _selected_interaction: int = 0
var _scan_accumulator: float = 0.0
var _last_prompt: String = ""

var _pose_accumulator: float = 0.0
var _pose_sequence: int = 0

## Remote peers damp toward the last streamed surface pose rather than snapping
## to each packet.
var _remote_uv: Vector2 = Vector2.ZERO
var _remote_yaw: float = 0.0
var _remote_world_position: Vector3 = Vector3.ZERO
var _has_remote_pose: bool = false

## A seat claim awaiting the server's answer.
var _pending_seat: StringName = &""
var _pending_link: VehicleTraversalLink = null
var _pending_timer: float = 0.0


## Called by the spawner immediately after instantiation.
func setup(body: CharacterBody3D, owning_peer: int, crew_role: int) -> void:
	_body = body
	peer_id = owning_peer
	role = crew_role


## Bind to the vehicle this crew member rides. Safe to call again if the crew
## transfers to a different vehicle later.
func attach_to_vehicle(vehicle: VehicleController) -> void:
	if _rig != null and _rig.occupancy_changed.is_connected(_on_occupancy_changed):
		_rig.occupancy_changed.disconnect(_on_occupancy_changed)

	_vehicle = vehicle
	_rig = vehicle.rig() if vehicle != null else null
	attachment.bind_vehicle(vehicle)

	if _rig != null:
		_rig.occupancy_changed.connect(_on_occupancy_changed)
		# The server may have seated this crew member before the node existed,
		# so adopt whatever seat is already recorded rather than waiting for the
		# next occupancy broadcast.
		var existing: VehicleAttachmentPoint = _rig.point_occupied_by(peer_id)
		if existing != null and attachment.state == GameEnums.CrewState.UNASSIGNED:
			_enter_seat(existing, false)


func is_local() -> bool:
	return peer_id == multiplayer.get_unique_id()


func vehicle() -> VehicleController:
	return _vehicle


func state() -> int:
	return attachment.state


func is_attached() -> bool:
	return attachment.is_attached()


## True while the crew member cannot act: mid-climb, down, or dead.
func is_action_locked() -> bool:
	return attachment.state == GameEnums.CrewState.TRAVERSING \
		or attachment.state == GameEnums.CrewState.DOWNED \
		or attachment.state == GameEnums.CrewState.DEAD


func is_driving() -> bool:
	return _rig != null and _rig.driver_peer_id == peer_id \
		and attachment.state == GameEnums.CrewState.SEATED


# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------

## Advance one physics step. Called by PlayerCharacter.
func simulate(delta: float) -> void:
	if attachment.state == GameEnums.CrewState.TRAVERSING:
		# Deterministic on every peer: same link, same curve, same duration.
		_advance_traversal(delta)

	if is_local():
		_simulate_local(delta)
	else:
		_apply_remote_pose(delta)

	if attachment.is_attached() and _body != null:
		_body.global_transform = attachment.compose_world_transform()


func _simulate_local(delta: float) -> void:
	_tick_pending_seat(delta)

	match attachment.state:
		GameEnums.CrewState.ON_SURFACE:
			_simulate_surface(delta)
		GameEnums.CrewState.SEATED:
			_simulate_seated(delta)
		_:
			pass

	_scan_accumulator += delta
	if _scan_accumulator >= scan_interval:
		_scan_accumulator = 0.0
		_rescan_interactions()

	_stream_surface_pose(delta)
	_stream_world_pose(delta)


func _simulate_seated(_delta: float) -> void:
	if not input_enabled:
		return
	# A seated crew member still turns to look: aim is world-anchored, and the
	# local yaw is whatever keeps them facing that way as the vehicle rotates
	# underneath them.
	attachment.local_yaw = _world_yaw_to_rig(aim_yaw)


func _simulate_surface(delta: float) -> void:
	var surface: VehicleSurface = attachment.current_surface()
	if surface == null:
		return

	var uv: Vector2 = attachment.surface_uv

	if input_enabled and move_input.length_squared() > 0.0001:
		var direction: Vector2 = _world_move_to_surface(surface, move_input)
		var stability: float = _stability_scale(surface)
		uv += direction * surface_walk_speed * surface.walk_speed_scale * stability * delta

	uv += _stability_shove(surface, delta)

	# Hard clamp. Vehicle motion can push a crew member toward the edge and make
	# footing feel precarious, but it can never throw them off: the design
	# requirement is that attachment does not fail, so the shove is a movement
	# tax, not an ejection mechanic. Being thrown clear is a deliberate future
	# mechanic (an explosion, a low bridge), triggered explicitly.
	attachment.surface_uv = surface.clamp_uv(uv)

	if input_enabled:
		attachment.local_yaw = _world_yaw_to_rig(aim_yaw)


## Convert camera-relative movement input into a direction on the surface plane.
func _world_move_to_surface(surface: VehicleSurface, input: Vector2) -> Vector2:
	var forward: Vector3 = Vector3(-sin(aim_yaw), 0.0, -cos(aim_yaw))
	var right: Vector3 = Vector3(cos(aim_yaw), 0.0, -sin(aim_yaw))
	var world_direction: Vector3 = right * input.x + forward * input.y

	var frame: Transform3D = _vehicle.crew_frame_transform()
	var rig_direction: Vector3 = frame.basis.inverse() * world_direction
	var surface_direction: Vector3 = surface.rig_local_transform.basis.inverse() * rig_direction

	var planar: Vector2 = Vector2(surface_direction.x, surface_direction.z)
	if planar.length_squared() < 0.000001:
		return Vector2.ZERO
	return planar.normalized() * minf(input.length(), 1.0)


## Slow the crew member down under heavy acceleration, scaled by how exposed the
## surface is. Walking the roof during hard cornering should be a decision.
func _stability_scale(surface: VehicleSurface) -> float:
	if _vehicle == null or surface.is_interior:
		return 1.0
	var g_force: float = _vehicle.crew_frame_acceleration().length() / 9.8
	return clampf(1.0 - g_force * 0.22 * surface.exposure, min_stability_scale, 1.0)


## Inertial shove: the vehicle accelerates, the crew member does not, so they
## slide the other way.
func _stability_shove(surface: VehicleSurface, delta: float) -> Vector2:
	if _vehicle == null or surface.is_interior or stability_shove <= 0.0:
		return Vector2.ZERO
	var acceleration: Vector3 = _vehicle.crew_frame_acceleration()
	var local: Vector3 = surface.rig_local_transform.basis.inverse() * acceleration
	return Vector2(-local.x, -local.z) * stability_shove * surface.exposure * delta


## Convert a world-space yaw into the equivalent yaw within the crew frame.
func _world_yaw_to_rig(world_yaw: float) -> float:
	if _vehicle == null:
		return world_yaw
	var frame: Transform3D = _vehicle.crew_frame_transform()
	var frame_yaw: float = MathUtil.yaw_from_direction(-frame.basis.z)
	return wrapf(world_yaw - frame_yaw, -PI, PI)


# ---------------------------------------------------------------------------
# Traversal
# ---------------------------------------------------------------------------

func _advance_traversal(delta: float) -> void:
	var link: VehicleTraversalLink = attachment.current_link()
	if link == null:
		# The link vanished (vehicle swapped, bad data). Fail safe rather than
		# leaving the crew member stuck in a state with no way out.
		GameLog.warn("crew", "traversal link '%s' missing; recovering" % attachment.link_name)
		_recover_to_nearest_position()
		return

	attachment.link_progress += delta / maxf(link.duration, 0.01)
	if attachment.link_progress < 1.0:
		return

	attachment.link_progress = 1.0
	var destination: VehicleAttachmentPoint = link.to_point if attachment.link_forward else link.from_point
	if destination == null:
		_recover_to_nearest_position()
		return
	_arrive_at(destination)


func _arrive_at(point: VehicleAttachmentPoint) -> void:
	if point.is_surface_anchor():
		var surface: VehicleSurface = point.surface()
		if surface != null:
			var uv: Vector2 = surface.rig_to_uv(point.rig_local_transform.origin)
			_enter_surface(surface, uv, point.rig_local_yaw, is_local())
			return
		GameLog.warn("crew", "surface anchor '%s' has no surface" % point.point_name)
		_recover_to_nearest_position()
		return

	# Seats and everything else: settle onto the point itself. The claim was
	# already confirmed before the traversal started.
	_enter_seat(point, is_local())


## Last-resort recovery: put the crew member somewhere valid on the vehicle.
## Being stuck in an unresolvable state is far worse than an inelegant snap.
func _recover_to_nearest_position() -> void:
	if _rig == null:
		return
	var held: VehicleAttachmentPoint = _rig.point_occupied_by(peer_id)
	if held != null:
		_enter_seat(held, is_local())
		return
	if not _rig.surfaces.is_empty():
		var names: Array = _rig.surfaces.keys()
		names.sort()
		var surface: VehicleSurface = _rig.surfaces[names[0]]
		_enter_surface(surface, Vector2.ZERO, 0.0, is_local())
		return
	if is_local():
		GameLog.error("crew", "no valid position to recover to on this vehicle")


# ---------------------------------------------------------------------------
# State entry
# ---------------------------------------------------------------------------

func _enter_seat(point: VehicleAttachmentPoint, replicate: bool) -> void:
	attachment.enter_seat(point)
	_after_state_change(replicate)


func _enter_surface(surface: VehicleSurface, uv: Vector2, yaw: float, replicate: bool) -> void:
	attachment.enter_surface(surface, uv, yaw)
	_remote_uv = attachment.surface_uv
	_remote_yaw = yaw
	_has_remote_pose = true
	_after_state_change(replicate)


func _begin_traversal(link: VehicleTraversalLink, forward: bool, replicate: bool) -> void:
	attachment.enter_traversal(link, forward)
	_after_state_change(replicate)


func _after_state_change(replicate: bool) -> void:
	state_changed.emit(attachment.state)
	if is_local():
		GameEvents.local_crew_state_changed.emit(attachment.state)
		_rescan_interactions()
	if replicate and is_local() and NetworkManager.is_session_active():
		_rpc_crew_state.rpc(attachment.to_state_dict())


# ---------------------------------------------------------------------------
# Interactions
# ---------------------------------------------------------------------------

## The interaction the player would trigger right now, or null.
func selected_interaction() -> Interaction:
	if _interactions.is_empty():
		return null
	return _interactions[clampi(_selected_interaction, 0, _interactions.size() - 1)]


## Cycle to the next offered interaction.
func cycle_interaction() -> void:
	if _interactions.size() <= 1:
		return
	_selected_interaction = (_selected_interaction + 1) % _interactions.size()
	_emit_prompt()


## Trigger the selected interaction. Called by PlayerCharacter on the interact
## input.
func activate_interaction() -> void:
	if is_action_locked() or not input_enabled:
		return
	var choice: Interaction = selected_interaction()
	if choice == null:
		return
	match choice.kind:
		Interaction.Kind.TRAVERSE:
			_try_traverse(choice.link)
		Interaction.Kind.TAKE_SEAT:
			_try_take_seat(choice.point, null)
		Interaction.Kind.DISMOUNT:
			_try_dismount(choice.point)
		Interaction.Kind.BOARD:
			_try_board(choice.point)


func _try_traverse(link: VehicleTraversalLink) -> void:
	if link == null or _vehicle == null:
		return
	if not link.is_allowed_at_speed(_vehicle.speed_kph()):
		GameEvents.interaction_prompt_changed.emit("Too fast to climb")
		return

	var origin: StringName = _current_anchor_name()
	if not link.can_start_at(origin):
		return
	var forward: bool = link.is_forward_from(origin)
	var destination: VehicleAttachmentPoint = link.destination_from(origin)
	if destination == null:
		return

	# Exclusive destinations need the server's blessing before we commit to the
	# climb; shared surfaces do not.
	if destination.exclusive and destination.point_type != GameEnums.AttachmentType.SURFACE_ANCHOR:
		_try_take_seat(destination, link)
		return

	_release_current_seat()
	_begin_traversal(link, forward, true)


func _try_take_seat(point: VehicleAttachmentPoint, via_link: VehicleTraversalLink) -> void:
	if point == null or _rig == null:
		return
	if not point.is_free() and not point.is_occupied_by(peer_id):
		GameEvents.interaction_prompt_changed.emit("Occupied")
		return
	if not point.accepts_role(role):
		GameEvents.interaction_prompt_changed.emit("Not your station")
		return

	_pending_seat = point.point_name
	_pending_link = via_link
	_pending_timer = seat_claim_timeout
	_rig.request_occupy(point.point_name)


func _tick_pending_seat(delta: float) -> void:
	if String(_pending_seat).is_empty():
		return
	_pending_timer -= delta
	if _pending_timer > 0.0:
		return
	GameLog.warn("crew", "seat claim '%s' timed out" % _pending_seat)
	_pending_seat = &""
	_pending_link = null


func _try_dismount(point: VehicleAttachmentPoint) -> void:
	if _vehicle == null or point == null:
		return
	# Stepping off a vehicle doing 80 km/h is not a dismount, it is a fatality.
	if _vehicle.speed_kph() > 12.0:
		GameEvents.interaction_prompt_changed.emit("Too fast to dismount")
		return
	_release_current_seat()
	var exit_transform: Transform3D = _vehicle.crew_frame_transform() * point.rig_local_transform
	attachment.enter_dismounted(exit_transform)
	if _body != null:
		_body.global_transform = exit_transform
	_after_state_change(true)


## Step out of the current seat onto the nearest surface it connects to.
##
## A convenience over the contextual interact key: a crew member who needs to get
## out *now* should not have to cycle a prompt list to find the way out.
func leave_seat() -> void:
	if attachment.state != GameEnums.CrewState.SEATED or _rig == null:
		return
	if is_action_locked() or not input_enabled:
		return

	for link: VehicleTraversalLink in _rig.links_from(attachment.point_name):
		var destination: VehicleAttachmentPoint = link.destination_from(attachment.point_name)
		if destination == null or not destination.is_surface_anchor():
			continue
		if _vehicle != null and not link.is_allowed_at_speed(_vehicle.speed_kph()):
			continue
		_release_current_seat()
		_begin_traversal(link, link.is_forward_from(attachment.point_name), true)
		return

	GameEvents.interaction_prompt_changed.emit("No way out from here")


## Climb aboard from the ground through an entry point.
func _try_board(point: VehicleAttachmentPoint) -> void:
	if point == null or _vehicle == null:
		return
	if _vehicle.speed_kph() > 12.0:
		GameEvents.interaction_prompt_changed.emit("Too fast to board")
		return
	var surface: VehicleSurface = point.surface()
	if surface == null:
		GameLog.warn("crew", "entry point '%s' has no surface to board onto" % point.point_name)
		return
	# Land at the entry point's position projected onto the surface, clamped
	# inside it — an entry point sits at the door, which is by design outside the
	# walkable floor.
	var uv: Vector2 = surface.clamp_uv(surface.rig_to_uv(point.rig_local_transform.origin))
	_enter_surface(surface, uv, point.rig_local_yaw, true)


func _release_current_seat() -> void:
	if _rig == null:
		return
	var held: VehicleAttachmentPoint = _rig.point_occupied_by(peer_id)
	if held != null:
		_rig.request_release()


## The attachment point traversals are measured from. While seated that is the
## seat; while on a surface it is whichever anchor the crew member is standing
## closest to.
func _current_anchor_name() -> StringName:
	if attachment.state == GameEnums.CrewState.SEATED:
		return attachment.point_name
	if attachment.state != GameEnums.CrewState.ON_SURFACE or _rig == null:
		return &""

	var here: Vector3 = attachment.rig_local_position()
	var best_name: StringName = &""
	var best_distance: float = INF
	for point: VehicleAttachmentPoint in _rig.points.values():
		if not point.is_surface_anchor():
			continue
		var distance: float = here.distance_to(point.rig_local_transform.origin)
		if distance < best_distance and distance <= point.interaction_radius:
			best_distance = distance
			best_name = point.point_name
	return best_name


func _rescan_interactions() -> void:
	if not is_local():
		return
	var previous_prompt: String = _last_prompt
	_interactions.clear()

	if _rig != null and not is_action_locked():
		if attachment.state == GameEnums.CrewState.DISMOUNTED:
			_scan_boarding_interactions()
		else:
			_scan_attached_interactions()

	if _selected_interaction >= _interactions.size():
		_selected_interaction = 0
	_emit_prompt()
	if _last_prompt != previous_prompt:
		prompt_changed.emit(_last_prompt)


## What a crew member riding the vehicle can do: climb somewhere, take a seat,
## or step off. Everything is measured in vehicle-local space, so it works
## identically at a standstill and at 100 km/h.
func _scan_attached_interactions() -> void:
	var here: Vector3 = attachment.rig_local_position()
	var anchor: StringName = _current_anchor_name()

	# Traversals available from wherever we are standing or sitting.
	if not String(anchor).is_empty():
		for link: VehicleTraversalLink in _rig.links_from(anchor):
			var destination: VehicleAttachmentPoint = link.destination_from(anchor)
			if destination == null:
				continue
			if destination.exclusive and not destination.is_free() \
					and not destination.is_occupied_by(peer_id):
				continue
			var entry := Interaction.new()
			entry.kind = Interaction.Kind.TRAVERSE
			entry.link = link
			entry.point = destination
			entry.prompt = link.effective_prompt()
			entry.distance = 0.0
			_interactions.append(entry)

	# Points close enough to interact with directly.
	for point: VehicleAttachmentPoint in _rig.points.values():
		var distance: float = here.distance_to(point.rig_local_transform.origin)
		if distance > point.interaction_radius:
			continue
		if point.point_name == attachment.point_name:
			continue
		if point.is_seat() and point.is_free() and point.accepts_role(role):
			var seat_entry := Interaction.new()
			seat_entry.kind = Interaction.Kind.TAKE_SEAT
			seat_entry.point = point
			seat_entry.prompt = point.effective_prompt()
			seat_entry.distance = distance
			_interactions.append(seat_entry)
		elif point.point_type == GameEnums.AttachmentType.EXIT:
			var exit_entry := Interaction.new()
			exit_entry.kind = Interaction.Kind.DISMOUNT
			exit_entry.point = point
			exit_entry.prompt = point.effective_prompt()
			exit_entry.distance = distance
			_interactions.append(exit_entry)


## What a crew member standing on the ground can do: board through a door.
##
## Distances here are measured from the body's real world position projected into
## the vehicle's frame, because a dismounted crew member has no vehicle-local
## position of their own — and because the vehicle may well be driving away.
func _scan_boarding_interactions() -> void:
	if _vehicle == null or _body == null:
		return
	var here: Vector3 = _vehicle.crew_frame_transform().affine_inverse() * _body.global_position
	for point: VehicleAttachmentPoint in _rig.points.values():
		if point.point_type != GameEnums.AttachmentType.ENTRY:
			continue
		var distance: float = here.distance_to(point.rig_local_transform.origin)
		if distance > point.interaction_radius:
			continue
		var entry := Interaction.new()
		entry.kind = Interaction.Kind.BOARD
		entry.point = point
		entry.prompt = point.effective_prompt()
		entry.distance = distance
		_interactions.append(entry)


func _emit_prompt() -> void:
	var choice: Interaction = selected_interaction()
	var text: String = ""
	if choice != null:
		text = choice.prompt
		if _interactions.size() > 1:
			text += "   [Q] %d/%d" % [_selected_interaction + 1, _interactions.size()]
	if text == _last_prompt:
		return
	_last_prompt = text
	GameEvents.interaction_prompt_changed.emit(text)


# ---------------------------------------------------------------------------
# Occupancy callbacks
# ---------------------------------------------------------------------------

func _on_occupancy_changed(point_name: StringName, occupant: int) -> void:
	if occupant != peer_id:
		# Somebody else took a seat: our offered interactions may have gone
		# stale, so refresh the prompt.
		if is_local():
			_rescan_interactions()
		return

	# The server confirmed a claim for us.
	var point: VehicleAttachmentPoint = _rig.find_point(point_name)
	if point == null:
		return

	if is_local() and _pending_seat == point_name:
		var link: VehicleTraversalLink = _pending_link
		_pending_seat = &""
		_pending_link = null
		if link != null:
			var origin: StringName = _current_anchor_name()
			if link.can_start_at(origin):
				_begin_traversal(link, link.is_forward_from(origin), true)
				return
		_enter_seat(point, true)
		return

	# Initial seating at match start, or a server-driven move.
	if attachment.state == GameEnums.CrewState.UNASSIGNED:
		_enter_seat(point, is_local())


# ---------------------------------------------------------------------------
# Replication
# ---------------------------------------------------------------------------

func _stream_surface_pose(delta: float) -> void:
	if attachment.state != GameEnums.CrewState.ON_SURFACE:
		return
	if not NetworkManager.is_session_active() or multiplayer.get_peers().is_empty():
		return
	_pose_accumulator += delta
	if _pose_accumulator < NetConfig.SNAPSHOT_INTERVAL:
		return
	_pose_accumulator -= NetConfig.SNAPSHOT_INTERVAL
	_pose_sequence += 1
	_rpc_surface_pose.rpc(_pose_sequence, attachment.surface_uv, attachment.local_yaw)


## Dismounted crew are ordinary characters in the world, so unlike the attached
## states there is no vehicle transform doing the work and their world position
## has to be streamed directly.
func _stream_world_pose(delta: float) -> void:
	if attachment.state != GameEnums.CrewState.DISMOUNTED or _body == null:
		return
	if not NetworkManager.is_session_active() or multiplayer.get_peers().is_empty():
		return
	_pose_accumulator += delta
	if _pose_accumulator < NetConfig.SNAPSHOT_INTERVAL:
		return
	_pose_accumulator -= NetConfig.SNAPSHOT_INTERVAL
	_pose_sequence += 1
	attachment.world_transform = _body.global_transform
	_rpc_world_pose.rpc(_pose_sequence, _body.global_position, _body.rotation.y)


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_world_pose(sequence: int, position_value: Vector3, yaw: float) -> void:
	if not NetGuard.is_from_authority_of(self):
		return
	if sequence <= _pose_sequence and _has_remote_pose:
		return
	_pose_sequence = sequence
	_remote_world_position = position_value
	_remote_yaw = yaw
	_has_remote_pose = true


@rpc("any_peer", "call_remote", "reliable")
func _rpc_crew_state(data: Dictionary) -> void:
	if not NetGuard.is_from_authority_of(self):
		return
	attachment.apply_state_dict(data)
	if attachment.state == GameEnums.CrewState.ON_SURFACE:
		_remote_uv = attachment.surface_uv
		_remote_yaw = attachment.local_yaw
		_has_remote_pose = true
	if attachment.state == GameEnums.CrewState.DISMOUNTED and _body != null:
		_body.global_transform = attachment.world_transform
	state_changed.emit(attachment.state)


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_surface_pose(sequence: int, uv: Vector2, yaw: float) -> void:
	if not NetGuard.is_from_authority_of(self):
		return
	# Sequence numbers discard reordered packets; without this a late packet
	# would drag the remote crew member briefly backwards.
	if sequence <= _pose_sequence and _has_remote_pose:
		return
	_pose_sequence = sequence
	_remote_uv = uv
	_remote_yaw = yaw
	_has_remote_pose = true


## Remote crew members ease toward the last streamed pose. A crew member walks
## at ~2 m/s, so a short damp is smoother than a snapshot buffer's fixed delay
## and the position error it hides is centimetres.
func _apply_remote_pose(delta: float) -> void:
	if not _has_remote_pose:
		return

	if attachment.state == GameEnums.CrewState.ON_SURFACE:
		var surface: VehicleSurface = attachment.current_surface()
		if surface == null:
			return
		attachment.surface_uv = surface.clamp_uv(
			MathUtil.damp_vector2(attachment.surface_uv, _remote_uv, 0.06, delta))
		attachment.local_yaw = MathUtil.damp_angle(attachment.local_yaw, _remote_yaw, 0.06, delta)
		return

	if attachment.state == GameEnums.CrewState.DISMOUNTED and _body != null:
		# Slightly longer damp than the surface case: a dismounted crew member
		# moves twice as fast, so the same half-life would read as rubber-banding.
		var position_value: Vector3 = MathUtil.damp_vector3(
			_body.global_position, _remote_world_position, 0.09, delta)
		var yaw: float = MathUtil.damp_angle(_body.rotation.y, _remote_yaw, 0.09, delta)
		_body.global_position = position_value
		_body.rotation = Vector3(0.0, yaw, 0.0)
		attachment.world_transform = _body.global_transform
