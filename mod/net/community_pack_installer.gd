extends Node
# Downloads a GameBanana ZIP into a private staging area, validates its central
# directory before allocating decompressed data, extracts only inert dub-pack
# assets, and moves the complete folder into packs_voice in one rename.

signal progress(received: int, total: int, status: String)
signal finished(result: Dictionary)
signal failed(message: String)

const DOWNLOAD_ROOT: String = "user://community_pack_downloads"
const REGISTRY_PATH: String = "user://community_pack_registry.json"
const MANIFEST_NAME: String = ".tcv-community-pack.json"
const NO_DUB_ROOT: String = "::missing-dub-root::"

const MAX_ARCHIVE_BYTES: int = 1024 * 1024 * 1024
const MAX_EXPANDED_BYTES: int = 4 * 1024 * 1024 * 1024
const MAX_FILE_BYTES: int = 768 * 1024 * 1024
const MAX_FILES: int = 4096
const FREE_SPACE_MARGIN: int = 256 * 1024 * 1024

const SAFE_EXTENSIONS: PackedStringArray = [
	"wav", "mp3", "ogg", "ogv",
	"ini", "cfg", "json", "txt", "md",
	"png", "jpg", "jpeg", "webp", "bmp",
]
const AUDIO_EXTENSIONS: PackedStringArray = ["wav", "mp3", "ogg"]

var _http: HTTPRequest
var _busy: bool = false
var _mod: Dictionary = {}
var _file: Dictionary = {}
var _download_path: String = ""


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.timeout = 0.0
	_http.download_chunk_size = 256 * 1024
	_http.request_completed.connect(_on_download_completed)
	add_child(_http)
	set_process(false)


func _process(_delta: float) -> void:
	if not _busy: return
	progress.emit(_http.get_downloaded_bytes(), int(_file.get("size", 0)), "Downloading from GameBanana...")


func is_busy() -> bool:
	return _busy


func cancel() -> void:
	if not _busy: return
	_http.cancel_request()
	_busy = false
	set_process(false)
	_cleanup_download()
	failed.emit("Download canceled.")


func install(mod: Dictionary, file: Dictionary) -> void:
	if _busy: return
	var problem: String = installability_problem(file)
	if not problem.is_empty():
		failed.emit(problem)
		return
	var existing: String = installed_path(int(mod.get("id", 0)))
	if not existing.is_empty():
		finished.emit({"path": existing, "already_installed": true})
		return
	_mod = mod.duplicate(true)
	_file = file.duplicate(true)
	if DirAccess.make_dir_recursive_absolute(DOWNLOAD_ROOT) != OK:
		failed.emit("Could not create the community-pack download folder.")
		return
	_download_path = DOWNLOAD_ROOT.path_join("%d.zip.part" % int(file["id"]))
	if FileAccess.file_exists(_download_path): DirAccess.remove_absolute(_download_path)
	_http.download_file = _download_path
	_http.body_size_limit = MAX_ARCHIVE_BYTES
	_busy = true
	set_process(true)
	progress.emit(0, int(file.get("size", 0)), "Connecting to GameBanana...")
	var headers: PackedStringArray = [
		"Accept: application/octet-stream",
		"User-Agent: TCV-Multiplayer/%s" % str(Net.MOD_VERSION),
	]
	var error: Error = _http.request(str(file["url"]), headers)
	if error != OK:
		_fail("Could not start the download (%s)." % error_string(error))


static func installability_problem(file: Dictionary) -> String:
	var name: String = str(file.get("name", ""))
	if name.get_extension().to_lower() != "zip":
		return "This file is not a ZIP. RAR and 7z support is not available yet."
	var size: int = int(file.get("size", 0))
	if size <= 0: return "GameBanana did not report a valid file size."
	if size > MAX_ARCHIVE_BYTES: return "This archive is larger than the 1 GB safety limit."
	var url: String = str(file.get("url", ""))
	if not url.begins_with("https://gamebanana.com/dl/"):
		return "The download URL did not come from GameBanana."
	var md5: String = str(file.get("md5", "")).to_lower()
	if md5.length() != 32 or not _is_hex(md5):
		return "GameBanana did not provide a usable checksum for this file."
	if str(file.get("analysis_state", "")) != "done" or str(file.get("analysis_result", "")) != "ok":
		return "GameBanana has not finished approving this archive."
	if str(file.get("av_state", "")) != "done" or str(file.get("av_result", "")) != "clean":
		return "GameBanana has not marked this archive clean."
	if bool(file.get("archived", false)): return "This GameBanana file has been archived."
	return ""


