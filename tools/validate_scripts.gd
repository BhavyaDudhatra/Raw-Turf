extends SceneTree
## Phase A static validator — parses every GDScript in the project and reports
## parse/compile errors, missing node paths, and unresolved scene groups.
##
## Read-only: loads resources, never modifies them.
## Run: Godot --headless --path <project> --script res://tools/validate_scripts.gd
## Exit 0 = all scripts parsed, 1 = failures, 2 = harness error.

const SCAN_DIRS := ["res://scripts", "res://tools", "res://data"]

var _failures: Array[String] = []
var _script_count := 0
var _scene_count := 0


func _initialize() -> void:
	var scripts: Array[String] = []
	for d in SCAN_DIRS:
		_collect(d, scripts, "gd")
	scripts.sort()
	print("VALIDATE: scanning %d scripts" % scripts.size())
	for path in scripts:
		_check_script(path)

	var scenes: Array[String] = []
	_collect("res://scenes", scenes, "tscn")
	scenes.sort()
	for path in scenes:
		_check_scene(path)

	await _check_group_resolution()

	if _failures.is_empty():
		print("VALIDATE-RESULT: ALL PASS (%d scripts, %d scenes)" % [_script_count, _scene_count])
		quit(0)
	else:
		for f in _failures:
			print("VALIDATE-FAIL: " + f)
		print("VALIDATE-RESULT: %d FAILURE(S)" % _failures.size())
		quit(1)


func _collect(dir_path: String, out: Array[String], ext: String) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = d.get_next()
			continue
		var full := dir_path.path_join(entry)
		if d.current_is_dir():
			# Nested scratch projects are separate Godot projects; skip them.
			if not FileAccess.file_exists(full.path_join("project.godot")):
				_collect(full, out, ext)
		elif entry.get_extension() == ext:
			out.append(full)
		entry = d.get_next()
	d.list_dir_end()


func _check_script(path: String) -> void:
	_script_count += 1
	var res := load(path)
	if res == null:
		_failures.append("script failed to load (parse/compile error): " + path)
		return
	if not (res is GDScript):
		_failures.append("not a GDScript: " + path)
		return
	var gds := res as GDScript
	if gds.get_instance_base_type() == "":
		_failures.append("script has no resolvable base type: " + path)


func _check_scene(path: String) -> void:
	_scene_count += 1
	var ps := load(path)
	if ps == null:
		_failures.append("scene failed to load: " + path)
		return
	if not (ps is PackedScene):
		_failures.append("not a PackedScene: " + path)
		return
	var inst := (ps as PackedScene).instantiate()
	if inst == null:
		_failures.append("scene failed to instantiate: " + path)
		return
	# Not added to the tree, so no _ready()/gameplay side effects fire.
	inst.free()


## Every group the production code resolves at runtime must be resolvable in
## the real main scene. This catches a renamed/missing node before gameplay.
func _check_group_resolution() -> void:
	var required := {
		"player": 1,
		"mission": 1,
		"toast": 1,
		"delivery_dock": 1,
		"vehicle_system": 1,
		"save_system": 1,
		"courier_van": 1,
	}
	var ps := load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		_failures.append("main.tscn failed to load")
		return
	var m := ps.instantiate()
	root.add_child(m)
	for i in range(4):
		await physics_frame
	for g in required.keys():
		var nodes := get_nodes_in_group(String(g))
		if nodes.size() < int(required[g]):
			_failures.append("group '%s' resolved %d node(s), expected >= %d" % [
				String(g), nodes.size(), int(required[g])])
		else:
			print("VALIDATE-PASS: group '%s' -> %d node(s)" % [String(g), nodes.size()])
	# Required node paths referenced by production code via get_node.
	var paths := [
		"Main/Player", "Main/Player/Collision", "Main/Player/CamPivot/SpringArm/Camera",
		"Main/Player/CharacterRoot", "Main/Player/CharacterRoot/CharAnim",
		"Main/Player/CharacterRoot/MHChar", "Main/Van",
		"Main/Van/DrivePivot/SpringArm/DriveCamera",
		"Main/VehicleSystem", "Main/HB01Mission", "Main/DeliveryDock",
		"Main/MissionHUD/Label", "Main/VehicleHUD/Label", "Main/Toast/Label",
	]
	for p in paths:
		var n := root.get_node_or_null(NodePath(p))
		if n == null:
			_failures.append("required node path missing: " + p)
		else:
			print("VALIDATE-PASS: node path " + p)
	m.queue_free()
	await process_frame
