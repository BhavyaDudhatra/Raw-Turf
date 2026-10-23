class_name NpcBase
extends CharacterBody3D
## Meridian Bay — shared pedestrian body (Task 8, stage 8.1).
##
## Owns everything a pedestrian needs and nothing else:
##   * locomotion (gravity, move_and_slide, a capped turn rate so nobody
##     snap-turns like a turret),
##   * the behaviour state machine
##         IDLE -> WALK -> WAIT -> WALK ... and YIELDING as an override,
##   * local avoidance (a shape cast against the world layer, a soft
##     separation force against other pedestrians),
##   * the navigation contract used by the director:
##         get_next_target()      -> Vector3
##         is_target_reachable()  -> bool
##
## Navigation sits behind that small interface on purpose: a baked
## NavigationRegion3D can replace the waypoint graph in Task 9+ without
## touching the state machine, the director or the tests (proposal 5.3).
##
## Nothing here changes the player, the van, the mission or the save format.
## The van's physics, steering, braking and collision masks are never touched:
## the van reacts to pedestrians, never the other way round.

## Behaviour states (proposal 5.1).
enum State {
	IDLE,      ## spawned, no destination yet
	WALK,      ## moving towards the current waypoint
	WAIT,      ## arrived at a waypoint, pausing
	FROZEN,    ## outside the activation radius: no simulation at all
	YIELDING,  ## stepping out of the courier van's path
}

## Every pedestrian registers here so other systems can find them.
const GROUP_NAME: String = "npc"
## Physics layer used for world probes (world statics are layer 1).
const WORLD_LAYER: int = 1
## Chest height of every shape probe (the ground surface is y = 0).
const PROBE_HEIGHT: float = 0.9

@export_group("Locomotion")
@export var walk_speed: float = 1.30
## Radians per second the visible body may turn.
@export var turn_rate: float = 4.0
## Ground acceleration in m/s^2.
@export var acceleration: float = 8.0
@export var gravity: float = 9.8
## Distance at which a waypoint counts as reached.
@export var arrive_radius: float = 0.65
## How far ahead the obstacle shape cast looks.
@export var obstacle_lookahead: float = 1.35

@export_group("Steering")
@export var separation_radius: float = 1.30
@export var separation_strength: float = 0.85
@export var player_avoid_radius: float = 3.00
@export var player_avoid_strength: float = 3.00
## Inside this distance the pedestrian moves directly away from the player.
@export var player_escape_radius: float = 1.30

@export_group("Van yield")
## Radius around the van's PREDICTED PATH that makes a pedestrian yield
## (proposal 4.3: "an NPC within 3 m of the van's predicted path switches to
## YIELDING and steps aside").
@export var yield_path_radius: float = 3.0
## How far the van's path is predicted ahead, scaled by its speed.
@export var yield_prediction_time: float = 1.5
## Minimum predicted path length (a parked van still has a short path).
@export var yield_min_prediction: float = 1.5
## Speed multiplier while stepping aside.
@export var yield_speed_multiplier: float = 1.50
## How far aside the pedestrian tries to get (must exceed yield_path_radius
## so a pedestrian that reached its spot is really clear of the path).
@export var yield_clear_lateral: float = 3.60
## Seconds before a blocked pedestrian re-targets instead of pushing.
@export var yield_timeout: float = 3.0

## Current behaviour state (read by the tests and the debug overlay).
var state: int = State.IDLE
## Deterministic per-instance RNG, seeded by the director.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
## The waypoint the pedestrian is walking to.
var target_point: Vector3 = Vector3.ZERO
var target_id: String = ""
## Pre-picked follow-up waypoint (seek-and-arrive with one waypoint of
## look-ahead, so the pedestrian never stands still waiting for a decision).
var next_target_point: Vector3 = Vector3.ZERO
var next_target_id: String = ""
## Physics ticks between waypoint decisions (1 = every tick, 12 = 5 Hz).
var decision_interval: int = 1
## Phase offset so mid-tier pedestrians do not all decide on the same tick.
var decision_phase: int = 0
## Set by the director.
## Signature: (from_id: String, mode: String, from_pos: Vector3) -> Dictionary
## mode "next" -> the next waypoint to walk to,
## mode "safe" -> the nearest waypoint outside the protected zones.
var waypoint_provider: Callable = Callable()
## Set by the director: () -> float, the pause duration at a waypoint.
var idle_duration_provider: Callable = Callable()
## Set by the director: the RIDs of the whole population, so an obstacle probe
## ignores the other pedestrians and only sees the static world.
var population_rids: Array[RID] = []
## Set by the director: a snapshot of the population positions, refreshed
## every physics tick. The soft separation reads it instead of pulling every
## neighbour's transform through the engine on every tick.
var population_positions: PackedVector3Array = PackedVector3Array()
## Set by the director: this pedestrian's own index in population_positions.
var population_index: int = -1

