# CLAUDE.md：筆記 App（note-app）

這份是給 Claude Code 讀的工作說明。每次開新的對話都會先讀這裡，請照做。
最後整理：2026-11-22（從 claude.ai「筆記軟體」專案的 Cowork 對話搬過來，那時做到 v12.15.13）。

## 1. 這是什麼

- 使用者王耀元（物理系大四，準備 2027-01 底的研究所考試）自己的 iPad 筆記 App，用來取代 GUGA。程式全部由 Claude 寫，使用者只會基本的 C。
- Swift 6（嚴格並行檢查）、UIKit＋SwiftUI、PencilKit、PDFKit、Vision。iPadOS 26，部署目標 iOS 26.0。
- 用 XcodeGen 產生專案（`project.yml`），在 GitHub Actions 的雲端 Mac 編譯（repo：`hotdogyong/note-app`），使用者用 Sideloadly 裝 `.ipa`。
- **這台 Mac（MacBook Air A1932，8 GB、128 GB）最高只能到 macOS Sonoma，跑不了 Xcode 26，不能在本機編譯。** 一律推到 GitHub 讓雲端編譯。Mac 的硬碟也很滿，不要在本機產生大檔案（不要裝 Xcode、模擬器、大型套件）。

## 2. 跟使用者講話的方式

- 一律繁體中文、台灣用語。專有名詞第一次寫「中文（英文）」。
- 結論先講。一次問很多事：開頭每題幾句話給結論，再依序詳細說明。
- 標題用不編號的 `#`，標題下面空一行放 `&nbsp;`，內文和下一個標題之間也空一行。標題下要再分重點用獨立一行的 `**▍小標**`。
- 回答要完整、不要精簡；但不要寫重複已經說過的填充句。分塊、分層寫，他比較快懂。
- 不要盲目附和；他說的不對、或做法有問題，要直接講。
- 他打字多半用鍵盤；介面上的東西多到放不下時一律要可以滑。
- **外觀、互動以 GUGA 為標準**（他會傳 GUGA 截圖）。他很在意醜、動畫不順。
- 他覺得每版都要用 Sideloadly 裝很累：**一版多做一點，自己在模擬器看過、修好才請他裝**。只說「已經做好」之前一定要真的編譯成功、看過截圖。
- 做不到、不確定的地方要老實講；實機才測得出來的（Pencil 手寫、手勢衝突、順不順）要明講請他測哪幾項。

## 3. 硬性規則（一定要遵守）

- **GitHub 權杖不可以寫進任何檔案**（包括這個 repo、設定檔、腳本）。用 `gh auth login` 存在 Mac 鑰匙圈裡的登入就好。
- 不要做任何依賴 iCloud 的設計（他的 iCloud 滿了）。App 的資料存在「我的 iPad／筆記軟體」。
- 使用者的 email 不能送到任何外部服務。
- 不能刪使用者的資料或檔案，除非他明確要求。舊的安裝檔留著。
- 不要繞過網路、權限的限制。
- 推到 `main` 之前先自己檢查 diff；commit 訊息用中文簡短寫這次改了什麼。

## 4. 每一版的流程

### 4.1 第一次在這台 Mac 用 Claude Code（只做一次；2026-11-22 已完成，資料夾已是 git、接上 origin）

1. 確認 `gh` 裝好、登入過：`gh auth status`。沒有的話請使用者到 https://cli.github.com 下載 macOS 安裝檔安裝，再跑 `gh auth login`（選 GitHub.com → HTTPS → 用瀏覽器登入）。
2. 這個資料夾原本**不是** git 資料夾（以前靠 `tools/watch.sh`＋`tools/sync.pl` 用權杖上傳）。改成 git：
   ```
   git init -b main
   git remote add origin https://github.com/hotdogyong/note-app.git
   git fetch origin main
   git reset --mixed origin/main      # 只改 git 的紀錄，不動檔案
   git status                          # 看本機比 GitHub 多改了哪些（v12.15.13 的日誌面板還沒推）
   ```
   確認 `git status` 列出來的差異合理再 commit、push。
