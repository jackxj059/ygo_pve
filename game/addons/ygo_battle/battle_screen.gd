extends Control
## Minimal battle screen for one YgoBattleSession. attach() shows a running session and
## drives it; detach() stops driving and hides the screen without touching the duel, so a
## host can leave and re-enter (needed for consecutive battles).
## Every prompt is answered here by clicking (hot-seat for both players) unless
## "auto-pass opponent" is ticked. Cards without an image are drawn as text.

signal leave_requested
signal finished(result: Dictionary)

const CARD_SIZE := YgoCardArt.SIZE
const POS_FACEDOWN := 0xA
const POS_DEFENSE := 0xC

const LOCATION_NAMES := {1: "牌組", 2: "手牌", 4: "怪獸區", 8: "魔陷區", 16: "墓地", 32: "除外", 64: "額外"}
const PHASE_NAMES := {1: "抽牌階段", 2: "準備階段", 4: "主要階段1", 8: "戰鬥階段", 16: "戰鬥步驟",
	32: "傷害步驟", 64: "傷害計算", 128: "戰鬥階段", 256: "主要階段2", 512: "結束階段"}
const PROMPT_NAMES := {
	"SELECT_IDLECMD": "主要階段", "SELECT_BATTLECMD": "戰鬥階段", "SELECT_EFFECTYN": "是否發動效果",
	"SELECT_YESNO": "是／否", "SELECT_OPTION": "選擇效果", "SELECT_CHAIN": "是否連鎖",
	"SELECT_CARD": "選擇卡片", "SELECT_TRIBUTE": "選擇解放", "SELECT_UNSELECT_CARD": "選擇卡片",
	"SELECT_SUM": "選擇卡片（合計）", "SELECT_COUNTER": "移除計數器", "SELECT_PLACE": "選擇區域",
	"SELECT_POSITION": "選擇表示形式", "SORT_CARD": "排列順序", "ANNOUNCE_RACE": "宣言種族",
	"ANNOUNCE_ATTRIB": "宣言屬性", "ANNOUNCE_NUMBER": "宣言數字", "ANNOUNCE_CARD": "宣言卡名",
	"ROCK_PAPER_SCISSORS": "猜拳",
}
const ACTION_NAMES := {
	"summon": "通常召喚", "spsummon": "特殊召喚", "repos": "變更表示形式", "mset": "覆蓋怪獸",
	"sset": "覆蓋魔陷", "activate": "發動", "battle": "進入戰鬥階段", "main2": "進入主要階段2",
	"shuffle": "洗切手牌", "attack": "攻擊", "pass": "不連鎖", "yes": "是", "no": "否",
	"card": "", "must": "（必選）", "select": "選擇", "unselect": "取消選擇", "finish": "完成",
	"cancel": "取消", "zone": "", "fu_atk": "表側攻擊", "fd_atk": "裡側攻擊", "fu_def": "表側守備",
	"fd_def": "裡側守備", "race": "", "attribute": "", "number": "", "option": "",
	"scissors": "剪刀", "rock": "石頭", "paper": "布",
}
const RACES := ["戰士", "魔法使", "天使", "惡魔", "不死", "機械", "水", "炎", "岩石", "鳥獸", "植物",
	"昆蟲", "雷", "龍", "獸", "獸戰士", "恐龍", "魚", "海龍", "爬蟲類", "念動力", "幻神獸", "創造神",
	"幻龍", "電子界", "幻想魔", "機械人", "魔導騎士", "高位龍", "超念動", "天界戰士", "銀河"]
const ATTRIBUTES := ["地", "水", "炎", "風", "光", "闇", "神"]

var session: YgoBattleSession
var resources := {}
var _prompt := {}
var _shown_prompt_id := -1
var _finished_sent := false
var _turn := 0
var _turn_player := 0
var _phase := ""
var _infos := {} ## code -> card info Dictionary

