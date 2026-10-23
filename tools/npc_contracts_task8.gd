extends SceneTree
## Task 8 structural contracts (NPC & Pedestrian Foundations).
##
## This is a NEW gate file, separate from the historical Task 7B.8 contracts
## in scratch_7b_8/contracts.gd (which are left untouched as evidence). The
## 7B contracts assert the *player character* state; these assert the *NPC*
## state. Keeping them apart means a Task 8 regression is never reported as a
## Task 7B failure.
##
## Run: Godot --headless --path <project> --script res://tools/npc_contracts_task8.gd
##
## Stage 8.0 contract set:
##   * the five Task 8 scripts exist and carry their class_name,
##   * the data files parse, the waypoint graph is connected and never enters
##     the HB-01 delivery lane or the Pier 9 dock pad,
##   * the pedestrian scene has the agreed collision layer/mask (9/9) and
##     capsule (r0.35 h1.7 @ y0.85),
##   * main.tscn wires the NpcDirector node,
##   * no autoload was introduced,
##   * the protected player / van collision configuration is untouched.

const NPC_SCRIPTS := {
	"res://scripts/npc/npc_base.gd": "NpcBase",
	"res://scripts/npc/npc_pedestrian.gd": "NpcPedestrian",
	"res://scripts/npc/npc_talk.gd": "NpcTalk",
	"res://scripts/npc/npc_director.gd": "NpcDirector",
	"res://scripts/npc/npc_profile.gd": "NpcProfile",
}

var _failures: Array[String] = []


func _check(ok: bool, n: String) -> void:
	print(("CONTRACT-PASS: " if ok else "CONTRACT-FAIL: ") + n)
	if not ok:
		_failures.append(n)


func _initialize() -> void:
	_check_scripts()
	_check_no_autoload()
	_check_pedestrian_scene()
	_check_graph()
	await _check_runtime()
	if _failures.is_empty():
		print("CONTRACT-RESULT: ALL PASS")
		quit(0)
	else:
		print("CONTRACT-RESULT: %d FAILURE(S)" % _failures.size())
		quit(1)


func _check_scripts() -> void:
	for path in NPC_SCRIPTS:
		var res: Resource = load(path)
		_check(res != null, "script exists: %s" % path)
		if res is GDScript:
			var gs: GDScript = res
			_check(gs.get_global_name() == NPC_SCRIPTS[path],
				"class_name %s in %s" % [NPC_SCRIPTS[path], path])


func _check_no_autoload() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load("res://project.godot")
	_check(err == OK, "project.godot readable")
	if err != OK:
		return
	var has_section := cfg.has_section("autoload")
	var keys: Array = cfg.get_section_keys("autoload") if has_section else []
	_check(not has_section or keys.is_empty(), "no autoloads introduced")


func _check_pedestrian_scene() -> void:
	var packed := load("res://scenes/npcs/npc_pedestrian.tscn") as PackedScene
	_check(packed != null, "pedestrian scene loads")
	if packed == null:
		return
	var ped := packed.instantiate()
	_check(ped is CharacterBody3D, "pedestrian root is CharacterBody3D")
	_check(ped.collision_layer == 9, "pedestrian collision_layer = 9 (world 1 + pedestrian 8)")
	_check(ped.collision_mask == 9, "pedestrian collision_mask = 9")
	var col := ped.get_node_or_null("Collision") as CollisionShape3D
	var cap := col.shape as CapsuleShape3D if col != null else null
	_check(cap != null and is_equal_approx(cap.radius, 0.35) and is_equal_approx(cap.height, 1.7),
		"pedestrian capsule r0.35 h1.7")
	_check(col != null and col.position.is_equal_approx(Vector3(0, 0.85, 0)),
		"pedestrian capsule at y0.85")
	_check(ped.get_node_or_null("Visual") != null, "pedestrian Visual node present")
	ped.free()


