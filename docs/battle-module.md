# 戰鬥模組（`native/battle/`）

戰鬥模組負責驅動 ygopro-core，並把核心的二進位協定轉成事件與結構化提示。它**不替玩家做任何決定**，誰來回答提示由宿主決定。目前的宿主是測試程式 `duel_harness`，未來會換成 Godot GUI。

模組不依賴 Godot、Demo 地圖或主選單，也不啟動 EDOPro 客戶端，同樣不需要多執行緒。

| 檔案 | 內容 |
| --- | --- |
| `battle.h` / `battle.cpp` | `Content`（卡片資料庫與腳本索引）、`Duel`（一場決鬥）、事件、提示 |
| `deck.h` / `deck.cpp` | `.ydk` 解析，不依賴核心 |

敵人（擁有 HP 的自訂怪獸卡）的定義方式與規則見 [enemies.md](enemies.md)。

## 使用流程

```cpp
battle::Content content("third_party/CardScripts", {"third_party/BabelCDB/cards.cdb"}); // 可跨多場決鬥共用
battle::DuelConfig cfg;                         // 種子、雙方 LP／起手抽數、牌組、固定配置
cfg.players[0].main = battle::load_ydk("deck.ydk").main;
battle::Duel duel(content, cfg);                // 設定錯誤會丟出 std::runtime_error

for(;;) {
    auto status = duel.advance();               // 只推進一步
    for(auto& e : duel.take_events()) { /* 播放動畫、寫紀錄 */ }
    if(status == battle::Status::Continue) continue;
    if(status == battle::Status::Ended) break;   // duel.winner()、duel.win_reason()
    if(status == battle::Status::Error) break;   // duel.error()
    const battle::Prompt& p = *duel.prompt();   // Awaiting：把控制權交回宿主
    std::string err;
    duel.submit(p.id, {/* 選項索引 */}, err);   // 驗證不過時回傳 false，提示保持不變
}
```

### 狀態

| 狀態 | 意思 | 宿主該做的事 |
| --- | --- | --- |
| `Continue` | 還能繼續處理 | 再呼叫 `advance()`，可以分散到多個影格 |
| `Awaiting` | 正在等某位玩家回答 `prompt()` | 讓玩家選擇。在送出答案前，`advance()` 會立即回傳，不會呼叫核心，也不會忙等 |
| `Ended` | 收到 `MSG_WIN`，或核心回報決鬥結束 | 讀取勝負結果 |
| `Error` | 腳本錯誤、未知卡號、訊息格式錯誤，或核心在等待回答卻沒有送出任何可辨識的提示 | 讀取 `error()` 並停止這場決鬥 |

核心送出 `MSG_WIN` 後其實還會繼續跑，模組在收到 `MSG_WIN` 時就停止，做法和 EDOPro 伺服器相同。

### 提示（`Prompt`）

- **`id`**：每次提示都不同。提交時必須帶上目前的 `id`，過期的 `id` 或重複提交都會被拒絕。
- **`type`**：核心所有需要玩家回答的提示都有對應的種類。

  | 種類 | 情境 |
  | --- | --- |
  | `Idle`、`Battle` | 主要階段、戰鬥階段的指令 |
  | `EffectYesNo`、`YesNo` | 是否發動選發效果、一般是／否問題 |
  | `Option` | 效果選項 |
  | `Chain` | 連鎖窗口 |
  | `SelectCard` | 選卡、選對象 |
  | `SelectTribute` | 選擇解放 |
  | `SelectUnselect` | 可增減的選擇 |
  | `SelectSum` | 合計選擇，例如等級或攻擊力總和 |
  | `Counter` | 從哪些卡移除計數器 |
  | `Place`、`Position` | 選區域、選表示形式 |
  | `Sort` | 排序，例如牌組最上面幾張、連鎖順序 |
  | `AnnounceRace`、`AnnounceAttribute`、`AnnounceNumber`、`AnnounceCard` | 宣言種族、屬性、數字、卡名 |
  | `RockPaperScissors` | 猜拳 |

