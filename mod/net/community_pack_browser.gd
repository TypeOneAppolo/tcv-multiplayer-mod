extends Control
# Native catalog UI. It is an overlay rather than a web view: only JSON, a
# selected preview image and the chosen archive ever leave GameBanana.

signal closed

const CATALOG_SCRIPT: Script = preload("res://net/gamebanana_client.gd")
const INSTALLER_SCRIPT: Script = preload("res://net/community_pack_installer.gd")

const BG: Color = Color("080b14")
const SURFACE: Color = Color("121827")
const SURFACE_2: Color = Color("1a2234")
const BORDER: Color = Color("34415d")
const TEXT: Color = Color("f3f5fb")
const MUTED: Color = Color("9ba7bd")
const ACCENT: Color = Color("61c4ff")
const WARNING: Color = Color("ffca58")
const SUCCESS: Color = Color("63d69a")
const DANGER: Color = Color("ff7b83")

var _catalog: Node
var _installer: Node
var _image_http: HTTPRequest

var _page: int = 1
var _complete: bool = false
var _query: String = ""
var _records: Array[Dictionary] = []
var _selected: Dictionary = {}
var _detail: Dictionary = {}
var _loading_detail: bool = false

var _search: LineEdit
var _sort: OptionButton
var _rated: CheckBox
var _page_label: Label
var _list_status: Label
var _list: VBoxContainer
var _previous: Button
var _next: Button

var _preview: TextureRect
var _preview_placeholder: Label
var _detail_title: Label
var _detail_meta: Label
var _detail_description: Label
var _file_picker: OptionButton
var _install_status: Label
var _install_progress: ProgressBar
var _install_button: Button
var _open_button: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_fit_to_viewport()
	get_viewport().size_changed.connect(_fit_to_viewport)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_catalog = CATALOG_SCRIPT.new()
	_catalog.page_loaded.connect(_on_page_loaded)
	_catalog.detail_loaded.connect(_on_detail_loaded)
	_catalog.request_failed.connect(_on_request_failed)
	add_child(_catalog)
	_installer = INSTALLER_SCRIPT.new()
	_installer.progress.connect(_on_install_progress)
	_installer.finished.connect(_on_install_finished)
	_installer.failed.connect(_on_install_failed)
	add_child(_installer)
	_image_http = HTTPRequest.new()
	_image_http.use_threads = true
	_image_http.timeout = 12.0
	_image_http.body_size_limit = 12 * 1024 * 1024
	_image_http.request_completed.connect(_on_image_loaded)
	add_child(_image_http)
	_load_page()


func _fit_to_viewport() -> void:
	position = Vector2.ZERO
	size = get_viewport_rect().size


func _exit_tree() -> void:
	if is_instance_valid(_catalog): _catalog.cancel()
	if is_instance_valid(_installer) and _installer.is_busy(): _installer.cancel()
	if is_instance_valid(_image_http): _image_http.cancel_request()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not _installer.is_busy():
		get_viewport().set_input_as_handled()
		closed.emit()


