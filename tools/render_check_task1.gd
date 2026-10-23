extends SceneTree
## Task 1 render check — runs the real main.tscn WITH rendering, captures one
## viewport screenshot after 90 frames, and asserts the image is not blank:
## sky-blue pixels in the top third, ground-tone pixels in the bottom half,
## and the Stage 1 MakeHuman character near the spawn silhouette (bright warm
## skin-tone fraction + silhouette edge density in a tight spawn window;
## replaced the retired blue-capsule gate in Task 7B.6 Stage 1).
## Informational, lenient by design.
## Run (needs a display/GPU, NOT headless):
##   Godot --path <project> --resolution 1280x720 --script res://tools/render_check_task1.gd
## Screenshot: .godot/render_check.png (git-ignored, stays on B:).
## Exit 0 = pass, 1 = fail, 2 = error.
##
## DETERMINISM (Phase C, 2026-10-22) — the camera is pinned by this HARNESS
## only; production mouse-look behaviour is untouched.
## Root cause of the intermittent failure: `player_controller._ready()` calls
## `Input.mouse_mode = MOUSE_MODE_CAPTURED`. Capturing the mouse warps the OS
## cursor to the window centre and emits a mouse-motion event whose `relative`
## equals the distance the cursor travelled. `player_controller._input()` then
## rotates `CamPivot` by that delta, so the framing depended on where the
## physical cursor happened to be. With a rotated camera the character left the
## fixed sample window and `char_warm` collapsed (0.015 vs the 0.06 floor).
## The fix keeps the GAME as-is and neutralises the input path in the test:
##   1. The harness drops mouse capture for the duration of the test, so
##      `player_controller._input()` cannot apply any mouse-look delta.
##   2. The harness re-pins `CamPivot.rotation` to the controller's own
##      declared default pitch (`player._pitch`) and yaw 0 every frame, so even
##      a warp event that landed before the override is corrected.
##   3. The pre-test mouse mode is restored when the capture finishes.
## Thresholds and sample windows are UNCHANGED — only the camera is made
## deterministic. Residual variance is the idle-animation phase (a few
## percent); see the Phase C report for measured numbers.

var _frames: int = 0
var _done: bool = false

## Test-only state (restored after the capture).
var _saved_mouse_mode: int = -1
var _pivot: Node3D = null
var _player: CharacterBody3D = null
var _pinned_pitch: float = -0.3
var _pin_count: int = 0
var _drift_events: int = 0


func _initialize() -> void:
	_saved_mouse_mode = Input.mouse_mode
	var ps := load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		push_error("RENDER: main.tscn failed to load")
		quit(2)
		return
	var m: Node = ps.instantiate()
	root.add_child.call_deferred(m)
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	if _done:
		return
	_frames += 1
	if _frames == 1:
		_setup_pin()
	if _frames < 90:
		_pin_camera()
		return
	# The capture must show the player STATIONARY AT THE SPAWN PAD (the
	# documented intent of this check). The player spawns 1 m up and needs
	# ~27 physics ticks to land, but this harness counts PROCESS frames:
	# on a fast machine 90 process frames can be well under 27 physics
	# ticks, so the player was still airborne when the frame was grabbed.
	# The camera rides the player, so an airborne capture raises the whole
	# view (more sky, less ground) and lifts the character out of the fixed
	# sample window -> char_warm collapsed to 0.015 (the intermittent
	# failure). Waiting for the settle makes the capture state-independent
	# of machine speed. Process frames are still a hard minimum so the
	# scene is fully warmed (materials compiled, character animated).
	if not _player_settled():
		_pin_camera()
		if _frames < 900:
			return
		print("RENDER: WARN capture forced before the player settled")
	_done = true
	_evaluate()


func _player_settled() -> bool:
	if _player == null:
		return true
	return _player.is_on_floor() and absf(_player.global_position.y) < 0.05


## Resolve the camera pivot and neutralise mouse capture for the test.
func _setup_pin() -> void:
	_player = root.get_node_or_null("Main/Player") as CharacterBody3D
	_pivot = root.get_node_or_null("Main/Player/CamPivot") as Node3D
	if _player != null:
		# The controller's declared default pitch is the authoritative
		# "un-drifted" framing; fall back to the documented -0.3 default.
		var p: Variant = _player.get("_pitch")
		if p is float or p is int:
			_pinned_pitch = float(p)
	# Release mouse capture so `player_controller._input()` stops applying
	# mouse-look deltas (it only rotates while MOUSE_MODE_CAPTURED).
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Re-pin the pivot every frame: a mouse-warp event can arrive between
## frames, so the rotation is corrected before the next render.
func _pin_camera() -> void:
	if _pivot == null:
		return
	_pin_count += 1
	var target := Vector3(_pinned_pitch, 0.0, 0.0)
	if not _pivot.rotation.is_equal_approx(target):
		_drift_events += 1
	_pivot.rotation = target


