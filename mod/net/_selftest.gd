extends Node
# dev tool, not shipped. register as the last autoload to compile every .gd.

class QueueTestNet:
	extends Node
	var online: bool = true
	func is_online() -> bool: return online
	func community_pack_library_changed() -> void: pass

class QueueTestInstaller:
	extends Node
	signal failed(message: String)
	var busy: bool = false
	func is_busy() -> bool: return busy
	func cancel() -> void:
		busy = false
		failed.emit("Download canceled.")

func _ready() -> void:
	var failures: Array[String] = []
	var total: int = 0
	var stack: Array[String] = ["res://"]

	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		for d: String in DirAccess.get_directories_at(dir_path):
			if d.begins_with("."):
				continue
			stack.append(dir_path.path_join(d))
		for f: String in DirAccess.get_files_at(dir_path):
			if not f.ends_with(".gd"):
				continue
			var p: String = dir_path.path_join(f)
			total += 1
			if load(p) == null:
				failures.append(p)

	print("SELFTEST | compiled %d scripts" % total)
	_run_community_pack_tests(failures)
	_run_download_queue_tests(failures)
	for f: String in failures:
		print("SELFTEST FAIL | %s" % f)
	print("SELFTEST | %d failure(s)" % failures.size())
	get_tree().quit()


func _run_community_pack_tests(failures: Array[String]) -> void:
	var client: Script = load("res://net/gamebanana_client.gd")
	var installer: Script = load("res://net/community_pack_installer.gd")
	if client == null or installer == null:
		failures.append("community pack services did not compile")
		return

	var catalog_json: String = JSON.stringify({
		"_aMetadata": {"_nRecordCount": 2, "_bIsComplete": true},
		"_aRecords": [
			{"_idRow": 10, "_sName": "Dub pack", "_aRootCategory": {"_sName": "Dub Mode"}},
			{"_idRow": 11, "_sName": "Wrong category", "_aRootCategory": {"_sName": "Audio"}},
		],
	})
	var page: Dictionary = client.parse_page_json(catalog_json, 3, true)
	if int(page.get("page", 0)) != 3 or Array(page.get("records", [])).size() != 1:
		failures.append("GameBanana catalog normalization/category filtering")
	var search_url: String = client.build_search_url("movie night", 2)
	if (search_url.contains("%%")
		or not search_url.contains("_sSearchString=movie%20night")
		or not search_url.contains("_csvFields=name%2Cdescription%2Cowner%2Ccredits")
		or not search_url.ends_with("_nPage=2")):
		failures.append("GameBanana search URL encoding")
	var api_error: String = client._http_error_message(400, JSON.stringify({
		"_sErrorCode": "INPUT_ERRORS",
		"_aErrorData": {"_sSearchString": {"_sErrorMessage": "Must be 2 characters or more"}},
	}))
	if not api_error.contains("Must be 2 characters or more"):
		failures.append("GameBanana API error details")

	var detail_json: String = JSON.stringify({
		"_idRow": 10,
		"_sName": "Dub pack",
		"_sText": "A <b>safe</b> description",
		"_aFiles": [{
			"_idRow": 99,
			"_sFile": "dub-pack.zip",
			"_sDownloadUrl": "https://gamebanana.com/dl/99",
			"_nFilesize": 1024,
			"_sMd5Checksum": "0123456789abcdef0123456789abcdef",
			"_sAnalysisState": "done",
			"_sAnalysisResult": "ok",
			"_sAvState": "done",
			"_sAvResult": "clean",
		}],
	})
	var detail: Dictionary = client.parse_detail_json(detail_json)
	var detail_files: Array = detail.get("files", [])
	if detail_files.size() != 1 or str(detail.get("description", "")) != "A safe description":
		failures.append("GameBanana detail/file normalization")
	elif not installer.installability_problem(detail_files[0]).is_empty():
		failures.append("clean GameBanana ZIP was not installable")
	if not installer.installability_problem({"name": "pack.rar"}).contains("RAR"):
		failures.append("RAR archive guidance")
	var long_name: String = "A".repeat(100) + ".rar"
	var compact: String = load("res://net/community_pack_browser.gd")._compact_text(long_name, 40)
	if compact.length() > 40 or not compact.ends_with(".rar") or not compact.contains("…"):
		failures.append("community browser long-name compaction")

	for unsafe: String in ["../outside.wav", "/absolute.wav", "C:/drive.wav", "ok/../outside.wav"]:
		if installer._safe_relative_path(unsafe):
			failures.append("unsafe archive path accepted: %s" % unsafe)

	var zip_path: String = "user://community-pack-selftest.zip"
	if FileAccess.file_exists(zip_path): DirAccess.remove_absolute(zip_path)
	var packer: = ZIPPacker.new()
	var zip_error: Error = packer.open(zip_path)
	if zip_error == OK:
		for path: String in ["wrapper/dub_video.ogv", "wrapper/line.wav", "wrapper/line.ini"]:
			packer.start_file(path)
			packer.write_file(PackedByteArray([1, 2, 3]))
			packer.close_file()
		packer.close()
		var indexed: Dictionary = installer.inspect_zip(zip_path)
		var entries: Array = indexed.get("entries", [])
		if indexed.has("error") or entries.size() != 3:
			failures.append("valid ZIP central directory inspection")
		else:
			var typed_entries: Array[Dictionary] = []
			for value: Variant in entries:
				if value is Dictionary: typed_entries.append(value)
			if installer._find_dub_root(typed_entries) != "wrapper":
				failures.append("dub root detection")
			var test_root: String = "user://community-pack-selftest-packs"
			var result: Dictionary = installer._validate_and_extract(
				zip_path,
				{"id": 2147483646, "name": "Selftest pack", "author": "Selftest"},
				{"id": 123, "name": "fixture.zip", "md5": FileAccess.get_md5(zip_path)},
				test_root,
				false)
			if result.has("error"):
				failures.append("validated ZIP extraction: %s" % str(result["error"]))
			else:
				var installed: String = str(result.get("path", ""))
				if not FileAccess.file_exists(installed.path_join("dub_video.ogv")):
					failures.append("validated ZIP was not moved into packs_voice")
				_remove_test_tree(installed, test_root)
			_remove_test_tree(test_root.path_join(".tcv-community-staging"), test_root)
			DirAccess.remove_absolute(test_root)
	else:
		failures.append("could not create ZIP self-test fixture")
	if FileAccess.file_exists(zip_path): DirAccess.remove_absolute(zip_path)
	_test_flat_pack_archive(installer, failures)

	if failures.is_empty(): print("SELFTEST PASS | community catalog and ZIP safety checks")


