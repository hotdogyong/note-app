import SwiftUI
import UIKit
import PencilKit
import UniformTypeIdentifiers

// BoardCards.swift：白板上的筆記本（v12.12.0）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）
//
// 卡片：白板上的一張「帶連結的圖片」（ImageBox.link＝筆記本的編號；圖是封面＋標題）。
//   所以移動、縮放、刪除、復原、跟著區塊搬、匯出都跟一般圖片一樣，不用另外寫一套。
//   v12.12.2（照 GUGA，使用者要求）：卡片左上角有兩顆按鈕——第一顆開浮動視窗、第二顆開成分頁（整個畫面）。
//   點卡片其他地方（或長按）：選取，跟圖片一樣可以搬、拉大小、刪除。
// 浮動視窗：固定在畫面上（不跟著白板捲動），裡面是完整的筆記本（NotebookEditorView 的內嵌模式）。
//   可以同時開好幾個（最多 3 個，超過會收掉最早開的）；抓上面那一條移動、右下角拉大小、可以開成分頁。
//   筆盒用白板的那一個：選什麼筆，視窗裡就用什麼筆。
// 筆記本的「家」：NotebookMeta.boardID 有值＝家在那張白板裡，首頁不列出來
//   （檔案還是放在白板所在的資料夾裡，只是首頁不顯示）。首頁長按白板 →「白板裡的檔案」可以單獨打開、搬回首頁。

/// 白板要放卡片的請求（NotebookView 提出；NotebookEditorView 手上有 LibraryModel，由它完成）
enum CardRequest: Equatable {
    case newNotebook       // 新筆記本（家在這張白板裡）
    case importExisting    // 現有的筆記本（只是連結，家不變）
    case importPDF         // 匯入一份 PDF（家在這張白板裡）
}

/// 要打開哪一本的浮動視窗（stamp 每次加一，同一本連點兩次也會通知）
struct CardOpen: Equatable {
    let notebookID: UUID
    let stamp: Int
}

/// 一個開著的浮動視窗
struct BoardWindow: Identifiable, Equatable {
    let id = UUID()
    var meta: NotebookMeta
    var frame: CGRect?          // 在白板畫面上的位置、大小；nil：還沒擺過，用預設的

    static func == (a: BoardWindow, b: BoardWindow) -> Bool {
        a.id == b.id && a.frame == b.frame && a.meta == b.meta
    }
}

/// 卡片的圖：筆記本第一頁的縮圖，下面一條標題
@MainActor
enum CardCover {
    static let width: CGFloat = 240
    static let captionHeight: CGFloat = 46
    /// 左上角兩顆按鈕（畫在圖上；點在哪一顆由 NotebookView 用位置判斷）：每顆佔 buttonZone × buttonZone（圖的座標）
    static let buttonZone: CGFloat = 54
    static let buttonSize: CGFloat = 40

    static func image(for meta: NotebookMeta, caption: String) -> UIImage {
        let data = Store.loadNotebook(meta.id)
        var page: NotePage?
        if let row = data.rows.first {
            page = row.pages.indices.contains(row.mainIndex) ? row.pages[row.mainIndex] : row.pages.first
        }
        var coverHeight = width * 842 / 595
        var cover: UIImage?
        if let page = page, data.board != true {
            // 太長的頁（Markdown 頁會往下長）只取上面一段
            coverHeight = min(width * page.spec.height / max(page.spec.width, 1), width * 1.5)
            cover = Thumbnail.image(for: page, width: width)
        }
        let size = CGSize(width: width, height: coverHeight + captionHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.16, alpha: 1).setFill()
            ctx.fill(CGRect(origin: CGPoint.zero, size: size))
            let coverRect = CGRect(x: 0, y: 0, width: width, height: coverHeight)
            if let cover = cover {
                ctx.cgContext.saveGState()
                ctx.cgContext.clip(to: coverRect)
                let h = width * cover.size.height / max(cover.size.width, 1)
                cover.draw(in: CGRect(x: 0, y: 0, width: width, height: h))
                ctx.cgContext.restoreGState()
            } else {
                let symbol = UIImage(systemName: data.board == true ? "rectangle.dashed" : "book.closed",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .regular))?
                    .withTintColor(UIColor(white: 0.7, alpha: 1), renderingMode: .alwaysOriginal)
                if let symbol = symbol {
                    symbol.draw(at: CGPoint(x: coverRect.midX - symbol.size.width / 2, y: coverRect.midY - symbol.size.height / 2))
                }
            }
            // 標題
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingMiddle
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: style
            ]
            let text = caption as NSString
            text.draw(in: CGRect(x: 10, y: coverHeight + 12, width: width - 20, height: 24), withAttributes: attrs)
            // 左上角的兩顆按鈕：開浮動視窗、開成分頁
            let inset = (buttonZone - buttonSize) / 2
            for (i, name) in ["rectangle.on.rectangle", "book"].enumerated() {
                let rect = CGRect(x: CGFloat(i) * buttonZone + inset, y: inset, width: buttonSize, height: buttonSize)
                UIColor(white: 0.1, alpha: 0.82).setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 9).fill()
                let icon = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))?
                    .withTintColor(UIColor.white, renderingMode: .alwaysOriginal)
                if let icon = icon {
                    icon.draw(at: CGPoint(x: rect.midX - icon.size.width / 2, y: rect.midY - icon.size.height / 2))
                }
            }
            // 外框
            UIColor(white: 1, alpha: 0.35).setStroke()
            let border = UIBezierPath(rect: CGRect(origin: CGPoint.zero, size: size).insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
        }
    }
}