var _rows := {} ## "p<player>_<location>" -> HBoxContainer
var _info_labels := {} ## player -> Label
var _phase_label: Label
var _prompt_title: Label
var _prompt_box: VBoxContainer
var _detail: RichTextLabel
var _log: RichTextLabel
var _auto_pass: CheckBox


func _init() -> void:
	# Built here rather than in _ready() so attach() works right after instantiate().
	_build()
	set_process(false)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func attach(with_session: YgoBattleSession, with_resources: Dictionary) -> void:
	session = with_session
	resources = with_resources
	_shown_prompt_id = -1
	_prompt = {}
	_finished_sent = not session.is_running()
	_log.clear()
	for line in session.log_lines:
		_log.append_text(line + "\n")
	_refresh_board()
	show()
	set_process(true)


## Stops driving the duel and hides the screen. The session (and its duel) is untouched.
func detach() -> void:
	set_process(false)
	session = null
	_clear_prompt()
	hide()


func current_prompt_type() -> String:
	return _prompt.get("type", "")


func _process(_delta: float) -> void:
	if session == null:
		return
	if session.is_running():
		var p := session.prompt()
		if p.is_empty():
			var events := session.step()
			for e in events:
				_on_event(e)
			if not events.is_empty():
				_refresh_board()
			p = session.prompt()
		if not p.is_empty() and p.id != _shown_prompt_id:
			if not _auto_answer(p):
				_show_prompt(p)
	elif not _finished_sent:
		_finished_sent = true
		_refresh_board()
		_clear_prompt()
		var r := session.result
		if r.get("error", "") != "":
			_prompt_title.text = "對戰中止（錯誤）：%s" % r.error
		else:
			_prompt_title.text = "對戰結束：玩家 %d 獲勝（%s）" % [r.winner, _win_reason(r.reason)]
		finished.emit(r)


# ---------------------------------------------------------------- layout

func _build() -> void:
	var root := HBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var board := VBoxContainer.new()
	board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board.add_theme_constant_override("separation", 6)
	root.add_child(board)
	for player in [1, 0]:
		var rows := [2, 8, 4] if player == 1 else [4, 8, 2] # opponent mirrored
		if player == 0:
			_phase_label = Label.new()
			_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			board.add_child(_phase_label)
		var info := Label.new()
		_info_labels[player] = info
		if player == 1:
			board.add_child(info)
		for loc in rows:
			var row := HBoxContainer.new()
			var caption := Label.new()
			caption.text = "P%d %s" % [player, LOCATION_NAMES[loc]]
			caption.custom_minimum_size = Vector2(90, 0)
			row.add_child(caption)
			board.add_child(row)
			_rows["p%d_%d" % [player, loc]] = row
		if player == 0:
			board.add_child(info)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(470, 0)
	root.add_child(side)
	_prompt_title = Label.new()
	_prompt_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_prompt_title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 300)
	side.add_child(scroll)
	_prompt_box = VBoxContainer.new()
	_prompt_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_prompt_box)
	_detail = RichTextLabel.new()
	_detail.custom_minimum_size = Vector2(0, 150)
	side.add_child(_detail)
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	side.add_child(_log)
	var bottom := HBoxContainer.new()
	side.add_child(bottom)
	_auto_pass = CheckBox.new()
	_auto_pass.text = "對手自動略過"
	bottom.add_child(_auto_pass)
	var leave := Button.new()
	leave.text = "離開畫面"
	leave.pressed.connect(func() -> void: leave_requested.emit())
	bottom.add_child(leave)


