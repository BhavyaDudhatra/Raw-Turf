extends CanvasLayer
## Lightweight developer overlay (Task 1). Shows FPS, player position and
## movement mode. Disable later by setting `enabled = false` in the inspector
## or by toggling it at runtime with F3.

@export var enabled: bool = true
@export var refresh_interval: float = 0.15

@onready var label: Label = $Label

var _player: CharacterBody3D
var _timer: float = 0.0


func _ready() -> void:
	visible = enabled
	# Main scene owns both this overlay and the Player instance.
	_player = get_parent().get_node_or_null("Player") as CharacterBody3D


func _process(delta: float) -> void:
	_timer += delta
	if _timer < refresh_interval:
		return
	_timer = 0.0
	if _player == null or label == null:
		return
	var mode := String(_player.get("movement_mode"))
	var p := _player.global_position
	label.text = "FPS: %d\nPos: (%.1f, %.1f, %.1f)\nMode: %s" % [
		Engine.get_frames_per_second(), p.x, p.y, p.z, mode]


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.physical_keycode == KEY_F3:
			enabled = not enabled
			visible = enabled
