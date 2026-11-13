import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// ActivityLog.swift：修改紀錄（v12.9.5）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）
//
// 之後要做「行事曆／日誌」（像 GUGA 的 My Logbook，但記的是「改了哪些頁」，只打開來看不算）。
// 畫面怎麼做還要討論（交接檔 8.10），但紀錄沒辦法往回補，所以先開始記。
// 「改過」：筆跡存檔（頁面的 flush，只有真的改了才存）、文字方塊／圖片／紙膠帶內容有變（NotebookModel 的 setTexts 等）。
// 存在資料位置的 _App資料/修改紀錄.json：
//   { "2026-11-13": { "<筆記本 id>": { "<頁面 id>": [第一次改的時間, 最後一次改的時間] } } }
// 時間是 1970 年起的秒數；日期用 iPad 當地時間分天

@MainActor
enum ActivityLog {
    typealias Days = [String: [String: [String: [Double]]]]

    private static var days: Days = [:]
    private static var loaded = false
    private static var dirty = false
    private static var saveTask: Task<Void, Never>?

    static var url: URL { Store.systemDir.appendingPathComponent("修改紀錄.json") }

    /// 這一頁剛剛改過
    static func touch(pageID: UUID) {
        guard let owner = Store.pageOwner[pageID] else { return }
        load()
        let now = Date()
        let day = dayKey(now)
        let t = now.timeIntervalSince1970
        var notebook = days[day]?[owner.uuidString] ?? [:]
        if var range = notebook[pageID.uuidString], range.count == 2 {
            range[1] = t
            notebook[pageID.uuidString] = range
        } else {
            notebook[pageID.uuidString] = [t, t]
        }
        var today = days[day] ?? [:]
        today[owner.uuidString] = notebook
        days[day] = today
        dirty = true
        scheduleSave()
    }

    /// 某一天改過的：筆記本 id → (頁面 id → 第一次、最後一次改的時間)（之後的日誌畫面用）
    static func entries(on date: Date) -> [UUID: [UUID: (first: Date, last: Date)]] {
        load()
        var out: [UUID: [UUID: (first: Date, last: Date)]] = [:]
        for (nb, pages) in days[dayKey(date)] ?? [:] {
            guard let nbID = UUID(uuidString: nb) else { continue }
            var list: [UUID: (first: Date, last: Date)] = [:]
            for (page, range) in pages {
                guard let pageID = UUID(uuidString: page), range.count == 2 else { continue }
                list[pageID] = (first: Date(timeIntervalSince1970: range[0]), last: Date(timeIntervalSince1970: range[1]))
            }
            out[nbID] = list
        }
        return out
    }

    /// 有紀錄的日子（月曆上打點用）
    static func activeDays() -> Set<String> {
        load()
        return Set(days.keys)
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Days.self, from: data) {
            days = saved
        }
    }

    /// 改了之後 3 秒才寫檔（連續寫字時不會一直存）
    private static func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// 馬上寫檔（App 進背景、離開筆記本時）
    static func saveNow() {
        guard loaded, dirty else { return }
        dirty = false
        Store.ensureDir(Store.systemDir)
        if let data = try? JSONEncoder().encode(days) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
