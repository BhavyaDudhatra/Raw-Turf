extends SceneTree
## Task 1 render check — runs the real main.tscn WITH rendering, captures one
## viewport screenshot after 90 frames, and asserts the image is not blank:
## sky-blue pixels in the top third, ground-tone pixels in the bottom half,
## and player-blue pixels near screen centre. Informational, lenient by design.
## Run (needs a display/GPU, NOT headless):
##   Godot --path <project> --resolution 1280x720 --script res://tools/render_check_task1.gd
## Screenshot: .godot/render_check.png (git-ignored, stays on B:).
## Exit 0 = pass, 1 = fail, 2 = error.

var _frames: int = 0
var _done: bool = false


func _initialize() -> void:
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
	if _frames < 90:
		return
	_done = true
	_evaluate()


func _evaluate() -> void:
	var failures: Array[String] = []
	var tex: Texture2D = root.get_texture()
	if tex == null:
		push_error("RENDER: no viewport texture")
		quit(2)
		return
	var img := (tex as ViewportTexture).get_image()
	var w := img.get_width()
	var h := img.get_height()
	print("RENDER: captured %dx%d" % [w, h])
	var save_path := ProjectSettings.globalize_path("res://") + ".godot/render_check.png"
	if img.save_png(save_path) != OK:
		failures.append("could not save screenshot")
	else:
		print("RENDER: saved " + save_path)
	var sky := 0
	var sky_total := 0
	var ground := 0
	var ground_total := 0
	var player_blue := 0
	var center_total := 0
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
			if abs(x - w / 2) < 200 and abs(y - h / 2) < 150:
				center_total += 1
				if c.b > 0.25 and c.b > c.r + 0.08 and c.b > c.g:
					player_blue += 1
	var sky_ratio := float(sky) / float(maxi(sky_total, 1))
	var ground_ratio := float(ground) / float(maxi(ground_total, 1))
	var blue_ratio := float(player_blue) / float(maxi(center_total, 1))
	var avg_lum := lum_sum / float(maxi(samples, 1))
	print("RENDER: sky=%.2f ground=%.2f player_blue=%.3f distinct=%d avg_lum=%.3f" % [
		sky_ratio, ground_ratio, blue_ratio, buckets.size(), avg_lum])
	_check(sky_ratio > 0.15, "sky visible in top third", failures)
	_check(ground_ratio > 0.15, "ground visible in bottom half", failures)
	_check(blue_ratio > 0.001, "player blue near centre", failures)
	_check(avg_lum > 0.05, "image is not black", failures)
	_check(buckets.size() > 50, "image has variety (not blank)", failures)
	if failures.is_empty():
		print("RENDER-RESULT: ALL PASS")
		quit(0)
	else:
		print("RENDER-RESULT: %d FAILURE(S)" % failures.size())
		quit(1)


func _check(ok: bool, check_name: String, failures: Array[String]) -> void:
	print(("RENDER-PASS: " if ok else "RENDER-FAIL: ") + check_name)
	if not ok:
		failures.append(check_name)
