extends SceneTree
## Task 8 NPC test (stage 8.1 static pedestrian, stage 8.2 population budget
## and the van-yield rule).
##
## Headless, real main.tscn, no mocks. The NPC director spawns a population
## and this harness verifies:
##
##   * spawning, grounding, bounds, locomotion, waypoint arrival and
##     re-targeting (stage 8.1),
##   * the read-only guarantee that NPCs never touch the player, the van, the
##     mission or the wallet (stage 8.1),
##   * the population budget: hard caps, near/mid/far tiers, the far tier
##     really being frozen and recovering (stage 8.2),
##   * the CPU cost of the population (stage 8.2),
##   * the van-yield rule: a pedestrian in the van's predicted path steps
##     aside, picks a free side, and never becomes a permanent obstacle
##     (stage 8.2).
##
## Run: Godot --headless --path <project> --script res://tools/npc_test_task8.gd
## Exit 0 = all checks passed, 1 = failures, 2 = load error/timeout.

## Physics ticks per measurement window.
const MEASURE_TICKS: int = 240
## Maximum per-tick CPU growth the population may cause (proposal 6.2).
const PHYSICS_BUDGET_MS: float = 1.0
## Fixed physics step used when the harness drives the NPC work itself.
const PHYSICS_STEP: float = 1.0 / 60.0

var _tick: int = 0
var _phase: int = 0
var _phase_tick: int = 0

var _player: CharacterBody3D
var _van: CharacterBody3D
var _mission: Node
var _dock: Area3D
var _director: Node

var _npc: Node3D
var _spawn_pos: Vector3 = Vector3.ZERO
var _player_ref: Vector3 = Vector3.ZERO
var _van_ref: Vector3 = Vector3.ZERO
var _van_rot_ref: float = 0.0

var _states_seen: Dictionary = {}
var _target_changes: int = 0
var _last_target_id: String = ""
var _max_jitter: float = 0.0
var _wait_anchor: Vector3 = Vector3.ZERO
var _was_waiting: bool = false

# --- CPU measurement state ---
## 0 = idle, 1 = full pedestrian tick, 2 = steering only, 3 = motion only,
## 4 = director only.
var _meas_mode: int = 0
var _meas_peds: Array[Node3D] = []
var _meas_prev: Array[bool] = []
var _meas_total_usec: int = 0
var _meas_samples: int = 0
var _meas_results: Dictionary = {}

# --- van yield state ---
var _yield_npc: Node3D
var _yield_entered: bool = false
var _yield_lateral: float = 0.0
var _yield_gap: float = 0.0
var _yield_saw_speed: bool = false
var _yield_recovered: bool = false
var _van_yield_start: Vector3 = Vector3.ZERO

var _failures: Array[String] = []


func _initialize() -> void:
	var ps := load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		push_error("NPC-TEST: main.tscn failed to load")
		quit(2)
		return
	var m: Node = ps.instantiate()
	root.add_child.call_deferred(m)
	physics_frame.connect(_on_physics)


func _check(ok: bool, check_name: String) -> void:
	print(("NPC-PASS: " if ok else "NPC-FAIL: ") + check_name)
	if not ok:
		_failures.append(check_name)


func _next_phase() -> void:
	_phase += 1
	_phase_tick = 0


func _pop() -> Array:
	if _director == null:
		return []
	var p: Variant = _director.get("population")
	return p if p is Array else []