func _evaluate() -> void:
	var failures: Array[String] = []
	var tex: Texture2D = root.get_texture()
	if tex == null:
		push_error("RENDER: no viewport texture")
		_restore()
		quit(2)
		return
	var img := (tex as ViewportTexture).get_image()
	var w := img.get_width()
	var h := img.get_height()
	print("RENDER: captured %dx%d" % [w, h])
	# Determinism evidence: the pinned framing was in force for the capture.
	if _pivot != null:
		print("RENDER: camera pinned pitch=%.4f yaw=%.4f (pins=%d, drift_corrections=%d)" % [
			_pivot.rotation.x, _pivot.rotation.y, _pin_count, _drift_events])
		if not is_equal_approx(_pivot.rotation.y, 0.0) \
				or not is_equal_approx(_pivot.rotation.x, _pinned_pitch):
			failures.append("camera not pinned at capture time")
	if _player != null:
		print("RENDER: player settled=%s y=%.4f (process_frames=%d physics_frames=%d)" % [
			str(_player.is_on_floor()), _player.global_position.y, _frames,
			Engine.get_physics_frames()])
	var save_path := ProjectSettings.globalize_path("res://") + ".godot/render_check.png"
	if img.save_png(save_path) != OK:
		failures.append("could not save screenshot")
	else:
		print("RENDER: saved " + save_path)
	var sky := 0
	var sky_total := 0
	var ground := 0
	var ground_total := 0
	var lum_sum := 0.0
	var samples := 0
	var buckets := {}
	for y in range(0, h, 8):
		for x in range(0, w, 8):
			var c := img.get_pixel(x, y)
			samples += 1
			lum_sum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			var key := "%d,%d,%d" % [int(c.r * 16.0), int(c.g * 16.0), int(c.b * 16.0)]
			buckets[key] = true
			if y < h / 3:
				sky_total += 1
				if c.b > 0.45 and c.b > c.r:
					sky += 1
			if y > h / 2:
				ground_total += 1
				# Sky ambient tints the ground blue-grey, so match by low
				# saturation + mid luminance instead of raw albedo.
				var cmax := maxf(c.r, maxf(c.g, c.b))
				var cmin := minf(c.r, minf(c.g, c.b))
				var sat := 0.0
				if cmax > 0.001:
					sat = (cmax - cmin) / cmax
				var lum := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
				if sat < 0.45 and lum > 0.25 and lum < 0.92:
					ground += 1
	# Stage 1 player-presence check (replaces the retired blue-capsule gate):
	# the MakeHuman visual is bright warm skin (r high, g mid, r>=b) inside a
	# tight spawn-silhouette window, with silhouette edge density above a floor.
	# Calibrated on scratch_7b_6 pre/post/neg captures (character present:
	# warm=0.162 edge=0.182; player hidden: warm=0.020 edge=0.096). A missing or
	# fully invisible player yields background pixels -> both sub-metrics
	# collapse -> fail. A flat background-colored panel cannot pass the edge
	# floor. Window is resolution-relative; the render check captures the player
	# stationary at the spawn pad.
	var char_warm := 0
	var char_total := 0
	var pcx := w / 2
	var pcy := int(h * 0.583)
	var phw := int(w * 0.078)
	var phh := int(h * 0.139)
	for y in range(pcy - phh, pcy + phh, 4):
		for x in range(pcx - phw, pcx + phw, 4):
			if x < 0 or y < 0 or x >= w or y >= h:
				continue
			char_total += 1
			var cc := img.get_pixel(x, y)
			if cc.r > 0.55 and cc.g > 0.48 and cc.r >= cc.b:
				char_warm += 1
	var char_edge := 0
	var char_edge_total := 0
	for y in range(pcy - phh + 10, pcy + phh - 10, 4):
		for x in range(pcx - phw + 10, pcx + phw - 10, 4):
			if x < 0 or y < 0 or x + 4 >= w or y + 4 >= h:
				continue
			var c0 := img.get_pixel(x, y)
			var cx := img.get_pixel(x + 4, y)
			var cy := img.get_pixel(x, y + 4)
			var l0 := 0.2126 * c0.r + 0.7152 * c0.g + 0.0722 * c0.b
			var lx := 0.2126 * cx.r + 0.7152 * cx.g + 0.0722 * cx.b
			var ly := 0.2126 * cy.r + 0.7152 * cy.g + 0.0722 * cy.b
			char_edge_total += 1
			if abs(lx - l0) + abs(ly - l0) > 0.12:
				char_edge += 1
	var sky_ratio := float(sky) / float(maxi(sky_total, 1))
	var ground_ratio := float(ground) / float(maxi(ground_total, 1))
	var char_warm_ratio := float(char_warm) / float(maxi(char_total, 1))
	var char_edge_ratio := float(char_edge) / float(maxi(char_edge_total, 1))
	var avg_lum := lum_sum / float(maxi(samples, 1))
	print("RENDER: sky=%.2f ground=%.2f char_warm=%.3f char_edge=%.3f distinct=%d avg_lum=%.3f" % [
		sky_ratio, ground_ratio, char_warm_ratio, char_edge_ratio, buckets.size(), avg_lum])
	_check(sky_ratio > 0.15, "sky visible in top third", failures)
	_check(ground_ratio > 0.15, "ground visible in bottom half", failures)
	_check(char_warm_ratio > 0.06, "character skin-tone presence near spawn", failures)
	_check(char_edge_ratio > 0.13, "character silhouette edges near spawn", failures)
	_check(avg_lum > 0.05, "image is not black", failures)
	_check(buckets.size() > 50, "image has variety (not blank)", failures)
	_restore()
	if failures.is_empty():
		print("RENDER-RESULT: ALL PASS")
		quit(0)
	else:
		print("RENDER-RESULT: %d FAILURE(S)" % failures.size())
		quit(1)


## Restore every piece of state this harness modified, so no test-only
## behaviour leaks out of the run.
func _restore() -> void:
	if _saved_mouse_mode >= 0:
		Input.mouse_mode = _saved_mouse_mode
		_saved_mouse_mode = -1


func _check(ok: bool, check_name: String, failures: Array[String]) -> void:
	print(("RENDER-PASS: " if ok else "RENDER-FAIL: ") + check_name)
	if not ok:
		failures.append(check_name)
