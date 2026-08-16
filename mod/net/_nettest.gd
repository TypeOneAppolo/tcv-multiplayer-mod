extends Node
# dev tool, not shipped. run two copies with -- host and -- client.

# host takes Tuco, client takes Heisenberg. the untagged clip and the one for a
# character nobody picked are dealt out in turn, so they land on 0 then 1.
var CLIP_CHARACTERS: Array = [
	PackedStringArray(["Tuco"]),
	PackedStringArray(["Heisenberg"]),
	PackedStringArray(["Tuco"]),
	PackedStringArray([]),
	PackedStringArray(["Nobody"]),
]
var EXPECTED_OWNERS: PackedInt32Array = PackedInt32Array([0, 1, 0, 0, 1])

func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty(): return
	_check_handshake_ordering()
	match args[0]:
		"host": _run_host()
		"client": _run_client()


# the one invariant everything else rests on. Godot addresses an rpc by its index
# in the name sorted list of them, so the handshake only survives a version
# difference while it holds calls 0 and 1. Break this and two builds go back to
# staring at each other, which is the bug this test exists downstream of.
func _check_handshake_ordering() -> void:
	var names: Array[String] = []
	for m: Dictionary in Net.get_method_list():
		var n: String = str(m.get("name", ""))
		if n.begins_with("_HANDSHAKE") or n.begins_with("_rpc_"):
			if not names.has(n): names.append(n)
	names.sort()
	if names.size() > 1 and names[0] == "_HANDSHAKE" and names[1] == "_HANDSHAKE_REPLY":
		print("NETTEST PASS | handshake still holds calls 0 and 1")
	else:
		print("NETTEST FAIL | handshake is no longer first, rpc order starts %s" % str(names.slice(0, 3)))


func _fake_take() -> AudioStreamWAV:
	var w: = AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = 44100
	w.stereo = false
	var data: = PackedByteArray()
	data.resize(120000)
	for i: int in range(0, data.size(), 997): data[i] = 42
	w.data = data
	return w


func _write_test_bytes(path: String, count: int, marker: int) -> void:
	var data: PackedByteArray = []
	data.resize(count)
	for i: int in range(0, count, 997): data[i] = marker
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(data)
	file.close()


