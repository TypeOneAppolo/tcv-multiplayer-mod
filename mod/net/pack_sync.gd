extends Node
# Host-to-client dub-pack transfer. This is a child of the Net autoload instead
# of more code on Net itself: Godot numbers RPCs by their sorted name within a
# node, and keeping this protocol on /root/Net/PackSync means it cannot move the
# join handshake that has to survive old builds.

signal pack_ready(pack_id: String, local_path: String)
signal state_changed

const CACHE_ROOT: String = "user://multiplayer_pack_cache"
const COMPLETE_MARKER: String = ".net-pack-complete"

const CHUNK_SIZE: int = 24576
const SEND_WINDOW: int = 98304
const STALL_TIMEOUT_MSEC: int = 45000
const FREE_SPACE_MARGIN: int = 64 * 1024 * 1024

const MAX_FILES: int = 2048
const MAX_PACK_BYTES: int = 4 * 1024 * 1024 * 1024
const MAX_FILE_BYTES: int = 2 * 1024 * 1024 * 1024
const MAX_PATH_LENGTH: int = 512
const MAX_MANIFEST_TEXT: int = 2 * 1024 * 1024
const MANIFEST_FILES_PER_PAGE: int = 32

# These are all inert data formats the base game's external pack loader may
# consume. Never accept scripts, libraries, executables, archives or PCKs from a
# peer. Unknown files are left behind on the host rather than copied blindly.
const SAFE_EXTENSIONS: PackedStringArray = [
	"wav", "mp3", "ogg", "ogv",
	"ini", "cfg", "json", "txt", "md",
	"png", "jpg", "jpeg", "webp", "bmp", "tga", "svg", "dds", "exr", "hdr",
]
const AUDIO_EXTENSIONS: PackedStringArray = ["wav", "mp3", "ogg"]

var _net: Node
var _cache_root: String = CACHE_ROOT

var _active_offer: Dictionary = {}
var _incoming_offer: Dictionary = {}
var _incoming_files: Array = []
var _incoming_page: int = 0
var _incoming_manifest_chars: int = 0
var _host_folder: String = ""
var _pack_paths: Dictionary = {}
var _peer_states: Dictionary = {}
var _host_acks: Dictionary = {}
var _transfer_tokens: Dictionary = {}
var _offer_serial: int = 0
var _prepare_generation: int = 0
var _host_decision: int = 0

var _client_state: String = "idle"
var _client_error: String = ""
var _client_received: int = 0
var _client_transfer_id: int = 0
var _download_file: FileAccess
var _download_index: int = -1
var _download_offset: int = 0
var _render_queued: bool = false

var _layer: CanvasLayer
var _panel: PanelContainer
var _title: Label
var _detail: Label
var _roster: Label
var _progress: ProgressBar
var _primary: Button
var _secondary: Button

# Used only by the headless network smoke test. Production always requires the
# client and host to press the visible buttons.
var _test_auto_accept: bool = false
var _test_auto_begin: bool = false


func configure(net: Node) -> void:
	_net = net
	if not _net.player_list_changed.is_connected(_on_roster_changed):
		_net.player_list_changed.connect(_on_roster_changed, CONNECT_DEFERRED)


func enable_test_automation(auto_accept: bool, auto_begin: bool) -> void:
	_test_auto_accept = auto_accept
	_test_auto_begin = auto_begin


func set_test_cache_root(path: String) -> void:
	if OS.is_debug_build() and path.begins_with("user://"):
		_cache_root = path.trim_suffix("/")


func _ready() -> void:
	_build_ui()


func reset() -> void:
	_prepare_generation += 1
	_close_download_file()
	_active_offer.clear()
	_incoming_offer.clear()
	_incoming_files.clear()
	_incoming_page = 0
	_incoming_manifest_chars = 0
	_host_folder = ""
	_peer_states.clear()
	_host_acks.clear()
	_transfer_tokens.clear()
	_host_decision = -1
	_client_state = "idle"
	_client_error = ""
	_client_received = 0
	_client_transfer_id = 0
	_hide_panel.call_deferred()
	_emit_state_changed.call_deferred()


func dismiss_for_start(pack_id: String) -> void:
	if str(_active_offer.get("pack_id", "")) == pack_id and is_instance_valid(_panel):
		_panel.visible = false


func local_path_for(pack_id: String) -> String:
	return str(_pack_paths.get(pack_id, ""))


func local_clip_paths(pack_id: String, relative_paths: PackedStringArray) -> PackedStringArray:
	var root: String = local_path_for(pack_id).replace("\\", "/").trim_suffix("/")
	if root.is_empty(): return PackedStringArray()
	var out: PackedStringArray = []
	for relative: String in relative_paths:
		if not _safe_relative_path(relative) or not AUDIO_EXTENSIONS.has(relative.get_extension().to_lower()):
			return PackedStringArray()
		var full: String = root.path_join(relative).replace("\\", "/").simplify_path()
		if not full.begins_with(root + "/"): return PackedStringArray()
		out.append(full)
	return out