func _on_download_completed(
	result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray
) -> void:
	set_process(false)
	_http.download_file = ""
	if not _busy: return
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("The archive download failed (%d)." % result)
		return
	if response_code < 200 or response_code >= 300:
		_fail("GameBanana returned HTTP %d for the archive." % response_code)
		return
	_finish_download.call_deferred()


func _finish_download() -> void:
	if not _busy: return
	var expected_size: int = int(_file.get("size", 0))
	var actual_size: int = _file_size(_download_path)
	if actual_size != expected_size:
		_fail("The archive was incomplete: expected %s, received %s." % [
			_format_bytes(expected_size), _format_bytes(actual_size)])
		return
	progress.emit(actual_size, expected_size, "Verifying the archive checksum...")
	var actual_md5: String = FileAccess.get_md5(_download_path).to_lower()
	if actual_md5 != str(_file.get("md5", "")).to_lower():
		_fail("The downloaded archive failed its checksum. It was not installed.")
		return

	progress.emit(actual_size, expected_size, "Checking and installing the dub pack...")
	var thread: = Thread.new()
	# Resolve the game autoload on the main thread. The worker only receives an
	# immutable path and then sticks to its own FileAccess/DirAccess instances.
	var voice_root: String = str(FileManager.MODPACKS_VOICE)
	var error: Error = thread.start(
		_validate_and_extract.bind(_download_path, _mod, _file, voice_root, true))
	if error != OK:
		_fail("Could not start archive validation (%s)." % error_string(error))
		return
	while thread.is_alive(): await get_tree().process_frame
	var extracted_value: Variant = thread.wait_to_finish()
	if not extracted_value is Dictionary:
		_fail("Archive validation stopped unexpectedly.")
		return
	var extracted: Dictionary = extracted_value
	if extracted.has("error"):
		_fail(str(extracted["error"]))
		return
	_busy = false
	_cleanup_download()
	progress.emit(expected_size, expected_size, "Installed.")
	finished.emit(extracted)


func _fail(message: String) -> void:
	_busy = false
	set_process(false)
	_http.download_file = ""
	_cleanup_download()
	failed.emit(message)


func _cleanup_download() -> void:
	if (_download_path.begins_with(DOWNLOAD_ROOT + "/")
		and FileAccess.file_exists(_download_path)):
		DirAccess.remove_absolute(_download_path)
	_download_path = ""


