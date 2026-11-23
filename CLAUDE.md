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
| `SelfTest.swift` | 模擬器自動測試的場景 |

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

## 7. 目前狀態（2026-11-23）

- **v12.16.1 已編譯、截圖看過、安裝檔在 `../安裝檔/NoteApp-v12.16.1.ipa`**，等使用者實機測。照他測 v12.16.0 的回饋改：
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
- 實機要測（v12.16.1）：抽屜跟手拉出、左邊那條往右收回順不順；兩邊交替寫字會不會搶筆；「−」好不好點；旗子；白板的旗子；首頁右緣滑出日誌。語音還沒測（使用者說晚點）。v12.16.0 已測過：恢復 App 可以、跳回記號好用、抽屜標題列沒問題。
- 還沒做／待確認：
  - 檔案拖曳（使用者說暫緩）。
  - 隨手記之後可能要：看別本的隨手記、紙張樣式選擇、抽屜預設寬度。
  - 日誌右上角的鈴鐺（提醒）沒做。
  - 浮動視窗開著時卡片顯示「正以浮窗模式打開」、心智圖交叉線、Markdown 鍵盤編輯。
  - 白板分區儲存第二階段：先不做，等他決定（8 萬筆不見的原因還不知道）。
  - 匯入文件要不要支援 Word、PPT。
