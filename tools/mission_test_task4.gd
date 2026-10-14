extends SceneTree
## Task 4 mission test — HB-01 full flow with synthetic input.
## Run: Godot_console --headless --path <project> --script res://tools/mission_test_task4.gd
## Exit 0 = pass, 1 = failures, 2 = load error/timeout.
## Covers: AVAILABLE start, pre-accept drive-in no-op, on-foot no-op,
## accept -> ACTIVE, no duplicate accept, unrelated body no-op, van delivery,
## single reward, COMPLETED, beacon on/off, HUD text, exit-near-dock valid,
## completed-contact message. Older suites run separately (see report).

var _tick: int = 0
var _phase: int = 0
var _phase_tick: int = 0
var _player: CharacterBody3D
var _van: CharacterBody3D
var _sys: Node
var _mission: Node
var _dock: Area3D
var _toast: CanvasLayer
var _failures: Array[String] = []
var _stray: CharacterBody3D


func _initialize() -> void:
	var ps := load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		push_error("MISSION-TEST: main.tscn failed to load")
		quit(2)
		return
	var m: Node = ps.instantiate()
	root.add_child.call_deferred(m)
	physics_frame.connect(_on_physics)


func _place(p: Vector3) -> void:
	_player.global_position = p
	_player.velocity = Vector3.ZERO


func _dock_center() -> Vector3:
	return Vector3(16.5, 0.5, -13)