func prepare_dub(folder: String, clip_paths: PackedStringArray) -> Dictionary:
	if _net == null or not _net.is_host() or not _net.is_online(): return {}
	if not _active_offer.is_empty(): _cancel_host_offer("The host chose another dub pack.")
	_prepare_generation += 1
	var generation: int = _prepare_generation

	_host_folder = folder.trim_suffix("/").replace("\\", "/")
	_host_decision = 0
	_client_error = ""
	_show_scanning()

	var thread: = Thread.new()
	var start_error: Error = thread.start(_build_manifest.bind(_host_folder))
	if start_error != OK:
		_show_host_error("Could not start the pack scan (error %d)." % start_error)
		return {}
	var abandoned: bool = false
	while thread.is_alive():
		if generation != _prepare_generation or not _net.is_online() or not _net.is_host():
			abandoned = true
		await get_tree().process_frame
	var built: Dictionary = thread.wait_to_finish()
	if abandoned or generation != _prepare_generation: return {}
	if _host_decision < 0:
		reset()
		return {}
	if built.has("error"):
		_show_host_error(str(built["error"]))
		return {}

	var relative_clips: PackedStringArray = []
	var known_paths: Dictionary = {}
	for item: Dictionary in built.get("files", []): known_paths[str(item["path"])] = true
	for path: String in clip_paths:
		var relative: String = _relative_path(_host_folder, path)
		if relative.is_empty() or not known_paths.has(relative):
			_show_host_error("The selected clip is outside the pack or was not safe to transfer: %s" % path.get_file())
			return {}
		relative_clips.append(relative)

	_offer_serial += 1
	var pack_id: String = str(built["pack_id"])
	_active_offer = {
		"id": "%s:%d:%d" % [pack_id, Time.get_ticks_msec(), _offer_serial],
		"pack_id": pack_id,
		"name": _host_folder.get_file(),
		"folder_name": _host_folder.get_file(),
		"total_bytes": int(built["total_bytes"]),
		"files": built["files"],
		"clips": Array(relative_clips),
		"ignored": int(built.get("ignored", 0)),
	}
	_pack_paths[pack_id] = _host_folder
	_peer_states.clear()
	_peer_states[1] = _state_record("ready", int(built["total_bytes"]), "")
	for peer: int in _net.players:
		if peer != 1: _peer_states[peer] = _state_record("checking", 0, "")

	_net.log_net("offering dub pack '%s' (%s, %d files)" % [
		_active_offer["name"], _format_bytes(int(_active_offer["total_bytes"])),
		Array(_active_offer["files"]).size()])
	for peer: int in _net.players:
		if peer != 1: _send_offer_manifest.call_deferred(peer, str(_active_offer["id"]))
	_queue_render()

	while _host_decision == 0:
		if generation != _prepare_generation: return {}
		if not _net.is_online() or not _net.is_host():
			reset()
			return {}
		if _test_auto_begin and _all_players_ready(): _host_decision = 1
		await get_tree().process_frame

	if _host_decision < 0:
		if not _active_offer.is_empty(): _cancel_host_offer("The host canceled this dub pack.")
		return {}

	var result: Dictionary = {
		"pack_id": pack_id,
		"clip_paths": relative_clips,
	}
	if is_instance_valid(_panel): _panel.visible = false
	return result


func _build_manifest(root: String) -> Dictionary:
	if not DirAccess.dir_exists_absolute(root): return {"error": "The selected dub-pack folder no longer exists."}
	var files: Array[Dictionary] = []
	var stack: Array[String] = [root]
	var ignored: int = 0
	var total: int = 0

	while not stack.is_empty():
		var current: String = stack.pop_back()
		var dir: DirAccess = DirAccess.open(current)
		if dir == null: return {"error": "Could not read the dub-pack folder: %s" % current}
		dir.list_dir_begin()
		var name: String = dir.get_next()
		while not name.is_empty():
			if name == "." or name == "..":
				name = dir.get_next()
				continue
			if dir.is_link(name):
				ignored += 1
				name = dir.get_next()
				continue
			var full: String = current.path_join(name).replace("\\", "/")
			if dir.current_is_dir():
				stack.append(full)
			else:
				var relative: String = _relative_path(root, full)
				if not _host_file_is_safe(relative):
					ignored += 1
					name = dir.get_next()
					continue
				var size: int = _file_size(full)
				if size < 0: return {"error": "Could not read %s." % relative}
				if size > MAX_FILE_BYTES: return {"error": "%s is larger than the %s per-file limit." % [relative, _format_bytes(MAX_FILE_BYTES)]}
				total += size
				if total > MAX_PACK_BYTES: return {"error": "This pack is larger than the %s transfer limit." % _format_bytes(MAX_PACK_BYTES)}
				var sha: String = FileAccess.get_sha256(full)
				if sha.is_empty(): return {"error": "Could not checksum %s." % relative}
				files.append({"path": relative, "size": size, "sha256": sha})
				if files.size() > MAX_FILES: return {"error": "This pack contains more than %d transferable files." % MAX_FILES}
			name = dir.get_next()
		dir.list_dir_end()

	files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["path"]) < str(b["path"]))
	var has_video: bool = false
	var canonical: String = ""
	for item: Dictionary in files:
		if str(item["path"]).to_lower() == "dub_video.ogv": has_video = true
		canonical += "%d:%s:%d:%s\n" % [
			str(item["path"]).length(), item["path"], item["size"], item["sha256"]]
	if not has_video: return {"error": "The selected folder has no root-level dub_video.ogv."}
	if files.is_empty(): return {"error": "The selected dub pack contains no transferable files."}
	if canonical.length() > MAX_MANIFEST_TEXT: return {"error": "The pack manifest is too large to send safely."}
	return {
		"pack_id": canonical.sha256_text(),
		"files": files,
		"total_bytes": total,
		"ignored": ignored,
	}


func _host_file_is_safe(relative: String) -> bool:
	if not _safe_relative_path(relative): return false
	var file_name: String = relative.get_file()
	var extension: String = file_name.get_extension().to_lower()
	if not SAFE_EXTENSIONS.has(extension): return false
	# The base game creates underscore-prefixed recordings of its own. They are
	# output, not pack input. The backing track is the intentional exception.
	if AUDIO_EXTENSIONS.has(extension) and file_name.begins_with("_"):
		return file_name.get_basename().to_lower() == "_backing_track"
	return true


func _safe_relative_path(path: String) -> bool:
	if path.is_empty() or path.length() > MAX_PATH_LENGTH: return false
	if path.contains("\\") or path.contains(":") or path.begins_with("/"): return false
	if path.contains("\n") or path.contains("\r") or path.contains("\t"): return false
	if path != path.simplify_path(): return false
	for part: String in path.split("/"):
		if part.is_empty() or part == "." or part == "..": return false
	return true