func _build_ui() -> void:
	var backdrop: = ColorRect.new()
	backdrop.color = BG
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var margin: = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)

	var main: = VBoxContainer.new()
	main.add_theme_constant_override("separation", 16)
	margin.add_child(main)

	var header: = HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	main.add_child(header)
	var heading_box: = VBoxContainer.new()
	heading_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading_box)
	var heading: = Label.new()
	heading.text = "COMMUNITY PACKS"
	heading.add_theme_font_size_override("font_size", 30)
	heading.add_theme_color_override("font_color", TEXT)
	heading_box.add_child(heading)
	var subheading: = Label.new()
	subheading.text = "Browse and install Dub Mode packs without leaving the game"
	subheading.add_theme_font_size_override("font_size", 14)
	subheading.add_theme_color_override("font_color", MUTED)
	heading_box.add_child(subheading)
	var source: = Label.new()
	source.text = "  GAMEBANANA  •  DUB MODE  "
	source.add_theme_font_size_override("font_size", 13)
	source.add_theme_color_override("font_color", ACCENT)
	header.add_child(source)
	var close: Button = _button("Close", false)
	close.pressed.connect(func() -> void:
		if not _installer.is_busy(): closed.emit())
	header.add_child(close)

	var tools: = HBoxContainer.new()
	tools.add_theme_constant_override("separation", 10)
	main.add_child(tools)
	_search = LineEdit.new()
	_search.placeholder_text = "Search dub packs, creators or descriptions..."
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.custom_minimum_size.y = 40
	_search.text_submitted.connect(func(text: String) -> void:
		_query = text.strip_edges()
		_page = 1
		_load_page())
	tools.add_child(_search)
	var search_button: Button = _button("Search", true)
	search_button.pressed.connect(func() -> void:
		_query = _search.text.strip_edges()
		_page = 1
		_load_page())
	tools.add_child(search_button)
	_sort = OptionButton.new()
	_sort.add_item("Newest")
	_sort.set_item_metadata(0, "Generic_Newest")
	_sort.add_item("Recently updated")
	_sort.set_item_metadata(1, "Generic_LatestModified")
	_sort.add_item("Most downloaded")
	_sort.set_item_metadata(2, "Generic_MostDownloaded")
	_sort.add_item("Most liked")
	_sort.set_item_metadata(3, "Generic_MostLiked")
	_sort.tooltip_text = "Sorting applies while browsing. Searches are ordered by relevance."
	_sort.item_selected.connect(func(_index: int) -> void:
		_page = 1
		_load_page())
	tools.add_child(_sort)
	_rated = CheckBox.new()
	_rated.text = "Include content-rated"
	_rated.tooltip_text = "Content-rated packs are hidden by default."
	_rated.toggled.connect(func(_on: bool) -> void: _render_list())
	tools.add_child(_rated)
	var refresh: Button = _button("Refresh", false)
	refresh.pressed.connect(func() -> void: _load_page(true))
	tools.add_child(refresh)

	var split: = HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 480
	main.add_child(split)

	var left_panel: = PanelContainer.new()
	left_panel.custom_minimum_size.x = 420
	left_panel.add_theme_stylebox_override("panel", _box(SURFACE, 12, BORDER, 1))
	split.add_child(left_panel)
	var left_margin: = MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		left_margin.add_theme_constant_override("margin_" + side, 14)
	left_panel.add_child(left_margin)
	var left: = VBoxContainer.new()
	left.add_theme_constant_override("separation", 10)
	left_margin.add_child(left)
	_list_status = Label.new()
	_list_status.add_theme_color_override("font_color", MUTED)
	left.add_child(_list_status)
	var scroll: = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 7)
	scroll.add_child(_list)
	var paging: = HBoxContainer.new()
	paging.alignment = BoxContainer.ALIGNMENT_CENTER
	paging.add_theme_constant_override("separation", 10)
	left.add_child(paging)
	_previous = _button("Previous", false)
	_previous.pressed.connect(func() -> void:
		if _page > 1:
			_page -= 1
			_load_page())
	paging.add_child(_previous)
	_page_label = Label.new()
	_page_label.custom_minimum_size.x = 100
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	paging.add_child(_page_label)
	_next = _button("Next", false)
	_next.pressed.connect(func() -> void:
		if not _complete:
			_page += 1
			_load_page())
	paging.add_child(_next)

	var right_panel: = PanelContainer.new()
	right_panel.custom_minimum_size.x = 400
	right_panel.add_theme_stylebox_override("panel", _box(SURFACE, 12, BORDER, 1))
	split.add_child(right_panel)
	var right_margin: = MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		right_margin.add_theme_constant_override("margin_" + side, 18)
	right_panel.add_child(right_margin)
	var detail_scroll: = ScrollContainer.new()
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_margin.add_child(detail_scroll)
	var detail: = VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation", 10)
	detail_scroll.add_child(detail)
	var preview_panel: = PanelContainer.new()
	preview_panel.custom_minimum_size = Vector2(400, 170)
	preview_panel.add_theme_stylebox_override("panel", _box(SURFACE_2, 8, BORDER, 1))
	detail.add_child(preview_panel)
	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview_panel.add_child(_preview)
	_preview_placeholder = Label.new()
	_preview_placeholder.text = "SELECT A PACK TO PREVIEW"
	_preview_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_preview_placeholder.add_theme_font_size_override("font_size", 13)
	_preview_placeholder.add_theme_color_override("font_color", MUTED)
	preview_panel.add_child(_preview_placeholder)
	_detail_title = Label.new()
	_detail_title.text = "Choose a pack"
	_detail_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_title.add_theme_font_size_override("font_size", 24)
	_detail_title.add_theme_color_override("font_color", TEXT)
	detail.add_child(_detail_title)
	_detail_meta = Label.new()
	_detail_meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_meta.add_theme_color_override("font_color", MUTED)
	detail.add_child(_detail_meta)
	_detail_description = Label.new()
	_detail_description.text = "Select a result to see its files and installation status."
	_detail_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_child(_detail_description)
	var file_label: = Label.new()
	file_label.text = "Download file"
	file_label.add_theme_font_size_override("font_size", 14)
	file_label.add_theme_color_override("font_color", MUTED)
	detail.add_child(file_label)
	_file_picker = OptionButton.new()
	_file_picker.disabled = true
	_file_picker.item_selected.connect(func(_index: int) -> void: _refresh_install_action())
	detail.add_child(_file_picker)
	_install_progress = ProgressBar.new()
	_install_progress.visible = false
	_install_progress.show_percentage = true
	detail.add_child(_install_progress)
	_install_status = Label.new()
	_install_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_install_status.add_theme_color_override("font_color", MUTED)
	detail.add_child(_install_status)
	var detail_buttons: = HBoxContainer.new()
	detail_buttons.add_theme_constant_override("separation", 8)
	detail.add_child(detail_buttons)
	_install_button = _button("Install pack", true)
	_install_button.disabled = true
	_install_button.pressed.connect(_on_install_pressed)
	detail_buttons.add_child(_install_button)
	_open_button = _button("Open on GameBanana", false)
	_open_button.disabled = true
	_open_button.pressed.connect(func() -> void:
		var url: String = str(_selected.get("profile_url", ""))
		if url.begins_with("https://gamebanana.com/"): OS.shell_open(url))
	detail_buttons.add_child(_open_button)
	var caution: = Label.new()
	caution.text = ("Downloads are community content. ZIPs are staged and checked before installation, "
		+ "but only install packs from creators you trust.")
	caution.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caution.add_theme_color_override("font_color", WARNING)
	detail.add_child(caution)


