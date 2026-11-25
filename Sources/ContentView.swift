import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// 版本：v12.7（首頁最下方也會顯示，用來確認跑的是哪一版）
let appVersion = "v12.16.2"
//
// v12.0 起，程式拆成下面這些檔案（同一個 App 專案裡，檔案之間可以直接互相使用，不用另外 import）：
//   ContentView.swift     最外層：版本號、側邊欄＋首頁的外框（ContentView）、側邊欄的資料夾列與排列順序
//   Models.swift          共用的小工具與資料型別：螢光筆判斷、筆畫點重建、頁面／筆記本／資料夾的資料結構、封面與顏色
//   Store.swift           Store：所有檔案讀寫、路徑、資料位置、歷史版本、圖片檔
//   LibraryModel.swift    LibraryModel：首頁的資料（資料夾、筆記本、排序、搜尋、移動、最近刪除、隨手記）
//   LibraryViews.swift    首頁的畫面：LibraryView、命名／資料夾／新建筆記本的視窗、設定、資料位置、最近刪除、首頁的格子
//   NotebookEditor.swift  筆記本畫面的 SwiftUI 外框：NotebookModel、NotebookEditorView、「⋯」選單、新增頁面選單、面板（縮略圖／書籤／大綱／旁頁）、分享
//   NotebookSheets.swift  筆記本裡的視窗：歷史版本、變更範本、移出頁面、概覽（九宮格）
//   NotebookView.swift    NotebookView：筆記本的 UIKit 主體（捲動、縮放、手勢、復原、選取、文字、圖片、截圖、貼上）
//   PageViews.swift       頁面：PageRowView（一列）、NoteCanvas、NotePageView（一頁）、紙膠帶、紙張與封面的畫法、拉動新增的圓圈、PDF、匯出與縮圖
//   TextAndImage.swift    圖片選取框、文字方塊、數學式（KaTeX）、文字工具列
//   StrokeTools.swift     筆跡相關：停筆變形（ShapeSnapper）、虛線、筆跡點擊判斷、筆跡的選取框（SelectionEditorView）
//   PenBox.swift          筆盒：筆的資料、PenBoxModel、PenBoxView、筆／套索／橡皮擦的設定
//   InsertMenu.swift      （v12.3 新增）長按空白處的一圈按鈕、照片／相機／檔案的選取畫面
//   BoardMarks.swift      （v12.7 新增）白板的圖釘、區塊：資料、畫面上的樣子、右上角的清單
//   BoardEngineTest.swift   新白板引擎的測試版（v12.8.8，實驗用：PKCanvasView 自己縮放）
//   BoardSettings.swift     白板右上角的齒輪面板（v12.9.1：底色、格線圓圈＋一排一排的設定）
//   ActivityLog.swift       修改紀錄（v12.9.5：每天改了哪些頁，之後的行事曆／日誌用；畫面還沒做）
//   StorageCheck.swift      儲存空間檢查（v12.9.6：首頁設定裡，列出可用空間、App 佔的、暫存，可以清暫存）
//   BoardTiles.swift        白板筆跡的分區儲存：怎麼切格子（v12.10.1 準備、v12.11.0 接上）
//   BoardTileStore.swift    分區儲存接到存檔系統：只存有變的格子、安全地換檔、平行讀取、開關的轉換（v12.11.0）
//   BoardTileCheck.swift    分區儲存的自動測試（v12.11.0；平常不會執行）
//   SelfTest.swift          自動測試的場景（雲端模擬器截圖用；平常不會執行）
//   BoardCards.swift        白板上的筆記本（v12.12.0）：卡片（帶連結的圖片）、浮動視窗、匯入現有筆記本的選單、首頁「白板裡的檔案」
//   TextLinks.swift         文字方塊的外框樣式（顏色、填滿／上面一條／外框、形狀、存成預設）、方塊之間的連線（v12.13.0）
// 每一版只要換有改到的檔案，再加上這個檔案（版本號在這裡）。

enum LibraryRoute: Hashable {
    case folder(NoteFolder)
    case notebook(NotebookMeta)
}

enum ItemRef: Hashable {
    case folder(UUID)
    case notebook(UUID)

    var id: UUID {
        switch self {
        case .folder(let id), .notebook(let id): return id
        }
    }
}

/// 側邊欄裡「所有文件」「最近刪除」用的編號
let allDocumentsID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
let trashID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

