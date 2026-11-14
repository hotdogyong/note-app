import UIKit
import PencilKit

// BoardTileStore.swift：分區儲存接到存檔系統的部分（v12.11.0）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）
//
// BoardTiles.swift 是「怎麼切格子」；這個檔案是「格子檔怎麼安全地讀寫」：
//   1. 一頁是不是分區儲存：看它的格子資料夾（page-….tiles）在不在。在的話 Store.loadDrawing／saveDrawing 自動改走這裡，
//      其他程式（匯出、縮圖、復原、歷史版本）拿到的還是「整頁的筆跡」，不用知道底下怎麼存。
//   2. 存檔只寫有變的格子：每一格記一個指紋（筆數、每一筆的外框、位置、墨水、路徑的幾個取樣點），指紋沒變就不寫。
//   3. 一次存檔要嘛全部生效、要嘛全部不生效：先把要換的格子寫成 .new，全部寫好後放一個記號檔 commit.txt，
//      再一個一個換上去。中途 App 被關掉：下次打開時，記號在就接著換完，記號不在就把 .new 丟掉（等於那次沒存）。
//   4. 讀取：所有格子同時讀（平行），再合成一份。合起來的上下順序：螢光筆在最下面（App 本來的規則），
//      其他的每一格裡維持存檔時的順序，格子之間照寫的時間排。
//   5. 開、關分區儲存：開的時候原本的單一檔原封不動留著當備份；每一格寫完都讀回來核對筆數，不對就不換。
//
// 目前畫布上還是放整張白板的筆跡（只載入畫面附近的格子是下一步），所以復原、選取、區塊都跟以前一樣。

/// 平行讀格子時放結果的盒子
private final class TileParts: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [[PKStroke]?]

    init(count: Int) {
        parts = Array(repeating: nil, count: count)
    }

    func set(_ i: Int, _ strokes: [PKStroke]?) {
        lock.lock()
        parts[i] = strokes
        lock.unlock()
    }

    var all: [[PKStroke]?] {
        lock.lock()
        defer { lock.unlock() }
        return parts
    }
}

/// 算指紋用：每個數字都攪進去，順序不同結果也不同
private struct TileMixer {
    var h: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func addBits(_ v: UInt64) {
        var x = h ^ v
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        h = x ^ (x >> 31)
    }

    mutating func addReal(_ v: CGFloat) {
        addBits(Double(v).bitPattern)
    }

    mutating func addInt(_ v: Int) {
        addBits(UInt64(bitPattern: Int64(v)))
    }
}

extension BoardTiles {
    /// 存檔的記號檔：在，表示所有 .new 都寫好了，可以換上去
    static let commitName = "commit.txt"

    // 所有格子檔的讀寫都排隊（同一時間只有一個在做），不會讀到換到一半的狀態
    private static let io = NSRecursiveLock()
    /// 每個格子資料夾（路徑）裡每一格目前的指紋；沒有記錄的資料夾，下次存檔會整份重寫
    nonisolated(unsafe) private static var signatures: [String: [TileKey: UInt64]] = [:]
    /// 這次開 App 之後已經檢查過「上次有沒有存到一半」的資料夾
    nonisolated(unsafe) private static var recovered: Set<String> = []

    // MARK: 位置

    /// 單一檔的位置 → 格子資料夾的位置（page-….drawing → page-….tiles）
    static func dir(forDrawing url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("tiles")
    }

    static func isFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 這一頁是不是用分區儲存
    static func isTiled(_ pageID: UUID) -> Bool {
        isFolder(dir(pageID))
    }

