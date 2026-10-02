# 無畫面決鬥測試（P1／P2）

不依賴 EDOPro 客戶端，直接以 `ygopro-core` 的 C API 搭配 `BabelCDB` 卡片資料庫與 `CardScripts` Lua 腳本跑決鬥。

## 需求

- Windows 10/11 x64、PowerShell 5.1、git（需在 PATH 上）。
- 不需要 Visual Studio、Python、CMake 或系統管理員權限。編譯器（llvm-mingw）與 SQLite 原始碼由 bootstrap 依 `third_party/versions.lock.json` 下載到 `tools/`，並驗證 SHA256。

## 指令

在 repo 根目錄執行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/bootstrap.ps1   # 還原三個第三方 checkout 與工具鏈（可重複執行）
powershell -ExecutionPolicy Bypass -File scripts/build.ps1       # 產生 build/ocgcore.dll、build/duel_harness.exe
powershell -ExecutionPolicy Bypass -File scripts/test-duel.ps1   # 跑全部情境，紀錄寫到 tests/records/latest/
```

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
| `card P hand/deck/grave/removed/extra CODE [xN]` | 放置卡片 |

操作行的開頭是玩家編號，依序對應核心送出的選擇提示。

| 操作 | 對應提示 |
| --- | --- |
| `P idle summon/spsummon/repos/mset/sset/activate CODE`、`P idle battle`、`P idle end` | 主要階段指令 |
| `P battle attack/activate CODE`、`P battle main2`、`P battle end` | 戰鬥階段指令 |
| `P yesno yes/no` | 是否發動選發效果；一般是／否問題 |
| `P select CODE [CODE...]` | 選卡、選對象、解放；`select finish` 結束可增減選擇 |
| `P chain CODE`、`P chain pass` | 連鎖窗口 |
| `P option N` | 效果選項 |
| `P position fu_atk/fd_atk/fu_def/fd_def` | 表示形式（可省略） |

斷言在下一個「情境指定的操作」執行前檢查，或在決鬥結束時檢查。

| 斷言 | 檢查內容 |
| --- | --- |
| `expect lp P n` | 向核心查詢的 LP |
| `expect count P LOC n` | 指定區域的卡片張數 |
| `expect chain CODE...` | 最近一次完成的連鎖中，各連鎖鏈結的實際處理順序 |
| `expect win P [reason]` | 勝方；reason 1 為 LP 歸零，2 為抽乾牌組 |

### 預設處理的提示

為了讓情境只描述有意義的操作，以下提示會自動處理，並在紀錄中標成 `default` 或 `pass (not scripted)`：

- **區域**：選第一個空格，自己的怪獸區優先。
- **表示形式**：依序選表側攻擊、表側守備、裡側守備，取第一個可用的。
- **排序**：沿用核心預設順序。
- **非強制連鎖窗口**：只有當下一個情境操作正好是同一玩家的 `chain` 才會發動，否則放棄。
- **強制連鎖**：只有一個選項時自動選；有多個選項時必須寫在情境裡。

其餘選擇提示必須寫在情境裡，否則立即失敗。以下提示尚未支援，遇到會明確失敗：計數器、合計選擇、宣言種族／屬性／卡名／數字、猜拳。

### 反向測試

- `tests/duel/negative/*.duel` 的第一行寫 `# expect-fail: <文字>`。
- 該情境必須以非零結束，且輸出含有該文字，才算通過。
- 這類測試用來確認程式出錯時會停下來並說明原因，不會繼續猜下去。

## 與 EDOPro 客戶端的關係

- 執行時只用到 `ocgcore.dll`、`.cdb` 與 `.lua`，沒有用到 EDOPro 客戶端的程式碼、設定或素材。
- `ocgcore.dll` 只依賴 Windows 內建的 UCRT 與 KERNEL32。
- 原本由客戶端負責的工作，目前都在 `native/duel_harness/main.cpp` 中自行處理：讀卡片資料、找腳本、載入入口腳本、解碼訊息與組裝回應。