func _relative_path(root: String, full_path: String) -> String:
	var clean_root: String = root.replace("\\", "/").trim_suffix("/").simplify_path()
	var clean_full: String = full_path.replace("\\", "/").simplify_path()
	var prefix: String = clean_root + "/"
	if not clean_full.begins_with(prefix): return ""
	var relative: String = clean_full.substr(prefix.length())
	return relative if _safe_relative_path(relative) else ""


func _valid_offer(value: Variant) -> String:
	if not (value is Dictionary): return "The host sent an invalid pack offer."
	var offer: Dictionary = value
	var offer_id: String = str(offer.get("id", ""))
	var pack_id: String = str(offer.get("pack_id", ""))
	if offer_id.is_empty() or offer_id.length() > 160: return "The pack offer has an invalid ID."
	if not _valid_sha256(pack_id): return "The pack offer has an invalid content hash."
	var files_value: Variant = offer.get("files", null)
	if not (files_value is Array): return "The pack offer has no valid file manifest."
	var files: Array = files_value
	if files.is_empty() or files.size() > MAX_FILES: return "The pack offer contains an invalid number of files."

	var paths: Dictionary = {}
	var total: int = 0
	var has_video: bool = false
	var canonical: String = ""
	for value_item: Variant in files:
		if not (value_item is Dictionary): return "The pack offer contains an invalid file entry."
		var item: Dictionary = value_item
		var path: String = str(item.get("path", ""))
		var size: int = int(item.get("size", -1))
		var sha: String = str(item.get("sha256", ""))
		if not _safe_relative_path(path): return "The pack offer contains an unsafe path."
		if paths.has(path): return "The pack offer contains the same path twice."
		if not SAFE_EXTENSIONS.has(path.get_extension().to_lower()): return "The pack offer contains an unsupported file type."
		if size < 0 or size > MAX_FILE_BYTES: return "The pack offer contains an invalid file size."
		if not _valid_sha256(sha): return "The pack offer contains an invalid file checksum."
		paths[path] = true
		total += size
		if total > MAX_PACK_BYTES: return "The offered pack is larger than the transfer limit."
		if path.to_lower() == "dub_video.ogv": has_video = true
		canonical += "%d:%s:%d:%s\n" % [path.length(), path, size, sha]
	if not has_video: return "The offered pack has no root-level dub_video.ogv."
	if int(offer.get("total_bytes", -1)) != total: return "The pack offer's total size is inconsistent."
	if canonical.length() > MAX_MANIFEST_TEXT or canonical.sha256_text() != pack_id:
		return "The pack offer's content hash is inconsistent."

	var clips_value: Variant = offer.get("clips", null)
	if not (clips_value is Array): return "The pack offer has no valid clip list."
	if Array(clips_value).size() > files.size(): return "The pack offer contains too many selected clips."
	for clip_value: Variant in clips_value:
		var clip: String = str(clip_value)
		if not _safe_relative_path(clip) or not paths.has(clip): return "The pack offer references a missing clip."
		if not AUDIO_EXTENSIONS.has(clip.get_extension().to_lower()): return "The pack offer references a non-audio clip."
	return ""


func _valid_sha256(value: String) -> bool:
	if value.length() != 64: return false
	for i: int in value.length():
		var c: String = value.substr(i, 1).to_lower()
		if not "0123456789abcdef".contains(c): return false
	return true


@rpc("authority", "call_remote", "reliable", 1)
func _rpc_pack_offer_begin(summary: Dictionary) -> void:
	if _net == null or _net.is_host(): return
	var offer_id: String = str(summary.get("id", ""))
	var pack_id: String = str(summary.get("pack_id", ""))
	var pack_name: String = str(summary.get("name", "Dub pack"))
	var folder_name: String = str(summary.get("folder_name", ""))
	var count: int = int(summary.get("file_count", -1))
	var total: int = int(summary.get("total_bytes", -1))
	if (offer_id.is_empty() or offer_id.length() > 160 or not _valid_sha256(pack_id)
		or pack_name.is_empty() or pack_name.length() > 256 or folder_name.length() > 256
		or count <= 0 or count > MAX_FILES or total < 0 or total > MAX_PACK_BYTES):
		_active_offer = {"id": offer_id, "pack_id": pack_id, "total_bytes": maxi(0, total)}
		_client_fail("The host sent an invalid pack summary.")
		return
	if str(_active_offer.get("id", "")) == offer_id: return
	_close_download_file()
	_incoming_offer = {
		"id": offer_id,
		"pack_id": pack_id,
		"name": pack_name,
		"folder_name": folder_name,
		"total_bytes": total,
		"file_count": count,
		"ignored": clampi(int(summary.get("ignored", 0)), 0, MAX_FILES),
	}
	_incoming_files = []
	_incoming_page = 0
	_incoming_manifest_chars = 0
	_active_offer = _incoming_offer.duplicate(true)
	_client_state = "checking"
	_client_error = ""
	_client_received = 0
	_queue_render()
	_send_client_state("checking")


@rpc("authority", "call_remote", "reliable", 1)
func _rpc_pack_offer_files(offer_id: String, page: int, pages: int, files: Array) -> void:
	if _net == null or _net.is_host() or offer_id != str(_incoming_offer.get("id", "")): return
	var file_count: int = int(_incoming_offer.get("file_count", 0))
	var expected_pages: int = int((file_count + MANIFEST_FILES_PER_PAGE - 1) / MANIFEST_FILES_PER_PAGE)
	var expected_files: int = mini(MANIFEST_FILES_PER_PAGE, file_count - page * MANIFEST_FILES_PER_PAGE)
	if (page != _incoming_page or pages != expected_pages or files.is_empty()
		or files.size() != expected_files):
		_reject_incoming_offer("The host sent the pack manifest out of order.")
		return
	var clean_files: Array[Dictionary] = []
	for value_item: Variant in files:
		if not (value_item is Dictionary):
			_reject_incoming_offer("The host sent an invalid pack-manifest entry.")
			return
		var item: Dictionary = value_item
		var path: String = str(item.get("path", ""))
		var size: int = int(item.get("size", -1))
		var sha: String = str(item.get("sha256", ""))
		if (not _safe_relative_path(path) or not SAFE_EXTENSIONS.has(path.get_extension().to_lower())
			or size < 0 or size > MAX_FILE_BYTES or not _valid_sha256(sha)):
			_reject_incoming_offer("The host sent an unsafe pack-manifest entry.")
			return
		_incoming_manifest_chars += path.length() + sha.length() + 32
		if _incoming_manifest_chars > MAX_MANIFEST_TEXT:
			_reject_incoming_offer("The host sent a pack manifest that is too large.")
			return
		clean_files.append({"path": path, "size": size, "sha256": sha})
	_incoming_files.append_array(clean_files)
	_incoming_page += 1


