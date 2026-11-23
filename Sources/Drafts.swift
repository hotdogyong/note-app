import SwiftUI
import UIKit

// Drafts.swift（v12.16.0）：隨手記（使用者：取代讀書時在平板旁邊撕幾張白紙；要有空白感、可以翻頁的小白板）。
// ・每本筆記本（白板也是）各有一本藏起來的隨手記（NotebookMeta.draftOf），首頁、搜尋、日誌都不列。
// ・從右邊滑出來（右邊緣偏下的把手，或從右下角往內滑），佔畫面約 45%，可以拉寬、可以放大成全螢幕。左邊的筆記本照樣能看、能寫。
// ・頁面是橫的（842 × 595），紙跟外面那本目前這頁一樣（v12.16.1；以前是空白的白紙）。一次「主題」從新的一張白頁開始，往上滑看得到之前的頁；要新的一頁往下拉或按 ＋。
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
    static let paper = PaperStyle(pattern: 0, color: 1)              // 空白、白色（外面那本的紙拿不到時才用）

    static var library: LibraryModel?
    /// 抽屜裡的隨手記、外面的筆記本（放進筆記本用）
    static weak var drawerDoc: NotebookView?
    static weak var parentDoc: NotebookView?
    /// 抽屜蓋住外面筆記本右邊多少（0～1；全螢幕＝1）
    static var covered: CGFloat = 0.45
    /// 抽屜的左邊緣在螢幕上的 x（全域座標）；收起來＝nil。外面那本畫到這裡就切斷（v12.16.1）
    static var edgeX: CGFloat?

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

    /// 拉出隨手記：這一次主題還在就接著用；沒有就在最後面加一張新的白頁。
    /// paper：外面那本目前這頁的紙（v12.16.1，使用者：預設跟旁邊那本一樣的底色和格線）
    static func open(for parent: NotebookMeta, paper wanted: PaperStyle? = nil) -> NotebookMeta? {
        guard let library = library else { return nil }
        let draft = library.draftNotebook(for: parent)
        var all = sessions
        var data = Store.loadNotebook(draft.id)
        let newPaper = wanted ?? paper
        if var s = all[parent.id.uuidString], s.draft == draft.id,
           let start = data.rows.firstIndex(where: { $0.pages.contains { $0.id == s.startPage } }) {
            s.lastUsed = Date()
            all[parent.id.uuidString] = s
            sessions = all
            // 這次主題裡還沒寫的頁：換成外面那本現在的紙
            var changed = false
            for r in start ..< data.rows.count {
                for p in data.rows[r].pages.indices where data.rows[r].pages[p].paper != newPaper && isBlank(data.rows[r].pages[p]) {
                    data.rows[r].pages[p].paper = newPaper
                    changed = true
                }
            }
            if changed { Store.saveNotebook(data, id: draft.id) }
            return draft
        }
        var row = PageRow()
        row.pages[0].spec = pageSize
        row.pages[0].paper = newPaper
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

/// 抽屜的狀態：NotebookEditorView、右邊緣的手勢（UIKit）、抽屜本身共用（v12.16.1）
@MainActor
final class DraftDrawerState: ObservableObject {
    /// 停在打開的樣子（外面要打開也是設這個，例如自動測試）
    @Published var open = false
    /// 手指正拉著抽屜的左邊緣：在螢幕上的 x（全域座標）；沒在拉＝nil
    @Published var drag: CGFloat?
    /// 放開了：往右的速度（點／秒），抽屜決定要停在哪、還是收回去
    @Published var released: CGFloat?
}

/// 筆記本畫面右邊的隨手記：收起來時只有右下角的一個小把手；拉出來是一本嵌在裡面的筆記本。
/// v12.16.1（使用者要求）：
/// ・拉出來時紙跟著手指出來，放手的地方就是抽屜的寬度（太窄就收回去）
/// ・抓左邊那一條：左右拖改寬度；往右拖到底（或往右甩）就收回去，一路跟著手指
/// ・上面只留一排（收起、全螢幕、頁數；上一步、下一步、＋、放進筆記本）
struct DraftDrawerLayer: View {
    @EnvironmentObject private var library: LibraryModel
    @ObservedObject var parent: NotebookModel
    @ObservedObject var state: DraftDrawerState
    @State private var draft: NotebookMeta?
    @State private var full = false
    @State private var fraction: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "draftWidth")
        return saved > 0.2 ? CGFloat(saved) : 0.45
    }()
    @State private var shown = false             // 抽屜在畫面上（拉著、打開、正在收）
    @State private var offset: CGFloat = 0       // 往右移出去多少（收回、點把手滑進來的動畫）
    @State private var settle: CGFloat?          // 放手後動畫中的寬度（動畫結束就回到 fraction）
    @State private var handleMoved = false
    @State private var closing = false

    /// 拉著的時候，抽屜最窄多寬；比這個窄就改成整個往右移（看起來是被手指推回去）
    static let minWidth: CGFloat = 300

    var body: some View {
        GeometryReader { geo in
            let box = geo.frame(in: .global)
            let size = geo.size
            let width = drawerWidth(size, box: box)
            ZStack(alignment: .trailing) {
                handle(size, box: box)
                    .opacity(shown ? 0 : 1)
                    .allowsHitTesting(!shown || handleMoved)          // 拉著把手時抽屜已經出來了：手勢不能斷
                if shown, let draft = draft {
                    drawer(draft, size: size, width: width)
                        .offset(x: drawerOffset(size, box: box))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .trailing)
            .onChange(of: state.drag) { _, x in
                if x != nil && !shown { beginReveal() }
                publishEdge(box: box, width: width)
            }
            .onChange(of: shown) { _, _ in publishEdge(box: box, width: width) }
            .onChange(of: state.released) { _, v in
                guard let v = v else { return }
                state.released = nil
                finishDrag(velocity: v, size: size, box: box)
            }
            .onChange(of: state.open) { _, now in
                if now && !shown { slideIn(size: size, box: box) }      // 外面要打開（自動測試）
                if !now && shown && state.drag == nil { slideOut(size: size, box: box) }
            }
            .onChange(of: width) { _, w in publishEdge(box: box, width: w) }
            .onChange(of: offset) { _, _ in publishEdge(box: box, width: width) }
        }
    }

    // MARK: 寬度、位置

    private func restingWidth(_ size: CGSize) -> CGFloat {
        if full { return size.width }
        return min(max(Self.minWidth, size.width * fraction), size.width - 120)
    }

    /// 手指拉著時：抽屜左邊緣到右邊的距離（可能比最窄還窄，那時整個往右移）
    private func liveWidth(_ box: CGRect) -> CGFloat? {
        state.drag.map { box.maxX - $0 }
    }

    private func drawerWidth(_ size: CGSize, box: CGRect) -> CGFloat {
        if let live = liveWidth(box) { return min(max(live, Self.minWidth), size.width - 60) }
        return settle ?? restingWidth(size)
    }

    private func drawerOffset(_ size: CGSize, box: CGRect) -> CGFloat {
        if let live = liveWidth(box) { return max(0, Self.minWidth - max(live, 0)) }
        return offset
    }

    /// 告訴外面那本：抽屜蓋到哪裡（筆跡畫到這裡就切斷；放進筆記本時貼在露出來那一塊的中間）
    private func publishEdge(box: CGRect, width: CGFloat) {
        guard shown else {
            Drafts.edgeX = nil
            return
        }
        let left = box.maxX - width + (state.drag == nil ? offset : drawerOffset(box.size, box: box))
        Drafts.edgeX = left
        Drafts.covered = min(max((box.maxX - left) / max(box.width, 1), 0), 1)
    }

    // MARK: 打開、收起

    /// 開始拉出來：準備好這次的隨手記
    private func beginReveal() {
        parent.documentView?.flushAll()
        // 外面那本目前這頁看起來的紙（舊的頁沒存紙張＝預設的深灰方格，要用 paperStyle 才拿得到）
        let paper = (parent.currentPageID.flatMap { parent.page($0) } ?? parent.notebook.rows.first?.pages.first)?.paperStyle
        if draft == nil || draft?.draftOf != parent.meta.id {
            draft = Drafts.open(for: parent.meta, paper: paper)
        } else {
            _ = Drafts.open(for: parent.meta, paper: paper)
        }
        Drafts.parentDoc = parent.documentView
        shown = true
        offset = 0
        settle = nil
    }

    /// 點把手：從右邊滑進來，停在上次的寬度
    private func slideIn(size: CGSize, box: CGRect) {
        if !shown { beginReveal() }
        let w = restingWidth(size)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { offset = w + 30 }
        state.open = true
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { offset = 0 }
        }
    }

    /// 收起：整個往右滑出去
    private func slideOut(size: CGSize, box: CGRect) {
        guard !closing else { return }
        closing = true
        Drafts.drawerDoc?.flushAll()
        let w = settle ?? restingWidth(size)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.92)) {
            offset = w + 30
        } completion: {
            shown = false
            closing = false
            offset = 0
            settle = nil
            full = false
            Drafts.edgeX = nil
            Drafts.touch(parent.meta.id)
        }
        state.open = false
    }

    /// 放手：太窄（或往右甩）就收回去；不然就停在放手的地方
    private func finishDrag(velocity: CGFloat, size: CGSize, box: CGRect) {
        guard let live = liveWidth(box) else { return }
        let shownWidth = min(max(live, Self.minWidth), size.width - 60)
        let shownOffset = max(0, Self.minWidth - max(live, 0))
        // 先把「拉著」的樣子原封不動交給 settle、offset，再動畫到最後的樣子
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            settle = shownWidth
            offset = shownOffset
            state.drag = nil
        }
        let closing = (live < 180 && velocity > -300) || velocity > 900
        if closing {
            if state.open {
                state.open = false                               // onChange(state.open) 會收回去
            } else {
                slideOut(size: size, box: box)                   // 剛拉出來就放回去
            }
            return
        }
        // 停下來：放手的地方就是寬度（往左甩：再寬一點）
        var target = live - min(velocity, 0) * 0.15
        if target > size.width * 0.9 {
            full = true
            target = size.width
        } else {
            full = false
            fraction = min(max(target / max(size.width, 1), 0.28), 0.85)
            UserDefaults.standard.set(Double(fraction), forKey: "draftWidth")
            target = restingWidth(size)
        }
        state.open = true
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            settle = target
            offset = 0
        } completion: {
            settle = nil
        }
    }

    private func setFull(_ on: Bool, size: CGSize) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { full = on }
    }

    // MARK: 畫面

    private func drawer(_ meta: NotebookMeta, size: CGSize, width: CGFloat) -> some View {
        let isFull = full && state.drag == nil
        let shape = UnevenRoundedRectangle(topLeadingRadius: isFull ? 0 : 18, bottomLeadingRadius: isFull ? 0 : 18,
                                           bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        let inner = isFull ? width : width - 16
        return HStack(spacing: 0) {
            if !isFull { grip(size) }
            NotebookEditorView(meta: meta, embedded: true,
                               windowActions: BoardWindowActions(close: { state.open = false },
                                                                 expand: { setFull(true, size: size) },
                                                                 back: { setFull(false, size: size) },
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
                .frame(width: inner)
                .frame(maxHeight: .infinity)
                .clipped()
                .background(Color(uiColor: .systemBackground))
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity)
        .clipShape(shape)
        .background(shape.fill(Color.black).shadow(color: Color.black.opacity(0.35), radius: 14, x: -3))
        .overlay(shape.stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    /// 左邊的一條：左右拖改寬度；往右拖到底、或往右甩就收回去
    private func grip(_ size: CGSize) -> some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            Capsule().fill(Color.secondary.opacity(0.7)).frame(width: 5, height: 52)
        }
        .frame(width: 16)
        .contentShape(Rectangle().inset(by: -10))
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    state.drag = value.location.x - 8
                }
                .onEnded { value in
                    state.drag = value.location.x - 8
                    state.released = value.velocity.width
                }
        )
    }

    /// 收起來時：右下角一個小把手（點一下打開；往左拉：抽屜跟著手指出來）
    private func handle(_ size: CGSize, box: CGRect) -> some View {
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
        .contentShape(Rectangle().inset(by: -8))
        .position(x: size.width - 13, y: max(size.height * 0.6, size.height - 150))   // 靠近右下角（筆盒停在右邊時不會被擋住）
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !handleMoved && abs(value.translation.width) < 6 { return }
                    handleMoved = true
                    state.drag = min(value.location.x, box.maxX)
                }
                .onEnded { value in
                    if handleMoved {
                        state.drag = min(value.location.x, box.maxX)
                        state.released = value.velocity.width
                    } else {
                        slideIn(size: size, box: box)
                    }
                    handleMoved = false
                }
        )
    }
}
