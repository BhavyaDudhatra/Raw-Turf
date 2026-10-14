class_name VehicleController
extends CharacterBody3D
## Meridian Bay — arcade van controller (Task 3).
## Deliberately NOT VehicleBody3D: a CharacterBody3D + move_and_slide gives
## free wall/building collision and slope handling, while an explicit bicycle
## model (yaw rate proportional to speed) guarantees no in-place rotation and
## predictable tuning that is easy to verify headlessly. No plugins.
##
## Conventions: forward is -Z. `forward_speed` is signed (+ forward).
## The VehicleSystem toggles `driving`; with it off the van only settles.

@export var max_speed: float = 28.0
@export var max_reverse_speed: float = 8.0
@export var acceleration: float = 10.0
@export var reverse_acceleration: float = 7.0
@export var brake_force: float = 22.0
@export var coast_deceleration: float = 3.0
@export var handbrake_force: float = 30.0
@export var wheel_base: float = 3.0
@export var max_steer_angle: float = 0.55
@export var steer_speed: float = 6.0
@export var gravity: float = 20.0

## Set by the VehicleSystem. False = parked (input ignored, rolls to rest).
var driving: bool = false
## Signed speed along the van's forward axis (m/s). Read by HUD/tests.
var forward_speed: float = 0.0

var _steer: float = 0.0
var _was_on_wall: bool = false


func _physics_process(delta: float) -> void:
	var basis_flat := Basis(Vector3.UP, global_rotation.y)
	var forward: Vector3 = -basis_flat.z
	if driving:
		_drive(delta, forward)
	else:
		forward_speed = move_toward(forward_speed, 0.0, coast_deceleration * delta)
	# Planar velocity is fully derived from forward_speed: no lateral slide.
	velocity.x = forward.x * forward_speed
	velocity.z = forward.z * forward_speed
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = minf(velocity.y, 0.0)
	move_and_slide()
	# Scrub speed once per impact (rising edge only): a sustained wall slide
	# stays drivable instead of grinding to a halt under held throttle.
	var on_wall := is_on_wall()
	if on_wall and not _was_on_wall:
		forward_speed *= 0.5
	_was_on_wall = on_wall
	# Keep the van above the world at all times (failsafe, mirrors player).
	if global_position.y < -10.0:
		global_position = Vector3(14, 1, 0)
		velocity = Vector3.ZERO
		forward_speed = 0.0


func _drive(delta: float, forward: Vector3) -> void:
	var throttle := Input.get_axis("move_backward", "move_forward")
	# S doubles as brake when rolling forward, reverse when stopped.
	if throttle < 0.0 and forward_speed > 0.5:
		forward_speed = move_toward(forward_speed, 0.0, brake_force * delta)
	elif throttle > 0.0:
		forward_speed = move_toward(forward_speed, max_speed, acceleration * delta)
	elif throttle < 0.0:
		forward_speed = move_toward(forward_speed, -max_reverse_speed, reverse_acceleration * delta)
	else:
		forward_speed = move_toward(forward_speed, 0.0, coast_deceleration * delta)
	if Input.is_action_pressed("handbrake"):
		forward_speed = move_toward(forward_speed, 0.0, handbrake_force * delta)
	# Steering: smoothed input, authority ramps in with speed (never spins in
	# place) and fades at very high speed for stability.
	var steer_input := Input.get_axis("move_right", "move_left")
	var speed_abs := absf(forward_speed)
	var authority := clampf(speed_abs / 4.0, 0.0, 1.0)
	authority *= clampf(1.0 - (speed_abs - 18.0) / 20.0, 0.35, 1.0)
	var target_steer := steer_input * max_steer_angle * authority
	_steer = move_toward(_steer, target_steer, steer_speed * delta)
	# Bicycle model: yaw rate = v / L * tan(steer). Reverse flips naturally.
	if speed_abs > 0.1:
		rotate_y(forward_speed / wheel_base * tan(_steer) * delta)