func _refresh_board() -> void:
	if session == null or session.duel == null:
		return
	var duel := session.duel
	for key in _rows:
		var row: HBoxContainer = _rows[key]
		for i in range(row.get_child_count() - 1, 0, -1):
			var child := row.get_child(i)
			row.remove_child(child)
			child.queue_free()
		var player := int(String(key).substr(1, 1))
		var loc := int(String(key).split("_")[1])
		var cards := duel.cards(player, loc)
		if loc == YgoDuel.LOCATION_SZONE:
			cards = cards.slice(0, 6) # 5 spell/trap zones + field zone
		if loc == YgoDuel.LOCATION_HAND and player in session.script_players:
			cards = [] # an enemy side's hand is its skill pool, which the player does not see
		for c in cards:
			row.add_child(_card_view(c))
	for player in [0, 1]:
		var grave := duel.cards(player, YgoDuel.LOCATION_GRAVE)
		var top := ("，墓地最上面：%s" % _name(grave[-1].code)) if not grave.is_empty() else ""
		var ap: Dictionary = duel.ap(player)
		var ap_text := ("　AP %d/%d" % [ap.current, ap.max]) if ap.enabled else ""
		_info_labels[player].text = "P%d　LP %d%s　牌組 %d　額外 %d　墓地 %d　除外 %d%s" % [
			player, duel.lp(player), ap_text, duel.count(player, YgoDuel.LOCATION_DECK),
			duel.count(player, YgoDuel.LOCATION_EXTRA), grave.size(),
			duel.count(player, YgoDuel.LOCATION_REMOVED), top]
	_phase_label.text = "第 %d 回合（P%d）　%s" % [_turn, _turn_player, _phase]


func _card_view(c: Dictionary) -> Control:
	# A plain Control, not a Container: containers reset their children's rotation.
	var box := Control.new()
	box.custom_minimum_size = CARD_SIZE
	box.mouse_filter = Control.MOUSE_FILTER_PASS
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(bg)
	var code: int = c.code
	if code == 0:
		box.modulate = Color(1, 1, 1, 0.25)
		return box
	var face := YgoCardArt.face(_info(code), resources.get("images_dir", ""))
	box.add_child(face)
	# Position only means something on the field; hand cards are always "face-down" to the core.
	var on_field: bool = c.location == YgoDuel.LOCATION_MZONE or c.location == YgoDuel.LOCATION_SZONE
	var pos: int = c.position if on_field else 0
	if pos & POS_DEFENSE and c.location == YgoDuel.LOCATION_MZONE: # face-up spells/traps also carry the defense bit
		face.pivot_offset = CARD_SIZE / 2
		face.rotation_degrees = 90
		face.scale = Vector2(0.7, 0.7)
	if pos & POS_FACEDOWN:
		box.modulate = Color(0.55, 0.55, 0.75)
	box.tooltip_text = "%s%s" % [_name(code), "（裡側）" if pos & POS_FACEDOWN else ""]
	# Enemy units: HP bar text on the card (reported by the enemy rules script through the module).
	var hp: Dictionary = session.duel.hp(c.instance) if on_field else {}
	if not hp.is_empty():
		var hp_label := Label.new()
		hp_label.text = "HP %d/%d" % [hp.hp, hp.max]
		hp_label.add_theme_font_size_override("font_size", 11)
		hp_label.add_theme_color_override("font_color", Color(1, 0.35, 0.35))
		hp_label.add_theme_constant_override("outline_size", 4)
		hp_label.add_theme_color_override("font_outline_color", Color.BLACK)
		hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hp_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(hp_label)
		box.tooltip_text += "　HP %d/%d" % [hp.hp, hp.max]
	box.mouse_entered.connect(_show_detail.bind(code))
	return box


func _show_detail(code: int) -> void:
	var info := _info(code)
	_detail.clear()
	_detail.append_text("[b]%s[/b] (%d)\n%s" % [info.get("name", "?"), code, info.get("text", "")])


func _info(code: int) -> Dictionary:
	if not _infos.has(code):
		_infos[code] = session.content.card_info(code) if session else {}
	return _infos[code]


func _name(code: int) -> String:
	return _info(code).get("name", str(code))


