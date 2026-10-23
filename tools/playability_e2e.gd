extends SceneTree
## End-to-end playability test — drives the REAL main.tscn through the whole
## current gameplay loop with synthetic input:
##
##   boot -> spawn -> movement/collision -> interaction prompt + E ->
##   enter courier van -> drive -> HB-01 delivery -> wallet/mission state ->
##   exit van safely -> save (F6) -> mutate -> load (F9) -> compare
##
## Nothing is mocked: every scene, script, group and input path is the
## production one. The only fixture is the van being parked in the dock lane
## before the delivery drive (the map geometry makes a single-arc approach
## from the van spawn impossible without crossing the warehouse); the
## delivery itself is completed by the van physically driving onto the dock
## and the real Area3D `body_entered` path firing.
##
## Run: Godot --headless --path <project> --script res://tools/playability_e2e.gd
## Exit 0 = all checks passed, 1 = failures, 2 = load error/timeout.
##
## Saves: `save_dir_override` is redirected to an isolated folder under
## reports/ (still on B:). The real userdata/saves directory is snapshotted
## at boot and re-checked at the end — it must be byte-identical.

const SPAWN := Vector3(0.0, 1.0, 8.0)
const CONTACT := Vector3(2.2, 0.0, 6.2)
const VAN_SPAWN := Vector3(14.0, 0.5, 0.0)
const DOCK := Vector3(16.5, 0.0, -13.0)
## Parking fixture: the dock lane, clear of the warehouse and the east wall.
const LANE := Vector3(16.5, 0.5, -2.0)
const SAVE_DIR_REL := "res://reports/20261022_stabilize_playable/e2e_saves"

const MISSION_AVAILABLE := 0
const MISSION_ACTIVE := 1
const MISSION_COMPLETED := 2

enum P {
	BOOT, PROMPT, MOVE, RETURN, INTERACT, LEAVE, COLLIDE,
	TO_VAN, ENTER, DRIVE_TEST, LANE, DOCKED, EXIT,
	SAVE, MUTATE, LOAD, SAFETY, DONE,
}

var _tick: int = 0
var _phase: int = P.BOOT
var _phase_tick: int = 0
var _fails: Array[String] = []
var _checks: int = 0
var _isolated := false

var _player: CharacterBody3D
var _pivot: Node3D
var _van: CharacterBody3D
var _sys: Node
var _mission: Node
var _dock: Area3D
var _contact: Area3D
var _entry: Area3D
var _save: Node
var _toast: CanvasLayer
var _hud: Label
var _beacon: MeshInstance3D

var _walk_target := Vector3.ZERO
var _walk_start := Vector3.ZERO
var _waypoints: Array[Vector3] = []
var _waypoint := 0
var _max_z := -999.0
var _van_start := Vector3.ZERO
var _expect_state := 0
var _expect_balance := 0
var _expect_mode := 0
var _expect_player := Vector3.ZERO
var _expect_van := Vector3.ZERO
var _primary_snapshot := ""
var _save_path := ""


func _initialize() -> void:
	var ps := load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		push_error("E2E: main.tscn failed to load")
		quit(2)
		return
	# Snapshot the real save folder BEFORE anything runs so we can prove it
	# was never touched by this test.
	_primary_snapshot = _snapshot_dir(ProjectSettings.globalize_path("res://userdata/saves"))
	root.add_child.call_deferred(ps.instantiate())
	physics_frame.connect(_on_physics)


