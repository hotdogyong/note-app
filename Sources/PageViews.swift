import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// PageViews.swift：頁面：PageRowView（一列）、NoteCanvas、NotePageView（一頁）、紙膠帶、紙張與封面的畫法、拉動新增的圓圈、PDF、匯出與縮圖
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

// MARK: - 6. 一列：主頁 + 旁頁，左右滑動、往左右拉新增

final class PageRowView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let rowID: UUID
    weak var host: NotebookView?
    var pages: [NotePage] = []                                     // 這一列的頁面資料（由左到右）
    private(set) var pageFrames: [CGRect] = []                     // 每一頁在這一列裡的位置
    private(set) var ranges: [(lo: CGFloat, hi: CGFloat)] = []   // 每一頁可停留的水平範圍
    var currentIndex = 0
    var mainIndex = 0

    private var dragStartX: CGFloat = 0
    private var dragStartIndex = 0
    private var pendingAdd = 0          // -1 = 左邊新增，+1 = 右邊新增
    private var startedAtLeftEnd = false
    private var startedAtRightEnd = false
    private let leftPull = PullIndicator(text: "新增旁頁", width: 100)
    private let rightPull = PullIndicator(text: "新增旁頁", width: 100)

    init(rowID: UUID, host: NotebookView) {
        self.rowID = rowID
        self.host = host
        super.init(frame: .zero)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = true
        alwaysBounceVertical = false
        scrollsToTop = false                         // 一排旁頁是左右捲的，點狀態列不要動它
        decelerationRate = .fast
        delaysContentTouches = false
        clipsToBounds = false
        panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addSubview(leftPull)
        addSubview(rightPull)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 白板（v12.3）：這一列的左右捲動可以跟外層的上下捲動同時進行，斜著拖也可以。一般筆記本照舊（一次只捲一個方向）
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer, let host = host, host.isBoard else { return false }
        return host.isOuterPan(other)
    }

    // 頁面上的選取框超出這一列時，超出的部分也要能點
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        return subviews.contains { $0 is NotePageView && $0.point(inside: convert(point, to: $0), with: event) }
    }

    /// 依頁面尺寸排版；已經載入的頁面視圖順便放到正確位置
    func layoutPages(scale s: CGFloat, margin m: CGFloat) {
        let viewWidth = bounds.width
        var x = m
        var newRanges: [(lo: CGFloat, hi: CGFloat)] = []
        var frames: [CGRect] = []
        for page in pages {
            let w = page.spec.width * s
            let h = page.spec.height * s
            let frame = CGRect(x: x, y: 0, width: w, height: h)
            frames.append(frame)
            if let pv = host?.loadedPageView(page.id) {
                pv.frame = frame
                pv.apply(scale: s)
            }
            var lo = x - m
            var hi = x + w + m - viewWidth
            if lo > hi {                         // 頁面比畫面窄：置中
                let c = x + w / 2 - viewWidth / 2
                lo = c
                hi = c
            }
            newRanges.append((lo: lo, hi: hi))
            x += w + 2 * m
        }
        ranges = newRanges
        pageFrames = frames
        let contentWidth = x - m
        contentSize = CGSize(width: max(contentWidth, viewWidth), height: bounds.height)
        let leftInset = max(0, -(ranges.first?.lo ?? 0))
        let rightInset = max(0, (ranges.last?.hi ?? 0) + viewWidth - contentSize.width)
        contentInset = UIEdgeInsets(top: 0, left: leftInset, bottom: 0, right: rightInset)
        let midY = bounds.height / 2
        if let f = ranges.first { leftPull.center = CGPoint(x: f.lo - 50, y: midY) }
        if let l = ranges.last { rightPull.center = CGPoint(x: l.hi + viewWidth + 50, y: midY) }
    }

    func offsetFor(_ index: Int, inPage: CGFloat) -> CGFloat {
        guard ranges.indices.contains(index) else { return 0 }
        let r = ranges[index]
        return min(max(r.lo + inPage, r.lo), r.hi)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStartX = contentOffset.x
        dragStartIndex = currentIndex
        // 開始拖的時候，是否已經停在最左邊／最右邊那一張的邊緣
        startedAtLeftEnd = currentIndex == 0 && abs(contentOffset.x - (ranges.first?.lo ?? 0)) < 6
        startedAtRightEnd = currentIndex == ranges.count - 1 && abs(contentOffset.x - (ranges.last?.hi ?? 0)) < 6
        if host?.allowsPagePull == false {                     // 白板：往左、往右拉不新增旁頁
            startedAtLeftEnd = false
            startedAtRightEnd = false
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let first = ranges.first, let last = ranges.last, let host = host else { return }
        let x = contentOffset.x
        leftPull.progress = (isTracking && startedAtLeftEnd) ? (first.lo - x) / host.pullThreshold : 0
        rightPull.progress = (isTracking && startedAtRightEnd) ? (x - last.hi) / host.pullThreshold : 0
        if isDragging || isDecelerating { host.rowDidScroll(self) }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard let host = host, ranges.indices.contains(dragStartIndex),
              let first = ranges.first, let last = ranges.last else { return }
        let x = contentOffset.x
        let viewWidth = bounds.width
        pendingAdd = 0

        // 先停在最邊緣、再慢慢往外拉到圓圈跑滿 → 新增旁頁；一路甩過去不算
        let slowEnough = abs(velocity.x) < host.pullMaxVelocity
        if startedAtLeftEnd && slowEnough && first.lo - x >= host.pullThreshold {
            pendingAdd = -1
            targetContentOffset.pointee.x = first.lo
            return
        }
        if startedAtRightEnd && slowEnough && x - last.hi >= host.pullThreshold {
            pendingAdd = 1
            targetContentOffset.pointee.x = last.hi
            return
        }

        // 換頁：從頁面邊緣開始滑才換頁；放大時在頁面中間滑，只會在這一頁內移動
        let i = dragStartIndex
        let r = ranges[i]
        let proposed = targetContentOffset.pointee.x
        var newIndex = i
        var target = min(max(proposed, r.lo), r.hi)
        // 靈敏度：輕輕一撥（速度 0.12）或拖過畫面寬度的 7% 就換頁
        let startedAtLeftEdge = dragStartX <= r.lo + 8
        let startedAtRightEdge = dragStartX >= r.hi - 8
        let goLeft = (startedAtLeftEdge && (velocity.x < -0.12 || proposed < r.lo - viewWidth * 0.07))
            || x < r.lo - viewWidth * 0.25
        let goRight = (startedAtRightEdge && (velocity.x > 0.12 || proposed > r.hi + viewWidth * 0.07))
            || x > r.hi + viewWidth * 0.25
        if i > 0 && goLeft {
            newIndex = i - 1
            target = ranges[newIndex].hi
        } else if i < ranges.count - 1 && goRight {
            newIndex = i + 1
            target = ranges[newIndex].lo
        }
        targetContentOffset.pointee.x = target
        if newIndex != currentIndex {
            currentIndex = newIndex
            host.rowPageChanged(self)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard pendingAdd != 0 else { return }
        let left = pendingAdd < 0
        pendingAdd = 0
        Task { @MainActor [weak self] in
            guard let self = self, let host = self.host else { return }
            host.addSidePage(rowID: self.rowID, left: left)
        }
    }
}


// MARK: - 7. 一張頁面：方格底 + 手寫層，自動存檔

final class NoteCanvas: PKCanvasView {
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    /// PencilKit 自己的復原紀錄一律忽略（筆跡被程式換掉時它會失效），改由筆記本統一記錄
    private static let ignoredUndo: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    override var undoManager: UndoManager? { Self.ignoredUndo }

    // PencilKit 自己的選單（插入空間、全選、貼上…）一律不要
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        stripSystemMenus()
        // PencilKit 有些東西是之後才加上去的，晚一點再清一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.stripSystemMenus() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.stripSystemMenus() }
    }

    // 畫布只需要 Pencil：手指的觸碰不交給 PencilKit（它的選單是手指點出來的）
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stripSystemMenus()
        let pencil = touches.filter { $0.type == .pencil }
        if !pencil.isEmpty { super.touchesBegan(pencil, with: event) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencil = touches.filter { $0.type == .pencil }
        if !pencil.isEmpty { super.touchesMoved(pencil, with: event) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencil = touches.filter { $0.type == .pencil }
        if !pencil.isEmpty { super.touchesEnded(pencil, with: event) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencil = touches.filter { $0.type == .pencil }
        if !pencil.isEmpty { super.touchesCancelled(pencil, with: event) }
    }

    // PencilKit 之後才要加上的選單功能，直接擋掉
    override func addInteraction(_ interaction: UIInteraction) {
        if interaction is UIEditMenuInteraction || interaction is UIContextMenuInteraction { return }
        super.addInteraction(interaction)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g !== drawingGestureRecognizer, g is UITapGestureRecognizer || g is UILongPressGestureRecognizer {
            return false
        }
        return super.gestureRecognizerShouldBegin(g)
    }

    /// 畫布裡面（包含內部的子視圖）手指點一下、長按會跳出的選單都關掉；Pencil 書寫不受影響
    private func stripSystemMenus() {
        func walk(_ v: UIView) {
            for interaction in v.interactions
            where interaction is UIEditMenuInteraction || interaction is UIContextMenuInteraction {
                v.removeInteraction(interaction)
            }
            for g in v.gestureRecognizers ?? [] where g !== drawingGestureRecognizer {
                if g is UITapGestureRecognizer || g is UILongPressGestureRecognizer {
                    g.isEnabled = false
                } else if !(g is UIPanGestureRecognizer || g is UIPinchGestureRecognizer || g is UIHoverGestureRecognizer) {
                    g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]   // 其他不明的手勢：手指不能觸發
                }
            }
            v.subviews.forEach(walk)
        }
        walk(self)
    }
}

final class NotePageView: UIView, PKCanvasViewDelegate {
    private(set) var page: NotePage
    let canvas = NoteCanvas()
    // PDF 頁：手寫（螢光筆以外）再畫一次在最上層、正常顯示，課本的字不會疊在你的字上面
    private var inkOverlay: PKCanvasView?
    weak var host: NotebookView?
    private let grid = GridView()
    private let pdfView = UIImageView()
    private var renderedPixelWidth: CGFloat = 0
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private(set) var strokeCountAtBegin = 0
    private(set) var committedDrawing = PKDrawing()   // 上一次登記復原時的筆跡
    private var silent = false
    private var toolActive = false                     // 筆正在紙上（一次擦好幾筆也只算一步）
    private var changedDuringTool = false
    private var inkBase: PKDrawing?                   // 這一筆開始寫的時候畫布上的筆跡（v12.15.7：檢查舊的筆跡有沒有被吃掉）
    private(set) var toolUses = 0                      // 下筆的次數（判斷變形後有沒有又寫了新的一筆）
    private(set) var loadMillis = 0                    // 打開這一頁時讀筆跡花了多久（v12.11.0：白板齒輪面板顯示，比較分區前後）

    /// 白板的大頁面（v12.5）：畫布、格線只蓋住這一塊（頁面座標），由筆記本畫面依捲動位置更新。
    /// PencilKit 的畫布跟整張白板一樣大的話會吃光記憶體（v12.3 只好限制白板大小和放大倍數）；
    /// 改成畫布只跟畫面附近一樣大，用畫布自己的捲動位置對到白板上的位置，座標換算跟以前一樣
    var canvasWindow: CGRect?
    /// 這一頁是白板的大頁面
    var isFlat: Bool { page.spec.flat == true }
    /// 筆正在紙上（這時候不要移動畫布）
    var isDrawing: Bool { toolActive }

    init(page: NotePage) {
        self.page = page
        super.init(frame: .zero)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = page.spec.flat == true ? 0 : 0.2       // 白板不畫陰影（整張白板的陰影很耗資源）
        if page.spec.flat == true {
            backgroundColor = PaperRenderer.background(page.paperStyle)   // 格線只畫畫面附近，其他地方用紙的底色
        }
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        if page.pdf != nil {
            pdfView.backgroundColor = .white
            pdfView.contentMode = .scaleToFill
            addSubview(pdfView)                 // PDF 頁：背景是課本內容
        } else {
            grid.paper = page.paperStyle
            grid.cover = page.cover
            grid.pageWidth = page.spec.width
            addSubview(grid)                    // 一般頁：紙張（或封面）
        }

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly          // 只有 Pencil 能寫
        canvas.overrideUserInterfaceStyle = .light  // 顏色照實顯示
        canvas.isScrollEnabled = false
        canvas.scrollsToTop = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.bouncesZoom = false
        canvas.contentInsetAdjustmentBehavior = .never
        let loadStart = CACurrentMediaTime()
        canvas.drawing = Store.loadDrawing(page.id)
        loadMillis = Int((CACurrentMediaTime() - loadStart) * 1000)
        committedDrawing = canvas.drawing
        canvas.delegate = self
        if page.pdf != nil {
            // PDF 頁：筆跡用「相乘」疊在課本上，螢光筆底下的黑字不會被蓋淡
            canvas.layer.compositingFilter = "multiplyBlendMode"
        }
        addSubview(canvas)
        if page.pdf != nil {
            let overlay = PKCanvasView()
            overlay.isUserInteractionEnabled = false
            overlay.backgroundColor = .clear
            overlay.isOpaque = false
            overlay.overrideUserInterfaceStyle = .light
            overlay.isScrollEnabled = false
            overlay.showsVerticalScrollIndicator = false
            overlay.showsHorizontalScrollIndicator = false
            overlay.contentInsetAdjustmentBehavior = .never
            overlay.drawingGestureRecognizer.isEnabled = false
            addSubview(overlay)
            inkOverlay = overlay
            syncOverlay()
        }
        syncImages(page.images ?? [])
        clipView.isUserInteractionEnabled = false
        addSubview(clipView)                         // 剪去白板的範圍（v12.15.1）：灰色虛線框（v12.15.3：每個框自己的顏色）
        clips = page.clips ?? []
        DispatchQueue.main.async { [weak self] in   // host 接上之後才知道要不要放 →、哪些框的圖已經在白板刪掉了
            guard let self else { return }
            if let host = self.host { self.clips = host.model.clips(of: self.page.id) }
            self.layoutClips()
        }
        linkView.isUserInteractionEnabled = false
        addSubview(linkView)                         // 文字方塊之間的連線（v12.13.0）：在筆跡上面、文字方塊下面
        links = page.links ?? []
        syncTexts(page.texts ?? [])
        syncTapes(page.tapes ?? [])
    }

    // MARK: 白板的區塊、圖釘（v12.7）

    private var frameBodies: [UUID: BoardFrameBodyView] = [:]
    private(set) var frameTitles: [UUID: BoardFrameTitleView] = [:]
    private var frameHandle: BoardFrameHandleView?
    private(set) var pinViews: [UUID: BoardPinView] = [:]
    private var boardFrames: [BoardFrame] = []
    private var boardPins: [BoardPin] = []
    private(set) var selectedFrameID: UUID?
    private var hiddenMarks = Set<UUID>()              // 拖曳區塊時暫時藏起來的

    /// 依資料更新區塊、圖釘（新增、更新、移除）
    func syncBoardMarks(frames: [BoardFrame], pins: [BoardPin]) {
        boardFrames = frames
        boardPins = pins
        let frameIDs = Set(frames.map { $0.id })
        for (id, view) in frameBodies where !frameIDs.contains(id) {
            view.removeFromSuperview()
            frameBodies[id] = nil
        }
        for (id, view) in frameTitles where !frameIDs.contains(id) {
            view.removeFromSuperview()
            frameTitles[id] = nil
        }
        for f in frames {
            if frameBodies[f.id] == nil {
                let body = BoardFrameBodyView()
                insertSubview(body, aboveSubview: grid)               // 在筆跡、圖片下面
                frameBodies[f.id] = body
            }
            if frameTitles[f.id] == nil {
                let title = BoardFrameTitleView(frameID: f.id)
                title.host = host
                addSubview(title)                                     // 在筆跡上面（才點得到）
                frameTitles[f.id] = title
            }
            frameBodies[f.id]?.colorIndex = f.color
            frameBodies[f.id]?.collapsed = f.isCollapsed
            frameTitles[f.id]?.configure(name: f.name, color: f.color, locked: f.isLocked, collapsed: f.isCollapsed)
        }
        let pinIDs = Set(pins.map { $0.id })
        for (id, view) in pinViews where !pinIDs.contains(id) {
            view.removeFromSuperview()
            pinViews[id] = nil
        }
        for p in pins {
            let view: BoardPinView
            if let existing = pinViews[p.id] {
                view = existing
            } else {
                view = BoardPinView(pinID: p.id)
                view.host = host
                addSubview(view)
                pinViews[p.id] = view
            }
            view.configure(p)
        }
        if let id = selectedFrameID, !frameIDs.contains(id) { selectedFrameID = nil }
        layoutBoardMarks()
    }

    /// 區塊、圖釘的位置（縮放、捲動、資料改了都要重排）。overrides：拖曳中暫時用的位置
    /// 拖曳圖釘時只移動那一顆（v12.9.7）；tip 是這個頁面視圖的座標
    func movePin(_ id: UUID, tip: CGPoint) {
        pinViews[id]?.place(tip: tip)
    }

    func layoutBoardMarks(overrides: [UUID: CGRect] = [:]) {
        let s = bounds.width / max(page.spec.width, 1)
        guard s > 0 else { return }
        for f in boardFrames {
            let r = overrides[f.id] ?? f.rect
            let body = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
            if let view = frameBodies[f.id] {
                view.frame = body
                view.selected = f.id == selectedFrameID
                view.isHidden = hiddenMarks.contains(f.id)
            }
            if let title = frameTitles[f.id] {
                let w = title.fittingWidth(max: max(body.width, 60))
                title.frame = CGRect(x: body.minX, y: body.minY - 34, width: w, height: 30)
                title.isHidden = hiddenMarks.contains(f.id)
                bringSubviewToFront(title)
            }
        }
        for p in boardPins {
            guard let view = pinViews[p.id] else { continue }
            view.place(tip: overrides[p.id].map { CGPoint(x: $0.minX * s, y: $0.minY * s) } ?? CGPoint(x: p.x * s, y: p.y * s))
            view.isHidden = p.isHidden || hiddenMarks.contains(p.id)
            bringSubviewToFront(view)
        }
        // 選取中的區塊：右下角的把手
        if let id = selectedFrameID, let f = boardFrames.first(where: { $0.id == id }), !hiddenMarks.contains(id) {
            let r = overrides[id] ?? f.rect
            if frameHandle?.frameID != id {
                frameHandle?.removeFromSuperview()
                let handle = BoardFrameHandleView(frameID: id)
                handle.host = host
                addSubview(handle)
                frameHandle = handle
            }
            frameHandle?.center = CGPoint(x: r.maxX * s, y: r.maxY * s)
            if let handle = frameHandle { bringSubviewToFront(handle) }
        } else {
            frameHandle?.removeFromSuperview()
            frameHandle = nil
        }
    }

    func setSelectedFrame(_ id: UUID?) {
        selectedFrameID = id
        layoutBoardMarks()
    }

    /// 拖曳區塊時：暫時藏起來的區塊、圖釘
    func setHiddenMarks(_ ids: Set<UUID>) {
        hiddenMarks = ids
        layoutBoardMarks()
    }

    // MARK: 紙膠帶

    private(set) var tapeViews: [UUID: TapeView] = [:]

    func syncTapes(_ tapes: [TapeBox]) {
        let ids = Set(tapes.map { $0.id })
        for (id, view) in tapeViews where !ids.contains(id) {
            view.removeFromSuperview()
            tapeViews[id] = nil
        }
        for t in tapes {
            let view: TapeView
            if let existing = tapeViews[t.id] {
                view = existing
            } else {
                view = TapeView()
                tapeViews[t.id] = view
                addSubview(view)
            }
            view.box = t
            view.revealed = host?.isTapeRevealed(t.id) ?? false
            bringSubviewToFront(view)                    // 蓋在筆跡、圖片、文字上面
        }
        layoutTapes()
        for case let editor as SelectionEditorView in subviews { bringSubviewToFront(editor) }
        for case let editor as ImageEditorView in subviews { bringSubviewToFront(editor) }
    }

    func layoutTapes() {
        let s = bounds.width / max(page.spec.width, 1)
        guard s > 0 else { return }
        for view in tapeViews.values {
            let t = view.box
            view.frame = CGRect(x: t.x * s, y: t.y * s, width: t.width * s, height: t.height * s)
        }
    }

    /// 打開、遮住的狀態（記在筆記本畫面，不存檔：每次打開筆記本都是遮住的）
    func refreshTapeStates() {
        for (id, view) in tapeViews { view.revealed = host?.isTapeRevealed(id) ?? false }
    }

    // MARK: 圖片

    private(set) var imageViews: [UUID: UIImageView] = [:]
    private var imageBoxes: [UUID: ImageBox] = [:]

    /// 依資料更新這一頁的圖片（新增、更新、移除、上下層）
    func syncImages(_ boxes: [ImageBox]) {
        let ids = Set(boxes.map { $0.id })
        for (id, view) in imageViews where !ids.contains(id) {
            view.removeFromSuperview()
            imageViews[id] = nil
            imageBoxes[id] = nil
        }
        for box in boxes {
            let view: UIImageView
            if let existing = imageViews[box.id] {
                view = existing
                // 換了圖檔（裁剪、復原裁剪；v12.15.1）：重新讀圖
                if let old = imageBoxes[box.id], old.file != box.file { view.image = Store.loadImage(box.file, pageID: page.id) }
            } else {
                view = UIImageView()
                view.isUserInteractionEnabled = false        // 不攔觸控：Pencil 照常可以在圖片上寫
                view.contentMode = .scaleToFill
                view.image = Store.loadImage(box.file, pageID: page.id)
                imageViews[box.id] = view
            }
            let layerChanged = imageBoxes[box.id]?.above != box.above || view.superview == nil
            imageBoxes[box.id] = box
            if layerChanged {
                view.removeFromSuperview()
                if box.above {
                    insertSubview(view, aboveSubview: inkOverlay ?? canvas)
                } else {
                    insertSubview(view, belowSubview: canvas)
                }
            }
            placeImage(view, box)
            view.isHidden = foldHidden.contains(box.id)      // 心智圖收起來的分支（v12.16.0）
        }
        layoutLinks()                                    // 接在圖片上的線（v12.15.1）
    }

    /// 只更新位置大小（拖曳中用，不寫檔）
    func layoutImage(_ box: ImageBox) {
        guard let view = imageViews[box.id] else { return }
        imageBoxes[box.id] = box
        placeImage(view, box)
        if links.contains(where: { $0.from == box.id || $0.to == box.id }) { layoutLinks() }   // 接在圖片上的線跟著動
    }

    /// 線的兩頭：文字方塊或圖片（卡片）的外框（頁面座標）
    private func linkEndRect(_ id: UUID) -> CGRect? {
        if let tv = textViews[id] { return tv.linkRect }
        if let b = imageBoxes[id] { return b.isMini ? b.miniRect : CGRect(x: b.x, y: b.y, width: b.width, height: b.height) }
        return nil
    }

    private func placeImage(_ view: UIImageView, _ box: ImageBox) {
        let s = bounds.width / max(page.spec.width, 1)
        guard s > 0 else { return }
        view.transform = .identity
        let badgeTag = 4242
        if box.isMini {
            // 縮成小圖（v12.8.3）：圓角、白框、右下角一個放大的小記號；點了彈出大圖
            let r = box.miniRect
            view.bounds = CGRect(x: 0, y: 0, width: r.width * s, height: r.height * s)
            view.center = CGPoint(x: r.midX * s, y: r.midY * s)
            view.layer.cornerRadius = min(8, r.width * s * 0.15)
            view.layer.borderWidth = 1.5
            view.layer.borderColor = UIColor(white: 1, alpha: 0.85).cgColor
            view.clipsToBounds = true
            let badge = (view.viewWithTag(badgeTag) as? UIImageView) ?? UIImageView()
            if badge.superview == nil {
                badge.tag = badgeTag
                badge.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                badge.tintColor = UIColor.white
                badge.backgroundColor = UIColor(white: 0, alpha: 0.45)
                badge.layer.cornerRadius = 8
                badge.clipsToBounds = true
                view.addSubview(badge)
            }
            let side = min(16, view.bounds.width * 0.4)
            badge.frame = CGRect(x: view.bounds.width - side - 2, y: view.bounds.height - side - 2, width: side, height: side)
            badge.layer.cornerRadius = side / 2
            return
        }
        view.viewWithTag(badgeTag)?.removeFromSuperview()
        view.layer.cornerRadius = 0
        view.layer.borderWidth = 0
        view.clipsToBounds = false
        view.bounds = CGRect(x: 0, y: 0, width: box.width * s, height: box.height * s)
        view.center = CGPoint(x: (box.x + box.width / 2) * s, y: (box.y + box.height / 2) * s)
        view.transform = CGAffineTransform(rotationAngle: box.rotation)
    }

    /// 變更範本：換紙張或封面
    func updatePaper(_ newPage: NotePage) {
        page.paper = newPage.paper
        page.cover = newPage.cover
        grid.paper = page.paperStyle
        grid.cover = page.cover
        if isFlat { backgroundColor = PaperRenderer.background(page.paperStyle) }   // 白板換底色（v12.8）
    }

    // MARK: 文字方塊

    private(set) var textViews: [UUID: TextBoxView] = [:]

    /// 依資料更新這一頁的文字方塊（新增、更新、移除）
    /// 便利貼的小畫布跟著頁面換筆、停用（v12.15.12）
    func syncStickyInk() {
        for view in textViews.values where view.box.sticky == true {
            view.inkTool = canvas.tool
            view.inkEnabled = canvas.drawingGestureRecognizer.isEnabled
        }
    }

    func syncTexts(_ texts: [TextBox]) {
        let ids = Set(texts.map { $0.id })
        for (id, view) in textViews where !ids.contains(id) {
            view.removeFromSuperview()
            textViews[id] = nil
        }
        let s = bounds.width / max(page.spec.width, 1)
        linkLayoutPaused = true
        for t in texts {
            if let view = textViews[t.id] {
                if view.box != t { view.update(t) }
            } else {
                let view = TextBoxView(box: t, pageID: page.id, pageWidth: page.spec.width,
                                       pageHeight: page.spec.height)
                view.wrapWidth = textWrapWidth(page.spec)            // 白板：換行的寬度不照整張白板算
                view.onRelayout = { [weak self] in self?.layoutLinks() }
                view.inkTool = canvas.tool                            // 便利貼的手寫跟頁面用同一支筆（v12.15.12）
                view.inkEnabled = canvas.drawingGestureRecognizer.isEnabled
                view.onInk = { [weak self, weak view] _ in
                    guard let self = self, let view = view else { return }
                    self.host?.stickyInkChanged(view)
                }
                if let editor = subviews.first(where: { $0 is SelectionEditorView }) {
                    insertSubview(view, belowSubview: editor)
                } else {
                    addSubview(view)
                }
                textViews[t.id] = view
                if s > 0 { view.apply(scale: s) }
            }
        }
        linkLayoutPaused = false
        markLinked()
        applyFolds()                                           // 心智圖收起來的分支（v12.16.0）
    }

    // MARK: 剪去白板的範圍（v12.15.1）

    private let clipView = UIView()
    private var clipLayers: [UUID: CAShapeLayer] = [:]
    private(set) var clips: [PageClip] = []
    private(set) var selectedClipID: UUID?               // 點了的框（v12.15.3：點一下才出現 → 和顏色）
    private var clipButtons: [UIButton] = []
    private var clipButtonsFor: PageClip?                // 按鈕是為哪個框做的（一樣的話只移位置，不重做：選單開著時不會被關掉）
    static let clipButtonTag = 4343

    /// 框可以選的顏色（nil＝灰色）
    static let clipColors: [(String, UInt32?)] = [("灰色", nil), ("紅色", 0xE0584F), ("橘色", 0xEE9A3A), ("黃色", 0xE8C43A),
                                                   ("綠色", 0x5BB36A), ("藍色", 0x4A8FE0), ("紫色", 0x9B6BD6)]

    static func clipColor(_ rgb: UInt32?) -> UIColor {
        guard let rgb else { return UIColor.systemGray }
        return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    func syncClips(_ list: [PageClip]) {
        clips = list
        if let id = selectedClipID, !list.contains(where: { $0.id == id }) { selectedClipID = nil }
        layoutClips()
    }

    /// 頁面座標的這一點落在哪個框裡（後畫的在上面）
    func clip(atPagePoint q: CGPoint) -> PageClip? {
        clips.last(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(q) })
    }

    func selectClip(_ id: UUID?) {
        guard selectedClipID != id else { return }
        selectedClipID = id
        layoutClips()
    }

    private func layoutClips() {
        let s = bounds.width / max(page.spec.width, 1)
        guard s > 0 else { return }
        clipView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var alive = Set<UUID>()
        for clip in clips {
            alive.insert(clip.id)
            let layer: CAShapeLayer
            if let existing = clipLayers[clip.id] {
                layer = existing
            } else {
                layer = CAShapeLayer()
                layer.lineDashPattern = [6, 4]
                clipView.layer.addSublayer(layer)
                clipLayers[clip.id] = layer
            }
            let color = Self.clipColor(clip.rgb)
            let selected = clip.id == selectedClipID
            let r = clip.rect
            layer.path = UIBezierPath(rect: CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)).cgPath
            layer.strokeColor = color.cgColor
            layer.fillColor = color.withAlphaComponent(selected ? 0.16 : 0.08).cgColor
            layer.lineWidth = selected ? 2.5 : 1.5
        }
        for (id, layer) in clipLayers where !alive.contains(id) {
            layer.removeFromSuperlayer()
            clipLayers[id] = nil
        }
        CATransaction.commit()
        // 選了的框：右下角 → （在白板的浮動視窗裡：白板跳到那張圖）和 ● 顏色（v12.15.3，使用者要求：點了框才出現）
        let chosen = selectedClipID.flatMap { id in clips.first(where: { $0.id == id }) }
        if chosen == nil || chosen != clipButtonsFor {
            for button in clipButtons { button.removeFromSuperview() }
            clipButtons = []
            clipButtonsFor = nil
        }
        guard let clip = chosen else { return }
        let id = clip.id
        let r = clip.rect
        var x = r.maxX * s - 30
        let y = r.maxY * s - 30
        if !clipButtons.isEmpty {
            for button in clipButtons {
                button.frame = CGRect(x: x, y: y, width: 26, height: 26)
                bringSubviewToFront(button)
                x -= 32
            }
            return
        }
        clipButtonsFor = clip
        if host?.model.revealOnBoard != nil, let imageID = clip.imageID {
            let button = clipButton("arrow.right")
            button.addAction(UIAction { [weak self] _ in
                self?.selectClip(nil)
                self?.host?.model.revealOnBoard?(imageID)
            }, for: .touchUpInside)
            button.frame = CGRect(x: x, y: y, width: 26, height: 26)
            x -= 32
        }
        let paint = clipButton("paintpalette.fill")
        let pageID = page.id
        var items: [UIMenuElement] = Self.clipColors.map { name, rgb in
            UIAction(title: name, image: UIImage(systemName: "circle.fill")?
                        .withTintColor(Self.clipColor(rgb), renderingMode: .alwaysOriginal),
                     state: clip.rgb == rgb ? .on : .off) { [weak self] _ in
                self?.host?.setClipColor(id, rgb: rgb, pageID: pageID)
            }
        }
        items.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "拿掉這個框", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.host?.removeClipMark(id, pageID: pageID)
            }
        ]))
        paint.menu = UIMenu(children: items)
        paint.showsMenuAsPrimaryAction = true
        paint.frame = CGRect(x: x, y: y, width: 26, height: 26)
    }

    private func clipButton(_ symbol: String) -> UIButton {
        let button = UIButton(type: .system)
        button.tag = Self.clipButtonTag
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)),
                        for: .normal)
        button.tintColor = UIColor.white
        button.backgroundColor = UIColor(white: 0.35, alpha: 0.92)
        button.layer.cornerRadius = 13
        addSubview(button)
        bringSubviewToFront(button)
        clipButtons.append(button)
        return button
    }

    // MARK: 文字方塊之間的連線（v12.13.0；TextLinks.swift）

    private let linkView = UIView()
    private(set) var links: [BoxLink] = []
    private var linkLayers: [UUID: CAShapeLayer] = [:]
    private let linkPreview = CAShapeLayer()
    private var linkLayoutPaused = false             // 一次改很多個方塊時先不要每個都重畫
    private var linkPaths: [UUID: CGPath] = [:]      // 每一條線目前的樣子（這個視圖的座標；判斷點到哪一條用）
    var selectedLink: UUID? {                        // 選取中的線：外面一圈藍色的光
        didSet { if selectedLink != oldValue { layoutLinks() } }
    }

    /// 點到哪一條線（p：這個視圖的座標）；線很細，旁邊 14 點以內都算
    func linkHit(at p: CGPoint) -> BoxLink? {
        for link in links.reversed() {
            guard let path = linkPaths[link.id] else { continue }
            let fat = path.copy(strokingWithWidth: 28, lineCap: .round, lineJoin: .round, miterLimit: 2)
            if fat.contains(p) { return link }
        }
        return nil
    }

    func syncLinks(_ list: [BoxLink]) {
        links = list
        markLinked()
        applyFolds()
    }

    // MARK: 心智圖的折疊（v12.16.0；TextLinks.swift 的 MindFold）
    // 收起來的方塊旁邊：橘色圓圈寫藏了幾個，點了展開。選取一個有連線的方塊時，那一整棵樹有分支的方塊旁邊多一個「−」，點了收起來。
    // 兩種圓圈都可以長按：只展開到第 1、2、3 層／全部展開

    private(set) var foldHidden: Set<UUID> = []
    var shownLinkCount: Int { linkLayers.count }             // 自動測試用：畫出來幾條線
    /// 要顯示「−」的方塊（選取中的方塊連著的那一整棵樹；NotebookView 設）
    var foldHandles: Set<UUID> = [] {
        didSet { if foldHandles != oldValue { layoutFoldButtons() } }
    }
    /// 選取中的那一個方塊（它四邊有拉新方塊的灰點：「−」要讓開，放在灰點再外面；v12.16.1）
    var foldActive: UUID? {
        didSet { if foldActive != oldValue { layoutFoldButtons() } }
    }
    private var foldButtons: [UUID: UIButton] = [:]
    static let foldButtonTag = 4344

    /// 重新算哪些要藏起來
    func applyFolds() {
        let texts = textViews.values.map { $0.box }
        let hidden = MindFold.hidden(texts: texts, links: links)
        foldHidden = hidden
        for (id, view) in textViews { view.isHidden = hidden.contains(id) }
        for (id, view) in imageViews { view.isHidden = hidden.contains(id) }
        layoutLinks()
    }

    private func layoutFoldButtons() {
        let s = bounds.width / max(page.spec.width, 1)
        let kids = MindFold.children(links.filter { linkEndRect($0.from) != nil && linkEndRect($0.to) != nil })
        var alive = Set<UUID>()
        if s > 0 {
            for (id, view) in textViews where !foldHidden.contains(id) {
                guard let first = links.first(where: { $0.from == id && kids[id]?.contains($0.to) == true }),
                      let rect = linkEndRect(id) else { continue }
                let folded = view.box.branchFolded == true
                guard folded || foldHandles.contains(id) else { continue }
                let count = folded ? MindFold.descendants(of: id, children: kids).count : 0
                let button = foldButton(id)
                style(button, folded: folded, count: count)
                // 放在第一條往下的線出去的那一邊，再往外一點。
                // v12.16.1（使用者：「−」不好點，很容易變成在拉線）：以前剛好疊在選取方塊四邊的灰點上（拉新方塊用的），
                // 一按就變成拉線。選取中的方塊：放到灰點再外面（灰點在邊外 20 點、摸得到的範圍半徑 16）；
                // 其他方塊沒有灰點，放近一點。圓圈也加大（30 點，摸得到的範圍再外擴 8 點）
                let r = rect.applying(CGAffineTransform(scaleX: s, y: s))
                let a = BoxLinkPath.anchor(r, side: first.fromSide)
                let side: CGFloat = 30
                let out: CGFloat = id == foldActive ? 20 + 16 + 4 + side / 2 : side / 2 + 4
                let d: CGPoint = [CGPoint(x: 0, y: -out), CGPoint(x: out, y: 0), CGPoint(x: 0, y: out), CGPoint(x: -out, y: 0)][max(0, min(3, first.fromSide))]
                let width: CGFloat = folded ? max(side, 20 + CGFloat(String(count).count) * 9) : side
                button.frame = CGRect(x: a.x + d.x - width / 2, y: a.y + d.y - side / 2, width: width, height: side)
                button.layer.cornerRadius = side / 2
                bringSubviewToFront(button)
                alive.insert(id)
            }
        }
        for (id, button) in foldButtons where !alive.contains(id) {
            button.removeFromSuperview()
            foldButtons[id] = nil
        }
    }

    private func foldButton(_ id: UUID) -> UIButton {
        if let b = foldButtons[id] { return b }
        let b = FoldButton(type: .custom)
        b.tag = Self.foldButtonTag
        b.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        b.layer.borderWidth = 1.5
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.18
        b.layer.shadowRadius = 2
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        let pageID = page.id
        b.addAction(UIAction { [weak self] _ in self?.host?.toggleBranch(id, pageID: pageID) }, for: .touchUpInside)
        let levels: [(String, Int?)] = [("只展開到第 1 層", 1), ("只展開到第 2 層", 2), ("只展開到第 3 層", 3), ("全部展開", nil)]
        b.menu = UIMenu(title: "這一支往下", children: levels.map { item in
            UIAction(title: item.0, image: UIImage(systemName: item.1 == nil ? "arrow.up.left.and.arrow.down.right" : "list.bullet.indent")) { [weak self] _ in
                self?.host?.expandBranch(id, pageID: pageID, level: item.1)
            }
        })
        b.showsMenuAsPrimaryAction = false                     // 點一下：收起／展開；長按：選單
        addSubview(b)
        foldButtons[id] = b
        return b
    }

    private func style(_ b: UIButton, folded: Bool, count: Int) {
        if folded {
            b.backgroundColor = UIColor.systemOrange
            b.layer.borderColor = UIColor.white.cgColor
            b.setTitle("\(count)", for: .normal)
            b.setTitleColor(.white, for: .normal)
            b.setImage(nil, for: .normal)
        } else {
            b.backgroundColor = UIColor.systemBackground
            b.layer.borderColor = UIColor.systemGray3.cgColor
            b.setTitle(nil, for: .normal)
            b.setImage(UIImage(systemName: "minus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)), for: .normal)
            b.tintColor = UIColor.secondaryLabel
        }
    }

    /// 告訴每個文字方塊有沒有線接著它（有的話，空的也留著、顯示「輸入文字」）
    private func markLinked() {
        var ends = Set<UUID>()
        for link in links where textViews[link.from] != nil && textViews[link.to] != nil {
            ends.insert(link.from)
            ends.insert(link.to)
        }
        for (id, view) in textViews { view.linked = ends.contains(id) }
    }

    private func styleLinkLayer(_ shape: CAShapeLayer, scale s: CGFloat) {
        shape.fillColor = nil
        shape.strokeColor = UIColor(white: 0.62, alpha: 1).cgColor
        shape.lineWidth = max(2 * s, 1)
        shape.lineJoin = .round
        shape.lineCap = .round
    }

    /// 每一條線各自一個小圖層（白板很大，不要用一個跟白板一樣大的圖層）
    func layoutLinks() {
        if linkLayoutPaused { return }
        if links.isEmpty && linkLayers.isEmpty { return }
        let s = bounds.width / max(page.spec.width, 1)
        guard s > 0 else { return }
        linkView.frame = bounds
        var alive = Set<UUID>()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for link in links {
            if foldHidden.contains(link.from) || foldHidden.contains(link.to) { continue }   // 收起來的分支（v12.16.0）
            guard let a0 = linkEndRect(link.from), let b0 = linkEndRect(link.to) else { continue }
            let ra = a0.applying(CGAffineTransform(scaleX: s, y: s))
            let rb = b0.applying(CGAffineTransform(scaleX: s, y: s))
            let path = BoxLinkPath.path(from: BoxLinkPath.anchor(ra, side: link.fromSide), fromSide: link.fromSide,
                                        to: BoxLinkPath.anchor(rb, side: link.toSide), toSide: link.toSide, scale: s,
                                        route: link.route ?? 0, arrow: link.arrow ?? 0)
            linkPaths[link.id] = path
            let shape: CAShapeLayer
            if let existing = linkLayers[link.id] {
                shape = existing
            } else {
                shape = CAShapeLayer()
                linkView.layer.addSublayer(shape)
                linkLayers[link.id] = shape
            }
            styleLinkLayer(shape, scale: s)
            shape.strokeColor = BoxLinkPath.color(link).cgColor
            shape.lineWidth = max(CGFloat(link.width ?? 2) * s, 1)
            shape.lineDashPattern = link.dash == true ? [NSNumber(value: Double(7 * s)), NSNumber(value: Double(6 * s))] : nil
            let chosen = link.id == selectedLink
            shape.shadowColor = UIColor.systemBlue.cgColor
            shape.shadowOffset = CGSize.zero
            shape.shadowRadius = 5
            shape.shadowOpacity = chosen ? 1 : 0
            let box = path.boundingBoxOfPath.insetBy(dx: -6 * s - 8, dy: -6 * s - 8)
            shape.frame = box
            var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
            shape.path = path.copy(using: &shift)
            alive.insert(link.id)
        }
        for (id, shape) in linkLayers where !alive.contains(id) {
            shape.removeFromSuperlayer()
            linkLayers[id] = nil
            linkPaths[id] = nil
        }
        CATransaction.commit()
        layoutFoldButtons()
    }

    /// 從點往外拉的時候：先畫出線（跟放開後會多出來的方塊的位置）。座標都是頁面座標
    func showLinkPreview(from start: CGPoint, fromSide: Int, to end: CGPoint, toSide: Int, ghost: CGRect?) {
        let s = bounds.width / max(page.spec.width, 1)
        guard s > 0 else { return }
        linkView.frame = bounds
        if linkPreview.superlayer == nil { linkView.layer.addSublayer(linkPreview) }
        let a = CGPoint(x: start.x * s, y: start.y * s)
        let b = CGPoint(x: end.x * s, y: end.y * s)
        let path = CGMutablePath()
        path.addPath(BoxLinkPath.path(from: a, fromSide: fromSide, to: b, toSide: toSide, scale: s))
        if let ghost = ghost {
            let r = ghost.applying(CGAffineTransform(scaleX: s, y: s))
            path.addPath(UIBezierPath(roundedRect: r, cornerRadius: 9 * s).cgPath)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        styleLinkLayer(linkPreview, scale: s)
        linkPreview.strokeColor = UIColor.systemBlue.cgColor
        let box = path.boundingBoxOfPath.insetBy(dx: -4 * s - 2, dy: -4 * s - 2)
        linkPreview.frame = box
        var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        linkPreview.path = path.copy(using: &shift)
        CATransaction.commit()
    }

    func hideLinkPreview() {
        linkPreview.removeFromSuperlayer()
        linkPreview.path = nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 依縮放倍率排版；筆跡維持頁面座標，所以縮放後依然清晰
    // MARK: 選取 PDF 的文字（v12.15.11）
    // 選取文字的時候，課本那一層換成系統的 PDF 視圖（只有這一頁），長按文字就能選、拷貝；筆跡還是畫在它上面，
    // 畫布暫時不收觸控，手指、Pencil 都交給底下的 PDF
    private var textLayer: PDFView?

    func setTextLayer(_ document: PDFDocument?) {
        textLayer?.removeFromSuperview()
        textLayer = nil
        canvas.isUserInteractionEnabled = document == nil
        guard let document = document else { return }
        let v = PDFView(frame: bounds)
        v.displayMode = .singlePage
        v.displaysPageBreaks = false
        v.pageShadowsEnabled = false
        v.backgroundColor = .white
        v.autoScales = true
        v.document = document
        v.minScaleFactor = v.scaleFactorForSizeToFit
        v.maxScaleFactor = v.scaleFactorForSizeToFit
        for case let scroll as UIScrollView in v.subviews {
            scroll.isScrollEnabled = false                   // 捲動、縮放還是交給筆記本自己
            scroll.pinchGestureRecognizer?.isEnabled = false
            scroll.bouncesZoom = false
        }
        insertSubview(v, aboveSubview: pdfView)
        textLayer = v
    }

    // MARK: 頁面反相（v12.15.11，使用者：黑轉白，有一個按鈕隨時切換）
    // 頁面最上面蓋一層白色、用「差值」混合：底下的課本、筆跡、文字、圖片全部反相（白底黑字 → 黑底白字）。
    // 只是顯示，存檔、匯出、縮圖都不變。選取框、按鈕放在這一層上面，不跟著反相
    // v12.16.0（使用者：反相要比較好看的顏色）：純黑底配純白字太刺眼，改成深灰底、柔和的米白字。
    // 疊三層：① 白色「差值」＝反相；② 灰色「濾色」把黑抬成深灰；③ 米白「色彩增值」把白壓暗一點、帶一點暖色。
    // 底色約 #1F1F21、字約 #E6E1D8（像閱讀 App 的夜間模式）
    private var invertViews: [UIView] = []
    private var invertView: UIView? { invertViews.first }

    func setInverted(_ on: Bool) {
        if on, invertViews.isEmpty {
            let layers: [(UIColor, String)] = [
                (.white, "differenceBlendMode"),
                (UIColor(red: 0.125, green: 0.125, blue: 0.135, alpha: 1), "screenBlendMode"),
                (UIColor(red: 0.90, green: 0.88, blue: 0.84, alpha: 1), "multiplyBlendMode"),
            ]
            for (color, filter) in layers {
                let v = UIView(frame: bounds)
                v.backgroundColor = color
                v.isUserInteractionEnabled = false
                v.layer.compositingFilter = filter
                addSubview(v)
                invertViews.append(v)
            }
            keepInvertOnTop()
        } else if !on, !invertViews.isEmpty {
            for v in invertViews { v.removeFromSuperview() }
            invertViews = []
        }
    }

    /// 反相那一層放在內容上面、選取框和按鈕下面
    func keepInvertOnTop() {
        guard !invertViews.isEmpty else { return }
        for v in invertViews {                               // 照順序：反相 → 抬黑 → 壓白
            v.frame = bounds
            bringSubviewToFront(v)
        }
        for sub in subviews where sub is SelectionEditorView || sub is ImageEditorView || sub.tag == Self.clipButtonTag {
            bringSubviewToFront(sub)
        }
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        if invertView != nil, !invertViews.contains(where: { $0 === subview }), !(subview is SelectionEditorView), !(subview is ImageEditorView),
           subview.tag != Self.clipButtonTag {
            keepInvertOnTop()
        }
    }

    func apply(scale s: CGFloat) {
        if page.pdf != nil { pdfView.frame = bounds }
        for v in invertViews { v.frame = bounds }
        if let t = textLayer, t.frame != bounds {
            t.frame = bounds
            t.autoScales = true
            t.minScaleFactor = t.scaleFactorForSizeToFit
            t.maxScaleFactor = t.scaleFactorForSizeToFit
        }
        layoutCanvasWindow(scale: s)
        if !isFlat { layer.shadowPath = UIBezierPath(rect: bounds).cgPath }
        linkLayoutPaused = true
        for view in textViews.values { view.apply(scale: s) }
        linkLayoutPaused = false
        layoutLinks()
        if !clips.isEmpty { layoutClips() }
        for (id, view) in imageViews {
            if let box = imageBoxes[id] { placeImage(view, box) }
        }
        layoutTapes()
        layoutBoardMarks()
        host?.positionTextBar()
        for case let editor as SelectionEditorView in subviews {
            editor.frame = bounds
            editor.setNeedsLayout()
        }
        // 圖片的選取框也要跟著重排（v12.1：以前放大縮小時，框會留在原本的位置）
        for case let editor as ImageEditorView in subviews {
            editor.frame = bounds
            editor.setNeedsLayout()
        }
    }

    /// 畫布（和格線）放在哪裡（v12.5）。一般頁：蓋住整頁。
    /// 白板：只蓋住 canvasWindow 那一塊；畫布的捲動位置等於它在頁面上的位置，所以畫布裡的座標跟整頁時一模一樣
    func layoutCanvasWindow(scale s: CGFloat) {
        let full = bounds
        var area = full
        if isFlat {
            if let w = canvasWindow {
                area = CGRect(x: w.minX * s, y: w.minY * s, width: w.width * s, height: w.height * s).intersection(full)
            } else {
                area = CGRect(x: 0, y: 0, width: 1, height: 1)         // 還不知道畫面在哪：先不畫，等筆記本畫面告訴我
            }
            if area.isNull || area.width < 1 || area.height < 1 { area = CGRect(x: 0, y: 0, width: 1, height: 1) }
            // 保險：畫布最多是畫面的 2.6 倍大（放大到一半、位置還沒更新時，不會一下子變得很大）
            let screen = host?.bounds.size ?? CGSize(width: 1200, height: 900)
            let maxW = max(screen.width, 300) * 2.6
            let maxH = max(screen.height, 300) * 2.6
            if area.width > maxW || area.height > maxH {
                let w = min(area.width, maxW)
                let h = min(area.height, maxH)
                area = CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
            }
            area = area.integral
        }
        placeCanvas(canvas, in: area, full: full, scale: s)
        if let overlay = inkOverlay { placeCanvas(overlay, in: area, full: full, scale: s) }
        layoutPinchInk()
        if isFlat {
            // 格線：對齊格子（格線的起點跟整頁時一樣）
            let step = max(PaperRenderer.gridUnit * s, 0.5)
            let gx = floor(area.minX / step) * step
            let gy = floor(area.minY / step) * step
            grid.stepScale = s
            grid.frame = CGRect(x: gx, y: gy, width: area.maxX - gx, height: area.maxY - gy)
        } else {
            grid.stepScale = nil
            grid.frame = full
        }
    }

    // MARK: 白板縮放中（v12.8.3）：畫布外面的筆跡用一張低解析度的圖補；格線先鋪大一點

    private var pinchInkView: UIImageView?
    private var pinchInkRegion: CGRect?

    /// 筆跡圖放在畫布底下（頁面座標的 region）；畫布那一塊在圖上已經是空的（畫布自己畫的比較清楚）
    func showPinchInk(_ image: UIImage, region: CGRect) {
        let v = pinchInkView ?? UIImageView()
        v.isUserInteractionEnabled = false
        v.contentMode = .scaleToFill
        v.image = image
        v.layer.removeAllAnimations()
        v.alpha = 1
        if v.superview == nil { insertSubview(v, belowSubview: canvas) }
        pinchInkView = v
        pinchInkRegion = region
        layoutPinchInk()
    }

    func layoutPinchInk() {
        guard let v = pinchInkView, v.superview != nil, let region = pinchInkRegion else { return }
        let s = bounds.width / max(page.spec.width, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        v.frame = CGRect(x: region.minX * s, y: region.minY * s, width: region.width * s, height: region.height * s)
        // v12.8.7：以前用遮罩把畫布那一塊挖空，遮罩蓋在幾萬點大的圖上，每一格都要另外算一次，縮放很卡；
        // 改成畫圖時就把那一塊清掉（見 NotebookView.startBoardPinch）
        CATransaction.commit()
    }

    /// 放手後過一下再淡出拿掉（等畫布換好位置、畫好）
    func hidePinchInk(after delay: Double) {
        guard let v = pinchInkView else { return }
        UIView.animate(withDuration: 0.25, delay: delay, options: [], animations: {
            v.alpha = 0
        }, completion: { _ in
            if v.alpha == 0 { v.removeFromSuperview() }
        })
    }

    /// 縮放中：格線先鋪到 area（頁面座標）那麼大，縮小時外圍也有格線
    func pinchGrid(area: CGRect) {
        guard isFlat else { return }
        let s = bounds.width / max(page.spec.width, 1)
        let r = CGRect(x: area.minX * s, y: area.minY * s, width: area.width * s, height: area.height * s).intersection(bounds)
        guard !r.isNull, r.width > 1, r.height > 1 else { return }
        let step = max(PaperRenderer.gridUnit * s, 0.5)
        let gx = floor(r.minX / step) * step
        let gy = floor(r.minY / step) * step
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.frame = CGRect(x: gx, y: gy, width: r.maxX - gx, height: r.maxY - gy)
        grid.layoutIfNeeded()
        CATransaction.commit()
    }

    /// 縮放中：畫面上的格子變小就跟著淡出（跟放手後的規則一樣：小於 9 點變淡、小於 5 點不畫）
    func pinchGridFade(_ f: CGFloat) {
        guard isFlat else { return }
        let step = PaperRenderer.gridUnit * bounds.width / max(page.spec.width, 1)
        let base = min(max((step - 5) / 4, 0), 1)
        let now = min(max((step * f - 5) / 4, 0), 1)
        grid.alpha = base > 0.01 ? min(now / base, 1) : 0
    }

    func endPinchGrid() {
        grid.alpha = 1
    }

    /// 一張畫布放在 area（這一頁的座標）；畫布裡的內容大小是整頁，捲動位置對到 area 的左上角
    private func placeCanvas(_ view: PKCanvasView, in area: CGRect, full: CGRect, scale s: CGFloat) {
        if abs(view.zoomScale - s) > 0.0001 || view.minimumZoomScale != s || view.maximumZoomScale != s {
            view.minimumZoomScale = s
            view.maximumZoomScale = s
            view.zoomScale = s
        }
        view.pinchGestureRecognizer?.isEnabled = false
        view.frame = area
        view.contentSize = full.size
        view.contentOffset = area.origin
    }

    /// PDF 背景依目前大小重畫（放大後才清楚）；一般頁不用做事
    func refreshBackground() {
        guard let pdf = page.pdf, bounds.width > 0 else { return }
        let screenScale = window?.screen.scale ?? 2
        let wanted = min(bounds.width * screenScale, 2400)
        guard abs(wanted - renderedPixelWidth) > renderedPixelWidth * 0.25 || renderedPixelWidth == 0 else { return }
        renderedPixelWidth = wanted
        pdfView.image = PDFStore.image(pdf, aspect: page.spec.height / max(page.spec.width, 1), pixelWidth: wanted)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        host?.dismissShapeEditor()                     // 開始寫下一筆：結束調整
        host?.endTextSelection()
        // v12.15.6（使用者：寫完很久的一筆，寫下一筆後按上一步，那一筆跟著不見）：
        // 上一次下筆如果沒收到「放開」（手勢被中斷：長按螢光筆選取、換畫布、畫到一半被其他手勢搶走…），
        // toolActive 會一直是 true，那時寫的筆跡只記成「下筆中的變化」、沒有登記復原，
        // 結果跟下一筆合成同一步，上一步就連它一起退掉。開始下一筆之前，沒登記到的變化先自己登記一步
        let unrecorded = changedDuringTool || canvasView.drawing.strokes.count != committedDrawing.strokes.count
        if unrecorded && !silent {
            host?.recordUndo(pageID: page.id, old: committedDrawing)
            committedDrawing = canvasView.drawing
        }
        changedDuringTool = false
        inkBase = canvasView.tool is PKInkingTool ? canvasView.drawing : nil
        strokeCountAtBegin = canvasView.drawing.strokes.count
        toolUses += 1
        toolActive = true
        changedDuringTool = false
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        let usedMarker = (canvasView.tool as? PKInkingTool).map { isHighlighterInk($0.inkType, $0.color) } ?? false
        toolActive = false
        if changedDuringTool {                         // 這一次下筆的所有變化合成一步
            changedDuringTool = false
            host?.recordUndo(pageID: page.id, old: committedDrawing)
            committedDrawing = canvasView.drawing
        }
        let before = strokeCountAtBegin
        let usedInk = canvasView.tool is PKInkingTool
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)   // 等這一筆存進畫布
            if usedMarker {
                self?.host?.finishMarkerStroke(on: self, countBefore: before)
            } else if usedInk {
                self?.host?.finishPenStroke(on: self, countBefore: before)       // 停住過：換成標準圖形；虛線筆：切段
            }
        }
    }

    /// 筆跡一變就登記一步復原（不管是寫字、擦掉，還是選取框、變形、貼上造成的）
    /// 最上層只放手寫（不含螢光筆）
    private func syncOverlay() {
        guard let overlay = inkOverlay else { return }
        overlay.drawing = PKDrawing(strokes: canvas.drawing.strokes.filter { !isHighlighter($0) })
    }

    /// 一筆的身分：位置、點數、下筆時間（PKStroke 不能直接比）
    private static func strokeKey(_ stroke: PKStroke) -> String {
        let b = stroke.renderBounds
        return "\(b.minX),\(b.minY),\(b.width),\(b.height),\(stroke.path.count),\(stroke.path.creationDate.timeIntervalSince1970)"
    }

    /// v12.15.7（使用者：寫下一筆，之前寫好的筆跡會不見，按上一步也救不回來）：
    /// 用筆寫字只會「多」筆跡，不會少。寫完這一筆如果畫布上比開始寫時少了舊的筆跡，就把少掉的放回去
    private func restoreDroppedStrokes(_ canvasView: PKCanvasView) {
        guard let base = inkBase, canvasView.tool is PKInkingTool else { return }
        let now = canvasView.drawing
        guard now.strokes.count < base.strokes.count + 1 else { return }
        let nowKeys = Set(now.strokes.map(Self.strokeKey))
        let missing = base.strokes.filter { !nowKeys.contains(Self.strokeKey($0)) }
        guard !missing.isEmpty else { return }
        let baseKeys = Set(base.strokes.map(Self.strokeKey))
        var fixed = base
        fixed.strokes.append(contentsOf: now.strokes.filter { !baseKeys.contains(Self.strokeKey($0)) })
        silent = true
        canvasView.drawing = fixed
        silent = false
        syncOverlay()
        host?.showMessage("bandage", "剛剛有 \(missing.count) 筆舊的筆跡被吃掉，已經補回來了")
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if !silent { restoreDroppedStrokes(canvasView) }
        syncOverlay()
        scheduleSave()
        guard !silent else { return }
        if toolActive {
            // 橡皮擦擦的過程會一直改筆跡：等放開再合成一步。
            // v12.15.6（使用者：按上一步會連其他筆跡一起消失）：寫字很快時，上一筆要等一下才真的放進畫布，
            // 那時下一筆已經開始了，以前就跟下一筆合成同一步（上一步一次退掉兩筆以上）。
            // 筆、螢光筆這類寫字的工具，下筆中途進來的變化就是上一筆：馬上自己登記一步
            if canvasView.tool is PKInkingTool {
                host?.recordUndo(pageID: page.id, old: committedDrawing)
                committedDrawing = canvasView.drawing
                return
            }
            changedDuringTool = true
            return
        }
        host?.recordUndo(pageID: page.id, old: committedDrawing)
        committedDrawing = canvasView.drawing
    }

    // 選取框可能超出頁面：超出的部分也要能點
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        return subviews.contains { v in
            (v is SelectionEditorView || v is ImageEditorView) && v.point(inside: convert(point, to: v), with: event)
        }
    }

    /// 程式改筆跡並登記一步復原；undoTo 可以指定復原要回到哪個狀態
    func setDrawingRecorded(_ drawing: PKDrawing, undoTo old: PKDrawing? = nil) {
        let previous = old ?? committedDrawing
        silent = true
        canvas.drawing = drawing
        silent = false
        committedDrawing = drawing
        toolActive = false                             // 正在畫的那一筆被中斷了（例如變形）
        changedDuringTool = false
        host?.recordUndo(pageID: page.id, old: previous)
    }

    /// 換掉筆跡但不登記復原（拖曳中途、整理順序、復原本身）。
    /// updateBaseline = true：之後的復原以這個狀態為準
    func replaceSilently(_ drawing: PKDrawing, updateBaseline: Bool) {
        silent = true
        canvas.drawing = drawing
        silent = false
        if updateBaseline {
            committedDrawing = drawing
            changedDuringTool = false
        }
    }

    // 停筆 0.6 秒後自動存檔
    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        guard dirty else { return }
        dirty = false
        let drawing = canvas.drawing
        if drawing.strokes.count > 1500 {
            Store.saveDrawingLater(drawing, pageID: page.id)   // v12.10.1：筆跡多（存一次要很久）就丟到背景存，寫字不會卡
        } else {
            Store.saveDrawing(drawing, pageID: page.id)
        }
        ActivityLog.touch(pageID: page.id)                     // 修改紀錄（v12.9.5）
    }

    func discard() {
        saveTask?.cancel()
        dirty = false
    }
}

