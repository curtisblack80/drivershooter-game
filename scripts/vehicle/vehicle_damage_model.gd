class_name VehicleDamageModel
extends RefCounted

## Per-component health for one vehicle.
##
## The vehicle deliberately has no single health bar. A crew that has lost its
## radiator has a different problem from a crew that has lost a front wheel, and
## the whole engineering role exists because those problems are distinguishable
## and fixable. A single pooled health value would collapse all of that into one
## number and delete the Engineer's job.
##
## This class is pure state and pure arithmetic — no nodes, no signals fired at
## the tree, no network calls. VehicleController owns an instance, is the only
## thing that mutates it, and is responsible for replicating the result. Keeping
## it a plain object means the damage rules can be unit-tested without standing
## up a scene or a multiplayer peer.
##
## Authority: only the server ever calls apply_damage(). Clients receive the
## resulting health values and display them.

## Fired after any component's health changes. `ratio` is 0..1.
signal component_changed(component: int, ratio: float)

## Fired the first time a component reaches zero.
signal component_disabled(component: int)

## Fired when the vehicle as a whole is no longer operable.
signal vehicle_destroyed()

## Component health below this fraction counts as "critical" for UI and for the
## harsher gameplay effects.
const CRITICAL_RATIO: float = 0.25

## component (int) -> current health (float)
var _health: Dictionary = {}
## component (int) -> maximum health (float)
var _max_health: Dictionary = {}

var _destroyed: bool = false

## How much of an incoming hit intact armour absorbs.
var _armor_reduction: float = 0.0

## Per-damage-type multipliers applied when a component is hit. Wheels shrug off
## small-arms fire but are wrecked by explosions; the fuel tank is the opposite
## of resilient to fire. This is what makes enemy loadouts meaningful.
const VULNERABILITY: Dictionary = {
	GameEnums.VehicleComponent.FUEL_TANK: {
		GameEnums.DamageType.FIRE: 2.5,
		GameEnums.DamageType.EXPLOSIVE: 1.8,
	},
	GameEnums.VehicleComponent.RADIATOR: {
		GameEnums.DamageType.BALLISTIC: 1.4,
	},
	GameEnums.VehicleComponent.WHEEL_FRONT_LEFT: {
		GameEnums.DamageType.BALLISTIC: 0.6,
		GameEnums.DamageType.EXPLOSIVE: 1.6,
	},
	GameEnums.VehicleComponent.WHEEL_FRONT_RIGHT: {
		GameEnums.DamageType.BALLISTIC: 0.6,
		GameEnums.DamageType.EXPLOSIVE: 1.6,
	},
	GameEnums.VehicleComponent.WHEEL_REAR_LEFT: {
		GameEnums.DamageType.BALLISTIC: 0.6,
		GameEnums.DamageType.EXPLOSIVE: 1.6,
	},
	GameEnums.VehicleComponent.WHEEL_REAR_RIGHT: {
		GameEnums.DamageType.BALLISTIC: 0.6,
		GameEnums.DamageType.EXPLOSIVE: 1.6,
	},
}


func configure(definition: VehicleDefinition) -> void:
	_health.clear()
	_max_health.clear()
	_destroyed = false
	if definition == null:
		return
	_armor_reduction = definition.armor_damage_reduction
	for component: Variant in definition.component_max_health.keys():
		var key: int = int(component)
		var maximum: float = maxf(float(definition.component_max_health[component]), 1.0)
		_max_health[key] = maximum
		_health[key] = maximum


func has_component(component: int) -> bool:
	return _max_health.has(component)


func components() -> Array:
	return _max_health.keys()


func health_of(component: int) -> float:
	return float(_health.get(component, 0.0))


func max_health_of(component: int) -> float:
	return float(_max_health.get(component, 0.0))


func ratio_of(component: int) -> float:
	var maximum: float = max_health_of(component)
	if maximum <= 0.0:
		return 0.0
	return clampf(health_of(component) / maximum, 0.0, 1.0)


func is_disabled(component: int) -> bool:
	return has_component(component) and health_of(component) <= 0.0


func is_critical(component: int) -> bool:
	return has_component(component) and ratio_of(component) <= CRITICAL_RATIO


func is_destroyed() -> bool:
	return _destroyed


## Apply damage to one component. Returns the amount actually applied.
##
## Armour soaks a fraction of every hit until the armour component itself is
## gone, at which point the crew is taking full damage everywhere — that is the
## pressure that makes "patch the armour" an urgent call rather than a chore.
func apply_damage(component: int, amount: float, damage_type: int = GameEnums.DamageType.BALLISTIC) -> float:
	if _destroyed or amount <= 0.0 or not has_component(component):
		return 0.0

	var incoming: float = amount * _vulnerability(component, damage_type)

	# Armour mitigates hits on everything except itself.
	if component != GameEnums.VehicleComponent.ARMOR and has_component(GameEnums.VehicleComponent.ARMOR):
		var armor_ratio: float = ratio_of(GameEnums.VehicleComponent.ARMOR)
		incoming *= 1.0 - (_armor_reduction * armor_ratio)

	var before: float = health_of(component)
	if before <= 0.0:
		return 0.0

	var after: float = maxf(before - incoming, 0.0)
	_health[component] = after
	component_changed.emit(component, ratio_of(component))

	if after <= 0.0 and before > 0.0:
		component_disabled.emit(component)
		_check_destroyed()

	return before - after


