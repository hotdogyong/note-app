import SwiftUI
import UIKit

// Drafts.swift（v12.16.0）：隨手記（使用者：取代讀書時在平板旁邊撕幾張白紙；要有空白感、可以翻頁的小白板）。
// ・每本筆記本（白板也是）各有一本藏起來的隨手記（NotebookMeta.draftOf），首頁、搜尋、日誌都不列。
// ・從右邊滑出來（右邊緣偏下的把手，或從右下角往內滑），佔畫面約 45%，可以拉寬、可以放大成全螢幕。左邊的筆記本照樣能看、能寫。
// ・頁面是橫的白紙（842 × 595，空白）。一次「主題」從新的一張白頁開始，往上滑看得到之前的頁；要新的一頁往下拉或按 ＋。
// ・主題什麼時候結束（使用者決定）：換到別本筆記本，或隔 6 小時以上再進這本。結束時完全沒寫就直接拿掉，有寫一點就問保留／不保留
//   （不保留的移到最近刪除，30 天內救得回來）。
// ・好的東西放進筆記本：套索圈起來 →「放進筆記本」（貼在筆記本畫面中間，可以再拖）；或整頁 → 插在筆記本目前這頁的後面。

/// 一次主題：從哪一頁開始、最後用的時間
struct DraftSession: Codable {
    var draft: UUID
    var startPage: UUID
    var lastUsed: Date
}

@MainActor
enum Drafts {
    static let staleAfter: TimeInterval = 6 * 3600
    static let pageSize = PageSpec(width: 842, height: 595)          // 橫的 A4
    static let paper = PaperStyle(pattern: 0, color: 1)              // 空白、白色

    static var library: LibraryModel?
    /// 抽屜裡的隨手記、外面的筆記本（放進筆記本用）
    static weak var drawerDoc: NotebookView?
    static weak var parentDoc: NotebookView?
    /// 抽屜蓋住外面筆記本右邊多少（0～1；全螢幕＝1）
    static var covered: CGFloat = 0.45

    private static let sessionsKey = "draftSessions"
    private static let lastParentKey = "draftLastParent"

