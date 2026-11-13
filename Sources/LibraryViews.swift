import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// LibraryViews.swift：首頁的畫面：LibraryView、命名／資料夾／新建筆記本的視窗、設定、資料位置、最近刪除、首頁的格子
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryModel
    let folderID: UUID?
    let title: String

    @State private var renameRef: ItemRef?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var deleteRef: ItemRef?
    @State private var showDelete = false
    @State private var showImporter = false
    @State private var importFailed = false
    @State private var folderEdit: FolderEdit?        // 新資料夾／編輯資料夾的視窗
    @State private var showNewNotebook = false
    @State private var showSettings = false
    @State private var dragging: UUID?                // 長按拖曳中的項目
    @State private var endZoneTargeted = false        // 拖到「放到最後」上
    @State private var upTargeted = false             // 拖到「回到上一層」上
    @State private var cellSize = CGSize(width: 180, height: 230)   // 一格的大小（判斷資料夾中間）

    /// 正在拖的項目（從別的資料夾彈開進來時，自己的 dragging 是空的，用共用的）
    private var activeDrag: UUID? { dragging ?? library.draggingID }
    @State private var selecting = false              // 選取模式
    @State private var selected = Set<UUID>()
    @State private var showDeleteSelected = false
    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 28)]

    var body: some View {
        mainContent
            .navigationTitle(title)
            .searchable(text: $searchText, prompt: "搜尋筆記本、資料夾")
            .toolbar { toolbarItems }
            .background(sheetsA)
            .background(sheetsB)
    }

    // MARK: 畫面

    private var mainContent: some View {
        let searching: Bool = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let items: [ItemRef] = searching ? library.search(searchText) : library.items(in: folderID)
        return ScrollView {
            VStack {
                if items.isEmpty {
                    Text(searching ? "找不到符合的筆記本或資料夾" : "按右上角「＋ 新」建立筆記本或資料夾")
                        .foregroundStyle(.secondary)
                        .padding(.top, 120)
                }
                LazyVGrid(columns: columns, spacing: 36) {
                    ForEach(items, id: \.id) { (ref: ItemRef) in
                        cell(ref, searching: searching)
                    }
                }
                .padding(32)
                .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                    // 放在空白處：結束拖曳（從別層彈開進來的，放進這一層）
                    if let id = activeDrag { library.bringHere(id, folder: folderID) }
                    dragging = nil
                    library.clearDrag()
                    return true
                }

                // 拖曳中：最後面多一塊「放到最後」，最後一個是資料夾時也放得到最後
                if activeDrag != nil && !searching {
                    endDropZone
                }

                Text("App 版本 \(appVersion)　筆畫重建：\(pointRebuildLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .bottom) { copiedBanner }
        .safeAreaInset(edge: .top) {
            if activeDrag != nil && folderID != nil && !searching { upDropBar }
        }
    }

    /// 拖曳中、在資料夾裡面時，上方出現「回到上一層」：停 1 秒回到上一層（像 Finder 拖到返回鈕），
    /// 直接放開＝搬到上一層
    private var upDropBar: some View {
        let parent = folderID.flatMap { library.folder($0)?.parentID }
        let parentName = parent.flatMap { library.folder($0)?.name } ?? "文件"
        return HStack(spacing: 8) {
            Image(systemName: "arrow.up.backward.circle.fill")
            Text("回到上一層「\(parentName)」：停 1 秒打開，放開＝搬過去")
                .font(.callout)
        }
        .foregroundStyle(upTargeted ? Color.white : Color.accentColor)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 12).fill(upTargeted ? Color.accentColor : Color.accentColor.opacity(0.12)))
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .onDrop(of: [UTType.text], isTargeted: $upTargeted) { _ in
            if let id = activeDrag, let ref = library.ref(for: id) {
                let ok: Bool
                if let p = parent { ok = library.canDrop(id, into: p) } else { ok = true }
                if ok { withAnimation(.easeInOut(duration: 0.2)) { library.moveItems([ref], to: parent) } }
            }
            dragging = nil
            library.clearDrag()
            return true
        }
        .onChange(of: upTargeted) { _, on in
            guard on else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if upTargeted { library.springRequest = LibraryModel.SpringRequest(openFolder: nil) }
            }
        }
    }

    private var endDropZone: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(endZoneTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            .background(RoundedRectangle(cornerRadius: 14).fill(endZoneTargeted ? Color.accentColor.opacity(0.1) : Color.clear))
            .frame(height: 90)
            .overlay(
                Label("放到最後", systemImage: "arrow.down.to.line")
                    .foregroundStyle(endZoneTargeted ? Color.accentColor : Color.secondary)
            )
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
            .onDrop(of: [UTType.text], isTargeted: $endZoneTargeted) { _ in
                if let id = activeDrag {
                    library.bringHere(id, folder: folderID)
                    withAnimation(.easeInOut(duration: 0.2)) { library.moveToEnd(id, in: folderID) }
                }
                dragging = nil
                library.clearDrag()
                return true
            }
    }

    @ViewBuilder
    private func cell(_ ref: ItemRef, searching: Bool) -> some View {
        if selecting {
            selectableCell(ref)
        } else if searching {
            itemCell(ref)                              // 搜尋結果不能拖曳排序
        } else {
            draggableCell(ref)
        }
    }

    /// 選取模式：點一下打勾
    private func selectableCell(_ ref: ItemRef) -> some View {
        let chosen: Bool = selected.contains(ref.id)
        let mark: String = chosen ? "checkmark.circle.fill" : "circle"
        let markColor: Color = chosen ? Color.accentColor : Color.secondary
        return itemVisual(ref)
            .overlay(alignment: .topTrailing) {
                Image(systemName: mark)
                    .font(.title2)
                    .foregroundStyle(markColor)
                    .background(Circle().fill(Color.white))
                    .padding(6)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(ref.id) }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// 只有外觀（不能點進去）
    @ViewBuilder
    private func itemVisual(_ ref: ItemRef) -> some View {
        switch ref {
        case .folder(let id):
            if let folder = library.folder(id) {
                FolderItemView(name: folder.name, color: folderColor(folder.colorIndex))
            }
        case .notebook(let id):
            if let meta = library.notebook(id) {
                NotebookItemView(meta: meta)
            }
        }
    }

    private var selectedRefs: [ItemRef] {
        library.items(in: folderID).filter { selected.contains($0.id) }
    }

    // MARK: 右上角

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if selecting {
            ToolbarItemGroup(placement: .topBarTrailing) {
                selectionButtons
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                normalButtons
            }
        }
    }

    @ViewBuilder
    private var normalButtons: some View {
        Button {
            library.openQuickNotes()
        } label: {
            Label("隨手記", systemImage: "square.and.pencil")
                .labelStyle(.titleAndIcon)
        }
        Button("選取") {
            selected = []
            selecting = true
        }
        newMenu
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
    }

    /// 新白板：寬 columns 張 A4、高 rows 張 A4，建立後直接打開
    /// 新白板：固定橫式（v12.8；寬用 A4 的長邊、高用 A4 的短邊）
    private func newBoard(columns: Int, rows: Int) {
        let meta = library.addBoard(in: folderID, title: "未命名白板",
                                    width: CGFloat(columns) * 842, height: CGFloat(rows) * 595)
        library.openRequest = meta
    }

    private var newMenu: some View {
        Menu {
            Button {
                showNewNotebook = true
            } label: {
                Label("新筆記本", systemImage: "book.closed")
            }
            // Markdown 筆記本（v12.9.2）：每一頁都是整頁的 Markdown，像一般的 Markdown 文件
            Button {
                library.openRequest = library.addMarkdownNotebook(in: folderID)
            } label: {
                Label("新 Markdown 筆記本", systemImage: "doc.plaintext")
            }
            // 新白板（v12.5）：寬、高各 100 張 A4（v12.8 起橫式），縮到 5% 也看不到邊；不夠的話在白板裡「⋯ → 加大白板」
            Button {
                newBoard(columns: 100, rows: 100)
            } label: {
                Label("新白板", systemImage: "rectangle.dashed")
            }
            Button {
                folderEdit = FolderEdit(folderID: nil, name: "", colorIndex: defaultFolderColor)
            } label: {
                Label("新資料夾", systemImage: "folder.badge.plus")
            }
            Button {
                showImporter = true
            } label: {
                Label("匯入 PDF", systemImage: "doc.richtext")
            }
            if !library.copiedAlive.isEmpty {
                Button {
                    library.paste(into: folderID)
                } label: {
                    Label("貼上 \(library.copiedLabel)", systemImage: "doc.on.clipboard")
                }
            }
        } label: {
            Label("新", systemImage: "plus")
                .labelStyle(.titleAndIcon)
        }
    }

    @ViewBuilder
    private var selectionButtons: some View {
        let all: [ItemRef] = library.items(in: folderID)
        let allChosen: Bool = !all.isEmpty && selected.count == all.count
        Button(allChosen ? "取消全選" : "全選") {
            selected = allChosen ? [] : Set(all.map { $0.id })
        }
        Button {
            library.copied = selectedRefs
            selecting = false
            selected = []
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .disabled(selected.isEmpty)
        moveMenu
        Button(role: .destructive) {
            showDeleteSelected = true
        } label: {
            Image(systemName: "trash")
        }
        .disabled(selected.isEmpty)
        Button("完成") {
            selecting = false
            selected = []
        }
        .fontWeight(.semibold)
    }

    /// 移動到…：列出所有資料夾
    private var moveMenu: some View {
        let refs: [ItemRef] = selectedRefs
        let targets: [(id: UUID, name: String)] = library.moveTargets(excluding: refs)
        return Menu {
            Button {
                library.moveItems(refs, to: nil)
                selected = []
            } label: {
                Label("最外層（所有文件）", systemImage: "tray.full")
            }
            ForEach(targets, id: \.id) { (target: (id: UUID, name: String)) in
                Button {
                    library.moveItems(refs, to: target.id)
                    selected = []
                } label: {
                    Label(target.name, systemImage: "folder")
                }
            }
        } label: {
            Image(systemName: "folder")
        }
        .disabled(selected.isEmpty)
    }

    // MARK: 各種視窗

    private var sheetsA: some View {
        Color.clear
            .sheet(isPresented: $showRename) {
                NameSheet(text: $renameText) { applyRename() }
            }
            .sheet(isPresented: $showNewNotebook) {
                NewNotebookSheet { name, data, openNow in
                    let title = name.isEmpty ? "未命名筆記本" : name
                    let meta = library.addNotebook(in: folderID, title: title, data: data)
                    if openNow { library.openRequest = meta }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet()
                    .environmentObject(library)
            }
            .sheet(item: $folderEdit) { edit in
                FolderSheet(edit: edit) { name, color in
                    saveFolder(edit, name: name, color: color)
                }
            }
    }

    private var sheetsB: some View {
        Color.clear
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result {
                    importFailed = !library.importPDF(from: url, into: folderID)
                }
            }
            .alert("PDF 匯入失敗", isPresented: $importFailed) {
                Button("好", role: .cancel) { }
            }
            .confirmationDialog("把選取的 \(selected.count) 個項目移到最近刪除？", isPresented: $showDeleteSelected,
                                titleVisibility: .visible) {
                Button("刪除", role: .destructive) { deleteSelected() }
            }
    }

    private func saveFolder(_ edit: FolderEdit, name: String, color: Int) {
        let finalName = name.isEmpty ? "未命名資料夾" : name
        if let id = edit.folderID {
            library.updateFolder(id, name: finalName, colorIndex: color)
        } else {
            _ = library.addFolder(in: folderID, name: finalName, colorIndex: color)
        }
    }

    private func deleteSelected() {
        for ref in selectedRefs { library.moveToTrash(ref) }
        selected = []
        selecting = false
    }

    /// 可以長按拖曳排列順序的項目（規則見 ReorderDropDelegate）
    private func draggableCell(_ ref: ItemRef) -> some View {
        var isFolder = false
        if case .folder = ref { isFolder = true }
        let delegate = ReorderDropDelegate(target: ref.id, folderID: folderID, library: library,
                                           isFolder: isFolder, size: cellSize, dragging: $dragging)
        let lit: Bool = library.dropHover == ref.id
        return itemCell(ref)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accentColor, lineWidth: 4)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.12)))
                    .padding(-8)
                    .opacity(lit ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .scaleEffect(lit ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: lit)
            .background(GeometryReader { g in
                Color.clear.onAppear { if g.size.width > 10 { cellSize = g.size } }
            })
            .onDrag { dragProvider(ref.id) }
            .onDrop(of: [UTType.text], delegate: delegate)
            // 刪除的確認跳在要刪的那一格旁邊（v12.6；以前跳在畫面上方）
            .confirmationDialog("移到最近刪除？", isPresented: deleteShown(ref), titleVisibility: .visible) {
                Button("刪除", role: .destructive) { applyDelete() }
            } message: {
                Text("會放在側邊欄的「最近刪除」，30 天內可以復原，之後自動永久刪除；資料夾裡的內容會跟著移過去。")
            }
    }

    private func deleteShown(_ ref: ItemRef) -> Binding<Bool> {
        Binding(get: { showDelete && deleteRef?.id == ref.id },
                set: { on in
                    if !on { showDelete = false }
                })
    }

    private func dragProvider(_ id: UUID) -> NSItemProvider {
        dragging = id
        library.draggingID = id
        return NSItemProvider(object: id.uuidString as NSString)
    }

    /// 一個項目：資料夾或筆記本
    @ViewBuilder
    private func itemCell(_ ref: ItemRef) -> some View {
        switch ref {
        case .folder(let id):
            if let folder = library.folder(id) {
                NavigationLink(value: LibraryRoute.folder(folder)) {
                    FolderItemView(name: folder.name, color: folderColor(folder.colorIndex))
                }
                .buttonStyle(.plain)
                .contextMenu { itemMenu(ref, name: folder.name) }
            }
        case .notebook(let id):
            if let meta = library.notebook(id) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { library.openNotebook = meta }
                } label: {
                    NotebookItemView(meta: meta)
                }
                .buttonStyle(.plain)
                .contextMenu { itemMenu(ref, name: meta.title) }
            }
        }
    }

    @ViewBuilder
    private func itemMenu(_ ref: ItemRef, name: String) -> some View {
        if case .folder(let id) = ref, let folder = library.folder(id) {
            Button {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)     // 等選單收起來
                    folderEdit = FolderEdit(folderID: id, name: folder.name,
                                            colorIndex: folder.colorIndex ?? defaultFolderColor)
                }
            } label: {
                Label("名稱與顏色", systemImage: "paintpalette")
            }
        }
        Button {
            startRename(ref, name: name)
        } label: {
            Label("重新命名", systemImage: "pencil")
        }
        Button {
            library.duplicateNextTo(ref)
        } label: {
            Label("複製一份", systemImage: "plus.square.on.square")
        }
        Button {
            library.copied = [ref]
        } label: {
            Label("拷貝", systemImage: "doc.on.doc")
        }
        Menu {
            moveDestinations([ref])
        } label: {
            Label("移動到…", systemImage: "folder")
        }
        Button(role: .destructive) {
            deleteRef = ref
            showDelete = true
        } label: {
            Label("刪除", systemImage: "trash")
        }
    }

    /// 「移動到…」的選項：最外層＋所有資料夾（不能搬進自己裡面；已經在那裡的不列）
    @ViewBuilder
    private func moveDestinations(_ refs: [ItemRef]) -> some View {
        let targets: [(id: UUID, name: String)] = library.moveTargets(excluding: refs)
        let here: UUID? = refs.count == 1 ? library.parent(of: refs[0]) : nil
        if refs.count != 1 || here != nil {
            Button {
                library.moveItems(refs, to: nil)
            } label: {
                Label("最外層（所有文件）", systemImage: "tray.full")
            }
        }
        ForEach(targets.filter { refs.count != 1 || $0.id != here }, id: \.id) { (target: (id: UUID, name: String)) in
            Button {
                library.moveItems(refs, to: target.id)
            } label: {
                Label(target.name, systemImage: "folder")
            }
        }
    }

    /// 拷貝之後下方的提示：在這裡貼上
    @ViewBuilder
    private var copiedBanner: some View {
        if !library.copiedAlive.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc")
                Text("已拷貝 \(library.copiedLabel)")
                    .lineLimit(1)
                Spacer()
                Button("在這裡貼上") {
                    library.paste(into: folderID)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    library.copied = []
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    /// 等選單完全收起再跳出命名視窗，輸入框才能正常叫出鍵盤
    private func startRename(_ ref: ItemRef, name: String) {
        renameRef = ref
        renameText = name
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            showRename = true
        }
    }

    private func applyRename() {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let ref = renameRef else { return }
        switch ref {
        case .folder(let id): library.renameFolder(id, to: name)
        case .notebook(let id): library.renameNotebook(id, to: name)
        }
    }

    private func applyDelete() {
        guard let ref = deleteRef else { return }
        library.moveToTrash(ref)
    }
}