static func _validate_and_extract(
	archive: String, mod: Dictionary, file: Dictionary, voice_root_override: String = "",
	use_registry: bool = true
) -> Dictionary:
	var indexed: Dictionary = inspect_zip(archive)
	if indexed.has("error"): return indexed
	var entries: Array[Dictionary] = []
	for value: Variant in Array(indexed.get("entries", [])):
		if value is Dictionary: entries.append(value)
	var root: String = _find_dub_root(entries)
	if root == NO_DUB_ROOT:
		return {"error": "No dub pack was found in the archive. A dub pack needs an OGV video and audio clips."}

	var chosen: Array[Dictionary] = []
	var total: int = 0
	var audio_count: int = 0
	var video_count: int = 0
	var seen: Dictionary = {}
	for entry: Dictionary in entries:
		if bool(entry.get("directory", false)): continue
		var path: String = str(entry["path"])
		if not root.is_empty():
			if not path.begins_with(root + "/"): continue
			path = path.substr(root.length() + 1)
		if _junk_path(path): continue
		if not _safe_relative_path(path):
			return {"error": "The archive contains an unsafe path: %s" % path}
		var ext: String = path.get_extension().to_lower()
		if not SAFE_EXTENSIONS.has(ext):
			return {"error": "The dub pack contains a blocked file type: %s" % path}
		var key: String = path.to_lower()
		if seen.has(key): return {"error": "The archive writes the same path twice: %s" % path}
		seen[key] = true
		var size: int = int(entry["size"])
		if size > MAX_FILE_BYTES:
			return {"error": "%s is larger than the per-file safety limit." % path}
		total += size
		if total > MAX_EXPANDED_BYTES:
			return {"error": "The extracted pack would exceed the 4 GB safety limit."}
		if AUDIO_EXTENSIONS.has(ext): audio_count += 1
		if ext == "ogv": video_count += 1
		var selected: Dictionary = entry.duplicate()
		selected["output_path"] = path
		chosen.append(selected)
	if chosen.is_empty() or audio_count == 0 or video_count == 0:
		return {"error": "The archive did not contain a complete dub pack."}

	var voice_root: String = (
		str(FileManager.MODPACKS_VOICE) if voice_root_override.is_empty()
		else voice_root_override).trim_suffix("/")
	if DirAccess.make_dir_recursive_absolute(voice_root) != OK:
		return {"error": "Could not create the game's packs_voice folder."}
	var root_dir: DirAccess = DirAccess.open(voice_root)
	if root_dir != null:
		var free: int = root_dir.get_space_left()
		if free > 0 and free < total + FREE_SPACE_MARGIN:
			return {"error": "Not enough disk space to install this pack."}
	# Stage beside the final pack. user:// may be on C: while the game and its
	# external packs live on another drive; a rename across those volumes is not
	# atomic and normally fails outright on Windows.
	var staging_root: String = voice_root.path_join(".tcv-community-staging")
	if DirAccess.make_dir_recursive_absolute(staging_root) != OK:
		return {"error": "Could not create the community-pack staging folder."}

	var folder_name: String = _safe_folder_name(str(mod.get("name", "Dub pack")), int(mod.get("id", 0)))
	var destination: String = voice_root.path_join(folder_name)
	var registry: Dictionary = load_registry() if use_registry else {}
	var registered: Dictionary = _as_dictionary(registry.get(str(mod.get("id", 0)), {}))
	var registered_path: String = str(registered.get("path", ""))
	if not registered_path.is_empty() and DirAccess.dir_exists_absolute(registered_path):
		return {"path": registered_path, "already_installed": true}
	var suffix: int = 2
	while DirAccess.dir_exists_absolute(destination):
		destination = voice_root.path_join("%s (%d)" % [folder_name, suffix])
		suffix += 1

	var staging: String = staging_root.path_join(
		"%d-%d" % [int(mod.get("id", 0)), Time.get_ticks_usec()])
	if DirAccess.make_dir_recursive_absolute(staging) != OK:
		return {"error": "Could not create a temporary installation folder."}
	var zip: = ZIPReader.new()
	var open_error: Error = zip.open(archive)
	if open_error != OK:
		_remove_tree(staging, staging_root)
		return {"error": "Godot could not open this ZIP (%s)." % error_string(open_error)}
	for entry: Dictionary in chosen:
		var output_path: String = staging.path_join(str(entry["output_path"]))
		if DirAccess.make_dir_recursive_absolute(output_path.get_base_dir()) != OK:
			zip.close()
			_remove_tree(staging, staging_root)
			return {"error": "Could not create a folder while extracting the pack."}
		var bytes: PackedByteArray = zip.read_file(str(entry["zip_path"]))
		if bytes.size() != int(entry["size"]):
			zip.close()
			_remove_tree(staging, staging_root)
			return {"error": "The ZIP entry %s did not extract to its declared size." % str(entry["output_path"])}
		var output: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
		if output == null:
			zip.close()
			_remove_tree(staging, staging_root)
			return {"error": "Could not write %s." % str(entry["output_path"])}
		output.store_buffer(bytes)
		output.close()
	zip.close()

	var manifest: Dictionary = {
		"schema": 1,
		"provider": "gamebanana",
		"mod_id": int(mod.get("id", 0)),
		"file_id": int(file.get("id", 0)),
		"name": str(mod.get("name", "Dub pack")),
		"author": str(mod.get("author", "Unknown creator")),
		"profile_url": str(mod.get("profile_url", "")),
		"archive_name": str(file.get("name", "")),
		"archive_md5": str(file.get("md5", "")),
		"installed_files": chosen.size(),
		"installed_bytes": total,
		"installed_unix": int(Time.get_unix_time_from_system()),
	}
	var manifest_file: FileAccess = FileAccess.open(staging.path_join(MANIFEST_NAME), FileAccess.WRITE)
	if manifest_file == null:
		_remove_tree(staging, staging_root)
		return {"error": "Could not write the installed-pack manifest."}
	manifest_file.store_string(JSON.stringify(manifest, "  "))
	manifest_file.close()

	var move_error: Error = DirAccess.rename_absolute(staging, destination)
	if move_error != OK:
		_remove_tree(staging, staging_root)
		return {"error": "Could not move the verified pack into packs_voice (%s)." % error_string(move_error)}
	if not use_registry:
		return {"path": destination, "files": chosen.size(), "bytes": total}
	registry[str(mod.get("id", 0))] = {
		"path": destination,
		"file_id": int(file.get("id", 0)),
		"md5": str(file.get("md5", "")),
		"name": str(mod.get("name", "Dub pack")),
	}
	if not save_registry(registry):
		# Installation is still complete; the embedded manifest lets a later run
		# rediscover it even if this convenience index could not be written.
		return {"path": destination, "warning": "Installed, but could not update the local pack index."}
	return {"path": destination, "files": chosen.size(), "bytes": total}


