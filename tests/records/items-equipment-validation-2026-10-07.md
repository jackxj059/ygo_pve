# 道具與裝備第一階段技術驗證紀錄（2026-10-07）

規格見 `docs/items-equipment.md`，結果與支援範圍見 `docs/items.md`。這次沒有新增核心補丁，所有未定案的規則都以測試設定處理。

## 指令

```powershell
powershell -ExecutionPolicy Bypass -File scripts/test-duel.ps1 -Build
```

## 新增的測試

| 驗證 | 情境 |
| --- | --- |
| 1. 道具不開連鎖 | `items/item_recover`、`items/item_recycle`、`negative/item_needs_five`、`negative/item_facedown_excluded`、`negative/item_not_in_battle`、`negative/item_not_in_chain` |
| 2. 指定卡片免 AP | `equipment/equip_ap_free` |
| 3. 戰鬥傷害 2 倍 | `equipment/equip_double_damage`、`equipment/equip_double_stack`、`equipment/equip_double_enemy` |
| 4. 原效果成功後回復 | `equipment/equip_recover` |
| 裝備綁定錯誤 | `negative/equip_no_target` |

## 驗證後的決定（同日）

- **道具**：
  - 不花 AP，是消耗品。
  - 用了就算用掉，不論結果；取消選卡不算。
  - 新增 `item … xN` 和 `expect uses`；用完後選項標成不能選，戰鬥模組也會拒絕。
- **回收**：額外牌組的卡算在 5 張之內。
- **裝備跟著卡**：
  - 2 倍傷害改用卡片當下控制者的對手，回復也改給當下控制者。
  - 新測試 `equipment/equip_control`：對手用心變奪走裝備的怪獸直接攻擊，傷害一樣是 2 倍。
- **裝備不會被無效**：維持原樣。
- **敵人 HP 的計算方式**：確認保留「讀取核心算出的戰鬥傷害」。不改 Lua 的話只能改核心，因為戰鬥模組只能在核心判定完破壞之後才收到結果。

## 一起改動的部分

- **敵人扣 HP 的數字來源**：改成讀取核心算出的敵方戰鬥傷害，做法與原因見 `docs/items.md` 驗證 3。原有 11 個敵人情境的結果完全相同。
- **自訂卡片的定義表**：由 `s.ygopve_enemy` 改名為 `s.ygopve`。自訂卡片資料夾改為 `game/data`，模擬器參數改成 `--custom`。
- **模擬器**：
  - 可以用 `卡號@區域[格子]` 指定同名卡中的哪一張。
  - 新增設定行 `item`、`equip`，以及斷言 `expect item`。
- **`test-duel.ps1`**：改用 UTF-8 讀取模擬器的輸出。以前用系統編碼讀取，紀錄裡的中文卡名會變成亂碼，比對中文的反向測試也會失敗。

## 過程中發現的核心行為

- **核心把持續效果也列在戰鬥階段和連鎖窗口的選項中**：所以模組會在主要階段以外，把道具選項拿掉。
- **效果被無效時，核心仍然送出 `CHAIN_SOLVED`**：所以不能用這個事件判斷效果成功。
- **貫穿傷害的對象**：核心把貫穿傷害算給「效果所屬玩家的對手」，所以敵人用的貫穿效果必須註冊在玩家那一方。
- **無限泡影從蓋放狀態發動時**：同一直列的魔法、陷阱也會被無效。這個效果讓測試裡的一張貪欲之壺被無效，調整卡片位置後，反而順便驗證了「效果被無效時不回復」。

## 裝備限制（同日追加）

規則：
- 裝備可以用 `requires` 限制對象：種類、等級範圍、種族、屬性。
- 超量怪獸的階級算作等級；連結怪獸沒有等級。

測試：
- `equipment/equip_requires`：勇士之證裝給蓋亞（7 星戰士）和 No.90（8 階戰士），魔導書籤裝給死者蘇生，都能正常開戰；勇士之證讓蓋亞攻擊力 +500。
- 反向測試：
  - `negative/equip_requires_level`：凱爾特守衛只有 4 星。
  - `negative/equip_requires_rank`：No.39 是 4 階，階級算作等級後仍不到 5。
  - `negative/equip_requires_type`：凱爾特守衛不是魔法卡。

畫面：在牌組預覽點哥布林飛行隊（4 星機械族），勇士之證和魔導書籤顯示成灰色，並寫出需要的條件。
