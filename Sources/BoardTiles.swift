import UIKit
import PencilKit

// BoardTiles.swift：白板筆跡的分區儲存（v12.11 準備中）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）
//
// 為什麼要做：整張白板存成一個筆跡檔，存檔和載入的時間都跟總筆數成正比（使用者實測 1 萬筆存一次 4.9 秒）。
// 做法：把白板切成 1200 × 1200 點的格子，每格一個檔；一筆照它外框的中心算在哪一格。
// 畫布只放畫面附近幾格的筆跡，存檔只存有變動的那幾格。
//
// 目前這個檔案只有「切格子、讀寫每一格、整份拆開／合起來」這些基本工具，**還沒有接到白板上**，
// 正式的白板仍然用原本的單一檔案。接上去之前先用自動測試（SelfTest 的 tiles 場景）確認拆開再合起來不會少任何一筆。

/// 第幾格（x、y 都可以是負的）
struct TileKey: Hashable, Comparable, Sendable {
    var x: Int
    var y: Int

    static func < (a: TileKey, b: TileKey) -> Bool {
        a.y != b.y ? a.y < b.y : a.x < b.x
    }

    var fileName: String { "c_\(x)_\(y).drawing" }

    init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// 從檔名讀回來（c_3_-2.drawing）
    init?(fileName: String) {
        guard fileName.hasPrefix("c_"), fileName.hasSuffix(".drawing") else { return nil }
        let parts = fileName.dropFirst(2).dropLast(8).split(separator: "_")
        guard parts.count == 2, let px = Int(parts[0]), let py = Int(parts[1]) else { return nil }
        self.x = px
        self.y = py
    }
}

enum BoardTiles {
    /// 一格的邊長（頁面座標）
    static let size: CGFloat = 1200

    static func key(at p: CGPoint) -> TileKey {
        TileKey(x: Int((p.x / size).rounded(.down)), y: Int((p.y / size).rounded(.down)))
    }

    /// 這一筆算在哪一格：外框的中心
    static func key(for stroke: PKStroke) -> TileKey {
        let b = stroke.renderBounds
        if b.isNull || b.isInfinite { return TileKey(x: 0, y: 0) }
        return key(at: CGPoint(x: b.midX, y: b.midY))
    }

    /// 蓋到 rect 的所有格子
    static func keys(covering rect: CGRect) -> Set<TileKey> {
        guard !rect.isNull, !rect.isInfinite, rect.width >= 0, rect.height >= 0 else { return [] }
        let a = key(at: CGPoint(x: rect.minX, y: rect.minY))
        let b = key(at: CGPoint(x: rect.maxX, y: rect.maxY))
        var out = Set<TileKey>()
        for y in a.y ... b.y {
            for x in a.x ... b.x { out.insert(TileKey(x: x, y: y)) }
        }
        return out
    }

    /// 把一堆筆跡照格子分開（每一格裡維持原本的先後順序）
    static func split(_ strokes: [PKStroke]) -> [TileKey: [PKStroke]] {
        var out: [TileKey: [PKStroke]] = [:]
        for stroke in strokes { out[key(for: stroke), default: []].append(stroke) }
        return out
    }

    /// 這一頁的格子檔放在哪個資料夾（跟原本的 page-….drawing 同一層，副檔名換成 .tiles）
    static func dir(_ pageID: UUID) -> URL {
        Store.drawingURL(pageID).deletingPathExtension().appendingPathExtension("tiles")
    }

