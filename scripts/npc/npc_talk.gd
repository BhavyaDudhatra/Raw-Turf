class_name NpcTalk
extends Interactable
## Meridian Bay — talk to a pedestrian (Task 8).
##
## A thin extension of the existing Interactable contract (Area3D on layer 0
## with mask 2, so only the player is detected). It lives on the pedestrian's
## child "TalkRange" area, keeps the shared prompt behaviour and answers with
## a line taken from the pedestrian's archetype.
##
## Stage 8.3: deterministic one-shot response per press, cycling through the
## archetype lines. Does not touch mission, wallet, controls or save data.

## Lines this NPC can say (copied from the archetype profile on setup).
var talk_lines: Array[String] = []
## Index of the next line to use, so replies cycle deterministically.
var talk_index: int = 0


func _ready() -> void:
	# Ensure the prompt node exists (mirrors Interactable expectations).
	if not has_node("Prompt"):
		var p := Label3D.new()
		p.name = "Prompt"
		p.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		p.no_depth_test = true
		p.pixel_size = 0.01
		p.font_size = 42
		p.outline_size = 10
		p.outline_modulate = Color(0, 0, 0, 1)
		p.modulate = Color(1, 0.9, 0.3, 1)
		p.visible = false
		p.position = Vector3(0, 2.2, 0)
		add_child(p)
	super._ready()
	if talk_lines.is_empty() and response_text.is_empty():
		response_text = "..."
	if _prompt != null and talk_lines.is_empty():
		# Fallback prompt/response kept compatible with existing behaviour.
		pass


## Sets the lines this NPC may say.
func set_talk_lines(lines: Array[String]) -> void:
	talk_lines = lines.duplicate()
	talk_index = 0
	if not talk_lines.is_empty() and response_text.is_empty():
		response_text = talk_lines[0]


## The line that would be spoken next (without consuming it).
func peek_line() -> String:
	if talk_lines.is_empty():
		return response_text
	return talk_lines[talk_index % talk_lines.size()]


func interact() -> void:
	if not talk_lines.is_empty():
		response_text = talk_lines[talk_index % talk_lines.size()]
		talk_index += 1
	else:
		talk_index += 1
	times_activated += 1
	var toast: Node = get_tree().get_first_node_in_group("toast")
	if toast != null and toast.has_method("show_message"):
		toast.show_message(response_text)
	print("INTERACT: ", name, " activated x", times_activated)
