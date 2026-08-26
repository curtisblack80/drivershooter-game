class_name CrewSpawner
extends Node3D

## Creates and destroys the crew member nodes for a match.
##
## ============================================================================
## WHY NOT MultiplayerSpawner
## ============================================================================
##
## Godot's MultiplayerSpawner exists for objects that appear at unpredictable
## times — projectiles, pickups, mid-match joiners. The crew is the opposite: the
## roster is fixed and identical on every peer before the level loads, and the
## match-start handshake in NetworkManager guarantees every peer has the level in
## its tree before anyone spawns.
##
## So each peer builds the same crew from the same roster, in the same peer-id
## order, with names derived from peer ids. That gives identical node paths
## everywhere — which is what RPCs are addressed by — with no spawn packets, no
## ordering races, and nothing to debug when a client's node ends up named
## `@CharacterBody3D@27`.
##
## Mid-match joining changes this calculus and is exactly when MultiplayerSpawner
## starts earning its keep. Phase 1 rejects mid-match joins (see
## NetworkManager._rpc_register_player), so that trade is not being made yet.

@export var player_scene: PackedScene = null
@export_node_path("Node3D") var vehicle_path: NodePath = NodePath()

## peer_id -> PlayerCharacter
var _crew: Dictionary = {}
var _vehicle: VehicleController = null


func _ready() -> void:
	_vehicle = get_node_or_null(vehicle_path) as VehicleController
	if _vehicle == null:
		GameLog.error("spawn", "CrewSpawner has no vehicle at '%s'" % vehicle_path)
	if player_scene == null:
		GameLog.error("spawn", "CrewSpawner has no player_scene assigned")

	GameEvents.match_state_changed.connect(_on_match_state_changed)
	GameEvents.player_roster_changed.connect(_on_roster_changed)

	# The match may already be playing by the time this level finishes loading on
	# a slow client, in which case the state-changed signal has been and gone.
	if NetworkManager.match_state == GameEnums.MatchState.PLAYING:
		_spawn_all()


func crew_for(peer_id: int) -> PlayerCharacter:
	return _crew.get(peer_id, null) as PlayerCharacter


func local_crew() -> PlayerCharacter:
	return crew_for(multiplayer.get_unique_id())


func _on_match_state_changed(state: int) -> void:
	if state == GameEnums.MatchState.PLAYING:
		_spawn_all()
	elif state == GameEnums.MatchState.LOBBY or state == GameEnums.MatchState.IDLE:
		_despawn_all()


func _spawn_all() -> void:
	if player_scene == null or _vehicle == null:
		return

	var roster: Array[PlayerInfo] = NetworkManager.sorted_players()

	# Seating is decided once, by the server, and broadcast. Crew nodes read
	# whatever occupancy the rig already holds when they bind, so this is safe to
	# do before or after the nodes exist.
	if multiplayer.is_server() and _vehicle.rig() != null:
		_vehicle.rig().server_assign_initial_seats(roster)

	for info: PlayerInfo in roster:
		if _crew.has(info.peer_id):
			continue
		_spawn_one(info)


func _spawn_one(info: PlayerInfo) -> void:
	var player: PlayerCharacter = player_scene.instantiate() as PlayerCharacter
	if player == null:
		GameLog.error("spawn", "player_scene's root is not a PlayerCharacter")
		return

	# Name before add_child: the name is the network address of every RPC this
	# node will ever receive, and it must match on all peers.
	player.name = "Crew_%d" % info.peer_id
	player.configure(info.peer_id, info.role, info.display_name)
	add_child(player)

	# Binding happens after the node is in the tree, because CrewController needs
	# the vehicle rig to have completed its scan.
	player.bind_vehicle(_vehicle)

	_crew[info.peer_id] = player
	GameLog.info("spawn", "spawned crew for peer %d (%s, %s)"
		% [info.peer_id, info.display_name, GameEnums.role_name(info.role)])


func _on_roster_changed() -> void:
	# Remove crew whose peer has left the session.
	var departed: Array = []
	for peer_id: int in _crew.keys():
		if not NetworkManager.players.has(peer_id):
			departed.append(peer_id)

	for peer_id: int in departed:
		_despawn_one(peer_id)


func _despawn_one(peer_id: int) -> void:
	var player: PlayerCharacter = _crew.get(peer_id, null)
	_crew.erase(peer_id)
	if player != null and is_instance_valid(player):
		player.queue_free()
	if multiplayer.is_server() and _vehicle != null and _vehicle.rig() != null:
		# Free whatever seat they were holding, or it stays locked for the match.
		_vehicle.rig().server_release_peer(peer_id)
	GameLog.info("spawn", "despawned crew for peer %d" % peer_id)


func _despawn_all() -> void:
	for peer_id: int in _crew.keys().duplicate():
		_despawn_one(peer_id)
