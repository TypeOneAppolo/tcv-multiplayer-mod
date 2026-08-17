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
var _downloads: Node
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
var _uninstall_button: Button
var _open_button: Button
var _downloads_button: Button
var _downloads_modal: Control
var _downloads_list: VBoxContainer
var _download_summary: Label
var _uninstall_dialog: ConfirmationDialog


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
	_downloads = Net.community_pack_downloads
	_downloads.changed.connect(_on_downloads_changed)
	_image_http = HTTPRequest.new()
	_image_http.use_threads = true
	_image_http.timeout = 12.0
	_image_http.body_size_limit = 12 * 1024 * 1024
	_image_http.request_completed.connect(_on_image_loaded)
	add_child(_image_http)
	_on_downloads_changed()
	_load_page()


func _fit_to_viewport() -> void:
	position = Vector2.ZERO
	size = get_viewport_rect().size


func _exit_tree() -> void:
	if is_instance_valid(_catalog): _catalog.cancel()
	if is_instance_valid(_image_http): _image_http.cancel_request()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"): return
	get_viewport().set_input_as_handled()
	if is_instance_valid(_downloads_modal) and _downloads_modal.visible:
		_downloads_modal.visible = false
	else:
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
	_downloads_button = _button("Downloads", false)
	_downloads_button.pressed.connect(_show_downloads)
	header.add_child(_downloads_button)
	var close: Button = _button("Close", false)
	close.tooltip_text = "Downloads keep running after this screen closes."
	close.pressed.connect(func() -> void: closed.emit())
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
	_uninstall_button = _button("Uninstall", false)
	_uninstall_button.visible = false
	_uninstall_button.pressed.connect(_on_uninstall_pressed)
	detail_buttons.add_child(_uninstall_button)
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

	_build_downloads_modal()


func _build_downloads_modal() -> void:
	_downloads_modal = Control.new()
	_downloads_modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_downloads_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	_downloads_modal.visible = false
	add_child(_downloads_modal)
	var backdrop: = ColorRect.new()
	backdrop.color = Color(0.01, 0.015, 0.03, 0.88)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_downloads_modal.add_child(backdrop)
	var center: = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_downloads_modal.add_child(center)
	var panel: = PanelContainer.new()
	panel.custom_minimum_size = Vector2(720, 430)
	panel.add_theme_stylebox_override("panel", _box(SURFACE, 12, BORDER, 1))
	center.add_child(panel)
	var margin: = MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	panel.add_child(margin)
	var column: = VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	var header: = HBoxContainer.new()
	column.add_child(header)
	var title: = Label.new()
	title.text = "DOWNLOAD QUEUE"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", TEXT)
	header.add_child(title)
	var close: Button = _button("Close", false)
	close.pressed.connect(func() -> void: _downloads_modal.visible = false)
	header.add_child(close)
	_download_summary = Label.new()
	_download_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_download_summary.add_theme_color_override("font_color", MUTED)
	column.add_child(_download_summary)
	var scroll: = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	_downloads_list = VBoxContainer.new()
	_downloads_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_downloads_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_downloads_list)
	var note: = Label.new()
	note.text = ("Downloads continue while this screen is closed and during offline play. "
		+ "New queued downloads wait while you are in online multiplayer.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", MUTED)
	column.add_child(note)

	_uninstall_dialog = ConfirmationDialog.new()
	_uninstall_dialog.title = "Uninstall community pack?"
	_uninstall_dialog.confirmed.connect(_confirm_uninstall)
	add_child(_uninstall_dialog)


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
	if _catalog.is_busy(): return
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
	if not is_instance_valid(_downloads): return
	var mod_id: int = int(_detail.get("id", 0))
	var installed: String = INSTALLER_SCRIPT.installed_path(mod_id)
	_uninstall_button.visible = not installed.is_empty()
	_uninstall_button.disabled = Net.is_online() or _mod_has_active_job(mod_id)
	if not installed.is_empty():
		_install_button.text = "Installed"
		_install_button.disabled = true
		_install_progress.visible = false
		_install_status.text = "Installed in %s" % installed
		if _mod_has_active_job(mod_id):
			_install_status.text += "\nA download for this submission is still active."
		_install_status.add_theme_color_override("font_color", SUCCESS)
		return
	var file: Dictionary = _selected_file()
	if file.is_empty():
		_install_button.text = "Install pack"
		_install_button.disabled = true
		_install_progress.visible = false
		_install_status.text = "This submission has no downloadable files."
		return
	var job: Dictionary = _downloads.job_for(mod_id, int(file.get("id", 0)))
	var state: String = str(job.get("state", ""))
	if state in ["queued", "downloading", "verifying", "installing"]:
		_install_button.text = "View downloads"
		_install_button.disabled = false
		_install_progress.visible = true
		_install_progress.max_value = maxi(1, int(job.get("total", file.get("size", 0))))
		_install_progress.value = clampi(
			int(job.get("received", 0)), 0, int(_install_progress.max_value))
		var status: String = str(job.get("status", "Queued"))
		if state == "queued" and Net.is_online():
			status = "Queued — waiting until you leave online multiplayer."
		_install_status.text = status
		_install_status.add_theme_color_override("font_color", MUTED)
		return
	if state in ["failed", "canceled"]:
		_install_progress.visible = false
		_install_button.text = "Retry download"
		_install_button.disabled = false
		_install_status.text = str(job.get(
			"error", "Canceled" if state == "canceled" else "Download failed"))
		if _install_status.text.is_empty(): _install_status.text = "Canceled"
		_install_status.add_theme_color_override("font_color", DANGER if state == "failed" else MUTED)
		return
	var problem: String = INSTALLER_SCRIPT.installability_problem(file)
	_install_progress.visible = false
	_install_button.text = "Add to download queue"
	_install_button.disabled = not problem.is_empty()
	if Net.is_online():
		_install_status.text = "This will wait in the queue until you leave online multiplayer."
		_install_status.add_theme_color_override("font_color", WARNING)
	elif not problem.is_empty():
		_install_status.text = problem
		_install_status.add_theme_color_override("font_color", DANGER)
	else:
		_install_status.text = "Ready to queue. Downloads continue during offline play."
		_install_status.add_theme_color_override("font_color", MUTED)


