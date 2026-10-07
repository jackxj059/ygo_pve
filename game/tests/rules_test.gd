extends SceneTree
## Headless checks for the building points and the AP fields exposed to GDScript.
## Run by scripts/test-duel.ps1; exit code 0 = pass.

const TestBattles := preload("res://host/test_battles.gd")
const TestSettings := preload("res://host/test_settings.gd")

const ASH := 14558127 # Ash Blossom & Joyous Spring: 20 points in the imported table
const REBORN := 83764718 # Monster Reborn: 3 points
const ELF := 15025844 # Mystical Elf: not on the list
const FAIMENA_ALT := 1498450 # alternate artwork of Dracotail Faimena (1498449, 30 points)

var failures := 0


func check(ok: bool, what: String) -> void:
	print(("  ok: " if ok else "  FAIL: ") + what)
	if not ok:
		failures += 1


func _initialize() -> void:
	var error := []
	var content := YgoBattleSession.open_content(TestBattles.resources(), error)
	var table := YgoDeckPoints.load_table(TestSettings.POINTS_TABLE, error)
	check(content != null and table != null, "content and points table load %s" % [error])
	if content == null or table == null:
		quit(1)
		return

	print("points table")
	check(table.version == "genesys-tcg-2026-10-06" and table.points.size() == 761, "version and size")
	check(table.unlisted_points == 0, "the table declares unlisted cards as 0 points")

	print("deck totals")
	var r := table.evaluate({"main": [ASH, ASH, REBORN, ELF], "extra": [], "side": []}, 100, content)
	check(r.ok and r.total == 43, "duplicates count per copy: 20+20+3+0 = 43 (got %d)" % r.total)
	var elf_line: Dictionary = r.lines.filter(func(l): return l.code == ELF)[0]
	check(not elf_line.listed and elf_line.each == 0, "unlisted card uses the declared value")
	r = table.evaluate({"main": [REBORN], "extra": [ASH], "side": [ASH, ASH, ASH, ASH, ASH, ASH]}, 100, content)
	check(r.total == 23, "extra counts, side does not (got %d)" % r.total)
	r = table.evaluate({"main": [ASH, ASH, ASH, ASH, ASH, ASH]}, 100, content)
	check(not r.ok and r.total == 120 and "the cap is 100" in r.errors[0], "over the cap is not ok: %s" % [r.errors])
	r = table.evaluate({"main": [FAIMENA_ALT]}, 100, content)
	check(r.total == 30 and r.lines[0].listed, "alternate artwork uses its base card's points")
	r = table.evaluate({"main": [99999999]}, 100, content)
	check(not r.ok and "unknown card code 99999999" in r.errors[0], "unknown card is an error")

	print("table validation")
	var path := "user://points_without_default.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"format": YgoDeckPoints.FORMAT, "version": "t", "points": {}}))
	f.close()
	error.clear()
	check(YgoDeckPoints.load_table(path, error) == null and "unlisted_points" in error[0], "a table without unlisted_points is refused")
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"format": YgoDeckPoints.FORMAT, "version": "t", "unlisted_points": 5, "points": {}}))
	f.close()
	var custom := YgoDeckPoints.load_table(path, error)
	check(custom.evaluate({"main": [ELF, ELF]}, 100, content).total == 10, "a table's own unlisted value is used")

	print("legal deck required to start")
	var deck := YgoContent.load_ydk(TestBattles.deck_path("tests/decks/test_basic.ydk"))
	var config := {"seed": 1, "players": [{"main": [ASH, ASH, ASH, ASH, ASH, ASH] + Array(deck.main)}, {"main": deck.main}]}
	var session := YgoBattleSession.new()
	var err := session.start(content, config, {"points": table, "cap": 100})
	check("deck is not legal" in err and session.duel == null, "over-cap deck cannot start: %s" % err)
	config.players[0].main = deck.main
	check(session.start(content, config, {"points": table, "cap": 100}) == "", "legal deck starts")

	print("AP through the GDExtension")
	var battle := TestBattles.basic_chain_win()
	battle.players[0]["ap"] = TestSettings.AP
	session = YgoBattleSession.new()
	session.start(content, battle)
	session.step()
	var p := session.prompt()
	check(session.duel.ap(0).enabled and session.duel.ap(0).current == 3 and session.duel.ap(0).max == 3, "AP 3/3 at turn 1")
	check(not session.duel.ap(1).enabled, "opponent has no AP")
	var summon := -1
	for i in p.options.size():
		if p.options[i].action == "summon" and p.options[i].card.code == 25259669:
			summon = i
	check(summon >= 0 and p.options[summon].cost == 1 and p.options[summon].blocked == "", "summon option costs 1 AP")
	session.answer(p.id, PackedInt64Array([summon]))
	for i in 3:
		session.step()
		p = session.prompt()
		if p.type == "SELECT_PLACE":
			session.answer(p.id, PackedInt64Array([0]))
	check(session.duel.ap(0).current == 2, "summoning spent 1 AP (now %d)" % session.duel.ap(0).current)
	check(session.log_lines.has("p0 spends 1 AP (2 left)"), "the AP event reaches GDScript")

	print("enemy prototype through the GDExtension")
	check(content.is_enemy(990000001) and content.card_info(990000001).name == "岩殼守衛", "enemy definition read from Lua")
	session = YgoBattleSession.new()
	check(session.start(content, TestBattles.enemy_prototype()) == "", "enemy test battle starts")
	session.step()
	var enemy: Dictionary = session.duel.cards(1, YgoDuel.LOCATION_MZONE)[0]
	var hp: Dictionary = session.duel.hp(enemy.instance)
	check(enemy.code == 990000001 and enemy.position == YgoDuel.POS_FACEUP_DEFENSE, "enemy placed in face-up defense")
	check(hp.get("hp") == 3200 and hp.get("max") == 3200, "HP 3200/3200 reported at the start (got %s)" % [hp])

	print("enemy scripts play P1")
	session = YgoBattleSession.new()
	session.start(content, TestBattles.enemy_prototype(), {"script_players": [1]})
	# P0 passes chain windows and ends turn 1; the enemy's whole turn then runs inside step().
	var ended := false
	for i in 50:
		session.step()
		p = session.prompt()
		if p.is_empty():
			continue # still running (step() processes a limited number of batches per call)
		if ended and p.type == "SELECT_IDLECMD":
			break
		var wanted := "end" if p.type == "SELECT_IDLECMD" else "pass"
		ended = ended or wanted == "end"
		for j in p.options.size():
			if p.options[j].action == wanted:
				session.answer(p.id, PackedInt64Array([j]))
				break
	check(ended and p.get("player") == 0 and p.get("type") == "SELECT_IDLECMD" and session.result.is_empty(),
		"back to P0's main phase after the enemy's turn (%s)" % [session.result])
	check(session.duel.lp(0) == 6300, "the enemy used 岩盤強化 and attacked directly: 1700 (P0 LP %d)" % session.duel.lp(0))
	check(session.duel.count(1, YgoDuel.LOCATION_SZONE) == 1 and session.duel.count(1, YgoDuel.LOCATION_HAND) == 1,
		"重壓結界 on the field, 岩盤強化 back in the skill pool")

	print("items and equipment through the GDExtension")
	check(content.is_item(990000303) and content.is_equip(990000202), "item and equipment definitions read from Lua")
	session = YgoBattleSession.new()
	err = session.start(content, {"seed": 1, "players": [{"main": deck.main, "start_draw": 0}, {"main": deck.main}],
		"items": [{"player": 0, "code": 990000303, "count": 1}],
		"equipment": [{"player": 0, "source": "main", "index": 0, "code": 990000202}]})
	check(err == "", "battle with an item and equipment starts: %s" % err)
	var equipped := 0
	for c: Dictionary in session.duel.cards(0, YgoDuel.LOCATION_DECK):
		if session.equipment_of(c.instance) == 990000202:
			equipped += 1
	check(equipped == 1, "the equipment is on exactly one card (main deck index 0)")
	var used := false
	for i in 10:
		session.step()
		p = session.prompt()
		if p.get("type") == "SELECT_IDLECMD":
			for j in p.options.size():
				if p.options[j].card.code == 990000303:
					session.answer(p.id, PackedInt64Array([j]))
					used = true
			break
		if not p.is_empty():
			session.answer(p.id, PackedInt64Array([p.options.size() - 1])) # pass chain windows
	var item_events := []
	for i in 3:
		item_events.append_array(session.step().filter(func(e: Dictionary) -> bool: return e.type == "item"))
	check(used and session.duel.lp(0) == 9000, "the item was used from the main phase command (LP %d)" % session.duel.lp(0))
	check(item_events.size() == 1 and item_events[0].result == "success", "item event with its result: %s" % [item_events])
	check(session.duel.items()[0].left == 0, "the item is used up")
	session = YgoBattleSession.new()
	err = session.start(content, {"seed": 1, "players": [{"main": deck.main}, {"main": deck.main}],
		"equipment": [{"player": 0, "source": "main", "index": 99, "code": 990000202}]})
	check("no card at that position" in err, "equipment on a missing card is refused: %s" % err)
	check(content.equip_refusal(990000204, 6368038) == "" and "Level 5" in content.equip_refusal(990000204, 91152256),
		"equipment restrictions are visible to the setup screen (Gaia ok, Celtic Guardian refused)")
	check(content.equip_requires(990000204) == {"race": 1, "min_level": 5}, "equip_requires: %s" % [content.equip_requires(990000204)])

	print("PASS" if failures == 0 else "FAIL: %d check(s)" % failures)
	quit(0 if failures == 0 else 1)
