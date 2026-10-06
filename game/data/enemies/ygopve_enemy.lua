-- YGO PvE enemy units (technical prototype). The battle module loads this file into every duel
-- that has enemy definitions, right after utility.lua; enemy card scripts call YgoEnemy.Init(c).
--
-- An enemy is a monster card with HP; the enemy side has no LP. Rules decided so far
-- (docs/enemies.md):
--   * HP starts at the printed ATK + DEF (test rule). Later ATK/DEF changes never change the cap.
--   * Attacked in defense position, attacker ATK > DEF: the enemy loses the difference in HP
--     instead of being destroyed; at HP 0 it is destroyed by battle (normal battle destruction).
--     ATK = DEF and ATK < DEF follow the normal rules (no damage / attacker's controller takes it).
--   * Attacked in attack position: the enemy's ATK is not compared (decided 2026-10-06). It counts
--     as 0 during that damage step, so the attacker is not destroyed, its controller takes no
--     damage, and the enemy loses the attacker's ATK in HP; at HP 0 it is destroyed by battle.
--   * The enemy attacks a monster in attack position (decided 2026-10-06): equal ATK - the other
--     monster is destroyed as usual and the enemy loses that monster's ATK in HP; lower ATK - the
--     enemy loses the difference in HP. Either way it is destroyed by battle only at HP 0.
--     Attacking a defense-position monster with a higher DEF is not decided (normal rules: the
--     enemy side takes no damage, so no HP is lost).
--   * Effect damage to the enemy side goes to an enemy's HP; at HP 0 it is destroyed by effect.
--   * Removal effects (destroy, send to GY, banish...) work on enemies as on any monster.
-- Rule effects cannot be negated or copied, so negating an enemy's effects leaves its HP rules.
-- HP is reported to the host as Debug.Message("YGOPVE_HP <card id> <code> <hp> <max>").

YgoEnemy = {}

local hp, maxhp, pending = {}, {}, {} -- by Card.GetCardID()
-- Enemy cards (set). During initial_effect the core has not yet assigned the card id or the
-- owner, so everything per side is set up at the start of the duel.
local units = {}
local sides = {} -- player -> LP kept fixed for the enemy side

local RULE = EFFECT_FLAG_CANNOT_DISABLE | EFFECT_FLAG_UNCOPYABLE

local function ensure(c)
	local id = c:GetCardID()
	if not hp[id] then
		maxhp[id] = math.max(c:GetTextAttack(), 0) + math.max(c:GetTextDefense(), 0)
		hp[id] = maxhp[id]
	end
	return id
end

local function report(c)
	local id = ensure(c)
	Debug.Message(string.format("YGOPVE_HP %d %d %d %d", id, c:GetOriginalCode(), hp[id], maxhp[id]))
end

-- Value of EFFECT_INDESTRUCTABLE_BATTLE, asked by the core at damage calculation with the card
-- battling the enemy. The loss is recorded here because this is the moment the core decides
-- destruction with these exact ATK/DEF values; it is applied after damage calculation.
-- ponytail: a second check in the same damage step overwrites the record with the same values.
function YgoEnemy.SurvivesBattle(e, opponent)
	local c = e:GetHandler()
	local id = ensure(c)
	local loss
	if Duel.GetAttacker() == c then -- the enemy attacked and would lose this battle
		local diff = opponent:GetAttack() - c:GetAttack()
		loss = opponent:IsAttackPos() and (diff > 0 and diff or opponent:GetAttack()) or 0
	elseif c:IsDefensePos() then
		loss = opponent:GetAttack() - c:GetDefense()
	else -- attacked in attack position: its ATK counts as 0
		loss = opponent:GetAttack()
	end
	if loss <= 0 then return true end
	pending[id] = loss
	return loss < hp[id]
end

local function apply_battle(e)
	local c = e:GetHandler()
	local id = c:GetCardID()
	local loss = pending[id]
	pending[id] = nil
	if not loss or not c:IsLocation(LOCATION_MZONE) then return end -- destroyed: reported on leaving
	hp[id] = math.max(hp[id] - loss, 0)
	report(c)
end

local function leave_field(e)
	local c = e:GetHandler()
	local id = c:GetCardID()
	if not hp[id] then return end
	if hp[id] > 0 then
		hp[id] = 0
		report(c)
	end
	hp[id], maxhp[id], pending[id] = nil, nil, nil -- back on the field later = a new unit
end

-- Test rule: with several enemies, effect damage goes to the one in the lowest zone (not decided).
local function damage_target(p)
	local g = Duel.GetMatchingGroup(function(c) return units[c] and c:IsFaceup() end, p, LOCATION_MZONE, 0, nil)
	local best
	for c in g:Iter() do
		if not best or c:GetSequence() < best:GetSequence() then best = c end
	end
	return best
end

local function effect_damage(e, tp, eg, ep, ev, re, r, rp)
	local p = e:GetLabel()
	Duel.SetLP(p, sides[p]) -- the enemy side has no LP
	local c = damage_target(p)
	if not c then return end
	local id = ensure(c)
	if hp[id] == 0 then return end
	hp[id] = math.max(hp[id] - ev, 0)
	report(c)
	if hp[id] == 0 then
		Duel.Destroy(c, REASON_EFFECT, LOCATION_GRAVE, rp)
	end
end

local function register_side(p)
	if sides[p] then return end
	sides[p] = Duel.GetLP(p)
	local e1 = Effect.GlobalEffect()
	e1:SetType(EFFECT_TYPE_FIELD)
	e1:SetProperty(EFFECT_FLAG_PLAYER_TARGET | RULE)
	e1:SetCode(EFFECT_CANNOT_LOSE_LP)
	e1:SetTargetRange(1, 0)
	Duel.RegisterEffect(e1, p)
	local e2 = e1:Clone()
	e2:SetCode(EFFECT_AVOID_BATTLE_DAMAGE) -- piercing and direct attacks: no LP to hit
	Duel.RegisterEffect(e2, p)
	local e3 = Effect.GlobalEffect()
	e3:SetType(EFFECT_TYPE_FIELD | EFFECT_TYPE_CONTINUOUS)
	e3:SetProperty(RULE)
	e3:SetCode(EVENT_DAMAGE)
	e3:SetLabel(p)
	e3:SetCondition(function(e, tp, eg, ep, ev, re, r) return ep == p and r & REASON_EFFECT ~= 0 end)
	e3:SetOperation(effect_damage)
	Duel.RegisterEffect(e3, p)
end

local startup = Effect.GlobalEffect()
startup:SetType(EFFECT_TYPE_FIELD | EFFECT_TYPE_CONTINUOUS)
startup:SetCode(EVENT_STARTUP)
startup:SetOperation(function()
	for c in pairs(units) do
		register_side(c:GetOwner())
		if c:IsLocation(LOCATION_MZONE) then report(c) end
	end
end)
Duel.RegisterEffect(startup, 0)

-- The enemy is the attack target in attack position, from the start of the damage step.
local function attacked_in_attack_pos(e)
	local c = e:GetHandler()
	local ph = Duel.GetCurrentPhase()
	return (ph == PHASE_DAMAGE or ph == PHASE_DAMAGE_CAL) and c:IsAttackPos() and Duel.GetAttackTarget() == c
end

function YgoEnemy.Init(c)
	units[c] = true
	local e1 = Effect.CreateEffect(c)
	e1:SetType(EFFECT_TYPE_SINGLE)
	e1:SetProperty(EFFECT_FLAG_SINGLE_RANGE | RULE)
	e1:SetRange(LOCATION_MZONE)
	e1:SetCode(EFFECT_INDESTRUCTABLE_BATTLE)
	-- (only asked in battles involving this card; SurvivesBattle covers every case)
	e1:SetValue(YgoEnemy.SurvivesBattle)
	c:RegisterEffect(e1)
	local e0 = Effect.CreateEffect(c)
	e0:SetType(EFFECT_TYPE_SINGLE)
	e0:SetProperty(EFFECT_FLAG_SINGLE_RANGE | RULE)
	e0:SetRange(LOCATION_MZONE)
	e0:SetCode(EFFECT_SET_ATTACK_FINAL)
	e0:SetCondition(attacked_in_attack_pos)
	e0:SetValue(0)
	c:RegisterEffect(e0)
	local e2 = Effect.CreateEffect(c)
	e2:SetType(EFFECT_TYPE_SINGLE | EFFECT_TYPE_CONTINUOUS)
	e2:SetProperty(RULE)
	e2:SetCode(EVENT_BATTLED)
	e2:SetOperation(apply_battle)
	c:RegisterEffect(e2)
	local e3 = e2:Clone()
	e3:SetCode(EVENT_LEAVE_FIELD)
	e3:SetOperation(leave_field)
	c:RegisterEffect(e3)
end

-- Enemy decisions ---------------------------------------------------------------------------
-- When the enemy side has to answer a prompt, the battle module runs
--   YgoEnemy.Decide(prompt)
-- inside the core's Lua state while the core waits. The core does not allow actions there
-- (Duel.Destroy etc. raise "Action is not allowed here."), so decisions can only look at the duel.
--
-- prompt = {type = "SELECT_IDLECMD" | "SELECT_BATTLECMD" | "SELECT_CHAIN" | "SELECT_CARD" | ...,
--           player, min, max, value, forced, cancelable, desc,
--           card = Card (subject of SELECT_EFFECTYN / SELECT_POSITION) or nil,
--           options = {{action, code, card = Card or nil, controller, location, sequence,
--                       position, desc, param}, ...}}
-- An enemy script answers in s.ai(c, prompt), c being that enemy's card: return one option index
-- (1-based), a list of indices for multi-pick prompts, or nil/false to leave it to the next enemy and
-- finally to YgoEnemy.DefaultDecide.

-- Index of the first option with this action (and card, if given), or nil.
function YgoEnemy.Find(prompt, action, card)
	for i, o in ipairs(prompt.options) do
		if o.action == action and (not card or o.card == card) then return i end
	end
end

-- Index of the option whose card scores highest (score(card) -> number), or nil.
function YgoEnemy.Best(prompt, score)
	local best, best_score
	for i, o in ipairs(prompt.options) do
		if o.card then
			local v = score(o.card)
			if not best or v > best_score then best, best_score = i, v end
		end
	end
	return best
end

function YgoEnemy.GetHP(c)
	local id = ensure(c)
	return hp[id], maxhp[id]
end

-- Fallback for prompts no enemy script answered (TEST RULE): go to battle and attack with the
-- first monster that can, never activate optional effects, take the first legal choice otherwise.
function YgoEnemy.DefaultDecide(prompt)
	local t = prompt.type
	if t == "SELECT_IDLECMD" then
		return YgoEnemy.Find(prompt, "battle") or YgoEnemy.Find(prompt, "end")
	elseif t == "SELECT_BATTLECMD" then
		return YgoEnemy.Find(prompt, "attack") or YgoEnemy.Find(prompt, "end")
	elseif t == "SELECT_CHAIN" then
		return prompt.forced and 1 or YgoEnemy.Find(prompt, "pass")
	elseif t == "SELECT_EFFECTYN" or t == "SELECT_YESNO" then
		return YgoEnemy.Find(prompt, "no")
	elseif t == "SORT_CARD" then
		return {} -- the core's default order
	end
	local picks = {}
	for i = 1, math.max(prompt.min or 1, 1) do picks[i] = i end
	return picks
end

-- Which enemies get asked, in order: the card the prompt is about (the effect being activated or
-- resolved, the attacker), then every face-up enemy on the field from the left.
local function deciders(prompt)
	local list, seen = {}, {}
	local function add(c)
		if c and units[c] and not seen[c] then
			seen[c] = true
			list[#list + 1] = c
		end
	end
	local ch = Duel.GetCurrentChain()
	if ch > 0 then
		local te = Duel.GetChainInfo(ch, CHAININFO_TRIGGERING_EFFECT)
		if te then add(te:GetHandler()) end
	end
	add(Duel.GetAttacker())
	add(prompt.card)
	local g = Duel.GetFieldGroup(prompt.player, LOCATION_MZONE, 0):Filter(Card.IsFaceup, nil)
	local cards = {}
	for c in g:Iter() do cards[#cards + 1] = c end
	table.sort(cards, function(a, b) return a:GetSequence() < b:GetSequence() end)
	for _, c in ipairs(cards) do add(c) end
	return list
end

function YgoEnemy.Decide(prompt)
	for _, o in ipairs(prompt.options) do
		if o.cardid then o.card = Duel.GetCardFromCardID(o.cardid) end
	end
	if prompt.cardid then prompt.card = Duel.GetCardFromCardID(prompt.cardid) end
	local answer
	for _, c in ipairs(deciders(prompt)) do
		local s = c:GetMetatable()
		if s and s.ai then answer = s.ai(c, prompt) end
		if answer then break end -- nil or false: no opinion
	end
	if not answer then answer = YgoEnemy.DefaultDecide(prompt) end
	if type(answer) == "number" then answer = {answer} end
	local zero_based = {}
	for i, v in ipairs(answer) do zero_based[i] = tostring(math.tointeger(v) - 1) end
	Debug.Message("YGOPVE_ANSWER " .. table.concat(zero_based, " "))
end
