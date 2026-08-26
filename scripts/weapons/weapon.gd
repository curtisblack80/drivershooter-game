class_name Weapon
extends Node3D

## A held weapon. Hitscan resolution, ammunition, reloading, and the
## predict-then-confirm network flow.
##
## ============================================================================
## WHO DECIDES WHAT
## ============================================================================
##
## Shooting has to feel instant and must not be forgeable, and those pull in
## opposite directions. The split:
##
##   The firing client  decides *when it looks like* it fired. It checks its own
##                      cooldown, plays the tracer immediately, and decrements a
##                      predicted ammo count so the HUD responds on the frame the
##                      trigger is pulled.
##
##   The server         decides what actually happened. It holds the real
##                      ammunition count, enforces the rate of fire, rejects
##                      shots whose origin is nowhere near the shooter, runs its
##                      own raycast, and looks the damage value up from its own
##                      copy of the WeaponDefinition. A client that claims a hit,
##                      a damage number, or a round it does not have is simply
##                      ignored.
##
## The one thing the server takes on trust is the *direction* of each pellet,
## because spread is rolled on the client and the server has no way to know what
## the player was aiming at. The exposure is bounded — a client can aim
## perfectly, which is aimbot territory, not damage forgery — and the origin
## check stops the more damaging version where a client shoots from across the
## map. Closing it fully needs the server to reconstruct aim from a replicated
## look direction, which is Phase 6 hardening.

signal ammo_changed(current: int, magazine: int)
signal fired()
signal reload_started(duration: float)
signal reload_finished()

@export var definition: WeaponDefinition = null
@export_node_path("Node3D") var muzzle_path: NodePath = ^"Muzzle"

## Whether shots can hurt other crew members. Off for Phase 1.
@export var friendly_fire: bool = false

## How far a reported shot origin may be from the shooter before the server
## rejects it. Generous enough to absorb interpolation error between the
## shooter's predicted position and the server's view of it.
@export_range(0.5, 20.0, 0.5) var max_origin_error: float = 4.0

var owner_peer_id: int = 0

var _body: CharacterBody3D = null
var _crew: CrewController = null
var _muzzle: Node3D = null

## Client-side predicted state.
var _ammo: int = 0
var _cooldown: float = 0.0
var _reload_timer: float = 0.0
var _reloading: bool = false
var _extra_spread_degrees: float = 0.0
var _fired_this_trigger: bool = false

## Server-side authoritative state.
var _server_ammo: int = 0
var _server_next_shot_msec: int = 0
var _server_reload_end_msec: int = 0


func _ready() -> void:
	_muzzle = get_node_or_null(muzzle_path) as Node3D
	if _muzzle == null:
		GameLog.warn("weapon", "no muzzle node at '%s'; falling back to the weapon origin" % muzzle_path)
	if definition == null:
		GameLog.error("weapon", "Weapon '%s' has no WeaponDefinition and cannot fire" % name)
		return
	for problem: String in definition.validate():
		GameLog.warn("weapon", "%s: %s" % [definition.weapon_id, problem])
	_ammo = definition.magazine_size
	_server_ammo = definition.magazine_size
	ammo_changed.emit(_ammo, definition.magazine_size)


## Called by PlayerCharacter after spawning.
func setup(body: CharacterBody3D, crew: CrewController, peer_id: int) -> void:
	_body = body
	_crew = crew
	owner_peer_id = peer_id


func ammo() -> int:
	return _ammo


func magazine_size() -> int:
	return definition.magazine_size if definition != null else 0


func is_reloading() -> bool:
	return _reloading


func muzzle_position() -> Vector3:
	return _muzzle.global_position if _muzzle != null else global_position


func _process(delta: float) -> void:
	if definition == null:
		return

	if _cooldown > 0.0:
		_cooldown -= delta

	if _reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			_reloading = false
			_ammo = definition.magazine_size
			ammo_changed.emit(_ammo, definition.magazine_size)
			reload_finished.emit()

	# Accumulated spread bleeds off once the player stops firing.
	if not _fired_this_trigger and _extra_spread_degrees > 0.0:
		_extra_spread_degrees = maxf(
			_extra_spread_degrees - definition.spread_recovery_per_second * delta, 0.0)
	_fired_this_trigger = false


func can_fire() -> bool:
	if definition == null or _reloading:
		return false
	if definition.fire_mode != GameEnums.WeaponFireMode.HITSCAN:
		return false
	if _cooldown > 0.0:
		return false
	return _ammo > 0