static func inspect_zip(path: String) -> Dictionary:
	var input: FileAccess = FileAccess.open(path, FileAccess.READ)
	if input == null: return {"error": "Could not open the downloaded archive."}
	var length: int = input.get_length()
	if length < 22 or length > MAX_ARCHIVE_BYTES:
		input.close()
		return {"error": "The downloaded ZIP has an invalid size."}
	var tail_size: int = mini(length, 65557)
	input.seek(length - tail_size)
	var tail: PackedByteArray = input.get_buffer(tail_size)
	var eocd: int = -1
	for i: int in range(tail.size() - 22, -1, -1):
		if tail.decode_u32(i) == 0x06054b50:
			eocd = i
			break
	if eocd < 0:
		input.close()
		return {"error": "The archive has no readable ZIP directory."}
	var entry_count: int = tail.decode_u16(eocd + 10)
	var directory_size: int = tail.decode_u32(eocd + 12)
	var directory_offset: int = tail.decode_u32(eocd + 16)
	if (entry_count == 0xffff or directory_size == 0xffffffff or directory_offset == 0xffffffff
		or entry_count <= 0 or entry_count > MAX_FILES
		or directory_offset < 0 or directory_size < 0
		or directory_offset + directory_size > length):
		input.close()
		return {"error": "ZIP64 or an invalid archive directory is not supported."}
	input.seek(directory_offset)
	var entries: Array[Dictionary] = []
	var expanded: int = 0
	for _index: int in entry_count:
		var header: PackedByteArray = input.get_buffer(46)
		if header.size() != 46 or header.decode_u32(0) != 0x02014b50:
			input.close()
			return {"error": "The ZIP directory is corrupt."}
		var flags: int = header.decode_u16(8)
		var method: int = header.decode_u16(10)
		var compressed: int = header.decode_u32(20)
		var size: int = header.decode_u32(24)
		var name_length: int = header.decode_u16(28)
		var extra_length: int = header.decode_u16(30)
		var comment_length: int = header.decode_u16(32)
		var external_attributes: int = header.decode_u32(38)
		if (compressed == 0xffffffff or size == 0xffffffff or name_length <= 0
			or name_length > 4096 or extra_length > 65535 or comment_length > 65535):
			input.close()
			return {"error": "The ZIP uses unsupported ZIP64 entry metadata."}
		var name_bytes: PackedByteArray = input.get_buffer(name_length)
		if name_bytes.size() != name_length:
			input.close()
			return {"error": "A ZIP filename is truncated."}
		input.seek(input.get_position() + extra_length + comment_length)
		var zip_path: String = name_bytes.get_string_from_utf8()
		var normalized: String = zip_path.replace("\\", "/").trim_prefix("./")
		var directory: bool = normalized.ends_with("/")
		var unix_type: int = (external_attributes >> 16) & 0xf000
		if unix_type == 0xa000:
			input.close()
			return {"error": "The archive contains a symbolic link, which is not allowed."}
		if (flags & 1) != 0:
			input.close()
			return {"error": "Password-protected ZIP entries are not supported."}
		if not directory and method != 0 and method != 8:
			input.close()
			return {"error": "The ZIP uses an unsupported compression method."}
		if not directory:
			if size > MAX_FILE_BYTES:
				input.close()
				return {"error": "%s is too large to extract safely." % normalized}
			expanded += size
			if expanded > MAX_EXPANDED_BYTES:
				input.close()
				return {"error": "The archive expands beyond the 4 GB safety limit."}
			if size > 16 * 1024 * 1024 and (compressed <= 0 or size / compressed > 200):
				input.close()
				return {"error": "%s has an unsafe compression ratio." % normalized}
		entries.append({
			"zip_path": zip_path,
			"path": normalized.trim_suffix("/"),
			"directory": directory,
			"size": size,
			"compressed": compressed,
		})
	input.close()
	return {"entries": entries, "expanded_bytes": expanded}


