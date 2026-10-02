extends RefCounted
## Battle setups and resource paths for the test host. In this repository the game data
## lives next to the Godot project (../third_party); another host passes its own paths.

const LOCATION_DECK := 0x01
const LOCATION_HAND := 0x02
const LOCATION_GRAVE := 0x10


static func repo_root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


## Paths the battle module needs: card scripts, card databases, card images.
static func resources() -> Dictionary:
	var tp := repo_root().path_join("third_party")
	return {
		"scripts_dir": tp.path_join("CardScripts"),
		"databases": PackedStringArray([
			tp.path_join("BabelCDB/cards.cdb"),
			tp.path_join("BabelCDB/release-betb.cdb"),
		]),
		"images_dir": tp.path_join("card_images/full"),
	}


static func deck_path(file: String) -> String:
	return repo_root().path_join(file)


## Same opening as tests/duel/basic_chain_win.duel (test settings, not product rules).
static func basic_chain_win() -> Dictionary:
	var placements := []
	for p in [
		[0, LOCATION_HAND, 25259669], [0, LOCATION_HAND, 43096270], [0, LOCATION_HAND, 83764718],
		[0, LOCATION_GRAVE, 89631139], [1, LOCATION_HAND, 26202165], [1, LOCATION_HAND, 24068492],
	]:
		placements.append({"player": p[0], "location": p[1], "code": p[2]})
	for player in 2:
		for i in 10:
			placements.append({"player": player, "location": LOCATION_DECK, "code": 15025844})
	return {
		"seed": [20261001, 1, 2, 3],
		"players": [
			{"lp": 8000, "start_draw": 0},
			{"lp": 4000, "start_draw": 0},
		],
		"placements": placements,
	}