/// 深色方格：每條線是一個細長的圖層，放大後線條粗細不變、也不吃記憶體
// MARK: - 文字方塊

/// 一條紙膠帶：遮住時是灰色，打開時只剩虛線框
final class TapeView: UIView {
    var box = TapeBox()
    var revealed = false { didSet { updateLook() } }
    private let border = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false                   // 點擊由筆記本判斷
        layer.cornerRadius = 4
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 2
        border.fillColor = nil
        border.strokeColor = UIColor(white: 0.55, alpha: 1).cgColor
        border.lineWidth = 1.5
        border.lineDashPattern = [6, 4]
        layer.addSublayer(border)
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        border.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 4).cgPath
    }

    private func updateLook() {
        backgroundColor = revealed ? UIColor.clear : UIColor(red: 0.66, green: 0.68, blue: 0.71, alpha: 1)
        border.isHidden = !revealed
        layer.shadowOpacity = revealed ? 0 : 0.18
    }
}


/// 頁面的紙張：用重複圖層畫格線、點、橫線（放大縮小都不會吃太多記憶體）
final class GridView: UIView {
    var paper = PaperStyle() { didSet { setNeedsLayout() } }
    var cover: Int? { didSet { setNeedsLayout() } }
    var pageWidth: CGFloat = referencePageWidth { didSet { setNeedsLayout() } }   // 頁面實際寬度：格子大小照實際尺寸
    /// 白板（v12.5）：格線只畫一塊，格子大小不能用這一塊的寬度算，直接給縮放倍率
    var stepScale: CGFloat? { didSet { if stepScale != oldValue { setNeedsLayout() } } }
    private var coverLines: [CALayer] = []

