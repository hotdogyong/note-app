import UIKit
import PencilKit

// BoardTileCheck.swift：分區儲存的自動測試（v12.11.0）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）
//
// 平常不會執行。雲端的模擬器用「-selftest tilestore」啟動 App 時，照真的存檔流程（Store.saveDrawing、loadDrawing、
// 歷史版本、複製、刪除）在一個測試用的頁面上跑一遍，每一步都核對筆數，結果寫在畫面上讓 Claude 截圖看。
// 測試用的檔案放在 _App資料 裡的一個臨時資料夾，跑完就刪掉，不會碰到任何筆記。

enum BoardTileCheck {
    /// 測試用的假筆跡：前 markers 筆是螢光筆，其餘是白色的筆；每一筆 8 個點；建立時間一筆比一筆晚一秒
    static func makeStrokes(count: Int, markers: Int, origin: CGPoint, spread: CGSize,
                            seed start: UInt64 = 0x1234_5678_9ABC_DEF1) -> [PKStroke] {
        var seed = start
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 100_000) / 100_000
        }
        let pen = PKInk(.pen, color: UIColor.white)
        let marker = PKInk(.marker, color: UIColor.yellow)
        let base = Date().addingTimeInterval(-Double(count) - 10)
        var strokes: [PKStroke] = []
        strokes.reserveCapacity(count)
        for n in 0 ..< count {
            let x = origin.x + next() * spread.width
            let y = origin.y + next() * spread.height
            let w: CGFloat = n < markers ? 12 : 3
            var points: [PKStrokePoint] = []
            for k in 0 ..< 8 {
                let p = CGPoint(x: x + CGFloat(k) * 4, y: y + (k % 2 == 0 ? 0 : 6) + next() * 2)
                points.append(PKStrokePoint(location: p, timeOffset: Double(k) * 0.02, size: CGSize(width: w, height: w),
                                            opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2))
            }
            let path = PKStrokePath(controlPoints: points, creationDate: base.addingTimeInterval(Double(n)))
            strokes.append(PKStroke(ink: n < markers ? marker : pen, path: path))
        }
        return strokes
    }

    private static func ms(_ t0: CFTimeInterval) -> Int {
        Int((CACurrentMediaTime() - t0) * 1000)
    }

    /// 每個格子檔的修改時間
    private static func fileDates(_ folder: URL) -> [String: Date] {
        var out: [String: Date] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard TileKey(fileName: name) != nil else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            if let date = attrs?[.modificationDate] as? Date { out[name] = date }
        }
        return out
    }

    /// 兩次之間有幾個格子檔不一樣（改過、多出來、不見了）
    private static func changed(_ before: [String: Date], _ after: [String: Date]) -> Int {
        var n = 0
        for (name, date) in after where before[name] != date { n += 1 }
        for name in before.keys where after[name] == nil { n += 1 }
        return n
    }

    private static func sameOrder(_ a: [PKStroke], _ b: [PKStroke]) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices {
            if abs(a[i].path.creationDate.timeIntervalSince(b[i].path.creationDate)) > 0.01 { return false }
        }
        return true
    }

    /// 照真的存檔流程跑一遍，回傳每一步的結果
    static func run(count: Int = 6000) -> String {
        var lines: [String] = []
        var failed = 0
        func check(_ ok: Bool, _ text: String) {
            lines.append((ok ? "✓ " : "✗ ") + text)
            if !ok { failed += 1 }
        }
        func pause() { Thread.sleep(forTimeInterval: 0.05) }

        let notebookID = UUID()
        let pageID = UUID()
        let copyID = UUID()
        Store.pageOwner[pageID] = notebookID
        Store.pageOwner[copyID] = notebookID
        defer {
            try? FileManager.default.removeItem(at: Store.notebookDir(notebookID))
            Store.pageOwner[pageID] = nil
            Store.pageOwner[copyID] = nil
        }
        let folder = BoardTiles.dir(pageID)
        let markers = 60
        let original = makeStrokes(count: count, markers: markers, origin: CGPoint(x: 20000, y: 20000),
                                   spread: CGSize(width: 9000, height: 6000))
        var current = PKDrawing(strokes: original)
        var expected = count

        // 1. 原本的單一檔
        Store.saveDrawing(current, pageID: pageID)
        check(Store.loadDrawing(pageID).strokes.count == expected, "單一檔存、讀：\(expected) 筆")

        // 2. 改用分區
        var t0 = CACurrentMediaTime()
        let problem = BoardTiles.enable(pageID, drawing: current)
        let enableMs = ms(t0)
        check(problem == nil && BoardTiles.isTiled(pageID) && Store.exists(Store.drawingURL(pageID)),
              "改用分區：\(BoardTiles.allKeys(pageID).count) 格，\(enableMs) ms，單一檔還在" + (problem.map { "（\($0)）" } ?? ""))

        // 3. 平行讀回來：筆數、順序
        t0 = CACurrentMediaTime()
        current = Store.loadDrawing(pageID)
        let loadMs = ms(t0)
        check(current.strokes.count == expected, "所有格子同時讀回 \(current.strokes.count) 筆，\(loadMs) ms")
        check(sameOrder(current.strokes, original), "讀回來的上下順序跟原本一樣（螢光筆在最下面）")
        var repeatOK = true
        for _ in 0 ..< 5 where Store.loadDrawing(pageID).strokes.count != expected { repeatOK = false }
        check(repeatOK, "連續再讀 5 次，筆數都對")

        // 4. 沒改就存
        var before = fileDates(folder)
        pause()
        Store.saveDrawing(current, pageID: pageID)
        let touched4 = changed(before, fileDates(folder))
        check(touched4 == 0, "沒改就存檔：動到 \(touched4) 個檔（應該 0）")

        // 5. 一格擦掉幾筆、遠處新的一格加 5 筆
        let firstKey = BoardTiles.key(for: current.strokes[min(markers, current.strokes.count - 1)])
        var removed = 0
        var kept: [PKStroke] = []
        for stroke in current.strokes {
            if removed < 10, !isHighlighter(stroke), BoardTiles.key(for: stroke) == firstKey {
                removed += 1
            } else {
                kept.append(stroke)
            }
        }
        kept.append(contentsOf: makeStrokes(count: 5, markers: 0, origin: CGPoint(x: 50000, y: 20000),
                                            spread: CGSize(width: 200, height: 200), seed: 77))
        expected += 5 - removed
        before = fileDates(folder)
        pause()
        Store.saveDrawing(PKDrawing(strokes: kept), pageID: pageID)
        let touched5 = changed(before, fileDates(folder))
        current = Store.loadDrawing(pageID)
        check(touched5 == 2 && current.strokes.count == expected,
              "一格擦掉 \(removed) 筆、遠處加 5 筆：動到 \(touched5) 個檔（應該 2），共 \(current.strokes.count) 筆")

        // 6. 一筆搬到隔壁格
        var list = current.strokes
        if let index = list.firstIndex(where: { !isHighlighter($0) }) {
            let s = list[index]
            let move = CGAffineTransform(translationX: BoardTiles.size, y: 0)
            list[index] = PKStroke(ink: s.ink, path: s.path, transform: s.transform.concatenating(move), mask: s.mask)
        }
        before = fileDates(folder)
        pause()
        Store.saveDrawing(PKDrawing(strokes: list), pageID: pageID)
        let touched6 = changed(before, fileDates(folder))
        current = Store.loadDrawing(pageID)
        check(touched6 == 2 && current.strokes.count == expected,
              "一筆搬到隔壁格：動到 \(touched6) 個檔（應該 2），共 \(current.strokes.count) 筆")

        // 7. 背景存檔
        expected -= 3
        Store.saveDrawingLater(PKDrawing(strokes: Array(current.strokes.dropLast(3))), pageID: pageID)
        let waiting = Store.loadDrawing(pageID).strokes.count
        Store.finishPendingSaves()
        current = Store.loadDrawing(pageID)
        check(waiting == expected && current.strokes.count == expected,
              "背景存檔：排隊時讀到 \(waiting) 筆，寫完後檔案裡 \(current.strokes.count) 筆")

        // 8、9. 存到一半 App 被關掉
        if let key = BoardTiles.allKeys(pageID).first {
            let stray = folder.appendingPathComponent(key.fileName + ".new")
            let commit = folder.appendingPathComponent(BoardTiles.commitName)
            try? PKDrawing().dataRepresentation().write(to: stray)
            BoardTiles.resetMemory()
            let n8 = Store.loadDrawing(pageID).strokes.count
            check(n8 == expected && !Store.exists(stray), "存到一半被關掉（還沒放記號）：沒寫完的丟掉，還是 \(n8) 筆")

            let part = BoardTiles.load(pageID, key)
            try? PKDrawing(strokes: Array(part.dropLast())).dataRepresentation().write(to: stray)
            try? Data().write(to: commit)
            BoardTiles.resetMemory()
            if !part.isEmpty { expected -= 1 }
            current = Store.loadDrawing(pageID)
            check(current.strokes.count == expected && !Store.exists(stray) && !Store.exists(commit),
                  "存到一半被關掉（已經放記號）：接著換完，\(current.strokes.count) 筆")
        }

        // 10. 歷史版本
        var page = NotePage()
        page.id = pageID
        var row = PageRow()
        row.pages = [page]
        let notebook = NotebookData(rows: [row])
        let info = Store.makeSnapshot(notebook, id: notebookID, manual: true, reason: "測試")
        let inSnapshot = info.map { Store.snapshotDrawing($0, notebook: notebookID, pageID: pageID).strokes.count } ?? -1
        check(inSnapshot == expected, "歷史版本存一份：裡面 \(inSnapshot) 筆")
        Store.saveDrawing(PKDrawing(strokes: Array(current.strokes.prefix(expected / 2))), pageID: pageID)
        let halved = Store.loadDrawing(pageID).strokes.count
        var restored = -1
        var sameFingerprint = false
        if let info = info, Store.restoreSnapshot(info, notebook: notebookID) != nil {
            restored = Store.loadDrawing(pageID).strokes.count
            sameFingerprint = Store.fingerprint(notebook) == info.fingerprint
        }
        check(halved == expected / 2 && restored == expected && BoardTiles.isTiled(pageID) && sameFingerprint,
              "擦掉一半（剩 \(halved) 筆）再恢復：\(restored) 筆，還是分區，指紋\(sameFingerprint ? "一樣" : "不一樣")")

        // 11. 改回單一檔
        current = Store.loadDrawing(pageID)
        let offProblem = BoardTiles.disable(pageID, drawing: current)
        let single = Store.loadDrawing(pageID).strokes.count
        check(offProblem == nil && !BoardTiles.isTiled(pageID) && single == expected,
              "改回單一檔：\(single) 筆" + (offProblem.map { "（\($0)）" } ?? ""))

        // 12. 單一檔的頁，恢復「分區時存的版本」
        Store.saveDrawing(PKDrawing(), pageID: pageID)
        var mixed1 = -1
        if let info = info, Store.restoreSnapshot(info, notebook: notebookID) != nil {
            mixed1 = Store.loadDrawing(pageID).strokes.count
        }
        check(mixed1 == expected && !BoardTiles.isTiled(pageID), "單一檔的頁恢復分區時存的版本：\(mixed1) 筆，還是單一檔")

        // 13. 分區的頁，恢復「單一檔時存的版本」
        let info2 = Store.makeSnapshot(notebook, id: notebookID, manual: true, reason: "測試 2")
        current = Store.loadDrawing(pageID)
        let again = BoardTiles.enable(pageID, drawing: current)
        Store.saveDrawing(PKDrawing(strokes: Array(current.strokes.prefix(100))), pageID: pageID)
        var mixed2 = -1
        if let info2 = info2, Store.restoreSnapshot(info2, notebook: notebookID) != nil {
            mixed2 = Store.loadDrawing(pageID).strokes.count
        }
        check(again == nil && mixed2 == expected && BoardTiles.isTiled(pageID),
              "分區的頁恢復單一檔時存的版本：\(mixed2) 筆，還是分區")

        // 14、15. 複製給另一頁、刪掉
        Store.copyDrawingFiles(from: pageID, to: copyID)
        let copied = Store.loadDrawing(copyID).strokes.count
        check(copied == expected && BoardTiles.isTiled(copyID), "複製給另一頁：\(copied) 筆，也是分區")
        Store.deleteDrawing(copyID)
        check(!BoardTiles.isTiled(copyID) && !Store.exists(Store.drawingURL(copyID)) && Store.loadDrawing(copyID).strokes.isEmpty,
              "刪掉那一頁的筆跡：格子檔、單一檔都不在了")

        // 16. 全部擦光
        Store.saveDrawing(PKDrawing(), pageID: pageID)
        check(BoardTiles.isTiled(pageID) && BoardTiles.allKeys(pageID).isEmpty && Store.loadDrawing(pageID).strokes.isEmpty,
              "全部擦光再存：格子檔都拿掉，還是分區")

        lines.append(failed == 0 ? "結果：全部正確" : "結果：有 \(failed) 項不對")
        return lines.joined(separator: "\n")
    }
}