3. `.sync/`、`tools/watch.sh`、`tools/sync.pl` 是舊的上傳方式，先留著不要刪（Claude Code 不能用時的備案）。

### 4.2 改版本號

- `Sources/ContentView.swift` 的 `let appVersion = "v12.x.y"`
- `project.yml` 的 `MARKETING_VERSION: 12.x.y`
- 兩個要一起改。小修正加最後一碼（12.15.13 → 12.15.14）。

### 4.3 編譯

- `git push origin main` 會同時跑兩個 workflow：`build`（真機的 ipa）和 `sim`（iPad 模擬器截圖）。
- 看進度：`gh run list --limit 4`、`gh run watch <id>`。一次約 3～4 分鐘，模擬器約 6～12 分鐘。
- 編譯錯誤：`git fetch origin ci-results && git show origin/ci-results:errors.txt`（`status.txt` 有對應的 commit）。
- 偶爾會是 GitHub 自己的問題（例如「Upload full log」失敗但編譯成功）：看 `gh run view <id>` 每一步的結果再判斷，必要時重跑 `gh run rerun <id>`。
- 安裝檔：`gh release download latest -p NoteApp.ipa -O ../安裝檔/NoteApp-v12.x.y.ipa --clobber`（`安裝檔` 資料夾在這個 repo 的上一層；舊的不要刪）。

### 4.4 模擬器截圖（自動測試）

- 場景清單：`ci/scenes.txt`，一行一個。**第一個是暖機，截圖常常不準，放 `board` 當第一個。** 每個場景跑 20 秒。
- 截圖在 `ci-shots` 分支：`git fetch origin ci-shots`，再用 `git show origin/ci-shots:<場景>.jpg > /tmp/<場景>.jpg` 拿出來看（要看圖就讀那個檔）。`status.txt` 寫是哪個 commit 的。
- 場景的程式在 `Sources/SelfTest.swift`：`run()` 依場景名稱建好筆記本或白板，`notebookOpened(view)` 打開後做事；`SelfTest.show(text)` 會在畫面上顯示一段結果文字（截圖看得到）。`SelfTest.sceneDone` 防止浮動視窗裡的筆記本又觸發一次。
- 現有場景（挑相關的放進 scenes.txt）：board、notebook、home、pinhome、logbook、notetools、textsel、cardtitle、pagepos、undoink、clip、winsplit、winfull、pills、tidytree、textzone、importdoc、subboard、linkedit、texttidy、textlinks、textstyle、markdown、cards、outline、pdfoutline、boardimage、manypens、frame、tiles、tilestore、tiledboard、collapsed、strokesN（例如 strokes66000）。
- 新功能盡量加一個場景，把要看的狀態直接做出來（例如畫面右下角放一張縮圖看匯出的樣子）。

### 4.5 做完一版

1. 確認編譯成功、截圖看過、有問題的修好。
2. 下載 ipa，改名 `NoteApp-v12.x.y.ipa` 放到 `../安裝檔/`。
3. 更新這份 CLAUDE.md 的「目前狀態」。
4. 跟使用者報告：照第 2 節的格式，講做了什麼、怎麼用、要他實機測哪幾項。

## 5. 程式在哪裡（Sources/）

