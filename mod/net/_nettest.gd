extends Node
# dev tool, not shipped. run two copies with -- host and -- client.

func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty(): return
	match args[0]:
		"host": _run_host()
		"client": _run_client()


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


func _run_host() -> void:
	print("NETTEST | hosting...")
	var err: Error = Net.host_game("Hosty", "packA")
	print("NETTEST | host_game err=%d" % err)

	await get_tree().create_timer(4.0).timeout
	print("NETTEST | roster=%d slots=%s" % [Net.players.size(), str(Net.slot_map)])

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

	await get_tree().create_timer(2.0).timeout
	print("NETTEST | HOST DONE")
	get_tree().quit()


func _run_client() -> void:
	await get_tree().create_timer(1.5).timeout
	print("NETTEST | joining...")
	var err: Error = Net.join_game("127.0.0.1", "Clienty", "packB")
	print("NETTEST | join_game err=%d" % err)

	await get_tree().create_timer(3.5).timeout
	print("NETTEST | roster=%d slots=%s myslot=%d" % [Net.players.size(), str(Net.slot_map), Net.my_slot()])

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

	print("NETTEST | CLIENT DONE")
	get_tree().quit()
