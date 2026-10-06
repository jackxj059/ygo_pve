-- 訓練用稻草人：測試用敵人（數值為測試值），示範自訂 HP。
-- 沒有效果，也沒有行動模式（s.ai），由 YgoEnemy.DefaultDecide 決定行動。
local s,id=GetID()

s.ygopve_enemy={
	name="訓練用稻草人",
	text="【敵人】HP 由定義指定（1500），不是攻擊力加守備力。",
	atk=500, def=500, level=1, race=RACE_PLANT, attribute=ATTRIBUTE_EARTH,
	hp=1500,   -- 沒寫時為攻擊力加守備力（這裡會是 1000）
}

function s.initial_effect(c)
	YgoEnemy.Init(c)
end