func _check_graph() -> void:
	var text := FileAccess.get_file_as_string("res://data/npc/wander_points.json")
	_check(not text.is_empty(), "wander_points.json readable")
	if text.is_empty():
		return
	var raw: Variant = JSON.parse_string(text)
	_check(raw is Dictionary, "wander_points.json parses")
	if not (raw is Dictionary):
		return
	var d: Dictionary = raw
	var points: Dictionary = {}
	var links: Dictionary = {}
	var order: Array[String] = []
	for entry in d.get("points", []):
		var pd: Dictionary = entry
		var id := str(pd.get("id", ""))
		var pos: Array = pd.get("pos", [])
		points[id] = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		var l: Array[String] = []
		for link in pd.get("links", []):
			l.append(str(link))
		links[id] = l
		order.append(id)
	_check(points.size() >= 12, "waypoint graph has >= 12 points (%d)" % points.size())

	# Connectivity: every point must be reachable from every other point.
	var seen: Dictionary = {}
	if order.size() > 0:
		var stack: Array[String] = [order[0]]
		seen[order[0]] = true
		while not stack.is_empty():
			var cur: String = stack.pop_back()
			for nb in links.get(cur, []):
				if not seen.has(nb):
					seen[nb] = true
					stack.append(nb)
	_check(seen.size() == points.size(), "waypoint graph is fully connected (%d/%d)" % [seen.size(), points.size()])

	# Keep-out: no point and no transit may enter the delivery lane / dock pad.
	var zones: Array = d.get("keep_out", [])
	var violations := NpcDirector.verify_waypoints(points, links, zones)
	_check(violations.is_empty(), "waypoint graph respects keep-out zones %s" % str(violations))

	var ptext := FileAccess.get_file_as_string("res://data/npc/pedestrian_profiles.json")
	_check(not ptext.is_empty(), "pedestrian_profiles.json readable")
	var praw: Variant = JSON.parse_string(ptext)
	_check(praw is Dictionary, "pedestrian_profiles.json parses")
	if praw is Dictionary:
		var plist: Array = (praw as Dictionary).get("profiles", [])
		_check(plist.size() >= 3, "at least 3 pedestrian archetypes (%d)" % plist.size())
		for entry in plist:
			var pd: Dictionary = entry
			_check(float(pd.get("walk_speed", 0.0)) > 0.0, "profile %s has a positive walk_speed" % str(pd.get("id", "?")))


func _check_runtime() -> void:
	var ps: PackedScene = load("res://scenes/main/main.tscn") as PackedScene
	_check(ps != null, "main.tscn loads")
	if ps == null:
		return
	var m: Node = ps.instantiate()
	root.add_child(m)
	for i in range(20):
		await physics_frame

	var director := root.get_node_or_null("Main/NpcDirector")
	_check(director != null, "main.tscn contains the NpcDirector node")
	_check(director != null and director.is_in_group("npc_director"), "director joins group npc_director")
	if director != null:
		_check(director.get("load_error") == "", "director loaded its data (err=%s)" % str(director.get("load_error")))
		_check(director.get("profiles").size() >= 3, "director holds the archetype profiles")
		_check(director.get("waypoints").size() >= 12, "director holds the waypoint graph")

	# The pedestrian group must resolve at runtime (proposal 9.2).
	var npcs: Array[Node] = get_nodes_in_group("npc")
	_check(npcs.size() >= 1, "group npc resolves at runtime (%d)" % npcs.size())
	if npcs.size() > 0:
		var ped := npcs[0] as Node3D
		_check(ped != null and ped.collision_layer == 9 and ped.collision_mask == 9,
			"runtime pedestrian layer 9 / mask 9")

	# Protected configuration must be untouched by Task 8.
	var player := root.get_node_or_null("Main/Player")
	_check(player != null and player.get("collision_layer") == 2 and player.get("collision_mask") == 1,
		"player collision still layer 2 / mask 1")
	var van := root.get_node_or_null("Main/Van")
	_check(van != null and van.get("collision_layer") == 5 and van.get("collision_mask") == 1,
		"van collision still layer 5 / mask 1")