func _on_physics() -> void:
	_tick += 1
	_phase_tick += 1
	if _player == null:
		if not _resolve_nodes():
			return
	match _phase:
		P.BOOT: _p_boot()
		P.PROMPT: _p_prompt()
		P.MOVE: _p_move()
		P.RETURN: _p_return()
		P.INTERACT: _p_interact()
		P.LEAVE: _p_leave()
		P.COLLIDE: _p_collide()
		P.TO_VAN: _p_to_van()
		P.ENTER: _p_enter()
		P.DRIVE_TEST: _p_drive_test()
		P.LANE: _p_lane()
		P.DOCKED: _p_docked()
		P.EXIT: _p_exit()
		P.SAVE: _p_save()
		P.MUTATE: _p_mutate()
		P.LOAD: _p_load()
		P.SAFETY: _p_safety()
		P.DONE: pass
	if _tick > 6000:
		_fail("timeout: exceeded 6000 physics ticks")
		_finish()


# ---------------------------------------------------------------- resolution

func _resolve_nodes() -> bool:
	_player = root.get_node_or_null("Main/Player") as CharacterBody3D
	_pivot = root.get_node_or_null("Main/Player/CamPivot") as Node3D
	_van = root.get_node_or_null("Main/Van") as CharacterBody3D
	_sys = root.get_node_or_null("Main/VehicleSystem")
	_mission = root.get_node_or_null("Main/HB01Mission")
	_dock = root.get_node_or_null("Main/DeliveryDock") as Area3D
	_contact = root.get_node_or_null("Main/CourierContact") as Area3D
	_save = root.get_node_or_null("Main/SaveSystem")
	_toast = root.get_node_or_null("Main/Toast") as CanvasLayer
	_hud = root.get_node_or_null("Main/MissionHUD/Label") as Label
	if _player == null or _van == null or _sys == null or _mission == null \
			or _dock == null or _contact == null or _save == null:
		return false
	_entry = _van.get_node_or_null("Entry") as Area3D
	_beacon = _dock.get_node_or_null("Beacon") as MeshInstance3D
	return true


# ------------------------------------------------------------------- phases

func _p_boot() -> void:
	if not _isolated:
		_isolated = true
		# Isolate the save folder (B:) before any save/load can happen.
		var dir := ProjectSettings.globalize_path(SAVE_DIR_REL)
		DirAccess.make_dir_recursive_absolute(dir)
		_save.set("save_dir_override", dir)
		_save_path = dir.path_join("savegame.json")
		_check(true, "boot: save folder isolated at %s" % dir)
	if _phase_tick < 30:
		return
	# --- groups resolve ---------------------------------------------------
	for g in ["player", "mission", "toast", "delivery_dock", "vehicle_system",
			"save_system", "courier_van"]:
		_check(get_nodes_in_group(g).size() >= 1, "boot: group '%s' resolves" % g)
	# --- player spawned ---------------------------------------------------
	_check(_player.is_on_floor(), "boot: player landed on the ground")
	_check(absf(_player.global_position.x - SPAWN.x) < 0.2
			and absf(_player.global_position.z - SPAWN.z) < 0.2
			and _player.global_position.y < 0.1,
		"boot: player spawned at %s (now %s)" % [SPAWN, _player.global_position])
	# --- van present ------------------------------------------------------
	_check(_van.is_on_floor(), "boot: van settled on the ground")
	_check(absf(_van.global_position.x - VAN_SPAWN.x) < 0.5
			and absf(_van.global_position.z - VAN_SPAWN.z) < 0.5,
		"boot: van present at %s" % VAN_SPAWN)
	# --- mission starts AVAILABLE ----------------------------------------
	_check(int(_mission.get("state")) == MISSION_AVAILABLE, "boot: mission AVAILABLE")
	_check(int(_mission.get("balance")) == 0, "boot: wallet starts at 0")
	_next(P.PROMPT)


func _p_prompt() -> void:
	if _phase_tick < 6:
		return
	_check(_prompt_visible(_contact), "prompt: courier prompt visible at spawn (in range)")
	_check(_prompt_visible(_entry) == false, "prompt: van entry prompt hidden at spawn")
	_next(P.MOVE)


