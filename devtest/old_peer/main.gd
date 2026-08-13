extends Node
# Dev tool. Stands in for a peer too old to speak this build's handshake: it
# opens an ENet connection to a host, says nothing whatsoever, and leaves. That
# is exactly what a v1.1.3-or-earlier joiner looks like from the host's side --
# its "let me in" lands on a call that has since moved, Godot drops it, and the
# host hears nothing but the socket. Reproducing it this way saves building an
# old exe, and needs no copy of the game at all.
#
#   ..\.cache\godot-4.4.1-stable\Godot_v4.4.1-stable_win64_console.exe ^
#       --headless --path devtest\old_peer -- 127.0.0.1 7654 3
#
# The three user args are address, port and how long to linger, and the linger
# is the whole point. Net.HANDSHAKE_TIMEOUT is 10 seconds, so:
#
#   3   leaves first. The host's watchdog never fires -- _on_peer_disconnected
#       has to be the one that speaks up. Up to v1.1.5 nothing did, which is the
#       hole v1.1.6 fills.
#   12  outstays the watchdog, so that fires instead and drops us.
#
# Either way the host's lobby should name the problem and the log should carry a
# matching line. Nothing should ever appear in the contestant list.


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var address: String = args[0] if args.size() > 0 else "127.0.0.1"
	var port: int = int(args[1]) if args.size() > 1 else 7654
	var linger: float = float(args[2]) if args.size() > 2 else 3.0

	var peer: = ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(address, port)
	if err != OK:
		print("OLDPEER | could not open a socket to %s:%d (error %d)" % [address, port, err])
		get_tree().quit(1)
		return

	# defaults on both sides for channels and the range coder, which is what the
	# mod uses. mismatch either and the connection is refused before any of this
	# is interesting.
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected.bind(linger))
	multiplayer.connection_failed.connect(_on_failed)
	print("OLDPEER | dialling %s:%d" % [address, port])

	await get_tree().create_timer(linger).timeout
	print("OLDPEER | leaving without ever handshaking")
	peer.close()
	# let the close go out rather than killing the process under it.
	await get_tree().create_timer(0.5).timeout
	get_tree().quit()


func _on_connected(linger: float) -> void:
	print("OLDPEER | connected. saying nothing for %.1fs" % linger)


func _on_failed() -> void:
	print("OLDPEER | never got a connection. is the lobby open and hosting on that port?")
	get_tree().quit(1)
