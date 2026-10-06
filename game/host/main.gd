extends Control
## Minimal test host: previews decks, starts battles, leaves the battle screen and comes back
## to the same duel, and shows results. AP values and the building point cap come from
## host/test_settings.gd (test values); the battle module only gets them as config.

const TestBattles := preload("res://host/test_battles.gd")
const TestSettings := preload("res://host/test_settings.gd")
const OPPONENT_DECK := "tests/decks/test_basic.ydk"

var content: YgoContent
var points: YgoDeckPoints
var session: YgoBattleSession
var screen: Control
var preview: Control
var menu: VBoxContainer
var status: Label
var resume_button: Button
var ap_check: CheckBox


func _ready() -> void:
	menu = VBoxContainer.new()
	menu.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	menu.custom_minimum_size = Vector2(560, 0)
	add_child(menu)
	var title := Label.new()
	title.text = "YGO PvE 戰鬥測試宿主"
	title.add_theme_font_size_override("font_size", 28)
	menu.add_child(title)
	ap_check = CheckBox.new()
	ap_check.text = "P0 啟用 AP（測試值：上限 %d，每個動作 1 點）" % TestSettings.AP.max
	ap_check.button_pressed = true
	menu.add_child(ap_check)
	_add_button("測試對戰：basic_chain_win 的開場（雙方手動）", func() -> void: _start(TestBattles.basic_chain_win()))
	for file in [OPPONENT_DECK, "dark_time_wizard.ydk"]:
		if FileAccess.file_exists(TestBattles.deck_path(file)):
			_add_button("預覽牌組：%s（對手 %s）" % [file.get_file(), OPPONENT_DECK.get_file()], _preview.bind(file))
	resume_button = _add_button("回到目前的對戰", _enter)
	resume_button.disabled = true
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu.add_child(status)

	screen = load("res://addons/ygo_battle/battle_screen.tscn").instantiate()
	screen.hide()
	add_child(screen)
	screen.leave_requested.connect(_leave)
	screen.finished.connect(_on_finished)
	preview = load("res://addons/ygo_battle/deck_preview.tscn").instantiate()
	preview.hide()
	add_child(preview)
	preview.back_requested.connect(func() -> void:
		preview.hide()
		menu.show())
	preview.start_requested.connect(_start_with_deck)


func _add_button(text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(callback)
	menu.add_child(b)
	return b


func _ensure_content() -> bool:
	var error := []
	if content == null:
		content = YgoBattleSession.open_content(TestBattles.resources(), error)
	if points == null and content != null:
		points = YgoDeckPoints.load_table(TestSettings.POINTS_TABLE, error)
	if not error.is_empty():
		status.text = "無法載入資料：%s" % [error]
	return content != null and points != null


func _preview(file: String) -> void:
	if not _ensure_content():
		return
	var deck := YgoContent.load_ydk(TestBattles.deck_path(file))
	if deck.error != "":
		status.text = "牌組載入失敗：%s" % deck.error
		return
	menu.hide()
	preview.show_deck(file, deck, points, TestSettings.BUILD_POINT_CAP, content, TestBattles.resources().images_dir)


func _start_with_deck(deck: Dictionary) -> void:
	var opponent := YgoContent.load_ydk(TestBattles.deck_path(OPPONENT_DECK))
	var seed := Time.get_ticks_usec()
	preview.hide()
	_start({"seed": seed, "players": [{"main": deck.main, "extra": deck.extra}, {"main": opponent.main, "extra": opponent.extra}]},
		{"points": points, "cap": TestSettings.BUILD_POINT_CAP})
	if session != null:
		status.text = "種子 %d（同一種子可重現開場）" % seed


func _start(config: Dictionary, rules := {}) -> void:
	if not _ensure_content():
		menu.show()
		return
	if ap_check.button_pressed:
		config.players[0]["ap"] = TestSettings.AP
	session = YgoBattleSession.new()
	var err := session.start(content, config, rules)
	if err != "":
		status.text = "無法建立對戰：%s" % err
		session = null
		menu.show()
		return
	_enter()


func _enter() -> void:
	menu.hide()
	screen.attach(session, TestBattles.resources())


## Leaving the screen keeps the session (and its duel) for later.
func _leave() -> void:
	screen.detach()
	menu.show()
	if session != null and not session.is_running():
		session = null # finished: nothing to come back to
	resume_button.disabled = session == null
	if session != null:
		status.text = "對戰暫停中，可以按「回到目前的對戰」繼續。"


func _on_finished(result: Dictionary) -> void:
	status.text = "上一場：%s" % ("錯誤 " + result.error if result.get("error", "") != "" else "玩家 %d 獲勝" % result.winner)
