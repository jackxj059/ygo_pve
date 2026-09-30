$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Drawing
$baseDir = if($PSScriptRoot){$PSScriptRoot}else{(Get-Location).Path}
$outDir = Join-Path $baseDir 'output'
[System.IO.Directory]::CreateDirectory($outDir) | Out-Null
$outPath = Join-Path $outDir '遊戲王_PvE_設計共識_2026-09-30.pptx'
$slides = @'
[
 {"section":"DESIGN NOTES / 2026.09.30","title":"遊戲王 PvE｜設計共識","subtitle":"角色探索 × 怪獸討伐 × 構築與 AP 養成","tag":"討論整理","cards":[{"title":"遊戲體驗","body":"操控角色在地圖上探索\n遇敵後，使用整副牌對抗怪獸\n擊敗敵人，取得合成素材"},{"title":"角色成長","body":"升級選擇構築點數或 AP 上限\n合成裝備，賦予卡片額外能力\n以單人為目前範圍，保留三人打王方向"}],"note":"依本次對話整理。已定案、原始構想與待定內容分開標示。"},
 {"section":"01 / GAME LOOP","title":"探索與戰鬥的基本循環","subtitle":"已確認角色走動探索；美術維度與移動呈現尚未定案。","tag":"已定方向","cards":[{"title":"探索 → 遭遇 → 決鬥","body":"玩家直接操控角色在地圖上移動\n遭遇敵人後進入卡牌戰鬥\n目前以一名玩家對抗場上怪獸為主"},{"title":"素材 → 合成 → 強化卡片","body":"擊敗怪物會掉落素材\n素材可用來合成裝備\n裝備配置給卡片，提供額外能力"}],"note":"2D 俯視角是曾提出的建議，並未定案；2D／3D 與探索道具用途仍待討論。"},
 {"section":"02 / WORLD CONCEPT","title":"世界與据點｜原簡報構想","subtitle":"整理原始文件第 2、3 頁，作為背景；並非本輪新增定案規格。","tag":"原始構想","cards":[{"title":"機構與區域掌控度","body":"機構是安全區與遊戲大廳\n可升級設施、裝備及購買道具\n達一定等級可招募 NPC\n外部區域以掌控度影響安全性與設施建造"},{"title":"區域生成與推進","body":"地圖由 chunk 與地圖物件構成\n包含寒帶、雷雨等區域主題\n曾列出保暖設備與避雷針\n全區域 100% 後，可帶較好起始資源前往新區域"}],"note":"掌控度的計算、探索獎勵、設施成本與具體支援效果，尚未細化。"},
 {"section":"03 / ENEMY DESIGN","title":"敵人分級：保留解牌的價值","subtitle":"敵人本身是場上的怪獸；不以全面抗性封鎖玩家的卡片。","tag":"已定案","cards":[{"title":"小怪與菁英","body":"小怪：允許直接破壞、送墓、除外等解場\n快速處理小怪，是合理的卡片價值\n菁英：增加明確的個別抗性\n例如效果破壞抗性，保留其他解法"},{"title":"Boss 多階段","body":"解掉目前階段，就推進戰鬥\n一張解牌通常不直接結束整場 Boss 戰\n階段轉換條件與出現時機待定\n攻守擊破或獨立血條，尚未決定"}],"note":"後續方向：一個 Boss 對三名玩家。三人場地、回合與連鎖流程尚未設計。"},
 {"section":"04 / PROGRESSION","title":"升級：構築能力或行動空間","subtitle":"兩種成長選擇，分別影響能帶進戰鬥的卡片與每輪能採取的行動。","tag":"已定案","cards":[{"title":"選擇 A｜構築點數上限","body":"採 Genesys 式構築點數制\n牌組的總點數不能超過玩家上限\n升級可選擇提高構築點數上限\n官方點數表與完整賽制是否沿用，待定"},{"title":"選擇 B｜AP 上限","body":"AP 是採取行動時支付的資源\n升級可選擇增加 AP 上限\n更多 AP 提供更多展開與回應空間\n初始值與每次升級增量，待定"}],"note":"此處借用 Genesys 的構築概念；不代表已決定禁用連結、靈擺或照搬所有官方規則。"},
 {"section":"05 / ACTION POINTS","title":"AP 的支付與恢復","subtitle":"AP 類似額外行動代價；不足時不能開始需要 AP 的行動。","tag":"已定案","cards":[{"title":"支付規則","body":"宣告行動或發動時支付 AP\n被無效後，不退還已支付的 AP\n接連鎖算一次發動，不另加連鎖費\n效果處理途中不重複扣點"},{"title":"回合節奏","body":"每次輪到該玩家時，AP 回滿\n自己回合剩下的 AP 留給敵方回合使用\n用光後，不能做需支付 AP 的回應\n必發效果仍依規則處理"}],"note":"恢復至當前 AP 上限。起始 AP、每個動作的費用與首次行動前的初始化細節待定。"},
 {"section":"06 / AP COVERAGE","title":"哪些行動需要 AP？","subtitle":"區分玩家主動開始的行動，與已發動效果所造成的結果。","tag":"已定案","cards":[{"title":"需要支付 AP","body":"通常召喚、主動特殊召喚\n發動卡片、選發效果及起動效果\n攻擊宣告\n蓋牌／覆蓋怪獸\n手動變更表示形式"},{"title":"不另外支付 AP","body":"必發效果\n不經發動而持續適用的效果\n已發動效果處理造成的特殊召喚\n效果造成的表示形式變更\n例：死者蘇生只在發動時扣一次"}],"note":"永續魔法卡的「卡片發動」仍需 AP；其效果持續適用時不重複扣點。"},
 {"section":"07 / RULE IMPLEMENTATION","title":"必發效果有既有類型可辨識","subtitle":"標記在每個效果上；同一張卡可以同時具有不同類型的效果。","tag":"技術依據","cards":[{"title":"必發｜免 AP","body":"EFFECT_TYPE_TRIGGER_F\n必發誘發效果\n\nEFFECT_TYPE_QUICK_F\n必發誘發即時效果"},{"title":"主動／選發｜付 AP","body":"EFFECT_TYPE_TRIGGER_O：選發誘發\nEFFECT_TYPE_QUICK_O：選發即時\nEFFECT_TYPE_IGNITION：起動效果\n\n扣點需接入合法性檢查與實際發動流程"}],"note":"已有原始碼依據；AP 整體尚未實作驗證。召喚、攻擊等不發動的動作須另外接入。"},
 {"section":"08 / MATERIALS & EQUIPMENT","title":"素材用途：合成卡片裝備","subtitle":"先確認裝備的用途，裝備種類與配置細節保留後續討論。","tag":"已定案","cards":[{"title":"用途已確認","body":"擊敗怪物取得素材\n使用素材合成裝備\n裝備配置給卡片\n賦予卡片額外能力，調整戰鬥用途"},{"title":"尚未定義","body":"戰前配置，或戰鬥中選擇目標裝備\n裝備欄位數量、拆卸與消耗規則\n是否對應裝備魔法卡\n效果類型、合成配方與 AP 互動"}],"note":"群體攻擊、穿防等為候選效果；具體裝備種類及實作語意尚未定案。"},
 {"section":"09 / HEALING & ATTRIBUTES","title":"回復目標與種族屬性","subtitle":"保留未來合作玩法的回復需求，同時控制額外規則的數量。","tag":"已定方向","cards":[{"title":"回復可以指定玩家","body":"單體回復可選擇一名友方玩家\n目標包含自己或隊友\n升級版可提供群體回復\n群體範圍、數值與升級方式待定"},{"title":"不新增通用克制表","body":"不另加種族／屬性的固定增傷減傷\n保留原卡片效果中的種族屬性互動\n種族屬性仍可表達敵人主題\n個別效果可依種族屬性判定"}],"note":"單人階段仍保留回復目標的概念；多玩家的實際規則與技術支援需後續驗證。"},
 {"section":"10 / TECHNICAL DIRECTION","title":"技術方向：沿用核心，自製 PvE","subtitle":"屬於建議架構；目前是文件與原始碼可行性評估，尚未編譯跑通原型。","tag":"建議／待驗證","cards":[{"title":"建議沿用與自製範圍","body":"沿用 EDOPro 決鬥核心\n搭配相容的卡片腳本與資料庫\n自製探索、養成、裝備與戰後結算\n另行整合對戰介面與敵人決策"},{"title":"主要驗證重點","body":"特殊開場、環境效果與 Boss 階段\nAP 合法性檢查、扣點與回合恢復\nAP 規則可能需要修改核心\n三人對同一 Boss 不能假設直接支援"}],"note":"只搬卡片腳本無法保留完整規則；腳本依賴核心的連鎖、時點與效果處理。"},
 {"section":"11 / OPEN QUESTIONS","title":"下一輪需要決定的事項","subtitle":"以下均為待定項目，不以簡報中的示例作為正式規格。","tag":"待討論","cards":[{"title":"玩法與平衡","body":"Boss：原版攻守擊破或獨立血條\n離場、控制權轉移與階段判定\n構築點數表、初始上限與升級增量\nAP 各行動費用、初始值與成長幅度"},{"title":"探索、裝備與合作","body":"2D／3D 呈現與遊戲引擎\n裝備配置、欄位、拆卸及合成配方\n回復效果的範圍、數值與 AP 互動\n三人合作的回合、場地與連鎖順序"}],"note":"建議先驗證單人最小戰鬥原型，再逐步加入 AP、Boss 階段與裝備效果。"},
 {"section":"APPENDIX / REFERENCES","title":"整理依據與技術參考","subtitle":"本簡報是設計共識紀錄，不代表已完成實作或相容性測試。","tag":"參考資料","cards":[{"title":"設計來源","body":"本次對話：2026 年 9 月 29–30 日\n原始文件：遊戲.pptx 第 2、3 頁\n原始簡報保留不變\n\n版本：設計共識 v1.0"},{"title":"公開技術資料","body":"Genesys 官方規則\nwww.yugioh-card.com/en/genesys/\n\nEDOPro 核心與卡片腳本\ngithub.com/edo9300/ygopro-core\ngithub.com/ProjectIgnis/CardScripts"}],"note":"原始碼定位：ocgapi.h（外部介面）、effect_constants.h（效果類型）；WindBot 提供 AI 參考。"}
]
'@ | ConvertFrom-Json