/// 側邊欄的資料夾樹
struct FolderNode: Identifiable, Hashable {
    let id: UUID
    let name: String
    let colorIndex: Int?
    var children: [FolderNode]?
}

struct ContentView: View {
    @StateObject private var library = LibraryModel()
    @State private var selection: UUID? = allDocumentsID
    @State private var sidebarHover: UUID?          // 拖到側邊欄的哪一列上（亮起來）
    @State private var editingSidebar = false        // 側邊欄「編輯資料夾順序」
    @State private var path: [LibraryRoute] = []
    @State private var columns: NavigationSplitViewVisibility = .automatic
    @State private var lowSpace: String?             // iPad 快沒空間了（v12.15.9）：打開 App、回到 App 時檢查
    @State private var logDrag: CGFloat = 0         // 日誌面板正被往右拉多少（v12.16.1）

    var body: some View {
        ZStack {
            // 日誌面板（v12.15.13，照 GUGA 的 My Logbook）：首頁右邊滑出來，首頁讓出那一塊
            // v12.16.1（使用者要求）：首頁從最右邊往內滑叫出來；面板往右滑收進去（跟著手指）
            HStack(spacing: 0) {
                splitView                              // 首頁不顯示分頁（v12.8.4，使用者：回首頁時分頁要收起來）
                    .overlay(alignment: .trailing) {
                        if !library.logbookOpen && library.openNotebook == nil {
                            Color.clear
                                .frame(width: 18)
                                .frame(maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 6, coordinateSpace: .global)
                                        .onChanged { v in
                                            if v.translation.width < -36 && !library.logbookOpen { openLogbook() }
                                        }
                                        .onEnded { v in
                                            if v.velocity.width < -300 && !library.logbookOpen { openLogbook() }
                                        }
                                )
                        }
                    }
                if library.logbookOpen {
                    LogbookPanel(close: closeLogbook)
                        .offset(x: logDrag)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 14, coordinateSpace: .global)
                                .onChanged { v in
                                    // 橫的才算（直的留給面板裡的捲動）
                                    guard logDrag > 0 || abs(v.translation.width) > abs(v.translation.height) * 1.3 else { return }
                                    logDrag = max(0, v.translation.width)
                                }
                                .onEnded { v in
                                    if logDrag > 90 || (logDrag > 10 && v.velocity.width > 500) {
                                        closeLogbook()
                                    } else if logDrag > 0 {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { logDrag = 0 }
                                    }
                                }
                        )
                        .transition(.move(edge: .trailing))
                }
            }
            // 筆記本：整個蓋在首頁（含側邊欄）上面，打開筆記本時完全看不到資料夾側邊欄
            if let meta = library.openNotebook {
                notebookCover(meta)
                    .transition(library.zoomTransition
                                ? AnyTransition.scale(scale: 0.88).combined(with: .opacity)
                                : AnyTransition.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .environmentObject(library)
        .onAppear {
            SelfTest.run(library)                      // 自動測試的場景（v12.9.9）；平常不會做任何事
            checkSpace()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            checkSpace()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            SessionRestore.touch()                     // v12.16.0：記下離開的時間（6 小時內重進回到這裡）
        }
        .alert("iPad 的空間快滿了", isPresented: Binding(get: { lowSpace != nil }, set: { if !$0 { lowSpace = nil } })) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text(lowSpace ?? "")
        }
    }

    private func openLogbook() {
        logDrag = 0
        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { library.logbookOpen = true }
    }

    private func closeLogbook() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.92)) {
            library.logbookOpen = false
            logDrag = 0
        }
    }

    /// 真的能寫的空間太少就提醒（v12.15.9）。使用者的 iPad 設定裡寫還有 16 GB，其實已經寫不進去：
    /// 筆跡存不了、截圖也存不了。用系統說「重要資料還能用多少」來判斷，比設定裡的數字準
    private func checkSpace() {
        guard let free = Store.freeSpace() else { return }
        let gb = Double(free) / 1_000_000_000
        guard gb < 3 else { return }
        lowSpace = String(format: "現在大約只剩 %.1f GB 能用。", gb)
            + "空間用完時筆跡會存不進去（重新打開就不見）。請到「設定 → 一般 → iPad 儲存空間」清一些照片、影片或用不到的 App，清完重新開機一次。"
    }

    private func notebookCover(_ meta: NotebookMeta) -> some View {
        NavigationStack {
            NotebookEditorView(meta: meta, onClose: {
                library.goHome()
            })
        }
        .id(meta.id)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            NavigationStack(path: $path) {
                rootLibrary
                    .navigationDestination(for: LibraryRoute.self) { route in
                        destination(route)
                    }
            }
        }
        .onChange(of: selection) { _, _ in
            path = []                                  // 換資料夾：回到那個資料夾的最上層
        }
        .onChange(of: library.springRequest) { _, request in
            guard let request = request else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                if let id = request.openFolder {
                    if let f = library.folder(id) { path.append(LibraryRoute.folder(f)) }   // 拖曳中停在資料夾上：打開
                } else if !path.isEmpty {
                    path.removeLast()                                                    // 回到上一層
                } else if let sel = selection, sel != allDocumentsID, sel != trashID, let f = library.folder(sel) {
                    selection = f.parentID ?? allDocumentsID
                }
            }
        }
        .onChange(of: library.openRequest) { _, meta in
            guard let meta = meta else { return }
            library.openRequest = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)    // 等新建視窗收起來
                withAnimation(.easeInOut(duration: 0.25)) { library.openNotebook = meta }
            }
        }
        .onChange(of: path) { _, newPath in
            // 打開筆記本時收起側邊欄；回到首頁再打開
            if case .notebook? = newPath.last {
                columns = .detailOnly
            } else if columns == .detailOnly {
                columns = .automatic
            }
        }
    }

    /// 左邊的側邊欄：所有文件 + 資料夾（可以展開、收合）
    @ViewBuilder
    private var sidebar: some View {
        if editingSidebar {
            SidebarReorderList {
                editingSidebar = false
            }
        } else {
            sidebarList
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                editingSidebar = true
                            } label: {
                                Label("編輯排列順序", systemImage: "arrow.up.arrow.down")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
        }
    }

    private var sidebarList: some View {
        let tree: [FolderNode] = library.folderTree(parent: nil)
        return List(selection: $selection) {
            Label("所有文件", systemImage: "tray.full")
                .tag(allDocumentsID)
                .listRowBackground(sidebarHighlight(allDocumentsID))
                .onDrop(of: [UTType.text], isTargeted: hoverBinding(allDocumentsID)) { _ in
                    sidebarDrop(to: nil, trash: false)
                }
            let pins = library.pinnedItems
            if !pins.isEmpty {
                // 釘選的資料夾、筆記本（v12.15.11）：從哪裡都一點就到
                Section("釘選") {
                    ForEach(pins, id: \.self) { (ref: ItemRef) in
                        pinnedRow(ref)
                    }
                }
            }
            if !tree.isEmpty {
                Section("資料夾") {
                    OutlineGroup(tree, children: \.children) { (node: FolderNode) in
                        FolderRow(node: node)
                            .tag(node.id)
                            .listRowBackground(sidebarHighlight(node.id))
                            .onDrop(of: [UTType.text], isTargeted: hoverBinding(node.id)) { _ in
                                sidebarDrop(to: node.id, trash: false)
                            }
                    }
                }
            }
            Section {
                Label("最近刪除", systemImage: "trash")
                    .tag(trashID)
                    .listRowBackground(sidebarHighlight(trashID))
                    .onDrop(of: [UTType.text], isTargeted: hoverBinding(trashID)) { _ in
                        sidebarDrop(to: nil, trash: true)
                    }
            }
        }
        .navigationTitle("筆記")
    }

    @ViewBuilder
    private func pinnedRow(_ ref: ItemRef) -> some View {
        switch ref {
        case .folder(let id):
            if let folder = library.folder(id) {
                Button {
                    selection = id
                } label: {
                    Label {
                        Text(folder.name).foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: "folder.fill").foregroundStyle(folderColor(folder.colorIndex))
                    }
                }
                .contextMenu {
                    Button { library.togglePin(ref) } label: { Label("取消釘選", systemImage: "pin.slash") }
                }
            }
        case .notebook(let id):
            if let meta = library.notebook(id) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { library.openNotebook = meta }
                } label: {
                    Label {
                        Text(meta.title).foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: meta.isBoard == true ? "rectangle.dashed" : "book.closed")
                    }
                }
                .contextMenu {
                    Button { library.togglePin(ref) } label: { Label("取消釘選", systemImage: "pin.slash") }
                }
            }
        }
    }

    // MARK: 側邊欄：把首頁的項目拖進來

    private func hoverBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { sidebarHover == id },
                set: { on in
                    if on { sidebarHover = id } else if sidebarHover == id { sidebarHover = nil }
                })
    }

    @ViewBuilder
    private func sidebarHighlight(_ id: UUID) -> some View {
        if sidebarHover == id {
            RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.25))
        }
    }

    /// 放到資料夾：搬進去；放到「所有文件」：搬到最外層；放到「最近刪除」：刪除
    private func sidebarDrop(to folder: UUID?, trash: Bool) -> Bool {
        sidebarHover = nil
        guard let id = library.draggingID, let ref = library.ref(for: id) else { return false }
        library.clearDrag()
        if trash {
            library.moveToTrash(ref)
            return true
        }
        if let f = folder, !library.canDrop(id, into: f) { return false }
        withAnimation(.easeInOut(duration: 0.2)) {
            library.moveItems([ref], to: folder)
        }
        return true
    }

    @ViewBuilder
    private var rootLibrary: some View {
        if selection == trashID {
            TrashView()
        } else if let id = selection, id != allDocumentsID, let folder = library.folder(id), folder.deletedAt == nil {
            LibraryView(folderID: id, title: folder.name)
                .id(id)
        } else {
            LibraryView(folderID: nil, title: "文件")
                .id(allDocumentsID)
        }
    }

    @ViewBuilder
    private func destination(_ route: LibraryRoute) -> some View {
        switch route {
        case .folder(let folder):
            LibraryView(folderID: folder.id, title: folder.name)
        case .notebook(let meta):
            NotebookEditorView(meta: meta, onClose: { if !path.isEmpty { path.removeLast() } })
                .toolbar(removing: .sidebarToggle)     // 筆記本裡不要側邊欄按鈕
        }
    }
}

