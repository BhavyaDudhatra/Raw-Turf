extends SceneTree
## Task 1 headless smoke test — drives the real main.tscn with synthetic input.
## Run: Godot_console --headless --path <project> --script res://tools/smoke_test_task1.gd
## Exit 0 = all checks passed, 1 = failures, 2 = load error/timeout.
## Covers: settle/ground collision, walk, sprint, strafe, jump arc, landing,
## no-fall-through, movement modes, debug overlay text. Camera/mouse and
## rendered visuals are NOT covered here — see manual test instructions.

var _tick: int = 0
var _phase: int = 0
var _phase_tick: int = 0
var _player: CharacterBody3D
var _label: Label
var _failures: Array[String] = []
var _start_pos := Vector3.ZERO
var _peak_y := 0.0
var _min_y := 999.0
var _saw_airborne := false


func _initialize() -> void:
	var ps: PackedScene = load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		push_error("SMOKE: main.tscn failed to load")
		quit(2)
		return
	var m: Node = ps.instantiate()
	root.add_child.call_deferred(m)
	physics_frame.connect(_on_physics)


func _on_physics() -> void:
	if _player == null:
		_player = root.get_node_or_null("Main/Player") as CharacterBody3D
		_label = root.get_node_or_null("Main/DebugOverlay/Label") as Label
		if _player == null:
			return
	_tick += 1
	_phase_tick += 1
	var p: Vector3 = _player.global_position
	_min_y = minf(_min_y, p.y)
	_peak_y = maxf(_peak_y, p.y)
	if String(_player.get("movement_mode")) == "airborne":
		_saw_airborne = true
	match _phase:
		0: # Settle: player drops 0.1 m and lands.
			if _phase_tick >= 30:
				_check(_player.is_on_floor(), "settle: player on floor")
				_check(absf(p.y) < 0.3, "settle: y near 0 (got %.2f)" % p.y)
				_start_pos = p
				_next_phase()
				Input.action_press("move_forward")
		1: # Walk 60 ticks (~1 s at 4 m/s -> expect >= 2.5 m).
			if _phase_tick >= 60:
				var d := p - _start_pos
				_check(-d.z >= 2.5, "walk: forward >= 2.5m (got %.2f)" % -d.z)
				_check(absf(d.x) < 0.6, "walk: no strafe drift (x %.2f)" % d.x)
				_check(String(_player.get("movement_mode")) == "walking", "walk: mode is walking")
				_start_pos = p
				_next_phase()
				Input.action_press("sprint")
		2: # Sprint 60 ticks (~1 s at 7 m/s -> expect >= 4.5 m).
			if _phase_tick >= 60:
				var d2 := p - _start_pos
				_check(-d2.z >= 4.5, "sprint: forward >= 4.5m (got %.2f)" % -d2.z)
				_check(String(_player.get("movement_mode")) == "sprinting", "sprint: mode is sprinting")
				_start_pos = p
				_next_phase()
				Input.action_release("sprint")
				Input.action_release("move_forward")
		3: # Full stop 30 ticks: residual momentum must decay (no ice slide).
			if _phase_tick >= 30:
				var v := _player.velocity
				var planar := Vector2(v.x, v.z).length()
				_check(planar < 0.6, "stop: decays to rest (speed %.2f)" % planar)
				_start_pos = p
				_next_phase()
				Input.action_press("move_left")
		4: # Strafe left 45 ticks (expect >= 1.5 m on -X).
			if _phase_tick >= 45:
				var d3 := p - _start_pos
				_check(-d3.x >= 1.5, "strafe: left >= 1.5m (got %.2f)" % -d3.x)
				_check(absf(d3.z) < 0.8, "strafe: no fwd drift (z %.2f)" % d3.z)
				Input.action_release("move_left")
				_peak_y = p.y
				_saw_airborne = false
				_next_phase()
				Input.action_press("jump")
		5: # Single-tick jump tap (no held multi-jump), then observe.
			Input.action_release("jump")
			_next_phase()
		6: # Observe 120 ticks: rise ~1.2 m, land, overlay alive.
			if _phase_tick >= 120:
				_check(_saw_airborne, "jump: airborne observed")
				_check(_peak_y >= 0.6 and _peak_y <= 2.2,
					"jump: peak in [0.6, 2.2] (got %.2f)" % _peak_y)
				_check(_player.is_on_floor(), "jump: landed back on floor")
				_check(absf(p.y) < 0.3, "jump: y near 0 after land (got %.2f)" % p.y)
				_check(_min_y > -0.5, "global: never fell through (min %.2f)" % _min_y)
				_check(_label != null and _label.text.length() > 10 and _label.text.contains("FPS"),
					"overlay: label populated")
				_finish()
	if _tick > 1200:
		_failures.append("timeout: exceeded 1200 physics ticks")
		_finish()


func _next_phase() -> void:
	_phase += 1
	_phase_tick = 0


func _check(ok: bool, check_name: String) -> void:
	print(("SMOKE-PASS: " if ok else "SMOKE-FAIL: ") + check_name)
	if not ok:
		_failures.append(check_name)


func _finish() -> void:
	if _failures.is_empty():
		print("SMOKE-RESULT: ALL PASS")
		quit(0)
	else:
		print("SMOKE-RESULT: %d FAILURE(S)" % _failures.size())
		quit(1)
