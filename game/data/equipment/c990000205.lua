-- 魔導書籤：裝備（驗證用）
-- 只能裝給魔法卡。裝備的那張魔法卡發動時不花 AP。
local s,id=GetID()

s.ygopve={
	name="魔導書籤", kind="equip",
	text="【裝備】只能裝給魔法卡。這張卡的發動不花費 AP。",
	requires={type=TYPE_SPELL},
	ap_free={"activate"},
}

function s.initial_effect(c)
	YgoSupport.Equip(c)
end
