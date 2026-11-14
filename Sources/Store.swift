import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// Store.swift：Store：所有檔案讀寫、路徑、資料位置、歷史版本、圖片檔
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

// MARK: - 2. 存檔與讀檔（全部放在 App 的文件資料夾）

/// 存檔：照 App 裡的資料夾擺
///   資料位置/
///     _App資料/library.json          首頁的資料夾、筆記本清單、排序
///     某個資料夾/某本筆記本/notebook.json
///                          /筆跡/page-….drawing
///                          /pdf-….pdf
enum Store {
    /// App 自己的資料夾
    static let appDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    /// 使用者在「檔案」App 選的資料夾（有選的話，所有資料都存在那裡）
    nonisolated(unsafe) static var customDir: URL?
    static var dir: URL { customDir ?? appDir }
    static let bookmarkKey = "dataFolderBookmark"
    static let systemFolderName = "_App資料"
    static var systemDir: URL { dir.appendingPathComponent(systemFolderName, isDirectory: true) }

    /// 目前的首頁資料（算資料夾路徑用）
    nonisolated(unsafe) static var libraryCache = LibraryData()
    /// 哪一頁、哪個 PDF 屬於哪一本筆記本（讀筆記本時登記）
    nonisolated(unsafe) static var pageOwner: [UUID: UUID] = [:]
    nonisolated(unsafe) static var pdfOwner: [String: UUID] = [:]

    // MARK: 共用

    // MARK: 設定的備份（v12.4）
    // 筆盒、每本筆記本的習慣、白板的位置這些設定存在系統的 UserDefaults 裡，重裝 App 時可能被清掉
    //（2026-11-12 使用者把專案的檔案全部刪掉重加之後，資料位置和筆盒設定都不見了）。
    // 所以在資料位置的 _App資料/設定備份.plist 留一份；設定不見時從那裡讀回來。

    /// 要備份的設定：名稱開頭是這些的
    static let settingsPrefixes = ["penBox", "penOwn.", "penSel.", "snap", "boardView.", "textDefault",
                                   "notebookBackdrop", "sideExportOrder", "quickNotebookID",
                                   "lassoOwn.", "boardLock.", "notebookZoomPreset", "tabsCollapsed", "openTabs",   // v12.9 加的
                                   "lastSideExport."]                                                              // v12.9.2

    /// 設定最後一次存到資料夾的時間（v12.9）：資料夾裡的比較新（例如重裝、換裝置）才讀回來
    static let settingsStampKey = "settingsSavedAt"

    static var settingsBackupURL: URL {
        dir.appendingPathComponent(systemFolderName, isDirectory: true).appendingPathComponent("設定備份.plist")
    }

