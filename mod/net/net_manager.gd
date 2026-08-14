extends Node
# ENet client/server, host authoritative. host is always slot 0.

signal player_list_changed
signal connection_failed(reason: String)
signal connected_to_lobby
signal server_disconnected
# something the host needs telling that happened to somebody else, eg a joiner
# turned away. the person it concerns is not the one looking at this screen.
signal host_notice(text: String)
signal match_should_start(clip_paths: PackedStringArray)
signal performance_received(slot: int)
signal scores_received(scores: PackedInt32Array)

# shown in the lobby and the log, so two people can compare builds. bump it for
# anything that goes out, even when the protocol below does not move: two builds
# that behave differently and both call themselves 1.1.5 make the one question
# worth asking -- "what does yours say?" -- impossible to answer.
const MOD_VERSION: String = "1.1.7"

const PORT: int = 7654
const MAX_PLAYERS: int = 4
# 6: the dub watch goes through the host now, which took two new @rpc methods.
# Both are named _rpc_* so the handshake still sorts first and a 1.1.6 joiner is
# told what is wrong rather than hanging -- but every call index after them has
# moved, so 5 and 6 genuinely cannot play together.
# 5: the join handshake moved off _rpc_register onto _HANDSHAKE, see the long
# note above it. builds on 4 and below cannot be negotiated with at all, which
# is the entire reason it had to move. 1.1.6 stayed on 5 deliberately: it added a
# key to the handshake payload and no @rpc at all, so the sorted call list was
# identical to 1.1.4's and 1.1.5's and all three still played together.
# 4: pack hashes cover the contents of a pack and not the folder name, so the
# manifest from an older build would compare against nothing and read as a
# missing pack. better to say so than to let it look broken.
const PROTOCOL_VERSION: int = 6
const CHUNK_SIZE: int = 24576
const PERFORMANCE_TIMEOUT: float = 60.0
const BARRIER_TIMEOUT: float = 90.0
# how long either end waits on the join handshake before saying so. the work
# behind it is a dictionary and two rpcs, so anything approaching this is not
# slowness, it is a peer that cannot be talked to.
const HANDSHAKE_TIMEOUT: float = 10.0

# ENet drops a peer that stops acking for 30s by default. Loading a match scene
# blocks whichever machine is doing it -- the studio model, the contestant packs
# and the dub video all load on the main thread inside the base game, where the
# mod can't yield for them -- and on a slow disk that alone can outlast 30s and
# take the lobby down with it. Given a barrier waits 90s before it gives up on
# somebody, the connection has no business dying before then.
const PEER_TIMEOUT_LIMIT: int = 32
const PEER_TIMEOUT_MIN: int = 15000
const PEER_TIMEOUT_MAX: int = 90000


func log_net(msg: String) -> void:
	print("[NET %s] %s" % [Time.get_time_string_from_system(), msg])

enum MODE {OFFLINE, HOST, CLIENT}

var mode: MODE = MODE.OFFLINE
var players: Dictionary = {}
var slot_map: PackedInt32Array = []

# peer -> voice pack summary. kept out of the roster because the roster is
# resent every time anyone ticks Ready, and this only changes when someone
# joins or leaves.
var manifests: Dictionary = {}

var _perf_inbox: Dictionary = {}
var _perf_staging: Dictionary = {}
var _barriers: Dictionary = {}
# tags already released. without this a latecomer recreates an entry nothing erases.
var _barriers_done: Dictionary = {}

# bumped every show. round state is keyed by round number and slot, both of which
# restart at zero, so without a stamp the leftovers of a finished match look
# exactly like the new one.
var session_id: int = 0


func is_online() -> bool: return mode != MODE.OFFLINE
func is_host() -> bool: return mode == MODE.HOST
func my_id() -> int: return multiplayer.get_unique_id() if is_online() else 1
func slot_count() -> int: return slot_map.size()


func peer_for_slot(slot: int) -> int:
	if slot < 0 or slot >= slot_map.size(): return 0
	return slot_map[slot]


func slot_for_peer(peer: int) -> int:
	for i: int in slot_map.size():
		if slot_map[i] == peer: return i
	return -1


func my_slot() -> int: return slot_for_peer(my_id())
func is_my_slot(slot: int) -> bool: return peer_for_slot(slot) == my_id()


func player_name_for_slot(slot: int) -> String:
	var peer: int = peer_for_slot(slot)
	if players.has(peer): return players[peer].get("name", "Player")
	return "Player"




func host_game(player_name: String, pack: String, port: int = PORT) -> Error:
	var peer: = ENetMultiplayerPeer.new()
	var err: Error = peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		log_net("FAILED to open port %d (error %d)" % [port, err])
		connection_failed.emit("Could not open port %d. Is another copy already hosting?" % port)
		return err
	multiplayer.multiplayer_peer = peer
	mode = MODE.HOST
	log_net("hosting on UDP %d as '%s'" % [port, player_name])
	_wire_signals()
	players.clear()
	manifests.clear()
	players[1] = _make_record(player_name, pack)
	manifests[1] = voice_pack_manifest()
	_rebuild_slots()
	player_list_changed.emit()
	return OK


# every address a joiner might be asked to type, with the one that works marked.
# on Hamachi or Radmin it is theirs, never the public IP people go and look up.
func addresses_to_give_out() -> String:
	var lines: PackedStringArray = []
	for address: String in IP.get_local_addresses():
		# IPv4 only here, and link-local means the adapter never got a lease.
		if address.contains(":"): continue
		if address.begins_with("127.") or address.begins_with("169.254."): continue
		lines.append("    %s%s" % [address, _address_hint(address)])
	if lines.is_empty(): return "    (no network address found on this machine)"
	return "\n".join(lines)


func _address_hint(address: String) -> String:
	if address.begins_with("25."): return "   <- Hamachi. Use this one."
	if address.begins_with("26."): return "   <- Radmin VPN. Use this one."
	if address.begins_with("192.168.") or address.begins_with("10."):
		return "   (only works for someone on your own wifi)"
	return ""


func join_game(address: String, player_name: String, pack: String, port: int = PORT) -> Error:
	# before the socket, not after. this walks every voice pack on the disk, and
	# once we are connected the only place left to do it is inside the multiplayer
	# poll, where it stalls the handshake it is holding up.
	voice_pack_manifest()
	var peer: = ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(address, port)
	if err != OK:
		connection_failed.emit("Could not reach %s:%d." % [address, port])
		return err
	multiplayer.multiplayer_peer = peer
	mode = MODE.CLIENT
	_join_generation += 1
	_handshake_answered = false
	log_net("dialling %s:%d" % [address, port])
	_wire_signals()
	players.clear()
	manifests.clear()
	_pending_name = player_name
	_pending_pack = pack
	return OK


func leave() -> void:
	if multiplayer.multiplayer_peer: multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	mode = MODE.OFFLINE
	players.clear()
	manifests.clear()
	slot_map = []
	_manifest_cache.clear()
	_pending_handshakes.clear()
	_handshake_answered = false
	_reset_session_state()
	player_list_changed.emit()




