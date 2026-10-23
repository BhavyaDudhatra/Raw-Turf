extends SceneTree
## Project health audit — read-only.
##
##   1. Asset usage: which files are referenced by an imported model or by a
##      scene/resource file, and which are orphans (candidates for removal).
##      This tool NEVER deletes anything — it only reports.
##   2. Model complexity: mesh / surface / material counts per model.
##   3. Render configuration: renderer, environment features, sun shadows,
##      viewport size — the knobs that drive the frame cost.
##
## Run: Godot --headless --path <project> --script res://tools/asset_audit.gd
## Exit 0 = audit completed (findings are informational), 2 = hard error.

var _lines: Array[String] = []

# Counters (members, because GDScript passes ints by value).
var _c_mesh := 0
var _c_surface := 0
var _c_lights := 0
var _c_shadowcasters := 0
var _mats := {}
var _texs := {}


func _initialize() -> void:
	_lines.append("=== AUDIT: model complexity ===")
	var referenced := {}
	_audit_dir("res://assets", referenced)
	_lines.append("")
	_lines.append("=== AUDIT: references from scene / resource files ===")
	var text_refs := _scan_text_files(referenced)
	_lines.append("  distinct res:// paths referenced by .tscn/.tres/.material/.res: %d" % text_refs)
	_lines.append("")
	_lines.append("=== AUDIT: orphan candidates (files referenced by nothing) ===")
	var orphans := 0
	var orphan_bytes := 0
	for f in _all_files("res://assets"):
		if referenced.has(f):
			continue
		if f.ends_with(".md") or f.ends_with(".txt") or f.ends_with(".gitkeep"):
			continue
		if f.ends_with(".import"):
			continue # Godot-managed import sidecar, not a game asset.
		orphans += 1
		orphan_bytes += _file_size(f)
		_lines.append("  ORPHAN? %s (%d KB)" % [f, _file_size(f) / 1024])
	if orphans == 0:
		_lines.append("  (none)")
	_lines.append("  orphan candidate count=%d total=%.1f KB" % [
		orphans, float(orphan_bytes) / 1024.0])
	_lines.append("")
	_lines.append("=== AUDIT: render configuration ===")
	_audit_render()
	_lines.append("")
	_lines.append("=== AUDIT: scene complexity (main.tscn) ===")
	_audit_scene()
	for l in _lines:
		print(l)
	print("AUDIT-RESULT: DONE")
	quit(0)


# --------------------------------------------------------------- asset audit

func _audit_dir(path: String, referenced: Dictionary) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if d.current_is_dir():
			if not name.begins_with("."):
				_audit_dir(path.path_join(name), referenced)
		else:
			var full := path.path_join(name)
			var ext := name.get_extension().to_lower()
			if ext == "glb" or ext == "gltf" or ext == "fbx" or ext == "obj":
				_audit_model(full, referenced)
		name = d.get_next()
	d.list_dir_end()


func _audit_model(path: String, referenced: Dictionary) -> void:
	var ps := load(path) as PackedScene
	if ps == null:
		_lines.append("  MODEL %s -> LOAD FAILED" % path)
		return
	var inst := ps.instantiate()
	_c_mesh = 0
	_c_surface = 0
	_mats = {}
	_texs = {}
	_collect(inst)
	for t in _texs.keys():
		referenced[t] = true
	_lines.append("  MODEL %s meshes=%d surfaces=%d materials=%d external_textures=%d" % [
		path, _c_mesh, _c_surface, _mats.size(), _texs.size()])
	for t in _texs.keys():
		_lines.append("        tex -> %s" % t)
	inst.free()


func _collect(n: Node) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			_c_mesh += 1
			var mi := c as MeshInstance3D
			if mi.mesh != null:
				_c_surface += mi.mesh.get_surface_count()
				for i in range(mi.mesh.get_surface_count()):
					var m := mi.get_active_material(i)
					if m == null:
						continue
					_mats[m.resource_path] = true
					for prop in ["albedo_texture", "normal_texture", "orm_texture",
							"roughness_texture", "metallic_texture", "emission_texture",
							"height_texture", "ao_texture", "texture_albedo",
							"texture_normal", "texture_orm", "texture_roughness"]:
						if not (prop in m):
							continue
						var t: Texture2D = m.get(prop)
						if t != null and t.resource_path != "":
							_texs[t.resource_path] = true
		_collect(c)


