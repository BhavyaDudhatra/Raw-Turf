class_name MissionContact
extends Interactable
## Meridian Bay — courier contact with mission flow (Task 4).
## Reuses the Task 2 proximity prompt. Each E press routes by mission state:
## AVAILABLE -> accept (intentional opt-in, never proximity auto-start),
## ACTIVE -> status/objective reminder, COMPLETED -> finished message.
## The prompt label itself reflects the current state.

func interact() -> void:
	times_activated += 1
	var mission: Node = get_tree().get_first_node_in_group("mission")
	if mission == null:
		push_error("CONTACT: no mission in group 'mission'.")
		return
	var st := int(mission.get("state"))
	if st == 0: # AVAILABLE
		mission.call("accept_mission")
	elif st == 1: # ACTIVE
		_show(String(mission.call("status_text")))
	else: # COMPLETED
		_show(String(mission.call("status_text")))


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	var mission: Node = get_tree().get_first_node_in_group("mission")
	if mission != null and _prompt != null and _prompt.visible:
		var st := int(mission.get("state"))
		if st == 0:
			_prompt.text = "E — Accept delivery (HB-01)"
		elif st == 1:
			_prompt.text = "E — Mission status"
		else:
			_prompt.text = "E — Courier Rana"


func _show(text: String) -> void:
	var toast: Node = get_tree().get_first_node_in_group("toast")
	if toast != null and toast.has_method("show_message"):
		toast.show_message(text)
