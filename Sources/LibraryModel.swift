import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// LibraryModel.swift：LibraryModel：首頁的資料（資料夾、筆記本、排序、搜尋、移動、最近刪除、隨手記）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

// MARK: - 3. 首頁：資料夾與筆記本

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var library: LibraryData
    @Published var openRequest: NotebookMeta?          // 「新建並全屏打開」：首頁收到後直接打開
    @Published var openNotebook: NotebookMeta? {       // 正在看的筆記本：蓋在整個首頁（含側邊欄）上面（v11.17）
        didSet {
            if let meta = openNotebook { addTab(meta.id) }     // 打開的筆記本都放進上面的分頁（v12.8.2）
        }
    }
    /// 跳轉捷徑指到別本：打開那一本之後要跳到哪一頁（v12.15.11）
    var pendingJump: PageJump?
    /// 這一次換筆記本用「從中間放大」的動畫（白板上的浮動視窗放大成整個畫面；v12.12.3）
    @Published var zoomTransition = false

    /// 從白板的浮動視窗放大成整個畫面：馬上換過去，用放大的動畫
    func expandOpen(_ meta: NotebookMeta) {
        zoomTransition = true
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { openNotebook = meta }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.zoomTransition = false }
    }

    /// 上面的分頁（v12.8.2，照 GoodNotes）：打開過、還沒關掉的筆記本和白板，照打開的順序。存在 UserDefaults，重開 App 還在
    @Published private(set) var openTabs: [UUID] = []

    init() {
        Store.restoreDataFolder()                      // 資料存在自己選的資料夾的話，先找回來
        // 設定以資料夾裡的為準（v12.9）：資料夾裡的比較新就讀回來
        if Store.restoreSettingsIfNeeded() { PenBoxModel.shared.reloadFromDefaults() }
        StorageReport.clear(StorageReport.exportURL)        // 上次匯出留下的 PDF（v12.9.7：只清自己的子資料夾）
        var lib = Store.loadLibrary()
        if Store.needsMigration { lib = Store.migrate(lib) }   // 舊版擺在一起的檔案：整理成照資料夾擺
        library = lib
        purgeExpiredTrash()                            // 最近刪除超過 30 天的：永久刪除
        openTabs = (UserDefaults.standard.stringArray(forKey: Self.tabsKey) ?? []).compactMap { UUID(uuidString: $0) }
    }

    // MARK: 上面的分頁（v12.8.2）

    static let tabsKey = "openTabs"

    private func saveTabs() {
        UserDefaults.standard.set(openTabs.map { $0.uuidString }, forKey: Self.tabsKey)
    }

    private func addTab(_ id: UUID) {
        defer { tabAnchor = nil }
        guard !openTabs.contains(id) else { return }
        if let anchor = tabAnchor, let i = openTabs.firstIndex(of: anchor) {
            openTabs.insert(id, at: i + 1)                 // 分頁的 ＋ 回首頁選的：放在那個分頁的右邊
        } else {
            openTabs.append(id)
        }
        saveTabs()
    }

    /// 分頁的 ＋（v12.8.8）：回首頁選要開哪一本；選到的開在原本那個分頁的右邊
    private var tabAnchor: UUID?

    func goHomeToOpenTab() {
        goHome()
        tabAnchor = nil                                    // v12.9.3：＋ 在最後面，開的也放最後面
    }

    /// 分頁上要顯示的（刪掉、找不到的不顯示）
    var tabMetas: [NotebookMeta] {
        openTabs.compactMap { (id: UUID) -> NotebookMeta? in
            library.notebooks.first { $0.id == id && $0.deletedAt == nil }
        }
    }

    /// 點分頁：換到那一本（不用動畫，像換分頁）
    func switchTab(_ id: UUID) {
        guard openNotebook?.id != id, let meta = tabMetas.first(where: { $0.id == id }) else { return }
        openNotebook = meta
    }

    /// 回到首頁（分頁留著）
    func goHome() {
        tabAnchor = nil
        withAnimation(.easeInOut(duration: 0.25)) { openNotebook = nil }
    }

    /// 關掉分頁：關的是正在看的那一本，就換到旁邊的分頁；沒有分頁了就回首頁
    func closeTab(_ id: UUID) {
        let before = tabMetas.map { $0.id }
        let index = before.firstIndex(of: id) ?? 0
        openTabs.removeAll { $0 == id }
        saveTabs()
        guard openNotebook?.id == id else { return }
        let rest = tabMetas
        if rest.isEmpty {
            goHome()
        } else {
            openNotebook = rest[max(0, min(index - 1, rest.count - 1))]
        }
    }

    /// 拖分頁換位置（v12.8.4）：往右（+1）或往左（-1）一格；換成功回傳 true
    @discardableResult
    func moveTab(_ id: UUID, by step: Int) -> Bool {
        var order = tabMetas.map { $0.id }                 // 刪掉的筆記本順便從分頁拿掉
        guard let i = order.firstIndex(of: id) else { return false }
        let j = i + step
        guard order.indices.contains(j) else { return false }
        order.swapAt(i, j)
        openTabs = order                                   // 動畫交給分頁列（拖著的那一個不要動畫，才不會跳）
        saveTabs()
        return true
    }

    /// 關掉其他分頁（長按分頁的選單）
    func closeOtherTabs(_ id: UUID) {
        openTabs = openTabs.filter { $0 == id }
        saveTabs()
        if let current = openNotebook, current.id != id { switchTab(id) }
    }

    // MARK: 最近刪除（30 天後自動永久刪除）

    static let trashDays = 30

    /// 最近刪除裡的項目（資料夾裡面的東西跟著資料夾，不另外列）
    var trashedItems: [ItemRef] {
        var list: [(ItemRef, Date)] = []
        for f in library.folders {
            if let d = f.deletedAt { list.append((ItemRef.folder(f.id), d)) }
        }
        for n in library.notebooks {
            guard let d = n.deletedAt else { continue }
            list.append((ItemRef.notebook(n.id), d))
        }
        list.sort { (a: (ItemRef, Date), b: (ItemRef, Date)) -> Bool in a.1 > b.1 }
        return list.map { $0.0 }
    }

    func deletedDate(_ ref: ItemRef) -> Date? {
        switch ref {
        case .folder(let id): return folder(id)?.deletedAt
        case .notebook(let id): return notebook(id)?.deletedAt
        }
    }

    /// 還剩幾天會永久刪除
    func daysLeft(_ ref: ItemRef) -> Int {
        guard let d = deletedDate(ref) else { return Self.trashDays }
        let passed = Int(Date().timeIntervalSince(d) / 86_400)
        return max(0, Self.trashDays - passed)
    }

    func moveToTrash(_ ref: ItemRef) {
        switch ref {
        case .folder(let id):
            guard let i = library.folders.firstIndex(where: { $0.id == id }) else { return }
            let old = Store.folderPath(id)
            library.folders[i].deletedAt = Date()
            save()
            Store.moveDirectory(from: old, to: Store.folderPath(id))
        case .notebook(let id):
            guard let i = library.notebooks.firstIndex(where: { $0.id == id }) else { return }
            let old = Store.notebookDir(id)
            library.notebooks[i].deletedAt = Date()
            // 刪的是白板：家在它裡面的筆記本放回首頁（跟白板同一個資料夾），不會跟著不見（v12.12.0）
            for j in library.notebooks.indices where library.notebooks[j].boardID == id { library.notebooks[j].boardID = nil }
            save()
            Store.moveDirectory(from: old, to: Store.notebookDir(id))
        }
    }

    // MARK: 白板裡的筆記本（v12.12.0）

    /// 在白板裡新建筆記本：檔案放在白板所在的資料夾，但首頁不列出來
    func addNotebook(inBoard board: NotebookMeta, title: String, data: NotebookData = NotebookData()) -> NotebookMeta {
        let meta = addNotebook(in: board.folderID, title: title, data: data)
        setBoardHome(meta.id, board: board.id)
        return notebook(meta.id) ?? meta
    }

    /// 改一本筆記本的家：board 有值＝在那張白板裡（首頁不列）；nil＝回到首頁
    func setBoardHome(_ id: UUID, board: UUID?) {
        guard let i = library.notebooks.firstIndex(where: { $0.id == id }) else { return }
        library.notebooks[i].boardID = board
        save()
    }

    /// 家在這張白板裡的筆記本
    func boardFiles(_ boardID: UUID) -> [NotebookMeta] {
        library.notebooks.filter { $0.boardID == boardID && $0.deletedAt == nil }
            .sorted { (a: NotebookMeta, b: NotebookMeta) -> Bool in a.title < b.title }
    }

    /// 復原：放回原本的資料夾；原本的資料夾也被刪了，就放回最外層；同名的話自動加「 2」
    func restore(_ ref: ItemRef) {
        switch ref {
        case .folder(let id):
            guard let i = library.folders.firstIndex(where: { $0.id == id }) else { return }
            let old = Store.folderPath(id)
            if let parent = library.folders[i].parentID, folder(parent) == nil || folder(parent)?.deletedAt != nil {
                library.folders[i].parentID = nil
            }
            library.folders[i].deletedAt = nil
            let names = uniqueNames(library.folders[i].name, parent: library.folders[i].parentID, excluding: id, folder: true)
            library.folders[i].name = names.title
            library.folders[i].dirName = names.dir
            save()
            Store.moveDirectory(from: old, to: Store.folderPath(id))
        case .notebook(let id):
            guard let i = library.notebooks.firstIndex(where: { $0.id == id }) else { return }
            let old = Store.notebookDir(id)
            if let parent = library.notebooks[i].folderID, folder(parent) == nil || folder(parent)?.deletedAt != nil {
                library.notebooks[i].folderID = nil
            }
            library.notebooks[i].deletedAt = nil
            let names = uniqueNames(library.notebooks[i].title, parent: library.notebooks[i].folderID, excluding: id, folder: false)
            library.notebooks[i].title = names.title
            library.notebooks[i].dirName = names.dir
            save()
            Store.moveDirectory(from: old, to: Store.notebookDir(id))
        }
    }

    func deleteForever(_ ref: ItemRef) {
        switch ref {
        case .folder(let id): deleteFolder(id)
        case .notebook(let id): deleteNotebook(id)
        }
    }

    func restoreAll() {
        for ref in trashedItems { restore(ref) }
    }

    /// 某個資料夾是不是在另一個資料夾裡面（避免把資料夾搬進自己裡面）
    func isInside(_ folderID: UUID?, ancestor: UUID) -> Bool {
        var current = folderID
        while let id = current {
            if id == ancestor { return true }
            current = folder(id)?.parentID
        }
        return false
    }

    /// 選取後「移動到…」：可以搬去的資料夾（名稱含上層路徑）
    func moveTargets(excluding refs: [ItemRef]) -> [(id: UUID, name: String)] {
        var result: [(id: UUID, name: String)] = []
        func walk(_ parent: UUID?, prefix: String) {
            for ref in items(in: parent) {
                guard case .folder(let id) = ref, let f = folder(id) else { continue }
                var blocked = false
                for r in refs {
                    if case .folder(let selectedID) = r, isInside(id, ancestor: selectedID) { blocked = true }
                }
                if blocked { continue }
                let name = prefix.isEmpty ? f.name : prefix + " / " + f.name
                result.append((id: id, name: name))
                walk(id, prefix: name)
            }
        }
        walk(nil, prefix: "")
        return result
    }

    /// 搬到另一個資料夾（nil：最外層）；同名的話自動加「 2」
    func moveItems(_ refs: [ItemRef], to target: UUID?) {
        for ref in refs {
            switch ref {
            case .folder(let id):
                guard let i = library.folders.firstIndex(where: { $0.id == id }) else { continue }
                if let t = target, isInside(t, ancestor: id) { continue }
                let old = Store.folderPath(id)
                library.folders[i].parentID = target
                let names = uniqueNames(library.folders[i].name, parent: target, excluding: id, folder: true)
                library.folders[i].name = names.title
                library.folders[i].dirName = names.dir
                save()
                Store.moveDirectory(from: old, to: Store.folderPath(id))
            case .notebook(let id):
                guard let i = library.notebooks.firstIndex(where: { $0.id == id }) else { continue }
                let old = Store.notebookDir(id)
                library.notebooks[i].folderID = target
                let names = uniqueNames(library.notebooks[i].title, parent: target, excluding: id, folder: false)
                library.notebooks[i].title = names.title
                library.notebooks[i].dirName = names.dir
                save()
                Store.moveDirectory(from: old, to: Store.notebookDir(id))
            }
        }
    }

    /// 搜尋：名字含有這段文字的筆記本、資料夾（不含最近刪除裡的）
    func search(_ text: String) -> [ItemRef] {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return [] }
        var result: [ItemRef] = []
        func walk(_ parent: UUID?) {
            for ref in items(in: parent) {
                switch ref {
                case .folder(let id):
                    if let f = folder(id), f.name.lowercased().contains(key) { result.append(ref) }
                    walk(id)
                case .notebook(let id):
                    if let m = notebook(id), m.title.lowercased().contains(key) { result.append(ref) }
                }
            }
        }
        walk(nil)
        return result
    }

    func emptyTrash() {
        for ref in trashedItems { deleteForever(ref) }
    }

    func purgeExpiredTrash() {
        for ref in trashedItems where daysLeft(ref) <= 0 { deleteForever(ref) }
    }

    /// 換了資料位置之後重新讀取
    func reload() {
        var lib = Store.loadLibrary()
        if Store.needsMigration { lib = Store.migrate(lib) }
        library = lib
        covers = [:]
        // 設定被清掉、而這個資料位置裡有備份：讀回來（v12.4）
        if Store.restoreSettingsIfNeeded() { PenBoxModel.shared.reloadFromDefaults() }
        MathRenderer.shared.cleanCache()                          // 數學式快取：刪掉 30 天沒用到的（v12.6）
    }

    private func save() { Store.saveLibrary(library) }

    func folders(in parent: UUID?) -> [NoteFolder] {
        library.folders.filter { $0.parentID == parent }.sorted { $0.name < $1.name }
    }

    func notebooks(in folder: UUID?) -> [NotebookMeta] {
        library.notebooks.filter { $0.folderID == folder && $0.boardID == nil }.sorted { $0.modified > $1.modified }
    }

    /// 名字（v12.15.11，使用者：資料夾和筆記本可以同名）：只跟同一層、同一種的比，重複才加「 2」「 3」；
    /// 磁碟上的資料夾名稱另外取，跟所有東西都不重複（資料夾「測試」旁邊的筆記本「測試」放在「測試 2」這個資料夾裡，畫面上還是叫「測試」）
    func uniqueNames(_ wanted: String, parent: UUID?, excluding id: UUID?, folder isFolder: Bool) -> (title: String, dir: String) {
        var used = Set<String>()
        if isFolder {
            for f in library.folders where f.parentID == parent && f.id != id && f.deletedAt == nil { used.insert(f.name) }
        } else {
            for m in library.notebooks where m.folderID == parent && m.id != id && m.deletedAt == nil { used.insert(m.title) }
        }
        var base = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = isFolder ? "未命名資料夾" : "未命名筆記本" }
        var title = base
        var k = 2
        while used.contains(title) {
            title = "\(base) \(k)"
            k += 1
        }
        return (title, Store.uniqueDirName(title, parent: parent, excluding: id, in: library))
    }

    func addFolder(in parent: UUID?, name: String = "未命名資料夾", colorIndex: Int? = nil) -> NoteFolder {
        // 名字跟「檔案」App 的資料夾一樣：同一層不重名、不能用「/」
        let names = uniqueNames(name, parent: parent, excluding: nil, folder: true)
        var folder = NoteFolder(name: names.title, parentID: parent, colorIndex: colorIndex)
        folder.dirName = names.dir
        library.folders.append(folder)
        library.order = [folder.id] + (library.order ?? [])      // 新的放最前面
        save()
        Store.ensureDir(Store.folderPath(folder.id))
        return folder
    }

    func updateFolder(_ id: UUID, name: String, colorIndex: Int) {
        guard let i = library.folders.firstIndex(where: { $0.id == id }) else { return }
        let oldPath = Store.folderPath(id)
        var finalName = library.folders[i].name
        if library.folders[i].name != name || library.folders[i].dirName == nil {
            let names = uniqueNames(name, parent: library.folders[i].parentID, excluding: id, folder: true)
            finalName = names.title
            library.folders[i].dirName = names.dir
        }
        library.folders[i].name = finalName
        library.folders[i].colorIndex = colorIndex
        save()
        Store.moveDirectory(from: oldPath, to: Store.folderPath(id))     // 資料夾跟著改名
    }

    func folder(_ id: UUID) -> NoteFolder? { library.folders.first { $0.id == id } }
    func notebook(_ id: UUID) -> NotebookMeta? { library.notebooks.first { $0.id == id } }

    /// 某個資料夾裡的所有項目（資料夾、筆記本混在一起），照自己排的順序
    func items(in folder: UUID?) -> [ItemRef] {
        // 分成幾個簡單的步驟寫，編譯器才不會卡住
        var position: [UUID: Int] = [:]
        for (i, id) in (library.order ?? []).enumerated() { position[id] = i }

        var newFolders: [NoteFolder] = []           // 還沒排過的資料夾
        var newNotebooks: [NotebookMeta] = []       // 還沒排過的筆記本
        var placed: [(id: UUID, ref: ItemRef)] = [] // 排過的
        for f in library.folders where f.parentID == folder && f.deletedAt == nil {
            if position[f.id] == nil {
                newFolders.append(f)
            } else {
                placed.append((id: f.id, ref: ItemRef.folder(f.id)))
            }
        }
        // 家在白板裡的筆記本（boardID 有值，v12.12.0）首頁不列
        for n in library.notebooks where n.folderID == folder && n.deletedAt == nil && n.boardID == nil {
            if position[n.id] == nil {
                newNotebooks.append(n)
            } else {
                placed.append((id: n.id, ref: ItemRef.notebook(n.id)))
            }
        }
        newNotebooks.sort { (a: NotebookMeta, b: NotebookMeta) -> Bool in a.modified > b.modified }
        placed.sort { (a: (id: UUID, ref: ItemRef), b: (id: UUID, ref: ItemRef)) -> Bool in
            (position[a.id] ?? 0) < (position[b.id] ?? 0)
        }

        // 還沒排過的放前面：資料夾先、筆記本照修改時間
        var result: [ItemRef] = []
        for f in newFolders { result.append(ItemRef.folder(f.id)) }
        for n in newNotebooks { result.append(ItemRef.notebook(n.id)) }
        for item in placed { result.append(item.ref) }
        // 釘選的（v12.15.11）排在最前面，照釘選的先後
        let pinnedHere = result.filter { pinDate($0) != nil }
            .sorted { (pinDate($0) ?? Date.distantPast) < (pinDate($1) ?? Date.distantPast) }
        if !pinnedHere.isEmpty {
            result = pinnedHere + result.filter { pinDate($0) == nil }
        }
        return result
    }

    // MARK: 釘選（v12.15.11，使用者要求）

    func pinDate(_ ref: ItemRef) -> Date? {
        switch ref {
        case .folder(let id): return folder(id)?.pinned
        case .notebook(let id): return notebook(id)?.pinned
        }
    }

    func togglePin(_ ref: ItemRef) {
        let now: Date? = pinDate(ref) == nil ? Date() : nil
        switch ref {
        case .folder(let id):
            guard let i = library.folders.firstIndex(where: { $0.id == id }) else { return }
            library.folders[i].pinned = now
        case .notebook(let id):
            guard let i = library.notebooks.firstIndex(where: { $0.id == id }) else { return }
            library.notebooks[i].pinned = now
        }
        save()
    }

    /// 所有釘選的（側邊欄）：照釘選的先後
    var pinnedItems: [ItemRef] {
        var list: [(Date, ItemRef)] = []
        for f in library.folders where f.deletedAt == nil {
            if let d = f.pinned { list.append((d, ItemRef.folder(f.id))) }
        }
        for n in library.notebooks where n.deletedAt == nil {
            if let d = n.pinned { list.append((d, ItemRef.notebook(n.id))) }
        }
        return list.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// 側邊欄用的資料夾樹（照首頁排的順序）
    func folderTree(parent: UUID?) -> [FolderNode] {
        var nodes: [FolderNode] = []
        for ref in items(in: parent) {
            guard case .folder(let id) = ref, let f = folder(id) else { continue }
            let kids: [FolderNode] = folderTree(parent: id)
            nodes.append(FolderNode(id: id, name: f.name, colorIndex: f.colorIndex,
                                    children: kids.isEmpty ? nil : kids))
        }
        return nodes
    }

    /// 長按拖曳：把 id 移到 target 的位置
    func move(_ id: UUID, to target: UUID, in folder: UUID?) {
        var ids = items(in: folder).map { $0.id }
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target), from != to else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        library.order = ids + (library.order ?? []).filter { !ids.contains($0) }
        save()
    }

    // 筆記本的第一頁預覽（照修改時間快取；離開筆記本後會自動更新）
    private var covers: [String: UIImage] = [:]

    func cover(for meta: NotebookMeta) -> UIImage? {
        let key = "\(meta.id.uuidString)-\(meta.modified.timeIntervalSince1970)"
        if let image = covers[key] { return image }
        let data = Store.loadNotebook(meta.id)
        guard let row = data.rows.first, row.pages.indices.contains(row.mainIndex) else { return nil }
        let image = Thumbnail.image(for: row.pages[row.mainIndex], width: 220)
        covers = covers.filter { !$0.key.hasPrefix(meta.id.uuidString) }
        covers[key] = image
        return image
    }

    // MARK: 複製一份、拷貝、貼上

    @Published var copied: [ItemRef] = []          // 首頁的「拷貝」（貼上時才真的複製）
    @Published var draggingID: UUID?               // 正在拖的項目（側邊欄、彈開的資料夾裡放下時要知道是哪一個）
    @Published var dropHover: UUID?                // 停在資料夾圖示中間夠久：亮起來，放開就放進去
    @Published var springRequest: SpringRequest?   // 拖曳中停久一點：打開資料夾、回到上一層（像 Finder）
    private var hoverPending: UUID?
    private var hoverToken = 0
    private var lastReorder: (id: UUID, at: Date)?

    /// 拖曳中要換頁：打開某個資料夾，或回到上一層
    struct SpringRequest: Equatable {
        let token = UUID()
        let openFolder: UUID?          // nil：回到上一層
    }

    /// 停在資料夾圖示中間（像 Finder）：
    /// 0.8 秒資料夾亮起來（這時放開就放進去），再停 1.2 秒資料夾自己打開，可以在裡面繼續排位置
    func beginHover(_ target: UUID) {
        if hoverPending == target { return }             // 已經在計時
        hoverPending = target
        hoverToken += 1
        let token = hoverToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self = self, self.hoverToken == token, self.hoverPending == target else { return }
            self.dropHover = target
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard self.hoverToken == token, self.hoverPending == target else { return }
            self.hoverPending = nil
            self.dropHover = nil
            self.springRequest = SpringRequest(openFolder: target)
        }
    }

    func endHover(_ target: UUID) {
        if hoverPending == target {
            hoverPending = nil
            hoverToken += 1
        }
        if dropHover == target { dropHover = nil }
    }

    /// 拖曳排位置：同一個目標 0.4 秒內不重複換（項目讓開時，手指底下會換成別的項目，避免來回跳）
    func reorder(_ id: UUID, to target: UUID, in folder: UUID?) {
        if let last = lastReorder, last.id == target, Date().timeIntervalSince(last.at) < 0.4 { return }
        lastReorder = (target, Date())
        withAnimation(.easeInOut(duration: 0.2)) {
            move(id, to: target, in: folder)
        }
    }

    /// 拖曳中的項目還在別層（資料夾彈開、回到上一層之後）：先搬進這一層，才能在這裡排位置
    func bringHere(_ id: UUID, folder: UUID?) {
        guard let ref = ref(for: id), parent(of: ref) != folder else { return }
        if let f = folder, !canDrop(id, into: f) { return }
        withAnimation(.easeInOut(duration: 0.2)) { moveItems([ref], to: folder) }
    }

    func clearDrag() {
        hoverPending = nil
        hoverToken += 1
        dropHover = nil
        draggingID = nil
        lastReorder = nil
    }

    /// 側邊欄「編輯排列順序」：同一層的資料夾和筆記本一起換順序（v11.25）
    func reorderItems(in parent: UUID?, from source: IndexSet, to destination: Int) {
        var ids = items(in: parent).map { $0.id }
        ids.move(fromOffsets: source, toOffset: destination)
        library.order = ids + (library.order ?? []).filter { !ids.contains($0) }
        save()
    }

    /// 首頁拖到「放到最後」：移到這一層的最後面
    func moveToEnd(_ id: UUID, in folder: UUID?) {
        var ids = items(in: folder).map { $0.id }
        guard let from = ids.firstIndex(of: id), from != ids.count - 1 else { return }
        ids.remove(at: from)
        ids.append(id)
        library.order = ids + (library.order ?? []).filter { !ids.contains($0) }
        save()
    }

    /// 舊的：只換資料夾（筆記本位置不動），已經改用 reorderItems
    func reorderFolders(in parent: UUID?, from source: IndexSet, to destination: Int) {
        let all = items(in: parent).map { $0.id }
        var folders = all.filter { folder($0) != nil }
        folders.move(fromOffsets: source, toOffset: destination)
        var result = all
        var next = 0
        for i in result.indices where folder(result[i]) != nil {
            result[i] = folders[next]
            next += 1
        }
        library.order = result + (library.order ?? []).filter { !result.contains($0) }
        save()
    }

    func ref(for id: UUID) -> ItemRef? {
        if folder(id) != nil { return .folder(id) }
        if notebook(id) != nil { return .notebook(id) }
        return nil
    }

    /// 能不能把 id 放進 folderID（資料夾不能放進自己或自己裡面）
    func canDrop(_ id: UUID, into folderID: UUID) -> Bool {
        id != folderID && !isInside(folderID, ancestor: id)
    }

    /// 拷貝的東西還在（沒被刪掉、沒在最近刪除）
    var copiedAlive: [ItemRef] {
        copied.filter { ref in
            switch ref {
            case .folder(let id): return folder(id).map { $0.deletedAt == nil } ?? false
            case .notebook(let id): return notebook(id).map { $0.deletedAt == nil } ?? false
            }
        }
    }

    var copiedLabel: String {
        let alive = copiedAlive
        if alive.count == 1, let ref = alive.first {
            switch ref {
            case .folder(let id): return "「\(folder(id)?.name ?? "")」"
            case .notebook(let id): return "「\(notebook(id)?.title ?? "")」"
            }
        }
        return "\(alive.count) 個項目"
    }

    func parent(of ref: ItemRef) -> UUID? {
        switch ref {
        case .folder(let id): return folder(id)?.parentID
        case .notebook(let id): return notebook(id)?.folderID
        }
    }

    /// 複製一份，放在原本那一項的旁邊
    func duplicateNextTo(_ ref: ItemRef) {
        let parentID = parent(of: ref)
        let newID: UUID?
        switch ref {
        case .folder(let id):
            newID = duplicateFolder(id, into: parentID, name: (folder(id)?.name ?? "資料夾") + " 副本")
        case .notebook(let id):
            newID = duplicateNotebook(id, into: parentID, title: (notebook(id)?.title ?? "筆記本") + " 副本")
        }
        if let n = newID { place(n, after: ref.id, in: parentID) }
    }

    /// 貼上：把拷貝的東西複製一份到這個資料夾（同名會自動加「 2」）
    func paste(into target: UUID?) {
        for ref in copiedAlive {
            switch ref {
            case .folder(let id):
                if let t = target, isInside(t, ancestor: id) { continue }      // 不能貼進自己裡面
                _ = duplicateFolder(id, into: target, name: folder(id)?.name ?? "資料夾")
            case .notebook(let id):
                _ = duplicateNotebook(id, into: target, title: notebook(id)?.title ?? "筆記本")
            }
        }
    }

    private func place(_ newID: UUID, after anchor: UUID, in folder: UUID?) {
        var ids = items(in: folder).map { $0.id }
        guard let from = ids.firstIndex(of: newID) else { return }
        ids.remove(at: from)
        guard let a = ids.firstIndex(of: anchor) else { return }
        ids.insert(newID, at: a + 1)
        library.order = ids + (library.order ?? []).filter { !ids.contains($0) }
        save()
    }

    /// 複製一本筆記本。每一頁、每個 PDF 都換新的編號：App 用頁面編號找筆跡檔、用檔名找 PDF，
    /// 沿用舊編號的話，兩本會搶同一個檔案。歷史版本不複製。
    func duplicateNotebook(_ id: UUID, into folder: UUID?, title: String) -> UUID? {
        guard let meta = notebook(id) else { return nil }
        let fm = FileManager.default
        let sourceDir = Store.notebookDir(id)
        var data = Store.loadNotebook(id)
        var pageMap: [UUID: UUID] = [:]
        var pdfMap: [String: String] = [:]
        for r in data.rows.indices {
            for p in data.rows[r].pages.indices {
                let old = data.rows[r].pages[p].id
                let new = UUID()
                pageMap[old] = new
                data.rows[r].pages[p].id = new
                if let pdf = data.rows[r].pages[p].pdf {
                    let newName = pdfMap[pdf.file] ?? "pdf-\(UUID().uuidString).pdf"
                    pdfMap[pdf.file] = newName
                    data.rows[r].pages[p].pdf?.file = newName
                }
            }
        }
        data.bookmarks = data.bookmarks?.compactMap { pageMap[$0] }
        var outlineMap: [UUID: UUID] = [:]                      // 大綱的層級（v12.11.0）：上一層也要換成新的編號
        for item in data.outline ?? [] { outlineMap[item.id] = UUID() }
        data.outline = data.outline?.compactMap { (item: OutlineItem) -> OutlineItem? in
            guard let new = pageMap[item.pageID] else { return nil }
            var copy = item
            copy.id = outlineMap[item.id] ?? UUID()
            copy.pageID = new
            copy.parentID = item.parentID.flatMap { outlineMap[$0] }
            return copy
        }
        data.lastPage = data.lastPage.flatMap { pageMap[$0] }

        let created = addNotebook(in: folder, title: title, data: data)     // 存 notebook.json、登記新的頁面
        if let i = library.notebooks.firstIndex(where: { $0.id == created.id }) {
            library.notebooks[i].colorIndex = meta.colorIndex
            save()
        }
        let targetDir = Store.notebookDir(created.id)
        Store.ensureDir(targetDir)
        // 筆跡：換成新的頁面編號
        for (old, new) in pageMap {
            Store.copyDrawingFiles(from: old, to: new)         // 分區儲存的頁連格子檔一起（v12.11.0）
        }
        // PDF：換成新的檔名
        for (oldName, newName) in pdfMap {
            let src = Store.pdfURL(oldName)
            if Store.exists(src) { try? fm.copyItem(at: src, to: targetDir.appendingPathComponent(newName)) }
        }
        // 圖片：檔名不用換（只在這本筆記本自己的資料夾裡找）
        let images = sourceDir.appendingPathComponent("圖片", isDirectory: true)
        if Store.exists(images) {
            let dst = targetDir.appendingPathComponent("圖片", isDirectory: true)
            Store.ensureDir(dst)
            _ = Store.copyAll(from: images, to: dst)
        }
        return created.id
    }

    /// 複製整個資料夾（裡面的筆記本、子資料夾一起，順序不變）
    func duplicateFolder(_ id: UUID, into parent: UUID?, name: String) -> UUID? {
        guard let source = folder(id) else { return nil }
        if let p = parent, isInside(p, ancestor: id) { return nil }
        let children = items(in: id)
        let created = addFolder(in: parent, name: name, colorIndex: source.colorIndex)
        for child in children.reversed() {                      // 新的會排在最前面，倒著複製順序才會一樣
            switch child {
            case .folder(let cid):
                _ = duplicateFolder(cid, into: created.id, name: folder(cid)?.name ?? "資料夾")
            case .notebook(let cid):
                _ = duplicateNotebook(cid, into: created.id, title: notebook(cid)?.title ?? "筆記本")
            }
        }
        return created.id
    }

    // MARK: 隨手記（v11.23）

    static let quickNotesKey = "quickNotebookID"

    /// 隨手記那本筆記本（被刪掉、還沒建立就是 nil）
    var quickNotebook: NotebookMeta? {
        guard let text = UserDefaults.standard.string(forKey: Self.quickNotesKey),
              let id = UUID(uuidString: text), let meta = notebook(id), meta.deletedAt == nil else { return nil }
        return meta
    }

    /// 打開隨手記；還沒有就在最外層建一本「隨手記」
    func openQuickNotes() {
        let meta: NotebookMeta
        if let existing = quickNotebook {
            meta = existing
        } else {
            meta = addNotebook(in: nil, title: "隨手記")
            UserDefaults.standard.set(meta.id.uuidString, forKey: Self.quickNotesKey)
        }
        withAnimation(.easeInOut(duration: 0.25)) { openNotebook = meta }
    }

    /// 資料夾路徑文字，例如「考研 / 工數」；最外層是「所有文件」
    func folderPathText(_ folderID: UUID?) -> String {
        var names: [String] = []
        var current = folderID
        var guardCount = 0
        while let id = current, let f = folder(id), guardCount < 50 {
            names.insert(f.name, at: 0)
            current = f.parentID
            guardCount += 1
        }
        return names.isEmpty ? "所有文件" : names.joined(separator: " / ")
    }

    func addNotebook(in folder: UUID?, title: String = "未命名筆記本",
                     data: NotebookData = NotebookData()) -> NotebookMeta {
        let names = uniqueNames(title, parent: folder, excluding: nil, folder: false)
        var meta = NotebookMeta(title: names.title, folderID: folder, colorIndex: Int.random(in: 0..<8))
        meta.dirName = names.dir
        library.notebooks.append(meta)
        library.order = [meta.id] + (library.order ?? [])        // 新的放最前面
        save()                                                   // 先登記，筆記本才知道要存在哪個資料夾
        Store.saveNotebook(data, id: meta.id)
        return meta
    }

    /// 新白板（v12.3）：一本只有一張大頁面的筆記本。寬高的單位是點（一張 A4 是 595 × 842）
    /// 刪掉的頁（v12.9.2）：複製成一本「已刪除的頁」放進最近刪除（30 天內可以打開看、復原；復原後用「移動頁面」搬回去）
    func trashDeletedPages(_ rows: [PageRow], title: String, folder: UUID?) {
        guard !rows.isEmpty else { return }
        let meta = addNotebook(in: folder, title: "已刪除的頁－" + title, data: NotebookData(rows: []))
        guard Store.transferRows(rows, to: meta.id) else {
            deleteNotebook(meta.id)
            return
        }
        moveToTrash(.notebook(meta.id))
    }

    /// Markdown 筆記本（v12.9.2；v12.9.3 改成深灰底）：沒有格線，每一頁是一個整頁寬、固定的 Markdown 方塊；往下拉新增的頁也是
    func addMarkdownNotebook(in folder: UUID?) -> NotebookMeta {
        let spec = PageSpec()
        var page = NotePage(spec: spec, paper: PaperStyle(pattern: 0, color: 0))   // v12.9.3：深色、沒有格線
        let intro = "# 標題\n\n點一下就能打字（Pencil 手寫會轉成文字），也可以貼上整段 Markdown。\n\n- 條列\n- **粗體**、*斜體*、`程式碼`\n- 數學式 $E = mc^2$\n\n$$\\int_0^1 x\\,dx = \\frac{1}{2}$$\n\n寫超過頁底，這一頁會自己往下長；往下拉可以新增一頁。"
        page.texts = [markdownPageBox(spec: spec, text: intro, fontSize: TextDefaults.size(nil),
                                      rgba: TextDefaults.rgba(nil) ?? [1, 1, 1, 1])]
        var row = PageRow()
        row.pages = [page]
        var data = NotebookData(rows: [row])
        data.markdown = true
        return addNotebook(in: folder, title: "未命名 Markdown", data: data)
    }

    func addBoard(in folder: UUID?, title: String, width: CGFloat, height: CGFloat) -> NotebookMeta {
        var spec = PageSpec(width: width, height: height)
        spec.flat = true
        var row = PageRow()
        row.pages = [NotePage(spec: spec, paper: PaperStyle(pattern: 2, color: 0))]
        var data = NotebookData(rows: [row])
        data.board = true
        var meta = addNotebook(in: folder, title: title, data: data)
        if let i = library.notebooks.firstIndex(where: { $0.id == meta.id }) {
            library.notebooks[i].isBoard = true
            meta = library.notebooks[i]
            save()
        }
        // v12.11.1（使用者決定）：新建的白板一開始就用分區儲存；不想用的話在白板的齒輪面板關掉。舊的白板不動
        if let page = Store.loadNotebook(meta.id).rows.first?.pages.first {
            _ = BoardTiles.enable(page.id, drawing: PKDrawing())
        }
        return meta
    }

    /// 匯入 PDF：每一頁 PDF 變成一張主頁（尺寸跟 PDF 一樣）
    func importPDF(from url: URL, into folder: UUID?) -> Bool {
        importPDFNotebook(from: url, into: folder) != nil
    }

    /// 匯入一份文件（v12.14.0）：PDF → 每頁是課本頁的筆記本；Markdown、純文字 → Markdown 筆記本。其他格式回傳 nil
    func importDocument(from url: URL, into folder: UUID?) -> NotebookMeta? {
        switch url.pathExtension.lowercased() {
        case "pdf": return importPDFNotebook(from: url, into: folder)
        case "md", "markdown", "txt": return importMarkdownNotebook(from: url, into: folder)
        default: return nil
        }
    }

    static func isDocument(_ url: URL) -> Bool {
        ["pdf", "md", "markdown", "txt"].contains(url.pathExtension.lowercased())
    }

    /// 匯入 Markdown／純文字檔：一本 Markdown 筆記本，第一頁就是整份內容（名稱用檔名）
    func importMarkdownNotebook(from url: URL, into folder: UUID?) -> NotebookMeta? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bytes = try? Data(contentsOf: url),
              let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16) else { return nil }
        let spec = PageSpec()
        var page = NotePage(spec: spec, paper: PaperStyle(pattern: 0, color: 0))
        page.texts = [markdownPageBox(spec: spec, text: text, fontSize: TextDefaults.size(nil),
                                      rgba: TextDefaults.rgba(nil) ?? [1, 1, 1, 1])]
        var row = PageRow()
        row.pages = [page]
        var data = NotebookData(rows: [row])
        data.markdown = true
        return addNotebook(in: folder, title: url.deletingPathExtension().lastPathComponent, data: data)
    }

    /// 匯入 PDF，回傳做好的筆記本（白板上匯入 PDF 用；v12.12.0）
    func importPDFNotebook(from url: URL, into folder: UUID?) -> NotebookMeta? {
        let title = url.deletingPathExtension().lastPathComponent
        let meta = addNotebook(in: folder, title: title, data: NotebookData(rows: []))
        guard let file = Store.importPDF(from: url, notebook: meta.id),
              let document = PDFDocument(url: Store.pdfURL(file)),
              document.pageCount > 0 else {
            deleteNotebook(meta.id)
            return nil
        }
        var rows: [PageRow] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            let spec = PageSpec(width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
            var row = PageRow()
            row.pages = [NotePage(spec: spec, pdf: PDFRef(file: file, index: i))]
            rows.append(row)
        }
        Store.saveNotebook(NotebookData(rows: rows), id: meta.id)
        return meta
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let i = library.folders.firstIndex(where: { $0.id == id }) else { return }
        updateFolder(id, name: name, colorIndex: library.folders[i].colorIndex ?? defaultFolderColor)
    }

    func renameNotebook(_ id: UUID, to name: String) {
        guard let i = library.notebooks.firstIndex(where: { $0.id == id }) else { return }
        let oldPath = Store.notebookDir(id)
        let names = uniqueNames(name, parent: library.notebooks[i].folderID, excluding: id, folder: false)
        library.notebooks[i].title = names.title
        library.notebooks[i].dirName = names.dir
        save()
        Store.moveDirectory(from: oldPath, to: Store.notebookDir(id))    // 資料夾跟著改名
    }

    func touchNotebook(_ id: UUID) {
        guard let i = library.notebooks.firstIndex(where: { $0.id == id }) else { return }
        library.notebooks[i].modified = Date()
        save()
    }

    func deleteNotebook(_ id: UUID) {
        Store.deleteNotebook(id)
        library.notebooks.removeAll { $0.id == id }
        library.order?.removeAll { $0 == id }
        save()
    }

    /// 刪除資料夾時，裡面的子資料夾和筆記本一起刪除
    func deleteFolder(_ id: UUID) {
        let path = Store.folderPath(id)
        for sub in library.folders where sub.parentID == id { deleteFolder(sub.id) }
        for nb in library.notebooks where nb.folderID == id { Store.deleteNotebook(nb.id) }
        try? FileManager.default.removeItem(at: path)
        library.notebooks.removeAll { $0.folderID == id }
        library.folders.removeAll { $0.id == id }
        let alive = Set(library.folders.map { $0.id } + library.notebooks.map { $0.id })
        library.order?.removeAll { !alive.contains($0) }
        save()
    }
}
