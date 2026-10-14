class_name PlayerController
extends CharacterBody3D
## Meridian Bay — third-person prototype controller (Task 1).
## WASD camera-relative movement, Shift sprint, Space jump, mouse camera.
## Yaw lives on CamPivot (decoupled from the body); the visible mesh turns
## toward travel direction. Camera pitch is clamped to prevent flipping.

@export var walk_speed: float = 4.0
@export var sprint_speed: float = 7.0
## v = sqrt(2 * g * h): sqrt(2 * 9.8 * 1.2) ~= 4.85 -> ~1.2 m jump height.
@export var jump_velocity: float = 4.9
@export var acceleration: float = 14.0
@export var mouse_sensitivity: float = 0.003
@export var min_pitch: float = -1.2
@export var max_pitch: float = 0.6
@export var gravity: float = 9.8
@export var fall_reset_height: float = -10.0

@onready var cam_pivot: Node3D = $CamPivot
@onready var body_mesh: MeshInstance3D = $Mesh

## Walking | sprinting | airborne | driving — read by the debug overlay.
var movement_mode: String = "walking"
## False while the VehicleSystem has the player seated in a vehicle:
## movement input and mouse-look are ignored, the body just settles.
var controls_enabled: bool = true

var _pitch: float = -0.3
var _spawn_position: Vector3


func _ready() -> void:
	_spawn_position = global_position
	add_to_group("player")
	_apply_pitch()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if not controls_enabled:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
					and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		cam_pivot.rotate_y(-motion.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - motion.relative.y * mouse_sensitivity, min_pitch, max_pitch)
		_apply_pitch()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
				and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _physics_process(delta: float) -> void:
	if not controls_enabled:
		# Seated in a vehicle: no input, just settle and report.
		velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)
		if not is_on_floor():
			velocity.y -= gravity * delta
		move_and_slide()
		movement_mode = "driving"
		return
	if not is_on_floor():
		velocity.y -= gravity * delta
	# Grounded jumps only: just_pressed is true for exactly one physics tick,
	# so holding Space cannot multi-jump mid-air.
	if is_on_floor() and Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity
	# Camera-relative planar direction. Only the pivot's yaw is used so the
	# camera's vertical angle never tilts movement up/down.
	var input_vec := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var yaw := Basis(Vector3.UP, cam_pivot.global_rotation.y)
	var wish_dir: Vector3 = yaw * Vector3(input_vec.x, 0.0, input_vec.y)
	if wish_dir.length_squared() > 1.0:
		wish_dir = wish_dir.normalized()
	var sprinting := Input.is_action_pressed("sprint") and input_vec.length() > 0.1
	var target_speed := sprint_speed if sprinting else walk_speed
	var target_vel := wish_dir * target_speed
	velocity.x = move_toward(velocity.x, target_vel.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, acceleration * delta)
	move_and_slide()
	# Turn the visible mesh toward travel direction (mesh only).
	var planar := Vector3(velocity.x, 0.0, velocity.z)
	if planar.length() > 0.5:
		body_mesh.rotation.y = lerp_angle(
			body_mesh.rotation.y, atan2(-planar.x, -planar.z), 1.0 - exp(-10.0 * delta))
	if not is_on_floor():
		movement_mode = "airborne"
	elif sprinting and planar.length() > 0.5:
		movement_mode = "sprinting"
	else:
		movement_mode = "walking"
	# Failsafe: never strand the player below the world.
	if global_position.y < fall_reset_height:
		global_position = _spawn_position
		velocity = Vector3.ZERO


func _apply_pitch() -> void:
	cam_pivot.rotation.x = _pitch
