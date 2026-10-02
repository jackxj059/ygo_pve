# 補齊提示、核心重新提示、卡片實例 ID 測試紀錄（2026-10-02）

處理 [battle-module-2026-10-02.md](battle-module-2026-10-02.md) 已知限制中的三項：

1. 不支援的提示
2. 核心拒絕回答的路徑沒有實測過
3. 卡片實例無法跨區域識別

環境與第三方版本同 [p1-p2-2026-10-01.md](p1-p2-2026-10-01.md)。

## 指令與結果

```powershell
powershell -ExecutionPolicy Bypass -File scripts/test-duel.ps1 -Build
```

```
[ok] build/battle_tests.exe (exit 0)
[ok] .\tests\duel\basic_chain_win.duel (exit 0)
[ok] .\tests\duel\ydk_opening.duel (exit 0)
[ok] .\tests\duel\prompts\announce_attribute.duel (exit 0)
[ok] .\tests\duel\prompts\announce_card.duel (exit 0)
[ok] .\tests\duel\prompts\announce_number.duel (exit 0)
[ok] .\tests\duel\prompts\announce_race.duel (exit 0)
[ok] .\tests\duel\prompts\rock_paper_scissors.duel (exit 0)
[ok] .\tests\duel\prompts\select_counter.duel (exit 0)
[ok] .\tests\duel\prompts\select_sum.duel (exit 0)
[ok] .\tests\duel\prompts\sort_deck.duel (exit 0)
[ok] .\tests\duel\prompts\tribute_retry.duel (exit 0)
[ok] .\tests\duel\negative\card_not_offered.duel (exit 1)
[ok] .\tests\duel\negative\unscripted_optional_trigger.duel (exit 1)
[ok] .\tests\duel\negative\ydk_bad_format.duel (exit 1)
[ok] .\tests\duel\negative\ydk_unknown_card.duel (exit 1)
16/16 scenarios behaved as expected
```

連續執行兩次，16 份紀錄逐字相同。建置後 `third_party/ygopro-core` 沒有任何修改（`git status` 為空）。

## 1. 補齊提示

核心所有需要玩家回答的提示，戰鬥模組現在都會轉成結構化提示。每種提示都用真卡實測，並查詢核心狀態驗證結果：

| 提示 | 情境 | 驗證方式 |
| --- | --- | --- |
| 宣言卡名 | 禁止令宣言死者蘇生 | 禁止令留在場上；下一個主要階段提示不再列出「發動死者蘇生」 |
| 宣言數字 | Side Effects?，P1 宣言 2 | P1 手牌 3（第 2 回合抽 1 + 效果 2）、P0 LP 12000 |
| 宣言種族 | Array of Revealing Light，宣言龍族 `0x2000` | 場地魔法留在場上；提示列出 26 個種族供選 |
| 宣言屬性 | DNA Transplant，宣言光屬性 `0x10` | 永續陷阱留在場上；提示列出 7 個屬性 |
| 猜拳 | Transmission Gear | P0 出石頭、P1 出剪刀；P1 的 Mystical Elf 被裡側除外，P0 的亞歷山大龍留在場上 |
| 合計選擇 | Ferret Flames | 提示為「達到 1000」模式；P1 選亞歷山大龍（2000）回到牌組 |
| 計數器 | Anti-Spell 加兩張 Breaker | 提示列出兩張 Breaker 各有 1 個計數器；各移除 1 個後，死者蘇生被無效，青眼留在墓地 |
| 自訂排序 | Fruits of Kozaky's Studies | 排序前牌組由下到上為 Elf、Sangan、亞歷山大龍、青眼；指定「Sangan、青眼、亞歷山大龍」由上而下排列後，查詢結果為 Elf、亞歷山大龍、青眼、Sangan |

## 2. 核心拒絕回答的路徑

- **分工**：模組只檢查答案的形狀，遊戲規則交給核心，這兩者的界線因此變得明確。
- **實測情境**：`tribute_retry.duel`。
  1. 上級召喚青眼時只選 1 隻解放。
  2. 核心回覆 `MSG_RETRY`。
  3. 模組用新的提示 ID 重問同一個問題，並標記 `retry`。
  4. 改選 2 隻後成功召喚：場上 1 隻怪獸、墓地 2 張卡。

