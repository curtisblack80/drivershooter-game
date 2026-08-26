class_name GameEnums
extends RefCounted

## Shared enumerations.
##
## These live in one place so that networking code, gameplay code and UI code all
## agree on the integer values that travel over RPCs. Never reorder existing
## entries: the integer value is what is serialised across the wire, so inserting
## a value in the middle silently changes the meaning of every packet in flight
## between mismatched builds. Append new entries at the end of an enum instead.


## The gameplay role a crew member has signed up for. Roles are a loadout and a
## seat preference, not a hard lock: any crew member may occupy any seat that
## accepts them (see VehicleAttachmentPoint.accepted_roles).
enum CrewRole {
	NONE = 0,
	DRIVER = 1,
	GUNNER = 2,
	ENGINEER = 3,
}


## Where a crew member physically is. This is the master state of the crew state
## machine; see scripts/player/crew_state_machine.gd.
enum CrewState {
	## Not yet attached to any vehicle (pre-spawn / spectating).
	UNASSIGNED = 0,
	## Locked to a seat attachment point. Local transform equals the seat's.
	SEATED = 1,
	## Standing on a VehicleSurface, free to move within its bounds.
	ON_SURFACE = 2,
	## Mid-transition along a VehicleTraversalLink (climbing, vaulting, ...).
	TRAVERSING = 3,
	## Off the vehicle entirely, moving through the world under normal physics.
	DISMOUNTED = 4,
	## Incapacitated but revivable.
	DOWNED = 5,
	## Dead, awaiting respawn.
	DEAD = 6,
}


## What a VehicleAttachmentPoint is for. Drives which interactions the point
## offers and which crew states can occupy it.
enum AttachmentType {
	## A ride position inside (or on) the vehicle. Occupancy is exclusive.
	SEAT = 0,
	## The anchor/landing spot associated with a VehicleSurface region.
	SURFACE_ANCHOR = 1,
	## A repair interaction point bound to a vehicle component.
	REPAIR = 2,
	## A mount a crew member can man to use a vehicle weapon.
	WEAPON_MOUNT = 3,
	## Where a dismounted player may board the vehicle.
	ENTRY = 4,
	## Where a crew member may drop off the vehicle to the ground.
	EXIT = 5,
	## Non-interactive labelled location (VFX, camera hints, AI targeting).
	MARKER = 6,
}


## The flavour of a traversal link, used to pick the motion curve and (later) the
## animation that plays while moving along it.
enum TraversalKind {
	## Short step between adjacent surfaces; nearly flat.
	STEP = 0,
	## Through a window opening: arcs up and over a sill.
	CLIMB_WINDOW = 1,
	## Over a low obstacle such as a door top or roof rack.
	VAULT = 2,
	## Vertical climb, e.g. up a ladder on a transport's rear.
	LADDER = 3,
	## Controlled drop down to a lower surface.
	DROP = 4,
}


## Lobby / match lifecycle. Owned by the server; mirrored to clients.
enum MatchState {
	## No session. Main menu.
	IDLE = 0,
	## Peers connected, choosing roles and vehicle.
	LOBBY = 1,
	## Level is being instantiated on every peer.
	LOADING = 2,
	## Gameplay running.
	PLAYING = 3,
	## Match over, showing results.
	RESULTS = 4,
}


## Individually damageable vehicle components. Phase 1 only wires up a subset,
## but the identifiers are defined now so that damage packets stay stable as the
## damage model fills in during Phase 3.
enum VehicleComponent {
	ENGINE = 0,
	TRANSMISSION = 1,
	FUEL_TANK = 2,
	WHEEL_FRONT_LEFT = 3,
	WHEEL_FRONT_RIGHT = 4,
	WHEEL_REAR_LEFT = 5,
	WHEEL_REAR_RIGHT = 6,
	ARMOR = 7,
	RADIATOR = 8,
	ELECTRICAL = 9,
	WEAPON_MOUNT = 10,
	WINDOWS = 11,
	DOORS = 12,
}


## Damage classification. Used by armour mitigation and by component-specific
## vulnerability multipliers.
enum DamageType {
	BALLISTIC = 0,
	EXPLOSIVE = 1,
	FIRE = 2,
	COLLISION = 3,
}


## How a weapon resolves a shot.
enum WeaponFireMode {
	## Instant raycast. Used for pistols, rifles, snipers.
	HITSCAN = 0,
	## Spawns a travelling projectile. Used for launchers and heavy weapons.
	PROJECTILE = 1,
}


## Human-readable names, for UI and logs. Keep in sync with the enums above.
const ROLE_NAMES: Dictionary = {
	CrewRole.NONE: "Unassigned",
	CrewRole.DRIVER: "Driver",
	CrewRole.GUNNER: "Gunner",
	CrewRole.ENGINEER: "Engineer",
}

const CREW_STATE_NAMES: Dictionary = {
	CrewState.UNASSIGNED: "Unassigned",
	CrewState.SEATED: "Seated",
	CrewState.ON_SURFACE: "On Surface",
	CrewState.TRAVERSING: "Traversing",
	CrewState.DISMOUNTED: "Dismounted",
	CrewState.DOWNED: "Downed",
	CrewState.DEAD: "Dead",
}

const COMPONENT_NAMES: Dictionary = {
	VehicleComponent.ENGINE: "Engine",
	VehicleComponent.TRANSMISSION: "Transmission",
	VehicleComponent.FUEL_TANK: "Fuel Tank",
	VehicleComponent.WHEEL_FRONT_LEFT: "Front Left Wheel",
	VehicleComponent.WHEEL_FRONT_RIGHT: "Front Right Wheel",
	VehicleComponent.WHEEL_REAR_LEFT: "Rear Left Wheel",
	VehicleComponent.WHEEL_REAR_RIGHT: "Rear Right Wheel",
	VehicleComponent.ARMOR: "Armor",
	VehicleComponent.RADIATOR: "Radiator",
	VehicleComponent.ELECTRICAL: "Electrical System",
	VehicleComponent.WEAPON_MOUNT: "Weapon Mount",
	VehicleComponent.WINDOWS: "Windows",
	VehicleComponent.DOORS: "Doors",
}


static func role_name(role: int) -> String:
	return String(ROLE_NAMES.get(role, "Unknown"))


static func crew_state_name(state: int) -> String:
	return String(CREW_STATE_NAMES.get(state, "Unknown"))


static func component_name(component: int) -> String:
	return String(COMPONENT_NAMES.get(component, "Unknown"))