var _idle_timer: float = 0.0
var _yield_timer: float = 0.0
var _yield_point: Vector3 = Vector3.ZERO
var _yield_retargeted: bool = false
var _pre_freeze_state: int = State.IDLE
var _van: Node3D = null
var _player: Node3D = null
var _probe_shape: SphereShape3D = null
var _probe_params: PhysicsShapeQueryParameters3D = null


func _ready() -> void:
	add_to_group(GROUP_NAME)
	_probe_shape = SphereShape3D.new()
	_probe_shape.radius = 0.30
	_probe_params = PhysicsShapeQueryParameters3D.new()
	_probe_params.shape = _probe_shape
	_probe_params.collision_mask = WORLD_LAYER
	_player = get_tree().get_first_node_in_group("player") as Node3D
	_van = get_tree().get_first_node_in_group("courier_van") as Node3D


## Called by the director right after the pedestrian enters the tree.
func setup_waypoints(id: String, pos: Vector3, next_id: String, next_pos: Vector3) -> void:
	target_id = id
	target_point = pos
	next_target_id = next_id
	next_target_point = next_pos
	if state == State.IDLE:
		state = State.WALK


## Far tier: the pedestrian is outside the activation radius. It stops being
## simulated entirely (no physics process, no animation, no decisions) but
## stays in the scene as a resident.
func freeze() -> void:
	if state == State.FROZEN:
		return
	_pre_freeze_state = state
	state = State.FROZEN
	set_physics_process(false)


## Un-freezes the pedestrian and restores the state it had before.
func unfreeze() -> void:
	if state != State.FROZEN:
		return
	state = _pre_freeze_state
	set_physics_process(true)


## Current state as a readable string (tests / debug overlay).
func state_name() -> String:
	return State.keys()[state] if state >= 0 and state < State.size() else "UNKNOWN"


## Navigation contract: the next point the pedestrian should walk to.
func get_next_target() -> Vector3:
	return target_point


## Navigation contract: whether the current target can actually be reached.
## Uses a single ray against the world layer; a static body on the path means
## the pedestrian asks the director for a different waypoint.
func is_target_reachable() -> bool:
	if target_point == Vector3.ZERO:
		return false
	var params := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0.0, PROBE_HEIGHT, 0.0),
		target_point + Vector3(0.0, PROBE_HEIGHT, 0.0))
	params.collision_mask = WORLD_LAYER
	params.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	if hit.is_empty():
		return true
	var collider: Variant = hit.get("collider")
	return not (collider is StaticBody3D)


func _physics_process(delta: float) -> void:
	if state == State.FROZEN:
		return
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0
	_update_yield(delta)
	var desired := _desired_direction()
	var speed := walk_speed
	if state == State.YIELDING:
		speed *= yield_speed_multiplier
	var target_vel := desired * speed
	velocity.x = move_toward(velocity.x, target_vel.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, acceleration * delta)
	move_and_slide()
	_update_visual_yaw(delta, desired)
	_update_state_machine(delta)


# --- steering ---------------------------------------------------------------

func _desired_direction() -> Vector3:
	var dir := Vector3.ZERO
	if state == State.YIELDING:
		dir = _seek(_yield_point)
	elif state == State.WALK:
		dir = _seek(target_point)
	dir = _avoid_obstacles(dir)
	dir += _separation_vector()
	dir += _player_avoid_vector()
	dir.y = 0.0
	# Close to the player the soft force is not enough: step directly away so
	# the player is never blocked by a pedestrian on the delivery route.
	var escape := _player_escape_direction()
	if escape != Vector3.ZERO:
		return escape
	if dir.length_squared() < 0.0001:
		return Vector3.ZERO
	return dir.normalized()


## Pure "move directly away from the player" direction, used only when the
## player is inside the escape radius.
func _player_escape_direction() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		return Vector3.ZERO
	var d := global_position - _player.global_position
	d.y = 0.0
	var l := d.length()
	if l > player_escape_radius or l < 0.001:
		return Vector3.ZERO
	return d / l


func _seek(point: Vector3) -> Vector3:
	var d := point - global_position
	d.y = 0.0
	if d.length_squared() < 0.0001:
		return Vector3.ZERO
	return d.normalized()


## Shape cast in front of the pedestrian; a static body in the way makes it
## sidestep instead of grinding into the wall.
func _avoid_obstacles(dir: Vector3) -> Vector3:
	if dir == Vector3.ZERO:
		return dir
	var hit := _probe(dir, obstacle_lookahead)
	if hit.is_empty():
		return dir
	var normal: Vector3 = hit.get("normal", Vector3.ZERO)
	if normal.length_squared() < 0.0001:
		return dir
	var tangent := dir.cross(normal)
	if tangent.length_squared() < 0.0001:
		return dir
	tangent = tangent.normalized()
	var to_target := target_point - global_position
	to_target.y = 0.0
	var alt := -tangent
	tangent = tangent if tangent.dot(to_target) >= alt.dot(to_target) else alt
	return (dir * 0.35 + tangent).normalized()