/// 側邊欄裡的一個資料夾
struct FolderRow: View {
    let node: FolderNode

    var body: some View {
        let color: Color = folderColor(node.colorIndex)
        return Label {
            Text(node.name)
        } icon: {
            Image(systemName: "folder.fill")
                .foregroundStyle(color)
        }
    }
}

/// 側邊欄「編輯資料夾順序」：每一層分開列，拖右邊的把手換順序（同一層才能換）
struct FolderLevel: Identifiable {
    let id: String
    let parent: UUID?
    let title: String
    let items: [ItemRef]            // 這一層的資料夾和筆記本（照首頁的順序）
}

struct SidebarReorderList: View {
    @EnvironmentObject private var library: LibraryModel
    let onDone: () -> Void

    private var levels: [FolderLevel] {
        var result: [FolderLevel] = []
        func walk(_ parent: UUID?, path: String) {
            let items: [ItemRef] = library.items(in: parent)
            guard !items.isEmpty else { return }
            let title = parent == nil ? "最外層" : path + " 裡面"
            result.append(FolderLevel(id: parent?.uuidString ?? "root", parent: parent, title: title, items: items))
            for ref in items {
                guard case .folder(let id) = ref, let f = library.folder(id) else { continue }
                walk(f.id, path: path.isEmpty ? f.name : path + " / " + f.name)
            }
        }
        walk(nil, path: "")
        return result
    }