## Scan the project's scene / resource / material text files for res:// asset
## paths. Those references cannot be discovered by loading models.
func _scan_text_files(referenced: Dictionary) -> int:
	var roots := ["res://scenes", "res://data", "res://assets"]
	var found := 0
	for root in roots:
		for f in _all_files(root):
			var ext := f.get_extension().to_lower()
			if ext != "tscn" and ext != "tres" and ext != "material" and ext != "res":
				continue
			var txt := FileAccess.get_file_as_string(f)
			if txt.is_empty():
				continue
			for line in txt.split("\n"):
				var idx := line.find("res://")
				if idx < 0:
					continue
				var rest := line.substr(idx)
				var stop := rest.length()
				for ch in ['"', "'", ")", ",", " ", "]"]:
					var p := rest.find(ch)
					if p >= 0 and p < stop:
						stop = p
				var path := rest.substr(0, stop)
				if path.length() > 8 and not referenced.has(path):
					referenced[path] = true
					found += 1
	return found


func _all_files(path: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(path)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if d.current_is_dir():
			if not name.begins_with("."):
				out.append_array(_all_files(path.path_join(name)))
		else:
			out.append(path.path_join(name))
		name = d.get_next()
	d.list_dir_end()
	return out


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n


# -------------------------------------------------------------- render audit

func _audit_render() -> void:
	_lines.append("  renderer=%s method=%s" % [
		RenderingServer.get_current_rendering_driver_name(),
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method"))])
	_lines.append("  viewport=%dx%d stretch=%s" % [
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height"),
		str(ProjectSettings.get_setting("display/window/stretch/mode"))])
	_lines.append("  msaa_2d=%s msaa_3d=%s taa=%s" % [
		str(ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_2d")),
		str(ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d")),
		str(ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_taa"))])
	_lines.append("  directional_shadow_size=%s shadow_filter=%s" % [
		str(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size")),
		str(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality"))])
	_lines.append("  texture_filter=%s anisotropic=%s" % [
		str(ProjectSettings.get_setting("rendering/textures/canvas_textures/default_texture_filter")),
		str(ProjectSettings.get_setting("rendering/textures/default_filters/anisotropic_filtering_level"))])


func _audit_scene() -> void:
	var ps := load("res://scenes/main/main.tscn") as PackedScene
	if ps == null:
		_lines.append("  main.tscn LOAD FAILED")
		return
	var inst := ps.instantiate()
	var counts := {}
	_count(inst, counts)
	var type_lines: Array[String] = []
	for k in counts.keys():
		type_lines.append("%s=%d" % [k, counts[k]])
	type_lines.sort()
	_lines.append("  node types: %s" % ", ".join(type_lines))
	_c_mesh = 0
	_c_lights = 0
	_c_shadowcasters = 0
	_mats = {}
	_gather(inst)
	_lines.append("  mesh_instances=%d unique_materials=%d lights=%d shadow_casters=%d" % [
		_c_mesh, _mats.size(), _c_lights, _c_shadowcasters])
	# World environment + sun settings that matter for the frame cost.
	var we := inst.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we != null and we.environment != null:
		var env := we.environment
		_lines.append("  environment: background=%s ambient_source=%s ssao=%s glow=%s fog=%s tonemap=%s adjustments=%s" % [
			str(env.background_mode), str(env.ambient_light_source),
			str(env.ssao_enabled), str(env.glow_enabled), str(env.fog_enabled),
			str(env.tonemap_mode), str(env.adjustment_enabled)])
	var sun := inst.get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		_lines.append("  sun: shadows=%s shadow_mode=%s shadow_opacity=%.2f energy=%.2f angular_distance=%.4f" % [
			str(sun.shadow_enabled), str(sun.directional_shadow_mode),
			sun.shadow_opacity, sun.light_energy, sun.light_angular_distance])
	else:
		_lines.append("  sun: NOT FOUND")
	inst.free()


func _count(n: Node, counts: Dictionary) -> void:
	for c in n.get_children():
		var key := c.get_class()
		counts[key] = int(counts.get(key, 0)) + 1
		_count(c, counts)


func _gather(n: Node) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			_c_mesh += 1
			var mi := c as MeshInstance3D
			if mi.mesh != null:
				for i in range(mi.mesh.get_surface_count()):
					var m := mi.get_active_material(i)
					if m != null:
						_mats[m.resource_path] = true
			if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				_c_shadowcasters += 1
		if c is Light3D:
			_c_lights += 1
		_gather(c)