func _on_physics() -> void:
	if _player == null:
		_player = root.get_node_or_null("Main/Player") as CharacterBody3D
		_van = root.get_node_or_null("Main/Van") as CharacterBody3D
		_sys = root.get_node_or_null("Main/VehicleSystem")
		_mission = root.get_node_or_null("Main/HB01Mission")
		_dock = root.get_node_or_null("Main/DeliveryDock") as Area3D
		_toast = root.get_node_or_null("Main/Toast") as CanvasLayer
		if _player == null or _van == null or _mission == null or _dock == null:
			return
	_tick += 1
	_phase_tick += 1
	var state := int(_mission.get("state"))
	match _phase:
		0: # Initial state.
			if _phase_tick >= 30:
				_check(state == 0, "init: AVAILABLE")
				_check(int(_mission.get("balance")) == 0, "init: balance 0")
				_check(not _beacon_visible(), "init: beacon hidden")
				_check(_hud_text().contains("HB-01"), "init: HUD names mission")
				_next_phase()
				_van.global_position = _dock_center()
		1: # Van in dock BEFORE accept: must not complete.
			if _phase_tick >= 20:
				_check(state == 0, "pre-accept: still AVAILABLE")
				_check(int(_mission.get("balance")) == 0, "pre-accept: no reward")
				_next_phase()
				_van.global_position = Vector3(14, 0.5, 0)
				_van.rotation.y = -1.5708
				_place(_dock_center())
		2: # On foot in dock: must not complete.
			if _phase_tick >= 20:
				_check(state == 0, "foot: still AVAILABLE")
				_check(int(_mission.get("balance")) == 0, "foot: no reward")
				_next_phase()
				_place(Vector3(1.0, 0.5, 7.0))
		3: # At the contact: prompt shows the accept text.
			if _phase_tick >= 15:
				_check(_contact_prompt().contains("Accept"), "contact: accept prompt shown")
				_next_phase()
				Input.action_press("interact")
		4:
			if _phase_tick >= 3:
				Input.action_release("interact")
				_next_phase()
		5: # Accepted exactly once.
			if _phase_tick >= 10:
				_check(state == 1, "accept: ACTIVE")
				_check(_beacon_visible(), "accept: beacon shown")
				_check(_toast_text().contains("ACCEPTED"), "accept: briefing toast")
				_check(_hud_text().contains("Pier 9"), "accept: HUD directs to dock")
				_next_phase()
				Input.action_press("interact")
		6:
			if _phase_tick >= 3:
				Input.action_release("interact")
				_next_phase()
		7: # Second E: status only, no duplicate mission, no reward.
			if _phase_tick >= 10:
				_check(state == 1, "re-press: still ACTIVE (no duplicate)")
				_check(int(_mission.get("balance")) == 0, "re-press: no early reward")
				_next_phase()
				_stray = CharacterBody3D.new()
				var col := CollisionShape3D.new()
				var sph := SphereShape3D.new()
				sph.radius = 0.4
				col.shape = sph
				_stray.add_child(col)
				root.add_child(_stray)
				_stray.global_position = _dock_center()
		8: # Unrelated body in dock: must not complete.
			if _phase_tick >= 20:
				_check(state == 1, "stray: still ACTIVE")
				_check(int(_mission.get("balance")) == 0, "stray: no reward")
				_stray.queue_free()
				_stray = null
				_next_phase()
				_place(Vector3(11.5, 0.5, 1.0))
		9: # To the van: enter while ACTIVE.
			if _phase_tick >= 15:
				_next_phase()
				Input.action_press("interact")
		10:
			if _phase_tick >= 3:
				Input.action_release("interact")
				_next_phase()
		11:
			if _phase_tick >= 10:
				_check(int(_sys.get("mode")) == 1, "enter: DRIVING")
				_next_phase()
				_van.global_position = _dock_center()
		12: # Van delivery completes exactly once.
			if _phase_tick >= 20:
				_check(state == 2, "delivery: COMPLETED")
				_check(int(_mission.get("balance")) == 150, "delivery: +150cr")
				_check(bool(_mission.get("reward_paid")), "delivery: reward_paid set")
				_check(_toast_text().contains("DELIVERED"), "delivery: completion toast")
				_check(not _beacon_visible(), "delivery: beacon hidden")
				_check(_hud_text().contains("COMPLETE"), "delivery: HUD complete")
				_next_phase()
				_van.global_position = Vector3(10, 0.5, -13)
		13: # Out and back in: no duplicate reward.
			if _phase_tick >= 10:
				_van.global_position = _dock_center()
				_next_phase()
		14:
			if _phase_tick >= 15:
				_check(int(_mission.get("balance")) == 150, "revisit: still 150cr")
				_check(state == 2, "revisit: still COMPLETED")
				_next_phase()
				Input.action_press("interact")
		15: # Exit the van beside the dock: valid.
			if _phase_tick >= 3:
				Input.action_release("interact")
				_next_phase()
		16:
			if _phase_tick >= 10:
				_check(int(_sys.get("mode")) == 0, "exit: ON_FOOT near dock")
				_check(_player.global_position.y > -0.5, "exit: y sane")
				_next_phase()
				_place(Vector3(1.0, 0.5, 7.0))
		17: # Contact after completion: finished message, balance intact.
			if _phase_tick >= 15:
				_next_phase()
				Input.action_press("interact")
		18:
			if _phase_tick >= 3:
				Input.action_release("interact")
				_next_phase()
		19:
			if _phase_tick >= 10:
				_check(_toast_text().contains("done"), "done: finished message")
				_check(int(_mission.get("balance")) == 150, "done: balance intact")
				_finish()
	if _tick > 1500:
		_failures.append("timeout: exceeded 1500 physics ticks")
		_finish()


func _beacon_visible() -> bool:
	var b := root.get_node_or_null("Main/DeliveryDock/Beacon") as MeshInstance3D
	return b != null and b.visible


func _hud_text() -> String:
	var hud := root.get_node_or_null("Main/MissionHUD/Label") as Label
	return "" if hud == null else hud.text


func _toast_text() -> String:
	return "" if _toast == null else String(_toast.get("last_message"))


func _contact_prompt() -> String:
	var p := root.get_node_or_null("Main/CourierContact/Prompt") as Label3D
	return "" if p == null else p.text


func _next_phase() -> void:
	_phase += 1
	_phase_tick = 0


func _check(ok: bool, check_name: String) -> void:
	print(("MISSION-PASS: " if ok else "MISSION-FAIL: ") + check_name)
	if not ok:
		_failures.append(check_name)


func _finish() -> void:
	if _failures.is_empty():
		print("MISSION-RESULT: ALL PASS")
		quit(0)
	else:
		print("MISSION-RESULT: %d FAILURE(S)" % _failures.size())
		quit(1)
