class_name NpcPedestrian
extends NpcBase
## Meridian Bay — the Harbor Row pedestrian (Task 8).
##
## A pedestrian is an NpcBase with:
##   * an archetype profile (speed, idle window, colour, talk lines),
##   * a shared archetype material, so pedestrians of the same archetype
##     batch into the same draw call and the +60 draw-call budget holds.
##
## The collision shape and the visual meshes live in
## res://scenes/npcs/npc_pedestrian.tscn so the physics footprint can be
## reviewed in one place. The pedestrian body is on collision layer 9
## (world layer 1 + pedestrian layer 8) with mask 9: it collides with the
## world and with other pedestrians, and the player (layer 2, mask 1) and the
## van (layer 5, mask 1) collide with it without any change to their own
## configuration.

## The archetype this pedestrian was built from.
var profile: NpcProfile = null
## The archetype's shared material (assigned to every visual mesh).
var body_material: StandardMaterial3D = null

## One merged visual mesh shared by every pedestrian in the scene.
## The sun renders four shadow splits, so every visible mesh is drawn up to
## five times per frame (four shadow passes + the colour pass). Two meshes
## per pedestrian therefore cost about ten draw calls each; one merged mesh
## costs about five, which is what keeps the population inside the
## +60 draw-call budget. The geometry itself is unchanged.
static var _shared_visual_mesh: ArrayMesh = null


func _ready() -> void:
	super._ready()
	# The scene ships a default material; apply_profile replaces it with the
	# archetype's shared material so same-archetype pedestrians batch.
	if body_material != null:
		_apply_material(body_material)
	_merge_visual()


## Collapses the body and head meshes into one shared mesh.
##
## The geometry is the same capsule plus the same sphere; only the number of
## meshes (and therefore draw calls) changes.
func _merge_visual() -> void:
	var visual := get_node_or_null("Visual")
	if visual == null:
		return
	var body := visual.get_node_or_null("Body") as MeshInstance3D
	var head := visual.get_node_or_null("Head") as MeshInstance3D
	if body == null or head == null or body.mesh == null or head.mesh == null:
		return
	if _shared_visual_mesh == null:
		_shared_visual_mesh = _build_merged_visual(
			body.mesh, head.mesh, head.transform * body.transform.affine_inverse())
	if _shared_visual_mesh == null:
		return
	body.mesh = _shared_visual_mesh
	# The head is now part of the merged mesh.
	if head != null:
		head.visible = false
	# Apply the current archetype material to the merged mesh too.
	if body_material != null:
		body.material_override = body_material


## Builds one mesh that contains the body capsule and the head sphere.
static func _build_merged_visual(body: Mesh, head: Mesh, head_local: Transform3D) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(body, 0, Transform3D.IDENTITY)
	st.append_from(head, 0, head_local)
	return st.commit()


## Applies an archetype profile to this pedestrian.
func apply_profile(p: NpcProfile) -> void:
	if p == null:
		return
	profile = p
	walk_speed = p.walk_speed
	body_material = p.material_for()
	_apply_material(body_material)
	idle_duration_provider = Callable(self, "_profile_idle_seconds")
	# Wire the talk lines into the interaction area (stage 8.3).
	var talk := get_node_or_null("TalkRange") as NpcTalk
	if talk != null:
		var lines: Array[String] = []
		for s in p.talk_lines:
			lines.append(str(s))
		talk.set_talk_lines(lines)
		if lines.is_empty():
			talk.prompt_text = "E — Talk"
			talk.response_text = "..."
		else:
			talk.prompt_text = "E — Talk"
			talk.response_text = lines[0]


## The archetype's pause duration at a waypoint (deterministic per
## pedestrian, because the RNG is seeded by the director).
func _profile_idle_seconds() -> float:
	if profile == null:
		return 2.0
	return profile.idle_seconds(rng)


func _apply_material(mat: StandardMaterial3D) -> void:
	if mat == null:
		return
	var visual := get_node_or_null("Visual")
	if visual == null:
		return
	for child in visual.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).material_override = mat
