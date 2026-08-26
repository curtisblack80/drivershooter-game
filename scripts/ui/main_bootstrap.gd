extends Node

## Root of the application. Holds the screen slot and starts on the main menu.
##
## The network peer lives in an autoload, not under the screen slot, so swapping
## from the lobby to the level never tears the session down. This node exists
## purely to give SceneRouter something stable to parent screens to.

@onready var _screen: Node = $Screen


func _ready() -> void:
	GameLog.info("boot", "Driver Shooter %s starting"
		% ProjectSettings.get_setting("application/config/version", "?"))
	SceneRouter.register_container(_screen)
	SceneRouter.go_to(SceneRouter.MAIN_MENU_SCENE)


func _notification(what: int) -> void:
	# Close the ENet peer explicitly on quit so the other peers see a clean
	# disconnect rather than waiting out a timeout.
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if NetworkManager.is_session_active():
			NetworkManager.leave_session()
