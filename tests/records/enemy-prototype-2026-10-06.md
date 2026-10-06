# Lua 自訂敵人技術原型測試紀錄（2026-10-06）

範圍：用 Lua 定義一隻敵人，沿用核心的攻擊、效果與連鎖流程。規則與對應關係見 `docs/enemies.md`。HP 初始值等數值都是**測試值**。

## 這次確認的決策

- **敵方不是玩家**：敵方沒有 LP，HP 屬於每一隻怪獸，HP 歸零就代表該單位死亡。
- **戰鬥中 HP 歸零**：算戰鬥破壞。
- **用效果移除**：落雷、送墓等效果移除敵人，算效果破壞，不看 HP。
- **給予敵方的效果傷害**：改扣敵人的 HP。

## 指令與結果

```powershell
powershell -ExecutionPolicy Bypass -File scripts/test-duel.ps1 -Build
```

結果是 `34/34 scenarios behaved as expected`（後來加入敵人自動行動與攻擊表示規則後的最終結果；最初的原型是 30/30）：

- **原有測試**：25 項，維持通過，包含 AP 和構築點數的測試。
- **新增敵人情境**：9 個（原型 5 個，加上 `enemy_ai_turn`、`enemy_ai_defend`、`enemy_attack_pos`、`enemy_attacks`）。
- **Godot 規則測試**：原本就算在 25 項裡，這次在裡面新增 4 項敵人相關的檢查。

## 驗收

| 驗收項目 | 情境 | 結果 |
| --- | --- | --- |
| 1. 玩家可以攻擊敵人，也能用卡片效果選取它 | `enemy_defense_hp`、`enemy_turn`、`enemy_negated_rules` | 攻擊時可以選敵人為攻擊對象；無限泡影可以選敵人為對象 |
| 2. 敵人透過核心發動效果，玩家可以連鎖並無效 | `enemy_turn` | 連鎖的處理順序是無限泡影、岩殼守衛，紀錄中顯示 `link 1 effect negated`；神秘精靈的攻擊力沒有下降，所以受到的傷害是 400 |
| 3. 敵人攻擊沿用核心的攻擊宣告與回應窗口，不消耗 AP | `enemy_turn` | 攻擊宣告後，玩家得到連鎖窗口；玩家的 AP 在敵人攻擊前後都是 2 |
| 4. 守備時扣血的規則 | `enemy_defense_hp` | 攻擊力 1400 小於守備力 2000：玩家受到 600 傷害；2000 等於 2000：沒有傷害；3000 大於 2000：HP 從 3200 變成 2200 |
| 5. HP 沒有歸零時，不會被破壞、送墓或離場 | `enemy_defense_hp`、`enemy_negated_rules` | 敵人仍在場上、墓地 0 張，也沒有任何破壞紀錄 |
| 6. HP 歸零只結算一次，並記錄處理方式 | `enemy_defense_hp`、`enemy_effect_kill` | 戰鬥中歸零：`reason=0x21`，也就是戰鬥破壞；效果傷害歸零：`reason=0x41`，也就是效果破壞。兩種情況都只送墓一次，HP 0 也只回報一次 |
| 7. 永續加攻、加防由核心處理，HP 上限不變 | `enemy_defense_hp` | 發動荒野後守備力變成 2200，同樣 3000 攻擊只扣 800；HP 上限維持 3200 |
| 8. 原有的 AP、牌組與決鬥測試維持通過 | 全部 | 30/30 |
| 額外：無效敵人不會移除 HP 規則 | `enemy_negated_rules` | 敵人已經是被無效的狀態，被攻擊時仍然扣 HP，沒有被破壞 |
| 額外：效果移除不看 HP | `enemy_removal` | 落雷直接以效果破壞（`reason=0x41`） |

紀錄片段（`enemy_defense_hp`）：

```
  attack p0.mzone[0]#2 -> p1.mzone[0]#18
  岩殼守衛(990000001)#18 HP 2200/3200
  ok: expect count 1 mzone 1
  ok: expect destroyed 990000001 not destroyed
...
  岩殼守衛(990000001)#18 HP 0/3200
  move 岩殼守衛(990000001) p1.mzone[0]#18 -> p1.grave[0]#18 reason=0x21
  ok: expect destroyed 990000001 battle
  ok: expect lp 1 8000
  ok: expect win none
```

## 敵人的行動（Lua `s.ai`）

決定：行動模式寫在敵人的 Lua 檔裡，方便日後開放給其他開發者設計。

| 檢查 | 情境 | 結果 |
| --- | --- | --- |
| 敵方的回合完全由腳本操作 | `enemy_ai_turn` | 發動效果，對象選青眼；轉成攻擊表示；攻擊神秘精靈，玩家剩 7600 LP |
| 依 HP 改變行動 | `enemy_ai_defend` | HP 剩一半時維持守備、不攻擊 |
| 在對手的回合回應 | `enemy_ai_defend` | 被攻擊時連鎖發動效果，扣的 HP 從 1000 降到 200 |
| 決策只能查詢 | 手動測試，暫時在 `s.ai` 加入 `Duel.Destroy` | 核心回報 `Action is not allowed here.`，模擬器以 `enemy decision failed` 停止；之後已還原 |