## Soft push away from other pedestrians so they never stack.
## Reads the director's position snapshot: pulling every neighbour's
## transform through the engine on every tick was the single most expensive
## part of the pedestrian update.
func _separation_vector() -> Vector3:
	var out := Vector3.ZERO
	var others := population_positions
	var count := others.size()
	if count == 0:
		return out
	var r2 := separation_radius * separation_radius
	var my := global_position
	for i in range(count):
		if i == population_index:
			continue
		var d := my - others[i]
		d.y = 0.0
		var l2 := d.length_squared()
		if l2 > 0.000001 and l2 < r2:
			var l := sqrt(l2)
			out += (d / l) * (1.0 - l / separation_radius) * separation_strength
	return out


## Soft push away from the player, so a pedestrian never blocks the player
## on the delivery route.
func _player_avoid_vector() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node3D
		if _player == null:
			return Vector3.ZERO
	var d := global_position - _player.global_position
	d.y = 0.0
	var l := d.length()
	if l > player_avoid_radius or l < 0.001:
		return Vector3.ZERO
	return (d / l) * (1.0 - l / player_avoid_radius) * player_avoid_strength

## Shape probe against the world layer. Returns the first static hit.
## The other pedestrians are excluded, so only the static world can block a
## step (a pedestrian is handled by the separation force instead).
func _probe(dir: Vector3, distance: float) -> Dictionary:
	if _probe_shape == null or _probe_params == null:
		return {}
	_probe_params.transform = Transform3D(Basis(), global_position + Vector3(0.0, PROBE_HEIGHT, 0.0) + dir * distance)
	var excl: Array[RID] = [get_rid()]
	excl.append_array(population_rids)
	_probe_params.exclude = excl
	var hits := get_world_3d().direct_space_state.intersect_shape(_probe_params, 4)
	for h in hits:
		var collider: Variant = h.get("collider")
		if collider is StaticBody3D:
			return h
	return {}


# --- van yield --------------------------------------------------------------

func _get_van() -> Node3D:
	if _van == null or not is_instance_valid(_van):
		_van = get_tree().get_first_node_in_group("courier_van") as Node3D
	return _van


static func _van_forward(van: Node3D) -> Vector3:
	var fwd := -van.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return Vector3.FORWARD
	return fwd.normalized()


## The van's direction of travel (reversing flips it).
func _van_motion_dir(van: Node3D) -> Vector3:
	var speed := float(van.get("forward_speed"))
	var fwd := _van_forward(van)
	if speed < -0.5:
		return -fwd
	return fwd


## True when the pedestrian is inside the van's predicted path corridor.
## The corridor is the van's PREDICTED PATH (the segment it is going to
## travel), not the van itself: a pedestrian that is still behind the van is
## safe, one that is in front of it is not.
func _in_van_corridor(van: Node3D) -> bool:
	var motion := _van_motion_dir(van)
	var a := van.global_position
	var b := a + motion * _van_path_length(van)
	return _in_corridor(motion, a, b)


## Length of the van's predicted path.
func _van_path_length(van: Node3D) -> float:
	var speed := absf(float(van.get("forward_speed")))
	return maxf(yield_min_prediction, speed * yield_prediction_time)


## Corridor test with an already computed motion direction and path.
func _in_corridor(motion: Vector3, a: Vector3, b: Vector3) -> bool:
	var rel := global_position - a
	# Behind the van is not in its path (the van's front is what hits).
	if rel.dot(motion) < -1.0:
		return false
	return _distance_to_segment(global_position, a, b) <= yield_path_radius


## Shortest distance from a point to a line segment.
static func _distance_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _update_yield(delta: float) -> void:
	var van := _get_van()
	if van == null:
		if state == State.YIELDING:
			state = State.WALK
		return
	# The van's motion data is read once per tick and reused, so the yield
	# check does not walk the van's properties over and over.
	var motion := _van_motion_dir(van)
	var a := van.global_position
	var b := a + motion * _van_path_length(van)
	if _in_corridor(motion, a, b):
		if state != State.YIELDING:
			_begin_yield(van, motion, a)
		return
	if state != State.YIELDING:
		return
	_yield_timer += delta
	if not _yield_retargeted:
		# The step-aside spot follows the pedestrian's own station on the
		# van's path, so the pedestrian moves sideways instead of chasing a
		# moving target.
		_yield_point = _compute_yield_point(van, motion, a)
	# The pedestrian stays aside until the van has gone by. Walking back
	# into the corridor as soon as it is clear again would make it flicker
	# in and out of the yield.
	var rel := global_position - a
	if rel.dot(motion) < 0.0:
		_resume_walk()
	elif _yield_retargeted:
		# Re-targeted to a safe waypoint and out of the lane: walk on.
		_resume_walk()
	elif _yield_timer >= yield_timeout:
		_retarget_away_from_lane()


