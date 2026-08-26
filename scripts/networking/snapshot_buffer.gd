class_name SnapshotBuffer
extends RefCounted

## Buffered interpolation for remotely-owned transforms.
##
## Continuous state arrives at NetConfig.SNAPSHOT_HZ over an unreliable channel:
## irregularly spaced, occasionally dropped, occasionally out of order. Applying
## each packet the moment it lands produces the classic 20 Hz stutter. Instead,
## receivers render remote objects NetConfig.INTERPOLATION_DELAY in the past and
## interpolate between the two samples bracketing that time, which converts
## jitter into a small constant latency — a trade that is always worth making for
## objects the local player does not control.
##
## Time base: samples are stamped with the *receiver's* clock on arrival, not the
## sender's. This deliberately avoids needing clock synchronisation between
## peers. The cost is that a change in one-way latency shows up as a brief
## speed-up or slow-down of the remote object rather than a position correction.
## For co-op PvE that is invisible; a competitive build would want real clock
## sync and sender timestamps here instead.
##
## Ordering: arrival time alone cannot detect a reordered packet, so the sender
## stamps every snapshot with a monotonically increasing sequence number and
## anything not newer than the last accepted sample is discarded.
##
## Sampling writes into `out_position` / `out_rotation` rather than returning a
## container, because this runs once per synchronised object per frame and
## allocating a Dictionary per call would be pure garbage-collector pressure.

class Sample extends RefCounted:
	var sequence: int = 0
	var time: float = 0.0
	var position: Vector3 = Vector3.ZERO
	var rotation: Quaternion = Quaternion.IDENTITY
	var linear_velocity: Vector3 = Vector3.ZERO

## Result of the most recent sample_at() call.
var out_position: Vector3 = Vector3.ZERO
var out_rotation: Quaternion = Quaternion.IDENTITY

## True once at least one snapshot has been accepted.
var has_state: bool = false

## Set by sample_at() when it ran past the end of the buffer and had to
## extrapolate. Useful for a debug overlay: sustained true means the sender is
## starved or the connection is stalling.
var is_extrapolating: bool = false

var _samples: Array = []
var _last_sequence: int = -1


## Record a snapshot. `now` should be the receiver's monotonic clock, normally
## `Time.get_ticks_msec() / 1000.0`.
## Returns false if the snapshot was stale (out of order) and was discarded.
func push_sample(sequence: int, now: float, position: Vector3, rotation: Quaternion,
		linear_velocity: Vector3 = Vector3.ZERO) -> bool:
	if sequence <= _last_sequence:
		return false
	_last_sequence = sequence

	var sample := Sample.new()
	sample.sequence = sequence
	sample.time = now
	sample.position = position
	sample.rotation = rotation.normalized()
	sample.linear_velocity = linear_velocity
	_samples.append(sample)

	while _samples.size() > NetConfig.SNAPSHOT_BUFFER_SIZE:
		_samples.pop_front()

	has_state = true
	return true


## Evaluate the buffer at `render_time` (receiver clock, already delayed by
## NetConfig.INTERPOLATION_DELAY). Writes out_position / out_rotation.
## Returns false when there is nothing to sample yet.
func sample_at(render_time: float) -> bool:
	is_extrapolating = false
	if _samples.is_empty():
		return false

	var newest: Sample = _samples[_samples.size() - 1]
	var oldest: Sample = _samples[0]

	# Behind the buffer: the object just started replicating, or the clock was
	# reset. Snap to the oldest known state rather than inventing history.
	if render_time <= oldest.time:
		out_position = oldest.position
		out_rotation = oldest.rotation
		return true

	# Past the newest sample: the buffer has run dry.
	if render_time >= newest.time:
		var overshoot: float = render_time - newest.time
		if overshoot > NetConfig.MAX_EXTRAPOLATION:
			# Long stall. Freeze at the last known pose; continuing to
			# extrapolate would send the object through walls, and the snap when
			# packets resume would be far worse than a brief pause.
			overshoot = NetConfig.MAX_EXTRAPOLATION
		is_extrapolating = true
		out_position = newest.position + newest.linear_velocity * overshoot
		out_rotation = newest.rotation
		return true

	# Normal case: find the pair straddling render_time and blend.
	# Walking backwards is deliberate — render_time is almost always inside the
	# last couple of samples, so this exits after one or two iterations.
	for index in range(_samples.size() - 1, 0, -1):
		var later: Sample = _samples[index]
		var earlier: Sample = _samples[index - 1]
		if render_time >= earlier.time and render_time <= later.time:
			var span: float = later.time - earlier.time
			var weight: float = 0.0 if span <= 0.0 else (render_time - earlier.time) / span
			out_position = earlier.position.lerp(later.position, weight)
			out_rotation = earlier.rotation.slerp(later.rotation, weight)
			return true

	# Unreachable given the bounds checks above, but returning the newest state
	# is the correct fallback if it ever is reached.
	out_position = newest.position
	out_rotation = newest.rotation
	return true


## Velocity of the most recent snapshot. Used for effects that need remote
## motion (wheel spin, engine audio pitch) without re-deriving it per frame.
func latest_velocity() -> Vector3:
	if _samples.is_empty():
		return Vector3.ZERO
	var newest: Sample = _samples[_samples.size() - 1]
	return newest.linear_velocity


func sample_count() -> int:
	return _samples.size()


## Drop all history. Call when authority changes hands or the object teleports,
## otherwise the buffer would interpolate across the discontinuity and the object
## would visibly slide from its old pose to its new one.
func clear() -> void:
	_samples.clear()
	_last_sequence = -1
	has_state = false
	is_extrapolating = false
