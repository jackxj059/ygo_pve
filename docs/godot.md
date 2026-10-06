# Godot 專案（P0／P3）

D01 已定案：Godot **4.7.2-stable**、Windows x64。畫面與流程使用 GDScript；戰鬥模組以 C++ GDExtension 包裝 `native/battle/`，使用 godot-cpp 10.0.0，`api_version=4.7`。

## 指令

```powershell
powershell -ExecutionPolicy Bypass -File scripts/bootstrap.ps1   # 另外下載 Godot、可攜式 Python、SCons，並 clone godot-cpp
powershell -ExecutionPolicy Bypass -File scripts/build.ps1       # 另外建置 GDExtension；第一次會順便建置 godot-cpp，需要幾分鐘
powershell -ExecutionPolicy Bypass -File scripts/run-game.ps1    # 啟動測試宿主；加 -Editor 則開啟 Godot 編輯器
powershell -ExecutionPolicy Bypass -File scripts/test-duel.ps1   # 包含無畫面的 Godot 煙霧測試
```

- **Python 和 SCons**：只用來建置 godot-cpp，放在 `tools/`，版本鎖定在 `third_party/versions.lock.json`，不需要安裝，也不需要管理員權限。
- **編譯器**：GDExtension 和核心使用同一套 llvm-mingw。

## 目錄與依賴方向

```
game/                        Godot 專案（Demo 宿主）
  host/                      測試宿主：開始戰鬥、離開、回到戰鬥、顯示結果
  addons/ygo_battle/         可搬移的戰鬥模組（依賴清單見其 README.md）
  tests/                     煙霧測試、截圖工具
native/gdextension/          GDExtension 原始碼（YgoContent、YgoDuel）
native/battle/               共用戰鬥模組（C++，不依賴 Godot）
```

依賴方向：`host` → `addons/ygo_battle` → GDExtension → `native/battle` → ygopro-core。

模組不會反向引用宿主。冒險模組尚未建立，日後加入時位置會在宿主和戰鬥模組之間。

## 戰鬥設定（`YgoDuel.start` 的 config）

```gdscript
{
  "seed": [a, b, c, d],             # 或單一整數
  "players": [                      # 0 號與 1 號玩家
    {"lp": 8000, "start_draw": 5, "draw_per_turn": 1, "main": [卡號...], "extra": [卡號...]},
    {...},
  ],
  "placements": [{"player": 0, "location": YgoDuel.LOCATION_HAND, "code": 卡號}, ...],
}
```

- **`main`**：主牌組會依種子洗牌。
- **`placements`**：依指定順序放置，不洗牌，用於固定開場。
- **`YgoBattleSession.config_from_decks([路徑0, 路徑1], seed, err)`**：可以直接用兩個 `.ydk` 檔組出設定。

## 畫面掛載與生命週期

| 操作 | 效果 |
| --- | --- |
| `battle_screen.attach(session, resources)` | 顯示並開始推進。每個影格最多處理 64 批核心訊息，遇到選擇提示就停下來等玩家 |
| `battle_screen.detach()` | 停止推進並隱藏畫面，**不會**銷毀決鬥。測試宿主的「離開畫面 → 回到目前的對戰」就是用這個 |
| 放掉 `YgoBattleSession` 的參照 | 銷毀決鬥 |
| `session.finished(result)` | `{winner, reason, error}`。reason：1 為 LP 歸零，2 為抽乾牌組 |

## 最小戰鬥畫面

- **版面**：左側是雙方的手牌、魔陷區、怪獸區（含額外怪獸區）、LP 和各區張數；右側是選擇提示、卡片說明、事件紀錄。
- **卡片顯示**：有卡圖就顯示卡圖，沒有就以文字顯示卡名、等級和攻守；裡側的卡會變暗，守備表示會橫放。
- **操作方式**：在右側點選選項回答。
  - 單選題：直接按按鈕。
  - 多選題：勾選後按確定。
  - 計數器：設定每張卡要移除幾個。
  - 排序：依序點選。
  - 宣言卡名：輸入卡號。
- **雙人輪流**：兩位玩家都在同一個畫面上操作。勾選「對手自動略過」後，P1 會自動不連鎖、結束回合、不發動效果；遇到無法自動決定的選擇時，仍然會交給你。

## AP 與構築點數

- **AP**：
  - 在宿主的戰鬥設定裡加上 `players[i].ap = {max, initial, costs}`，規則見 `docs/battle-module.md`。
  - 測試宿主的數值放在 `host/test_settings.gd`，全部都是**測試值**。
  - 戰鬥畫面會顯示目前 AP 和上限，選項標上費用；付不起的選項會停用並寫明原因。即使宿主硬送，戰鬥模組也會拒絕。
- **構築點數**（`YgoDeckPoints`，位於 `addons/ygo_battle/deck_points.gd`）：
  - **點數表**：`game/data/points/*.json`，格式是 `ygo-pve-points/1`，帶有版本和來源。
    - 由 `scripts/import_genesys_points.py` 從官方 TCG Genesys 頁面匯入，只取點數，不帶卡池限制。
    - 點數表必須明確宣告 `unlisted_points`，也就是沒列出的卡算幾點；沒寫就拒絕載入。資料庫找不到的卡號一律視為錯誤。
  - **計分**：主牌組加額外牌組，重複卡每張都算；備牌不算。這是專案自己的決定，官方 Genesys 也會計算備牌。
  - **開戰檢查**：`YgoBattleSession.start(content, config, {points, cap})` 會檢查 0 號玩家的牌組，超出上限就拒絕開戰。對手不檢查。
  - **牌組預覽**：`deck_preview.tscn` 依區塊列出卡片、張數和每張的點數，顯示總點數和上限；不合法時「開始戰鬥」按鈕會停用。

## 測試

- **`game/tests/smoke_test.gd`**：無畫面執行，由 `test-duel.ps1` 呼叫。
  - 用 GDScript 透過 GDExtension 完整重播 `basic_chain_win`，確認 P0 以 LP 獲勝、最後 LP 為 7000 對 0。
  - 把畫面掛到一場新的決鬥上，確認第一個提示有顯示；卸下畫面後，決鬥仍然存在。
- **`game/tests/rules_test.gd`**：無畫面執行，檢查構築點數和 AP 是否正確開放給 GDScript。
- **`game/tests/screenshot.gd`**：開啟視窗後截圖，用來在不手動點選的情況下檢查版面。
  - 可以先自動執行前 N 步再截圖。
  - 也可以用 `preview:<牌組>` 截牌組預覽畫面。
- **逾時保護**：Godot 測試在 `test-duel.ps1` 裡有 2 分鐘的逾時限制，因為腳本編譯失敗時 Godot 不會自己結束。

## 已知限制

- **選卡方式**：只能從右側的選項清單選，還不能直接點場上的卡片。
- **沒有動畫**：事件只寫進紀錄，畫面會整個重新整理。
- **墓地、除外區、額外牌組**：只顯示張數和墓地最上面的卡名，還不能查看完整內容。
- **只有除錯版**：只建置了 `template_debug`；匯出遊戲用的 `template_release` 版本之後再加。
- **路徑**：使用非 ASCII 的資料路徑還沒有測過。