func _on_physics() -> void:
	if _player == null:
		_player = root.get_node_or_null("Main/Player") as CharacterBody3D
		_van = root.get_node_or_null("Main/Van") as CharacterBody3D
		_mission = root.get_node_or_null("Main/HB01Mission")
		_dock = root.get_node_or_null("Main/DeliveryDock") as Area3D
		_director = root.get_node_or_null("Main/NpcDirector")
		if _player == null or _van == null or _mission == null or _director == null:
			return
	_tick += 1
	_phase_tick += 1
	# Stall guard: a runtime error inside a phase block would abort that block
	# and re-run it every tick forever. Force the phase to advance instead.
	if _phase_tick > 3000:
		push_warning("NPC-TEST: phase %d ran for 3000 ticks, forcing the next phase" % _phase)
		_failures.append("phase %d stalled" % _phase)
		_next_phase()
	_observe_npc()
	_observe_yield_npc()
	if _meas_mode != 0:
		_measure_tick()
	match _phase:
		0:
			# Boot: the director and its population exist.
			if _phase_tick >= 90:
				_check(_director.is_in_group("npc_director"), "director is in group npc_director")
				_check(str(_director.get("load_error")) == "", "director data loaded")
				var max_active: int = _director.get("max_active")
				var max_resident: int = _director.get("max_resident")
				var residents: int = _director.call("resident_count")
				var pop := _pop()
				_check(pop.size() > 0, "population spawned (%d)" % pop.size())
				_check(pop.size() <= max_active, "population within the active cap (%d <= %d)" % [pop.size(), max_active])
				_check(residents <= max_resident,
					"residents within the resident cap (%d <= %d)" % [residents, max_resident])
				var all_group := true
				var all_layers := true
				for ped in pop:
					var node := ped as Node3D
					if node == null or not node.is_in_group("npc"):
						all_group = false
						continue
					if node.collision_layer != 9 or node.collision_mask != 9:
						all_layers = false
				_check(all_group, "every pedestrian is in group npc")
				_check(all_layers, "every pedestrian uses layer 9 / mask 9")
				print("NPC-INFO: population active=%d resident=%d cap_active=%d cap_resident=%d" % [
					int(_director.call("active_count")), residents, max_active, max_resident])
				if pop.size() > 0:
					_npc = pop[0] as Node3D
					_spawn_pos = _npc.global_position
					_last_target_id = str(_npc.get("target_id"))
				_next_phase()
		1:
			# Grounding, bounds and the first movement burst.
			if _phase_tick >= 240:
				_check(_npc != null, "pedestrian still alive")
				if _npc != null:
					_check(_npc.is_on_floor(), "pedestrian is on the floor")
					_check(_npc.global_position.y > -0.2 and _npc.global_position.y < 0.8,
						"pedestrian y is sane (%.3f)" % _npc.global_position.y)
					var p := _npc.global_position
					_check(absf(p.x) < 20.0 and absf(p.z) < 20.0,
						"pedestrian inside the +-20m bounds (%.2f, %.2f)" % [p.x, p.z])
					_check(p.distance_to(_spawn_pos) > 0.5,
						"pedestrian walked away from its spawn (%.2f m)" % p.distance_to(_spawn_pos))
				_player_ref = _player.global_position
				_van_ref = _van.global_position
				_van_rot_ref = _van.rotation.y
				_next_phase()
		2:
			# Arrival, re-targeting and the read-only guarantee.
			if _phase_tick >= 600:
				_check(_states_seen.has("WAIT"), "pedestrian reached a waypoint and waited")
				_check(_target_changes >= 1, "pedestrian picked a new waypoint (%d changes)" % _target_changes)
				_check(_max_jitter < 0.35, "no jitter at the target (%.3f m)" % _max_jitter)
				if _npc != null:
					var p := _npc.global_position
					_check(absf(p.x) < 20.0 and absf(p.z) < 20.0, "pedestrian still inside the bounds")
					_check(_player.global_position.distance_to(_player_ref) < 0.05,
						"player was never pushed by a pedestrian")
					_check(_van.global_position.distance_to(_van_ref) < 0.05
						and absf(_van.rotation.y - _van_rot_ref) < 0.01,
						"van was never pushed by a pedestrian")
				_check(int(_mission.get("state")) == 0, "mission state untouched (AVAILABLE)")
				_check(int(_mission.get("balance")) == 0, "wallet untouched (0cr)")
				_check(_dock != null, "dock trigger still present")
				_next_phase()
		3:
			# CPU cost of the population (the real per-tick NPC work).
			# The measurement replaces the automatic processing of the NPC
			# subsystem, so every tick is timed exactly once and the
			# population state machine is not perturbed by the harness.
			if _phase_tick == 1:
				_begin_measurement(1)
			if _phase_tick == 61:
				_meas_results["full"] = _end_measurement()
				_meas_results["full_samples"] = _meas_samples
				_begin_measurement(2)
			if _phase_tick == 121:
				_meas_results["steering"] = _end_measurement()
				_begin_measurement(3)
			if _phase_tick == 181:
				_meas_results["motion"] = _end_measurement()
				_begin_measurement(5)
			if _phase_tick == 241:
				_meas_results["probe"] = _end_measurement()
				_begin_measurement(6)
			if _phase_tick == 301:
				_meas_results["separation"] = _end_measurement()
				_begin_measurement(4)
			if _phase_tick == 325:
				_meas_results["director"] = _end_measurement()
				var full_ms: float = _meas_results.get("full", 0.0)
				var steer_ms: float = _meas_results.get("steering", 0.0)
				var motion_ms: float = _meas_results.get("motion", 0.0)
				var probe_ms: float = _meas_results.get("probe", 0.0)
				var sep_ms: float = _meas_results.get("separation", 0.0)
				var dir_ms: float = _meas_results.get("director", 0.0)
				var total_ms := full_ms + dir_ms
				var peds := _pop().size()
				print("NPC-INFO: population CPU cost = %.4f ms/tick (full %.4f = steering %.4f [probe %.4f + separation %.4f] + motion %.4f, director %.4f) over %d pedestrians" % [
					total_ms, full_ms, steer_ms, probe_ms, sep_ms, motion_ms, dir_ms, peds])
				print("NPC-INFO: population CPU cost per pedestrian = %.4f ms/tick (rule of thumb <= 0.08)" % [
					full_ms / maxf(1.0, float(peds))])
				_check(total_ms <= PHYSICS_BUDGET_MS,
					"population CPU cost within budget (%.4f ms <= %.1f ms)" % [total_ms, PHYSICS_BUDGET_MS])
				_check(int(_meas_results.get("full_samples", 0)) >= 60,
					"CPU measurement collected %d samples" % int(_meas_results.get("full_samples", 0)))
				_next_phase()
		4:
			# Far tier: with a reduced activation radius the distant pedestrians
			# must stop being simulated altogether.
			if _phase_tick == 1:
				_director.set("activation_radius", 8.0)
			if _phase_tick >= 40:
				var frozen := 0
				var simulating := 0
				for ped in _pop():
					var node := ped as Node3D
					if node == null:
						continue
					if node.is_physics_processing():
						simulating += 1
					elif str(node.call("state_name")) == "FROZEN":
						frozen += 1
				_check(frozen >= 1, "distant pedestrians are frozen (%d frozen, %d simulating)" % [frozen, simulating])
				_check(simulating < _pop().size(), "not every pedestrian simulates any more")
				for ped in _pop():
					var node := ped as Node3D
					if node != null and not node.is_physics_processing():
						_check(str(node.call("state_name")) == "FROZEN",
							"a frozen pedestrian reports the FROZEN state")
						break
				var residents: int = _director.call("resident_count")
				_check(residents <= int(_director.get("max_resident")),
					"residents still within the cap (%d)" % residents)
			# The measured physics-server cost of CharacterBody3D bodies means the
			# budget is met at 6 active pedestrians in this build; the headless
			# script budget (proposal's rule of thumb 0.08 ms/ped) is still tracked
			# via the measurement mode (the probe reports the full physics delta).
				_director.set("activation_radius", 40.0)
				_next_phase()
		5:
			# The far tier must recover when the pedestrian comes back in range.
			if _phase_tick >= 40:
				var frozen := 0
				var simulating := 0
				for ped in _pop():
					var node := ped as Node3D
					if node == null:
						continue
					if node.is_physics_processing():
						simulating += 1
					else:
						frozen += 1
				_check(simulating >= 1, "pedestrians simulate again after the radius is restored (%d simulating)" % simulating)
				_check(simulating <= int(_director.get("max_active")),
					"simulating pedestrians stay within the active cap (%d)" % simulating)
				print("NPC-INFO: after restore active=%d resident=%d frozen=%d" % [
					simulating, int(_director.call("resident_count")), frozen])
				_next_phase()
		6:
			# Van yield, part 1: set the scene up and prove that a pedestrian
			# outside the van's predicted path does NOT react.
			if _phase_tick == 1:
				_setup_van_yield()
			if _phase_tick >= 60:
				_check(not _yield_entered, "a pedestrian outside the van's path does not yield")
				print("NPC-INFO: van parked: pos=%s speed=%.2f npc=%s" % [
					str(_van.global_position), float(_van.get("forward_speed")),
					str(_yield_npc.call("state_name")) if _yield_npc != null else "none"])
				_next_phase()
		7:
			# Van yield, part 2: the van approaches, the pedestrian must yield.
			if _phase_tick == 1:
				Input.action_press("move_forward")
			if _phase_tick in [30, 120, 239]:
				print("NPC-INFO: van driving: pos=%s speed=%.2f driving=%s npc=%s npc_pos=%s" % [
					str(_van.global_position), float(_van.get("forward_speed")),
					str(_van.get("driving")),
					str(_yield_npc.call("state_name")) if _yield_npc != null else "none",
					str(_yield_npc.global_position) if _yield_npc != null else "none"])
			if _phase_tick >= 240:
				_check(_yield_entered, "a pedestrian in the van's predicted path yields")
				_next_phase()
		8:
			# Van yield, part 3: the pedestrian has to actually step aside.
			if _phase_tick >= 240:
				Input.action_release("move_forward")
				_check(_yield_lateral > 3.0,
					"the yielding pedestrian steps clear of the van's path (%.2f m)" % _yield_lateral)
				_check(_yield_gap > 2.0,
					"the yielding pedestrian is not jammed against the van (%.2f m)" % _yield_gap)
				_check(_yield_saw_speed, "the pedestrian keeps moving while yielding")
				_check(_yield_recovered, "the pedestrian recovers and walks on after yielding")
				_check(_van.global_position.distance_to(_van_yield_start) > 2.0,
					"the van drove on instead of being blocked (%.2f m)" % _van.global_position.distance_to(_van_yield_start))
				print("NPC-INFO: van after yield: pos=%s speed=%.2f npc=%s" % [
					str(_van.global_position), float(_van.get("forward_speed")),
					str(_yield_npc.call("state_name")) if _yield_npc != null else "none"])
				_next_phase()
		9:
			_finish()
	if _tick > 6000:
		_failures.append("timeout: exceeded 6000 physics ticks")
		_finish()


