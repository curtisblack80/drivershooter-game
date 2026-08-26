class_name TracerEffect
extends MeshInstance3D

## A short-lived visible line for one shot.
##
## Hitscan weapons resolve instantly, so without a tracer a firefight is silent
## flashes and health bars moving — which makes a prototype almost impossible to
## judge, because you cannot see whether shots go where you aimed. This is
## placeholder presentation: real muzzle flashes, impact decals and shell
## ejection belong in Phase 8, but seeing the line matters from the first test.
##
## Implemented as a stretched box rather than an ImmediateMesh so that a single
## BoxMesh and one material per colour are shared across every tracer in flight.

## Cross-section of the tracer, in metres.
const THICKNESS: float = 0.022

## Shared geometry: every tracer is the same unit box, scaled by its transform.
static var _shared_mesh: BoxMesh = null
## Colour -> StandardMaterial3D, so a firefight does not allocate a material per
## shot.
static var _materials: Dictionary = {}


## Create a tracer between two world points, parented under `parent`, and free it
## after `lifetime` seconds.
static func spawn(parent: Node, from: Vector3, to: Vector3, color: Color,
		lifetime: float = 0.06) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var length: float = from.distance_to(to)
	if length < 0.05:
		return

	var tracer := TracerEffect.new()
	tracer.mesh = _get_mesh()
	tracer.material_override = _get_material(color)
	tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(tracer)

	# Orient the unit box along the shot and scale it to length. looking_at
	# fails when the direction is parallel to the reference up vector, so pick a
	# different reference in that case rather than producing a NaN basis.
	var midpoint: Vector3 = (from + to) * 0.5
	var direction: Vector3 = (to - from).normalized()
	var reference_up: Vector3 = Vector3.UP
	if absf(direction.dot(reference_up)) > 0.99:
		reference_up = Vector3.RIGHT

	# Scale is baked into the basis rather than assigned to `scale` afterwards:
	# `scale` is a local property, so setting it after a global_transform
	# assignment would be re-interpreted through the parent's transform.
	var basis: Basis = Basis.looking_at(direction, reference_up) \
		.scaled(Vector3(THICKNESS, THICKNESS, length))
	tracer.global_transform = Transform3D(basis, midpoint)

	var timer: SceneTreeTimer = tracer.get_tree().create_timer(lifetime, false)
	timer.timeout.connect(tracer.queue_free)


static func _get_mesh() -> BoxMesh:
	if _shared_mesh == null:
		_shared_mesh = BoxMesh.new()
		_shared_mesh.size = Vector3.ONE
	return _shared_mesh


static func _get_material(color: Color) -> StandardMaterial3D:
	if _materials.has(color):
		return _materials[color]
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.0
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.disable_receive_shadows = true
	_materials[color] = material
	return material