    private let columnsRep = CAReplicatorLayer()     // 直線（往右重複）
    private let vLine = CALayer()
    private let rowsRep = CAReplicatorLayer()        // 橫線（往下重複）
    private let hLine = CALayer()
    private let dotRowsRep = CAReplicatorLayer()     // 點：一排往下重複
    private let dotColsRep = CAReplicatorLayer()     //     一個點往右重複
    private let dot = CALayer()
    private let spine = CALayer()                    // 封面左邊的深色帶子

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        columnsRep.addSublayer(vLine)
        rowsRep.addSublayer(hLine)
        dotColsRep.addSublayer(dot)
        dotRowsRep.addSublayer(dotColsRep)
        layer.addSublayer(columnsRep)
        layer.addSublayer(rowsRep)
        layer.addSublayer(dotRowsRep)
        layer.addSublayer(spine)
        for _ in 0..<6 {
            let line = CALayer()
            layer.addSublayer(line)
            coverLines.append(line)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // 封面
        let showCover = cover != nil
        let template = coverTemplate(cover ?? 0)
        backgroundColor = showCover ? uiColor(hex: template.color) : PaperRenderer.background(paper)
        spine.isHidden = !showCover
        spine.backgroundColor = template.spine.map { uiColor(hex: $0).cgColor } ?? UIColor(white: 0, alpha: 0.22).cgColor
        spine.frame = CGRect(x: w * 0.08, y: 0, width: w * 0.035, height: h)
        let decoColor: UIColor = coverIsLight(template) ? UIColor(white: 0, alpha: 0.15) : UIColor(white: 1, alpha: 0.25)
        let k = stepScale ?? (w / max(pageWidth, 1))           // 頁面座標 → 畫面
        for (i, line) in coverLines.enumerated() {
            line.isHidden = !(showCover && template.lines)
            line.backgroundColor = decoColor.cgColor
            line.frame = PaperRenderer.coverLineRect(i, width: w, height: h, thickness: max(0.6, k))
        }

        let pattern = showCover ? 0 : paper.pattern
        let lineColor = PaperRenderer.lineColor(paper).cgColor
        let lw = max(0.5, 0.5 * k)
        let gridStep = PaperRenderer.gridUnit * k               // 格子實際大小固定（A3 會比 A4 多格）
        // 縮得很小時格線淡出（v12.5）：格子在畫面上小於 9 點開始變淡，小於 5 點就不畫（不然整片都是線）
        let fade = Float(min(max((gridStep - 5) / 4, 0), 1))
        columnsRep.opacity = fade
        rowsRep.opacity = fade
        dotRowsRep.opacity = fade
        if fade == 0 {
            columnsRep.isHidden = true
            rowsRep.isHidden = true
            dotRowsRep.isHidden = true
            return
        }
        columnsRep.isHidden = pattern != 2
        rowsRep.isHidden = !(pattern == 2 || pattern == 3 || pattern == 4)
        dotRowsRep.isHidden = pattern != 1

        // 方格的直線
        vLine.backgroundColor = lineColor
        vLine.frame = CGRect(x: 0, y: 0, width: lw, height: h)
        columnsRep.frame = bounds
        columnsRep.instanceCount = Int(w / gridStep) + 1
        columnsRep.instanceTransform = CATransform3DMakeTranslation(gridStep, 0, 0)

        // 橫線：方格每一格；直線紙留上方空白
        let rowStep: CGFloat
        let top: CGFloat
        if pattern == 3 {
            rowStep = PaperRenderer.narrowLine * k
            top = rowStep * 3
        } else if pattern == 4 {
            rowStep = PaperRenderer.wideLine * k
            top = rowStep * 2
        } else {
            rowStep = gridStep
            top = 0
        }
        let topGap = stepScale == nil ? top : 0                // 白板只畫一塊：不留上方空白
        hLine.backgroundColor = lineColor
        hLine.frame = CGRect(x: 0, y: topGap, width: w, height: lw)
        rowsRep.frame = bounds
        rowsRep.instanceCount = max(Int((h - topGap) / rowStep) + 1, 1)
        rowsRep.instanceTransform = CATransform3DMakeTranslation(0, rowStep, 0)

        // 點狀紙
        let r = max(0.9, gridStep * 0.06)
        dot.backgroundColor = PaperRenderer.dotColor(paper).cgColor
        dot.cornerRadius = r
        dot.frame = CGRect(x: gridStep - r, y: gridStep - r, width: r * 2, height: r * 2)
        dotColsRep.frame = bounds
        dotColsRep.instanceCount = max(Int(w / gridStep) - 1, 1)
        dotColsRep.instanceTransform = CATransform3DMakeTranslation(gridStep, 0, 0)
        dotRowsRep.frame = bounds
        dotRowsRep.instanceCount = max(Int(h / gridStep) - 1, 1)
        dotRowsRep.instanceTransform = CATransform3DMakeTranslation(0, gridStep, 0)
    }
}

