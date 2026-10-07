-- 回復藥：道具（驗證用，數值為測試值）
-- 自己回合的主要階段，自己回復 1000 LP。不開連鎖。
-- 「指定玩家」目前固定為使用者自己（測試設定）。
local s,id=GetID()

s.ygopve={
	name="回復藥", kind="item",
	text="【道具】自己回復 1000 LP。",
}

function s.initial_effect(c)
	YgoSupport.Item(c,nil,s.operation)
end

function s.operation(e,tp)
	-- 回復被改成傷害、或不能回復時，核心照原規則處理；這裡只看 LP 有沒有增加。
	return Duel.Recover(tp,1000,REASON_EFFECT)>0 and "success" or "nochange"
end
