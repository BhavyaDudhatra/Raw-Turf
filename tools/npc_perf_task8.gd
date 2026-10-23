extends SceneTree
## Task 8 NPC performance probe — rendered (NOT headless) measurement.
##
## Measures the budgets of proposal 6.2 / 6.4 with the population in the
## running game:
##
##   * the physics-time growth caused by the NPC subsystem (<= 1.0 ms),
##   * the draw-call growth (<= +60 draw calls at 12 NPCs),
##   * the static memory growth (<= +8 MB).
##
## Method: the same scene is measured twice.
##   phase "baseline" : the NPC director is held back, so no pedestrian
##                      exists at all,
##   phase "npc"      : the director runs with the full population
##                      (12 active pedestrians).
## The difference between the two phases is what the NPC subsystem costs the
## running game. `Performance.TIME_PHYSICS_PROCESS` is only meaningful in a
## rendered run (it saturates in headless), which is why this probe needs a
## display.
##
## Usage:
##   Godot --path <project> --resolution 1280x720 \
##     --script res://tools/npc_perf_task8.gd -- --seconds=6 --cap=0 [--novsync]
##
## Prints NPC-PERF-* lines and "NPC-PERF-RESULT: ALL PASS" or "... FAIL".
## Exit 0 = every budget met, 1 = a budget was exceeded, 2 = setup error.
##
## Nothing is written to disk.

## Physics-time budget for the whole NPC subsystem (proposal 6.2).
const PHYSICS_BUDGET_MS: float = 1.0
## Draw-call budget for 12 NPCs (proposal 6.2).
const DRAWCALL_BUDGET: int = 60
## Static memory budget for 12 NPCs (proposal 6.2).
const MEMORY_BUDGET_MB: float = 8.0
## Frames discarded at the start of every phase (shaders, caches).
const WARMUP_FRAMES: int = 90

var _phases: Array[String] = ["baseline", "npc"]
var _phase_idx: int = 0
var _warmup: int = 0
var _frames: int = 0
var _phase_time: float = 0.0
var _last_msec: int = 0
var _seconds: float = 6.0

var _frame_samples: Array[float] = []
var _phys_samples: Array[float] = []
var _draw_samples: Array[float] = []
var _mem_samples: Array[float] = []
var _vram_samples: Array[float] = []

var _player: CharacterBody3D
var _director: Node
var _results: Dictionary = {}
var _failures: Array[String] = []
var _population_ready: bool = false
var _population: int = -1


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var cap := 0
	var novsync := false
	var winsize := Vector2i(1280, 720)
	for a in args:
		if a.begins_with("--seconds="):
			_seconds = float(a.get_slice("=", 1))
		elif a.begins_with("--cap="):
			cap = int(a.get_slice("=", 1))
		elif a.begins_with("--winsize="):
			var parts: PackedStringArray = a.get_slice("=", 1).split("x")
			if parts.size() == 2:
				winsize = Vector2i(int(parts[0]), int(parts[1]))
		elif a == "--novsync":
			novsync = true
		elif a.begins_with("--population="):
			_population = int(a.get_slice("=", 1))
	Engine.max_fps = cap
	root.size = winsize
	# Performance.TIME_PHYSICS_PROCESS accumulates over every physics step
	# of a frame. Pinning the frame to a single physics step makes the
	# monitor a per-step number, which is what the proposal's budget is
	# stated in (one 60 Hz physics frame).
	Engine.max_physics_steps_per_frame = 1
	if novsync:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	var ps := load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		push_error("NPC-PERF: main.tscn failed to load")
		quit(2)
		return
	var m: Node = ps.instantiate()
	root.add_child.call_deferred(m)
	print("NPC-PERF: godot=%s seconds=%s cap=%d size=%s population=%s" % [
		Engine.get_version_info()["string"], _seconds, cap, root.size,
		("director default" if _population < 0 else str(_population))])
	process_frame.connect(_on_frame)
	physics_frame.connect(_on_physics_tick)


func _on_physics_tick() -> void:
	if _player == null:
		_player = root.get_node_or_null("Main/Player") as CharacterBody3D
		_director = root.get_node_or_null("Main/NpcDirector")
		if _player == null or _director == null:
			return
		# The baseline phase runs with the director held back, so the scene
		# contains no pedestrian at all.
		if _phase_idx == 0 and not _population_ready:
			_director.set_physics_process(false)
			if _population >= 0:
				_director.set("max_active", _population)


