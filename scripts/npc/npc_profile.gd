class_name NpcProfile
extends Resource
## Meridian Bay — pedestrian archetype data (Task 8, stage 8.0).
##
## A profile is pure data loaded from res://data/npc/pedestrian_profiles.json.
## One profile is shared by every pedestrian that uses that archetype, so the
## walk speed, idle window, colour and talk lines are identical for each of
## them and the behaviour stays deterministic (no per-instance randomness that
## is not driven by the director's seeded RNG).
##
## The profile also owns ONE shared StandardMaterial3D (see material_for())
## so that pedestrians of the same archetype batch into the same draw call.
## Creating a material per pedestrian would break batching and blow the
## +60 draw-call budget of the NPC foundation.

@export var id: String = "pedestrian"
@export var display_name: String = "Pedestrian"
## Metres per second along the ground plane.
@export var walk_speed: float = 1.30
## Inclusive [min, max] pause in seconds when a pedestrian reaches a waypoint.
@export var idle_seconds_min: float = 1.5
@export var idle_seconds_max: float = 4.0
## Linear RGB tint applied to the shared body material.
@export var wear_colour: Color = Color(0.55, 0.55, 0.60)
## When true the pedestrian steers out of the player's way.
@export var avoid_player: bool = true
@export var talk_lines: Array[String] = []

## Lazily created shared material (one per archetype).
var _material: StandardMaterial3D = null


## Builds a profile from a parsed JSON dictionary.
## Missing or malformed keys fall back to the class defaults so a broken data
## file can never crash the NPC director.
static func from_dict(d: Dictionary) -> NpcProfile:
	var p := NpcProfile.new()
	p.id = str(d.get("id", p.id))
	p.display_name = str(d.get("display_name", p.id))
	p.walk_speed = maxf(0.0, float(d.get("walk_speed", p.walk_speed)))
	var idle: Array = d.get("idle_seconds", []) if d.has("idle_seconds") else []
	if idle.size() == 2:
		p.idle_seconds_min = maxf(0.0, float(idle[0]))
		p.idle_seconds_max = maxf(p.idle_seconds_min, float(idle[1]))
	p.wear_colour = _colour_from(d.get("wear_colour", null), p.wear_colour)
	p.avoid_player = bool(d.get("avoid_player", p.avoid_player))
	var lines: Array = d.get("talk_lines", [])
	for line in lines:
		p.talk_lines.append(str(line))
	return p


## The archetype's shared body material (created once, reused by every
## pedestrian of this archetype).
func material_for() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.albedo_color = wear_colour
		_material.roughness = 0.9
	return _material


## A random idle duration for this archetype, in seconds.
func idle_seconds(rng: RandomNumberGenerator) -> float:
	if idle_seconds_max <= idle_seconds_min:
		return idle_seconds_min
	return rng.randf_range(idle_seconds_min, idle_seconds_max)


static func _colour_from(value: Variant, fallback: Color) -> Color:
	if value == null:
		return fallback
	if value is Array and (value as Array).size() >= 3:
		var a: Array = value
		return Color(float(a[0]), float(a[1]), float(a[2]))
	if value is String:
		return Color(str(value))
	return fallback
