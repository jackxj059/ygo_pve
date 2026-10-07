-- 勇士之證：裝備（驗證用，數值為測試值）
-- 只能裝給等級 5 以上的戰士族怪獸（超量怪獸的階級視為等級；連結怪獸不行）。
-- 裝備的怪獸攻擊力上升 500。
local s,id=GetID()

s.ygopve={
	name="勇士之證", kind="equip",
	text="【裝備】只能裝給 5 星以上的戰士族怪獸。這張卡的攻擊力上升 500。",
	requires={min_level=5, race=RACE_WARRIOR},
}

function s.initial_effect(c)
	YgoSupport.Equip(c,s.install)
end

function s.install(tc)
	local e1=Effect.CreateEffect(tc)
	e1:SetType(EFFECT_TYPE_SINGLE)
	e1:SetProperty(YgoSupport.RULE|EFFECT_FLAG_SINGLE_RANGE)
	e1:SetRange(LOCATION_MZONE)
	e1:SetCode(EFFECT_UPDATE_ATTACK)
	e1:SetValue(500)
	tc:RegisterEffect(e1)
end