@rpc("authority", "call_remote", "reliable", 1)
func _rpc_pack_offer_end(offer_id: String, clips: Array) -> void:
	if _net == null or _net.is_host() or offer_id != str(_incoming_offer.get("id", "")): return
	if _incoming_files.size() != int(_incoming_offer.get("file_count", -1)):
		_reject_incoming_offer("The host did not send the complete pack manifest.")
		return
	if clips.size() > _incoming_files.size():
		_reject_incoming_offer("The host sent too many selected clips for this pack.")
		return
	var offer: Dictionary = _incoming_offer.duplicate(true)
	offer.erase("file_count")
	offer["files"] = _incoming_files.duplicate(true)
	offer["clips"] = clips.duplicate()
	var problem: String = _valid_offer(offer)
	if not problem.is_empty():
		_active_offer = offer
		_reject_incoming_offer(problem)
		return
	_active_offer = offer
	_incoming_offer.clear()
	_incoming_files.clear()
	_incoming_page = 0
	_incoming_manifest_chars = 0
	_check_for_existing_pack.call_deferred(offer_id)


func _send_offer_manifest(peer: int, offer_id: String) -> void:
	if (_net == null or not _net.is_host() or not _net.players.has(peer)
		or offer_id != str(_active_offer.get("id", ""))): return
	var files: Array = _active_offer.get("files", [])
	var summary: Dictionary = {
		"id": _active_offer["id"],
		"pack_id": _active_offer["pack_id"],
		"name": _active_offer["name"],
		"folder_name": _active_offer["folder_name"],
		"total_bytes": _active_offer["total_bytes"],
		"file_count": files.size(),
		"ignored": _active_offer.get("ignored", 0),
	}
	_rpc_pack_offer_begin.rpc_id(peer, summary)
	var pages: int = int((files.size() + MANIFEST_FILES_PER_PAGE - 1) / MANIFEST_FILES_PER_PAGE)
	for page: int in pages:
		if (_net == null or not _net.is_host() or not _net.players.has(peer)
			or offer_id != str(_active_offer.get("id", ""))): return
		var first: int = page * MANIFEST_FILES_PER_PAGE
		var last: int = mini(first + MANIFEST_FILES_PER_PAGE, files.size())
		_rpc_pack_offer_files.rpc_id(peer, offer_id, page, pages, files.slice(first, last))
		await get_tree().process_frame
	if offer_id == str(_active_offer.get("id", "")) and _net.players.has(peer):
		_rpc_pack_offer_end.rpc_id(peer, offer_id, Array(_active_offer.get("clips", [])))


func _check_for_existing_pack(offer_id: String) -> void:
	if str(_active_offer.get("id", "")) != offer_id: return
	var candidates: PackedStringArray = []
	var pack_id: String = str(_active_offer["pack_id"])
	var cached: String = _cache_path(pack_id)
	if _cache_marker_matches(cached, pack_id): candidates.append(cached)

	var folder_name: String = str(_active_offer.get("folder_name", ""))
	if _safe_folder_name(folder_name):
		var same_name: String = str(FileManager.MODPACKS_VOICE).path_join(folder_name)
		if DirAccess.dir_exists_absolute(same_name): candidates.append(same_name)
		var host_manifest: Dictionary = _dictionary(_net.manifests.get(1, {}))
		var remap: Dictionary = _net.pack_remap(host_manifest)
		if remap.has(folder_name):
			var mapped: String = str(FileManager.MODPACKS_VOICE).path_join(str(remap[folder_name]))
			if not candidates.has(mapped) and DirAccess.dir_exists_absolute(mapped): candidates.append(mapped)

	for candidate: String in candidates:
		var thread: = Thread.new()
		var offer_snapshot: Dictionary = _active_offer.duplicate(true)
		if thread.start(_folder_matches_offer.bind(candidate, offer_snapshot)) != OK: continue
		var abandoned: bool = false
		while thread.is_alive():
			if str(_active_offer.get("id", "")) != offer_id:
				abandoned = true
			await get_tree().process_frame
		var matches: bool = bool(thread.wait_to_finish())
		if abandoned or str(_active_offer.get("id", "")) != offer_id: return
		if matches:
			_pack_paths[pack_id] = candidate
			_client_state = "ready"
			_client_received = int(_active_offer["total_bytes"])
			_queue_render()
			_send_client_state("ready")
			pack_ready.emit(pack_id, candidate)
			return

	if str(_active_offer.get("id", "")) != offer_id: return
	_client_state = "offered"
	_queue_render()
	_send_client_state("offered")
	if _test_auto_accept: accept_download.call_deferred()


func _folder_matches_offer(folder: String, offer: Dictionary) -> bool:
	for item_value: Variant in Array(offer.get("files", [])):
		var item: Dictionary = item_value
		var path: String = folder.path_join(str(item["path"]))
		if not FileAccess.file_exists(path): return false
		if _file_size(path) != int(item["size"]): return false
		if FileAccess.get_sha256(path) != str(item["sha256"]): return false
	return true


func _safe_folder_name(value: String) -> bool:
	return (not value.is_empty() and value == value.get_file() and value != "." and value != ".."
		and not value.contains(":") and not value.contains("\\") and not value.contains("/"))