## Restore health to a component. Returns the amount actually restored.
## `cap_ratio` models field repairs that cannot fully restore a part: an
## emergency patch might cap at 0.6 while a proper repair kit reaches 1.0.
func apply_repair(component: int, amount: float, cap_ratio: float = 1.0) -> float:
	if _destroyed or amount <= 0.0 or not has_component(component):
		return 0.0
	var maximum: float = max_health_of(component)
	var ceiling: float = maximum * clampf(cap_ratio, 0.0, 1.0)
	var before: float = health_of(component)
	if before >= ceiling:
		return 0.0
	var after: float = minf(before + amount, ceiling)
	_health[component] = after
	component_changed.emit(component, ratio_of(component))
	return after - before


func _vulnerability(component: int, damage_type: int) -> float:
	if not VULNERABILITY.has(component):
		return 1.0
	var table: Dictionary = VULNERABILITY[component]
	return float(table.get(damage_type, 1.0))


## The vehicle is finished when the engine is gone and it can no longer be
## nursed along. Losing wheels is crippling but survivable; losing the engine
## with a ruptured fuel tank is not.
func _check_destroyed() -> void:
	if _destroyed:
		return
	var engine_gone: bool = is_disabled(GameEnums.VehicleComponent.ENGINE)
	var fuel_gone: bool = has_component(GameEnums.VehicleComponent.FUEL_TANK) \
		and is_disabled(GameEnums.VehicleComponent.FUEL_TANK)
	if engine_gone and fuel_gone:
		_destroyed = true
		vehicle_destroyed.emit()


# ---------------------------------------------------------------------------
# Gameplay effects
# ---------------------------------------------------------------------------

## Fraction of full engine force still available.
##
## Engine and radiator both feed this: a cooked radiator does not stop the engine
## outright, it strangles it, which gives the crew a window to notice and react
## before the vehicle dies.
func engine_output_scale() -> float:
	if not has_component(GameEnums.VehicleComponent.ENGINE):
		return 1.0
	var engine: float = ratio_of(GameEnums.VehicleComponent.ENGINE)
	if engine <= 0.0:
		return 0.0
	# Falls off gently at first, then steeply once critical.
	var scale: float = lerpf(0.25, 1.0, sqrt(engine))
	if has_component(GameEnums.VehicleComponent.RADIATOR):
		scale *= lerpf(0.55, 1.0, ratio_of(GameEnums.VehicleComponent.RADIATOR))
	return clampf(scale, 0.0, 1.0)


## Grip multiplier for one wheel, 0.15 (shredded) to 1.0 (intact).
func wheel_grip_scale(wheel_component: int) -> float:
	if not has_component(wheel_component):
		return 1.0
	return lerpf(0.15, 1.0, ratio_of(wheel_component))


## Net sideways pull, in the range -1 (drags left) to 1 (drags right), caused by
## asymmetric wheel damage. A blown front-left tyre should fight the driver.
func steering_pull() -> float:
	var left: float = 0.0
	var right: float = 0.0
	var count: int = 0
	if has_component(GameEnums.VehicleComponent.WHEEL_FRONT_LEFT):
		left += 1.0 - ratio_of(GameEnums.VehicleComponent.WHEEL_FRONT_LEFT)
		count += 1
	if has_component(GameEnums.VehicleComponent.WHEEL_REAR_LEFT):
		left += 1.0 - ratio_of(GameEnums.VehicleComponent.WHEEL_REAR_LEFT)
		count += 1
	if has_component(GameEnums.VehicleComponent.WHEEL_FRONT_RIGHT):
		right += 1.0 - ratio_of(GameEnums.VehicleComponent.WHEEL_FRONT_RIGHT)
		count += 1
	if has_component(GameEnums.VehicleComponent.WHEEL_REAR_RIGHT):
		right += 1.0 - ratio_of(GameEnums.VehicleComponent.WHEEL_REAR_RIGHT)
		count += 1
	if count == 0:
		return 0.0
	# A damaged left side drags the vehicle to the left, hence left pulling
	# negative on a +right axis.
	return clampf((right - left) / float(count), -1.0, 1.0)


# ---------------------------------------------------------------------------
# Replication
# ---------------------------------------------------------------------------

## Snapshot of every component's health, for sending to clients.
func to_dict() -> Dictionary:
	var payload: Dictionary = {}
	for component: Variant in _health.keys():
		payload[component] = _health[component]
	return payload


## Overwrite local health from a server snapshot. Emits change signals so the
## HUD updates, but never re-runs destruction logic: whether the vehicle is
## destroyed is the server's call, delivered explicitly.
func apply_snapshot(payload: Dictionary, destroyed: bool) -> void:
	for key: Variant in payload.keys():
		var component: int = int(key)
		if not _max_health.has(component):
			continue
		var value: float = clampf(float(payload[key]), 0.0, max_health_of(component))
		if is_equal_approx(value, health_of(component)):
			continue
		_health[component] = value
		component_changed.emit(component, ratio_of(component))
	if destroyed and not _destroyed:
		_destroyed = true
		vehicle_destroyed.emit()