func _on_event(e: Dictionary) -> void:
	_log.append_text(String(e.text).strip_edges() + "\n")
	match e.type:
		"new_turn":
			_turn += 1
			_turn_player = e.player
		"new_phase":
			_phase = PHASE_NAMES.get(e.value, str(e.value))


func _win_reason(reason: int) -> String:
	return {1: "LP 歸零", 2: "牌組抽乾"}.get(reason, "卡片效果")


# --------------------------------------------------------------- prompts

func _clear_prompt() -> void:
	_prompt = {}
	for child in _prompt_box.get_children():
		_prompt_box.remove_child(child)
		child.queue_free()


func _show_prompt(p: Dictionary) -> void:
	_clear_prompt()
	_prompt = p
	_shown_prompt_id = p.id
	_prompt_title.text = "玩家 %d：%s%s" % [p.player, PROMPT_NAMES.get(p.type, p.type),
		"（上次的選擇不合規則，請重選）" if p.retry else ""]
	var exactly_one: bool = p.min == 1 and p.max == 1 and p.type in ["SELECT_CARD", "SELECT_PLACE"]
	match String(p.type) if not exactly_one else "":
		"SELECT_CARD", "SELECT_TRIBUTE", "SELECT_SUM", "SELECT_PLACE", "ANNOUNCE_RACE", "ANNOUNCE_ATTRIB":
			_multi_pick(p)
		"SELECT_COUNTER":
			_counter_pick(p)
		"SORT_CARD":
			_sort_pick(p)
		"ANNOUNCE_CARD":
			_card_code_pick(p)
		_:
			for i in p.options.size():
				var b := _add_button(_option_label(p, p.options[i]), _submit.bind(PackedInt64Array([i])))
				# The battle module refuses blocked options anyway; this only explains why.
				if p.options[i].get("blocked", "") != "":
					b.disabled = true
					var ap: Dictionary = session.duel.ap(p.player)
					b.text += "　【AP 不足：需要 %d，剩 %d】" % [p.options[i].cost, ap.current]
					b.tooltip_text = p.options[i].blocked


func _option_label(p: Dictionary, o: Dictionary) -> String:
	var action: String = o.action
	var parts := []
	var verb: String = ACTION_NAMES.get(action, action)
	if action == "end":
		verb = "進入結束階段" if p.type == "SELECT_BATTLECMD" else "結束回合"
	if verb != "":
		parts.append(verb)
	var card: Dictionary = o.card
	if action == "zone":
		parts.append(_where(card))
	elif card.code != 0:
		parts.append(_name(card.code) + ("　" + _where(card) if card.location != 0 else ""))
	match action:
		"race":
			parts.append(_bit_name(o.desc, RACES))
		"attribute":
			parts.append(_bit_name(o.desc, ATTRIBUTES))
		"number":
			parts.append(str(o.desc))
	if o.desc != 0 and action in ["activate", "option", "yes"]:
		var text := session.content.description(o.desc)
		if text != "":
			parts.append("「%s」" % text)
	if p.type in ["SELECT_SUM", "SELECT_COUNTER"]:
		parts.append("(%d)" % (int(o.param) & 0xffff))
	if o.get("cost", 0) > 0:
		parts.append("（AP %d）" % o.cost)
	return " ".join(parts)


func _where(card: Dictionary) -> String:
	return "P%d %s[%d]" % [card.controller, LOCATION_NAMES.get(card.location, str(card.location)), card.sequence]


func _bit_name(bit: int, names: Array) -> String:
	for i in names.size():
		if bit == 1 << i:
			return names[i]
	return "0x%x" % bit


