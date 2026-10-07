-- 回復徽章：裝備（驗證用，數值為測試值）
-- 裝備的那一張卡的效果「成功處理」後，這張卡當下的控制者回復 1000 LP
-- （控制權轉移時跟著卡，2026-10-07 決定）。
--
-- 「成功」的判定（有限支援，docs/items.md）：同一個連鎖鏈結中，
--   * 發動沒有被無效（核心送出 CHAIN_NEGATED 時不算）
--   * 效果沒有被無效（核心送出 CHAIN_DISABLED 時不算，雖然之後仍會送出 CHAIN_SOLVED）
--   * 開始處理時，取對象的效果的每個對象都還在（還和這次效果有關聯）
--   * 發動的魔法、陷阱開始處理時仍在場上
-- 處理內容本身是否「做到了」（例如要檢索卡卻沒有可檢索的卡）、部分完成與延遲效果，無法通用判定。
local s,id=GetID()

s.ygopve={
	name="回復徽章", kind="equip",
	text="【裝備】這張卡的效果成功處理後，控制這張卡的玩家回復 1000 LP。",
}

function s.initial_effect(c)
	YgoSupport.Equip(c,s.install)
end

function s.install(tc,owner)
	local state={} -- chain link number -> "ok" / "target" / "disabled"
	local function mine(re) return re and re:GetHandler()==tc end
	local function on(code,op)
		local e=Effect.CreateEffect(tc)
		e:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS)
		e:SetProperty(YgoSupport.RULE)
		e:SetCode(code)
		e:SetOperation(function(e,tp,eg,ep,ev,re) if mine(re) then op(ev,re) end end)
		Duel.RegisterEffect(e,owner)
	end
	on(EVENT_CHAIN_SOLVING,function(ev,re)
		local ok=true
		if re:IsHasProperty(EFFECT_FLAG_CARD_TARGET) then
			local tg=Duel.GetChainInfo(ev,CHAININFO_TARGET_CARDS)
			ok=tg~=nil and #tg>0 and tg:FilterCount(Card.IsRelateToEffect,nil,re)==#tg
		end
		if re:IsHasType(EFFECT_TYPE_ACTIVATE) and not tc:IsRelateToEffect(re) then ok=false end
		state[ev]=ok and "ok" or "target"
	end)
	on(EVENT_CHAIN_DISABLED,function(ev) state[ev]="disabled" end)
	on(EVENT_CHAIN_NEGATED,function(ev) state[ev]=nil end)
	on(EVENT_CHAIN_SOLVED,function(ev)
		local st=state[ev]
		state[ev]=nil
		if st=="ok" then Duel.Recover(tc:GetControler(),1000,REASON_EFFECT) end
	end)
end
