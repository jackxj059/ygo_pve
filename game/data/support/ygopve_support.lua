-- YGO PvE items and equipment (technical validation stage, docs/items.md). The battle module loads
-- this file into every duel that has item or equipment definitions, after utility.lua.
--
-- Both are cards for the core: the module creates each one in its owner's hand, and at the start
-- of the duel this file sets it up and takes it out of the duel (like EDOPro skills), so it is
-- never in a zone, never drawn and never seen as a hand card.
--
-- Item: a player-level continuous effect on EVENT_FREE_CHAIN. When the player picks it from the
-- main phase command, the core runs it at once (no chain, nothing to respond to), and what it
-- does - moving cards, gaining LP - is a normal core action whose triggers follow as usual.
-- The core also lists such effects in chain windows; the module drops item options from every
-- prompt but the main phase command, and the condition below keeps them to the owner's own main
-- phase with no chain building or resolving.
--
-- Equipment: the module binds each equipment card to one card instance (YgoSupport.Bind) before
-- the duel starts; at the start its install function registers effects on that card. Those
-- effects belong to that card object for the whole duel (zone moves, set, revived), so same-name
-- copies are not affected. Equipment effects cannot be negated or copied (decided 2026-10-07)
-- and follow the card: its current controller benefits (decided 2026-10-07).

YgoSupport = {}

YgoSupport.RULE = EFFECT_FLAG_CANNOT_DISABLE | EFFECT_FLAG_UNCOPYABLE

local bound = {} -- equipment card id -> target card id

function YgoSupport.Bind(self_id, target_id)
	bound[self_id] = target_id
end

-- Runs once at the start of the duel for a card created in its owner's hand.
local function at_startup(c, op)
	local e1 = Effect.CreateEffect(c)
	e1:SetType(EFFECT_TYPE_FIELD | EFFECT_TYPE_CONTINUOUS)
	e1:SetProperty(YgoSupport.RULE)
	e1:SetCode(EVENT_STARTUP)
	e1:SetRange(LOCATION_HAND)
	e1:SetOperation(function(e)
		local h = e:GetHandler()
		op(h, h:GetOwner())
		Duel.SendtoDeck(h, h:GetOwner(), -2, REASON_RULE) -- out of the duel
		e:Reset()
	end)
	c:RegisterEffect(e1)
end

local RESULTS = {success = true, partial = true, nochange = true, cancel = true}

-- condition(e, tp) -> bool: whether the item can be used now (beyond the window rules).
-- operation(e, tp) -> "success" | "partial" | "nochange" | "cancel" (nil = "success").
function YgoSupport.Item(c, condition, operation)
	at_startup(c, function(item, tp)
		local use = Effect.CreateEffect(item)
		use:SetType(EFFECT_TYPE_FIELD | EFFECT_TYPE_CONTINUOUS)
		use:SetProperty(YgoSupport.RULE)
		use:SetCode(EVENT_FREE_CHAIN)
		use:SetCondition(function(e)
			return Duel.GetTurnPlayer() == tp and Duel.IsMainPhase() and Duel.GetCurrentChain() == 0
				and (not condition or condition(e, tp))
		end)
		use:SetOperation(function(e)
			local result = operation(e, tp) or "success"
			if not RESULTS[result] then error("item " .. item:GetOriginalCode() .. " returned '" .. tostring(result) .. "'") end
			Debug.Message(string.format("YGOPVE_ITEM %d %d %s", item:GetCardID(), item:GetOriginalCode(), result))
		end)
		Duel.RegisterEffect(use, tp)
	end)
end

-- install(target, owner, equipment) registers the equipment's effects on the target card.
-- Equipment without effects in the core (for example only ap_free, which the module applies)
-- passes no install function.
function YgoSupport.Equip(c, install)
	at_startup(c, function(eq, tp)
		local id = bound[eq:GetCardID()]
		local target = id and Duel.GetCardFromCardID(id)
		if not target then error("equipment " .. eq:GetOriginalCode() .. " is not bound to a card") end
		if install then install(target, tp, eq) end
	end)
end

-- Cards the shuffle-into-deck items may pick: able to return to the deck (the core's own check,
-- so "cannot return to the deck" effects are respected) and, when banished, face-up only
-- (decided for the first version).
function YgoSupport.CanShuffle(c)
	return c:IsAbleToDeck() and (not c:IsLocation(LOCATION_REMOVED) or c:IsFaceup())
end

-- Shared item operation: the player picks n of their own cards in `location` that can return to
-- the deck, and they are shuffled into the deck. Cancelling the pick changes nothing. Extra Deck
-- monsters count and go back to the Extra Deck (TEST SETTING, not decided).
function YgoSupport.ShuffleIntoDeck(tp, location, n)
	local g = Duel.GetMatchingGroup(YgoSupport.CanShuffle, tp, location, 0, nil)
	if #g < n then return "nochange" end
	Duel.Hint(HINT_SELECTMSG, tp, HINTMSG_TODECK)
	local sg = g:Select(tp, n, n, true, nil)
	if not sg or #sg == 0 then return "cancel" end
	Duel.SendtoDeck(sg, nil, SEQ_DECKSHUFFLE, REASON_EFFECT)
	-- Count what really arrived (a destination can be replaced by other effects).
	local arrived = Duel.GetOperatedGroup():FilterCount(Card.IsLocation, nil, LOCATION_DECK | LOCATION_EXTRA)
	if arrived == 0 then return "nochange" end
	return arrived < n and "partial" or "success"
end
