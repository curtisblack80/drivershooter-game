class_name VehicleRig
extends Node3D

## The vehicle's crew frame and the registry of everything crew members can
## stand on, sit in, climb along or repair.
##
## Two jobs, both central:
##
## 1. **Reference frame.** Every crew member's position is stored as an offset
##    relative to this node, and recomposed into world space each frame as
##    `rig.global_transform * local_offset`. This node is therefore the single
##    definition of "attached to the vehicle".
##
## 2. **Registry and seat authority.** It scans the vehicle scene once for
##    attachment points, surfaces and traversal links, binds them, and owns seat
##    occupancy. Occupancy is server-authoritative: clients ask, the server
##    decides, and the decision is broadcast. Without that, two players pressing
##    the interact key on the same seat in the same frame would each believe they
##    got it.
##
## This node's multiplayer authority stays with the server permanently, even
## though the *vehicle body's* physics authority follows the driver. Those are
## deliberately separate: who simulates the chassis is a latency decision, who
## decides which seat you are in is a fairness decision.

## A seat's occupant changed. `peer_id` is 0 when the seat became free.
signal occupancy_changed(point_name: StringName, peer_id: int)

## The crew member in the driver seat changed. 0 when nobody is driving.
signal driver_changed(peer_id: int)

## StringName -> VehicleAttachmentPoint
var points: Dictionary = {}
## StringName -> VehicleSurface
var surfaces: Dictionary = {}
## Array of VehicleTraversalLink
var links: Array = []
## StringName (point name) -> Array of VehicleTraversalLink touching it
var _links_by_point: Dictionary = {}

var driver_seat: VehicleAttachmentPoint = null
var driver_peer_id: int = 0


func _ready() -> void:
	_scan()


# ---------------------------------------------------------------------------
# Scanning and binding
# ---------------------------------------------------------------------------

## Walk the vehicle scene and register every attachment point, surface and link.
##
## Surfaces are bound before points (a Surface Anchor point resolves a surface),
## and links last (they read both endpoints' cached crew-frame poses). Getting
## this order wrong produces links anchored at the origin, which looks like a
## physics bug and is not one — hence doing it explicitly in three passes rather
## than binding as we walk.
func _scan() -> void:
	points.clear()
	surfaces.clear()
	links.clear()
	_links_by_point.clear()
	driver_seat = null

	var vehicle_root: Node = get_parent() if get_parent() != null else self
	var found_points: Array = []
	var found_surfaces: Array = []
	var found_links: Array = []
	_collect(vehicle_root, found_points, found_surfaces, found_links)

	for surface: VehicleSurface in found_surfaces:
		surface.bind_to_rig(self)
		if surfaces.has(surface.surface_name):
			GameLog.warn("vehicle", "duplicate surface name '%s'; the later one wins" % surface.surface_name)
		surfaces[surface.surface_name] = surface

	for point: VehicleAttachmentPoint in found_points:
		point.bind_to_rig(self)
		if points.has(point.point_name):
			GameLog.warn("vehicle", "duplicate attachment point name '%s'; the later one wins" % point.point_name)
		points[point.point_name] = point
		if point.is_driver_seat:
			if driver_seat != null:
				GameLog.warn("vehicle", "more than one driver seat; using '%s'" % point.point_name)
			driver_seat = point

	for link: VehicleTraversalLink in found_links:
		link.bind_to_rig(self)
		if not link.is_resolved():
			continue
		links.append(link)
		_register_link(link.from_point.point_name, link)
		if link.bidirectional:
			_register_link(link.to_point.point_name, link)

	if driver_seat == null:
		GameLog.warn("vehicle", "no attachment point is flagged is_driver_seat; this vehicle cannot be driven")

	GameLog.info("vehicle", "rig scanned: %d points, %d surfaces, %d links"
		% [points.size(), surfaces.size(), links.size()])


func _collect(node: Node, out_points: Array, out_surfaces: Array, out_links: Array) -> void:
	if node is VehicleAttachmentPoint:
		out_points.append(node)
	elif node is VehicleSurface:
		out_surfaces.append(node)
	elif node is VehicleTraversalLink:
		out_links.append(node)
	for child in node.get_children():
		_collect(child, out_points, out_surfaces, out_links)


func _register_link(point_name: StringName, link: VehicleTraversalLink) -> void:
	if not _links_by_point.has(point_name):
		_links_by_point[point_name] = []
	(_links_by_point[point_name] as Array).append(link)


# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------

func find_point(point_name: StringName) -> VehicleAttachmentPoint:
	return points.get(point_name, null) as VehicleAttachmentPoint


func find_surface(surface_name: StringName) -> VehicleSurface:
	return surfaces.get(surface_name, null) as VehicleSurface


## Every link that can be entered from `point_name`.
func links_from(point_name: StringName) -> Array:
	var candidates: Array = _links_by_point.get(point_name, [])
	var usable: Array = []
	for link: VehicleTraversalLink in candidates:
		if link.can_start_at(point_name):
			usable.append(link)
	return usable


## The attachment point a peer currently occupies, or null.
func point_occupied_by(peer_id: int) -> VehicleAttachmentPoint:
	if peer_id == 0:
		return null
	for point: VehicleAttachmentPoint in points.values():
		if point.occupant_peer_id == peer_id:
			return point
	return null


