class_name Interactable
extends Area3D
## Meridian Bay — reusable interaction target (Task 2).
## Proximity (Area3D on mask 2 = player layer) shows a Label3D prompt;
## pressing the `interact` action (E) fires exactly once per key press.
## Feedback goes through the `toast` group — no autoloads, no direct refs.
## Future targets (doors, vehicles, NPCs, mission contacts) extend this.

@export var prompt_text: String = "E — Interact"
@export_multiline var response_text: String = ""

## Counts successful activations; used by automated tests.
var times_activated: int = 0

var _player_in_range: bool = false
var _was_pressed: bool = false

@onready var _prompt: Label3D = $Prompt


func _ready() -> void:
	collision_layer = 0
	collision_mask = 2
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	if _prompt != null:
		_prompt.text = prompt_text
		_prompt.visible = false


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player"):
		_player_in_range = true
		if _prompt != null:
			_prompt.visible = true


func _on_body_exited(body: Node3D) -> void:
	if body.is_in_group("player"):
		_player_in_range = false
		if _prompt != null:
			_prompt.visible = false


func _physics_process(_delta: float) -> void:
	# Edge-detect the action state instead of consuming input events: one
	# activation per press, no auto-repeat on held keys, and testable with
	# synthetic Input.action_press() (which generates state, not events).
	var pressed := Input.is_action_pressed("interact")
	if _player_in_range and pressed and not _was_pressed:
		interact()
	_was_pressed = pressed


func interact() -> void:
	times_activated += 1
	var toast: Node = get_tree().get_first_node_in_group("toast")
	if toast != null and toast.has_method("show_message"):
		toast.show_message(response_text)
	print("INTERACT: ", name, " activated x", times_activated)
