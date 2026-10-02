# ygo_battle（可搬移戰鬥模組）

要把戰鬥搬到另一個 Godot 4.7 專案時，複製這個資料夾，並依下列清單準備依賴即可。模組不依賴 Demo 的主選單、地圖、Autoload 或專案設定。

## 檔案

| 檔案 | 用途 |
| --- | --- |
| `ygo_battle.gdextension` | 讓 Godot 載入原生程式庫 |
| `bin/ygo_battle.windows.template_debug.x86_64.dll` | 戰鬥模組、ygopro-core、Lua、SQLite 全部靜態連結在一起，只依賴 Windows 內建的 UCRT。由 `scripts/build.ps1` 產生，不進 repo |
| `battle_session.gd`（`YgoBattleSession`） | 一場戰鬥：持有決鬥、推進核心、收集紀錄、送出回答；與畫面無關 |
| `battle_screen.tscn` / `.gd` | 最小戰鬥畫面：`attach(session, resources)` / `detach()` |

## 執行時需要的資料（路徑由宿主傳入，模組不寫死）

| 鍵 | 內容 | 本 repo 的位置 |
| --- | --- | --- |
| `scripts_dir` | CardScripts 根目錄 | `third_party/CardScripts` |
| `databases` | 卡片資料庫，可以有多個，先找到的優先 | `third_party/BabelCDB/cards.cdb`、`release-betb.cdb` |
| `images_dir` | `<卡號>.jpg` 卡圖（可省略，沒有圖的卡以文字顯示） | `third_party/card_images/full` |

## 對外介面

GDExtension 提供兩個類別：

- **`YgoContent`**：`open(scripts_dir, databases)`、`card_info(code)`、`description(desc)`，以及靜態方法 `YgoContent.load_ydk(path)`。
- **`YgoDuel`**：`start(content, config)`、`advance()`、`take_events()`、`get_prompt()`、`submit(id, picks)`、`lp()`、`count()`、`cards()`、`origin()`、`winner()`、`win_reason()`、`get_error()`。

**宿主的使用流程：**

```gdscript
var err := []
var content := YgoBattleSession.open_content(resources, err)  # 可在多場戰鬥共用
var session := YgoBattleSession.new()
session.start(content, config)       # config 格式見 docs/godot.md
session.finished.connect(on_result)  # {winner, reason, error}
battle_screen.attach(session, resources)
# 離開畫面：battle_screen.detach()，session 與決鬥都保留，之後可再 attach
# 結束這場決鬥：放掉對 session 的參照
```

提示與事件的欄位定義和 `native/battle/battle.h` 相同，詳見 `docs/battle-module.md`。