func _load_page(force: bool = false) -> void:
	if not is_instance_valid(_catalog) or _catalog.is_busy(): return
	_loading_detail = false
	_set_list_busy(true)
	_records.clear()
	_render_list()
	if _query.is_empty():
		_catalog.fetch_page(_page, str(_sort.get_item_metadata(_sort.selected)), force)
	else:
		_catalog.search(_query, _page, "best_match", force)


func _set_list_busy(busy: bool) -> void:
	_search.editable = not busy
	_sort.disabled = busy or not _query.is_empty()
	_previous.disabled = busy or _page <= 1
	_next.disabled = busy or _complete
	if busy: _list_status.text = "Loading from GameBanana..."


func _on_page_loaded(payload: Dictionary) -> void:
	_loading_detail = false
	_page = int(payload.get("page", _page))
	_complete = bool(payload.get("complete", false))
	_records.clear()
	for value: Variant in Array(payload.get("records", [])):
		if value is Dictionary: _records.append(value)
	_set_list_busy(false)
	_page_label.text = "Page %d" % _page
	_previous.disabled = _page <= 1
	_next.disabled = _complete
	var total: int = int(payload.get("total", 0))
	_list_status.text = "%s%d dub pack%s" % [
		"About " if not _complete else "", total, "" if total == 1 else "s"]
	_render_list()


func _render_list() -> void:
	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	var shown: int = 0
	var hidden: int = 0
	for record: Dictionary in _records:
		if bool(record.get("content_rated", false)) and not _rated.button_pressed:
			hidden += 1
			continue
		shown += 1
		var row: Button = Button.new()
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.custom_minimum_size.y = 68
		row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var category: String = str(record.get("subcategory", ""))
		if category.is_empty(): category = str(record.get("category", "Dub Mode"))
		if category.is_empty(): category = "Dub Mode"
		var warning: String = "  •  CONTENT-RATED" if bool(record.get("content_rated", false)) else ""
		row.text = "%s\nby %s  •  %s%s" % [record["name"], record["author"], category, warning]
		row.tooltip_text = str(record.get("name", ""))
		row.add_theme_font_size_override("font_size", 15)
		row.add_theme_color_override("font_color", TEXT)
		row.add_theme_color_override("font_hover_color", TEXT)
		row.add_theme_stylebox_override("normal", _box(SURFACE_2, 8, Color.TRANSPARENT, 0))
		row.add_theme_stylebox_override("hover", _box(Color("25304a"), 8, ACCENT, 1))
		row.add_theme_stylebox_override("pressed", _box(Color("202c45"), 8, ACCENT, 2))
		row.pressed.connect(_select_record.bind(record))
		_list.add_child(row)
	if shown == 0 and not _records.is_empty():
		var empty: = Label.new()
		empty.text = "%d content-rated result(s) hidden. Enable the checkbox above to show them." % hidden
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", MUTED)
		_list.add_child(empty)
	elif shown == 0 and not _catalog.is_busy():
		var empty: = Label.new()
		empty.text = "No Dub Mode packs were found on this page."
		empty.add_theme_color_override("font_color", MUTED)
		_list.add_child(empty)