func _p_move() -> void:
	# Walk 4 m away from the spawn pad with the real movement input.
	_walk_target = SPAWN + Vector3(0.0, 0.0, 4.0)
	if _phase_tick == 1:
		_walk_start = _player.global_position
	_walk_toward(_walk_target)
	if _phase_tick < 45:
		return
	_release_walk()
	var moved := _player.global_position.distance_to(_walk_start)
	_check(moved > 1.5, "move: player travelled %.2f m on WASD input" % moved)
	_check(_player.is_on_floor(), "move: player still grounded after walking")
	_check(absf(_player.global_position.y) < 0.1, "move: player did not fall through")
	_check(String(_player.get("movement_mode")) in ["walking", "sprinting"],
		"move: movement_mode is '%s'" % String(_player.get("movement_mode")))
	_next(P.RETURN)


func _p_return() -> void:
	# Walk back to Courier Rana — the prompt must come back.
	_walk_target = CONTACT + Vector3(0.0, 0.0, 1.0)
	_walk_toward(_walk_target)
	if _phase_tick > 420:
		_release_walk()
		_fail("move: could not walk back to the courier contact")
		_next(P.INTERACT)
		return
	if _player.global_position.distance_to(_walk_target) > 1.6:
		return
	_release_walk()
	_check(_prompt_visible(_contact), "prompt: courier prompt visible again on return")
	_next(P.INTERACT)


func _p_interact() -> void:
	if _phase_tick == 1:
		Input.action_press("interact")
		return
	if _phase_tick == 4:
		Input.action_release("interact")
		return
	if _phase_tick < 20:
		return
	_check(int(_contact.get("times_activated")) == 1, "interact: contact activated exactly once")
	_check(int(_mission.get("state")) == MISSION_ACTIVE, "interact: E accepted HB-01 (ACTIVE)")
	_check(int(_mission.get("balance")) == 0, "interact: wallet unchanged after accepting")
	_check(String(_toast.get("last_message")).contains("HB-01"),
		"interact: toast shows the HB-01 briefing")
	# A second press must not re-accept or change the wallet.
	Input.action_press("interact")
	_next(P.LEAVE)


func _p_leave() -> void:
	if _phase_tick == 4:
		Input.action_release("interact")
		return
	if _phase_tick < 8:
		return
	# Walk out of the contact range — the prompt must disappear.
	_walk_target = CONTACT + Vector3(0.0, 0.0, 6.0)
	_walk_toward(_walk_target)
	if _phase_tick > 300:
		_release_walk()
		_fail("interact: could not leave the contact range")
		_next(P.COLLIDE)
		return
	if _player.global_position.distance_to(_walk_target) > 1.0:
		return
	_release_walk()
	_check(not _prompt_visible(_contact), "prompt: courier prompt hidden out of range")
	_check(int(_mission.get("state")) == MISSION_ACTIVE,
		"interact: extra E press did not change the mission state")
	_check(int(_mission.get("balance")) == 0, "interact: extra E press did not pay out")
	_next(P.COLLIDE)


func _p_collide() -> void:
	# Sprint into the south world wall: the player must be blocked by it.
	_max_z = _player.global_position.z
	_walk_target = Vector3(0.0, 0.0, 40.0)
	_walk_toward(_walk_target)
	_set_input("sprint", true)
	_max_z = maxf(_max_z, _player.global_position.z)
	if _phase_tick < 400 and _player.global_position.z < 18.4:
		return
	_release_walk()
	_set_input("sprint", false)
	_check(_player.global_position.z < 19.3,
		"collision: player blocked by the wall at z=%.2f (< 19.3)" % _player.global_position.z)
	_check(_max_z < 19.6, "collision: player never passed through the wall (max z=%.2f)" % _max_z)
	_check(_player.is_on_floor(), "collision: player still grounded against the wall")
	_next(P.TO_VAN)


