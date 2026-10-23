class_name NpcDirector
extends Node
## Meridian Bay — NPC population manager (Task 8).
##
## The director is an ordinary scene node (group `npc_director`) that lives in
## main.tscn. It owns:
##
##   * the pedestrian archetypes (data/npc/pedestrian_profiles.json),
##   * the waypoint graph (data/npc/wander_points.json),
##   * the population and its budget (active / resident caps),
##   * the deterministic RNG that drives every spawn and every walk.
##
## No autoloads: everything resolves through the scene tree and the
## established groups. The director never touches the player, the van, the
## mission or the save format beyond the optional "npc" key (stage 8.4).

## Every director registers here.
const GROUP_NAME: String = "npc_director"

const PROFILES_PATH: String = "res://data/npc/pedestrian_profiles.json"
const WAYPOINTS_PATH: String = "res://data/npc/wander_points.json"

@export_group("Budget")
## Maximum number of simultaneously simulated pedestrians.
## The proposal targets 12, but the measured CharacterBody3D physics cost in
## Godot Physics requires a lower cap in this build to satisfy the A3 physics
## budget (see the Task 8 progress report). The cap is a hard limit enforced
## by the director.
@export var max_active: int = 6
## Maximum number of instantiated pedestrians (simulated + dormant).
@export var max_resident: int = 24
## Pedestrians further than this from the player are frozen and released.
@export var activation_radius: float = 40.0
## Inside this distance a pedestrian decides every physics frame.
@export var near_radius: float = 15.0
## Physics ticks between decisions for mid-tier pedestrians (12 ticks = 5 Hz).
@export var mid_decision_interval: int = 12

@export_group("Content")
@export var pedestrian_scene: PackedScene
@export var profiles_path: String = PROFILES_PATH
@export var waypoints_path: String = WAYPOINTS_PATH
## Fixed seed -> the whole population is reproducible across runs.
@export var rng_seed: int = 20261022
## Number of pedestrians spawned at boot (the population is topped up to
## max_active by the 5 Hz population update).
@export var initial_spawn_count: int = 1
## Minimum distance between a spawn point and the player.
@export var min_spawn_distance: float = 6.0
## Minimum distance between a spawn point and any existing pedestrian.
@export var min_spawn_separation: float = 2.5

## Counter used to track deterministic spawn order (persisted in saves).
var spawn_index: int = 0

## Loaded archetypes.
var profiles: Array[NpcProfile] = []
## Waypoint id -> world position.
var waypoints: Dictionary = {}
## Waypoint id -> array of linked waypoint ids.
var waypoint_links: Dictionary = {}
## Ordered waypoint ids (stable iteration order).
var waypoint_order: Array[String] = []
## Keep-out rectangles that the walkable graph must never enter.
var keep_out: Array[Dictionary] = []
## The live pedestrians.
var population: Array[NpcPedestrian] = []
## The RIDs of the live pedestrians (shared with them so their obstacle
## probes ignore other pedestrians).
var population_rids: Array[RID] = []
## Snapshot of the population positions, refreshed every physics tick. The
## pedestrians read it for the soft separation, so they do not have to pull
## every neighbour's transform through the engine on every tick.
var population_positions: PackedVector3Array = PackedVector3Array()

## Deterministic RNG shared by the population.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
## Set when the data files could not be read.
var load_error: String = ""
## How many pedestrians have been spawned since boot (restored on load).
var spawn_index: int = 0

var _spawned: bool = false
var _tick: int = 0


func _ready() -> void:
	add_to_group(GROUP_NAME)
	rng.seed = rng_seed
	load_data()


func _physics_process(_delta: float) -> void:
	if not _spawned:
		_spawned = true
		_spawn_initial()
	_tick += 1
	# The position snapshot is refreshed every tick: the director is the
	# parent of the population, so it runs before the pedestrians and they
	# read a snapshot that is one tick old (a soft force does not care).
	_refresh_positions()
	# Population work runs at 5 Hz, not per frame (proposal 6.2 / 6.3).
	if _tick % 12 == 0:
		_update_population()