func _select_record(record: Dictionary) -> void:
	if _installer.is_busy() or _catalog.is_busy(): return
	_loading_detail = true
	_selected = record.duplicate(true)
	_detail.clear()
	_preview.texture = null
	_preview_placeholder.visible = true
	_detail_title.text = str(record.get("name", "Dub pack"))
	_detail_meta.text = "by %s  •  Loading details..." % str(record.get("author", "Unknown creator"))
	_detail_description.text = "Loading description and download files..."
	_file_picker.clear()
	_file_picker.disabled = true
	_install_status.text = ""
	_install_button.disabled = true
	_open_button.disabled = false
	_catalog.fetch_detail(int(record.get("id", 0)))
	_load_preview(str(record.get("image_url", "")))


func _on_detail_loaded(detail: Dictionary) -> void:
	_loading_detail = false
	if int(detail.get("id", 0)) != int(_selected.get("id", 0)): return
	for key: Variant in _selected:
		if not detail.has(key) or str(detail.get(key, "")).is_empty(): detail[key] = _selected[key]
	_detail = detail
	_detail_title.text = str(detail.get("name", "Dub pack"))
	var parts: PackedStringArray = ["by %s" % str(detail.get("author", "Unknown creator"))]
	if not str(detail.get("subcategory", "")).is_empty(): parts.append(str(detail["subcategory"]))
	if not str(detail.get("version", "")).is_empty(): parts.append("version %s" % str(detail["version"]))
	if bool(detail.get("content_rated", false)): parts.append("CONTENT-RATED")
	_detail_meta.text = "  •  ".join(parts)
	_detail_meta.add_theme_color_override(
		"font_color", WARNING if bool(detail.get("content_rated", false)) else MUTED)
	var description: String = str(detail.get("description", ""))
	_detail_description.text = description if not description.is_empty() else "No description was provided."
	_file_picker.clear()
	for file_value: Variant in Array(detail.get("files", [])):
		if not file_value is Dictionary: continue
		var file: Dictionary = file_value
		_file_picker.add_item("%s  —  %s" % [file["name"], _format_bytes(int(file["size"]))])
		_file_picker.set_item_metadata(_file_picker.item_count - 1, file)
	_file_picker.disabled = _file_picker.item_count == 0
	if _file_picker.item_count > 0:
		var first_zip: int = 0
		for i: int in _file_picker.item_count:
			var candidate: Dictionary = _file_picker.get_item_metadata(i)
			if str(candidate.get("name", "")).get_extension().to_lower() == "zip":
				first_zip = i
				break
		_file_picker.select(first_zip)
	_refresh_install_action()


func _selected_file() -> Dictionary:
	if _file_picker.item_count == 0 or _file_picker.selected < 0: return {}
	var value: Variant = _file_picker.get_item_metadata(_file_picker.selected)
	return value if value is Dictionary else {}


func _refresh_install_action() -> void:
	var installed: String = INSTALLER_SCRIPT.installed_path(int(_detail.get("id", 0)))
	if not installed.is_empty():
		_install_button.text = "Installed"
		_install_button.disabled = true
		_install_status.text = "Installed in %s" % installed
		_install_status.add_theme_color_override("font_color", SUCCESS)
		return
	var file: Dictionary = _selected_file()
	if file.is_empty():
		_install_button.text = "Install pack"
		_install_button.disabled = true
		_install_status.text = "This submission has no downloadable files."
		return
	var problem: String = INSTALLER_SCRIPT.installability_problem(file)
	_install_button.text = "Install pack"
	_install_button.disabled = not problem.is_empty() or Net.is_online()
	if Net.is_online():
		_install_status.text = "Leave the online lobby before installing packs so its pack list stays consistent."
		_install_status.add_theme_color_override("font_color", WARNING)
	elif not problem.is_empty():
		_install_status.text = problem
		_install_status.add_theme_color_override("font_color", DANGER)
	else:
		_install_status.text = "Ready to download, verify and install into packs_voice."
		_install_status.add_theme_color_override("font_color", MUTED)


func _on_install_pressed() -> void:
	var file: Dictionary = _selected_file()
	if file.is_empty() or _detail.is_empty() or Net.is_online(): return
	_install_button.disabled = true
	_file_picker.disabled = true
	_install_progress.visible = true
	_install_progress.min_value = 0
	_install_progress.max_value = maxi(1, int(file.get("size", 0)))
	_install_progress.value = 0
	_installer.install(_detail, file)


