-- 墓地回收網：道具（驗證用，數值為測試值）
-- 自己回合的主要階段，從自己墓地選 5 張卡洗回牌組。不開連鎖。
local s,id=GetID()

s.ygopve={
	name="墓地回收網", kind="item",
	text="【道具】從自己的墓地選 5 張卡洗回牌組。",
}

function s.initial_effect(c)
	YgoSupport.Item(c,s.condition,s.operation)
end

function s.condition(e,tp)
	return Duel.IsExistingMatchingCard(YgoSupport.CanShuffle,tp,LOCATION_GRAVE,0,5,nil)
end

function s.operation(e,tp)
	return YgoSupport.ShuffleIntoDeck(tp,LOCATION_GRAVE,5)
end
