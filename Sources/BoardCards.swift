import SwiftUI
import UIKit
import PencilKit
import UniformTypeIdentifiers

// BoardCards.swift：白板上的筆記本（v12.12.0）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）
//
// 卡片：白板上的一張「帶連結的圖片」（ImageBox.link＝筆記本的編號；圖是封面＋標題）。
//   所以移動、縮放、刪除、復原、跟著區塊搬、匯出都跟一般圖片一樣，不用另外寫一套。
//   v12.12.3（照 GUGA，使用者給了截圖）：平常卡片上沒有按鈕；點一下（或長按）選取，選取後左上角才出現兩顆——
//   第一顆開浮動視窗、第二顆直接在卡片上預覽（可以翻頁；再按一次回到封面）。按鈕畫在選取框 ImageEditorView 上。
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
    case newBoard          // 子白板（v12.14.0）：新的白板，家在這張白板裡
    case importBoard       // 現有的白板（只是連結，家不變）
}

/// 要打開哪一本的浮動視窗（stamp 每次加一，同一本連點兩次也會通知）
struct CardOpen: Equatable {
    let notebookID: UUID
    let stamp: Int
    var jump: WindowJump? = nil       // 打開後跳到哪一頁的哪一塊（白板上剪下來的圖的 ‹；v12.15.0）
}

/// 浮動視窗裡的筆記本要跳到哪裡（stamp 每次不一樣，同一個地方按兩次也會跳）
struct WindowJump: Equatable {
    let page: UUID
    let rect: CGRect
    let stamp: Int
}

/// 書籤面板裡一個「剪去白板的」範圍（v12.15.1）
struct ClipLine: Identifiable {
    let row: Int
    let page: Int
    let pageID: UUID
    let clip: PageClip
    var id: UUID { clip.id }
}

/// 浮動視窗的樣子（v12.15.0）：浮著、整個白板（全屏）、左半邊（分屏）
enum BoardWindowMode: Equatable {
    case float, full, split
}

/// 一個開著的浮動視窗
struct BoardWindow: Identifiable, Equatable {
    let id = UUID()
    var meta: NotebookMeta
    var frame: CGRect?          // 在白板畫面上的位置、大小；nil：還沒擺過，用預設的
    var mode = BoardWindowMode.float
    var jump: WindowJump? = nil
    var aspect: CGFloat? = nil  // 第一頁的高÷寬（v12.15.1：預設的視窗照這個比例，之後直接放大縮小就好）；白板：nil
    var split: CGFloat = 0.5    // 分屏時佔左邊多少（v12.15.2：右下角的 ‹› 可以拉）

    static func == (a: BoardWindow, b: BoardWindow) -> Bool {
        a.id == b.id && a.frame == b.frame && a.meta == b.meta && a.mode == b.mode && a.jump == b.jump
    }
}

/// 卡片的圖：筆記本第一頁的縮圖（或正在預覽的那一頁），下面是標題；四個角是圓的
@MainActor
enum CardCover {
    static let width: CGFloat = 240
    static let captionHeight: CGFloat = 52

    /// 每一列的主頁（卡片上預覽翻頁用的頁）
    static func mainPages(_ data: NotebookData) -> [NotePage] {
        data.rows.compactMap { row in
            row.pages.indices.contains(row.mainIndex) ? row.pages[row.mainIndex] : row.pages.first
        }
    }

    static func pageCount(_ meta: NotebookMeta) -> Int {
        mainPages(Store.loadNotebook(meta.id)).count
    }

    /// 上次看到第幾頁（開始預覽時從這一頁看起）
    static func lastPageIndex(_ meta: NotebookMeta) -> Int {
        let data = Store.loadNotebook(meta.id)
        guard let last = data.lastPage else { return 0 }
        return data.rows.firstIndex(where: { row in row.pages.contains(where: { $0.id == last }) }) ?? 0
    }

