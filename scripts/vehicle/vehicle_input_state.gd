class_name VehicleInputState
extends RefCounted

## The complete set of driving inputs for one physics step.
##
## Every path that can drive a vehicle — a local player, a replayed input
## packet, an AI convoy driver — produces one of these, and VehicleController
## consumes nothing else. Keeping the input surface to a single struct is what
## makes the authority model swappable: moving to a predicted,
## server-authoritative vehicle later means shipping this struct to the server
## each tick, and nothing inside the controller has to change.

## -1.0 (full reverse) .. 1.0 (full throttle).
var throttle: float = 0.0

## 0.0 .. 1.0. Separate from negative throttle so that "brake" and "reverse" stay
## distinguishable — they mean different things once the vehicle is already
## rolling backwards.
var brake: float = 0.0

## -1.0 (full left) .. 1.0 (full right).
var steer: float = 0.0

var handbrake: bool = false


func reset() -> void:
	throttle = 0.0
	brake = 0.0
	steer = 0.0
	handbrake = false


func copy_from(other: VehicleInputState) -> void:
	throttle = other.throttle
	brake = other.brake
	steer = other.steer
	handbrake = other.handbrake


## Clamp everything into range. Applied to any input that arrived over the
## network, so a malformed or hostile packet cannot inject a 900x throttle.
func sanitise() -> void:
	throttle = clampf(throttle, -1.0, 1.0)
	brake = clampf(brake, 0.0, 1.0)
	steer = clampf(steer, -1.0, 1.0)


func to_dict() -> Dictionary:
	return {"t": throttle, "b": brake, "s": steer, "h": handbrake}


static func from_dict(data: Dictionary) -> VehicleInputState:
	var state := VehicleInputState.new()
	state.throttle = float(data.get("t", 0.0))
	state.brake = float(data.get("b", 0.0))
	state.steer = float(data.get("s", 0.0))
	state.handbrake = bool(data.get("h", false))
	state.sanitise()
	return state


func is_idle() -> bool:
	return is_zero_approx(throttle) and is_zero_approx(brake) \
		and is_zero_approx(steer) and not handbrake