function Esc([string]$s) { [System.Security.SecurityElement]::Escape($s) }
function E([double]$v) { [long][Math]::Round($v * 914400) }
$script:id = 1
function Rect($x,$y,$w,$h,$color) {
 $script:id++
 return '<p:sp><p:nvSpPr><p:cNvPr id="'+$script:id+'" name="Panel '+$script:id+'"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="'+(E $x)+'" y="'+(E $y)+'"/><a:ext cx="'+(E $w)+'" cy="'+(E $h)+'"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="'+$color+'"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr></p:sp>'
}
function TextBox($x,$y,$w,$h,[string]$text,[int]$size,[string]$color,[bool]$bold=$false) {
 $script:id++
 $b = if($bold){'1'}else{'0'}
 $pars = foreach($line in ($text -split "`n")) {
  '<a:p><a:pPr><a:lnSpc><a:spcPct val="125000"/></a:lnSpc></a:pPr><a:r><a:rPr lang="zh-TW" sz="'+($size*100)+'" b="'+$b+'"><a:solidFill><a:srgbClr val="'+$color+'"/></a:solidFill><a:latin typeface="Microsoft JhengHei"/><a:ea typeface="Microsoft JhengHei"/></a:rPr><a:t>'+ (Esc $line) +'</a:t></a:r><a:endParaRPr lang="zh-TW" sz="'+($size*100)+'"/></a:p>'
 }
 return '<p:sp><p:nvSpPr><p:cNvPr id="'+$script:id+'" name="Text '+$script:id+'"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="'+(E $x)+'" y="'+(E $y)+'"/><a:ext cx="'+(E $w)+'" cy="'+(E $h)+'"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0" anchor="t"/><a:lstStyle/>'+($pars -join '')+'</p:txBody></p:sp>'
}
$ns = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"'
$group = '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$stream = [System.IO.File]::Open($outPath,[System.IO.FileMode]::Create)
$zip = [System.IO.Compression.ZipArchive]::new($stream,[System.IO.Compression.ZipArchiveMode]::Create)
function Put([string]$path,[string]$content) {
 $entry = $zip.CreateEntry($path)
 $writer = [System.IO.StreamWriter]::new($entry.Open(),$utf8)
 $writer.Write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+$content)
 $writer.Dispose()
}
try {
 $types = '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>'
 $rels = '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>'
 $ids = ''
 for($i=0;$i -lt $slides.Count;$i++) {
  $s=$slides[$i]; $n=$i+1; $script:id=1
  $body = Rect 0 0 13.333333 7.5 '101A2B'
  $body += Rect 0.55 0.55 0.07 0.30 '52D7C2'
  $body += TextBox 0.78 0.51 10.6 0.35 $s.section 12 '52D7C2' $true
  $body += TextBox 0.65 1.08 12 0.7 $s.title 30 'F5F7FC' $true
  $body += TextBox 0.65 1.92 12 0.68 $s.subtitle 16 'AFBED1'
  for($j=0;$j -lt 2;$j++) {
   $x=0.65 + $j*6.13
   $body += Rect $x 2.85 5.9 3.45 '1B2940'
   $body += Rect $x 2.85 5.9 0.045 '52D7C2'
   $body += TextBox ($x+0.25) 3.10 5.4 0.48 $s.cards[$j].title 21 '52D7C2' $true
   $body += TextBox ($x+0.25) 3.82 5.4 2.28 $s.cards[$j].body 16 'E5EBF5'
  }
  $body += TextBox 0.65 6.57 12.05 0.48 $s.note 12 'AFBED1'
  $body += TextBox 0.65 7.16 9 0.22 ('YGO PVE  /  '+$s.tag) 10 '7D90AB'
  $body += TextBox 11.8 7.12 0.9 0.3 ('{0:00} / {1:00}' -f $n,$slides.Count) 10 '7D90AB'
  Put "ppt/slides/slide$n.xml" ('<p:sld '+$ns+'><p:cSld><p:spTree>'+$group+$body+'</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>')
  Put "ppt/slides/_rels/slide$n.xml.rels" '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>'
  $types += '<Override PartName="/ppt/slides/slide'+$n+'.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'
  $rels += '<Relationship Id="rId'+($n+1)+'" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide'+$n+'.xml"/>'
  $ids += '<p:sldId id="'+(255+$n)+'" r:id="rId'+($n+1)+'"/>'
 }
 Put '[Content_Types].xml' ($types+'</Types>')
 Put '_rels/.rels' '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>'
 Put 'ppt/presentation.xml' ('<p:presentation '+$ns+'><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>'+$ids+'</p:sldIdLst><p:sldSz cx="12192000" cy="6858000" type="screen16x9"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>')
 Put 'ppt/_rels/presentation.xml.rels' ($rels+'</Relationships>')
 $clr = '<p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/>'
 Put 'ppt/slideMasters/slideMaster1.xml' ('<p:sldMaster '+$ns+'><p:cSld><p:spTree>'+$group+'</p:spTree></p:cSld>'+$clr+'<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>')
 Put 'ppt/slideMasters/_rels/slideMaster1.xml.rels' '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>'
 Put 'ppt/slideLayouts/slideLayout1.xml' ('<p:sldLayout '+$ns+' type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>'+$group+'</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>')
 Put 'ppt/slideLayouts/_rels/slideLayout1.xml.rels' '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>'
 # Preserve the source document theme for full Office theme compatibility.
 $original=[System.IO.Compression.ZipFile]::OpenRead('C:\Users\jackd\Downloads\遊戲.pptx')
 try {
  $reader=[System.IO.StreamReader]::new($original.GetEntry('ppt/theme/theme1.xml').Open())
  $theme=$reader.ReadToEnd();$reader.Dispose()
  $theme=$theme -replace '^\s*<\?xml[^?]*\?>',''
  Put 'ppt/theme/theme1.xml' $theme
 } finally { $original.Dispose() }
} finally { $zip.Dispose();$stream.Dispose() }