func _test_flat_pack_archive(installer: Script, failures: Array[String]) -> void:
	var zip_path: String = "user://community-pack-flat-selftest.zip"
	var test_root: String = "user://community-pack-flat-selftest-packs"
	if FileAccess.file_exists(zip_path): DirAccess.remove_absolute(zip_path)
	var packer: = ZIPPacker.new()
	if packer.open(zip_path) != OK:
		failures.append("could not create flat ZIP self-test fixture")
		return
	for path: String in ["dub_video.ogv", "line.wav", "line.ini"]:
		packer.start_file(path)
		packer.write_file(PackedByteArray([4, 5, 6]))
		packer.close_file()
	packer.close()

	var indexed: Dictionary = installer.inspect_zip(zip_path)
	var entries: Array[Dictionary] = []
	for value: Variant in Array(indexed.get("entries", [])):
		if value is Dictionary: entries.append(value)
	if indexed.has("error") or installer._find_dub_root(entries) != "":
		failures.append("flat dub-pack ZIP detection")
	else:
		var result: Dictionary = installer._validate_and_extract(
			zip_path,
			{"id": 2147483645, "name": "Flat selftest pack", "author": "Selftest"},
			{"id": 124, "name": "flat-fixture.zip", "md5": FileAccess.get_md5(zip_path)},
			test_root,
			false)
		if result.has("error"):
			failures.append("flat ZIP installation: %s" % str(result["error"]))
		else:
			var installed: String = str(result.get("path", ""))
			if (installed == test_root or installed.get_base_dir() != test_root
				or not FileAccess.file_exists(installed.path_join("dub_video.ogv"))
				or FileAccess.file_exists(test_root.path_join("dub_video.ogv"))):
				failures.append("flat ZIP files were not contained in their own pack folder")
			var listed: Array[Dictionary] = installer.installed_packs(test_root)
			if (listed.size() != 1 or str(listed[0].get("path", "")) != installed
				or int(listed[0].get("mod_id", 0)) != 2147483645
				or int(listed[0].get("installed_files", 0)) != 3
				or int(listed[0].get("installed_bytes", 0)) != 9):
				failures.append("installed community-pack library scan")
			var removed: Dictionary = installer._uninstall_path(
				2147483645, installed, test_root, false)
			if removed.has("error") or DirAccess.dir_exists_absolute(installed):
				failures.append("guarded community-pack uninstall: %s" % str(removed))
	_remove_test_tree(test_root.path_join(".tcv-community-staging"), test_root)
	DirAccess.remove_absolute(test_root)
	if FileAccess.file_exists(zip_path): DirAccess.remove_absolute(zip_path)


