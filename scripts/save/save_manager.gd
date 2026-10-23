class_name SaveManager
extends Node
## Meridian Bay — versioned JSON save/load (Task 5).
## Centralized persistence owned here; game scripts own their live state and
## only expose it for capture/restore (see state map in the Task 5 report).
## Development save location is fixed under the project on B::
##   <project>/userdata/saves/<slot>.json
## It is NEVER user:// (which resolves to AppData on C:) and NEVER falls back
## to C:: if the B: path is unwritable, saving disables itself with an error.
## Writes are atomic-ish: tmp file -> validate -> rotate previous to .bak ->
## promote tmp. A crash between renames leaves the .bak recoverable, and
## load_game() falls back to it. This is documented best-effort durability,
## NOT crash-proof transactions.

const SCHEMA_VERSION: int = 1
const PRIMARY_SLOT: String = "savegame"
const POS_LIMIT: float = 5000.0

## Tests set this to probe failure paths (e.g. "" forces a write failure).
@export var save_dir_override: String = ""

var save_enabled: bool = true
var last_error: String = ""

@onready var _player: CharacterBody3D = get_parent().get_node_or_null("Player")
@onready var _van: CharacterBody3D = get_parent().get_node_or_null("Van")
@onready var _sys: Node = get_parent().get_node_or_null("VehicleSystem")
@onready var _mission: Node = get_parent().get_node_or_null("HB01Mission")


func _ready() -> void:
	add_to_group("save_system")


func get_save_dir() -> String:
	if save_dir_override != "":
		return save_dir_override
	return ProjectSettings.globalize_path("res://").path_join("userdata/saves")


func get_save_path(slot: String = PRIMARY_SLOT) -> String:
	return get_save_dir().path_join(slot + ".json")


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed or k.echo:
			return
		if k.physical_keycode == KEY_F6:
			save_game()
		elif k.physical_keycode == KEY_F9:
			load_game()


func save_game(slot: String = PRIMARY_SLOT) -> bool:
	if not save_enabled:
		_fail("Saving is disabled (previous path failure).")
		return false
	if _player == null or _van == null or _sys == null or _mission == null:
		_fail("Cannot save: game nodes missing.")
		return false
	if not _ensure_dir():
		return false
	var data := {
		"schema": SCHEMA_VERSION,
		"game": "meridian-bay",
		"saved_unix": Time.get_unix_time_from_system(),
		"player": {"pos": _vec(_player.global_position), "yaw": _yaw(_player)},
		"van": {"pos": _vec(_van.global_position), "yaw": _yaw(_van)},
		"mode": int(_sys.get("mode")),
		"mission": {
			"state": int(_mission.get("state")),
			"balance": int(_mission.get("balance")),
			"reward_paid": bool(_mission.get("reward_paid")),
		},
	}
	# Optional NPC persistence (schema v1, backward compatible).
	var director: Node = get_parent().get_node_or_null("NpcDirector")
	if director == null:
		director = get_tree().get_first_node_in_group("npc_director")
	if director != null and director.has_method("get_save_data"):
		var npc_data: Variant = director.call("get_save_data")
		if npc_data is Dictionary and not (npc_data as Dictionary).is_empty():
			data["npc"] = npc_data
	var text := JSON.stringify(data, "  ")
	var main_path := get_save_path(slot)
	var tmp_path := main_path + ".tmp"
	var bak_path := main_path + ".bak"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		_fail("Cannot open temp save: %s (%s)." % [tmp_path, error_string(FileAccess.get_open_error())])
		return false
	f.store_string(text)
	f.flush()
	var werr := f.get_error()
	f.close()
	if werr != OK:
		_fail("Write failed: %s (%s)." % [tmp_path, error_string(werr)])
		DirAccess.remove_absolute(tmp_path)
		return false
	if not _read_valid(tmp_path):
		_fail("New save failed validation; previous save kept.")
		DirAccess.remove_absolute(tmp_path)
		return false
	# Rotate: previous -> .bak (if any), tmp -> primary. Previous save is
	# never removed before its replacement is validated on disk.
	if FileAccess.file_exists(bak_path) and DirAccess.remove_absolute(bak_path) != OK:
		_fail("Cannot clear stale backup; previous save kept.")
		return false
	if FileAccess.file_exists(main_path) and DirAccess.rename_absolute(main_path, bak_path) != OK:
		_fail("Cannot back up previous save; it is left untouched.")
		return false
	if DirAccess.rename_absolute(tmp_path, main_path) != OK:
		DirAccess.rename_absolute(bak_path, main_path) # best-effort restore
		_fail("Cannot promote new save; previous save restored if possible.")
		return false
	last_error = ""
	_toast("Saved.")
	return true


func load_game(slot: String = PRIMARY_SLOT) -> bool:
	var main_path := get_save_path(slot)
	var bak_path := main_path + ".bak"
	var used := main_path
	if not FileAccess.file_exists(main_path):
		if FileAccess.file_exists(bak_path):
			used = bak_path
			push_warning("SAVE: primary missing, recovering from backup.")
		else:
			_fail("No save file found.")
			return false
	var f := FileAccess.open(used, FileAccess.READ)
	if f == null:
		_fail("Cannot read save: %s." % used)
		return false
	var text := f.get_as_text()
	f.close()
	var parser := JSON.new()
	if parser.parse(text) != OK:
		_fail("Save is not valid JSON (%s); live game preserved." % parser.get_error_message())
		return false
	var data: Variant = parser.get_data()
	var reason := _validate(data)
	if reason != "":
		_fail("Save rejected (%s); live game preserved." % reason)
		return false
	return _apply(data as Dictionary)