## Fire at `aim_target`. Called only on the owning client.
## Returns true when a shot was actually taken.
func try_fire(aim_target: Vector3, aiming: bool) -> bool:
	if definition == null:
		return false
	if definition.fire_mode != GameEnums.WeaponFireMode.HITSCAN:
		GameLog.error("weapon", "'%s' uses an unimplemented fire mode (Phase 5)" % definition.display_name)
		return false
	if not can_fire():
		if _ammo <= 0 and not _reloading:
			start_reload()
		return false

	_cooldown = definition.seconds_between_shots()
	_ammo -= 1
	_fired_this_trigger = true
	ammo_changed.emit(_ammo, definition.magazine_size)

	var origin: Vector3 = muzzle_position()
	var base_direction: Vector3 = aim_target - origin
	if base_direction.length_squared() < 0.000001:
		base_direction = -global_transform.basis.z
	base_direction = base_direction.normalized()

	var directions := PackedVector3Array()
	for _index in definition.pellets:
		directions.append(_apply_spread(base_direction, aiming))

	_extra_spread_degrees = minf(
		_extra_spread_degrees + definition.spread_growth_per_shot,
		definition.max_extra_spread_degrees)

	# Show the shot immediately; the server's confirmation arrives later and is
	# only needed for the other peers' tracers and for damage.
	_play_local_tracers(origin, directions)
	fired.emit()

	if NetworkManager.is_session_active():
		_rpc_request_fire.rpc_id(1, origin, directions)
	return true


func start_reload() -> void:
	if definition == null or _reloading or _ammo >= definition.magazine_size:
		return
	_reloading = true
	_reload_timer = definition.reload_seconds
	reload_started.emit(definition.reload_seconds)
	if NetworkManager.is_session_active():
		_rpc_request_reload.rpc_id(1)


func _apply_spread(direction: Vector3, aiming: bool) -> Vector3:
	var cone: float = definition.spread_radians(aiming) + deg_to_rad(_extra_spread_degrees)
	if cone <= 0.0001:
		return direction

	# Uniform sample within the cone. sqrt() on the radius keeps the
	# distribution even across the disc instead of clustering at the centre.
	var angle: float = randf() * TAU
	var radius: float = sqrt(randf()) * cone

	var reference: Vector3 = Vector3.UP
	if absf(direction.dot(reference)) > 0.95:
		reference = Vector3.RIGHT
	var right: Vector3 = direction.cross(reference).normalized()
	var up: Vector3 = right.cross(direction).normalized()

	var offset: float = tan(radius)
	return (direction + right * (cos(angle) * offset) + up * (sin(angle) * offset)).normalized()


## Bodies a shot from this weapon must ignore: the shooter, and the vehicle they
## are riding. Without the second one, a gunner standing on the hood shoots
## their own bonnet every time they aim below the horizon.
func shot_exclusions() -> Array[RID]:
	var list: Array[RID] = []
	if _body != null:
		list.append(_body.get_rid())
	if _crew != null and _crew.is_attached():
		var vehicle: VehicleController = _crew.vehicle()
		if vehicle != null:
			list.append(vehicle.get_rid())
	return list


func _play_local_tracers(origin: Vector3, directions: PackedVector3Array) -> void:
	var exclusions: Array[RID] = shot_exclusions()
	for direction: Vector3 in directions:
		var end_point: Vector3 = _trace_end(origin, direction, exclusions)
		TracerEffect.spawn(self, origin, end_point, definition.tracer_color, definition.tracer_lifetime)


## Where a shot visually stops. Used for tracers on every peer; the server runs
## its own copy of this for damage.
func _trace_end(origin: Vector3, direction: Vector3, exclusions: Array[RID]) -> Vector3:
	var world: World3D = get_world_3d()
	var far_point: Vector3 = origin + direction * definition.max_range
	if world == null:
		return far_point
	var query := PhysicsRayQueryParameters3D.create(origin, far_point,
		NetConfig.Layer.SHOOTABLE, exclusions)
	query.collide_with_areas = false
	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return far_point
	return hit["position"]


# ---------------------------------------------------------------------------
# Server resolution
# ---------------------------------------------------------------------------