/// 紙張、封面的畫法（匯出 PDF、縮圖、新建畫面的預覽用）
@MainActor
enum PaperRenderer {
    /// 格子、橫線的實際間距（頁面座標；A4 寬約 30 格，約 7 公釐）
    static let gridUnit: CGFloat = referencePageWidth / 30
    static let narrowLine: CGFloat = referencePageWidth / 30
    static let wideLine: CGFloat = referencePageWidth / 22

    /// 封面右邊的橫線：上面兩條、下面四條
    static func coverLineRect(_ i: Int, width w: CGFloat, height h: CGFloat, thickness: CGFloat) -> CGRect {
        let ys: [CGFloat] = [0.10, 0.13, 0.62, 0.66, 0.70, 0.74]
        let y = h * ys[min(max(i, 0), ys.count - 1)]
        return CGRect(x: w * 0.55, y: y, width: w * 0.45, height: thickness)
    }

    static func background(_ paper: PaperStyle) -> UIColor {
        switch paper.color {
        case 1: return UIColor.white
        case 2: return UIColor(red: 0.99, green: 0.97, blue: 0.89, alpha: 1)
        default: return UIColor(white: 0.19, alpha: 1)
        }
    }

    static func lineColor(_ paper: PaperStyle) -> UIColor {
        paper.isDark ? UIColor(white: 0.32, alpha: 1) : UIColor(red: 0.78, green: 0.81, blue: 0.86, alpha: 1)
    }

