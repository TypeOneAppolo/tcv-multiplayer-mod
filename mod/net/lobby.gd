extends Control

const ROW_HEIGHT: int = 34
# ENet drops a peer it cannot reach after 30s of its own accord. say something
# useful before that happens rather than letting the lobby sit there empty.
const JOIN_TIMEOUT: float = 12.0
const KOFI_URL: String = "https://ko-fi.com/appolodev"
const GAMEBANANA_URL: String = "https://gamebanana.com/mods/702231"
const DISCORD_URL: String = "https://discord.gg/HYhh6V4NZk"
const SUPPORT_INSET: Vector2 = Vector2(48, 32)
# Discord's own. the button is the one thing on this screen someone reaches for
# when the rest of it isn't working, so let it stand out from the two links next
# to it that are only ever asking them for something.
const DISCORD_COLOR: Color = Color("5865f2")

var name_field: LineEdit
var address_field: LineEdit
var port_field: LineEdit
var host_button: Button
var join_button: Button
var start_button: Button
var dub_button: Button
var ready_button: CheckBox
var leave_button: Button
var status_label: Label
var warning_label: Label
var player_rows: VBoxContainer
var support_box: VBoxContainer


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	# deferred: these fire from inside the multiplayer poll, and rebuilding the
	# player list there takes the engine down with no error to show for it.
	Net.player_list_changed.connect(_refresh, CONNECT_DEFERRED)
	Net.connection_failed.connect(_on_error, CONNECT_DEFERRED)
	Net.connected_to_lobby.connect(_on_connected, CONNECT_DEFERRED)
	# a joiner turned away is the host's problem to hear about: the person it
	# happened to is looking at their own screen, not this one.
	Net.host_notice.connect(_on_host_notice, CONNECT_DEFERRED)
	Net.server_disconnected.connect(func() -> void: _on_error(
		"Lost the connection to the host. Either they closed the lobby, or the link between you dropped."))
	_refresh()
	if Net.is_online():
		if Net.is_host(): _set_status("Lobby still open. Choose the next pack when everyone is ready.")
		else: _set_status("Connected. Waiting for the host to pick the next pack.")


func _build_ui() -> void:
	var backdrop: = ColorRect.new()
	backdrop.color = Color(0.05, 0.05, 0.09, 0.94)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var margin: = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 64)
	add_child(margin)

	var column: = VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var title: = Label.new()
	title.text = "ONLINE MATCH"
	title.add_theme_font_size_override("font_size", 32)
	column.add_child(title)

	# "check you are on the same version" is no use if the version is nowhere.
	var build: = Label.new()
	build.text = "Multiplayer mod %s, protocol %d. Everyone has to be on the same protocol number." % [
		Net.MOD_VERSION, Net.PROTOCOL_VERSION]
	build.add_theme_font_size_override("font_size", 14)
	build.add_theme_color_override("font_color", Color(0.65, 0.65, 0.75))
	column.add_child(build)

	var default_name: String = OS.get_environment("USERNAME")
	if default_name.is_empty(): default_name = "Player"
	name_field = _labeled_field(column, "Your name", default_name)
	address_field = _labeled_field(column, "Host address", "127.0.0.1")
	port_field = _labeled_field(column, "Port", str(Net.PORT))

	var buttons: = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	column.add_child(buttons)

	host_button = Button.new()
	host_button.text = "Host"
	host_button.pressed.connect(_on_host)
	buttons.add_child(host_button)

	join_button = Button.new()
	join_button.text = "Join"
	join_button.pressed.connect(_on_join)
	buttons.add_child(join_button)

	ready_button = CheckBox.new()
	ready_button.text = "Ready"
	ready_button.toggled.connect(func(v: bool) -> void: Net.set_ready(v))
	buttons.add_child(ready_button)

	start_button = Button.new()
	start_button.text = "Start (choose clips)"
	start_button.pressed.connect(_on_start)
	buttons.add_child(start_button)

	dub_button = Button.new()
	dub_button.text = "Start (dub mode)"
	dub_button.pressed.connect(_on_start_dub)
	buttons.add_child(dub_button)

	leave_button = Button.new()
	leave_button.text = "Back"
	leave_button.pressed.connect(_on_leave)
	buttons.add_child(leave_button)

	status_label = Label.new()
	status_label.text = "Not connected."
	column.add_child(status_label)

	warning_label = Label.new()
	warning_label.add_theme_color_override("font_color", Color("ffcc44"))
	warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(warning_label)

	var players_title: = Label.new()
	players_title.text = "Contestants"
	players_title.add_theme_font_size_override("font_size", 22)
	column.add_child(players_title)

	player_rows = VBoxContainer.new()
	player_rows.custom_minimum_size.y = ROW_HEIGHT * Net.MAX_PLAYERS
	column.add_child(player_rows)

	_build_support_footer()


