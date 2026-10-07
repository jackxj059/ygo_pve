-- 省力徽章：裝備（驗證用）
-- 裝備的那一張卡發動時不花 AP。由戰鬥模組的 AP 計價處理（ap_free），核心內沒有效果。
local s,id=GetID()

s.ygopve={
	name="省力徽章", kind="equip",
	text="【裝備】這張卡的發動不花費 AP。",
	ap_free={"activate"},
}

function s.initial_effect(c)
	YgoSupport.Equip(c)
end
