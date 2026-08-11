extends Node
# ENet client/server, host authoritative. host is always slot 0.

signal player_list_changed
signal connection_failed(reason: String)
signal connected_to_lobby
signal server_disconnected
signal match_should_start(clip_paths: PackedStringArray)
signal performance_received(slot: int)
signal scores_received(scores: PackedInt32Array)

const PORT: int = 7654
const MAX_PLAYERS: int = 4
const PROTOCOL_VERSION: int = 3
const CHUNK_SIZE: int = 24576
const PERFORMANCE_TIMEOUT: float = 60.0
const BARRIER_TIMEOUT: float = 90.0


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


func join_game(address: String, player_name: String, pack: String, port: int = PORT) -> Error:
	var peer: = ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(address, port)
	if err != OK:
		connection_failed.emit("Could not reach %s:%d." % [address, port])
		return err
	multiplayer.multiplayer_peer = peer
	mode = MODE.CLIENT
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


func _make_record(player_name: String, pack: String) -> Dictionary:
	return {"name": player_name, "pack": pack, "ready": false}


func _wire_signals() -> void:
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		multiplayer.connected_to_server.connect(_on_connected_to_server)
		multiplayer.connection_failed.connect(_on_connection_failed)
		multiplayer.server_disconnected.connect(_on_server_disconnected)


func _on_peer_connected(id: int) -> void:
	log_net("peer %d connected" % id)


func _on_peer_disconnected(id: int) -> void:
	log_net("peer %d disconnected" % id)
	if is_host():
		players.erase(id)
		manifests.erase(id)
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
	_rpc_register.rpc_id(1, PROTOCOL_VERSION, _pending_name, _pending_pack, voice_pack_manifest())
	connected_to_lobby.emit()


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
	_reset_session_state()
	server_disconnected.emit()
	if get_tree().get_root().has_node("World"): M.world.CreateMenu()




@rpc("any_peer", "call_remote", "reliable")
func _rpc_register(version: int, player_name: String, pack: String, manifest: Dictionary) -> void:
	if not is_host(): return
	var sender: int = multiplayer.get_remote_sender_id()
	if version != PROTOCOL_VERSION:
		_rpc_kick.rpc_id(sender, "Different mod version. Everyone needs the same build.")
		return
	if players.size() >= MAX_PLAYERS:
		_rpc_kick.rpc_id(sender, "Lobby is full (%d players max)." % MAX_PLAYERS)
		return
	log_net("'%s' joined (peer %d)" % [player_name, sender])
	players[sender] = _make_record(player_name, pack)
	manifests[sender] = manifest
	_rebuild_slots()
	_push_roster()
	_push_manifests()


@rpc("authority", "call_remote", "reliable")
func _rpc_kick(reason: String) -> void:
	connection_failed.emit(reason)
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
func voice_pack_manifest() -> Dictionary:
	if not _manifest_cache.is_empty(): return _manifest_cache
	var out: Dictionary = {}
	var root: String = FileManager.MODPACKS_VOICE
	for pack: String in DirAccess.get_directories_at(root):
		var entries: PackedStringArray = []
		var stack: Array[String] = [root.path_join(pack)]
		while not stack.is_empty():
			var dir_path: String = stack.pop_back()
			for sub: String in DirAccess.get_directories_at(dir_path):
				stack.append(dir_path.path_join(sub))
			for f: String in DirAccess.get_files_at(dir_path):
				if CLIP_EXTENSIONS.has(f.get_extension().to_lower()):
					entries.append(dir_path.trim_prefix(root).path_join(f))
		entries.sort()
		out[pack] = {"clips": entries.size(), "hash": "\n".join(entries).hash()}
	_manifest_cache = out
	return out


# everything off the wire is checked, a peer running a doctored build should
# only ever cost itself a warning line.
func _as_dictionary(value: Variant) -> Dictionary:
	if value is Dictionary: return value
	return {}


func pack_differences(other: Dictionary) -> PackedStringArray:
	var mine: Dictionary = voice_pack_manifest()
	var diffs: PackedStringArray = []
	for k: String in mine:
		if not other.has(k):
			diffs.append("'%s' -- they don't have this pack at all" % k)
			continue
		var ours: Dictionary = _as_dictionary(mine[k])
		var theirs: Dictionary = _as_dictionary(other[k])
		if theirs.has("hash") and ours.get("hash") == theirs.get("hash"): continue
		diffs.append("'%s' -- they have %d clip(s), you have %d" % [
			k, int(theirs.get("clips", 0)), int(ours.get("clips", 0))])
	for k: String in other:
		if not mine.has(k): diffs.append("'%s' -- you don't have this pack at all" % k)
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


func broadcast_dub_watch(playing: bool) -> void:
	if is_online(): _rpc_dub_watch.rpc(session_id, playing)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_dub_watch(sid: int, playing: bool) -> void:
	if sid != session_id: return
	dub_watch.emit(playing)




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
	var res: = GameplayResourceDubMode.new(folder)
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


func _abort_to_menu(reason: String) -> void:
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


func rebuild_clip_set(paths: PackedStringArray) -> PackedStringArray:
	var clips: Array[OmniClip] = []
	var missing: PackedStringArray = []
	for p: String in paths:
		var clip: = OmniClip.new(M.CLIP_USES.VOICE)
		clip.generate_from_audio_file_exact(p)
		if clip.clip_audio: clips.append(clip)
		else: missing.append(p)
	if missing.is_empty(): Metro.gameplay_omniclip_set = clips
	return missing


func _ready() -> void:
	match_should_start.connect(_on_match_should_start)
	dub_should_start.connect(_on_dub_should_start)


func _on_match_should_start(clip_paths: PackedStringArray) -> void:
	if is_host(): return
	var missing: PackedStringArray = rebuild_clip_set(clip_paths)
	if not missing.is_empty():
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
