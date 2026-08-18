extends Node
# Small read-only client for the public GameBanana catalog. The browser talks to
# this node instead of baking response shapes into its controls, which also
# gives the parsers somewhere deterministic to be tested without the network.

signal page_loaded(payload: Dictionary)
signal detail_loaded(payload: Dictionary)
signal request_failed(message: String)

const GAME_ID: int = 20674
const DUB_CATEGORY_ID: int = 44064
const PAGE_SIZE: int = 18
const API_BODY_LIMIT: int = 8 * 1024 * 1024

const INDEX_URL: String = "https://gamebanana.com/apiv13/Mod/Index"
const SEARCH_URL: String = "https://gamebanana.com/apiv13/Util/Search/Results"
const DETAIL_URL: String = "https://gamebanana.com/apiv11/Mod/%d"
const SEARCH_FIELDS: String = "name,description,owner,credits"

var _http: HTTPRequest
var _request_kind: String = ""
var _request_page: int = 1


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.timeout = 15.0
	_http.body_size_limit = API_BODY_LIMIT
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)


func is_busy() -> bool:
	return not _request_kind.is_empty()


func cancel() -> void:
	if is_busy(): _http.cancel_request()
	_request_kind = ""


func fetch_page(page: int, sort: String = "Generic_Newest", force: bool = false) -> void:
	if is_busy(): return
	_request_kind = "page"
	_request_page = maxi(1, page)
	var url: String = (INDEX_URL
		+ "?_nPerpage=%d" % PAGE_SIZE
		+ "&_aFilters%%5BGeneric_Category%%5D=%d" % DUB_CATEGORY_ID
		+ "&_nPage=%d" % _request_page
		+ "&_sSort=%s" % sort.uri_encode())
	_start(url, force)


func search(query: String, page: int, sort: String = "best_match", force: bool = false) -> void:
	if is_busy(): return
	var clean: String = query.strip_edges()
	if clean.is_empty():
		fetch_page(page, "Generic_Newest", force)
		return
	if clean.length() < 2:
		request_failed.emit("Search for at least 2 characters.")
		return
	_request_kind = "search"
	_request_page = maxi(1, page)
	_start(build_search_url(clean, _request_page, sort), force)


static func build_search_url(query: String, page: int, sort: String = "best_match") -> String:
	return (SEARCH_URL
		+ "?_sModelName=Mod"
		+ "&_sOrder=%s" % sort.uri_encode()
		+ "&_idGameRow=%d" % GAME_ID
		+ "&_sSearchString=%s" % query.strip_edges().uri_encode()
		+ "&_csvFields=%s" % SEARCH_FIELDS.uri_encode()
		+ "&_nPerpage=%d" % PAGE_SIZE
		+ "&_nPage=%d" % maxi(1, page))


func fetch_detail(mod_id: int, force: bool = false) -> void:
	if is_busy() or mod_id <= 0: return
	_request_kind = "detail"
	var fields: String = ("_idRow,_sName,_sText,_sDescription,_sVersion,_aFiles,"
		+ "_sProfileUrl,_aSubmitter,_aRootCategory,_aPreviewMedia,_bIsObsolete")
	var url: String = (DETAIL_URL % mod_id) + "?_csvProperties=" + fields.uri_encode()
	_start(url, force)


func _start(url: String, force: bool) -> void:
	var headers: PackedStringArray = [
		"Accept: application/json",
		"User-Agent: TCV-Multiplayer/%s" % str(Net.MOD_VERSION),
	]
	if force: headers.append("Cache-Control: no-cache")
	var error: Error = _http.request(url, headers)
	if error != OK:
		_request_kind = ""
		request_failed.emit("Could not start the GameBanana request (%s)." % error_string(error))