    static func exists(_ pageID: UUID) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir(pageID).path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 有檔案的格子（照順序）
    static func allKeys(_ pageID: UUID) -> [TileKey] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir(pageID).path)) ?? []
        return names.compactMap { TileKey(fileName: $0) }.sorted()
    }

    static func load(_ pageID: UUID, _ key: TileKey) -> [PKStroke] {
        let url = dir(pageID).appendingPathComponent(key.fileName)
        guard let data = try? Data(contentsOf: url), let drawing = try? PKDrawing(data: data) else { return [] }
        return drawing.strokes
    }

    /// 存一格；空的就把檔案拿掉。回傳有沒有成功
    @discardableResult
    static func save(_ pageID: UUID, _ key: TileKey, _ strokes: [PKStroke]) -> Bool {
        let folder = dir(pageID)
        let url = folder.appendingPathComponent(key.fileName)
        if strokes.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PKDrawing(strokes: strokes).dataRepresentation().write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 所有格子合起來（匯出、縮圖、歷史版本這些要整頁的地方用；慢，但一筆都不會少）
    static func loadAll(_ pageID: UUID) -> PKDrawing {
        var strokes: [PKStroke] = []
        for key in allKeys(pageID) { strokes.append(contentsOf: load(pageID, key)) }
        return PKDrawing(strokes: strokes)
    }

    /// 整份拆開寫成格子檔；原本有、現在沒有筆跡的格子會拿掉。回傳寫了幾格；有任何一格寫失敗回傳 nil
    static func writeAll(_ drawing: PKDrawing, pageID: UUID) -> Int? {
        let parts = split(drawing.strokes)
        for key in allKeys(pageID) where parts[key] == nil { save(pageID, key, []) }
        for (key, strokes) in parts {
            if !save(pageID, key, strokes) { return nil }
        }
        return parts.count
    }

    /// 自動測試：亂數產生 count 筆，拆開存檔、再讀回來，檢查筆數、每一筆都在對的格子、改一格只動到那一格。
    /// 回傳一段說明文字（模擬器截圖用）
    static func selfCheck(count: Int) -> String {
        let pageID = UUID()
        defer { try? FileManager.default.removeItem(at: dir(pageID)) }
        var seed: UInt64 = 0x1234_5678_9ABC_DEF1
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 100_000) / 100_000
        }
        let ink = PKInk(.pen, color: UIColor.white)
        var strokes: [PKStroke] = []
        for _ in 0 ..< count {
            let x = next() * 9000 - 1500                      // 也測負的座標
            let y = next() * 6000 - 1500
            let a = PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: 0, size: CGSize(width: 2, height: 2),
                                  opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2)
            let b = PKStrokePoint(location: CGPoint(x: x + 20 * next(), y: y + 20 * next()), timeOffset: 0.1,
                                  size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2)
            strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: [a, b], creationDate: Date())))
        }
        let t0 = CACurrentMediaTime()
        let written = writeAll(PKDrawing(strokes: strokes), pageID: pageID)
        let t1 = CACurrentMediaTime()
        let back = loadAll(pageID)
        let t2 = CACurrentMediaTime()
        // 每一格讀回來的筆都算在那一格
        var misplaced = 0
        var perTile: [TileKey: Int] = [:]
        for key in allKeys(pageID) {
            let part = load(pageID, key)
            perTile[key] = part.count
            for stroke in part where BoardTiles.key(for: stroke) != key { misplaced += 1 }
        }
        // 只改一格：其他格的檔案不動（修改時間不變），總筆數少掉那一格的一半
        var touched = 0
        var afterEdit = -1
        if let first = allKeys(pageID).first {
            let before = fileDates(pageID)
            Thread.sleep(forTimeInterval: 1.1)
            let part = load(pageID, first)
            save(pageID, first, Array(part.prefix(part.count / 2)))
            let after = fileDates(pageID)
            for (name, date) in after where before[name] != date { touched += 1 }
            touched += before.keys.filter { after[$0] == nil }.count
            afterEdit = loadAll(pageID).strokes.count
            let expected = count - (part.count - part.count / 2)
            if afterEdit != expected { afterEdit = -afterEdit }
        }
        let covered = keys(covering: CGRect(x: -1500, y: -1500, width: 9020, height: 6020)).count
        var lines: [String] = []
        lines.append("產生 \(count) 筆 → 拆成 \(written.map { String($0) } ?? "失敗") 格（範圍蓋到 \(covered) 格）")
        lines.append("寫入 \(Int((t1 - t0) * 1000)) ms，讀回 \(back.strokes.count) 筆 \(Int((t2 - t1) * 1000)) ms")
        lines.append("放錯格子的：\(misplaced) 筆")
        lines.append("只改一格：動到 \(touched) 個檔，改完總筆數 \(afterEdit)")
        let ok = written != nil && back.strokes.count == count && misplaced == 0 && touched == 1 && afterEdit > 0
        lines.append(ok ? "結果：全部正確" : "結果：有問題")
        return lines.joined(separator: "\n")
    }

    private static func fileDates(_ pageID: UUID) -> [String: Date] {
        var out: [String: Date] = [:]
        let folder = dir(pageID)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let attrs = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            if let date = attrs?[.modificationDate] as? Date { out[name] = date }
        }
        return out
    }
}
