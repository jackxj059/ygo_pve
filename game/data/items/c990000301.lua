-- 回收之鈴：道具（驗證用，數值為測試值）
-- 自己回合的主要階段，從自己除外區選 5 張表側卡洗回牌組（裡側除外的卡不能選）。不開連鎖。
local s,id=GetID()

s.ygopve={
	name="回收之鈴", kind="item",
	text="【道具】從自己的除外區選 5 張表側表示的卡洗回牌組。",
}

function s.initial_effect(c)
	YgoSupport.Item(c,s.condition,s.operation)
end

function s.condition(e,tp)
	return Duel.IsExistingMatchingCard(YgoSupport.CanShuffle,tp,LOCATION_REMOVED,0,5,nil)
end

function s.operation(e,tp)
	return YgoSupport.ShuffleIntoDeck(tp,LOCATION_REMOVED,5)
end
