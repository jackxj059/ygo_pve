-- 雙擊徽章：裝備（驗證用）
-- 裝備的怪獸給予對手的戰鬥傷害變成 2 倍（玩家 LP 與敵人 HP 都適用）。
-- 「對手」是這張卡當下控制者的對手：控制權轉移時跟著卡（2026-10-07 決定）。
-- 用核心的 EFFECT_CHANGE_BATTLE_DAMAGE，倍傷、減半、固定值的組合照核心規則處理，只套用一次。
local s,id=GetID()

s.ygopve={
	name="雙擊徽章", kind="equip",
	text="【裝備】這張卡給予對手的戰鬥傷害變成 2 倍。",
}

function s.initial_effect(c)
	YgoSupport.Equip(c,s.install)
end

function s.install(tc)
	local e1=Effect.CreateEffect(tc)
	e1:SetType(EFFECT_TYPE_SINGLE)
	e1:SetProperty(YgoSupport.RULE)
	e1:SetCode(EFFECT_CHANGE_BATTLE_DAMAGE)
	e1:SetValue(function(e,damp) return damp~=e:GetHandlerPlayer() and DOUBLE_DAMAGE or -1 end)
	tc:RegisterEffect(e1)
end
