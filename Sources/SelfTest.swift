import SwiftUI
import UIKit
import PencilKit
import PDFKit

// SelfTest.swift：自動測試用的場景（v12.9.9）
// GitHub 的雲端 Mac 會在 iPad 模擬器裡用「-selftest 場景名稱」啟動 App，等 20 秒後截圖，
// 讓 Claude 不用等使用者就能自己看到畫面（排版、有沒有閃退、功能有沒有出現）。
// 平常使用時沒有這個參數，這個檔案什麼都不會做。場景清單在 ci/scenes.txt。

@MainActor
enum SelfTest {
    static var scene: String? { UserDefaults.standard.string(forKey: "selftest") }

    static weak var library: LibraryModel?
    static var sceneDone = false
    static var windowMode: BoardWindowMode?
    static var otherNotebook: NotebookMeta?            // draftend：寫完隨手記之後換過去的那一本          // winsplit、winfull：新開的浮動視窗一開就是這個樣子

    static func run(_ library: LibraryModel) {
        Self.library = library
        guard let scene = scene, scene != "home" else { return }
        UserDefaults.standard.set(scene == "collapsed" || scene == "pills", forKey: "tabsCollapsed")   // 只有 collapsed、pills 場景把分頁那一排收起來
        UserDefaults.standard.set(scene == "pills", forKey: "boardLeftToolsHidden")    // pills：白板上面兩個膠囊都收起來（v12.15.1）
        UserDefaults.standard.set(scene == "pills", forKey: "boardRightToolsHidden")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if scene.hasPrefix("strokes"), let count = Int(scene.dropFirst(7)) {
                // 很多筆的白板（例如 strokes66000）：看 PencilKit 一張畫布畫不畫得出這麼多筆。
                // 使用者實機壓力測試到 80,000 筆時筆跡整個不見（2026-11-14）
                let meta = library.addBoard(in: nil, title: "\(count) 筆", width: 100 * 842, height: 100 * 595)
                if let page = Store.loadNotebook(meta.id).rows.first?.pages.first {
                    let strokes = BoardTileCheck.makeStrokes(count: count, markers: 0,
                                                             origin: CGPoint(x: page.spec.width / 2 - 1500, y: page.spec.height / 2 - 1500),
                                                             spread: CGSize(width: 3000, height: 3000))
                    Store.saveDrawing(PKDrawing(strokes: strokes), pageID: page.id)
                }
                library.openNotebook = meta
                return
            }
            switch scene {
            case "board":
                library.openNotebook = library.addBoard(in: nil, title: "測試白板", width: 100 * 842, height: 100 * 595)
            case "frame":
                // 白板＋筆盒選「區塊」工具：看筆盒有沒有多一顆、提示有沒有出來
                library.openNotebook = library.addBoard(in: nil, title: "測試白板", width: 100 * 842, height: 100 * 595)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    PenBoxModel.shared.select(.frame)
                }
            case "tiles":
                // 分區儲存的基本工具：拆開、存檔、讀回來對不對（結果用一個視窗顯示，截圖看）
                let text = BoardTiles.selfCheck(count: 6000)
                let alert = UIAlertController(title: "分區儲存自動測試", message: text, preferredStyle: .alert)
                let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                scene?.keyWindow?.rootViewController?.present(alert, animated: false)
            case "tilestore":
                // 分區儲存接到存檔系統之後（v12.11.0）：照真的存檔流程跑一遍，每一步核對筆數
                show(BoardTileCheck.run())
            case "tiledboard":
                // 一張已經是分區儲存的白板（3,000 筆在正中間）：打開、關開分區、存檔、復原（NotebookView.selfTestTiles）
                let meta = library.addBoard(in: nil, title: "分區測試白板", width: 100 * 842, height: 100 * 595)
                if let page = Store.loadNotebook(meta.id).rows.first?.pages.first {
                    let strokes = BoardTileCheck.makeStrokes(count: 3000, markers: 30,
                                                             origin: CGPoint(x: page.spec.width / 2 - 1500, y: page.spec.height / 2 - 1500),
                                                             spread: CGSize(width: 3000, height: 3000))
                    let drawing = PKDrawing(strokes: strokes)
                    Store.saveDrawing(drawing, pageID: page.id)
                    _ = BoardTiles.enable(page.id, drawing: drawing)
                }
                library.openNotebook = meta
            case "notebook":
                library.openNotebook = library.addNotebook(in: nil)
            case "collapsed":
                // 直式、分頁收起來、名稱很長（v12.12.1）：上面那一排要放得下，四宮格和頁數排成一列
                library.openNotebook = library.addNotebook(in: nil, title: "IEM 工程數學_OCR版 第一冊")
            case "outline", "outlinedrag":
                // 大綱分層、往左滑的按鈕（v12.11.0）：筆記本畫面會自己打開左邊面板的大綱，第一項是滑開的
                let meta = library.addNotebook(in: nil)
                var data = Store.loadNotebook(meta.id)
                if let page = data.rows.first?.pages.first {
                    let a = OutlineItem(title: "第一章 靜電學", pageID: page.id)
                    var b = OutlineItem(title: "1.1 電荷", pageID: page.id)
                    b.parentID = a.id
                    var c = OutlineItem(title: "1.1.1 例題", pageID: page.id)
                    c.parentID = b.id
                    var d = OutlineItem(title: "1.2 電荷守恆", pageID: page.id)
                    d.parentID = a.id
                    var e = OutlineItem(title: "第二章（收合起來的）", pageID: page.id)
                    e.collapsed = true
                    var f = OutlineItem(title: "2.1 看不到這一項才對", pageID: page.id)
                    f.parentID = e.id
                    let g = OutlineItem(title: "沒有下一層的一項", pageID: page.id)
                    data.outline = [a, b, c, d, e, f, g]
                    Store.saveNotebook(data, id: meta.id)
                }
                library.openNotebook = meta
            case "logbook":
                // v12.15.13：首頁的日誌面板（今天改過兩本、一條自己寫的日誌）
                let a = library.addNotebook(in: nil, title: "電磁學 Griffiths 筆記")
                let b = library.addNotebook(in: nil, title: "工數習題")
                for meta in [a, b] {
                    let data = Store.loadNotebook(meta.id)
                    for row in data.rows { for page in row.pages { ActivityLog.touch(pageID: page.id) } }
                }
                LogNotes.set([LogNote(text: "讀完 Griffiths 2.3，高斯定律的題目還要再練")], day: ActivityLog.dayKey(Date()))
                library.goHome()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { library.logbookOpen = true }
            case "pinhome":
                // v12.15.11：釘選、資料夾和筆記本同名（留在首頁看）
                let folder = library.addFolder(in: nil, name: "測試")
                let same = library.addNotebook(in: nil, title: "測試")
                let lecture = library.addNotebook(in: nil, title: "電磁學講義")
                library.togglePin(ItemRef.folder(folder.id))
                library.togglePin(ItemRef.notebook(lecture.id))
                _ = same
                library.goHome()
            case "cardtitle":
                // v12.15.11：白板上很長的卡片標題排兩行，不要「…」
                library.openNotebook = library.addBoard(in: nil, title: "標題測試白板", width: 100 * 842, height: 100 * 595)
            case "notetools", "textsel":
                // v12.15.11：便利貼（展開、收起）、跳轉捷徑；選取文字＋反相
                if let url = makeOutlinePDF(), library.importPDF(from: url, into: nil),
                   let meta = library.library.notebooks.last(where: { $0.title.hasPrefix("目錄測試") }) {
                    library.openNotebook = meta
                }
            case "pagepos":
                // v12.15.10：同一本裡移動頁面的位置選單（六頁的 PDF，選第 4 頁「移到這本的其他位置」）
                if let url = makeOutlinePDF(), library.importPDF(from: url, into: nil),
                   let meta = library.library.notebooks.first(where: { $0.title.hasPrefix("目錄測試") }) {
                    library.openNotebook = meta
                }
            case "pdfoutline":
                // PDF 自帶的目錄（v12.11.1）：做一份有三層目錄的 PDF 匯入；面板打開後自動「在 1.2 那一列按改名」，
                // 應該整份搬進我的大綱、層級照舊、那一項改了名、下面不再列 PDF 的目錄
                if let url = makeOutlinePDF(), library.importPDF(from: url, into: nil),
                   let meta = library.library.notebooks.first(where: { $0.title.hasPrefix("目錄測試") }) {
                    library.openNotebook = meta
                }
            case "boardimage":
                // 白板貼圖的大小（v12.11.1）：打開後貼三張（橫的、直的、很小的），回報各佔幾格（NotebookView.selfTestImages）
                library.openNotebook = library.addBoard(in: nil, title: "貼圖測試白板", width: 100 * 842, height: 100 * 595)
            case "cards":
                // 白板上的筆記本（v12.12.0）：打開白板後放兩張卡片、開兩個浮動視窗（notebookOpened 裡做）
                library.openNotebook = library.addBoard(in: nil, title: "卡片測試白板", width: 100 * 842, height: 100 * 595)
            case "linkedit", "texttidy":
                // 連線改樣子＋選取一條線；一鍵整理（v12.14.0）
                library.openNotebook = library.addBoard(in: nil, title: scene == "texttidy" ? "整理測試白板" : "線的樣子測試白板",
                                                        width: 100 * 842, height: 100 * 595)
            case "importdoc", "subboard":
                // 白板匯入文件（Markdown、PDF）、子白板（v12.14.0）：notebookOpened 裡匯入、放卡片、開一個視窗
                library.openNotebook = library.addBoard(in: nil, title: scene == "subboard" ? "子白板測試" : "匯入文件測試",
                                                        width: 100 * 842, height: 100 * 595)
            case "mathpaste":
                // v12.16.3：使用者白板上沒排出來的數學式
                library.openNotebook = library.addBoard(in: nil, title: "數學式測試", width: 100 * 842, height: 100 * 595)
            case "boardsettings", "framedefault":
                // v12.16.5：白板設定面板裡「新文字方塊的框」；framedefault 再打開「其他…」的面板
                library.openNotebook = library.addBoard(in: nil, title: "設定測試", width: 100 * 842, height: 100 * 595)
            case "mindfold", "voice":
                // v12.16.0：心智圖折疊；語音的膠囊和「一句一個方塊」
                library.openNotebook = library.addBoard(in: nil, title: "測試白板 " + scene, width: 100 * 842, height: 100 * 595)
            case "draftpull":
                // v12.16.1：手指從右邊緣拉出隨手記（紙跟外面這本一樣）；外面畫一條橫過交界的線要被切斷
                library.openNotebook = library.addNotebook(in: nil, title: "熱統筆記")
            case "drafts", "draftend":
                // v12.16.0：隨手記。drafts：拉出來、寫一行、整頁放進筆記本；draftend：寫了之後換到別本，問要不要保留
                let a = library.addNotebook(in: nil, title: "電磁學 Griffiths 筆記")
                if scene == "draftend" { otherNotebook = library.addNotebook(in: nil, title: "工數習題") }
                library.openNotebook = a
            case "placemarks", "invert":
                // v12.16.0：跳回記號；反相的新顏色（反相用白紙，像課本 PDF）
                let meta = library.addNotebook(in: nil, title: scene == "invert" ? "反相測試" : "記號測試")
                if scene == "invert" {
                    var data = Store.loadNotebook(meta.id)
                    if !data.rows.isEmpty, !data.rows[0].pages.isEmpty {
                        data.rows[0].pages[0].paper = PaperStyle(pattern: 4, color: 1)
                        Store.saveNotebook(data, id: meta.id)
                    }
                }
                library.openNotebook = meta
            case "winsplit", "winfull", "clip", "tidytree", "pills", "wintuck":
                // v12.15.0：分屏、全屏的浮動視窗；視窗裡剪一塊貼到白板；四層的一鍵整理
                if scene == "winsplit" || scene == "pills" || scene == "wintuck" { windowMode = .split }
                if scene == "winfull" { windowMode = .full }
                library.openNotebook = library.addBoard(in: nil, title: "視窗測試 " + scene, width: 100 * 842, height: 100 * 595)
            case "textzone":
                library.openNotebook = library.addNotebook(in: nil, title: "文字方塊測試")
            case "undoink":
                // v12.15.7：照 PencilKit 的順序假裝寫幾筆、按上一步／重做，看筆跡有沒有不見
                library.openNotebook = library.addNotebook(in: nil, title: "復原測試")
            case "textlinks":
                // 文字方塊的外框樣式、連線（v12.13.0）：白板上放幾個方塊和線，選取其中一個（看四邊的點）
                library.openNotebook = library.addBoard(in: nil, title: "連線測試白板", width: 100 * 842, height: 100 * 595)
            case "textedge":
                // v12.16.2：方塊超出頁面右邊要收進來；預設樣式；卡片樣式面板放不下可以滑
                library.openNotebook = library.addNotebook(in: nil, title: "文字邊界測試")
            case "textstyle":
                // 同上，在一般筆記本裡，而且打開「卡片樣式」面板
                library.openNotebook = library.addNotebook(in: nil, title: "連線測試")
            case "manypens":
                // 筆盒超過 10 支筆（v12.11.0）：筆的那一段固定長度、用滑的
                library.openNotebook = library.addNotebook(in: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    for _ in 0 ..< 6 { PenBoxModel.shared.add(.pen) }
                }
            case "markdown":
                library.openNotebook = library.addMarkdownNotebook(in: nil)
            case "remote":
                // v12.17.0：App 自己連自己的區網服務（跟 Mac 上的 noteapp.py 走一樣的路）：配對、加頁、加文字方塊、拿頁面的圖
                library.openNotebook = library.addNotebook(in: nil, title: "Claude 連線測試")
            case "remoteboard":
                library.openNotebook = library.addBoard(in: nil, title: "Claude 白板測試", width: 100 * 842, height: 100 * 595)
            case "remotesettings":
                RemoteAccess.shared.enabled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let vc = UIHostingController(rootView: SettingsSheet().environmentObject(library))
                    vc.modalPresentationStyle = .formSheet
                    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                    scene?.keyWindow?.rootViewController?.present(vc, animated: false)
                }
            default:
                break
            }
        }
    }

    /// 筆記本／白板打開、回到上次位置之後（NotebookView 呼叫）：需要在開著的畫面上做事的場景
    static func notebookOpened(_ view: NotebookView) {
        if scene == "remote" || scene == "remoteboard", !view.model.embedded, !sceneDone {
            sceneDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                guard let view = view else { return }
                Task { @MainActor in await RemoteSelfTest.run(view) }
            }
            return
        }
        if scene == "cards", view.model.isBoard, let library = library {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                guard let view = view else { return }
                let first = library.addNotebook(inBoard: view.model.meta, title: "第一章 筆記")
                let second = library.addNotebook(inBoard: view.model.meta, title: "例題本")
                view.placeCard(for: first, at: CGPoint(x: view.bounds.width * 0.2, y: view.bounds.height * 0.3))
                view.placeCard(for: second, at: CGPoint(x: view.bounds.width * 0.2, y: view.bounds.height * 0.62))
                view.model.openCard(first.id)                // 只開一個視窗
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak view] in
                    view?.selfTestSelectCard(second.id, preview: true)   // 另一張卡片選取＋預覽：看左上角的按鈕、翻頁鈕、頁碼
                }
            }
            return
        }
        if scene == "importdoc" || scene == "subboard", view.model.isBoard, !sceneDone, let library = library {
            sceneDone = true                 // 開在視窗裡的子白板也會走到這裡：只做一次
            let sub = scene == "subboard"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                guard let view = view else { return }
                var lines: [String] = []
                var metas: [NotebookMeta] = []
                // 一份 Markdown（走跟「檔案」選到的一樣的 importDocument）
                let md = FileManager.default.temporaryDirectory.appendingPathComponent("電磁學重點.md")
                let text = "# 電磁學重點\n\n## 高斯定律\n\n- 封閉曲面的電通量 $\\oint \\vec E \\cdot d\\vec A = Q/\\varepsilon_0$\n- **對稱性**決定高斯面\n\n| 情況 | 電場 |\n|---|---|\n| 點電荷 | $kq/r^2$ |\n"
                try? Data(text.utf8).write(to: md)
                if let meta = library.importDocument(from: md, into: view.model.meta.folderID) {
                    library.setBoardHome(meta.id, board: view.model.meta.id)
                    metas.append(library.notebook(meta.id) ?? meta)
                    lines.append("Markdown：匯入成「\(meta.title)」")
                } else {
                    lines.append("Markdown：失敗")
                }
                if let pdf = makeOutlinePDF(), let meta = library.importDocument(from: pdf, into: view.model.meta.folderID) {
                    library.setBoardHome(meta.id, board: view.model.meta.id)
                    metas.append(library.notebook(meta.id) ?? meta)
                    lines.append("PDF：匯入成「\(meta.title)」，\(CardCover.pageCount(meta)) 頁")
                } else {
                    lines.append("PDF：失敗")
                }
                let txt = FileManager.default.temporaryDirectory.appendingPathComponent("不收的格式.docx")
                try? Data("x".utf8).write(to: txt)
                lines.append("docx：" + (library.importDocument(from: txt, into: nil) == nil ? "不收（對）" : "收了（不對）"))
                var subBoard: NotebookMeta?
                if sub {
                    let board = library.addBoard(in: view.model.meta.folderID, title: "第一章 子白板", width: 100 * 842, height: 100 * 595)
                    library.setBoardHome(board.id, board: view.model.meta.id)
                    subBoard = library.notebook(board.id) ?? board
                    if let b = subBoard { metas.append(b) }
                    let inside = library.boardFiles(view.model.meta.id).map { $0.title }.joined(separator: "、")
                    lines.append("白板裡的檔案：" + inside)
                    lines.append("首頁列不列子白板：" + (library.items(in: nil).contains(ItemRef.notebook(board.id)) ? "列（不對）" : "不列（對）"))
                }
                view.insertLocationForTest(CGPoint(x: view.bounds.width * 0.12, y: view.bounds.height * 0.3))
                view.placeCards(for: metas)
                // 開一個視窗：importdoc 開 Markdown 那一本、subboard 開子白板
                if let open = sub ? subBoard : metas.first { view.model.openCard(open.id) }
                show(lines.joined(separator: "\n"))
            }
            return
        }
        if scene == "clip", view.model.embedded {
            // 視窗裡那一本打開了：剪一塊貼到白板（貼上的圖會是選取的，左下角應該有 ‹）
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak view] in view?.selfTestClip() }
            return
        }
        if scene == "cardtitle", view.model.isBoard, !sceneDone, let library = library {
            sceneDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                guard let view = view else { return }
                let long = library.addNotebook(inBoard: view.model.meta, title: "116學年度台聯大碩士班招生簡章（含系所組代碼）")
                let short = library.addNotebook(inBoard: view.model.meta, title: "例題本")
                view.placeCard(for: long, at: CGPoint(x: view.bounds.width * 0.3, y: view.bounds.height * 0.4))
                view.placeCard(for: short, at: CGPoint(x: view.bounds.width * 0.65, y: view.bounds.height * 0.4))
            }
            return
        }
        if (scene == "notetools" || scene == "textsel"), !view.model.isBoard, !view.model.embedded, !sceneDone {
            sceneDone = true
            let tools = scene == "notetools"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak view] in
                guard let view = view else { return }
                if tools {
                    view.selfTestNoteTools()
                } else {
                    view.model.inverted = true
                    view.setTextSelectMode(true)
                }
            }
            return
        }
        if scene == "undoink", !view.model.isBoard, !sceneDone {
            sceneDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                view?.selfTestUndoInk { show($0) }
            }
            return
        }
        if scene == "textzone", !view.model.isBoard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in view?.selfTestTextZone() }
            return
        }
        if scene == "tidytree", view.model.isBoard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                guard let view = view else { return }
                show(view.selfTestTidyTree())
            }
            return
        }
        if scene == "drafts" || scene == "draftend", view.model.meta.draftOf != nil, !sceneDone, let library = library {
            sceneDone = true
            let end = scene == "draftend"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak view] in
                guard let view = view, let pid = view.model.currentPageID else { return }
                var box = TextBox()
                box.text = "Gauss：先找對稱性 → 畫高斯面 → Q_enc"
                box.fontSize = 26
                box.rgba = [0.1, 0.1, 0.1, 1]
                box.x = 40
                box.y = 60
                box.width = 520
                view.setTextsRecorded([box], pageID: pid)
                let draftRows = view.model.notebook.rows.count
                if end {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if let other = otherNotebook { library.openNotebook = other }   // 換到別本：應該跳出「要保留嗎？」
                    }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    Drafts.sendCurrentPage()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let parentRows = Drafts.parentDoc?.model.notebook.rows.count ?? -1
                        let listed = library.items(in: nil).contains { ref in
                            if case .notebook(let id) = ref { return library.notebook(id)?.draftOf != nil }
                            return false
                        }
                        show("隨手記有 \(draftRows) 頁（應該 1）；整頁放進筆記本後，筆記本有 \(parentRows) 頁（應該 2）\n首頁列不列隨手記：" + (listed ? "列（不對）" : "不列（對）"))
                    }
                }
            }
            return
        }
        if scene == "draftpull", view.model.meta.draftOf == nil, !view.model.embedded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak view] in
                guard let view = view else { return }
                show(view.selfTestTrim())
            }
            return
        }
        if scene == "mindfold", view.model.isBoard, !view.model.embedded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                guard let view = view else { return }
                show(view.selfTestMindFold())
            }
            return
        }
        if scene == "mathpaste", view.model.isBoard, !view.model.embedded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                view?.selfTestMathPaste { show($0) }
            }
            return
        }
        if scene == "textedge", !view.model.isBoard, !view.model.embedded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                guard let view = view else { return }
                show(view.selfTestTextEdge())
            }
            return
        }
        if scene == "voice", view.model.isBoard, !view.model.embedded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                guard let view = view else { return }
                show(view.selfTestVoice())
            }
            return
        }
        if scene == "placemarks" || scene == "invert", !view.model.isBoard, !view.model.embedded {
            let invert = scene == "invert"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                guard let view = view else { return }
                if invert {
                    show(view.selfTestInvert())
                } else {
                    view.selfTestPlaceMarks { show($0) }
                }
            }
            return
        }
        if scene == "winsplit" || scene == "winfull" || scene == "clip" || scene == "pills" || scene == "wintuck", view.model.isBoard,
           !view.model.embedded, !sceneDone,
           let library = library {
            sceneDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                guard let view = view else { return }
                var meta: NotebookMeta?
                if let pdf = makeOutlinePDF(), let made = library.importDocument(from: pdf, into: view.model.meta.folderID) {
                    library.setBoardHome(made.id, board: view.model.meta.id)
                    meta = library.notebook(made.id) ?? made
                }
                guard let open = meta else { return }
                view.placeCard(for: open, at: CGPoint(x: view.bounds.width * 0.75, y: view.bounds.height * 0.3))
                view.model.openCard(open.id)
                if scene == "wintuck" {
                    // v12.16.0：分屏之後按「收起視窗」：左下角的百分比那一排要回到最左邊
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak view] in
                        view?.onToggleWindows?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak view] in
                            guard let view = view else { return }
                            show("收起視窗後，左下角那一排往右讓了 \(Int(view.boardLeftInset)) 點（應該是 0）")
                        }
                    }
                }
            }
            return
        }
        if scene == "linkedit" || scene == "texttidy" {
            let tidy = scene == "texttidy"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                guard let view = view else { return }
                show(view.selfTestLinkEdit(tidy: tidy))
            }
            return
        }
        if scene == "textlinks" || scene == "textstyle" {
            let panel = scene == "textstyle"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
                view?.selfTestLinks(panel: panel)
            }
            return
        }
        if let scene = scene, scene.hasPrefix("strokes"), view.model.isBoard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak view] in
                guard let view = view else { return }
                show("畫布上的資料：" + view.boardInkInfo + "\n（下面看得到白色的筆跡＝畫得出來；一片空白＝畫不出來）")
            }
            return
        }
        guard scene == "tiledboard" || scene == "boardimage" else { return }
        let images = scene == "boardimage"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak view] in
            guard let view = view else { return }
            show(images ? view.selfTestImages() : view.selfTestTiles())
        }
    }

    /// 一張純色的測試圖，上面寫著尺寸
    static func testImage(_ width: CGFloat, _ height: CGFloat, _ color: UIColor) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: CGPoint.zero, size: size))
            let text = "\(Int(width))×\(Int(height))" as NSString
            text.draw(at: CGPoint(x: width * 0.08, y: height * 0.08),
                      withAttributes: [.font: UIFont.boldSystemFont(ofSize: min(width, height) * 0.16),
                                       .foregroundColor: UIColor.black])
        }
    }

    /// 一份 6 頁、有三層目錄的 PDF（放在暫存資料夾）
    private static func makeOutlinePDF() -> URL? {
        let doc = PDFDocument()
        let size = CGSize(width: 595, height: 842)
        for _ in 0 ..< 6 {
            guard let page = PDFPage(image: testImage(size.width, size.height, UIColor.white)) else { return nil }
            doc.insert(page, at: doc.pageCount)
        }
        let root = PDFOutline()
        doc.outlineRoot = root
        func add(_ title: String, _ index: Int, to parent: PDFOutline) -> PDFOutline {
            let item = PDFOutline()
            item.label = title
            if let page = doc.page(at: index) {
                item.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: size.height))
            }
            parent.insertChild(item, at: parent.numberOfChildren)
            return item
        }
        let book = add("Electricity and Magnetism", 0, to: root)
        _ = add("Preface", 1, to: book)
        let chapter = add("1 Electrostatics", 2, to: book)
        _ = add("1.1 Electric charge", 2, to: chapter)
        _ = add("1.2 Conservation of charge", 3, to: chapter)
        _ = add("2 The electric potential", 4, to: book)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("目錄測試.pdf")
        try? FileManager.default.removeItem(at: url)
        return doc.write(to: url) ? url : nil
    }

    /// 把結果直接寫在畫面上方（截圖看）
    static func show(_ text: String) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.keyWindow else { return }
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.text = text
        let width = window.bounds.width - 60
        let size = label.sizeThatFits(CGSize(width: width - 28, height: CGFloat.greatestFiniteMagnitude))
        let box = UIView(frame: CGRect(x: 30, y: 150, width: width, height: size.height + 24))
        box.backgroundColor = UIColor(red: 0.05, green: 0.14, blue: 0.32, alpha: 0.95)
        box.layer.cornerRadius = 12
        box.isUserInteractionEnabled = false
        label.frame = CGRect(x: 14, y: 12, width: width - 28, height: size.height)
        box.addSubview(label)
        window.addSubview(box)
    }
}

