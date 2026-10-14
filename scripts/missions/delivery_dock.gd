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


func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("courier_van"):
		return
	var mission: Node = get_tree().get_first_node_in_group("mission")
	if mission == null:
		push_error("DOCK: no mission in group 'mission'.")
		return
	if mission.has_method("try_complete"):
		if bool(mission.call("try_complete")):
			print("DOCK: delivery completed by ", body.name)


func set_marker(active: bool) -> void:
	if _beacon != null:
		_beacon.visible = active
