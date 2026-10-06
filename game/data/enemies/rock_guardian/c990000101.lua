-- 岩盤強化：岩殼守衛的技能（一般魔法，數值為測試值）
-- 技能不會消耗：處理完不進墓地，回到敵方手牌（YgoEnemy.InitSkill）。
local s,id=GetID()

s.ygopve_enemy={
	name="岩盤強化", kind="spell", spell="normal",
	text="【技能】自己場上的怪獸攻擊力直到回合結束時上升500。",
}

function s.initial_effect(c)
	YgoEnemy.InitSkill(c)
	local e1=Effect.CreateEffect(c)
	e1:SetCategory(CATEGORY_ATKCHANGE)
	e1:SetType(EFFECT_TYPE_ACTIVATE)
	e1:SetCode(EVENT_FREE_CHAIN)
	e1:SetTarget(s.target)
	e1:SetOperation(s.activate)
	c:RegisterEffect(e1)
end

function s.target(e,tp,eg,ep,ev,re,r,rp,chk)
	if chk==0 then return Duel.IsExistingMatchingCard(Card.IsFaceup,tp,LOCATION_MZONE,0,1,nil) end
end

function s.activate(e,tp,eg,ep,ev,re,r,rp)
	for tc in Duel.GetMatchingGroup(Card.IsFaceup,tp,LOCATION_MZONE,0,nil):Iter() do
		local e1=Effect.CreateEffect(e:GetHandler())
		e1:SetType(EFFECT_TYPE_SINGLE)
		e1:SetCode(EFFECT_UPDATE_ATTACK)
		e1:SetValue(500)
		e1:SetReset(RESET_EVENT|RESETS_STANDARD|RESET_PHASE|PHASE_END)
		tc:RegisterEffect(e1)
	end
end
