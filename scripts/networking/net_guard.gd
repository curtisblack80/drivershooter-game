class_name NetGuard
extends RefCounted

## Sender validation helpers for RPCs.
##
## Godot's `@rpc` annotation controls *who may invoke* a method, but only in two
## coarse modes: "authority" (the node's authority only) and "any_peer" (anyone).
## Several systems here need a third thing — "the server only" — on nodes whose
## authority is a *client*. The vehicle is the clearest case: its multiplayer
## authority is the driver's peer, so a `@rpc("authority")` method on it could not
## be called by the server at all, and `@rpc("any_peer")` would let any client
## call it. These helpers close that gap with an explicit sender check.
##
## Every "any_peer" RPC in this project must begin with one of these checks, or
## with its own deliberate validation of the sender.


## True when the RPC currently executing originated from the server.
##
## `get_remote_sender_id()` returns 0 for a locally-executed call (which is what
## `call_local` and self-targeted `rpc_id` produce), so a local call only counts
## as coming from the server when we *are* the server.
static func is_from_server(node: Node) -> bool:
	var sender: int = node.multiplayer.get_remote_sender_id()
	if sender == 1:
		return true
	return sender == 0 and node.multiplayer.is_server()


## True when the RPC originated from the peer that owns `node`.
## Used to reject snapshots for an object from anyone but its authority — without
## this, any client could stream positions for the vehicle it does not drive.
static func is_from_authority_of(node: Node) -> bool:
	var sender: int = node.multiplayer.get_remote_sender_id()
	if sender == 0:
		return node.is_multiplayer_authority()
	return sender == node.get_multiplayer_authority()


## The peer that invoked the currently-executing RPC, with local calls resolved
## to this peer's own id instead of 0. Use when you need the acting player's
## identity and do not care whether the call arrived over the wire.
static func effective_sender(node: Node) -> int:
	var sender: int = node.multiplayer.get_remote_sender_id()
	if sender == 0:
		return node.multiplayer.get_unique_id()
	return sender