func _reset_session_state() -> void:
	_perf_inbox.clear()
	_perf_staging.clear()
	_barriers.clear()
	_barriers_done.clear()
	_barrier_released.clear()
	_end_round_queue.clear()
	_dub_begin_pending = false
	_dub_finished.clear()
	_pending_dub_watch = 0
	_dub_watch_pending = false
	_dub_watch_cancelled = false
	dub_roles.clear()
	dub_clip_owners = PackedInt32Array()
	_scores_inbox = PackedInt32Array()
	_scores_waiting = false


func begin_session(id: int = -1) -> void:
	_reset_session_state()
	if id >= 0: session_id = id
	else: session_id += 1
	log_net("session %d begins" % session_id)


func end_session() -> void:
	if not is_online(): return
	log_net("session %d ends" % session_id)
	session_id += 1
	_reset_session_state()
	if is_host():
		for id: int in players: players[id]["ready"] = false
		_push_roster()


var _pending_name: String = ""
var _pending_pack: String = ""

# host: peers that have connected but not handshook yet. client: whether the
# host has answered ours at all, which is a different question from whether the
# roster has turned up and is the one worth telling people about.
var _pending_handshakes: Dictionary = {}
var _handshake_answered: bool = false
# bumped every time we dial out. the watchdog below sleeps for ten seconds, and
# without a stamp one left over from an attempt the user has already given up on
# comes back and closes the connection they made on the second go.
var _join_generation: int = 0


func _make_record(player_name: String, pack: String) -> Dictionary:
	return {"name": player_name, "pack": pack, "ready": false}


func _wire_signals() -> void:
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		multiplayer.connected_to_server.connect(_on_connected_to_server)
		multiplayer.connection_failed.connect(_on_connection_failed)
		multiplayer.server_disconnected.connect(_on_server_disconnected)


func _relax_timeout(id: int) -> void:
	var enet: = multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null: return
	var link: ENetPacketPeer = enet.get_peer(id)
	if link == null: return
	link.set_timeout(PEER_TIMEOUT_LIMIT, PEER_TIMEOUT_MIN, PEER_TIMEOUT_MAX)


func _on_peer_connected(id: int) -> void:
	log_net("peer %d connected" % id)
	_relax_timeout(id)
	if is_host():
		_pending_handshakes[id] = true
		_watch_for_handshake(id)


func _on_peer_disconnected(id: int) -> void:
	log_net("peer %d disconnected" % id)
	# a peer that opened a socket and left again without ever registering. the
	# watchdog below was meant to be the one that says so, but it only ever got
	# the chance when the host's clock ran out first: both ends wait the same ten
	# seconds from the same moment, and a joiner that gives up takes the socket
	# with it, which lands here and erases the entry the watchdog was waiting on.
	# So roughly half the time the host was left watching somebody blink in and
	# out with no explanation whatsoever -- which is the exact shrug this pair of
	# timers exists to stop handing people. Say it here too.
	var never_handshook: bool = is_host() and _pending_handshakes.has(id)
	_pending_handshakes.erase(id)
	if never_handshook:
		log_net("peer %d left without ever handshaking" % id)
		host_notice.emit("Someone reached you and left again without getting through the "
			+ "join handshake. That is nearly always an older build of the mod -- and an "
			+ "older one cannot even be told that it is old, so it gives up rather than "
			+ "saying anything. You both need to install off the same download. "
			+ _this_build())
	if is_host():
		# somebody who never made it into the roster cannot have changed it, and
		# everything below is about a seat coming free. This used to run for any
		# disconnect at all, so a peer that merely knocked -- an old build being
		# turned away, and they retry -- cleared the whole dub casting on its way
		# past, every attempt, while four people were sat there picking.
		var was_seated: bool = players.has(id)
		players.erase(id)
		manifests.erase(id)
		if was_seated:
			_rebuild_slots()
			# roles are keyed by slot and the slots below the leaver just shifted
			# up, so keeping them would hand someone else's characters over.
			if not dub_roles.is_empty():
				dub_roles.clear()
				log_net("cleared the dub casting, someone left while it was being picked")
				_push_dub_roles()
			_push_roster()
			_push_manifests()
	player_list_changed.emit()


func _on_connected_to_server() -> void:
	log_net("connected to host, registering as '%s'" % _pending_name)
	_handshake_answered = false
	# the manifest was worked out in join_game. walking packs_voice from in here
	# would stall the poll this is being called from, and on a big library that
	# alone can outlast the host's patience for us.
	# "mod" is only ever quoted back at people in a message. new keys are free --
	# the payload is one Dictionary and always will be, see the note by _HANDSHAKE
	# -- and a build too old to send it is told apart by its absence.
	_HANDSHAKE.rpc_id(1, {
		"version": PROTOCOL_VERSION,
		"mod": MOD_VERSION,
		"name": _pending_name,
		"pack": _pending_pack,
		"manifest": voice_pack_manifest(),
	})
	connected_to_lobby.emit()
	_watch_for_answer(_join_generation)


func _on_connection_failed() -> void:
	log_net("connection to host failed")
	mode = MODE.OFFLINE
	connection_failed.emit("Could not reach the host. Check the IP, the port, and that they are hosting.")


func _on_server_disconnected() -> void:
	log_net("host closed the connection, returning to menu")
	mode = MODE.OFFLINE
	players.clear()
	manifests.clear()
	slot_map = []
	_manifest_cache.clear()
	_pending_handshakes.clear()
	_handshake_answered = false
	_reset_session_state()
	server_disconnected.emit()
	if get_tree().get_root().has_node("World"): M.world.CreateMenu()




### the join handshake. READ THIS BEFORE ADDING AN RPC. ########################
#
# Godot never puts method names on the wire. It sorts a script's @rpc methods by
# name and sends the index, so _rpc_roster is "call 16" and nothing else. Add,
# rename or remove one @rpc anywhere in this file and every method after it
# alphabetically shifts a place -- while a peer on the old build carries on
# sending the old numbers. Their "register me" lands on whatever now sits at that
# index, the argument count doesn't match, Godot drops the call, and the host
# never finds out anybody knocked.
#
# That is exactly what the version check was meant to catch, and exactly why it
# never did: the check lived inside _rpc_register, which is the one call that
# cannot survive a version difference. v1.1.3 inserted _rpc_manifests, which
# sorts tenth and pushed _rpc_register from call 14 to call 15, so a v1.1.2
# joiner's registration arrived at a v1.1.3 host as _rpc_perf_end and went in the
# bin. Both ends sat there politely. The joiner was told "the host hasn't sent
# the lobby", and everyone went off checking ports and firewalls that were fine,
# because the real answer -- one of you is on the old build -- was the one thing
# the mod had made itself unable to say.
#
# So the handshake is pinned to the front of that sorted list. _HANDSHAKE and
# _HANDSHAKE_REPLY sort ahead of _rpc_anything ('H' < 'r'), which makes them call
# 0 and call 1 in this build and in every future build that keeps the _rpc_
# prefix on everything else. They take one Dictionary each, so new fields go
# inside the payload and the argument count never moves either. Whatever else
# changes, two peers can always get far enough to tell each other what they are
# running.
#
# Keep every other @rpc in this file named _rpc_*. _ready() checks and shouts.


