extends SceneTree
## Task 3 vehicle test — drives the real main.tscn with synthetic input.
## Run: Godot_console --headless --path <project> --script res://tools/vehicle_test_task3.gd
## Exit 0 = pass, 1 = failures, 2 = load error/timeout.
## Covers: van loads/settles, entry prompt, enter (state/cameras/hide),
## accelerate, brake, reverse, steering (no in-place spin), handbrake, exit
## (state/cameras/restore/safe spot), van ignores input after exit, on-foot
## controls restored, re-enter, old interactables intact, wall-adjacent exit.
## Fully-blocked exit + mouse/camera feel are manual (see report).

const DRIVING: int = 1
const ON_FOOT: int = 0

var _tick: int = 0
var _phase: int = 0
var _phase_tick: int = 0
var _player: CharacterBody3D
var _van: CharacterBody3D
var _sys: Node
var _toast: CanvasLayer
var _contact: Area3D
var _failures: Array[String] = []
var _mark_x: float = 0.0
var _mark_yaw: float = 0.0
var _mark_pos := Vector3.ZERO


func _initialize() -> void:
	var ps := load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		push_error("VEHICLE-TEST: main.tscn failed to load")
		quit(2)
		return
	var m: Node = ps.instantiate()
	root.add_child.call_deferred(m)
	physics_frame.connect(_on_physics)


func _place(p: Vector3) -> void:
	_player.global_position = p
	_player.velocity = Vector3.ZERO


func _van_side_spot() -> Vector3:
	var yaw_basis := Basis(Vector3.UP, _van.global_rotation.y)
	var spot: Vector3 = _van.global_position + yaw_basis * Vector3(2.5, 0, 0)
	spot.y = _van.global_position.y + 0.5
	return spot


func _hold(action: String) -> void:
	Input.action_press(action)


func _release(action: String) -> void:
	Input.action_release(action)