| 檔案 | 內容 |
|---|---|
| `ContentView.swift` | 版本號、首頁外框（側邊欄、釘選區、分頁列 `NotebookTabBar`、日誌面板的位置、空間不足提醒）、檔案清單說明 |
| `LibraryModel.swift` | 資料夾、筆記本的清單、排序、釘選、改名規則 `uniqueNames`、匯入、分頁 |
| `LibraryViews.swift` | 首頁的格子、長按選單、新增選單 |
| `Models.swift` | 資料結構：`NotePage`、`PageRow`、`TextBox`（含便利貼、跳轉捷徑）、`ImageBox`、`PageClip`、`ClipSync`、`PageJump` |
| `Store.swift` | 存檔讀檔、資料夾路徑、歷史版本、`transferRows`（搬／複製頁到別本）、存檔失敗回報 `reportWriteFailure`、`freeSpace` |
| `NotebookEditor.swift` | 筆記本外框（SwiftUI）：工具列、浮動視窗、分屏全屏、各種 sheet、`NotebookModel` |
| `NotebookView.swift` | 筆記本／白板本體（UIKit，最大的檔案）：捲動縮放、手勢、文字方塊、圖片、剪刀、圖釘、區塊、套索、便利貼、捷徑、選取 PDF 文字、反相 |
| `PageViews.swift` | 一頁：`NotePageView`（畫布、PDF、文字、圖片、連線、剪去白板的框、反相層、文字選取層）、`PageRenderer`（匯出、縮圖）、`PDFStore`、`Thumbnail` |
| `TextAndImage.swift` | `TextBoxView`（含便利貼手寫畫布）、`ImageEditorView`、`TextBar`、`MathRenderer`（KaTeX） |
| `TextLinks.swift` | 文字方塊外框樣式、方塊之間的連線、一鍵整理的面板 |
| `BoardCards.swift` | 白板上的筆記本卡片 `CardCover`、浮動視窗 `BoardWindowView`／`BoardWindowsLayer` |
| `BoardMarks.swift`、`BoardSettings.swift` | 白板的圖釘、區塊；白板設定面板 |
| `BoardTileStore.swift`、`BoardTileCheck.swift` | 白板分區儲存 |
| `PenBox.swift` | 筆盒（停靠、收起、切換筆盒） |
| `StrokeTools.swift` | 選取框、變形、圖形校正 |
| `InsertMenu.swift` | 長按空白處的一圈按鈕、照片／相機／檔案 |
| `NotebookSheets.swift` | 概覽、搬移／複製頁面（`MovePagesSheet`、`PagePositionPicker`、`WithinMoveSheet`） |
| `PageTools.swift` | 跳轉捷徑的選擇畫面、OCR（`TextRecognizer`、`OCRSheet`） |
| `Logbook.swift` | 日誌面板（照 GUGA 的 My Logbook）、自己寫的日誌條 `LogNotes` |
| `ActivityLog.swift` | 修改紀錄（每天改了哪些頁；只打開看不算） |
| `SelfTest.swift` | 模擬器自動測試的場景（`RemoteSelfTest`：App 自己連自己的區網服務） |
| `RemoteAccess.swift` | 讓 Mac 上的 Claude 透過區網讀寫筆記：服務、配對、API、設定裡的開關（Mac 端 `tools/noteapp.py`） |

## 5.1 直接讀寫使用者 iPad 上的筆記（v12.17.0 起）

- 使用者在 iPad「首頁 → 設定 → 讓 Claude 連進來」打開，筆記軟體開在前景、跟 Mac 同一個 Wi-Fi。第一次：`python3 tools/noteapp.py pair <iPad 上的 6 位數配對碼>`（找不到就加 `--host <設定畫面上的位址>`）。鑰匙存在 `~/.config/noteapp/config.json`，**不要放進 repo**。
- 常用：`list`、`current`（現在開著哪本、哪頁、看得到的範圍）、`show <本> --from 3 --to 5`、`image <本> --page 3 -o /tmp/p.jpg`（再讀圖看排版）、`add <本> <json>`、`pages <本> <json>`、`edit`、`delete`、`outline`、`new`。JSON 格式寫在 `tools/noteapp.py` 開頭。
- 座標是頁面座標（A4 595×842；白板是整張大頁面，`current` 的 visible 是畫面看得到的那塊）；`size` 跟工具列上的字級一樣。沒給 x、y 會自動往下排。
- 打開中的那本走畫面改（可以按上一步復原；加頁會清掉復原紀錄）。刪方塊、改別人寫的東西之前先問使用者。
- 方塊寬度用原始字估：有 LaTeX 的方塊在畫面上框會比排好的式子寬一點，要精準就給 width。

## 6. 踩過的雷（改之前先看）

