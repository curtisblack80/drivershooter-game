extends Node3D

## The Phase 1 test level.
##
## Deliberately plain: flat ground, a few blocks for cover and line-of-sight
## breaks, one vehicle and one enemy spawner. Its job is to make the vehicle and
## crew systems observable, not to be a map. Real level design — roads, bridges,
## ambush geometry, repair stations — is Phase 8, and would only get in the way
## of judging whether four players can ride, fight from and climb over a moving
## vehicle.
##
## The level is instantiated identically on every peer *before* any crew spawns;
## see the match-start handshake in NetworkManager. Calling notify_level_ready()
## from _ready() is this peer's half of that handshake.


func _ready() -> void:
	GameLog.info("level", "test arena ready")
	GameEvents.session_ended.connect(_on_session_ended)
	NetworkManager.notify_level_ready()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	# Escape leaves the match. For the host that returns the whole crew to the
	# lobby; for a client it disconnects only them.
	if NetworkManager.is_server():
		NetworkManager.end_match()
	else:
		NetworkManager.leave_session()


func _on_session_ended() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	SceneRouter.go_to(SceneRouter.MAIN_MENU_SCENE)
