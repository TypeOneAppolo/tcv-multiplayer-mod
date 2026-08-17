extends Node
# Session-long download queue. It lives under the Net autoload rather than the
# catalog screen, so closing the browser or entering an offline game does not
# tear down a large download.

signal changed

const INSTALLER_SCRIPT: Script = preload("res://net/community_pack_installer.gd")

var _net: Node
var _installer: Node
var _jobs: Array[Dictionary] = []
var _active_id: String = ""
var _cancel_requested: bool = false
var _last_online: bool = false
var _poll_elapsed: float = 0.0
var _last_progress_emit_msec: int = 0


func configure(net: Node) -> void:
	_net = net
	_last_online = _net.is_online()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_installer = INSTALLER_SCRIPT.new()
	_installer.progress.connect(_on_progress)
	_installer.finished.connect(_on_finished)
	_installer.failed.connect(_on_failed)
	add_child(_installer)


func _process(delta: float) -> void:
	_poll_elapsed += delta
	if _poll_elapsed < 0.5: return
	_poll_elapsed = 0.0
	var online: bool = _net != null and _net.is_online()
	if online != _last_online:
		_last_online = online
		changed.emit()
	if _active_id.is_empty() and not online: _pump()


func enqueue(mod: Dictionary, file: Dictionary) -> String:
	var mod_id: int = int(mod.get("id", 0))
	var file_id: int = int(file.get("id", 0))
	if mod_id <= 0 or file_id <= 0: return ""
	var id: String = job_id(mod_id, file_id)
	var index: int = _job_index(id)
	if index >= 0:
		var state: String = str(_jobs[index].get("state", ""))
		if state in ["queued", "downloading", "verifying", "installing"]: return id
		_jobs.remove_at(index)
	_jobs.append({
		"id": id,
		"mod": mod.duplicate(true),
		"file": file.duplicate(true),
		"state": "queued",
		"received": 0,
		"total": int(file.get("size", 0)),
		"status": "Queued",
		"error": "",
		"result": {},
	})
	changed.emit()
	_pump.call_deferred()
	return id


func cancel(id: String) -> void:
	var index: int = _job_index(id)
	if index < 0: return
	if id == _active_id:
		if str(_jobs[index].get("state", "")) != "downloading": return
		_cancel_requested = true
		_installer.cancel()
		return
	if str(_jobs[index].get("state", "")) == "queued":
		_jobs[index]["state"] = "canceled"
		_jobs[index]["status"] = "Canceled"
		changed.emit()


func dismiss(id: String) -> void:
	var index: int = _job_index(id)
	if index < 0: return
	if str(_jobs[index].get("state", "")) in ["finished", "failed", "canceled"]:
		_jobs.remove_at(index)
		changed.emit()


func dismiss_for_mod(mod_id: int) -> void:
	var removed: bool = false
	for index: int in range(_jobs.size() - 1, -1, -1):
		if int(_jobs[index].get("mod", {}).get("id", 0)) != mod_id: continue
		if str(_jobs[index].get("state", "")) not in ["finished", "failed", "canceled"]: continue
		_jobs.remove_at(index)
		removed = true
	if removed: changed.emit()


func retry(id: String) -> void:
	var record: Dictionary = get_job(id)
	if record.is_empty(): return
	if str(record.get("state", "")) not in ["failed", "canceled"]: return
	enqueue(record.get("mod", {}), record.get("file", {}))


func get_job(id: String) -> Dictionary:
	var index: int = _job_index(id)
	return _jobs[index].duplicate(true) if index >= 0 else {}


func get_jobs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for record: Dictionary in _jobs: out.append(record.duplicate(true))
	return out


func job_for(mod_id: int, file_id: int) -> Dictionary:
	return get_job(job_id(mod_id, file_id))


func active_count() -> int:
	var total: int = 0
	for record: Dictionary in _jobs:
		if str(record.get("state", "")) in ["queued", "downloading", "verifying", "installing"]:
			total += 1
	return total


func is_busy() -> bool:
	return active_count() > 0


static func job_id(mod_id: int, file_id: int) -> String:
	return "%d:%d" % [mod_id, file_id]


func _pump() -> void:
	if not _active_id.is_empty() or _installer.is_busy(): return
	if _net != null and _net.is_online(): return
	for index: int in _jobs.size():
		if str(_jobs[index].get("state", "")) != "queued": continue
		_active_id = str(_jobs[index]["id"])
		_cancel_requested = false
		_jobs[index]["state"] = "downloading"
		_jobs[index]["status"] = "Connecting to GameBanana..."
		changed.emit()
		_installer.install(_jobs[index]["mod"], _jobs[index]["file"])
		return


func _on_progress(received: int, total: int, status: String) -> void:
	var index: int = _job_index(_active_id)
	if index < 0: return
	var previous_state: String = str(_jobs[index].get("state", ""))
	_jobs[index]["received"] = received
	_jobs[index]["total"] = total
	_jobs[index]["status"] = status
	var lower: String = status.to_lower()
	if lower.contains("verifying"): _jobs[index]["state"] = "verifying"
	elif lower.contains("installing") or lower.contains("checking"):
		_jobs[index]["state"] = "installing"
	else: _jobs[index]["state"] = "downloading"
	var now: int = Time.get_ticks_msec()
	if (str(_jobs[index].get("state", "")) != previous_state
		or now - _last_progress_emit_msec >= 100 or received >= total):
		_last_progress_emit_msec = now
		changed.emit()


func _on_finished(result: Dictionary) -> void:
	var index: int = _job_index(_active_id)
	if index >= 0:
		_jobs[index]["state"] = "finished"
		_jobs[index]["status"] = "Installed"
		_jobs[index]["received"] = int(_jobs[index].get("total", 0))
		_jobs[index]["result"] = result.duplicate(true)
	var completed_id: String = _active_id
	_active_id = ""
	_cancel_requested = false
	if _net != null: _net.community_pack_library_changed()
	changed.emit()
	if not completed_id.is_empty(): _pump.call_deferred()


func _on_failed(message: String) -> void:
	var index: int = _job_index(_active_id)
	if index >= 0:
		_jobs[index]["state"] = "canceled" if _cancel_requested else "failed"
		_jobs[index]["status"] = "Canceled" if _cancel_requested else "Download failed"
		_jobs[index]["error"] = "" if _cancel_requested else message
	_active_id = ""
	_cancel_requested = false
	changed.emit()
	_pump.call_deferred()


func _job_index(id: String) -> int:
	for index: int in _jobs.size():
		if str(_jobs[index].get("id", "")) == id: return index
	return -1