## Leaves the yield state and resumes the normal behaviour.
func _resume_walk() -> void:
	state = State.WALK
	_yield_timer = 0.0
	_yield_retargeted = false


func _begin_yield(van: Node3D, motion: Vector3, a: Vector3) -> void:
	state = State.YIELDING
	_yield_timer = 0.0
	_yield_retargeted = false
	_yield_point = _compute_yield_point(van, motion, a)


## Picks the spot to step into: beside the van's path, on the side the
## pedestrian is already on when that side is free, otherwise the other
## side, otherwise straight away from the van (a fully constrained pedestrian
## must not jam against the van).
func _compute_yield_point(van: Node3D, motion: Vector3, a: Vector3) -> Vector3:
	var right := motion.cross(Vector3.UP).normalized()
	var rel := global_position - a
	# The station of the pedestrian on the van's path.
	var base := van.global_position + motion * rel.dot(motion)
	var side := 1.0 if rel.dot(right) >= 0.0 else -1.0
	var step := right * side
	if not _direction_clear(step):
		var other := -step
		if _direction_clear(other):
			step = other
	if not _direction_clear(step):
		# Constrained on both sides: move away from the van instead.
		var away := rel
		away.y = 0.0
		if away.length_squared() < 0.0001:
			away = -motion
		return global_position + away.normalized() * 2.0
	return base + step * yield_clear_lateral


## True when nothing static blocks a step of `yield_clear_lateral` in that
## direction (a ray, so a wall anywhere along the step counts).
func _direction_clear(dir: Vector3) -> bool:
	var from := global_position + Vector3(0.0, PROBE_HEIGHT, 0.0)
	var params := PhysicsRayQueryParameters3D.create(from, from + dir * yield_clear_lateral)
	params.collision_mask = WORLD_LAYER
	params.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	if hit.is_empty():
		return true
	var collider: Variant = hit.get("collider")
	return not (collider is StaticBody3D)


## Gives up on squeezing past and asks the director for a waypoint that is
## outside the protected delivery lane.
func _retarget_away_from_lane() -> void:
	if not waypoint_provider.is_valid():
		return
	var res: Dictionary = waypoint_provider.call(target_id, "safe", global_position)
	var safe_id := str(res.get("id", ""))
	var safe_pos: Variant = res.get("pos", Vector3.ZERO)
	if safe_pos == Vector3.ZERO:
		return
	target_id = safe_id
	target_point = safe_pos
	next_target_id = safe_id
	next_target_point = safe_pos
	_yield_point = safe_pos
	_yield_retargeted = true
	_yield_timer = 0.0


# --- state machine ----------------------------------------------------------

func _update_state_machine(delta: float) -> void:
	if state == State.WALK:
		var d := target_point - global_position
		d.y = 0.0
		if d.length() <= arrive_radius:
			_arrive()
	elif state == State.WAIT:
		_idle_timer -= delta
		if _idle_timer <= 0.0 and _is_decision_tick():
			_advance_to_next_target()


func _arrive() -> void:
	state = State.WAIT
	_idle_timer = _idle_duration()


func _advance_to_next_target() -> void:
	target_id = next_target_id
	target_point = next_target_point
	if not waypoint_provider.is_valid():
		state = State.WAIT
		return
	var res: Dictionary = waypoint_provider.call(target_id, "next", global_position)
	next_target_id = str(res.get("id", ""))
	var p: Variant = res.get("pos", Vector3.ZERO)
	next_target_point = p
	state = State.WALK


func _idle_duration() -> float:
	if idle_duration_provider.is_valid():
		return float(idle_duration_provider.call())
	return 2.0


## Waypoint decisions are staggered: mid-tier pedestrians only decide every
## `decision_interval` physics ticks, each with its own phase offset.
func _is_decision_tick() -> bool:
	if decision_interval <= 1:
		return true
	return (int(Engine.get_physics_frames()) + decision_phase) % decision_interval == 0


func _update_visual_yaw(delta: float, dir: Vector3) -> void:
	var visual := get_node_or_null("Visual") as Node3D
	if visual == null or dir.length_squared() < 0.0001:
		return
	var want := atan2(-dir.x, -dir.z)
	var diff := wrapf(want - visual.rotation.y, -PI, PI)
	var max_step := turn_rate * delta
	visual.rotation.y += clampf(diff, -max_step, max_step)