/// 命名視窗：輸入框不會自動取得焦點，用手指點它才叫出鍵盤
/// （iPadOS 在用過 Apple Pencil 後，自動取得焦點的輸入框常會變成隨手寫）
struct NameSheet: View {
    @Binding var text: String
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名稱", text: $text)
                        .font(.title3)
                        .submitLabel(.done)
                        .onSubmit {
                            onDone()
                            dismiss()
                        }
                }
            }
            .navigationTitle("命名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onDone()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 長按拖曳（v11.27，參考 Finder 和 iPad 主畫面）：
/// 拖到筆記本上、或資料夾的邊緣 → 換到那個位置，其他項目自己讓開；
/// 停在資料夾圖示的中間 → 0.8 秒後亮起來（放開＝放進去），再停 1.2 秒資料夾自己打開
struct ReorderDropDelegate: DropDelegate {
    let target: UUID
    let folderID: UUID?
    let library: LibraryModel
    let isFolder: Bool
    let size: CGSize                      // 這一格的大小（判斷手指在資料夾中間還是邊緣）
    @Binding var dragging: UUID?

    private var dragged: UUID? { dragging ?? library.draggingID }

    /// 資料夾圖示的中間：左右各留 20%、下面的名稱不算
    private func inCenter(_ p: CGPoint) -> Bool {
        let w = max(size.width, 1)
        let h = max(size.height, 1)
        return p.x > w * 0.2 && p.x < w * 0.8 && p.y > h * 0.05 && p.y < h * 0.72
    }

    private func handle(_ p: CGPoint) {
        guard let d = dragged, d != target else { return }
        library.bringHere(d, folder: folderID)          // 從別層彈開進來的：先搬進這一層
        if isFolder, inCenter(p), library.canDrop(d, into: target) {
            library.beginHover(target)
        } else {
            library.endHover(target)
            library.reorder(d, to: target, in: folderID)
        }
    }

    func dropEntered(info: DropInfo) {
        handle(info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isFolder { handle(info.location) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let d = dragged
        defer {
            dragging = nil
            library.clearDrag()
        }
        guard isFolder, let id = d, id != target else { return true }
        if library.dropHover == target, library.canDrop(id, into: target), let ref = library.ref(for: id) {
            withAnimation(.easeInOut(duration: 0.2)) {
                library.moveItems([ref], to: target)          // 亮起來了：放進去
            }
        }
        return true
    }

    func dropExited(info: DropInfo) {
        library.endHover(target)
    }
}

/// 新資料夾／編輯資料夾視窗要用的資料
struct FolderEdit: Identifiable {
    let id = UUID()
    let folderID: UUID?           // nil：新資料夾
    var name: String
    var colorIndex: Int
}

/// 顏色表裡的一個圓點（拆成獨立元件，編譯器比較好推算）
struct ColorSwatch: View {
    let color: Color
    let selected: Bool
    let lightColor: Bool          // 淺色的圓點，勾勾用深色

    var body: some View {
        let ring: Color = selected ? Color.gray.opacity(0.2) : Color.clear
        let checkColor: Color = lightColor ? Color.black.opacity(0.7) : Color.white
        return ZStack {
            Circle().fill(ring).frame(width: 44, height: 44)
            Circle().fill(color).frame(width: 36, height: 36)
            Circle().stroke(Color.gray.opacity(0.35), lineWidth: 1).frame(width: 36, height: 36)
            if selected {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(checkColor)
            }
        }
    }
}

/// 新資料夾：名稱 + 顏色（像 GoodNotes）
struct FolderSheet: View {
    let edit: FolderEdit
    let onDone: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorIndex = defaultFolderColor

    private let columns: [GridItem] = Array(repeating: GridItem(.fixed(44), spacing: 14), count: 9)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    preview
                    nameField
                    palette
                }
                .padding(24)
            }
            .navigationTitle(edit.folderID == nil ? "新資料夾" : "資料夾")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { finish() }
                }
            }
        }
        .onAppear {
            name = edit.name
            colorIndex = edit.colorIndex
        }
    }

    private func finish() {
        onDone(name.trimmingCharacters(in: .whitespacesAndNewlines), colorIndex)
        dismiss()
    }

    private var preview: some View {
        let color: Color = folderColor(colorIndex)
        return Image(systemName: "folder.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 150, height: 120)
            .foregroundStyle(color)
            .padding(.top, 20)
    }

    private var nameField: some View {
        VStack(spacing: 8) {
            TextField("未命名", text: $name)
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.vertical, 10)
                .background(Capsule().stroke(Color.gray.opacity(0.4)))
        }
        .frame(maxWidth: 460)
    }

    private func pasteName() {
        if let pasted = UIPasteboard.general.string, !pasted.isEmpty { name = pasted }
    }

    private var palette: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(0..<folderPalette.count, id: \.self) { (i: Int) in
                ColorSwatch(color: folderColor(i), selected: i == colorIndex, lightColor: i >= 9)
                    .onTapGesture { colorIndex = i }
            }
        }
    }
}