- **iPad 空間滿了，存檔會失敗**：以前 `try?` 吞掉錯誤，筆跡「重新載入就不見」。現在 `Store.writePending` 失敗會留著記憶體那份、15 秒後重試，並跳警告。存檔相關的程式不可以再用 `try?` 默默吞錯。
- SwiftUI 自訂 `==` 的型別（例如 `BoardWindow`）一定要比所有會影響畫面的欄位，不然改了不會重畫（分屏分隔線就是這樣壞的）。
- `@MainActor` 要緊貼在宣告上面；在 `@MainActor` 和 `enum TextPrompt` 中間插東西會讓屬性跑到別的型別上 → Swift 6 編譯錯。
- SwiftUI 的 GeometryReader 座標跟 UIKit 不一樣：在兩邊傳位置用螢幕座標（`frame(in: .global)` ↔ `convert(_, from: nil)`）。
- PencilKit 自己的復原紀錄一律忽略（`NoteCanvas.ignoredUndo`），全部由筆記本的 `history` 記；`committedDrawing` 是上一步的狀態。
- 白板的狀態列藏起來了（`BoardStatusBar`），白板捲動 `scrollsToTop = false`（以前點最上面會跳走）。
- 頁面反相是在頁面上蓋一層白色 `differenceBlendMode`，只是顯示。
- 匯出、縮圖裡的便利貼：展開會擋到課本（看那一塊的像素＋PDF 的字）、筆跡、其他方塊、圖片就畫成小圖示。
- 模擬器沒辦法用 Pencil，手寫相關的只能測資料流程（例如 `undoink` 場景照 PencilKit 的順序假裝呼叫代理）。

## 7. 目前狀態（2026-11-26）

- **v12.17.0 已編譯、截圖看過、安裝檔在 `../安裝檔/NoteApp-v12.17.0.ipa`**：
  - 讓 Mac 上的 Claude 連進來（`RemoteAccess.swift`、`tools/noteapp.py`，見 5.1）：NWListener 埠 8765＋Bonjour `_noteapp._tcp`；配對碼換鑰匙（錯 5 次換碼）；進背景關、回前景開。API：GET /ping /notebooks /current /notebooks/{id} /notebooks/{id}/image；POST /pair /notebooks /notebooks/{id}/texts /pages /outline；PATCH、DELETE /notebooks/{id}/texts/{box}。筆記本可用編號、名稱、current。場景 `remote`、`remoteboard`、`remotesettings`。
  - 外框顏色多一格 #73B8FF（`TextBoxStyle.palette` 第 13 個）；字級選單改 16～72。
  - 實機要測：打開開關時跳「尋找區域網路裝置」要按允許；Mac 配對（Bonjour 找不找得到 iPad）；我加的方塊即時出現、上一步能復原；App 進背景再回來還連得到。
- **v12.16.6 已編譯、安裝檔在 `../安裝檔/NoteApp-v12.16.6.ipa`**：文字方塊工具列的字級數字改成按鈕（`TextBar.sizeButton`），點了選常用字級（8～64）或「輸入數字…」（數字鍵盤、可小數，4～200，以 A4 為準；`NotebookView.setTextSize`、`promptTextSize`）。
- v12.16.5 已編譯、截圖看過、安裝檔在 `../安裝檔/NoteApp-v12.16.5.ipa`：白板設定面板「新文字方塊的框」以前字被擠成直的 → 字一行、按鈕一行（`TextFrameDefaultRow`），多一顆「其他…」打開卡片樣式面板直接改預設（`TextStyleDefault.presentEditor`、`TextStylePanel(editingDefault:)`）；筆記本 ⋯ 選單也有「其他框的樣式…」。場景 `boardsettings`、`framedefault`。
- v12.16.4 已編譯、安裝檔在 `../安裝檔/NoteApp-v12.16.4.ipa`（使用者沒裝 12.16.2，直接裝 12.16.3，回報白板不能縮放、點兩下新增變難）：
  - 手掌防誤觸改成只擋長按的一圈按鈕（使用者原意）：Pencil 寫字中、放開 0.8 秒內、觸碰面積大（majorRadius > 32，長按跳出那一刻再看一次）不跳；手掌先按著再下筆會取消。縮放、捲動、點兩下都不再擋。以前白板程式載入筆跡也被當成 Pencil 在寫（`silent` 的筆跡變化現在不算）。
  - 大綱長按拖曳（使用者選「拖到哪就停在哪」）：`NotebookData.outlineManual`＝true 後照陣列順序顯示（第一次拖時把照頁碼的順序存下來）；新加的插在照頁碼該在的位置；`moveOutline(id, parent:, before:)`；放到一項中間＝下一層，放到兩項之間＝插入（手指左右移 36 點換一層）；拖到上下緣自動捲；長按選單拿掉。場景 `outlinedrag`。
  - 新文字方塊的框：筆記本「⋯ → 新文字方塊的預設 → 框」、白板齒輪面板，直接選沒有框／藍框（`TextFrameDefaultPicker`，分深淺紙）。