    static func dotColor(_ paper: PaperStyle) -> UIColor {
        paper.isDark ? UIColor(white: 0.45, alpha: 1) : UIColor(white: 0.62, alpha: 1)
    }

    /// 畫進目前的繪圖區（UIGraphicsImageRenderer、PDF 匯出裡都能用）；pageWidth：頁面實際寬度
    static func draw(_ paper: PaperStyle, cover: Int?, in rect: CGRect, pageWidth: CGFloat) {
        let w = rect.width
        let k = w / max(pageWidth, 1)
        if let c = cover {
            let t = coverTemplate(c)
            uiColor(hex: t.color).setFill()
            UIRectFill(rect)
            let spineColor: UIColor = t.spine.map { uiColor(hex: $0) } ?? UIColor(white: 0, alpha: 0.22)
            spineColor.setFill()
            UIRectFill(CGRect(x: rect.minX + w * 0.08, y: rect.minY, width: w * 0.035, height: rect.height))
            if t.lines {
                let deco: UIColor = coverIsLight(t) ? UIColor(white: 0, alpha: 0.15) : UIColor(white: 1, alpha: 0.25)
                deco.setFill()
                for i in 0..<6 {
                    UIRectFill(coverLineRect(i, width: w, height: rect.height, thickness: max(0.5, k))
                        .offsetBy(dx: rect.minX, dy: rect.minY))
                }
            }
            return
        }
        background(paper).setFill()
        UIRectFill(rect)
        let lw = max(0.3, 0.5 * k)
        let step = gridUnit * k
        // v12.9.1 修閃退：白板的縮圖（整張 100×100 張 A4 縮成 200 點寬）每一格不到 0.1 點，
        // 點狀紙會一次做出幾百萬個小圓，記憶體吃光，主畫面一畫封面就閃退。
        // 現在：只畫看得到的範圍（畫布裁切的那一塊），格子小於 3 點或數量太多就不畫紋理（反正看不出來）
        var area = rect
        if let clip = UIGraphicsGetCurrentContext()?.boundingBoxOfClipPath {
            area = rect.intersection(clip)
        }
        guard !area.isNull, area.width > 0, area.height > 0, step >= 3,
              (area.width / step) * (area.height / step) <= 40_000 else { return }
        // 從看得到的範圍開始畫，但格子仍對齊整頁的原點
        func first(_ lo: CGFloat, _ origin: CGFloat, _ s: CGFloat) -> CGFloat {
            origin + max(0, ((lo - origin) / s).rounded(.down)) * s
        }
        let path = UIBezierPath()
        switch paper.pattern {
        case 1:
            let r = max(0.5, step * 0.06)
            var y = max(rect.minY + step, first(area.minY, rect.minY, step))
            while y < min(rect.maxY - 1, area.maxY + step) {
                var x = max(rect.minX + step, first(area.minX, rect.minX, step))
                while x < min(rect.maxX - 1, area.maxX + step) {
                    path.append(UIBezierPath(ovalIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)))
                    x += step
                }
                y += step
            }
            dotColor(paper).setFill()
            path.fill()
            return
        case 2:
            var x = first(area.minX, rect.minX, step)
            while x <= min(rect.maxX, area.maxX + step) {
                path.move(to: CGPoint(x: x, y: area.minY))
                path.addLine(to: CGPoint(x: x, y: area.maxY))
                x += step
            }
            var y = first(area.minY, rect.minY, step)
            while y <= min(rect.maxY, area.maxY + step) {
                path.move(to: CGPoint(x: area.minX, y: y))
                path.addLine(to: CGPoint(x: area.maxX, y: y))
                y += step
            }
        case 3, 4:
            let rowStep = (paper.pattern == 3 ? narrowLine : wideLine) * k
            let y0 = rect.minY + rowStep * (paper.pattern == 3 ? 3 : 2)
            var y = max(y0, y0 + ((area.minY - y0) / rowStep).rounded(.down) * rowStep)
            while y <= min(rect.maxY, area.maxY + rowStep) {
                path.move(to: CGPoint(x: area.minX, y: y))
                path.addLine(to: CGPoint(x: area.maxX, y: y))
                y += rowStep
            }
        default:
            return
        }
        lineColor(paper).setStroke()
        path.lineWidth = lw
        path.stroke()
    }

    /// 小預覽圖（新建筆記本畫面用）
    static func preview(_ paper: PaperStyle, cover: Int?, size: CGSize, pageWidth: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            draw(paper, cover: cover, in: CGRect(origin: .zero, size: size), pageWidth: pageWidth)
        }
    }

    /// 「無封面」的預覽：淺灰虛線框
    static func noCover(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            UIColor(white: 0.97, alpha: 1).setFill()
            UIRectFill(rect)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
            path.lineWidth = 2
            path.setLineDash([6, 5], count: 2, phase: 0)
            UIColor(white: 0.78, alpha: 1).setStroke()
            path.stroke()
        }
    }
}