    private static var sessions: [String: DraftSession] {
        get {
            guard let data = UserDefaults.standard.data(forKey: sessionsKey),
                  let list = try? JSONDecoder().decode([String: DraftSession].self, from: data) else { return [:] }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: sessionsKey) }
        }
    }

    /// 打開一本筆記本（不是視窗裡的、不是隨手記本身）：換了一本 → 上一本的主題結束；隔太久才進來 → 這本的主題結束
    static func enter(_ parent: UUID) {
        let last = UserDefaults.standard.string(forKey: lastParentKey).flatMap { UUID(uuidString: $0) }
        if let last = last, last != parent, sessions[last.uuidString] != nil { end(last) }
        if let s = sessions[parent.uuidString], Date().timeIntervalSince(s.lastUsed) > staleAfter { end(parent) }
        UserDefaults.standard.set(parent.uuidString, forKey: lastParentKey)
    }

    /// 拉出隨手記：這一次主題還在就接著用；沒有就在最後面加一張新的白頁
    static func open(for parent: NotebookMeta) -> NotebookMeta? {
        guard let library = library else { return nil }
        let draft = library.draftNotebook(for: parent)
        var all = sessions
        var data = Store.loadNotebook(draft.id)
        if var s = all[parent.id.uuidString], s.draft == draft.id,
           data.rows.contains(where: { $0.pages.contains { $0.id == s.startPage } }) {
            s.lastUsed = Date()
            all[parent.id.uuidString] = s
            sessions = all
            return draft
        }
        var row = PageRow()
        row.pages[0].spec = pageSize
        row.pages[0].paper = paper
        data.rows.append(row)
        data.lastPage = row.pages[0].id                       // 打開時直接在這張新的白頁
        Store.saveNotebook(data, id: draft.id)
        all[parent.id.uuidString] = DraftSession(draft: draft.id, startPage: row.pages[0].id, lastUsed: Date())
        sessions = all
        return draft
    }

    /// 收起抽屜：記下最後用的時間
    static func touch(_ parent: UUID) {
        var all = sessions
        guard var s = all[parent.uuidString] else { return }
        s.lastUsed = Date()
        all[parent.uuidString] = s
        sessions = all
    }

    /// 這次主題結束：完全沒寫就拿掉；有寫一點就問要不要保留
    static func end(_ parent: UUID) {
        var all = sessions
        guard let s = all[parent.uuidString] else { return }
        all[parent.uuidString] = nil
        sessions = all
        // 等抽屜裡那一本存好（換筆記本時，舊的畫面晚一點才收起來）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            Store.finishPendingSaves()
            let data = Store.loadNotebook(s.draft)
            guard let start = data.rows.firstIndex(where: { $0.pages.contains { $0.id == s.startPage } }) else { return }
            let rows = Array(data.rows[start...])
            let written = rows.contains { row in row.pages.contains { !isBlank($0) } }
            guard written else {
                remove(rows.map { $0.id }, from: s.draft, trash: false)
                return
            }
            let parentTitle = library?.notebook(parent)?.title ?? "筆記本"
            let count = rows.reduce(0) { $0 + $1.pages.count }
            let alert = UIAlertController(title: "隨手記這次寫了 \(count) 頁，要保留嗎？",
                                          message: "「\(parentTitle)」旁邊寫的。不保留的會移到「最近刪除」，30 天內救得回來。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "不保留", style: .destructive) { _ in
                remove(rows.map { $0.id }, from: s.draft, trash: true)
            })
            alert.addAction(UIAlertAction(title: "保留", style: .default))
            Presenter.present(alert)
        }
    }

    /// 這一頁有沒有寫東西（筆跡、文字方塊、圖片）
    static func isBlank(_ page: NotePage) -> Bool {
        (page.texts ?? []).isEmpty && (page.images ?? []).isEmpty && Store.loadDrawing(page.id).strokes.isEmpty
    }

    /// 從隨手記拿掉幾列（trash：先複製一份到最近刪除）
    private static func remove(_ rowIDs: [UUID], from draft: UUID, trash: Bool) {
        var data = Store.loadNotebook(draft)
        let ids = Set(rowIDs)
        let rows = data.rows.filter { ids.contains($0.id) }
        guard !rows.isEmpty else { return }
        if trash, let library = library, let meta = library.notebook(draft) {
            library.trashDeletedPages(rows, title: meta.title, folder: meta.folderID)
        }
        data.rows.removeAll { ids.contains($0.id) }
        if let last = data.lastPage, rows.contains(where: { $0.pages.contains { $0.id == last } }) { data.lastPage = nil }
        Store.saveNotebook(data, id: draft)
    }

    /// 套索選取的「放進筆記本」：已經拷貝進剪貼簿了，貼在外面那本畫面露出來那一塊的中間
    static func pasteIntoParent() {
        guard let parent = parentDoc else { return }
        let visibleWidth = parent.bounds.width * max(1 - covered, 0.3)
        parent.pasteClipboard(at: CGPoint(x: visibleWidth / 2, y: parent.bounds.midY))
    }

    /// 整頁放進筆記本：插在外面那本目前這頁的後面
    static func sendCurrentPage() {
        guard let draft = drawerDoc, let parent = parentDoc,
              let pid = draft.model.currentPageID,
              var row = draft.model.notebook.rows.first(where: { $0.pages.contains { $0.id == pid } }),
              let page = row.pages.first(where: { $0.id == pid }) else { return }
        if isBlank(page) {
            draft.showMessage("doc", "這一頁還沒寫東西")
            return
        }
        draft.flushAll()
        draft.model.save()
        Store.finishPendingSaves()
        row.pages = [page]
        row.mainIndex = 0
        parent.receiveRows([row])
    }
}

