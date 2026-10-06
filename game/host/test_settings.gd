extends RefCounted
## TEST VALUES ONLY - not balance decisions. AP numbers (D02) are still open; the battle module
## and screen take whatever the host passes in.

## Player AP rules for test battles: refill to max at the start of the player's own turn.
const AP := {
	"max": 3,
	"initial": 3,
	"costs": {"summon": 1, "spsummon": 1, "set": 1, "activate": 1, "attack": 1, "repos": 1},
}