func _on_install_pressed() -> void:
	var file: Dictionary = _selected_file()
	if file.is_empty() or _detail.is_empty(): return
	var existing: Dictionary = _downloads.job_for(
		int(_detail.get("id", 0)), int(file.get("id", 0)))
	if str(existing.get("state", "")) in ["queued", "downloading", "verifying", "installing"]:
		_show_downloads()
		return
	_downloads.enqueue(_detail, file)
	_refresh_install_action()


func _on_downloads_changed() -> void:
	if not is_instance_valid(_downloads_button): return
	var active: int = _downloads.active_count()
	_downloads_button.text = "Downloads (%d)" % active if active > 0 else "Downloads"
	if is_instance_valid(_downloads_modal) and _downloads_modal.visible: _render_downloads()
	if not _update_selected_active_download(): _refresh_install_action()


func _update_selected_active_download() -> bool:
	var file: Dictionary = _selected_file()
	if file.is_empty() or _detail.is_empty(): return false
	var job: Dictionary = _downloads.job_for(
		int(_detail.get("id", 0)), int(file.get("id", 0)))
	var state: String = str(job.get("state", ""))
	if state not in ["queued", "downloading", "verifying", "installing"]: return false
	_install_button.text = "View downloads"
	_install_button.disabled = false
	_install_progress.visible = true
	_install_progress.max_value = maxi(1, int(job.get("total", file.get("size", 0))))
	_install_progress.value = clampi(int(job.get("received", 0)), 0, int(_install_progress.max_value))
	_install_status.text = str(job.get("status", "Queued"))
	if state == "queued" and Net.is_online():
		_install_status.text = "Queued — waiting until you leave online multiplayer."
	_install_status.add_theme_color_override("font_color", MUTED)
	return true


func _show_downloads() -> void:
	_render_downloads()
	_downloads_modal.visible = true