# placed by hand off the viewport, not by anchors. world.gd hangs the lobby off
# PrimaryCapsule, a plain Node, so the anchor preset never resolves and this
# Control stays 0x0 -- anchor anything to the bottom and it lands top left.
func _build_support_footer() -> void:
	support_box = VBoxContainer.new()
	support_box.add_theme_constant_override("separation", 6)
	add_child(support_box)

	var pitch: = Label.new()
	pitch.text = ("Stuck, or short of people to play with? The Discord is where to ask."
		+ "\nThis mod is free. If it got your group playing, please support me on Ko-fi, "
		+ "or upvote it on GameBanana.")
	pitch.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pitch.add_theme_font_size_override("font_size", 14)
	pitch.add_theme_color_override("font_color", Color(0.72, 0.72, 0.8))
	support_box.add_child(pitch)

	var links: = HBoxContainer.new()
	links.alignment = BoxContainer.ALIGNMENT_END
	links.add_theme_constant_override("separation", 8)
	support_box.add_child(links)

	var discord: Button = _link_button("Join the Discord", DISCORD_URL)
	discord.add_theme_color_override("font_color", DISCORD_COLOR)
	discord.add_theme_color_override("font_hover_color", DISCORD_COLOR.lightened(0.3))
	links.add_child(discord)
	var community: = Button.new()
	community.text = "Browse community packs"
	community.tooltip_text = "Open the in-game GameBanana Dub Mode browser."
	community.pressed.connect(Net.open_community_packs)
	links.add_child(community)
	links.add_child(_link_button("Support me on Ko-fi", KOFI_URL))
	links.add_child(_link_button("Upvote on GameBanana", GAMEBANANA_URL))

	_place_support_box()
	support_box.minimum_size_changed.connect(_place_support_box)
	get_viewport().size_changed.connect(_place_support_box)
	_place_support_box.call_deferred()


func _place_support_box() -> void:
	if not is_instance_valid(support_box): return
	support_box.size = support_box.get_combined_minimum_size()
	support_box.position = get_viewport_rect().size - support_box.size - SUPPORT_INSET


func _link_button(text: String, url: String) -> Button:
	var button: = Button.new()
	button.text = text
	button.tooltip_text = url
	button.pressed.connect(func() -> void: OS.shell_open(url))
	return button


func _labeled_field(parent: Control, label_text: String, default_value: String) -> LineEdit:
	var row: = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var label: = Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 140
	row.add_child(label)

	var field: = LineEdit.new()
	field.text = default_value
	field.custom_minimum_size.x = 320
	row.add_child(field)
	return field




func _on_host() -> void:
	var err: Error = Net.host_game(name_field.text, Profile.contestant, int(port_field.text))
	if err == OK:
		# spell them out. "share your IP" is where most failed joins start.
		_set_status("Hosting on port %s. Your friends type one of these as the host address:\n%s" % [
			port_field.text, Net.addresses_to_give_out()])


