extends Node

## Autoload: NetworkManager
##
## Owns the ENet peer, the lobby roster, and the match lifecycle handshake.
##
## ============================================================================
## AUTHORITY MODEL  (read this before touching any networked system)
## ============================================================================
##
## This game splits authority in two, deliberately, rather than making the
## server authoritative over everything:
##
##   * The SERVER (peer 1, the host) is authoritative over everything that can
##     be cheated to another player's detriment: component health, damage
##     application, deaths, enemy AI, seat occupancy, role assignment, match
##     state. Clients never apply these locally; they request, and they display
##     what the server confirms.
##
##   * The DRIVER'S CLIENT is authoritative over the vehicle's rigid-body
##     transform. The vehicle simulates on whichever peer is driving it; every
##     other peer freezes its rigid body and follows replicated snapshots.
##
## Why the vehicle is not server-authoritative:
##
##   Driving is the single most latency-sensitive input in the game. A
##   server-authoritative vehicle gives the driver a full round-trip of input
##   lag on every steering correction, which at 60-100 ms makes threading a
##   vehicle between obstacles feel broken. Fixing that properly means client
##   prediction with rollback and reconciliation of a rigid body — a large,
##   subtle, and famously fragile piece of engineering.
##
##   The thing that authority buys you is protection from a malicious driver.
##   But this is four-player co-op PvE: the only people a cheating driver can
##   hurt are the three friends who invited them. That is a bad trade, so we
##   take the responsive option and keep authority over the things that would
##   actually ruin a session (damage, health, loot, progression) on the server.
##
##   The design stays reversible. All driving input flows through a single
##   VehicleInputState struct, so moving to a predicted server-authoritative
##   model later means sending that struct to the server and adding
##   reconciliation, not restructuring the vehicle.
##
## Why crew members are NOT reparented onto the vehicle:
##
##   The obvious way to keep a player glued to a moving vehicle is to reparent
##   them under it. That works offline and breaks in multiplayer: a node's path
##   is its network identity, so reparenting renames it mid-session and every
##   in-flight RPC and synchroniser aimed at the old path is silently lost.
##
##   Instead crew nodes live at fixed paths under the level, and each one
##   replicates a *vehicle-local* offset. Its world transform is recomposed
##   every frame as `vehicle_crew_root_transform * local_offset`. Because both
##   halves of that product are replicated, every peer arrives at the same world
##   position, node paths never change, and a crew member physically cannot
##   detach from the vehicle no matter what the vehicle does — being attached is
##   a property of the maths, not of a physics interaction that can fail.
##
## ============================================================================
## MATCH START HANDSHAKE
## ============================================================================
##
##   host: request_start_match()
##      -> _rpc_begin_match (all peers, call_local)   state = LOADING
##      -> every peer loads the level scene
##      -> level _ready() calls notify_level_ready()
##      -> _rpc_level_ready (clients -> server)
##      -> server waits until every connected peer is level-ready
##      -> _rpc_match_playing (all peers, call_local) state = PLAYING
##      -> every peer spawns the identical crew set from the identical roster
##
## The two phases matter: spawning crew before a client has instantiated the
## level would place nodes into a tree that does not exist yet on that peer.

## peer_id (int) -> PlayerInfo
var players: Dictionary = {}

## Mirrored from the server. Clients must treat this as read-only.
var match_state: int = GameEnums.MatchState.IDLE

## Name this peer will register with. Set by the main menu before hosting/joining.
var local_display_name: String = "Player"

## Vehicle the crew will spawn in. Host-selected during the lobby.
var selected_vehicle_id: StringName = &"tactical_suv"

var _peer: ENetMultiplayerPeer = null

## Server-side set of peers that have finished instantiating the level.
## peer_id (int) -> true
var _level_ready_peers: Dictionary = {}

## Set while tearing down, so that the disconnect signals we cause ourselves do
## not re-enter leave_session() and fight the teardown already in progress.
var _shutting_down: bool = false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

func is_session_active() -> bool:
	return _peer != null and multiplayer.multiplayer_peer != null


func is_server() -> bool:
	return is_session_active() and multiplayer.is_server()


func local_peer_id() -> int:
	if not is_session_active():
		return 0
	return multiplayer.get_unique_id()


func local_player() -> PlayerInfo:
	return players.get(local_peer_id(), null) as PlayerInfo


func get_player(peer_id: int) -> PlayerInfo:
	return players.get(peer_id, null) as PlayerInfo


