import SwiftUI
import UIKit

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
            case "notebook":
                library.openNotebook = library.addNotebook(in: nil)
            case "markdown":
                library.openNotebook = library.addMarkdownNotebook(in: nil)
            default:
                break
            }
        }
    }
}