func _render_downloads() -> void:
	if not is_instance_valid(_downloads_list) or not is_instance_valid(_downloads): return
	for child: Node in _downloads_list.get_children():
		_downloads_list.remove_child(child)
		child.queue_free()
	var jobs: Array[Dictionary] = _downloads.get_jobs()
	var active: int = _downloads.active_count()
	_download_summary.text = (
		"%d active or queued. Downloads run one at a time to avoid saturating the connection." % active)
	if jobs.is_empty():
		var empty: = Label.new()
		empty.text = "No downloads in this session."
		empty.add_theme_color_override("font_color", MUTED)
		_downloads_list.add_child(empty)
		return
	for job: Dictionary in jobs:
		var card: = PanelContainer.new()
		card.add_theme_stylebox_override("panel", _box(SURFACE_2, 8, BORDER, 1))
		_downloads_list.add_child(card)
		var row: = HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		card.add_child(row)
		var info: = VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info)
		var mod: Dictionary = job.get("mod", {})
		var file: Dictionary = job.get("file", {})
		var title: = Label.new()
		title.text = "%s  —  %s" % [str(mod.get("name", "Dub pack")), str(file.get("name", "ZIP"))]
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		title.add_theme_color_override("font_color", TEXT)
		info.add_child(title)
		var state: String = str(job.get("state", "queued"))
		var status: = Label.new()
		status.text = str(job.get("status", state.capitalize()))
		if state == "queued" and Net.is_online():
			status.text = "Queued — waiting until online multiplayer closes"
		if state == "failed" and not str(job.get("error", "")).is_empty():
			status.text += " — " + str(job["error"])
		status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		status.add_theme_color_override(
			"font_color", DANGER if state == "failed" else SUCCESS if state == "finished" else MUTED)
		info.add_child(status)
		if state in ["queued", "downloading", "verifying", "installing"]:
			var progress: = ProgressBar.new()
			progress.show_percentage = state != "queued"
			progress.max_value = maxi(1, int(job.get("total", 0)))
			progress.value = clampi(int(job.get("received", 0)), 0, int(progress.max_value))
			info.add_child(progress)
		var actions: = VBoxContainer.new()
		row.add_child(actions)
		var id: String = str(job.get("id", ""))
		if state in ["queued", "downloading"]:
			var cancel: Button = _button("Cancel", false)
			cancel.pressed.connect(_downloads.cancel.bind(id))
			actions.add_child(cancel)
		elif state in ["failed", "canceled"]:
			var retry: Button = _button("Retry", true)
			retry.pressed.connect(_downloads.retry.bind(id))
			actions.add_child(retry)
			var dismiss: Button = _button("Dismiss", false)
			dismiss.pressed.connect(_downloads.dismiss.bind(id))
			actions.add_child(dismiss)
		elif state == "finished":
			var dismiss: Button = _button("Dismiss", false)
			dismiss.pressed.connect(_downloads.dismiss.bind(id))
			actions.add_child(dismiss)


func _mod_has_active_job(mod_id: int) -> bool:
	if mod_id <= 0: return false
	for job: Dictionary in _downloads.get_jobs():
		var mod: Dictionary = job.get("mod", {})
		if (int(mod.get("id", 0)) == mod_id
			and str(job.get("state", "")) in ["queued", "downloading", "verifying", "installing"]):
			return true
	return false


func _on_uninstall_pressed() -> void:
	var mod_id: int = int(_detail.get("id", 0))
	if mod_id <= 0 or Net.is_online() or _mod_has_active_job(mod_id): return
	_uninstall_dialog.dialog_text = ("Remove '%s' and all files this installer placed in its pack folder?\n\n"
		+ "Manually installed packs are never removed by this button.") % str(_detail.get("name", "Dub pack"))
	_uninstall_dialog.popup_centered(Vector2i(560, 190))


func _confirm_uninstall() -> void:
	var mod_id: int = int(_detail.get("id", 0))
	if mod_id <= 0 or Net.is_online() or _mod_has_active_job(mod_id): return
	var result: Dictionary = INSTALLER_SCRIPT.uninstall(mod_id)
	if result.has("error"):
		_install_status.text = str(result["error"])
		_install_status.add_theme_color_override("font_color", DANGER)
		return
	_downloads.dismiss_for_mod(mod_id)
	Net.community_pack_library_changed()
	_refresh_install_action()
	_install_status.text = "Uninstalled %s." % str(_detail.get("name", "community pack"))
	_install_status.add_theme_color_override("font_color", SUCCESS)


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
