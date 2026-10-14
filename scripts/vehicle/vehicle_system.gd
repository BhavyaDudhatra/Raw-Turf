extends Node
## Meridian Bay — ON_FOOT / DRIVING coordinator (Task 3).
## Plain Node in the main scene (group `vehicle_system`); no autoload.
## Owns the enter/exit state machine, camera swap, player freeze/hide and the
## minimal vehicle HUD label. Exit spots are probed with a physics shape cast
## so the player can never be spawned inside walls or buildings.

enum Mode { ON_FOOT, DRIVING }

var mode: int = Mode.ON_FOOT

@onready var player: CharacterBody3D = get_parent().get_node("Player")
@onready var van: CharacterBody3D = get_parent().get_node("Van")
@onready var player_camera: Camera3D = get_parent().get_node("Player/CamPivot/SpringArm/Camera")
@onready var van_camera: Camera3D = get_parent().get_node("Van/DrivePivot/SpringArm/DriveCamera")
@onready var hud_label: Label = get_parent().get_node("VehicleHUD/Label")

var _was_pressed: bool = false


func _ready() -> void:
	add_to_group("vehicle_system")
	_update_hud()


func request_enter() -> bool:
	if mode != Mode.ON_FOOT:
		return false
	mode = Mode.DRIVING
	player.set("controls_enabled", false)
	player.velocity = Vector3.ZERO
	player.visible = false
	player_camera.current = false
	van_camera.current = true
	van.set("driving", true)
	_was_pressed = true # same press must not instantly exit
	_update_hud()
	_toast("Driving — W/S accelerate and brake, Space handbrake, E exits.")
	return true


func _physics_process(_delta: float) -> void:
	if mode != Mode.DRIVING:
		return
	# Exit uses edge detection: release E at least once after entering.
	var pressed := Input.is_action_pressed("interact")
	if not pressed:
		_was_pressed = false
		return
	if _was_pressed:
		return
	_was_pressed = true
	_try_exit()


func _try_exit() -> void:
	var spot := _find_exit_spot()
	if spot == Vector3.INF:
		_toast("No safe exit here — drive clear of walls first.")
		return
	_set_on_foot(spot)
	_toast("On foot.")


## Shared on-foot baseline used by exits AND save/load restoration.
func _set_on_foot(spot: Vector3) -> void:
	van.set("driving", false)
	van.set("forward_speed", 0.0)
	player.global_position = spot
	player.velocity = Vector3.ZERO
	player.visible = true
	player.set("controls_enabled", true)
	van_camera.current = false
	player_camera.current = true
	mode = Mode.ON_FOOT
	_was_pressed = true
	_update_hud()


## Save/load entry: rebuilds a coherent mode from validated data. Baseline is
## forced on-foot first (idempotent), then driving is re-entered through the
## normal path, so no frozen-hidden / walking-while-driving mix is possible.
func apply_loaded_mode(driving_mode: bool) -> void:
	_set_on_foot(player.global_position)
	if driving_mode:
		request_enter()
	else:
		_toast("On foot.")


## Driver side first, then passenger side, then behind the van. The front is
## deliberately excluded — never drop the player in the van's path.
func _find_exit_spot() -> Vector3:
	var space := van.get_world_3d().direct_space_state
	var sphere := SphereShape3D.new()
	sphere.radius = 0.45
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sphere
	params.collision_mask = 1
	params.exclude = [van.get_rid(), player.get_rid()]
	var yaw_basis := Basis(Vector3.UP, van.global_rotation.y)
	for local in [Vector3(-2.0, 0, 0), Vector3(2.0, 0, 0), Vector3(0, 0, 3.4)]:
		var candidate: Vector3 = van.global_position + yaw_basis * local
		candidate.y = van.global_position.y + 1.0
		params.transform = Transform3D(Basis(), candidate)
		if _spot_is_solid(space, params):
			continue
		return candidate
	return Vector3.INF


## Trigger areas are not geometry: only solid bodies block an exit spot.
func _spot_is_solid(space: PhysicsDirectSpaceState3D, params: PhysicsShapeQueryParameters3D) -> bool:
	for h in space.intersect_shape(params, 8):
		var c: Object = (h as Dictionary).get("collider")
		if not (c is Area3D):
			return true
	return false


func _process(_delta: float) -> void:
	if mode == Mode.DRIVING:
		_update_hud()


func _update_hud() -> void:
	if hud_label == null:
		return
	if mode == Mode.DRIVING:
		var speed := absf(float(van.get("forward_speed")))
		hud_label.text = "DRIVING  %.1f m/s   —   E exits" % speed
	else:
		hud_label.text = "ON FOOT  —  E near the van to drive"


func _toast(text: String) -> void:
	var toast: Node = get_tree().get_first_node_in_group("toast")
	if toast != null and toast.has_method("show_message"):
		toast.show_message(text)
