class_name PlayerInfo
extends RefCounted

## One entry in the lobby roster.
##
## Godot's high-level multiplayer can only serialise built-in Variant types
## across an RPC, so this class never travels over the wire directly. It converts
## to and from a plain Dictionary at the network boundary via to_dict() /
## from_dict(), and every field is re-validated on the way in — a client is free
## to send whatever it likes, so nothing here may be trusted until the server has
## clamped it.

var peer_id: int = 0
var display_name: String = "Player"
var role: int = GameEnums.CrewRole.NONE
var is_ready: bool = false

## Which crew slot the server has assigned. -1 until the match starts. Drives
## spawn ordering and default seat, and is stable for the life of the match.
var crew_index: int = -1


func _init(p_peer_id: int = 0, p_display_name: String = "Player") -> void:
	peer_id = p_peer_id
	display_name = p_display_name


func duplicate_info() -> PlayerInfo:
	var copy := PlayerInfo.new(peer_id, display_name)
	copy.role = role
	copy.is_ready = is_ready
	copy.crew_index = crew_index
	return copy


func to_dict() -> Dictionary:
	return {
		"peer_id": peer_id,
		"display_name": display_name,
		"role": role,
		"is_ready": is_ready,
		"crew_index": crew_index,
	}


## Rebuild from a received Dictionary, coercing every field into range.
## A malformed or hostile payload yields a valid-but-boring PlayerInfo rather
## than propagating junk (or a type error) deeper into the game.
static func from_dict(data: Dictionary) -> PlayerInfo:
	var info := PlayerInfo.new()
	info.peer_id = int(data.get("peer_id", 0))
	info.display_name = clean_name(String(data.get("display_name", "Player")))
	info.role = clampi(int(data.get("role", GameEnums.CrewRole.NONE)),
		GameEnums.CrewRole.NONE, GameEnums.CrewRole.ENGINEER)
	info.is_ready = bool(data.get("is_ready", false))
	info.crew_index = clampi(int(data.get("crew_index", -1)), -1, NetConfig.MAX_PLAYERS - 1)
	return info


## Strip control characters and clamp length. Display names end up in the lobby
## list and the HUD, so a name containing newlines or BBCode-looking text would
## otherwise be able to disturb another player's UI.
static func clean_name(raw: String) -> String:
	var cleaned: String = ""
	for character in raw:
		var code: int = character.unicode_at(0)
		# Drop C0 controls, DEL, and the C1 range.
		if code < 32 or code == 127 or (code >= 128 and code <= 159):
			continue
		if character == "[" or character == "]":
			# RichTextLabel is used for the chat/roster; neutralise BBCode.
			continue
		cleaned += character
	cleaned = cleaned.strip_edges()
	if cleaned.is_empty():
		cleaned = "Player"
	if cleaned.length() > NetConfig.MAX_NAME_LENGTH:
		cleaned = cleaned.substr(0, NetConfig.MAX_NAME_LENGTH)
	return cleaned


func role_name() -> String:
	return GameEnums.role_name(role)