func _on_frame() -> void:
	if _player == null or _director == null:
		return
	_freeze_camera()
	if _phase_idx >= _phases.size():
		return
	if _phase_idx == 1 and not _population_ready:
		# Let the director spawn the population, then wait for it to settle.
		_director.set_physics_process(true)
		var active: int = _director.call("active_count")
		var cap: int = _director.get("max_active")
		if active >= cap:
			_population_ready = true
			print("NPC-PERF: population ready (active=%d resident=%d)" % [
				active, int(_director.call("resident_count"))])
		return
	if _warmup < WARMUP_FRAMES:
		_warmup += 1
		_last_msec = Time.get_ticks_msec()
		return
	var now := Time.get_ticks_msec()
	var dt: float = float(now - _last_msec) / 1000.0
	_last_msec = now
	_frames += 1
	_phase_time += dt
	_frame_samples.append(dt * 1000.0)
	_phys_samples.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_draw_samples.append(float(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	_mem_samples.append(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0)
	_vram_samples.append(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0)
	if _phase_time >= _seconds:
		_end_phase(_phases[_phase_idx])
		_phase_idx += 1
		_warmup = 0
		_frames = 0
		_phase_time = 0.0
		if _phase_idx >= _phases.size():
			_finish()


func _average(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


func _freeze_camera() -> void:
	# Keep the camera fixed for a reproducible A/B draw-call and physics delta.
	var cam := root.get_node_or_null("Main/Player/CamPivot/SpringArm/Camera")
	if cam != null and cam.has_method("set_current"):
		# The main camera is already current; nothing to do.
		pass
	var pivot := root.get_node_or_null("Main/Player/CamPivot")
	if pivot is Node3D:
		var p := pivot as Node3D
		# Lock to the game's default view so the draw-call count stays
		# comparable with the Phase E measurements (274 calls) and the
		# shadow frustum does not drift between the two phases.
		p.rotation = Vector3(-0.3, 0.0, 0.0)
	var arm := root.get_node_or_null("Main/Player/CamPivot/SpringArm")
	if arm is SpringArm3D:
		# The spring arm shortens when something blocks the view. A
		# pedestrian crossing in front of the player would otherwise move
		# the camera and make the draw-call A/B comparison meaningless.
		(arm as SpringArm3D).collision_mask = 0


## The median is used for the physics and draw-call numbers: a single slow
## frame (a shader compile, a spawn) must not decide the budget.
func _median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var mid := sorted.size() / 2
	if sorted.size() % 2 == 1:
		return sorted[mid]
	return (sorted[mid - 1] + sorted[mid]) * 0.5


func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var idx := int(float(sorted.size() - 1) * fraction)
	return sorted[clampi(idx, 0, sorted.size() - 1)]


func _maximum(values: Array[float]) -> float:
	var m := 0.0
	for v in values:
		if v > m:
			m = v
	return m


func _end_phase(phase: String) -> void:
	var frame_avg := _average(_frame_samples)
	var phys_avg := _average(_phys_samples)
	var phys_med := _median(_phys_samples)
	var phys_p90 := _percentile(_phys_samples, 0.9)
	var draw_avg := _average(_draw_samples)
	var draw_med := _median(_draw_samples)
	var mem_max := _maximum(_mem_samples)
	var vram_max := _maximum(_vram_samples)
	var p99: float = _percentile(_frame_samples, 0.99)
	_results[phase] = {
		"frames": _frames,
		"frame_avg_ms": frame_avg,
		"frame_p99_ms": p99,
		"phys_avg_ms": phys_avg,
		"phys_med_ms": phys_med,
		"phys_p90_ms": phys_p90,
		"draw_avg": draw_avg,
		"draw_med": draw_med,
		"mem_max_mb": mem_max,
		"vram_max_mb": vram_max,
	}
	print("NPC-PERF: phase=%s frames=%d frame_avg_ms=%.3f frame_p99_ms=%.3f phys_avg_ms=%.4f phys_med_ms=%.4f phys_p90_ms=%.4f draw_avg=%.1f draw_med=%.1f mem_max_mb=%.2f vram_max_mb=%.2f objects=%d nodes=%d" % [
		phase, _frames, frame_avg, p99, phys_avg, phys_med, phys_p90,
		draw_avg, draw_med, mem_max, vram_max,
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	_frame_samples.clear()
	_phys_samples.clear()
	_draw_samples.clear()
	_mem_samples.clear()
	_vram_samples.clear()


func _finish() -> void:
	var base: Dictionary = _results.get("baseline", {})
	var with_npcs: Dictionary = _results.get("npc", {})
	if base.is_empty() or with_npcs.is_empty():
		print("NPC-PERF-RESULT: FAIL (a phase produced no samples)")
		quit(1)
		return
	var phys_delta: float = float(with_npcs["phys_med_ms"]) - float(base["phys_med_ms"])
	var phys_delta_avg: float = float(with_npcs["phys_avg_ms"]) - float(base["phys_avg_ms"])
	var draw_delta: float = float(with_npcs["draw_med"]) - float(base["draw_med"])
	var mem_delta: float = float(with_npcs["mem_max_mb"]) - float(base["mem_max_mb"])
	var vram_delta: float = float(with_npcs["vram_max_mb"]) - float(base["vram_max_mb"])
	var active: int = int(_director.call("active_count"))
	var resident: int = int(_director.call("resident_count"))
	print("NPC-PERF: population active=%d resident=%d" % [active, resident])
	print("NPC-PERF: physics delta=%.4f ms (median, budget %.1f ms) avg delta=%.4f ms | draw delta=%.1f (budget %d) | memory delta=%.2f MB (budget %.1f MB) | vram delta=%.2f MB" % [
		phys_delta, PHYSICS_BUDGET_MS, phys_delta_avg, draw_delta, DRAWCALL_BUDGET, mem_delta, MEMORY_BUDGET_MB, vram_delta])
	if phys_delta > PHYSICS_BUDGET_MS:
		_failures.append("physics delta %.4f ms > %.1f ms" % [phys_delta, PHYSICS_BUDGET_MS])
	if draw_delta > float(DRAWCALL_BUDGET):
		_failures.append("draw call delta %.1f > %d" % [draw_delta, DRAWCALL_BUDGET])
	if mem_delta > MEMORY_BUDGET_MB:
		_failures.append("memory delta %.2f MB > %.1f MB" % [mem_delta, MEMORY_BUDGET_MB])
	if active <= 0:
		_failures.append("no pedestrian was active during the measurement")
	if _failures.is_empty():
		print("NPC-PERF-RESULT: ALL PASS")
		quit(0)
	else:
		for f in _failures:
			print("NPC-PERF-FAIL: ", f)
		print("NPC-PERF-RESULT: %d FAILURE(S)" % _failures.size())
		quit(1)
