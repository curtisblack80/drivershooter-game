class_name MathUtil
extends RefCounted

## Frame-rate independent smoothing and small geometry helpers.
##
## The smoothing functions here are used everywhere the camera, the crew
## controller and the vehicle need to ease toward a target. They are all
## exponential decay rather than `lerp(a, b, delta * k)`, because plain lerp with
## a delta-scaled weight changes behaviour when the frame rate changes and will
## overshoot (or go unstable) if `delta * k` ever exceeds 1.0.


## Exponentially decay `current` toward `target`.
## `half_life` is the time in seconds to close half the remaining distance,
## which is an intuitive unit to tune: 0.05 is snappy, 0.4 is lazy.
static func damp(current: float, target: float, half_life: float, delta: float) -> float:
	if half_life <= 0.0:
		return target
	var factor: float = pow(0.5, delta / half_life)
	return target + (current - target) * factor


static func damp_vector3(current: Vector3, target: Vector3, half_life: float, delta: float) -> Vector3:
	if half_life <= 0.0:
		return target
	var factor: float = pow(0.5, delta / half_life)
	return target + (current - target) * factor


static func damp_vector2(current: Vector2, target: Vector2, half_life: float, delta: float) -> Vector2:
	if half_life <= 0.0:
		return target
	var factor: float = pow(0.5, delta / half_life)
	return target + (current - target) * factor


## Angle-aware damping. Takes the short way around the circle.
static func damp_angle(current: float, target: float, half_life: float, delta: float) -> float:
	if half_life <= 0.0:
		return target
	var factor: float = pow(0.5, delta / half_life)
	# Fold the difference into [-PI, PI] before decaying it, so the value never
	# takes the long way around when it crosses the +/-PI seam.
	var difference: float = wrapf(current - target, -PI, PI)
	return target + difference * factor


## Move `current` toward `target` by at most `max_step`, without overshoot.
static func approach(current: float, target: float, max_step: float) -> float:
	var difference: float = target - current
	if absf(difference) <= max_step:
		return target
	return current + signf(difference) * max_step


## Quadratic Bezier. Used for traversal arcs: `control` lifts the path so a crew
## member climbing through a window rises over the sill instead of clipping it.
static func quadratic_bezier(from: Vector3, control: Vector3, to: Vector3, t: float) -> Vector3:
	var inverse: float = 1.0 - t
	return (inverse * inverse * from) + (2.0 * inverse * t * control) + (t * t * to)


## Smootherstep (Ken Perlin's variant): zero first *and* second derivative at
## both ends, so a traversal that uses it starts and stops without a visible
## velocity pop.
static func smoother_step(t: float) -> float:
	var x: float = clampf(t, 0.0, 1.0)
	return x * x * x * (x * (x * 6.0 - 15.0) + 10.0)


## Yaw (rotation about +Y) of a direction vector, in radians, matching Godot's
## convention where -Z is forward.
static func yaw_from_direction(direction: Vector3) -> float:
	var flat: Vector2 = Vector2(direction.x, direction.z)
	if flat.length_squared() < 0.000001:
		return 0.0
	return atan2(-flat.x, -flat.y)


## Clamp a point to an axis-aligned rectangle centred on the origin of the XZ
## plane. `half_extents` is measured from the centre out.
static func clamp_to_rect_xz(local_point: Vector3, half_extents: Vector2) -> Vector3:
	return Vector3(
		clampf(local_point.x, -half_extents.x, half_extents.x),
		local_point.y,
		clampf(local_point.z, -half_extents.y, half_extents.y)
	)


## True when `point` lies inside the centred XZ rectangle, with `margin` grown
## outward. Used for "am I still on this surface" tests.
static func is_inside_rect_xz(local_point: Vector3, half_extents: Vector2, margin: float = 0.0) -> bool:
	return absf(local_point.x) <= half_extents.x + margin \
		and absf(local_point.z) <= half_extents.y + margin