/// 區網服務的自動測試（v12.17.0）：用 URLSession 連 127.0.0.1，結果和拿回來的頁面圖顯示在右下角
@MainActor
enum RemoteSelfTest {
    static let base = "http://127.0.0.1:\(RemoteAccess.port)"
    static var token = ""

    static func call(_ method: String, _ path: String, _ body: Any? = nil) async -> (Int, Data) {
        guard let url = URL(string: base + path) else { return (0, Data()) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 8
        if !token.isEmpty { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            return (-1, Data(error.localizedDescription.utf8))
        }
    }

    static func json(_ d: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    static func run(_ view: NotebookView) async {
        var lines: [String] = []
        let access = RemoteAccess.shared
        access.enabled = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        lines.append("服務：" + access.status + "　" + access.address)
        let (s0, _) = await call("GET", "/notebooks")
        lines.append("沒配對就讀：\(s0)（應該 401）")
        let (s1, d1) = await call("POST", "/pair", ["code": access.pairCode])
        token = json(d1)["token"] as? String ?? ""
        lines.append("配對：\(s1)，鑰匙 \(token.count) 字")
        let (s2, d2) = await call("GET", "/notebooks")
        let count = (json(d2)["notebooks"] as? [Any])?.count ?? -1
        lines.append("列出筆記本：\(s2)，\(count) 本")
        let board = view.model.isBoard
        let id = view.model.meta.id.uuidString
        if !board {
            let page: [String: Any] = ["boxes": [["text": "第二頁：Claude 加的頁", "size": 26, "bold": true, "frame": "none"] as [String: Any]]]
            let (s3, d3) = await call("POST", "/notebooks/\(id)/pages", ["after": 1, "pages": [page]] as [String: Any])
            lines.append("加一頁：\(s3) " + String(decoding: d3.prefix(80), as: UTF8.self))
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        var c: [String: Any] = ["key": "c", "text": "例：3×5 矩陣、rank 2 → nullity 3",
                                "frame": ["color": "#F2C74F", "mode": 0, "shape": 2] as [String: Any]]
        if !board {
            c["x"] = 330
            c["y"] = 230
        }
        let boxes: [[String: Any]] = [
            ["key": "t", "text": "秩—零度定理（Rank–Nullity）", "size": 24, "bold": true, "frame": "none"],
            ["key": "a", "text": "$\\operatorname{rank}(A)+\\operatorname{nullity}(A)=n$", "frame": "#73B8FF"],
            ["key": "b", "text": "映射前的維度 = 像的維度 + 被壓到 0 的維度", "frame": "blue"],
            c
        ]
        let (s4, d4) = await call("POST", "/notebooks/current/texts", [
            "page": "current",
            "boxes": boxes,
            "links": [["from": "a", "to": "b"], ["from": "a", "to": "c", "route": "curve"]] as [[String: Any]]
        ] as [String: Any])
        let made = (json(d4)["boxes"] as? [[String: Any]]) ?? []
        lines.append("加文字方塊：\(s4)，\(made.count) 個" + (s4 == 200 ? "" : " " + String(decoding: d4.prefix(120), as: UTF8.self)))
        if let first = made.first?["id"] as? String {
            let (s5, _) = await call("PATCH", "/notebooks/\(id)/texts/\(first)", ["text": "秩—零度定理（Rank–Nullity Theorem）"])
            lines.append("改字：\(s5)")
        }
        let (s6, d6) = await call("GET", "/notebooks/\(id)?from=1&to=2")
        let pages = (json(d6)["pages"] as? [[String: Any]]) ?? []
        let texts = pages.map { (($0["texts"] as? [Any])?.count ?? 0) }
        lines.append("讀回來：\(s6)，頁數 \(pages.count)，每頁方塊 \(texts)")
        let (s7, d7) = await call("GET", "/current")
        let cur = json(d7)
        lines.append("現在：\(s7) 第 \(cur["page"] ?? "?") 頁，看得到 \(cur["visible"] ?? "?")")
        try? await Task.sleep(nanoseconds: 2_500_000_000)          // 等數學式排好
        let (s8, d8) = await call("GET", "/notebooks/\(id)/image?page=current&width=700")
        lines.append("頁面圖：\(s8)，\(d8.count / 1024) KB")
        let (s9, d9) = await call("POST", "/notebooks", ["title": "Claude 新增的筆記本"])
        lines.append("新筆記本：\(s9) " + ((json(d9)["title"] as? String) ?? ""))
        overlay(lines.joined(separator: "\n"), image: s8 == 200 ? UIImage(data: d8) : nil)
    }

    static func overlay(_ text: String, image: UIImage?) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.keyWindow else { return }
        let w = window.bounds.width
        let panel = UIView()
        panel.backgroundColor = UIColor(red: 0.05, green: 0.14, blue: 0.32, alpha: 0.95)
        panel.layer.cornerRadius = 12
        panel.isUserInteractionEnabled = false
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.text = text
        let textWidth: CGFloat = image == nil ? w - 80 : w * 0.55
        let size = label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        label.frame = CGRect(x: 12, y: 10, width: textWidth, height: size.height)
        panel.addSubview(label)
        var height = size.height + 20
        if let img = image {
            let iw = w - textWidth - 60
            let ih = min(iw * img.size.height / max(img.size.width, 1), 420)
            let iv = UIImageView(image: img)
            iv.contentMode = .scaleAspectFit
            iv.layer.borderColor = UIColor.white.cgColor
            iv.layer.borderWidth = 1
            iv.frame = CGRect(x: textWidth + 24, y: 10, width: iw, height: ih)
            panel.addSubview(iv)
            height = max(height, ih + 20)
        }
        panel.frame = CGRect(x: 30, y: window.bounds.height - height - 40, width: w - 60, height: height)
        window.addSubview(panel)
    }
}
