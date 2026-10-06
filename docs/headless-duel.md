# 無畫面決鬥測試（P1／P2）

不依賴 EDOPro 客戶端，直接以 `ygopro-core` 的 C API 搭配 `BabelCDB` 卡片資料庫與 `CardScripts` Lua 腳本跑決鬥。

驅動核心的程式碼在共用戰鬥模組 `native/battle/`，說明見 [battle-module.md](battle-module.md)。本文件說明的是建置指令，以及測試程式 `duel_harness` 使用的情境檔格式。

## 需求

- Windows 10/11 x64、PowerShell 5.1、git（需在 PATH 上）。
- 不需要 Visual Studio、Python、CMake 或系統管理員權限。編譯器（llvm-mingw）與 SQLite 原始碼由 bootstrap 依 `third_party/versions.lock.json` 下載到 `tools/`，並驗證 SHA256。

## 指令

在 repo 根目錄執行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/bootstrap.ps1   # 還原三個第三方 checkout 與工具鏈（可重複執行）
powershell -ExecutionPolicy Bypass -File scripts/build.ps1       # 產生 build/ocgcore.dll、duel_harness.exe、battle_tests.exe
powershell -ExecutionPolicy Bypass -File scripts/test-duel.ps1   # 跑模組自測與全部情境，紀錄寫到 tests/records/latest/
```

卡圖不是決鬥所需的資料，另外用這支腳本下載（約 1.5 萬張、2 GB，不進 repo）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fetch-card-images.ps1                 # 完整卡圖 -> third_party/card_images/full/<卡號>.jpg
powershell -ExecutionPolicy Bypass -File scripts/fetch-card-images.ps1 -Kind cropped   # 只有卡圖插畫 -> third_party/card_images/cropped/
```

- **來源**：YGOPRODeck。
- **對方的規定**：每張圖只下載一次並存在本機，高頻率抓圖會被封鎖 IP。所以腳本依序下載、每次間隔 0.1 秒，已經存在的檔案會跳過，中斷後重跑會從斷點繼續。
- **結果紀錄**：每次執行的結果寫在 `third_party/card_images/source-<kind>.txt`，失敗的卡號寫在 `failed-<kind>.txt`。
- **沒有圖的卡**：卡號以 YGOPRODeck 的卡片清單為準，所以先行卡、動畫原創卡等可能沒有圖。