## 攻擊表示被攻擊（2026-10-06 追加決定）

規則：玩家攻擊攻擊表示的敵人時，不比較敵人的攻擊力，敵人直接扣 HP。

測試情境 `enemy_attack_pos`：

| 攻擊方 | 結果 |
| --- | --- |
| 凱爾特守衛（1400），比敵人強 | HP 3200 → 1800 |
| 神秘精靈（800），比敵人弱 | HP 1800 → 1000，精靈沒有被破壞，玩家沒受傷害 |
| Warwolf（2000） | HP 歸零，以戰鬥破壞處理（`reason=0x21`） |

做法：傷害步驟中，把敵人的攻擊力當成 0，見 `docs/enemies.md`。

## 敵人主動攻擊（2026-10-06 追加決定）

規則：敵人攻擊攻擊表示的怪獸時，

- 攻擊力相同：我方怪獸被破壞，敵人扣該怪獸攻擊力的 HP。
- 敵人攻擊力較低：敵人扣差額 HP。

測試情境 `enemy_attacks`：

| 情況 | 結果 |
| --- | --- |
| 敵人（1200）攻擊企鵝（1200） | 企鵝被破壞，敵人 HP 3200 → 2000，玩家沒受傷害 |
| 敵人（1200）攻擊 Warwolf（2000） | Warwolf 沒被破壞，敵人 HP 2000 → 1200，玩家沒受傷害 |

起因是試玩時，攻擊表示的敵人與攻擊怪獸攻擊力相同而同歸於盡。當時這部分規則還沒定案，照原規則處理，所以不是程式錯誤。

## 畫面確認

用 `screenshot.gd -- <檔案> enemy` 截圖確認：

- 敵人以守備表示放在 P1 的怪獸區，卡片下方顯示「HP 3200/3200」。
- 事件紀錄裡有一行 `岩殼守衛(990000001)#2 HP 3200/3200`。

## 過程中遇到的核心行為

- **`initial_effect` 執行時，卡片還沒有 ID 和擁有者**：核心在 `initial_effect` 執行完後才給卡片 ID（`interpreter::register_card`），當時擁有者也還沒設定。
  - 處理方式：敵人卡片直接以卡片物件記錄；整個敵方的設定移到決鬥開始（`EVENT_STARTUP`）時再做。
- **被無效的怪獸，啟動效果仍會出現在發動選項中**：核心檢查能否發動時，不看「被無效」的狀態。
  - 判斷：這是核心原本的行為，不影響這次的驗收。
  - 確認方式：測試時已經確認敵人確實處於被無效的狀態。
- **讀取敵人定義時，`constant.lua` 會呼叫 `Duel.LoadScript`**：模組自己的 Lua 環境裡沒有核心函式。
  - 處理方式：模組提供一個什麼都不做的替代版本。所以敵人定義裡只能使用 `constant.lua` 本身的常數。

## 修改清單

| 檔案 | 變更 |
| --- | --- |
| `native/battle/battle.h`、`battle.cpp` | `Content` 讀取敵人定義（模組自己的 Lua 環境）；載入 `ygopve_enemy.lua`；固定配置可以放到場上；`Hp` 事件與 `Duel::hp()`；接收腳本訊息 |
| `scripts/build.ps1` | 模組程式也連結 Lua，並加上 Lua 標頭檔路徑 |
| `native/duel_harness/main.cpp` | `--enemies`、`card P mzone CODE 表示形式`、`draw_per_turn P n`、`expect hp`、`expect destroyed` |
| `native/gdextension/ygo_battle.cpp` | `YgoContent.open(…, enemies_dir)`、`is_enemy`、`YgoDuel.hp`、`"hp"` 事件、固定配置的 `sequence`／`position` |
| `game/data/enemies/` | 新增：`ygopve_enemy.lua`（敵人規則）、`c990000001.lua`（岩殼守衛） |
| `tests/duel/enemy/*.duel` | 新增 5 個情境 |
| `scripts/test-duel.ps1` | 加入敵人情境，並傳入 `--enemies` |
| `Duel::script_decide`、`YgoDuel.script_decide`、`YgoBattleSession`（`script_players`） | 敵人腳本回答提示 |
| `game/host/*`、`battle_session.gd`、`battle_screen.gd` | 敵人資料夾路徑、「敵人原型」按鈕、卡片上的 HP 顯示 |
| `game/tests/rules_test.gd`、`screenshot.gd` | 敵人檢查、`enemy` 截圖模式 |
| `docs/enemies.md`（新增）、`docs/*`、`TODO.md` | 更新 |

## 已知限制與待決定事項

詳見 `docs/enemies.md` 的「已知限制」，以及 TODO P5 的原型清單和 D11。重點如下：

- 攻擊表示敵人的 HP 怎麼結算。
- 多隻敵人時，效果傷害扣哪一隻。
- HP 歸零卻沒有被破壞時怎麼處理。
- 敵人卡號的號段。
- 敵方 LP 的顯示方式。
- 敵人 AI（P5）。