func _on_join() -> void:
	var err: Error = Net.join_game(address_field.text, name_field.text, Profile.contestant, int(port_field.text))
	if err == OK:
		_set_status("Connecting to %s..." % address_field.text)
		_refresh()
		_watch_the_join()


func _on_connected() -> void:
	_set_status("Connected. Waiting for the host to send the lobby.")
	_refresh()


# the status line rather than the warning line: _refresh() rewrites the warning
# every time the roster moves, and a joiner being turned away moves it.
func _on_host_notice(text: String) -> void:
	_set_status(text)


# nothing has answered on the socket at all. Net handles the other case itself
# now -- reached them, they never answered the handshake -- and says so, because
# that one is a build difference rather than anything to do with the network.
# This used to cover both and blamed the network for both, which had people
# reopening ports that were fine.
func _watch_the_join() -> void:
	await get_tree().create_timer(JOIN_TIMEOUT).timeout
	if not is_inside_tree(): return
	if Net.is_host() or not Net.is_online() or Net.slot_count() > 0: return
	_set_status(("No answer from %s after %d seconds.\n"
		+ "Check they are hosting on port %s, and that the address you typed is the one "
		+ "their end shows. On Hamachi that is the IPv4 address next to their name.") % [
		address_field.text, int(JOIN_TIMEOUT), port_field.text])


func _on_leave() -> void:
	Net.leave()
	M.world.CreateMenu()


func _on_start() -> void:
	if not Net.is_host(): return
	if Net.slot_count() < 2:
		_set_status("Need at least two contestants to start.")
		return
	Net.apply_roster_to_metro()
	M.session_type = M.SESSION_TYPE.STANDARD
	M.world.CreateSameLobby([])


func _on_start_dub() -> void:
	if not Net.is_host(): return
	if Net.slot_count() < 2:
		_set_status("Need at least two players to split the clips.")
		return
	Net.apply_roster_to_metro()
	M.session_type = M.SESSION_TYPE.VIDEO_DUB
	M.world.return_to_dub_selection()


func _on_error(reason: String) -> void:
	_set_status(reason)
	_refresh()


func _set_status(text: String) -> void:
	if status_label: status_label.text = text




func _refresh() -> void:
	if not is_node_ready() or not is_inside_tree(): return
	Net.log_net("lobby refresh: %d player(s)" % Net.players.size())

	var online: bool = Net.is_online()
	host_button.disabled = online
	join_button.disabled = online
	name_field.editable = not online
	address_field.editable = not online
	port_field.editable = not online
	# only once the host has actually put us in the roster. before that the tick
	# goes nowhere and it just looks broken.
	var seated: bool = online and Net.my_slot() >= 0
	ready_button.disabled = not seated
	if seated:
		ready_button.set_pressed_no_signal(
			bool(Net.players.get(Net.my_id(), {}).get("ready", false)))
	start_button.visible = Net.is_host()
	start_button.disabled = Net.slot_count() < 2
	dub_button.visible = Net.is_host()
	dub_button.disabled = Net.slot_count() < 2

	for child: Node in player_rows.get_children():
		player_rows.remove_child(child)
		child.queue_free()

	for slot: int in Net.slot_count():
		var peer: int = Net.peer_for_slot(slot)
		var record: Dictionary = Net.players.get(peer, {})
		var row: = Label.new()
		var marks: PackedStringArray = []
		if peer == 1: marks.append("host")
		if peer == Net.my_id(): marks.append("you")
		if record.get("ready", false): marks.append("ready")
		var shown: String = str(record.get("name", "?")).substr(0, 28)
		row.text = "%d.  %s   [%s]" % [slot + 1, shown, ", ".join(marks)]
		row.clip_text = true
		player_rows.add_child(row)

	if online:
		var mismatched: PackedStringArray = Net.mismatched_players()
		if mismatched.is_empty(): warning_label.text = ""
		else:
			warning_label.text = ("Your voice packs are not identical: %s.\nThis is only a problem "
				+ "if the host picks clips from those packs. Start anyway if you like.") % "; ".join(mismatched)
