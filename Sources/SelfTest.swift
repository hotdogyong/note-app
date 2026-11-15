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

    static func run(_ library: LibraryModel) {
        Self.library = library
        guard let scene = scene, scene != "home" else { return }
        UserDefaults.standard.set(scene == "collapsed", forKey: "tabsCollapsed")   // 只有 collapsed 場景把分頁那一排收起來
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
            case "outline":
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
            case "textlinks":
                // 文字方塊的外框樣式、連線（v12.13.0）：白板上放幾個方塊和線，選取其中一個（看四邊的點）
                library.openNotebook = library.addBoard(in: nil, title: "連線測試白板", width: 100 * 842, height: 100 * 595)
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
            default:
                break
            }
        }
    }

    /// 筆記本／白板打開、回到上次位置之後（NotebookView 呼叫）：需要在開著的畫面上做事的場景
    static func notebookOpened(_ view: NotebookView) {
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