    static func keys(in folder: URL) -> [TileKey] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { TileKey(fileName: $0) }.sorted()
    }

    /// 讀一個格子檔；讀不出來回傳 nil
    static func loadFile(_ url: URL) -> [PKStroke]? {
        guard let data = try? Data(contentsOf: url), let drawing = try? PKDrawing(data: data) else { return nil }
        return drawing.strokes
    }

    // MARK: 指紋

    /// 一格的指紋：筆數、每一筆的外框、位置、墨水、路徑的取樣點、遮罩。任何編輯（寫、擦、搬、縮放、換色、換順序）都會讓它變
    static func signature(_ strokes: [PKStroke]) -> UInt64 {
        var m = TileMixer()
        m.addInt(strokes.count)
        for stroke in strokes {
            let b = stroke.renderBounds
            m.addReal(b.origin.x)
            m.addReal(b.origin.y)
            m.addReal(b.size.width)
            m.addReal(b.size.height)
            let t = stroke.transform
            m.addReal(t.a)
            m.addReal(t.b)
            m.addReal(t.c)
            m.addReal(t.d)
            m.addReal(t.tx)
            m.addReal(t.ty)
            let path = stroke.path
            let n = path.count
            m.addInt(n)
            m.addBits(path.creationDate.timeIntervalSinceReferenceDate.bitPattern)
            if n > 0 {
                var last = -1
                for i in [0, n / 4, n / 2, (n * 3) / 4, n - 1] where i != last {
                    last = i
                    let p = path[i]
                    m.addReal(p.location.x)
                    m.addReal(p.location.y)
                    m.addReal(p.size.width)
                    m.addReal(p.size.height)
                    m.addReal(p.opacity)
                    m.addReal(p.force)
                }
            }
            let ink = stroke.ink
            for byte in ink.inkType.rawValue.utf8 { m.addInt(Int(byte)) }
            let color = ink.color.cgColor
            m.addReal(color.alpha)
            for c in color.components ?? [] { m.addReal(c) }
            m.addInt(Int(stroke.randomSeed))
            for range in stroke.maskedPathRanges {
                m.addReal(range.lowerBound)
                m.addReal(range.upperBound)
            }
            if let mask = stroke.mask {
                // 擦掉一部分的筆：遮罩的每個點都算進去
                mask.cgPath.applyWithBlock { element in
                    let e = element.pointee
                    let points: Int
                    switch e.type {
                    case .moveToPoint, .addLineToPoint: points = 1
                    case .addQuadCurveToPoint: points = 2
                    case .addCurveToPoint: points = 3
                    case .closeSubpath: points = 0
                    @unknown default: points = 0
                    }
                    m.addInt(Int(e.type.rawValue))
                    for i in 0 ..< points {
                        m.addReal(e.points[i].x)
                        m.addReal(e.points[i].y)
                    }
                }
            }
        }
        return m.h
    }

    // MARK: 讀

    /// 幾格合成一份。螢光筆放最下面；其他的每一格裡維持原本的先後，格子之間照寫的時間排
    static func merge(_ parts: [[PKStroke]]) -> [PKStroke] {
        if parts.count == 1 { return parts[0] }
        var markers: [(time: Double, seq: Int, stroke: PKStroke)] = []
        var others: [(time: Double, seq: Int, stroke: PKStroke)] = []
        var seq = 0
        for part in parts {
            var markerTime = -Double.infinity
            var otherTime = -Double.infinity
            for stroke in part {
                let t = stroke.path.creationDate.timeIntervalSinceReferenceDate
                if isHighlighter(stroke) {
                    markerTime = max(markerTime, t)
                    markers.append((markerTime, seq, stroke))
                } else {
                    otherTime = max(otherTime, t)
                    others.append((otherTime, seq, stroke))
                }
                seq += 1
            }
        }
        markers.sort { a, b in a.time != b.time ? a.time < b.time : a.seq < b.seq }
        others.sort { a, b in a.time != b.time ? a.time < b.time : a.seq < b.seq }
        var out: [PKStroke] = []
        out.reserveCapacity(markers.count + others.count)
        for item in markers { out.append(item.stroke) }
        for item in others { out.append(item.stroke) }
        return out
    }

    /// 一個格子資料夾裡所有格子合起來。remember：這是正在用的那一頁（要記指紋、檢查上次有沒有存到一半）；
    /// 歷史版本裡的資料夾用 false，只讀不動
    static func loadAll(folder: URL, remember: Bool = true) -> PKDrawing {
        io.lock()
        defer { io.unlock() }
        if remember { recover(folder) }
        let tileKeys = keys(in: folder)
        let box = TileParts(count: tileKeys.count)
        DispatchQueue.concurrentPerform(iterations: tileKeys.count) { i in
            box.set(i, loadFile(folder.appendingPathComponent(tileKeys[i].fileName)))
        }
        let loaded = box.all
        var parts: [[PKStroke]] = []
        var sigs: [TileKey: UInt64] = [:]
        for (i, key) in tileKeys.enumerated() {
            if let strokes = loaded[i] {
                parts.append(strokes)
                if !strokes.isEmpty { sigs[key] = signature(strokes) }
            } else if remember {
                // 讀不出來的格子：改個名字留著（不會被之後的存檔蓋掉或刪掉）
                let bad = folder.appendingPathComponent("讀不出來-" + key.fileName)
                try? FileManager.default.removeItem(at: bad)
                try? FileManager.default.moveItem(at: folder.appendingPathComponent(key.fileName), to: bad)
            }
        }
        if remember { signatures[folder.path] = sigs }
        return PKDrawing(strokes: merge(parts))
    }

    // MARK: 寫

    /// 存檔：只寫有變的格子。回傳寫了幾格、刪了幾格；失敗回傳 nil（原本的格子檔都還在）
    @discardableResult
    static func writeChanged(_ drawing: PKDrawing, folder: URL) -> (written: Int, removed: Int)? {
        io.lock()
        defer { io.unlock() }
        recover(folder)
        let fm = FileManager.default
        let parts = split(drawing.strokes)
        var sigs: [TileKey: UInt64] = [:]
        for (key, strokes) in parts { sigs[key] = signature(strokes) }
        let old = signatures[folder.path]
        let onDisk = Set(keys(in: folder))
        var toWrite: [TileKey] = []
        for (key, sig) in sigs where old?[key] != sig || !onDisk.contains(key) { toWrite.append(key) }
        let toRemove = onDisk.filter { parts[$0] == nil }
        if toWrite.isEmpty && toRemove.isEmpty {
            signatures[folder.path] = sigs
            return (0, 0)
        }
        signatures[folder.path] = nil                          // 中途失敗的話，下次整份重寫
        clearStaged(folder)                                    // 上次沒做完留下的 .new、記號先清掉（這次會整份蓋過去）
        var staged: [URL] = []
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for key in toWrite {
                let url = folder.appendingPathComponent(key.fileName + ".new")
                staged.append(url)
                try PKDrawing(strokes: parts[key] ?? []).dataRepresentation().write(to: url)
            }
            let list = toRemove.map { $0.fileName }.joined(separator: "\n")
            try Data(list.utf8).write(to: folder.appendingPathComponent(commitName), options: .atomic)
        } catch {
            for url in staged { try? fm.removeItem(at: url) }
            return nil
        }
        guard applyCommit(folder) else { return nil }
        signatures[folder.path] = sigs
        return (toWrite.count, toRemove.count)
    }

    /// 把 .new 換上去、刪掉空了的格子、拿掉記號。可以重複做（做到一半被中斷，再做一次結果一樣）
    private static func applyCommit(_ folder: URL) -> Bool {
        let fm = FileManager.default
        let marker = folder.appendingPathComponent(commitName)
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return false }
        var ok = true
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".new") {
            let src = folder.appendingPathComponent(name).path
            let dst = folder.appendingPathComponent(String(name.dropLast(4))).path
            if rename(src, dst) != 0 { ok = false }
        }
        guard ok else { return false }                          // 記號留著，之後再接著做
        for line in text.split(separator: "\n") {
            let name = String(line)
            if TileKey(fileName: name) != nil { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
        }
        try? fm.removeItem(at: marker)
        return true
    }

    private static func clearStaged(_ folder: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: folder.appendingPathComponent(commitName))
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".new") {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// 這次開 App 第一次碰這個資料夾：上次存到一半被關掉的話，接著做完或丟掉
    private static func recover(_ folder: URL) {
        guard !recovered.contains(folder.path) else { return }
        recovered.insert(folder.path)
        guard isFolder(folder) else { return }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(commitName).path) {
            _ = applyCommit(folder)
        } else {
            clearStaged(folder)
        }
    }

    // MARK: 開、關

    /// 改用分區儲存：把 drawing（這一頁現在完整的筆跡）拆成格子檔。原本的單一檔不動，留著當備份。
    /// 成功回傳 nil；失敗回傳原因（這時候什麼都沒變）
    static func enable(_ pageID: UUID, drawing: PKDrawing) -> String? {
        io.lock()
        defer { io.unlock() }
        let fm = FileManager.default
        let folder = dir(pageID)
        if isFolder(folder) { return nil }
        let tmp = folder.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        let parts = split(drawing.strokes)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            for (key, strokes) in parts {
                try PKDrawing(strokes: strokes).dataRepresentation().write(to: tmp.appendingPathComponent(key.fileName))
            }
        } catch {
            try? fm.removeItem(at: tmp)
            return "格子檔寫不進去（\(error.localizedDescription)）"
        }
        // 每一格都讀回來核對筆數
        var total = 0
        for (key, strokes) in parts {
            let back = loadFile(tmp.appendingPathComponent(key.fileName))?.count ?? -1
            if back != strokes.count {
                try? fm.removeItem(at: tmp)
                return "核對不過（有一格應該 \(strokes.count) 筆，讀回來 \(back) 筆）"
            }
            total += back
        }
        if total != drawing.strokes.count {
            try? fm.removeItem(at: tmp)
            return "核對不過（應該 \(drawing.strokes.count) 筆，格子裡共 \(total) 筆）"
        }
        if rename(tmp.path, folder.path) != 0 {
            try? fm.removeItem(at: tmp)
            return "格子資料夾放不上去"
        }
        var sigs: [TileKey: UInt64] = [:]
        for (key, strokes) in parts { sigs[key] = signature(strokes) }
        signatures[folder.path] = sigs
        recovered.insert(folder.path)
        return nil
    }

    /// 改回單一檔：把 drawing（這一頁現在完整的筆跡）寫回單一檔、讀回來核對筆數，沒問題才把格子資料夾拿掉。
    /// 成功回傳 nil；失敗回傳原因（這時候還是分區儲存，格子檔沒動）
    static func disable(_ pageID: UUID, drawing: PKDrawing) -> String? {
        io.lock()
        defer { io.unlock() }
        let fm = FileManager.default
        let folder = dir(pageID)
        guard isFolder(folder) else { return nil }
        let url = Store.drawingURL(pageID)
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try drawing.dataRepresentation().write(to: url, options: .atomic)
        } catch {
            return "單一檔寫不進去（\(error.localizedDescription)）"
        }
        guard let data = try? Data(contentsOf: url), let back = try? PKDrawing(data: data),
              back.strokes.count == drawing.strokes.count else {
            return "核對不過（單一檔讀回來的筆數不對）"
        }
        try? fm.removeItem(at: folder)
        signatures[folder.path] = nil
        if isFolder(folder) { return "格子資料夾拿不掉" }
        return nil
    }

    // MARK: 其他地方會用到的

    /// 這一頁的格子檔被別的方式換掉了（例如恢復歷史版本）：指紋作廢，下次存檔整份重寫
    static func forget(_ pageID: UUID) {
        io.lock()
        signatures[dir(pageID).path] = nil
        io.unlock()
    }

    /// 換資料位置時：記在記憶體裡的都作廢
    static func resetMemory() {
        io.lock()
        signatures = [:]
        recovered = []
        io.unlock()
    }

    /// 刪掉這一頁的格子檔
    static func remove(_ pageID: UUID) {
        io.lock()
        defer { io.unlock() }
        let folder = dir(pageID)
        try? FileManager.default.removeItem(at: folder)
        signatures[folder.path] = nil
    }

    /// 把正在用的格子資料夾整個複製一份到 target（歷史版本、複製筆記本用）
    @discardableResult
    static func copyFolder(from source: URL, to target: URL) -> Bool {
        io.lock()
        defer { io.unlock() }
        recover(source)
        guard isFolder(source) else { return false }
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
            return true
        } catch {
            return false
        }
    }

    /// 一頁的格子檔複製給另一頁（複製筆記本、把頁面移到別本）
    static func copy(from old: UUID, to new: UUID) {
        guard isTiled(old) else { return }
        copyFolder(from: dir(old), to: dir(new))
        forget(new)
    }

    /// 這一頁的格子檔整個換成 source 那一份（恢復歷史版本）。先複製到旁邊，都好了才換上去
    @discardableResult
    static func replaceFolder(_ pageID: UUID, with source: URL) -> Bool {
        io.lock()
        defer { io.unlock() }
        let fm = FileManager.default
        let folder = dir(pageID)
        let tmp = folder.appendingPathExtension("tmp")
        let old = folder.appendingPathExtension("old")
        try? fm.removeItem(at: tmp)
        try? fm.removeItem(at: old)
        do {
            try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            return false
        }
        signatures[folder.path] = nil
        if isFolder(folder), rename(folder.path, old.path) != 0 {
            try? fm.removeItem(at: tmp)
            return false
        }
        if rename(tmp.path, folder.path) != 0 {
            _ = rename(old.path, folder.path)                   // 換不上去：把原本的放回來
            try? fm.removeItem(at: tmp)
            return false
        }
        try? fm.removeItem(at: old)
        return true
    }

    /// 每一格的檔名和內容（算歷史版本的指紋用）
    static func allData(_ pageID: UUID) -> [(name: String, data: Data)] {
        io.lock()
        defer { io.unlock() }
        let folder = dir(pageID)
        recover(folder)
        var out: [(name: String, data: Data)] = []
        for key in keys(in: folder) {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(key.fileName)) {
                out.append((key.fileName, data))
            }
        }
        return out
    }

    /// 最後一次存檔的時間（格子資料夾的修改時間：每次換格子檔都會更新）
    static func modified(_ pageID: UUID) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir(pageID).path)
        return attrs?[.modificationDate] as? Date
    }
}
