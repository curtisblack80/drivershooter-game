class_name PlayerInputState
extends RefCounted

## All local input for one player, gathered in one place.
##
## Nothing else in the player stack reads the Input singleton. That is what makes
## the same code path usable for a replay, an AI-driven crew member, or a network
## test harness: swap what fills this struct and everything downstream is
## unchanged.
##
## Mouse look is accumulated from events rather than polled, because a poll
## samples the pointer once per frame and silently drops motion that arrived in
## between — which shows up as the camera feeling coarse at low frame rates.

## Movement axes. x is strafe (+right), y is forward (+forward).
var move: Vector2 = Vector2.ZERO

var sprint_held: bool = false
var jump_pressed: bool = false

var fire_held: bool = false
var fire_pressed: bool = false
var aim_held: bool = false
var reload_pressed: bool = false

var interact_pressed: bool = false
var cycle_pressed: bool = false
var leave_seat_pressed: bool = false

## Accumulated mouse motion since the last take_look_delta(), in pixels.
var _look_accumulator: Vector2 = Vector2.ZERO


## Feed every input event here from _unhandled_input.
func handle_event(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look_accumulator += (event as InputEventMouseMotion).relative


## Read the action state for this frame. When `enabled` is false everything is
## cleared, so a player with a menu open neither moves nor shoots — and, just as
## importantly, does not have a burst of queued input fire the moment it closes.
func poll(enabled: bool) -> void:
	if not enabled:
		clear()
		return

	move = Vector2(
		Input.get_axis(&"move_left", &"move_right"),
		Input.get_axis(&"move_back", &"move_forward")
	)
	if move.length() > 1.0:
		move = move.normalized()

	sprint_held = Input.is_action_pressed(&"move_sprint")
	jump_pressed = Input.is_action_just_pressed(&"move_jump")

	fire_held = Input.is_action_pressed(&"combat_fire")
	fire_pressed = Input.is_action_just_pressed(&"combat_fire")
	aim_held = Input.is_action_pressed(&"combat_aim")
	reload_pressed = Input.is_action_just_pressed(&"combat_reload")

	interact_pressed = Input.is_action_just_pressed(&"interact")
	cycle_pressed = Input.is_action_just_pressed(&"interact_cycle")
	leave_seat_pressed = Input.is_action_just_pressed(&"vehicle_leave_seat")


## Return accumulated mouse motion and reset it. Call exactly once per frame:
## calling twice gives the second caller nothing, and never calling lets motion
## pile up into a spin the next time anything reads it.
func take_look_delta() -> Vector2:
	var delta: Vector2 = _look_accumulator
	_look_accumulator = Vector2.ZERO
	return delta


func clear() -> void:
	move = Vector2.ZERO
	sprint_held = false
	jump_pressed = false
	fire_held = false
	fire_pressed = false
	aim_held = false
	reload_pressed = false
	interact_pressed = false
	cycle_pressed = false
	leave_seat_pressed = false
	_look_accumulator = Vector2.ZERO
