extends SceneTree
## Phase C root-cause probe — reproduces the render-gate nondeterminism on
## demand and proves the harness fix neutralises it.
##
## A mouse-capture "warp" (the OS cursor jumping to the window centre when
## `Input.mouse_mode = MOUSE_MODE_CAPTURED` is set) delivers an
## InputEventMouseMotion whose `relative` equals the distance the cursor
## travelled. `player_controller._input()` applies that delta to CamPivot,
## so the framing depends on where the physical cursor happened to be.
## This probe injects that event synthetically so the failure can be
## reproduced deterministically instead of waiting for it.
##
##   MODE A (reproduce): production behaviour — capture ON, no pinning.
##   MODE B (fixed):     harness behaviour — capture OFF + camera pinning.
##
## Run: Godot --path <project> --resolution 1280x720 --script res://tools/render_drift_probe.gd
## Exit 0 = the probe confirmed the expected difference, 1 = inconclusive.

const WARP_PIXELS := Vector2(0.0, 260.0)  # typical warp magnitude (vertical)
const WINDOW_CX_FRAC := 0.5
const WINDOW_CY_FRAC := 0.583
const WINDOW_HW_FRAC := 0.078
const WINDOW_HH_FRAC := 0.139

var _mode := "A"
var _warp := Vector2(0.0, 260.0)
var _frames := 0
var _warp_sent := false
var _settled := false
var _player: CharacterBody3D
var _pivot: Node3D
var _saved_mouse_mode := -1


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "fixed":
			_mode = "B"
		elif arg == "early":
			_mode = "early"
		elif arg.begins_with("warp="):
			var v := float(arg.substr(5))
			_warp = Vector2(0.0, v)
	_saved_mouse_mode = Input.mouse_mode
	var ps := load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		push_error("PROBE: main.tscn failed to load")
		quit(2)
		return
	root.add_child.call_deferred(ps.instantiate())
	process_frame.connect(_on_frame)

func _on_frame() -> void:
	if _frames == 1:
		_player = root.get_node_or_null("Main/Player") as CharacterBody3D
		_pivot = root.get_node_or_null("Main/Player/CamPivot") as Node3D
		if _mode == "B":
			# Harness behaviour: drop capture, then re-pin every frame.
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_frames += 1
	# "early" mode: capture while the player is still AIRBORNE (the spawn
	# drop is 1 m, so the very first frames have the player in the air).
	if _mode == "early":
		if _frames < 8:
			if _mode == "B" and _pivot != null:
				_pivot.rotation = Vector3(-0.3, 0.0, 0.0)
			return
		_measure()
		return
	if not _settled and _player != null and _player.is_on_floor() \
			and absf(_player.global_position.y) < 0.05:
		_settled = true
		print("PROBE: settled after %d frames" % _frames)
	if not _warp_sent and _settled:
		_warp_sent = true
		_inject_warp()
		# Give the event time to be delivered and applied.
	elif _warp_sent and _frames > _warp_frame + 10:
		_measure()
		return
	if _frames > 600:
		push_error("PROBE: timed out")
		quit(2)
		return
	if _mode == "B" and _pivot != null:
		# Harness behaviour: re-pin to the documented default framing.
		_pivot.rotation = Vector3(-0.3, 0.0, 0.0)


var _warp_frame := 0


func _inject_warp() -> void:
	_warp_frame = _frames
	var ev := InputEventMouseMotion.new()
	ev.relative = _warp
	ev.position = Vector2(640, 360)
	ev.global_position = Vector2(640, 360)
	print("PROBE: injecting warp event relative=%s (mode %s)" % [str(_warp), _mode])
	Input.parse_input_event(ev)