- **`options`**：可選的項目。每個選項包含：
  - `action`：動作名稱，例如 `summon`、`activate`、`attack`、`end`、`pass`、`yes`、`card`、`must`、`zone`、`fu_atk`、`race`、`number`、`rock`。
  - `card`：卡號、控制者、區域、位置編號，以及**實例 ID**（見下方「卡片實例」）。
  - `desc`：效果描述編號；宣言種族或屬性時是該種族或屬性的位元值，宣言數字時是數字本身。
  - `param`：解放時這張卡算幾隻；合計選擇時是這張卡的數值（低 16 位元，另一個可選數值放在高 16 位元）；計數器選擇時是這張卡上的計數器數量。

  宿主只要回傳選項索引，**同卡號的不同卡片可以靠位置或實例 ID 區分，同一張卡的不同效果可以靠 `desc` 區分**，不需要解析核心的二進位訊息。
- **`min` / `max`**：可選數量。
- **`value`**：計數器選擇時要移除的數量；合計選擇時的目標值；宣言種族或屬性時要宣言幾個。
- **`at_least`**：合計選擇時，總和只要「達到」目標值即可，不必剛好相等。
- **`cancelable`、`forced`**：能否取消、能否放棄連鎖。
- **`filter`**：宣言卡名時，核心用來判斷哪些卡可以宣言的條件程式。
- **`retry`**：核心拒絕了上一次的回答（`MSG_RETRY`），現在用新的 `id` 再問一次。

`submit()` 的規則：

| 提示種類 | 要傳入的選項 |
| --- | --- |
| 單選提示 | 剛好 1 個索引 |
| `SelectCard` | `min`～`max` 個不重複的索引；`cancelable` 時傳空清單代表取消 |
| `SelectTribute` | 1～`max` 個不重複的索引；`min`／`max` 以解放數計算，一張卡可能算兩隻 |
| `SelectSum` | 不重複的 `card` 選項；`must` 選項一定會被算進去，不能選 |
| `Counter` | 剛好 `value` 個索引；同一個索引出現幾次，就從那張卡移除幾個 |
| `Place` | 剛好 `min` 個區域 |
| `Sort` | 空清單代表沿用核心預設順序；或把所有索引各列一次，第一個代表最上面／最先 |
| `AnnounceRace`、`AnnounceAttribute` | 剛好 `value` 個不重複的索引 |
| `AnnounceCard` | 剛好 1 個**卡號**（不是索引），而且必須存在於卡片資料庫 |

**分工原則：模組只檢查答案的形狀，遊戲規則交給核心判斷。**
- **模組負責的形狀檢查**：索引是否超出範圍、是否重複、數量對不對、提示 ID 是否過期。不符合時，`submit()` 直接回傳錯誤，提示維持不變。
- **核心負責的規則檢查**：合計是否正確、每張卡上有沒有足夠的計數器、解放數值夠不夠、宣言的卡是否符合條件。不符合時，核心回覆 `MSG_RETRY`，模組會用新的 `id` 重新提示，並把 `retry` 設為 true。
- **好處**：模組不需要複製一套遊戲規則，也不會和核心的判斷不一致。`tests/duel/prompts/tribute_retry.duel` 實測了這條路徑。

模組只會自動處理一種情況：**沒有任何可發動卡片的非強制連鎖窗口**。這時放棄是唯一合法的回答，模組直接回應核心，不另外產生提示。

### AP（行動點數）

AP 由戰鬥模組執行，沒有修改核心。所有數值都由宿主透過 `PlayerConfig::ap` 傳入，模組和畫面都不寫死。

| 設定 | 說明 |
| --- | --- |
| `enabled` | 沒啟用的玩家（例如敵人、測試對手）完全不受 AP 限制 |
| `max` | 每次輪到**自己的回合開始時**回滿到這個值；剩下的 AP 可以留到對手回合使用 |
| `initial` | 第一個回合之前的 AP |
| `costs` | 各動作的費用：`summon`、`spsummon`、`set`、`activate`、`attack`、`repos`。反轉召喚算 `repos`（2026-10-06 決定）；沒列出的動作不收費 |

**運作方式：**