    /// previewPage：在卡片上預覽第幾頁（從 0 開始）；nil：封面（第一頁）
    static func image(for meta: NotebookMeta, caption: String, previewPage: Int? = nil) -> UIImage {
        let data = Store.loadNotebook(meta.id)
        let pages = mainPages(data)
        let isBoard = data.board == true
        var coverHeight = width * 842 / 595
        if let first = pages.first, !isBoard {
            // 太長的頁（Markdown 頁會往下長）只取上面一段
            coverHeight = min(width * first.spec.height / max(first.spec.width, 1), width * 1.5)
        }
        var shown: NotePage?
        if !isBoard {
            if let k = previewPage, pages.indices.contains(k) { shown = pages[k] } else { shown = pages.first }
        }
        let size = CGSize(width: width, height: coverHeight + captionHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let full = CGRect(origin: CGPoint.zero, size: size)
            UIBezierPath(roundedRect: full, cornerRadius: 16).addClip()
            UIColor(white: 0.27, alpha: 1).setFill()                   // 標題那一條比白板的底色亮一點
            ctx.fill(full)
            let coverRect = CGRect(x: 0, y: 0, width: width, height: coverHeight)
            if let page = shown {
                let thumb = Thumbnail.image(for: page, width: width)
                ctx.cgContext.saveGState()
                ctx.cgContext.clip(to: coverRect)
                let h = width * thumb.size.height / max(thumb.size.width, 1)
                if previewPage == nil || h <= coverHeight {
                    thumb.draw(in: CGRect(x: 0, y: 0, width: width, height: h))            // 寬度填滿、從上面開始
                } else {
                    let w = width * coverHeight / h                                         // 預覽：整頁縮到放得進去、置中
                    thumb.draw(in: CGRect(x: (width - w) / 2, y: 0, width: w, height: coverHeight))
                }
                ctx.cgContext.restoreGState()
            } else {
                let symbol = UIImage(systemName: isBoard ? "rectangle.dashed" : "book.closed",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .regular))?
                    .withTintColor(UIColor(white: 0.7, alpha: 1), renderingMode: .alwaysOriginal)
                if let symbol = symbol {
                    symbol.draw(at: CGPoint(x: coverRect.midX - symbol.size.width / 2, y: coverRect.midY - symbol.size.height / 2))
                }
            }
            // 預覽中：右上角寫第幾頁
            if let k = previewPage, !pages.isEmpty {
                let text = "\(min(k, pages.count - 1) + 1)/\(pages.count)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: UIColor.white
                ]
                let textSize = text.size(withAttributes: attrs)
                let pill = CGRect(x: width - textSize.width - 30, y: 10, width: textSize.width + 20, height: 24)
                UIColor(white: 0.1, alpha: 0.8).setFill()
                UIBezierPath(roundedRect: pill, cornerRadius: 12).fill()
                text.draw(at: CGPoint(x: pill.minX + 10, y: pill.midY - textSize.height / 2), withAttributes: attrs)
            }
            // 標題：靠左，最多兩行
            let style = NSMutableParagraphStyle()
            style.alignment = .left
            style.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: UIColor(white: 0.92, alpha: 1),
                .paragraphStyle: style
            ]
            (caption as NSString).draw(with: CGRect(x: 14, y: coverHeight + 8, width: width - 28, height: captionHeight - 14),
                                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: attrs, context: nil)
            // 一圈亮一點的邊（v12.13.0）：空白的深色筆記本放在深色白板上，以前跟背景幾乎一樣，看起來像卡片不見了
            ctx.cgContext.resetClip()
            let edge = UIBezierPath(roundedRect: full.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 14.5)
            edge.lineWidth = 3
            UIColor(white: 0.62, alpha: 1).setStroke()
            edge.stroke()
        }
    }
}

// MARK: - 浮動視窗