## Declared "call_local" so that the host's own shots resolve.
##
## `rpc_id(1, ...)` from the host targets itself, and Godot only executes a
## self-targeted RPC when the method is call_local — a call_remote method is
## simply dropped. Without this the host could fire all day and never damage
## anything, while every client worked correctly, which is a maddening bug to
## chase. `effective_sender` then reports 1 rather than 0 for that local call.
@rpc("any_peer", "call_local", "reliable")
func _rpc_request_fire(origin: Vector3, directions: PackedVector3Array) -> void:
	if not multiplayer.is_server() or definition == null:
		return
	var sender: int = NetGuard.effective_sender(self)
	if sender != owner_peer_id:
		GameLog.warn("weapon", "peer %d tried to fire peer %d's weapon" % [sender, owner_peer_id])
		return

	var now: int = Time.get_ticks_msec()
	if now < _server_next_shot_msec:
		# Firing faster than the weapon allows.
		return
	if now < _server_reload_end_msec:
		return
	if _server_ammo <= 0:
		return
	if directions.size() != definition.pellets:
		GameLog.warn("weapon", "peer %d sent %d pellets, expected %d"
			% [sender, directions.size(), definition.pellets])
		return
	if _body != null and _body.global_position.distance_to(origin) > max_origin_error:
		GameLog.warn("weapon", "peer %d shot origin is %.1fm from their body; rejected"
			% [sender, _body.global_position.distance_to(origin)])
		return

	_server_ammo -= 1
	# 10% grace absorbs jitter without letting a client meaningfully outpace the
	# weapon's real rate of fire.
	_server_next_shot_msec = now + int(definition.seconds_between_shots() * 900.0)

	var exclusions: Array[RID] = shot_exclusions()
	var end_points := PackedVector3Array()
	for direction: Vector3 in directions:
		end_points.append(_server_resolve_pellet(origin, direction.normalized(), exclusions))

	_rpc_confirm_shot.rpc(origin, end_points)
	_rpc_sync_ammo.rpc_id(owner_peer_id, _server_ammo, false)


func _server_resolve_pellet(origin: Vector3, direction: Vector3, exclusions: Array[RID]) -> Vector3:
	var world: World3D = get_world_3d()
	var far_point: Vector3 = origin + direction * definition.max_range
	if world == null:
		return far_point

	var query := PhysicsRayQueryParameters3D.create(origin, far_point,
		NetConfig.Layer.SHOOTABLE, exclusions)
	query.collide_with_areas = false
	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return far_point

	var hit_point: Vector3 = hit["position"]
	var collider: Object = hit.get("collider")

	if collider != null:
		var target: Node = DamageRouter.find_damageable(collider)
		var is_crew: bool = target != null and target.has_method(&"owning_peer_id")
		if target != null and (friendly_fire or not is_crew):
			# The damage number comes from the server's own definition, never
			# from anything the client sent.
			var distance: float = origin.distance_to(hit_point)
			var amount: float = definition.damage_at_distance(distance)
			DamageRouter.apply(collider, hit_point, amount, definition.damage_type, owner_peer_id)

	return hit_point


## Sent by the server only. See the note on HealthComponent._rpc_sync_health for
## why this is "any_peer" with an explicit check: a Weapon's node authority is
## the player who owns it, so an "authority" annotation would lock the server out
## of the very broadcast it is responsible for making.
##
## call_local matters here too: `rpc()` reaches every peer *except* the caller,
## so without it the host would never see a tracer for any client's shot. The
## shooter-is-me guard below stops it from drawing its own shot twice.
@rpc("any_peer", "call_local", "reliable")
func _rpc_confirm_shot(origin: Vector3, end_points: PackedVector3Array) -> void:
	if not NetGuard.is_from_server(self):
		return
	# The shooter already played this on their own machine when they pulled the
	# trigger; replaying it would double every tracer.
	if owner_peer_id == multiplayer.get_unique_id():
		return
	if definition == null:
		return
	for end_point: Vector3 in end_points:
		TracerEffect.spawn(self, origin, end_point, definition.tracer_color, definition.tracer_lifetime)
		GameEvents.shot_fired.emit(owner_peer_id, origin, end_point, true)


## call_local for the same reason as _rpc_request_fire.
@rpc("any_peer", "call_local", "reliable")
func _rpc_request_reload() -> void:
	if not multiplayer.is_server() or definition == null:
		return
	if NetGuard.effective_sender(self) != owner_peer_id:
		return
	if _server_ammo >= definition.magazine_size:
		return
	_server_reload_end_msec = Time.get_ticks_msec() + int(definition.reload_seconds * 1000.0)
	# The magazine is refilled when the reload finishes, not when it starts, so a
	# client cannot cancel-reload its way to a full magazine early.
	var timer: SceneTreeTimer = get_tree().create_timer(definition.reload_seconds, false)
	timer.timeout.connect(_server_finish_reload)


func _server_finish_reload() -> void:
	if not multiplayer.is_server() or definition == null:
		return
	_server_ammo = definition.magazine_size
	_rpc_sync_ammo.rpc_id(owner_peer_id, _server_ammo, true)


## Correct the owning client's predicted ammo from the server's count.
## Server-sent; "any_peer" plus an explicit check, for the same reason as above.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_sync_ammo(server_ammo: int, reload_complete: bool) -> void:
	if not NetGuard.is_from_server(self):
		return
	if definition == null:
		return
	if reload_complete:
		_reloading = false
		_reload_timer = 0.0
		reload_finished.emit()
	if _ammo == server_ammo:
		return
	_ammo = server_ammo
	ammo_changed.emit(_ammo, definition.magazine_size)
