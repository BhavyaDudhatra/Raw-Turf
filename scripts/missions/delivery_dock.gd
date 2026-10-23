class_name DeliveryDock
extends Area3D
## Meridian Bay — HB-01 destination trigger (Task 4).
## Fires only for the designated courier van (group `courier_van`) and only
## via MissionController.try_complete(), which re-validates ACTIVE state and
## single payment. On-foot entry, pre-acceptance drive-ins, unrelated bodies
## and repeat visits are all no-ops. Safe exit from the van nearby stays valid
## because completion is event-driven, not presence-polled.

@export var dock_name: String = "Pier 9 Dock"

@onready var _beacon: MeshInstance3D = $Beacon


func _ready() -> void:
	add_to_group("delivery_dock")
	collision_layer = 0
	collision_mask = 1
	body_entered.connect(_on_body_entered)
	set_marker(false)


const COOLDOWN_FRAMES := 180  # 3 s at 60 Hz physics.

var _last_key := ""
var _last_frame := -100000


func _toast_key(body_kind: String, state: int) -> String:
	return "%s:%d" % [body_kind, state]


func _say(key: String, text: String) -> void:
	var now := Engine.get_physics_frames()
	if key == _last_key and now - _last_frame < COOLDOWN_FRAMES:
		return
	_last_key = key
	_last_frame = now
	var toast: Node = get_tree().get_first_node_in_group("toast")
	if toast != null and toast.has_method("show_message"):
		toast.call("show_message", text)


func _mission_state() -> int:
	var mission: Node = get_tree().get_first_node_in_group("mission")
	if mission == null:
		return -1
	return int(mission.get("state"))


func _on_body_entered(body: Node3D) -> void:
	var st := _mission_state()
	if body.is_in_group("courier_van"):
		if st == 1:  # ACTIVE: identical completion path to production.
			var mission: Node = get_tree().get_first_node_in_group("mission")
			if mission != null and mission.has_method("try_complete"):
				if bool(mission.call("try_complete")):
					print("DOCK: delivery completed by ", body.name)
					return  # success toast comes from the mission itself.
			_say(_toast_key("van", st), "DOCK: delivery not accepted (state=%d)." % st)
		elif st == 0:  # AVAILABLE
			_say(_toast_key("van", st), "DOCK: finish HB-01 first — talk to Courier Rana (E).")
		else:  # COMPLETED or other
			_say(_toast_key("van", st), "DOCK: delivery already completed. Nice driving.")
	elif body.is_in_group("player"):
		_say(_toast_key("foot", st), "DOCK: bring the courier van onto this pad.")


func set_marker(active: bool) -> void:
	if _beacon != null:
		_beacon.visible = active