## Refreshes the shared snapshot of the population: the positions (used by
## the soft separation) and the RIDs (used by the obstacle probes).
func _refresh_positions() -> void:
	var pos := PackedVector3Array()
	pos.resize(population.size())
	var rids: Array[RID] = []
	rids.resize(population.size())
	for i in range(population.size()):
		var ped := population[i]
		pos[i] = ped.global_position
		ped.population_index = i
		rids[i] = ped.get_rid()
	population_positions = pos
	population_rids = rids
	for ped in population:
		ped.population_positions = pos
		ped.population_rids = rids


## The 5 Hz population update: tier assignment, spawning and despawning.
##
## Tiers (proposal 6.1):
##   * NEAR (< near_radius)        -> decides every physics frame,
##   * MID  (near_radius .. activation_radius) -> decides 5 times a second,
##   * FAR  (> activation_radius)  -> frozen, not simulated at all.
func _update_population() -> void:
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var anchor := Vector3.ZERO
	if player != null:
		anchor = player.global_position

	# 1. Split the residents into "inside the activation radius" and the rest.
	var inside: Array[NpcPedestrian] = []
	var outside: Array[NpcPedestrian] = []
	for ped in population:
		if ped.global_position.distance_to(anchor) > activation_radius:
			outside.append(ped)
		else:
			inside.append(ped)

	# 2. The closest max_active residents simulate, the rest stay dormant.
	inside.sort_custom(func(a: NpcPedestrian, b: NpcPedestrian) -> bool:
		return a.global_position.distance_to(anchor) < b.global_position.distance_to(anchor))
	var simulating := 0
	for i in range(inside.size()):
		var ped := inside[i]
		if simulating < max_active:
			simulating += 1
			_assign_tier(ped, ped.global_position.distance_to(anchor))
		else:
			ped.freeze()

	# 3. Every resident outside the activation radius is frozen.
	for ped in outside:
		ped.freeze()

	# 4. Top the population up to max_active while the resident cap allows it.
	var guard := 0
	while active_count() < max_active and population.size() < max_resident and guard < 64:
		guard += 1
		if _spawn_one(anchor) == null:
			break

	# 5. Enforce the resident cap by freeing the farthest residents.
	while population.size() > max_resident:
		if not _free_farthest(anchor):
			break

	_refresh_population_refs()


## Assigns the simulation tier of one pedestrian.
func _assign_tier(ped: NpcPedestrian, distance: float) -> void:
	ped.unfreeze()
	if distance < near_radius:
		ped.decision_interval = 1
	else:
		ped.decision_interval = mid_decision_interval


## Frees the resident that is farthest from the player. Returns false when
## there is nothing left to free.
func _free_farthest(anchor: Vector3) -> bool:
	var worst: NpcPedestrian = null
	var worst_d := -1.0
	for ped in population:
		var d := ped.global_position.distance_to(anchor)
		if d > worst_d:
			worst_d = d
			worst = ped
	if worst == null:
		return false
	population.erase(worst)
	worst.queue_free()
	return true


## Reads the archetype and waypoint data files.
func load_data() -> bool:
	load_error = ""
	profiles.clear()
	waypoints.clear()
	waypoint_links.clear()
	waypoint_order.clear()
	keep_out.clear()

	var praw: Variant = _read_json(profiles_path)
	if praw is Dictionary:
		for entry in (praw as Dictionary).get("profiles", []):
			if entry is Dictionary:
				profiles.append(NpcProfile.from_dict(entry))
	if profiles.is_empty():
		load_error = "no profiles loaded from %s" % profiles_path

	var wraw: Variant = _read_json(waypoints_path)
	if wraw is Dictionary:
		var wdict: Dictionary = wraw
		for entry in wdict.get("points", []):
			if not (entry is Dictionary):
				continue
			var pd: Dictionary = entry
			var id := str(pd.get("id", ""))
			if id == "":
				continue
			var pos: Array = pd.get("pos", [0.0, 0.0, 0.0])
			if pos.size() < 3:
				continue
			waypoints[id] = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
			var links: Array[String] = []
			for link in pd.get("links", []):
				links.append(str(link))
			waypoint_links[id] = links
			waypoint_order.append(id)
		for entry in wdict.get("keep_out", []):
			if entry is Dictionary:
				keep_out.append(entry)
	return not profiles.is_empty()


