extends Control
## Deck preview and out-of-battle setup: every card of the main / extra deck (one tile per copy),
## building points against the cap, the items brought along, and equipment fixed to specific
## cards. Equipment is named by the card's place in the deck list (its external fixed id), so
## same-name copies are separate. Starting is only offered for a legal deck; the battle module
## (YgoBattleSession.start with rules) refuses illegal decks on its own as well.
## One piece of equipment per card for now (slots are not decided).

const BattleScreen := preload("res://addons/ygo_battle/battle_screen.gd") # race / attribute names

## equipment: [{player, source, index, code}]; opponent: "deck" or "enemy"
signal start_requested(deck: Dictionary, equipment: Array, opponent: String)
signal back_requested

var _title: Label
var _summary: Label
var _errors: Label
var _start: Button
var _start_enemy: Button
var _items_label: Label
var _sections := {} ## section -> FoldableContainer
var _deck := {}
var _content: YgoContent
var _images_dir := ""
var _supply := {} ## equipment code -> pieces left to assign
var _equipped := {} ## "main:3" -> equipment code
var _tiles := {} ## "main:3" -> the label under that card's tile
var _menu: PopupMenu
var _menu_key := ""


func _init() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 22)
	root.add_child(_title)
	_summary = Label.new()
	root.add_child(_summary)
	_errors = Label.new()
	_errors.add_theme_color_override("font_color", Color(1, 0.45, 0.45))
	_errors.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_errors)
	var buttons := HBoxContainer.new()
	root.add_child(buttons)
	_start = Button.new()
	_start.text = "開始戰鬥：對手 test_basic.ydk"
	_start.pressed.connect(func() -> void: start_requested.emit(_deck, _equipment_config(), "deck"))
	buttons.add_child(_start)
	_start_enemy = Button.new()
	_start_enemy.text = "開始戰鬥：對手 岩殼守衛（自動行動）"
	_start_enemy.pressed.connect(func() -> void: start_requested.emit(_deck, _equipment_config(), "enemy"))
	buttons.add_child(_start_enemy)
	var back := Button.new()
	back.text = "返回"
	back.pressed.connect(func() -> void: back_requested.emit())
	buttons.add_child(back)
	_items_label = Label.new()
	_items_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_items_label)
	var hint := Label.new()
	hint.text = "點一張主牌組或額外牌組的卡，可以裝上或拿下裝備（每張卡一件，同名卡分開計算）。"
	hint.add_theme_font_size_override("font_size", 12)
	root.add_child(hint)
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_menu)
	add_child(_menu)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	var sections := VBoxContainer.new()
	sections.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(sections)
	for section in ["main", "extra", "side"]:
		var fold := FoldableContainer.new()
		var flow := HFlowContainer.new()
		fold.add_child(flow)
		sections.add_child(fold)
		_sections[section] = fold


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## deck: as from YgoContent.load_ydk; points: YgoDeckPoints; cap: the player's building limit;
## items: [{code, count}] brought into battle; equipment: {code: pieces} that can be assigned.
func show_deck(title: String, deck: Dictionary, points: YgoDeckPoints, cap: int, content: YgoContent, images_dir: String,
		items := [], equipment := {}) -> void:
	_deck = deck
	_content = content
	_images_dir = images_dir
	_supply = equipment.duplicate()
	_equipped = {}
	_tiles = {}
	var names := []
	for it in items:
		names.append("%s ×%d" % [content.card_info(it.code).get("name", str(it.code)), it.count])
	_items_label.text = "道具（測試配給，戰鬥中在自己的主要階段使用）：" + ("、".join(names) if names else "無")
	var result := points.evaluate(deck, cap, content)
	_title.text = title
	_summary.text = "構築點數 %d / %d（計算主牌組＋額外牌組，備牌不計）　點數表 %s" % [result.total, cap, points.version]
	var messages := []
	for e: String in result.errors:
		if e.begins_with("unknown card code "):
			messages.append("資料庫找不到卡號 %s，不能開始戰鬥" % e.trim_prefix("unknown card code "))
		elif e.begins_with("deck uses "):
			messages.append("超過構築點數上限 %d 點，不能開始戰鬥" % (result.total - cap))
		else:
			messages.append(e)
	_errors.text = "\n".join(messages)
	_start.disabled = not result.ok
	_start_enemy.disabled = not result.ok
	var each := {}
	for line in result.lines:
		each[line.code] = line.each
	for section in _sections:
		var fold: FoldableContainer = _sections[section]
		var codes: Array = deck.get(section, [])
		var counted: bool = section in YgoDeckPoints.COUNTED_SECTIONS
		fold.title = "%s　%d 張%s" % [{"main": "主牌組", "extra": "額外牌組", "side": "備牌"}[section], codes.size(),
			"" if counted else "（不計點數）"]
		var flow: HFlowContainer = fold.get_child(0)
		for child in flow.get_children():
			child.queue_free()
		for i in codes.size():
			var key := "%s:%d" % [section, i] if section != "side" else ""
			flow.add_child(_tile(codes[i], each.get(codes[i], -1) if counted else -1, key))
	show()


