extends Control
# shown over dub mode before an online dub starts. everyone ticks the characters
# they want to dub, the host resolves the picks and starts.

signal begin_requested

const INSET: int = 56

# set by dub_mode before this is added to the tree.
var characters: PackedStringArray = []

var _boxes: Dictionary = {}
var roster_rows: VBoxContainer
var status_label: Label
var warning_label: Label
var begin_button: Button
var auto_button: Button
var backdrop: ColorRect
var column: VBoxContainer


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	Net.dub_roles_changed.connect(_refresh, CONNECT_DEFERRED)
	Net.player_list_changed.connect(_refresh, CONNECT_DEFERRED)
	get_viewport().size_changed.connect(_fit)
	_fit()
	_fit.call_deferred()
	_refresh()


# dub mode is a Control, but sizing off the viewport as well costs nothing and
# keeps this from collapsing to the top left the way the lobby did.
func _fit() -> void:
	var view: Vector2 = get_viewport_rect().size
	position = Vector2.ZERO
	size = view
	if is_instance_valid(backdrop): backdrop.size = view


func _build_ui() -> void:
	backdrop = ColorRect.new()
	backdrop.color = Color(0.05, 0.05, 0.09, 0.96)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var margin: = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, INSET)
	add_child(margin)

	column = VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var title: = Label.new()
	title.text = "WHO ARE YOU DUBBING?"
	title.add_theme_font_size_override("font_size", 32)
	column.add_child(title)

	var blurb: = Label.new()
	blurb.text = "Tick the characters you want. Every clip goes to whoever took that character; anything left over is shared out evenly."
	blurb.add_theme_font_size_override("font_size", 14)
	blurb.add_theme_color_override("font_color", Color(0.72, 0.72, 0.8))
	column.add_child(blurb)

	var picks: = HFlowContainer.new()
	picks.add_theme_constant_override("h_separation", 14)
	column.add_child(picks)

	if characters.is_empty():
		var none: = Label.new()
		none.text = "This pack does not tag its clips with characters, so the clips will just be split evenly."
		none.add_theme_color_override("font_color", Color("ffcc44"))
		picks.add_child(none)

	for character: String in characters:
		var box: = CheckBox.new()
		box.text = character
		box.toggled.connect(_on_box_toggled.unbind(1))
		picks.add_child(box)
		_boxes[character] = box

	var roster_title: = Label.new()
	roster_title.text = "Casting"
	roster_title.add_theme_font_size_override("font_size", 22)
	column.add_child(roster_title)

	roster_rows = VBoxContainer.new()
	column.add_child(roster_rows)

	warning_label = Label.new()
	warning_label.add_theme_color_override("font_color", Color("ffcc44"))
	warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warning_label.custom_minimum_size.x = 720
	column.add_child(warning_label)

	var buttons: = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	column.add_child(buttons)

	auto_button = Button.new()
	auto_button.text = "Split the cast for us"
	auto_button.pressed.connect(_on_auto_split)
	buttons.add_child(auto_button)

	begin_button = Button.new()
	begin_button.text = "Begin dub"
	begin_button.pressed.connect(func() -> void: begin_requested.emit())
	buttons.add_child(begin_button)

	status_label = Label.new()
	column.add_child(status_label)


func _on_box_toggled() -> void:
	var mine: PackedStringArray = []
	for character: String in characters:
		if _boxes[character].button_pressed: mine.append(character)
	Net.set_my_dub_characters(mine)


func _on_auto_split() -> void:
	if not Net.is_host(): return
	var slots: int = maxi(1, Net.slot_count())
	var per_slot: Array = []
	for i: int in slots: per_slot.append(PackedStringArray())
	for i: int in characters.size(): per_slot[i % slots].append(characters[i])
	for slot: int in slots: Net.set_dub_characters_for_slot(slot, per_slot[slot])


# the host can overwrite our picks with the auto split, so the boxes follow the
# roster rather than whatever was last clicked.
func _sync_boxes_from_roles() -> void:
	var mine: PackedStringArray = Net.characters_for_slot(maxi(0, Net.my_slot()))
	for character: String in characters:
		var box: CheckBox = _boxes[character]
		var want: bool = mine.has(character)
		if box.button_pressed == want: continue
		box.set_block_signals(true)
		box.button_pressed = want
		box.set_block_signals(false)


func _refresh() -> void:
	if not is_node_ready() or not is_inside_tree(): return
	_sync_boxes_from_roles()

	for child: Node in roster_rows.get_children():
		roster_rows.remove_child(child)
		child.queue_free()

	for slot: int in Net.slot_count():
		var row: = Label.new()
		var picked: PackedStringArray = Net.characters_for_slot(slot)
		var who: String = Net.player_name_for_slot(slot).substr(0, 24)
		if Net.peer_for_slot(slot) == Net.my_id(): who += " (you)"
		var what: String = ", ".join(picked) if not picked.is_empty() else "nobody yet"
		row.text = "%d.  %s  --  %s" % [slot + 1, who, what]
		row.clip_text = true
		roster_rows.add_child(row)

	var notes: PackedStringArray = []
	var contested: PackedStringArray = []
	for character: String in characters:
		var takers: int = 0
		for slot: int in Net.slot_count():
			if Net.characters_for_slot(slot).has(character): takers += 1
		if takers > 1: contested.append(character)
	if not contested.is_empty():
		notes.append("%s picked by more than one of you -- the earlier player in the list gets those clips." % ", ".join(contested))
	var idle: PackedStringArray = Net.slots_without_a_character()
	if not idle.is_empty() and not characters.is_empty():
		notes.append("%s picked nobody, so they only get clips no one claimed." % ", ".join(idle))
	warning_label.text = "\n".join(notes)

	auto_button.visible = Net.is_host() and not characters.is_empty()
	begin_button.visible = Net.is_host()
	if Net.is_host(): status_label.text = "Start when everyone has picked."
	else: status_label.text = "Waiting for the host to start."