1. **標價**：送出提示時，替選項標上 `cost`。付不起的選項會帶有 `blocked` 原因，`submit()` 會拒絕它，所以 AP 不足時動作根本不會開始，卡片原本的代價也不會被支付。
2. **扣點時機**：等核心確認動作成立時才扣，也就是收到召喚中、特殊召喚中、蓋放、連鎖發動、宣告攻擊、表示形式變更這些訊息的時候。
   - 確認之前如果先回到下一個決策提示，代表動作被取消，不扣點。
   - 被無效不退點。
3. **只有玩家主動的選擇才收費**：
   - 收費：主要階段或戰鬥階段的指令、非強制的連鎖、選擇發動選發效果。
   - 不收費：強制連鎖（必發效果）、不經玩家選擇自動發動的效果、效果處理中造成的召喚和表示形式變更。
   - 接連鎖時，只收那一次發動的費用，不另外加收。
4. **事件與查詢**：AP 變化會產生 `Ap` 事件；也可以用 `ap()`、`ap_max()`、`ap_enabled()` 查詢。

AP 不會取代原本的次數限制，例如每回合一次通常召喚，這些仍然由核心照原規則處理。

### 事件（`Event`）

- **種類**：換回合、換階段、抽牌、移動、各種召喚、蓋放、連鎖發動／處理／結束／被無效、傷害、回復、支付 LP、攻擊、勝負。
- **內容**：每個事件帶有相關的卡片位置，以及數值（傷害量、連鎖編號、勝利原因等）。
- **除錯**：`describe()` 會把事件或提示轉成文字。測試紀錄就是用它輸出的，GUI 也可以拿來寫除錯紀錄。

### 查詢

- `lp(player)`：LP。
- `count(player, location)`：區域張數。
- `cards(player, location)`：依序列出區域裡的卡號、表示形式與實例 ID；怪獸區、魔陷區的空格卡號為 0。
- `origin(instance)`：這個實例來自設定裡的哪一項，見下方「卡片實例」。

### 卡片實例

- **實例 ID（`CardRef::instance`）**：每張卡在這場決鬥中的固定編號。卡片在手牌、場上、墓地、除外之間移動，ID 都不會改變；衍生物會拿到新的 ID。
- **哪裡會帶上 ID**：查詢結果、提示選項、事件都會帶上它。之後裝備要綁定特定卡片、連戰要追蹤卡片時，就用這個 ID。
- **ID 從哪裡來**：核心內部本來就替每張卡編號（`cardid`，Lua 的 `Card.GetCardID` 用的就是它），但 C API 沒有提供查詢方式，所以我們對核心打了一個小補丁，見下方「對核心的修改」。
- **`origin(instance)`**：回傳這張卡來自哪位玩家的主牌組、額外牌組或固定配置，以及它在設定清單中的索引（洗牌前）。
  - 運作方式：核心依建立順序編號，模組建立決鬥後依編號排序，就能一一對應回設定。
  - 安全檢查：如果卡號對不上，建立決鬥會直接失敗，不會產生錯誤的對應。
  - 用途：例如「玩家收藏裡的第 2 張亞歷山大龍」在決鬥中是哪個實例，就靠它查。
- **限制：事件中的實例 ID 是在這一批訊息處理完後，依卡片當下的位置查出來的**。
  - 如果同一批訊息裡同一張卡移動了兩次，查到的可能是之後佔據那個位置的卡。模組會比對卡號，大部分情況都能發現；但如果剛好是同名的另一張卡，就分辨不出來。
  - 提示選項和查詢結果都是在核心暫停時查的，沒有這個問題。

## 對核心的修改

- **補丁位置**：所有修改都放在 `patches/ygopro-core/*.patch`，並納入版本控制。
- **套用方式**：`build.ps1` 把核心原始碼複製到 `build/core-src/`，套用補丁後再編譯，所以 `third_party/ygopro-core` 本身一直停在乾淨的鎖定 commit。
- **鎖定版本變更時**：如果補丁套不上，建置會直接失敗並指出是哪個補丁。

