class_name YgoBattleSession
extends RefCounted
## One battle. Owns the duel and keeps it alive while screens are attached or detached;
## dropping the last reference to the session is what destroys the duel.

signal finished(result: Dictionary) ## {winner: int, reason: int, error: String}

var content: YgoContent
var duel: YgoDuel
var log_lines := PackedStringArray()
var result := {} ## empty until the duel ends or fails
var script_players := [] ## players whose prompts the enemy scripts answer (see start())
var equipment := [] ## config.equipment of this battle: [{player, source, index, code}]


## resources: {scripts_dir: String, databases: PackedStringArray, custom_dir: String (optional:
## enemies, items, equipment)}.
## Returns null and fills `error`
## (a one-element Array) when the content cannot be opened.
static func open_content(resources: Dictionary, error: Array) -> YgoContent:
	var c := YgoContent.new()
	var err := c.open(resources.get("scripts_dir", ""), PackedStringArray(resources.get("databases", [])),
		resources.get("custom_dir", ""))
	if err != "":
		error.append(err)
		return null
	return c


## Builds a duel config from two .ydk files (players 0 and 1). Returns {} and fills `error` on failure.
static func config_from_decks(deck_paths: Array, seed: int, error: Array) -> Dictionary:
	var players := []
	for path in deck_paths:
		var deck := YgoContent.load_ydk(path)
		if deck.error != "":
			error.append(deck.error)
			return {}
		players.append({"main": deck.main, "extra": deck.extra})
	return {"seed": seed, "players": players}


## rules (optional):
##   {points: YgoDeckPoints, cap: int} - player 0's main + extra deck must fit the cap.
##     Opponents are not checked (enemies will not be built from decks).
##   {script_players: [1]} - the enemy scripts (s.ai in game/data/enemies) answer every prompt of
##     these players inside step(); hosts only ever see the other players' prompts.
func start(with_content: YgoContent, config: Dictionary, rules := {}) -> String:
	content = with_content
	script_players = rules.get("script_players", [])
	equipment = config.get("equipment", [])
	if rules.has("points"):
		var player: Dictionary = config.get("players", [{}])[0]
		var check: Dictionary = rules.points.evaluate(player, rules.get("cap", 0), content)
		if not check.ok:
			return "deck is not legal: " + "; ".join(check.errors)
	duel = YgoDuel.new()
	return duel.start(content, config)


func is_running() -> bool:
	return result.is_empty() and duel != null


## Runs the core until it needs an answer, the duel ends, or `max_steps` batches were processed.
## Returns the events of this call; they are also appended to `log_lines`.
func step(max_steps := 64) -> Array:
	var events := []
	if not is_running():
		return events
	for i in max_steps:
		var status := duel.advance()
		var batch := duel.take_events()
		for e in batch:
			log_lines.append(String(e.text).strip_edges())
		events.append_array(batch)
		if status == YgoDuel.STATUS_CONTINUE:
			continue
		if status == YgoDuel.STATUS_AWAITING and _answer_by_script():
			continue
		if status == YgoDuel.STATUS_ENDED or status == YgoDuel.STATUS_ERROR:
			result = {"winner": duel.winner(), "reason": duel.win_reason(), "error": duel.get_error()}
			finished.emit(result)
		break
	return events


## Answers the pending prompt with the enemy scripts if it belongs to a script player.
## A failed or rejected answer ends the battle with an error instead of guessing.
func _answer_by_script() -> bool:
	var p := duel.get_prompt()
	if not int(p.player) in script_players:
		return false
	var err := ""
	if p.get("retry", false):
		err = "the core rejected the enemy scripts' previous answer"
	else:
		var d := duel.script_decide()
		err = d.error if d.error != "" else duel.submit(p.id, d.picks)
	if err != "":
		result = {"winner": -1, "reason": 0, "error": "enemy decision failed: " + err}
		finished.emit(result)
		return false
	return true


## The equipment fixed to a card instance (0 if none), found through the card's origin in the
## config - the same external fixed id the battle module bound it by.
func equipment_of(instance: int) -> int:
	var o := duel.origin(instance) if duel else {}
	for eq: Dictionary in equipment:
		if not o.is_empty() and eq.get("player", 0) == o.player and eq.source == o.source and eq.index == o.index:
			return eq.code
	return 0


func prompt() -> Dictionary:
	return duel.get_prompt() if is_running() else {}


func answer(prompt_id: int, picks: PackedInt64Array) -> String:
	return duel.submit(prompt_id, picks)