    @ViewBuilder
    private func itemRow(_ ref: ItemRef) -> some View {
        switch ref {
        case .folder(let id):
            let f = library.folder(id)
            Label {
                Text(f?.name ?? "資料夾")
            } icon: {
                Image(systemName: "folder.fill")
                    .foregroundStyle(folderColor(f?.colorIndex))
            }
        case .notebook(let id):
            Label {
                Text(library.notebook(id)?.title ?? "筆記本")
            } icon: {
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        List {
            if levels.isEmpty {
                Text("還沒有資料夾或筆記本")
                    .foregroundStyle(.secondary)
            }
            ForEach(levels) { (level: FolderLevel) in
                Section(level.title) {
                    ForEach(level.items, id: \.id) { (ref: ItemRef) in
                        itemRow(ref)
                    }
                    .onMove { source, destination in
                        library.reorderItems(in: level.parent, from: source, to: destination)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("排列順序")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { onDone() }
                    .fontWeight(.semibold)
            }
        }
    }
}


/// 最上面一排分頁（v12.8.2，照 GoodNotes）：最左邊的房子回首頁；後面是打開過、還沒關的筆記本和白板。
/// 點分頁換過去；正在看的那一個才有 ×，它右邊有 ＋（回首頁選一本，開在它右邊）；按住一下再左右拖可以換位置；最右邊 ︿ 收起這一排。
/// 顏色（v12.8.7）：深灰底，跟下面黑色的工具那一排分開
struct NotebookTabBar: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var draggingID: UUID?
    @State private var dragX: CGFloat = 0          // 手指移動的距離
    @State private var consumed: CGFloat = 0       // 已經換過位置的距離（每換一格扣掉一個分頁的寬）
    @AppStorage("tabsCollapsed") private var collapsed = false

    private static let tabWidth: CGFloat = 210
    private static let tabStep: CGFloat = 214      // 分頁寬＋間距
    static let barColor = Color(white: 0.17)

    var body: some View {
        HStack(spacing: 0) {
            Button {
                library.goHome()
            } label: {
                Image(systemName: "house")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 54, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(white: 0.75))
            Rectangle()
                .fill(Color(white: 0.4))
                .frame(width: 1, height: 22)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(library.tabMetas, id: \.id) { (meta: NotebookMeta) in
                            tab(meta)
                                .id(meta.id)
                        }
                        plusButton                                 // v12.9.3：＋ 放在最後一個分頁後面（像 Chrome）
                    }
                    .padding(.horizontal, 6)
                    .animation(.easeOut(duration: 0.15), value: library.openTabs)
                }
                .scrollDisabled(draggingID != nil)                 // 拖分頁換位置時，這一排不要跟著捲
                .onChange(of: library.openNotebook?.id) { _, id in
                    if let id = id {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                    }
                }
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { collapsed = true }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 44, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(white: 0.75))
            .padding(.trailing, 6)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Self.barColor.ignoresSafeArea(edges: .top))
        .environment(\.colorScheme, .dark)
    }

