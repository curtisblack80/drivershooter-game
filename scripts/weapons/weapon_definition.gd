@tool
class_name WeaponDefinition
extends Resource

## Data-driven weapon stats.
##
## Every weapon in the game is one of these plus a model. Weapon.gd contains no
## per-weapon constants, so adding an SMG is authoring a .tres, not writing a
## class.

@export_group("Identity")
@export var weapon_id: StringName = &""
@export var display_name: String = "Unnamed Weapon"

## Matches GameEnums.WeaponFireMode.
##
## Only Hitscan is implemented. Projectile is defined here because the data model
## needs it and launchers arrive in Phase 5; a weapon set to Projectile logs an
## error rather than silently behaving like a rifle.
@export_enum("Hitscan", "Projectile") var fire_mode: int = GameEnums.WeaponFireMode.HITSCAN

@export_group("Damage")
@export_range(1.0, 500.0, 1.0) var damage: float = 22.0
## Matches GameEnums.DamageType.
@export_enum("Ballistic", "Explosive", "Fire", "Collision")
var damage_type: int = GameEnums.DamageType.BALLISTIC
## Pellets per trigger pull. Above 1 makes it a shotgun.
@export_range(1, 24, 1) var pellets: int = 1
@export_range(5.0, 500.0, 1.0) var max_range: float = 180.0
## Fraction of damage remaining at max_range. 1.0 disables falloff.
@export_range(0.05, 1.0, 0.05) var damage_at_max_range: float = 0.45

@export_group("Handling")
@export_range(30.0, 1400.0, 5.0) var rounds_per_minute: float = 520.0
@export var automatic: bool = true
@export_range(1, 200, 1) var magazine_size: int = 30
@export_range(0.3, 8.0, 0.1) var reload_seconds: float = 2.1
## Cone half-angle while hip-firing, in degrees.
@export_range(0.0, 20.0, 0.1) var spread_degrees: float = 2.4
## Cone half-angle while aiming down sights.
@export_range(0.0, 20.0, 0.1) var aim_spread_degrees: float = 0.6
## Extra spread added per shot while firing continuously, in degrees.
@export_range(0.0, 6.0, 0.05) var spread_growth_per_shot: float = 0.35
## Degrees of accumulated spread shed per second once the trigger is released.
@export_range(0.5, 30.0, 0.5) var spread_recovery_per_second: float = 7.0
@export_range(0.0, 12.0, 0.1) var max_extra_spread_degrees: float = 3.5

@export_group("Presentation")
@export var tracer_color: Color = Color(1.0, 0.86, 0.5, 1.0)
@export_range(0.0, 1.0, 0.01) var tracer_lifetime: float = 0.06


func seconds_between_shots() -> float:
	return 60.0 / maxf(rounds_per_minute, 1.0)


func spread_radians(aiming: bool) -> float:
	return deg_to_rad(aim_spread_degrees if aiming else spread_degrees)


## Damage after range falloff.
func damage_at_distance(distance: float) -> float:
	if damage_at_max_range >= 1.0 or max_range <= 0.0:
		return damage
	var normalised: float = clampf(distance / max_range, 0.0, 1.0)
	return damage * lerpf(1.0, damage_at_max_range, normalised)


func validate() -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	if String(weapon_id).is_empty():
		problems.append("weapon_id is empty.")
	if fire_mode == GameEnums.WeaponFireMode.PROJECTILE:
		problems.append("Projectile fire mode is not implemented yet (Phase 5); this weapon will refuse to fire.")
	if aim_spread_degrees > spread_degrees:
		problems.append("aim_spread_degrees is larger than hip spread, so aiming makes accuracy worse.")
	return problems