    /// 把現在的設定存一份到資料位置（離開筆記本、App 進背景時呼叫）。還沒有筆盒設定時不存，免得用空的蓋掉備份
    static func backupSettings() {
        guard UserDefaults.standard.data(forKey: "penBox") != nil else { return }
        var out: [String: Any] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            if settingsPrefixes.contains(where: { key.hasPrefix($0) }) { out[key] = value }
        }
        guard !out.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        out[settingsStampKey] = now
        ensureDir(dir.appendingPathComponent(systemFolderName, isDirectory: true))
        if (out as NSDictionary).write(to: settingsBackupURL, atomically: true) {
            UserDefaults.standard.set(now, forKey: settingsStampKey)
        }
    }

    /// v12.9：設定以資料夾裡的為準。資料夾裡的比這台的新（剛重裝、設定被清掉、在別台改過），就讀回來。回傳有沒有讀回東西
    static func restoreSettingsIfNeeded() -> Bool {
        guard let saved = NSDictionary(contentsOf: settingsBackupURL) as? [String: Any], !saved.isEmpty else { return false }
        let local = UserDefaults.standard.double(forKey: settingsStampKey)
        let remote = (saved[settingsStampKey] as? Double) ?? 0
        let cleared = UserDefaults.standard.data(forKey: "penBox") == nil
        guard cleared || remote > local + 1 else { return false }
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
        return true
    }

    static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        ensureDir(url.deletingLastPathComponent())
        try? data.write(to: url, options: .atomic)
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// 檔名不能用的字元換掉
    static func sanitize(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
        if text.hasPrefix(".") { text = "＿" + text.dropFirst() }
        return text.isEmpty ? "未命名" : text
    }

    /// 同一層不重複的資料夾名稱（重複就加 2、3…）
    static func uniqueDirName(_ title: String, parent: UUID?, excluding id: UUID?, in library: LibraryData) -> String {
        var used = Set<String>()
        for f in library.folders where f.parentID == parent && f.id != id && f.deletedAt == nil {
            if let n = f.dirName { used.insert(n) }
        }
        for m in library.notebooks where m.folderID == parent && m.id != id && m.deletedAt == nil {
            if let n = m.dirName { used.insert(n) }
        }
        used.insert(systemFolderName)
        let base = sanitize(title)
        var name = base
        var k = 2
        while used.contains(name) {
            name = "\(base) \(k)"
            k += 1
        }
        return name
    }

    // MARK: 路徑

    /// 最近刪除的東西搬到這裡（不會出現在「檔案」App 的一般資料夾裡）
    static var trashDir: URL { systemDir.appendingPathComponent("最近刪除", isDirectory: true) }

    static func trashName(_ name: String?, id: UUID) -> String {
        "\(name ?? "項目")-\(id.uuidString.prefix(4))"
    }

    static func folderPath(_ folderID: UUID?) -> URL {
        guard let id = folderID, let f = libraryCache.folders.first(where: { $0.id == id }) else { return dir }
        if f.deletedAt != nil {
            return trashDir.appendingPathComponent(trashName(f.dirName, id: id), isDirectory: true)
        }
        return folderPath(f.parentID).appendingPathComponent(f.dirName ?? id.uuidString, isDirectory: true)
    }

    static func notebookDir(_ id: UUID) -> URL {
        guard let m = libraryCache.notebooks.first(where: { $0.id == id }) else {
            return systemDir.appendingPathComponent(id.uuidString, isDirectory: true)
        }
        if m.deletedAt != nil {
            return trashDir.appendingPathComponent(trashName(m.dirName, id: id), isDirectory: true)
        }
        return folderPath(m.folderID).appendingPathComponent(m.dirName ?? id.uuidString, isDirectory: true)
    }

    // MARK: 首頁清單

    static var libraryURL: URL { systemDir.appendingPathComponent("library.json") }
    static var legacyLibraryURL: URL { dir.appendingPathComponent("library.json") }

    static func loadLibrary() -> LibraryData {
        let lib = decode(LibraryData.self, libraryURL) ?? decode(LibraryData.self, legacyLibraryURL) ?? LibraryData()
        libraryCache = lib
        return lib
    }

    static func saveLibrary(_ library: LibraryData) {
        libraryCache = library
        encode(library, to: libraryURL)
    }

    // MARK: 筆記本

    static func notebookURL(_ id: UUID) -> URL { notebookDir(id).appendingPathComponent("notebook.json") }
    static func legacyNotebookURL(_ id: UUID) -> URL { dir.appendingPathComponent("notebook-\(id.uuidString).json") }

    static func register(_ notebook: NotebookData, id: UUID) {
        for row in notebook.rows {
            for page in row.pages {
                pageOwner[page.id] = id
                if let pdf = page.pdf { pdfOwner[pdf.file] = id }
            }
        }
    }

    static func loadNotebook(_ id: UUID) -> NotebookData {
        let data = decode(NotebookData.self, notebookURL(id)) ?? decode(NotebookData.self, legacyNotebookURL(id))
            ?? NotebookData()
        register(data, id: id)
        return data
    }

    static func saveNotebook(_ notebook: NotebookData, id: UUID) {
        register(notebook, id: id)
        encode(notebook, to: notebookURL(id))
    }

    // MARK: 筆跡

    static func drawingURL(_ pageID: UUID) -> URL {
        let name = "page-\(pageID.uuidString).drawing"
        guard let owner = pageOwner[pageID] else { return dir.appendingPathComponent(name) }
        return notebookDir(owner).appendingPathComponent("筆跡", isDirectory: true).appendingPathComponent(name)
    }

    static func legacyDrawingURL(_ pageID: UUID) -> URL {
        dir.appendingPathComponent("page-\(pageID.uuidString).drawing")
    }

    static func loadDrawing(_ pageID: UUID) -> PKDrawing {
        saveLock.lock()
        let waiting = pendingSaves[pageID]?.drawing            // 還在排隊存檔的那一份比檔案新
        saveLock.unlock()
        if let waiting = waiting { return waiting }
        if BoardTiles.isTiled(pageID) { return BoardTiles.loadAll(pageID) }   // 分區儲存的頁（v12.11.0）：所有格子合起來
        // 新位置找不到就找舊位置（整理到一半出問題也讀得到）
        for url in [drawingURL(pageID), legacyDrawingURL(pageID)] {
            if let data = try? Data(contentsOf: url), let drawing = try? PKDrawing(data: data) { return drawing }
        }
        return PKDrawing()
    }

    // 存檔都排進同一條佇列（v12.10.1）。使用者實測：白板 1 萬筆整份存一次要 4.9 秒，以前每次停筆都在主執行緒存，畫面就卡住。
    // 筆跡多的頁改成丟到背景存（saveDrawingLater）；同一頁只留最新的一份；還沒寫進檔案的，loadDrawing 會先拿記憶體裡這一份
    private static let saveQueue = DispatchQueue(label: "note.drawing.save", qos: .utility)
    private static let saveLock = NSLock()
    nonisolated(unsafe) private static var pendingSaves: [UUID: (generation: Int, drawing: PKDrawing)] = [:]
    nonisolated(unsafe) private static var saveGeneration = 0

    private static func queueSave(_ drawing: PKDrawing, pageID: UUID) {
        saveLock.lock()
        saveGeneration += 1
        pendingSaves[pageID] = (saveGeneration, drawing)
        saveLock.unlock()
    }

    private static func writePending(_ pageID: UUID, to url: URL) {
        saveLock.lock()
        let job = pendingSaves[pageID]
        saveLock.unlock()
        guard let job = job else { return }
        let tiles = BoardTiles.dir(forDrawing: url)
        if BoardTiles.isFolder(tiles) {
            BoardTiles.writeChanged(job.drawing, folder: tiles)   // 分區儲存的頁（v12.11.0）：只寫有變的格子
        } else {
            ensureDir(url.deletingLastPathComponent())
            try? job.drawing.dataRepresentation().write(to: url, options: .atomic)
        }
        saveLock.lock()
        if pendingSaves[pageID]?.generation == job.generation { pendingSaves[pageID] = nil }   // 寫的這段時間沒有更新的才拿掉
        saveLock.unlock()
    }

    /// 馬上存好才回來（頁面不大、或一定要立刻寫進檔案的時候）
    static func saveDrawing(_ drawing: PKDrawing, pageID: UUID) {
        let url = drawingURL(pageID)
        queueSave(drawing, pageID: pageID)
        saveQueue.sync { writePending(pageID, to: url) }
    }

    /// 丟到背景存（筆跡很多的頁）；要確定都寫完用 finishPendingSaves()
    static func saveDrawingLater(_ drawing: PKDrawing, pageID: UUID) {
        let url = drawingURL(pageID)
        queueSave(drawing, pageID: pageID)
        saveQueue.async { writePending(pageID, to: url) }
    }

    /// 等背景的存檔都做完（離開筆記本、App 進背景、要複製筆跡檔之前）
    static func finishPendingSaves() {
        saveQueue.sync { }
    }

    // MARK: 歷史版本
    // 存頁面結構（notebook.json）和筆跡；PDF、圖片檔不會被改動，不重複複製

    static let autoSnapshotLimit = 10

    /// 內容的指紋（頁面結構＋每一頁的筆跡）；「上次看到第幾頁」不算，翻頁不會讓內容變成不一樣
    static func fingerprint(_ notebook: NotebookData) -> String {
        var copy = notebook
        copy.lastPage = nil
        var hash: UInt64 = 0xcbf29ce484222325                 // FNV-1a：每次執行結果都一樣
        func mix(_ data: Data) {
            for byte in data {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
        }
        if let json = try? JSONEncoder().encode(copy) { mix(json) }
        for row in copy.rows {
            for page in row.pages {
                mix(Data(page.id.uuidString.utf8))
                if BoardTiles.isTiled(page.id) {               // 分區儲存的頁：每一格的檔名和內容
                    for tile in BoardTiles.allData(page.id) {
                        mix(Data(tile.name.utf8))
                        mix(tile.data)
                    }
                    continue
                }
                for url in [drawingURL(page.id), legacyDrawingURL(page.id)] {
                    if let data = try? Data(contentsOf: url) {
                        mix(data)
                        break
                    }
                }
            }
        }
        return String(hash, radix: 16)
    }

    static func historyDir(_ id: UUID) -> URL {
        notebookDir(id).appendingPathComponent("歷史版本", isDirectory: true)
    }

    static func snapshots(_ id: UUID) -> [SnapshotInfo] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: historyDir(id), includingPropertiesForKeys: nil)) ?? []
        var list: [SnapshotInfo] = []
        for folder in folders {
            if var info = decode(SnapshotInfo.self, folder.appendingPathComponent("info.json")) {
                info.id = folder.lastPathComponent
                list.append(info)
            }
        }
        return list.sorted { (a: SnapshotInfo, b: SnapshotInfo) -> Bool in a.date > b.date }
    }

    @discardableResult
    static func makeSnapshot(_ notebook: NotebookData, id: UUID, manual: Bool, reason: String,
                             trim: Bool = true) -> SnapshotInfo? {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let now = Date()
        var name = formatter.string(from: now) + (manual ? " 手動" : " 自動")
        if exists(historyDir(id).appendingPathComponent(name)) { name += " \(UUID().uuidString.prefix(4))" }
        let folder = historyDir(id).appendingPathComponent(name, isDirectory: true)
        let drawings = folder.appendingPathComponent("筆跡", isDirectory: true)
        ensureDir(drawings)
        var pages = 0
        for row in notebook.rows {
            for page in row.pages {
                pages += 1
                if BoardTiles.isTiled(page.id) {               // 分區儲存的頁：整個格子資料夾複製一份
                    BoardTiles.copyFolder(from: BoardTiles.dir(page.id),
                                          to: drawings.appendingPathComponent("page-\(page.id.uuidString).tiles"))
                    continue
                }
                for src in [drawingURL(page.id), legacyDrawingURL(page.id)] where exists(src) {
                    try? fm.copyItem(at: src, to: drawings.appendingPathComponent("page-\(page.id.uuidString).drawing"))
                    break
                }
            }
        }
        encode(notebook, to: folder.appendingPathComponent("notebook.json"))
        var info = SnapshotInfo(id: name, date: now, manual: manual, reason: reason, pageCount: pages)
        info.fingerprint = fingerprint(notebook)
        encode(info, to: folder.appendingPathComponent("info.json"))
        if !manual && trim { trimAutoSnapshots(id) }
        return info
    }

    /// 自動保存最多留 10 份，舊的刪掉（手動保存不動）；protecting：這一份不刪
    static func trimAutoSnapshots(_ id: UUID, protecting: String? = nil) {
        let autos = snapshots(id).filter { !$0.manual && $0.id != protecting }
        for old in autos.dropFirst(autoSnapshotLimit) {
            try? FileManager.default.removeItem(at: historyDir(id).appendingPathComponent(old.id))
        }
    }

    /// 改標題、摘要
    static func updateSnapshot(_ snapshot: SnapshotInfo, notebook id: UUID) {
        encode(snapshot, to: historyDir(id).appendingPathComponent(snapshot.id).appendingPathComponent("info.json"))
    }

    /// 預覽用：讀出那個版本的頁面結構（現在已經刪掉的頁也找得到它的 PDF、圖片）
    static func snapshotNotebook(_ snapshot: SnapshotInfo, notebook id: UUID) -> NotebookData? {
        let url = historyDir(id).appendingPathComponent(snapshot.id).appendingPathComponent("notebook.json")
        guard let data = decode(NotebookData.self, url) else { return nil }
        register(data, id: id)
        return data
    }

    static func snapshotDrawing(_ snapshot: SnapshotInfo, notebook id: UUID, pageID: UUID) -> PKDrawing {
        let url = historyDir(id).appendingPathComponent(snapshot.id).appendingPathComponent("筆跡", isDirectory: true)
            .appendingPathComponent("page-\(pageID.uuidString).drawing")
        let tiles = BoardTiles.dir(forDrawing: url)             // 那個版本是分區儲存的（v12.11.0）
        if BoardTiles.isFolder(tiles) { return BoardTiles.loadAll(folder: tiles, remember: false) }
        if let data = try? Data(contentsOf: url), let drawing = try? PKDrawing(data: data) { return drawing }
        return PKDrawing()
    }

    static func deleteSnapshot(_ snapshot: SnapshotInfo, notebook id: UUID) {
        try? FileManager.default.removeItem(at: historyDir(id).appendingPathComponent(snapshot.id))
    }

    /// 把歷史版本的頁面結構和筆跡放回去，回傳讀出來的筆記本
    static func restoreSnapshot(_ snapshot: SnapshotInfo, notebook id: UUID) -> NotebookData? {
        let fm = FileManager.default
        let folder = historyDir(id).appendingPathComponent(snapshot.id)
        guard let data = decode(NotebookData.self, folder.appendingPathComponent("notebook.json")) else { return nil }
        register(data, id: id)
        let saved = folder.appendingPathComponent("筆跡", isDirectory: true)
        for row in data.rows {
            for page in row.pages {
                let dst = drawingURL(page.id)
                ensureDir(dst.deletingLastPathComponent())
                let src = saved.appendingPathComponent("page-\(page.id.uuidString).drawing")
                // 分區儲存（v12.11.0）：這一頁現在用哪一種存法，恢復之後還是那一種
                let srcTiles = BoardTiles.dir(forDrawing: src)
                let snapTiled = BoardTiles.isFolder(srcTiles)
                if BoardTiles.isTiled(page.id) {
                    if snapTiled {
                        BoardTiles.replaceFolder(page.id, with: srcTiles)
                    } else {
                        var old = PKDrawing()                  // 那個版本是單一檔（或空白）：內容換成它，拆成格子存
                        if let data = try? Data(contentsOf: src), let drawing = try? PKDrawing(data: data) { old = drawing }
                        BoardTiles.forget(page.id)
                        BoardTiles.writeChanged(old, folder: BoardTiles.dir(page.id))
                    }
                    continue
                }
                if snapTiled {                                  // 那個版本是分區的、現在是單一檔：合起來寫回單一檔
                    let drawing = BoardTiles.loadAll(folder: srcTiles, remember: false)
                    try? drawing.dataRepresentation().write(to: dst, options: .atomic)
                    continue
                }
                try? fm.removeItem(at: dst)                    // 那時候是空白的頁：清掉現在的筆跡
                if exists(src) { try? fm.copyItem(at: src, to: dst) }
            }
        }
        saveNotebook(data, id: id)
        return data
    }

    static func deleteDrawing(_ pageID: UUID) {
        BoardTiles.remove(pageID)                               // 分區儲存的格子檔（v12.11.0）
        try? FileManager.default.removeItem(at: drawingURL(pageID))
        try? FileManager.default.removeItem(at: legacyDrawingURL(pageID))
    }

    /// 一頁的筆跡檔複製給另一頁（複製筆記本、把頁面移到別本）。分區儲存的頁：格子資料夾也一起複製
    static func copyDrawingFiles(from old: UUID, to new: UUID) {
        for src in [drawingURL(old), legacyDrawingURL(old)] where exists(src) {
            let dst = drawingURL(new)
            ensureDir(dst.deletingLastPathComponent())
            try? FileManager.default.copyItem(at: src, to: dst)
            break
        }
        BoardTiles.copy(from: old, to: new)
    }

    // MARK: 圖片

    nonisolated(unsafe) static var imageCache: [String: UIImage] = [:]

    static func imagesDir(_ pageID: UUID) -> URL {
        guard let owner = pageOwner[pageID] else { return dir.appendingPathComponent("圖片", isDirectory: true) }
        return notebookDir(owner).appendingPathComponent("圖片", isDirectory: true)
    }

    /// 存一張圖片到那一頁所屬筆記本的「圖片」資料夾，回傳檔名
    static func saveImage(_ image: UIImage, pageID: UUID) -> String? {
        var hasAlpha = false
        if let info = image.cgImage?.alphaInfo {
            hasAlpha = !(info == .none || info == .noneSkipFirst || info == .noneSkipLast)
        }
        let name = "img-\(UUID().uuidString)" + (hasAlpha ? ".png" : ".jpg")
        let data: Data? = hasAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.9)
        guard let bytes = data else { return nil }
        let folder = imagesDir(pageID)
        ensureDir(folder)
        do { try bytes.write(to: folder.appendingPathComponent(name), options: .atomic) } catch { return nil }
        imageCache[name] = image
        return name
    }

    static func loadImage(_ file: String, pageID: UUID) -> UIImage? {
        if let image = imageCache[file] { return image }
        let url = imagesDir(pageID).appendingPathComponent(file)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        imageCache[file] = image
        return image
    }

    // MARK: PDF

    static func pdfURL(_ file: String) -> URL {
        if let owner = pdfOwner[file] {
            let url = notebookDir(owner).appendingPathComponent(file)
            if exists(url) { return url }
        }
        return dir.appendingPathComponent(file)
    }

    /// 把使用者選的 PDF 複製進某本筆記本的資料夾，回傳檔名
    static func importPDF(from url: URL, notebook id: UUID) -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let name = "pdf-\(UUID().uuidString).pdf"
        let folder = notebookDir(id)
        ensureDir(folder)
        do {
            try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
            pdfOwner[name] = id
            return name
        } catch {
            return nil
        }
    }

    /// 把幾列頁面複製到另一本筆記本的最後面（移出頁面用；原本那本自己再刪掉）。
    /// 每一頁換新的編號；筆跡、圖片跟著複製；PDF 只取用到的那幾頁另存成一個小 PDF（不會把整本課本複製過去）
    @discardableResult
    static func transferRows(_ rows: [PageRow], to target: UUID) -> Bool {
        let fm = FileManager.default
        var dest = loadNotebook(target)
        let targetDir = notebookDir(target)
        ensureDir(targetDir)

        // PDF：每個來源檔只取用到的頁
        var needed: [String: Set<Int>] = [:]
        for row in rows {
            for page in row.pages {
                if let pdf = page.pdf { needed[pdf.file, default: []].insert(pdf.index) }
            }
        }
        var pdfMap: [String: (file: String, index: [Int: Int])] = [:]
        for (file, indexSet) in needed {
            let indices = indexSet.sorted()
            let newName = "pdf-\(UUID().uuidString).pdf"
            let src = pdfURL(file)
            if let document = PDFDocument(url: src) {
                let out = PDFDocument()
                var map: [Int: Int] = [:]
                for i in indices {
                    if let page = document.page(at: i)?.copy() as? PDFPage {
                        out.insert(page, at: out.pageCount)
                        map[i] = out.pageCount - 1
                    }
                }
                if out.pageCount > 0, out.write(to: targetDir.appendingPathComponent(newName)) {
                    pdfOwner[newName] = target
                    pdfMap[file] = (newName, map)
                    continue
                }
            }
            // 取頁失敗：整個檔案複製過去，頁碼不變
            if exists(src), (try? fm.copyItem(at: src, to: targetDir.appendingPathComponent(newName))) != nil {
                pdfOwner[newName] = target
                var same: [Int: Int] = [:]
                for i in indices { same[i] = i }
                pdfMap[file] = (newName, same)
            }
        }

        for original in rows {
            var row = original
            row.id = UUID()
            for p in row.pages.indices {
                let old = row.pages[p].id
                let new = UUID()
                row.pages[p].id = new
                pageOwner[new] = target                          // 先登記，筆跡、圖片才會放進目的地的資料夾
                if let pdf = row.pages[p].pdf {
                    if let m = pdfMap[pdf.file], let ni = m.index[pdf.index] {
                        row.pages[p].pdf = PDFRef(file: m.file, index: ni)
                    } else {
                        row.pages[p].pdf = nil                   // PDF 找不到：變成一般的紙
                    }
                }
                copyDrawingFiles(from: old, to: new)
                for image in row.pages[p].images ?? [] {
                    let src = imagesDir(old).appendingPathComponent(image.file)
                    let folder = imagesDir(new)
                    ensureDir(folder)
                    let dst = folder.appendingPathComponent(image.file)
                    if exists(src) && !exists(dst) { try? fm.copyItem(at: src, to: dst) }
                }
            }
            dest.rows.append(row)
        }
        saveNotebook(dest, id: target)
        return true
    }

    static func deleteNotebook(_ id: UUID) {
        let notebook = loadNotebook(id)
        for row in notebook.rows {
            for page in row.pages {
                try? FileManager.default.removeItem(at: legacyDrawingURL(page.id))
                if let pdf = page.pdf { try? FileManager.default.removeItem(at: dir.appendingPathComponent(pdf.file)) }
            }
        }
        try? FileManager.default.removeItem(at: legacyNotebookURL(id))
        try? FileManager.default.removeItem(at: notebookDir(id))
    }

    /// 改名或搬動後：把舊的資料夾搬到新的位置
    static func moveDirectory(from old: URL, to new: URL) {
        guard old.standardizedFileURL != new.standardizedFileURL, exists(old) else { return }
        ensureDir(new.deletingLastPathComponent())
        try? FileManager.default.moveItem(at: old, to: new)
    }

    // MARK: 舊版（全部檔案擺在一起）整理成新版

    static var needsMigration: Bool { exists(legacyLibraryURL) }

    /// 舊版擺在最外層的檔案
    static func isLegacyDataFile(_ name: String) -> Bool {
        if name.hasPrefix("notebook-") { return true }
        if name.hasPrefix("page-") { return true }
        return name.hasPrefix("pdf-")
    }

    /// 整理前先把舊檔案完整複製一份到 _App資料/整理前的備份
    static func migrate(_ library: LibraryData) -> LibraryData {
        let fm = FileManager.default
        let backup = systemDir.appendingPathComponent("整理前的備份", isDirectory: true)
        ensureDir(backup)
        let rootItems = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for item in rootItems {
            let name: String = item.lastPathComponent
            guard name == "library.json" || isLegacyDataFile(name) else { continue }
            let target = backup.appendingPathComponent(name)
            if !exists(target) { try? fm.copyItem(at: item, to: target) }
        }

        // 每個資料夾、筆記本取一個資料夾名稱
        var lib = library
        for i in lib.folders.indices where lib.folders[i].dirName == nil {
            lib.folders[i].dirName = uniqueDirName(lib.folders[i].name, parent: lib.folders[i].parentID,
                                                   excluding: lib.folders[i].id, in: lib)
        }
        for i in lib.notebooks.indices where lib.notebooks[i].dirName == nil {
            lib.notebooks[i].dirName = uniqueDirName(lib.notebooks[i].title, parent: lib.notebooks[i].folderID,
                                                     excluding: lib.notebooks[i].id, in: lib)
        }
        saveLibrary(lib)

        // 搬進各自的資料夾
        for f in lib.folders { ensureDir(folderPath(f.id)) }
        for m in lib.notebooks {
            let folder = notebookDir(m.id)
            ensureDir(folder)
            let oldJSON = legacyNotebookURL(m.id)
            if exists(oldJSON) && !exists(notebookURL(m.id)) { try? fm.moveItem(at: oldJSON, to: notebookURL(m.id)) }
            let notebook = loadNotebook(m.id)
            for row in notebook.rows {
                for page in row.pages {
                    let old = legacyDrawingURL(page.id)
                    let new = drawingURL(page.id)
                    if exists(old) && !exists(new) {
                        ensureDir(new.deletingLastPathComponent())
                        try? fm.moveItem(at: old, to: new)
                    }
                    if let pdf = page.pdf {
                        let oldPDF = dir.appendingPathComponent(pdf.file)
                        let newPDF = folder.appendingPathComponent(pdf.file)
                        if exists(oldPDF) && !exists(newPDF) { try? fm.moveItem(at: oldPDF, to: newPDF) }
                    }
                }
            }
        }

        // 剩下沒有用到的舊檔案收進 _App資料
        let leftovers = systemDir.appendingPathComponent("沒用到的舊檔案", isDirectory: true)
        let remaining = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for item in remaining {
            let name: String = item.lastPathComponent
            guard isLegacyDataFile(name) else { continue }
            ensureDir(leftovers)
            try? fm.moveItem(at: item, to: leftovers.appendingPathComponent(name))
        }
        try? fm.removeItem(at: legacyLibraryURL)          // 已經存到 _App資料/library.json
        return lib
    }

    // MARK: 資料位置

    /// 開 App 時：找回上次選的資料夾
    static func restoreDataFolder() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return }
        _ = url.startAccessingSecurityScopedResource()          // 一直保持可以存取
        customDir = url
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
    }

    /// 這個資料夾裡有沒有筆記資料
    static func hasLibrary(at folder: URL) -> Bool {
        exists(folder.appendingPathComponent(systemFolderName).appendingPathComponent("library.json"))
            || exists(folder.appendingPathComponent("library.json"))
    }

    /// 把一個資料夾裡的東西整個複製到另一個資料夾（同名的會被取代）
    static func copyAll(from source: URL, to target: URL) -> Bool {
        let fm = FileManager.default
        var ok = true
        let items = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            let dest = target.appendingPathComponent(item.lastPathComponent)
            if exists(dest) { try? fm.removeItem(at: dest) }
            do { try fm.copyItem(at: item, to: dest) } catch { ok = false }
        }
        return ok
    }

    /// 改用某個資料夾（nil：改回 App 自己的資料夾）
    static func useFolder(_ folder: URL?) {
        if let folder = folder {
            _ = folder.startAccessingSecurityScopedResource()
            customDir = folder
            if let data = try? folder.bookmarkData() {
                UserDefaults.standard.set(data, forKey: bookmarkKey)
            }
        } else {
            customDir = nil
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
        pageOwner = [:]
        pdfOwner = [:]
        BoardTiles.resetMemory()                                // 分區儲存記在記憶體裡的指紋（v12.11.0）
    }
}