@rpc("any_peer", "call_remote", "reliable")
func _HANDSHAKE(payload: Dictionary) -> void:
	if not is_host(): return
	var sender: int = multiplayer.get_remote_sender_id()
	_pending_handshakes.erase(sender)

	var their_version: int = int(payload.get("version", 0))
	if their_version != PROTOCOL_VERSION:
		var which: String = "a newer" if their_version > PROTOCOL_VERSION else "an older"
		var theirs: String = _describe_build(str(payload.get("mod", "")), their_version)
		var told_them: String = ("Different build of the mod. You are on %s, the host is on "
			+ "%s. Whoever is behind runs the installer again, off the same download.") % [
			theirs, _this_build()]
		var told_us: String = ("Turned a joiner away: they are on %s build of the mod (%s), "
			+ "you are on %s. You both need to install off the same download.") % [
			which, theirs, _this_build()]
		_refuse(sender, told_them, told_us)
		return
	if players.size() >= MAX_PLAYERS:
		_refuse(sender, "Lobby is full (%d players max)." % MAX_PLAYERS,
			"Someone tried to join a full lobby.")
		return

	var player_name: String = str(payload.get("name", "Player"))
	log_net("'%s' joined (peer %d)" % [player_name, sender])
	players[sender] = _make_record(player_name, str(payload.get("pack", "")))
	manifests[sender] = _as_dictionary(payload.get("manifest", {}))
	_HANDSHAKE_REPLY.rpc_id(sender, {"ok": true})
	_rebuild_slots()
	_push_roster()
	_push_manifests()


@rpc("authority", "call_remote", "reliable")
func _HANDSHAKE_REPLY(payload: Dictionary) -> void:
	_handshake_answered = true
	if bool(payload.get("ok", false)): return
	var reason: String = str(payload.get("reason", "The host turned the join down."))
	log_net("host refused the join: %s" % reason)
	connection_failed.emit(reason)
	leave()


# tell them why, tell the host why, then close it -- but not in the same breath.
# ENet hands the refusal and the disconnect over together, and a client that gets
# both at once acts on the disconnect and throws the packet queue away with the
# reason still sitting unread in it. You then get "lost the connection to the
# host", which is the same shrug this whole fix exists to stop handing people.
# Anyone who can read the refusal leaves on their own well inside the grace;
# closing it afterwards is only for those who can't.
const REFUSAL_GRACE: float = 2.0


func _refuse(peer_id: int, reason: String, notice: String) -> void:
	log_net("refused peer %d: %s" % [peer_id, reason])
	_HANDSHAKE_REPLY.rpc_id(peer_id, {"ok": false, "reason": reason})
	host_notice.emit(notice)
	_drop_peer_once_that_has_landed(peer_id)


func _drop_peer_once_that_has_landed(peer_id: int) -> void:
	await get_tree().create_timer(REFUSAL_GRACE).timeout
	_drop_peer(peer_id)


func _drop_peer(peer_id: int) -> void:
	if not is_online(): return
	# they may well have taken themselves off already, and asking ENet to
	# disconnect somebody it has never heard of is an error in its own right.
	if not multiplayer.get_peers().has(peer_id): return
	var enet: = multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null: return
	enet.disconnect_peer(peer_id)


# a peer that opened a socket and then said nothing this build understands. an
# old copy of the mod calling an rpc that has since moved looks precisely like
# this, and it is far and away the usual cause, so say so rather than leaving the
# host wondering why the list never filled in.
func _watch_for_handshake(id: int) -> void:
	await get_tree().create_timer(HANDSHAKE_TIMEOUT).timeout
	if not is_host() or not _pending_handshakes.has(id): return
	_pending_handshakes.erase(id)
	log_net("peer %d connected but never handshook, dropping it" % id)
	host_notice.emit("Someone reached you but never got through the join handshake. "
		+ "That is nearly always an older build of the mod -- they need to run the "
		+ "installer again off the same download as you. " + _this_build())
	_drop_peer(id)


# every message about a build difference carries this. the message is the thing
# that gets screenshotted and pasted at me, and "one of you is on the wrong
# build" is no use to anybody unless it also says which build said it.
func _this_build() -> String:
	return "You are on mod %s, protocol %d." % [MOD_VERSION, PROTOCOL_VERSION]


# what to call the other end's build. anything old enough not to send its version
# number is pinned down by that absence alone, which is worth saying rather than
# printing an empty pair of quotes.
func _describe_build(mod: String, protocol: int) -> String:
	if mod.is_empty(): return "protocol %d, too old to say which build it is" % protocol
	return "mod %s, protocol %d" % [mod, protocol]


# the other side of it: we got a socket open and the host has said nothing back.
# the lobby's own timer only ever knew that no lobby had turned up, which reads
# as a network problem and usually isn't one.
func _watch_for_answer(generation: int) -> void:
	await get_tree().create_timer(HANDSHAKE_TIMEOUT).timeout
	if generation != _join_generation: return
	if is_host() or not is_online() or _handshake_answered: return
	log_net("host never answered the handshake")
	connection_failed.emit(("Reached the host, but they never answered the join.\n"
		+ "You are almost certainly on different builds of the mod: an older one cannot "
		+ "even be told that it is old. Both of you run the installer again off the same "
		+ "download, then try again.\n" + _this_build() + " Ask the host what theirs says "
		+ "at the top of their lobby."))
	leave()


func _rebuild_slots() -> void:
	if not is_host(): return
	var ids: Array = players.keys()
	ids.sort()
	# host takes slot 0
	ids.erase(1)
	ids.push_front(1)
	slot_map = PackedInt32Array(ids)


func _push_roster() -> void:
	_rpc_roster.rpc(players, slot_map)
	player_list_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_roster(new_players: Dictionary, new_slots: PackedInt32Array) -> void:
	_handshake_answered = true
	players = new_players
	slot_map = new_slots
	player_list_changed.emit()


func _push_manifests() -> void:
	if is_host(): _rpc_manifests.rpc(manifests)


@rpc("authority", "call_remote", "reliable")
func _rpc_manifests(new_manifests: Dictionary) -> void:
	manifests = new_manifests
	player_list_changed.emit()


func set_ready(value: bool) -> void:
	if is_host():
		players[1]["ready"] = value
		_push_roster()
	else:
		_rpc_set_ready.rpc_id(1, value)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_set_ready(value: bool) -> void:
	if not is_host(): return
	var sender: int = multiplayer.get_remote_sender_id()
	if players.has(sender):
		players[sender]["ready"] = value
		_push_roster()


