# 共用戰鬥模組與 `.ydk` 載入測試紀錄（2026-10-02）

環境與第三方版本同 [p1-p2-2026-10-01.md](p1-p2-2026-10-01.md)，對上游沒有任何修改。

> 後續：本文「已知限制」的前三項已在同日處理，見 [prompts-instances-2026-10-02.md](prompts-instances-2026-10-02.md)。`unsupported_prompt.duel` 因此改為正向情境 `prompts/announce_card.duel`。

## 指令

```powershell
powershell -ExecutionPolicy Bypass -File scripts/test-duel.ps1 -Build
```

## 結果

```
[ok] build/battle_tests.exe (exit 0)
[ok] .\tests\duel\basic_chain_win.duel (exit 0)
[ok] .\tests\duel\ydk_opening.duel (exit 0)
[ok] .\tests\duel\negative\card_not_offered.duel (exit 1)
[ok] .\tests\duel\negative\unscripted_optional_trigger.duel (exit 1)
[ok] .\tests\duel\negative\unsupported_prompt.duel (exit 1)
[ok] .\tests\duel\negative\ydk_bad_format.duel (exit 1)
[ok] .\tests\duel\negative\ydk_unknown_card.duel (exit 1)
8/8 scenarios behaved as expected
```

連續執行兩次，8 份紀錄逐字相同。完整輸出見 `tests/records/latest/`。

## 驗收對照

| # | 條件 | 證據 |
| --- | --- | --- |
| 1 | 原有正向／反向測試仍通過 | `basic_chain_win` 與兩個原有反向情境都通過。決鬥流程、傷害、連鎖順序與勝負和重構前相同，紀錄只差在輸出格式（選項加上編號、提示改用核心的正式名稱） |
| 2 | 測試程式透過共用模組操作核心 | `native/duel_harness/main.cpp` 只引用 `battle.h`／`deck.h`，不再直接呼叫任何 `OCG_*` 函式 |
| 3 | 收到提示可交回宿主，之後提交仍能繼續 | `battle_tests`：等待中連續呼叫 `advance()` 三次都回傳 `Awaiting`，也沒有產生新事件；之後提交「結束回合」，決鬥正常推進到 P1 的回合 |
| 4 | 測試的自動決策沒有混進共用規則 | 選區域、表示形式、放棄連鎖等預設都寫在 harness 的 `decide()`，紀錄標為 `default: ...`。模組只會自動放棄「沒有任何可發動卡片」的連鎖窗口，因為那是唯一合法的回答 |
| 5 | `.ydk` 主／額外／備牌、重複卡 | `battle_tests` 測了 CRLF、註解與空白行；`test_basic.ydk` 解析出主牌組 40、額外 2、備牌 2，Goblindbergh 保留 3 張 |
| 6 | 用牌組建立決鬥，檢查起手與剩餘牌庫 | `ydk_opening`：雙方手牌 5、牌庫 35、額外 2（備牌不在場）；P1 第 2 回合抽牌後手牌 6、牌庫 34。`battle_tests` 另外確認手牌加牌庫剛好等於主牌組的全部卡片 |
| 7 | 相同輸入與種子可重現 | `ydk_opening` 用標準答案比對雙方確切手牌。`battle_tests` 確認同一種子重建兩次，牌庫順序和第一個提示都相同；換種子後順序不同。未洗牌時起手應為檔案最後 5 張，實際並非如此，證明有洗牌 |
| 8 | 明確診斷 | 格式錯誤：`tests/decks/bad_format.ydk:4: expected a card code, got '15025844 x2'`<br>未知卡號：`p0 main deck: unknown card code 99999999`<br>不支援的提示：`prompt type 142 is not supported by the battle module yet`（禁止令宣言卡名）<br>無效回應：`stale prompt id`、`out of range`、`exactly one`、`no prompt`（重複提交） |
| 9 | 建立、結束並重新建立 | `battle_tests` 在同一個程序裡建立並銷毀 3 場決鬥，結果和全新建立相同；建立失敗（未知卡號）之後再建立一場仍然正常 |

## 修改清單

| 檔案 | 變更 |
| --- | --- |
| `native/battle/battle.h`、`battle.cpp` | 新增：共用戰鬥模組 |
| `native/battle/deck.h`、`deck.cpp` | 新增：`.ydk` 解析 |
| `native/duel_harness/main.cpp` | 改寫：成為模組的使用者；新增 `deck`、`stop`、`expect cards` |
| `native/battle_tests/main.cpp` | 新增：模組自測 |
| `scripts/build.ps1` | 編譯模組，新增 `battle_tests.exe` |
| `scripts/test-duel.ps1` | 一併執行 `battle_tests.exe` |
| `tests/decks/*.ydk` | 新增：測試牌組，以及兩份刻意寫壞的牌組 |
| `tests/duel/ydk_opening.duel`、`tests/duel/negative/{ydk_bad_format,ydk_unknown_card,unsupported_prompt}.duel` | 新增情境 |
| `docs/battle-module.md` | 新增：模組入口、資料結構、Godot 接入方式 |
| `docs/headless-duel.md`、`TODO.md` | 更新 |

## 已知限制

- **尚未支援的提示**：計數器、合計選擇、宣言、猜拳。遇到時會進入 `Error` 狀態，訊息會寫明不支援。自訂排序也還不行，只能沿用核心預設順序。
- **核心拒絕回答的路徑沒有自動化測試**：模組端的驗證已經擋掉目前測得到的無效回答，所以這個路徑沒有被實際觸發過。程式邏輯是用新的 ID 重新提示，並標記 `retry`。
- **卡片識別**：卡片實例目前以「控制者、區域、位置」識別。核心不提供跨區域不變的實例 ID，卡片移動後位置就會改變。如果日後裝備需要綁定特定卡片實例，需要另外設計。
- **牌組合法性**：沒有實作，等 D07 決策。
- **`ydk_opening` 的標準手牌**：綁定目前的洗牌演算法與種子。日後若改了洗牌演算法，需要重新產生。
