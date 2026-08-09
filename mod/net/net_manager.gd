extends Node
## Multiplayer backbone for The Choicer Voicer.
##
## The base game is already turn-based: contestants record one at a time, and a
## contestant's score is derived entirely from `round_plmic_data` (three small
## PackedByteArrays). That means we never need realtime state sync -- we only
## need to (a) agree on whose turn it is, (b) ship one performance per turn, and
## (c) keep everyone on the same phase of the round.
##
## Topology: ENet client/server, host-authoritative. Host is always slot 0.
## Server relay is on by default, so a client `rpc()` reaches every other peer.

signal player_list_changed
signal connection_failed(reason: String)
signal connected_to_lobby
signal server_disconnected
signal match_should_start(clip_paths: PackedStringArray)
signal performance_received(slot: int)
signal scores_received(scores: PackedInt32Array)

const PORT: int = 7654
const MAX_PLAYERS: int = 4
const PROTOCOL_VERSION: int = 1
## ENet fragments reliable packets for us, but keeping chunks well under the
## default MTU budget avoids stalling the channel while a 500 KB take transfers.
const CHUNK_SIZE: int = 24576
## Nothing may block the match forever. If a peer crashes or alt-F4s, everyone
## else carries on after these instead of freezing on a black screen.
const PERFORMANCE_TIMEOUT: float = 60.0
const BARRIER_TIMEOUT: float = 90.0


## Everything here lands in user://logs/choicervoicer.log via file logging.
func log_net(msg: String) -> void:
	print("[NET %s] %s" % [Time.get_time_string_from_system(), msg])

enum MODE {OFFLINE, HOST, CLIENT}

var mode: MODE = MODE.OFFLINE
## peer_id -> {name, pack, ready, manifest}
var players: Dictionary = {}
## slot index -> peer_id, rebuilt by the host on every roster change.
var slot_map: PackedInt32Array = []

var _perf_inbox: Dictionary = {}
var _perf_staging: Dictionary = {}
var _barriers: Dictionary = {}
## Tags the host has already released this session. A peer that showed up after
## the host stopped waiting used to recreate the entry the host had just erased,
## and that ghost then satisfied the SAME tag on sight next time round.
var _barriers_done: Dictionary = {}

## Bumped by the host for every show it starts, and adopted by everyone on the
## way in. Round state is keyed by round number and contestant slot, and both of
## those restart at zero, so with nothing to tell one show from the next the
## leftovers of a finished match looked exactly like the new one: takes arrived
## "already received", barriers opened on sight, and the second pack of the
## evening played itself through. Every round-scoped RPC carries this stamp and
## is dropped when it does not match.
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
	players[1] = _make_record(player_name, pack)
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
	_pending_name = player_name
	_pending_pack = pack
	return OK


func leave() -> void:
	if multiplayer.multiplayer_peer: multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	mode = MODE.OFFLINE
	players.clear()
	slot_map = []
	_reset_session_state()
	player_list_changed.emit()




## Everything below is scoped to a single show and must not survive it. Leaving
## any of it behind is what made the match after the first one unplayable.
func _reset_session_state() -> void:
	_perf_inbox.clear()
	_perf_staging.clear()
	_barriers.clear()
	_barriers_done.clear()
	_barrier_released.clear()
	_end_round_queue.clear()
	_dub_begin_pending = false
	_scores_inbox = PackedInt32Array()
	_scores_waiting = false


## Called on every machine as it enters a show: the host stamps a fresh id, the
## followers adopt the host's. Doing it on the way IN as well as on the way out
## means a crash, an alt-F4 or a missed exit cannot poison the next match.
func begin_session(id: int = -1) -> void:
	_reset_session_state()
	if id >= 0: session_id = id
	else: session_id += 1
	log_net("session %d begins" % session_id)


## Called when a match or dub hands back to a menu. Retires the id so anything
## still in flight from the show that just ended is discarded on arrival, and
## clears the ready flags so the lobby is usable for the next pack.
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
	return {
		"name": player_name,
		"pack": pack,
		"ready": false,
		"manifest": voice_pack_manifest(),
	}


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
		_rebuild_slots()
		_push_roster()
	player_list_changed.emit()


func _on_connected_to_server() -> void:
	log_net("connected to host, registering as '%s'" % _pending_name)
	_rpc_register.rpc_id(1, PROTOCOL_VERSION, _pending_name, _pending_pack, voice_pack_manifest())
	connected_to_lobby.emit()


func _on_connection_failed() -> void:
	log_net("connection to host failed")
	mode = MODE.OFFLINE
	connection_failed.emit("Could not reach the host. Check the IP, the port, and that they are hosting.")