/// 浮動視窗交給裡面那本筆記本的動作：它工具列最左邊的「關閉、放大」
struct BoardWindowActions {
    let close: () -> Void
    let expand: () -> Void             // 全屏（v12.15.0：在白板上放大，不是開成分頁）
    let back: () -> Void               // 全屏、分屏時左上角的 ‹：回到浮著的大小
    let mode: BoardWindowMode
    let openCard: (UUID, WindowJump?) -> Void   // 視窗裡是白板：按它上面的卡片，交給外面的白板再開一個視窗（v12.13.0）
    // 剪刀「貼到白板」（v12.15.0）：圖、哪一本、哪一頁、頁面上的範圍、這個視窗現在在畫面上的位置；回傳貼上的那張圖
    let pasteToBoard: (UIImage, UUID, UUID, CGRect, CGRect) -> UUID?
    let revealOnBoard: (UUID, CGRect) -> Void   // 剪去白板的框 → 白板跳到那張圖（v12.15.2）
    let frame: CGRect                           // 這個視窗現在在畫面上的位置（v12.15.2：以前只記得剛開時的位置）
}

/// 視窗靠到哪一邊
enum BoardWindowSnap {
    case left, right, top, bottom, mini
}

/// 白板上所有開著的浮動視窗（蓋在白板上面、筆盒下面）
struct BoardWindowsLayer: View {
    @Binding var windows: [BoardWindow]
    @Binding var tucked: Bool                      // 全部先收到旁邊（還開著，只是看不到）
    let topExtend: CGFloat                         // 分屏時往上多蓋多少（白板工具列那一條的高度）
    let openCard: (UUID, WindowJump?) -> Void
    let pasteToBoard: (UIImage, UUID, UUID, CGRect, CGRect) -> UUID?   // 最後一個：那個視窗在畫面上的位置（貼的時候讓開）
    let revealOnBoard: (UUID, CGRect) -> Void
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
                                    topExtend: topExtend,
                                    openCard: openCard,
                                    pasteToBoard: pasteToBoard,
                                    revealOnBoard: revealOnBoard,
                                    close: { close(window) },
                                    toFront: { bringToFront(window.id) },
                                    openAsTab: { openAsTab(window) },
                                    renameCard: { renameCard(window) },
                                    moveHome: { moveHome(window) })
                }
                .opacity(tucked ? 0 : 1)
                .scaleEffect(tucked ? 0.97 : 1)
                .allowsHitTesting(!tucked)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            // 「收起視窗」在白板左下角那一排的第一顆（v12.15.0，照 GUGA；NotebookView.windowsButton）
        }
    }

    private func bringToFront(_ id: UUID) {
        guard let i = windows.firstIndex(where: { $0.id == id }), i != windows.count - 1 else { return }
        let w = windows.remove(at: i)
        windows.append(w)
    }
}

/// 一個浮動視窗（v12.12.3 照 GUGA 重排）：
/// 最上面中間三個點的小把手（點一下出選單：位置、模式、關閉；按住拖著移動），下面直接是筆記本（它的工具列最左邊是關閉、放大），
/// 右下角一小段弧線拉大小
struct BoardWindowView: View {
    @Binding var window: BoardWindow
    let container: CGSize
    let index: Int
    let inBoard: Bool
    let topExtend: CGFloat
    let openCard: (UUID, WindowJump?) -> Void
    let pasteToBoard: (UIImage, UUID, UUID, CGRect, CGRect) -> UUID?
    let revealOnBoard: (UUID, CGRect) -> Void
    let close: () -> Void
    let toFront: () -> Void
    let openAsTab: () -> Void
    let renameCard: () -> Void
    let moveHome: () -> Void
    @GestureState private var moveBy: CGSize = .zero
    @GestureState private var growBy: CGSize = .zero
    @GestureState private var splitBy: CGFloat = 0
    @State private var showMenu = false
    @State private var shown = false               // 打開時彈出來、關掉時縮回去