func _p_to_van() -> void:
	# Walk the player over to the courier van (real walking, real collisions).
	# Route: back down the plaza to the Harbor road, then east to the van.
	if _phase_tick == 1:
		_waypoints = [Vector3(0.0, 0.0, 2.0), Vector3(11.5, 0.0, 2.0), Vector3(11.5, 0.0, 0.0)]
		_waypoint = 0
	if _phase_tick > 900:
		_release_walk()
		_fail("van: could not walk to the courier van")
		_next(P.ENTER)
		return
	_p_to_van_step()


func _p_to_van_step() -> void:
	if _waypoint >= _waypoints.size():
		return
	_walk_target = _waypoints[_waypoint]
	_walk_toward(_walk_target)
	if _player.global_position.distance_to(_walk_target) > 1.2:
		return
	_release_walk()
	_waypoint += 1
	if _waypoint < _waypoints.size():
		return
	_check(_prompt_visible(_entry), "van: entry prompt visible next to the van")
	_next(P.ENTER)


func _p_enter() -> void:
	if _phase_tick == 1:
		Input.action_press("interact")
		return
	if _phase_tick == 4:
		Input.action_release("interact")
		return
	if _phase_tick < 16:
		return
	_check(int(_sys.get("mode")) == 1, "van: vehicle system switched to DRIVING")
	_check(not _player.visible, "van: player hidden while seated")
	_check(bool(_player.get("controls_enabled")) == false, "van: on-foot controls disabled")
	_check(_van.get("driving") == true, "van: van is in driving mode")
	_check(_current_camera() == "Main/Van/DrivePivot/SpringArm/DriveCamera",
		"van: drive camera is the active camera")
	_check(int(_entry.get("times_activated")) == 1, "van: entry used exactly once")
	_next(P.DRIVE_TEST)


func _p_drive_test() -> void:
	# Throttle for a short burst from the van's spawn pose, then coast.
	if _phase_tick == 1:
		_van_start = _van.global_position
		_set_input("move_forward", true)
		return
	if _phase_tick == 31:
		_set_input("move_forward", false)
		var speed := float(_van.get("forward_speed"))
		_check(speed > 1.0, "drive: throttle accelerates the van (%.2f m/s)" % speed)
		_check(_van.global_position.distance_to(_van_start) > 0.5,
			"drive: van moved %.2f m under throttle" % _van.global_position.distance_to(_van_start))
		return
	if _phase_tick < 90:
		return
	_check(absf(float(_van.get("forward_speed"))) < 1.0,
		"drive: van coasts to rest after throttle release")
	_next(P.LANE)


func _p_lane() -> void:
	# Parking fixture: put the van in the dock lane facing the dock.
	# (The warehouse blocks a single-arc approach from the van spawn, so the
	# van is parked in the lane first and then DRIVEN in for real.)
	_van.global_position = LANE
	_van.rotation = Vector3(0.0, 0.0, 0.0)
	_van.velocity = Vector3.ZERO
	_van.set("forward_speed", 0.0)
	_check(int(_mission.get("state")) == MISSION_ACTIVE, "dock: mission still ACTIVE before delivery")
	_next(P.DOCKED)


func _p_docked() -> void:
	# Real drive onto the dock: throttle only, the Area3D does the rest.
	_set_input("move_forward", true)
	if int(_mission.get("state")) != MISSION_COMPLETED:
		if _phase_tick < 420:
			return
		_set_input("move_forward", false)
		_fail("dock: van did not reach the dock within 420 ticks (state=%d)"
			% int(_mission.get("state")))
		_next(P.EXIT)
		return
	_set_input("move_forward", false)
	_check(int(_mission.get("state")) == MISSION_COMPLETED, "dock: HB-01 COMPLETED")
	_check(int(_mission.get("balance")) == 150, "dock: wallet paid 150 credits (balance=%d)"
		% int(_mission.get("balance")))
	_check(bool(_mission.get("reward_paid")) == true, "dock: reward_paid flag set")
	_check(_beacon != null and not _beacon.visible, "dock: destination beacon switched off")
	_check(_hud != null and _hud.text.contains("COMPLETE"), "dock: mission HUD shows COMPLETE")
	_check(String(_toast.get("last_message")).contains("DELIVERED"),
		"dock: delivery toast shown")
	_next(P.EXIT)