## Seats that a crew member with `role` could take right now, in a stable order.
func free_seats_for(role: int) -> Array:
	var names: Array = points.keys()
	names.sort()
	var result: Array = []
	for point_name: StringName in names:
		var point: VehicleAttachmentPoint = points[point_name]
		if point.is_seat() and point.is_free() and point.accepts_role(role):
			result.append(point)
	return result


# ---------------------------------------------------------------------------
# Occupancy (server-authoritative)
# ---------------------------------------------------------------------------

## Server-only. Seat the whole crew deterministically at match start.
##
## Drivers get the driver seat; everyone else fills the remaining seats in crew
## index order. This runs once on the server and is broadcast, so every peer ends
## up with the same seating — recomputing it independently per peer would be a
## desync waiting for the first tie-break to differ.
func server_assign_initial_seats(roster: Array[PlayerInfo]) -> void:
	if not multiplayer.is_server():
		return

	for point: VehicleAttachmentPoint in points.values():
		point.occupant_peer_id = 0

	var unseated: Array[PlayerInfo] = []
	for info: PlayerInfo in roster:
		if info.role == GameEnums.CrewRole.DRIVER and driver_seat != null and driver_seat.is_free():
			driver_seat.occupant_peer_id = info.peer_id
		else:
			unseated.append(info)

	# Fill remaining seats in a deterministic order.
	var seat_names: Array = points.keys()
	seat_names.sort()
	for info: PlayerInfo in unseated:
		var seated: bool = false
		for seat_name: StringName in seat_names:
			var seat: VehicleAttachmentPoint = points[seat_name]
			if seat.is_seat() and seat.is_free() and seat.accepts_role(info.role):
				seat.occupant_peer_id = info.peer_id
				seated = true
				break
		if not seated:
			GameLog.warn("vehicle", "no free seat for peer %d (role %s)"
				% [info.peer_id, GameEnums.role_name(info.role)])

	_broadcast_full_occupancy()


func _broadcast_full_occupancy() -> void:
	if not multiplayer.is_server():
		return
	var payload: Dictionary = {}
	for point_name: StringName in points.keys():
		var point: VehicleAttachmentPoint = points[point_name]
		if point.occupant_peer_id != 0:
			payload[String(point_name)] = point.occupant_peer_id
	_rpc_sync_occupancy.rpc(payload)


@rpc("authority", "call_local", "reliable")
func _rpc_sync_occupancy(payload: Dictionary) -> void:
	for point: VehicleAttachmentPoint in points.values():
		point.occupant_peer_id = 0
	for key: Variant in payload.keys():
		var point: VehicleAttachmentPoint = find_point(StringName(String(key)))
		if point != null:
			point.occupant_peer_id = int(payload[key])
	for point_name: StringName in points.keys():
		var point: VehicleAttachmentPoint = points[point_name]
		occupancy_changed.emit(point_name, point.occupant_peer_id)
		GameEvents.seat_occupancy_changed.emit(point_name, point.occupant_peer_id)
	_refresh_driver()


## Ask the server for a point. The reply arrives as an occupancy broadcast; the
## caller must not assume success.
func request_occupy(point_name: StringName) -> void:
	_rpc_request_occupy.rpc_id(1, String(point_name))


## Ask the server to release whatever point this peer holds.
func request_release() -> void:
	_rpc_request_release.rpc_id(1)


@rpc("any_peer", "call_local", "reliable")
func _rpc_request_occupy(point_name_text: String) -> void:
	if not multiplayer.is_server():
		return
	var requester: int = NetGuard.effective_sender(self)
	var point: VehicleAttachmentPoint = find_point(StringName(point_name_text))
	if point == null:
		return

	var info: PlayerInfo = NetworkManager.get_player(requester)
	if info == null:
		return
	if not point.accepts_role(info.role):
		GameLog.debug("vehicle", "peer %d refused '%s': role not accepted" % [requester, point_name_text])
		return
	if point.exclusive and point.occupant_peer_id != 0 and point.occupant_peer_id != requester:
		GameLog.debug("vehicle", "peer %d refused '%s': already held by %d"
			% [requester, point_name_text, point.occupant_peer_id])
		return

	# Leaving the old point and taking the new one must be one atomic step on the
	# server, otherwise a rejected claim could leave the crew member seatless.
	var previous: VehicleAttachmentPoint = point_occupied_by(requester)
	if previous != null and previous != point:
		previous.occupant_peer_id = 0
	point.occupant_peer_id = requester

	_broadcast_full_occupancy()


@rpc("any_peer", "call_local", "reliable")
func _rpc_request_release() -> void:
	if not multiplayer.is_server():
		return
	var requester: int = NetGuard.effective_sender(self)
	var previous: VehicleAttachmentPoint = point_occupied_by(requester)
	if previous == null:
		return
	previous.occupant_peer_id = 0
	_broadcast_full_occupancy()


## Server-only. Free every point a departing peer held.
func server_release_peer(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var changed: bool = false
	for point: VehicleAttachmentPoint in points.values():
		if point.occupant_peer_id == peer_id:
			point.occupant_peer_id = 0
			changed = true
	if changed:
		_broadcast_full_occupancy()


func _refresh_driver() -> void:
	var new_driver: int = 0
	if driver_seat != null:
		new_driver = driver_seat.occupant_peer_id
	if new_driver == driver_peer_id:
		return
	driver_peer_id = new_driver
	GameLog.info("vehicle", "driver is now peer %d" % driver_peer_id)
	driver_changed.emit(driver_peer_id)
	GameEvents.driver_changed.emit(driver_peer_id)