## Number of instantiated pedestrians.
func resident_count() -> int:
	return population.size()


## Number of simulating pedestrians.
func active_count() -> int:
	var n := 0
	for ped in population:
		if is_instance_valid(ped) and ped.is_physics_processing():
			n += 1
	return n


## Returns the NPC state for optional persistence (schema v1).
func get_save_data() -> Dictionary:
	return {"seed": rng_seed, "active_count": active_count(), "spawn_index": spawn_index}


## Restores NPC state from a save. The population is rebuilt deterministically
## using the stored seed; individuals are never restored at arbitrary positions
## (the director spawns from safe waypoints within the activation radius).
func load_save_data(data: Dictionary) -> void:
	if data == null or typeof(data) != TYPE_DICTIONARY or data.is_empty():
		return
	if data.has("seed"):
		rng_seed = int(data.get("seed"))
		_rng = RandomNumberGenerator.new()
		_rng.seed = rng_seed
	if data.has("spawn_index"):
		spawn_index = int(data.get("spawn_index"))
	# Rebuild deterministically: clear and repopulate.
	for ped in population:
		if is_instance_valid(ped):
			ped.queue_free()
	population.clear()
	population_rids.clear()
	population_positions.clear()
	if not waypoints.is_empty():
		_assign_phases()
	_spawn_initial()
	# Force a population update on the next tick.
	_tick = 11


## World position of a waypoint, or Vector3.ZERO when unknown.
func waypoint_position(id: String) -> Vector3:
	return waypoints.get(id, Vector3.ZERO)


## The waypoint closest to a world position.
func nearest_waypoint(p: Vector3) -> String:
	var best := ""
	var best_d := INF
	for id in waypoint_order:
		var d: float = waypoints[id].distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = id
	return best


## Picks the next waypoint from a set of linked waypoints.
## Deterministic for a given RNG state.
func request_next_waypoint(from_id: String) -> String:
	var links: Array = waypoint_links.get(from_id, [])
	if links.is_empty():
		return from_id
	return str(links[rng.randi_range(0, links.size() - 1)])


## Picks a random waypoint at least min_distance away from a position.
## Returns an empty string when no waypoint qualifies.
func random_waypoint_away_from(p: Vector3, min_distance: float) -> String:
	var candidates: Array[String] = []
	for id in waypoint_order:
		if waypoints[id].distance_to(p) >= min_distance:
			candidates.append(id)
	if candidates.is_empty():
		return ""
	return candidates[rng.randi_range(0, candidates.size() - 1)]


## The nearest waypoint that is not inside a protected zone. Used when a
## pedestrian has to escape the delivery lane.
func nearest_safe_waypoint(from_pos: Vector3) -> String:
	var best := ""
	var best_d := INF
	for id in waypoint_order:
		var p: Vector3 = waypoints[id]
		if _inside_any_keep_out(p):
			continue
		var d := p.distance_squared_to(from_pos)
		if d < best_d:
			best_d = d
			best = id
	return best


## The navigation callback handed to every pedestrian.
## mode "next" -> the next waypoint to walk to,
## mode "safe" -> the nearest waypoint outside the protected zones.
func _provide_next_waypoint(from_id: String, mode: String, from_pos: Vector3) -> Dictionary:
	if mode == "safe":
		var safe := nearest_safe_waypoint(from_pos)
		return {"id": safe, "pos": waypoint_position(safe)}
	var next_id := request_next_waypoint(from_id)
	return {"id": next_id, "pos": waypoint_position(next_id)}


## Verifies that no waypoint and no straight-line transit between two linked
## waypoints enters a keep-out rectangle. Returns a list of violations
## (empty when the graph is safe). Used by the Task 8 contracts gate.
static func verify_waypoints(points: Dictionary, links: Dictionary, zones: Array) -> Array[String]:
	var violations: Array[String] = []
	for id in points:
		var p: Vector3 = points[id]
		for zone in zones:
			if _inside_zone(p, zone):
				violations.append("waypoint %s inside keep-out %s" % [id, str(zone.get("id", "?"))])
	for id in links:
		var a: Vector3 = points.get(id, Vector3.ZERO)
		for other in links[id]:
			var b: Vector3 = points.get(other, Vector3.ZERO)
			if a == Vector3.ZERO or b == Vector3.ZERO:
				continue
			for zone in zones:
				if _segment_enters_zone(a, b, zone):
					violations.append("transit %s->%s enters keep-out %s" % [id, str(other), str(zone.get("id", "?"))])
	return violations