`build.ps1` 會把核心原始碼複製到 `build/core-src/`，套用 `patches/ygopro-core/` 的補丁後再編譯，`third_party` 的 checkout 本身不會被修改（見 [battle-module.md](battle-module.md#對核心的修改)）。

`battle_tests.exe` 是戰鬥模組的自測程式，必須在 repo 根目錄執行。它檢查情境檔表達不了的部分：`.ydk` 解析、提示的生命週期、洗牌，以及重建決鬥。

`test-duel.ps1 -Build` 會先重新建置。單跑一個情境：

```powershell
build/duel_harness.exe --scripts third_party/CardScripts --db third_party/BabelCDB/cards.cdb tests/duel/basic_chain_win.duel
```

`--db` 可重複指定，找卡時先找到的資料庫優先。

- bootstrap 遇到有本地修改的 checkout 只會警告或中止，不會 reset。
- 若 checkout 停在鎖定以外的 commit 又有修改，會直接報錯。

## 載入順序

1. `OCG_CreateDuel` 時以 `DUEL_MODE_MR5` 建立決鬥。卡片資料由 SQLite 讀取；`level` 欄位的刻度與 Link 標記依 EDOPro 格式拆解。
2. 由宿主載入 `constant.lua`、`utility.lua`，其餘 `proc_*.lua` 等由它們自行 `Duel.LoadScript`。
3. 卡片腳本依序在 CardScripts 根目錄、`official/`、`pre-release/`、`pre-errata/`、`unofficial/`、`goat/`、`rush/`、`skill/` 中尋找 `c<卡號>.lua`。
4. 通常怪獸沒有腳本屬正常；其他卡片缺腳本、資料庫找不到卡號，或核心回報任何 Lua 錯誤，測試都會失敗。

## 情境檔格式（`tests/duel/*.duel`）

`#` 之後為註解。設定行必須寫在所有操作之前。

| 設定 | 說明 |
| --- | --- |
| `seed a b c d` | 亂數種子 |
| `lp P n` | 玩家 P（0／1）起始 LP |
| `start_draw P n` | 起手抽牌數；設 0 並用 `card` 指定手牌，可得到固定開場 |
| `draw_per_turn n` | 每回合抽牌數 |
| `deck P path.ydk` | 載入牌組：主牌組依種子洗牌後放入牌庫，額外牌組放入額外牌組區，備牌不放入決鬥 |
| `card P hand/deck/grave/removed/extra CODE [xN]` | 依指定順序放置卡片，不洗牌；用於固定開場的規則測試 |
| `ap P MAX INITIAL` | 啟用玩家 P 的 AP（沒寫就不啟用，沿用原規則） |
| `ap_cost P KIND N` | 動作費用：KIND 可以是 `summon`、`spsummon`、`set`、`activate`、`attack`、`repos` |

操作行的開頭是玩家編號，依序對應核心送出的選擇提示。

| 操作 | 對應提示 |
| --- | --- |
| `P idle summon/spsummon/repos/mset/sset/activate CODE`、`P idle battle`、`P idle end` | 主要階段指令 |
| `P battle attack/activate CODE`、`P battle main2`、`P battle end` | 戰鬥階段指令 |
| `P yesno yes/no` | 是否發動選發效果；一般是／否問題 |
| `P select CODE [CODE...]` | 選卡、選對象、解放、合計選擇；`select finish` 結束可增減選擇 |
| `P counter CODE [CODE...]` | 移除計數器：每個卡號代表移除 1 個，從第一張還有計數器的同名卡移除 |
| `P announce VALUE [VALUE...]` | 宣言：種族、屬性用位元值（例如 `0x2000` 龍族、`0x10` 光屬性），數字直接寫數字，卡名寫卡號 |
| `P rps scissors/rock/paper` | 猜拳 |
| `P sort CODE...` | 自訂排序，第一個代表最上面／最先（可省略，省略時沿用核心預設順序） |
| `P chain CODE`、`P chain pass` | 連鎖窗口 |
| `P option N` | 效果選項 |
| `P position fu_atk/fd_atk/fu_def/fd_def` | 表示形式（可省略） |
| `stop` | 在下一個需要情境回答的提示出現時，結束情境並銷毀決鬥，不需要分出勝負 |

斷言在下一個「情境指定的操作」執行前檢查，或在決鬥結束、遇到 `stop` 時檢查。

| 斷言 | 檢查內容 |
| --- | --- |
| `expect lp P n` | 向核心查詢的 LP |
| `expect count P LOC n` | 指定區域的卡片張數 |
| `expect cards P LOC CODE...` | 指定區域依序的卡號；怪獸區、魔陷區的空格以 0 表示 |
| `expect chain CODE...` | 最近一次完成的連鎖中，各連鎖鏈結的實際處理順序 |
| `expect win P [reason]` | 勝方；reason 1 為 LP 歸零，2 為抽乾牌組 |
| `expect ap P n` | 玩家 P 目前的 AP |
| `expect cost ACTION CODE n` | 目前提示中，該選項的 AP 費用 |
| `expect blocked ACTION CODE` | 目前提示中，該選項因為 AP 不足被擋下 |
| `expect retry` | 上一個回答被核心以 `MSG_RETRY` 拒絕，現在是同一個提示重問。沒寫這行時，核心拒絕回答一律視為失敗 |

### 預設處理的提示

為了讓情境只描述有意義的操作，以下提示會由**測試程式**自動處理，並在紀錄中標成 `default: ...`。這些是測試層的選擇，不屬於戰鬥規則，戰鬥模組也不會替玩家做這些決定：

- **區域**：選第一個空格，自己的怪獸區優先。
- **表示形式**：依序選表側攻擊、表側守備、裡側守備，取第一個可用的。
- **排序**：沿用核心預設順序。
- **非強制連鎖窗口**：只有當下一個情境操作正好是同一玩家的 `chain` 才會發動，否則放棄。
- **強制連鎖**：只有一個選項時自動選；有多個選項時必須寫在情境裡。

其餘選擇提示必須寫在情境裡，否則立即失敗。

### 各提示的實卡情境

`tests/duel/prompts/` 為每種較少見的提示各準備了一個情境，全部使用真卡，並各自查詢核心狀態驗證結果。

| 情境 | 使用的卡 | 驗證的提示 |
| --- | --- | --- |
| `announce_card` | 禁止令 | 宣言卡名 |
| `announce_number` | Side Effects? | 宣言數字（由對手宣言） |
| `announce_race` | Array of Revealing Light | 宣言種族 |
| `announce_attribute` | DNA Transplant | 宣言屬性 |
| `rock_paper_scissors` | Transmission Gear | 雙方猜拳 |
| `select_sum` | Ferret Flames | 合計選擇（「達到」模式） |
| `select_counter` | Anti-Spell 與兩張 Breaker | 計數器選擇 |
| `sort_deck` | Fruits of Kozaky's Studies | 自訂排序 |
| `tribute_retry` | 青眼白龍 | 核心拒絕回答後重新提示 |

### 反向測試

- `tests/duel/negative/*.duel` 的第一行寫 `# expect-fail: <文字>`。
- 該情境必須以非零結束，且輸出含有該文字，才算通過。
- 這類測試用來確認程式出錯時會停下來並說明原因，不會繼續猜下去。

## 與 EDOPro 客戶端的關係

- 執行時只用到 `ocgcore.dll`、`.cdb` 與 `.lua`，沒有用到 EDOPro 客戶端的程式碼、設定或素材。
- `ocgcore.dll` 只依賴 Windows 內建的 UCRT 與 KERNEL32。
- 原本由客戶端負責的工作，目前由戰鬥模組 `native/battle/` 處理：讀卡片資料、找腳本、載入入口腳本、洗牌、解碼訊息與組裝回應。
