class_name MissionController
extends Node
## Meridian Bay — HB-01 mission state + wallet (Task 4).
## Explicit AVAILABLE -> ACTIVE -> COMPLETED model. Transitions happen only
## through accept_mission() (courier contact, intentional E press) and
## try_complete() (delivery dock, validated van entry). No timers, no autoload.
## The wallet is session-only: no save system exists yet (scripts/save/ is
## empty), so the balance is kept in memory and exposed for tests.

enum State { AVAILABLE, ACTIVE, COMPLETED }

@export var mission_id: String = "HB-01"
@export var mission_name: String = "The Harbor Delivery"
@export var destination_name: String = "Pier 9 Dock"
@export var reward_credits: int = 150

var state: int = State.AVAILABLE
var balance: int = 0
var reward_paid: bool = false

## Physics-frame deadline before which try_complete() refuses (used across
## save/load restoration so a van restored inside the dock cannot auto-complete).
var _suppress_until_frame: int = -1

var _hud_label: Label
var _player: Node3D
var _van: Node3D
var _sys: Node
var _dock: Node3D


func _ready() -> void:
	add_to_group("mission")
	_hud_label = get_parent().get_node_or_null("MissionHUD/Label") as Label
	_player = get_parent().get_node_or_null("Player") as Node3D
	_van = get_parent().get_node_or_null("Van") as Node3D
	_sys = get_parent().get_node_or_null("VehicleSystem")
	_dock = get_parent().get_node_or_null("DeliveryDock") as Node3D
	if _hud_label == null:
		push_warning("MISSION: MissionHUD/Label missing — HUD disabled, logic unaffected.")
	_update_hud()


func accept_mission() -> bool:
	if state != State.AVAILABLE:
		return false
	state = State.ACTIVE
	_set_beacon(true)
	_toast("HB-01 ACCEPTED: Take the courier van to %s." % destination_name)
	_update_hud()
	return true


func try_complete() -> bool:
	if Engine.get_physics_frames() < _suppress_until_frame:
		return false
	if state != State.ACTIVE or reward_paid:
		return false
	state = State.COMPLETED
	reward_paid = true
	balance += reward_credits
	_set_beacon(false)
	_toast("DELIVERED: %s complete! +%dcr (balance %dcr)." % [mission_id, reward_credits, balance])
	_update_hud()
	return true


## Restoration entry for the save system: sets state WITHOUT toasts or
## gameplay events, then recomputes beacon + HUD. Caller pre-validates.
func apply_loaded_state(p_state: int, p_balance: int, p_paid: bool) -> void:
	state = clampi(p_state, State.AVAILABLE, State.COMPLETED)
	balance = maxi(p_balance, 0)
	reward_paid = p_paid or state == State.COMPLETED
	_set_beacon(state == State.ACTIVE)
	_update_hud()


## Ignore dock completions for the next few physics frames (restore window).
func suppress_completion(frames: int) -> void:
	_suppress_until_frame = Engine.get_physics_frames() + frames


func status_text() -> String:
	match state:
		State.AVAILABLE:
			return "COURIER RANA: One package, %s. Good pay. Press E to accept." % destination_name
		State.ACTIVE:
			return "HB-01 ACTIVE: Drive the van to %s." % destination_name
		_:
			return "COURIER RANA: Delivery done. Pleasure doing business."


func get_objective_text() -> String:
	match state:
		State.AVAILABLE:
			return "%s: %s — Talk to Courier Rana (E)" % [mission_id, mission_name]
		State.ACTIVE:
			return "%s: Deliver to %s — %s" % [mission_id, destination_name, _distance_text()]
		_:
			return "%s: COMPLETE — +%dcr (balance %dcr)" % [mission_id, reward_credits, balance]


func _process(_delta: float) -> void:
	if state == State.ACTIVE:
		_update_hud()


func _distance_text() -> String:
	if _dock == null:
		return "--"
	var from: Node3D = _van
	if _sys == null or int(_sys.get("mode")) != 1 or _van == null:
		from = _player
	if from == null:
		return "--"
	var a := Vector2(from.global_position.x, from.global_position.z)
	var b := Vector2(_dock.global_position.x, _dock.global_position.z)
	return "%dm" % int(a.distance_to(b))


func _set_beacon(active: bool) -> void:
	var dock := get_tree().get_first_node_in_group("delivery_dock")
	if dock != null and dock.has_method("set_marker"):
		dock.call("set_marker", active)


func _update_hud() -> void:
	if _hud_label != null:
		_hud_label.text = get_objective_text()


func _toast(text: String) -> void:
	var toast: Node = get_tree().get_first_node_in_group("toast")
	if toast != null and toast.has_method("show_message"):
		toast.show_message(text)
