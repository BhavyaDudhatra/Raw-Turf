class_name BuildingBlock
extends StaticBody3D
## Meridian Bay — modular blockout building (Task 2).
## A unit-box collision shape and meshes are scaled from exports in _ready,
## so every instance in main.tscn only sets size + colors. Collision and all
## visuals are generated from primitives; no external assets.

@export var size: Vector3 = Vector3(8, 6, 8)
@export var wall_color: Color = Color(0.6, 0.3, 0.25)
@export var trim_color: Color = Color(0.2, 0.2, 0.22)
@export var door_color: Color = Color(0.1, 0.1, 0.12)
@export var door_width: float = 1.8

@onready var _collision: CollisionShape3D = $Collision
@onready var _body: MeshInstance3D = $Body
@onready var _roof: MeshInstance3D = $Roof
@onready var _door: MeshInstance3D = $Door


func _ready() -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	_collision.shape = shape
	_collision.position = Vector3(0, size.y * 0.5, 0)
	_body.scale = size
	_body.position = Vector3(0, size.y * 0.5, 0)
	_body.material_override = _make_mat(wall_color)
	_roof.scale = Vector3(size.x + 0.5, 0.4, size.z + 0.5)
	_roof.position = Vector3(0, size.y + 0.2, 0)
	_roof.material_override = _make_mat(trim_color)
	_door.scale = Vector3(door_width, 2.3, 0.15)
	_door.position = Vector3(0, 1.15, -size.z * 0.5 - 0.04)
	_door.material_override = _make_mat(door_color)


func _make_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	return m
