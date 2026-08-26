extends Control

## Host / join screen.

@onready var _name_edit: LineEdit = %NameEdit
@onready var _address_edit: LineEdit = %AddressEdit
@onready var _port_edit: LineEdit = %PortEdit
@onready var _host_button: Button = %HostButton
@onready var _join_button: Button = %JoinButton
@onready var _quit_button: Button = %QuitButton
@onready var _error_label: Label = %ErrorLabel
@onready var _version_label: Label = %VersionLabel


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# A different default name per launch, because the normal way to test this
	# is several instances on one machine and "Player" four times over is
	# unreadable in the lobby.
	_name_edit.text = "Player %d" % (randi() % 900 + 100)
	_address_edit.text = "127.0.0.1"
	_port_edit.text = str(NetConfig.DEFAULT_PORT)
	_error_label.text = ""
	_version_label.text = "v%s  ·  protocol %d" % [
		ProjectSettings.get_setting("application/config/version", "?"),
		NetConfig.PROTOCOL_VERSION,
	]

	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)
	_address_edit.text_submitted.connect(_on_address_submitted)

	GameEvents.session_started.connect(_on_session_started)
	GameEvents.network_error.connect(_on_network_error)


func _on_host_pressed() -> void:
	_set_busy(true)
	_error_label.text = ""
	if NetworkManager.host_game(_name_edit.text, _read_port()) != OK:
		_set_busy(false)


func _on_join_pressed() -> void:
	_set_busy(true)
	_error_label.text = "Connecting…"
	if NetworkManager.join_game(_address_edit.text, _name_edit.text, _read_port()) != OK:
		_set_busy(false)


func _on_address_submitted(_text: String) -> void:
	_on_join_pressed()


func _on_quit_pressed() -> void:
	get_tree().quit()


func _read_port() -> int:
	var value: int = int(_port_edit.text)
	if value <= 0 or value > 65535:
		return NetConfig.DEFAULT_PORT
	return value


func _on_session_started(_is_server: bool) -> void:
	SceneRouter.go_to(SceneRouter.LOBBY_SCENE)


func _on_network_error(message: String) -> void:
	_error_label.text = message
	_set_busy(false)


func _set_busy(busy: bool) -> void:
	_host_button.disabled = busy
	_join_button.disabled = busy