/// 筆記本畫面右邊的隨手記：收起來時只有右邊緣偏下的一個小把手；拉出來是一本嵌在裡面的筆記本
struct DraftDrawerLayer: View {
    @EnvironmentObject private var library: LibraryModel
    @ObservedObject var parent: NotebookModel
    @Binding var open: Bool
    @State private var draft: NotebookMeta?
    @State private var full = false
    @State private var fraction: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "draftWidth")
        return saved > 0.2 ? CGFloat(saved) : 0.45
    }()
    @State private var dragStart: CGFloat?
    @State private var handleDrag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                if open, let draft = draft {
                    drawer(draft, size: geo.size)
                        .transition(.move(edge: .trailing))
                } else if !open {
                    handle(geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
        }
        .onChange(of: open) { _, now in
            if now {
                if draft == nil || draft?.draftOf != parent.meta.id { draft = Drafts.open(for: parent.meta) }
                else { _ = Drafts.open(for: parent.meta) }
                Drafts.parentDoc = parent.documentView
                Drafts.covered = full ? 1 : fraction
            } else {
                Drafts.touch(parent.meta.id)
            }
        }
    }

    private func drawer(_ meta: NotebookMeta, size: CGSize) -> some View {
        let width = full ? size.width : min(max(320, size.width * fraction), size.width - 120)
        let shape = UnevenRoundedRectangle(topLeadingRadius: full ? 0 : 18, bottomLeadingRadius: full ? 0 : 18,
                                           bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        return HStack(spacing: 0) {
            if !full { resizeGrip(size) }
            VStack(spacing: 0) {
                header
                NotebookEditorView(meta: meta, embedded: true,
                                   windowActions: BoardWindowActions(close: closeDrawer,
                                                                     expand: { setFull(true) },
                                                                     back: { setFull(false) },
                                                                     mode: full ? .full : .float,
                                                                     openCard: { _, _ in },
                                                                     pasteToBoard: { image, _, _, _, _ in
                                                                         // 剪刀：剪下來的圖貼到外面那本
                                                                         let p = parent.documentView
                                                                         let w = (p?.bounds.width ?? 0) * max(1 - Drafts.covered, 0.3)
                                                                         p?.pasteImage(image, at: CGPoint(x: w / 2, y: (p?.bounds.midY ?? 0)))
                                                                         return nil
                                                                     },
                                                                     revealOnBoard: { _, _ in },
                                                                     frame: CGRect(x: size.width - width, y: 0, width: width, height: size.height)))
                    .id(meta.id)
            }
            .background(Color(uiColor: .systemBackground))
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipShape(shape)
        .background(shape.fill(Color.black).shadow(color: Color.black.opacity(0.35), radius: 14, x: -3))
        .overlay(shape.stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    /// 最上面一條：隨手記、＋新的一頁、放進筆記本
    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(Color.orange)
            Text("隨手記")
                .font(.headline)
            Spacer()
            Button {
                guard let doc = Drafts.drawerDoc else { return }
                doc.insertRow(at: doc.model.notebook.rows.count)
            } label: {
                Image(systemName: "plus.rectangle")
            }
            Menu {
                Button {
                    Drafts.sendCurrentPage()
                } label: {
                    Label("這一頁放進筆記本（插在目前這頁後面）", systemImage: "doc.badge.plus")
                }
                Text("要放一小塊：用套索圈起來，按「放進筆記本」")
            } label: {
                Image(systemName: "arrow.left.doc.on.clipboard")
            }
            Button {
                setFull(!full)
            } label: {
                Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            Button(action: closeDrawer) {
                Image(systemName: "chevron.right.2")
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    /// 左邊的一條：拖著改寬度
    private func resizeGrip(_ size: CGSize) -> some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            Capsule().fill(Color.secondary.opacity(0.6)).frame(width: 4, height: 44)
        }
        .frame(width: 14)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? fraction
                    if dragStart == nil { dragStart = start }
                    let f = start - value.translation.width / max(size.width, 1)
                    fraction = min(max(f, 0.3), 0.85)
                    Drafts.covered = fraction
                }
                .onEnded { _ in
                    dragStart = nil
                    UserDefaults.standard.set(Double(fraction), forKey: "draftWidth")
                }
        )
    }

    /// 收起來時：右邊緣偏下一個小把手（點一下、或往左拉就打開）
    private func handle(_ size: CGSize) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13, weight: .semibold))
            Image(systemName: "chevron.compact.left")
                .font(.system(size: 15, weight: .bold))
        }
        .foregroundStyle(Color.white)
        .frame(width: 26, height: 64)
        .background(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 0,
                                           topTrailingRadius: 0, style: .continuous).fill(Color.orange.opacity(0.85)))
        .offset(x: min(0, handleDrag))
        .position(x: size.width - 13, y: size.height * 0.74)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in handleDrag = value.translation.width }
                .onEnded { value in
                    handleDrag = 0
                    if value.translation.width < -24 || abs(value.translation.width) < 8 { openDrawer() }
                }
        )
    }

    private func openDrawer() {
        parent.documentView?.flushAll()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) { open = true }
    }

    private func closeDrawer() {
        Drafts.drawerDoc?.flushAll()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { open = false }
    }

    private func setFull(_ on: Bool) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { full = on }
        Drafts.covered = on ? 1 : fraction
    }
}