static func _inside_zone(p: Vector3, zone: Dictionary) -> bool:
	return p.x >= float(zone.get("x_min", 0.0)) and p.x <= float(zone.get("x_max", 0.0)) \
		and p.z >= float(zone.get("z_min", 0.0)) and p.z <= float(zone.get("z_max", 0.0))


func _inside_any_keep_out(p: Vector3) -> bool:
	for zone in keep_out:
		if _inside_zone(p, zone):
			return true
	return false


static func _segment_enters_zone(a: Vector3, b: Vector3, zone: Dictionary) -> bool:
	# Sample the segment; 32 samples is far finer than the smallest
	# rectangle side used by the map.
	var steps := 32
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var p := a.lerp(b, t)
		if _inside_zone(p, zone):
			return true
	return false


# --- population -------------------------------------------------------------

## Spawns the boot population (stage 8.1: a single pedestrian).
func _spawn_initial() -> void:
	if pedestrian_scene == null or profiles.is_empty():
		return
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var anchor := Vector3.ZERO
	if player != null:
		anchor = player.global_position
	for i in range(initial_spawn_count):
		_spawn_one(anchor)


## Spawns one pedestrian near a point. Returns null when the scene is unset.
func _spawn_one(anchor: Vector3) -> NpcPedestrian:
	if pedestrian_scene == null or profiles.is_empty():
		return null
	var profile: NpcProfile = profiles[spawn_index % profiles.size()]
	var pos := _pick_spawn_position(anchor)
	if pos == Vector3.ZERO:
		return null
	pos.y = 0.05
	var ped := pedestrian_scene.instantiate() as NpcPedestrian
	if ped == null:
		return null
	ped.apply_profile(profile)
	ped.rng.seed = rng_seed * 7919 + spawn_index
	ped.decision_interval = 1
	ped.decision_phase = spawn_index % 12
	ped.waypoint_provider = Callable(self, "_provide_next_waypoint")
	add_child(ped)
	ped.global_position = pos
	var start_id := nearest_waypoint(pos)
	var res := _provide_next_waypoint(start_id, "next", pos)
	ped.setup_waypoints(start_id, waypoint_position(start_id), str(res.get("id", "")), res.get("pos", Vector3.ZERO))
	population.append(ped)
	spawn_index += 1
	return ped


## Picks a spawn point: a waypoint that is away from the player, inside the
## activation radius (a pedestrian spawned outside it would be frozen right
## away) and not on top of an existing pedestrian (no clustering, no physics
## pop).
func _pick_spawn_position(anchor: Vector3) -> Vector3:
	var clear_pool: Array[String] = []
	var far_pool: Array[String] = []
	for id in waypoint_order:
		var p: Vector3 = waypoints[id]
		var d := p.distance_to(anchor)
		if d < min_spawn_distance:
			continue
		if d > activation_radius:
			continue
		far_pool.append(id)
		var clear := true
		for other in population:
			if other.global_position.distance_to(p) < min_spawn_separation:
				clear = false
				break
		if clear:
			clear_pool.append(id)
	var pool: Array[String] = clear_pool if not clear_pool.is_empty() else far_pool
	if pool.is_empty():
		return Vector3.ZERO
	var id: String = pool[rng.randi_range(0, pool.size() - 1)]
	return waypoint_position(id)


## Keeps the pedestrians' shared population reference fresh (soft separation)
## and publishes the population RIDs, so an obstacle probe only sees the
## static world.
func _refresh_population_refs() -> void:
	_refresh_positions()


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		load_error = "missing file %s" % path
		push_warning("NPC DIRECTOR: missing data file %s" % path)
		return null
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		load_error = "empty file %s" % path
		push_warning("NPC DIRECTOR: empty data file %s" % path)
		return null
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		load_error = "bad JSON in %s" % path
		push_warning("NPC DIRECTOR: bad JSON in %s" % path)
	return parsed
