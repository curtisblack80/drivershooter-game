@tool
class_name VehicleDefinition
extends Resource

## Data-driven description of a vehicle class.
##
## Everything that differs between a Fast Attack Vehicle and a Heavy Transport
## lives in one of these resources, so adding a vehicle class means authoring a
## .tres and a scene — never editing VehicleController. The controller reads
## these numbers and owns no per-vehicle constants of its own.
##
## Component maximum health is a Dictionary keyed by GameEnums.VehicleComponent
## rather than a fixed set of exported floats, so a vehicle can simply omit
## components it does not have (a bike has no rear wheels; a support truck may
## have two engines later) without every vehicle carrying dead fields.

@export_group("Identity")
## Stable identifier used over the network and in save data. Must be unique.
@export var vehicle_id: StringName = &""
@export var display_name: String = "Unnamed Vehicle"
@export_multiline var description: String = ""
## The scene instantiated for this vehicle. Its root must extend VehicleController.
##
## Leave this EMPTY on a definition that the vehicle scene itself references,
## which is the normal case: the scene points at the definition, so a definition
## pointing back at the scene is a resource cycle that the loader has no good way
## to resolve. It is filled in only on catalogue entries used by vehicle
## selection, which nothing inside a vehicle scene loads.
@export var scene: PackedScene = null

@export_group("Mass and Handling")
@export_range(400.0, 20000.0, 10.0) var mass: float = 1800.0
## Top speed under power, in km/h. Enforced by cutting engine force, not by
## clamping velocity: clamping fights the physics solver and makes collisions
## behave strangely.
@export_range(20.0, 300.0, 1.0) var max_speed_kph: float = 130.0
@export_range(0.0, 12000.0, 10.0) var engine_force: float = 2600.0
## Reverse is deliberately weaker than forward, as on a real gearbox.
@export_range(0.0, 8000.0, 10.0) var reverse_force: float = 1200.0
@export_range(0.0, 400.0, 1.0) var brake_force: float = 55.0
@export_range(5.0, 60.0, 0.5) var max_steer_angle_deg: float = 32.0
## Seconds for the steering angle to close half the gap to its target. Lower is
## twitchier. This is what makes a heavy transport feel heavy.
@export_range(0.01, 0.6, 0.01) var steer_half_life: float = 0.09
## Fraction of full steering lock still available at max speed. Without this,
## a light vehicle flips the instant it is turned at speed.
@export_range(0.05, 1.0, 0.01) var steer_authority_at_top_speed: float = 0.32
## Downward force proportional to speed, in newtons per (m/s). Keeps wheels
## planted through jumps and hard turns; the single most effective knob for
## "crew members stay on the roof".
@export_range(0.0, 400.0, 1.0) var downforce_per_speed: float = 90.0
## Rear wheel grip multiplier while the handbrake is held. Below ~0.4 the
## vehicle will drift.
@export_range(0.05, 1.0, 0.01) var handbrake_grip: float = 0.35

@export_group("Recovery")
## Whether the vehicle rights itself when it ends up on its roof. Co-op players
## stranded upside down is not interesting failure, it is just downtime.
@export var allow_self_right: bool = true
## Seconds inverted and nearly stationary before self-righting kicks in.
@export_range(0.5, 10.0, 0.1) var self_right_delay: float = 2.5
@export_range(0.0, 200.0, 1.0) var self_right_torque: float = 45.0

@export_group("Durability")
## Flat damage reduction applied before component damage, from intact armour.
@export_range(0.0, 0.95, 0.01) var armor_damage_reduction: float = 0.25
## GameEnums.VehicleComponent -> maximum health (float).
@export var component_max_health: Dictionary = {}

@export_group("Crew")
@export_range(1, 8, 1) var crew_capacity: int = 4
## Extra metres of camera distance for larger vehicles.
@export_range(0.0, 8.0, 0.1) var camera_distance_bonus: float = 0.0


## Maximum health for a component, or 0.0 when this vehicle has no such part.
func max_health_for(component: int) -> float:
	return float(component_max_health.get(component, 0.0))


func has_component(component: int) -> bool:
	return component_max_health.has(component)


func max_speed_ms() -> float:
	return max_speed_kph / 3.6


func max_steer_angle_rad() -> float:
	return deg_to_rad(max_steer_angle_deg)


## Steering authority remaining at `speed_ms`, from 1.0 at rest down to
## `steer_authority_at_top_speed` at the vehicle's top speed.
func steer_authority_at(speed_ms: float) -> float:
	var top: float = maxf(max_speed_ms(), 0.001)
	var normalised: float = clampf(speed_ms / top, 0.0, 1.0)
	return lerpf(1.0, steer_authority_at_top_speed, normalised)


## Sanity checks, reported by VehicleController at load. Surfaces
## misconfiguration as a readable warning rather than as confusing behaviour
## three systems downstream.
func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if String(vehicle_id).is_empty():
		problems.append("vehicle_id is empty; it is the network identifier and must be set.")
	# `scene` being empty is not a problem: it is the documented, correct state
	# for a definition that a vehicle scene references, since the reverse link
	# would form a resource load cycle. Only catalogue entries fill it in.
	if reverse_force > engine_force:
		problems.append("reverse_force exceeds engine_force, which will feel wrong.")
	if component_max_health.is_empty():
		problems.append("component_max_health is empty; this vehicle cannot take component damage.")
	return problems
