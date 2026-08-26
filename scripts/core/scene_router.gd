extends Node

## Autoload: SceneRouter
##
## Owns the single "current screen" slot beneath Main and swaps it safely.
##
## Godot's `get_tree().change_scene_to_file()` replaces the *whole* scene tree
## root, which would tear down anything parented under it. This project keeps the
## networking peer and the screen side by side under `Main`, so screens are
## swapped inside a container node instead and the network session survives the
## transition from lobby to level.
##
## Swaps are deferred by one frame. Freeing a node from inside one of its own
## signal handlers (which is exactly how "Start Match" reaches this code) is a
## use-after-free waiting to happen; `queue_free()` plus a deferred instantiate
## makes the ordering explicit and safe.

const MAIN_MENU_SCENE: String = "res://scenes/ui/main_menu.tscn"
const LOBBY_SCENE: String = "res://scenes/ui/lobby.tscn"
const TEST_ARENA_SCENE: String = "res://scenes/maps/test_arena.tscn"

## Emitted after the new screen has entered the tree.
signal screen_changed(scene_path: String)

var _container: Node = null
var _current: Node = null
var _current_path: String = ""
var _pending_path: String = ""


## Main calls this once, handing over the node that screens are parented to.
func register_container(container: Node) -> void:
	_container = container
	GameLog.info("router", "container registered: %s" % container.get_path())


func current_scene_path() -> String:
	return _current_path


func current_screen() -> Node:
	return _current


## Replace the current screen with the scene at `scene_path`.
## Safe to call from within a signal handler of the outgoing screen.
func go_to(scene_path: String) -> void:
	if _container == null:
		GameLog.error("router", "go_to(%s) before a container was registered" % scene_path)
		return
	if scene_path == _pending_path:
		return
	_pending_path = scene_path
	_swap.call_deferred(scene_path)


func _swap(scene_path: String) -> void:
	if not is_instance_valid(_container):
		GameLog.error("router", "container disappeared before swap to %s" % scene_path)
		_pending_path = ""
		return

	if is_instance_valid(_current):
		_current.queue_free()
		# Detach immediately so lookups during the same frame do not find a node
		# that is already scheduled for deletion.
		_container.remove_child(_current)
	_current = null

	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		GameLog.error("router", "failed to load scene: %s" % scene_path)
		_pending_path = ""
		return

	var instance: Node = packed.instantiate()
	_container.add_child(instance)
	_current = instance
	_current_path = scene_path
	_pending_path = ""

	GameLog.info("router", "screen -> %s" % scene_path)
	screen_changed.emit(scene_path)