func _p_exit() -> void:
	if _phase_tick == 1:
		Input.action_press("interact")
		return
	if _phase_tick == 4:
		Input.action_release("interact")
		return
	if _phase_tick < 16:
		return
	_check(int(_sys.get("mode")) == 0, "exit: vehicle system back to ON_FOOT")
	_check(_player.visible, "exit: player visible again")
	_check(bool(_player.get("controls_enabled")) == true, "exit: on-foot controls restored")
	_check(_current_camera() == "Main/Player/CamPivot/SpringArm/Camera",
		"exit: on-foot camera is the active camera")
	_check(absf(float(_van.get("forward_speed"))) < 0.5, "exit: van stopped")
	_check(_spot_is_clear(_player.global_position),
		"exit: player is not inside an obstruction")
	_next(P.SAVE)


func _p_save() -> void:
	# F6 through the real key handler.
	_expect_state = int(_mission.get("state"))
	_expect_balance = int(_mission.get("balance"))
	_expect_mode = int(_sys.get("mode"))
	_expect_player = _player.global_position
	_expect_van = _van.global_position
	if _phase_tick == 1:
		_send_key(KEY_F6)
		return
	if _phase_tick < 20:
		return
	_check(FileAccess.file_exists(_save_path), "save: F6 wrote the save file to the isolated folder")
	_check(String(_save.get("last_error")) == "", "save: no save error reported")
	_next(P.MUTATE)


func _p_mutate() -> void:
	# Change the live state so the load has something real to restore.
	_player.global_position = Vector3(-15.0, 0.0, -12.0)
	_van.global_position = Vector3(-5.0, 0.5, 6.0)
	_van.rotation = Vector3(0.0, 1.0, 0.0)
	if _phase_tick < 10:
		return
	_check(_player.global_position.distance_to(_expect_player) > 5.0,
		"mutate: live state changed before loading")
	_next(P.LOAD)


func _p_load() -> void:
	if _phase_tick == 1:
		_send_key(KEY_F9)
		return
	if _phase_tick < 20:
		return
	_check(String(_save.get("last_error")) == "", "load: no load error reported")
	_check(int(_mission.get("state")) == _expect_state,
		"load: mission state restored (%d)" % _expect_state)
	_check(int(_mission.get("balance")) == _expect_balance,
		"load: wallet restored (%d)" % _expect_balance)
	_check(bool(_mission.get("reward_paid")) == true, "load: reward_paid restored")
	_check(int(_sys.get("mode")) == _expect_mode, "load: vehicle mode restored (%d)" % _expect_mode)
	_check(_player.global_position.distance_to(_expect_player) < 0.5,
		"load: player position restored (%s)" % _player.global_position)
	_check(_van.global_position.distance_to(_expect_van) < 0.5,
		"load: van position restored (%s)" % _van.global_position)
	_next(P.SAFETY)


func _p_safety() -> void:
	# The real save folder must be byte-identical to the pre-test snapshot.
	var now := _snapshot_dir(ProjectSettings.globalize_path("res://userdata/saves"))
	_check(now == _primary_snapshot,
		"safety: real userdata/saves folder untouched by the test")
	_check(not FileAccess.file_exists(
			ProjectSettings.globalize_path("res://userdata/saves/savegame.json")),
		"safety: no primary savegame.json was written")
	_next(P.DONE)
	_finish()


# ------------------------------------------------------------------ helpers

func _next(p: int) -> void:
	_phase = p
	_phase_tick = 0


func _check(ok: bool, name: String) -> void:
	_checks += 1
	print(("E2E-PASS: " if ok else "E2E-FAIL: ") + name)
	if not ok:
		_fails.append(name)


func _fail(msg: String) -> void:
	_fails.append(msg)
	print("E2E-FAIL: " + msg)