    static let minSize = CGSize(width: 440, height: 360)
    static let gripHeight: CGFloat = 26
    static let corner: CGFloat = 18
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// 還沒擺過的視窗：靠右、一個比一個往左下錯開
    static func defaultFrame(_ container: CGSize, _ index: Int, aspect: CGFloat? = nil) -> CGRect {
        var w = min(max(container.width * 0.6, minSize.width), 620, container.width - 24)
        var h = min(max(container.height * 0.62, minSize.height), container.height - 150)
        if let a = aspect, a > 0 {
            // 照頁面的比例（v12.15.1）：頁面寬約是視窗寬的 94%，上面加三個點那一條和工具列
            let chrome = gripHeight + 54
            let maxH = max(container.height - 140, minSize.height)
            w = min(max(container.width * 0.5, minSize.width), 600, container.width - 24)
            h = w * 0.94 * a + chrome + 20
            if h > maxH {
                h = maxH
                w = max((h - chrome - 20) / (0.94 * a), minSize.width)
            }
        }
        let shift = CGFloat(index) * 44
        let x = max(container.width - w - 84 - shift, 12)
        let y = min(110 + shift, max(container.height - h - 20, 60))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(max(r.width, Self.minSize.width), max(container.width, Self.minSize.width))
        r.size.height = min(max(r.height, Self.minSize.height), max(container.height - 60, Self.minSize.height))
        // 上面的把手至少留在畫面裡，才抓得回來；不要鑽到最上面的工具列底下
        r.origin.x = min(max(r.minX, 160 - r.width), container.width - 160)
        r.origin.y = min(max(r.minY, 56), container.height - Self.gripHeight - 8)
        return r
    }

    private func snapFrame(_ snap: BoardWindowSnap, from base: CGRect) -> CGRect {
        let top: CGFloat = 104                     // 讓開最上面的分頁和工具列
        let margin: CGFloat = 10
        let fullH = max(container.height - top - margin, Self.minSize.height)
        let fullW = max(container.width - margin * 2, Self.minSize.width)
        let halfW = max((container.width - margin * 3) / 2, Self.minSize.width)
        let halfH = max((container.height - top - margin * 2) / 2, Self.minSize.height)
        switch snap {
        case .left: return CGRect(x: margin, y: top, width: halfW, height: fullH)
        case .right: return CGRect(x: container.width - margin - halfW, y: top, width: halfW, height: fullH)
        case .top: return CGRect(x: margin, y: top, width: fullW, height: halfH)
        case .bottom: return CGRect(x: margin, y: container.height - margin - halfH, width: fullW, height: halfH)
        case .mini: return CGRect(x: base.minX, y: base.minY, width: Self.minSize.width, height: Self.minSize.height)
        }
    }