// MARK: - 新建筆記本（仿 GUGA：封面、紙張、名稱、顏色、版式、尺寸）

/// 新建畫面左邊的一張預覽（封面或紙張）
struct PagePreviewCard: View {
    let title: String
    let caption: String
    let image: UIImage
    let highlighted: Bool

    var body: some View {
        let bg: Color = highlighted ? Color.white : Color.clear
        return VStack(spacing: 10) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
            Text(caption)
                .font(.subheadline)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(bg))
    }
}

/// 紙張模板的一格
struct TemplateCard: View {
    let name: String
    let image: UIImage
    let selected: Bool

    var body: some View {
        let border: Color = selected ? Color.primary : Color.clear
        return VStack(spacing: 8) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(5)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 3))
                .overlay {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(Color.white, Color.black)
                    }
                }
            Text(name)
                .font(.subheadline)
        }
    }
}

/// 黑底白字的大按鈕
struct BlackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
        }
        .buttonStyle(.plain)
    }
}

struct NewNotebookSheet: View {
    let onCreate: (String, NotebookData, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hasCover = false
    @State private var coverColor = 8                   // 預設「基礎藍色」
    @State private var pattern = 2
    @State private var paperColor = 0
    @State private var landscape = false
    @State private var sizeIndex = 0
    @State private var showCovers = false               // 下方顯示封面模板（點左邊的封面卡片）

    private var style: PaperStyle { PaperStyle(pattern: pattern, color: paperColor) }

    /// 目前尺寸、方向的寬高
    private var pageSize: CGSize {
        let size = paperSizes[min(max(sizeIndex, 0), paperSizes.count - 1)]
        return landscape ? CGSize(width: size.h, height: size.w) : CGSize(width: size.w, height: size.h)
    }

    private func previewSize(height: CGFloat) -> CGSize {
        let ratio: CGFloat = pageSize.width / max(pageSize.height, 1)
        return CGSize(width: height * ratio, height: height)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    topSection
                    Divider()
                    bottomSection
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("新建筆記本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    // 上半部：預覽 + 設定 + 按鈕
    private var topSection: some View {
        HStack(alignment: .top, spacing: 20) {
            HStack(spacing: 8) {
                PagePreviewCard(title: "封面", caption: hasCover ? coverTemplate(coverColor).name : "無封面",
                                image: coverPreview(height: 200), highlighted: showCovers)
                    .onTapGesture { showCovers = true }
                PagePreviewCard(title: "紙張", caption: PaperStyle.patternNames[pattern],
                                image: PaperRenderer.preview(style, cover: nil, size: previewSize(height: 200),
                                                             pageWidth: pageSize.width),
                                highlighted: !showCovers)
                    .onTapGesture { showCovers = false }
            }
            VStack(spacing: 16) {
                settingsForm
                HStack(spacing: 16) {
                    BlackButton(title: "新建") { create(open: false) }
                    BlackButton(title: "新建並全屏打開") { create(open: true) }
                }
            }
            .frame(maxWidth: 460)
        }
    }

    private var settingsForm: some View {
        VStack(spacing: 0) {
            HStack {
                Text("名稱")
                TextField("無標題的筆記本", text: $name)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 12)
            Divider()
            Toggle("封面", isOn: $hasCover)
                .padding(.vertical, 8)
            Divider()
            menuRow(title: "紙張顏色", value: PaperStyle.colorNames[paperColor]) {
                ForEach(0..<PaperStyle.colorNames.count, id: \.self) { (i: Int) in
                    Button(PaperStyle.colorNames[i]) { paperColor = i }
                }
            }
            Divider()
            menuRow(title: "版式", value: landscape ? "橫向" : "縱向") {
                Button("縱向") { landscape = false }
                Button("橫向") { landscape = true }
            }
            Divider()
            menuRow(title: "尺寸", value: paperSizes[sizeIndex].name) {
                ForEach(0..<paperSizes.count, id: \.self) { (i: Int) in
                    Button(paperSizes[i].name) { sizeIndex = i }
                }
            }
        }
        .padding(.horizontal, 18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func menuRow<Content: View>(title: String, value: String,
                                        @ViewBuilder items: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            Menu {
                items()
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    private func coverPreview(height: CGFloat) -> UIImage {
        if hasCover {
            return PaperRenderer.preview(style, cover: coverColor, size: previewSize(height: height), pageWidth: pageSize.width)
        }
        return PaperRenderer.noCover(size: previewSize(height: height))
    }

    // 下半部：點封面卡片看封面模板，點紙張卡片看紙張模板
    @ViewBuilder
    private var bottomSection: some View {
        if showCovers {
            coverSection
        } else {
            templateSection
        }
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("封面模板")
                .font(.title2.weight(.bold))
            coverGroup(title: "基礎", group: 0, includeNone: true)
            Divider()
            coverGroup(title: "純色", group: 1, includeNone: false)
        }
    }

    private func coverGroup(title: String, group: Int, includeNone: Bool) -> some View {
        let indices: [Int] = coverTemplates.indices.filter { coverTemplates[$0].group == group }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    if includeNone {
                        TemplateCard(name: "無封面", image: PaperRenderer.noCover(size: previewSize(height: 150)),
                                     selected: !hasCover)
                            .onTapGesture { hasCover = false }
                    }
                    ForEach(indices, id: \.self) { (i: Int) in
                        TemplateCard(name: coverTemplates[i].name,
                                     image: PaperRenderer.preview(style, cover: i, size: previewSize(height: 150),
                                                                  pageWidth: pageSize.width),
                                     selected: hasCover && coverColor == i)
                            .onTapGesture {
                                hasCover = true
                                coverColor = i
                            }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // 紙張模板
    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("紙張模板")
                .font(.title2.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(0..<PaperStyle.patternNames.count, id: \.self) { (i: Int) in
                        TemplateCard(name: PaperStyle.patternNames[i],
                                     image: PaperRenderer.preview(PaperStyle(pattern: i, color: paperColor), cover: nil,
                                                                  size: previewSize(height: 150), pageWidth: pageSize.width),
                                     selected: i == pattern)
                            .onTapGesture { pattern = i }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func create(open: Bool) {
        let size = pageSize
        let spec = PageSpec(width: size.width, height: size.height)
        var rows: [PageRow] = []
        if hasCover {
            var coverRow = PageRow()
            coverRow.pages = [NotePage(spec: spec, paper: style, cover: coverColor)]
            rows.append(coverRow)
        }
        var firstRow = PageRow()
        firstRow.pages = [NotePage(spec: spec, paper: style)]
        rows.append(firstRow)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(trimmed, NotebookData(rows: rows), open)
        dismiss()
    }
}

// MARK: - 首頁的設定

struct SettingsSheet: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notebookBackdrop") private var backdrop = "dark"
    @State private var showDataLocation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("頁面後面的底色", selection: $backdrop) {
                        Text("深灰").tag("dark")
                        Text("淺灰").tag("light")
                    }
                } header: {
                    Text("筆記本畫面")
                } footer: {
                    Text("筆記本裡右上角「⋯ → 檢視」也可以切換。")
                }
                StorageCheckSection()                            // 儲存空間（檢查用，v12.9.6）
                Section {
                    NavigationLink {
                        Form {
                            SnapSettingsSections(notebookID: nil)
                            Section {
                                Text("這裡是預設：新的筆記本、還沒自己改過的筆記本都照這個。在某本筆記本裡用右上角「⋯ → 停筆設定」改的，只會記在那一本。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .navigationTitle("停筆的預設")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("停筆的預設", systemImage: "wand.and.stars")
                    }
                } header: {
                    Text("筆記本的習慣")
                }
                Section {
                    Button {
                        showDataLocation = true
                    } label: {
                        HStack {
                            Label("資料位置", systemImage: "externaldrive")
                            Spacer()
                            Text(Store.customDir?.lastPathComponent ?? "App 內部")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("資料")
                }
                Section {
                    Text("App 版本 \(appVersion)")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showDataLocation) {
                DataLocationSheet()
                    .environmentObject(library)
            }
        }
        .onDisappear { Store.backupSettings() }            // 設定改完就存一份到資料夾（v12.9）
    }
}

// MARK: - 資料位置：所有筆記存在「檔案」App 裡自己選的資料夾

struct DataLocationSheet: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var picked: URL?
    @State private var askExisting = false
    @State private var message = ""

    private var currentName: String {
        Store.customDir?.lastPathComponent ?? "App 內部（預設）"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(currentName, systemImage: Store.customDir == nil ? "iphone" : "folder")
                } header: {
                    Text("目前的資料位置")
                }
                Section {
                    Button {
                        showPicker = true
                    } label: {
                        Label("選擇資料夾…", systemImage: "folder.badge.gearshape")
                    }
                    if Store.customDir != nil {
                        Button {
                            moveBackToApp()
                        } label: {
                            Label("改回 App 內部（把資料複製回來）", systemImage: "arrow.uturn.backward")
                        }
                    }
                } footer: {
                    Text(footerText)
                }
                if !message.isEmpty {
                    Section {
                        Text(message)
                    }
                }
            }
            .navigationTitle("資料位置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [UTType.folder]) { result in
                if case .success(let url) = result { choose(url) }
            }
            .confirmationDialog("這個資料夾裡已經有筆記資料", isPresented: $askExisting, titleVisibility: .visible) {
                Button("直接使用那裡的資料") { switchTo(picked, copy: false) }
                Button("用目前的資料覆蓋過去", role: .destructive) { switchTo(picked, copy: true) }
                Button("取消", role: .cancel) { }
            }
        }
    }

    private var footerText: String {
        "建議在「檔案」App 的「我的 iPad」裡建一個資料夾來選。所有筆記本、PDF、筆跡都會存在那裡，"
            + "刪掉 App 或換安裝方式都不會不見；在「檔案」App 裡複製整個資料夾就是備份。"
            + "搬過去時原本的資料會留在 App 裡，不會刪掉。放在 iCloud Drive 也可以，但不要同時用兩個版本的 App 開同一本筆記。"
    }

    private func choose(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        picked = url
        if Store.hasLibrary(at: url) {
            askExisting = true
        } else {
            switchTo(url, copy: true)
        }
    }

    private func switchTo(_ url: URL?, copy: Bool) {
        guard let url = url else { return }
        library.objectWillChange.send()
        if copy && !Store.copyAll(from: Store.dir, to: url) {
            message = "有些檔案沒有複製成功，資料位置沒有改變。"
            return
        }
        Store.useFolder(url)
        library.reload()
        message = copy ? "已經把資料搬到「\(url.lastPathComponent)」，之後都會存在那裡。"
            : "已經改用「\(url.lastPathComponent)」裡的資料。"
    }

    private func moveBackToApp() {
        library.objectWillChange.send()
        _ = Store.copyAll(from: Store.dir, to: Store.appDir)
        Store.useFolder(nil)
        library.reload()
        message = "已經改回 App 內部，資料也複製回來了。原本那個資料夾裡的檔案還在。"
    }
}


// MARK: - 最近刪除

struct TrashView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var confirmEmpty = false
    @State private var target: ItemRef?
    @State private var showActions = false
    @State private var pending: TrashAction?          // 長按選了復原或永久刪除：先確認一次（v12.6）

    private enum TrashAction: Identifiable {
        case restore(ItemRef)
        case delete(ItemRef)
        var id: String {
            switch self {
            case .restore(let ref): return "r" + ref.id.uuidString
            case .delete(let ref): return "d" + ref.id.uuidString
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 28)]

    var body: some View {
        let items: [ItemRef] = library.trashedItems
        return ScrollView {
            VStack(spacing: 12) {
                Text("刪除的筆記本和資料夾會放在這裡 \(LibraryModel.trashDays) 天，之後自動永久刪除。點筆記本可以打開來看（只能看）；長按可以復原或永久刪除。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if items.isEmpty {
                    Text("沒有最近刪除的項目")
                        .foregroundStyle(.secondary)
                        .padding(.top, 100)
                }
                LazyVGrid(columns: columns, spacing: 36) {
                    ForEach(items, id: \.id) { (ref: ItemRef) in
                        trashCell(ref)
                    }
                }
            }
            .padding(32)
        }
        .navigationTitle("最近刪除")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("全部復原") { library.restoreAll() }
                    .disabled(items.isEmpty)
                Button("全部清空", role: .destructive) { confirmEmpty = true }
                    .disabled(items.isEmpty)
            }
        }
        .confirmationDialog("全部永久刪除？", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("全部永久刪除", role: .destructive) { library.emptyTrash() }
        } message: {
            Text("永久刪除後無法復原。")
        }
        .alert(item: $pending) { action in
            switch action {
            case .restore(let ref):
                return Alert(title: Text("復原「\(name(ref))」？"),
                             message: Text("會放回原本的資料夾。"),
                             primaryButton: .default(Text("復原")) { library.restore(ref) },
                             secondaryButton: .cancel(Text("取消")))
            case .delete(let ref):
                return Alert(title: Text("永久刪除「\(name(ref))」？"),
                             message: Text("永久刪除後無法復原。"),
                             primaryButton: .destructive(Text("永久刪除")) { library.deleteForever(ref) },
                             secondaryButton: .cancel(Text("取消")))
            }
        }
    }

    private func name(_ ref: ItemRef) -> String {
        switch ref {
        case .folder(let id): return library.folder(id)?.name ?? "資料夾"
        case .notebook(let id): return library.notebook(id)?.title ?? "筆記本"
        }
    }

    private var title: String {
        guard let ref = target else { return "" }
        return "還剩 \(library.daysLeft(ref)) 天會永久刪除"
    }

    /// 這一格的選單有沒有打開（選單掛在每一格上，才會跳在點的那一格旁邊）
    private func actionsShown(_ ref: ItemRef) -> Binding<Bool> {
        Binding(get: { showActions && target?.id == ref.id },
                set: { on in
                    if !on { showActions = false }
                })
    }

    @ViewBuilder
    private func trashCell(_ ref: ItemRef) -> some View {
        VStack(spacing: 4) {
            switch ref {
            case .folder(let id):
                if let folder = library.folder(id) {
                    FolderItemView(name: folder.name, color: folderColor(folder.colorIndex))
                }
            case .notebook(let id):
                if let meta = library.notebook(id) {
                    NotebookItemView(meta: meta)
                }
            }
            Text("剩 \(library.daysLeft(ref)) 天")
                .font(.caption)
                .foregroundStyle(.red)
        }
        .opacity(0.85)
        .contentShape(Rectangle())
        .onTapGesture {
            // 筆記本：打開來看（只能看，v12.6）；資料夾：跳出復原、永久刪除
            if case .notebook(let id) = ref, let meta = library.notebook(id) {
                withAnimation(.easeInOut(duration: 0.25)) { library.openNotebook = meta }
            } else {
                target = ref
                showActions = true
            }
        }
        .confirmationDialog(title, isPresented: actionsShown(ref), titleVisibility: .visible) {
            Button("復原") { pending = .restore(ref) }
            Button("永久刪除", role: .destructive) { pending = .delete(ref) }
        }
        .contextMenu {
            Button {
                pending = .restore(ref)
            } label: {
                Label("復原", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                pending = .delete(ref)
            } label: {
                Label("永久刪除", systemImage: "trash")
            }
        }
    }
}

struct FolderItemView: View {
    let name: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)
                .padding(10)
                .frame(height: 180)
            Text(name)
                .font(.headline)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// 筆記本：用第一頁當預覽
struct NotebookItemView: View {
    @EnvironmentObject private var library: LibraryModel
    let meta: NotebookMeta
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 8) {
            cover
                .frame(height: 180)
            HStack(spacing: 4) {
                if meta.isBoard == true {
                    Image(systemName: "rectangle.dashed")           // 白板的記號
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(meta.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(meta.modified, format: .dateTime.year().month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .task(id: meta.modified) {
            image = library.cover(for: meta)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.15))
                .aspectRatio(0.7, contentMode: .fit)
        }
    }
}
