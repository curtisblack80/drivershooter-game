@tool
class_name VehicleSurface
extends Node3D

## A rectangular region of a vehicle that crew members can walk around on: the
## hood, the roof, a running board, the trunk, the cargo bed.
##
## ============================================================================
## WHY A DESIGNED SURFACE INSTEAD OF PHYSICS COLLISION
## ============================================================================
##
## The intuitive implementation is to let a CharacterBody3D walk on the
## vehicle's collision mesh. That does not survive contact with this game. A
## character controller resolves motion against a world that it assumes is
## roughly static; the vehicle underneath it is doing 30 m/s, changing
## orientation, and getting shot. The failure modes are all familiar from games
## that tried it: the player sinks through the roof on a bump, gets launched on a
## landing, or slides off during a hard turn because friction is not a contract.
##
## So crew traversal does not use physics at all. A surface is a plane with
## bounds, expressed in the vehicle's own coordinate space. A crew member's
## position on it is a 2D coordinate within those bounds, and their world
## position is recomposed each frame from the vehicle's transform. The vehicle
## can flip, launch, or be shunted by an explosion, and the arithmetic is
## unchanged — the crew member is exactly as attached as they were before,
## because attachment is not something that can fail.
##
## What this gives up: crew members do not collide with world geometry while on
## the vehicle, so driving under a low bridge will not sweep a roof gunner off.
## That is a gameplay behaviour to add deliberately later (a swept-volume test
## against the world along the crew member's path, triggering a knock-off state),
## not an emergent physics accident.
##
## Placement convention: the node's local XZ plane is the walkable surface and
## its +Y is "up" for anyone standing on it. `half_extents` is measured from the
## node's origin outward, in metres, along local X and local Z.

@export_group("Identity")
## Unique within a vehicle. Crosses the network in crew state updates.
@export var surface_name: StringName = &""

@export_group("Bounds")
## Half-size of the walkable rectangle: X is local X, Y is local Z.
@export var half_extents: Vector2 = Vector2(0.75, 1.1)

## How far past the edge a crew member may drift before they are considered to
## have left the surface. Small and forgiving: a hard clamp at the exact edge
## makes the surface feel like an invisible box.
@export_range(0.0, 0.6, 0.01) var edge_margin: float = 0.12

@export_group("Movement")
## Multiplies the crew member's walk speed here. Lower it for awkward footing
## like a sloped hood or a narrow running board.
@export_range(0.1, 2.0, 0.05) var walk_speed_scale: float = 1.0

## Crew on this surface are inside the vehicle body (cabin floor, cargo bay).
## Interior surfaces do not apply the wind/instability penalty and do not expose
## crew to fire from outside.
@export var is_interior: bool = false

## How exposed this surface is, 0.0 (fully sheltered) to 1.0 (fully in the open).
## Scales how much vehicle acceleration destabilises a crew member standing here,
## so the roof is a genuinely riskier firing position than the cabin.
@export_range(0.0, 1.0, 0.05) var exposure: float = 1.0

## This surface's transform relative to the vehicle's crew frame. Cached at bind
## time; surfaces are rigidly fixed to the chassis.
var rig_local_transform: Transform3D = Transform3D.IDENTITY
var _rig_local_inverse: Transform3D = Transform3D.IDENTITY

var _rig: Node3D = null


func _ready() -> void:
	if String(surface_name).is_empty():
		surface_name = StringName(name)


## Called by VehicleRig during its scan.
func bind_to_rig(rig: Node3D) -> void:
	_rig = rig
	if String(surface_name).is_empty():
		surface_name = StringName(name)
	rig_local_transform = rig.global_transform.affine_inverse() * global_transform
	_rig_local_inverse = rig_local_transform.affine_inverse()


## Convert a surface coordinate (metres along local X and local Z) into a
## position in the vehicle's crew frame.
func uv_to_rig(uv: Vector2) -> Vector3:
	return rig_local_transform * Vector3(uv.x, 0.0, uv.y)


## Convert a position in the vehicle's crew frame into a surface coordinate.
## The local Y component is discarded: this is a projection onto the plane.
func rig_to_uv(rig_position: Vector3) -> Vector2:
	var local: Vector3 = _rig_local_inverse * rig_position
	return Vector2(local.x, local.z)


## Height of `rig_position` above this surface's plane. Used to tell whether a
## crew member arriving from a traversal is standing on the surface or above it.
func height_above(rig_position: Vector3) -> float:
	return (_rig_local_inverse * rig_position).y


## Clamp a surface coordinate into the walkable rectangle.
func clamp_uv(uv: Vector2) -> Vector2:
	return Vector2(
		clampf(uv.x, -half_extents.x, half_extents.x),
		clampf(uv.y, -half_extents.y, half_extents.y)
	)


func contains_uv(uv: Vector2, extra_margin: float = 0.0) -> bool:
	var limit: Vector2 = half_extents + Vector2(edge_margin + extra_margin, edge_margin + extra_margin)
	return absf(uv.x) <= limit.x and absf(uv.y) <= limit.y


## How far outside the rectangle `uv` is, in metres. 0.0 when inside.
func distance_outside(uv: Vector2) -> float:
	var overflow: Vector2 = Vector2(
		maxf(absf(uv.x) - half_extents.x, 0.0),
		maxf(absf(uv.y) - half_extents.y, 0.0)
	)
	return overflow.length()


## The surface's up direction expressed in the vehicle's crew frame. Crew members
## stand along this, so a sloped hood tilts them correctly.
func up_in_rig() -> Vector3:
	return rig_local_transform.basis.y.normalized()


## World-space position of a surface coordinate. Only valid while bound.
func uv_to_global(uv: Vector2) -> Vector3:
	if _rig == null:
		return global_transform * Vector3(uv.x, 0.0, uv.y)
	return _rig.global_transform * uv_to_rig(uv)


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = PackedStringArray()
	if half_extents.x <= 0.0 or half_extents.y <= 0.0:
		warnings.append("half_extents must be positive on both axes; this surface has no walkable area.")
	if half_extents.x < 0.2 or half_extents.y < 0.2:
		warnings.append("This surface is narrower than a crew member's stance and will feel like a tightrope.")
	return warnings