func everyone_ready() -> bool:
	if players.size() < 2: return false
	for id: int in players: if not players[id].get("ready", false): return false
	return true




const CLIP_EXTENSIONS: PackedStringArray = ["wav", "mp3", "ogg"]

# walking packs_voice is not free and the answer does not change while a lobby
# is open, so it is worked out once and thrown away in leave().
var _manifest_cache: Dictionary = {}


# a clip count and a hash per pack, never the file names. sending the names was
# hundreds of kilobytes on a normal install, and ENet gives a reliable packet it
# cannot get across exactly 30 seconds before it drops the peer -- which is why
# joiners were being kicked at the 30 second mark with an empty lobby in front
# of them. audio file names only; hashing captions and pack icons gave constant
# false mismatches.
#
# the hash covers what is inside the pack and deliberately not the folder it sits
# in. two people who downloaded the same pack often have it under different folder
# names -- 'SML - Mushroom Pizza' against 'sml_-_mushroom_pizza' -- and that used
# to read as two packs neither of them had, which then threw the joiner out of a
# match over clips it was holding all along.
func voice_pack_manifest() -> Dictionary:
	if not _manifest_cache.is_empty(): return _manifest_cache
	var out: Dictionary = {}
	var root: String = FileManager.MODPACKS_VOICE
	for pack: String in DirAccess.get_directories_at(root):
		var pack_root: String = root.path_join(pack)
		var entries: PackedStringArray = []
		var stack: Array[String] = [pack_root]
		while not stack.is_empty():
			var dir_path: String = stack.pop_back()
			for sub: String in DirAccess.get_directories_at(dir_path):
				stack.append(dir_path.path_join(sub))
			for f: String in DirAccess.get_files_at(dir_path):
				if not CLIP_EXTENSIONS.has(f.get_extension().to_lower()): continue
				# backing tracks, _ignore and the dub recordings the game writes
				# itself. it never performs these, so counting them only ever
				# invented a difference between two identical packs.
				if f.begins_with("_"): continue
				entries.append(dir_path.trim_prefix(pack_root).path_join(f).trim_prefix("/"))
		entries.sort()
		out[pack] = {"clips": entries.size(), "hash": "\n".join(entries).hash()}
	_manifest_cache = out
	return out


# their folder name -> the folder holding the same clips here. a pack we haven't
# got simply doesn't appear.
func pack_remap(their_manifest: Dictionary) -> Dictionary:
	var by_hash: Dictionary = {}
	var mine: Dictionary = voice_pack_manifest()
	for name: String in mine:
		by_hash[_as_dictionary(mine[name]).get("hash", 0)] = name
	var out: Dictionary = {}
	for their_name: String in their_manifest:
		var h: Variant = _as_dictionary(their_manifest[their_name]).get("hash", 0)
		if by_hash.has(h): out[their_name] = by_hash[h]
	return out


func _host_manifest() -> Dictionary:
	return _as_dictionary(manifests.get(1, {}))


# rewrite a packs_voice path the host sent us so it points at our own copy,
# whatever we happen to have called the folder.
func localise_path(path: String, remap: Dictionary) -> String:
	var root: String = FileManager.MODPACKS_VOICE
	if not path.begins_with(root): return path
	var rest: String = path.trim_prefix(root)
	var cut: int = rest.find("/")
	var pack: String = rest if cut < 0 else rest.substr(0, cut)
	if not remap.has(pack) or remap[pack] == pack: return path
	var tail: String = "" if cut < 0 else rest.substr(cut)
	return root.path_join(remap[pack]) + tail


