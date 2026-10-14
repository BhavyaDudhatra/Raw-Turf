extends SceneTree
## Task 5 save/load test — deterministic fixtures, test slot only.
## Run: Godot_console --headless --path <project> --script res://tools/save_test_task5.gd
## Exit 0 = pass, 1 = failures, 2 = load error/timeout.
## Uses slot "task5test" under userdata/saves (B:); cleans its own files and
## NEVER touches the primary "savegame" slot. Covers: JSON creation + B: path,
## transform/wallet/state round trips (AVAILABLE/ACTIVE/COMPLETED/DRIVING),
## single reward after load, suppressed auto-complete on restore, missing /
## malformed / bad-version / incomplete / out-of-range saves rejected with live
## state preserved, failed writes keep the previous valid save.

const SLOT := "task5test"

var _tick: int = 0
var _phase: int = 0
var _phase_tick: int = 0
var _player: CharacterBody3D
var _van: CharacterBody3D
var _sys: Node
var _mission: Node
var _saver: Node
var _toast: CanvasLayer
var _failures: Array[String] = []
var _saved_player := Vector3.ZERO
var _saved_van := Vector3.ZERO


func _initialize() -> void:
	var ps := load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		push_error("SAVE-TEST: main.tscn failed to load")
		quit(2)
		return
	var m: Node = ps.instantiate()
	root.add_child.call_deferred(m)
	physics_frame.connect(_on_physics)


func _slot_path() -> String:
	return String(_saver.call("get_save_path", SLOT))