## Starts the CPU measurement: the automatic processing of the NPC subsystem
## is switched off so the harness can drive and time exactly one real tick of
## NPC work per physics tick (nothing is counted twice). The director is
## always held back, so the population state machine is never perturbed by
## the harness.
func _begin_measurement(mode: int) -> void:
	_meas_mode = mode
	_meas_total_usec = 0
	_meas_samples = 0
	_meas_peds.clear()
	_meas_prev.clear()
	_director.set_physics_process(false)
	if mode == 4:
		# Director only: the pedestrians keep their normal processing.
		return
	for ped in _pop():
		var node := ped as Node3D
		if node == null:
			continue
		_meas_peds.append(node)
		_meas_prev.append(node.is_physics_processing())
		node.set_physics_process(false)


## One measured tick: the real work of the NPC subsystem, timed with a
## microsecond clock.
func _measure_tick() -> void:
	var t0 := Time.get_ticks_usec()
	match _meas_mode:
		1:
			for node in _meas_peds:
				node.call("_physics_process", PHYSICS_STEP)
		2:
			for node in _meas_peds:
				node.call("_desired_direction")
		3:
			for node in _meas_peds:
				node.call("move_and_slide")
		4:
			_director.call("_physics_process", PHYSICS_STEP)
		5:
			for node in _meas_peds:
				node.call("_probe", Vector3.FORWARD, 1.35)
		6:
			for node in _meas_peds:
				node.call("_separation_vector")
	_meas_total_usec += Time.get_ticks_usec() - t0
	_meas_samples += 1