func _measure() -> void:
	var tex := root.get_texture()
	if tex == null:
		push_error("PROBE: no viewport texture")
		quit(2)
		return
	var img := (tex as ViewportTexture).get_image()
	var w := img.get_width()
	var h := img.get_height()
	var cx := int(w * WINDOW_CX_FRAC)
	var cy := int(h * WINDOW_CY_FRAC)
	var hw := int(w * WINDOW_HW_FRAC)
	var hh := int(h * WINDOW_HH_FRAC)
	var warm := 0
	var total := 0
	for y in range(cy - hh, cy + hh, 4):
		for x in range(cx - hw, cx + hw, 4):
			if x < 0 or y < 0 or x >= w or y >= h:
				continue
			total += 1
			var c := img.get_pixel(x, y)
			if c.r > 0.55 and c.g > 0.48 and c.r >= c.b:
				warm += 1
	var ratio := float(warm) / float(maxi(total, 1))
	# Sky/ground split for signature comparison with the historical failure.
	var sky := 0
	var sky_total := 0
	var ground := 0
	var ground_total := 0
	for y in range(0, h, 8):
		for x in range(0, w, 8):
			var c := img.get_pixel(x, y)
			if y < h / 3:
				sky_total += 1
				if c.b > 0.45 and c.b > c.r:
					sky += 1
			if y > h / 2:
				ground_total += 1
				var cmax := maxf(c.r, maxf(c.g, c.b))
				var cmin := minf(c.r, minf(c.g, c.b))
				var sat := 0.0
				if cmax > 0.001:
					sat = (cmax - cmin) / cmax
				var lum := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
				if sat < 0.45 and lum > 0.25 and lum < 0.92:
					ground += 1
	var edge := 0
	var edge_total := 0
	for y in range(cy - hh + 10, cy + hh - 10, 4):
		for x in range(cx - hw + 10, cx + hw - 10, 4):
			if x < 0 or y < 0 or x + 4 >= w or y + 4 >= h:
				continue
			var c0 := img.get_pixel(x, y)
			var cx2 := img.get_pixel(x + 4, y)
			var cy2 := img.get_pixel(x, y + 4)
			var l0 := 0.2126 * c0.r + 0.7152 * c0.g + 0.0722 * c0.b
			var lx := 0.2126 * cx2.r + 0.7152 * cx2.g + 0.0722 * cx2.b
			var ly := 0.2126 * cy2.r + 0.7152 * cy2.g + 0.0722 * cy2.b
			edge_total += 1
			if absf(lx - l0) + absf(ly - l0) > 0.12:
				edge += 1
	var lum_sum := 0.0
	var samples := 0
	var buckets := {}
	for y in range(0, h, 8):
		for x in range(0, w, 8):
			var c := img.get_pixel(x, y)
			samples += 1
			lum_sum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			buckets["%d,%d,%d" % [int(c.r * 16.0), int(c.g * 16.0), int(c.b * 16.0)]] = true
	print("PROBE: mode=%s pivot_rot=(%.4f, %.4f, %.4f) player_y=%.3f" % [
		_mode, _pivot.rotation.x, _pivot.rotation.y, _pivot.rotation.z,
		_player.global_position.y if _player != null else -999.0])
	print("PROBE: mode=%s char_warm=%.3f char_edge=%.3f sky=%.2f ground=%.2f distinct=%d avg_lum=%.3f" % [
		_mode, ratio, float(edge) / float(maxi(edge_total, 1)),
		float(sky) / float(maxi(sky_total, 1)), float(ground) / float(maxi(ground_total, 1)),
		buckets.size(), lum_sum / float(maxi(samples, 1))])
	print("PROBE: historical failure signature = sky=0.78 ground=0.53 char_warm=0.015 char_edge=0.252 distinct=237 avg_lum=0.684")
	if _saved_mouse_mode >= 0:
		Input.mouse_mode = _saved_mouse_mode
		_saved_mouse_mode = -1
	if _mode == "A":
		print("PROBE-EXPECT: drifted camera (pitch != -0.3) and/or collapsed char_warm")
		quit(0)
	else:
		print("PROBE-EXPECT: pinned camera, char_warm restored")
		quit(0)
