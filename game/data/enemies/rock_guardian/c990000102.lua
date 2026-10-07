-- 重壓結界：岩殼守衛的技能（永續魔法）
-- 留在魔陷區持續生效；被拆掉時不進墓地，回到敵方手牌，之後可以再放（YgoEnemy.InitSkill）。
-- 單位死亡後繼續留在場上。
local s,id=GetID()

s.ygopve={
	name="重壓結界", kind="spell", spell="continuous",
	text="【技能】只要這張卡在魔法與陷阱區域存在，對手不能發動陷阱卡。",
}

function s.initial_effect(c)
	YgoEnemy.InitSkill(c)
	local e1=Effect.CreateEffect(c)
	e1:SetType(EFFECT_TYPE_ACTIVATE)
	e1:SetCode(EVENT_FREE_CHAIN)
	c:RegisterEffect(e1)
	-- 對手不能發動陷阱卡
	local e2=Effect.CreateEffect(c)
	e2:SetType(EFFECT_TYPE_FIELD)
	e2:SetCode(EFFECT_CANNOT_ACTIVATE)
	e2:SetProperty(EFFECT_FLAG_PLAYER_TARGET)
	e2:SetRange(LOCATION_SZONE)
	e2:SetTargetRange(0,1)
	e2:SetValue(function(e,re,tp) return re:IsHasType(EFFECT_TYPE_ACTIVATE) and re:IsActiveType(TYPE_TRAP) end)
	c:RegisterEffect(e2)
end
