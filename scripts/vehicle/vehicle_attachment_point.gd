@tool
class_name VehicleAttachmentPoint
extends Node3D

## A named, typed location on a vehicle that crew members can occupy or interact
## with.
##
## This is the unit that makes crew positioning data-driven. A new vehicle
## defines its own seats, hatches, repair hatches and weapon mounts by placing
## these nodes in its scene; no controller code knows the name or position of any
## seat on any specific vehicle.
##
## Placement convention: the node's own transform *is* the crew pose. Its origin
## is where the crew member's feet (or seat base) go, and its -Z axis is the
## direction they face. Rotate the node in the editor to aim a gunner outward.
##
## Occupancy is server-authoritative and lives here, but is only ever mutated
## through VehicleRig, which is the node that owns the seat-claim RPCs.

## Bit positions used by `accepted_role_flags`. Role enum values are 1-based, so
## a role maps to `1 << (role - 1)`.
const ROLE_FLAG_DRIVER: int = 1
const ROLE_FLAG_GUNNER: int = 2
const ROLE_FLAG_ENGINEER: int = 4

@export_group("Identity")
## Unique within a vehicle. Travels over the network in seat-claim RPCs, so it
## must be stable: renaming it in a shipped build breaks save data and mismatched
## clients. Leave empty to fall back to the node's name.
@export var point_name: StringName = &""

## Matches GameEnums.AttachmentType. Declared with @export_enum rather than the
## enum type so the inspector shows readable labels and the stored value is a
## plain int, which is what crosses the wire.
@export_enum("Seat", "Surface Anchor", "Repair", "Weapon Mount", "Entry", "Exit", "Marker")
var point_type: int = GameEnums.AttachmentType.SEAT

@export_group("Occupancy")
## Only one crew member at a time. True for seats and weapon mounts; usually
## false for markers.
@export var exclusive: bool = true

## Which roles may occupy this point. 0 means "any role" — that is the default,
## and the right default: roles are a loadout, and locking a panicking crew out
## of the driver seat because they picked Gunner would be hostile design.
@export_flags("Driver", "Gunner", "Engineer") var accepted_role_flags: int = 0

## Exactly one point per vehicle should set this. Occupying it makes that crew
## member the driver, which also moves the vehicle's network authority.
@export var is_driver_seat: bool = false

@export_group("Behaviour")
## For Surface Anchor points: the VehicleSurface a crew member stands on after
## arriving here. Required for Surface Anchor, ignored otherwise.
@export_node_path("Node3D") var surface_path: NodePath = NodePath()

## For Repair points: which component this hatch services.
## Matches GameEnums.VehicleComponent.
@export_enum("Engine", "Transmission", "Fuel Tank", "Front Left Wheel", "Front Right Wheel",
	"Rear Left Wheel", "Rear Right Wheel", "Armor", "Radiator", "Electrical System",
	"Weapon Mount", "Windows", "Doors")
var repair_component: int = GameEnums.VehicleComponent.ENGINE

## How close a crew member must be (in metres, measured in vehicle-local space)
## for this point to offer its interaction.
@export_range(0.2, 4.0, 0.05) var interaction_radius: float = 1.1

## Shown in the HUD prompt. "%s" is not substituted; write the whole phrase.
@export var prompt_text: String = ""

@export_group("Camera")
## Extra camera distance while occupying this point. A roof gunner wants a wider
## view than someone wedged in a rear seat.
@export_range(-3.0, 8.0, 0.1) var camera_distance_bonus: float = 0.0
## Extra camera height while occupying this point.
@export_range(-2.0, 4.0, 0.1) var camera_height_bonus: float = 0.0

## Peer id currently occupying this point, or 0 when free.
## Server-authoritative; mutated only by VehicleRig.
var occupant_peer_id: int = 0

## This point's transform relative to the vehicle's crew frame (the VehicleRig).
## Cached at bind time because it never changes: attachment points are rigidly
## fixed to the chassis, so recomputing it per frame per crew member would be
## pure waste.
var rig_local_transform: Transform3D = Transform3D.IDENTITY

## Yaw of this point within the crew frame, derived from rig_local_transform.
var rig_local_yaw: float = 0.0

var _rig: Node3D = null
var _surface: VehicleSurface = null


func _ready() -> void:
	if String(point_name).is_empty():
		point_name = StringName(name)


## Called by VehicleRig during its scan. Caches everything that depends on where
## this point sits relative to the crew frame.
func bind_to_rig(rig: Node3D) -> void:
	_rig = rig
	if String(point_name).is_empty():
		point_name = StringName(name)
	rig_local_transform = rig.global_transform.affine_inverse() * global_transform
	rig_local_yaw = MathUtil.yaw_from_direction(-rig_local_transform.basis.z)

	_surface = null
	if not surface_path.is_empty():
		_surface = get_node_or_null(surface_path) as VehicleSurface
		if _surface == null:
			GameLog.warn("vehicle", "attachment point '%s' has surface_path '%s' which is not a VehicleSurface"
				% [point_name, surface_path])


func surface() -> VehicleSurface:
	return _surface


func is_free() -> bool:
	return not exclusive or occupant_peer_id == 0


func is_occupied_by(peer_id: int) -> bool:
	return occupant_peer_id == peer_id


## Whether a crew member with `role` (GameEnums.CrewRole) may take this point.
func accepts_role(role: int) -> bool:
	if accepted_role_flags == 0:
		return true
	if role == GameEnums.CrewRole.NONE:
		# Unassigned crew can use anything that is not role-restricted.
		return false
	return (accepted_role_flags & (1 << (role - 1))) != 0


func is_seat() -> bool:
	return point_type == GameEnums.AttachmentType.SEAT


func is_surface_anchor() -> bool:
	return point_type == GameEnums.AttachmentType.SURFACE_ANCHOR


## Prompt to show when a crew member is in range, falling back to something
## sensible so an unauthored point is still usable.
func effective_prompt() -> String:
	if not prompt_text.is_empty():
		return prompt_text
	match point_type:
		GameEnums.AttachmentType.SEAT:
			return "Take seat" if not is_driver_seat else "Take the wheel"
		GameEnums.AttachmentType.REPAIR:
			return "Repair %s" % GameEnums.component_name(repair_component)
		GameEnums.AttachmentType.WEAPON_MOUNT:
			return "Man weapon"
		GameEnums.AttachmentType.ENTRY:
			return "Board vehicle"
		GameEnums.AttachmentType.EXIT:
			return "Dismount"
		_:
			return ""


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = PackedStringArray()
	if point_type == GameEnums.AttachmentType.SURFACE_ANCHOR and surface_path.is_empty():
		warnings.append("Surface Anchor points must set surface_path to a VehicleSurface.")
	if is_driver_seat and point_type != GameEnums.AttachmentType.SEAT:
		warnings.append("is_driver_seat is only meaningful on a Seat point.")
	if not exclusive and point_type == GameEnums.AttachmentType.SEAT:
		warnings.append("A non-exclusive Seat would let several crew occupy the same seat.")
	return warnings
