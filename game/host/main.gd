extends Control
## Minimal test host: starts battles, leaves the battle screen and comes back to the same
## duel, and shows results. AP values come from host/test_settings.gd (test values); the
## battle module only gets them as config.

const TestBattles := preload("res://host/test_battles.gd")
const TestSettings := preload("res://host/test_settings.gd")

var content: YgoContent
var session: YgoBattleSession
var screen: Control
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
	_add_button("牌組對戰：test_basic.ydk 對 test_basic.ydk", func() -> void:
		_start_decks(["tests/decks/test_basic.ydk", "tests/decks/test_basic.ydk"]))
	if FileAccess.file_exists(TestBattles.deck_path("dark_time_wizard.ydk")):
		_add_button("牌組對戰：dark_time_wizard.ydk 對 test_basic.ydk", func() -> void:
			_start_decks(["dark_time_wizard.ydk", "tests/decks/test_basic.ydk"]))
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


func _add_button(text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(callback)
	menu.add_child(b)
	return b


func _ensure_content() -> bool:
	if content != null:
		return true
	var error := []
	content = YgoBattleSession.open_content(TestBattles.resources(), error)
	if content == null:
		status.text = "無法開啟卡片資料：%s" % [error]
	return content != null


func _start_decks(files: Array) -> void:
	var paths := files.map(func(f: String) -> String: return TestBattles.deck_path(f))
	var seed := Time.get_ticks_usec()
	var error := []
	var config := YgoBattleSession.config_from_decks(paths, seed, error)
	if config.is_empty():
		status.text = "牌組載入失敗：%s" % [error]
		return
	_start(config)
	status.text = "種子 %d（同一種子可重現開場）" % seed


func _start(config: Dictionary) -> void:
	if not _ensure_content():
		return
	if ap_check.button_pressed:
		config.players[0]["ap"] = TestSettings.AP
	session = YgoBattleSession.new()
	var err := session.start(content, config)
	if err != "":
		status.text = "無法建立對戰：%s" % err
		session = null
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