    /// 縮回去再關（動畫做完才真的拿掉）
    private func animateOut(_ then: @escaping () -> Void) {
        withAnimation(.easeIn(duration: 0.16)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { then() }
    }

    /// 浮著的時候的位置、大小
    private var floatFrame: CGRect { clamped(window.frame ?? Self.defaultFrame(container, index, aspect: window.aspect)) }

    /// 現在畫面上的位置、大小：全屏＝整個白板（白板的工具列下面）；分屏＝左半邊
    private var shownFrame: CGRect {
        switch window.mode {
        case .float: return floatFrame
        case .full: return CGRect(origin: CGPoint.zero, size: container)
        case .split:
            // 左半邊吃滿（v12.15.1，照 GUGA）：分頁那一排先收起來，往上蓋過白板工具列那一條（白板的工具列移到右半邊）
            return CGRect(x: 0, y: -topExtend, width: (container.width * window.split).rounded(), height: container.height + topExtend)
        }
    }

    private func setMode(_ mode: BoardWindowMode) {
        toFront()
        withAnimation(Self.spring) { window.mode = mode }
    }

    var body: some View {
        let floating = window.mode == .float
        let base = shownFrame
        let shape = RoundedRectangle(cornerRadius: floating ? Self.corner : 0, style: .continuous)
        let frameNow = base
        return VStack(spacing: 0) {
            if floating { grip(base) }
            NotebookEditorView(meta: window.meta, embedded: true,
                               windowActions: BoardWindowActions(close: { animateOut(close) },
                                                                 expand: { setMode(.full) },
                                                                 back: { setMode(.float) },
                                                                 mode: window.mode,
                                                                 openCard: openCard,
                                                                 pasteToBoard: pasteToBoard,
                                                                 revealOnBoard: revealOnBoard,
                                                                 frame: frameNow),
                               jump: window.jump)
                .id(window.meta.id)
        }
        .frame(width: base.width, height: base.height)
        .clipShape(shape)
        // 影子畫在後面那塊單純的圓角方塊上（畫在整個視窗上的話，拖的時候每一格都要重算，會頓）
        .background(shape.fill(Color.black).shadow(color: Color.black.opacity(0.45), radius: 12, y: 5))
        .overlay(shape.stroke(Color.white.opacity(0.2), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            // 拉大小的時候只畫一個虛線框，放手才真的改（筆記本重排很花時間）
            if growBy != .zero {
                shape
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .frame(width: max(base.width + growBy.width, Self.minSize.width),
                           height: max(base.height + growBy.height, Self.minSize.height))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if floating { resizeHandle(base) }
        }
        .overlay(alignment: .trailing) {
            if window.mode == .split {
                // 分屏：右邊一條分隔線
                Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if window.mode == .split { splitHandle(base) }
        }
        .transaction { $0.animation = nil }        // 大小的改變不做動畫（裡面的筆記本每一格都重排會頓）；位置、彈出才做
        .scaleEffect(shown ? 1 : 0.9)
        .opacity(shown ? 1 : 0)
        .offset(x: base.minX + moveBy.width, y: base.minY + moveBy.height)
        .onAppear {
            withAnimation(Self.spring) { shown = true }
        }
    }

    /// 分屏時右下角的 ‹›（v12.15.2，照 GUGA）：左右拉改變兩邊的寬度。拉的時候只畫一條虛線，放手才真的改
    private func splitHandle(_ base: CGRect) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if splitBy != 0 {
                Rectangle()
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .frame(width: 2, height: base.height)
                    .offset(x: splitBy - 1)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                Image(systemName: "chevron.right")
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.primary)
            .frame(width: 52, height: 40)
            .background(Capsule().fill(.regularMaterial))
            .shadow(color: Color.black.opacity(0.25), radius: 4)
            .contentShape(Capsule())
            .offset(x: 26 + splitBy, y: -60)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($splitBy) { value, state, _ in state = value.translation.width }
                    .onEnded { value in
                        let width = max(container.width, 1)
                        let k = (base.width + value.translation.width) / width
                        window.split = min(max(k, 0.3), 0.75)
                    }
            )
        }
    }

    /// 最上面那一條：中間三個點的小把手。點一下：選單；按住拖：移動視窗
    private func grip(_ base: CGRect) -> some View {
        ZStack {
            Color.black
            HStack(spacing: 4) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    Circle()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 14)
            .background(Capsule().fill(Color(white: 0.48)))
        }
        .frame(height: Self.gripHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            toFront()
            showMenu = true
        }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .updating($moveBy) { value, state, _ in state = value.translation }
                .onEnded { value in
                    window.frame = clamped(base.offsetBy(dx: value.translation.width, dy: value.translation.height))
                    toFront()
                }
        )
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            BoardWindowMenu(inBoard: inBoard,
                            snap: { snap in
                                showMenu = false
                                withAnimation(Self.spring) { window.frame = clamped(snapFrame(snap, from: base)) }
                            },
                            fullScreen: {
                                showMenu = false
                                setMode(.full)
                            },
                            split: {
                                showMenu = false
                                setMode(.split)
                            },
                            openTab: {
                                showMenu = false
                                animateOut(openAsTab)
                            },
                            rename: {
                                showMenu = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { renameCard() }
                            },
                            moveHome: {
                                showMenu = false
                                moveHome()
                            },
                            close: {
                                showMenu = false
                                animateOut(close)
                            })
        }
    }

    /// 右下角：沿著圓角的一小段粗弧線（照 GUGA），拖它改大小
    private func resizeHandle(_ base: CGRect) -> some View {
        Path { path in
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 14,
                        startAngle: Angle.degrees(12), endAngle: Angle.degrees(78), clockwise: false)
        }
        .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        .shadow(color: Color.black.opacity(0.7), radius: 1.5)
        .frame(width: 30, height: 30)
        .padding(.trailing, 4)
        .padding(.bottom, 4)
        .frame(width: 50, height: 50, alignment: .bottomTrailing)
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