static func _find_dub_root(entries: Array[Dictionary]) -> String:
	var best: String = NO_DUB_ROOT
	var best_audio: int = -1
	for entry: Dictionary in entries:
		if bool(entry.get("directory", false)): continue
		var path: String = str(entry.get("path", ""))
		if path.get_extension().to_lower() != "ogv": continue
		var candidate: String = path.get_base_dir()
		if candidate == ".": candidate = ""
		var audio: int = 0
		for other: Dictionary in entries:
			if bool(other.get("directory", false)): continue
			var other_path: String = str(other.get("path", ""))
			if not candidate.is_empty() and not other_path.begins_with(candidate + "/"): continue
			if AUDIO_EXTENSIONS.has(other_path.get_extension().to_lower()): audio += 1
		if audio > best_audio or (audio == best_audio and candidate.length() > best.length()):
			best = candidate
			best_audio = audio
	return best if best_audio > 0 else NO_DUB_ROOT


static func installed_path(mod_id: int) -> String:
	if mod_id <= 0: return ""
	var registry: Dictionary = load_registry()
	var record: Dictionary = _as_dictionary(registry.get(str(mod_id), {}))
	var path: String = str(record.get("path", ""))
	if not path.is_empty() and DirAccess.dir_exists_absolute(path): return path
	# The per-pack manifest is authoritative. Rebuild the convenience index if
	# it was deleted or an installed folder was moved within packs_voice.
	var voice_root: String = str(FileManager.MODPACKS_VOICE).trim_suffix("/")
	if not DirAccess.dir_exists_absolute(voice_root): return ""
	for folder: String in DirAccess.get_directories_at(voice_root):
		var candidate: String = voice_root.path_join(folder)
		var manifest_path: String = candidate.path_join(MANIFEST_NAME)
		if not FileAccess.file_exists(manifest_path): continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		if not parsed is Dictionary or int(parsed.get("mod_id", 0)) != mod_id: continue
		registry[str(mod_id)] = {
			"path": candidate,
			"file_id": int(parsed.get("file_id", 0)),
			"md5": str(parsed.get("archive_md5", "")),
			"name": str(parsed.get("name", folder)),
		}
		save_registry(registry)
		return candidate
	return ""


static func installed_packs(voice_root_override: String = "") -> Array[Dictionary]:
	var voice_root: String = (
		str(FileManager.MODPACKS_VOICE) if voice_root_override.is_empty()
		else voice_root_override).replace("\\", "/").trim_suffix("/")
	var packs: Array[Dictionary] = []
	var parent: DirAccess = DirAccess.open(voice_root)
	if parent == null: return packs
	parent.include_hidden = true
	for folder: String in parent.get_directories():
		if parent.is_link(folder): continue
		var path: String = voice_root.path_join(folder)
		var manifest_path: String = path.path_join(MANIFEST_NAME)
		if not FileAccess.file_exists(manifest_path): continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		if (not parsed is Dictionary or str(parsed.get("provider", "")) != "gamebanana"
			or int(parsed.get("mod_id", 0)) <= 0):
			continue
		var record: Dictionary = parsed.duplicate(true)
		record["path"] = path
		record["folder"] = folder
		packs.append(record)
	packs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", ""))) < 0)
	return packs


static func uninstall(mod_id: int, exact_path: String = "") -> Dictionary:
	var path: String = (
		exact_path if not exact_path.is_empty()
		else installed_path(mod_id)).replace("\\", "/").trim_suffix("/")
	if path.is_empty(): return {"error": "This community pack is not installed."}
	var voice_root: String = str(FileManager.MODPACKS_VOICE).replace("\\", "/").trim_suffix("/")
	return _uninstall_path(mod_id, path, voice_root, true)