func _on_physics() -> void:
	if _player == null:
		_player = root.get_node_or_null("Main/Player") as CharacterBody3D
		_van = root.get_node_or_null("Main/Van") as CharacterBody3D
		_sys = root.get_node_or_null("Main/VehicleSystem")
		_toast = root.get_node_or_null("Main/Toast") as CanvasLayer
		_contact = root.get_node_or_null("Main/CourierContact") as Area3D
		if _player == null or _van == null or _sys == null:
			return
	_tick += 1
	_phase_tick += 1
	var mode := int(_sys.get("mode"))
	match _phase:
		0: # Settle: van drops to the ground, player lands.
			if _phase_tick >= 40:
				_check(_van.is_on_floor(), "settle: van on floor")
				_check(absf(_van.global_position.y) < 0.6,
					"settle: van y sane (%.2f)" % _van.global_position.y)
				_check(_player.is_on_floor(), "settle: player on floor")
				_check(mode == ON_FOOT, "settle: starts ON_FOOT")
				_next_phase()
				_place(Vector3(11.3, 0.5, 0.5))
		1: # Next to the van: entry prompt visible.
			if _phase_tick >= 20:
				_check(_prompt_visible("Main/Van/Entry"), "entry: prompt visible near van")
				_next_phase()
				_hold("interact")
		2: # E enters: state, hide, cameras.
			if _phase_tick >= 3:
				_release("interact")
				_next_phase()
		3:
			if _phase_tick >= 10:
				_check(mode == DRIVING, "enter: mode is DRIVING")
				_check(not _player.visible, "enter: player hidden")
				_check(_drive_cam().current, "enter: van camera current")
				_check(not _player_cam().current, "enter: player camera off")
				_check(String(_player.get("movement_mode")) == "driving",
					"enter: player reports driving")
				_next_phase()
				_hold("move_forward")
		4: # Accelerate 45 ticks: rolling, +X, no walls yet.
			if _phase_tick >= 45:
				var sp := float(_van.get("forward_speed"))
				_check(sp > 5.0, "drive: speed > 5 (got %.1f)" % sp)
				_check(_van.global_position.x > 15.5,
					"drive: moved +X (x %.1f)" % _van.global_position.x)
				_check(_van.is_on_floor(), "drive: van stays grounded")
				_release("move_forward")
				_next_phase()
				_hold("move_backward")
		5: # S brakes: stop the moment rolling halts (S becomes reverse after).
			var bsp := float(_van.get("forward_speed"))
			if bsp <= 0.5:
				_check(bsp >= -1.0, "brake: stopped (%.1f)" % bsp)
				_mark_x = _van.global_position.x
				_next_phase()
			elif _phase_tick >= 120:
				_check(false, "brake: never stopped (%.1f)" % bsp)
				_release("move_backward")
				_mark_x = _van.global_position.x
				_next_phase()
		6: # Keep holding S: reverse builds from rest.
			if _phase_tick >= 60:
				var rsp := float(_van.get("forward_speed"))
				_check(rsp < -2.0, "reverse: backing up (%.1f)" % rsp)
				_check(_van.global_position.x < _mark_x - 1.0, "reverse: x decreased")
				_release("move_backward")
				_mark_yaw = _van.global_rotation.y
				_next_phase()
				_hold("move_forward")
		7: # Rebuild forward speed with W before steering.
			if _phase_tick >= 75:
				_check(float(_van.get("forward_speed")) > 4.0,
					"rebuild: rolling again (%.1f)" % float(_van.get("forward_speed")))
				_mark_pos = _van.global_position
				_next_phase()
				_hold("move_left")
		8: # Steer with W+A held: must turn while rolling, keep moving.
			if _phase_tick >= 60:
				var dyaw := absf(_van.global_rotation.y - _mark_yaw)
				_check(dyaw > 0.15, "steer: yaw changed (%.2f rad)" % dyaw)
				_check(absf(float(_van.get("forward_speed"))) > 1.5, "steer: still rolling")
				_check(_van.global_position.distance_to(_mark_pos) > 2.0,
					"steer: turned while moving, not spinning in place")
				_release("move_left")
				_release("move_forward")
				_next_phase()
				_hold("handbrake")
		9:
			if _phase_tick >= 45:
				_check(absf(float(_van.get("forward_speed"))) < 1.5,
					"handbrake: near stop (%.1f)" % float(_van.get("forward_speed")))
				_release("handbrake")
				_next_phase()
				_hold("interact")
		10: # E exits.
			if _phase_tick >= 3:
				_release("interact")
				_next_phase()
		11:
			if _phase_tick >= 10:
				_check(mode == ON_FOOT, "exit: mode is ON_FOOT")
				_check(_player.visible, "exit: player visible")
				_check(_player_cam().current, "exit: player camera back")
				_check(not _drive_cam().current, "exit: van camera off")
				var gap: float = _player.global_position.distance_to(_van.global_position)
				_check(gap > 1.0 and gap < 7.0, "exit: safe gap (%.1f m)" % gap)
				_check(_player.global_position.y > -0.5 and _player.global_position.y < 2.0,
					"exit: player y sane")
				_mark_pos = _player.global_position
				_next_phase()
				_hold("move_forward")
		12: # Van ignores input; player walks again.
			if _phase_tick >= 30:
				_check(absf(float(_van.get("forward_speed"))) < 0.5,
					"exit: van ignores throttle")
				_check(_player.global_position.distance_to(_mark_pos) > 1.0,
					"exit: on-foot controls restored")
				_release("move_forward")
				_next_phase()
				_place(_van_side_spot())
		13: # Re-enter works (repeated enter/exit).
			if _phase_tick >= 20:
				_check(_prompt_visible("Main/Van/Entry"), "re-enter: prompt visible")
				_next_phase()
				_hold("interact")
		14:
			if _phase_tick >= 3:
				_release("interact")
				_next_phase()
		15:
			if _phase_tick >= 10:
				_check(mode == DRIVING, "re-enter: DRIVING again")
				_check(int(_van_entry().get("times_activated")) == 2,
					"re-enter: entry count x2 (exit press did not re-enter)")
				_next_phase()
				_hold("interact")
		16: # Exit, then old contact still works.
			if _phase_tick >= 3:
				_release("interact")
				_next_phase()
		17:
			if _phase_tick >= 10:
				_check(mode == ON_FOOT, "exit2: ON_FOOT")
				_next_phase()
				_place(Vector3(0, 0.5, 8))
		18:
			if _phase_tick >= 20:
				_next_phase()
				_hold("interact")
		19:
			if _phase_tick >= 3:
				_release("interact")
				_next_phase()
		20:
			if _phase_tick >= 10:
				_check(int(_contact.get("times_activated")) == 1,
					"regression: courier contact still works")
				# Task 4: the contact now briefs HB-01 instead of the old placeholder.
				_check(String(_toast.get("last_message")).contains("HB-01"),
					"regression: courier briefing intact")
				_check(_player.global_position.y > -0.5, "global: never fell through")
				_finish()
	if _tick > 1500:
		_failures.append("timeout: exceeded 1500 physics ticks")
		_finish()


func _player_cam() -> Camera3D:
	return root.get_node("Main/Player/CamPivot/SpringArm/Camera") as Camera3D


func _drive_cam() -> Camera3D:
	return root.get_node("Main/Van/DrivePivot/SpringArm/DriveCamera") as Camera3D


func _van_entry() -> Area3D:
	return root.get_node("Main/Van/Entry") as Area3D


func _prompt_visible(path: String) -> bool:
	var area := root.get_node_or_null(path) as Area3D
	if area == null:
		return false
	var prompt := area.get_node_or_null("Prompt") as Label3D
	return prompt != null and prompt.visible


func _next_phase() -> void:
	_phase += 1
	_phase_tick = 0


func _check(ok: bool, check_name: String) -> void:
	print(("VEHICLE-PASS: " if ok else "VEHICLE-FAIL: ") + check_name)
	if not ok:
		_failures.append(check_name)


func _finish() -> void:
	if _failures.is_empty():
		print("VEHICLE-RESULT: ALL PASS")
		quit(0)
	else:
		print("VEHICLE-RESULT: %d FAILURE(S)" % _failures.size())
		quit(1)