func _write_test_text(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _make_test_dub_pack() -> Dictionary:
	var root: String = "user://packsync-nettest-source"
	DirAccess.make_dir_recursive_absolute(root)
	# More than PackSync.SEND_WINDOW so this cannot pass without at least one
	# application acknowledgement opening the send window again.
	_write_test_bytes(root.path_join("dub_video.ogv"), 1200000, 7)
	_write_test_bytes(root.path_join("01_line.wav"), 90000, 11)
	_write_test_text(root.path_join("01_line.ini"), "caption=Network test\ndub_timestamps=1.25\n")
	_write_test_bytes(root.path_join("_backing_track.ogg"), 30000, 13)
	_write_test_text(root.path_join("_pack_info.ini"),
		"title=Network test\nbuild_nonce=%s-%d\n" % [
			Time.get_datetime_string_from_system(true, true), Time.get_ticks_usec()])
	return {"root": root, "clip": root.path_join("01_line.wav")}


func _run_host() -> void:
	print("NETTEST | hosting...")
	Net.pack_sync.enable_test_automation(false, true)
	var err: Error = Net.host_game("Hosty", "packA")
	print("NETTEST | host_game err=%d" % err)

	# Give the second headless process enough time to start on a cold machine.
	# Four seconds put the roster check and the join on the same frame and made
	# this smoke test occasionally run its first round with the host alone.
	await get_tree().create_timer(10.0).timeout
	print("NETTEST | roster=%d slots=%s" % [Net.players.size(), str(Net.slot_map)])
	if Net.manifests.size() == Net.players.size(): print("NETTEST PASS | host has a pack summary per player")
	else: print("NETTEST FAIL | host has %d summaries for %d players" % [Net.manifests.size(), Net.players.size()])

	var take: AudioStreamWAV = _fake_take()
	print("NETTEST | submitting %d bytes for slot 0" % take.data.size())
	await Net.submit_performance(0, {"max": PackedByteArray([1, 2, 3])}, take)
	print("NETTEST | host submit complete")

	await Net.barrier("t1")
	print("NETTEST | host cleared barrier")

	Net.publish_scores(PackedInt32Array([4, 2]))
	print("NETTEST | host published scores")

	await get_tree().create_timer(2.0).timeout
	Net.end_session()
	await get_tree().create_timer(1.0).timeout
	Net.begin_session()
	Net._rpc_start_match.rpc(Net.session_id, PackedStringArray())
	print("NETTEST | host began session %d" % Net.session_id)

	await get_tree().create_timer(2.0).timeout
	var take2: AudioStreamWAV = _fake_take()
	take2.data = take2.data.slice(0, 60000)
	print("NETTEST | submitting %d bytes for slot 0 (session 2)" % take2.data.size())
	await Net.submit_performance(0, {"max": PackedByteArray([9])}, take2)

	await Net.barrier("t1")
	print("NETTEST | host cleared barrier again")

	var test_pack: Dictionary = _make_test_dub_pack()
	var prepared: Dictionary = await Net.prepare_dub_pack(
		str(test_pack["root"]), PackedStringArray([str(test_pack["clip"])]))
	if prepared.is_empty():
		print("NETTEST FAIL | host pack preparation did not complete")
	else:
		print("NETTEST PASS | host waited until the client had the pack (%s)" % str(prepared["pack_id"]).left(12))
		Net.pack_sync._cancel_host_offer("PackSync network test complete.")

	Net.set_my_dub_characters(PackedStringArray(["Tuco"]))
	await get_tree().create_timer(2.5).timeout
	var owners: PackedInt32Array = Net.resolve_dub_owners(CLIP_CHARACTERS)
	print("NETTEST | roles=%s owners=%s" % [str(Net.dub_roles), str(owners)])
	if owners == EXPECTED_OWNERS: print("NETTEST PASS | host resolved the cast")
	else: print("NETTEST FAIL | host resolved %s, wanted %s" % [str(owners), str(EXPECTED_OWNERS)])
	Net.broadcast_dub_begin(owners)

	# the watch. pressing it must not start anything until everyone is sat on
	# their results screen -- the client below takes its time getting there on
	# purpose, the way a slow machine does while it scores the clips.
	var watched: Array = []
	Net.dub_watch.connect(func(playing: bool) -> void: watched.append(playing))
	Net.report_dub_finished()
	Net.request_dub_watch(true)
	await get_tree().create_timer(1.5).timeout
	if watched.is_empty(): print("NETTEST PASS | host held the watch back, someone was still scoring")
	else: print("NETTEST FAIL | host started the watch on its own: %s" % str(watched))

	await get_tree().create_timer(3.5).timeout
	if watched == [true]: print("NETTEST PASS | the watch went out once everyone was ready")
	else: print("NETTEST FAIL | host watch signals were %s, wanted [true]" % str(watched))

	await get_tree().create_timer(2.0).timeout
	print("NETTEST | HOST DONE")
	get_tree().quit()


func _run_client() -> void:
	await get_tree().create_timer(1.5).timeout
	print("NETTEST | joining...")
	Net.pack_sync.enable_test_automation(false, false)
	Net.pack_sync.set_test_cache_root("user://packsync-nettest-client-cache")
	var err: Error = Net.join_game("127.0.0.1", "Clienty", "packB")
	print("NETTEST | join_game err=%d" % err)

	await get_tree().create_timer(3.5).timeout
	print("NETTEST | roster=%d slots=%s myslot=%d" % [Net.players.size(), str(Net.slot_map), Net.my_slot()])
	if Net.manifests.has(1): print("NETTEST PASS | client has the host's pack summary")
	else: print("NETTEST FAIL | client never got the host's pack summary")

	var perf: Dictionary = await Net.await_performance(0)
	var got: int = perf["wav"].data.size() if perf.has("wav") else -1
	print("NETTEST | client received take: %d bytes, plmic=%s" % [got, str(perf.get("plmic", {}))])

	await Net.barrier("t1")
	print("NETTEST | client cleared barrier")

	var scores: PackedInt32Array = await Net.await_scores()
	print("NETTEST | client received scores=%s" % str(scores))

	var first_session: int = Net.session_id
	while Net.session_id == first_session: await get_tree().process_frame
	print("NETTEST | client entered session %d" % Net.session_id)

	var perf2: Dictionary = await Net.await_performance(0)
	var got2: int = perf2["wav"].data.size() if perf2.has("wav") else -1
	print("NETTEST | client received take: %d bytes, plmic=%s" % [got2, str(perf2.get("plmic", {}))])
	if got2 == 60000: print("NETTEST PASS | second session take is the new one")
	else: print("NETTEST FAIL | second session returned %d bytes (stale inbox)" % got2)

	await Net.barrier("t1")
	print("NETTEST | client cleared barrier again")

	var received_pack: Array[String] = []
	Net.pack_sync.pack_ready.connect(func(pack_id: String, path: String) -> void:
		received_pack.assign([pack_id, path]))
	var offer_waited: float = 0.0
	while Net.pack_sync._client_state not in ["offered", "ready", "failed"] and offer_waited < 10.0:
		await get_tree().process_frame
		offer_waited += get_process_delta_time()
	if Net.pack_sync._client_state == "offered":
		Net.pack_sync.decline_download()
		await get_tree().process_frame
		if Net.pack_sync._client_state == "declined":
			print("NETTEST PASS | client could decline the offered pack without losing it")
		else:
			print("NETTEST FAIL | client decline did not stick")
		# Retry immediately, then interrupt once more after bytes are on disk. The
		# second retry exercises both resume offsets and stale-chunk rejection.
		Net.pack_sync.accept_download()
		var partial_waited: float = 0.0
		while (Net.pack_sync._client_state == "downloading"
			and Net.pack_sync._client_received < 150000 and partial_waited < 5.0):
			await get_tree().process_frame
			partial_waited += get_process_delta_time()
		if (Net.pack_sync._client_state == "downloading"
			and Net.pack_sync._client_received < int(Net.pack_sync._active_offer["total_bytes"])):
			var partial_bytes: int = Net.pack_sync._client_received
			Net.pack_sync.decline_download()
			await get_tree().process_frame
			Net.pack_sync.accept_download()
			if Net.pack_sync._client_received >= partial_bytes:
				print("NETTEST PASS | interrupted pack download resumed from %d bytes" % partial_bytes)
			else:
				print("NETTEST FAIL | interrupted pack download restarted from zero")
		else:
			print("NETTEST FAIL | pack transfer finished before its resume path could be tested")
	elif Net.pack_sync._client_state == "failed":
		print("NETTEST FAIL | client rejected the pack offer: %s" % Net.pack_sync._client_error)
	var pack_waited: float = 0.0
	while received_pack.is_empty() and pack_waited < 20.0:
		await get_tree().process_frame
		pack_waited += get_process_delta_time()
	if received_pack.is_empty():
		print("NETTEST FAIL | client did not receive the offered pack")
	else:
		var received_root: String = received_pack[1]
		var complete: bool = (
			FileAccess.file_exists(received_root.path_join("dub_video.ogv"))
			and FileAccess.file_exists(received_root.path_join("01_line.wav"))
			and FileAccess.get_sha256(received_root.path_join("01_line.wav"))
				== FileAccess.get_sha256("user://packsync-nettest-source/01_line.wav"))
		if complete: print("NETTEST PASS | client cached and verified the streamed dub pack")
		else: print("NETTEST FAIL | client pack cache is incomplete or corrupt")

	Net.set_my_dub_characters(PackedStringArray(["Heisenberg"]))
	await Net.dub_begin
	print("NETTEST | client roles=%s owners=%s" % [str(Net.dub_roles), str(Net.dub_clip_owners)])
	if Net.dub_clip_owners == EXPECTED_OWNERS: print("NETTEST PASS | client agrees on the cast")
	else: print("NETTEST FAIL | client got %s, wanted %s" % [str(Net.dub_clip_owners), str(EXPECTED_OWNERS)])

	var watched: Array = []
	Net.dub_watch.connect(func(playing: bool) -> void: watched.append(playing))
	# slow off the mark on purpose. the host presses Watch well before this.
	await get_tree().create_timer(3.0).timeout
	if not watched.is_empty(): print("NETTEST FAIL | client was watching before it said it was ready")
	Net.report_dub_finished()

	await get_tree().create_timer(2.5).timeout
	if watched == [true]: print("NETTEST PASS | client was told to watch")
	else: print("NETTEST FAIL | client watch signals were %s, wanted [true]" % str(watched))

	print("NETTEST | CLIENT DONE")
	get_tree().quit()