func localise_paths(paths: PackedStringArray, remap: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	for p: String in paths: out.append(localise_path(p, remap))
	return out


# everything off the wire is checked, a peer running a doctored build should
# only ever cost itself a warning line.
func _as_dictionary(value: Variant) -> Dictionary:
	if value is Dictionary: return value
	return {}


# matched on contents first, so a pack only gets mentioned when the clips really
# do differ. a folder name that doesn't line up is no longer worth saying anything
# about, because nothing downstream cares about it any more.
func pack_differences(other: Dictionary) -> PackedStringArray:
	var mine: Dictionary = voice_pack_manifest()
	var my_hashes: Dictionary = {}
	for k: String in mine: my_hashes[_as_dictionary(mine[k]).get("hash", 0)] = k
	var their_hashes: Dictionary = {}
	for k: String in other: their_hashes[_as_dictionary(other[k]).get("hash", 0)] = k

	var diffs: PackedStringArray = []
	for k: String in mine:
		var ours: Dictionary = _as_dictionary(mine[k])
		if their_hashes.has(ours.get("hash", 0)): continue
		# same name on both sides but different clips inside is the one case worth
		# spelling out, because the counts usually tell you which of you is short.
		if other.has(k):
			var theirs: Dictionary = _as_dictionary(other[k])
			diffs.append("'%s' -- they have %d clip(s), you have %d" % [
				k, int(theirs.get("clips", 0)), int(ours.get("clips", 0))])
		else:
			diffs.append("'%s' -- they don't have this pack at all" % k)
	for k: String in other:
		var theirs: Dictionary = _as_dictionary(other[k])
		if my_hashes.has(theirs.get("hash", 0)): continue
		if mine.has(k): continue
		diffs.append("'%s' -- you don't have this pack at all" % k)
	return diffs


func mismatched_players() -> PackedStringArray:
	var out: PackedStringArray = []
	for id: int in players:
		if id == my_id(): continue
		# nothing to say until their manifest has actually landed
		if not manifests.has(id): continue
		var diffs: PackedStringArray = pack_differences(_as_dictionary(manifests[id]))
		if not diffs.is_empty():
			out.append("%s -- %s" % [players[id].get("name", "Player"), ", ".join(diffs)])
	return out




func start_match(clip_paths: PackedStringArray) -> void:
	if not is_host(): return
	begin_session()
	log_net("starting match with %d clips" % clip_paths.size())
	_rpc_start_match.rpc(session_id, clip_paths)
	match_should_start.emit(clip_paths)


@rpc("authority", "call_remote", "reliable")
func _rpc_start_match(sid: int, clip_paths: PackedStringArray) -> void:
	begin_session(sid)
	match_should_start.emit(clip_paths)




### the microphone #############################################################

# Profile.audio_device_in keeps the name of a mic that has since been unplugged:
# the profile setter falls back to "Default" but leaves the dead name behind. The
# game assigns it straight back, unchecked, every turn. Offline that is one
# person who still owns the mic they picked; online it is everyone. Check it the
# way the game's own device dropdown does.
func use_configured_microphone() -> void:
	var wanted: String = Profile.audio_device_in
	if not AudioServer.get_input_device_list().has(wanted):
		log_net("microphone '%s' is not on this machine, falling back to Default" % wanted)
		wanted = "Default"
	if AudioServer.input_device == wanted: return
	AudioServer.input_device = wanted
	log_net("microphone set to '%s'" % wanted)


const PLMIC_RECORD_EFFECT_INDEX: int = 7


func _raw_plmic_recording() -> AudioStreamWAV:
	var bus: int = AudioServer.get_bus_index("Plmic")
	if bus < 0: return null
	var effect: AudioEffectRecord = AudioServer.get_bus_effect(
		bus, PLMIC_RECORD_EFFECT_INDEX) as AudioEffectRecord
	if effect == null: return null
	return effect.get_recording()


# the game crops 0.4s off the front of every take by byte count, and slice() past
# the end returns nothing -- so a short capture comes out empty rather than short.
# The waveform is sampled off the spectrum analyser and still draws fine, which is
# the report we keep getting. Keep the uncropped take instead of sending nothing.
func vetted_take(take: AudioStreamWAV) -> AudioStreamWAV:
	if take != null and take.data.size() > 0:
		log_net("take: %d bytes, %d Hz, %s" % [take.data.size(), take.mix_rate,
			"stereo" if take.stereo else "mono"])
		return take
	log_net("TAKE IS EMPTY -- the crop consumed the whole recording, so capture came "
		+ "up shorter than 0.4s. Check the mic selected in Settings is the one plugged in.")
	var raw: AudioStreamWAV = _raw_plmic_recording()
	if raw != null and raw.data.size() > 0:
		log_net("recovered the uncropped take, %d bytes at %d Hz" % [raw.data.size(), raw.mix_rate])
		return raw
	log_net("nothing was captured at all this turn")
	return take


func clear_round_performances() -> void:
	_perf_inbox.clear()
	_perf_staging.clear()


func submit_performance(slot: int, plmic: Dictionary, take: AudioStreamWAV) -> void:
	var meta: Dictionary = _wav_meta(take)
	var data: PackedByteArray = take.data
	_perf_inbox[slot] = {"plmic": plmic, "wav": take}
	if not is_online():
		performance_received.emit(slot)
		return
	var sid: int = session_id
	_rpc_perf_begin.rpc(sid, slot, plmic, meta)
	var offset: int = 0
	while offset < data.size():
		if not is_online() or session_id != sid: return
		var end: int = mini(offset + CHUNK_SIZE, data.size())
		_rpc_perf_chunk.rpc(sid, slot, data.slice(offset, end))
		offset = end
		await get_tree().process_frame
	if not is_online() or session_id != sid: return
	_rpc_perf_end.rpc(sid, slot)
	log_net("sent %d bytes for slot %d" % [data.size(), slot])
	performance_received.emit(slot)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_perf_begin(sid: int, slot: int, plmic: Dictionary, meta: Dictionary) -> void:
	if sid != session_id: return
	_perf_staging[slot] = {"plmic": plmic, "meta": meta, "data": PackedByteArray()}


@rpc("any_peer", "call_remote", "reliable")
func _rpc_perf_chunk(sid: int, slot: int, chunk: PackedByteArray) -> void:
	if sid != session_id: return
	if not _perf_staging.has(slot): return
	_perf_staging[slot]["data"].append_array(chunk)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_perf_end(sid: int, slot: int) -> void:
	if sid != session_id: return
	if not _perf_staging.has(slot): return
	var staged: Dictionary = _perf_staging[slot]
	_perf_inbox[slot] = {
		"plmic": staged["plmic"],
		"wav": _wav_from(staged["meta"], staged["data"]),
	}
	_perf_staging.erase(slot)
	log_net("received take for slot %d" % slot)
	performance_received.emit(slot)


func await_performance(slot: int, owner_slot: int = -1) -> Dictionary:
	var waited: float = 0.0
	var sid: int = session_id
	while not _perf_inbox.has(slot):
		var owner_peer: int = peer_for_slot(owner_slot if owner_slot >= 0 else slot)
		if owner_peer != 0 and not players.has(owner_peer):
			log_net("slot %d left before sending a take, skipping them" % slot)
			break
		if not is_online():
			break
		if session_id != sid:
			log_net("session ended while waiting for slot %d" % slot)
			return {}
		await get_tree().process_frame
		waited += get_process_delta_time()
		if waited > PERFORMANCE_TIMEOUT:
			log_net("timed out after %.0fs waiting for slot %d" % [waited, slot])
			break
	return _perf_inbox.get(slot, {})


func _wav_meta(w: AudioStreamWAV) -> Dictionary:
	return {
		"format": w.format,
		"mix_rate": w.mix_rate,
		"stereo": w.stereo,
		"loop_mode": w.loop_mode,
		"loop_begin": w.loop_begin,
		"loop_end": w.loop_end,
	}


func _wav_from(meta: Dictionary, data: PackedByteArray) -> AudioStreamWAV:
	var w: = AudioStreamWAV.new()
	w.format = meta.get("format", AudioStreamWAV.FORMAT_16_BITS)
	w.mix_rate = meta.get("mix_rate", 44100)
	w.stereo = meta.get("stereo", false)
	w.loop_mode = meta.get("loop_mode", AudioStreamWAV.LOOP_DISABLED)
	w.loop_begin = meta.get("loop_begin", 0)
	w.loop_end = meta.get("loop_end", 0)
	w.data = data
	return w




func publish_scores(scores: PackedInt32Array) -> void:
	if not is_host(): return
	_rpc_scores.rpc(session_id, scores)
	scores_received.emit(scores)


var _scores_inbox: PackedInt32Array = []
var _scores_waiting: bool = false


@rpc("authority", "call_remote", "reliable")
func _rpc_scores(sid: int, scores: PackedInt32Array) -> void:
	if sid != session_id: return
	_scores_inbox = scores
	_scores_waiting = true
	scores_received.emit(scores)


func await_scores() -> PackedInt32Array:
	var sid: int = session_id
	while not _scores_waiting:
		if not is_online() or session_id != sid: return PackedInt32Array()
		await get_tree().process_frame
	_scores_waiting = false
	return _scores_inbox




func barrier(tag: String) -> void:
	if not is_online(): return
	log_net("barrier '%s' reached" % tag)
	var waited: float = 0.0
	var sid: int = session_id
	if is_host():
		if not _barriers.has(tag): _barriers[tag] = {}
		_barriers[tag][1] = true
		while _barriers[tag].size() < players.size():
			if not is_online() or session_id != sid: return
			await get_tree().process_frame
			waited += get_process_delta_time()
			if waited > BARRIER_TIMEOUT:
				log_net("barrier '%s' timed out, continuing without everyone" % tag)
				break
		_barriers.erase(tag)
		_barriers_done[tag] = true
		_rpc_barrier_release.rpc(sid, tag)
	else:
		_barrier_released[tag] = false
		_rpc_barrier_reached.rpc_id(1, sid, tag)
		while not _barrier_released.get(tag, false):
			if not is_online() or session_id != sid: return
			await get_tree().process_frame
			waited += get_process_delta_time()
			if waited > BARRIER_TIMEOUT:
				log_net("barrier '%s' timed out waiting for the host" % tag)
				break
		_barrier_released.erase(tag)


var _barrier_released: Dictionary = {}


@rpc("any_peer", "call_remote", "reliable")
func _rpc_barrier_reached(sid: int, tag: String) -> void:
	if not is_host(): return
	if sid != session_id: return
	if _barriers_done.has(tag): return
	if not _barriers.has(tag): _barriers[tag] = {}
	_barriers[tag][multiplayer.get_remote_sender_id()] = true


@rpc("authority", "call_remote", "reliable")
func _rpc_barrier_release(sid: int, tag: String) -> void:
	if sid != session_id: return
	_barrier_released[tag] = true




signal dialogue_state(idx: int, active: bool, revealed: bool)
signal dialogue_skip
signal match_skip
signal end_round_choice(choice: int)

func is_spectator() -> bool: return is_online() and not is_host()


func broadcast_dialogue_state(idx: int, active: bool, revealed: bool) -> void:
	if is_online(): _rpc_dialogue_state.rpc(session_id, idx, active, revealed)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_dialogue_state(sid: int, idx: int, active: bool, revealed: bool) -> void:
	if sid != session_id: return
	dialogue_state.emit(idx, active, revealed)


func broadcast_dialogue_skip() -> void:
	if is_online(): _rpc_dialogue_skip.rpc(session_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_dialogue_skip(sid: int) -> void:
	if sid != session_id: return
	dialogue_skip.emit()


func broadcast_match_skip() -> void:
	if is_online(): _rpc_match_skip.rpc(session_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_match_skip(sid: int) -> void:
	if sid != session_id: return
	match_skip.emit()


var _end_round_queue: Array[int] = []


func broadcast_end_round_choice(choice: int) -> void:
	if is_online(): _rpc_end_round_choice.rpc(session_id, choice)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_end_round_choice(sid: int, choice: int) -> void:
	if sid != session_id: return
	_end_round_queue.append(choice)
	end_round_choice.emit(choice)


func await_end_round_choice() -> int:
	var sid: int = session_id
	while _end_round_queue.is_empty():
		if not is_online() or session_id != sid: return -1
		await get_tree().process_frame
	return _end_round_queue.pop_front()




signal dub_should_start(folder: String, clip_paths: PackedStringArray)
signal dub_begin
signal dub_watch(playing: bool)


func start_dub(folder: String, clip_paths: PackedStringArray) -> void:
	if not is_host(): return
	begin_session()
	log_net("starting dub '%s' with %d clips" % [folder, clip_paths.size()])
	_rpc_start_dub.rpc(session_id, folder, clip_paths)

@rpc("authority", "call_remote", "reliable")
func _rpc_start_dub(sid: int, folder: String, clip_paths: PackedStringArray) -> void:
	begin_session(sid)
	dub_should_start.emit(folder, clip_paths)


var _dub_begin_pending: bool = false


func broadcast_dub_begin(owners: PackedInt32Array = PackedInt32Array()) -> void:
	dub_clip_owners = owners
	if is_online(): _rpc_dub_begin.rpc(session_id, owners)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_dub_begin(sid: int, owners: PackedInt32Array) -> void:
	if sid != session_id: return
	dub_clip_owners = owners
	_dub_begin_pending = true
	dub_begin.emit()


func take_pending_dub_begin() -> bool:
	var pending: bool = _dub_begin_pending
	_dub_begin_pending = false
	return pending


### watching the finished dub together #########################################
#
# Everyone reaches the last clip within a frame of each other -- the whole dub
# runs in lockstep, nobody moves on until the take for the clip in front of them
# has landed. What is not in lockstep is what happens next: dub_finished() scores
# every clip on a background thread and spins a wheel for a second on top, and
# that takes as long as the machine takes. So the host's Watch button lit up,
# the host pressed it, and the joiners were still staring at a spinning wheel --
# and worse, the results screen they were still building painted straight over
# the video that had just started underneath it.
#
# So the press no longer starts anything by itself. It asks the host, the host
# waits until every peer has said it is sat on its results screen, and only then
# does one broadcast start all of them. Anyone can press it; it means the same
# thing whoever does.

# peer -> true, host side only. cleared with the rest of the session.
var _dub_finished: Dictionary = {}
# a watch that arrived before this end was ready for it. applied on arrival at
# the results screen, so a peer that was still scoring does not miss it.
var _pending_dub_watch: int = 0
# one wait at a time, or a second press starts a second one.
var _dub_watch_pending: bool = false
# a Stop pressed while that wait is still running. without it the wait finishes
# afterwards and starts a video everyone has already been told not to play.
var _dub_watch_cancelled: bool = false

# long enough for the slowest machine anyone has reported, short enough that a
# peer which has quietly wedged does not hold the whole room hostage.
const DUB_WATCH_TIMEOUT: float = 30.0


# "I am on the results screen." everyone calls this, host included.
func report_dub_finished() -> void:
	if not is_online(): return
	if is_host(): _dub_finished[1] = true
	else: _rpc_dub_finished.rpc_id(1, session_id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_dub_finished(sid: int) -> void:
	if not is_host(): return
	if sid != session_id: return
	_dub_finished[multiplayer.get_remote_sender_id()] = true


func everyone_finished_dub() -> bool:
	if not is_host(): return true
	for id: int in players:
		if not _dub_finished.has(id): return false
	return true


func players_still_dubbing() -> PackedStringArray:
	var out: PackedStringArray = []
	for slot: int in slot_count():
		if not _dub_finished.has(peer_for_slot(slot)): out.append(player_name_for_slot(slot))
	return out


# what the Watch and Stop buttons call. offline it is just the local signal.
func request_dub_watch(playing: bool) -> void:
	if not is_online():
		dub_watch.emit(playing)
		return
	if is_host(): _host_start_watch(playing)
	else: _rpc_dub_watch_request.rpc_id(1, session_id, playing)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_dub_watch_request(sid: int, playing: bool) -> void:
	if not is_host(): return
	if sid != session_id: return
	_host_start_watch(playing)


func _host_start_watch(playing: bool) -> void:
	if not is_host(): return
	# stopping never waits on anybody. whoever is behind gets the stop latched and
	# applies it the moment they arrive, which is the right thing either way.
	if not playing:
		_dub_watch_cancelled = _dub_watch_pending
		_broadcast_dub_watch(false)
		return
	if _dub_watch_pending: return
	_dub_watch_pending = true
	_dub_watch_cancelled = false
	var sid: int = session_id
	var waited: float = 0.0
	var told: bool = false
	while not everyone_finished_dub():
		if _dub_watch_cancelled or not is_online() or session_id != sid:
			_dub_watch_pending = false
			if told: _loading_hint("")
			return
		if not told:
			told = true
			# said once, not every frame: the hint frees and rebuilds its overlay
			# on each call, and the names in it barely move anyway.
			_loading_hint("Waiting for %s to finish scoring..." % ", ".join(players_still_dubbing()))
		await get_tree().process_frame
		waited += get_process_delta_time()
		if waited > DUB_WATCH_TIMEOUT:
			log_net("starting the watch without %s, they have had %.0fs" % [
				", ".join(players_still_dubbing()), waited])
			break
	_dub_watch_pending = false
	if told: _loading_hint("")
	_broadcast_dub_watch(true)


# host only, and the host goes through the same signal as everyone else so the
# two ends cannot drift apart in what they do with it.
func _broadcast_dub_watch(playing: bool) -> void:
	if not is_host(): return
	_rpc_dub_watch.rpc(session_id, playing)
	dub_watch.emit(playing)


@rpc("authority", "call_remote", "reliable")
func _rpc_dub_watch(sid: int, playing: bool) -> void:
	if sid != session_id: return
	dub_watch.emit(playing)


# for a peer that got the watch while it was still scoring. -1 stop, 0 nothing,
# 1 play.
func latch_dub_watch(playing: bool) -> void:
	_pending_dub_watch = 1 if playing else -1


func take_pending_dub_watch() -> int:
	var pending: int = _pending_dub_watch
	_pending_dub_watch = 0
	return pending




signal dub_roles_changed

# slot -> the characters that slot dubs. host is authoritative; everyone else
# only ever reads the copy it pushes.
var dub_roles: Dictionary = {}

# clip index -> slot, resolved once by the host and sent with dub_begin. every
# peer must agree on this, and recomputing it locally would let a late roles
# push give two players different answers for the same clip.
var dub_clip_owners: PackedInt32Array = []


func characters_for_slot(slot: int) -> PackedStringArray:
	return PackedStringArray(dub_roles.get(slot, PackedStringArray()))


func slot_for_character(character: String) -> int:
	var best: int = -1
	for slot: int in dub_roles:
		if slot < 0 or slot >= slot_count(): continue
		if not characters_for_slot(slot).has(character): continue
		if best < 0 or slot < best: best = slot
	return best


func anyone_picked() -> bool:
	for slot: int in dub_roles:
		if not characters_for_slot(slot).is_empty(): return true
	return false


func slots_without_a_character() -> PackedStringArray:
	var out: PackedStringArray = []
	for slot: int in slot_count():
		if characters_for_slot(slot).is_empty(): out.append(player_name_for_slot(slot))
	return out


func set_my_dub_characters(characters: PackedStringArray) -> void:
	if not is_online():
		dub_roles[0] = characters
		dub_roles_changed.emit()
		return
	if is_host(): set_dub_characters_for_slot(my_slot(), characters)
	else: _rpc_claim_characters.rpc_id(1, session_id, characters)


# host only. also used by the auto split button.
func set_dub_characters_for_slot(slot: int, characters: PackedStringArray) -> void:
	if not is_host(): return
	dub_roles[slot] = characters
	_push_dub_roles()


@rpc("any_peer", "call_remote", "reliable")
func _rpc_claim_characters(sid: int, characters: PackedStringArray) -> void:
	if not is_host(): return
	if sid != session_id: return
	# trust the sender's peer id, never a slot it sends us.
	var slot: int = slot_for_peer(multiplayer.get_remote_sender_id())
	if slot < 0: return
	dub_roles[slot] = characters
	_push_dub_roles()


func _push_dub_roles() -> void:
	if is_online(): _rpc_dub_roles.rpc(session_id, dub_roles)
	dub_roles_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_dub_roles(sid: int, roles: Dictionary) -> void:
	if sid != session_id: return
	dub_roles = roles
	dub_roles_changed.emit()


# clip_characters is one PackedStringArray per clip, in performance order.
func resolve_dub_owners(clip_characters: Array) -> PackedInt32Array:
	var owners: PackedInt32Array = []
	var slots: int = maxi(1, slot_count())
	# clips nobody claimed are dealt round robin, counted separately so that a
	# pack where one character has most of the lines still splits the leftovers.
	var spare: int = 0
	for i: int in clip_characters.size():
		var owner: int = -1
		for character: String in PackedStringArray(clip_characters[i]):
			owner = slot_for_character(character)
			if owner >= 0: break
		if owner < 0:
			owner = spare % slots
			spare += 1
		owners.append(owner)
	return owners


func _on_dub_should_start(folder: String, clip_paths: PackedStringArray) -> void:
	if is_host(): return
	_loading_hint("The host has started. Loading the dub pack...")
	var remap: Dictionary = pack_remap(_host_manifest())
	folder = localise_path(folder, remap)
	clip_paths = localise_paths(clip_paths, remap)
	# a dub pack drags the video in with it, so this is the slowest load in the
	# mod by far. the host already does it on a thread in clip_selection_dub;
	# doing it inline here froze the joiner until the host's ENet gave up on it.
	var thread: = Thread.new()
	thread.start(func() -> GameplayResourceDubMode: return GameplayResourceDubMode.new(folder))
	while thread.is_alive(): await get_tree().process_frame
	var res: GameplayResourceDubMode = thread.wait_to_finish()
	if not is_online():
		_loading_hint("")
		return
	if res.failed_to_load or res.no_video_file:
		_abort_to_menu("Cannot start: you don't have the dub pack '%s'." % folder.trim_suffix("/").get_file())
		return

	var by_path: Dictionary = {}
	for c: OmniClip in res.omni_clip_array.data: by_path[c.self_global_path] = c
	var ordered: Array[OmniClip] = []
	var missing: PackedStringArray = []
	for p: String in clip_paths:
		if by_path.has(p): ordered.append(by_path[p])
		else: missing.append(p.get_file())
	if not missing.is_empty():
		_abort_to_menu("Cannot start: missing %d dub clip(s) (%s)." % [missing.size(), ", ".join(missing.slice(0, 3))])
		return

	res.omni_clip_array.data = ordered
	Metro.gameplay_resource_dub_mode = res
	M.session_type = M.SESSION_TYPE.VIDEO_DUB
	if get_tree().get_root().has_node("World"): M.world.enter_dub_mode()


# the joiner has no idea the host has pressed anything until its scene changes,
# and the load in between is the slowest part of joining a show. say so. an empty
# string takes the hint back down.
func _loading_hint(text: String) -> void:
	if not get_tree().get_root().has_node("World"): return
	if text.is_empty(): M.world.ActiveHint(false)
	else: M.world.ActiveHint(true, text, false)


func _abort_to_menu(reason: String) -> void:
	_loading_hint("")
	log_net("ABORT: %s" % reason)
	connection_failed.emit(reason)
	leave()
	if get_tree().get_root().has_node("World"): M.world.CreateMenu()




func apply_roster_to_metro() -> void:
	var members: Array[BasicPlayerPackage] = []
	for slot: int in slot_map.size():
		var peer: int = slot_map[slot]
		var pack: String = players.get(peer, {}).get("pack", "")
		members.append(BasicPlayerPackage.new(pack, ""))
	Metro.current_players = members


# decoding a clip is not quick, and ENet only gets polled between frames. doing a
# whole pack in one go stops us acking anything, and the host drops a peer that
# has gone quiet -- after 30 seconds on a real link, which is exactly what the
# joiner saw: a frozen lobby, then dropped, while the host was already playing.
# so come up for air after every clip.
func rebuild_clip_set(paths: PackedStringArray) -> PackedStringArray:
	var clips: Array[OmniClip] = []
	var missing: PackedStringArray = []
	for p: String in paths:
		var clip: = OmniClip.new(M.CLIP_USES.VOICE)
		clip.generate_from_audio_file_exact(p)
		if clip.clip_audio: clips.append(clip)
		else: missing.append(p)
		await get_tree().process_frame
		if not is_online(): return missing
	if missing.is_empty(): Metro.gameplay_omniclip_set = clips
	return missing


### the way in #################################################################
#
# F9 alone was never enough. The function row on a lot of laptops is media keys
# unless you hold Fn, OBS and Medal both want F9 for recording, and some people
# were pressing it on the stock exe. None of that gets better by reading the key
# more carefully, so there is a button on screen now. F9 still works.

const ENTRY_INSET: Vector2 = Vector2(24, 20)

var _entry_layer: CanvasLayer
var _entry_button: Button


func _build_the_way_in() -> void:
	_entry_layer = CanvasLayer.new()
	# clear of the game's overlays, which sit on z_index 1 of the default layer.
	_entry_layer.layer = 128
	add_child(_entry_layer)

	_entry_button = Button.new()
	_entry_button.text = "ONLINE  (F9)"
	_entry_button.tooltip_text = "Open the multiplayer lobby.\nMultiplayer mod %s, protocol %d." % [
		MOD_VERSION, PROTOCOL_VERSION]
	# the menus run on ui_accept, and a button holding focus eats the first press.
	_entry_button.focus_mode = Control.FOCUS_NONE
	_entry_button.pressed.connect(open_lobby)
	_entry_layer.add_child(_entry_button)

	# polled: there is no hook into the game's screen changes, and they all go
	# through primary_capsule anyway.
	var ticker: = Timer.new()
	ticker.wait_time = 0.4
	ticker.timeout.connect(_place_entry_button)
	add_child(ticker)
	ticker.start()
	_place_entry_button()


func _place_entry_button() -> void:
	if not is_instance_valid(_entry_button): return
	_entry_button.visible = can_open_lobby()
	if not _entry_button.visible: return
	_entry_button.size = _entry_button.get_combined_minimum_size()
	var view: Vector2 = _entry_layer.get_viewport().get_visible_rect().size
	_entry_button.position = Vector2(
		view.x - _entry_button.size.x - ENTRY_INSET.x, ENTRY_INSET.y)


# menus only. CreateLobby frees everything under primary_capsule, so F9 mid-show
# tears the show down for you and then for everyone waiting on your barrier. Also
# stops a second press stacking another lobby on the first.
func can_open_lobby() -> bool:
	if not get_tree().get_root().has_node("World"): return false
	var world: Node = M.world
	# mid-transition. The button sits above the blackout, so hide it.
	var blackout: CanvasItem = world.blackout
	if is_instance_valid(blackout) and blackout.visible: return false
	var capsule: Node = world.primary_capsule
	if capsule == null: return false
	for child: Node in capsule.get_children():
		if child.scene_file_path.contains("menu_master"): return true
	return false


func open_lobby() -> void:
	if not can_open_lobby(): return
	log_net("opening the lobby")
	M.world.CreateLobby()


# on Net rather than world.gd: this is in the tree from startup, and _input runs
# ahead of the focused control that used to swallow the key.
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey): return
	var key: InputEventKey = event
	if not key.pressed or key.echo: return
	# physical_keycode too, keycode goes through the keyboard layout.
	if key.keycode != KEY_F9 and key.physical_keycode != KEY_F9: return
	if not can_open_lobby(): return
	get_viewport().set_input_as_handled()
	open_lobby()


func _ready() -> void:
	# CONNECT_DEFERRED for the same reason the lobby uses it: these fire from
	# inside the multiplayer poll. Loading a pack and swapping the scene from in
	# there is what stranded joiners on the lobby screen while the host played on.
	match_should_start.connect(_on_match_should_start, CONNECT_DEFERRED)
	dub_should_start.connect(_on_dub_should_start, CONNECT_DEFERRED)
	log_net("multiplayer mod %s (protocol %d) loaded" % [MOD_VERSION, PROTOCOL_VERSION])
	_build_the_way_in()
	if OS.is_debug_build(): _check_the_handshake_still_sorts_first()


# the handshake only survives a version difference because it sorts to the front
# of the rpc list, and nothing in the language enforces that. an rpc named, say,
# _abort_round would quietly take call 0 off it and put us straight back to
# joiners hanging with no idea why. catch it here rather than in someone's lobby.
func _check_the_handshake_still_sorts_first() -> void:
	var names: Array[String] = []
	for m: Dictionary in get_method_list():
		var n: String = str(m.get("name", ""))
		if n.begins_with("_HANDSHAKE") or n.begins_with("_rpc_"):
			if not names.has(n): names.append(n)
	names.sort()
	if names.size() < 2: return
	if names[0] == "_HANDSHAKE" and names[1] == "_HANDSHAKE_REPLY": return
	push_error(("net: '%s' now sorts ahead of the handshake, so its rpc numbers have moved. "
		+ "Every rpc other than the handshake pair must be named _rpc_*, or two builds "
		+ "stop being able to tell each other what they are.") % names[0])


func _on_match_should_start(clip_paths: PackedStringArray) -> void:
	if is_host(): return
	_loading_hint("The host has started. Loading the clips...")
	# the host's folder names are the host's business. point these at our copies.
	var local_paths: PackedStringArray = localise_paths(clip_paths, pack_remap(_host_manifest()))
	var missing: PackedStringArray = await rebuild_clip_set(local_paths)
	# leave() during the load already took us back to the menu.
	if not is_online():
		_loading_hint("")
		return
	if not missing.is_empty():
		_loading_hint("")
		log_net("ABORT: missing %d of %d clips, first is %s" % [missing.size(), clip_paths.size(), missing[0]])
		var names: PackedStringArray = []
		for p: String in missing: names.append(p.get_file())
		connection_failed.emit("Cannot start: you are missing %d clip(s) the host is using (%s). Copy the host's packs_voice folder across." % [
			missing.size(), ", ".join(names.slice(0, 3))])
		leave()
		if get_tree().get_root().has_node("World"): M.world.CreateMenu()
		return
	apply_roster_to_metro()
	M.session_type = M.SESSION_TYPE.STANDARD
	if get_tree().get_root().has_node("World"): M.world.CreateMatch()