## The host vanishing used to leave followers frozen mid-match with no way out.
func _on_server_disconnected() -> void:
	log_net("host closed the connection, returning to menu")
	mode = MODE.OFFLINE
	players.clear()
	slot_map = []
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
	players[sender] = {"name": player_name, "pack": pack, "ready": false, "manifest": manifest}
	_rebuild_slots()
	_push_roster()


@rpc("authority", "call_remote", "reliable")
func _rpc_kick(reason: String) -> void:
	connection_failed.emit(reason)
	leave()


func _rebuild_slots() -> void:
	if not is_host(): return
	var ids: Array = players.keys()
	ids.sort()
	## Host always takes slot 0 so contestant 0 is the machine driving the show.
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




## Fingerprint of the installed voice packs, so we can refuse to start a match
## where players would be scored against clips they do not have.
const CLIP_EXTENSIONS: PackedStringArray = ["wav", "mp3", "ogg"]

## One hash per pack, over audio file names only. Captions, readmes and pack
## icons differ harmlessly between installs, and packs nobody is playing are
## irrelevant -- hashing all of it produced constant false mismatches.
func voice_pack_manifest() -> Dictionary:
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
		out[pack] = entries
	return out


## Advisory only -- the match is gated on the clips actually chosen, not this.
## Reports the offending file names, because "different clips inside" tells a
## player nothing about what to actually fix.
func pack_differences(other: Dictionary) -> PackedStringArray:
	var mine: Dictionary = voice_pack_manifest()
	var diffs: PackedStringArray = []
	for k: String in mine:
		if not other.has(k):
			diffs.append("'%s' -- they don't have this pack at all" % k)
			continue
		var ours: PackedStringArray = PackedStringArray(mine[k])
		var theirs: PackedStringArray = PackedStringArray(other[k])
		var they_lack: PackedStringArray = []
		var they_have_extra: PackedStringArray = []
		for f: String in ours:
			if not theirs.has(f): they_lack.append(f.get_file())
		for f: String in theirs:
			if not ours.has(f): they_have_extra.append(f.get_file())
		if they_lack.is_empty() and they_have_extra.is_empty(): continue
		var bits: PackedStringArray = []
		if not they_lack.is_empty():
			bits.append("they're missing %d (%s)" % [they_lack.size(), ", ".join(they_lack.slice(0, 4))])
		if not they_have_extra.is_empty():
			bits.append("they have %d you don't (%s)" % [they_have_extra.size(), ", ".join(they_have_extra.slice(0, 4))])
		diffs.append("'%s' -- %s" % [k, "; ".join(bits)])
	for k: String in other:
		if not mine.has(k): diffs.append("'%s' -- you don't have this pack at all" % k)
	return diffs


func mismatched_players() -> PackedStringArray:
	var out: PackedStringArray = []
	for id: int in players:
		if id == my_id(): continue
		var diffs: PackedStringArray = pack_differences(players[id].get("manifest", {}))
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


## Called by the peer that just recorded. Ships the waveform data (used for
## scoring) plus the raw take (so everyone can hear it) to every other peer.
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
		## Bail if the show ended mid-upload -- the rest of these chunks would
		## arrive during whatever comes next.
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


## Blocks until the take for `slot` has fully arrived, or until that player is
## gone. Never blocks forever -- a crashed peer used to freeze everybody.
## `key` identifies the take (a contestant slot in match mode, a clip index in
## dub mode). `owner_slot` says which player owes it, when that differs.
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
		## The show this take belonged to is over; whoever is still awaiting it
		## is a leftover from it and must not block the new one.
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




## Host scores every contestant so a float rounding difference on one machine
## can never produce two different leaderboards.
func publish_scores(scores: PackedInt32Array) -> void:
	if not is_host(): return
	_rpc_scores.rpc(session_id, scores)
	scores_received.emit(scores)


## Banked for the same reason as the end-of-round choice: the host finishes
## scoring while a follower is still animating its way there, and a follower
## that started awaiting the signal one frame too late waited for a round that
## had already been decided.
var _scores_inbox: PackedInt32Array = []
var _scores_waiting: bool = false


@rpc("authority", "call_remote", "reliable")
func _rpc_scores(sid: int, scores: PackedInt32Array) -> void:
	if sid != session_id: return
	_scores_inbox = scores
	_scores_waiting = true
	scores_received.emit(scores)


## Returns an empty array if the show ends before the host scores the round.
func await_scores() -> PackedInt32Array:
	var sid: int = session_id
	while not _scores_waiting:
		if not is_online() or session_id != sid: return PackedInt32Array()
		await get_tree().process_frame
	_scores_waiting = false
	return _scores_inbox