| 補丁 | 內容 |
| --- | --- |
| `0001-query-cardid.patch` | 新增查詢旗標 `QUERY_YGOPVE_CARDID`（`0x40000000`），回傳卡片的 `cardid`。只多一個查詢欄位，不改變任何訊息格式或決鬥規則 |

敵人原型沒有新增補丁，全部使用核心既有的 Lua 介面和 log 回呼。

## 牌組與開場

- **`.ydk` 標記**：`parse_ydk` / `load_ydk` 認得 `#main`、`#extra`、`!side`。
  - 其他以 `#` 開頭的行視為註解，空白行和 CRLF 都可以。
  - 重複的卡片會照原樣保留。
- **錯誤訊息**：會指出 `檔名:行號`，例如卡號前面沒有 `#main`、格式不是卡號、未知區段、卡號超出範圍。
- **卡號是否存在**：建立 `Duel` 時檢查，錯誤訊息會指出是哪位玩家的哪個區塊，例如 `p0 main deck: unknown card code 99999999`。
- **合法性**：牌組合法性（張數、禁限、構築點數）尚未定案，所以**刻意不實作**。
- **洗牌**：核心不會自己洗牌，由模組用種子洗主牌組，採 splitmix64 加 Fisher–Yates。
  - 相同種子一定得到相同順序，而且結果不受編譯器或標準函式庫影響；之後 Godot 端改用 MSVC 編譯也一樣。
- **固定配置**：`DuelConfig::placements` 會照指定順序放置、不洗牌，供規則測試使用。
  - 可以直接放到怪獸區或魔陷區：用 `sequence` 指定格子，用 `position` 指定表示形式，預設是表側攻擊。
- **自訂卡片**：建立 `Content` 時傳入 `custom_dir`（測試時是 `game/data`），就會讀取底下所有 `c<卡號>.lua` 的定義：敵人、技能、道具、裝備。
  - 敵人的 HP 用 `Duel::hp(instance)` 查詢；HP 變化時會產生 `Hp` 事件，`value` 是目前 HP，`reason` 是上限。
  - 詳見 [enemies.md](enemies.md)。
- **道具與裝備**：`DuelConfig::items`、`DuelConfig::equipment`；裝備用卡片的外部固定 ID（`CardOrigin`：哪位玩家的主牌組、額外牌組或固定配置的第幾張）綁定到那一張卡。道具使用結果會產生 `Item` 事件。詳見 [items.md](items.md)。
- **備牌**：只保留在 `Deck` 資料裡，不會放進決鬥。

## 生命週期

- **一個 `Duel` 物件就是一場決鬥**：解構時才銷毀核心裡的決鬥。
- **離開畫面不等於銷毀決鬥**：GUI 只要繼續保留 `Duel` 物件，之後的連戰就能保留狀態。
- **建立失敗不留殘骸**：建構子丟出錯誤時，已經建立的核心決鬥會一併銷毀。
- **決鬥之間互不影響**：每場決鬥的錯誤紀錄、缺少的腳本、提示 ID 都各自保存，重新建立不會殘留上一場的狀態，`battle_tests` 有驗證這點。
- **`Content` 可以共用**：資料庫連線、卡片快取和腳本索引是唯讀的，多場決鬥共用同一份。

## Godot 接入方式（P3 建議）

1. 用 godot-cpp 寫一個 GDExtension 類別，例如 `YgoDuel : RefCounted`，內部持有 `battle::Duel`；`battle::Content` 可以由一個共用物件持有。
2. 對外提供這些方法：
   - `advance()`：回傳狀態。
   - `take_events()`：回傳 `Array[Dictionary]`。
   - `get_prompt()`：回傳 `Dictionary`，包含 id、type、options 等。
   - `submit(id, PackedInt32Array)`：回傳錯誤字串。
   - 查詢方法：`lp`、`count`、`cards`。
3. GDScript 每個影格呼叫 `advance()`。遇到 `Awaiting` 就把 `options` 顯示成可點的卡片或按鈕，玩家點選後再呼叫 `submit()`；播放動畫時可以暫停推進。
4. GDExtension 和 `ocgcore.dll`、`.cdb`、`.lua` 都列入模組依賴清單，資源根目錄由宿主設定。