## Roster in a stable, peer-id-ascending order. Every peer derives the same
## ordering from the same roster, which is what makes deterministic crew
## spawning possible without a MultiplayerSpawner.
func sorted_players() -> Array[PlayerInfo]:
	var ids: Array = players.keys()
	ids.sort()
	var result: Array[PlayerInfo] = []
	for id: int in ids:
		result.append(players[id])
	return result


func player_count() -> int:
	return players.size()


func all_players_ready() -> bool:
	if players.is_empty():
		return false
	for info: PlayerInfo in players.values():
		if not info.is_ready:
			return false
	return true


# ---------------------------------------------------------------------------
# Session lifecycle
# ---------------------------------------------------------------------------

## Start hosting. Returns OK, or an Error which the caller should surface.
func host_game(display_name: String, port: int = NetConfig.DEFAULT_PORT) -> Error:
	if is_session_active():
		leave_session()

	local_display_name = PlayerInfo.clean_name(display_name)

	var peer := ENetMultiplayerPeer.new()
	# max_clients excludes the host itself, hence the -1.
	var error: Error = peer.create_server(port, NetConfig.MAX_PLAYERS - 1)
	if error != OK:
		GameLog.error("net", "create_server(%d) failed: %s" % [port, error_string(error)])
		GameEvents.network_error.emit("Could not host on port %d (%s)." % [port, error_string(error)])
		return error

	_peer = peer
	multiplayer.multiplayer_peer = peer
	_shutting_down = false

	# The host is a player too, and it registers itself directly: there is no
	# round trip to wait for.
	var host_info := PlayerInfo.new(1, local_display_name)
	players = {1: host_info}
	_level_ready_peers.clear()
	match_state = GameEnums.MatchState.LOBBY

	GameLog.info("net", "hosting on port %d as '%s'" % [port, local_display_name])
	GameEvents.session_started.emit(true)
	GameEvents.match_state_changed.emit(match_state)
	GameEvents.player_roster_changed.emit()
	return OK


## Connect to a host. Returns OK if the attempt started; success or failure
## arrives later via GameEvents.session_started / GameEvents.network_error.
func join_game(address: String, display_name: String, port: int = NetConfig.DEFAULT_PORT) -> Error:
	if is_session_active():
		leave_session()

	local_display_name = PlayerInfo.clean_name(display_name)

	var host: String = address.strip_edges()
	if host.is_empty():
		host = "127.0.0.1"

	var peer := ENetMultiplayerPeer.new()
	var error: Error = peer.create_client(host, port)
	if error != OK:
		GameLog.error("net", "create_client(%s:%d) failed: %s" % [host, port, error_string(error)])
		GameEvents.network_error.emit("Could not reach %s:%d (%s)." % [host, port, error_string(error)])
		return error

	_peer = peer
	multiplayer.multiplayer_peer = peer
	_shutting_down = false
	players.clear()
	_level_ready_peers.clear()
	match_state = GameEnums.MatchState.IDLE

	GameLog.info("net", "connecting to %s:%d as '%s'" % [host, port, local_display_name])
	return OK


## Tear the session down and return to the main menu.
func leave_session() -> void:
	if _shutting_down:
		return
	_shutting_down = true

	if _peer != null:
		_peer.close()
	_peer = null
	multiplayer.multiplayer_peer = null

	players.clear()
	_level_ready_peers.clear()
	match_state = GameEnums.MatchState.IDLE

	GameLog.info("net", "session ended")
	GameEvents.session_ended.emit()
	GameEvents.match_state_changed.emit(match_state)
	GameEvents.player_roster_changed.emit()

	_shutting_down = false