func _cache_path(pack_id: String) -> String:
	return _cache_root.path_join(pack_id)


func _cache_marker_matches(folder: String, pack_id: String) -> bool:
	var marker: String = folder.path_join(COMPLETE_MARKER)
	if not FileAccess.file_exists(marker): return false
	return FileAccess.get_file_as_string(marker).strip_edges() == pack_id


func accept_download() -> void:
	if _net == null or _net.is_host(): return
	if not ["offered", "declined", "failed"].has(_client_state): return
	var pack_id: String = str(_active_offer.get("pack_id", ""))
	if not _valid_sha256(pack_id): return
	if DirAccess.make_dir_recursive_absolute(_cache_path(pack_id)) != OK:
		_client_fail("Could not create the multiplayer pack cache.")
		return

	var offsets: Array[int] = []
	var present: int = 0
	for value_item: Variant in Array(_active_offer["files"]):
		var item: Dictionary = value_item
		var target: String = _cache_path(pack_id).path_join(str(item["path"]))
		var size: int = _file_size(target) if FileAccess.file_exists(target) else 0
		if size < 0 or size > int(item["size"]):
			var reset_file: FileAccess = FileAccess.open(target, FileAccess.WRITE)
			if reset_file != null: reset_file.close()
			size = 0
		offsets.append(size)
		present += size

	var cache_dir: DirAccess = DirAccess.open(_cache_root)
	var needed: int = int(_active_offer["total_bytes"]) - present
	if cache_dir != null:
		var free: int = cache_dir.get_space_left()
		if free > 0 and free < needed + FREE_SPACE_MARGIN:
			_client_fail("Not enough disk space: this download still needs %s." % _format_bytes(needed))
			return

	_client_state = "downloading"
	_client_error = ""
	_client_received = present
	_client_transfer_id += 1
	_queue_render()
	_send_client_state("downloading")
	_rpc_pack_accept.rpc_id(1, str(_active_offer["id"]), _client_transfer_id, offsets)


func decline_download() -> void:
	if _net == null or _net.is_host(): return
	if not ["offered", "downloading", "failed"].has(_client_state): return
	_close_download_file()
	_client_transfer_id += 1
	_client_state = "declined"
	_client_error = ""
	_queue_render()
	_send_client_state("declined")


@rpc("any_peer", "call_remote", "reliable", 1)
func _rpc_pack_accept(offer_id: String, client_transfer_id: int, offsets: Array) -> void:
	if _net == null or not _net.is_host(): return
	var sender: int = multiplayer.get_remote_sender_id()
	if not _net.players.has(sender) or offer_id != str(_active_offer.get("id", "")): return
	var files: Array = _active_offer.get("files", [])
	if client_transfer_id <= 0 or offsets.size() != files.size():
		_fail_peer(sender, client_transfer_id, "The resume information did not match this pack.")
		return
	for i: int in offsets.size():
		var offset: int = int(offsets[i])
		if offset < 0 or offset > int(_dictionary(files[i]).get("size", -1)):
			_fail_peer(sender, client_transfer_id, "The resume information contained an invalid offset.")
			return

	_transfer_tokens[sender] = int(_transfer_tokens.get(sender, 0)) + 1
	var token: int = int(_transfer_tokens[sender])
	_peer_states[sender] = _state_record("downloading", _sum_offsets(offsets), "")
	_queue_render()
	_send_to_peer.call_deferred(sender, offsets.duplicate(), token, client_transfer_id, offer_id)


func _send_to_peer(peer: int, offsets: Array, token: int, client_transfer_id: int, offer_id: String) -> void:
	var files: Array = _active_offer.get("files", [])
	for i: int in files.size():
		if not _transfer_is_current(peer, token, offer_id): return
		var item: Dictionary = files[i]
		var expected_size: int = int(item["size"])
		var offset: int = int(offsets[i])
		var source_path: String = _host_folder.path_join(str(item["path"]))
		var source: FileAccess = FileAccess.open(source_path, FileAccess.READ)
		if source == null or source.get_length() != expected_size:
			_fail_peer(peer, client_transfer_id, "The host could no longer read %s." % str(item["path"]))
			return
		source.seek(offset)
		_host_acks[peer] = {
			"client_transfer_id": client_transfer_id,
			"file": i,
			"offset": offset,
			"last_msec": Time.get_ticks_msec(),
		}
		_rpc_pack_file_begin.rpc_id(peer, offer_id, client_transfer_id, i, offset)
		var sent: int = offset
		while sent < expected_size:
			if not _transfer_is_current(peer, token, offer_id):
				source.close()
				return
			while sent - _ack_offset(peer, i) >= SEND_WINDOW:
				if not _transfer_is_current(peer, token, offer_id):
					source.close()
					return
				if _ack_stalled(peer):
					source.close()
					_fail_peer(peer, client_transfer_id, "The pack download stopped responding for %d seconds." % int(STALL_TIMEOUT_MSEC / 1000))
					return
				await get_tree().process_frame
			var wanted: int = mini(CHUNK_SIZE, expected_size - sent)
			var chunk: PackedByteArray = source.get_buffer(wanted)
			if chunk.size() != wanted:
				source.close()
				_fail_peer(peer, client_transfer_id, "The host failed while reading %s." % str(item["path"]))
				return
			_rpc_pack_chunk.rpc_id(peer, offer_id, client_transfer_id, i, sent, chunk)
			sent += chunk.size()
		source.close()
		while _ack_offset(peer, i) < expected_size:
			if not _transfer_is_current(peer, token, offer_id): return
			if _ack_stalled(peer):
				_fail_peer(peer, client_transfer_id, "The pack download stopped responding for %d seconds." % int(STALL_TIMEOUT_MSEC / 1000))
				return
			await get_tree().process_frame
	if _transfer_is_current(peer, token, offer_id):
		_rpc_pack_complete.rpc_id(peer, offer_id, client_transfer_id)