/// 點視窗上面三個點跳出來的選單（照 GUGA）：位置、模式、卡片、關閉
struct BoardWindowMenu: View {
    let inBoard: Bool
    let snap: (BoardWindowSnap) -> Void
    let fullScreen: () -> Void
    let split: () -> Void
    let openTab: () -> Void
    let rename: () -> Void
    let moveHome: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("位置")
            HStack(spacing: 10) {
                tile("左", "rectangle.lefthalf.inset.filled") { snap(BoardWindowSnap.left) }
                tile("右", "rectangle.righthalf.inset.filled") { snap(BoardWindowSnap.right) }
            }
            HStack(spacing: 10) {
                tile("頂", "rectangle.tophalf.inset.filled") { snap(BoardWindowSnap.top) }
                tile("底", "rectangle.bottomhalf.inset.filled") { snap(BoardWindowSnap.bottom) }
            }
            Divider()
            title("模式")
            tile("全屏", "arrow.up.left.and.arrow.down.right", action: fullScreen)
            tile("Mini 浮窗", "arrow.down.right.and.arrow.up.left") { snap(BoardWindowSnap.mini) }
            tile("分屏模式", "rectangle.lefthalf.inset.filled", action: split)
            tile("開成分頁", "macwindow.on.rectangle", action: openTab)
            Divider()
            title("卡片")
            tile("改卡片上的標題", "pencil", action: rename)
            if inBoard {
                tile("搬到首頁", "house", action: moveHome)
            }
            Divider()
            Button(action: close) {
                HStack {
                    Text("關閉浮窗")
                    Spacer()
                    Image(systemName: "xmark")
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.red)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 270)
        .presentationCompactAdaptation(.popover)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func tile(_ text: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text)
                Spacer(minLength: 6)
                Image(systemName: symbol)
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 匯入現有的筆記本

/// 選一本現有的筆記本放到白板上（只是連結；筆記本還是在原本的資料夾）
struct CardNotebookPicker: View {
    @ObservedObject var library: LibraryModel
    let boardID: UUID
    var boards = false                     // true：列白板（子白板「匯入現有的」；v12.14.0）
    let pick: (NotebookMeta) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var groups: [(path: String, items: [NotebookMeta])] {
        let key = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var byPath: [String: [NotebookMeta]] = [:]
        for meta in library.library.notebooks {
            guard meta.deletedAt == nil, (meta.isBoard == true) == boards, meta.id != boardID else { continue }
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
                    Text(searchText.isEmpty ? (boards ? "沒有別的白板可以放" : "還沒有可以放的筆記本")
                                            : "找不到名稱裡有「\(searchText)」的" + (boards ? "白板" : "筆記本"))
                        .foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.path) { group in
                    Section(group.path) {
                        ForEach(group.items) { (meta: NotebookMeta) in
                            Button {
                                dismiss()
                                pick(meta)
                            } label: {
                                Label(meta.title, systemImage: boards ? "rectangle.dashed" : "book.closed")
                                    .foregroundStyle(Color.primary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: boards ? "搜尋白板" : "搜尋筆記本")
            .navigationTitle(boards ? "放哪一張白板到這裡？" : "放哪一本到白板上？")
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