func _on_request_completed(
	result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	var kind: String = _request_kind
	_request_kind = ""
	if result != HTTPRequest.RESULT_SUCCESS:
		request_failed.emit("GameBanana request failed (%d)." % result)
		return
	if response_code < 200 or response_code >= 300:
		request_failed.emit(_http_error_message(response_code, body.get_string_from_utf8()))
		return
	var text: String = body.get_string_from_utf8()
	if kind == "detail":
		var detail: Dictionary = parse_detail_json(text)
		if detail.has("error"): request_failed.emit(str(detail["error"]))
		else: detail_loaded.emit(detail)
	else:
		var page: Dictionary = parse_page_json(text, _request_page, kind == "search")
		if page.has("error"): request_failed.emit(str(page["error"]))
		else: page_loaded.emit(page)


static func _http_error_message(response_code: int, text: String) -> String:
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		var error_data: Dictionary = _as_dictionary(parsed.get("_aErrorData", {}))
		for value: Variant in error_data.values():
			if value is Dictionary:
				var message: String = str(value.get("_sErrorMessage", "")).strip_edges()
				if not message.is_empty():
					return "GameBanana rejected the request: %s." % message.trim_suffix(".")
		var code: String = str(parsed.get("_sErrorCode", "")).strip_edges()
		if not code.is_empty(): return "GameBanana rejected the request: %s." % code
	return "GameBanana returned HTTP %d." % response_code


static func parse_page_json(text: String, page: int = 1, dub_only: bool = false) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary: return {"error": "GameBanana returned malformed catalog data."}
	var root: Dictionary = parsed
	if root.has("_sErrorCode"):
		return {"error": "GameBanana rejected the catalog request: %s" % str(root["_sErrorCode"])}
	var metadata: Dictionary = _as_dictionary(root.get("_aMetadata", {}))
	var records: Array[Dictionary] = []
	for value: Variant in _as_array(root.get("_aRecords", [])):
		if not value is Dictionary: continue
		var record: Dictionary = _normalize_record(value)
		if record.is_empty(): continue
		if dub_only and str(record.get("category", "")).to_lower() != "dub mode": continue
		records.append(record)
	return {
		"page": maxi(1, page),
		"records": records,
		"total": maxi(0, int(metadata.get("_nRecordCount", records.size()))),
		"complete": bool(metadata.get("_bIsComplete", records.is_empty())),
	}


static func parse_detail_json(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary: return {"error": "GameBanana returned malformed pack data."}
	var root: Dictionary = parsed
	if root.has("_sErrorCode"):
		return {"error": "GameBanana rejected the pack request: %s" % str(root["_sErrorCode"])}
	var detail: Dictionary = _normalize_record(root)
	if detail.is_empty(): return {"error": "The pack details did not contain a valid ID or name."}
	detail["description"] = _plain_text(str(root.get("_sText", root.get("_sDescription", ""))))
	var files: Array[Dictionary] = []
	for value: Variant in _as_array(root.get("_aFiles", [])):
		if not value is Dictionary: continue
		var item: Dictionary = value
		var file_id: int = int(item.get("_idRow", 0))
		var name: String = str(item.get("_sFile", "")).strip_edges()
		var url: String = str(item.get("_sDownloadUrl", ""))
		if file_id <= 0 or name.is_empty() or not url.begins_with("https://gamebanana.com/dl/"):
			continue
		files.append({
			"id": file_id,
			"name": name,
			"size": maxi(0, int(item.get("_nFilesize", 0))),
			"url": url,
			"md5": str(item.get("_sMd5Checksum", "")).to_lower(),
			"analysis_state": str(item.get("_sAnalysisState", "")),
			"analysis_result": str(item.get("_sAnalysisResult", "")),
			"analysis_text": str(item.get("_sAnalysisResultVerbose", "")),
			"av_state": str(item.get("_sAvState", "")),
			"av_result": str(item.get("_sAvResult", "")),
			"archived": bool(item.get("_bIsArchived", false)),
			"version": str(item.get("_sVersion", "")),
			"description": _plain_text(str(item.get("_sDescription", ""))),
		})
	detail["files"] = files
	return detail


static func _normalize_record(value: Dictionary) -> Dictionary:
	var mod_id: int = int(value.get("_idRow", 0))
	var name: String = str(value.get("_sName", "")).strip_edges()
	if mod_id <= 0 or name.is_empty(): return {}
	var author: Dictionary = _as_dictionary(value.get("_aSubmitter", {}))
	var category: Dictionary = _as_dictionary(value.get("_aRootCategory", {}))
	var subcategory: Dictionary = _as_dictionary(value.get("_aSubCategory", {}))
	return {
		"id": mod_id,
		"name": name,
		"profile_url": str(value.get("_sProfileUrl", "https://gamebanana.com/mods/%d" % mod_id)),
		"author": str(author.get("_sName", "Unknown creator")),
		"author_url": str(author.get("_sProfileUrl", "")),
		"category": str(category.get("_sName", "")),
		"subcategory": str(subcategory.get("_sName", "")),
		"version": str(value.get("_sVersion", "")),
		"image_url": _preview_url(value),
		"modified": int(value.get("_tsDateModified", value.get("_tsDateAdded", 0))),
		"obsolete": bool(value.get("_bIsObsolete", false)),
		"content_rated": bool(value.get("_bHasContentRatings", false)),
		"pay_type": str(value.get("_sPayType", "free")),
	}


static func _preview_url(value: Dictionary) -> String:
	var content: Dictionary = _as_dictionary(value.get("_aPreviewContent", {}))
	var shot: Dictionary = _as_dictionary(content.get("screenshot", {}))
	if not shot.is_empty():
		var file: String = str(shot.get("_sFile530", shot.get("_sFile220", shot.get("_sFile", ""))))
		var base: String = str(shot.get("_sBaseUrl", "")).trim_suffix("/")
		if not base.is_empty() and not file.is_empty(): return base + "/" + file
	var media: Dictionary = _as_dictionary(value.get("_aPreviewMedia", {}))
	var images: Array = _as_array(media.get("_aImages", []))
	if not images.is_empty() and images[0] is Dictionary:
		shot = images[0]
		var media_file: String = str(shot.get(
			"_sFile530", shot.get("_sFile220", shot.get("_sFile", ""))))
		var media_base: String = str(shot.get("_sBaseUrl", "")).trim_suffix("/")
		if not media_base.is_empty() and not media_file.is_empty():
			return media_base + "/" + media_file
	return ""


static func _plain_text(value: String) -> String:
	var out: String = value.replace("<br>", "\n").replace("<br/>", "\n").replace("<br />", "\n")
	var tags: = RegEx.new()
	if tags.compile("<[^>]*>") == OK: out = tags.sub(out, "", true)
	return out.replace("&amp;", "&").replace("&quot;", "\"").replace("&#039;", "'").replace(
		"&lt;", "<").replace("&gt;", ">").replace("&nbsp;", " ").strip_edges()


static func _as_dictionary(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _as_array(value: Variant) -> Array:
	return value if value is Array else []