- v12.16.3：
  - 數學式：沒用 $$ 包的 `\begin{aligned}` 等環境也排版（`MathRenderer.bareEnvironments`，auto-render 加環境的分隔符）；排版失敗不再永遠顯示原文（`failedAt` 30 秒後可再排、每段 12 秒逾時換新網頁、網頁被系統關掉 `webViewWebContentProcessDidTerminate` 會重開）。使用者白板上有 $ 的那段在模擬器排得出來，實機沒排出來的原因推測是網頁被系統關掉或卡住。新場景 `mathpaste`。
  - 大綱改用系統 List：往左滑改名、加下一層、刪除；往右滑升一層、降一層（`setOutlineParent`）；長按選單也有。舊的自製 `SwipeRow` 沒在用了。
- v12.16.2（11/24 的回饋）：
  - 語音：按「完成」以前會被當成點外面，點兩下新增的空方塊先被收掉、字沒地方放 → 語音黑色膠囊排除在手勢外、語音中的目標方塊不收；句號拿掉（句尾刪、句中換逗號）；語音詞庫 `VoiceWords`（一行一詞＝提示，「聽錯 → 正確」＝自動改；膠囊上的書本、長按麥克風）；一句一個方塊不再疊（後面的不往上挪）。
  - 文字方塊超出頁面右邊：有地方就在頁邊換行（改固定寬度），太靠右就往左移（`keepInsidePage`）；選取中的方塊旁 44 點內長按不跳圓盤。
  - 卡片樣式面板放進 ScrollView（以前上下被切）；預設樣式分深色紙、淺色紙（`TextStyleDefault.load(dark:)`），沒存過＝淡紫藍圓角外框（mode 2）。
  - 點狀態列捲回第一頁前自動插旗（`scrollViewShouldScrollToTop`）。
  - 大綱：PDF 目錄打開面板就自動併進大綱，一個列表。
  - 手掌防誤觸：Pencil 寫字中和放開 0.5 秒內，手指的點、長按、雙指點、縮放、上下左右捲動都不算；很大一片的觸碰任何時候都不算（`pencilBusy`、`PalmScrollView`）。
  - 圖片可以拖到上下頁、左右旁頁（`EdgeDragging` 讓圖片也用選取框的邊緣自動捲動；放開 `transferImage`）。沒有自動測試場景，要實機測。
- v12.16.1：
  - 隨手記抽屜重寫（`DraftDrawerState`、`DraftDrawerLayer`）：右邊緣往內滑或拉把手，紙跟著手指出來，放手的地方＝寬度（太窄、往右甩就收回）；抓左邊那條往右拖收回；紙＝外面那頁的 `paperStyle`；抽屜裡只留一排工具（`draftRowContent`），沒有選字、剪刀、標題列。
  - 外面那本畫進抽屜底下：放開後在交界切斷（`NotebookView.trimUnderDrawer`，`Drafts.edgeX` 是抽屜左邊緣的螢幕座標）。
  - 心智圖「−」：原本疊在選取方塊拉新方塊的灰點上 → 選取中的方塊放到灰點外面（`foldActive`），30 點、摸得到範圍外擴 8（`FoldButton`）。
  - 跳回記號換成旗子 🚩：頁面上有橘色小旗子（`refreshPlaceFlags`），用掉的消失；白板也能用（記中心點＋縮放；圖釘、區塊跳之前自動記）。
  - 首頁從最右邊往內滑叫出日誌，面板往右滑收回（`ContentView.logDrag`）。
  - 新場景 `draftpull`（假裝手指拉出抽屜＋畫一條橫過交界的線）。
