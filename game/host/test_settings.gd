extends RefCounted
## TEST VALUES ONLY - not balance decisions. AP numbers (D02) and the building point cap (D07)
## are still open; the battle module and screen take whatever the host passes in.

## Player AP rules for test battles: refill to max at the start of the player's own turn.
const AP := {
	"max": 3,
	"initial": 3,
	"costs": {"summon": 1, "spsummon": 1, "set": 1, "activate": 1, "attack": 1, "repos": 1},
}

## Building point cap for "legal deck" test battles, and the points table version used.
const BUILD_POINT_CAP := 100
const POINTS_TABLE := "res://data/points/genesys-tcg-2026-10-06.json"

## Items and equipment the test host hands out (test data, no drops or crafting yet).
## Items: consumables, used from the main phase command (count = uses).
const ITEMS := [
	{"code": 990000303, "count": 2}, # 回復藥
	{"code": 990000301, "count": 1}, # 回收之鈴
	{"code": 990000302, "count": 1}, # 墓地回收網
]
## Equipment: pieces that can be fixed to cards before a deck battle.
const EQUIPMENT := {
	990000201: 2, # 省力徽章: activations of that card cost no AP
	990000202: 1, # 雙擊徽章: double battle damage
	990000203: 1, # 回復徽章: +1000 LP after its effect resolves successfully
}