func _add_button(text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(callback)
	_prompt_box.add_child(b)
	return b


func _multi_pick(p: Dictionary) -> void:
	var checks := []
	for i in p.options.size():
		var o: Dictionary = p.options[i]
		var check := CheckBox.new()
		check.text = _option_label(p, o)
		check.disabled = o.action == "must"
		check.button_pressed = o.action == "must"
		_prompt_box.add_child(check)
		checks.append(check)
	var need := ""
	if p.type == "SELECT_SUM":
		need = "合計%s %d" % ["至少" if p.at_least else "等於", p.value]
	elif p.type in ["ANNOUNCE_RACE", "ANNOUNCE_ATTRIB"]:
		need = "選 %d 個" % p.value
	else:
		need = "選 %d～%d 個" % [p.min, p.max]
	_add_button("確定（%s）" % need, func() -> void:
		var picks := PackedInt64Array()
		for i in checks.size():
			if checks[i].button_pressed and not checks[i].disabled:
				picks.append(i)
		_submit(picks))
	if p.cancelable:
		_add_button("取消", _submit.bind(PackedInt64Array()))


func _counter_pick(p: Dictionary) -> void:
	var spins := []
	for o in p.options:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = _option_label(p, o)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var spin := SpinBox.new()
		spin.max_value = o.param
		row.add_child(label)
		row.add_child(spin)
		_prompt_box.add_child(row)
		spins.append(spin)
	_add_button("確定（共移除 %d 個）" % p.value, func() -> void:
		var picks := PackedInt64Array()
		for i in spins.size():
			for n in int(spins[i].value):
				picks.append(i)
		_submit(picks))


func _sort_pick(p: Dictionary) -> void:
	var order := [] # Array, not PackedInt64Array: packed arrays are copied into lambdas
	var shown := Label.new()
	shown.text = "依序點選，第一個在最上面："
	_prompt_box.add_child(shown)
	for i in p.options.size():
		var b := _add_button(_option_label(p, p.options[i]), func() -> void: pass)
		b.pressed.connect(func() -> void:
			order.append(i)
			b.disabled = true
			shown.text += " %d.%s" % [order.size(), _name(p.options[i].card.code)])
	_add_button("確定順序", func() -> void: _submit(PackedInt64Array(order)))
	_add_button("使用預設順序", _submit.bind(PackedInt64Array()))


func _card_code_pick(p: Dictionary) -> void:
	var edit := LineEdit.new()
	edit.placeholder_text = "輸入卡號"
	var name_label := Label.new()
	edit.text_changed.connect(func(t: String) -> void:
		name_label.text = _name(int(t)) if t.is_valid_int() else "")
	_prompt_box.add_child(edit)
	_prompt_box.add_child(name_label)
	_add_button("宣言", func() -> void:
		_submit(PackedInt64Array([int(edit.text)]) if edit.text.is_valid_int() else PackedInt64Array()))


func _submit(picks: PackedInt64Array) -> void:
	if _prompt.is_empty():
		return
	var err := session.answer(_prompt.id, picks)
	if err != "":
		_prompt_title.text = "%s\n無法送出：%s" % [_prompt_title.text.split("\n")[0], err]
		return
	_clear_prompt()


## Passive opponent for testing one's own deck: passes, ends turns, declines effects.
func _auto_answer(p: Dictionary) -> bool:
	if not _auto_pass.button_pressed or p.player != 1:
		return false
	var picks := PackedInt64Array()
	match String(p.type):
		"SELECT_PLACE":
			for i in int(p.min):
				picks.append(i)
		"SORT_CARD":
			pass
		"SELECT_POSITION":
			picks.append(0)
		_:
			var wanted := {"SELECT_CHAIN": "pass", "SELECT_IDLECMD": "end", "SELECT_BATTLECMD": "end",
				"SELECT_EFFECTYN": "no", "SELECT_YESNO": "no"}.get(p.type, "")
			for i in p.options.size():
				if p.options[i].action == wanted:
					picks.append(i)
					break
			if picks.is_empty():
				return false # something the passive policy cannot decide: ask the user
	_shown_prompt_id = p.id
	_log.append_text("（對手自動：%s）\n" % PROMPT_NAMES.get(p.type, p.type))
	return session.answer(p.id, picks) == ""