static func _uninstall_path(
	mod_id: int, installed: String, voice_root_value: String, update_registry: bool
) -> Dictionary:
	var path: String = installed.replace("\\", "/").trim_suffix("/")
	var voice_root: String = voice_root_value.replace("\\", "/").trim_suffix("/")
	# Only a direct child created by this installer can be removed. Never turn a
	# registry entry or edited manifest into a recursive delete outside the pack
	# library.
	if path.get_base_dir() != voice_root:
		return {"error": "The installed pack is outside packs_voice and was not removed."}
	var parent: DirAccess = DirAccess.open(voice_root)
	if parent == null or parent.is_link(path.get_file()):
		return {"error": "The installed pack folder is not safe to remove automatically."}
	var manifest_path: String = path.path_join(MANIFEST_NAME)
	if not FileAccess.file_exists(manifest_path):
		return {"error": "This folder has no community-pack manifest, so it was not removed."}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if (not parsed is Dictionary or str(parsed.get("provider", "")) != "gamebanana"
		or int(parsed.get("mod_id", 0)) != mod_id):
		return {"error": "The community-pack manifest did not match; nothing was removed."}
	if not _remove_installed_tree(path, path):
		return {"error": "Could not completely remove the installed pack."}
	if update_registry:
		var registry: Dictionary = load_registry()
		registry.erase(str(mod_id))
		save_registry(registry)
	return {"path": path}


static func load_registry() -> Dictionary:
	if not FileAccess.file_exists(REGISTRY_PATH): return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(REGISTRY_PATH))
	return parsed if parsed is Dictionary else {}


static func save_registry(registry: Dictionary) -> bool:
	var output: FileAccess = FileAccess.open(REGISTRY_PATH, FileAccess.WRITE)
	if output == null: return false
	output.store_string(JSON.stringify(registry, "  "))
	output.close()
	return true


static func _safe_relative_path(path: String) -> bool:
	if (path.is_empty() or path.length() > 512 or path.begins_with("/")
		or path.contains(String.chr(0))):
		return false
	if path.length() >= 2 and path.substr(1, 1) == ":": return false
	for part: String in path.replace("\\", "/").split("/", false):
		if part.is_empty() or part == "." or part == "..": return false
	return true


static func _junk_path(path: String) -> bool:
	var lower: String = path.to_lower()
	return (lower.begins_with("__macosx/") or lower.ends_with("/.ds_store")
		or lower == ".ds_store" or lower.ends_with("/thumbs.db") or lower == "thumbs.db"
		or lower.ends_with("/desktop.ini") or lower == "desktop.ini")


static func _safe_folder_name(value: String, mod_id: int) -> String:
	var out: String = ""
	for i: int in value.length():
		var c: String = value.substr(i, 1)
		if ("abcdefghijklmnopqrstuvwxyz0123456789".contains(c.to_lower())
			or " -_().[]".contains(c)):
			out += c
		elif not out.ends_with(" "): out += " "
	out = out.strip_edges().substr(0, 80).strip_edges()
	if out.is_empty(): out = "Dub pack"
	return "%s [GB-%d]" % [out, mod_id]


static func _remove_tree(path: String, staging_root: String) -> void:
	if not path.begins_with(staging_root + "/") or not DirAccess.dir_exists_absolute(path): return
	var dir: DirAccess = DirAccess.open(path)
	if dir == null: return
	dir.include_hidden = true
	for child: String in dir.get_directories(): _remove_tree(path.path_join(child), staging_root)
	for child: String in dir.get_files(): DirAccess.remove_absolute(path.path_join(child))
	DirAccess.remove_absolute(path)


static func _remove_installed_tree(path: String, allowed_root: String) -> bool:
	if (path != allowed_root and not path.begins_with(allowed_root + "/")):
		return false
	var dir: DirAccess = DirAccess.open(path)
	if dir == null: return false
	dir.include_hidden = true
	for child: String in dir.get_directories():
		var child_path: String = path.path_join(child)
		if dir.is_link(child):
			if DirAccess.remove_absolute(child_path) != OK: return false
		elif not _remove_installed_tree(child_path, allowed_root): return false
	for child: String in dir.get_files():
		if DirAccess.remove_absolute(path.path_join(child)) != OK: return false
	dir = null
	return DirAccess.remove_absolute(path) == OK


static func _file_size(path: String) -> int:
	var input: FileAccess = FileAccess.open(path, FileAccess.READ)
	if input == null: return -1
	var size: int = input.get_length()
	input.close()
	return size


static func _is_hex(value: String) -> bool:
	for i: int in value.length():
		if not "0123456789abcdef".contains(value.substr(i, 1).to_lower()): return false
	return true


static func _as_dictionary(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _format_bytes(bytes: int) -> String:
	if bytes >= 1024 * 1024 * 1024: return "%.2f GB" % (float(bytes) / 1073741824.0)
	if bytes >= 1024 * 1024: return "%.1f MB" % (float(bytes) / 1048576.0)
	if bytes >= 1024: return "%.1f KB" % (float(bytes) / 1024.0)
	return "%d bytes" % bytes
