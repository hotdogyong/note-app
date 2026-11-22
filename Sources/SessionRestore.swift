import SwiftUI
import UIKit

// SessionRestore.swift（v12.16.0）：短時間內重進 App，回到離開時的樣子。
// iPadOS 會把放在背景的 App 關掉；6 小時內再打開的話：打開離開時的那一本（分頁本來就有存），
// 白板上開著的浮動視窗（哪幾本、位置大小、浮著／全屏／分屏、分屏比例、有沒有暫時收起來）也照原樣開回來。
// 超過 6 小時就照舊回到首頁。筆記本看到哪一頁、白板的縮放位置，本來就各自有記（lastPage、boardView.<編號>）。

/// 一個浮動視窗要記的東西
struct SavedBoardWindow: Codable, Equatable {
    var notebook: UUID
    var frame: CGRect?
    var mode: String            // float、full、split
    var aspect: CGFloat?
    var split: CGFloat
}

/// 一張白板上的浮動視窗
struct SavedBoardWindows: Codable, Equatable {
    var windows: [SavedBoardWindow]
    var tucked: Bool
}

@MainActor
enum SessionRestore {
    static let window: TimeInterval = 6 * 3600         // 6 小時內算「短期」（使用者決定）

    private static let notebookKey = "session.openNotebook"
    private static let timeKey = "session.time"
    private static let windowsKey = "session.windows"

    /// 這次啟動要恢復的浮動視窗（App 一開始讀出來；白板打開時拿走自己的那一份）
    private static var pendingWindows: [String: SavedBoardWindows] = [:]
    private static var savedWindows: [String: SavedBoardWindows] = [:]
    private static var loaded = false

    /// 上次用 App 的時間在 6 小時內
    static var isRecent: Bool {
        let t = UserDefaults.standard.double(forKey: timeKey)
        guard t > 0 else { return false }
        return Date().timeIntervalSince1970 - t < window
    }

    /// 打開、關掉筆記本時記下來
    static func noteOpen(_ id: UUID?) {
        if let id = id {
            UserDefaults.standard.set(id.uuidString, forKey: notebookKey)
        } else {
            UserDefaults.standard.removeObject(forKey: notebookKey)
        }
        touch()
    }

    /// App 進背景、打開關掉筆記本：更新「上次用的時間」
    static func touch() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timeKey)
    }

    /// App 一開始：6 小時內的話，要打開哪一本（自動測試的時候不恢復）
    static func notebookToRestore() -> UUID? {
        load()
        guard SelfTest.scene == nil, isRecent,
              let s = UserDefaults.standard.string(forKey: notebookKey) else { return nil }
        return UUID(uuidString: s)
    }

    private static func load() {
        guard !loaded else { return }
        loaded = true
        if let data = UserDefaults.standard.data(forKey: windowsKey),
           let saved = try? JSONDecoder().decode([String: SavedBoardWindows].self, from: data) {
            savedWindows = saved
            if SelfTest.scene == nil && isRecent { pendingWindows = saved }
        }
    }

    /// 白板上的浮動視窗變了：記下來
    static func saveWindows(board: UUID, _ list: [BoardWindow], tucked: Bool) {
        load()
        let key = board.uuidString
        let items = list.map { w in
            SavedBoardWindow(notebook: w.meta.id, frame: w.frame, mode: name(w.mode), aspect: w.aspect, split: w.split)
        }
        let value = SavedBoardWindows(windows: items, tucked: tucked && !items.isEmpty)
        if items.isEmpty {
            guard savedWindows[key] != nil else { return }
            savedWindows[key] = nil
        } else {
            guard savedWindows[key] != value else { return }
            savedWindows[key] = value
        }
        if let data = try? JSONEncoder().encode(savedWindows) {
            UserDefaults.standard.set(data, forKey: windowsKey)
        }
    }

    /// 白板打開：這次啟動要恢復的浮動視窗（只給一次）
    static func takeWindows(board: UUID) -> SavedBoardWindows? {
        load()
        return pendingWindows.removeValue(forKey: board.uuidString)
    }

    static func name(_ mode: BoardWindowMode) -> String {
        switch mode {
        case .float: return "float"
        case .full: return "full"
        case .split: return "split"
        }
    }

    static func mode(_ name: String) -> BoardWindowMode {
        switch name {
        case "full": return .full
        case "split": return .split
        default: return .float
        }
    }
}