func _json_of_slot() -> Variant:
	var f := FileAccess.open(_slot_path(), FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return null
	return parser.get_data()


func _write_slot_raw(text: String) -> void:
	var f := FileAccess.open(_slot_path(), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _on_physics() -> void:
	if _player == null:
		_player = root.get_node_or_null("Main/Player") as CharacterBody3D
		_van = root.get_node_or_null("Main/Van") as CharacterBody3D
		_sys = root.get_node_or_null("Main/VehicleSystem")
		_mission = root.get_node_or_null("Main/HB01Mission")
		_saver = root.get_node_or_null("Main/SaveSystem")
		_toast = root.get_node_or_null("Main/Toast") as CanvasLayer
		if _player == null or _saver == null:
			return
	_tick += 1
	_phase_tick += 1
	match _phase:
		0: # Save path resolves under the project (B:), never user://.
			if _phase_tick >= 20:
				var p := _slot_path()
				var root_path := ProjectSettings.globalize_path("res://")
				_check(p.begins_with(root_path), "path: slot under project")
				_check(p.contains("userdata"), "path: uses userdata dir")
				_check(not p.contains("AppData") and not p.begins_with("user:"),
					"path: not on C: user data")
				_next_phase()
				_player.global_position = Vector3(5, 0.5, 5)
				_van.global_position = Vector3(10, 0.5, -5)
				_van.rotation.y = 0.7
		1: # AVAILABLE round trip.
			if _phase_tick >= 15:
				_check(bool(_saver.call("save_game", SLOT)), "save: AVAILABLE writes")
				_check(FileAccess.file_exists(_slot_path()), "save: JSON file exists")
				var j: Variant = _json_of_slot()
				_check(typeof(j) == TYPE_DICTIONARY and int(j["schema"]) == 1,
					"save: valid versioned JSON")
				_saved_player = _player.global_position
				_saved_van = _van.global_position
				_next_phase()
				_player.global_position = Vector3(-8, 0.5, 9)
				_van.global_position = Vector3(-12, 0.5, -9)
		2:
			if _phase_tick >= 10:
				_check(bool(_saver.call("load_game", SLOT)), "load: AVAILABLE reads")
				_check(_player.global_position.distance_to(_saved_player) < 0.3,
					"load: player transform restored")
				_check(_van.global_position.distance_to(_saved_van) < 0.3,
					"load: van transform restored")
				_check(int(_mission.get("state")) == 0, "load: still AVAILABLE")
				_check(int(_mission.get("balance")) == 0, "load: balance 0")
				_next_phase()
				_mission.call("accept_mission")
		3: # ACTIVE round trip (van parked near dock, must NOT complete).
			if _phase_tick >= 10:
				_check(int(_mission.get("state")) == 1, "setup: ACTIVE")
				# z=-5 keeps the whole van body clear of the trigger (z -16..-10).
				_van.global_position = Vector3(16.5, 0.5, -5)
				_saved_van = _van.global_position
				_next_phase()
		4:
			if _phase_tick >= 10:
				_check(bool(_saver.call("save_game", SLOT)), "save: ACTIVE writes")
				_van.global_position = Vector3(0, 0.5, 0)
				_next_phase()
		5:
			if _phase_tick >= 10:
				_check(bool(_saver.call("load_game", SLOT)), "load: ACTIVE reads")
				_check(int(_mission.get("state")) == 1, "load: still ACTIVE")
				_check(_van.global_position.distance_to(_saved_van) < 0.5,
					"load: van near dock restored")
				_check(int(_mission.get("balance")) == 0,
					"load: near dock did not auto-complete")
				_next_phase()
				_sys.call("request_enter")
		6: # DRIVING round trip.
			if _phase_tick >= 10:
				_check(int(_sys.get("mode")) == 1, "setup: DRIVING")
				_van.global_position = Vector3(7, 0.5, 7)
				_van.rotation.y = 1.2
				_saved_van = _van.global_position
				_check(bool(_saver.call("save_game", SLOT)), "save: DRIVING writes")
				_next_phase()
		7: # Settle with E released: arms the exit edge order-independently.
			if _phase_tick >= 5:
				_next_phase()
		8:
			if _phase_tick == 1:
				Input.action_press("interact")
			elif _phase_tick == 4:
				Input.action_release("interact")
			elif _phase_tick >= 10:
				print("SAVE-DBG mode=", int(_sys.get("mode")), " van=", _van.global_position,
					" spot=", _sys.call("_find_exit_spot"))
				_check(int(_sys.get("mode")) == 0, "setup: exited to ON_FOOT")
				_player.global_position = Vector3(-10, 0.5, 10)
				_next_phase()
		9:
			if _phase_tick >= 10:
				_check(bool(_saver.call("load_game", SLOT)), "load: DRIVING reads")
				_check(int(_sys.get("mode")) == 1, "load: DRIVING restored")
				_check(not _player.visible, "load: player hidden while driving")
				_check(not bool(_player.get("controls_enabled")),
					"load: controls off while driving")
				_check(_drive_cam_current(), "load: van camera current")
				_check(_van.global_position.distance_to(_saved_van) < 0.5,
					"load: van spot restored")
				_next_phase()
				_mission.call("suppress_completion", 100000)
				_van.global_position = Vector3(16.5, 0.5, -13)
		10: # Van placed inside dock under suppression, then saved.
			if _phase_tick >= 15:
				_check(int(_mission.get("state")) == 1,
					"suppress: dock entry did not complete")
				_check(bool(_saver.call("save_game", SLOT)), "save: ACTIVE in-dock writes")
				_mission.call("suppress_completion", 0)
				_van.global_position = Vector3(0, 0.5, 0)
				_next_phase()
		11: # Loading van-in-dock must NOT auto-complete.
			if _phase_tick >= 10:
				_check(bool(_saver.call("load_game", SLOT)), "load: in-dock reads")
				_check(int(_mission.get("state")) == 1,
					"load: restore did not auto-complete")
				_check(int(_mission.get("balance")) == 0,
					"load: no reward on restore")
				_next_phase()
				_van.global_position = Vector3(10, 0.5, -13)
		12:
			if _phase_tick >= 15:
				_van.global_position = Vector3(16.5, 0.5, -13)
				_next_phase()
		13: # Real delivery after load still pays exactly once.
			if _phase_tick >= 20:
				_check(int(_mission.get("state")) == 2, "delivery: COMPLETED")
				_check(int(_mission.get("balance")) == 150, "delivery: +150cr")
				_check(bool(_saver.call("save_game", SLOT)), "save: COMPLETED writes")
				_next_phase()
				_van.global_position = Vector3(0, 0.5, 0)
		14:
			if _phase_tick >= 10:
				_van.global_position = Vector3(16.5, 0.5, -13)
				_next_phase()
		15:
			if _phase_tick >= 20:
				_check(bool(_saver.call("load_game", SLOT)), "load: COMPLETED reads")
				_check(int(_mission.get("state")) == 2, "load: stays COMPLETED")
				_check(int(_mission.get("balance")) == 150, "load: stays 150cr")
				_next_phase()
				# Park the hidden player clear of every trigger so the exit
				# press below cannot also fire the contact or van entry.
				_player.global_position = Vector3(-10, 0.5, 10)
				Input.action_press("interact")
		16: # Exit beside the dock (overlapping its trigger): must still work,
			# proving trigger volumes never block exit spots.
			if _phase_tick >= 3:
				Input.action_release("interact")
				_next_phase()
		17:
			if _phase_tick == 1:
				Input.action_press("interact")
			elif _phase_tick == 4:
				Input.action_release("interact")
			elif _phase_tick >= 10:
				_check(int(_sys.get("mode")) == 0, "dock-exit: ON_FOOT")
				_check(_player.global_position.y > -0.5, "dock-exit: y sane")
				_check(String(_toast_text()).contains("On foot"), "dock-exit: exit toast")
				_next_phase()
		18: # Missing file: graceful, live preserved.
			# (Long wait: the exited player must finish landing first.)
			if _phase_tick >= 20:
				_saved_player = _player.global_position
				_check(not bool(_saver.call("load_game", "nope_missing_xyz")),
					"missing: load returns false")
				_check(_player.global_position.distance_to(_saved_player) < 0.01,
					"missing: live state preserved")
				_next_phase()
				_write_slot_raw("this is not json {{{")
		19: # Malformed JSON: rejected, live preserved.
			if _phase_tick >= 5:
				_check(not bool(_saver.call("load_game", SLOT)),
					"malformed: load returns false")
				_check(_player.global_position.distance_to(_saved_player) < 0.01,
					"malformed: live state preserved")
				_check(int(_mission.get("state")) == 2, "malformed: mission intact")
				_next_phase()
				_write_slot_raw('{"schema": 999, "player": {"pos": [0,1,8], "yaw": 0}}')
		20: # Future schema: rejected.
			if _phase_tick >= 5:
				_check(not bool(_saver.call("load_game", SLOT)),
					"version: future schema rejected")
				_check(int(_mission.get("state")) == 2, "version: mission intact")
				_next_phase()
				_write_slot_raw('{"schema": 1}')
		21: # Missing fields: rejected.
			if _phase_tick >= 5:
				_check(not bool(_saver.call("load_game", SLOT)),
					"fields: incomplete save rejected")
				_check(int(_mission.get("balance")) == 150, "fields: wallet intact")
				_next_phase()
				_write_slot_raw(
					'{"schema": 1, "player": {"pos": [1e10, 0, 0], "yaw": 0}, '
					+ '"van": {"pos": [0, 0, 0], "yaw": 0}, "mode": 0, '
					+ '"mission": {"state": 0, "balance": 0, "reward_paid": false}}')
		22: # Out-of-range coordinates: rejected, live preserved.
			if _phase_tick >= 5:
				_check(not bool(_saver.call("load_game", SLOT)),
					"coords: out-of-range rejected")
				_check(_player.global_position.distance_to(_saved_player) < 0.01,
					"coords: live state preserved")
				_next_phase()
		23: # Failed write keeps the previous valid save.
			if _phase_tick >= 5:
				_check(bool(_saver.call("save_game", SLOT)), "setup: valid save written")
				# Unwritable override: nested under an existing FILE, so the
				# directory can never be created (no C: fallback attempted).
				_saver.set("save_dir_override",
					"B:/Engines/Godot/Godot_v4.7.2-stable_win64.exe/saves")
				_check(not bool(_saver.call("save_game", SLOT)),
					"write-fail: returns false, no C: fallback")
				_saver.set("save_dir_override", "B:/Study/Projects/VibeCoding/GTA/userdata/saves")
				_saver.set("save_enabled", true)
				_check(bool(_saver.call("load_game", SLOT)), "write-fail: previous save loads")
				_check(int(_mission.get("state")) == 2, "write-fail: state intact")
				_next_phase()
		24: # Cleanup own test files only; primary slot never touched.
			if _phase_tick >= 5:
				var base := _slot_path()
				var primary := ProjectSettings.globalize_path("res://").path_join(
					"userdata/saves/savegame.json")
				_check(base != primary, "slot: test used its own slot, not primary")
				for extra in ["", ".tmp", ".bak"]:
					if FileAccess.file_exists(base + extra):
						DirAccess.remove_absolute(base + extra)
				_check(not FileAccess.file_exists(base), "cleanup: test files removed")
				_finish()
	if _tick > 2000:
		_failures.append("timeout: exceeded 2000 physics ticks")
		_finish()


func _drive_cam_current() -> bool:
	var c := root.get_node_or_null("Main/Van/DrivePivot/SpringArm/DriveCamera") as Camera3D
	return c != null and c.current


func _toast_text() -> String:
	return "" if _toast == null else String(_toast.get("last_message"))


func _next_phase() -> void:
	_phase += 1
	_phase_tick = 0


func _check(ok: bool, check_name: String) -> void:
	print(("SAVE-PASS: " if ok else "SAVE-FAIL: ") + check_name)
	if not ok:
		_failures.append(check_name)


func _finish() -> void:
	if _failures.is_empty():
		print("SAVE-RESULT: ALL PASS")
		quit(0)
	else:
		print("SAVE-RESULT: %d FAILURE(S)" % _failures.size())
		quit(1)