func _finish() -> void:
	_release_walk()
	if _fails.is_empty():
		print("E2E-RESULT: ALL PASS (%d checks)" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("E2E-FAILURE: " + f)
		print("E2E-RESULT: %d FAILURE(S) of %d checks" % [_fails.size(), _checks])
		quit(1)


func _prompt_visible(area: Area3D) -> bool:
	if area == null:
		return false
	var prompt := area.get_node_or_null("Prompt") as Label3D
	return prompt != null and prompt.visible


func _current_camera() -> String:
	var cam := root.get_node_or_null("Main/Player/CamPivot/SpringArm/Camera") as Camera3D
	if cam != null and cam.current:
		return "Main/Player/CamPivot/SpringArm/Camera"
	var dcam := root.get_node_or_null("Main/Van/DrivePivot/SpringArm/DriveCamera") as Camera3D
	if dcam != null and dcam.current:
		return "Main/Van/DrivePivot/SpringArm/DriveCamera"
	return "<none>"


## True when nothing but trigger Areas blocks the spot (same rule the game's
## own save system uses).
func _spot_is_clear(p: Vector3) -> bool:
	if _player == null:
		return false
	var space := _player.get_world_3d().direct_space_state
	var sphere := SphereShape3D.new()
	sphere.radius = 0.45
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sphere
	params.collision_mask = 1
	params.exclude = [_player.get_rid(), _van.get_rid()]
	params.transform = Transform3D(Basis(), p + Vector3(0.0, 0.9, 0.0))
	var hits := space.intersect_shape(params, 8)
	for h in hits:
		var c: Object = (h as Dictionary).get("collider")
		if not (c is Area3D):
			print("E2E-DEBUG: solid blocker at %s -> %s" % [p, c])
			return false
	return true


## Walk the player toward a world-space point using only the real movement
## actions (camera-relative, exactly like a human player).
##
## NOTE on the axis convention: `player_controller` reads
## `Input.get_vector("move_left", "move_right", "move_forward", "move_backward")`
## whose Y component is `move_backward - move_forward`, so pressing W walks
## towards -Z (the camera looks down -Z). The local vector below is therefore
## mapped inverted on the forward/back axis.
func _walk_toward(target: Vector3) -> void:
	if _player == null or _pivot == null:
		return
	var to := target - _player.global_position
	to.y = 0.0
	if to.length() < 0.05:
		_release_walk()
		return
	to = to.normalized()
	var local := Basis(Vector3.UP, _pivot.global_rotation.y).inverse() * to
	_set_input("move_right", local.x > 0.2)
	_set_input("move_left", local.x < -0.2)
	_set_input("move_forward", local.z < -0.2)
	_set_input("move_backward", local.z > 0.2)


func _release_walk() -> void:
	_set_input("move_right", false)
	_set_input("move_left", false)
	_set_input("move_forward", false)
	_set_input("move_backward", false)


func _set_input(action: String, on: bool) -> void:
	if on:
		if not Input.is_action_pressed(action):
			Input.action_press(action)
	elif Input.is_action_pressed(action):
		Input.action_release(action)


func _send_key(keycode: Key) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	ev.pressed = true
	Input.parse_input_event(ev)


## File-name + size + content checksum listing of a folder, for before/after
## comparison.
func _snapshot_dir(path: String) -> String:
	var out := ""
	var d := DirAccess.open(path)
	if d == null:
		return "<missing>"
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not name.begins_with("."):
			var full := path.path_join(name)
			var f := FileAccess.open(full, FileAccess.READ)
			var size := 0
			var sum := 0
			if f != null:
				size = f.get_length()
				f.close()
				var raw := FileAccess.get_file_as_bytes(full)
				for b in raw:
					sum = (sum * 31 + b) & 0x7fffffff
			out += "%s|%d|%d|" % [name, size, sum]
		name = d.get_next()
	d.list_dir_end()
	return out