    /// ＋：在最後一個分頁後面（v12.9.3）；按了回首頁選要開哪一本，開的放在最後面
    private var plusButton: some View {
        Button {
            library.goHomeToOpenTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(white: 0.75))
    }

    private func tab(_ meta: NotebookMeta) -> some View {
        let current = library.openNotebook?.id == meta.id
        let dragging = draggingID == meta.id
        return tabLabel(meta, current: current)
            .frame(width: Self.tabWidth, height: 34)
            .foregroundStyle(current ? Color.white : Color(white: 0.62))
            .background(RoundedRectangle(cornerRadius: 9).fill(current || dragging ? Color(white: 0.3) : Color.clear))
            .contentShape(Rectangle())
            .offset(x: dragging ? dragX - consumed : 0)
            .zIndex(dragging ? 1 : 0)
            .scaleEffect(dragging ? 1.04 : 1)
            .shadow(color: Color.black.opacity(dragging ? 0.4 : 0), radius: 6)
            .transaction { t in
                if dragging { t.animation = nil }              // 拖著的那一個跟著手指，不要動畫（以前會跳）
            }
            .onTapGesture {
                library.switchTab(meta.id)
            }
            // v12.15.1（使用者：分頁多的時候滑不動，最右邊的按不到）：以前用 .gesture，iPadOS 會讓它擋住整排的捲動。
            // 改成跟捲動同時判斷；按住 0.25 秒開始拖分頁以後，這一排才停止捲動（scrollDisabled）
            .simultaneousGesture(reorderGesture(meta.id))
    }

    private func tabLabel(_ meta: NotebookMeta, current: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: (meta.isBoard ?? false) ? "rectangle.dashed" : "book.closed")
                .font(.system(size: 13, weight: .semibold))
            Text(meta.title)
                .font(.system(size: 15, weight: current ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            if current {
                // × 只有正在看的分頁才有；按的範圍就是這個小圓
                Button {
                    library.closeTab(meta.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(white: 0.8))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }

    /// 按住 0.25 秒再左右拖：拖過半個分頁就跟旁邊那個交換位置
    private func reorderGesture(_ id: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if draggingID != id {
                    draggingID = id
                    dragX = 0
                    consumed = 0
                }
                dragX = drag?.translation.width ?? 0
                let shown = dragX - consumed
                if shown > Self.tabStep / 2, library.moveTab(id, by: 1) {
                    consumed += Self.tabStep
                } else if shown < -Self.tabStep / 2, library.moveTab(id, by: -1) {
                    consumed -= Self.tabStep
                }
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    draggingID = nil
                    dragX = 0
                    consumed = 0
                }
            }
    }
}
