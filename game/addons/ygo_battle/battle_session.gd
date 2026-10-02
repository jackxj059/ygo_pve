class_name YgoBattleSession
extends RefCounted
## One battle. Owns the duel and keeps it alive while screens are attached or detached;
## dropping the last reference to the session is what destroys the duel.

signal finished(result: Dictionary) ## {winner: int, reason: int, error: String}

var content: YgoContent
var duel: YgoDuel
var log_lines := PackedStringArray()
var result := {} ## empty until the duel ends or fails


## resources: {scripts_dir: String, databases: PackedStringArray}. Returns null and fills `error`
## (a one-element Array) when the content cannot be opened.
static func open_content(resources: Dictionary, error: Array) -> YgoContent:
	var c := YgoContent.new()
	var err := c.open(resources.get("scripts_dir", ""), PackedStringArray(resources.get("databases", [])))
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


func start(with_content: YgoContent, config: Dictionary) -> String:
	content = with_content
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
		if status == YgoDuel.STATUS_ENDED or status == YgoDuel.STATUS_ERROR:
			result = {"winner": duel.winner(), "reason": duel.win_reason(), "error": duel.get_error()}
			finished.emit(result)
		break
	return events


func prompt() -> Dictionary:
	return duel.get_prompt() if is_running() else {}


func answer(prompt_id: int, picks: PackedInt64Array) -> String:
	return duel.submit(prompt_id, picks)