func _transfer_is_current(peer: int, token: int, offer_id: String) -> bool:
	if _net == null or not _net.is_online() or not _net.is_host(): return false
	if offer_id != str(_active_offer.get("id", "")): return false
	if not _net.players.has(peer): return false
	if int(_transfer_tokens.get(peer, -1)) != token: return false
	return str(_dictionary(_peer_states.get(peer, {})).get("state", "")) == "downloading"


func _ack_offset(peer: int, file_index: int) -> int:
	var ack: Dictionary = _dictionary(_host_acks.get(peer, {}))
	if int(ack.get("file", -1)) != file_index: return 0
	return int(ack.get("offset", 0))


func _ack_stalled(peer: int) -> bool:
	var ack: Dictionary = _dictionary(_host_acks.get(peer, {}))
	return Time.get_ticks_msec() - int(ack.get("last_msec", 0)) > STALL_TIMEOUT_MSEC


@rpc("authority", "call_remote", "reliable", 1)
func _rpc_pack_file_begin(offer_id: String, client_transfer_id: int, file_index: int, offset: int) -> void:
	if _net == null or _net.is_host() or offer_id != str(_active_offer.get("id", "")): return
	if _client_state != "downloading" or client_transfer_id != _client_transfer_id: return
	var files: Array = _active_offer.get("files", [])
	if file_index < 0 or file_index >= files.size():
		_client_fail("The host selected an invalid file number.")
		return
	var item: Dictionary = files[file_index]
	if offset < 0 or offset > int(item["size"]):
		_client_fail("The host selected an invalid file offset.")
		return
	_close_download_file()
	var target: String = _cache_path(str(_active_offer["pack_id"])).path_join(str(item["path"]))
	if DirAccess.make_dir_recursive_absolute(target.get_base_dir()) != OK:
		_client_fail("Could not create a folder for %s." % str(item["path"]))
		return
	var actual: int = _file_size(target) if FileAccess.file_exists(target) else 0
	if actual != offset:
		_client_fail("The partial file size changed while resuming %s." % str(item["path"]))
		return
	_download_file = FileAccess.open(target, FileAccess.WRITE_READ if offset == 0 else FileAccess.READ_WRITE)
	if _download_file == null:
		_client_fail("Could not write %s." % str(item["path"]))
		return
	_download_file.seek(offset)
	_download_index = file_index
	_download_offset = offset


@rpc("authority", "call_remote", "reliable", 1)
func _rpc_pack_chunk(offer_id: String, client_transfer_id: int, file_index: int, offset: int, data: PackedByteArray) -> void:
	if _net == null or _net.is_host() or offer_id != str(_active_offer.get("id", "")): return
	if _client_state != "downloading" or client_transfer_id != _client_transfer_id: return
	var files: Array = _active_offer.get("files", [])
	if (_download_file == null or file_index != _download_index or offset != _download_offset
		or data.is_empty() or data.size() > CHUNK_SIZE or file_index < 0 or file_index >= files.size()
		or offset + data.size() > int(_dictionary(files[file_index]).get("size", -1))):
		_client_fail("The host sent an out-of-order or invalid pack chunk.")
		return
	_download_file.store_buffer(data)
	if _download_file.get_error() != OK:
		_client_fail("The disk write failed while receiving the dub pack.")
		return
	_download_offset += data.size()
	_client_received += data.size()
	_queue_render()
	_rpc_pack_ack.rpc_id(1, offer_id, client_transfer_id, file_index, _download_offset, _client_received)


@rpc("any_peer", "call_remote", "reliable", 1)
func _rpc_pack_ack(offer_id: String, client_transfer_id: int, file_index: int, next_offset: int, received: int) -> void:
	if _net == null or not _net.is_host() or offer_id != str(_active_offer.get("id", "")): return
	var sender: int = multiplayer.get_remote_sender_id()
	if not _net.players.has(sender): return
	var files: Array = _active_offer.get("files", [])
	if file_index < 0 or file_index >= files.size(): return
	var ack: Dictionary = _dictionary(_host_acks.get(sender, {}))
	if int(ack.get("client_transfer_id", -1)) != client_transfer_id or int(ack.get("file", -1)) != file_index: return
	if next_offset < int(ack.get("offset", 0)) or next_offset > int(_dictionary(files[file_index]).get("size", -1)): return
	ack["offset"] = next_offset
	ack["last_msec"] = Time.get_ticks_msec()
	_host_acks[sender] = ack
	var record: Dictionary = _dictionary(_peer_states.get(sender, {}))
	record["received"] = clampi(received, 0, int(_active_offer["total_bytes"]))
	_peer_states[sender] = record
	_queue_render()


@rpc("authority", "call_remote", "reliable", 1)
func _rpc_pack_complete(offer_id: String, client_transfer_id: int) -> void:
	if _net == null or _net.is_host() or offer_id != str(_active_offer.get("id", "")): return
	if _client_state != "downloading" or client_transfer_id != _client_transfer_id: return
	_close_download_file()
	_client_state = "verifying"
	_queue_render()
	_send_client_state("verifying")
	_verify_received_pack.call_deferred(offer_id, client_transfer_id)


func _verify_received_pack(offer_id: String, client_transfer_id: int) -> void:
	var pack_id: String = str(_active_offer.get("pack_id", ""))
	var folder: String = _cache_path(pack_id)
	var thread: = Thread.new()
	var offer_snapshot: Dictionary = _active_offer.duplicate(true)
	if thread.start(_mismatched_files.bind(folder, offer_snapshot)) != OK:
		_client_fail("Could not start verification of the downloaded pack.")
		return
	var abandoned: bool = false
	while thread.is_alive():
		if offer_id != str(_active_offer.get("id", "")) or client_transfer_id != _client_transfer_id:
			abandoned = true
		await get_tree().process_frame
	var mismatched: PackedStringArray = thread.wait_to_finish()
	if (abandoned or offer_id != str(_active_offer.get("id", ""))
		or client_transfer_id != _client_transfer_id): return
	if not mismatched.is_empty():
		for relative: String in mismatched:
			var bad: FileAccess = FileAccess.open(folder.path_join(relative), FileAccess.WRITE)
			if bad != null: bad.close()
		_client_fail("Verification failed for %d file(s). Click Retry to send those files again." % mismatched.size())
		return

	var marker: FileAccess = FileAccess.open(folder.path_join(COMPLETE_MARKER), FileAccess.WRITE)
	if marker == null:
		_client_fail("The pack verified, but its cache marker could not be written.")
		return
	marker.store_string(pack_id)
	marker.close()
	_pack_paths[pack_id] = folder
	_client_state = "ready"
	_client_received = int(_active_offer["total_bytes"])
	_queue_render()
	_send_client_state("ready")
	pack_ready.emit(pack_id, folder)