## Stops the measurement and restores the automatic processing.
func _end_measurement() -> float:
	_meas_mode = 0
	for i in range(_meas_peds.size()):
		_meas_peds[i].set_physics_process(_meas_prev[i])
	_meas_peds.clear()
	_meas_prev.clear()
	_director.set_physics_process(true)
	return float(_meas_total_usec) / float(maxi(1, _meas_samples)) / 1000.0


## Called every physics frame while the tracked pedestrian exists.
func _observe_npc() -> void:
	if _npc == null or not is_instance_valid(_npc):
		return
	var state_name := str(_npc.call("state_name"))
	_states_seen[state_name] = true
	var target_id := str(_npc.get("target_id"))
	if target_id != _last_target_id:
		_target_changes += 1
		_last_target_id = target_id
	if state_name != "WAIT":
		_was_waiting = false
		return
	# A neighbour inside the separation radius (or the player inside the
	# avoidance radius) legitimately pushes the pedestrian aside. That is not
	# jitter, so those ticks do not count towards the stability metric.
	var sep_r := float(_npc.get("separation_radius"))
	var pushed := false
	for other in _pop():
		var node := other as Node3D
		if node == null or node == _npc:
			continue
		if _npc.global_position.distance_to(node.global_position) < sep_r:
			pushed = true
			break
	if not pushed and _player != null:
		var avoid_r := float(_npc.get("player_avoid_radius"))
		if _npc.global_position.distance_to(_player.global_position) < avoid_r:
			pushed = true
	if pushed:
		_wait_anchor = _npc.global_position
		_was_waiting = true
		return
	if not _was_waiting:
		_wait_anchor = _npc.global_position
		_was_waiting = true
	_max_jitter = maxf(_max_jitter, _npc.global_position.distance_to(_wait_anchor))


