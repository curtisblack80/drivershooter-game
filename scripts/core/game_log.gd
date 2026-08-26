extends Node

## Autoload: GameLog
##
## Structured logging with a peer-id prefix.
##
## Debugging a four-peer session means reading four interleaved output streams.
## Every line this emits is tagged with the peer's network identity and the
## subsystem that produced it, so a copy-pasted log from a playtester can be
## untangled after the fact:
##
##     [S ][vehicle] authority handed to peer 3
##     [C2][crew   ] traversal begin: window_left -> hood
##
## "S" is the server/host, "Cn" is client peer n, "--" is offline (no peer yet).

enum Level {
	DEBUG = 0,
	INFO = 1,
	WARN = 2,
	ERROR = 3,
}

## Lines below this level are dropped. Raise to Level.WARN for playtest builds.
var min_level: Level = Level.INFO

## Subsystems listed here are muted regardless of level. Useful for silencing a
## chatty system while hunting a bug elsewhere, e.g. add "netsync".
var muted_tags: Array[String] = []

const _LEVEL_LABELS: Dictionary = {
	Level.DEBUG: "DBG",
	Level.INFO: "INF",
	Level.WARN: "WRN",
	Level.ERROR: "ERR",
}


func debug(tag: String, message: String) -> void:
	_emit(Level.DEBUG, tag, message)


func info(tag: String, message: String) -> void:
	_emit(Level.INFO, tag, message)


func warn(tag: String, message: String) -> void:
	_emit(Level.WARN, tag, message)


func error(tag: String, message: String) -> void:
	_emit(Level.ERROR, tag, message)


## Returns a short identity for this peer, e.g. "S", "C3" or "--".
func peer_label() -> String:
	if multiplayer == null or multiplayer.multiplayer_peer == null:
		return "--"
	# A peer that has not finished connecting reports id 0.
	var id: int = multiplayer.get_unique_id()
	if id == 0:
		return "??"
	if id == 1:
		return "S"
	return "C%d" % id


func _emit(level: Level, tag: String, message: String) -> void:
	if level < min_level:
		return
	if muted_tags.has(tag):
		return

	var line: String = "[%s][%-7s][%s] %s" % [
		peer_label(),
		tag,
		_LEVEL_LABELS.get(level, "???"),
		message,
	]

	# push_error / push_warning also surface in the editor's Debugger panel and
	# in stack traces, which is where these belong.
	match level:
		Level.ERROR:
			push_error(line)
			printerr(line)
		Level.WARN:
			push_warning(line)
			print(line)
		_:
			print(line)