紀錄片段：

```
? p0 SELECT_TRIBUTE pick 2-2: [0] card Goblindbergh(25259669)@p0.mzone[0]#2 [1] card Alexandrite Dragon(43096270)@p0.mzone[1]#3
  > 0 select 25259669
  ok: expect retry
? p0 SELECT_TRIBUTE (retry: previous answer rejected) pick 2-2: ...
  > 0 select 25259669 43096270
```

## 3. 卡片實例 ID

**對核心的修改**：`patches/ygopro-core/0001-query-cardid.patch`

- **內容**：新增查詢旗標 `QUERY_YGOPVE_CARDID`，回傳核心內部本來就有的 `cardid`。只多一個查詢欄位，不改變訊息格式或決鬥規則。
- **套用方式**：建置時複製一份核心原始碼再套用補丁，`third_party` 的 checkout 維持乾淨。

**`battle_tests` 的驗證項目**：

- **ID 不重複**：用 `.ydk` 牌組加上一張固定配置建立決鬥後，雙方所有卡片的 ID 都不為 0，而且互不重複。
- **能對應回設定**：
  - 牌組和手牌的卡片，`origin()` 會指向主牌組裡卡號相同的那一項。
  - 每一項主牌組都剛好對應到一個實例，洗牌之後也一樣。
  - 額外牌組和固定配置的卡片，也能對應回各自的設定項目。
- **移動後不變**：從手牌召喚一張怪獸後，場上同一個 ID 的卡片仍然是它，來源資訊也不變。

情境紀錄也能看到同一張卡在不同區域之間移動時，ID 保持不變：

```
  move Blue-Eyes White Dragon(89631139) p0.grave[0]#5 -> p0.mzone[2]#5 reason=0x800
  move Sangan(26202165) p1.hand[0]#16 -> p1.mzone[0]#16 reason=0x0
  move Sangan(26202165) p1.mzone[0]#16 -> p1.grave[1]#16 reason=0x21
```

## 修改清單

| 檔案 | 變更 |
| --- | --- |
| `patches/ygopro-core/0001-query-cardid.patch` | 新增：核心補丁 |
| `.gitattributes` | 補丁檔不做換行轉換 |
| `scripts/build.ps1` | 複製核心原始碼到 `build/core-src/` 並套用補丁 |
| `scripts/test-duel.ps1` | 一併執行 `tests/duel/prompts/` |
| `native/battle/battle.h`、`battle.cpp` | 新增 7 種提示、自訂排序、實例 ID、`origin()`；只做形狀檢查，規則交給核心 |
| `native/duel_harness/main.cpp` | 新增 `counter`、`announce`、`rps`、`sort`、`expect retry`；`stop` 只在需要情境回答的提示觸發 |
| `native/battle_tests/main.cpp` | 新增實例 ID 與來源對應的檢查 |
| `tests/duel/prompts/*.duel` | 新增 9 個實卡情境 |
| `tests/duel/negative/unsupported_prompt.duel` | 刪除：宣言卡名現在已支援，改為 `prompts/announce_card.duel` |
| `docs/battle-module.md`、`docs/headless-duel.md`、`TODO.md` | 更新 |

## 仍存在的限制

- **事件中的實例 ID**：是在這一批訊息處理完後，依卡片當下的位置查出來的。同一批訊息裡同一張卡移動兩次、而且剛好被同名的另一張卡佔據原位時，會查錯；提示和查詢不受影響。程式碼中以 `ponytail:` 註解標記。
- **宣言卡名不提供候選清單**：宿主要自己提供卡號，由核心判斷能不能宣言（不行就重新提示）。如果 GUI 要先篩選出可宣言的卡，需要在模組裡實作核心的條件判斷，目前沒有做。
- **超量素材的實例 ID**：素材疊在超量怪獸下面時，目前不查詢實例 ID（顯示為 0）。
- **還沒用真卡實測的提示**：
  - 連鎖排序（`SORT_CHAIN`）：和牌組排序共用同一套程式。
  - 可增減的選擇（`SELECT_UNSELECT_CARD`）：常見於連結、超量的素材選擇。
  
  兩者的程式都已寫好，等測試用的卡池用到時再補情境。
- **牌組合法性**：沒有實作，等 D07 決策。
