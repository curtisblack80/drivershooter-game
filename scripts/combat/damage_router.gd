class_name DamageRouter
extends RefCounted

## Turns "this raycast hit this collider" into "this entity took damage".
##
## The thing a shot physically hits is rarely the thing that owns health. A
## bullet strikes a CollisionShape3D belonging to a hitbox node, three levels
## below the enemy that should actually lose health; a shot into a vehicle hits
## the chassis body, which routes damage to a *component* rather than a health
## pool. Scattering that knowledge across every weapon is how combat code turns
## into a pile of special cases.
##
## So damage is delivered through one duck-typed method:
##
##     server_take_damage(amount, damage_type, source_peer_id, hit_point) -> float
##
## The router walks up from whatever was hit until it finds the first node that
## implements it. Anything that can be damaged — crew member, enemy, vehicle,
## destructible barrier — just implements that method, and every weapon in the
## game can hurt it without knowing what it is.
##
## Everything here is server-only. Clients predict effects, never damage.

## How far up the tree to search before giving up. Deep enough for
## body -> hitbox -> rig -> character, shallow enough that a stray hit on level
## geometry does not walk the entire scene.
const MAX_ANCESTOR_DEPTH: int = 6


## Deliver damage to whatever owns `collider`. Returns the amount actually
## applied, or 0.0 if nothing along the chain could take damage (a wall, say).
static func apply(collider: Object, hit_point: Vector3, amount: float,
		damage_type: int, source_peer_id: int) -> float:
	var target: Node = find_damageable(collider)
	if target == null:
		return 0.0
	return float(target.call(&"server_take_damage", amount, damage_type, source_peer_id, hit_point))


## The nearest node at or above `collider` that can take damage, or null.
static func find_damageable(collider: Object) -> Node:
	var node: Node = collider as Node
	var depth: int = 0
	while node != null and depth < MAX_ANCESTOR_DEPTH:
		if node.has_method(&"server_take_damage"):
			return node
		node = node.get_parent()
		depth += 1
	return null


## True when `collider` belongs to the entity owned by `peer_id`. Used to stop
## a crew member shooting themselves at point-blank range, and to keep friendly
## fire out of Phase 1.
static func belongs_to_peer(collider: Object, peer_id: int) -> bool:
	var node: Node = collider as Node
	var depth: int = 0
	while node != null and depth < MAX_ANCESTOR_DEPTH:
		if node.has_method(&"owning_peer_id"):
			return int(node.call(&"owning_peer_id")) == peer_id
		node = node.get_parent()
		depth += 1
	return false
