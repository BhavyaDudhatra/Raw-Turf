extends SceneTree
## Task 2 interaction test — drives the real main.tscn with synthetic input.
## Run: Godot_console --headless --path <project> --script res://tools/interact_test_task2.gd
## Exit 0 = all checks passed, 1 = failures, 2 = load error/timeout.
## Covers: prompt shows in range, E activates correct target exactly once,
## distant targets cannot activate, prompt hides out of range, toast content.
## Movement regression is covered by smoke_test_task1.gd (run separately).

var _tick: int = 0
var _phase: int = 0
var _phase_tick: int = 0
var _player: CharacterBody3D
var _contact: Area3D
var _garage: Area3D
var _toast: CanvasLayer
var _failures: Array[String] = []


func _initialize() -> void:
	var ps := load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		push_error("INTERACT-TEST: main.tscn failed to load")
		quit(2)
		return
	var m: Node = ps.instantiate()
	root.add_child.call_deferred(m)
	physics_frame.connect(_on_physics)


func _place(p: Vector3) -> void:
	_player.global_position = p
	_player.velocity = Vector3.ZERO


func _on_physics() -> void:
	if _player == null:
		_player = root.get_node_or_null("Main/Player") as CharacterBody3D
		_contact = root.get_node_or_null("Main/CourierContact") as Area3D
		_garage = root.get_node_or_null("Main/GarageDoor") as Area3D
		_toast = root.get_node_or_null("Main/Toast") as CanvasLayer
		if _player == null or _contact == null or _garage == null or _toast == null:
			return
	_tick += 1
	_phase_tick += 1
	match _phase:
		0: # Settle at spawn (dist to contact ~2.8 m — inside r=3).
			if _phase_tick >= 30:
				_check(_player.is_on_floor(), "spawn: player on floor")
				_check(_prompt_visible(_contact), "contact: prompt visible at spawn")
				_check(not _prompt_visible(_garage), "garage: prompt hidden at spawn")
				_next_phase()
				Input.action_press("interact")
		1: # Hold E a few ticks so the press spans full physics frames.
			if _phase_tick >= 3:
				Input.action_release("interact")
				_next_phase()
		2: # Let the press process; then assert exactly one activation.
			if _phase_tick >= 15:
				_check(int(_contact.get("times_activated")) == 1, "contact: activated exactly once")
				_check(int(_garage.get("times_activated")) == 0, "garage: not activated from spawn")
				_check(String(_toast.get("last_message")).contains("COURIER"),
					"toast: shows courier message")
				_next_phase()
				_place(Vector3(-15, 0.5, -2))
		3: # Far from both targets: E must do nothing, prompts hidden.
			if _phase_tick >= 20:
				_check(not _prompt_visible(_contact), "far: contact prompt hidden")
				_check(not _prompt_visible(_garage), "far: garage prompt hidden")
				_next_phase()
				Input.action_press("interact")
		4:
			if _phase_tick >= 3:
				Input.action_release("interact")
				_next_phase()
		5:
			if _phase_tick >= 15:
				_check(int(_contact.get("times_activated")) == 1, "far: contact still x1")
				_check(int(_garage.get("times_activated")) == 0, "far: garage still x0")
				_next_phase()
				_place(Vector3(8, 0.5, 6.5))
		6: # At the garage door: prompt shows, E activates garage only.
			if _phase_tick >= 20:
				_check(_prompt_visible(_garage), "garage: prompt visible in range")
				_check(not _prompt_visible(_contact), "garage: contact prompt hidden")
				_next_phase()
				Input.action_press("interact")
		7:
			if _phase_tick >= 3:
				Input.action_release("interact")
				_next_phase()
		8:
			if _phase_tick >= 15:
				_check(int(_garage.get("times_activated")) == 1, "garage: activated exactly once")
				_check(int(_contact.get("times_activated")) == 1, "garage: contact still x1")
				_check(String(_toast.get("last_message")).contains("GARAGE"),
					"toast: shows garage message")
				_check(_player.global_position.y > -0.5, "global: never fell through")
				_finish()
	if _tick > 1200:
		_failures.append("timeout: exceeded 1200 physics ticks")
		_finish()


func _prompt_visible(area: Area3D) -> bool:
	var prompt := area.get_node_or_null("Prompt") as Label3D
	return prompt != null and prompt.visible


func _next_phase() -> void:
	_phase += 1
	_phase_tick = 0


func _check(ok: bool, check_name: String) -> void:
	print(("INTERACT-PASS: " if ok else "INTERACT-FAIL: ") + check_name)
	if not ok:
		_failures.append(check_name)


func _finish() -> void:
	if _failures.is_empty():
		print("INTERACT-RESULT: ALL PASS")
		quit(0)
	else:
		print("INTERACT-RESULT: %d FAILURE(S)" % _failures.size())
		quit(1)