func _remove_test_tree(path: String, allowed_root: String) -> void:
	var prefix: String = allowed_root.trim_suffix("/") + "/"
	if (path.is_empty() or not path.begins_with(prefix)
		or not DirAccess.dir_exists_absolute(path)):
		return
	var dir: DirAccess = DirAccess.open(path)
	if dir == null: return
	dir.include_hidden = true
	for child: String in dir.get_directories():
		_remove_test_tree(path.path_join(child), allowed_root)
	for child: String in dir.get_files(): DirAccess.remove_absolute(path.path_join(child))
	DirAccess.remove_absolute(path)


func _run_download_queue_tests(failures: Array[String]) -> void:
	var queue_script: Script = load("res://net/community_pack_queue.gd")
	if queue_script == null:
		failures.append("community download queue did not compile")
		return
	var fake_net: = QueueTestNet.new()
	var queue: Node = queue_script.new()
	add_child(fake_net)
	queue.configure(fake_net)
	add_child(queue)
	queue.set_allow_online_downloads(false)
	var mod: Dictionary = {"id": 42, "name": "Queue test"}
	var invalid_file: Dictionary = {"id": 7, "name": "not-a-zip.rar", "size": 100}
	var id: String = queue.enqueue(mod, invalid_file)
	if str(queue.get_job(id).get("state", "")) != "queued":
		failures.append("download queue did not retain an online job")
	queue.cancel(id)
	if str(queue.get_job(id).get("state", "")) != "canceled":
		failures.append("queued download cancellation")
	queue.retry(id)
	if str(queue.get_job(id).get("state", "")) != "queued":
		failures.append("canceled download retry")
	var real_installer: Node = queue.get("_installer")
	var fake_installer: = QueueTestInstaller.new()
	fake_installer.failed.connect(Callable(queue, "_on_failed"))
	queue.add_child(fake_installer)
	queue.set("_installer", fake_installer)
	queue.set("_active_id", id)
	var jobs: Array = queue.get("_jobs")
	jobs[0]["state"] = "downloading"
	fake_installer.busy = true
	queue.cancel(id)
	if (str(queue.get_job(id).get("state", "")) != "canceled"
		or queue.active_count() != 0):
		failures.append("active download cancellation did not release the queue")
	queue.dismiss(id)
	if not queue.get_job(id).is_empty(): failures.append("terminal download dismissal")
	queue.set("_installer", real_installer)
	fake_installer.queue_free()

	fake_net.online = false
	var failed_id: String = queue.enqueue({"id": 43, "name": "Bad archive"}, invalid_file)
	queue._pump()
	if (str(queue.get_job(failed_id).get("state", "")) != "failed"
		or queue.active_count() != 0):
		failures.append("failed download did not release the queue")
	queue.dismiss(failed_id)
	fake_net.online = true
	queue.set_allow_online_downloads(true)
	var online_id: String = queue.enqueue(
		{"id": 44, "name": "Online opt-in"},
		{"id": 8, "name": "still-not-a-zip.rar", "size": 100})
	queue._pump()
	if str(queue.get_job(online_id).get("state", "")) != "failed":
		failures.append("online download opt-in did not release a queued job")
	queue.set_allow_online_downloads(false)
	queue.queue_free()
	fake_net.queue_free()