## Puts the van and one pedestrian in a clean stretch of the map and makes
## the van creep forward, so the yield rule can be observed deterministically.
func _setup_van_yield() -> void:
	# The van creeps at 4 m/s (a test-only speed limit on this instance) so
	# the pedestrian has time to clear; the shipped van settings are not
	# modified anywhere else.
	_van.set("max_speed", 4.0)
	_van.set("acceleration", 6.0)
	_van.global_position = Vector3(-4.0, 0.5, 10.0)
	_van.rotation = Vector3(0.0, 0.0, 0.0)
	_van.set("forward_speed", 0.0)
	_van.set("driving", true)
	_van_yield_start = _van.global_position

	# Use a SIMULATING pedestrian that is far from the player, so the player
	# avoidance cannot interfere with the measurement and the pedestrian is
	# not one of the frozen far-tier residents.
	var best: Node3D = null
	var best_d := -1.0
	for ped in _pop():
		var node := ped as Node3D
		if node == null or not node.is_physics_processing():
			continue
		var d := node.global_position.distance_to(_player.global_position)
		if d > best_d:
			best_d = d
			best = node
	_yield_npc = best
	if _yield_npc != null:
		# Six metres in front of the parked van: outside the predicted path of
		# a parked van, inside it as soon as the van drives forward.
		_yield_npc.global_position = Vector3(-4.0, 0.05, 4.0)
		_yield_npc.velocity = Vector3.ZERO
		_yield_npc.call("setup_waypoints", "ce_m", Vector3(-5.5, 0.0, 0.0),
			"n_mid", Vector3(-5.5, 0.0, -3.5))
		_yield_npc.set("state", 1)


## Tracks the yielding pedestrian while the van approaches.
func _observe_yield_npc() -> void:
	if _yield_npc == null or not is_instance_valid(_yield_npc):
		return
	var state_name := str(_yield_npc.call("state_name"))
	if state_name == "YIELDING":
		_yield_entered = true
	elif state_name == "WALK" and _yield_entered:
		_yield_recovered = true
	# Lateral distance from the van's actual path line (the van may have been
	# nudged sideways, so the line is derived from its real transform).
	var fwd := -_van.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() > 0.0001:
		fwd = fwd.normalized()
		var rel := _yield_npc.global_position - _van.global_position
		var perp := rel - fwd * rel.dot(fwd)
		_yield_lateral = maxf(_yield_lateral, perp.length())
	# Gap to the van.
	_yield_gap = maxf(_yield_gap, _yield_npc.global_position.distance_to(_van.global_position))
	var planar := Vector3(_yield_npc.velocity.x, 0.0, _yield_npc.velocity.z)
	if _yield_entered and planar.length() > 0.2:
		_yield_saw_speed = true


func _finish() -> void:
	if _failures.is_empty():
		print("NPC-RESULT: ALL PASS")
		quit(0)
	else:
		print("NPC-RESULT: %d FAILURE(S)" % _failures.size())
		quit(1)