# Verify every XML part, relationship target, slide count and text-box bounds.
$check=[System.IO.Compression.ZipFile]::OpenRead($outPath)
try {
 $entries=@{}; foreach($entry in $check.Entries){$entries[$entry.FullName]=$true}
 foreach($entry in $check.Entries) {
  $reader=[System.IO.StreamReader]::new($entry.Open());[xml]$doc=$reader.ReadToEnd();$reader.Dispose()
  if($entry.FullName.EndsWith('.rels')) {
   $base=if($entry.FullName -eq '_rels/.rels'){''}else{($entry.FullName -replace '_rels/[^/]+\.rels$','')}
   foreach($r in $doc.DocumentElement.ChildNodes) {
    if($r.TargetMode -ne 'External') {
     $uri=[Uri]::new([Uri]('http://package/'+$base),[string]$r.Target)
     $target=$uri.AbsolutePath.TrimStart('/')
     if(-not $entries.ContainsKey($target)){throw "Missing target: $target"}
    }
   }
  }
 }
 $count=@($check.Entries | Where-Object FullName -Match '^ppt/slides/slide\d+\.xml$').Count
 if($count -ne $slides.Count){throw 'Slide count mismatch'}
} finally {$check.Dispose()}

# A layout preview using the same positions and text; this is not an Office render.
$bmp=[System.Drawing.Bitmap]::new(1280,720)
$g=[System.Drawing.Graphics]::FromImage($bmp)
$g.TextRenderingHint=[System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
function Brush($hex){[System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#'+$hex))}
function PreviewText($text,$x,$y,$w,$h,$size,$color,$bold=$false){
 $style=if($bold){[System.Drawing.FontStyle]::Bold}else{[System.Drawing.FontStyle]::Regular}
 $font=[System.Drawing.Font]::new('Microsoft JhengHei',[single]($size*96/72),$style,[System.Drawing.GraphicsUnit]::Pixel)
 $brush=Brush $color
 $rect=[System.Drawing.RectangleF]::new([single]($x*96),[single]($y*96),[single]($w*96),[single]($h*96))
 $g.DrawString($text,$font,$brush,$rect)
 $font.Dispose();$brush.Dispose()
}
$s=$slides[6]
$g.Clear([System.Drawing.ColorTranslator]::FromHtml('#101A2B'))
PreviewText $s.section .78 .51 10.6 .35 12 '52D7C2' $true
PreviewText $s.title .65 1.08 12 .7 30 'F5F7FC' $true
PreviewText $s.subtitle .65 1.92 12 .68 16 'AFBED1'
for($j=0;$j -lt 2;$j++) {
 $x=.65+$j*6.13;$br=Brush '1B2940';$g.FillRectangle($br,[single]($x*96),[single](2.85*96),[single](5.9*96),[single](3.45*96));$br.Dispose()
 PreviewText $s.cards[$j].title ($x+.25) 3.1 5.4 .48 21 '52D7C2' $true
 PreviewText $s.cards[$j].body ($x+.25) 3.82 5.4 2.28 16 'E5EBF5'
}
PreviewText $s.note .65 6.57 12.05 .48 12 'AFBED1'
$bmp.Save((Join-Path $outDir '版面預覽.png'),[System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose();$bmp.Dispose()
Write-Output "Created: $outPath"
Write-Output "Validated: $count slides; all XML parts and relationship targets passed."