## Full structural validation BEFORE touching live state. Returns "" or why.
func _validate(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return "root is not an object"
	if int(data.get("schema", -1)) != SCHEMA_VERSION:
		return "unsupported schema v%s (need v%d)" % [str(data.get("schema", "?")), SCHEMA_VERSION]
	var r := _check_body(data, "player")
	if r != "":
		return r
	r = _check_body(data, "van")
	if r != "":
		return r
	if int(data.get("mode", -1)) not in [0, 1]:
		return "bad mode"
	var m: Variant = data.get("mission", null)
	if typeof(m) != TYPE_DICTIONARY:
		return "mission missing"
	if int(m.get("state", -1)) not in [0, 1, 2]:
		return "bad mission state"
	if int(m.get("balance", -1)) < 0:
		return "negative balance"
	if typeof(m.get("reward_paid", null)) != TYPE_BOOL:
		return "bad reward_paid"
	return ""


func _check_body(data: Dictionary, key: String) -> String:
	var b: Variant = data.get(key, null)
	if typeof(b) != TYPE_DICTIONARY:
		return key + " missing"
	var pos: Variant = b.get("pos", null)
	if typeof(pos) != TYPE_ARRAY or pos.size() != 3:
		return key + ".pos malformed"
	for c in pos:
		if typeof(c) not in [TYPE_INT, TYPE_FLOAT]:
			return key + ".pos not numeric"
		if not is_finite(float(c)) or absf(float(c)) > POS_LIMIT:
			return key + ".pos out of range"
	if typeof(b.get("yaw", null)) not in [TYPE_INT, TYPE_FLOAT]:
		return key + ".yaw malformed"
	if not is_finite(float(b.get("yaw"))):
		return key + ".yaw non-finite"
	return ""


func _apply(data: Dictionary) -> bool:
	if _player == null or _van == null or _sys == null or _mission == null:
		_fail("Cannot load: game nodes missing.")
		return false
	# Suppress dock auto-completion across the restore window (van may land
	# inside the dock while ACTIVE — that must not complete the mission).
	_mission.call("suppress_completion", 10)
	var pp: Array = data["player"]["pos"]
	var vp: Array = data["van"]["pos"]
	_van.global_position = Vector3(float(vp[0]), float(vp[1]), float(vp[2]))
	_van.rotation.y = float(data["van"]["yaw"])
	_van.set("forward_speed", 0.0)
	_van.velocity = Vector3.ZERO
	var ppos := Vector3(float(pp[0]), float(pp[1]), float(pp[2]))
	if not _spot_free(ppos):
		ppos = Vector3(0, 1, 8) # documented fallback: plaza spawn
		push_warning("SAVE: saved player spot blocked; using spawn fallback.")
	_player.global_position = ppos
	_player.rotation.y = float(data["player"]["yaw"])
	_player.velocity = Vector3.ZERO
	var m: Dictionary = data["mission"]
	_mission.call("apply_loaded_state", int(m["state"]), int(m["balance"]), bool(m["reward_paid"]))
	_sys.call("apply_loaded_mode", int(data["mode"]) == 1)
	# Optional NPC state (schema v1): rebuild deterministically if present.
	var npc_data: Variant = data.get("npc", null)
	if npc_data is Dictionary:
		var director: Node = get_parent().get_node_or_null("NpcDirector")
		if director == null:
			director = get_tree().get_first_node_in_group("npc_director")
		if director != null and director.has_method("load_save_data"):
			director.call("load_save_data", npc_data)
	last_error = ""
	_toast("Loaded.")
	return true


func _spot_free(p: Vector3) -> bool:
	var space := _player.get_world_3d().direct_space_state
	var sphere := SphereShape3D.new()
	sphere.radius = 0.45
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sphere
	params.collision_mask = 1
	params.exclude = [_player.get_rid(), _van.get_rid()]
	# Player origin is at the feet: probe the capsule volume, not the floor.
	params.transform = Transform3D(Basis(), p + Vector3(0, 0.9, 0))
	return _only_areas(space.intersect_shape(params, 8))


## Trigger volumes (contact/garage/entry/dock areas) are not geometry:
## only solid bodies block a spot.
func _only_areas(hits: Array) -> bool:
	for h in hits:
		var c: Object = (h as Dictionary).get("collider")
		if not (c is Area3D):
			return false
	return true


func _read_valid(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return false
	return _validate(parser.get_data()) == ""


func _ensure_dir() -> bool:
	var d := get_save_dir()
	if d == "" or DirAccess.open(d) != null:
		if d != "":
			return true
	if d == "":
		_fail("Save directory is empty; refusing to fall back to C:.")
		save_enabled = false
		return false
	if DirAccess.make_dir_recursive_absolute(d) != OK:
		_fail("Cannot create save directory; refusing to fall back to C:.")
		save_enabled = false
		return false
	return true


func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


func _yaw(n: Node3D) -> float:
	return n.global_rotation.y


func _fail(reason: String) -> void:
	last_error = reason
	push_error("SAVE: " + reason)
	_toast("Save/load failed: " + reason)


func _toast(text: String) -> void:
	var toast: Node = get_tree().get_first_node_in_group("toast")
	if toast != null and toast.has_method("show_message"):
		toast.show_message(text)
