extends CanvasLayer

## In-match HUD.
##
## Reads only from GameEvents and from the local player node. It never reaches
## into the vehicle or the network layer directly, so the whole HUD can be
## deleted or replaced without touching gameplay code.

@onready var _crosshair: Control = %Crosshair
@onready var _prompt_label: Label = %PromptLabel
@onready var _speed_label: Label = %SpeedLabel
@onready var _state_label: Label = %StateLabel
@onready var _role_label: Label = %RoleLabel
@onready var _ammo_label: Label = %AmmoLabel
@onready var _health_bar: ProgressBar = %HealthBar
@onready var _component_list: VBoxContainer = %ComponentList
@onready var _debug_panel: PanelContainer = %DebugPanel
@onready var _debug_label: Label = %DebugLabel

var _player: PlayerCharacter = null
var _vehicle: VehicleController = null

## GameEnums.VehicleComponent -> the Label showing it.
var _component_rows: Dictionary = {}


func _ready() -> void:
	_prompt_label.text = ""
	_debug_panel.visible = false

	GameEvents.local_player_spawned.connect(_on_local_player_spawned)
	GameEvents.local_player_despawned.connect(_on_local_player_despawned)
	GameEvents.local_crew_state_changed.connect(_on_crew_state_changed)
	GameEvents.interaction_prompt_changed.connect(_on_prompt_changed)
	GameEvents.vehicle_component_health_changed.connect(_on_component_changed)
	GameEvents.driver_changed.connect(_on_driver_changed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"debug_toggle_netstats"):
		_debug_panel.visible = not _debug_panel.visible
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return

	if _vehicle != null and is_instance_valid(_vehicle):
		_speed_label.text = "%3.0f km/h" % _vehicle.speed_kph()
	else:
		_speed_label.text = ""

	var health: HealthComponent = _player.health
	_health_bar.value = health.ratio() * 100.0

	var weapon: Weapon = _player.weapon
	if weapon != null and weapon.definition != null:
		if weapon.is_reloading():
			_ammo_label.text = "reloading…"
		else:
			_ammo_label.text = "%d / %d" % [weapon.ammo(), weapon.magazine_size()]
	else:
		_ammo_label.text = ""

	# The crosshair is meaningless while driving (no personal weapon) or mid-climb.
	var can_shoot: bool = not _player.crew.is_driving() and not _player.crew.is_action_locked()
	_crosshair.visible = can_shoot

	if _debug_panel.visible:
		_update_debug()


func _on_local_player_spawned(player: Node3D) -> void:
	_player = player as PlayerCharacter
	if _player == null:
		return
	_vehicle = _player.crew.vehicle()
	_role_label.text = GameEnums.role_name(_player.role)
	_on_crew_state_changed(_player.crew.state())
	_rebuild_component_list()


func _on_local_player_despawned() -> void:
	_player = null
	_vehicle = null


func _on_crew_state_changed(state: int) -> void:
	_state_label.text = GameEnums.crew_state_name(state)


func _on_prompt_changed(text: String) -> void:
	_prompt_label.text = text


func _on_driver_changed(peer_id: int) -> void:
	if _player == null:
		return
	if peer_id == _player.peer_id:
		_prompt_label.text = "You have the wheel"


func _rebuild_component_list() -> void:
	for child in _component_list.get_children():
		child.queue_free()
	_component_rows.clear()

	if _vehicle == null:
		return
	var components: Array = _vehicle.damage.components()
	components.sort()
	for component: int in components:
		var row := Label.new()
		row.add_theme_font_size_override(&"font_size", 13)
		_component_list.add_child(row)
		_component_rows[component] = row
		_set_component_row(component, _vehicle.damage.ratio_of(component))


func _on_component_changed(component: int, ratio: float) -> void:
	_set_component_row(component, ratio)


func _set_component_row(component: int, ratio: float) -> void:
	var row: Label = _component_rows.get(component, null)
	if row == null:
		return
	row.text = "%-18s %3d%%" % [GameEnums.component_name(component), int(round(ratio * 100.0))]
	# Colour carries the urgency; the number carries the detail.
	if ratio <= 0.0:
		row.add_theme_color_override(&"font_color", Color(0.85, 0.25, 0.25))
	elif ratio <= VehicleDamageModel.CRITICAL_RATIO:
		row.add_theme_color_override(&"font_color", Color(0.95, 0.6, 0.2))
	else:
		row.add_theme_color_override(&"font_color", Color(0.75, 0.8, 0.85))


func _update_debug() -> void:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("peer            %s" % GameLog.peer_label())
	lines.append("fps             %d" % Engine.get_frames_per_second())
	lines.append("players         %d" % NetworkManager.player_count())
	if _vehicle != null and is_instance_valid(_vehicle):
		lines.append("veh authority   peer %d%s" % [
			_vehicle.physics_authority_peer,
			"  (mine)" if _vehicle.has_physics_authority() else "",
		])
		lines.append("veh frozen      %s" % _vehicle.freeze)
		lines.append("veh speed       %.1f m/s" % _vehicle.speed_ms())
	if _player != null and is_instance_valid(_player):
		var crew: CrewController = _player.crew
		lines.append("crew state      %s" % GameEnums.crew_state_name(crew.state()))
		lines.append("crew point      %s" % crew.attachment.point_name)
		lines.append("crew surface    %s" % crew.attachment.surface_name)
		lines.append("crew uv         (%.2f, %.2f)" % [
			crew.attachment.surface_uv.x, crew.attachment.surface_uv.y])
	_debug_label.text = "\n".join(lines)
