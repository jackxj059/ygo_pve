extends SceneTree
## Headless check that the GDExtension loads and drives a whole duel from GDScript:
## replays tests/duel/basic_chain_win.duel through YgoBattleSession, then instantiates
## the battle screen on a fresh duel. Run by scripts/test-godot.ps1; exit code 0 = pass.

const TestBattles := preload("res://host/test_battles.gd")

## [player, action, card code]; chain windows/zones/positions not listed here are answered
## with "pass"/first option, like the C++ harness defaults.
const ACTIONS := [
	[0, "summon", 25259669], [0, "yes", 0], [0, "card", 43096270], [0, "end", 0],
	[1, "summon", 26202165], [1, "sset", 24068492], [1, "end", 0],
	[0, "activate", 83764718], [0, "card", 89631139], [1, "chain", 24068492],
	[0, "battle", 0], [0, "attack", 43096270], [0, "card", 26202165], [1, "card", 15025844],
	[0, "attack", 89631139],
]

var failures := 0


func check(ok: bool, what: String) -> void:
	print(("  ok: " if ok else "  FAIL: ") + what)
	if not ok:
		failures += 1


func _initialize() -> void:
	var error := []
	var content := YgoBattleSession.open_content(TestBattles.resources(), error)
	check(content != null, "content opened %s" % [error])
	if content == null:
		quit(1)
		return
	check(content.card_info(89631139).name == "Blue-Eyes White Dragon", "card_info reads the database")

	var session := YgoBattleSession.new()
	check(session.start(content, TestBattles.basic_chain_win()) == "", "duel started")
	var queue := ACTIONS.duplicate()
	for guard in 1000:
		session.step()
		var p := session.prompt()
		if p.is_empty():
			break
		var picks := PackedInt64Array([pick(p, queue)])
		if picks[0] < 0:
			check(false, "no scripted answer for %s" % p.text)
			break
		var err := session.answer(p.id, picks)
		if err != "":
			check(false, "answer rejected: " + err)
			break
	check(queue.is_empty(), "all scripted actions used (%d left)" % queue.size())
	check(session.result.get("winner") == 0 and session.result.get("reason") == 1, "p0 wins by LP: %s" % [session.result])
	check(session.duel.lp(1) == 0 and session.duel.lp(0) == 7000, "final LP 7000 / 0")

	# The screen attaches to a running session, renders the first prompt, and detaches again.
	var second := YgoBattleSession.new()
	second.start(content, TestBattles.basic_chain_win())
	var screen: Control = load("res://addons/ygo_battle/battle_screen.tscn").instantiate()
	root.add_child(screen)
	screen.attach(second, TestBattles.resources())
	for i in 5:
		await process_frame
	check(screen.current_prompt_type() == "SELECT_IDLECMD", "screen shows the first prompt")
	screen.detach()
	check(second.is_running(), "detaching the screen keeps the duel alive")
	screen.queue_free()

	print("PASS" if failures == 0 else "FAIL: %d check(s)" % failures)
	quit(0 if failures == 0 else 1)


## Option index for the next scripted action, or the harness-style default.
static func pick(p: Dictionary, queue: Array) -> int:
	var options: Array = p.options
	if not queue.is_empty() and queue[0][0] == p.player:
		var want: String = queue[0][1]
		var code: int = queue[0][2]
		var action := "activate" if want == "chain" else want
		for i in options.size():
			if options[i].action == action and (code == 0 or options[i].card.code == code):
				if p.type != "SELECT_CHAIN" or want == "chain":
					queue.pop_front()
					return i
	for default_action in ["pass", "zone", "fu_atk"]:
		for i in options.size():
			if options[i].action == default_action:
				return i
	return -1