func _mismatched_files(folder: String, offer: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	for value_item: Variant in Array(offer.get("files", [])):
		var item: Dictionary = value_item
		var target: String = folder.path_join(str(item["path"]))
		if (not FileAccess.file_exists(target) or _file_size(target) != int(item["size"])
			or FileAccess.get_sha256(target) != str(item["sha256"])):
			out.append(str(item["path"]))
	return out


@rpc("any_peer", "call_remote", "reliable", 1)
func _rpc_pack_state(offer_id: String, state: String, received: int, error: String) -> void:
	if _net == null or not _net.is_host() or offer_id != str(_active_offer.get("id", "")): return
	var sender: int = multiplayer.get_remote_sender_id()
	if not _net.players.has(sender): return
	if not ["checking", "offered", "declined", "downloading", "verifying", "ready", "failed"].has(state): return
	_peer_states[sender] = _state_record(state, clampi(received, 0, int(_active_offer["total_bytes"])), error.substr(0, 300))
	if state != "downloading": _transfer_tokens[sender] = int(_transfer_tokens.get(sender, 0)) + 1
	_queue_render()


func _send_client_state(state: String) -> void:
	if _net == null or not _net.is_online() or _net.is_host() or _active_offer.is_empty(): return
	_rpc_pack_state.rpc_id(1, str(_active_offer["id"]), state, _client_received, _client_error)


func _client_fail(reason: String) -> void:
	_close_download_file()
	_client_transfer_id += 1
	_client_state = "failed"
	_client_error = reason.substr(0, 300)
	_queue_render()
	_send_client_state("failed")
	if _net != null: _net.log_net("pack sync failed: %s" % reason)


func _reject_incoming_offer(reason: String) -> void:
	_incoming_offer.clear()
	_incoming_files.clear()
	_incoming_page = 0
	_incoming_manifest_chars = 0
	_client_fail(reason)


func _fail_peer(peer: int, client_transfer_id: int, reason: String) -> void:
	_transfer_tokens[peer] = int(_transfer_tokens.get(peer, 0)) + 1
	_peer_states[peer] = _state_record("failed", int(_dictionary(_peer_states.get(peer, {})).get("received", 0)), reason)
	_rpc_pack_error.rpc_id(peer, str(_active_offer.get("id", "")), client_transfer_id, reason)
	_queue_render()


@rpc("authority", "call_remote", "reliable", 1)
func _rpc_pack_error(offer_id: String, client_transfer_id: int, reason: String) -> void:
	if _net == null or _net.is_host() or offer_id != str(_active_offer.get("id", "")): return
	if client_transfer_id != _client_transfer_id: return
	_client_fail(reason)


@rpc("authority", "call_remote", "reliable", 1)
func _rpc_pack_cancel(offer_id: String, reason: String) -> void:
	if _net == null or _net.is_host(): return
	if (offer_id != str(_active_offer.get("id", ""))
		and offer_id != str(_incoming_offer.get("id", ""))): return
	_close_download_file()
	_client_state = "idle"
	_client_error = reason
	_active_offer.clear()
	_incoming_offer.clear()
	_incoming_files.clear()
	_incoming_manifest_chars = 0
	_hide_panel.call_deferred()
	_emit_state_changed.call_deferred()


func _cancel_host_offer(reason: String) -> void:
	if _active_offer.is_empty(): return
	_rpc_pack_cancel.rpc(str(_active_offer["id"]), reason)
	_net.log_net("canceled dub-pack offer: %s" % reason)
	reset()


func _on_roster_changed() -> void:
	if _net == null or not _net.is_host() or _active_offer.is_empty(): return
	var current: Dictionary = {}
	for peer: int in _net.players:
		current[peer] = true
		if peer != 1 and not _peer_states.has(peer):
			_peer_states[peer] = _state_record("checking", 0, "")
			_send_offer_later.call_deferred(peer, str(_active_offer["id"]))
	for peer_value: Variant in _peer_states.keys():
		var peer: int = int(peer_value)
		if not current.has(peer):
			_peer_states.erase(peer)
			_host_acks.erase(peer)
			_transfer_tokens[peer] = int(_transfer_tokens.get(peer, 0)) + 1
	_queue_render()


func _send_offer_later(peer: int, offer_id: String) -> void:
	await get_tree().create_timer(0.5).timeout
	if (_net != null and _net.is_host() and _net.players.has(peer)
		and offer_id == str(_active_offer.get("id", ""))):
		_send_offer_manifest(peer, offer_id)


func _all_players_ready() -> bool:
	if _net == null or _net.players.size() < 2: return false
	for peer: int in _net.players:
		if peer == 1: continue
		if str(_dictionary(_peer_states.get(peer, {})).get("state", "")) != "ready": return false
	return true


func _state_record(state: String, received: int, error: String) -> Dictionary:
	return {"state": state, "received": received, "error": error}


func _sum_offsets(offsets: Array) -> int:
	var total: int = 0
	for value: Variant in offsets: total += int(value)
	return total


func _dictionary(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


func _file_size(path: String) -> int:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null: return -1
	var size: int = file.get_length()
	file.close()
	return size


func _close_download_file() -> void:
	if _download_file != null:
		_download_file.flush()
		_download_file.close()
	_download_file = null
	_download_index = -1
	_download_offset = 0


func _hide_panel() -> void:
	if is_instance_valid(_panel): _panel.visible = false


func _emit_state_changed() -> void:
	state_changed.emit()


func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 140
	add_child(_layer)

	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.offset_left = -380
	_panel.offset_right = 380
	_panel.offset_top = 48
	_panel.visible = false
	_layer.add_child(_panel)

	var margin: = MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	_panel.add_child(margin)

	var column: = VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 24)
	column.add_child(_title)

	_detail = Label.new()
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_detail)

	_roster = Label.new()
	_roster.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_roster)

	_progress = ProgressBar.new()
	_progress.show_percentage = true
	column.add_child(_progress)

	var buttons: = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	column.add_child(buttons)

	_primary = Button.new()
	_primary.pressed.connect(_on_primary)
	buttons.add_child(_primary)

	_secondary = Button.new()
	_secondary.pressed.connect(_on_secondary)
	buttons.add_child(_secondary)