- v12.16.0 做了：
  - 大綱、書籤、剪去白板的列表跳頁後收起四方格面板（縮略圖不收）。
  - 白板分屏時按「收起視窗」，左下角百分比那一排回到左邊（`updateBoardLeftInset`）。
  - 反相改成三層混合：深灰底、米白字（`NotePageView.setInverted`）。彩色字會變補色（紅→青），這是反相本來就會的。
  - 跳回記號（`PlaceMarkButton`、`NotebookView.placeMarkTapped/navigate/rememberPlace`）：點＝放記號／跳回並互換；跳頁前自動記；長按列全部；只記到關掉這本；白板沒有。
  - 6 小時內重進 App 回到那一本＋白板浮窗（`SessionRestore.swift`）。
  - 心智圖折疊（`TextBox.branchFolded`、`MindFold`、`NotePageView.applyFolds`）：選取方塊時有分支的旁邊出現「−」；收起的顯示橘色數字；長按圓圈「只展開到第 N 層」；匯出也不畫收起的。
  - 語音轉文字（`VoiceInput.swift`）：iPadOS 26 `SpeechTranscriber`（zh-TW）優先，不支援就退回 `SFSpeechRecognizer`＋物理術語提示；文字工具列的麥克風（打進方塊），長按一圈的「語音」（一句一個方塊往下排）。不存錄音。
  - 隨手記（`Drafts.swift`；`NotebookMeta.draftOf`）：每本筆記本一本藏起來的隨手記（首頁、搜尋、日誌不列）；右下角把手或右邊緣下半段往內滑拉出；橫的白紙 842×595；主題＝一次拉出到「換到別本」或「隔 6 小時再進來」為止，結束時沒寫就拿掉、有寫就問保留／不保留（不保留進最近刪除）；套索「放進筆記本」貼到外面那本；整頁插在外面目前這頁後面（`receiveRows`，會清掉那本的復原紀錄）。使用者已關掉系統的「從角落滑動」快速備忘錄。
- 等 CI 的注意事項：`gh run list`／`gh run watch` 的狀態不可靠（會比工作本身先顯示 completed）。一律以 `ci-results`、`ci-shots` 的 `status.txt` 的 commit 等於這次 commit 為準。sim 的 concurrency 會取消前一次，所以上一版截圖沒出來前不要推。
- 實機要測（v12.16.4）：白板縮放、點兩下新增恢復；手掌碰到不跳圓盤；大綱長按拖曳順不順、會不會跟往左右滑打架；右上角選框。（v12.16.3 的：白板上那兩段數學式重開後排不排得出來、大綱往左／往右滑。）（v12.16.2 的：語音點兩下＋麥克風打進方塊、詞庫、手掌防誤觸會不會擋到正常操作、圖片拖到旁頁、文字方塊收進頁邊、拉角不跳圓盤。）（v12.16.1 的：抽屜跟手拉出、左邊那條往右收回順不順；兩邊交替寫字會不會搶筆；「−」好不好點；旗子；白板的旗子；首頁右緣滑出日誌。）v12.16.0 已測過：恢復 App 可以、跳回記號好用、抽屜標題列沒問題。
- 還沒做／待確認：
  - 檔案拖曳（使用者說暫緩）。
  - 隨手記之後可能要：看別本的隨手記、紙張樣式選擇、抽屜預設寬度。
  - 日誌右上角的鈴鐺（提醒）沒做。
  - 浮動視窗開著時卡片顯示「正以浮窗模式打開」、心智圖交叉線、Markdown 鍵盤編輯。
  - 白板分區儲存第二階段：先不做，等他決定（8 萬筆不見的原因還不知道）。
  - 匯入文件要不要支援 Word、PPT。