## key: "main:3" for a card that can take equipment, "" otherwise.
func _tile(code: int, points: int, key: String) -> Control:
	var info := _content.card_info(code)
	var box := VBoxContainer.new()
	box.add_child(YgoCardArt.face(info, _images_dir))
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size = Vector2(YgoCardArt.SIZE.x, 0)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 11)
	label.set_meta("points", points)
	box.add_child(label)
	var name: String = info.get("name", "") if info.get("found", false) else "（資料庫找不到 %d）" % code
	box.tooltip_text = "%s\n%s" % [name, info.get("text", "")]
	if key != "":
		_tiles[key] = label
		box.mouse_filter = Control.MOUSE_FILTER_STOP
		box.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				_open_menu(key))
	_update_tile(key, label)
	return box


func _update_tile(key: String, label: Label) -> void:
	var points: int = label.get_meta("points")
	var text := ("%d 點" % points) if points > 0 else ""
	if _equipped.has(key):
		text += ("\n" if text != "" else "") + "裝：" + _content.card_info(_equipped[key]).get("name", "")
		label.add_theme_color_override("font_color", Color(0.55, 0.85, 1))
	else:
		label.remove_theme_color_override("font_color")
	label.text = text


func _open_menu(key: String) -> void:
	_menu_key = key
	_menu.clear()
	if _equipped.has(key):
		_menu.add_item("拿下 %s" % _content.card_info(_equipped[key]).get("name", ""), 0)
	var parts := key.split(":")
	var card: int = _deck[parts[0]][int(parts[1])]
	for code: int in _supply:
		var left: int = _supply[code]
		# The same check the battle module makes when the battle is created.
		var refused := _content.equip_refusal(code, card) != ""
		var text := "裝上 %s（剩 %d）" % [_content.card_info(code).get("name", str(code)), left]
		if refused:
			text += "　不符合：需要%s" % _requirement_text(code)
		_menu.add_item(text, code)
		_menu.set_item_disabled(_menu.item_count - 1, refused or left <= 0 or _equipped.get(key, 0) == code)
		_menu.set_item_tooltip(_menu.item_count - 1, _content.card_info(code).get("text", ""))
	_menu.position = Vector2i(get_global_mouse_position()) + get_window().position
	_menu.popup()


func _on_menu(id: int) -> void:
	if _equipped.has(_menu_key): # one piece per card: take the old one off first
		_supply[_equipped[_menu_key]] += 1
		_equipped.erase(_menu_key)
	if id != 0:
		_equipped[_menu_key] = id
		_supply[id] -= 1
	_update_tile(_menu_key, _tiles[_menu_key])


func _requirement_text(equip: int) -> String:
	var req := _content.equip_requires(equip)
	var parts := []
	if req.has("type"):
		parts.append({YgoDuel.TYPE_MONSTER: "怪獸", YgoDuel.TYPE_SPELL: "魔法卡", YgoDuel.TYPE_TRAP: "陷阱卡"}.get(req.type, "特定種類的卡"))
	if req.has("min_level"):
		parts.append("%d 星以上（超量的階級算等級，連結不行）" % req.min_level)
	if req.has("max_level"):
		parts.append("%d 星以下" % req.max_level)
	for field in [["race", BattleScreen.RACES, "族"], ["attribute", BattleScreen.ATTRIBUTES, "屬性"]]:
		if req.has(field[0]):
			var names := []
			for i in field[1].size():
				if int(req[field[0]]) & (1 << i):
					names.append(field[1][i] + field[2])
			parts.append("或".join(names))
	return "、".join(parts)


## The assignment as battle config: equipment named by deck position (external fixed id).
func _equipment_config() -> Array:
	var out := []
	for key: String in _equipped:
		var parts := key.split(":")
		out.append({"player": 0, "source": parts[0], "index": int(parts[1]), "code": _equipped[key]})
	return out
