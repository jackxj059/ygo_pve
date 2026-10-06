-- 岩殼守衛：敵人技術原型（數值為測試值）
-- 同一個檔案有兩個用途：
--   s.ygopve_enemy   戰鬥模組在建立決鬥前讀取，作為核心的卡片資料（不需要卡片資料庫）
--   s.initial_effect 核心照一般卡片腳本執行
local s,id=GetID()

s.ygopve_enemy={
	name="岩殼守衛",
	text="【敵人】HP＝原本攻擊力＋守備力。\n1回合1次，自己或對手回合：以對手場上1隻表側怪獸為對象才能發動。那隻怪獸的攻擊力直到回合結束時下降800。",
	atk=1200, def=2000, level=4, race=RACE_ROCK, attribute=ATTRIBUTE_EARTH,
}

function s.initial_effect(c)
	YgoEnemy.Init(c)
	-- 1回合1次，自己或對手回合：對手1隻表側怪獸攻擊力下降800（可被連鎖、無效）
	local e1=Effect.CreateEffect(c)
	e1:SetCategory(CATEGORY_ATKCHANGE)
	e1:SetType(EFFECT_TYPE_QUICK_O)
	e1:SetCode(EVENT_FREE_CHAIN)
	e1:SetProperty(EFFECT_FLAG_CARD_TARGET)
	e1:SetRange(LOCATION_MZONE)
	e1:SetCountLimit(1)
	e1:SetHintTiming(0,TIMINGS_CHECK_MONSTER)
	e1:SetTarget(s.target)
	e1:SetOperation(s.operation)
	c:RegisterEffect(e1)
end

function s.target(e,tp,eg,ep,ev,re,r,rp,chk,chkc)
	if chkc then return chkc:IsLocation(LOCATION_MZONE) and chkc:IsControler(1-tp) and chkc:IsFaceup() end
	if chk==0 then return Duel.IsExistingTarget(Card.IsFaceup,tp,0,LOCATION_MZONE,1,nil) end
	Duel.Hint(HINT_SELECTMSG,tp,HINTMSG_FACEUP)
	Duel.SelectTarget(tp,Card.IsFaceup,tp,0,LOCATION_MZONE,1,1,nil)
end

function s.operation(e,tp,eg,ep,ev,re,r,rp)
	local tc=Duel.GetFirstTarget()
	if tc and tc:IsRelateToEffect(e) and tc:IsFaceup() then
		local e1=Effect.CreateEffect(e:GetHandler())
		e1:SetType(EFFECT_TYPE_SINGLE)
		e1:SetCode(EFFECT_UPDATE_ATTACK)
		e1:SetValue(-800)
		e1:SetReset(RESET_EVENT|RESETS_STANDARD|RESET_PHASE|PHASE_END)
		tc:RegisterEffect(e1)
	end
end

-- 行動模式：輪到敵方選擇時由戰鬥模組呼叫（docs/enemies.md「敵人的行動」）。
-- 只能查詢場面，不能直接操作；回傳選項索引（從 1 開始），回傳 nil 交給預設行為。
--   自己的回合：能發動效果就發動；HP 高於一半時轉攻擊表示並攻擊攻擊力最低的怪獸，
--             HP 一半以下時轉守備表示、不攻擊。
--   對手的回合：自己被攻擊時，發動效果降低攻擊怪獸的攻擊力（減少損失的 HP）。
function s.ai(c,prompt)
	local F=YgoEnemy.Find
	local hp,max=YgoEnemy.GetHP(c)
	local healthy=hp*2>max
	if prompt.type=="SELECT_IDLECMD" then
		local wrong_pos=(healthy and c:IsDefensePos()) or (not healthy and c:IsAttackPos())
		return F(prompt,"activate",c)
			or (wrong_pos and F(prompt,"repos",c))
			or (c:IsAttackPos() and F(prompt,"battle"))
			or F(prompt,"end")
	elseif prompt.type=="SELECT_BATTLECMD" then
		return F(prompt,"attack",c) or F(prompt,"end")
	elseif prompt.type=="SELECT_CHAIN" then
		local a=Duel.GetAttacker()
		if a and Duel.GetAttackTarget()==c then return F(prompt,"activate",c) end
		return F(prompt,"pass")
	elseif prompt.type=="SELECT_CARD" then
		if Duel.GetCurrentChain()>0 then
			-- 效果的對象：正在攻擊的怪獸，否則攻擊力最高的怪獸
			local a=Duel.GetAttacker()
			for i,o in ipairs(prompt.options) do
				if o.card==a then return i end
			end
			return YgoEnemy.Best(prompt,function(tc) return tc:GetAttack() end)
		end
		-- 攻擊對象：攻擊力最低的怪獸
		return YgoEnemy.Best(prompt,function(tc) return -tc:GetAttack() end)
	end
end