func _show_scanning() -> void:
	_panel.visible = true
	_title.text = "PREPARING DUB PACK"
	_detail.text = "Checking the selected pack and calculating its content hash..."
	_roster.text = ""
	_progress.visible = false
	_primary.visible = false
	_secondary.visible = true
	_secondary.text = "Cancel"
	_secondary.disabled = false


func _show_host_error(reason: String) -> void:
	_host_decision = -1
	_panel.visible = true
	_title.text = "PACK CANNOT BE SHARED"
	_detail.text = reason
	_roster.text = ""
	_progress.visible = false
	_primary.visible = false
	_secondary.visible = true
	_secondary.text = "Close"
	_secondary.disabled = false
	if _net != null: _net.log_net("cannot offer dub pack: %s" % reason)


func _queue_render() -> void:
	if _render_queued: return
	_render_queued = true
	_render_deferred.call_deferred()


func _render_deferred() -> void:
	_render_queued = false
	_render()


func _render() -> void:
	if not is_instance_valid(_panel) or _active_offer.is_empty(): return
	_panel.visible = true
	var total: int = int(_active_offer.get("total_bytes", 0))
	if _net != null and _net.is_host():
		_title.text = "SHARE DUB PACK"
		_detail.text = "%s — %s. Everyone must have and verify this pack before the dub can begin." % [
			_active_offer.get("name", "Dub pack"), _format_bytes(total)]
		var ignored: int = int(_active_offer.get("ignored", 0))
		if ignored > 0:
			_detail.text += " %d generated or unsupported file(s) will not be copied." % ignored
		var lines: PackedStringArray = []
		for slot: int in _net.slot_count():
			var peer: int = _net.peer_for_slot(slot)
			var record: Dictionary = _dictionary(_peer_states.get(peer, {}))
			var state: String = str(record.get("state", "checking"))
			var status: String = _state_label(state)
			if state == "downloading":
				status += " %d%%" % _percent(int(record.get("received", 0)), total)
			if state == "failed" and not str(record.get("error", "")).is_empty():
				status += " — " + str(record["error"])
			lines.append("%s: %s" % [_net.player_name_for_slot(slot), status])
		_roster.text = "\n".join(lines)
		_progress.visible = false
		_primary.visible = true
		_primary.text = "Begin dub"
		_primary.disabled = not _all_players_ready()
		_secondary.visible = true
		_secondary.text = "Cancel"
		_secondary.disabled = false
	else:
		_title.text = "HOST SELECTED A DUB PACK"
		_detail.text = "%s — %s" % [_active_offer.get("name", "Dub pack"), _format_bytes(total)]
		_roster.text = _client_status_text()
		_progress.visible = _client_state in ["downloading", "verifying", "ready"]
		_progress.min_value = 0
		_progress.max_value = maxi(1, total)
		_progress.value = _client_received
		_primary.visible = _client_state in ["offered", "declined", "failed"]
		_primary.text = "Retry download" if _client_state == "failed" else "Download pack"
		_primary.disabled = false
		_secondary.visible = _client_state in ["offered", "downloading"]
		_secondary.text = "Cancel download" if _client_state == "downloading" else "Not now"
		_secondary.disabled = false
	state_changed.emit()


func _client_status_text() -> String:
	match _client_state:
		"checking": return "Checking whether this pack is already installed..."
		"offered": return "This pack is missing. It will be kept in the multiplayer cache, not installed into your pack library."
		"declined": return "Download declined. You can change your mind while the host is still waiting."
		"downloading": return "Downloading from the host: %s / %s" % [
			_format_bytes(_client_received),
			_format_bytes(int(_active_offer.get("total_bytes", 0))),
		]
		"verifying": return "Download complete. Verifying every file..."
		"ready": return "Pack ready. Waiting for the host to begin the dub."
		"failed": return _client_error
	return "Waiting for the host..."


func _state_label(state: String) -> String:
	match state:
		"ready": return "ready"
		"checking": return "checking installed packs"
		"offered": return "waiting for their answer"
		"declined": return "declined"
		"downloading": return "downloading"
		"verifying": return "verifying"
		"failed": return "failed"
	return state


func _on_primary() -> void:
	if _net != null and _net.is_host():
		if _all_players_ready(): _host_decision = 1
	else:
		accept_download()


func _on_secondary() -> void:
	if _net != null and _net.is_host():
		if _active_offer.is_empty():
			_host_decision = -1
			_panel.visible = false
		else:
			_host_decision = -1
	else:
		decline_download()


func _percent(value: int, total: int) -> int:
	if total <= 0: return 0
	return clampi(int(float(value) * 100.0 / float(total)), 0, 100)


func _format_bytes(bytes: int) -> String:
	if bytes >= 1024 * 1024 * 1024: return "%.2f GB" % (float(bytes) / 1073741824.0)
	if bytes >= 1024 * 1024: return "%.1f MB" % (float(bytes) / 1048576.0)
	if bytes >= 1024: return "%.1f KB" % (float(bytes) / 1024.0)
	return "%d bytes" % bytes