# ---------------------------------------------------------------------------
# Peer signal handlers
# ---------------------------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	# Nothing to do yet. The roster entry is created when the client sends its
	# registration, which is the first point at which we know its name and
	# protocol version.
	GameLog.debug("net", "peer %d connected (awaiting registration)" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	GameLog.info("net", "peer %d disconnected" % peer_id)
	if not is_server():
		return
	players.erase(peer_id)
	_level_ready_peers.erase(peer_id)
	_broadcast_roster()
	# A departure during LOADING can be the last thing the handshake was waiting
	# on, so re-evaluate rather than stalling the match start forever.
	if match_state == GameEnums.MatchState.LOADING:
		_evaluate_level_readiness()


func _on_connected_to_server() -> void:
	GameLog.info("net", "connected; registering as '%s'" % local_display_name)
	var payload: Dictionary = {
		"protocol": NetConfig.PROTOCOL_VERSION,
		"display_name": local_display_name,
	}
	_rpc_register_player.rpc_id(1, payload)


func _on_connection_failed() -> void:
	GameLog.warn("net", "connection failed")
	GameEvents.network_error.emit("Could not connect to the host.")
	leave_session()


func _on_server_disconnected() -> void:
	GameLog.warn("net", "host closed the session")
	GameEvents.network_error.emit("The host closed the session.")
	leave_session()


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

## Deliberately call_remote: only a connecting client sends this, from
## _on_connected_to_server(), which never fires on the host. The host puts itself
## into the roster directly in host_game(), and must not re-register — doing so
## would replace its own PlayerInfo and wipe its role and ready state.
@rpc("any_peer", "call_remote", "reliable")  # validator: host-never-calls-this
func _rpc_register_player(payload: Dictionary) -> void:
	if not is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()

	var protocol: int = int(payload.get("protocol", -1))
	if protocol != NetConfig.PROTOCOL_VERSION:
		_reject_peer(sender_id, "Version mismatch: host is running protocol %d, you are running %d."
			% [NetConfig.PROTOCOL_VERSION, protocol])
		return

	if match_state != GameEnums.MatchState.LOBBY:
		# Phase 1 has no mid-match join: the crew set is fixed when the match
		# starts so that every peer spawns the identical node set. See
		# docs/ARCHITECTURE.md "Known limitations".
		_reject_peer(sender_id, "The match has already started.")
		return

	if players.size() >= NetConfig.MAX_PLAYERS:
		_reject_peer(sender_id, "The session is full (%d players)." % NetConfig.MAX_PLAYERS)
		return

	var info := PlayerInfo.new(sender_id, PlayerInfo.clean_name(String(payload.get("display_name", "Player"))))
	players[sender_id] = info
	GameLog.info("net", "peer %d registered as '%s'" % [sender_id, info.display_name])
	_broadcast_roster()


func _reject_peer(peer_id: int, reason: String) -> void:
	GameLog.warn("net", "rejecting peer %d: %s" % [peer_id, reason])
	_rpc_rejected.rpc_id(peer_id, reason)
	# Graceful (non-immediate) disconnect so the rejection packet is flushed
	# before the connection goes away; disconnecting immediately would drop it
	# and the client would show a generic timeout instead of the real reason.
	if _peer != null:
		_peer.disconnect_peer(peer_id, false)


@rpc("authority", "call_remote", "reliable")
func _rpc_rejected(reason: String) -> void:
	GameLog.warn("net", "rejected by host: %s" % reason)
	GameEvents.network_error.emit(reason)
	leave_session()


func _broadcast_roster() -> void:
	if not is_server():
		return
	var payload: Array = []
	for info: PlayerInfo in sorted_players():
		payload.append(info.to_dict())
	_rpc_sync_roster.rpc(payload, match_state)


@rpc("authority", "call_local", "reliable")
func _rpc_sync_roster(payload: Array, server_match_state: int) -> void:
	var rebuilt: Dictionary = {}
	for entry: Variant in payload:
		if entry is Dictionary:
			var info: PlayerInfo = PlayerInfo.from_dict(entry)
			if info.peer_id != 0:
				rebuilt[info.peer_id] = info
	players = rebuilt

	var previous_state: int = match_state
	match_state = server_match_state

	# A client learns it is really in the session the first time a roster
	# containing it arrives.
	if not is_server() and previous_state == GameEnums.MatchState.IDLE \
			and match_state != GameEnums.MatchState.IDLE:
		GameEvents.session_started.emit(false)

	GameEvents.player_roster_changed.emit()
	if previous_state != match_state:
		GameEvents.match_state_changed.emit(match_state)


# ---------------------------------------------------------------------------
# Lobby requests (client -> server -> everyone)
# ---------------------------------------------------------------------------

func request_role(role: int) -> void:
	_rpc_request_role.rpc_id(1, role)


@rpc("any_peer", "call_local", "reliable")
func _rpc_request_role(role: int) -> void:
	if not is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	# get_remote_sender_id() is 0 for a local call, which is how the host's own
	# request arrives.
	if sender_id == 0:
		sender_id = 1

	var info: PlayerInfo = players.get(sender_id, null)
	if info == null:
		return

	var requested: int = clampi(role, GameEnums.CrewRole.NONE, GameEnums.CrewRole.ENGINEER)

	# Driver and Engineer are exclusive *preferences*, so the lobby reads
	# clearly. This is not a gameplay lock: who actually drives is decided by
	# who occupies the driver seat, and any crew member may take any seat.
	if requested == GameEnums.CrewRole.DRIVER or requested == GameEnums.CrewRole.ENGINEER:
		for other: PlayerInfo in players.values():
			if other.peer_id != sender_id and other.role == requested:
				GameLog.debug("net", "peer %d denied role %s (taken by %d)"
					% [sender_id, GameEnums.role_name(requested), other.peer_id])
				return

	info.role = requested
	# Changing role clears ready, so nobody starts a match under a stale layout.
	info.is_ready = false
	_broadcast_roster()


func request_ready(is_ready: bool) -> void:
	_rpc_request_ready.rpc_id(1, is_ready)


@rpc("any_peer", "call_local", "reliable")
func _rpc_request_ready(is_ready: bool) -> void:
	if not is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	if sender_id == 0:
		sender_id = 1
	var info: PlayerInfo = players.get(sender_id, null)
	if info == null:
		return
	info.is_ready = is_ready
	_broadcast_roster()


## Host-only: choose the vehicle the crew will spawn in.
func set_selected_vehicle(vehicle_id: StringName) -> void:
	if not is_server():
		return
	selected_vehicle_id = vehicle_id
	_rpc_sync_vehicle_choice.rpc(String(vehicle_id))


@rpc("authority", "call_local", "reliable")
func _rpc_sync_vehicle_choice(vehicle_id: String) -> void:
	selected_vehicle_id = StringName(vehicle_id)
	GameEvents.player_roster_changed.emit()


# ---------------------------------------------------------------------------
# Match start handshake
# ---------------------------------------------------------------------------

## Host-only. Returns a human-readable refusal, or "" when the match is starting.
func request_start_match() -> String:
	if not is_server():
		return "Only the host can start the match."
	if match_state != GameEnums.MatchState.LOBBY:
		return "The match is already under way."
	if players.is_empty():
		return "No players in the session."
	if not all_players_ready():
		return "Every player must be ready."

	# Assign stable crew indices in peer order. Spawn points, default seats and
	# player colours are all derived from this, so it must be decided once, by
	# the server, and then replicated — never recomputed independently per peer.
	var index: int = 0
	for info: PlayerInfo in sorted_players():
		info.crew_index = index
		index += 1

	match_state = GameEnums.MatchState.LOADING
	_level_ready_peers.clear()
	_broadcast_roster()
	_rpc_begin_match.rpc(String(selected_vehicle_id))
	return ""


@rpc("authority", "call_local", "reliable")
func _rpc_begin_match(vehicle_id: String) -> void:
	selected_vehicle_id = StringName(vehicle_id)
	match_state = GameEnums.MatchState.LOADING
	GameLog.info("net", "loading level with vehicle '%s'" % vehicle_id)
	GameEvents.match_state_changed.emit(match_state)
	SceneRouter.go_to(SceneRouter.TEST_ARENA_SCENE)


## Called by the level scene from its _ready(). Signals that this peer has the
## level instantiated and can safely have crew spawned into it.
func notify_level_ready() -> void:
	if not is_session_active():
		return
	if is_server():
		_level_ready_peers[1] = true
		_evaluate_level_readiness()
	else:
		_rpc_level_ready.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_level_ready() -> void:
	if not is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	_level_ready_peers[sender_id] = true
	GameLog.debug("net", "peer %d level-ready (%d/%d)"
		% [sender_id, _level_ready_peers.size(), players.size()])
	_evaluate_level_readiness()


func _evaluate_level_readiness() -> void:
	if not is_server() or match_state != GameEnums.MatchState.LOADING:
		return
	for peer_id: int in players.keys():
		if not _level_ready_peers.has(peer_id):
			return
	GameLog.info("net", "all %d peers level-ready; starting play" % players.size())
	match_state = GameEnums.MatchState.PLAYING
	_broadcast_roster()
	_rpc_match_playing.rpc()


@rpc("authority", "call_local", "reliable")
func _rpc_match_playing() -> void:
	match_state = GameEnums.MatchState.PLAYING
	GameLog.info("net", "match playing")
	GameEvents.match_state_changed.emit(match_state)


## Host-only: end the match and send everyone back to the lobby.
func end_match() -> void:
	if not is_server():
		return
	match_state = GameEnums.MatchState.LOBBY
	_level_ready_peers.clear()
	for info: PlayerInfo in players.values():
		info.is_ready = false
		info.crew_index = -1
	_broadcast_roster()
	_rpc_return_to_lobby.rpc()


@rpc("authority", "call_local", "reliable")
func _rpc_return_to_lobby() -> void:
	match_state = GameEnums.MatchState.LOBBY
	GameEvents.match_state_changed.emit(match_state)
	SceneRouter.go_to(SceneRouter.LOBBY_SCENE)
