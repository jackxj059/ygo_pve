extends SceneTree
## Opens the test host, starts the basic test battle, optionally plays the first N scripted
## actions of the smoke test, and saves a screenshot, for checking the layout without
## clicking. Needs a window (not --headless). Usage:
##   godot --path game --script res://tests/screenshot.gd -- <output.png> [actions | preview:<deck.ydk> | enemy | enemy_ai]

const Smoke := preload("res://tests/smoke_test.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else ProjectSettings.globalize_path("user://battle.png")
	var mode: String = args[1] if args.size() > 1 else "0"
	var main: Control = load("res://host/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	if mode.begins_with("preview:") or mode.begins_with("equip:"):
		# preview:<deck> - deck preview of a .ydk relative to the repository root
		# equip:<deck>   - same, with 雙擊徽章 on main[0] and 省力徽章 on main[1], then a battle
		#                  against the enemy, shown at P0's first main phase prompt
		main._preview(mode.get_slice(":", 1))
		for i in 30:
			await process_frame
		if mode.begins_with("equip:"):
			for assign in [["main:0", 990000202], ["main:1", 990000201]]:
				main.preview._menu_key = assign[0]
				main.preview._on_menu(assign[1])
			for i in 5:
				await process_frame
			if args.size() > 2: # optional: a screenshot of the preview with the equipment
				root.get_viewport().get_texture().get_image().save_png(args[2])
			main._start_with_deck(main.preview._deck, main.preview._equipment_config(), "enemy")
			for i in 600:
				await process_frame
				var p: Dictionary = main.session.prompt() if main.session else {}
				if p.get("type") == "SELECT_IDLECMD":
					break
				if not p.is_empty() and p.type == "SELECT_CHAIN":
					main.session.answer(p.id, PackedInt64Array([p.options.size() - 1]))
			for i in 10:
				await process_frame
		root.get_viewport().get_texture().get_image().save_png(out)
		print("saved ", out)
		quit()
		return
	var actions := int(mode)
	if mode == "enemy": # enemy prototype opening (no scripted actions)
		main._start(preload("res://host/test_battles.gd").enemy_prototype())
	elif mode == "enemy_ai": # enemy prototype with the enemy script playing P1; P0 ends turn 1
		main._start(preload("res://host/test_battles.gd").enemy_prototype(), {"script_players": [1]})
		actions = 0
		var ended := false
		for i in 300:
			await process_frame
			var p: Dictionary = main.session.prompt()
			if p.is_empty():
				continue
			if ended and p.type == "SELECT_IDLECMD":
				break # P0's turn 3: the enemy's turn has been played
			var wanted := "end" if p.type == "SELECT_IDLECMD" else "pass" # P0: pass chain windows
			ended = ended or wanted == "end"
			for j in p.options.size():
				if p.options[j].action == wanted:
					main.session.answer(p.id, PackedInt64Array([j]))
					break
	else:
		main._start(preload("res://host/test_battles.gd").basic_chain_win())
	var queue := Smoke.ACTIONS.slice(0, actions)
	for i in 600:
		await process_frame
		var p: Dictionary = main.session.prompt()
		if p.is_empty():
			continue
		if queue.is_empty() and not p.type in ["SELECT_CHAIN", "SELECT_PLACE", "SELECT_POSITION"]:
			break # leave the next real decision on screen
		var pick := Smoke.pick(p, queue)
		if pick < 0:
			break
		main.session.answer(p.id, PackedInt64Array([pick]))
	for i in 10:
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out)
	print("saved ", out)
	quit()
