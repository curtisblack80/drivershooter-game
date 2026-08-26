extends Control

## Pre-match lobby: roster, role selection, ready check, launch.

@onready var _roster_list: VBoxContainer = %RosterList
@onready var _status_label: Label = %StatusLabel
@onready var _vehicle_label: Label = %VehicleLabel
@onready var _ready_button: Button = %ReadyButton
@onready var _start_button: Button = %StartButton
@onready var _leave_button: Button = %LeaveButton
@onready var _role_driver: Button = %RoleDriver
@onready var _role_gunner: Button = %RoleGunner
@onready var _role_engineer: Button = %RoleEngineer


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	_ready_button.pressed.connect(_on_ready_pressed)
	_start_button.pressed.connect(_on_start_pressed)
	_leave_button.pressed.connect(_on_leave_pressed)
	_role_driver.pressed.connect(_on_role_pressed.bind(GameEnums.CrewRole.DRIVER))
	_role_gunner.pressed.connect(_on_role_pressed.bind(GameEnums.CrewRole.GUNNER))
	_role_engineer.pressed.connect(_on_role_pressed.bind(GameEnums.CrewRole.ENGINEER))

	GameEvents.player_roster_changed.connect(_refresh)
	GameEvents.session_ended.connect(_on_session_ended)
	GameEvents.network_error.connect(_on_network_error)

	_refresh()


func _on_role_pressed(role: int) -> void:
	# Pressing the role you already hold clears it, so a player can free up
	# Driver for someone else without leaving the lobby.
	var info: PlayerInfo = NetworkManager.local_player()
	if info != null and info.role == role:
		NetworkManager.request_role(GameEnums.CrewRole.NONE)
	else:
		NetworkManager.request_role(role)


func _on_ready_pressed() -> void:
	var info: PlayerInfo = NetworkManager.local_player()
	NetworkManager.request_ready(info == null or not info.is_ready)


func _on_start_pressed() -> void:
	var refusal: String = NetworkManager.request_start_match()
	if not refusal.is_empty():
		_status_label.text = refusal


func _on_leave_pressed() -> void:
	NetworkManager.leave_session()


func _on_session_ended() -> void:
	SceneRouter.go_to(SceneRouter.MAIN_MENU_SCENE)


func _on_network_error(message: String) -> void:
	_status_label.text = message


func _refresh() -> void:
	for child in _roster_list.get_children():
		child.queue_free()

	var local_id: int = NetworkManager.local_peer_id()
	for info: PlayerInfo in NetworkManager.sorted_players():
		var row := Label.new()
		var markers: String = ""
		if info.peer_id == 1:
			markers += "  [host]"
		if info.peer_id == local_id:
			markers += "  ← you"
		row.text = "%s  ·  %s  ·  %s%s" % [
			info.display_name,
			info.role_name(),
			"READY" if info.is_ready else "not ready",
			markers,
		]
		row.add_theme_font_size_override(&"font_size", 16)
		_roster_list.add_child(row)

	var is_host: bool = NetworkManager.is_server()
	_start_button.visible = is_host
	_start_button.disabled = not NetworkManager.all_players_ready()

	var info_local: PlayerInfo = NetworkManager.local_player()
	_ready_button.text = "Cancel Ready" if info_local != null and info_local.is_ready else "Ready"

	_role_driver.button_pressed = info_local != null and info_local.role == GameEnums.CrewRole.DRIVER
	_role_gunner.button_pressed = info_local != null and info_local.role == GameEnums.CrewRole.GUNNER
	_role_engineer.button_pressed = info_local != null and info_local.role == GameEnums.CrewRole.ENGINEER

	_vehicle_label.text = "Vehicle: %s" % String(NetworkManager.selected_vehicle_id)

	if is_host:
		if NetworkManager.all_players_ready():
			_status_label.text = "All crew ready. Launch when you are."
		else:
			_status_label.text = "Waiting for the crew to ready up (%d/%d)." % [
				_ready_count(), NetworkManager.player_count()]
	else:
		_status_label.text = "Waiting for the host to start the match."


func _ready_count() -> int:
	var count: int = 0
	for info: PlayerInfo in NetworkManager.players.values():
		if info.is_ready:
			count += 1
	return count