// MARK: - 9. 小元件：拉動新增的圓圈、概覽縮圖

final class PullIndicator: UIView {
    private let ring = CAShapeLayer()
    private let track = CAShapeLayer()
    private let icon = UIImageView(image: UIImage(systemName: "plus"))
    private let label = UILabel()
    private let text: String

    var progress: CGFloat = 0 {
        didSet {
            let p = min(max(progress, 0), 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.strokeEnd = p
            CATransaction.commit()
            alpha = p > 0.02 ? 1 : 0
            let full = p >= 1
            icon.tintColor = full ? .systemBlue : .gray
            label.text = full ? "放開以新增" : text
        }
    }

    init(text: String, width: CGFloat) {
        self.text = text
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 84))
        isUserInteractionEnabled = false
        alpha = 0
        let circle = UIBezierPath(arcCenter: CGPoint(x: width / 2, y: 26), radius: 20,
                                  startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true)
        for shape in [track, ring] {
            shape.path = circle.cgPath
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 3
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
        track.strokeColor = UIColor(white: 0.75, alpha: 1).cgColor
        ring.strokeColor = UIColor.systemBlue.cgColor
        ring.strokeEnd = 0
        icon.frame = CGRect(x: width / 2 - 11, y: 15, width: 22, height: 22)
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .gray
        addSubview(icon)
        label.frame = CGRect(x: 0, y: 54, width: width, height: 22)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 13)
        label.textColor = .gray
        label.text = text
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 打開過的 PDF 留在記憶體裡，不用每次重讀
@MainActor
enum PDFStore {
    private static var cache: [String: PDFDocument] = [:]

