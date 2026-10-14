class_name VanEntry
extends Interactable
## Meridian Bay — van entry point (Task 3).
## Reuses the Task 2 Interactable proximity prompt, but activation requests a
## seat in the VehicleSystem instead of showing a toast. The request is
## refused (returns false, no count) unless the system is ON_FOOT, so the
## same E press that exits the van can never instantly re-enter it.

func interact() -> void:
	var sys: Node = get_tree().get_first_node_in_group("vehicle_system")
	if sys != null and sys.has_method("request_enter"):
		if bool(sys.call("request_enter")):
			times_activated += 1
			print("INTERACT: ", name, " entered van x", times_activated)