## Phase barrier: nobody leaves a round stage until every peer has arrived.
## Keeps host dialogue, camera cuts and recording prompts lined up without
## having to sync anything frame-by-frame.
func barrier(tag: String) -> void:
	if not is_online(): return
	log_net("barrier '%s' reached" % tag)
	var waited: float = 0.0
	var sid: int = session_id
	if is_host():
		## Merge rather than assign -- a fast client can arrive before we do.
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
	## Already released. Recording the latecomer would leave an entry nothing
	## ever erases, and every barrier tag repeats verbatim in the next match.
	if _barriers_done.has(tag): return
	if not _barriers.has(tag): _barriers[tag] = {}
	_barriers[tag][multiplayer.get_remote_sender_id()] = true


@rpc("authority", "call_remote", "reliable")
func _rpc_barrier_release(sid: int, tag: String) -> void:
	if sid != session_id: return
	_barrier_released[tag] = true




## The show is driven by the host's clicks. Dialogue, skips and the end-of-round
## menu never advance on their own, so without this every machine would sit on a
## different sentence until the next barrier yanked it forward.
signal dialogue_state(idx: int, active: bool, revealed: bool)
signal dialogue_skip
signal match_skip
signal end_round_choice(choice: int)

## True when this peer is only allowed to watch the host drive the show.
func is_spectator() -> bool: return is_online() and not is_host()


## Sends the host's resulting dialogue position rather than the click itself.
## A click means different things depending on how far the typewriter has got
## locally, so replaying the click elsewhere can strand a follower one line
## behind for the rest of the match.
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


## Queued rather than delivered by signal alone. A follower reaches the
## end-of-round menu a moment after the host does -- it is still writing its
## takes to disk -- and a choice made in that window used to vanish, leaving it
## parked on the results screen for the rest of the evening.
var _end_round_queue: Array[int] = []


func broadcast_end_round_choice(choice: int) -> void:
	if is_online(): _rpc_end_round_choice.rpc(session_id, choice)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_end_round_choice(sid: int, choice: int) -> void:
	if sid != session_id: return
	_end_round_queue.append(choice)
	end_round_choice.emit(choice)


## Followers take the host's choices from here, one per press, in order.
## Returns -1 if the show ends while waiting.
func await_end_round_choice() -> int:
	var sid: int = session_id
	while _end_round_queue.is_empty():
		if not is_online() or session_id != sid: return -1
		await get_tree().process_frame
	return _end_round_queue.pop_front()




## Dub mode: players take turns dubbing alternating clips, then everyone
## watches the finished dub together. The pack is rebuilt from its folder on
## each machine; only the clip ORDER needs syncing, since the host may shuffle.
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


## Banked, because the host can press Begin while a follower's dub scene is
## still loading. A missed start left that follower sitting on the idle screen
## with no button to press.
var _dub_begin_pending: bool = false


func broadcast_dub_begin() -> void:
	if is_online(): _rpc_dub_begin.rpc(session_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_dub_begin(sid: int) -> void:
	if sid != session_id: return
	_dub_begin_pending = true
	dub_begin.emit()


## True once, for a dub scene that came up after the host had already started.
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


func _on_dub_should_start(folder: String, clip_paths: PackedStringArray) -> void:
	if is_host(): return
	var res: = GameplayResourceDubMode.new(folder)
	if res.failed_to_load or res.no_video_file:
		_abort_to_menu("Cannot start: you don't have the dub pack '%s'." % folder.trim_suffix("/").get_file())
		return

	## Rebuild the host's exact clip order -- they may have shuffled or sorted.
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




## Turn the network roster into the session data the match scene already reads,
## so `GENERIC_setup_from_metro()` works unchanged.
func apply_roster_to_metro() -> void:
	var members: Array[BasicPlayerPackage] = []
	for slot: int in slot_map.size():
		var peer: int = slot_map[slot]
		var pack: String = players.get(peer, {}).get("pack", "")
		## Device name is unused online -- each machine records on its own mic.
		members.append(BasicPlayerPackage.new(pack, ""))
	Metro.current_players = members


## The host shuffles the clip order, so clients cannot regenerate it. They
## rebuild the exact same set from the host's file paths instead.
## Returns the clips this machine could not find. Skipping them silently used
## to leave a follower with fewer rounds than the host, which crashed as soon as
## the host advanced past the end of the follower's shorter list.
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
	## The host is already inside its own menu flow and will start the match
	## itself; only followers need to be pushed into the match scene.
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