    static func document(_ file: String) -> PDFDocument? {
        if let doc = cache[file] { return doc }
        guard let doc = PDFDocument(url: Store.pdfURL(file)) else { return nil }
        cache[file] = doc
        return doc
    }

    static func page(_ ref: PDFRef) -> PDFPage? {
        if let doc = cache[ref.file] { return doc.page(at: ref.index) }
        guard let doc = PDFDocument(url: Store.pdfURL(ref.file)) else { return nil }
        cache[ref.file] = doc
        return doc.page(at: ref.index)
    }

    /// PDF 那一頁的圖片；pixelWidth 是想要的像素寬度（PDFKit 會自動處理頁面方向）
    static func image(_ ref: PDFRef, aspect: CGFloat, pixelWidth: CGFloat) -> UIImage? {
        guard let page = page(ref) else { return nil }
        let w = max(pixelWidth, 1)
        return page.thumbnail(of: CGSize(width: w, height: w * aspect), for: .mediaBox)
    }

    /// 把 PDF 的某一頁畫進 rect（白底）
    static func draw(_ ref: PDFRef, in cg: CGContext, rect: CGRect, pixelWidth: CGFloat) {
        UIColor.white.setFill()
        cg.fill(rect)
        image(ref, aspect: rect.height / max(rect.width, 1), pixelWidth: pixelWidth)?.draw(in: rect)
    }
}

/// 畫一整張頁面（背景 + 筆跡），給概覽縮圖和匯出 PDF 用
@MainActor
enum PageRenderer {
    static func drawGrid(in cg: CGContext, rect: CGRect) {
        UIColor(white: 0.19, alpha: 1).setFill()
        cg.fill(rect)
        let step = rect.width / 30
        let grid = UIBezierPath()
        var x = rect.minX
        while x <= rect.maxX {
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += step
        }
        var y = rect.minY
        while y <= rect.maxY {
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += step
        }
        UIColor(white: 0.32, alpha: 1).setStroke()
        grid.lineWidth = 0.5
        grid.stroke()
    }

    /// region：只需要頁面上的這一塊（頁面座標；截圖、白板匯出用）。筆跡只畫這一塊，不然白板會畫出一張超大的圖
    static func draw(_ page: NotePage, in cg: CGContext, rect: CGRect, inkScale: CGFloat,
                     drawing override: PKDrawing? = nil, region: CGRect? = nil) {
        if let pdf = page.pdf {
            PDFStore.draw(pdf, in: cg, rect: rect, pixelWidth: page.spec.width * inkScale)
        } else {
            PaperRenderer.draw(page.paperStyle, cover: page.cover, in: rect, pageWidth: page.spec.width)
        }
        drawImages(page, rect: rect, above: false)
        let drawing = override ?? Store.loadDrawing(page.id)
        if !drawing.strokes.isEmpty {
            let fullPage = CGRect(x: 0, y: 0, width: page.spec.width, height: page.spec.height)
            let area = (region ?? fullPage).intersection(fullPage)
            if !area.isNull, area.width > 0, area.height > 0 {
                var ink = UIImage()
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    ink = drawing.image(from: area, scale: inkScale)
                }
                let k = rect.width / max(page.spec.width, 1)
                let target = CGRect(x: rect.minX + area.minX * k, y: rect.minY + area.minY * k,
                                    width: area.width * k, height: area.height * k)
                if page.pdf != nil {
                    ink.draw(in: target, blendMode: .multiply, alpha: 1)
                } else {
                    ink.draw(in: target)
                }
            }
        }
        drawImages(page, rect: rect, above: true)
        drawTexts(page, rect: rect)
    }

    /// 圖片（匯出、縮圖、截圖用）
    static func drawImages(_ fullPage: NotePage, rect: CGRect, above: Bool) {
        let page = MindFold.visible(fullPage)                  // 心智圖收起來的分支不畫（v12.16.0）
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let k = rect.width / max(page.spec.width, 1)
        for box in page.images ?? [] where box.above == above {
            guard let image = Store.loadImage(box.file, pageID: page.id) else { continue }
            if box.isMini {                                       // 縮成小圖：匯出、縮圖也畫小圖
                let r = box.miniRect
                let target = CGRect(x: rect.minX + r.minX * k, y: rect.minY + r.minY * k, width: r.width * k, height: r.height * k)
                let clip = UIBezierPath(roundedRect: target, cornerRadius: min(8 * k, target.width * 0.15))
                ctx.saveGState()
                clip.addClip()
                image.draw(in: target)
                ctx.restoreGState()
                UIColor(white: 1, alpha: 0.85).setStroke()
                clip.lineWidth = max(1.5 * k, 0.5)
                clip.stroke()
                continue
            }
            ctx.saveGState()
            ctx.translateBy(x: rect.minX + (box.x + box.width / 2) * k, y: rect.minY + (box.y + box.height / 2) * k)
            ctx.rotate(by: box.rotation)
            image.draw(in: CGRect(x: -box.width * k / 2, y: -box.height * k / 2, width: box.width * k, height: box.height * k))
            ctx.restoreGState()
        }
    }