func _on_install_progress(received: int, total: int, status: String) -> void:
	_install_progress.visible = true
	_install_progress.max_value = maxi(1, total)
	_install_progress.value = clampi(received, 0, maxi(1, total))
	_install_status.text = status
	_install_status.add_theme_color_override("font_color", MUTED)


func _on_install_finished(result: Dictionary) -> void:
	_install_progress.visible = false
	_file_picker.disabled = false
	_install_button.text = "Installed"
	_install_button.disabled = true
	var text: String = "Already installed" if bool(result.get("already_installed", false)) else "Installed"
	_install_status.text = "%s in %s" % [text, str(result.get("path", "packs_voice"))]
	if result.has("warning"): _install_status.text += "\n" + str(result["warning"])
	_install_status.add_theme_color_override("font_color", SUCCESS)


func _on_install_failed(message: String) -> void:
	_install_progress.visible = false
	_file_picker.disabled = false
	_install_status.text = message
	_install_status.add_theme_color_override("font_color", DANGER)
	var file: Dictionary = _selected_file()
	_install_button.text = "Retry install"
	_install_button.disabled = (file.is_empty() or Net.is_online()
		or not INSTALLER_SCRIPT.installability_problem(file).is_empty())


func _on_request_failed(message: String) -> void:
	_set_list_busy(false)
	if _loading_detail:
		_loading_detail = false
		_detail_description.text = message
		_install_status.text = "You can still open the submission on GameBanana."
		_install_status.add_theme_color_override("font_color", DANGER)
	else:
		_list_status.text = message


func _load_preview(url: String) -> void:
	_image_http.cancel_request()
	_preview_placeholder.visible = true
	if not url.begins_with("https://images.gamebanana.com/"):
		_preview_placeholder.text = "NO PREVIEW PROVIDED"
		return
	_preview_placeholder.text = "LOADING PREVIEW..."
	var error: Error = _image_http.request(
		url, ["User-Agent: TCV-Multiplayer/%s" % str(Net.MOD_VERSION)])
	if error != OK: _preview_placeholder.text = "PREVIEW UNAVAILABLE"


func _on_image_loaded(
	result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_preview_placeholder.text = "PREVIEW UNAVAILABLE"
		return
	var image: = Image.new()
	var error: Error = image.load_webp_from_buffer(body)
	if error != OK: error = image.load_jpg_from_buffer(body)
	if error != OK: error = image.load_png_from_buffer(body)
	if error == OK:
		_preview.texture = ImageTexture.create_from_image(image)
		_preview_placeholder.visible = false
	else:
		_preview_placeholder.text = "PREVIEW UNAVAILABLE"


static func _button(text: String, primary: bool) -> Button:
	var button: = Button.new()
	button.text = text
	button.custom_minimum_size.y = 38
	button.add_theme_font_size_override("font_size", 14)
	button.add_theme_color_override("font_color", Color("071019") if primary else TEXT)
	button.add_theme_color_override("font_hover_color", Color("071019") if primary else TEXT)
	button.add_theme_stylebox_override(
		"normal", _box(ACCENT if primary else SURFACE_2, 7, ACCENT if primary else BORDER, 1))
	button.add_theme_stylebox_override(
		"hover", _box(ACCENT.lightened(0.15) if primary else Color("26324b"), 7, ACCENT, 1))
	button.add_theme_stylebox_override(
		"pressed", _box(ACCENT.darkened(0.1) if primary else Color("1d2941"), 7, ACCENT, 2))
	return button


static func _box(color: Color, radius: int, border: Color, width: int) -> StyleBoxFlat:
	var box: = StyleBoxFlat.new()
	box.bg_color = color
	box.corner_radius_top_left = radius
	box.corner_radius_top_right = radius
	box.corner_radius_bottom_left = radius
	box.corner_radius_bottom_right = radius
	box.border_width_left = width
	box.border_width_right = width
	box.border_width_top = width
	box.border_width_bottom = width
	box.border_color = border
	box.content_margin_left = 12
	box.content_margin_right = 12
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	return box


static func _format_bytes(bytes: int) -> String:
	if bytes >= 1024 * 1024 * 1024: return "%.2f GB" % (float(bytes) / 1073741824.0)
	if bytes >= 1024 * 1024: return "%.1f MB" % (float(bytes) / 1048576.0)
	if bytes >= 1024: return "%.1f KB" % (float(bytes) / 1024.0)
	return "%d bytes" % bytes
