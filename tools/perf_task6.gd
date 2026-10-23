extends SceneTree
## Task 6 performance harness — rendered (NOT headless) measurement.
## Usage:
##   Godot --path <project> --resolution <WxH> --script res://tools/perf_task6.gd -- \
##     --profile=all|baseline|vehicle|mission|saveload --seconds=10 --cap=0|30|60 \
##     [--novsync] [--low] [--savedir=<abs dir>]
## --cap sets Engine.max_fps (0 = uncapped). --novsync disables compositor sync.
## --low disables sun shadows for the run only (in-memory, never saved).
## --savedir redirects the save folder to an isolated directory so the real
##   userdata/saves folder is never written to. Optional; behaviour without
##   it is unchanged.
## Prints PERF-* lines: avg FPS, p99 frame ms, 1% low FPS, monitors, save/load ms.
## Nothing is written to disk except an optional perf_tmp save slot, removed after.
## Exit 0 = completed, 2 = error.

var _frames: int = 0
var _phase_frames: int = 0
var _phase_time: float = 0.0
var _warmup: int = 0
var _samples: Array[float] = []
var _phase_idx: int = 0
var _phases: Array = []
var _seconds: float = 10.0
var _player: CharacterBody3D
var _van: CharacterBody3D
var _sys: Node
var _mission: Node
var _saver: Node
var _sun: DirectionalLight3D
var _last_msec: int = 0
var _savedir: String = ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var profile := "all"
	var cap := 0
	var novsync := false
	var low := false
	var winsize := Vector2i(1280, 720)
	for a in args:
		if a.begins_with("--profile="):
			profile = a.get_slice("=", 1)
		elif a.begins_with("--seconds="):
			_seconds = float(a.get_slice("=", 1))
		elif a.begins_with("--cap="):
			cap = int(a.get_slice("=", 1))
		elif a.begins_with("--winsize="):
			var parts := a.get_slice("=", 1).split("x")
			if parts.size() == 2:
				winsize = Vector2i(int(parts[0]), int(parts[1]))
		elif a == "--novsync":
			novsync = true
		elif a == "--low":
			low = true
		elif a.begins_with("--savedir="):
			_savedir = a.get_slice("=", 1)
	Engine.max_fps = cap
	root.size = winsize
	if novsync:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var ps := load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		push_error("PERF: main.tscn failed to load")
		quit(2)
		return
	var m: Node = ps.instantiate()
	root.add_child.call_deferred(m)
	if profile == "all":
		_phases = ["baseline", "vehicle", "mission", "saveload"]
	else:
		_phases = [profile]
	print("PERF: godot=%s profile=%s seconds=%s cap=%d novsync=%s low=%s size=%s" % [
		Engine.get_version_info()["string"], profile, _seconds, cap, novsync, low,
		root.size])
	print("PERF: gpu adapter='%s' api='%s' driver='%s' video_mem_mb=%.0f" % [
		RenderingServer.get_video_adapter_name(),
		RenderingServer.get_video_adapter_api_version(),
		RenderingServer.get_current_rendering_driver_name(),
		float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0])
	process_frame.connect(_on_frame)
	physics_frame.connect(_on_physics_tick)


func _on_physics_tick() -> void:
	if _player == null:
		_player = root.get_node_or_null("Main/Player") as CharacterBody3D
		_van = root.get_node_or_null("Main/Van") as CharacterBody3D
		_sys = root.get_node_or_null("Main/VehicleSystem")
		_mission = root.get_node_or_null("Main/HB01Mission")
		_saver = root.get_node_or_null("Main/SaveSystem")
		_sun = root.get_node_or_null("Main/Sun") as DirectionalLight3D
		if _player == null:
			return
		if _sun != null and _low_flag():
			_sun.shadow_enabled = false
		if _savedir != "" and _saver != null:
			DirAccess.make_dir_recursive_absolute(_savedir)
			_saver.set("save_dir_override", _savedir)
			print("PERF: save folder isolated at %s" % _savedir)


func _low_flag() -> bool:
	for a in OS.get_cmdline_user_args():
		if a == "--low":
			return true
	return false


func _current_phase() -> String:
	return String(_phases[_phase_idx])


func _on_frame() -> void:
	if _player == null or _phase_idx >= _phases.size():
		return
	if _warmup < 60:
		_warmup += 1
		_last_msec = Time.get_ticks_msec()
		if _warmup == 60:
			_begin_phase(_current_phase())
		return
	var now := Time.get_ticks_msec()
	var dt: float = float(now - _last_msec) / 1000.0
	_last_msec = now
	_phase_frames += 1
	_phase_time += dt
	_samples.append(dt * 1000.0)
	if _phase_time >= _seconds:
		_end_phase(_current_phase())
		_phase_idx += 1
		_phase_frames = 0
		_phase_time = 0.0
		_samples.clear()
		_warmup = 0
		if _phase_idx >= _phases.size():
			print("PERF-RESULT: DONE")
			quit(0)


func _begin_phase(phase: String) -> void:
	match phase:
		"vehicle":
			_place(Vector3(11.5, 0.5, 1.0))
			_sys.call("request_enter")
			Input.action_press("move_forward")
		"mission":
			_mission.call("accept_mission")
			_van.global_position = Vector3(10, 0.5, -2)
			Input.action_press("move_forward")
		"saveload":
			pass
	print("PERF: begin ", phase)


func _end_phase(phase: String) -> void:
	if phase == "vehicle" or phase == "mission":
		Input.action_release("move_forward")
	if phase == "saveload":
		_run_saveload()
		return
	var n := _samples.size()
	if n == 0:
		print("PERF: ", phase, " no samples")
		return
	var sorted := _samples.duplicate()
	sorted.sort()
	var sum := 0.0
	for s in sorted:
		sum += s
	var avg_ms := sum / n
	var p99_ms: float = sorted[mini(n - 1, int(n * 0.99))]
	var max_ms: float = sorted[n - 1]
	var avg_fps := 1000.0 / avg_ms if avg_ms > 0.0 else 0.0
	var low1_fps := 1000.0 / p99_ms if p99_ms > 0.0 else 0.0
	var mem_mb := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var vram_mb := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	print("PERF: phase=%s frames=%d avg_fps=%.1f avg_ms=%.2f p99_ms=%.2f low1_fps=%.1f max_ms=%.2f mem_mb=%.1f objects=%d nodes=%d drawcalls=%d phys_ms=%.2f process_ms=%.2f vram_mb=%.1f" % [
		phase, n, avg_fps, avg_ms, p99_ms, low1_fps, max_ms, mem_mb,
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		phys_ms, proc_ms, vram_mb])


func _run_saveload() -> void:
	var t0 := Time.get_ticks_msec()
	var ok_save := bool(_saver.call("save_game", "perf_tmp"))
	var t1 := Time.get_ticks_msec()
	_van.global_position = Vector3(-10, 0.5, 10)
	var ok_load := bool(_saver.call("load_game", "perf_tmp"))
	var t2 := Time.get_ticks_msec()
	var base: String = String(_saver.call("get_save_path", "perf_tmp"))
	for e in ["", ".tmp", ".bak"]:
		if FileAccess.file_exists(base + e):
			DirAccess.remove_absolute(base + e)
	print("PERF: phase=saveload save_ok=%s save_ms=%d load_ok=%s load_ms=%d last_error='%s'" % [
		ok_save, t1 - t0, ok_load, t2 - t1, String(_saver.get("last_error"))])


func _place(p: Vector3) -> void:
	_player.global_position = p
	_player.velocity = Vector3.ZERO