    /// 截圖：把頁面的某一塊（頁面座標）畫成一張圖
    static func renderCrop(_ page: NotePage, crop: CGRect) -> UIImage {
        let scale: CGFloat = max(1.5, min(3, 2000 / max(page.spec.width, 1)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: crop.size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: -crop.minX, y: -crop.minY)
            draw(page, in: ctx.cgContext, rect: CGRect(x: 0, y: 0, width: page.spec.width, height: page.spec.height),
                 inkScale: scale, region: crop)
        }
    }

    /// 文字方塊（匯出、縮圖用）
    /// 一個文字方塊的範圍（頁面座標，含留白）：資料裡只存寬度，高度要用字算出來
    static func textContentRect(_ t: TextBox, page: NotePage) -> CGRect {
        if t.sticky == true {
            // 便利貼（v12.15.12）：展開會擋到別的東西就畫成小圖示
            return stickyExpanded(t, page: page) ? stickyFullRect(t, page: page)
                : CGRect(x: t.x, y: t.y, width: TextBoxView.foldedSide, height: TextBoxView.foldedSide)
        }
        return plainContentRect(t, page: page)
    }

    /// 便利貼展開的範圍（含手寫要的高度）
    static func stickyFullRect(_ t: TextBox, page: NotePage) -> CGRect {
        var r = plainContentRect(t, page: page)
        var bottom = TextBoxView.stickyMinHeight
        if let data = t.ink, let ink = try? PKDrawing(data: data), !ink.strokes.isEmpty { bottom = max(bottom, ink.bounds.maxY + 10) }
        r.size.height = max(r.height, bottom)
        return r
    }

    /// 匯出、縮圖時便利貼要不要展開（v12.15.12，使用者：看會不會擋到其他字，不會擋到就展開）：
    /// 展開的範圍碰到課本上的字、筆跡、其他文字方塊或圖片，就畫成小圖示
    static func stickyExpanded(_ t: TextBox, page: NotePage) -> Bool {
        let f = stickyFullRect(t, page: page)
        for o in page.texts ?? [] where o.id != t.id && o.sticky != true {
            if textFrameRect(o, page: page).intersects(f) { return false }
        }
        for b in page.images ?? [] {
            let r = b.isMini ? b.miniRect : CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
            if r.intersects(f) { return false }
        }
        if Store.loadDrawing(page.id).strokes.contains(where: { $0.renderBounds.intersects(f) }) { return false }
        if let ref = page.pdf, let pdf = PDFStore.page(ref) {
            let box = pdf.bounds(for: .cropBox)
            let sx = box.width / max(page.spec.width, 1)
            let sy = box.height / max(page.spec.height, 1)
            let r = CGRect(x: box.minX + f.minX * sx, y: box.minY + (page.spec.height - f.maxY) * sy,
                           width: f.width * sx, height: f.height * sy)
            // 掃描的課本（整頁是圖）：看那一塊有沒有深色的東西
            if pdfHasMarks(ref, page: page, in: f) { return false }
            // 一個字一個字看：字的範圍碰到便利貼就算擋到（selection(for:) 只選到整個在裡面的字，蓋一半的會漏掉）
            if let text = pdf.string as NSString? {
                for i in 0 ..< pdf.numberOfCharacters {
                    if i < text.length, let scalar = UnicodeScalar(text.character(at: i)),
                       CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                    if pdf.characterBounds(at: i).intersects(r) { return false }
                }
            }
        }
        return true
    }

    /// PDF 頁的某一塊（頁面座標）有沒有字、圖（深色的點超過一點點就算有）
    private static func pdfHasMarks(_ ref: PDFRef, page: NotePage, in f: CGRect) -> Bool {
        guard let cg = PDFStore.image(ref, aspect: page.spec.height / max(page.spec.width, 1), pixelWidth: 400)?.cgImage else {
            return false
        }
        let sx = CGFloat(cg.width) / max(page.spec.width, 1)
        let sy = CGFloat(cg.height) / max(page.spec.height, 1)
        let r = CGRect(x: f.minX * sx, y: f.minY * sy, width: f.width * sx, height: f.height * sy).integral
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !r.isEmpty, let crop = cg.cropping(to: r) else { return false }
        let w = min(Int(r.width), 80)
        let h = min(Int(r.height), 80)
        guard w > 0, h > 0 else { return false }
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return false }
        var dark = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let lum = (Int(pixels[i]) * 3 + Int(pixels[i + 1]) * 6 + Int(pixels[i + 2])) / 10
            if lum < 150 { dark += 1 }
        }
        return Double(dark) / Double(w * h) > 0.004
    }

    private static func plainContentRect(_ t: TextBox, page: NotePage) -> CGRect {
        var w = t.width
        var h: CGFloat
        if !t.text.isEmpty, MathRenderer.needsRender(t),
           let image = MathRenderer.shared.cached(MathRenderer.request(for: t, pageWidth: textWrapWidth(page.spec))) {
            h = image.size.height / MathRenderer.scaleFactor
            if t.fixedWidth == nil { w = max(16, image.size.width / MathRenderer.scaleFactor) }
        } else {
            let font = TextBoxView.font(for: t, scale: 1)
            let text = t.text.isEmpty ? "輸入文字" : t.text
            let size = (text as NSString).boundingRect(with: CGSize(width: t.width + 2, height: CGFloat.greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                       attributes: [.font: font], context: nil)
            h = max(ceil(size.height), font.lineHeight)
        }
        return CGRect(x: t.x, y: t.y, width: w + TextBoxView.insetX * 2, height: h + TextBoxView.insetY * 2)
    }

    /// 文字方塊的外框（有樣式的比文字大一圈）
    static func textFrameRect(_ t: TextBox, page: NotePage) -> CGRect {
        let content = textContentRect(t, page: page)
        return t.fill == nil ? content : TextBoxStyle.frame(content: content, shape: t.shape ?? 1, scale: 1)
    }

    /// 文字方塊的外框樣式、方塊之間的連線（v12.13.0；匯出、縮圖用）
    static func drawTextStyles(_ page: NotePage, rect: CGRect) {
        let texts = page.texts ?? []
        guard texts.contains(where: { $0.fill != nil }) || !(page.links ?? []).isEmpty,
              let ctx = UIGraphicsGetCurrentContext() else { return }
        let k = rect.width / max(page.spec.width, 1)
        var frames: [UUID: CGRect] = [:]
        for t in texts where t.fill != nil || (page.links ?? []).contains(where: { $0.from == t.id || $0.to == t.id }) {
            let f = textFrameRect(t, page: page)
            frames[t.id] = CGRect(x: rect.minX + f.minX * k, y: rect.minY + f.minY * k, width: f.width * k, height: f.height * k)
        }
        for b in page.images ?? [] where (page.links ?? []).contains(where: { $0.from == b.id || $0.to == b.id }) {
            let f = b.isMini ? b.miniRect : CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
            frames[b.id] = CGRect(x: rect.minX + f.minX * k, y: rect.minY + f.minY * k, width: f.width * k, height: f.height * k)
        }
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for link in page.links ?? [] {
            guard let a = frames[link.from], let b = frames[link.to] else { continue }
            ctx.setStrokeColor(BoxLinkPath.color(link).cgColor)
            ctx.setLineWidth(max(CGFloat(link.width ?? 2) * k, 0.5))
            ctx.setLineDash(phase: 0, lengths: link.dash == true ? [7 * k, 6 * k] : [])
            ctx.addPath(BoxLinkPath.path(from: BoxLinkPath.anchor(a, side: link.fromSide), fromSide: link.fromSide,
                                         to: BoxLinkPath.anchor(b, side: link.toSide), toSide: link.toSide, scale: k,
                                         route: link.route ?? 0, arrow: link.arrow ?? 0))
            ctx.strokePath()
        }
        ctx.restoreGState()
        for t in texts where t.fill != nil {
            guard let f = frames[t.id] else { continue }
            if t.sticky == true && !stickyExpanded(t, page: page) {
                drawFoldedSticky(t, rect: f, scale: k)
            } else {
                TextBoxStyle.draw(t, rect: f, scale: k)
            }
        }
    }

    /// 收成小圖示的便利貼（匯出、縮圖）
    static func drawFoldedSticky(_ t: TextBox, rect: CGRect, scale k: CGFloat) {
        let side = TextBoxView.foldedSide * k
        let r = CGRect(x: rect.minX, y: rect.minY, width: side, height: side)
        let path = UIBezierPath(roundedRect: r, cornerRadius: 5 * k)
        (t.fill.map { TextBoxStyle.color($0) } ?? UIColor(red: 1, green: 0.9, blue: 0.45, alpha: 1)).setFill()
        path.fill()
        UIColor(white: 0, alpha: 0.18).setStroke()
        path.lineWidth = max(k, 0.5)
        path.stroke()
        if let icon = UIImage(systemName: "note.text")?.withTintColor(UIColor(white: 0.25, alpha: 1), renderingMode: .alwaysOriginal) {
            icon.draw(in: r.insetBy(dx: side * 0.2, dy: side * 0.22))
        }
    }

    static func drawTexts(_ fullPage: NotePage, rect: CGRect) {
        let page = MindFold.visible(fullPage)                  // 心智圖收起來的分支不畫（v12.16.0）
        let k = rect.width / max(page.spec.width, 1)
        drawTextStyles(page, rect: rect)
        for t in page.texts ?? [] where t.sticky == true && stickyExpanded(t, page: page) {
            // 便利貼上的手寫（v12.15.12）
            guard let data = t.ink, let ink = try? PKDrawing(data: data), !ink.strokes.isEmpty else { continue }
            let b = ink.bounds
            var image = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = ink.image(from: b, scale: max(k * 2, 1))
            }
            image.draw(in: CGRect(x: rect.minX + (t.x + b.minX) * k, y: rect.minY + (t.y + b.minY) * k,
                                  width: b.width * k, height: b.height * k))
        }
        for t in page.texts ?? [] where !t.text.isEmpty {
            if t.sticky == true && !stickyExpanded(t, page: page) { continue }   // 收成小圖示的便利貼：字不畫
            // 數學式：有排好的圖片就畫圖片
            if MathRenderer.needsRender(t),
               let image = MathRenderer.shared.cached(MathRenderer.request(for: t, pageWidth: textWrapWidth(page.spec))) {
                let f = MathRenderer.scaleFactor
                image.draw(in: CGRect(x: rect.minX + (t.x + TextBoxView.insetX) * k,
                                      y: rect.minY + (t.y + TextBoxView.insetY) * k,
                                      width: image.size.width / f * k, height: image.size.height / f * k))
                continue
            }
            let para = NSMutableParagraphStyle()
            para.alignment = TextBoxView.alignment(t.align)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: TextBoxView.font(for: t, scale: k),
                .foregroundColor: t.color,
                .paragraphStyle: para
            ]
            let box = CGRect(x: rect.minX + (t.x + TextBoxView.insetX) * k,
                             y: rect.minY + (t.y + TextBoxView.insetY) * k,
                             width: (t.width + 2) * k, height: 100_000)
            (t.text as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                      attributes: attributes, context: nil)
        }
    }
}

@MainActor
enum Thumbnail {
    static func image(for page: NotePage, width: CGFloat, drawing: PKDrawing? = nil) -> UIImage {
        let size = CGSize(width: width, height: width * page.spec.height / max(page.spec.width, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            PageRenderer.draw(page, in: ctx.cgContext, rect: CGRect(origin: .zero, size: size),
                              inkScale: width / max(page.spec.width, 1) * 2, drawing: drawing)
        }
    }
}

/// 心智圖折疊的圓圈（v12.16.1）：摸得到的範圍比看到的大一圈
final class FoldButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -8, dy: -8).contains(point)
    }
}