// MARK: - 浮動視窗

/// 白板上所有開著的浮動視窗（蓋在白板上面、筆盒下面）
struct BoardWindowsLayer: View {
    @Binding var windows: [BoardWindow]
    @Binding var tucked: Bool                      // 全部先收到旁邊（還開著，只是看不到）
    let close: (BoardWindow) -> Void
    let openAsTab: (BoardWindow) -> Void
    let renameCard: (BoardWindow) -> Void
    let moveHome: (BoardWindow) -> Void
    let isInBoard: (BoardWindow) -> Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach($windows) { $window in
                    BoardWindowView(window: $window, container: geo.size,
                                    index: windows.firstIndex(where: { $0.id == window.id }) ?? 0,
                                    inBoard: isInBoard(window),
                                    close: { close(window) },
                                    toFront: { bringToFront(window.id) },
                                    openAsTab: { openAsTab(window) },
                                    renameCard: { renameCard(window) },
                                    moveHome: { moveHome(window) })
                }
                .opacity(tucked ? 0 : 1)
                .allowsHitTesting(!tucked)
                if !windows.isEmpty {
                    // 左上角：全部收到旁邊／放回來（照 GUGA 的虛線方框）
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { tucked.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tucked ? "rectangle.on.rectangle" : "rectangle.dashed")
                            Text(tucked ? "放回 \(windows.count) 個視窗" : "收起視窗")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 16, y: 6)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private func bringToFront(_ id: UUID) {
        guard let i = windows.firstIndex(where: { $0.id == id }), i != windows.count - 1 else { return }
        let w = windows.remove(at: i)
        windows.append(w)
    }
}

/// 一個浮動視窗：上面一條（抓著移動、標題、選單、開成分頁、關閉），下面是筆記本，右下角拉大小
struct BoardWindowView: View {
    @Binding var window: BoardWindow
    let container: CGSize
    let index: Int
    let inBoard: Bool
    let close: () -> Void
    let toFront: () -> Void
    let openAsTab: () -> Void
    let renameCard: () -> Void
    let moveHome: () -> Void
    @GestureState private var moveBy: CGSize = .zero
    @GestureState private var growBy: CGSize = .zero

    static let minSize = CGSize(width: 440, height: 360)
    static let barHeight: CGFloat = 38

    /// 還沒擺過的視窗：靠右、一個比一個往左下錯開
    static func defaultFrame(_ container: CGSize, _ index: Int) -> CGRect {
        let w = min(max(container.width * 0.6, minSize.width), 620, container.width - 24)
        let h = min(max(container.height * 0.62, minSize.height), container.height - 150)
        let shift = CGFloat(index) * 44
        let x = max(container.width - w - 84 - shift, 12)
        let y = min(110 + shift, max(container.height - h - 20, 60))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(max(r.width, Self.minSize.width), max(container.width, Self.minSize.width))
        r.size.height = min(max(r.height, Self.minSize.height), max(container.height - 60, Self.minSize.height))
        // 上面那一條至少留 120 點在畫面裡，才抓得回來；不要鑽到最上面的工具列底下
        r.origin.x = min(max(r.minX, 120 - r.width), container.width - 120)
        r.origin.y = min(max(r.minY, 56), container.height - Self.barHeight - 8)
        return r
    }

