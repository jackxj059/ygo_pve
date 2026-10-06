extends Control
## Read-only deck preview: cards per section (main / extra / side), copies, building points and
## the deck total against the cap. Starting is only offered for a legal deck; the battle module
## (YgoBattleSession.start with rules) refuses illegal decks on its own as well.

signal start_requested(deck: Dictionary)
signal back_requested

var _title: Label
var _summary: Label
var _errors: Label
var _start: Button
var _sections := {} ## section -> FoldableContainer
var _deck := {}


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
	_start.text = "用這副牌開始戰鬥"
	_start.pressed.connect(func() -> void: start_requested.emit(_deck))
	buttons.add_child(_start)
	var back := Button.new()
	back.text = "返回"
	back.pressed.connect(func() -> void: back_requested.emit())
	buttons.add_child(back)
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


## deck: as from YgoContent.load_ydk; points: YgoDeckPoints; cap: the player's building limit.
func show_deck(title: String, deck: Dictionary, points: YgoDeckPoints, cap: int, content: YgoContent, images_dir: String) -> void:
	_deck = deck
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
		var copies := {}
		var order := []
		for code in codes:
			if not copies.has(code):
				order.append(code)
			copies[code] = copies.get(code, 0) + 1
		for code in order:
			flow.add_child(_tile(content.card_info(code), copies[code], each.get(code, -1) if counted else -1, images_dir))
	show()


func _tile(info: Dictionary, copies: int, points: int, images_dir: String) -> Control:
	var box := VBoxContainer.new()
	box.add_child(YgoCardArt.face(info, images_dir))
	var label := Label.new()
	label.text = "×%d%s" % [copies, ("\n每張 %d 點" % points) if points > 0 else ""]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size = Vector2(YgoCardArt.SIZE.x, 0)
	label.add_theme_font_size_override("font_size", 11)
	box.add_child(label)
	var name: String = info.get("name", "") if info.get("found", false) else "（資料庫找不到 %d）" % info.get("code", 0)
	box.tooltip_text = "%s\n%s" % [name, info.get("text", "")]
	return box
