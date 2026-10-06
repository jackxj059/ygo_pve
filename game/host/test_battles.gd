extends RefCounted
## Battle setups and resource paths for the test host. In this repository the game data
## lives next to the Godot project (../third_party); another host passes its own paths.

const LOCATION_DECK := 0x01
const LOCATION_HAND := 0x02
const LOCATION_GRAVE := 0x10
const LOCATION_MZONE := 0x04
const POS_FACEUP_DEFENSE := 0x4


static func repo_root() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


## Paths the battle module needs: card scripts, card databases, enemy definitions, card images.
static func resources() -> Dictionary:
	var tp := repo_root().path_join("third_party")
	return {
		"scripts_dir": tp.path_join("CardScripts"),
		"databases": PackedStringArray([
			tp.path_join("BabelCDB/cards.cdb"),
			tp.path_join("BabelCDB/release-betb.cdb"),
		]),
		"enemies_dir": ProjectSettings.globalize_path("res://data/enemies"),
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


## Enemy prototype opening (test settings, not product rules): the enemy in face-up defense, P0's
## field empty and a hand to try things with. P1 is the enemy side: no deck, no draws.
static func enemy_prototype() -> Dictionary:
	var placements := [{"player": 1, "location": LOCATION_MZONE, "code": 990000001, "sequence": 0, "position": POS_FACEUP_DEFENSE}]
	# 6 cards (the hand limit): Gene-Warped Warwolf, Celtic Guardian, Mystical Elf, Wasteland,
	# Hinotama, Infinite Impermanence
	for code in [69247929, 91152256, 15025844, 23424603, 46130346, 10045474]:
		placements.append({"player": 0, "location": LOCATION_HAND, "code": code})
	for i in 10:
		placements.append({"player": 0, "location": LOCATION_DECK, "code": 15025844})
	return {
		"seed": [20261006, 1, 2, 3],
		"players": [{"start_draw": 0}, {"start_draw": 0, "draw_per_turn": 0}],
		"placements": placements,
	}
