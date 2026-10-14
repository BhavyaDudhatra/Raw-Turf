extends CanvasLayer
## Meridian Bay — transient message toast (Task 2).
## Interactables call show_message() via the `toast` group.
## `last_message` is read by automated tests. Auto-hides after a few seconds.

@export var visible_seconds: float = 4.0

var last_message: String = ""

@onready var _label: Label = $Label

var _timer: float = 0.0


func _ready() -> void:
	add_to_group("toast")
	if _label != null:
		_label.visible = false


func show_message(text: String) -> void:
	last_message = text
	if _label != null:
		_label.text = text
		_label.visible = true
	_timer = visible_seconds


func _process(delta: float) -> void:
	if _timer > 0.0:
		_timer -= delta
		if _timer <= 0.0 and _label != null:
			_label.visible = false