    var body: some View {
        let base = clamped(window.frame ?? Self.defaultFrame(container, index))
        return VStack(spacing: 0) {
            titleBar(base)
            NotebookEditorView(meta: window.meta, embedded: true)
                .id(window.meta.id)
        }
        .frame(width: base.width, height: base.height)
        .background(Color(uiColor: UIColor.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.5), radius: 14, y: 6)
        .overlay(alignment: .topLeading) {
            // 拉大小的時候只畫一個虛線框，放手才真的改（筆記本重排很花時間）
            if growBy != .zero {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .frame(width: max(base.width + growBy.width, Self.minSize.width),
                           height: max(base.height + growBy.height, Self.minSize.height))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) { resizeHandle(base) }
        .offset(x: base.minX + moveBy.width, y: base.minY + moveBy.height)
    }

    private func titleBar(_ base: CGRect) -> some View {
        HStack(spacing: 4) {
            // v12.12.2：照 GUGA，關閉、開成整個畫面放在左上角
            Button(action: close) {
                Image(systemName: "xmark")
                    .frame(width: 36, height: Self.barHeight)
                    .contentShape(Rectangle())
            }
            Button(action: openAsTab) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 36, height: Self.barHeight)
                    .contentShape(Rectangle())
            }
            Text(window.meta.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .padding(.leading, 6)
            Spacer(minLength: 4)
            Menu {
                Button(action: renameCard) {
                    Label("改卡片上的標題", systemImage: "pencil")
                }
                Button(action: openAsTab) {
                    Label("開成分頁（整個畫面）", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                if inBoard {
                    Button(action: moveHome) {
                        Label("搬到首頁（跟白板同一個資料夾）", systemImage: "house")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 36, height: Self.barHeight)
                    .contentShape(Rectangle())
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .tint(Color.white)
        .foregroundStyle(Color.white)
        .padding(.horizontal, 4)
        .frame(height: Self.barHeight)
        .background(Color(white: 0.22))
        .overlay(alignment: .top) {
            // 中間上面的小把手：提示這一條可以抓著移動
            Capsule()
                .fill(Color.white.opacity(0.45))
                .frame(width: 36, height: 4)
                .padding(.top, 4)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .updating($moveBy) { value, state, _ in state = value.translation }
                .onEnded { value in
                    window.frame = clamped(base.offsetBy(dx: value.translation.width, dy: value.translation.height))
                    toFront()
                }
        )
    }

    private func resizeHandle(_ base: CGRect) -> some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color(white: 0.3)))
            .padding(4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($growBy) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        var r = base
                        r.size.width += value.translation.width
                        r.size.height += value.translation.height
                        window.frame = clamped(r)
                        toFront()
                    }
            )
    }
}

// MARK: - 匯入現有的筆記本

/// 選一本現有的筆記本放到白板上（只是連結；筆記本還是在原本的資料夾）
struct CardNotebookPicker: View {
    @ObservedObject var library: LibraryModel
    let boardID: UUID
    let pick: (NotebookMeta) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var groups: [(path: String, items: [NotebookMeta])] {
        let key = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var byPath: [String: [NotebookMeta]] = [:]
        for meta in library.library.notebooks {
            guard meta.deletedAt == nil, meta.isBoard != true, meta.id != boardID else { continue }
            if !key.isEmpty && !meta.title.lowercased().contains(key) { continue }
            var path = library.folderPathText(meta.folderID)
            if let board = meta.boardID, let owner = library.notebook(board) {
                path = "白板「\(owner.title)」裡的"
            }
            byPath[path, default: []].append(meta)
        }
        var out: [(path: String, items: [NotebookMeta])] = []
        for path in byPath.keys.sorted() {
            let items = (byPath[path] ?? []).sorted { (a: NotebookMeta, b: NotebookMeta) -> Bool in a.title < b.title }
            out.append((path, items))
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                if groups.isEmpty {
                    Text(searchText.isEmpty ? "還沒有可以放的筆記本" : "找不到名稱裡有「\(searchText)」的筆記本")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.path) { group in
                    Section(group.path) {
                        ForEach(group.items) { (meta: NotebookMeta) in
                            Button {
                                dismiss()
                                pick(meta)
                            } label: {
                                Label(meta.title, systemImage: "book.closed")
                                    .foregroundStyle(Color.primary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜尋筆記本")
            .navigationTitle("放哪一本到白板上？")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 首頁：白板裡的檔案

/// 首頁長按白板 →「白板裡的檔案」：家在這張白板裡的筆記本（首頁平常不列出來）。可以單獨打開，或搬回首頁
struct BoardFilesSheet: View {
    @ObservedObject var library: LibraryModel
    let board: NotebookMeta
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let files = library.boardFiles(board.id)
        return NavigationStack {
            List {
                if files.isEmpty {
                    Text("這張白板裡還沒有筆記本。在白板上長按空白處 →「新筆記本」，或右上角 ＋ 就可以加。")
                        .foregroundStyle(.secondary)
                }
                ForEach(files) { (meta: NotebookMeta) in
                    Button {
                        dismiss()
                        library.openRequest = meta
                    } label: {
                        Label(meta.title, systemImage: "book.closed")
                            .foregroundStyle(Color.primary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            library.setBoardHome(meta.id, board: nil)
                        } label: {
                            Label("搬到首頁", systemImage: "house")
                        }
                        .tint(Color.blue)
                    }
                }
                if !files.isEmpty {
                    Section {
                        Text("點一下：單獨打開。往左滑：搬到首頁（會出現在白板所在的資料夾裡；白板上的卡片還是連得到）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("「\(board.title)」裡的檔案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
