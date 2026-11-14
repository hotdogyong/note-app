import SwiftUI
import UIKit
import PencilKit

// SelfTest.swift：自動測試用的場景（v12.9.9）
// GitHub 的雲端 Mac 會在 iPad 模擬器裡用「-selftest 場景名稱」啟動 App，等幾秒後截圖，
// 讓 Claude 不用等使用者就能自己看到畫面（排版、有沒有閃退、功能有沒有出現）。
// 平常使用時沒有這個參數，這個檔案什麼都不會做。場景清單在 ci/scenes.txt。

@MainActor
enum SelfTest {
    static var scene: String? { UserDefaults.standard.string(forKey: "selftest") }

    static func run(_ library: LibraryModel) {
        guard let scene = scene, scene != "home" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
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
            case "markdown":
                library.openNotebook = library.addMarkdownNotebook(in: nil)
            default:
                break
            }
        }
    }

    /// 筆記本／白板打開、回到上次位置之後（NotebookView 呼叫）：需要在開著的畫面上做事的場景
    static func notebookOpened(_ view: NotebookView) {
        guard scene == "tiledboard" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak view] in
            guard let view = view else { return }
            show(view.selfTestTiles())
        }
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
