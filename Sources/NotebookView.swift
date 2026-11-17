import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// NotebookView.swift：NotebookView：筆記本的 UIKit 主體（捲動、縮放、手勢、復原、選取、文字、圖片、截圖、貼上）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

// MARK: - 5. 筆記本主體（UIKit）：上下捲動、縮放、拉動新增、工具列

final class NotebookView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, PKToolPickerObserver,
                          UIPencilInteractionDelegate {
    let model: NotebookModel
    let toolPicker = NotebookView.makeToolPicker()

    private let outer = UIScrollView()
    private let container = UIView()
    private let topPull = PullIndicator(text: "拉動以在最前面增加頁面", width: 200)
    private let bottomPull = PullIndicator(text: "拉動以增加頁面", width: 160)
    private let holdTracker = PencilHoldTracker()
    private var rowViews: [UUID: PageRowView] = [:]
    private var pageViews: [UUID: NotePageView] = [:]
    private(set) var shapeEditor: SelectionEditorView?
    let history = UndoManager()                         // 這本筆記本的復原紀錄（雙指、三指點、工具列都用它）
    static var clipboard: [PKStroke] = []               // 剪貼簿：所有筆記本共用
    static var textClipboard: TextBox?                  // 剪貼簿裡的文字方塊（跟筆跡二選一）
    static var imageClipboard: UIImage?                 // App 裡拷貝的圖片
    // 套索一起拷貝的圖片、文字方塊（v12.9.2）：跟 clipboard 的筆跡一起貼上
    static var clipImages: [(box: ImageBox, image: UIImage)] = []
    static var clipTexts: [TextBox] = []
    static var hasClipboard: Bool {
        !clipboard.isEmpty || textClipboard != nil || imageClipboard != nil || !clipImages.isEmpty || !clipTexts.isEmpty
    }
    static func clearMixedClipboard() {
        clipImages = []
        clipTexts = []
    }
    /// App 自己最後一次寫系統剪貼簿（或拷貝筆跡）時的編號；系統剪貼簿比這個新，代表是從別的地方拷貝的（例如截圖）
    static var ownPasteboardChange = -1
    static var clipboardScale: CGFloat = 1              // 拷貝來源頁面的大小比例（貼到不同大小的頁面時換算）
    private let dismissTap = UITapGestureRecognizer()
    private let textTap = UITapGestureRecognizer()           // 手指點兩下：新增文字方塊
    private let selectPress = UILongPressGestureRecognizer()
    // 自己的套索：圈完直接出現選取框（有旋轉、縮放、顏色等）
    private let lassoPan = UIPanGestureRecognizer()
    private let lassoLayer = CAShapeLayer()
    private var lassoPoints: [CGPoint] = []
    private(set) var lassoMode = false
    // 螢光筆停住：先畫一條預覽直線，放開後再用真正畫完的那一筆拉直
    private var pendingMarkerLine: (pageID: UUID, a: CGPoint, b: CGPoint)?
    private let markerGuide = CAShapeLayer()
    private var lastTool: PKTool = PKInkingTool(.pen, color: .white, width: 3)

    private(set) var zoom: CGFloat = 1
    private var focusRow = 0
    private var sharedInPageX: CGFloat = 0     // 放大時，各列主頁共用的水平位置
    private var lastWidth: CGFloat = 0
    private var pendingTopAdd = false
    private var pendingBottomAdd = false
    private var startedAtTop = false          // 開始拖的時候已經在最上面
    private var startedAtBottom = false       // 開始拖的時候已經在最下面

    // 縮放：記住手指下方是哪一頁的哪個位置，縮放時一直把它留在手指下方
    private var isPinching = false
    private var pinchStartZoom: CGFloat = 1
    private var zoomAnchors: [(UUID, Int, CGFloat)] = []
    private var zoomVerticalAnchor: (UUID, CGFloat)?

    let margin: CGFloat = 24
    let rowGap: CGFloat = 28
    let topInset: CGFloat = 20
    let bottomInset: CGFloat = 140             // 留空間給底部工具列
    let pullThreshold: CGFloat = 130           // 拉動新增的距離；數字越大越不容易誤觸
    let pullMaxVelocity: CGFloat = 0.8         // 放手時速度要低於這個值（甩過去不算）
    /// 在最近刪除裡打開的筆記本（v12.6）：只能看，不能寫、不能改
    var readOnly: Bool { model.meta.deletedAt != nil }

    /// 白板（v12.3）：一本只有一張大頁面的筆記本。不能加頁；左右、上下可以同時捲；縮放範圍照白板的大小算
    var isBoard: Bool { model.notebook.board ?? false }
    /// 往旁邊、往上下拉可以新增頁面（白板不行）
    var allowsPagePull: Bool { !isBoard }
    /// 是不是外層（上下捲動）的拖曳手勢：白板的那一列要跟它同時捲
    func isOuterPan(_ g: UIGestureRecognizer) -> Bool { g === outer.panGestureRecognizer }
    /// 白板的 100%（v12.5）：格子、字的大小跟筆記本 100% 一樣（一張 A4 的寬度剛好放滿畫面）。
    /// zoom 是「整張白板放滿畫面」的倍數，所以白板的 100% 換算成 zoom 是這個數字
    var boardZoom100: CGFloat {
        let s100 = max(0.05, (bounds.width - 2 * margin) / referencePageWidth)
        return s100 / max(baseScale, 0.0001)
    }

    /// 白板：5%～200%（以白板的 100% 為準；使用者說放到 200% 就夠了）；筆記本：35%～400%
    var minZoom: CGFloat { isBoard ? boardZoom100 * 0.05 : 0.35 }
    var maxZoom: CGFloat { isBoard ? boardZoom100 * 2 : 4 }

    /// 白板現在的百分比（之後左下角要顯示）
    var boardPercent: CGFloat { (boardPinching ? pinchLastZoom : zoom) / max(boardZoom100, 0.0001) }

    // MARK: 白板的畫布跟著畫面（v12.5）

    /// 畫面移動或縮放後：白板的畫布還蓋得住畫面就不動；蓋不住、或比需要的大太多，就換到畫面附近（四周多留 35%）
    func updateBoardWindow(force: Bool = false) {
        updateBoardHUD()                                       // 左下角的百分比、位置條、位置預覽
        guard isBoard, let row = model.notebook.rows.first, let page = row.pages.first,
              let pv = pageViews[page.id], bounds.width > 0 else { return }
        let s = pv.bounds.width / max(page.spec.width, 1)
        guard s > 0 else { return }
        if !force, pv.isDrawing { return }                    // 正在寫字：寫完再說
        let v = pv.convert(bounds, from: self)
        let visible = CGRect(x: v.minX / s, y: v.minY / s, width: v.width / s, height: v.height / s)
        if !force, let current = pv.canvasWindow, current.contains(visible),
           current.width < visible.width * 2.5, current.height < visible.height * 2.5 { return }
        // 四周各多留 45%（v12.8.1：以前 35%，捲快一點畫布就要換位置，換的時候字會閃一下）
        pv.canvasWindow = visible.insetBy(dx: -visible.width * 0.45, dy: -visible.height * 0.45)
        pv.layoutCanvasWindow(scale: s)
    }

    private static let fingerOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

    /// 工具列：白色、黑色、紅色、藍色鋼筆、白色鉛筆、黃色螢光筆、橡皮擦、套索、尺
    static func makeToolPicker() -> PKToolPicker {
        if #available(iOS 18.0, *) {
            let items: [PKToolPickerItem] = [
                PKToolPickerInkingItem(type: .pen, color: .white),
                PKToolPickerInkingItem(type: .pen, color: .black),          // 寫在 PDF 白底上用
                PKToolPickerInkingItem(type: .pen, color: UIColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 1)),
                PKToolPickerInkingItem(type: .pen, color: UIColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1)),
                PKToolPickerInkingItem(type: .pencil, color: .white),
                PKToolPickerInkingItem(type: .marker, color: .systemYellow),
                PKToolPickerEraserItem(type: .vector),
                PKToolPickerLassoItem(),
                PKToolPickerRulerItem()
            ]
            return PKToolPicker(toolItems: items)
        }
        return PKToolPicker()
    }

    init(model: NotebookModel) {
        self.model = model
        super.init(frame: .zero)
        applyBackdrop()

        outer.delegate = self
        outer.alwaysBounceVertical = true
        outer.showsHorizontalScrollIndicator = false
        outer.contentInsetAdjustmentBehavior = .never
        outer.delaysContentTouches = false
        outer.contentInset.bottom = bottomInset
        outer.panGestureRecognizer.allowedTouchTypes = Self.fingerOnly
        addSubview(outer)
        outer.addSubview(container)
        container.addSubview(topPull)
        container.addSubview(bottomPull)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = Self.fingerOnly
        outer.addGestureRecognizer(pinch)
        pinchGesture = pinch

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(undoAction))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = Self.fingerOnly
        addGestureRecognizer(undoTap)

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(redoAction))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = Self.fingerOnly
        addGestureRecognizer(redoTap)

        // 手指點一下：點到筆跡就選取它，點到空白就結束選取
        dismissTap.addTarget(self, action: #selector(handleSingleTap(_:)))
        dismissTap.allowedTouchTypes = Self.fingerOnly
        dismissTap.cancelsTouchesInView = false
        dismissTap.delegate = self
        dismissTap.require(toFail: undoTap)            // 雙指、三指點的時候，不要被當成單指點（選取筆跡）
        dismissTap.require(toFail: redoTap)
        addGestureRecognizer(dismissTap)

        // 手指點兩下：在那裡新增文字方塊（點在文字方塊上就編輯它）
        textTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
        textTap.numberOfTapsRequired = 2
        textTap.allowedTouchTypes = Self.fingerOnly
        textTap.cancelsTouchesInView = false
        textTap.delegate = self
        addGestureRecognizer(textTap)
        dismissTap.require(toFail: textTap)

        // 復原紀錄有變化時，更新右上角復原、重做按鈕能不能按
        for name in [NSNotification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                     .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint] {
            NotificationCenter.default.addObserver(self, selector: #selector(historyChanged), name: name, object: history)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(otherSurfaceTapped(_:)), name: Self.surfaceTapped, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clipSyncChanged), name: ClipSync.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storeWriteFailed(_:)), name: Store.writeFailed, object: nil)

        selectPress.addTarget(self, action: #selector(handleSelectPress(_:)))
        selectPress.minimumPressDuration = 0.25          // v12.9.8：0.4 → 0.25（使用者：按下去到跳出來要短一點）
        selectPress.allowedTouchTypes = Self.fingerOnly
        selectPress.cancelsTouchesInView = false
        selectPress.delegate = self
        addGestureRecognizer(selectPress)

        lassoPan.addTarget(self, action: #selector(handleLasso(_:)))
        lassoPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        lassoPan.delegate = self
        lassoPan.isEnabled = false
        addGestureRecognizer(lassoPan)
        setUpCrop()
        setUpTape()
        lassoLayer.fillColor = nil
        lassoLayer.strokeColor = UIColor.systemBlue.cgColor
        lassoLayer.lineWidth = 2
        lassoLayer.lineDashPattern = [6, 5]
        layer.addSublayer(lassoLayer)
        markerGuide.strokeColor = UIColor.systemBlue.cgColor
        markerGuide.lineWidth = 2
        markerGuide.lineDashPattern = [8, 6]
        markerGuide.fillColor = nil
        layer.addSublayer(markerGuide)
        addSubview(pasteButton)

        holdTracker.delegate = self
        holdTracker.cancelsTouchesInView = false
        holdTracker.delaysTouchesEnded = false
        holdTracker.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        holdTracker.onHold = { [weak self] points in
            self?.snapWhileHolding(points) ?? false
        }
        holdTracker.onTouchDown = { [weak self] in
            self?.enforceLassoMode()
        }
        addGestureRecognizer(holdTracker)

        // 工具列與畫布都用淺色模式：選什麼顏色就顯示什麼顏色
        toolPicker.overrideUserInterfaceStyle = .light
        toolPicker.colorUserInterfaceStyle = .light
        // Apple 的工具列不再顯示，全部改用筆盒；Pencil 點兩下由這裡處理
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        addInteraction(pencilInteraction)

        NotificationCenter.default.addObserver(self, selector: #selector(flushAll),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        rebuild()
    }

    // MARK: 鍵盤（v12.9.8：正式安裝後鍵盤叫得出來了）

    /// 鍵盤蓋住畫面下面多少
    private(set) var keyboardOverlap: CGFloat = 0

    @objc private func keyboardFrameChanged(_ note: Notification) {
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
              let screen = window?.screen else { return }
        let end = value.cgRectValue
        let screenHeight = screen.bounds.height
        let overlap: CGFloat = end.minY >= screenHeight ? 0 : max(0, screenHeight - end.minY)
        guard abs(overlap - keyboardOverlap) > 0.5 else { return }
        keyboardOverlap = overlap
        outer.contentInset.bottom = bottomInset + overlap      // 下面多留一塊，最後一頁的字也捲得上來
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.revealActiveText()
            self?.positionTextBar()
        }
    }

    /// 正在打字的地方被鍵盤蓋住：往上捲到看得到
    private func revealActiveText() {
        guard keyboardOverlap > 0, let tv = activeText, tv.textView.isFirstResponder else { return }
        var r = tv.convert(tv.contentRect, to: self)
        if let range = tv.textView.selectedTextRange {
            let caret = tv.textView.caretRect(for: range.end)
            if !caret.isNull, !caret.isInfinite { r = tv.textView.convert(caret, to: self) }
        }
        let limit = bounds.height - keyboardOverlap - 28
        let delta = r.maxY - limit
        guard delta > 0 else { return }
        outer.setContentOffset(CGPoint(x: outer.contentOffset.x, y: outer.contentOffset.y + delta), animated: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 讓工具列跟著這個畫面出現；並關掉系統的三指編輯手勢
    // 不再需要 Apple 工具列，筆記本也不接收「全選、插入空間」這類選單指令
    override var canBecomeFirstResponder: Bool { false }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
    override var undoManager: UndoManager? { history }

    /// 某一頁的筆跡改變了：登記一步，復原時換回 old（頁面已經捲走、被釋放了也沒關係）
    /// 選取框做的改動（移動、縮放、換色、刪除、搬到別頁）：復原後要把選取框叫回來
    private(set) var recordingSelectionEdit = false

    func recordingSelection(_ body: () -> Void) {
        recordingSelectionEdit = true
        body()
        recordingSelectionEdit = false
    }

    func recordUndo(pageID: UUID, old: PKDrawing) {
        let reselect = recordingSelectionEdit
        history.registerUndo(withTarget: self) { notebook in
            notebook.restoreDrawing(pageID: pageID, to: old, reselect: reselect)
        }
    }

    func restoreDrawing(pageID: UUID, to drawing: PKDrawing, reselect: Bool = false) {
        dismissShapeEditor()
        let current: PKDrawing
        if let pv = pageViews[pageID], let rv = pv.superview as? PageRowView {
            current = pv.canvas.drawing
            Store.saveDrawing(drawing, pageID: pageID)
            reloadPageView(pv, showing: drawing, in: rv)          // 換一張全新的畫布，不留殘影
        } else if let pv = pageViews[pageID] {
            current = pv.canvas.drawing
            pv.replaceSilently(drawing, updateBaseline: true)
        } else {
            current = Store.loadDrawing(pageID)
            Store.saveDrawing(drawing, pageID: pageID)
        }
        history.registerUndo(withTarget: self) { notebook in       // 重做
            notebook.restoreDrawing(pageID: pageID, to: current, reselect: reselect)
        }
        reveal(pageID: pageID, pageRect: Self.changedRect(current, drawing))   // 跳回改動的地方
        if reselect {
            // 回來的那幾筆重新選起來
            let old = current.strokes.map { $0.renderBounds }
            let back = drawing.strokes.indices.filter { !old.contains(drawing.strokes[$0].renderBounds) }
            guard !back.isEmpty else { return }
            let single = back.count == 1 && isHighlighter(drawing.strokes[back[0]])
            let select: () -> Bool = { [weak self] in
                guard let self = self, let pv = self.pageViews[pageID],
                      back.allSatisfy({ pv.canvas.drawing.strokes.indices.contains($0) }) else { return false }
                self.showSelection(on: pv, indices: back, allowLine: single)
                return true
            }
            if !select() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { _ = select() }   // 捲過去之後頁面才載入
            }
        }
    }

    /// 兩個狀態之間有變動的筆跡範圍（頁面座標）
    private static func changedRect(_ a: PKDrawing, _ b: PKDrawing) -> CGRect {
        let ra = a.strokes.map { $0.renderBounds }
        let rb = b.strokes.map { $0.renderBounds }
        var u = CGRect.null
        for r in ra where !rb.contains(r) { u = u.union(r) }
        for r in rb where !ra.contains(r) { u = u.union(r) }
        return u
    }

    static let surfaceTapped = Notification.Name("NotebookViewSurfaceTapped")

    /// 別的畫面（白板或浮動視窗）被點了：這裡選取中的文字方塊、圖片、選取框都結束
    @objc private func otherSurfaceTapped(_ note: Notification) {
        guard let other = note.object as? NotebookView, other !== self else { return }
        if activeText != nil { endTextSelection() }
        if imageEditor != nil { endImageSelection() }
        dismissShapeEditor()
    }

    /// 存檔失敗（v12.15.8）：iPad 空間滿了的時候筆跡、筆記本都存不進去，一定要讓使用者知道
    @objc private func storeWriteFailed(_ note: Notification) {
        guard window != nil else { return }
        let full = (note.userInfo?["full"] as? Bool) ?? false
        showMessage("exclamationmark.triangle.fill",
                    full ? "iPad 空間不夠，剛剛寫的沒辦法存檔！先不要關 App，到「設定 → 一般 → iPad 儲存空間」清出空間，會自動再存"
                         : "存檔失敗，剛剛寫的可能沒存進去（先不要關 App）")
    }

    /// 白板上從筆記本剪過來的圖刪掉／拿回來了：這一本的框重新整理（v12.15.3）
    @objc private func clipSyncChanged() {
        guard !isBoard else { return }
        for pv in pageViews.values { pv.syncClips(model.clips(of: pv.page.id)) }
    }

    /// 點框裡面：選取那個框（右下角出現 → 和顏色）；點別的地方：取消
    private func clipHit(at p: CGPoint) -> (NotePageView, PageClip)? {
        guard !isBoard else { return nil }
        for pv in pageViews.values {
            let local = pv.convert(p, from: self)
            guard pv.bounds.contains(local), !pv.clips.isEmpty else { continue }
            let s = pv.bounds.width / max(pv.page.spec.width, 1)
            guard s > 0 else { continue }
            if let clip = pv.clip(atPagePoint: CGPoint(x: local.x / s, y: local.y / s)) { return (pv, clip) }
        }
        return nil
    }

    private func deselectClips(except keep: NotePageView? = nil) {
        for pv in pageViews.values where pv !== keep && pv.selectedClipID != nil { pv.selectClip(nil) }
    }

    /// 框的顏色（框旁邊的 🎨）
    func setClipColor(_ id: UUID, rgb: UInt32?, pageID: UUID) {
        var clips = model.clips(of: pageID)
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].rgb = rgb
        model.setClips(clips, pageID: pageID)
        pageViews[pageID]?.syncClips(clips)
    }

    /// 浮動視窗裡剪去白板的框按 →（v12.15.2）：白板跳到那張圖（放在視窗旁邊空著的地方）並選取它
    func revealBoardImage(_ id: UUID, avoiding windowOnScreen: CGRect) {
        let window = convert(windowOnScreen, from: nil)          // 螢幕座標 → 白板畫面座標（v12.15.3）
        guard isBoard, let pv = boardPV, let box = model.images(of: pv.page.id).first(where: { $0.id == id }) else {
            showMessage("questionmark.square.dashed", "白板上找不到這張圖（可能被刪掉了）")
            return
        }
        let s = max(pv.bounds.width / max(pv.page.spec.width, 1), 0.0001)
        let leftRoom = window.minX
        let rightRoom = bounds.width - window.maxX
        var targetX = bounds.midX
        if max(leftRoom, rightRoom) > 160 {
            targetX = rightRoom >= leftRoom ? window.maxX + rightRoom / 2 : leftRoom / 2
        }
        let center = CGPoint(x: box.x + box.width / 2 - (targetX - bounds.midX) / s, y: box.y + box.height / 2)
        boardShow(center: center, zoom: zoom)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, let pv = self.boardPV,
                  let now = self.model.images(of: pv.page.id).first(where: { $0.id == id }) else { return }
            self.endTextSelection()
            self.selectImage(now, on: pv)
        }
    }

    /// 跳到某一頁的某一塊（白板上剪下來的圖的 ‹；v12.15.0），那一塊閃一下黃框
    func jumpTo(pageID: UUID, rect: CGRect) {
        guard model.page(pageID) != nil else {
            showMessage("questionmark.square.dashed", "找不到剪下來的那一頁（可能被刪掉了）")
            return
        }
        endTextSelection()
        dismissShapeEditor()
        reveal(pageID: pageID, pageRect: rect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self = self, let pv = self.pageViews[pageID] else { return }
            let s = pv.bounds.width / max(pv.page.spec.width, 1)
            let local = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
            let flash = UIView(frame: pv.convert(local, to: self).insetBy(dx: -4, dy: -4))
            flash.isUserInteractionEnabled = false
            flash.layer.borderColor = UIColor.systemYellow.cgColor
            flash.layer.borderWidth = 3
            flash.layer.cornerRadius = 6
            flash.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.12)
            self.addSubview(flash)
            UIView.animate(withDuration: 0.5, delay: 1.2, options: [], animations: { flash.alpha = 0 },
                           completion: { _ in flash.removeFromSuperview() })
        }
    }

    /// 改動的地方不在畫面上時，捲過去（旁頁也會切過去）
    private func reveal(pageID: UUID, pageRect: CGRect) {
        guard let row = model.notebook.rows.first(where: { $0.pages.contains { $0.id == pageID } }),
              let index = row.pages.firstIndex(where: { $0.id == pageID }),
              let rv = rowViews[row.id], rv.pageFrames.indices.contains(index) else { return }
        let pf = rv.pageFrames[index]
        let k = pf.width / max(row.pages[index].spec.width, 1)
        let target = pageRect.isNull ? CGRect(x: 0, y: 0, width: pf.width, height: pf.height)
            : CGRect(x: pageRect.minX * k, y: pageRect.minY * k, width: pageRect.width * k, height: pageRect.height * k)
        if rv.currentIndex != index {
            rv.currentIndex = index
            rv.setContentOffset(CGPoint(x: rv.offsetFor(index, inPage: 0), y: 0), animated: true)
        }
        let top = rv.frame.minY + pf.minY + target.minY
        let bottom = rv.frame.minY + pf.minY + target.maxY
        let visibleTop = outer.contentOffset.y
        let visibleBottom = visibleTop + outer.bounds.height
        if top >= visibleTop && bottom <= visibleBottom { return }            // 已經看得到就不動
        let y = clampOuterY((top + bottom) / 2 - outer.bounds.height / 2)
        outer.setContentOffset(CGPoint(x: outer.contentOffset.x, y: y), animated: true)
    }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { refocus() }
    }

    func refocus() {
        Task { @MainActor [weak self] in
            guard let self = self, self.window != nil else { return }
            self.becomeFirstResponder()
            if let tool = PenBoxModel.shared.currentTool {                    // 筆盒的工具優先
                self.setTool(tool, adaptive: PenBoxModel.shared.currentAdaptive)
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === holdTracker { return true }
        // 白板（v12.8.5）：雙指縮放可以跟捲動同時開始（開始縮放時才把捲動停掉），
        // 不然手指一動，捲動先接走，縮放就出不來，變成在移動
        if isBoard, gestureRecognizer === pinchGesture, other is UIPanGestureRecognizer {
            return true
        }
        // 文字框自己的點擊（手寫轉文字後系統會加回來）不能搶走「點旁邊退出」
        if gestureRecognizer === dismissTap, let v = other.view,
           sequence(first: v, next: { $0.superview }).contains(where: { $0 is TextBoxView }) {
            return true
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === pinchGesture { return true }   // 縮放：手指按在哪都算
        // 白板的圖釘、區塊標題、區塊的把手和工具列：自己處理觸控（v12.7）
        if let v = touch.view, sequence(first: v, next: { $0.superview }).contains(where: { $0 is BoardMarkView }) {
            return false
        }
        if let v = touch.view, v.isDescendant(of: pasteButton) { return false }
        if let viewer = imageViewer, let v = touch.view, v.isDescendant(of: viewer) { return false }   // 彈出的大圖
        if let menu = radialMenu, let v = touch.view, v.isDescendant(of: menu) { return false }   // 長按跳出的一圈按鈕
        if let v = touch.view, v.isDescendant(of: cropBar) { return false }      // 截圖選單上的按鈕
        if let v = touch.view, v.isDescendant(of: tapeDeleteButton) { return false }
        if let v = touch.view, v.isDescendant(of: regretBar) { return false }
        if let v = touch.view, v.isDescendant(of: textBar) { return false }      // 文字工具列上的按鈕
        if let v = touch.view, v.isDescendant(of: linkBar) { return false }      // 連線的小工具列（v12.14.0）
        if touch.view?.tag == TextBoxView.handleTag { return false }            // 文字方塊的角
        if touch.view?.tag == NotePageView.clipButtonTag { return false }       // 剪去白板的框的 →（v12.15.2）
        // Pencil 在文字方塊裡寫字（手寫轉文字）：不要當成畫線、停筆變形或套索
        if gestureRecognizer === holdTracker || gestureRecognizer === lassoPan,
           let v = touch.view, sequence(first: v, next: { $0.superview }).contains(where: { $0 is TextBoxView }) {
            return false
        }
        // 點在調整框上（控制點、圖形、操作列）的不算「點外面」
        if gestureRecognizer === dismissTap || gestureRecognizer === selectPress || gestureRecognizer === lassoPan,
           let editor = shapeEditor {
            return !editor.point(inside: touch.location(in: editor), with: nil)
        }
        if gestureRecognizer === dismissTap || gestureRecognizer === selectPress || gestureRecognizer === textTap,
           let editor = imageEditor, editor.point(inside: touch.location(in: editor), with: nil) {
            return false
        }
        return true
    }

    /// 選取某一頁上的幾筆筆跡，出現選取框
    /// allowLine：單獨一條直線（螢光筆、變形出來的直線）用兩端點的直線模式；套索一律用四角框
    /// images、texts：套索一起圈到的圖片、文字方塊，跟筆跡一起移動、縮放
    func showSelection(on pv: NotePageView, indices: [Int], allowLine: Bool = false, images: [ImageBox] = [],
                       texts: [SelectionEditorView.PickedText] = []) {
        dismissShapeEditor()
        endTextSelection()
        guard let editor = SelectionEditorView(pageView: pv, host: self, indices: indices,
                                               allowLine: allowLine, images: images, texts: texts) else { return }
        pv.addSubview(editor)
        shapeEditor = editor
        // 拖到別頁時選取框不會被蓋住：這一頁放到這一列的最上層（左右跨頁，v12.2），這一列放到所有列的最上層（上下跨頁）
        if let rv = pv.superview {
            rv.bringSubviewToFront(pv)
            rv.superview?.bringSubviewToFront(rv)
        }
    }

    // MARK: 拖著選取框到畫面上下邊緣：停一下就自動捲動

    private var autoScrollLink: CADisplayLink?
    private let scrollHint = UIImageView()                    // 自動捲動提示：出現 = 偵測到靠邊；變深 = 正在捲
    private var autoScrollSpeed: CGFloat = 0
    private var autoScrollSide = 0                            // 拖到左右邊緣：-1 捲到左邊那一頁、+1 右邊那一頁（v12.1）
    private var autoScrollAdds = false                        // 那個方向已經沒有頁面：停久一點就新增一張旁頁（v12.2）
    private var edgeSince: Date?

    func selectionDragged(to p: CGPoint, box r: CGRect) {
        let zone: CGFloat = 80                                  // 手指離上下邊緣 80 點以內
        let top = outer.frame.minY
        let bottom = outer.frame.maxY
        // 框碰到邊緣也算（框的上緣先碰到頂端時，手指通常還離邊緣很遠）；框比畫面還高時只看手指
        let box = r.isNull ? CGRect(origin: p, size: .zero) : r
        let useBox = box.height < outer.bounds.height * 0.8
        let up = max(useBox ? (top + 8 - box.minY) / 80 : 0, 1 - (p.y - top) / zone)
        let down = max(useBox ? (box.maxY - (bottom - 8)) / 80 : 0, 1 - (bottom - p.y) / zone)
        var speed: CGFloat = 0
        if up > 0 {
            speed = -min(1, max(0.35, up))
        } else if down > 0 {
            speed = min(1, max(0.35, down))
        }
        // 左右邊緣（v12.1）：手指離畫面左右邊緣 44 點以內，而且這一列那個方向還有頁面 → 停一下就捲到那一頁，放開就搬過去
        // 那個方向已經是這一列的最後一頁（v12.2）：停久一點（1.2 秒）就新增一張旁頁，再捲過去
        var side = 0
        var adds = false
        if speed == 0, !isBoard, let pv = shapeEditor?.pageView, let rv = pv.superview as? PageRowView {
            if p.x < 44 {
                side = -1
            } else if p.x > bounds.width - 44 {
                side = 1
            }
            if side != 0, !rv.ranges.indices.contains(rv.currentIndex + side) { adds = true }
        }
        guard speed != 0 || side != 0 else {
            stopAutoScroll()
            return
        }
        if side != autoScrollSide { edgeSince = nil }           // 換了方向：重新計時
        autoScrollSide = side
        autoScrollAdds = adds
        autoScrollSpeed = speed
        if edgeSince == nil { edgeSince = Date() }
        let config = UIImage.SymbolConfiguration(pointSize: 26, weight: .bold)
        scrollHint.tintColor = .systemBlue
        if side != 0 {
            let symbol = adds ? "plus.circle.fill" : (side < 0 ? "chevron.left.circle.fill" : "chevron.right.circle.fill")
            scrollHint.image = UIImage(systemName: symbol, withConfiguration: config)
            // 放在手指上方一點的那一側邊緣，不會被手擋住
            let hintY = min(max(p.y - 90, top + 8), bottom - 52)
            scrollHint.frame = CGRect(x: side < 0 ? 8 : bounds.width - 52, y: hintY, width: 44, height: 44)
        } else {
            scrollHint.image = UIImage(systemName: speed < 0 ? "chevron.up.circle.fill" : "chevron.down.circle.fill",
                                       withConfiguration: config)
            // 放在手指旁邊（預設左邊，手指太靠左就放右邊），不會被手擋住
            let hintX = p.x > 160 ? p.x - 100 : p.x + 100
            let clampedX = min(max(hintX, 30), bounds.width - 30)
            scrollHint.frame = CGRect(x: clampedX - 22, y: speed < 0 ? top + 8 : bottom - 52, width: 44, height: 44)
        }
        if scrollHint.superview == nil { addSubview(scrollHint) }
        bringSubviewToFront(scrollHint)
        scrollHint.isHidden = false
        scrollHint.alpha = 0.45
        if autoScrollLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(autoScrollStep))
            link.add(to: .main, forMode: .common)
            autoScrollLink = link
        }
    }

    func stopAutoScroll() {
        autoScrollLink?.invalidate()
        autoScrollLink = nil
        edgeSince = nil
        autoScrollSide = 0
        autoScrollAdds = false
        scrollHint.isHidden = true
    }

    @objc private func autoScrollStep() {
        // 上下停 0.4 秒才開始；左右換頁停久一點（0.6 秒）；要新增旁頁再久一點（1.2 秒）
        let wait: TimeInterval = autoScrollSide == 0 ? 0.4 : (autoScrollAdds ? 1.2 : 0.6)
        guard let since = edgeSince, Date().timeIntervalSince(since) > wait else { return }
        guard let editor = shapeEditor else {
            stopAutoScroll()
            return
        }
        if autoScrollSide != 0 {
            stepSideScroll(editor)
            return
        }
        let step = autoScrollSpeed * 16                         // 越靠邊越快，每格最多 16 點
        let oldY = outer.contentOffset.y
        let newY = clampOuterY(oldY + step)
        guard abs(newY - oldY) > 0.01 else { return }
        scrollHint.alpha = 1
        outer.setContentOffset(CGPoint(x: outer.contentOffset.x, y: newY), animated: false)
        editor.scrolled(by: newY - oldY)
    }

    /// 選取框拖到左右邊緣（v12.1）：這一列一格一格捲到隔壁那一頁（主頁、旁頁都可以），到了就停。
    /// 選取框跟著手指留在原地，放開後由 transferSelection 搬到那一頁
    private func stepSideScroll(_ editor: SelectionEditorView) {
        guard let pv = editor.pageView, let rv = pv.superview as? PageRowView else {
            stopAutoScroll()
            return
        }
        if isBoard {
            // 白板（v12.8）：沒有旁頁，拖到邊緣就是白板本身往那邊捲，到白板的邊為止
            guard rv.ranges.indices.contains(rv.currentIndex) else {
                stopAutoScroll()
                return
            }
            let r = rv.ranges[rv.currentIndex]
            let oldX = rv.contentOffset.x
            let newX = min(max(oldX + CGFloat(autoScrollSide) * 28, r.lo), r.hi)
            if newX == oldX {
                stopAutoScroll()
                return
            }
            scrollHint.alpha = 1
            rv.contentOffset.x = newX
            editor.scrolledSideways(by: newX - oldX)
            updateBoardWindow()
            return
        }
        if !rv.ranges.indices.contains(rv.currentIndex + autoScrollSide) {
            // 已經是最旁邊那一頁：新增一張旁頁（畫面先留在原地），下一格開始捲過去
            let rowID = rv.rowID
            guard autoScrollAdds, let r = model.notebook.rows.firstIndex(where: { $0.id == rowID }) else {
                stopAutoScroll()
                return
            }
            autoScrollAdds = false
            let row = model.notebook.rows[r]
            let main = row.pages[row.mainIndex]
            let page = NotePage(spec: main.spec, paper: main.paper)
            editor.prepareForRelayout()
            insertSidePage(rowID: rowID, at: autoScrollSide < 0 ? 0 : row.pages.count, page: page, jump: false)
            rv.bringSubviewToFront(pv)                          // 新的那一頁會蓋在上面：選取框所在的頁再放回最上層
            return
        }
        let target = rv.currentIndex + autoScrollSide
        guard rv.ranges.indices.contains(target) else {
            stopAutoScroll()
            return
        }
        // 往左：停在左邊那一頁的右緣；往右：停在右邊那一頁的左緣
        let goal: CGFloat = autoScrollSide < 0 ? rv.ranges[target].hi : rv.ranges[target].lo
        let oldX = rv.contentOffset.x
        var newX = oldX + CGFloat(autoScrollSide) * 28
        var arrived = false
        if autoScrollSide < 0, newX <= goal {
            newX = goal
            arrived = true
        }
        if autoScrollSide > 0, newX >= goal {
            newX = goal
            arrived = true
        }
        scrollHint.alpha = 1
        rv.contentOffset.x = newX
        editor.scrolledSideways(by: newX - oldX)
        if arrived {
            rv.currentIndex = target
            rowPageChanged(rv)
            stopAutoScroll()                                    // 到了；還要再往下一頁，手指動一下會重新計時
        }
    }

    /// 這一頁現在的圖片（選取框要用）
    func imagesNow(_ pageID: UUID) -> [ImageBox] {
        model.images(of: pageID)
    }

    /// 這一頁現在的文字方塊（選取框要用）
    func textsNow(_ pageID: UUID) -> [TextBox] {
        model.texts(of: pageID)
    }

    /// 選取框改了文字方塊（跟筆跡一起移動、縮放、刪除、複製）：寫進資料、更新畫面、登記復原
    func setTextsRecorded(_ texts: [TextBox], pageID: UUID) {
        let old = model.texts(of: pageID)
        guard old != texts else { return }
        model.setTexts(texts, pageID: pageID)
        pageViews[pageID]?.syncTexts(texts)
        history.registerUndo(withTarget: self) { notebook in
            notebook.restoreTexts(pageID: pageID, to: old)
        }
    }

    /// 選取框改了圖片（跟筆跡一起移動、縮放、刪除、複製）：寫進資料、更新畫面、登記復原
    func setImagesRecorded(_ images: [ImageBox], pageID: UUID) {
        let old = model.images(of: pageID)
        guard old != images else { return }
        model.setImages(images, pageID: pageID)
        pageViews[pageID]?.syncImages(images)
        history.registerUndo(withTarget: self) { notebook in
            notebook.restoreImages(pageID: pageID, to: old)
        }
    }

    /// 選取的東西拖到另一頁：搬過去（兩頁的變化合成一步復原）
    func transferSelection(_ editor: SelectionEditorView) -> Bool {
        guard let src = editor.pageView else { return false }
        let strokes = editor.currentStrokes()
        let pickedImages = editor.currentImages()                // 一起選到的圖片（v12.1）
        let pickedTexts = editor.currentTexts()                  // 一起選到的文字方塊（v12.2）
        var union = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        for box in pickedImages { union = union.union(SelectionEditorView.imageBounds(of: box)) }
        for item in pickedTexts { union = union.union(item.rect) }
        guard !union.isNull else { return false }
        let s1 = src.bounds.width / max(src.page.spec.width, 1)
        let center = src.convert(CGPoint(x: union.midX * s1, y: union.midY * s1), to: self)
        if src.bounds.contains(src.convert(center, from: self)) { return false }       // 還在原本這一頁
        guard let dst = pageViews.values.first(where: {
            $0 !== src && $0.bounds.contains($0.convert(center, from: self))
        }) else { return false }
        let s2 = dst.bounds.width / max(dst.page.spec.width, 1)
        // 來源頁座標 → 目標頁座標：p × s1 換成畫面位置，平移到目標頁，再 ÷ s2
        let o = src.convert(CGPoint.zero, to: dst)
        let k = s1 / s2
        let t = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: o.x / s2, ty: o.y / s2)
        let movedStrokes = strokes.map {
            PKStroke(ink: $0.ink, path: $0.path, transform: $0.transform.concatenating(t), mask: $0.mask)
        }
        var srcDrawing = editor.fullDrawing ?? src.canvas.drawing
        editor.endMovePreview(restore: false)
        for i in editor.indices.sorted(by: >) where srcDrawing.strokes.indices.contains(i) {
            srcDrawing.strokes.remove(at: i)
        }
        var dstDrawing = dst.canvas.drawing
        var newIndices: [Int] = []
        let markers = movedStrokes.filter { isHighlighter($0) }
        let others = movedStrokes.filter { !isHighlighter($0) }
        dstDrawing.strokes.insert(contentsOf: markers, at: 0)                  // 螢光筆放最下面
        newIndices.append(contentsOf: 0..<markers.count)
        let start = dstDrawing.strokes.count
        dstDrawing.strokes.append(contentsOf: others)
        newIndices.append(contentsOf: start..<(start + others.count))
        // 圖片：換算成目標頁的座標（位置、大小都照比例），從來源頁拿掉、加到目標頁
        let movedImages = pickedImages.map { (box: ImageBox) -> ImageBox in
            var copy = box
            let c = CGPoint(x: box.x + box.width / 2, y: box.y + box.height / 2).applying(t)
            copy.width = box.width * k
            copy.height = box.height * k
            copy.x = c.x - copy.width / 2
            copy.y = c.y - copy.height / 2
            return copy
        }
        let movedIDs = Set(movedImages.map { $0.id })
        let srcImages = model.images(of: src.page.id).filter { !movedIDs.contains($0.id) }
        let dstImages = model.images(of: dst.page.id) + movedImages
        // 文字方塊：位置、字級、寬度照比例換算，從來源頁拿掉、加到目標頁
        let movedTexts = pickedTexts.map { (item: SelectionEditorView.PickedText) -> SelectionEditorView.PickedText in
            var copy = item
            let origin = CGPoint(x: item.box.x, y: item.box.y).applying(t)
            copy.box.x = origin.x
            copy.box.y = origin.y
            copy.box.fontSize = item.box.fontSize * k
            copy.box.width = item.box.width * k
            if let fixed = item.box.fixedWidth { copy.box.fixedWidth = fixed * k }
            copy.rect = item.rect.applying(t)
            return copy
        }
        let movedTextIDs = Set(movedTexts.map { $0.box.id })
        let srcTexts = model.texts(of: src.page.id).filter { !movedTextIDs.contains($0.id) }
        let dstTexts = model.texts(of: dst.page.id) + movedTexts.map { $0.box }
        let hasStrokes = !editor.indices.isEmpty
        history.beginUndoGrouping()
        if hasStrokes {
            recordingSelection {
                src.setDrawingRecorded(srcDrawing)
                dst.setDrawingRecorded(dstDrawing)
            }
        }
        if !movedImages.isEmpty {
            setImagesRecorded(srcImages, pageID: src.page.id)
            setImagesRecorded(dstImages, pageID: dst.page.id)
        }
        if !movedTexts.isEmpty {
            setTextsRecorded(srcTexts, pageID: src.page.id)
            setTextsRecorded(dstTexts, pageID: dst.page.id)
        }
        history.endUndoGrouping()
        dismissShapeEditor()
        showSelection(on: dst, indices: newIndices.sorted(), allowLine: editor.lineMode, images: movedImages,
                      texts: movedTexts)
        return true
    }

    /// 找出某個位置（這個畫面的座標）下的筆跡
    private func stroke(at p: CGPoint) -> (NotePageView, Int)? {
        for pv in pageViews.values {
            let local = pv.convert(p, from: self)
            guard pv.bounds.contains(local) else { continue }
            let s = pv.bounds.width / max(pv.page.spec.width, 1)
            let pagePoint = CGPoint(x: local.x / s, y: local.y / s)
            if let i = StrokeHitTest.index(at: pagePoint, in: pv.canvas.drawing, tolerance: 14 / s) {
                return (pv, i)
            }
        }
        return nil
    }

    // 手指點一下：點到筆跡就選取，點到空白就退出編輯
    // 手指點一下：點到文字方塊就選取它；其他地方收起選取框和文字方塊（選取筆跡要長按或用套索）
    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        // 告訴其他開著的畫面（白板 ↔ 浮動視窗）：點了這裡，它們選取中的東西要結束（v12.15.2：視窗裡的空文字方塊點白板不會消失）
        NotificationCenter.default.post(name: NotebookView.surfaceTapped, object: self)
        hidePasteButton()
        let p = g.location(in: self)
        if cropMode {
            if let r = cropRectView, r.insetBy(dx: -12, dy: -12).contains(p) { return }
            clearCropRect()                                    // 點框外面：拿掉框，繼續截下一張（再按剪刀才離開）
            return
        }
        hideTapeDelete()
        let clipTap = clipHit(at: p)
        deselectClips(except: clipTap?.0)                      // 選著剪去白板的框：點別的地方就取消
        deselectLink()                                         // 選著一條連線：點別的地方就取消（點到線會在下面重新選）
        if frameMode, !frameToolOn {                           // 按了「新區塊」又不想拉了：手指點一下取消（筆盒的區塊工具不算）
            endFrameMode()
            showMessage("rectangle.dashed", "取消新區塊")
            return
        }
        if isBoard, boardPercent <= 0.3, let id = frameAt(p) {   // 縮到 30% 以下：點區塊裡面＝選取它（再點一次取消）
            hidePinBar()
            if selectedFrameID == id { deselectFrame() } else { selectFrame(id) }
            return
        }
        if selectedPinID != nil {                              // 白板：圖釘的工具列開著時點別的地方＝收起來
            hidePinBar()
            return
        }
        if selectedFrameID != nil {                            // 白板：選著區塊時點別的地方＝取消選取
            deselectFrame()
            return
        }
        // 點到紙膠帶：打開或遮住
        if let hit = tapeHit(at: p) {
            toggleTape(hit.1.id)
            return
        }
        if readOnly { return }                                 // 最近刪除裡打開的：文字、圖片都不能選
        if let tv = textBox(at: p) {
            if tv !== activeText {
                dismissShapeEditor()
                activate(tv, edit: false)
                if tv.box.isMarkdownPage {                     // Markdown 頁：點一下直接打字（v12.9.2）
                    tv.placeCursor(at: p, from: self)
                    textEditingChanged(tv)
                }
            } else {
                // 已經選取的方塊再點一下：在點的位置放游標，進入輸入（輸入中點也會移動游標）
                tv.placeCursor(at: p, from: self)
                textEditingChanged(tv)
            }
            return
        }
        // 點到圖片：選取它（可以移動、縮放、旋轉）；縮成小圖的：彈出大圖（v12.8.3）
        if let hit = imageHit(at: p) {
            // 白板上的筆記本卡片（v12.12.3）：點一下跟圖片一樣是選取；選取後左上角出現的按鈕才是打開（見 ImageEditorView）
            if hit.1.isMini {
                endTextSelection()
                endImageSelection()
                if hit.1.link != nil {
                    expandMiniImage(hit.1.id, pageID: hit.0.page.id)     // 被縮成小圖的卡片（v12.12.4）：點一下變回卡片
                    return
                }
                showImageViewer(hit.1, on: hit.0)
                return
            }
            if imageEditor?.box.id != hit.1.id {
                endTextSelection()
                selectImage(hit.1, on: hit.0)
            }
            return
        }
        // 點到文字方塊之間的連線（v12.14.0）：選取它，跳出小工具列（顏色、樣子、箭頭、走法、刪除）
        if let hit = linkHit(at: p) {
            endTextSelection()
            dismissShapeEditor()
            selectLink(hit.1, on: hit.0, at: p)
            return
        }
        // 剪去白板的框（v12.15.3，使用者要求）：點一下選取，右下角才出現 → 和顏色；再點一次取消
        if let hit = clipTap {
            endTextSelection()
            dismissShapeEditor()
            hit.0.selectClip(hit.0.selectedClipID == hit.1.id ? nil : hit.1.id)
            return
        }
        // Markdown 頁的空白處（文字下面）：接著最後面打字（v12.9.2）
        if markdownPageTap(at: p) { return }
        // 文字方塊：點旁邊直接結束（v12.11.0）。以前輸入中點旁邊會先退到「選取」（還留著外框和工具列），
        // 不小心點兩下跑出文字方塊的時候要再點一次才消得掉。要移動方塊：結束後點它一下（選取）再拖
        endTextSelection()
        dismissShapeEditor()
    }

    /// 點到 Markdown 頁的空白處：進入那一頁的 Markdown 方塊，游標放在最後面（像一般的文件）
    private func markdownPageTap(at p: CGPoint) -> Bool {
        guard !isBoard, let pv = pageViews.values.first(where: { $0.bounds.contains($0.convert(p, from: self)) }),
              let box = model.texts(of: pv.page.id).first(where: { $0.isMarkdownPage }),
              let tv = pv.textViews[box.id] else { return false }
        // 已經在打這一頁：照一般的規則（點旁邊 → 停止輸入 → 再點一次 → 看排好的樣子）
        if tv === activeText { return false }
        dismissShapeEditor()
        activate(tv, edit: true)
        let end = (tv.textView.text ?? "").utf16.count
        tv.textView.selectedRange = NSRange(location: end, length: 0)
        textEditingChanged(tv)
        return true
    }

    /// Markdown 頁寫超過頁底：這一頁往下長（每次半張 A4），結束輸入才長，不會打到一半整頁重排。
    /// v12.9.3 修正：以前拿輸入中的方塊大小算（輸入中方塊是整頁那麼大），每結束一次輸入就多長半頁。
    /// 現在用文字本身的高度；排好的圖出來之後（標題、表格的高度跟原文不一樣）再對一次
    private func growMarkdownPageIfNeeded(_ tv: TextBoxView) {
        guard !isBoard, tv.box.isMarkdownPage else { return }
        let pageID = tv.pageID
        let boxID = tv.box.id
        Task { @MainActor [weak self] in
            self?.checkMarkdownPageHeight(pageID: pageID, boxID: boxID)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.checkMarkdownPageHeight(pageID: pageID, boxID: boxID)
            // v12.9.7：長頁排版可能超過 2.5 秒，再對一次（那時排好的圖應該出來了）
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.checkMarkdownPageHeight(pageID: pageID, boxID: boxID)
        }
    }

    private func checkMarkdownPageHeight(pageID: UUID, boxID: UUID) {
        guard let loc = model.location(of: pageID),
              let box = model.texts(of: pageID).first(where: { $0.id == boxID }) else { return }
        if let tv = activeText, tv.pageID == pageID, tv.textView.isFirstResponder { return }   // 又在打字了：等下次結束再算
        let spec = model.notebook.rows[loc.row].pages[loc.page].spec
        let k = pageScaleFactor(spec)
        var textHeight = (box.text as NSString).boundingRect(
            with: CGSize(width: max(box.width, 20), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: TextBoxView.font(for: box, scale: 1)], context: nil).height
        if let image = MathRenderer.shared.cached(MathRenderer.request(for: box, pageWidth: spec.width)) {
            textHeight = image.size.height / MathRenderer.scaleFactor          // 排好的圖比較準
        }
        let unit = 421 * k
        var needed = box.y + textHeight + TextBoxView.insetY * 2 + 48 * k
        // 頁上的筆跡、圖片也要留著（縮短時不能切到）
        let page = model.notebook.rows[loc.row].pages[loc.page]
        let drawing = pageViews[pageID]?.canvas.drawing ?? Store.loadDrawing(pageID)
        if !drawing.strokes.isEmpty { needed = max(needed, drawing.bounds.maxY + 24 * k) }
        for image in page.images ?? [] { needed = max(needed, image.y + image.height + 24 * k) }
        // v12.9.7：紙膠帶、其他文字方塊、釘在這一頁的圖釘也不能被切到
        for tape in page.tapes ?? [] { needed = max(needed, tape.y + tape.height + 24 * k) }
        for other in page.texts ?? [] where other.id != boxID { needed = max(needed, other.y + other.fontSize * 2 * k + 24 * k) }
        for pin in model.notebook.pins ?? [] where pin.pageID == pageID { needed = max(needed, pin.y + 40 * k) }
        // 最短一張 A4 的比例；超過就以半張 A4 為單位長（文字刪短了也會縮回來，v12.9.3）
        let minHeight = round(spec.width * 842 / 595)
        let newHeight = max(minHeight, (needed / unit).rounded(.up) * unit)
        guard abs(newHeight - spec.height) > 1 else { return }
        let growing = newHeight > spec.height
        model.notebook.rows[loc.row].pages[loc.page].spec.height = newHeight
        model.save()
        unloadPageView(pageID)
        rebuild()
        showMessage(growing ? "arrow.down.to.line" : "arrow.up.to.line", growing ? "Markdown 頁往下長了一些" : "Markdown 頁縮回來了一些")
    }

    /// 輸入中不能直接拖方塊（要拖工具列的四向箭頭）；只選取時可以直接拖
    func textEditingChanged(_ tv: TextBoxView) {
        guard tv === activeText else { return }
        let editing = tv.textView.isFirstResponder
        textDrag.isEnabled = !editing && !tv.box.isLocked    // 選取：直接拖方塊（固定的不行）
        textCursorPress.isEnabled = editing              // 輸入中：按住拖動游標
        positionTextBar()
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if readOnly { return }                                 // 最近刪除裡打開的：只能看
        if cropMode { return }                                 // 剪刀開著（v12.15.2）：點兩下不新增文字方塊
        NotificationCenter.default.post(name: NotebookView.surfaceTapped, object: self)
        let p = g.location(in: self)
        if let tv = textBox(at: p) {
            // 點兩下文字方塊：直接進入輸入，游標放在點的位置
            if tv !== activeText {
                dismissShapeEditor()
                activate(tv, edit: false)
            }
            tv.placeCursor(at: p, from: self)
            textEditingChanged(tv)
            return
        }
        dismissShapeEditor()
        createText(at: p)
    }

    // MARK: 文字方塊

    private(set) weak var activeText: TextBoxView?
    private var textSnapshot: (pageID: UUID, texts: [TextBox])?   // 選取前的樣子（結束時合成一步復原）
    private lazy var textBar = TextBar(host: self)
    private var moveStart = CGPoint.zero

    private func textBox(at p: CGPoint) -> TextBoxView? {
        for pv in pageViews.values {
            for tv in pv.textViews.values {
                if tv.convert(tv.frameRect, to: self).insetBy(dx: -6, dy: -6).contains(p) { return tv }
            }
        }
        return nil
    }

    /// 新文字的顏色看背景：淺色紙、課本用黑色；深色紙、封面用白色（pdf = true 代表淺色背景）
    private func defaultTextRGBA(pdf: Bool) -> [Double] {
        pdf ? [0, 0, 0, 1] : [1, 1, 1, 1]
    }

    private func createText(at p: CGPoint) {
        guard let pv = pageViews.values.first(where: { $0.bounds.contains($0.convert(p, from: self)) }) else { return }
        if model.texts(of: pv.page.id).contains(where: { $0.isMarkdownPage }) {
            _ = markdownPageTap(at: p)                         // Markdown 頁不另外加方塊，直接在整頁的方塊裡打字
            return
        }
        endTextSelection()
        let s = pv.bounds.width / max(pv.page.spec.width, 1)
        let local = pv.convert(p, from: self)
        var box = TextBox()
        // 預設字級、顏色（「⋯ → 文字方塊預設」可以改）；大頁面的字跟著放大，看起來一樣大
        box.fontSize = TextDefaults.size(model.meta.id) * pageScaleFactor(pv.page.spec)
        box.bold = TextDefaults.bold(model.meta.id)
        box.x = min(max(local.x / s, 0), max(pv.page.spec.width - 40, 0))
        box.y = min(max(local.y / s - box.fontSize * 0.7, 0), max(pv.page.spec.height - 30, 0))
        let darkPage = pv.page.isDarkBackground
        box.rgba = TextDefaults.rgba(model.meta.id) ?? defaultTextRGBA(pdf: !darkPage)
        // 存成預設的外框樣式（v12.13.0；「卡片樣式」面板的「存成預設」）
        if let style = TextStyleDefault.load(), style.fill != nil {
            box.fill = style.fill
            box.fillMode = style.fillMode
            box.shape = style.shape
            box.rgba = TextBoxStyle.readable(text: box.rgba, fill: box.fill, mode: box.fillMode)
        }
        let before = model.texts(of: pv.page.id)
        model.setTexts(before + [box], pageID: pv.page.id)
        pv.syncTexts(model.texts(of: pv.page.id))
        guard let tv = pv.textViews[box.id] else { return }
        textSnapshot = (pv.page.id, before)
        // v12.12.3（使用者要求，照 GUGA）：點兩下只建一個空白的框（裡面有「輸入文字」的提示），先是選取的狀態；
        // 再點一下框裡面才開始輸入。點旁邊：空的框自動消失
        activate(tv, edit: false)
    }

    private func activate(_ tv: TextBoxView, edit: Bool) {
        deselectLink()
        if activeText !== tv {
            if activeText != nil { endTextSelection() }
            if textSnapshot?.pageID != tv.pageID || textSnapshot == nil {
                textSnapshot = (tv.pageID, model.texts(of: tv.pageID))
            }
        }
        activeText = tv
        tv.onChange = { [weak self, weak tv] in
            guard let self = self, let tv = tv else { return }
            self.commit(tv)
        }
        tv.setActive(true)
        if edit { tv.textView.becomeFirstResponder() }
        if textBar.superview == nil { addSubview(textBar) }
        bringSubviewToFront(textBar)
        textBar.refresh(tv.box, size: displaySize(tv))
        positionTextBar()
        // 只選取（沒在輸入）時可以直接拖方塊移動；輸入中按住拖動游標
        if textDrag.view !== tv {
            textDrag.view?.removeGestureRecognizer(textDrag)
            tv.addGestureRecognizer(textDrag)
        }
        if textCursorPress.view !== tv {
            textCursorPress.view?.removeGestureRecognizer(textCursorPress)
            tv.addGestureRecognizer(textCursorPress)
        }
        tv.onEditingChanged = { [weak self, weak tv] in
            guard let self = self, let tv = tv else { return }
            self.textEditingChanged(tv)
        }
        tv.onResize = { [weak self] x, width in
            self?.updateActive { box in
                box.x = x
                box.fixedWidth = width
            }
        }
        tv.onLink = { [weak self, weak tv] side, state, point in
            guard let self = self, let tv = tv else { return }
            self.handleLink(tv, side: side, state: state, at: point)
        }
        textDrag.isEnabled = !edit && !tv.textView.isFirstResponder && !tv.box.isLocked
        textCursorPress.isEnabled = edit || tv.textView.isFirstResponder
    }

    /// 輸入中：手指按住一下再拖，移動游標
    private lazy var textCursorPress: UILongPressGestureRecognizer = {
        let g = UILongPressGestureRecognizer(target: self, action: #selector(handleCursorPress(_:)))
        g.minimumPressDuration = 0.25
        g.allowedTouchTypes = NotebookView.fingerOnly
        g.delegate = textDragYield
        return g
    }()

    @objc private func handleCursorPress(_ g: UILongPressGestureRecognizer) {
        guard let tv = activeText, tv.textView.isFirstResponder else { return }
        switch g.state {
        case .began, .changed:
            tv.placeCursor(at: g.location(in: self), from: self)
        default:
            break
        }
    }

    /// 文字方塊的拖曳（手指）：捲動要等它先判斷
    private lazy var textDrag: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(textMovePan(_:)))
        g.allowedTouchTypes = NotebookView.fingerOnly
        g.delegate = textDragYield
        return g
    }()
    private let textDragYield = ScrollYield()

    /// 結束文字方塊的選取：空的方塊拿掉；這段期間的所有改動合成一步復原
    func endTextSelection() {
        guard let tv = activeText else { return }
        activeText = nil
        tv.onChange = nil
        tv.textView.resignFirstResponder()
        tv.setActive(false)
        textBar.removeFromSuperview()
        tv.removeGestureRecognizer(textDrag)
        tv.removeGestureRecognizer(textCursorPress)
        tv.onEditingChanged = nil
        tv.onResize = nil
        tv.onLink = nil
        pageViews[tv.pageID]?.hideLinkPreview()
        var texts = model.texts(of: tv.pageID)
        growMarkdownPageIfNeeded(tv)
        // 空的方塊拿掉；有線接著的留著（v12.13.0：從點拉出來的新方塊還沒打字，也要看得到）
        if let i = texts.firstIndex(where: { $0.id == tv.box.id }), !texts[i].isMarkdownPage,   // Markdown 頁的方塊空了也留著
           !tv.linked,
           texts[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            texts.remove(at: i)
            model.setTexts(texts, pageID: tv.pageID)
            pageViews[tv.pageID]?.syncTexts(texts)
        }
        if let snap = textSnapshot, snap.pageID == tv.pageID, snap.texts != texts {
            let pageID = snap.pageID
            let old = snap.texts
            history.registerUndo(withTarget: self) { notebook in
                notebook.restoreTexts(pageID: pageID, to: old)
            }
        }
        textSnapshot = nil
    }

    /// 復原、重做文字方塊
    func restoreTexts(pageID: UUID, to texts: [TextBox]) {
        endTextSelection()
        if let editor = shapeEditor, editor.hasTexts {          // 選取框裡的文字方塊要變回去了：先收起來（v12.2）
            editor.removeFromSuperview()
            shapeEditor = nil
        }
        let current = model.texts(of: pageID)
        model.setTexts(texts, pageID: pageID)
        pageViews[pageID]?.syncTexts(texts)
        history.registerUndo(withTarget: self) { notebook in
            notebook.restoreTexts(pageID: pageID, to: current)
        }
        // 跳回改動的地方
        var rect = CGRect.null
        for t in texts where !current.contains(t) { rect = rect.union(CGRect(x: t.x, y: t.y, width: t.width + 10, height: t.fontSize * 1.5)) }
        for t in current where !texts.contains(t) { rect = rect.union(CGRect(x: t.x, y: t.y, width: t.width + 10, height: t.fontSize * 1.5)) }
        reveal(pageID: pageID, pageRect: rect)
    }

    /// 文字方塊的內容改了：寫回資料
    private func commit(_ tv: TextBoxView) {
        var texts = model.texts(of: tv.pageID)
        if let i = texts.firstIndex(where: { $0.id == tv.box.id }) {
            texts[i] = tv.box
        } else {
            texts.append(tv.box)
        }
        model.setTexts(texts, pageID: tv.pageID)
        textBar.refresh(tv.box, size: displaySize(tv))
        positionTextBar()
    }

    private func updateActive(_ change: (inout TextBox) -> Void) {
        guard let tv = activeText else { return }
        var box = tv.box
        change(&box)
        tv.update(box)
        commit(tv)
    }

    /// 捲到看不到文字方塊那一頁：自動結束（跟按完成到底一樣，改動合成一步復原）
    private func endTextIfScrolledAway() {
        guard let tv = activeText else { return }
        guard let pv = pageViews[tv.pageID], pv.window != nil else {
            endTextSelection()
            return
        }
        let page = pv.convert(pv.bounds, to: self)
        if !page.intersects(bounds) { endTextSelection() }
    }

    /// 文字工具列放在方塊下面（下面放不下就放上面）
    /// 畫面下面被擋住多少（v12.9.8）：筆盒停在下面時約 110 點。選取框、文字方塊的工具列用它決定要不要改放上面
    var bottomObstruction: CGFloat {
        let box = PenBoxModel.shared
        return (box.dock == .bottom && !box.minimized) ? 110 : 0
    }

    func positionTextBar() {
        positionLinkBar()
        guard let tv = activeText, textBar.superview != nil else { return }
        let r = tv.convert(tv.frameRect, to: self)
        // v12.13.0：多了「卡片樣式」一顆（630 → 674）；畫面比較窄（浮動視窗裡）就縮到放得下
        let size = CGSize(width: min(674, max(bounds.width - 16, 320)), height: 44)
        var y: CGFloat
        if tv.textView.isFirstResponder {
            // 輸入中：放在文字上面，盡量不擋到要寫字的地方
            y = r.minY - 12 - size.height
            if y < 8 { y = r.maxY + 12 }
        } else {
            // 選取中：方塊四邊外面有連線用的點，工具列再往外讓一點
            y = r.maxY + 36
            if y + size.height > bounds.height - 8 - bottomObstruction { y = r.minY - 36 - size.height }
        }
        // v12.9.8：鍵盤出來時不要被鍵盤蓋住
        if keyboardOverlap > 0 { y = min(y, bounds.height - keyboardOverlap - size.height - 8) }
        // v12.13.0：筆盒停在左邊或右邊時，工具列不要鑽到筆盒底下（最後面的刪除、完成會按不到）。
        // 只有這個畫面真的貼著螢幕那一邊才算（浮動視窗裡的不算）
        var left: CGFloat = 8
        var right: CGFloat = 8
        let pens = PenBoxModel.shared
        if !pens.minimized, let w = window {
            let edges = convert(bounds, to: w)
            if pens.dock == .leading, edges.minX < 40 { left = 76 }
            if pens.dock == .trailing, edges.maxX > w.bounds.width - 40 { right = 76 }
        }
        var x = min(max(r.midX - size.width / 2, left), max(left, bounds.width - size.width - right))
        if x + size.width > bounds.width - right { x = max(8, bounds.width - size.width - 8) }   // 畫面太窄：讓不開就算了
        textBar.frame = CGRect(x: x, y: max(8, y), width: size.width, height: size.height)
    }

    // MARK: 文字方塊的外框樣式、連線（v12.13.0；TextLinks.swift）

    /// 工具列的調色盤：跳出「卡片樣式」面板（顏色的用法、顏色、形狀；套用預設、存成預設、清除）
    func showTextStyle() {
        guard let tv = activeText else { return }
        if tv.textView.isFirstResponder {                       // 輸入中：先退到選取（面板出來時鍵盤收起來）
            tv.textView.resignFirstResponder()
            textEditingChanged(tv)
        }
        let box = tv.box
        // 有連線的方塊：面板多一顆「一鍵整理」（跟它連在一起的全部）
        var tidy: (() -> Void)?
        if tv.linked {
            let pageID = tv.pageID
            let start = box.id
            tidy = { [weak self] in
                guard let self = self else { return }
                self.stylePanel?.dismiss(animated: true)
                self.tidyTexts(self.connectedTexts(from: start, pageID: pageID), pageID: pageID)
            }
        }
        let panel = TextStylePanel(fill: box.fill, mode: box.fillMode ?? 0, shape: box.shape ?? 1, tidy: tidy) { [weak self] fill, mode, shape in
            self?.applyTextStyle(fill: fill, mode: mode, shape: shape)
        }
        let vc = UIHostingController(rootView: panel)
        stylePanel = vc
        vc.modalPresentationStyle = .popover
        vc.preferredContentSize = CGSize(width: 300, height: tidy == nil ? 500 : 548)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = textBar
            pop.sourceRect = textBar.styleButton.frame
            pop.permittedArrowDirections = [.up, .down]
        }
        Presenter.present(vc)
    }

    private weak var stylePanel: UIViewController?

    // MARK: 選取一條連線、改它的樣子（v12.14.0）

    private var selectedLink: (pageID: UUID, id: UUID, at: CGPoint)?   // at：點到的地方（頁面座標），小工具列放在它上面
    private lazy var linkBar = LinkBar(host: self)

    private func linkHit(at p: CGPoint) -> (NotePageView, BoxLink)? {
        for pv in pageViews.values {
            let local = pv.convert(p, from: self)
            guard pv.bounds.contains(local) else { continue }
            if let link = pv.linkHit(at: local) { return (pv, link) }
        }
        return nil
    }

    private func selectLink(_ link: BoxLink, on pv: NotePageView, at p: CGPoint) {
        let s = max(pv.bounds.width / max(pv.page.spec.width, 1), 0.0001)
        let local = pv.convert(p, from: self)
        selectedLink = (pv.page.id, link.id, CGPoint(x: local.x / s, y: local.y / s))
        pv.selectedLink = link.id
        if linkBar.superview == nil { addSubview(linkBar) }
        bringSubviewToFront(linkBar)
        linkBar.refresh(link)
        positionLinkBar()
    }

    func deselectLink() {
        guard let chosen = selectedLink else { return }
        selectedLink = nil
        pageViews[chosen.pageID]?.selectedLink = nil
        linkBar.removeFromSuperview()
    }

    private func positionLinkBar() {
        guard let chosen = selectedLink, linkBar.superview != nil else { return }
        guard let pv = pageViews[chosen.pageID], pv.window != nil else {
            deselectLink()
            return
        }
        let s = pv.bounds.width / max(pv.page.spec.width, 1)
        let p = convert(CGPoint(x: chosen.at.x * s, y: chosen.at.y * s), from: pv)
        let size = LinkBar.size
        var y = p.y - 26 - size.height
        if y < 8 { y = p.y + 26 }
        let x = min(max(p.x - size.width / 2, 8), max(8, bounds.width - size.width - 8))
        linkBar.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 改連線並登記一步復原
    private func setLinksRecorded(_ links: [BoxLink], pageID: UUID) {
        let old = model.links(of: pageID)
        guard old != links else { return }
        model.setLinks(links, pageID: pageID)
        pageViews[pageID]?.syncLinks(links)
        history.registerUndo(withTarget: self) { notebook in
            notebook.deselectLink()
            notebook.setLinksRecorded(old, pageID: pageID)
        }
    }

    /// 小工具列改選取中那一條線的樣子
    func updateSelectedLink(_ change: (inout BoxLink) -> Void) {
        guard let chosen = selectedLink else { return }
        var links = model.links(of: chosen.pageID)
        guard let i = links.firstIndex(where: { $0.id == chosen.id }) else { return }
        change(&links[i])
        setLinksRecorded(links, pageID: chosen.pageID)
        linkBar.refresh(links[i])
    }

    func deleteSelectedLink() {
        guard let chosen = selectedLink else { return }
        var links = model.links(of: chosen.pageID)
        links.removeAll { $0.id == chosen.id }
        deselectLink()
        setLinksRecorded(links, pageID: chosen.pageID)
    }

    // MARK: 一鍵整理（v12.14.0，使用者要求：畫很大的時候圈選起來一鍵校正——連線多的給顏色、字放大）

    /// 跟某個方塊連在一起的全部方塊（順著線一直找）
    private func connectedTexts(from start: UUID, pageID: UUID) -> Set<UUID> {
        let links = model.links(of: pageID)
        var seen: Set<UUID> = [start]
        var queue = [start]
        while let id = queue.popLast() {
            for link in links where link.from == id || link.to == id {
                let other = link.from == id ? link.to : link.from
                if seen.insert(other).inserted { queue.append(other) }
            }
        }
        return seen
    }

    /// 整理一群文字方塊（套索圈到的，或跟某個方塊連在一起的全部）。v12.15.0（使用者：要考慮更多層、也要整理位置）：
    ///   1. 層級：每一群連在一起的方塊找一個「根」（沒有線指向它、接最多線的那個），從根順著線一層一層往外算第幾層。
    ///   2. 樣子照層級：第 0 層深藍填滿、粗體、字 1.5 倍；第 1 層淡紫藍填滿、粗體、1.25 倍；第 2 層淡紫藍外框、1.1 倍；
    ///      第 3 層以後灰色外框、原本大小。沒有接線的只換成灰色外框。字的大小以這一群裡最小的為準（再整理一次結果一樣）。
    ///   3. 位置：排成一棵樹。原本的線大多是左右接的就往右（或往左）長，大多是上下接的就往下（或往上）長；
    ///      同一層對齊成一欄（一列），下一層的方塊照原本的上下（左右）順序排在上一層的旁邊，根留在原本的位置。
    ///   4. 線改接到兩個方塊互相面對的那兩邊。整個算一步復原
    func tidyTexts(_ ids: Set<UUID>, pageID: UUID) {
        guard !readOnly, let page = model.page(pageID) else { return }
        endTextSelection()
        dismissShapeEditor()
        deselectLink()
        var texts = model.texts(of: pageID)
        var links = model.links(of: pageID)
        let chosen = Set(texts.filter { ids.contains($0.id) && !$0.isMarkdownPage }.map { $0.id })
        let inner = links.filter { chosen.contains($0.from) && chosen.contains($0.to) && $0.from != $0.to }
        guard chosen.count >= 2, !inner.isEmpty else {
            showMessage("wand.and.stars", "圈到的文字方塊之間沒有連線，沒有東西可以整理")
            return
        }
        var neighbors: [UUID: [UUID]] = [:]
        var indegree: [UUID: Int] = [:]
        var degree: [UUID: Int] = [:]
        var sideVotes = 0                                          // 左右接的線 +1、上下接的 -1
        for link in inner {
            neighbors[link.from, default: []].append(link.to)
            neighbors[link.to, default: []].append(link.from)
            indegree[link.to, default: 0] += 1
            degree[link.from, default: 0] += 1
            degree[link.to, default: 0] += 1
            sideVotes += (link.fromSide == 1 || link.fromSide == 3) ? 1 : -1
        }
        var index: [UUID: Int] = [:]
        for (i, t) in texts.enumerated() { index[t.id] = i }
        var original: [UUID: CGRect] = [:]
        for t in texts where chosen.contains(t.id) { original[t.id] = PageRenderer.textFrameRect(t, page: page) }
        let horizontal = true                                     // 心智圖：一律往左右長（v12.15.1）
        _ = sideVotes
        func mainCenter(_ r: CGRect) -> CGFloat { horizontal ? r.midX : r.midY }
        func crossCenter(_ r: CGRect) -> CGFloat { horizontal ? r.midY : r.midX }

        // 1. 每一群：找根，從根往外一層一層（BFS）
        var depth: [UUID: Int] = [:]
        var children: [UUID: [UUID]] = [:]
        var roots: [UUID] = []
        var unvisited = Set(chosen.filter { (degree[$0] ?? 0) > 0 })
        while let start = unvisited.first {
            var group: Set<UUID> = [start]
            var stack = [start]
            while let id = stack.popLast() {
                for other in neighbors[id] ?? [] where group.insert(other).inserted { stack.append(other) }
            }
            unvisited.subtract(group)
            let root = group.max { a, b in
                let ka = ((indegree[a] ?? 0) == 0 ? 1 : 0, degree[a] ?? 0)
                let kb = ((indegree[b] ?? 0) == 0 ? 1 : 0, degree[b] ?? 0)
                return ka.0 != kb.0 ? ka.0 < kb.0 : ka.1 < kb.1
            } ?? start
            roots.append(root)
            depth[root] = 0
            var queue = [root]
            var head = 0
            while head < queue.count {
                let id = queue[head]
                head += 1
                let next = (neighbors[id] ?? []).filter { depth[$0] == nil }
                let ordered = Array(Set(next)).sorted { a, b in
                    crossCenter(original[a] ?? CGRect.zero) < crossCenter(original[b] ?? CGRect.zero)
                }
                for child in ordered {
                    depth[child] = (depth[id] ?? 0) + 1
                    children[id, default: []].append(child)
                    queue.append(child)
                }
            }
        }
        let maxDepth = depth.values.max() ?? 0

        // 2. 樣子
        let hubFill: [Double] = [0.27, 0.33, 0.83]
        let midFill: [Double] = [0.53, 0.58, 0.95]
        let leafFill: [Double] = [0.5, 0.5, 0.5]
        func factor(_ level: Int?) -> CGFloat {
            switch level {
            case 0?: return 1.5
            case 1?: return 1.25
            case 2?: return 1.1
            default: return 1
            }
        }
        func styleFill(_ level: Int?) -> ([Double], Int) {
            switch level {
            case 0?: return (hubFill, 0)
            case 1?: return (midFill, 0)
            case 2?: return (midFill, 2)
            default: return (leafFill, 2)
            }
        }
        // 原本的字級：整理過的方塊（tidyLevel 記著當時排在第幾層）先除掉當時放大的倍數，所以再整理一次結果一樣
        var base = CGFloat.greatestFiniteMagnitude
        for t in texts where chosen.contains(t.id) {
            let before: Int? = (t.tidyLevel ?? -1) >= 0 ? t.tidyLevel : nil
            base = min(base, t.fontSize / factor(before))
        }
        if base == CGFloat.greatestFiniteMagnitude { base = 16 }
        base = (base * 100).rounded() / 100                    // 去掉除法的小誤差，再整理一次才會一模一樣
        let plain: [Double] = page.isDarkBackground ? [1, 1, 1, 1] : [0, 0, 0, 1]
        for i in texts.indices where chosen.contains(texts[i].id) {
            let level = depth[texts[i].id]
            var size = base
            var bold = false
            var fill = leafFill
            var mode = 2
            switch level {
            case 0?:
                size = base * 1.5
                bold = true
                fill = hubFill
                mode = 0
            case 1?:
                size = base * 1.25
                bold = true
                fill = midFill
                mode = 0
            case 2?:
                size = base * 1.1
                fill = midFill
            default:
                break
            }
            let ratio = size / max(texts[i].fontSize, 1)
            texts[i].tidyLevel = level ?? -1
            texts[i].fontSize = size
            texts[i].bold = bold
            texts[i].fill = fill
            texts[i].fillMode = mode
            texts[i].shape = texts[i].shape ?? 1
            texts[i].rgba = TextBoxStyle.readable(text: plain, fill: fill, mode: mode)
            texts[i].width *= ratio
            if let fixed = texts[i].fixedWidth { texts[i].fixedWidth = fixed * ratio }
        }
        var sizes: [UUID: CGSize] = [:]
        for t in texts where chosen.contains(t.id) { sizes[t.id] = PageRenderer.textFrameRect(t, page: page).size }
        func mainSize(_ id: UUID) -> CGFloat { horizontal ? (sizes[id]?.width ?? 0) : (sizes[id]?.height ?? 0) }
        func crossSize(_ id: UUID) -> CGFloat { horizontal ? (sizes[id]?.height ?? 0) : (sizes[id]?.width ?? 0) }

        // 3. 位置（v12.15.1，使用者：要有心智圖的感覺、太擠）：根留在原本的位置，第一層分到左右兩邊
        //    （原本就在根左邊的放左邊，其他的讓兩邊差不多一樣多），每一邊往外一層一層長、同一層對齊成一欄；間距比較寬
        let gapMain = base * 4.5
        let gapCross = base * 1.6
        func width(_ id: UUID) -> CGFloat { sizes[id]?.width ?? 0 }
        func height(_ id: UUID) -> CGFloat { sizes[id]?.height ?? 0 }
        var target: [UUID: CGRect] = [:]
        var sideOf: [UUID: CGFloat] = [:]                          // 在根的右邊 +1、左邊 −1、根 0
        var membersOf: [UUID: [UUID]] = [:]                        // 每一群有哪些方塊
        for root in roots {
            guard let rootRect = original[root] else { continue }
            var span: [UUID: CGFloat] = [:]
            func measure(_ id: UUID) -> CGFloat {
                let kids = children[id] ?? []
                var total: CGFloat = 0
                for (k, child) in kids.enumerated() { total += measure(child) + (k > 0 ? gapCross : 0) }
                let value = max(height(id), total)
                span[id] = value
                return value
            }
            let firsts = (children[root] ?? []).sorted { (original[$0]?.midY ?? 0) < (original[$1]?.midY ?? 0) }
            for c in firsts { _ = measure(c) }
            let half = firsts.reduce(CGFloat(0)) { $0 + (span[$1] ?? 0) } / 2
            var right: [UUID] = []
            var left: [UUID] = []
            var rightSpan: CGFloat = 0
            var leftSpan: CGFloat = 0
            var pending: [UUID] = []
            for c in firsts {
                if (original[c]?.midX ?? 0) < rootRect.minX {
                    left.append(c)
                    leftSpan += span[c] ?? 0
                } else {
                    pending.append(c)
                }
            }
            for c in pending {
                let size = span[c] ?? 0
                if rightSpan + size / 2 <= half || leftSpan >= half || pending.count == 1 {
                    right.append(c)
                    rightSpan += size
                } else {
                    left.append(c)
                    leftSpan += size
                }
            }
            left.sort { (original[$0]?.midY ?? 0) < (original[$1]?.midY ?? 0) }
            let rootSize = sizes[root] ?? rootRect.size
            target[root] = CGRect(x: rootRect.midX - rootSize.width / 2, y: rootRect.midY - rootSize.height / 2,
                                  width: rootSize.width, height: rootSize.height)
            sideOf[root] = 0
            membersOf[root] = [root]
            for (kids, dir) in [(right, CGFloat(1)), (left, CGFloat(-1))] where !kids.isEmpty {
                // 這一邊每一層最寬多少 → 每一層靠根那一邊離根中心多遠
                var levelW: [Int: CGFloat] = [:]
                var stack = kids
                while let id = stack.popLast() {
                    let d = depth[id] ?? 1
                    levelW[d] = max(levelW[d] ?? 0, width(id))
                    stack.append(contentsOf: children[id] ?? [])
                }
                var edge: [Int: CGFloat] = [:]
                var cursor = rootSize.width / 2 + gapMain
                for d in 1 ... max(levelW.keys.max() ?? 1, 1) {
                    edge[d] = cursor
                    cursor += (levelW[d] ?? 0) + gapMain
                }
                func put(_ id: UUID, _ top: CGFloat) {
                    let mine = span[id] ?? height(id)
                    let w = width(id)
                    let h = height(id)
                    let near = rootRect.midX + dir * (edge[depth[id] ?? 1] ?? 0)
                    target[id] = CGRect(x: dir > 0 ? near : near - w, y: top + mine / 2 - h / 2, width: w, height: h)
                    sideOf[id] = dir
                    membersOf[root, default: []].append(id)
                    let sub = children[id] ?? []
                    var total: CGFloat = 0
                    for (k, child) in sub.enumerated() { total += (span[child] ?? 0) + (k > 0 ? gapCross : 0) }
                    var y = top + (mine - total) / 2
                    for child in sub {
                        put(child, y)
                        y += (span[child] ?? 0) + gapCross
                    }
                }
                var sideTotal: CGFloat = 0
                for (k, c) in kids.enumerated() { sideTotal += (span[c] ?? 0) + (k > 0 ? gapCross : 0) }
                var y = rootRect.midY - sideTotal / 2
                for c in kids {
                    put(c, y)
                    y += (span[c] ?? 0) + gapCross
                }
            }
        }
        // 不同群之間不要疊在一起（v12.15.2）：照原本的上下順序，後面的群跟前面的重疊就往下移
        var placedBoxes: [CGRect] = []
        let orderedRoots = roots.sorted { (original[$0]?.midY ?? 0) < (original[$1]?.midY ?? 0) }
        for root in orderedRoots {
            let members = membersOf[root] ?? []
            var box = CGRect.null
            for id in members { if let r = target[id] { box = box.union(r) } }
            guard !box.isNull else { continue }
            var shift: CGFloat = 0
            var moved = true
            var guardCount = 0
            while moved && guardCount < 50 {
                moved = false
                guardCount += 1
                let now = box.offsetBy(dx: 0, dy: shift)
                for other in placedBoxes where now.insetBy(dx: -gapCross, dy: -gapCross).intersects(other) {
                    shift += other.maxY + gapCross * 2 - now.minY
                    moved = true
                    break
                }
            }
            if shift != 0 {
                for id in members { if let r = target[id] { target[id] = r.offsetBy(dx: 0, dy: shift) } }
            }
            placedBoxes.append(box.offsetBy(dx: 0, dy: shift))
        }
        for (id, rect) in target {
            guard let i = index[id] else { continue }
            let now = PageRenderer.textFrameRect(texts[i], page: page)
            texts[i].x = (max(texts[i].x + rect.minX - now.minX, 0) * 2).rounded() / 2   // 對齊半點：再整理一次位置一模一樣
            texts[i].y = (max(texts[i].y + rect.minY - now.minY, 0) * 2).rounded() / 2
        }
        // 沒接線的：中心不動
        for i in texts.indices where chosen.contains(texts[i].id) && target[texts[i].id] == nil {
            guard let before = original[texts[i].id] else { continue }
            let after = PageRenderer.textFrameRect(texts[i], page: page)
            texts[i].x = max(texts[i].x + before.midX - after.midX, 0)
            texts[i].y = max(texts[i].y + before.midY - after.midY, 0)
        }
        // 4. 線接到互相面對的兩邊
        var frames: [UUID: CGRect] = [:]
        for t in texts where chosen.contains(t.id) { frames[t.id] = PageRenderer.textFrameRect(t, page: page) }
        // 心智圖（v12.15.2）：線一律接左右兩邊。上下排在同一欄的兩個，從外側繞（不要穿過中間的方塊）
        for i in links.indices {
            guard let a = frames[links[i].from], let b = frames[links[i].to] else { continue }
            if a.minX < b.maxX && b.minX < a.maxX {
                let s = sideOf[links[i].from] ?? sideOf[links[i].to] ?? 1
                let outer = (s != 0 ? s : (sideOf[links[i].to] ?? 1)) < 0 ? 3 : 1
                links[i].fromSide = outer
                links[i].toSide = outer
            } else if b.midX > a.midX {
                links[i].fromSide = 1
                links[i].toSide = 3
            } else {
                links[i].fromSide = 3
                links[i].toSide = 1
            }
        }
        setTextsRecorded(texts, pageID: pageID)
        setLinksRecorded(links, pageID: pageID)
        showMessage("wand.and.stars", "整理了 \(chosen.count) 個方塊：分成 \(maxDepth + 1) 層，照層級排好位置。不喜歡按復原 ↶")
    }

    private func applyTextStyle(fill: [Double]?, mode: Int, shape: Int) {
        updateActive { box in
            box.fill = fill
            box.fillMode = fill == nil ? nil : mode
            box.shape = fill == nil ? nil : shape
            box.rgba = TextBoxStyle.readable(text: box.rgba, fill: box.fill, mode: box.fillMode)
        }
    }

    /// 從點拉出來的新方塊：字跟來源一樣；外框跟來源一樣（來源沒有外框：淡紫藍的圓角外框）。
    /// 位置：線接到的那一邊的中點剛好在手指放開的地方（pp，頁面座標）
    private func newLinkedBox(like source: TextBox, arrival: Int, at pp: CGPoint, page: NotePage) -> TextBox {
        var box = TextBox()
        box.fontSize = source.fontSize
        box.bold = source.bold
        box.rgba = source.rgba
        box.align = source.align
        if source.fill != nil {
            box.fill = source.fill
            box.fillMode = source.fillMode
            box.shape = source.shape
        } else {
            box.fill = TextBoxStyle.linkedFill
            box.fillMode = 2
            box.shape = 1
        }
        let font = TextBoxView.font(for: box, scale: 1)
        box.width = ceil(("輸入文字" as NSString).size(withAttributes: [.font: font]).width) + 2
        let content = PageRenderer.textContentRect(box, page: page)
        let frame = PageRenderer.textFrameRect(box, page: page)
        let padX = (frame.width - content.width) / 2
        let padY = (frame.height - content.height) / 2
        switch arrival {
        case 3:
            box.x = pp.x + padX
            box.y = pp.y - content.height / 2
        case 1:
            box.x = pp.x - padX - content.width
            box.y = pp.y - content.height / 2
        case 0:
            box.x = pp.x - content.width / 2
            box.y = pp.y + padY
        default:
            box.x = pp.x - content.width / 2
            box.y = pp.y - padY - content.height
        }
        box.x = min(max(box.x, 0), max(page.spec.width - 40, 0))
        box.y = min(max(box.y, 0), max(page.spec.height - 30, 0))
        return box
    }

    /// 連線的起點（v12.15.1：文字方塊或圖片、卡片都可以）：id、外框（頁面座標）、新方塊照誰的字和外框
    private struct LinkSource {
        let id: UUID
        let rect: CGRect
        let style: TextBox?
    }

    /// 從圖片、卡片新拉出來的方塊：這一本預設的字，淡紫藍圓角外框
    private func plainLinkedStyle(_ pv: NotePageView) -> TextBox {
        var box = TextBox()
        box.fontSize = TextDefaults.size(model.meta.id) * pageScaleFactor(pv.page.spec)
        box.bold = TextDefaults.bold(model.meta.id)
        box.rgba = TextDefaults.rgba(model.meta.id) ?? defaultTextRGBA(pdf: !pv.page.isDarkBackground)
        return box
    }

    /// 頁面上可以接線的東西（文字方塊、圖片、卡片）裡，pp 落在哪一個上面（頁面座標）
    private func linkTarget(at pp: CGPoint, on pv: NotePageView, except: UUID) -> (id: UUID, rect: CGRect)? {
        for other in pv.textViews.values where other.box.id != except && !other.box.isMarkdownPage {
            if other.linkRect.insetBy(dx: -8, dy: -8).contains(pp) { return (other.box.id, other.linkRect) }
        }
        for image in model.images(of: pv.page.id).reversed() where image.id != except {
            let r = image.isMini ? image.miniRect : CGRect(x: image.x, y: image.y, width: image.width, height: image.height)
            if r.insetBy(dx: -8, dy: -8).contains(pp) { return (image.id, r) }
        }
        return nil
    }

    /// 從四邊的點往外拉（文字方塊、圖片共用）。point：手指在那一頁視圖上的位置
    private func linkDrag(_ src: LinkSource, side: Int, state: UIGestureRecognizer.State, at point: CGPoint,
                          on pv: NotePageView) {
        let s = max(pv.bounds.width / max(pv.page.spec.width, 1), 0.0001)
        let pp = CGPoint(x: point.x / s, y: point.y / s)
        let start = BoxLinkPath.anchor(src.rect, side: side)
        let target = linkTarget(at: pp, on: pv, except: src.id)
        let style = src.style ?? plainLinkedStyle(pv)
        switch state {
        case .began, .changed:
            if let target = target {
                let toSide = BoxLinkPath.nearestSide(target.rect, to: start)
                pv.showLinkPreview(from: start, fromSide: side, to: BoxLinkPath.anchor(target.rect, side: toSide),
                                   toSide: toSide, ghost: nil)
            } else {
                let toSide = BoxLinkPath.arrivalSide(from: start, fromSide: side, to: pp)
                let ghost = PageRenderer.textFrameRect(newLinkedBox(like: style, arrival: toSide, at: pp, page: pv.page), page: pv.page)
                pv.showLinkPreview(from: start, fromSide: side, to: pp, toSide: toSide, ghost: ghost)
            }
        case .ended:
            pv.hideLinkPreview()
            if let target = target {
                toggleLink(from: src, side: side, to: target, on: pv)
                return
            }
            // 拉得太短（還在點的旁邊）：不算
            guard hypot(pp.x - start.x, pp.y - start.y) * s > 48 else { return }
            addLinkedText(from: src, side: side, at: pp, on: pv)
        default:
            pv.hideLinkPreview()
        }
    }

    /// 從文字方塊四邊的點往外拉（TextBoxView 呼叫）
    private func handleLink(_ tv: TextBoxView, side: Int, state: UIGestureRecognizer.State, at point: CGPoint) {
        guard let pv = pageViews[tv.pageID], tv === activeText else { return }
        linkDrag(LinkSource(id: tv.box.id, rect: tv.linkRect, style: tv.box), side: side, state: state, at: point, on: pv)
    }

    /// 從選取中的圖片、卡片四邊的點往外拉（ImageEditorView 呼叫；v12.15.1）
    func imageLinkDrag(_ box: ImageBox, side: Int, state: UIGestureRecognizer.State, at point: CGPoint) {
        guard let pv = imageEditor?.pageView else { return }
        let rect = box.isMini ? box.miniRect : CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
        linkDrag(LinkSource(id: box.id, rect: rect, style: nil), side: side, state: state, at: point, on: pv)
    }

    /// 兩個東西之間：沒有線就連起來；已經有線（不管方向）就拿掉
    private func toggleLink(from src: LinkSource, side: Int, to target: (id: UUID, rect: CGRect), on pv: NotePageView) {
        let id = pv.page.id
        var links = model.links(of: id)
        let a = src.id
        let b = target.id
        if let i = links.firstIndex(where: { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }) {
            links.remove(at: i)
            showMessage("minus.circle", "這兩個之間的線拿掉了")
        } else {
            let start = BoxLinkPath.anchor(src.rect, side: side)
            links.append(BoxLink(from: a, fromSide: side, to: b, toSide: BoxLinkPath.nearestSide(target.rect, to: start)))
        }
        model.setLinks(links, pageID: id)
        pv.syncLinks(links)
    }

    private func addLinkedText(from tv: TextBoxView, side: Int, at pp: CGPoint, on pv: NotePageView) {
        addLinkedText(from: LinkSource(id: tv.box.id, rect: tv.linkRect, style: tv.box), side: side, at: pp, on: pv)
    }

    /// 放開的地方多一個文字方塊，跟來源連起來；新的方塊變成選取的（再點一下就能打字）
    private func addLinkedText(from src: LinkSource, side: Int, at pp: CGPoint, on pv: NotePageView) {
        let id = pv.page.id
        let start = BoxLinkPath.anchor(src.rect, side: side)
        let arrival = BoxLinkPath.arrivalSide(from: start, fromSide: side, to: pp)
        let box = newLinkedBox(like: src.style ?? plainLinkedStyle(pv), arrival: arrival, at: pp, page: pv.page)
        var links = model.links(of: id)
        links.append(BoxLink(from: src.id, fromSide: side, to: box.id, toSide: arrival))
        model.setLinks(links, pageID: id)
        model.setTexts(model.texts(of: id) + [box], pageID: id)
        pv.syncLinks(links)
        pv.syncTexts(model.texts(of: id))
        endImageSelection()
        if let created = pv.textViews[box.id] { activate(created, edit: false) }
    }

    /// 自動測試（textlinks、textstyle 場景）：放四個文字方塊（三種外框、一個沒有外框）、三條線，選取其中一個。
    /// panel：順便打開「卡片樣式」面板
    func selfTestLinks(panel: Bool) {
        guard let pv = boardPV ?? pageViews.values.first else { return }
        let id = pv.page.id
        let s = max(pv.bounds.width / max(pv.page.spec.width, 1), 0.0001)
        let c = pv.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: self)
        let center = CGPoint(x: c.x / s, y: c.y / s)
        let k = pageScaleFactor(pv.page.spec)
        func make(_ text: String, _ dx: CGFloat, _ dy: CGFloat, fill: [Double]?, mode: Int, shape: Int) -> TextBox {
            var box = TextBox()
            box.text = text
            box.fontSize = 20 * k
            box.x = center.x + dx * k
            box.y = center.y + dy * k
            box.rgba = pv.page.isDarkBackground ? [1, 1, 1, 1] : [0, 0, 0, 1]
            if let fill = fill {
                box.fill = fill
                box.fillMode = mode
                box.shape = shape
                box.rgba = TextBoxStyle.readable(text: box.rgba, fill: fill, mode: mode)
            }
            return box
        }
        let a = make("電磁學", -60, -150, fill: TextBoxStyle.palette[5], mode: 0, shape: 1)
        let b = make("靜電學\n第二行", 160, -60, fill: TextBoxStyle.palette[11], mode: 2, shape: 1)
        let d = make("靜磁學", -260, -40, fill: TextBoxStyle.palette[7], mode: 1, shape: 0)
        let e = make("沒有外框的字", -40, 60, fill: nil, mode: 0, shape: 1)
        let f = make("圓頭", 170, 90, fill: TextBoxStyle.palette[10], mode: 0, shape: 2)
        model.setTexts(model.texts(of: id) + [a, b, d, e, f], pageID: id)
        let links = [BoxLink(from: a.id, fromSide: 1, to: b.id, toSide: 0),
                     BoxLink(from: a.id, fromSide: 3, to: d.id, toSide: 0),
                     BoxLink(from: a.id, fromSide: 2, to: e.id, toSide: 0),
                     BoxLink(from: b.id, fromSide: 2, to: f.id, toSide: 0)]
        model.setLinks(links, pageID: id)
        pv.syncLinks(links)
        pv.syncTexts(model.texts(of: id))
        if let tv = pv.textViews[b.id] {
            activate(tv, edit: false)
            // 從下面的點往左下拉出一個新的（跟手指拉的走同一段程式）
            let from = BoxLinkPath.anchor(tv.linkRect, side: 3)
            addLinkedText(from: tv, side: 3, at: CGPoint(x: from.x - 70 * k, y: from.y + 190 * k), on: pv)
        }
        if let tv = pv.textViews[b.id] { activate(tv, edit: false) }
        if panel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.showTextStyle() }
        }
    }

    /// 自動測試（linkedit、texttidy 場景）：先放跟 selfTestLinks 一樣的東西。
    /// tidy = false：兩條線改樣子（紅色虛線、曲線兩端箭頭），再選取一條線（看藍色的光和小工具列）；
    /// tidy = true：全部圈起來一鍵整理，回報每個方塊的字級
    func selfTestLinkEdit(tidy: Bool) -> String {
        selfTestLinks(panel: false)
        endTextSelection()
        guard let pv = boardPV ?? pageViews.values.first else { return "沒有頁面" }
        let id = pv.page.id
        var links = model.links(of: id)
        guard links.count >= 4 else { return "連線沒有放上去（\(links.count) 條）" }
        if tidy {
            tidyTexts(Set(model.texts(of: id).map { $0.id }), pageID: id)
            let k = pageScaleFactor(pv.page.spec)
            let lines = model.texts(of: id).map { t -> String in
                let name = t.text.isEmpty ? "（空的）" : t.text.replacingOccurrences(of: "\n", with: " ")
                return "\(name)：字級 \(Int((t.fontSize / k).rounded()))\(t.bold ? " 粗體" : "")、樣式 \(t.fillMode ?? -1)"
            }
            let once = model.texts(of: id)
            tidyTexts(Set(once.map { $0.id }), pageID: id)
            let same = model.texts(of: id) == once
            return (lines + [same ? "再整理一次：結果一樣（對）" : "再整理一次：結果不一樣（不對）"]).joined(separator: "\n")
        }
        links[0].rgb = [1.0, 0.45, 0.45]
        links[0].dash = true
        links[1].route = 2
        links[1].arrow = 2
        links[1].rgb = [0.97, 0.78, 0.31]
        links[2].route = 1
        links[2].width = 4
        setLinksRecorded(links, pageID: id)
        let s = max(pv.bounds.width / max(pv.page.spec.width, 1), 0.0001)
        if let from = pv.textViews[links[3].from], let to = pv.textViews[links[3].to] {
            // 第四條線中間的一點：照「手指點一下」的路走（先找點到哪一條，再選取）
            let a = BoxLinkPath.anchor(from.linkRect, side: links[3].fromSide)
            let b = BoxLinkPath.anchor(to.linkRect, side: links[3].toSide)
            let middle = convert(CGPoint(x: (a.x + b.x) / 2 * s, y: (a.y + b.y) / 2 * s), from: pv)
            if let hit = linkHit(at: middle) {
                selectLink(hit.1, on: hit.0, at: middle)
                return hit.1.id == links[3].id ? "點線的中間：選到了那一條（對）" : "點線的中間：選到別條"
            }
            return "點線的中間：沒有選到（不對）"
        }
        return "找不到第四條線的兩個方塊"
    }

    // 工具列的功能

    func setTextColor(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        updateActive { $0.rgba = [Double(r), Double(g), Double(b), 1] }
    }

    func changeTextSize(_ delta: CGFloat) {
        guard let tv = activeText, let page = model.page(tv.pageID) else { return }
        let k = pageScaleFactor(page.spec)
        updateActive { $0.fontSize = min(max($0.fontSize + delta * k, 8 * k), 96 * k) }
    }

    /// 工具列上顯示的字級（以 A4 為準）
    private func displaySize(_ tv: TextBoxView) -> Int {
        let k = model.page(tv.pageID).map { pageScaleFactor($0.spec) } ?? 1
        return Int((tv.box.fontSize / k).rounded())
    }

    func toggleTextBold() {
        updateActive { $0.bold.toggle() }
    }

    /// Markdown 排版開關（v12.9）：打開後，不在輸入時用標題、條列、粗體、表格、數學式排好顯示
    func toggleTextMarkdown() {
        guard let tv = activeText else { return }
        updateActive { $0.markdown = $0.isMarkdown ? nil : true }
        showMessage("doc.richtext", tv.box.isMarkdown ? "Markdown 排版：開（輸入完才會排好）" : "Markdown 排版：關")
    }

    /// 新增 Markdown 頁（v12.9）：在目前這一頁下面加一頁，裡面是一個整頁寬的 Markdown 方塊
    func insertMarkdownPage() {
        guard !readOnly, !isBoard else { return }
        let at = min(focusRow + 1, model.notebook.rows.count)
        insertRow(at: at)
        guard model.notebook.rows.indices.contains(at), let page = model.notebook.rows[at].pages.first else { return }
        if model.texts(of: page.id).contains(where: { $0.isMarkdownPage }) { return }   // Markdown 筆記本：新頁已經有了
        let rgba = TextDefaults.rgba(model.meta.id) ?? defaultTextRGBA(pdf: !page.isDarkBackground)
        var box = markdownPageBox(spec: page.spec, text: "", fontSize: TextDefaults.size(model.meta.id), rgba: rgba)
        box.text = "# 標題\n\n在這裡貼上或寫 Markdown：\n\n- 條列\n- **粗體**、*斜體*、`程式碼`\n- 數學式 $E = mc^2$\n\n$$\\int_0^1 x\\,dx = \\frac{1}{2}$$"
        model.setTexts(model.texts(of: page.id) + [box], pageID: page.id)
        pageViews[page.id]?.syncTexts(model.texts(of: page.id))
        showMessage("doc.richtext", "新增了 Markdown 頁：點一下就能打字，貼上的內容會照 Markdown 排好")
    }

    /// 文字工具列的鎖頭：固定後不能拖動、不能拉寬度（內容照樣可以改）
    func toggleTextLock() {
        guard let tv = activeText else { return }
        updateActive { $0.locked = $0.isLocked ? nil : true }
        textDrag.isEnabled = !tv.box.isLocked && !tv.textView.isFirstResponder
        showMessage(tv.box.isLocked ? "lock.fill" : "lock.open", tv.box.isLocked ? "已固定文字" : "已解開固定")
    }

    func cycleTextAlign() {
        updateActive { $0.align = ($0.align + 1) % 3 }
    }

    func duplicateText() {
        guard let tv = activeText, let pv = pageViews[tv.pageID] else { return }
        var copy = tv.box
        copy.id = UUID()
        copy.x = min(copy.x + 14, max(pv.page.spec.width - 40, 0))
        copy.y = min(copy.y + 14, max(pv.page.spec.height - 30, 0))
        var texts = model.texts(of: tv.pageID)
        texts.append(copy)
        model.setTexts(texts, pageID: tv.pageID)
        pv.syncTexts(texts)
        if let newView = pv.textViews[copy.id] { activate(newView, edit: false) }
    }

    /// 工具列的「完成」：輸入中先退到選取，選取中就結束
    func finishTextStep() {
        guard let tv = activeText else { return }
        if tv.textView.isFirstResponder {
            tv.textView.resignFirstResponder()
            textEditingChanged(tv)
        } else {
            endTextSelection()
        }
    }

    func copyText() {
        guard let tv = activeText else { return }
        Self.textClipboard = tv.box
        Self.clipboard = []
        Self.clearMixedClipboard()
        Self.imageClipboard = nil
        Self.clipboardScale = model.page(tv.pageID).map { pageScaleFactor($0.spec) } ?? 1
        UIPasteboard.general.string = tv.box.text              // 也能貼到別的 App
        Self.ownPasteboardChange = UIPasteboard.general.changeCount
        model.canPaste = true
        showMessage("doc.on.doc", "已拷貝")
        endTextSelection()
    }

    func cutText() {
        guard let tv = activeText else { return }
        Self.textClipboard = tv.box
        Self.clipboard = []
        Self.clearMixedClipboard()
        Self.imageClipboard = nil
        Self.clipboardScale = model.page(tv.pageID).map { pageScaleFactor($0.spec) } ?? 1
        UIPasteboard.general.string = tv.box.text
        Self.ownPasteboardChange = UIPasteboard.general.changeCount
        model.canPaste = true
        showMessage("scissors", "已剪下")
        deleteText()
    }

    /// 貼上文字方塊：長按的位置，或目前這一頁（往右下錯開一點）
    private func pasteText(_ text: TextBox, at viewPoint: CGPoint?) {
        var target: NotePageView?
        var anchor: CGPoint?
        if let vp = viewPoint,
           let pv = pageViews.values.first(where: { $0.bounds.contains($0.convert(vp, from: self)) }) {
            let s = pv.bounds.width / max(pv.page.spec.width, 1)
            let local = pv.convert(vp, from: self)
            target = pv
            anchor = CGPoint(x: local.x / s, y: local.y / s)
        } else {
            let rows = model.notebook.rows
            if rows.indices.contains(focusRow), let rv = rowViews[rows[focusRow].id],
               rv.pages.indices.contains(rv.currentIndex) {
                target = pageViews[rv.pages[rv.currentIndex].id]
            }
        }
        guard let pv = target else { return }
        endTextSelection()
        var copy = text
        copy.id = UUID()
        let dstScale = pageScaleFactor(pv.page.spec)
        copy.fontSize *= dstScale / max(Self.clipboardScale, 0.0001)   // 換算成這一頁看起來一樣大
        if let a = anchor {
            copy.x = a.x
            copy.y = max(0, a.y - copy.fontSize * 0.7)
        } else {
            copy.x += 20
            copy.y += 20
            Self.textClipboard = copy                         // 從選單連續貼上會一直往右下錯開
            Self.clipboardScale = dstScale
        }
        copy.x = min(max(copy.x, 0), max(pv.page.spec.width - 40, 0))
        copy.y = min(max(copy.y, 0), max(pv.page.spec.height - 30, 0))
        let before = model.texts(of: pv.page.id)
        model.setTexts(before + [copy], pageID: pv.page.id)
        pv.syncTexts(model.texts(of: pv.page.id))
        guard let tv = pv.textViews[copy.id] else { return }
        textSnapshot = (pv.page.id, before)
        activate(tv, edit: false)
    }

    func deleteText() {
        guard let tv = activeText else { return }
        var texts = model.texts(of: tv.pageID)
        texts.removeAll { $0.id == tv.box.id }
        model.setTexts(texts, pageID: tv.pageID)
        pageViews[tv.pageID]?.syncTexts(texts)
        endTextSelection()
    }

    /// 拖工具列最左邊的把手：移動文字方塊
    @objc func textMovePan(_ g: UIPanGestureRecognizer) {
        guard let tv = activeText, let pv = pageViews[tv.pageID], !tv.box.isLocked else { return }
        let s = pv.bounds.width / max(pv.page.spec.width, 1)
        switch g.state {
        case .began:
            moveStart = CGPoint(x: tv.box.x, y: tv.box.y)
        case .changed:
            let t = g.translation(in: self)
            let w = pv.page.spec.width, h = pv.page.spec.height
            updateActive { box in
                box.x = min(max(moveStart.x + t.x / s, 0), max(w - 20, 0))
                box.y = min(max(moveStart.y + t.y / s, 0), max(h - 10, 0))
            }
        default:
            break
        }
    }

    // 手指長按筆跡：選取（隨時都可以重新叫出選取框）
    // 手指長按：按在筆跡上 → 選取；按在空白處 → 跳出「貼上」
    @objc private func handleSelectPress(_ g: UILongPressGestureRecognizer) {
        if cropMode && radialMenu == nil { return }       // 剪刀開著（v12.15.1）：長按不跳一圈按鈕，免得拉框時跳出來
        // 一圈按鈕開著（v12.4）：手指不放開，滑到哪一顆就選哪一顆；放開就執行或收起來
        if let menu = radialMenu {
            switch g.state {
            case .changed:
                menu.track(g.location(in: self))
            case .ended:
                setScrolling(true)
                radialMenu = nil
                menu.finish(at: g.location(in: self))
            case .cancelled, .failed:
                setScrolling(true)
                radialMenu = nil
                menu.close()
            default:
                break
            }
            return
        }
        guard g.state == .began, g.numberOfTouches == 1 else { return }    // 只認單指長按
        if readOnly {
            showMessage("lock", "最近刪除裡的筆記本只能看，要改請先復原")
            return
        }
        if activeText?.textView.isFirstResponder == true { return }         // 輸入文字中：長按是移動游標
        let p = g.location(in: self)
        // 長按紙膠帶：跳出「刪除紙膠帶」
        if let hit = tapeHit(at: p) {
            hidePasteButton()
            showTapeDelete(at: p, pageID: hit.0.page.id, id: hit.1.id)
            return
        }
        // 長按白板上的筆記本卡片（v12.12.0）：選取它（跟圖片一樣可以搬、拉大小、刪除）；點一下也是選取（v12.12.3）
        if let hit = imageHit(at: p), hit.1.link != nil {
            hidePasteButton()
            endTextSelection()
            dismissShapeEditor()
            selectImage(hit.1, on: hit.0)
            return
        }
        if let hit = stroke(at: p) {
            // 手指長按任何一筆（v12.3；以前只有螢光筆）：選取它。直的線用兩端點的直線模式，其他用四角框
            hidePasteButton()
            showSelection(on: hit.0, indices: [hit.1], allowLine: true)
        } else {
            // 長按空白處：跳出一圈按鈕（貼上、照片、相機、檔案、文字）
            dismissShapeEditor()
            showRadialMenu(at: p)
        }
    }

    // MARK: 長按空白處的一圈按鈕（v12.3，仿 GUGA）

    private weak var radialMenu: RadialMenuView?
    private var insertLocation: CGPoint?                    // 長按的位置：選到的圖片、貼上的東西放在這裡

    private func showRadialMenu(at p: CGPoint) {
        radialMenu?.removeFromSuperview()
        hidePasteButton()
        insertLocation = p
        // 八格，順時針：貼上、圖釘、文件、相冊（外圈：相機）、錄音、新筆記本、子白板、新卡片（照使用者在 GUGA 習慣的順序）。
        // 筆記本裡「新筆記本」「子白板」那兩格空著。錄音還沒做，選到會提示
        let later: (String) -> (() -> Void) = { [weak self] name in
            return { self?.showMessage("hourglass", name + "還沒做，之後的版本會加") }
        }
        let filesBlue = UIColor(red: 0.20, green: 0.56, blue: 0.98, alpha: 1)
        let pinBlue = UIColor(red: 0.33, green: 0.40, blue: 0.96, alpha: 1)
        var items: [RadialMenuView.Item?] = []
        items.append(RadialMenuView.Item(symbol: "doc.on.clipboard.fill", title: "貼上", tint: UIColor.black,
                                         action: { [weak self] in self?.pasteFromMenu(at: p) }))
        let pinAction: () -> Void = { [weak self] in self?.createPin(at: p) }        // 筆記本也有圖釘（v12.9）
        items.append(RadialMenuView.Item(symbol: "mappin.circle.fill", title: "圖釘", tint: pinBlue, action: pinAction))
        items.append(RadialMenuView.Item(symbol: "folder.fill", title: "文件", tint: filesBlue,
                                         action: { [weak self] in self?.requestInsert(InsertKind.files) }))
        items.append(RadialMenuView.Item(symbol: "photo.fill", title: "相冊", tint: UIColor.systemPink,
                                         action: { [weak self] in self?.requestInsert(InsertKind.photos) },
                                         outerSymbol: "camera.fill", outerTitle: "相機", outerTint: UIColor.darkGray,
                                         outerAction: { [weak self] in self?.requestInsert(InsertKind.camera) }))
        items.append(RadialMenuView.Item(symbol: "mic.fill", title: "錄音", tint: UIColor.black, action: later("錄音")))
        if isBoard {
            items.append(RadialMenuView.Item(symbol: "book.closed.fill", title: "新筆記本", tint: UIColor.brown,
                                             action: { [weak self] in self?.model.cardRequest = CardRequest.newNotebook },
                                             outerSymbol: "square.and.arrow.down.fill", outerTitle: "匯入現有的",
                                             outerTint: UIColor.brown,
                                             outerAction: { [weak self] in self?.model.cardRequest = CardRequest.importExisting }))
        } else {
            items.append(nil)                                       // 筆記本裡：新筆記本那一格空著
        }
        if isBoard {
            // 子白板（v12.14.0）：新的白板／外圈「匯入現有的」白板，都變成這張白板上的一張卡片
            items.append(RadialMenuView.Item(symbol: "rectangle.on.rectangle.angled", title: "子白板", tint: UIColor.systemTeal,
                                             action: { [weak self] in self?.model.cardRequest = CardRequest.newBoard },
                                             outerSymbol: "square.and.arrow.down.fill", outerTitle: "匯入現有的",
                                             outerTint: UIColor.systemTeal,
                                             outerAction: { [weak self] in self?.model.cardRequest = CardRequest.importBoard }))
        } else {
            items.append(nil)                                       // 筆記本裡：子白板那一格空著
        }
        items.append(RadialMenuView.Item(symbol: "character.textbox", title: "新卡片", tint: UIColor.systemOrange,
                                         action: { [weak self] in self?.createText(at: p) }))
        let menu = RadialMenuView(frame: bounds, at: p, items: items)
        addSubview(menu)
        radialMenu = menu
        setScrolling(false)                                    // 手指滑去選按鈕時，頁面不要跟著捲
    }

    /// 一圈按鈕裡的「貼上」：別的 App 拷貝來的文字（例如 AI 的回覆）變成一個文字方塊；其他照原本的貼上
    private func pasteFromMenu(at p: CGPoint) {
        let board = UIPasteboard.general
        let external = board.changeCount != Self.ownPasteboardChange
        if external, !board.hasImages, board.hasStrings {
            let text = ClipboardText.listAwareString() ?? board.string ?? ""     // 條列的編號補回來
            let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmed.isEmpty {
                pasteNewText(trimmed, at: p)
                return
            }
        }
        pasteClipboard(at: p)
    }

    /// 在 p 的位置新增一個文字方塊，內容是 string（選取著，可以直接拖、改字級）
    private func pasteNewText(_ string: String, at p: CGPoint) {
        guard let pv = pageViews.values.first(where: { $0.bounds.contains($0.convert(p, from: self)) }) else { return }
        endTextSelection()
        dismissShapeEditor()
        let s = pv.bounds.width / max(pv.page.spec.width, 1)
        let local = pv.convert(p, from: self)
        var box = TextBox()
        box.text = string
        box.fontSize = TextDefaults.size(model.meta.id) * pageScaleFactor(pv.page.spec)
        box.bold = TextDefaults.bold(model.meta.id)
        box.x = min(max(local.x / s, 0), max(pv.page.spec.width - 40, 0))
        box.y = min(max(local.y / s, 0), max(pv.page.spec.height - 30, 0))
        box.rgba = TextDefaults.rgba(model.meta.id) ?? defaultTextRGBA(pdf: !pv.page.isDarkBackground)
        let before = model.texts(of: pv.page.id)
        model.setTexts(before + [box], pageID: pv.page.id)
        pv.syncTexts(model.texts(of: pv.page.id))
        guard let tv = pv.textViews[box.id] else { return }
        textSnapshot = (pv.page.id, before)
        activate(tv, edit: false)
    }

    /// 一圈按鈕裡的照片、相機、檔案：請外面的 SwiftUI 畫面打開選取畫面（InsertPickers）
    /// 白板右上角的 ＋（v12.8）：插入的東西放在畫面中間
    func insertFromToolbar(_ kind: InsertKind) {
        insertLocation = CGPoint(x: bounds.midX, y: bounds.midY)
        requestInsert(kind)
    }

    // MARK: 白板上的筆記本卡片（v12.12.0；說明在 BoardCards.swift）

    /// 右上角 ＋ 選的：卡片放在畫面中間
    func requestCard(_ request: CardRequest) {
        guard isBoard, !readOnly else { return }
        insertLocation = CGPoint(x: bounds.midX, y: bounds.midY)
        model.cardRequest = request
    }

    /// 浮動視窗裡剪刀的「貼到白板」（v12.15.0）：貼在視窗旁邊空著的地方，記住從哪裡剪的
    /// （選取這張圖，左下角的 ‹ 會打開那一本並跳回那裡）。avoiding：那個視窗在畫面上的位置
    @discardableResult
    func placeClip(_ image: UIImage, notebook: UUID, page: UUID, rect: CGRect, avoiding windowOnScreen: CGRect) -> UUID? {
        guard isBoard, !readOnly, let pv = boardPV else { return nil }
        // v12.15.1（使用者：貼到沒開視窗那邊、比較空的地方的中間）：視窗旁邊比較大的那一塊空地，
        // 在裡面找一個跟已經有的東西重疊最少、又靠近中間的位置。
        // v12.15.3：視窗的位置從螢幕座標換過來（以前直接拿 SwiftUI 那一層的座標，上下差了工具列那一段，圖會貼到視窗後面、畫面外面）
        let window = convert(windowOnScreen, from: nil)
        let top = safeAreaInsets.top + topBarHeight + 16
        let bottom = bounds.height - max(safeAreaInsets.bottom, 0) - 76      // 讓開左下、右下那兩排按鈕
        let height = max(bottom - top, 120)
        let leftRoom = max(window.minX, 0)
        let rightRoom = max(bounds.width - window.maxX, 0)
        var region = CGRect(x: 0, y: top, width: bounds.width, height: height)
        if window.width > 0, max(leftRoom, rightRoom) >= 160 {
            region = rightRoom >= leftRoom
                ? CGRect(x: window.maxX, y: top, width: rightRoom, height: height)
                : CGRect(x: 0, y: top, width: leftRoom, height: height)
        }
        region = region.insetBy(dx: 16, dy: 0)
        endImageSelection()
        pasteImage(image, at: CGPoint(x: region.midX, y: region.midY))
        guard let editor = imageEditor, editor.pageView === pv else { return nil }
        var box = editor.box
        let s = max(pv.bounds.width / max(pv.page.spec.width, 1), 0.0001)
        // 空地放不下：縮小到放得下
        let fit = min((region.width - 16) / max(box.width * s, 1), (region.height - 16) / max(box.height * s, 1), 1)
        if fit < 1 {
            box.width *= max(fit, 0.1)
            box.height *= max(fit, 0.1)
        }
        let w = box.width * s
        let h = box.height * s
        // 已經有的東西（畫面座標）
        func onScreen(_ r: CGRect) -> CGRect {
            pv.convert(CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s), to: self)
        }
        var taken: [CGRect] = []
        for other in model.images(of: pv.page.id) where other.id != box.id {
            taken.append(onScreen(other.isMini ? other.miniRect : CGRect(x: other.x, y: other.y, width: other.width, height: other.height)))
        }
        for t in model.texts(of: pv.page.id) { taken.append(onScreen(PageRenderer.textFrameRect(t, page: pv.page))) }
        taken = taken.filter { $0.intersects(region) }
        let spanX = max(region.width - w, 0)
        let spanY = max(region.height - h, 0)
        var best = CGPoint(x: region.midX, y: region.midY)
        var bestScore = CGFloat.greatestFiniteMagnitude
        let steps = 8
        for iy in 0 ... steps {
            for ix in 0 ... steps {
                let cx = region.minX + w / 2 + spanX * CGFloat(ix) / CGFloat(steps)
                let cy = region.minY + h / 2 + spanY * CGFloat(iy) / CGFloat(steps)
                let r = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h).insetBy(dx: -8, dy: -8)
                var overlap: CGFloat = 0
                for t in taken {
                    let i = r.intersection(t)
                    if !i.isNull { overlap += i.width * i.height }
                }
                let dx = (cx - region.midX) / max(region.width, 1)
                let dy = (cy - region.midY) / max(region.height, 1)
                let score = overlap + (dx * dx + dy * dy) * w * h * 0.6
                if score < bestScore {
                    bestScore = score
                    best = CGPoint(x: cx, y: cy)
                }
            }
        }
        // 整張都留在空地裡（放不下的那一邊就置中）
        best.x = spanX > 0 ? min(max(best.x, region.minX + w / 2), region.maxX - w / 2) : region.midX
        best.y = spanY > 0 ? min(max(best.y, region.minY + h / 2), region.maxY - h / 2) : region.midY
        let c = pv.convert(best, from: self)
        box.x = min(max(c.x / s - box.width / 2, 0), max(pv.page.spec.width - box.width, 0))
        box.y = min(max(c.y / s - box.height / 2, 0), max(pv.page.spec.height - box.height, 0))
        box.sourceNotebook = notebook
        box.sourcePage = page
        box.sourceRect = rect
        var images = model.images(of: pv.page.id)
        if let i = images.firstIndex(where: { $0.id == box.id }) { images[i] = box }
        model.setImages(images, pageID: pv.page.id)
        pv.syncImages(images)
        editor.update(box)
        lastClipScreenRect = onScreen(CGRect(x: box.x, y: box.y, width: box.width, height: box.height))
        showMessage("square.and.arrow.down.on.square", "已貼到白板：選取這張圖，按左下角的 ‹ 會回到剪下來的地方")
        return box.id
    }

    /// 自動測試用：最近一次貼到白板的圖在畫面上的位置
    private(set) var lastClipScreenRect: CGRect?

    /// 選取中的圖片左下角的 ‹（ImageEditorView 呼叫）：開剪下來的那一本的浮動視窗，跳到那一塊
    func openImageSource(_ box: ImageBox) {
        guard let notebook = box.sourceNotebook, let page = box.sourcePage else { return }
        guard Store.libraryCache.notebooks.contains(where: { $0.id == notebook && $0.deletedAt == nil }) else {
            showMessage("questionmark.folder", "找不到剪下來的那一本（可能被刪掉了）")
            return
        }
        endImageSelection()
        model.openCard(notebook, jumpTo: (page, box.sourceRect ?? CGRect.null))
    }

    /// 自動測試（tidytree）：11 個方塊、四層，位置亂放，用一鍵整理排好
    func selfTestTidyTree() -> String {
        guard let pv = boardPV else { return "沒有白板" }
        let id = pv.page.id
        let s = max(pv.bounds.width / max(pv.page.spec.width, 1), 0.0001)
        let c = pv.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: self)
        let center = CGPoint(x: c.x / s, y: c.y / s)
        let k = pageScaleFactor(pv.page.spec)
        let names = ["電磁學", "靜電學", "靜磁學", "電磁波", "高斯定律", "電位", "安培定律", "法拉第定律", "馬克士威方程", "電容", "例題 1"]
        let parents = [-1, 0, 0, 0, 1, 1, 2, 2, 3, 5, 9]
        var boxes: [TextBox] = []
        for (i, name) in names.enumerated() {
            var box = TextBox()
            box.text = name
            box.fontSize = 16 * k
            box.rgba = pv.page.isDarkBackground ? [1, 1, 1, 1] : [0, 0, 0, 1]
            box.x = i == 0 ? center.x - 40 * k : center.x - 300 * k + CGFloat((i * 137) % 520) * k
            box.y = i == 0 ? center.y : center.y - 260 * k + CGFloat((i * 89) % 430) * k
            boxes.append(box)
        }
        var links: [BoxLink] = []
        for (i, p) in parents.enumerated() where p >= 0 {
            links.append(BoxLink(from: boxes[p].id, fromSide: 1, to: boxes[i].id, toSide: 3))
        }
        model.setTexts(model.texts(of: id) + boxes, pageID: id)
        model.setLinks(model.links(of: id) + links, pageID: id)
        pv.syncLinks(model.links(of: id))
        pv.syncTexts(model.texts(of: id))
        tidyTexts(Set(boxes.map { $0.id }), pageID: id)
        let after = model.texts(of: id)
        var lines: [String] = []
        for name in ["電磁學", "靜電學", "高斯定律", "電容", "例題 1"] {
            if let t = after.first(where: { $0.text == name }) {
                lines.append(String(format: "%@：x %.0f、字級 %.0f", name, Double(t.x), Double(t.fontSize / max(k, 0.01))))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 自動測試（clip）：浮動視窗裡的筆記本，第一頁左上角剪一塊貼到白板
    func selfTestClip() {
        guard let page = model.notebook.rows.first?.pages.first else { return }
        cropResult = (page.id, CGRect(x: 20, y: 20, width: min(420, page.spec.width - 40), height: 240))
        cropToBoard()
        // v12.15.3：再剪第二塊（使用者：第二塊進不了白板），然後選第一個框（右下角出現 → 和顏色）
        cropResult = (page.id, CGRect(x: 40, y: 300, width: min(300, page.spec.width - 80), height: 160))
        cropToBoard()
        if let pv = pageViews[page.id], let first = model.clips(of: page.id).first {
            setClipColor(first.id, rgb: 0x4A8FE0, pageID: page.id)
            pv.selectClip(first.id)
        }
    }

    /// 自動測試（undoink，v12.15.7）：照 PencilKit 叫代理的順序假裝寫字（開始 → 筆跡改變 → 放開；
    /// 也試「開始 → 放開 → 筆跡改變」），中間按上一步、重做、再寫，每一步記下畫布和檔案裡各有幾筆
    func selfTestUndoInk(_ done: @escaping (String) -> Void) {
        guard let first = model.notebook.rows.first?.pages.first else { return done("沒有頁面") }
        let pageID = first.id
        let strokes = BoardTileCheck.makeStrokes(count: 12, markers: 0, origin: CGPoint(x: 80, y: 120),
                                                 spread: CGSize(width: 400, height: 500))
        var lines: [String] = []
        var next = 0
        func pv() -> NotePageView? { pageViews[pageID] }
        func count() -> String {
            Store.finishPendingSaves()
            let canvas = pv()?.canvas.drawing.strokes.count ?? -1
            let file = Store.loadDrawing(pageID).strokes.count
            return "畫布 \(canvas)／檔案 \(file)"
        }
        func write(endFirst: Bool) {
            guard let pv = pv(), next < strokes.count else { return }
            pv.canvasViewDidBeginUsingTool(pv.canvas)
            var d = pv.canvas.drawing
            d.strokes.append(strokes[next])
            next += 1
            if endFirst {
                pv.canvasViewDidEndUsingTool(pv.canvas)
                pv.canvas.drawing = d
            } else {
                pv.canvas.drawing = d
                pv.canvasViewDidEndUsingTool(pv.canvas)
            }
        }
        let steps: [(String, () -> Void)] = [
            ("寫第 1 筆", { write(endFirst: false) }),
            ("寫第 2 筆", { write(endFirst: false) }),
            ("寫第 3 筆（先放開）", { write(endFirst: true) }),
            ("上一步", { self.history.undo() }),
            ("寫第 4 筆", { write(endFirst: false) }),
            ("上一步", { self.history.undo() }),
            ("上一步", { self.history.undo() }),
            ("重做", { self.history.redo() }),
            ("寫第 5 筆", { write(endFirst: false) }),
            ("寫第 6 筆", { write(endFirst: true) }),
            ("上一步", { self.history.undo() }),
            ("寫第 7 筆，假裝第 1 筆被吃掉", {
                guard let pv = pv(), next < strokes.count else { return }
                pv.canvasViewDidBeginUsingTool(pv.canvas)
                var d = pv.canvas.drawing
                if !d.strokes.isEmpty { d.strokes.removeFirst() }
                d.strokes.append(strokes[next])
                next += 1
                pv.canvas.drawing = d
                pv.canvasViewDidEndUsingTool(pv.canvas)
            }),
            ("上一步", { self.history.undo() }),
        ]
        func run(_ i: Int) {
            guard i < steps.count else {
                lines.append("預期：吃掉後補回＝4；最後上一步＝3（第 1、2、5 筆）")
                return done(lines.joined(separator: "\n"))
            }
            steps[i].1()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                self.flushAll()
                lines.append("\(steps[i].0)：\(count())")
                run(i + 1)
            }
        }
        run(0)
    }

    /// 自動測試（textzone）：新增一個文字方塊、打字中（看手寫區有沒有關掉）
    func selfTestTextZone() {
        guard let pv = pageViews.values.first else { return }
        let p = pv.convert(CGPoint(x: pv.bounds.width * 0.25, y: pv.bounds.height * 0.25), to: self)
        createText(at: p)
        updateActive { $0.text = "用鍵盤打的字" }
        if let tv = activeText {
            tv.placeCursor(at: p, from: self)
            textEditingChanged(tv)
        }
    }

    /// 自動測試：指定接下來放卡片的位置
    func insertLocationForTest(_ p: CGPoint) {
        insertLocation = p
    }

    /// 一次放好幾張卡片（匯入文件）：從剛剛長按的位置往右排，一列 4 張
    func placeCards(for metas: [NotebookMeta]) {
        guard isBoard, !metas.isEmpty else { return }
        let base = insertLocation ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let step = PaperRenderer.gridUnit * 8 * scale
        for (i, meta) in metas.enumerated() {
            placeCard(for: meta, at: CGPoint(x: base.x + CGFloat(i % 4) * step, y: base.y + CGFloat(i / 4) * step * 1.6))
        }
        showMessage("doc.badge.plus", metas.count == 1 ? "已匯入「\(metas[0].title)」：點卡片選取，再按左上角打開"
                                                       : "已匯入 \(metas.count) 份文件")
    }

    /// 在白板上放一張筆記本的卡片：一張帶連結的圖片（封面＋標題），放在剛剛長按的位置（或畫面中間）。可以復原
    func placeCard(for meta: NotebookMeta, at viewPoint: CGPoint? = nil) {
        guard isBoard, !readOnly, let pv = boardPV else { return }
        let id = pv.page.id
        let image = CardCover.image(for: meta, caption: meta.title)
        guard let file = Store.saveImage(image, pageID: id) else { return }
        let w = PaperRenderer.gridUnit * 7                       // 卡片寬 7 格
        let h = w * image.size.height / max(image.size.width, 1)
        var box = ImageBox(file: file)
        box.width = w
        box.height = h
        box.link = meta.id
        box.caption = meta.title
        let vp = viewPoint ?? insertLocation ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let s = pv.bounds.width / max(pv.page.spec.width, 1)
        let local = pv.convert(vp, from: self)
        box.x = min(max(local.x / max(s, 0.0001) - w / 2, 0), max(pv.page.spec.width - w, 0))
        box.y = min(max(local.y / max(s, 0.0001) - h / 2, 0), max(pv.page.spec.height - h, 0))
        endTextSelection()
        dismissShapeEditor()
        endImageSelection()
        let before = model.images(of: id)
        model.setImages(before + [box], pageID: id)
        pv.syncImages(model.images(of: id))
        history.registerUndo(withTarget: self) { notebook in
            notebook.restoreImages(pageID: id, to: before)
        }
    }

    /// 打開白板之後：每張卡片的封面重畫一次（筆記本在別的地方改過、或卡片是舊版做的沒有左上角的按鈕）。
    /// 一張一張慢慢做，不要卡住畫面
    func refreshCardCovers() {
        guard isBoard, let pv = boardPV else { return }
        // 之前被縮成小圖的卡片（v12.12.2 以前按到「縮成小圖」）：放回原本的大小（v12.12.4）
        var images = model.images(of: pv.page.id)
        var restored = 0
        for i in images.indices where images[i].link != nil && images[i].isMini {
            images[i].mini = nil
            restored += 1
        }
        if restored > 0 {
            model.setImages(images, pageID: pv.page.id)
            pv.syncImages(images)
            showMessage("rectangle.portrait.on.rectangle.portrait", "有 \(restored) 張被縮成小圖的卡片，已經放回原本的大小")
        }
        let links = Set(model.images(of: pv.page.id).compactMap { $0.link })
        for (i, link) in links.enumerated() {
            guard let meta = Store.libraryCache.notebooks.first(where: { $0.id == link && $0.deletedAt == nil }) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * 0.15) { [weak self] in
                self?.updateCards(for: meta, caption: nil)
            }
        }
    }

    /// 選取中的卡片上的按鈕（ImageEditorView 呼叫）：0 開浮動視窗、1 在卡片上預覽／回到封面、2 上一頁、3 下一頁
    func cardButton(_ index: Int, box: ImageBox) {
        guard isBoard, let link = box.link, let pv = boardPV else { return }
        if index == 0 {
            endImageSelection()
            model.openCard(link)
            return
        }
        guard let meta = Store.libraryCache.notebooks.first(where: { $0.id == link && $0.deletedAt == nil }) else {
            showMessage("questionmark.folder", "找不到這本筆記本（可能被刪掉了）")
            return
        }
        var changed = box
        switch index {
        case 1: changed.previewPage = box.previewPage == nil ? CardCover.lastPageIndex(meta) : nil
        case 2: changed.previewPage = max((box.previewPage ?? 0) - 1, 0)
        default: changed.previewPage = min((box.previewPage ?? 0) + 1, max(CardCover.pageCount(meta) - 1, 0))
        }
        guard changed != box else { return }
        let id = pv.page.id
        var images = model.images(of: id)
        guard let i = images.firstIndex(where: { $0.id == box.id }) else { return }
        images[i] = changed
        let image = CardCover.image(for: meta, caption: changed.caption ?? meta.title, previewPage: changed.previewPage)
        Store.overwriteImage(image, file: changed.file, pageID: id)
        model.setImages(images, pageID: id)
        pv.syncImages(images)
        pv.imageViews[changed.id]?.image = image
        imageEditor?.update(changed)
        imageSnapshot = (id, images)                     // 預覽、翻頁不算一步復原
    }

    /// 選取中的卡片：改卡片下面顯示的名稱（不會改到筆記本的檔名）
    func editCardCaption() {
        guard let box = imageEditor?.box, let link = box.link,
              let meta = Store.libraryCache.notebooks.first(where: { $0.id == link }) else { return }
        TextPrompt.show(title: "卡片下面的名稱（不會改到筆記本的檔名）", initial: box.caption ?? meta.title) { [weak self] text in
            self?.updateCards(for: meta, caption: text, only: box.id)
        }
    }

    /// 自動測試：選取連到這一本的卡片（看選取後左上角的按鈕）
    func selfTestSelectCard(_ link: UUID, preview: Bool) {
        guard let pv = boardPV, let box = model.images(of: pv.page.id).first(where: { $0.link == link }) else { return }
        selectImage(box, on: pv)
        if preview { cardButton(1, box: box) }
    }

    /// 連到這一本的卡片：封面換成最新的。caption 有值：順便改卡片上的標題（only 有值：只改那一張）
    func updateCards(for meta: NotebookMeta, caption: String?, only: UUID? = nil) {
        guard isBoard, let pv = boardPV else { return }
        let id = pv.page.id
        var images = model.images(of: id)
        var touched = false
        for i in images.indices where images[i].link == meta.id {
            if let caption = caption, only == nil || only == images[i].id { images[i].caption = caption }
            let image = CardCover.image(for: meta, caption: images[i].caption ?? meta.title, previewPage: images[i].previewPage)
            Store.overwriteImage(image, file: images[i].file, pageID: id)
            pv.imageViews[images[i].id]?.image = image
            touched = true
        }
        guard touched, caption != nil else { return }
        if imageEditor != nil { endImageSelection() }
        model.setImages(images, pageID: id)
        pv.syncImages(images)
    }

    private func requestInsert(_ kind: InsertKind) {
        if kind == InsertKind.camera {
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                showMessage("camera", "這台裝置沒有相機可以用")
                return
            }
            // 沒有在 App 設定裡加上相機的用途說明就打開相機，App 會直接被系統關掉：先檢查
            guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
                showMessage("camera", "要先在 App 設定的「功能」加上「相機」")
                return
            }
        }
        model.insertRequest = kind
    }

    /// 相簿、相機、檔案選到的圖片：太大的先縮小（長邊最多 2400 像素），貼在剛剛長按的位置
    func insertPickedImage(_ image: UIImage) {
        pasteImage(Self.downscaled(image, maxSide: 2400), at: insertLocation)
    }

    /// 一次匯入很多張（v12.10）：白板上排成格狀（一列最多 4 張），筆記本裡一張一張稍微錯開
    func insertPickedImages(_ images: [UIImage]) {
        guard !images.isEmpty else {
            showMessage("exclamationmark.triangle", "沒有讀到圖片")
            return
        }
        let base = insertLocation ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let columns = min(images.count, 4)
        for (i, image) in images.enumerated() {
            var p = base
            if isBoard {
                // 一張最大 10 × 10 格（v12.11.1），每張之間留 2 格
                let step = PaperRenderer.gridUnit * 12 * scale
                p.x += (CGFloat(i % columns) - CGFloat(columns - 1) / 2) * step
                p.y += CGFloat(i / columns) * step
            } else {
                p.x += CGFloat(i) * 36
                p.y += CGFloat(i) * 36
            }
            pasteImage(Self.downscaled(image, maxSide: 2400), at: p)
        }
        showMessage("photo.on.rectangle", "已匯入 \(images.count) 張")
    }

    /// 長邊超過 maxSide 像素就等比例縮小（順便把照片的方向轉正）
    static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let w = image.size.width * image.scale
        let h = image.size.height * image.scale
        let longest = max(w, h)
        guard longest > maxSide, longest > 0 else { return image }
        let k = maxSide / longest
        let size = CGSize(width: floor(w * k), height: floor(h * k))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: CGPoint.zero, size: size))
        }
    }

    func copyToClipboard(_ strokes: [PKStroke], from page: NotePage? = nil, message: String = "已拷貝",
                         images: [ImageBox] = [], texts: [TextBox] = []) {
        Self.clipboard = strokes
        // 圖片：連圖檔一起記住（貼到別本筆記本時要另存一份）
        Self.clipImages = []
        if let page = page {
            for box in images {
                if let image = Store.loadImage(box.file, pageID: page.id) { Self.clipImages.append((box: box, image: image)) }
            }
        }
        Self.clipTexts = texts
        Self.textClipboard = nil
        Self.imageClipboard = nil
        Self.ownPasteboardChange = UIPasteboard.general.changeCount
        Self.clipboardScale = page.map { pageScaleFactor($0.spec) } ?? 1
        model.canPaste = Self.hasClipboard
        showMessage(message == "已剪下" ? "scissors" : "doc.on.doc", message)
    }

    /// 貼上。viewPoint 有值：貼在那個位置（長按的地方）；沒有：貼在目前這一頁，往右下錯開一點
    func pasteClipboard(at viewPoint: CGPoint? = nil) {
        if readOnly { return }
        var viewPoint = viewPoint
        if viewPoint == nil, isBoard { viewPoint = CGPoint(x: bounds.midX, y: bounds.midY) }   // 白板：沒指定位置就貼在畫面中間
        // 系統剪貼簿比 App 裡拷貝的還新（例如剛從 Mac、iPad 截圖）：貼那張圖
        let board = UIPasteboard.general
        if board.changeCount != Self.ownPasteboardChange, board.hasImages, let image = board.image {
            pasteImage(image, at: viewPoint)
            return
        }
        if Self.clipboard.isEmpty, Self.textClipboard == nil, let image = Self.imageClipboard {
            pasteImage(image, at: viewPoint)
            return
        }
        if Self.clipboard.isEmpty, let text = Self.textClipboard {
            pasteText(text, at: viewPoint)
            return
        }
        guard !Self.clipboard.isEmpty || !Self.clipImages.isEmpty || !Self.clipTexts.isEmpty else { return }
        var target: NotePageView?
        var anchor: CGPoint?
        if let vp = viewPoint,
           let pv = pageViews.values.first(where: { $0.bounds.contains($0.convert(vp, from: self)) }) {
            let local = pv.convert(vp, from: self)
            let s = pv.bounds.width / max(pv.page.spec.width, 1)
            target = pv
            anchor = CGPoint(x: local.x / s, y: local.y / s)
        } else {
            let rows = model.notebook.rows
            if rows.indices.contains(focusRow), let rv = rowViews[rows[focusRow].id],
               rv.pages.indices.contains(rv.currentIndex) {
                target = pageViews[rv.pages[rv.currentIndex].id]
            }
        }
        guard let pv = target else { return }
        var box = CGRect.null
        for stroke in Self.clipboard { box = box.union(stroke.renderBounds) }
        for item in Self.clipImages { box = box.union(SelectionEditorView.imageBounds(of: item.box)) }
        for t in Self.clipTexts { box = box.union(Self.clipTextRect(t)) }
        guard !box.isNull else { return }
        // 從大頁面（iEM）貼到小頁面（A4）：等比例縮放，看起來一樣大
        let dstScale = pageScaleFactor(pv.page.spec)
        let f = dstScale / max(Self.clipboardScale, 0.0001)
        let resize = CGAffineTransform(translationX: -box.midX, y: -box.midY)
            .concatenating(CGAffineTransform(scaleX: f, y: f))
            .concatenating(CGAffineTransform(translationX: box.midX, y: box.midY))
        let offset = anchor.map { CGAffineTransform(translationX: $0.x - box.midX, y: $0.y - box.midY) }
            ?? CGAffineTransform(translationX: 20, y: 20)
        let copies = Self.clipboard.map { stroke in
            PKStroke(ink: stroke.ink, path: stroke.path,
                     transform: stroke.transform.concatenating(resize).concatenating(offset), mask: stroke.mask)
        }
        let move = resize.concatenating(offset)
        // 圖片、文字方塊（v12.9.2）：位置跟筆跡一樣搬，大小跟著換算；圖檔在這一頁另存一份
        var newImages: [ImageBox] = []
        var keptImages: [(box: ImageBox, image: UIImage)] = []
        for item in Self.clipImages {
            guard let file = Store.saveImage(item.image, pageID: pv.page.id) else { continue }
            var b = item.box
            let c = CGPoint(x: b.x + b.width / 2, y: b.y + b.height / 2).applying(move)
            b.id = UUID()
            b.file = file
            b.width *= f
            b.height *= f
            b.x = c.x - b.width / 2
            b.y = c.y - b.height / 2
            newImages.append(b)
            var kept = item
            kept.box = b
            keptImages.append(kept)
        }
        var newTexts: [TextBox] = []
        for t in Self.clipTexts {
            var b = t
            let p = CGPoint(x: b.x, y: b.y).applying(move)
            b.id = UUID()
            b.x = p.x
            b.y = p.y
            b.fontSize *= f
            b.width *= f
            if let w = b.fixedWidth { b.fixedWidth = w * f }
            newTexts.append(b)
        }
        let pageID = pv.page.id
        if !newImages.isEmpty || !newTexts.isEmpty {
            // 文字、圖片、筆跡三樣合成一步復原
            history.beginUndoGrouping()
            if !newImages.isEmpty { setImagesRecorded(model.images(of: pageID) + newImages, pageID: pageID) }
            if !newTexts.isEmpty { setTextsRecorded(model.texts(of: pageID) + newTexts, pageID: pageID) }
        }
        var updated = pv.canvas.drawing
        let first = updated.strokes.count
        updated.strokes.append(contentsOf: copies)
        if !copies.isEmpty { ShapeSnapper.setDrawing(updated, on: pv.canvas) }
        if !newImages.isEmpty || !newTexts.isEmpty { history.endUndoGrouping() }
        if anchor == nil {                                  // 從選單連續貼上會一直往右下錯開
            Self.clipboard = copies
            Self.clipImages = keptImages
            Self.clipTexts = newTexts
            Self.clipboardScale = dstScale
        }
        let picked = newTexts.map { SelectionEditorView.PickedText(box: $0, rect: Self.clipTextRect($0)) }
        showSelection(on: pv, indices: Array(first..<(first + copies.count)), images: newImages, texts: picked)
        refocus()
    }

    /// 文字方塊大概佔的範圍（頁面座標；貼上時算外框用）
    static func clipTextRect(_ t: TextBox) -> CGRect {
        let lines = CGFloat(max(t.text.components(separatedBy: "\n").count, 1))
        return CGRect(x: t.x, y: t.y, width: (t.fixedWidth ?? t.width) + TextBoxView.insetX * 2,
                      height: t.fontSize * 1.4 * lines + 8)
    }

    // 長按空白處跳出的「貼上」
    private lazy var pasteButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle(" 貼上", for: .normal)
        button.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor(white: 0.16, alpha: 0.96)
        button.layer.cornerRadius = 20
        button.isHidden = true
        button.addTarget(self, action: #selector(pasteButtonTapped), for: .touchUpInside)
        return button
    }()
    private var pasteLocation: CGPoint?

    private func showPasteButton(at p: CGPoint) {
        pasteLocation = p
        let size = CGSize(width: 104, height: 40)
        let x = min(max(p.x - size.width / 2, 8), bounds.width - size.width - 8)
        let y = max(p.y - 70, 8)
        pasteButton.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        pasteButton.isHidden = false
        bringSubviewToFront(pasteButton)
    }

    private func hidePasteButton() {
        pasteButton.isHidden = true
        pasteLocation = nil
    }

    @objc private func pasteButtonTapped() {
        let location = pasteLocation
        hidePasteButton()
        pasteClipboard(at: location)
    }

    @objc func dismissShapeEditor() {
        shapeEditor?.removeFromSuperview()
        shapeEditor = nil
        endImageSelection()
    }

    // MARK: 圖片

    private weak var imageEditor: ImageEditorView?
    private var imageSnapshot: (pageID: UUID, images: [ImageBox])?    // 選取前的樣子（結束時合成一步復原）

    /// 點到哪一張圖片（上層的先）
    private func imageHit(at p: CGPoint) -> (NotePageView, ImageBox)? {
        var below: (NotePageView, ImageBox)?
        for pv in pageViews.values {
            for box in model.images(of: pv.page.id).reversed() {
                guard let view = pv.imageViews[box.id] else { continue }
                if view.bounds.contains(view.convert(p, from: self)) {
                    if box.above { return (pv, box) }
                    if below == nil { below = (pv, box) }
                }
            }
        }
        return below
    }

    func selectImage(_ box: ImageBox, on pv: NotePageView) {
        shapeEditor?.removeFromSuperview()
        shapeEditor = nil
        endImageSelection()
        if imageSnapshot == nil || imageSnapshot?.pageID != pv.page.id {
            imageSnapshot = (pv.page.id, model.images(of: pv.page.id))
        }
        let editor = ImageEditorView(box: box, pageView: pv, host: self)
        pv.addSubview(editor)
        imageEditor = editor
    }

    /// 圖片被拖動、縮放、旋轉：commit = 放開手（寫進資料）
    func imageEdited(_ box: ImageBox, commit: Bool) {
        guard let pv = imageEditor?.pageView else { return }
        if commit {
            var images = model.images(of: pv.page.id)
            if let i = images.firstIndex(where: { $0.id == box.id }) { images[i] = box }
            model.setImages(images, pageID: pv.page.id)
            pv.syncImages(images)
        } else {
            pv.layoutImage(box)
        }
    }

    /// 結束圖片選取：這段期間的改動合成一步復原
    func endImageSelection() {
        if let editor = imageEditor {
            editor.removeFromSuperview()
            imageEditor = nil
        }
        guard let snap = imageSnapshot else { return }
        imageSnapshot = nil
        let now = model.images(of: snap.pageID)
        if now != snap.images {
            let pageID = snap.pageID
            let old = snap.images
            history.registerUndo(withTarget: self) { notebook in
                notebook.restoreImages(pageID: pageID, to: old)
            }
        }
    }

    func restoreImages(pageID: UUID, to images: [ImageBox]) {
        if let editor = imageEditor {
            editor.removeFromSuperview()
            imageEditor = nil
        }
        if let editor = shapeEditor, editor.hasImages {         // 選取框裡的圖片要變回去了：先收起來（v12.1）
            editor.removeFromSuperview()
            shapeEditor = nil
        }
        imageSnapshot = nil
        let current = model.images(of: pageID)
        model.setImages(images, pageID: pageID)
        pageViews[pageID]?.syncImages(images)
        history.registerUndo(withTarget: self) { notebook in
            notebook.restoreImages(pageID: pageID, to: current)
        }
        // 這一步復原／重做讓白板上的筆記本卡片不見了（v12.13.0）：說清楚，不然看起來像卡片自己消失。
        // 最常見：放了卡片之後一直在浮動視窗裡寫字，白板自己的「上一步」還停在「放卡片」，這時候在白板上兩指點一下就會收回卡片
        let lost = current.filter { old in old.link != nil && !images.contains(where: { $0.id == old.id }) }
        if let first = lost.first {
            let name = first.caption ?? "筆記本"
            let undoing = history.isUndoing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showMessage("exclamationmark.triangle",
                                  undoing ? "這一步復原把卡片「\(name)」收回去了（筆記本還在）。要放回來：按重做 ↷，或三指點一下"
                                       : "這一步重做把卡片「\(name)」拿掉了（筆記本還在）。要放回來：按復原 ↶")
            }
        }
        var rect = CGRect.null
        for b in images where !current.contains(b) { rect = rect.union(CGRect(x: b.x, y: b.y, width: b.width, height: b.height)) }
        for b in current where !images.contains(b) { rect = rect.union(CGRect(x: b.x, y: b.y, width: b.width, height: b.height)) }
        reveal(pageID: pageID, pageRect: rect)
    }

    /// 貼上圖片：長按的位置，或目前這一頁的上方中間；太大會縮到頁寬的八成
    func pasteImage(_ image: UIImage, at viewPoint: CGPoint?) {
        var viewPoint = viewPoint
        if viewPoint == nil, isBoard { viewPoint = CGPoint(x: bounds.midX, y: bounds.midY) }   // 白板：沒指定位置就貼在畫面中間
        var target: NotePageView?
        if let vp = viewPoint {
            target = pageViews.values.first(where: { $0.bounds.contains($0.convert(vp, from: self)) })
        }
        if target == nil {
            let rows = model.notebook.rows
            if rows.indices.contains(focusRow), let rv = rowViews[rows[focusRow].id],
               rv.pages.indices.contains(rv.currentIndex) {
                target = pageViews[rv.pages[rv.currentIndex].id]
            }
        }
        guard let pv = target else { return }
        let id = pv.page.id
        guard let file = Store.saveImage(image, pageID: id) else { return }
        let pw = pv.page.spec.width
        let ph = pv.page.spec.height
        var w = max(image.size.width, 1)
        var h = max(image.size.height, 1)
        // 太大會縮到頁寬、頁高的八成。
        // 白板（v12.11.1，使用者要求）：貼上來差不多 6 × 10 格（橫的圖 10 × 6），之後自己再拉大小；本來就比較小的圖不放大。
        // 以前是最多 480 × 640 點，每張圖貼上來大小差很多
        let flat = pv.page.spec.flat == true
        let unit = PaperRenderer.gridUnit
        let boardW: CGFloat = (w >= h ? 10 : 6) * unit
        let boardH: CGFloat = (w >= h ? 6 : 10) * unit
        // 筆記本（v12.15.1，使用者：貼照片不要太大）：最寬半頁、最高四成頁高；本來就比較小的圖不放大
        let capW: CGFloat = flat ? min(pw * 0.8, boardW) : pw * 0.5
        let capH: CGFloat = flat ? min(ph * 0.8, boardH) : ph * 0.4
        if w > capW { h *= capW / w; w = capW }
        if h > capH { w *= capH / h; h = capH }
        var box = ImageBox(file: file)
        box.width = w
        box.height = h
        if let vp = viewPoint {
            let s = pv.bounds.width / max(pw, 1)
            let local = pv.convert(vp, from: self)
            box.x = local.x / s - w / 2
            box.y = local.y / s - h / 2
        } else {
            box.x = (pw - w) / 2
            box.y = 40 * pageScaleFactor(pv.page.spec)
        }
        box.x = min(max(box.x, 0), max(pw - w, 0))
        box.y = min(max(box.y, 0), max(ph - h, 0))
        endTextSelection()
        dismissShapeEditor()
        let before = model.images(of: id)
        model.setImages(before + [box], pageID: id)
        pv.syncImages(model.images(of: id))
        imageSnapshot = (id, before)
        selectImage(box, on: pv)
    }

    // 圖片工具列

    func copyImage(cut: Bool) {
        guard let editor = imageEditor, let pv = editor.pageView,
              let image = Store.loadImage(editor.box.file, pageID: pv.page.id) else { return }
        Self.imageClipboard = image
        Self.clipboard = []
        Self.clearMixedClipboard()
        Self.textClipboard = nil
        UIPasteboard.general.image = image                      // 也能貼到別的 App
        Self.ownPasteboardChange = UIPasteboard.general.changeCount
        model.canPaste = true
        showMessage(cut ? "scissors" : "doc.on.doc", cut ? "已剪下" : "已拷貝")
        if cut { deleteImage() } else { endImageSelection() }
    }

    func duplicateImage() {
        guard let editor = imageEditor, let pv = editor.pageView else { return }
        var copy = editor.box
        copy.id = UUID()
        copy.x += 20
        copy.y += 20
        var images = model.images(of: pv.page.id)
        images.append(copy)
        model.setImages(images, pageID: pv.page.id)
        pv.syncImages(images)
        editor.removeFromSuperview()
        imageEditor = nil
        let newEditor = ImageEditorView(box: copy, pageView: pv, host: self)
        pv.addSubview(newEditor)
        imageEditor = newEditor
    }

    /// 圖片工具列的鎖頭：固定／解開
    /// 圖片縮成小圖（v12.8.3）：頁面上只留一個小縮圖，點了彈出大圖
    func miniImage() {
        guard let editor = imageEditor else { return }
        var box = editor.box
        box.mini = true
        imageEdited(box, commit: true)
        endImageSelection()
        showMessage("arrow.down.right.and.arrow.up.left", "縮成小圖了，點一下就會彈出大圖")
    }

    /// 小圖放回原本的大小
    func expandMiniImage(_ id: UUID, pageID: UUID) {
        guard !readOnly, let pv = pageViews[pageID] else { return }
        var images = model.images(of: pageID)
        guard let i = images.firstIndex(where: { $0.id == id }) else { return }
        images[i].mini = nil
        setImagesRecorded(images, pageID: pageID)
        pv.syncImages(images)
    }

    // MARK: 小圖點開：彈出大圖（v12.8.3）

    private var imageViewer: UIView?

    func showImageViewer(_ box: ImageBox, on pv: NotePageView) {
        imageViewer?.removeFromSuperview()
        guard let image = Store.loadImage(box.file, pageID: pv.page.id), let thumb = pv.imageViews[box.id] else { return }
        let start = thumb.convert(thumb.bounds, to: self)
        let overlay = UIView(frame: bounds)
        overlay.backgroundColor = UIColor(white: 0, alpha: 0)
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 8
        overlay.addSubview(iv)
        // 下面兩個按鈕：放回原本的大小、關閉
        let bar = UIStackView()
        bar.axis = .horizontal
        bar.spacing = 12
        func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.filled()
            config.title = title
            config.image = UIImage(systemName: symbol)
            config.imagePadding = 6
            config.cornerStyle = .capsule
            config.baseBackgroundColor = UIColor(white: 0.2, alpha: 0.95)
            config.baseForegroundColor = UIColor.white
            let b = UIButton(configuration: config)
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            return b
        }
        let pageID = pv.page.id
        let id = box.id
        if !readOnly {
            bar.addArrangedSubview(button("放回原本的大小", "arrow.up.left.and.arrow.down.right") { [weak self] in
                self?.closeImageViewer(to: nil)
                self?.expandMiniImage(id, pageID: pageID)
            })
        }
        bar.addArrangedSubview(button("關閉", "xmark") { [weak self] in
            self?.closeImageViewer(to: start)
        })
        overlay.addSubview(bar)
        let size = bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        bar.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 40,
                           width: size.width, height: size.height)
        let tap = UITapGestureRecognizer(target: self, action: #selector(imageViewerTapped(_:)))
        overlay.addGestureRecognizer(tap)
        addSubview(overlay)
        imageViewer = overlay
        viewerStart = start
        // 從小圖的位置彈出來
        let maxW = bounds.width * 0.86
        let maxH = (bounds.height - topReserved) * 0.78
        let k = min(maxW / max(image.size.width, 1), maxH / max(image.size.height, 1))
        let w = image.size.width * k
        let h = image.size.height * k
        let target = CGRect(x: (bounds.width - w) / 2, y: topReserved + (bounds.height - topReserved - h) / 2 - 20,
                            width: w, height: h)
        iv.frame = start
        bar.alpha = 0
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.2,
                       options: [], animations: {
            iv.frame = target
            overlay.backgroundColor = UIColor(white: 0, alpha: 0.72)
            bar.alpha = 1
        }, completion: nil)
        imageViewerImage = iv
    }

    private var viewerStart: CGRect = .zero
    private weak var imageViewerImage: UIImageView?

    /// 點大圖外面的暗處：收回小圖（點在大圖上不動）
    @objc private func imageViewerTapped(_ g: UITapGestureRecognizer) {
        guard let iv = imageViewerImage else { return }
        if !iv.bounds.contains(g.location(in: iv)) { closeImageViewer(to: viewerStart) }
    }

    /// 收回：縮回小圖的位置再消失（to = nil：直接淡出）
    private func closeImageViewer(to rect: CGRect?) {
        guard let overlay = imageViewer, let iv = imageViewerImage else { return }
        imageViewer = nil
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseIn], animations: {
            if let r = rect { iv.frame = r } else { iv.alpha = 0 }
            overlay.backgroundColor = UIColor(white: 0, alpha: 0)
            for v in overlay.subviews where v !== iv { v.alpha = 0 }
        }, completion: { _ in
            overlay.removeFromSuperview()
        })
    }

    func toggleImageLock() {
        guard let editor = imageEditor else { return }
        var box = editor.box
        box.locked = box.isLocked ? nil : true
        editor.update(box)
        imageEdited(box, commit: true)
        showMessage(box.isLocked ? "lock.fill" : "lock.open", box.isLocked ? "已固定圖片" : "已解開固定")
    }

    func toggleImageLayer() {
        guard let editor = imageEditor else { return }
        var box = editor.box
        box.above.toggle()
        editor.update(box)
        imageEdited(box, commit: true)
        showMessage(box.above ? "square.3.layers.3d.top.filled" : "square.3.layers.3d.bottom.filled",
                    box.above ? "放到筆跡上面" : "放到筆跡下面")
    }

    func deleteImage() {
        guard let editor = imageEditor, let pv = editor.pageView else { return }
        let wasCard = editor.box.link != nil
        var images = model.images(of: pv.page.id)
        images.removeAll { $0.id == editor.box.id }
        model.setImages(images, pageID: pv.page.id)
        pv.syncImages(images)
        endImageSelection()
        if wasCard {                                           // 卡片（v12.13.0）：只是拿掉卡片，筆記本沒有刪
            showMessage("trash", "卡片拿掉了，筆記本還在。按復原 ↶ 放回來；或長按白板 →「匯入現有的」再放一張")
        }
    }

    // MARK: 版面

    override func layoutSubviews() {
        super.layoutSubviews()
        outer.frame = bounds
        layoutBoardHUD()
        guard bounds.width > 0, abs(bounds.width - lastWidth) > 0.5 else { return }
        let first = lastWidth == 0
        lastWidth = bounds.width
        // v12.10：寬度變了（轉向、分割畫面、滑去別的 App 時系統用別的大小拍縮圖）會整份重排。
        // 以前重排後捲動位置的數字不變，但每一頁的高度變了，回來就停在別頁（使用者：滑去別的 App 再回來，從第三頁跳回第二頁）。
        // 現在先記住「畫面最上面是哪一列的幾分之幾」，重排後回到同一個地方
        var anchor: (row: UUID, fraction: CGFloat)?
        if !first, !isBoard {
            let top = outer.contentOffset.y
            for row in model.notebook.rows {
                guard let f = rowViews[row.id]?.frame, f.height > 0 else { continue }
                if f.maxY > top {
                    anchor = (row.id, (top - f.minY) / f.height)
                    break
                }
            }
        }
        layoutDocument()
        if let a = anchor, let f = rowViews[a.row]?.frame {
            let maxY = max(0, outer.contentSize.height + outer.contentInset.bottom - outer.bounds.height)
            outer.contentOffset.y = min(max(f.minY + a.fraction * f.height, 0), maxY)
        }
        for rv in rowViews.values where !rv.ranges.isEmpty {
            if first { rv.currentIndex = rv.mainIndex }
            let inPage = rv.currentIndex == rv.mainIndex ? sharedInPageX : 0
            rv.contentOffset.x = rv.offsetFor(rv.currentIndex, inPage: inPage)
        }
        Task { @MainActor [weak self] in
            if first { self?.restoreLastPosition() }       // 打開筆記本：回到上次看到的那一頁
            self?.updateLoadedPages()
            self?.updateFocus(force: true)
        }
    }

    // MARK: 歷史版本

    /// 自動保存（變更範本前、刪除頁面前）：兩分鐘內同一種原因已經存過就不再存
    /// （連續刪好幾頁時，保留的是刪第一頁之前的樣子）
    func autoSnapshot(reason: String) {
        let id = model.meta.id
        if let last = Store.snapshots(id).first(where: { !$0.manual }),
           last.reason.contains(reason), Date().timeIntervalSince(last.date) < 120 { return }
        flushAll()
        if sameAsLatest(addReason: reason) { return }
        Store.makeSnapshot(model.notebook, id: id, manual: false, reason: reason)
    }

    /// 有打開筆記本的那天，第一次打開時存一份（等於上一次用完的樣子）；內容沒變就不存
    private func dailySnapshotIfNeeded() {
        let id = model.meta.id
        if let last = Store.snapshots(id).first(where: { !$0.manual }), Calendar.current.isDateInToday(last.date) { return }
        if sameAsLatest(addReason: nil) { return }
        Store.makeSnapshot(model.notebook, id: id, manual: false, reason: "每日自動")
    }

    /// 內容跟最新一份歷史版本一樣：不重複存。addReason 有值時，在那一份（自動保存）的原因後面補上這次的原因
    private func sameAsLatest(addReason: String?) -> Bool {
        let id = model.meta.id
        guard let latest = Store.snapshots(id).first, let saved = latest.fingerprint,
              saved == Store.fingerprint(model.notebook) else { return false }
        if let reason = addReason, !latest.manual, !latest.reason.contains(reason) {
            var updated = latest
            updated.reason += "、" + reason
            Store.updateSnapshot(updated, notebook: id)
        }
        return true
    }

    func manualSnapshot() {
        flushAll()
        Store.makeSnapshot(model.notebook, id: model.meta.id, manual: true, reason: "手動保存")
        showMessage("clock.arrow.circlepath", "已保存目前版本")
    }

    /// 恢復歷史版本：先把目前的樣子存一份「恢復前」，再整本換掉；backup = false：反悔時用，不另外存
    func restoreSnapshot(_ snapshot: SnapshotInfo, backup: Bool = true) {
        hideRegret()
        if cropMode { setCropMode(false) }
        endTextSelection()
        dismissShapeEditor()
        hideTapeDelete()
        flushAll()
        overviewCache = nil                                    // 白板縮放時墊的低解析度圖：內容整個換了
        let id = model.meta.id
        // 先不清舊的自動保存：要恢復的那一份可能剛好是最舊的
        let backupInfo: SnapshotInfo? = backup
            ? Store.makeSnapshot(model.notebook, id: id, manual: false, reason: "恢復前", trim: false) : nil
        // 不存檔地拿掉所有頁面（不然會把現在的筆跡寫回去）
        for (_, pv) in pageViews {
            pv.discard()
            toolPicker.removeObserver(pv.canvas)
            pv.removeFromSuperview()
        }
        pageViews = [:]
        guard let data = Store.restoreSnapshot(snapshot, notebook: id) else {
            rebuild()
            showMessage("exclamationmark.triangle", "恢復失敗")
            return
        }
        model.notebook = data
        history.removeAllActions()
        model.canUndo = false
        model.canRedo = false
        revealedTapes = []
        rebuild()
        for row in data.rows { rowViews[row.id]?.currentIndex = row.mainIndex }   // 每一列先回到主頁
        layoutDocument()
        if let pid = data.lastPage, let loc = model.location(of: pid) {
            jump(toRow: loc.row, page: loc.page)
        } else {
            jump(toRow: 0, page: data.rows.first?.mainIndex ?? 0)
        }
        savedLastPage = data.lastPage
        updateLoadedPages()
        updateFocus(force: true)
        Store.trimAutoSnapshots(id, protecting: snapshot.id)
        if let b = backupInfo {
            showRegret(b, restoredTitle: snapshot.displayTitle)
        } else {
            showMessage("arrow.uturn.backward", "已回到恢復之前")
        }
    }

    // MARK: 恢復後的「反悔」（倒數 10 秒）

    private let regretBar = UIView()
    private let regretLabel = UILabel()
    private let regretButton = UIButton(type: .system)
    private var regretSnapshot: SnapshotInfo?
    private var regretCount = 0
    private var regretToken = 0

    private func setUpRegretBar() {
        regretBar.backgroundColor = UIColor(white: 0.14, alpha: 0.96)
        regretBar.layer.cornerRadius = 26
        regretBar.layer.shadowColor = UIColor.black.cgColor
        regretBar.layer.shadowOpacity = 0.3
        regretBar.layer.shadowRadius = 8
        regretLabel.textColor = .white
        regretLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        regretLabel.lineBreakMode = .byTruncatingMiddle
        regretBar.addSubview(regretLabel)
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = .systemOrange
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        regretButton.configuration = config
        regretButton.addAction(UIAction { [weak self] _ in self?.undoRestore() }, for: .touchUpInside)
        regretBar.addSubview(regretButton)
        regretBar.isHidden = true
        addSubview(regretBar)
    }

    private func showRegret(_ backup: SnapshotInfo, restoredTitle: String) {
        if regretBar.superview == nil { setUpRegretBar() }
        regretSnapshot = backup
        regretCount = 10
        regretToken += 1
        regretLabel.text = "已恢復到「\(restoredTitle)」"
        updateRegretButton()
        let w: CGFloat = min(460, bounds.width - 40)
        let h: CGFloat = 52
        regretBar.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height - safeAreaInsets.bottom - h - 24, width: w, height: h)
        regretButton.frame = CGRect(x: w - 132, y: 7, width: 124, height: 38)
        regretLabel.frame = CGRect(x: 20, y: 0, width: w - 160, height: h)
        regretBar.isHidden = false
        bringSubviewToFront(regretBar)
        scheduleRegretTick(regretToken)
    }

    private func updateRegretButton() {
        regretButton.configuration?.title = "反悔（\(regretCount)）"
    }

    private func scheduleRegretTick(_ token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.regretToken == token, self.regretSnapshot != nil else { return }
            self.regretCount -= 1
            if self.regretCount <= 0 {
                self.hideRegret()
            } else {
                self.updateRegretButton()
                self.scheduleRegretTick(token)
            }
        }
    }

    private func hideRegret() {
        regretToken += 1
        regretSnapshot = nil
        regretBar.isHidden = true
    }

    /// 反悔：回到恢復之前（用剛剛自動存的「恢復前」），那一份用完就刪掉
    private func undoRestore() {
        guard let backup = regretSnapshot else { return }
        hideRegret()
        restoreSnapshot(backup, backup: false)
        Store.deleteSnapshot(backup, notebook: model.meta.id)
    }

    // MARK: 上次看到的位置

    private var positionRestored = false     // 回到上次位置之前，不記錄目前頁（避免先被第一頁蓋掉）
    private var savedLastPage: UUID?

    private func restoreLastPosition() {
        defer {
            positionRestored = true
            dailySnapshotIfNeeded()                        // 每天第一次打開：存一份歷史版本
            SelfTest.notebookOpened(self)                  // 自動測試的場景才會做事
            if isBoard { refreshCardCovers() }             // 白板上的卡片：封面換成最新的（v12.12.2）
        }
        if isBoard {
            restoreBoardView()                                 // 白板：回到上次的位置和縮放
            return
        }
        guard let pid = model.notebook.lastPage, let loc = model.location(of: pid) else { return }
        savedLastPage = pid
        jump(toRow: loc.row, page: loc.page)
    }

    // MARK: 白板的位置和縮放（v12.3）：每張白板各自記在 UserDefaults 的 boardView.<編號>（縮放、左上角在白板上的位置）

    private var boardViewKey: String { "boardView." + model.meta.id.uuidString }

    private func saveBoardView() {
        guard let row = model.notebook.rows.first, let rv = rowViews[row.id], rv.ranges.indices.contains(0) else { return }
        guard bounds.width > 50, bounds.height > 50 else { return }   // 畫面正在收起來（大小不正常）：不要把錯的位置存進去（v12.12.3）
        let s = max(scale, 0.0001)
        let x = (rv.contentOffset.x - rv.ranges[0].lo) / s
        let y = outer.contentOffset.y / s
        UserDefaults.standard.set([Double(zoom), Double(x), Double(y)], forKey: boardViewKey)
    }

    private func restoreBoardView() {
        guard let row = model.notebook.rows.first, let page = row.pages.first, let rv = rowViews[row.id] else { return }
        var z = clampZoom(boardZoom100)                        // 第一次打開：100%，在白板的正中間
        let s100 = baseScale * z
        var x: CGFloat = max(0, page.spec.width / 2 - bounds.width / max(s100, 0.0001) / 2)
        var y: CGFloat = max(0, page.spec.height / 2 - bounds.height / max(s100, 0.0001) / 2)
        if let saved = UserDefaults.standard.array(forKey: boardViewKey) as? [Double], saved.count == 3 {
            z = clampZoom(CGFloat(saved[0]))
            x = CGFloat(saved[1])
            y = CGFloat(saved[2])
        }
        zoom = z
        layoutDocument()
        let s = scale
        if rv.ranges.indices.contains(0) {
            let r = rv.ranges[0]
            rv.contentOffset.x = min(max(r.lo + x * s, r.lo), r.hi)
        }
        outer.contentOffset.y = clampOuterY(y * s)
        finishZoom()
        updateBoardWindow(force: true)
    }

    // MARK: 白板左下角：位置預覽、百分比、鎖定縮放；位置條（v12.6）

    private let hud = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let mapButton = UIButton(type: .system)
    // v12.15.0（使用者要求，照 GUGA）：位置預覽的按鈕改到右下角；左下角第一顆換成「收起視窗」（有浮動視窗時才出現）
    private let mapHUD = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let windowsButton = UIButton(type: .system)
    /// 白板上開著幾個浮動視窗、是不是都收起來了（NotebookEditorView 告訴它）
    var boardWindowCount = 0 {
        didSet { if boardWindowCount != oldValue { layoutBoardHUD() } }
    }
    var boardWindowsTucked = false {
        didSet { if boardWindowsTucked != oldValue { refreshWindowsButton() } }
    }
    var onToggleWindows: (() -> Void)?

    private func refreshWindowsButton() {
        let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        windowsButton.setImage(UIImage(systemName: boardWindowsTucked ? "rectangle.on.rectangle" : "rectangle.dashed",
                                       withConfiguration: config), for: .normal)
        windowsButton.tintColor = boardWindowsTucked ? UIColor.systemOrange : UIColor.label
    }

    @objc private func windowsTapped() {
        onToggleWindows?()
    }
    private let percentButton = UIButton(type: .system)
    private let lockButton = UIButton(type: .system)
    private let minimap = UIView()
    private let minimapImage = UIImageView()
    private let minimapFrame = CAShapeLayer()
    private let vBar = UIView()                               // 右邊的位置條（上下）
    private let hBar = UIView()                               // 下面的位置條（左右）
    private var barsLastMove: CFTimeInterval = 0
    private var barsHideScheduled = false
    private var shownPercent = -1

    /// 白板鋪到工具列下面（v12.8）：上面這一段被工具列蓋住，工具列、提示要放在它下面
    var topReserved: CGFloat {
        guard isBoard else { return 0 }
        if topBarHeight > 0 { return (window?.safeAreaInsets.top ?? 24) + topBarHeight }   // 狀態列＋上面兩排（SwiftUI 量好告訴我）
        return max(safeAreaInsets.top, (window?.safeAreaInsets.top ?? 24) + 104)   // 還不知道：分頁（44）＋工具那一排（58）
    }

    /// 上面分頁＋工具那兩排的高度（v12.8.8：編輯畫面量好傳進來）
    var topBarHeight: CGFloat = 0

    /// 白板（v12.8.8）：白板鋪到上面兩排的底下，那一塊的觸控不要收，交給上面的按鈕。
    /// 以前（v12.8.4 起上面兩排改成 SwiftUI 自己排）白板的點一下、長按等手勢會先搶走觸控，工具列點不了
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isBoard, point.y < topReserved { return false }
        return super.point(inside: point, with: event)
    }

    private var zoomLockKey: String { "boardLock." + model.meta.id.uuidString }
    /// 鎖定縮放：只能平移，不能縮放（每張白板各自記住）
    private var zoomLocked: Bool {
        get { UserDefaults.standard.bool(forKey: zoomLockKey) }
        set { UserDefaults.standard.set(newValue, forKey: zoomLockKey) }
    }

    /// 給白板的設定面板用的開關（v12.9.2）：跟左下角的鎖頭同一個設定
    var zoomLockSetting: Bool {
        get { zoomLocked }
        set {
            zoomLocked = newValue
            pinchGesture?.isEnabled = !newValue
            refreshLockButton()
        }
    }

    private func setUpBoardHUD() {
        guard hud.superview == nil else { return }
        hud.layer.cornerRadius = 24
        hud.clipsToBounds = true
        let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        mapButton.setImage(UIImage(systemName: "map", withConfiguration: config), for: .normal)
        mapButton.addTarget(self, action: #selector(toggleMinimap), for: .touchUpInside)
        percentButton.titleLabel?.font = UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        percentButton.addTarget(self, action: #selector(percentTapped), for: .touchUpInside)
        lockButton.addTarget(self, action: #selector(lockTapped), for: .touchUpInside)
        windowsButton.addTarget(self, action: #selector(windowsTapped), for: .touchUpInside)
        refreshWindowsButton()
        for b in [windowsButton, percentButton, lockButton] {
            b.tintColor = UIColor.label
            hud.contentView.addSubview(b)
        }
        windowsButton.tintColor = UIColor.label
        addSubview(hud)
        mapHUD.layer.cornerRadius = 24
        mapHUD.clipsToBounds = true
        mapButton.tintColor = UIColor.label
        mapHUD.contentView.addSubview(mapButton)
        addSubview(mapHUD)
        // 位置預覽
        minimap.backgroundColor = UIColor(white: 0.12, alpha: 0.95)
        minimap.layer.cornerRadius = 12
        minimap.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
        minimap.layer.borderWidth = 1
        minimap.clipsToBounds = true
        minimap.isHidden = true
        minimapImage.contentMode = .scaleToFill
        minimap.addSubview(minimapImage)
        minimapFrame.fillColor = UIColor.systemOrange.withAlphaComponent(0.15).cgColor
        minimapFrame.strokeColor = UIColor.systemOrange.cgColor
        minimapFrame.lineWidth = 2
        minimap.layer.addSublayer(minimapFrame)
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(minimapTouched(_:)))
        drag.minimumPressDuration = 0
        minimap.addGestureRecognizer(drag)
        addSubview(minimap)
        // 位置條
        for bar in [vBar, hBar] {
            bar.backgroundColor = UIColor(white: 0.85, alpha: 0.7)
            bar.layer.cornerRadius = 2.5
            bar.alpha = 0
            bar.isUserInteractionEnabled = false
            addSubview(bar)
        }
        pinchGesture?.isEnabled = !zoomLocked
        refreshLockButton()
        // 白板的手勢分工（v12.8.5）：一根手指＝捲動；兩根手指＝縮放（縮放時跟著兩指中心移動）。
        // 以前兩根手指也會被捲動接走，縮放常常變成移動。v12.8.6 拿掉單純的雙指移動（使用者用不到，還可能讓縮放一開始先動一下）
        outer.panGestureRecognizer.maximumNumberOfTouches = 1
        for rv in rowViews.values { rv.panGestureRecognizer.maximumNumberOfTouches = 1 }
        pinchGesture?.delegate = self
        // 區塊：用 Pencil 拉方框（只有按了「新區塊」之後才開）
        framePan.addTarget(self, action: #selector(handleFramePan(_:)))
        framePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        framePan.isEnabled = false
        addGestureRecognizer(framePan)
        framePreview.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        framePreview.strokeColor = UIColor.systemBlue.cgColor
        framePreview.lineWidth = 2
        framePreview.lineDashPattern = [8, 6]
        layer.addSublayer(framePreview)
        setUpFrameBar()
        setUpFrameBodyPress()
        layoutBoardHUD()
        updateBoardHUD()
    }

    private func refreshLockButton() {
        let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        lockButton.setImage(UIImage(systemName: zoomLocked ? "lock.fill" : "lock.open", withConfiguration: config), for: .normal)
        lockButton.tintColor = zoomLocked ? UIColor.systemOrange : UIColor.label
        // 筆記本左下角的鎖頭（v12.9.1）
        let small = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        pageLockButton.setImage(UIImage(systemName: zoomLocked ? "lock.fill" : "lock.open", withConfiguration: small), for: .normal)
        pageLockButton.tintColor = zoomLocked ? UIColor.systemOrange : UIColor.label
    }

    // MARK: 筆記本左下角的百分比（v12.8.4）：顯示現在的大小，點一下跳到「預設的大小」（⋯ → 檢視 可以改）

    private let pageZoomHUD = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let pageZoomButton = UIButton(type: .system)
    private let pageLockButton = UIButton(type: .system)       // 鎖定縮放（v12.9.1，跟白板一樣）
    private var shownPageZoom = -1
    static let zoomPresetKey = "notebookZoomPreset"           // "page"＝貼合整頁、"width"＝貼合寬度、數字＝自訂（zoom）

    private func setUpPageZoomHUD() {
        // 浮動視窗裡的筆記本（v12.15.0，使用者要求）：不放左下角的百分比和鎖頭
        guard !isBoard, !model.embedded, pageZoomHUD.superview == nil else { return }
        pageZoomHUD.layer.cornerRadius = 22
        pageZoomHUD.clipsToBounds = true
        pageZoomButton.titleLabel?.font = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        pageZoomButton.tintColor = UIColor.label
        pageZoomButton.addTarget(self, action: #selector(pageZoomTapped), for: .touchUpInside)
        pageZoomHUD.contentView.addSubview(pageZoomButton)
        pageLockButton.addTarget(self, action: #selector(lockTapped), for: .touchUpInside)
        pageZoomHUD.contentView.addSubview(pageLockButton)
        addSubview(pageZoomHUD)
        pinchGesture?.isEnabled = !zoomLocked
        refreshLockButton()
        layoutPageZoomHUD()
        updatePageZoomHUD()
    }

    private func layoutPageZoomHUD() {
        guard pageZoomHUD.superview != nil else { return }
        let box = PenBoxModel.shared
        var penBelow = box.dock == .bottom && !box.minimized
        if penBelow {
            let count = CGFloat(box.collapsed ? 1 : box.presets.count + 7)
            if (bounds.width - (count * 44 + 16)) / 2 > 16 + 140 + 12 { penBelow = false }
        }
        let y = bounds.height - 44 - (penBelow ? 112 : 28)
        pageZoomHUD.frame = CGRect(x: 16, y: y, width: 140, height: 44)
        pageZoomButton.frame = CGRect(x: 4, y: 0, width: 88, height: 44)
        pageLockButton.frame = CGRect(x: 90, y: 0, width: 46, height: 44)
        bringSubviewToFront(pageZoomHUD)
    }

    private func updatePageZoomHUD() {
        guard pageZoomHUD.superview != nil else { return }
        let percent = Int(((boardPinching ? pinchLastZoom : zoom) * 100).rounded())   // 貼合寬度＝100%；縮放中顯示手指的大小
        guard percent != shownPageZoom else { return }
        shownPageZoom = percent
        UIView.performWithoutAnimation {
            pageZoomButton.setTitle("\(percent)%", for: .normal)
            pageZoomButton.layoutIfNeeded()
        }
    }

    /// 現在的大小（「記住目前的大小」用）
    var currentZoom: CGFloat { zoom }

    @objc private func pageZoomTapped() {
        zoomToPreset()
    }

    /// 跳到預設的大小：貼合整頁（整張頁面放進畫面、置中）、貼合寬度、或自己記住的大小
    func zoomToPreset() {
        let preset = UserDefaults.standard.string(forKey: Self.zoomPresetKey) ?? "width"     // 預設 100%（v12.8.7）
        var target: CGFloat = 1
        if preset == "page" {
            target = fitPageZoom()
        } else if preset != "width", let v = Double(preset) {
            target = CGFloat(v)
        }
        // v12.10：連續地縮放過去（以前一下跳過去）
        animateZoom(to: clampZoom(target)) { [weak self] in
            guard let self = self, preset == "page" else { return }
            self.centerFocusedPage()
            self.finishZoom()
        }
    }

    // MARK: 連續縮放的動畫（v12.10）：左下角的 % 用。做法跟雙指縮放一樣：過程中只把整個畫面放大縮小，最後才真的重排一次

    private var zoomAnimLink: CADisplayLink?
    private var zoomAnimStart: CFTimeInterval = 0
    private var zoomAnimFrom: CGFloat = 1
    private var zoomAnimTo: CGFloat = 1
    private var zoomAnimThen: (() -> Void)?

    private func animateZoom(to target: CGFloat, then: (() -> Void)? = nil) {
        finishZoomAnimation()                                  // 上一段還沒跑完：先直接跳到終點
        guard abs(target - zoom) > 0.005, !isPinching else {
            then?()
            return
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        pinchStartZoom = zoom
        captureZoomAnchors(at: center)
        if isBoard {
            startBoardPinch(at: center)
        } else {
            startPagePinch(at: center)
        }
        zoomAnimFrom = zoom
        zoomAnimTo = target
        zoomAnimThen = then
        zoomAnimStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(zoomAnimStep(_:)))
        link.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
        zoomAnimLink = link
    }

    @objc private func zoomAnimStep(_ link: CADisplayLink) {
        let t = CGFloat(min(1, (CACurrentMediaTime() - zoomAnimStart) / 0.3))
        let eased = 1 - pow(1 - t, 3)                          // 先快後慢
        let ratio = zoomAnimTo / max(zoomAnimFrom, 0.0001)
        let z = zoomAnimFrom * pow(ratio, eased)               // 照倍率走，放大和縮小感覺一樣快
        moveBoardPinch(zoom: z, at: CGPoint(x: bounds.midX, y: bounds.midY))
        if t >= 1 { finishZoomAnimation() }
    }

    /// 動畫跑完（或被打斷）：真的換到新的大小
    private func finishZoomAnimation() {
        guard let link = zoomAnimLink else { return }
        link.invalidate()
        zoomAnimLink = nil
        moveBoardPinch(zoom: zoomAnimTo, at: CGPoint(x: bounds.midX, y: bounds.midY))
        endBoardPinch()
        finishZoom()
        let then = zoomAnimThen
        zoomAnimThen = nil
        then?()
    }

    /// 目前這一頁整張放進畫面的大小
    private func fitPageZoom() -> CGFloat {
        guard let id = model.currentPageID, let page = model.page(id) else { return 1 }
        let availW = bounds.width - 2 * margin
        let availH = bounds.height - safeAreaInsets.top - 2 * topInset
        let zw = availW / max(page.spec.width * baseScale, 1)
        let zh = availH / max(page.spec.height * baseScale, 1)
        return min(zw, zh)
    }

    /// 目前這一頁放到畫面正中間
    private func centerFocusedPage() {
        let rows = model.notebook.rows
        guard rows.indices.contains(focusRow), let rv = rowViews[rows[focusRow].id],
              rv.ranges.indices.contains(rv.currentIndex) else { return }
        let r = rv.ranges[rv.currentIndex]
        rv.contentOffset.x = (r.lo + r.hi) / 2
        outer.contentOffset.y = clampOuterY(rv.frame.midY - outer.bounds.height / 2)
    }

    /// 左下角的位置：筆盒停在下面時往上讓開
    /// 白板上有分屏的浮動視窗（v12.15.0）：左半邊被視窗蓋住，左下角的按鈕往右讓這麼多
    var boardLeftInset: CGFloat = 0 {
        didSet { if boardLeftInset != oldValue { layoutBoardHUD() } }
    }

    func layoutBoardHUD() {
        layoutPageZoomHUD()                                    // 筆記本的百分比（v12.8.4）也一起
        guard hud.superview != nil else { return }
        let box = PenBoxModel.shared
        var penBelow = box.dock == .bottom && !box.minimized
        if penBelow {
            // 筆盒停在下面、在畫面中間：估計它的寬度（每個按鈕約 44 點），擋不到左下角就不用讓開
            let count = CGFloat(box.collapsed ? 1 : box.presets.count + 7)
            let penWidth = count * 44 + 16
            if (bounds.width - penWidth) / 2 > 16 + 196 + 12 { penBelow = false }
        }
        let y = bounds.height - 48 - (penBelow ? 112 : 28)
        // 左下角：［收起視窗］百分比　鎖頭（收起視窗只有開著浮動視窗時才有）
        let lead: CGFloat = boardWindowCount > 0 ? 50 : 0
        windowsButton.isHidden = boardWindowCount == 0
        hud.frame = CGRect(x: 16 + boardLeftInset, y: y, width: 146 + lead, height: 48)
        windowsButton.frame = CGRect(x: 6, y: 0, width: 50, height: 48)
        percentButton.frame = CGRect(x: 6 + lead, y: 0, width: 84, height: 48)
        lockButton.frame = CGRect(x: 90 + lead, y: 0, width: 50, height: 48)
        // 右下角：位置預覽（筆盒停在右邊時往左讓開）
        let penRight = box.dock == .trailing && !box.minimized
        mapHUD.frame = CGRect(x: bounds.width - 16 - 52 - (penRight ? 76 : 0), y: y, width: 52, height: 48)
        mapButton.frame = mapHUD.bounds
        bringSubviewToFront(hud)
        bringSubviewToFront(mapHUD)
        layoutMinimap()
        bringSubviewToFront(minimap)
    }

    /// 位置預覽的大小：最寬 260、最高 260，比例跟白板一樣
    private func layoutMinimap() {
        guard let page = model.notebook.rows.first?.pages.first else { return }
        let ratio = page.spec.height / max(page.spec.width, 1)
        var w: CGFloat = 260
        var h = w * ratio
        if h > 260 {
            h = 260
            w = h / max(ratio, 0.01)
        }
        minimap.frame = CGRect(x: mapHUD.frame.maxX - w, y: mapHUD.frame.minY - 12 - h, width: w, height: h)
        minimapImage.frame = minimap.bounds
    }

    /// 現在畫面上看得到白板的哪一塊（頁面座標）
    private func boardVisibleRect() -> CGRect? {
        guard isBoard, let page = model.notebook.rows.first?.pages.first, let pv = pageViews[page.id] else { return nil }
        let s = pv.bounds.width / max(page.spec.width, 1)
        guard s > 0 else { return nil }
        let v = pv.convert(bounds, from: self)
        return CGRect(x: v.minX / s, y: v.minY / s, width: v.width / s, height: v.height / s)
    }

    /// 捲動、縮放時：更新百分比、位置條、位置預覽上的框
    func updateBoardHUD() {
        guard isBoard, hud.superview != nil, let page = model.notebook.rows.first?.pages.first else { return }
        positionFrameBar()
        positionPinBar()
        // v12.15.4（使用者）：點第一次 → 100%，按鈕寫「100%」；再點一次 → 回原點，按鈕寫「原點」。
        // 只有真的在原點（100%、畫面中間是白板的正中間）才寫「原點」；捲開了就寫百分比
        var atOrigin = false
        if abs(boardPercent - 1) <= 0.01, let v = boardVisibleRect() {
            let tolerance = max(v.width, v.height) * 0.02
            atOrigin = abs(v.midX - page.spec.width / 2) <= tolerance && abs(v.midY - page.spec.height / 2) <= tolerance
        }
        let percent = atOrigin ? -100 : Int((boardPercent * 100).rounded())
        if percent != shownPercent {                          // 捲動時每一格都會呼叫：數字沒變就不要重設（按鈕換字會閃）
            shownPercent = percent
            UIView.performWithoutAnimation {
                percentButton.setTitle(atOrigin ? "原點" : "\(percent)%", for: .normal)
                percentButton.layoutIfNeeded()
            }
        }
        guard let visible = boardVisibleRect() else { return }
        let W = max(page.spec.width, 1)
        let H = max(page.spec.height, 1)
        // 位置預覽上的框
        if !minimap.isHidden {
            let k = minimap.bounds.width / W
            let r = CGRect(x: visible.minX * k, y: visible.minY * k, width: visible.width * k, height: visible.height * k)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            minimapFrame.path = UIBezierPath(rect: r.intersection(minimap.bounds).isNull ? r : r.intersection(minimap.bounds)).cgPath
            CATransaction.commit()
        }
        // 位置條：捲動時出現，停 1 秒後淡出
        let top: CGFloat = 110
        let bottom = bounds.height - 110
        let trackH = max(bottom - top, 40)
        let vh = max(30, min(trackH, trackH * visible.height / H))
        let vy = top + (trackH - vh) * min(max(visible.minY / max(H - visible.height, 1), 0), 1)
        vBar.frame = CGRect(x: bounds.width - 9, y: vy, width: 5, height: vh)
        let left: CGFloat = 230
        let right = bounds.width - 40
        let trackW = max(right - left, 40)
        let hw = max(30, min(trackW, trackW * visible.width / W))
        let hx = left + (trackW - hw) * min(max(visible.minX / max(W - visible.width, 1), 0), 1)
        hBar.frame = CGRect(x: hx, y: bounds.height - 12, width: hw, height: 5)
        if !isPinching {
            vBar.alpha = 1
            hBar.alpha = 1
            barsLastMove = CACurrentMediaTime()
            if !barsHideScheduled { scheduleBarsHide(after: 1.0) }
        }
    }

    /// 位置條停 1 秒後淡出。以前捲動時每一格都重新排一次計時（一秒幾十次）；現在只排一個，到時間再看要不要延後
    private func scheduleBarsHide(after delay: Double) {
        barsHideScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            let idle = CACurrentMediaTime() - self.barsLastMove
            if idle < 1.0 {
                self.scheduleBarsHide(after: 1.0 - idle + 0.02)
                return
            }
            self.barsHideScheduled = false
            UIView.animate(withDuration: 0.3) {
                self.vBar.alpha = 0
                self.hBar.alpha = 0
            }
        }
    }

    private func hideBoardIndicators() {
        vBar.alpha = 0
        hBar.alpha = 0
    }

    /// 左下角的百分比（v12.8.7）：不是 100% → 回到 100%（畫面中間不動）；已經是 100% → 回到原點（白板的正中間，新建時打開的位置）
    @objc private func percentTapped() {
        if abs(boardPercent - 1) > 0.01 {
            resetZoom()
        } else if let page = model.notebook.rows.first?.pages.first {
            boardShow(center: CGPoint(x: page.spec.width / 2, y: page.spec.height / 2), zoom: boardZoom100)
            showMessage("scope", "回到原點")
        }
        updateBoardHUD()
    }

    @objc private func lockTapped() {
        zoomLocked.toggle()
        pinchGesture?.isEnabled = !zoomLocked
        refreshLockButton()
        showMessage(zoomLocked ? "lock.fill" : "lock.open", zoomLocked ? "鎖定縮放：只能移動" : "可以縮放了")
    }

    /// 位置預覽：打開時畫一張整張白板的縮圖
    @objc private func toggleMinimap() {
        if !minimap.isHidden {
            minimap.isHidden = true
            mapButton.tintColor = UIColor.label
            return
        }
        guard let row = model.notebook.rows.first, let page = row.pages.first else { return }
        layoutMinimap()
        let drawing = pageViews[page.id]?.canvas.drawing ?? Store.loadDrawing(page.id)
        let current = model.page(page.id) ?? page
        // v12.8.1：以前用縮圖的畫法，會把整張白板的格線（幾千條）都畫一次，很慢
        let full = CGRect(x: 0, y: 0, width: current.spec.width, height: current.spec.height)
        minimapImage.image = Self.renderOverview(current, drawing: drawing, region: full,
                                                 pxPerPt: minimap.bounds.width * 2 / max(current.spec.width, 1))
        minimap.isHidden = false
        mapButton.tintColor = UIColor.systemOrange
        bringSubviewToFront(minimap)
        updateBoardHUD()
    }

    /// 在位置預覽上點、拖：畫面跳到那裡
    @objc private func minimapTouched(_ g: UILongPressGestureRecognizer) {
        guard let page = model.notebook.rows.first?.pages.first, minimap.bounds.width > 0 else { return }
        let p = g.location(in: minimap)
        let k = max(page.spec.width, 1) / minimap.bounds.width
        boardJump(to: CGPoint(x: p.x * k, y: p.y * k))
    }

    /// 畫面中間移到白板上的 q（頁面座標）
    func boardJump(to q: CGPoint) {
        guard isBoard, let row = model.notebook.rows.first, let rv = rowViews[row.id],
              rv.pageFrames.indices.contains(0), rv.ranges.indices.contains(0) else { return }
        let s = scale
        let pf = rv.pageFrames[0]
        let r = rv.ranges[0]
        rv.contentOffset.x = min(max(pf.minX + q.x * s - rv.bounds.width / 2, r.lo), r.hi)
        outer.contentOffset.y = clampOuterY(rv.frame.minY + pf.minY + q.y * s - outer.bounds.height / 2)
        updateBoardWindow(force: true)
    }

    // MARK: 白板的圖釘、區塊（v12.7）

    private var boardPV: NotePageView? {
        guard isBoard, let page = model.notebook.rows.first?.pages.first else { return nil }
        return pageViews[page.id]
    }

    /// 壓力測試（v12.9.7）：在畫面左上角附近產生假筆跡（一張 A4 約 1,500 筆，接著上一次的排下去），用來量白板撐得住多少。
    /// 可以雙指點復原。請在測試用的白板上按
    private var stressCount = 0
    private var stressOrigin = CGPoint.zero
    private var stressTemplates: [PKStroke] = []

    func addStressStrokes(_ count: Int) {
        guard isBoard, !readOnly, let pv = boardPV, let visible = boardVisibleRect() else { return }
        // v12.9.9：拿真的筆跡當範本複製（自己組的筆畫點放大後畫不出來）
        if stressTemplates.isEmpty { stressTemplates = Array(pv.canvas.drawing.strokes.prefix(20)) }
        if stressTemplates.isEmpty {
            showMessage("pencil", "請先用 Pencil 在白板上寫幾個字，再按一次")
            return
        }
        if stressCount == 0 { stressOrigin = CGPoint(x: visible.minX + 40, y: visible.minY + 220) }
        let added = StressStrokes.clones(of: stressTemplates, count: count, origin: stressOrigin, startIndex: stressCount)
        stressCount += count
        var drawing = pv.canvas.drawing
        drawing.strokes.append(contentsOf: added)
        let t0 = CACurrentMediaTime()
        pv.setDrawingRecorded(drawing)
        let t1 = CACurrentMediaTime()
        Store.saveDrawing(drawing, pageID: pv.page.id)
        let t2 = CACurrentMediaTime()
        let total = drawing.strokes.count
        let setMs = Int((t1 - t0) * 1000)
        let saveMs = Int((t2 - t1) * 1000)
        let points = stressTemplates.reduce(0) { $0 + $1.path.count } / max(stressTemplates.count, 1)
        showMessage("flask", "共 \(total) 筆（每筆約 \(points) 點）｜換上去 \(setMs) ms｜存檔 \(saveMs) ms"
                    + (boardTiled ? "（分區）" : ""))
    }

    // MARK: 分區儲存（v12.11.0，實驗）

    /// 這張白板的筆跡是不是分區儲存
    var boardTiled: Bool {
        guard isBoard, let page = model.notebook.rows.first?.pages.first else { return false }
        return BoardTiles.isTiled(page.id)
    }

    /// 齒輪面板上的說明：現在幾筆、分成幾格、這次打開讀筆跡花多久
    var boardInkInfo: String {
        guard let pv = boardPV else { return "" }
        let count = pv.canvas.drawing.strokes.count
        let tiles = boardTiled ? "，分成 \(BoardTiles.allKeys(pv.page.id).count) 格" : ""
        return "目前 \(count) 筆\(tiles)；這次打開讀筆跡花了 \(pv.loadMillis) ms。"
    }

    /// 開、關分區儲存。開：把整份筆跡拆成格子檔（原本的單一檔留著當備份）；關：合回單一檔。
    /// 畫布上的筆跡不變，只是換存法；每一格寫完都會讀回來核對筆數，不對就不換
    func setBoardTiled(_ on: Bool) {
        guard isBoard, !readOnly, let pv = boardPV, on != boardTiled else { return }
        pv.flush()
        Store.finishPendingSaves()
        let drawing = pv.canvas.drawing
        let count = drawing.strokes.count
        let t0 = CACurrentMediaTime()
        let problem = on ? BoardTiles.enable(pv.page.id, drawing: drawing) : BoardTiles.disable(pv.page.id, drawing: drawing)
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        if let problem = problem {
            showMessage("exclamationmark.triangle", "沒有換成功，筆跡沒有動：" + problem)
        } else if on {
            showMessage("square.grid.3x3", "已改用分區儲存（\(count) 筆，\(ms) ms）")
        } else {
            showMessage("square", "已改回單一檔案（\(count) 筆，\(ms) ms）")
        }
    }

    /// 自動測試（boardimage 場景）：一次貼三張圖（橫的、直的、很小的），回報每一張在白板上佔幾格
    func selfTestImages() -> String {
        guard let pv = boardPV else { return "沒有白板" }
        insertPickedImages([SelfTest.testImage(1600, 900, UIColor.systemTeal),
                            SelfTest.testImage(900, 1600, UIColor.systemOrange),
                            SelfTest.testImage(100, 60, UIColor.systemPink)])
        let unit = PaperRenderer.gridUnit
        var lines: [String] = []
        for box in model.images(of: pv.page.id) {
            lines.append(String(format: "寬 %.1f 格 × 高 %.1f 格", Double(box.width / unit), Double(box.height / unit)))
        }
        lines.append("（應該是：橫的 10.0 × 5.6、直的 5.6 × 10.0、小的 5.0 × 3.0 不放大）")
        return lines.joined(separator: "\n")
    }

    /// 自動測試（tiledboard 場景）：在開著的白板上關、開分區，加筆跡存檔，再復原；回報每一步畫布上和檔案裡的筆數
    func selfTestTiles() -> String {
        guard let pv = boardPV else { return "沒有白板" }
        let id = pv.page.id
        var lines: [String] = []
        let opened = pv.canvas.drawing.strokes.count
        lines.append("打開：畫布 \(opened) 筆，分區 \(boardTiled)。" + boardInkInfo)
        setBoardTiled(false)
        let off = Store.loadDrawing(id).strokes.count
        lines.append("關掉分區：分區 \(boardTiled)，檔案裡 \(off) 筆")
        setBoardTiled(true)
        let on = Store.loadDrawing(id).strokes.count
        lines.append("再打開分區：分區 \(boardTiled)，檔案裡 \(on) 筆，\(BoardTiles.allKeys(id).count) 格")
        var drawing = pv.canvas.drawing
        let center = CGPoint(x: pv.page.spec.width / 2, y: pv.page.spec.height / 2)
        drawing.strokes.append(contentsOf: BoardTileCheck.makeStrokes(count: 50, markers: 0,
                                                                     origin: CGPoint(x: center.x - 300, y: center.y + 200),
                                                                     spread: CGSize(width: 600, height: 200)))
        pv.setDrawingRecorded(drawing)
        Store.saveDrawingLater(drawing, pageID: id)
        Store.finishPendingSaves()
        let added = Store.loadDrawing(id).strokes.count
        lines.append("加 50 筆、背景存檔：畫布 \(pv.canvas.drawing.strokes.count) 筆，檔案裡 \(added) 筆")
        history.undo()
        Store.finishPendingSaves()
        let undone = Store.loadDrawing(id).strokes.count
        let canvasNow = boardPV?.canvas.drawing.strokes.count ?? -1
        lines.append("復原：畫布 \(canvasNow) 筆，檔案裡 \(undone) 筆")
        let ok = opened > 0 && off == opened && on == opened && added == opened + 50 && undone == opened
            && canvasNow == opened && boardTiled
        lines.append(ok ? "結果：全部正確" : "結果：有問題")
        return lines.joined(separator: "\n")
    }

    /// 畫面上的一點（這個畫面的座標）→ 白板的頁面座標
    private func boardPoint(_ p: CGPoint) -> CGPoint? {
        guard let pv = boardPV else { return nil }
        let s = pv.bounds.width / max(pv.page.spec.width, 1)
        guard s > 0 else { return nil }
        let local = pv.convert(p, from: self)
        return CGPoint(x: local.x / s, y: local.y / s)
    }

    private func syncBoardMarks() {
        if isBoard {
            boardPV?.syncBoardMarks(frames: model.notebook.frames ?? [], pins: model.notebook.pins ?? [])
        } else {
            // 筆記本的圖釘（v12.9）：每一頁只放釘在那一頁的
            for pv in pageViews.values {
                pv.syncBoardMarks(frames: [], pins: boardPins.filter { $0.pageID == pv.page.id })
            }
        }
    }

    /// 這個圖釘所在的頁面視圖（白板：那一張大頁面；筆記本：釘的那一頁，沒載入就是 nil）
    private func pinPV(_ id: UUID) -> NotePageView? {
        if isBoard { return boardPV }
        guard let pid = boardPins.first(where: { $0.id == id })?.pageID else { return nil }
        return pageViews[pid]
    }

    /// 改區塊、圖釘：寫進資料、更新畫面、登記復原（復原時再呼叫自己，所以重做也可以）
    func setBoardMarks(frames: [BoardFrame], pins: [BoardPin]) {
        if readOnly { return }
        let oldFrames = model.notebook.frames ?? []
        let oldPins = model.notebook.pins ?? []
        guard oldFrames != frames || oldPins != pins else { return }
        model.notebook.frames = frames
        model.notebook.pins = pins
        model.save()
        if let id = selectedFrameID, !frames.contains(where: { $0.id == id }) { deselectFrame() }
        syncBoardMarks()
        positionFrameBar()
        refreshFrameBar()
        if let id = selectedPinID, !pins.contains(where: { $0.id == id && !$0.isHidden }) { hidePinBar() }
        positionPinBar()
        history.registerUndo(withTarget: self) { notebook in
            notebook.setBoardMarks(frames: oldFrames, pins: oldPins)
        }
    }

    private var boardFrames: [BoardFrame] { model.notebook.frames ?? [] }
    private var boardPins: [BoardPin] { model.notebook.pins ?? [] }

    // 圖釘

    /// 一圈按鈕的「圖釘」：釘在長按的位置
    func createPin(at viewPoint: CGPoint) {
        guard !readOnly else { return }
        if isBoard {
            guard let q = boardPoint(viewPoint) else { return }
            addPin(at: q)
        } else {
            // 筆記本（v12.9）：釘在按的那一頁的那個位置
            guard let pv = pageViews.values.first(where: { $0.bounds.contains($0.convert(viewPoint, from: self)) }) else { return }
            let s = max(pv.bounds.width / max(pv.page.spec.width, 1), 0.0001)
            let local = pv.convert(viewPoint, from: self)
            addPin(at: CGPoint(x: local.x / s, y: local.y / s), pageID: pv.page.id)
        }
    }

    /// 右上角的 ＋ 或圖釘清單的 ＋：釘在畫面中間
    func addPinAtCenter() {
        createPin(at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// 新增圖釘（v12.8）：先跳出卡片選名稱、顏色、符號（沿用上一個圖釘的顏色、符號）
    private func addPin(at q: CGPoint, pageID: UUID? = nil) {
        let percent = isBoard ? boardPercent : zoom          // 筆記本存當時的 zoom
        var pin = BoardPin(name: "圖釘 \(boardPins.count + 1)", x: q.x, y: q.y, percent: percent)
        pin.pageID = pageID
        if let last = boardPins.last {
            pin.color = last.color
            pin.symbol = last.symbol
        }
        PinEditor.show(pin: pin, isNew: true) { [weak self] result in
            guard let self = self else { return }
            var pins = self.boardPins
            pins.append(result)
            self.setBoardMarks(frames: self.boardFrames, pins: pins)
        }
    }

    /// 編輯圖釘：名稱、顏色、符號
    func editPin(_ id: UUID) {
        guard !readOnly, let pin = boardPins.first(where: { $0.id == id }) else { return }
        hidePinBar()
        PinEditor.show(pin: pin, isNew: false) { [weak self] result in
            guard let self = self else { return }
            var pins = self.boardPins
            if let i = pins.firstIndex(where: { $0.id == id }) { pins[i] = result }
            self.setBoardMarks(frames: self.boardFrames, pins: pins)
        }
    }

    // 點圖釘：上面出現黑色的小工具列（v12.8，照 GUGA）

    private(set) var selectedPinID: UUID?
    private let pinBar = BoardMarkView()
    private let pinGroupButton = UIButton(type: .system)

    func pinTapped(_ id: UUID) {
        if readOnly {
            jumpToPin(id)
            return
        }
        if selectedPinID == id {
            hidePinBar()
            return
        }
        deselectFrame()
        endTextSelection()
        dismissShapeEditor()
        selectedPinID = id
        if pinBar.subviews.isEmpty { buildPinBar() }
        pinGroupButton.menu = pinGroupMenu(id)
        pinBar.isHidden = false
        bringSubviewToFront(pinBar)
        positionPinBar()
    }

    func hidePinBar() {
        selectedPinID = nil
        pinBar.isHidden = true
    }

    private func buildPinBar() {
        pinBar.backgroundColor = UIColor(white: 0.04, alpha: 0.96)
        pinBar.layer.cornerRadius = 12
        pinBar.isHidden = true
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let specs: [(String, Selector?)] = [("square.and.pencil", #selector(pinBarEdit)), ("folder", nil),
                                            ("eye.slash", #selector(pinBarHide)), ("trash", #selector(pinBarDelete))]
        for (i, spec) in specs.enumerated() {
            let b = spec.1 == nil ? pinGroupButton : UIButton(type: .system)
            b.setImage(UIImage(systemName: spec.0, withConfiguration: config), for: .normal)
            b.tintColor = UIColor.white
            b.frame = CGRect(x: 6 + CGFloat(i) * 50, y: 2, width: 50, height: 44)
            if let action = spec.1 {
                b.addTarget(self, action: action, for: .touchUpInside)
            } else {
                b.showsMenuAsPrimaryAction = true
            }
            pinBar.addSubview(b)
            if i > 0 {
                let line = UIView(frame: CGRect(x: 6 + CGFloat(i) * 50, y: 13, width: 1, height: 22))
                line.backgroundColor = UIColor(white: 1, alpha: 0.25)
                line.isUserInteractionEnabled = false
                pinBar.addSubview(line)
            }
        }
        pinBar.frame = CGRect(x: 0, y: 0, width: CGFloat(specs.count) * 50 + 12, height: 48)
        addSubview(pinBar)
    }

    private func pinGroupMenu(_ id: UUID) -> UIMenu {
        let current = boardPins.first(where: { $0.id == id })?.group
        var items: [UIMenuElement] = []
        items.append(UIAction(title: "不分組", state: current == nil ? .on : .off) { [weak self] _ in
            self?.movePin(id, toGroup: nil)
        })
        for group in model.notebook.pinGroups ?? [] {
            items.append(UIAction(title: group, state: current == group ? .on : .off) { [weak self] _ in
                self?.movePin(id, toGroup: group)
            })
        }
        items.append(UIAction(title: "新增分組…", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
            TextPrompt.show(title: "新增圖釘分組", initial: "") { text in
                guard let self = self else { return }
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                self.addPinGroup(name)
                self.movePin(id, toGroup: name)
            }
        })
        return UIMenu(title: "移到分組", children: items)
    }

    @objc private func pinBarEdit() {
        if let id = selectedPinID { editPin(id) }
    }

    @objc private func pinBarHide() {
        guard let id = selectedPinID else { return }
        hidePinBar()
        setPinHidden(id, true)
        showMessage("eye.slash", "圖釘藏起來了；右上角的圖釘清單可以再打開")
    }

    @objc private func pinBarDelete() {
        guard let id = selectedPinID else { return }
        hidePinBar()
        deletePin(id)
    }

    /// 工具列放在圖釘上面（圖釘在畫面最上面時放下面）
    func positionPinBar() {
        guard let id = selectedPinID, !pinBar.isHidden else { return }
        guard let pv = pinPV(id), let view = pv.pinViews[id], !view.isHidden else {
            pinBar.isHidden = true
            return
        }
        let r = pv.convert(view.frame, to: self)
        var y = r.minY - 8 - pinBar.bounds.height
        if y < topReserved + 8 { y = r.maxY + 8 }
        let x = min(max(r.midX - pinBar.bounds.width / 2, 8), max(8, bounds.width - pinBar.bounds.width - 8))
        pinBar.frame.origin = CGPoint(x: x, y: y)
    }

    /// 按住圖釘拖：移動（放手才寫進資料，可以復原）
    private var pinDragStart: (point: CGPoint, pin: BoardPin)?

    func pinDragged(_ id: UUID, gesture g: UILongPressGestureRecognizer) {
        guard !readOnly, let pv = pinPV(id) else { return }
        let s = pv.bounds.width / max(pv.page.spec.width, 1)
        guard s > 0 else { return }
        let p = g.location(in: pv)
        switch g.state {
        case .began:
            // v12.15.3（使用者）：圖釘要先點一下（出現工具列）才能拖；沒選著的按住不會動
            guard selectedPinID == id, let pin = boardPins.first(where: { $0.id == id }) else {
                g.isEnabled = false
                g.isEnabled = true
                return
            }
            hidePinBar()
            // v12.9.8：以「水滴的正中間」當作抓住的點，所以一開始拖，圖釘就吸到手指正下方。
            // 以前用開始拖那一刻手指的位置：按住的那段時間手指已經移開了，圖釘就一直跟手指隔著那段距離
            let anchor = CGPoint(x: pin.x * s, y: pin.y * s - BoardPinView.markerSize.height / 2)
            pinDragStart = (anchor, pin)
            pv.movePin(id, tip: CGPoint(x: pin.x * s + p.x - anchor.x, y: pin.y * s + p.y - anchor.y))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            setScrolling(false)
        case .changed:
            guard let start = pinDragStart else { return }
            let q = CGPoint(x: start.pin.x + (p.x - start.point.x) / s, y: start.pin.y + (p.y - start.point.y) / s)
            pv.movePin(id, tip: CGPoint(x: q.x * s, y: q.y * s))    // v12.9.7：只移動這一顆（以前每一格都重排所有區塊和圖釘）
        case .ended:
            setScrolling(true)
            guard let start = pinDragStart else { return }
            pinDragStart = nil
            var pins = boardPins
            if let i = pins.firstIndex(where: { $0.id == id }) {
                pins[i].x = min(max(start.pin.x + (p.x - start.point.x) / s, 0), pv.page.spec.width)
                pins[i].y = min(max(start.pin.y + (p.y - start.point.y) / s, 0), pv.page.spec.height)
            }
            setBoardMarks(frames: boardFrames, pins: pins)
            pv.layoutBoardMarks()
        default:
            setScrolling(true)
            pinDragStart = nil
            pv.layoutBoardMarks()
        }
    }

    /// 跳到圖釘：回到放的時候的縮放，圖釘在畫面中間
    func jumpToPin(_ id: UUID) {
        guard let pin = boardPins.first(where: { $0.id == id }) else { return }
        if isBoard {
            boardShow(center: CGPoint(x: pin.x, y: pin.y), zoom: pin.percent * boardZoom100)
        } else if let pid = pin.pageID {
            pageShow(pageID: pid, center: CGPoint(x: pin.x, y: pin.y), zoom: pin.percent)
        }
    }

    /// 筆記本（v12.9）：跳到某一頁的某一點（頁面座標）放在畫面中間，縮放換成 z
    func pageShow(pageID: UUID, center q: CGPoint, zoom z: CGFloat) {
        guard let loc = model.location(of: pageID), model.notebook.rows.indices.contains(loc.row) else {
            showMessage("exclamationmark.triangle", "找不到這個圖釘的頁面（可能刪掉了）")
            return
        }
        endTextSelection()
        dismissShapeEditor()
        zoom = clampZoom(z)
        layoutDocument()
        let row = model.notebook.rows[loc.row]
        if let rv = rowViews[row.id], rv.pageFrames.indices.contains(loc.page), rv.ranges.indices.contains(loc.page) {
            let s = scale
            let pf = rv.pageFrames[loc.page]
            let r = rv.ranges[loc.page]
            rv.currentIndex = loc.page
            rv.contentOffset.x = min(max(pf.minX + q.x * s - rv.bounds.width / 2, r.lo), r.hi)
            outer.contentOffset.y = clampOuterY(rv.frame.minY + pf.minY + q.y * s - outer.bounds.height / 2)
            rowPageChanged(rv)
        }
        finishZoom()
        updateLoadedPages()
        syncBoardMarks()
        updateFocus(force: true)
        publishFocus()
    }

    func renamePin(_ id: UUID) {
        guard let pin = boardPins.first(where: { $0.id == id }) else { return }
        TextPrompt.show(title: "圖釘的名稱", initial: pin.name) { [weak self] text in
            guard let self = self else { return }
            var pins = self.boardPins
            if let i = pins.firstIndex(where: { $0.id == id }) { pins[i].name = text }
            self.setBoardMarks(frames: self.boardFrames, pins: pins)
        }
    }

    func setPinHidden(_ id: UUID, _ hidden: Bool) {
        var pins = boardPins
        guard let i = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[i].hidden = hidden ? true : nil
        setBoardMarks(frames: boardFrames, pins: pins)
    }

    func deletePin(_ id: UUID) {
        setBoardMarks(frames: boardFrames, pins: boardPins.filter { $0.id != id })
    }

    func movePin(_ id: UUID, toGroup group: String?) {
        var pins = boardPins
        guard let i = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[i].group = group
        setBoardMarks(frames: boardFrames, pins: pins)
    }

    func addPinGroup(_ name: String) {
        var groups = model.notebook.pinGroups ?? []
        guard !groups.contains(name) else { return }
        groups.append(name)
        model.notebook.pinGroups = groups
        model.save()
    }

    /// 白板：畫面中間移到 q（頁面座標），縮放換成 z
    func boardShow(center q: CGPoint, zoom z: CGFloat) {
        guard isBoard else { return }
        endTextSelection()
        dismissShapeEditor()
        zoom = clampZoom(z)
        layoutDocument()
        boardJump(to: q)
        finishZoom()
    }

    // 區塊

    private(set) var frameMode = false
    private let framePan = UIPanGestureRecognizer()
    private let framePreview = CAShapeLayer()
    private var frameStart = CGPoint.zero
    private(set) var selectedFrameID: UUID?
    private let frameBar = BoardMarkView()                     // 選取區塊時的工具列

    /// 右上角 ＋ →「新區塊」：接下來用 Pencil 拉一個方框
    /// 筆盒選著「區塊」工具（v12.10）：可以連續拉方框，不問名稱；換別的工具才停
    private var frameToolOn: Bool { PenBoxModel.shared.selection == .frame }

    /// 筆盒換到別的工具：離開拉方框的狀態
    func leaveFrameTool() {
        guard frameMode else { return }
        frameMode = false
        framePan.isEnabled = false
        framePreview.path = nil
        applyCanvasDrawingAllowed()
    }

    func startFrameMode() {
        guard isBoard, !readOnly, !frameMode else { return }
        deselectFrame()
        endTextSelection()
        dismissShapeEditor()
        frameMode = true
        framePan.isEnabled = true
        applyCanvasDrawingAllowed()
        showMessage("rectangle.dashed", "用 Pencil 拉一個方框，建立區塊（手指點一下取消）")
    }

    private func endFrameMode() {
        framePreview.path = nil
        if frameToolOn, isBoard, !readOnly { return }          // 區塊工具選著：留在拉方框的狀態
        frameMode = false
        framePan.isEnabled = false
        applyCanvasDrawingAllowed()
    }

    // 區塊的新操作（v12.8.2）：
    // ・選取中的區塊：手指在區塊裡任何地方按住一下再拖，就能搬（以前只能抓左上角的標題，縮小時很難按到）
    // ・縮到 30% 以下：手指點區塊裡面就選取它（縮那麼小時本來就不會在裡面寫字）
    // ・套索選一堆東西 → 選取框的工具列「建立區塊」：用選到的範圍建立區塊

    private let frameBodyPress = GatedLongPress()
    private var bodyDragID: UUID?

    private func setUpFrameBodyPress() {
        frameBodyPress.addTarget(self, action: #selector(handleFrameBodyPress(_:)))
        frameBodyPress.minimumPressDuration = 0.25
        frameBodyPress.allowableMovement = 12
        frameBodyPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        frameBodyPress.gate = { [weak self] p in self?.frameBodyCanStart(at: p) ?? false }
        addGestureRecognizer(frameBodyPress)
    }

    /// 只有：白板、有選取中的區塊、按在那個區塊裡面、不是按在圖釘或標題這些記號上、沒有其他選取框
    private func frameBodyCanStart(at p: CGPoint) -> Bool {
        guard isBoard, !readOnly, !frameMode, shapeEditor == nil, let id = selectedFrameID,
              let f = boardFrames.first(where: { $0.id == id }), !f.isLocked, let q = boardPoint(p), f.rect.contains(q) else { return false }
        if let v = hitTest(p, with: nil), sequence(first: v, next: { $0.superview }).contains(where: { $0 is BoardMarkView }) {
            return false
        }
        return true
    }

    @objc private func handleFrameBodyPress(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { bodyDragID = selectedFrameID }
        guard let id = bodyDragID else { return }
        frameTitleDragged(id, gesture: g)
        if g.state == .ended || g.state == .cancelled || g.state == .failed { bodyDragID = nil }
    }

    /// 這一點（畫面座標）在哪個區塊裡（好幾個疊在一起時選最小的那個）
    private func frameAt(_ p: CGPoint) -> UUID? {
        guard let q = boardPoint(p) else { return nil }
        return boardFrames.filter { $0.rect.contains(q) }
            .min(by: { $0.width * $0.height < $1.width * $1.height })?.id
    }

    /// 用一塊範圍（頁面座標）建立區塊：四周留一點空白，問名稱，建好後選取它
    func createFrame(around content: CGRect) {
        guard isBoard, !readOnly, let pv = boardPV, !content.isNull else { return }
        let full = CGRect(x: 0, y: 0, width: pv.page.spec.width, height: pv.page.spec.height)
        let rect = content.insetBy(dx: -40, dy: -40).intersection(full)
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return }
        let n = boardFrames.count + 1
        TextPrompt.show(title: "區塊的名稱", initial: "區塊 \(n)") { [weak self] text in
            guard let self = self else { return }
            var frames = self.boardFrames
            let frame = BoardFrame(name: text, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
                                   color: (n - 1) % BoardFrame.palette.count)
            frames.append(frame)
            self.setBoardMarks(frames: frames, pins: self.boardPins)
            self.selectFrame(frame.id)
        }
    }

    @objc private func handleFramePan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            let t = g.translation(in: self)
            frameStart = CGPoint(x: p.x - t.x, y: p.y - t.y)
            framePreview.path = nil
        case .changed:
            framePreview.path = UIBezierPath(rect: Self.rect(frameStart, p)).cgPath
        case .ended:
            framePreview.path = nil
            let r = Self.rect(frameStart, p)
            endFrameMode()
            guard let a = boardPoint(CGPoint(x: r.minX, y: r.minY)), let b = boardPoint(CGPoint(x: r.maxX, y: r.maxY)),
                  b.x - a.x > 40, b.y - a.y > 30 else {
                showMessage("rectangle.dashed", "方框太小，沒有建立區塊")
                return
            }
            let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            let n = boardFrames.count + 1
            if frameToolOn {                                   // 筆盒的區塊工具：不問名稱，直接建立（點標題可以改名）
                var frames = boardFrames
                frames.append(BoardFrame(name: "區塊 \(n)", x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
                                         color: (n - 1) % BoardFrame.palette.count))
                setBoardMarks(frames: frames, pins: boardPins)
                return
            }
            TextPrompt.show(title: "區塊的名稱", initial: "區塊 \(n)") { [weak self] text in
                guard let self = self else { return }
                var frames = self.boardFrames
                let frame = BoardFrame(name: text, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
                                       color: (n - 1) % BoardFrame.palette.count)
                frames.append(frame)
                self.setBoardMarks(frames: frames, pins: self.boardPins)
                self.selectFrame(frame.id)
            }
        default:
            framePreview.path = nil
            endFrameMode()
        }
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 點區塊的標題：選取（出現工具列和右下角的把手）
    func selectFrame(_ id: UUID) {
        if readOnly { return }
        hidePinBar()
        endTextSelection()
        dismissShapeEditor()
        selectedFrameID = id
        boardPV?.setSelectedFrame(id)
        frameBar.isHidden = false
        bringSubviewToFront(frameBar)
        refreshFrameBar()
        positionFrameBar()
    }

    func deselectFrame() {
        selectedFrameID = nil
        boardPV?.setSelectedFrame(nil)
        frameBar.isHidden = true
    }

    private func setUpFrameBar() {
        // v12.8.3：黑底小圓角（跟圖釘的一樣）；改名、顏色、放進畫面、收合／展開、鎖定、⋯（貼合內容、匯出、從這裡依序看）、刪除
        frameBar.backgroundColor = UIColor(white: 0.04, alpha: 0.96)
        frameBar.layer.cornerRadius = 12
        frameBar.isHidden = true
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        func make(_ symbol: String, tint: UIColor = UIColor.white) -> UIButton {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
            b.tintColor = tint
            frameBar.addSubview(b)
            return b
        }
        let rename = make("pencil")
        rename.addAction(UIAction { [weak self] _ in self?.renameSelectedFrame() }, for: .touchUpInside)
        let color = make("paintpalette")
        color.showsMenuAsPrimaryAction = true
        var colorActions: [UIMenuElement] = []
        for i in 0..<BoardFrame.palette.count {
            let swatch = UIImage(systemName: "circle.fill")?.withTintColor(BoardFrame.uiColor(i), renderingMode: .alwaysOriginal)
            colorActions.append(UIAction(title: BoardFrame.palette[i].name, image: swatch) { [weak self] _ in
                self?.recolorSelectedFrame(i)
            })
        }
        color.menu = UIMenu(title: "顏色", children: colorActions)
        let fit = make("arrow.up.left.and.arrow.down.right")
        fit.addAction(UIAction { [weak self] _ in
            if let id = self?.selectedFrameID { self?.jumpToFrame(id) }
        }, for: .touchUpInside)
        frameCollapseButton = make("rectangle.compress.vertical")
        frameCollapseButton.addAction(UIAction { [weak self] _ in self?.toggleCollapseSelectedFrame() }, for: .touchUpInside)
        frameLockButton = make("lock.open")
        frameLockButton.addAction(UIAction { [weak self] _ in self?.toggleLockSelectedFrame() }, for: .touchUpInside)
        let more = make("ellipsis.circle")
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [
            UIAction(title: "大小貼合裡面的東西", image: UIImage(systemName: "arrow.down.forward.and.arrow.up.backward")) { [weak self] _ in
                self?.fitSelectedFrameToContent()
            },
            UIAction(title: "匯出這個區塊（PDF）", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.exportSelectedFrame()
            },
            UIAction(title: "從這裡開始依序看", image: UIImage(systemName: "play.rectangle")) { [weak self] _ in
                guard let self = self, let id = self.selectedFrameID,
                      let i = self.boardFrames.firstIndex(where: { $0.id == id }) else { return }
                self.startFrameTour(at: i)
            }
        ])
        frameDeleteButton = make("trash", tint: UIColor.systemRed)
        frameDeleteButton.showsMenuAsPrimaryAction = true
        frameDeleteButton.menu = UIMenu(title: "刪除區塊", children: [
            UIAction(title: "只刪方框（裡面的東西留著）", image: UIImage(systemName: "rectangle.dashed")) { [weak self] _ in
                self?.deleteSelectedFrame(withContent: false)
            },
            UIAction(title: "連裡面的東西一起刪", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.deleteSelectedFrame(withContent: true)
            }
        ])
        let buttons = [rename, color, fit, frameCollapseButton, frameLockButton, more, frameDeleteButton]
        for (i, b) in buttons.enumerated() {
            b.frame = CGRect(x: CGFloat(i) * 50 + 6, y: 2, width: 50, height: 44)
            if i > 0 {
                let line = UIView(frame: CGRect(x: CGFloat(i) * 50 + 6, y: 13, width: 1, height: 22))
                line.backgroundColor = UIColor(white: 1, alpha: 0.25)
                line.isUserInteractionEnabled = false
                frameBar.addSubview(line)
            }
        }
        frameBar.frame = CGRect(x: 0, y: 0, width: CGFloat(buttons.count) * 50 + 12, height: 48)
        addSubview(frameBar)
    }

    private var frameCollapseButton = UIButton(type: .system)
    private var frameLockButton = UIButton(type: .system)
    private var frameDeleteButton = UIButton(type: .system)

    /// 工具列上收合、鎖定鈕的樣子跟著選取中的區塊
    private func refreshFrameBar() {
        guard let id = selectedFrameID, let f = boardFrames.first(where: { $0.id == id }) else { return }
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        frameCollapseButton.setImage(UIImage(systemName: f.isCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                                             withConfiguration: config), for: .normal)
        frameLockButton.setImage(UIImage(systemName: f.isLocked ? "lock.fill" : "lock.open", withConfiguration: config), for: .normal)
        frameLockButton.tintColor = f.isLocked ? UIColor.systemOrange : UIColor.white
        frameDeleteButton.isEnabled = !f.isLocked
        frameDeleteButton.alpha = f.isLocked ? 0.35 : 1
    }

    /// 鎖定的區塊不能拖、改大小、刪除、收合
    private func frameIsLocked(_ id: UUID) -> Bool {
        guard let f = boardFrames.first(where: { $0.id == id }), f.isLocked else { return false }
        showMessage("lock.fill", "這個區塊鎖住了（工具列的鎖頭可以解開）")
        return true
    }

    private func toggleLockSelectedFrame() {
        guard let id = selectedFrameID else { return }
        var frames = boardFrames
        guard let i = frames.firstIndex(where: { $0.id == id }) else { return }
        frames[i].locked = frames[i].isLocked ? nil : true
        setBoardMarks(frames: frames, pins: boardPins)
        refreshFrameBar()
        showMessage(frames[i].isLocked ? "lock.fill" : "lock.open", frames[i].isLocked ? "區塊鎖住了" : "區塊解鎖了")
    }

    /// 大小貼合裡面的東西（四周留 40）
    private func fitSelectedFrameToContent() {
        guard let id = selectedFrameID, !frameIsLocked(id), let f = boardFrames.first(where: { $0.id == id }),
              let pv = boardPV else { return }
        let m = members(of: f)
        var r = CGRect.null
        let strokes = pv.canvas.drawing.strokes
        for i in m.strokes where strokes.indices.contains(i) { r = r.union(strokes[i].renderBounds) }
        for box in model.images(of: pv.page.id) where m.images.contains(box.id) {
            r = r.union(SelectionEditorView.imageBounds(of: box))
        }
        let s = max(pv.bounds.width / max(pv.page.spec.width, 1), 0.0001)
        for t in model.texts(of: pv.page.id) where m.texts.contains(t.id) {
            let shown = (pv.textViews[t.id]?.bounds.height ?? 0) / s           // 文字方塊在畫面上的高度換回頁面座標
            r = r.union(CGRect(x: t.x, y: t.y, width: t.width + 10, height: max(shown, t.fontSize * 1.6)))
        }
        for other in boardFrames where other.id != id && m.frames.contains(other.id) { r = r.union(other.rect) }
        for p in boardPins where m.pins.contains(p.id) { r = r.union(CGRect(x: p.x - 10, y: p.y - 30, width: 20, height: 30)) }
        guard !r.isNull else {
            showMessage("rectangle.dashed", "區塊裡沒有東西")
            return
        }
        let fitted = r.insetBy(dx: -40, dy: -40)
        var frames = boardFrames
        if let i = frames.firstIndex(where: { $0.id == id }) {
            frames[i].x = fitted.minX
            frames[i].y = fitted.minY
            frames[i].width = max(fitted.width, 80)
            frames[i].height = max(fitted.height, 60)
        }
        setBoardMarks(frames: frames, pins: boardPins)
    }

    /// 收合：裡面的東西收進區塊（白板上看不到、也不會被畫出來）；展開：放回來（區塊搬過的話跟著平移）。都可以復原
    private func toggleCollapseSelectedFrame() {
        guard let id = selectedFrameID, let f = boardFrames.first(where: { $0.id == id }), let pv = boardPV else { return }
        if f.isLocked {
            _ = frameIsLocked(id)
            return
        }
        let pageID = pv.page.id
        if let stash = f.stash {
            // 展開
            let dx = f.x - stash.originX
            let dy = f.y - stash.originY
            let move = CGAffineTransform(translationX: dx, y: dy)
            history.beginUndoGrouping()
            if let saved = try? PKDrawing(data: stash.drawing), !saved.strokes.isEmpty {
                var d = pv.canvas.drawing
                for st in saved.strokes {
                    d.strokes.append(PKStroke(ink: st.ink, path: st.path, transform: st.transform.concatenating(move), mask: st.mask))
                }
                recordingSelection { pv.setDrawingRecorded(d) }
            }
            if !stash.images.isEmpty {
                let moved = stash.images.map { (b: ImageBox) -> ImageBox in
                    var n = b
                    n.x += dx
                    n.y += dy
                    return n
                }
                let images = model.images(of: pageID) + moved
                setImagesRecorded(images, pageID: pageID)
                pv.syncImages(images)
            }
            if !stash.texts.isEmpty {
                let moved = stash.texts.map { (t: TextBox) -> TextBox in
                    var n = t
                    n.x += dx
                    n.y += dy
                    return n
                }
                setTextsRecorded(model.texts(of: pageID) + moved, pageID: pageID)
            }
            var frames = boardFrames
            if let i = frames.firstIndex(where: { $0.id == id }) { frames[i].stash = nil }
            frames += stash.frames.map { (g: BoardFrame) -> BoardFrame in
                var n = g
                n.x += dx
                n.y += dy
                return n
            }
            let pins = boardPins + stash.pins.map { (p: BoardPin) -> BoardPin in
                var n = p
                n.x += dx
                n.y += dy
                return n
            }
            setBoardMarks(frames: frames, pins: pins)
            history.endUndoGrouping()
            showMessage("rectangle.expand.vertical", "區塊展開了")
        } else {
            // 收合
            let m = members(of: f)
            let all = pv.canvas.drawing
            var kept = all
            var taken: [PKStroke] = []
            for i in m.strokes.sorted(by: >) where kept.strokes.indices.contains(i) {
                taken.insert(kept.strokes[i], at: 0)
                kept.strokes.remove(at: i)
            }
            let images = model.images(of: pageID)
            let texts = model.texts(of: pageID)
            var stash = FrameStash(originX: f.x, originY: f.y, drawing: PKDrawing(strokes: taken).dataRepresentation())
            stash.images = images.filter { m.images.contains($0.id) }
            stash.texts = texts.filter { m.texts.contains($0.id) }
            stash.frames = boardFrames.filter { $0.id != id && m.frames.contains($0.id) }
            stash.pins = boardPins.filter { m.pins.contains($0.id) }
            history.beginUndoGrouping()
            if !taken.isEmpty { recordingSelection { pv.setDrawingRecorded(kept) } }
            if !stash.images.isEmpty {
                let rest = images.filter { !m.images.contains($0.id) }
                setImagesRecorded(rest, pageID: pageID)
                pv.syncImages(rest)
            }
            if !stash.texts.isEmpty { setTextsRecorded(texts.filter { !m.texts.contains($0.id) }, pageID: pageID) }
            var frames = boardFrames.filter { $0.id == id || !m.frames.contains($0.id) }
            if let i = frames.firstIndex(where: { $0.id == id }) { frames[i].stash = stash }
            setBoardMarks(frames: frames, pins: boardPins.filter { !m.pins.contains($0.id) })
            history.endUndoGrouping()
            let count = taken.count + stash.images.count + stash.texts.count + stash.frames.count + stash.pins.count
            showMessage("rectangle.compress.vertical", count == 0 ? "區塊收合了（裡面沒有東西）" : "區塊收合了，裡面的東西收起來了")
        }
        refreshFrameBar()
    }

    // 依序看區塊（像投影片；v12.8.3）：照區塊清單的順序，上面出現 ◀ 第幾個／名稱 ▶ ✕

    private var tourIndex: Int?
    private let tourBar = BoardMarkView()
    private let tourLabel = UILabel()

    func startFrameTour(at index: Int) {
        guard isBoard, !boardFrames.isEmpty else {
            showMessage("play.rectangle", "還沒有區塊")
            return
        }
        if tourBar.subviews.isEmpty { buildTourBar() }
        deselectFrame()
        hidePinBar()
        tourIndex = min(max(index, 0), boardFrames.count - 1)
        tourBar.isHidden = false
        bringSubviewToFront(tourBar)
        showTourFrame()
    }

    private func buildTourBar() {
        tourBar.backgroundColor = UIColor(white: 0.04, alpha: 0.92)
        tourBar.layer.cornerRadius = 24
        tourBar.isHidden = true
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let prev = UIButton(type: .system)
        prev.setImage(UIImage(systemName: "chevron.left", withConfiguration: config), for: .normal)
        prev.addAction(UIAction { [weak self] _ in self?.stepFrameTour(-1) }, for: .touchUpInside)
        let next = UIButton(type: .system)
        next.setImage(UIImage(systemName: "chevron.right", withConfiguration: config), for: .normal)
        next.addAction(UIAction { [weak self] _ in self?.stepFrameTour(1) }, for: .touchUpInside)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
        close.addAction(UIAction { [weak self] _ in self?.endFrameTour() }, for: .touchUpInside)
        for b in [prev, next, close] {
            b.tintColor = UIColor.white
            tourBar.addSubview(b)
        }
        tourLabel.textColor = UIColor.white
        tourLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        tourLabel.textAlignment = .center
        tourBar.addSubview(tourLabel)
        prev.frame = CGRect(x: 6, y: 0, width: 48, height: 48)
        tourLabel.frame = CGRect(x: 54, y: 0, width: 220, height: 48)
        next.frame = CGRect(x: 274, y: 0, width: 48, height: 48)
        close.frame = CGRect(x: 328, y: 0, width: 48, height: 48)
        tourBar.frame = CGRect(x: 0, y: 0, width: 382, height: 48)
        addSubview(tourBar)
    }

    private func stepFrameTour(_ step: Int) {
        guard let i = tourIndex, !boardFrames.isEmpty else { return }
        tourIndex = (i + step + boardFrames.count) % boardFrames.count       // 最後一個的下一個回到第一個
        showTourFrame()
    }

    private func showTourFrame() {
        guard let i = tourIndex, boardFrames.indices.contains(i) else {
            endFrameTour()
            return
        }
        let f = boardFrames[i]
        tourLabel.text = "\(i + 1)／\(boardFrames.count)　\(f.name.isEmpty ? "區塊" : f.name)"
        tourBar.frame.origin = CGPoint(x: (bounds.width - tourBar.bounds.width) / 2, y: topReserved + 10)
        jumpToFrame(f.id)
    }

    func endFrameTour() {
        tourIndex = nil
        tourBar.isHidden = true
    }

    /// 區塊清單拖曳排順序（v12.8.3）：順序就是「依序看」、「匯出所有區塊」的順序
    func moveFrames(from source: IndexSet, to destination: Int) {
        var frames = boardFrames
        frames.move(fromOffsets: source, toOffset: destination)
        setBoardMarks(frames: frames, pins: boardPins)
    }

    /// 區塊照位置排（由上到下、由左到右）
    func sortFramesByPosition() {
        let frames = boardFrames.sorted { (a: BoardFrame, b: BoardFrame) -> Bool in
            if abs(a.y - b.y) > 1 { return a.y < b.y }
            return a.x < b.x
        }
        setBoardMarks(frames: frames, pins: boardPins)
    }

    /// 匯出所有區塊：照清單的順序，一個區塊一頁（v12.8.3）
    func exportAllFrames() {
        guard isBoard, !boardFrames.isEmpty, let page = model.notebook.rows.first?.pages.first else {
            showMessage("rectangle.dashed", "還沒有區塊")
            return
        }
        flushAll()
        let name = (model.meta.title + "-所有區塊").replacingOccurrences(of: "/", with: "-")
        let url = StorageReport.exportURL.appendingPathComponent(name + ".pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let frames = boardFrames
        let current = model.page(page.id) ?? page
        do {
            try renderer.writePDF(to: url) { ctx in
                for f in frames { self.exportBoardPage(current, ctx: ctx, area: f.rect) }
            }
            model.shareFile = ExportFile(url: url)
            if frames.contains(where: { $0.isCollapsed }) { showMessage("rectangle.compress.vertical", "收合中的區塊匯出時是空的，要先展開") }
        } catch {
            showMessage("exclamationmark.triangle", "匯出失敗")
        }
    }

    private func positionFrameBar() {
        guard let id = selectedFrameID, !frameBar.isHidden, let pv = boardPV,
              let title = pv.frameTitles[id] else { return }
        let t = pv.convert(title.frame, to: self)
        var y = t.minY - 10 - frameBar.bounds.height
        if y < topReserved + 8, let f = boardFrames.first(where: { $0.id == id }) {
            let s = pv.bounds.width / max(pv.page.spec.width, 1)
            let bottom = pv.convert(CGPoint(x: 0, y: f.rect.maxY * s), to: self).y
            y = min(bottom + 16, bounds.height - 60)
        }
        let x = min(max(t.minX, 8), max(8, bounds.width - frameBar.bounds.width - 8))
        frameBar.frame.origin = CGPoint(x: x, y: max(y, topReserved + 8))
    }

    private func renameSelectedFrame() {
        guard let id = selectedFrameID, let f = boardFrames.first(where: { $0.id == id }) else { return }
        TextPrompt.show(title: "區塊的名稱", initial: f.name) { [weak self] text in
            guard let self = self else { return }
            var frames = self.boardFrames
            if let i = frames.firstIndex(where: { $0.id == id }) { frames[i].name = text }
            self.setBoardMarks(frames: frames, pins: self.boardPins)
        }
    }

    private func recolorSelectedFrame(_ color: Int) {
        guard let id = selectedFrameID else { return }
        var frames = boardFrames
        guard let i = frames.firstIndex(where: { $0.id == id }) else { return }
        frames[i].color = color
        setBoardMarks(frames: frames, pins: boardPins)
    }

    /// 點區塊清單：整個區塊放進畫面
    func jumpToFrame(_ id: UUID) {
        guard let f = boardFrames.first(where: { $0.id == id }), bounds.width > 0 else { return }
        let s = min((bounds.width * 0.9) / max(f.width, 1), (bounds.height * 0.8) / max(f.height, 1))
        boardShow(center: CGPoint(x: f.rect.midX, y: f.rect.midY), zoom: s / max(baseScale, 0.0001))
    }

    /// 區塊裡有哪些東西：筆跡（中心在裡面）、圖片（中心在裡面）、文字方塊（左上角在裡面）、整個在裡面的區塊、圖釘
    private struct FrameMembers {
        var strokes: [Int] = []
        var images = Set<UUID>()
        var texts = Set<UUID>()
        var frames = Set<UUID>()
        var pins = Set<UUID>()
    }

    private func members(of f: BoardFrame) -> FrameMembers {
        var m = FrameMembers()
        guard let pv = boardPV else { return m }
        let r = f.rect
        for (i, stroke) in pv.canvas.drawing.strokes.enumerated() {
            let b = stroke.renderBounds
            if r.contains(CGPoint(x: b.midX, y: b.midY)) { m.strokes.append(i) }
        }
        for box in model.images(of: pv.page.id) {
            let b = SelectionEditorView.imageBounds(of: box)                  // 縮成小圖的用小圖的位置（v12.8.3）
            if r.contains(CGPoint(x: b.midX, y: b.midY)) { m.images.insert(box.id) }
        }
        for t in model.texts(of: pv.page.id) where r.contains(CGPoint(x: t.x, y: t.y)) { m.texts.insert(t.id) }
        for other in boardFrames where r.contains(other.rect) { m.frames.insert(other.id) }
        for p in boardPins where r.contains(CGPoint(x: p.x, y: p.y)) { m.pins.insert(p.id) }
        m.frames.insert(f.id)
        return m
    }

    private func deleteSelectedFrame(withContent: Bool) {
        guard let id = selectedFrameID, !frameIsLocked(id), let f = boardFrames.first(where: { $0.id == id }),
              let pv = boardPV else { return }
        deselectFrame()
        guard withContent else {
            setBoardMarks(frames: boardFrames.filter { $0.id != id }, pins: boardPins)
            return
        }
        let m = members(of: f)
        history.beginUndoGrouping()
        if !m.strokes.isEmpty {
            var d = pv.canvas.drawing
            for i in m.strokes.sorted(by: >) where d.strokes.indices.contains(i) { d.strokes.remove(at: i) }
            recordingSelection { pv.setDrawingRecorded(d) }
        }
        if !m.images.isEmpty { setImagesRecorded(model.images(of: pv.page.id).filter { !m.images.contains($0.id) }, pageID: pv.page.id) }
        if !m.texts.isEmpty { setTextsRecorded(model.texts(of: pv.page.id).filter { !m.texts.contains($0.id) }, pageID: pv.page.id) }
        setBoardMarks(frames: boardFrames.filter { !m.frames.contains($0.id) }, pins: boardPins.filter { !m.pins.contains($0.id) })
        history.endUndoGrouping()
    }

    private func exportSelectedFrame() {
        guard let id = selectedFrameID, let f = boardFrames.first(where: { $0.id == id }),
              let page = model.notebook.rows.first?.pages.first else { return }
        flushAll()
        let title = (model.meta.title + "-" + (f.name.isEmpty ? "區塊" : f.name)).replacingOccurrences(of: "/", with: "-")
        let url = StorageReport.exportURL.appendingPathComponent(title + ".pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        do {
            try renderer.writePDF(to: url) { ctx in
                self.exportBoardPage(model.page(page.id) ?? page, ctx: ctx, area: f.rect)
            }
            model.shareFile = ExportFile(url: url)
        } catch {
            showMessage("exclamationmark.triangle", "匯出失敗")
        }
    }

    // 拖區塊的標題：整個區塊連裡面的東西一起移動。拖曳中只移動一張截圖，放手才真的搬

    private struct FrameDrag {
        var id: UUID
        var start: CGPoint                 // 按下去的位置（頁面視圖的座標）
        var members: FrameMembers
        var original: PKDrawing
        var shot: UIView?
        var shotOrigin: CGPoint
    }
    private var frameDrag: FrameDrag?

    func frameTitleDragged(_ id: UUID, gesture g: UILongPressGestureRecognizer) {
        guard !readOnly, let pv = boardPV else { return }
        let p = g.location(in: pv)
        switch g.state {
        case .began:
            guard !frameIsLocked(id), let f = boardFrames.first(where: { $0.id == id }) else { return }
            let s = pv.bounds.width / max(pv.page.spec.width, 1)
            let m = members(of: f)
            let area = CGRect(x: f.rect.minX * s, y: f.rect.minY * s - 36, width: f.rect.width * s, height: f.rect.height * s + 36)
            let shot = pv.resizableSnapshotView(from: area, afterScreenUpdates: false, withCapInsets: UIEdgeInsets.zero)
            shot?.frame = area
            shot?.isUserInteractionEnabled = false
            shot?.alpha = 0.92
            let original = pv.canvas.drawing
            // 原本的東西先藏起來
            var hidden = original
            for i in m.strokes.sorted(by: >) where hidden.strokes.indices.contains(i) { hidden.strokes.remove(at: i) }
            if !m.strokes.isEmpty { pv.replaceSilently(hidden, updateBaseline: false) }
            for id in m.images { pv.imageViews[id]?.isHidden = true }
            for id in m.texts { pv.textViews[id]?.isHidden = true }
            pv.setHiddenMarks(m.frames.union(m.pins))
            if let shot = shot { pv.addSubview(shot) }
            frameDrag = FrameDrag(id: id, start: p, members: m, original: original, shot: shot, shotOrigin: area.origin)
            frameBar.isHidden = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            guard let d = frameDrag else { return }
            d.shot?.frame.origin = CGPoint(x: d.shotOrigin.x + p.x - d.start.x, y: d.shotOrigin.y + p.y - d.start.y)
        case .ended, .cancelled, .failed:
            guard let d = frameDrag else { return }
            frameDrag = nil
            d.shot?.removeFromSuperview()
            for id in d.members.images { pv.imageViews[id]?.isHidden = false }
            for id in d.members.texts { pv.textViews[id]?.isHidden = false }
            pv.setHiddenMarks([])
            if selectedFrameID != nil { frameBar.isHidden = false }
            let s = pv.bounds.width / max(pv.page.spec.width, 1)
            let delta = CGPoint(x: (p.x - d.start.x) / max(s, 0.0001), y: (p.y - d.start.y) / max(s, 0.0001))
            if g.state != .ended || hypot(delta.x * s, delta.y * s) < 2 {
                if !d.members.strokes.isEmpty { pv.replaceSilently(d.original, updateBaseline: false) }
                positionFrameBar()
                return
            }
            applyFrameMove(d, delta: delta, on: pv)
        default:
            break
        }
    }

    /// 真的把區塊和裡面的東西搬過去（合成一步復原）
    private func applyFrameMove(_ d: FrameDrag, delta: CGPoint, on pv: NotePageView) {
        let move = CGAffineTransform(translationX: delta.x, y: delta.y)
        history.beginUndoGrouping()
        if !d.members.strokes.isEmpty {
            var drawing = d.original
            for i in d.members.strokes where drawing.strokes.indices.contains(i) {
                let st = drawing.strokes[i]
                drawing.strokes[i] = PKStroke(ink: st.ink, path: st.path, transform: st.transform.concatenating(move), mask: st.mask)
            }
            recordingSelection { pv.setDrawingRecorded(drawing, undoTo: d.original) }
        }
        if !d.members.images.isEmpty {
            let images = model.images(of: pv.page.id).map { (box: ImageBox) -> ImageBox in
                guard d.members.images.contains(box.id) else { return box }
                var b = box
                b.x += delta.x
                b.y += delta.y
                return b
            }
            setImagesRecorded(images, pageID: pv.page.id)
        }
        if !d.members.texts.isEmpty {
            let texts = model.texts(of: pv.page.id).map { (t: TextBox) -> TextBox in
                guard d.members.texts.contains(t.id) else { return t }
                var b = t
                b.x += delta.x
                b.y += delta.y
                return b
            }
            setTextsRecorded(texts, pageID: pv.page.id)
        }
        let frames = boardFrames.map { (f: BoardFrame) -> BoardFrame in
            guard d.members.frames.contains(f.id) else { return f }
            var g = f
            g.x += delta.x
            g.y += delta.y
            return g
        }
        let pins = boardPins.map { (p: BoardPin) -> BoardPin in
            guard d.members.pins.contains(p.id) else { return p }
            var q = p
            q.x += delta.x
            q.y += delta.y
            return q
        }
        setBoardMarks(frames: frames, pins: pins)
        history.endUndoGrouping()
        positionFrameBar()
    }

    // 拖右下角的把手：調整區塊大小（裡面的東西不動）
    private var resizeStart: (rect: CGRect, point: CGPoint)?

    func frameHandleDragged(_ id: UUID, gesture g: UILongPressGestureRecognizer) {
        guard !readOnly, let pv = boardPV, let f = boardFrames.first(where: { $0.id == id }) else { return }
        let p = g.location(in: pv)
        let s = max(pv.bounds.width / max(pv.page.spec.width, 1), 0.0001)
        switch g.state {
        case .began:
            if frameIsLocked(id) { return }
            resizeStart = (f.rect, p)
            frameBar.isHidden = true
        case .changed:
            guard let start = resizeStart else { return }
            let w = max(80, start.rect.width + (p.x - start.point.x) / s)
            let h = max(60, start.rect.height + (p.y - start.point.y) / s)
            pv.layoutBoardMarks(overrides: [id: CGRect(x: start.rect.minX, y: start.rect.minY, width: w, height: h)])
        case .ended, .cancelled, .failed:
            guard let start = resizeStart else { return }
            resizeStart = nil
            frameBar.isHidden = selectedFrameID == nil
            let w = max(80, start.rect.width + (p.x - start.point.x) / s)
            let h = max(60, start.rect.height + (p.y - start.point.y) / s)
            var frames = boardFrames
            if g.state == .ended, let i = frames.firstIndex(where: { $0.id == id }) {
                frames[i].width = w
                frames[i].height = h
                setBoardMarks(frames: frames, pins: boardPins)
            } else {
                pv.layoutBoardMarks()
            }
            positionFrameBar()
        default:
            break
        }
    }

    /// 加大白板（v12.5）：往右、往下各加一倍，已經寫的東西不動。沒有復原（要的話從歷史版本恢復）
    /// 白板的格線、底色（v12.8：取代「變更範本」，大小不會動到）。深淺換了：黑白筆跡跟著對調，才看得到
    func setBoardPaper(_ paper: PaperStyle) {
        guard isBoard, !readOnly, let page = model.notebook.rows.first?.pages.first, page.paperStyle != paper else { return }
        flushAll()
        overviewCache = nil                                    // 縮放時墊的低解析度圖也要換底色
        applyTemplate(paper: paper, cover: nil, toAll: true, size: nil, swapInk: page.paperStyle.isDark != paper.isDark)
        updateBoardWindow(force: true)
    }

    /// 白板的匯出（v12.8）：目前畫面看到的範圍，或所有內容
    func exportBoard(onlyVisible: Bool) {
        guard isBoard, let page = model.notebook.rows.first?.pages.first else { return }
        flushAll()
        let area: CGRect? = onlyVisible ? boardVisibleRect() : nil
        let name = model.meta.title + (onlyVisible ? "-目前畫面" : "")
        let url = StorageReport.exportURL.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        do {
            try renderer.writePDF(to: url) { ctx in
                self.exportBoardPage(self.model.page(page.id) ?? page, ctx: ctx, area: area)
            }
            model.shareFile = ExportFile(url: url)
        } catch {
            showMessage("exclamationmark.triangle", "匯出失敗")
        }
    }

    func enlargeBoard() {
        guard isBoard, let row = model.notebook.rows.first, let page = row.pages.first else { return }
        guard page.spec.width < 400 * 595 else {
            showMessage("exclamationmark.triangle", "白板已經是最大了")
            return
        }
        flushAll()
        autoSnapshot(reason: "加大白板前")
        endTextSelection()
        dismissShapeEditor()
        endImageSelection()
        model.notebook.rows[0].pages[0].spec.width = page.spec.width * 2
        model.notebook.rows[0].pages[0].spec.height = page.spec.height * 2
        model.save()
        // 頁面的大小變了：舊的頁面視圖拿掉，重新建立
        if let pv = pageViews[page.id] {
            pv.discard()
            toolPicker.removeObserver(pv.canvas)
            pv.removeFromSuperview()
            pageViews[page.id] = nil
        }
        rebuild()
        updateBoardWindow(force: true)
        showMessage("arrow.up.left.and.arrow.down.right", "白板加大了（往右、往下各加一倍）")
    }

    private var baseScale: CGFloat {
        let widest = model.notebook.rows.flatMap { $0.pages }.map { $0.spec.width }.max() ?? 595
        return max(0.05, (bounds.width - 2 * margin) / widest)
    }

    private var scale: CGFloat { baseScale * zoom }

    private func layoutDocument() {
        guard bounds.width > 0 else { return }
        let s = scale
        let viewWidth = bounds.width
        var y = topInset
        for row in model.notebook.rows {
            guard let rv = rowViews[row.id] else { continue }
            let h = (row.pages.map { $0.spec.height }.max() ?? 842) * s
            rv.frame = CGRect(x: 0, y: y, width: viewWidth, height: h)
            rv.mainIndex = row.mainIndex
            rv.layoutPages(scale: s, margin: margin)
            y += h + rowGap
        }
        let contentHeight = y - rowGap + topInset
        container.frame = CGRect(x: 0, y: 0, width: viewWidth, height: contentHeight)
        outer.contentSize = CGSize(width: viewWidth, height: contentHeight)
        topPull.center = CGPoint(x: viewWidth / 2, y: -55)
        bottomPull.center = CGPoint(x: viewWidth / 2, y: contentHeight + 60)
    }

    /// 依照資料重新整理所有列；頁面視圖只建立畫面附近的（見 updateLoadedPages）
    func rebuild() {
        var liveRows = Set<UUID>()
        var livePages = Set<UUID>()
        for row in model.notebook.rows {
            liveRows.insert(row.id)
            let rv: PageRowView
            if let existing = rowViews[row.id] {
                rv = existing
            } else {
                rv = PageRowView(rowID: row.id, host: self)
                rv.currentIndex = row.mainIndex
                rv.showsHorizontalScrollIndicator = false             // 白板的位置條自己畫（v12.6）
                if isBoard {
                    rv.decelerationRate = .normal
                    rv.panGestureRecognizer.maximumNumberOfTouches = 1     // 白板：兩根手指留給縮放（v12.8.5）
                }
                rv.panGestureRecognizer.minimumNumberOfTouches = cropMode ? 2 : 1     // 截圖中：兩指捲動
                rowViews[row.id] = rv
                container.addSubview(rv)
            }
            rv.pages = row.pages
            for page in row.pages { livePages.insert(page.id) }
            if !row.pages.indices.contains(rv.currentIndex) { rv.currentIndex = row.mainIndex }
        }
        for (id, rv) in rowViews where !liveRows.contains(id) {
            rv.removeFromSuperview()
            rowViews[id] = nil
        }
        for (id, pv) in pageViews where !livePages.contains(id) {
            if shapeEditor?.pageView === pv { dismissShapeEditor() }
            pv.discard()
            toolPicker.removeObserver(pv.canvas)
            pv.removeFromSuperview()
            pageViews[id] = nil
        }
        container.bringSubviewToFront(topPull)
        container.bringSubviewToFront(bottomPull)
        outer.showsVerticalScrollIndicator = false                     // 白板的位置條自己畫（v12.6，系統的會跑錯位置）
        // 白板：點最上面（狀態列、左上的名稱附近）不要捲到最上面（v12.15.4，使用者：點名稱會跳到白板別的地方）
        outer.scrollsToTop = !isBoard
        if isBoard { setUpBoardHUD() } else { setUpPageZoomHUD() }
        layoutDocument()
        updateLoadedPages()
        updateBoardWindow(force: true)
    }

    func loadedPageView(_ id: UUID) -> NotePageView? { pageViews[id] }

    private func makePageView(_ page: NotePage, in rv: PageRowView) -> NotePageView {
        let pv = NotePageView(page: page)
        pv.host = self
        pv.refreshTapeStates()
        pageViews[page.id] = pv
        rv.addSubview(pv)
        pv.canvas.tool = scaledTool(lastTool, for: page)
        pv.canvas.drawingGestureRecognizer.isEnabled = canvasDrawingAllowed && !readOnly
        if isBoard {                                           // 白板：區塊、圖釘（v12.7）
            pv.syncBoardMarks(frames: model.notebook.frames ?? [], pins: model.notebook.pins ?? [])
        } else if boardPins.contains(where: { $0.pageID == page.id }) {   // 筆記本的圖釘（v12.9）
            pv.syncBoardMarks(frames: [], pins: boardPins.filter { $0.pageID == page.id })
        }
        return pv
    }

    /// 復原、重做：PencilKit 有時會殘留已經復原掉的筆跡畫面，所以直接換一張新的畫布
    private func reloadPageView(_ old: NotePageView, showing drawing: PKDrawing, in rv: PageRowView) {
        let tool = old.canvas.tool
        old.replaceSilently(drawing, updateBaseline: true)    // 新畫布準備好之前，舊的先顯示正確內容
        old.discard()
        old.isUserInteractionEnabled = false
        toolPicker.removeObserver(old.canvas)
        pageViews[old.page.id] = nil
        let pv = makePageView(model.page(old.page.id) ?? old.page, in: rv)   // 從存檔讀出剛剛存進去的內容
        pv.frame = old.frame
        pv.apply(scale: scale)
        pv.refreshBackground()
        pv.canvas.tool = tool
        rv.bringSubviewToFront(old)                            // 舊的先蓋著，避免閃一下
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            old.removeFromSuperview()
        }
        updateBoardWindow(force: true)                         // 白板：新的畫布也放到畫面附近
    }

    /// 離畫面太遠的頁面：先存檔，再釋放記憶體
    private func unloadPageView(_ id: UUID) {
        guard let pv = pageViews[id] else { return }
        if activeText?.pageID == id { endTextSelection() }      // 正在輸入的那一頁要釋放：先結束文字方塊
        if shapeEditor?.pageView === pv { dismissShapeEditor() }
        pv.flush()
        toolPicker.removeObserver(pv.canvas)
        pv.removeFromSuperview()
        pageViews[id] = nil
    }

    /// 只保留畫面上下各一個畫面範圍內的頁面；一本幾百頁的 PDF 也不會一次全部載入
    private func updateLoadedPages() {
        guard bounds.width > 0, !isPinching else { return }
        let h = max(outer.bounds.height, 1)
        let band = CGRect(x: 0, y: outer.contentOffset.y - h, width: bounds.width, height: h * 3)
        let s = scale
        for row in model.notebook.rows {
            guard let rv = rowViews[row.id] else { continue }
            if rv.frame.intersects(band) {
                for (i, page) in row.pages.enumerated() where pageViews[page.id] == nil {
                    let pv = makePageView(page, in: rv)
                    if rv.pageFrames.indices.contains(i) { pv.frame = rv.pageFrames[i] }
                    pv.apply(scale: s)
                    pv.refreshBackground()
                    if isBoard { DispatchQueue.main.async { [weak self] in self?.updateBoardWindow(force: true) } }
                }
            } else {
                for page in row.pages where pageViews[page.id] != nil {
                    if shapeEditor?.pageView?.page.id == page.id { continue }   // 正在拖的選取框所在的頁先留著
                    unloadPageView(page.id)
                }
            }
        }
    }

    private func clampOuterY(_ y: CGFloat) -> CGFloat {
        let maxY = max(0, outer.contentSize.height + outer.contentInset.bottom - outer.bounds.height)
        return min(max(y, 0), maxY)
    }

    // MARK: 目前所在的頁

    private func updateFocus(force: Bool = false) {
        let rows = model.notebook.rows
        guard !rows.isEmpty else { return }
        let centerY = outer.contentOffset.y + outer.bounds.height / 2
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, row) in rows.enumerated() {
            guard let f = rowViews[row.id]?.frame else { continue }
            let d = centerY < f.minY ? f.minY - centerY : max(0, centerY - f.maxY)
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        if best != focusRow {
            focusRow = best                    // 旁頁不再自動收回主頁（要回主頁用右上角「⋯ → 回到主頁」）
        } else if force {
            focusRow = best
        }
        publishFocus()
    }

    /// 離開某一列時，把它收回主頁
    private func returnOtherRowsToMain() {
        for (i, row) in model.notebook.rows.enumerated() where i != focusRow {
            guard let rv = rowViews[row.id], !rv.ranges.isEmpty, rv.currentIndex != rv.mainIndex else { continue }
            rv.currentIndex = rv.mainIndex
            rv.setContentOffset(CGPoint(x: rv.offsetFor(rv.mainIndex, inPage: sharedInPageX), y: 0), animated: true)
        }
    }

    private func publishFocus() {
        let rows = model.notebook.rows
        guard rows.indices.contains(focusRow), let rv = rowViews[rows[focusRow].id] else { return }
        if model.focusRow != focusRow { model.focusRow = focusRow }
        if model.focusPage != rv.currentIndex { model.focusPage = rv.currentIndex }
        // 記住目前這一頁（離開筆記本或 App 進背景時存檔）
        let pages = rows[focusRow].pages
        if positionRestored, pages.indices.contains(rv.currentIndex), model.notebook.lastPage != pages[rv.currentIndex].id {
            model.notebook.lastPage = pages[rv.currentIndex].id
        }
    }

    /// 放大時在主頁上左右移動，其他列的主頁跟著對齊
    func rowDidScroll(_ rv: PageRowView) {
        updateBoardWindow()                                    // 白板：畫布跟著畫面（左右捲動）
        if !isBoard, selectedPinID != nil { positionPinBar() }  // 筆記本的圖釘工具列跟著走
        if cropMode, rv.isDragging, cropRectView != nil { clearCropRect() }
        endTextIfScrolledAway()
        positionTextBar()
        guard rv.currentIndex == rv.mainIndex, rv.ranges.indices.contains(rv.mainIndex) else { return }
        let r = rv.ranges[rv.mainIndex]
        let x = rv.contentOffset.x
        guard r.hi > r.lo, x >= r.lo, x <= r.hi else { return }
        sharedInPageX = x - r.lo
        for other in rowViews.values where other !== rv && other.currentIndex == other.mainIndex && !other.ranges.isEmpty {
            other.contentOffset.x = other.offsetFor(other.mainIndex, inPage: sharedInPageX)
        }
    }

    func rowPageChanged(_ rv: PageRowView) { publishFocus() }

    // MARK: 上下捲動，以及往上、往下拉新增

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === outer else { return }
        let maxY = clampOuterY(.greatestFiniteMagnitude)
        startedAtTop = outer.contentOffset.y <= 6
        startedAtBottom = outer.contentOffset.y >= maxY - 6
        if !allowsPagePull {                                   // 白板：往上、往下拉不新增頁面
            startedAtTop = false
            startedAtBottom = false
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === outer else { return }
        if cropMode, outer.isDragging, cropRectView != nil { clearCropRect() }   // 截圖中捲動：框跟不上，拿掉
        endTextIfScrolledAway()
        positionTextBar()
        let maxY = clampOuterY(.greatestFiniteMagnitude)
        // 只有「先停在最上面／最下面，再往外拉」才顯示圓圈；一路滑過來的不算
        topPull.progress = (outer.isTracking && startedAtTop) ? -outer.contentOffset.y / pullThreshold : 0
        bottomPull.progress = (outer.isTracking && startedAtBottom)
            ? (outer.contentOffset.y - maxY) / pullThreshold : 0
        if !isPinching {
            updateFocus()
            updateLoadedPages()
        }
        updateBoardWindow()                                    // 白板：畫布跟著畫面
        if !isBoard, selectedPinID != nil { positionPinBar() }  // 筆記本的圖釘工具列跟著走
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === outer else { return }
        let maxY = clampOuterY(.greatestFiniteMagnitude)
        let slowEnough = abs(velocity.y) < pullMaxVelocity
        if startedAtTop && slowEnough && -outer.contentOffset.y >= pullThreshold { pendingTopAdd = true }
        if startedAtBottom && slowEnough && outer.contentOffset.y - maxY >= pullThreshold { pendingBottomAdd = true }
        startedAtTop = false
        startedAtBottom = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === outer else { return }
        if pendingTopAdd {
            pendingTopAdd = false
            Task { @MainActor [weak self] in self?.insertRow(at: 0) }
        }
        if pendingBottomAdd {
            pendingBottomAdd = false
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.insertRow(at: self.model.notebook.rows.count)
            }
        }
    }

    func scrollToRow(_ i: Int, animated: Bool = true) {
        let rows = model.notebook.rows
        guard rows.indices.contains(i), let rv = rowViews[rows[i].id] else { return }
        outer.setContentOffset(CGPoint(x: 0, y: clampOuterY(rv.frame.minY - topInset)), animated: animated)
        if !animated { updateFocus() }
    }

    /// 頁面後面的底色：深灰（預設，比深灰紙再深一點）或淺灰
    func applyBackdrop() {
        let light = (NotebookPrefs.object("notebookBackdrop", model.meta.id) as? String) == "light"   // 每本各自記住（v12.9）
        backgroundColor = light ? UIColor(white: 0.80, alpha: 1) : UIColor(white: 0.11, alpha: 1)
    }

    /// 變更範本：這一頁（或整本的一般頁）換紙張；這一頁是封面就換封面
    func applyTemplate(paper: PaperStyle, cover: Int?, toAll: Bool, size: CGSize?, swapInk: Bool) {
        autoSnapshot(reason: "變更範本前")
        guard let current = model.currentPageID else { return }
        endTextSelection()
        dismissShapeEditor()
        flushAll()
        // 復原用（v12.9）：原本的頁面設定，和會被改到的筆跡（換深淺時黑白對調、改小時等比例縮小）
        let before = model.notebook
        var oldDrawings: [UUID: PKDrawing] = [:]
        if swapInk || size != nil {
            for row in model.notebook.rows {
                for page in row.pages where page.pdf == nil && (toAll || page.id == current) {
                    oldDrawings[page.id] = pageViews[page.id]?.canvas.drawing ?? Store.loadDrawing(page.id)
                }
            }
        }
        defer { registerStructureUndo(before, drawings: oldDrawings, name: "變更範本") }
        var notebook = model.notebook
        var papered: [UUID] = []          // 換了紙張的頁
        var touched: [UUID] = []          // 有變動的頁
        var resized: [UUID] = []          // 換了大小的頁
        var shrink: [UUID: CGFloat] = [:] // 變小的頁：內容要縮小的倍率
        for r in notebook.rows.indices {
            for p in notebook.rows[r].pages.indices {
                let page = notebook.rows[r].pages[p]
                if page.pdf != nil { continue }                   // PDF 頁不能換
                let isCurrent = page.id == current
                guard isCurrent || toAll else { continue }
                if isCurrent, let c = cover {
                    notebook.rows[r].pages[p].cover = c
                } else if page.cover == nil {
                    notebook.rows[r].pages[p].paper = paper
                    papered.append(page.id)
                }
                if let size = size {
                    let old = page.spec
                    let k: CGFloat = min(size.width / max(old.width, 1), size.height / max(old.height, 1))
                    if k < 0.999 { shrink[page.id] = k }          // 改小：內容等比例縮小
                    notebook.rows[r].pages[p].spec = PageSpec(width: size.width, height: size.height)
                    notebook.rows[r].pages[p].spec.flat = old.flat           // 白板的大頁面還是白板
                    resized.append(page.id)
                }
                touched.append(page.id)
            }
        }
        model.notebook = notebook
        model.save()
        if swapInk {
            for id in papered { swapBlackWhite(pageID: id) }
        }
        for id in touched where !resized.contains(id) {
            if let page = model.page(id) { pageViews[id]?.updatePaper(page) }
        }
        if adaptiveInk { setTool(lastTool, adaptive: true) }      // 紙換了深淺：萬用筆跟著換顏色
        if !resized.isEmpty {
            for id in resized { unloadPageView(id) }       // 大小變了：重新建立那幾頁（先存檔）
            for (id, k) in shrink { scaleContent(pageID: id, by: k) }
            rebuild()
        }
    }

    /// 頁面改小：筆跡、文字方塊等比例縮小（以左上角為準）
    private func scaleContent(pageID: UUID, by k: CGFloat) {
        var drawing = Store.loadDrawing(pageID)
        let t = CGAffineTransform(scaleX: k, y: k)
        drawing.strokes = drawing.strokes.map { (stroke: PKStroke) -> PKStroke in
            PKStroke(ink: stroke.ink, path: stroke.path, transform: stroke.transform.concatenating(t), mask: stroke.mask)
        }
        Store.saveDrawing(drawing, pageID: pageID)
        var texts = model.texts(of: pageID)
        for i in texts.indices {
            texts[i].x *= k
            texts[i].y *= k
            texts[i].width *= k
            texts[i].fontSize *= k
            if let fixed = texts[i].fixedWidth { texts[i].fixedWidth = fixed * k }
        }
        if !texts.isEmpty { model.setTexts(texts, pageID: pageID) }
    }

    /// 黑白筆跡互換：白色（很淺）的筆跡、文字變黑，黑色（很深）的變白；其他顏色不動
    private func swapBlackWhite(pageID: UUID) {
        func swapped(_ color: UIColor) -> UIColor? {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            if r > 0.85 && g > 0.85 && b > 0.85 { return UIColor(white: 0, alpha: a) }
            if r < 0.15 && g < 0.15 && b < 0.15 { return UIColor(white: 1, alpha: a) }
            return nil
        }
        var drawing = pageViews[pageID]?.canvas.drawing ?? Store.loadDrawing(pageID)
        var changed = false
        for i in drawing.strokes.indices {
            if let c = swapped(drawing.strokes[i].ink.color) {
                drawing.strokes[i].ink = PKInk(drawing.strokes[i].ink.inkType, color: c)
                changed = true
            }
        }
        if changed {
            if let pv = pageViews[pageID] { pv.replaceSilently(drawing, updateBaseline: true) }
            Store.saveDrawing(drawing, pageID: pageID)
        }
        var texts = model.texts(of: pageID)
        var textChanged = false
        for i in texts.indices {
            if let c = swapped(texts[i].color) {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                texts[i].rgba = [Double(r), Double(g), Double(b), 1]
                textChanged = true
            }
        }
        if textChanged {
            model.setTexts(texts, pageID: pageID)
            pageViews[pageID]?.syncTexts(texts)
        }
    }

    /// 「⋯ → 回到主頁」
    func returnToMain(row r: Int) {
        let rows = model.notebook.rows
        guard rows.indices.contains(r), let rv = rowViews[rows[r].id], !rv.ranges.isEmpty else { return }
        rv.currentIndex = rv.mainIndex
        rv.setContentOffset(CGPoint(x: rv.offsetFor(rv.mainIndex, inPage: sharedInPageX), y: 0), animated: true)
        publishFocus()
    }

    /// 從面板（縮略圖、書籤、大綱）跳到某一頁
    func jump(toPage id: UUID) {
        guard let loc = model.location(of: id) else { return }
        jump(toRow: loc.row, page: loc.page)
    }

    /// 從概覽點某一張縮圖跳過去
    func jump(toRow r: Int, page p: Int) {
        let rows = model.notebook.rows
        guard rows.indices.contains(r), let rv = rowViews[rows[r].id], rv.ranges.indices.contains(p) else { return }
        scrollToRow(r, animated: false)
        rv.currentIndex = p
        rv.contentOffset.x = rv.offsetFor(p, inPage: p == rv.mainIndex ? sharedInPageX : 0)
        publishFocus()
    }

    // MARK: 縮放（雙指，可以放大也可以縮小，過程中即時重新排版）

    private func setScrolling(_ enabled: Bool) {
        outer.isScrollEnabled = enabled
        for rv in rowViews.values { rv.isScrollEnabled = enabled }
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, minZoom), maxZoom) }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            finishZoomAnimation()                              // 縮放動畫跑到一半又用手指縮放：先讓動畫到終點
            isPinching = true
            if cropMode { clearCropRect() }
            pinchStartZoom = zoom
            captureZoomAnchors(at: g.location(in: self))
            setScrolling(false)
            if isBoard {
                startBoardPinch(at: g.location(in: self))
            } else {
                startPagePinch(at: g.location(in: self))
            }
        case .changed:
            // 放手時兩根手指通常不會同時離開：先離開一根時，位置會突然跳到剩下那根手指上，
            // 放開後畫面就跟著位移（v12.8.2）。少於兩根手指就不再更新，維持最後兩指時的位置和大小
            guard g.numberOfTouches >= 2 else { return }
            let z = clampZoom(pinchStartZoom * g.scale)
            // 縮放中只把畫面整個放大縮小（GPU 做），放開才重排一次（白板 v12.8.7；筆記本 v12.9 起也一樣）
            moveBoardPinch(zoom: z, at: g.location(in: self))
        case .ended, .cancelled, .failed:
            setScrolling(true)
            endBoardPinch()
            finishZoom()
        default:
            break
        }
    }

    // MARK: 白板的縮放（v12.6 → v12.8.3）
    // v12.5：每一格都重排整張白板，不順。v12.6：只縮放一張畫面截圖，但截圖外面是空的（縮小時「白板不見」）；
    // v12.8 在截圖下面墊一張模糊的白板，接縫很明顯（格線、區塊只在截圖裡，使用者說有「斷裂感」）。
    // v12.8.3：縮放中直接把真正的畫面（outer）整個放大縮小（GPU 縮放已經畫好的東西，不重畫），
    // 縮放時暫時不裁切，所以畫面外面的圖片、文字方塊、區塊、圖釘都是真的；格線先鋪大一點；
    // 只有畫布外面的筆跡用一張低解析度的「筆跡圖」補（放在畫布底下、畫布那一塊挖空）。放手才真的換到新的大小、重排一次

    private weak var pinchGesture: UIPinchGestureRecognizer?
    private var boardPinching = false

    private var pinchStartPoint = CGPoint.zero
    private var pinchLastPoint = CGPoint.zero
    private var pinchLastZoom: CGFloat = 1
    private var overviewCache: (image: UIImage, region: CGRect, pxPerPt: CGFloat)?   // 筆跡圖（透明底）
    private var overviewDirty = true
    private var observingHistory = false

    /// 白板的內容改了（任何能復原的動作）：筆跡圖要重畫（找空檔再畫，見 refreshOverviewWhenIdle）
    @objc private func boardContentChanged() {
        overviewDirty = true
    }

    /// 縮放放手 1.5 秒後：內容改過的話，趁沒在寫字、捲動、縮放時重畫筆跡圖
    private func refreshOverviewWhenIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.isBoard, self.overviewDirty, !self.boardPinching, !self.isPinching,
                  !self.outer.isTracking, !self.outer.isDecelerating,
                  let page = self.model.notebook.rows.first?.pages.first, let pv = self.pageViews[page.id],
                  !pv.isDrawing, let old = self.overviewCache else { return }
            let image = Self.renderInk(pv.canvas.drawing, region: old.region, pxPerPt: old.pxPerPt)
            self.overviewCache = (image, old.region, old.pxPerPt)
            self.overviewDirty = false
        }
    }

    /// 縮到最小時看得到的範圍的筆跡圖（有快取：舊的蓋得住就用舊的）
    private func pinchInk(for pv: NotePageView, page: NotePage) -> (image: UIImage, region: CGRect)? {
        guard let visible = boardVisibleRect() else { return nil }
        let s = pv.bounds.width / max(page.spec.width, 1)
        guard s > 0 else { return nil }
        if !observingHistory {
            observingHistory = true
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(boardContentChanged), name: .NSUndoManagerDidCloseUndoGroup, object: history)
            center.addObserver(self, selector: #selector(boardContentChanged), name: .NSUndoManagerDidUndoChange, object: history)
            center.addObserver(self, selector: #selector(boardContentChanged), name: .NSUndoManagerDidRedoChange, object: history)
        }
        let full = CGRect(x: 0, y: 0, width: page.spec.width, height: page.spec.height)
        let k = max(zoom / max(minZoom, 0.0001), 1) * 1.35
        let need = CGRect(x: visible.midX - visible.width * k / 2, y: visible.midY - visible.height * k / 2,
                          width: visible.width * k, height: visible.height * k).intersection(full)
        guard !need.isNull, need.width > 1, need.height > 1 else { return nil }
        let pxPerPt = s * (minZoom / max(zoom, 0.0001)) * 1.5
        // 舊的圖蓋得住就直接用：剛寫的字在畫布那一塊（清楚的畫布蓋在上面），看不出圖是舊的；放手後再找空檔重畫
        if let c = overviewCache, c.region.contains(need), c.pxPerPt >= pxPerPt * 0.6, c.pxPerPt <= pxPerPt * 3 {
            return (c.image, c.region)
        }
        let more = need.insetBy(dx: -need.width * 0.25, dy: -need.height * 0.25).intersection(full)
        let region = more.isNull ? need : more
        let image = Self.renderInk(pv.canvas.drawing, region: region, pxPerPt: pxPerPt)
        overviewCache = (image, region, pxPerPt)
        overviewDirty = false
        return (image, region)
    }

    /// 圖上挖掉一塊（變透明）
    private static func punch(_ image: UIImage, hole: CGRect) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { ctx in
            image.draw(at: CGPoint.zero)
            ctx.cgContext.clear(hole)
        }
    }

    /// 一塊範圍的筆跡（透明底；圖片、文字方塊、區塊在縮放時是真的，不用畫）
    private static func renderInk(_ drawing: PKDrawing, region: CGRect, pxPerPt: CGFloat) -> UIImage {
        let size = CGSize(width: max(1, (region.width * pxPerPt).rounded()), height: max(1, (region.height * pxPerPt).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            guard !drawing.strokes.isEmpty else { return }
            var ink = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = drawing.image(from: region, scale: max(pxPerPt, 0.02))
            }
            ink.draw(in: CGRect(origin: CGPoint.zero, size: size))
        }
    }

    /// 白板一塊範圍的低解析度圖：底色、圖片、筆跡、文字（不畫格線：縮小時格線本來就會淡掉）
    private static func renderOverview(_ page: NotePage, drawing: PKDrawing, region: CGRect, pxPerPt: CGFloat) -> UIImage {
        let size = CGSize(width: max(1, (region.width * pxPerPt).rounded()), height: max(1, (region.height * pxPerPt).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            PaperRenderer.background(page.paperStyle).setFill()
            cg.fill(CGRect(origin: CGPoint.zero, size: size))
            cg.scaleBy(x: pxPerPt, y: pxPerPt)
            cg.translateBy(x: -region.minX, y: -region.minY)
            let full = CGRect(x: 0, y: 0, width: page.spec.width, height: page.spec.height)
            var near = page
            near.images = page.images?.filter { SelectionEditorView.imageBounds(of: $0).intersects(region) }
            near.texts = page.texts?.filter {
                CGRect(x: $0.x, y: $0.y - 40, width: $0.width + 40, height: 6000).intersects(region)
            }
            PageRenderer.drawImages(near, rect: full, above: false)
            if !drawing.strokes.isEmpty {
                var ink = UIImage()
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    ink = drawing.image(from: region, scale: max(pxPerPt, 0.02))
                }
                ink.draw(in: region)
            }
            PageRenderer.drawImages(near, rect: full, above: true)
            PageRenderer.drawTexts(near, rect: full)
        }
    }

    /// 筆記本的縮放（v12.9）：跟白板一樣，縮放中只放大縮小畫面，放手才重排。
    /// 以前每動一下就重排所有頁面（畫布、文字方塊、圖片、PDF），頁面多、內容多就很卡。
    /// 附近的頁（上下各一個畫面）本來就載入了，縮小時看得到；更遠的放手後才出現
    private func startPagePinch(at p: CGPoint) {
        pinchStartPoint = p
        pinchLastPoint = p
        pinchLastZoom = zoom
        boardPinching = true
        outer.clipsToBounds = false
    }

    private func startBoardPinch(at p: CGPoint) {
        pinchStartPoint = p
        pinchLastPoint = p
        pinchLastZoom = zoom
        boardPinching = true
        hideBoardIndicators()
        frameBar.isHidden = true                               // 這兩個工具列不在 outer 裡，縮放中會對不上：先藏起來
        pinBar.isHidden = true
        outer.clipsToBounds = false                            // 縮小時，原本在畫面外的東西也看得到
        guard let page = model.notebook.rows.first?.pages.first, let pv = pageViews[page.id] else { return }
        let current = model.page(page.id) ?? page
        if let ink = pinchInk(for: pv, page: current) {
            // 畫布那一塊（清楚的筆跡）在筆跡圖上清掉，免得兩份疊在一起
            let s = pv.bounds.width / max(current.spec.width, 1)
            let k = ink.image.size.width / max(ink.region.width, 1)
            let c = pv.canvas.frame
            let hole = CGRect(x: (c.minX / max(s, 0.0001) - ink.region.minX) * k, y: (c.minY / max(s, 0.0001) - ink.region.minY) * k,
                              width: c.width / max(s, 0.0001) * k, height: c.height / max(s, 0.0001) * k)
            pv.showPinchInk(Self.punch(ink.image, hole: hole), region: ink.region)
            // 格線只先鋪到畫面四周各一個畫面那麼大（v12.8.9：以前鋪到縮到最小時的整個範圍，線太多、太長，iPad 的畫面系統吃不消）
            if let v = boardVisibleRect() {
                pv.pinchGrid(area: v.insetBy(dx: -v.width, dy: -v.height).intersection(ink.region))
            }
        }
    }

    private func moveBoardPinch(zoom z: CGFloat, at p: CGPoint) {
        pinchLastZoom = z
        pinchLastPoint = p
        guard boardPinching else {
            zoomLive(to: z, at: p)
            return
        }
        // 按下去時手指下的那一點跟著手指走：outer 以自己的中心放大 f 倍，再平移
        let f = z / max(pinchStartZoom, 0.0001)
        let c = outer.center
        let tx = p.x - c.x - f * (pinchStartPoint.x - c.x)
        let ty = p.y - c.y - f * (pinchStartPoint.y - c.y)
        // v12.8.7：改用 sublayerTransform。以前直接設 outer.transform，可是 layoutSubviews 每次都會
        // outer.frame = bounds，在有 transform 時設 frame 會把縮放「吃掉」、還改到捲動範圍：縮放中畫面不動、放手亂跳、一片空白
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outer.layer.sublayerTransform = CATransform3DMakeAffineTransform(CGAffineTransform(a: f, b: 0, c: 0, d: f, tx: tx, ty: ty))
        CATransaction.commit()
        if isBoard, let page = model.notebook.rows.first?.pages.first { pageViews[page.id]?.pinchGridFade(f) }
        updateBoardHUD()
        updatePageZoomHUD()                                    // 筆記本左下角的 %
    }

    private func endBoardPinch() {
        guard boardPinching else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outer.layer.sublayerTransform = CATransform3DIdentity
        CATransaction.commit()
        outer.clipsToBounds = true
        zoomLive(to: pinchLastZoom, at: pinchLastPoint)        // 真的換到新的大小（只重排這一次）
        boardPinching = false
        if isBoard, let page = model.notebook.rows.first?.pages.first, let pv = pageViews[page.id] {
            pv.endPinchGrid()
            pv.hidePinchInk(after: 0.35)                       // 畫布換好位置、畫好之前，外圍先用筆跡圖墊著
        }
        if selectedFrameID != nil { frameBar.isHidden = false }
        if selectedPinID != nil { pinBar.isHidden = false }
        if overviewDirty { refreshOverviewWhenIdle() }
    }

    /// p 是螢幕上的位置（這個畫面的座標）
    private func captureZoomAnchors(at p: CGPoint) {
        zoomAnchors = []
        for (id, rv) in rowViews where rv.pageFrames.indices.contains(rv.currentIndex) {
            let pf = rv.pageFrames[rv.currentIndex]
            zoomAnchors.append((id, rv.currentIndex, (rv.contentOffset.x + p.x - pf.minX) / max(pf.width, 1)))
        }
        let contentY = p.y + outer.contentOffset.y
        zoomVerticalAnchor = nil
        for row in model.notebook.rows {
            guard let rf = rowViews[row.id]?.frame else { continue }
            if contentY <= rf.maxY + rowGap {
                zoomVerticalAnchor = (row.id, (contentY - rf.minY) / max(rf.height, 1))
                break
            }
        }
        if zoomVerticalAnchor == nil, let last = model.notebook.rows.last, let rf = rowViews[last.id]?.frame {
            zoomVerticalAnchor = (last.id, (contentY - rf.minY) / max(rf.height, 1))
        }
    }

    private func zoomLive(to z: CGFloat, at p: CGPoint) {
        zoom = z
        updatePageZoomHUD()
        layoutDocument()
        for (id, index, fraction) in zoomAnchors {
            guard let rv = rowViews[id], rv.pageFrames.indices.contains(index),
                  rv.ranges.indices.contains(index) else { continue }
            let pf = rv.pageFrames[index]
            let r = rv.ranges[index]
            rv.contentOffset.x = min(max(pf.minX + fraction * pf.width - p.x, r.lo), r.hi)
        }
        if let anchor = zoomVerticalAnchor, let rf = rowViews[anchor.0]?.frame {
            outer.contentOffset.y = clampOuterY(rf.minY + anchor.1 * rf.height - p.y)
        }
        updateBoardWindow()                                    // 白板：畫布換到畫面附近
    }

    private func finishZoom() {
        updatePageZoomHUD()
        isPinching = false
        updateLoadedPages()
        updateBoardWindow(force: true)
        for pv in pageViews.values { pv.refreshBackground() }
        if let rv = rowViews.values.first(where: { $0.currentIndex == $0.mainIndex && !$0.ranges.isEmpty }) {
            sharedInPageX = rv.contentOffset.x - rv.ranges[rv.mainIndex].lo
        }
        updateFocus()
    }

    func resetZoom() {
        // 白板：回到白板的 100%。v12.10：連續地縮放過去
        animateZoom(to: isBoard ? boardZoom100 : 1) { [weak self] in
            self?.refocus()
            self?.updateBoardHUD()
        }
    }

    // MARK: 新增、刪除、移動頁面

    /// 在第 position 個位置插入一張新的主頁（0 = 最前面）
    func insertRow(at position: Int) {
        if isBoard { return }                                  // 白板不加頁
        let rows = model.notebook.rows
        let at = min(max(position, 0), rows.count)
        var row = PageRow()
        let refIndex = min(max(at - 1, 0), rows.count - 1)
        if rows.indices.contains(refIndex) {
            let ref = rows[refIndex]
            row.pages[0].spec = ref.pages[ref.mainIndex].spec
            row.pages[0].paper = ref.pages[ref.mainIndex].paper      // 沿用旁邊那一頁的紙張
            if model.notebook.markdown == true {
                // Markdown 筆記本（v12.9.2）：新頁是空的 Markdown 頁（長高過的頁，新頁回到一張 A4 的比例）
                row.pages[0].spec.height = round(row.pages[0].spec.width * 842 / 595)
                let dark = row.pages[0].isDarkBackground
                let rgba = TextDefaults.rgba(model.meta.id) ?? defaultTextRGBA(pdf: !dark)
                row.pages[0].texts = [markdownPageBox(spec: row.pages[0].spec, text: "",
                                                      fontSize: TextDefaults.size(model.meta.id), rgba: rgba)]
            }
        }
        let returnRow = focusRow
        let returnPage = rows.indices.contains(focusRow) ? (rowViews[rows[focusRow].id]?.currentIndex ?? 0) : 0
        model.notebook.rows.insert(row, at: at)
        model.save()
        rebuild()
        if let rv = rowViews[row.id] {
            rv.currentIndex = 0
            rv.contentOffset.x = rv.offsetFor(0, inPage: sharedInPageX)
        }
        scrollToRow(at)
        refocus()
        // 復原：拿掉這一頁，回到原本那一頁
        let rowID = row.id
        let back = returnRow >= at ? returnRow + 1 : returnRow
        history.registerUndo(withTarget: self) { notebook in
            notebook.undoInsertRow(rowID: rowID, returnRow: back, returnPage: returnPage)
        }
    }

    // MARK: 新增頁面的復原、重做

    /// 復原「新增一頁（上下）」：拿掉那一列，跳回新增之前所在的那一頁
    func undoInsertRow(rowID: UUID, returnRow: Int, returnPage: Int) {
        endTextSelection()
        dismissShapeEditor()
        guard let r = model.notebook.rows.firstIndex(where: { $0.id == rowID }), model.notebook.rows.count > 1 else { return }
        let snapshot = model.notebook.rows[r]
        for page in snapshot.pages { unloadPageView(page.id) }          // 先存檔，重做時還在
        model.notebook.rows.remove(at: r)
        model.save()
        rebuild()
        let target = returnRow > r ? returnRow - 1 : returnRow
        let row = min(max(target, 0), model.notebook.rows.count - 1)
        jump(toRow: row, page: min(returnPage, model.notebook.rows[row].pages.count - 1))
        history.registerUndo(withTarget: self) { notebook in
            notebook.redoInsertRow(snapshot, at: r, returnRow: returnRow, returnPage: returnPage)
        }
    }

    func redoInsertRow(_ row: PageRow, at position: Int, returnRow: Int, returnPage: Int) {
        let at = min(max(position, 0), model.notebook.rows.count)
        model.notebook.rows.insert(row, at: at)
        model.save()
        rebuild()
        jump(toRow: at, page: row.mainIndex)
        history.registerUndo(withTarget: self) { notebook in
            notebook.undoInsertRow(rowID: row.id, returnRow: returnRow, returnPage: returnPage)
        }
    }

    /// 復原「新增旁頁」：拿掉那一張，跳回新增之前看的那一張
    func undoInsertSidePage(rowID: UUID, pageID: UUID, returnIndex: Int) {
        endTextSelection()
        dismissShapeEditor()
        guard let r = model.notebook.rows.firstIndex(where: { $0.id == rowID }),
              let p = model.notebook.rows[r].pages.firstIndex(where: { $0.id == pageID }),
              model.notebook.rows[r].pages.count > 1 else { return }
        let page = model.notebook.rows[r].pages[p]
        unloadPageView(pageID)                                         // 先存檔，重做時還在
        model.notebook.rows[r].pages.remove(at: p)
        if p < model.notebook.rows[r].mainIndex { model.notebook.rows[r].mainIndex -= 1 }
        model.save()
        rebuild()
        jump(toRow: r, page: min(max(returnIndex, 0), model.notebook.rows[r].pages.count - 1))
        history.registerUndo(withTarget: self) { notebook in
            notebook.redoInsertSidePage(rowID: rowID, page: page, at: p, returnIndex: returnIndex)
        }
    }

    func redoInsertSidePage(rowID: UUID, page: NotePage, at position: Int, returnIndex: Int) {
        guard let r = model.notebook.rows.firstIndex(where: { $0.id == rowID }) else { return }
        let pos = min(max(position, 0), model.notebook.rows[r].pages.count)
        model.notebook.rows[r].pages.insert(page, at: pos)
        if pos <= model.notebook.rows[r].mainIndex { model.notebook.rows[r].mainIndex += 1 }
        model.save()
        rebuild()
        jump(toRow: r, page: pos)
        history.registerUndo(withTarget: self) { notebook in
            notebook.undoInsertSidePage(rowID: rowID, pageID: page.id, returnIndex: returnIndex)
        }
    }

    func addSidePage(row r: Int, left: Bool) {
        guard model.notebook.rows.indices.contains(r) else { return }
        addSidePage(rowID: model.notebook.rows[r].id, left: left)
    }

    /// 新增旁頁到最外側（拉到邊緣、概覽、截圖用）
    func addSidePage(rowID: UUID, left: Bool) {
        guard let r = model.notebook.rows.firstIndex(where: { $0.id == rowID }) else { return }
        let ref = model.notebook.rows[r]
        let page = NotePage(spec: ref.pages[ref.mainIndex].spec, paper: ref.pages[ref.mainIndex].paper)
        insertSidePage(rowID: rowID, at: left ? 0 : ref.pages.count, page: page)
    }

    /// 長按拖曳：把某一列移到 target 的位置
    func moveRow(id: UUID, toIndex target: Int) {
        guard let from = model.notebook.rows.firstIndex(where: { $0.id == id }),
              from != target, model.notebook.rows.indices.contains(target) else { return }
        flushAll()
        registerStructureUndo(model.notebook, drawings: [:], name: "調整頁面順序")   // 可以復原（v12.9.2）
        let row = model.notebook.rows.remove(at: from)
        model.notebook.rows.insert(row, at: target)
        model.save()
        rebuild()
        updateFocus(force: true)
    }

    /// 概覽裡長按拖曳：同一列的兩張頁面交換位置。主頁的「位置」不變，
    /// 所以把旁頁拖到主頁上，那張旁頁就會變成主頁，原本的主頁移到它原來的位置。
    func swapPages(rowID: UUID, pageID: UUID, with otherID: UUID) {
        guard let r = model.notebook.rows.firstIndex(where: { $0.id == rowID }),
              let a = model.notebook.rows[r].pages.firstIndex(where: { $0.id == pageID }),
              let b = model.notebook.rows[r].pages.firstIndex(where: { $0.id == otherID }),
              a != b else { return }
        flushAll()
        registerStructureUndo(model.notebook, drawings: [:], name: "調整頁面順序")   // 可以復原（v12.9.2）
        model.notebook.rows[r].pages.swapAt(a, b)
        model.save()
        rebuild()
        if let rv = rowViews[model.notebook.rows[r].id] {
            let m = model.notebook.rows[r].mainIndex
            rv.currentIndex = m
            rv.contentOffset.x = rv.offsetFor(m, inPage: sharedInPageX)
        }
        publishFocus()
    }

    /// 旁頁和主頁交換位置：這張旁頁變成主頁，原本的主頁移到這張旁頁的位置
    func swapWithMain(row r: Int, page p: Int) {
        guard model.notebook.rows.indices.contains(r) else { return }
        let main = model.notebook.rows[r].mainIndex
        guard model.notebook.rows[r].pages.indices.contains(p), p != main else { return }
        flushAll()
        registerStructureUndo(model.notebook, drawings: [:], name: "換主頁")         // 可以復原（v12.9.2）
        model.notebook.rows[r].pages.swapAt(p, main)
        model.save()
        rebuild()
        if let rv = rowViews[model.notebook.rows[r].id] {
            rv.currentIndex = main
            rv.contentOffset.x = rv.offsetFor(main, inPage: sharedInPageX)
        }
        publishFocus()
    }

    /// 旁頁往左或往右移一格（by = -1 或 +1）；主頁仍然是主頁
    func moveSidePage(row r: Int, page p: Int, by delta: Int) {
        guard model.notebook.rows.indices.contains(r) else { return }
        let q = p + delta
        let pages = model.notebook.rows[r].pages
        guard pages.indices.contains(p), pages.indices.contains(q) else { return }
        model.notebook.rows[r].pages.swapAt(p, q)
        let main = model.notebook.rows[r].mainIndex
        if main == p {
            model.notebook.rows[r].mainIndex = q
        } else if main == q {
            model.notebook.rows[r].mainIndex = p
        }
        model.save()
        rebuild()
        if let rv = rowViews[model.notebook.rows[r].id] {
            let m = model.notebook.rows[r].mainIndex
            rv.currentIndex = m
            rv.contentOffset.x = rv.offsetFor(m, inPage: sharedInPageX)
        }
        publishFocus()
    }

    // MARK: 頁面結構的復原（v12.9）：刪頁、變更範本

    /// 登記一步復原：回到 data（頁面、範本），drawings 裡的頁面筆跡也換回去。復原時再登記一步（所以可以重做）
    private func registerStructureUndo(_ data: NotebookData, drawings: [UUID: PKDrawing], name: String) {
        history.registerUndo(withTarget: self) { view in
            view.restoreStructure(data, drawings: drawings, name: name)
        }
        history.setActionName(name)
    }

    private func restoreStructure(_ data: NotebookData, drawings: [UUID: PKDrawing], name: String) {
        endTextSelection()
        dismissShapeEditor()
        flushAll()
        let now = model.notebook
        var nowDrawings: [UUID: PKDrawing] = [:]
        for id in drawings.keys { nowDrawings[id] = pageViews[id]?.canvas.drawing ?? Store.loadDrawing(id) }
        // 頁面的大小、紙張可能都變了：已經載入的頁面視圖全部重建
        for id in Array(pageViews.keys) { unloadPageView(id) }
        for (id, d) in drawings { Store.saveDrawing(d, pageID: id) }
        model.notebook = data
        model.save()
        rebuild()
        focusRow = min(focusRow, max(model.notebook.rows.count - 1, 0))
        outer.contentOffset.y = clampOuterY(outer.contentOffset.y)
        updateFocus(force: true)
        publishFocus()
        registerStructureUndo(now, drawings: nowDrawings, name: name)
        showMessage("arrow.uturn.backward", name)
    }

    func deleteCurrentPage() {
        let rows = model.notebook.rows
        guard rows.indices.contains(focusRow), let rv = rowViews[rows[focusRow].id] else { return }
        if rv.currentIndex == rows[focusRow].mainIndex {
            deleteRow(focusRow)
        } else {
            deleteSidePage(row: focusRow, page: rv.currentIndex)
        }
    }

    func deleteSidePage(row r: Int, page p: Int) {
        guard model.notebook.rows.indices.contains(r) else { return }
        let row = model.notebook.rows[r]
        guard row.pages.indices.contains(p), p != row.mainIndex else { return }
        autoSnapshot(reason: "刪除頁面前")
        let rv = rowViews[row.id]
        let oldCurrent = rv?.currentIndex ?? row.mainIndex
        flushAll()
        trashIfWorthKeeping([PageRow(pages: [row.pages[p]], mainIndex: 0)])
        let before = model.notebook
        model.notebook.rows[r].pages.remove(at: p)
        if p < row.mainIndex { model.notebook.rows[r].mainIndex -= 1 }
        // v12.9：筆跡檔先不刪，雙指點一下可以復原（以前直接刪掉，只能從歷史版本整本恢復）
        model.save()
        undoManager?.removeAllActions()
        registerStructureUndo(before, drawings: [:], name: "刪除頁面")
        rebuild()

        if let rv = rv {
            let newMain = model.notebook.rows[r].mainIndex
            var next = oldCurrent
            if oldCurrent == p {
                next = p < row.mainIndex ? p : p - 1      // 刪的就是正在看的這張：往主頁方向移一張
            } else if oldCurrent > p {
                next = oldCurrent - 1
            }
            rv.currentIndex = min(max(next, 0), rv.pages.count - 1)
            let inPage = rv.currentIndex == newMain ? sharedInPageX : 0
            rv.setContentOffset(CGPoint(x: rv.offsetFor(rv.currentIndex, inPage: inPage), y: 0), animated: true)
        }
        publishFocus()
        refocus()
    }

    /// 刪掉的頁有寫東西（筆跡、文字、圖片）才放進最近刪除；空白頁、沒寫過的課本頁就不放（v12.9.2）
    private func trashIfWorthKeeping(_ rows: [PageRow]) {
        guard !isBoard, !readOnly else { return }
        let worth = rows.contains { row in
            row.pages.contains { page in
                !(page.texts ?? []).isEmpty || !(page.images ?? []).isEmpty || !Store.loadDrawing(page.id).strokes.isEmpty
            }
        }
        if worth { model.trashPages?(rows) }
    }

    func deleteRow(_ r: Int) {
        guard model.notebook.rows.indices.contains(r) else { return }
        autoSnapshot(reason: "刪除頁面前")
        flushAll()
        trashIfWorthKeeping([model.notebook.rows[r]])
        let before = model.notebook
        model.notebook.rows.remove(at: r)
        // v12.9：筆跡檔先不刪，雙指點一下可以復原
        if model.notebook.rows.isEmpty { model.notebook.rows.append(PageRow()) }
        model.save()
        undoManager?.removeAllActions()
        registerStructureUndo(before, drawings: [:], name: "刪除頁面")
        rebuild()
        focusRow = min(r, model.notebook.rows.count - 1)
        outer.contentOffset.y = clampOuterY(outer.contentOffset.y)
        updateFocus(force: true)
        refocus()
    }

    /// 移出頁面（v11.23；v11.24 改成「選哪幾張就搬哪幾張」）。搬到 targetID 那本筆記本的最後面。
    /// 同一列裡：主頁有搬 → 在目的地還是一列，主頁＋一起搬的旁頁；主頁沒搬 → 搬的旁頁各自變成一張主頁。
    /// 原本那列：主頁被搬走、還剩旁頁時，最靠近的旁頁變成新的主頁（右邊優先）。
    /// 搬之前自動存一份歷史版本（「移出頁面前」）。回傳搬了幾頁
    @discardableResult
    /// 複製頁面到另一本（v12.15.6，使用者要求）：跟「移出」一樣的分法（整列、主頁＋旁頁一列、單張旁頁各自一列），
    /// 放到那本的最後面；這一本不動。Store.transferRows 會給新的 ID、複製筆跡、圖片和用到的 PDF 頁
    func copyPages(_ pageIDs: [UUID], to targetID: UUID, at: Int? = nil) -> Int {
        guard targetID != model.meta.id else { return 0 }
        let selected = Set(pageIDs)
        flushAll()
        var outRows: [PageRow] = []
        var count = 0
        for original in model.notebook.rows {
            let picked = original.pages.filter { selected.contains($0.id) }
            if picked.isEmpty { continue }
            count += picked.count
            guard original.pages.indices.contains(original.mainIndex) else { continue }
            let mainID = original.pages[original.mainIndex].id
            if picked.count == original.pages.count {
                outRows.append(original)
            } else if selected.contains(mainID) {
                var out = PageRow(pages: picked, mainIndex: 0)
                out.mainIndex = picked.firstIndex(where: { $0.id == mainID }) ?? 0
                outRows.append(out)
            } else {
                for page in picked { outRows.append(PageRow(pages: [page], mainIndex: 0)) }
            }
        }
        guard !outRows.isEmpty, Store.transferRows(outRows, to: targetID, at: at) else { return 0 }
        return count
    }

    /// 同一本裡移動頁面（v12.15.10，使用者：400 多頁拖不動）：選好的頁照「移出」的分法拿出來，
    /// 插在原本第 insertAt 列前面（0＝最前面，列數＝最後面）。可以復原
    func movePagesWithin(_ pageIDs: [UUID], insertAt k: Int) -> Int {
        let selected = Set(pageIDs)
        flushAll()
        var out: [PageRow] = []
        var remaining: [(row: PageRow, origin: Int)] = []
        var count = 0
        for (i, original) in model.notebook.rows.enumerated() {
            let moving = original.pages.filter { selected.contains($0.id) }
            guard !moving.isEmpty, original.pages.indices.contains(original.mainIndex) else {
                remaining.append((original, i))
                continue
            }
            count += moving.count
            let mainID = original.pages[original.mainIndex].id
            if moving.count == original.pages.count {
                out.append(original)
                continue
            }
            if selected.contains(mainID) {
                var row = PageRow(pages: moving, mainIndex: 0)
                row.mainIndex = moving.firstIndex(where: { $0.id == mainID }) ?? 0
                out.append(row)
            } else {
                for page in moving { out.append(PageRow(pages: [page], mainIndex: 0)) }
            }
            var row = original
            row.pages = original.pages.filter { !selected.contains($0.id) }
            if let m = row.pages.firstIndex(where: { $0.id == mainID }) {
                row.mainIndex = m
            } else {
                let m = original.mainIndex
                let right = original.pages.indices.first { $0 > m && !selected.contains(original.pages[$0].id) }
                let left = original.pages.indices.last { $0 < m && !selected.contains(original.pages[$0].id) }
                let newMainID = (right ?? left).map { original.pages[$0].id }
                row.mainIndex = newMainID.flatMap { id in row.pages.firstIndex(where: { $0.id == id }) } ?? 0
            }
            remaining.append((row, i))
        }
        guard !out.isEmpty else { return 0 }
        registerStructureUndo(model.notebook, drawings: [:], name: "移動頁面")
        let at = remaining.filter { $0.origin < k }.count
        var rows = remaining.map { $0.row }
        rows.insert(contentsOf: out, at: min(at, rows.count))
        model.notebook.rows = rows
        model.save()
        rebuild()
        updateFocus(force: true)
        publishFocus()
        if let first = out.first, first.pages.indices.contains(first.mainIndex) {
            let id = first.pages[first.mainIndex].id
            DispatchQueue.main.async { [weak self] in self?.reveal(pageID: id, pageRect: CGRect.null) }
        }
        return count
    }

    func movePages(_ pageIDs: [UUID], to targetID: UUID, at: Int? = nil) -> Int {
        guard targetID != model.meta.id else { return 0 }
        let selected = Set(pageIDs)
        flushAll()
        let any = model.notebook.rows.contains { row in row.pages.contains { selected.contains($0.id) } }
        guard any else { return 0 }
        autoSnapshot(reason: "移出頁面前")

        var outRows: [PageRow] = []
        var remaining: [PageRow] = []
        var changedRows: [UUID] = []
        var movedIDs: [UUID] = []
        for original in model.notebook.rows {
            let moving = original.pages.filter { selected.contains($0.id) }
            if moving.isEmpty {
                remaining.append(original)
                continue
            }
            movedIDs.append(contentsOf: moving.map { $0.id })
            guard original.pages.indices.contains(original.mainIndex) else { continue }
            let mainID = original.pages[original.mainIndex].id
            if moving.count == original.pages.count {
                outRows.append(original)                                   // 整列都搬
                continue
            }
            if selected.contains(mainID) {
                // 主頁＋部分旁頁：在目的地維持一列
                var out = PageRow(pages: moving, mainIndex: 0)
                out.mainIndex = moving.firstIndex(where: { $0.id == mainID }) ?? 0
                outRows.append(out)
            } else {
                for page in moving { outRows.append(PageRow(pages: [page], mainIndex: 0)) }
            }
            // 原本那列留下的頁
            var row = original
            row.pages = original.pages.filter { !selected.contains($0.id) }
            if let i = row.pages.firstIndex(where: { $0.id == mainID }) {
                row.mainIndex = i
            } else {
                // 主頁搬走了：右邊最近的旁頁變成主頁，沒有右邊就用左邊最近的
                let m = original.mainIndex
                let right = original.pages.indices.filter { $0 > m && !selected.contains(original.pages[$0].id) }.first
                let left = original.pages.indices.filter { $0 < m && !selected.contains(original.pages[$0].id) }.last
                let pick = right ?? left
                let newMainID = pick.map { original.pages[$0].id }
                row.mainIndex = newMainID.flatMap { id in row.pages.firstIndex(where: { $0.id == id }) } ?? 0
            }
            changedRows.append(row.id)
            remaining.append(row)
        }
        guard Store.transferRows(outRows, to: targetID, at: at) else { return 0 }

        if remaining.isEmpty { remaining.append(PageRow()) }
        let movedSet = Set(movedIDs)
        let oldFocus = focusRow
        model.notebook.rows = remaining
        model.notebook.bookmarks?.removeAll { movedSet.contains($0) }
        model.notebook.outline?.removeAll { movedSet.contains($0.pageID) }
        if let last = model.notebook.lastPage, movedSet.contains(last) { model.notebook.lastPage = nil }
        model.save()
        undoManager?.removeAllActions()
        rebuild()
        for id in movedIDs { Store.deleteDrawing(id) }        // 歷史版本裡還留著一份
        // 少了頁的那幾列：回到（新的）主頁
        for rowID in changedRows {
            guard let rv = rowViews[rowID], let row = model.notebook.rows.first(where: { $0.id == rowID }) else { continue }
            rv.currentIndex = row.mainIndex
            rv.contentOffset.x = rv.offsetFor(row.mainIndex, inPage: sharedInPageX)
        }
        focusRow = min(oldFocus, model.notebook.rows.count - 1)
        outer.contentOffset.y = clampOuterY(outer.contentOffset.y)
        updateFocus(force: true)
        publishFocus()
        refocus()
        return movedIDs.count
    }

    @objc func flushAll() {
        for pv in pageViews.values { pv.flush() }
        if positionRestored, isBoard { saveBoardView() }       // 白板：記住現在的位置和縮放
        Store.backupSettings()                                 // 設定在資料位置留一份備份（v12.4）
        Store.finishPendingSaves()                             // 背景的筆跡存檔等它做完（v12.10.1）
        ActivityLog.saveNow()                                  // 修改紀錄（v12.9.5）
        if positionRestored, model.notebook.lastPage != savedLastPage {
            savedLastPage = model.notebook.lastPage
            model.save()                                   // 上次看到的位置
        }
    }

    /// 螢光筆放開：有停住過就拉直，然後移到最下面
    func finishMarkerStroke(on pv: NotePageView?, countBefore: Int) {
        guard let pv = pv else { return }
        let pending = pendingMarkerLine
        pendingMarkerLine = nil
        markerGuide.path = nil
        guard let line = pending, line.pageID == pv.page.id else {
            sendMarkerToBack(on: pv, countBefore: countBefore)
            return
        }
        var drawing = pv.canvas.drawing
        guard drawing.strokes.count == countBefore + 1, let last = drawing.strokes.last,
              isHighlighter(last) else { return }
        // 停住之後如果又繼續拉，以放開時整筆的頭尾為準
        var a = line.a
        var b = line.b
        let pts = last.path.map { $0.location.applying(last.transform) }
        if let shape = ShapeSnapper.markerLine(for: pts), let a2 = shape.points.first, let b2 = shape.points.last {
            a = a2
            b = b2
        }
        let fixed: PKStroke
        if let uniform = ShapeSnapper.straightenUniform(last, from: a, to: b) {
            fixed = uniform                                     // 整條一樣粗、完全直
        } else if last.ink.inkType != .marker {
            fixed = ShapeSnapper.straightenRebuilt(last, from: a, to: b)   // 無壓感螢光筆：直接重建，粗細本來就固定
        } else if canRebuildPointsFully || PointExtras.supported {
            // 每個點投影到直線上，點本身的所有數值都保留
            fixed = ShapeSnapper.straighten(last, from: a, to: b)
        } else {
            // 開發環境不夠新：不重建筆畫點，只把整筆轉正、拉到兩端對齊（粗細一定一樣，但保留些微彎曲）
            fixed = ShapeSnapper.align(last, from: a, to: b)
        }
        drawing.strokes.removeLast()
        drawing.strokes.insert(stampedHighlighter(fixed), at: 0)   // 放到所有筆跡下面，蓋上螢光筆記號
        pv.replaceSilently(drawing, updateBaseline: true)       // 復原：直接回到畫這筆之前
        if snapOn(.markerEditor) { showSelection(on: pv, indices: [0], allowLine: true) }
    }

    /// 螢光筆畫完：把它移到這一頁所有筆跡的最下面，才不會蓋住字（GoodNotes 使用者一直想要的做法）
    func sendMarkerToBack(on pv: NotePageView?, countBefore: Int) {
        guard let pv = pv, shapeEditor?.pageView !== pv else { return }
        var drawing = pv.canvas.drawing
        guard drawing.strokes.count == countBefore + 1,
              let last = drawing.strokes.last, isHighlighter(last) else { return }
        drawing.strokes.removeLast()
        drawing.strokes.insert(stampedHighlighter(last), at: 0)       // 蓋上螢光筆記號（重開也認得出來）
        // 只是換順序：不另外登記，復原時直接回到畫這筆之前
        pv.replaceSilently(drawing, updateBaseline: true)
    }

    // MARK: 截圖（左上角剪刀）

    private(set) var cropMode = false
    private let cropPan = UIPanGestureRecognizer()
    private let cropUnder = CAShapeLayer()          // 白色底線：深色頁面上也看得到
    private let cropLayer = CAShapeLayer()          // 黑色虛線
    private let cropHandles = CAShapeLayer()        // 四個角的圓點
    private var cropRectView: CGRect?               // 目前的框（筆記本畫面座標）
    private var cropResult: (pageID: UUID, rect: CGRect)?      // 框到的範圍（頁面座標）
    private let cropBar = UIView()

    private enum CropDrag {
        case new(CGPoint)                // 拉一個新的框（起點）
        case move(CGRect, CGPoint)       // 拖中間移動（原本的框、起點）
        case corner(CGPoint)             // 拖角改大小（對角固定）
    }
    private var cropDrag: CropDrag?

    private func setUpCrop() {
        cropPan.addTarget(self, action: #selector(handleCrop(_:)))
        cropPan.isEnabled = false
        cropPan.maximumNumberOfTouches = 1
        cropPan.delegate = self
        addGestureRecognizer(cropPan)
        cropUnder.fillColor = nil
        cropUnder.strokeColor = UIColor(white: 1, alpha: 0.85).cgColor
        cropUnder.lineWidth = 4
        layer.addSublayer(cropUnder)
        cropLayer.fillColor = nil
        cropLayer.strokeColor = UIColor.black.cgColor
        cropLayer.lineWidth = 2
        cropLayer.lineDashPattern = [8, 6]
        layer.addSublayer(cropLayer)
        cropHandles.fillColor = UIColor.white.cgColor
        cropHandles.strokeColor = UIColor.black.cgColor
        cropHandles.lineWidth = 2
        layer.addSublayer(cropHandles)

        cropBar.backgroundColor = UIColor(white: 0.16, alpha: 0.96)
        cropBar.layer.cornerRadius = 16
        let items: [(String, String, () -> Void)] = [
            ("arrow.left.square", "往左新建旁頁", { [weak self] in self?.cropToSidePage(left: true) }),
            ("arrow.right.square", "往右新建旁頁", { [weak self] in self?.cropToSidePage(left: false) }),
            ("doc.on.doc", "拷貝圖片", { [weak self] in self?.cropCopy() })
        ] + (model.pasteToBoard == nil ? [] : [
            // 開在白板浮動視窗裡的（v12.15.0，照 GUGA）：直接貼到外面的白板上
            ("square.and.arrow.down.on.square", "貼到白板", { [weak self] in self?.cropToBoard() })
        ])
        let w: CGFloat = 132
        for (i, item) in items.enumerated() {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: item.0)
            config.title = item.1
            config.imagePlacement = .top
            config.imagePadding = 6
            config.baseForegroundColor = .white
            config.titleLineBreakMode = .byClipping
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.systemFont(ofSize: 14, weight: .medium)
                return outgoing
            }
            let action = item.2
            let b = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
            b.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: 72)
            cropBar.addSubview(b)
        }
        cropBar.frame = CGRect(x: 0, y: 0, width: CGFloat(items.count) * w, height: 72)
    }

    /// 剪刀：開關截圖模式。開著時不能寫字；一指拉框、兩指捲動和縮放。
    /// 截完一張不會離開（可以連續截好幾題），再按一次剪刀才離開（v11.17）
    func setCropMode(_ on: Bool) {
        cropMode = on
        model.cropActive = on
        cropPan.isEnabled = on
        selectPress.isEnabled = !on                       // 剪刀開著：長按不跳一圈按鈕（v12.15.1）
        clearCropRect()
        if on {
            endTextSelection()
            dismissShapeEditor()
            hidePasteButton()
            showMessage("scissors", "拉框截圖，兩指捲動；再按剪刀離開")
        }
        outer.isScrollEnabled = true
        for rv in rowViews.values { rv.isScrollEnabled = true }
        applyScrollTouches()
        tapePan.isEnabled = tapeMode && !on
        tapeTap.isEnabled = tapeMode && !on
        applyCanvasDrawingAllowed()
    }

    /// 拿掉目前的框和選單（還在截圖模式裡）
    private func clearCropRect() {
        cropDrag = nil
        cropResult = nil
        cropRectView = nil
        drawCrop(nil)
        cropBar.removeFromSuperview()
    }

    /// 截圖中一指留給拉框，捲動要兩指；平常一指就能捲動
    private func applyScrollTouches() {
        let n = cropMode ? 2 : 1
        if outer.panGestureRecognizer.minimumNumberOfTouches != n { outer.panGestureRecognizer.minimumNumberOfTouches = n }
        for rv in rowViews.values where rv.panGestureRecognizer.minimumNumberOfTouches != n {
            rv.panGestureRecognizer.minimumNumberOfTouches = n
        }
    }

    private func drawCrop(_ rect: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let r = rect else {
            cropUnder.path = nil
            cropLayer.path = nil
            cropHandles.path = nil
            return
        }
        let frame = UIBezierPath(rect: r).cgPath
        cropUnder.path = frame
        cropLayer.path = frame
        let dots = UIBezierPath()
        for c in cropCorners(r) {
            dots.append(UIBezierPath(ovalIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)))
        }
        cropHandles.path = dots.cgPath
    }

    private func cropCorners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    @objc private func handleCrop(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            let t = g.translation(in: self)
            let start = CGPoint(x: p.x - t.x, y: p.y - t.y)
            cropBar.removeFromSuperview()
            if let r = cropRectView {
                let corners = cropCorners(r)
                if let i = corners.firstIndex(where: { hypot($0.x - start.x, $0.y - start.y) < 30 }) {
                    cropDrag = .corner(corners[(i + 2) % 4])          // 拖角：對角固定
                } else if r.insetBy(dx: -6, dy: -6).contains(start) {
                    cropDrag = .move(r, start)                        // 拖中間：移動
                } else {
                    cropDrag = .new(start)
                }
            } else {
                cropDrag = .new(start)
            }
            updateCrop(to: p)
        case .changed:
            updateCrop(to: p)
        case .ended, .cancelled:
            updateCrop(to: p)
            finishCrop()
        default:
            break
        }
    }

    private func updateCrop(to p: CGPoint) {
        guard let drag = cropDrag else { return }
        let r: CGRect
        switch drag {
        case .new(let start):
            r = rect(from: start, to: p)
        case .move(let original, let start):
            r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
        case .corner(let fixed):
            r = rect(from: fixed, to: p)
        }
        cropRectView = r
        drawCrop(r)
    }

    /// 放開：框限制在那一頁裡面，跳出選單
    private func finishCrop() {
        cropDrag = nil
        guard let r0 = cropRectView else { return }
        var best: NotePageView?
        var bestArea: CGFloat = 0
        for pv in pageViews.values {
            let overlap = pv.convert(pv.bounds, to: self).intersection(r0)
            if overlap.isNull { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                best = pv
                bestArea = area
            }
        }
        guard let pv = best else {
            cropRectView = nil
            drawCrop(nil)
            return
        }
        let r = r0.intersection(pv.convert(pv.bounds, to: self))
        guard r.width > 20, r.height > 20 else {
            cropRectView = nil
            cropResult = nil
            drawCrop(nil)
            return
        }
        cropRectView = r
        drawCrop(r)
        let s = pv.bounds.width / max(pv.page.spec.width, 1)
        let local = pv.convert(r, from: self)
        cropResult = (pv.page.id, CGRect(x: local.minX / s, y: local.minY / s, width: local.width / s, height: local.height / s))
        // 選單放在框的下面，放不下就放上面
        let size = cropBar.bounds.size
        var y = r.maxY + 16
        if y + size.height > bounds.height - 12 { y = max(12, r.minY - 16 - size.height) }
        let x = min(max(r.midX - size.width / 2, 12), max(12, bounds.width - size.width - 12))
        cropBar.frame.origin = CGPoint(x: x, y: y)
        if cropBar.superview == nil { addSubview(cropBar) }
        bringSubviewToFront(cropBar)
    }

    /// 截下來的圖（頁面內容、筆跡、文字、圖片都在）
    private func croppedImage() -> (image: UIImage, page: NotePage, rect: CGRect)? {
        guard let r = cropResult, let page = model.page(r.pageID), r.rect.width > 1, r.rect.height > 1 else { return nil }
        flushAll()                                              // 先把筆跡存檔
        return (PageRenderer.renderCrop(page, crop: r.rect), page, r.rect)
    }

    private func cropCopy() {
        guard let result = croppedImage() else { return }
        Self.imageClipboard = result.image
        Self.clipboard = []
        Self.clearMixedClipboard()
        Self.textClipboard = nil
        UIPasteboard.general.image = result.image
        Self.ownPasteboardChange = UIPasteboard.general.changeCount
        model.canPaste = true
        clearCropRect()                                         // 留在截圖模式，可以接著截下一張
        showMessage("doc.on.doc", "已拷貝")
    }

    /// 浮動視窗裡：框到的範圍貼到外面的白板上（記住從哪裡剪的）
    private func cropToBoard() {
        guard let result = croppedImage(), let paste = model.pasteToBoard else { return }
        let imageID = paste(result.image, model.meta.id, result.page.id, result.rect)
        // 這一頁記下剪去的範圍（v12.15.1，照 GUGA）：頁面上一個灰色虛線框，書籤面板「剪去白板的」也列出來
        let pageID = result.page.id
        let clips = model.clips(of: pageID) + [PageClip(rect: result.rect, imageID: imageID)]
        model.setClips(clips, pageID: pageID)
        pageViews[pageID]?.syncClips(clips)
        clearCropRect()                                         // 留在截圖模式，可以接著剪下一塊
    }

    /// 拿掉頁面上剪去白板的虛線框（書籤面板長按）
    func removeClipMark(_ id: UUID, pageID: UUID) {
        let clips = model.clips(of: pageID).filter { $0.id != id }
        model.setClips(clips, pageID: pageID)
        pageViews[pageID]?.syncClips(clips)
    }

    /// 在截圖那一頁旁邊新建一頁，把截圖貼在左上角（大小跟原本一樣）
    private func cropToSidePage(left: Bool) {
        if isBoard {
            showMessage("scissors", "白板沒有旁頁：截圖請用「拷貝」，再長按空白處貼上")
            return
        }
        // v12.10：沒有課本 PDF 的頁（格線紙上的筆記）不貼圖片，直接把框裡的筆跡、文字方塊、圖片搬一份過去
        if let r = cropResult, let page = model.page(r.pageID), page.pdf == nil, r.rect.width > 1, r.rect.height > 1,
           let loc = model.location(of: page.id) {
            cropInkToSidePage(source: page, rect: r.rect, row: model.notebook.rows[loc.row], left: left)
            return
        }
        guard let result = croppedImage(), let loc = model.location(of: result.page.id) else { return }
        let row = model.notebook.rows[loc.row]
        let main = row.pages[row.mainIndex]
        let source = result.page
        let newPage = NotePage(spec: source.spec, paper: source.pdf == nil ? source.paper : main.paper)
        clearCropRect()
        // 加在最外側（已經有右 1 就變右 2）；還在截圖模式，所以畫面留在原本這一頁，可以接著截下一題
        guard let newID = insertSidePage(rowID: row.id, at: left ? 0 : row.pages.count, page: newPage, jump: false),
              let file = Store.saveImage(result.image, pageID: newID) else { return }
        showMessage(left ? "arrow.left.square" : "arrow.right.square", left ? "已貼到最左邊的新旁頁" : "已貼到最右邊的新旁頁")
        let margin = 24 * pageScaleFactor(newPage.spec)
        var w = result.rect.width
        var h = result.rect.height
        let maxW = newPage.spec.width - margin * 2
        if w > maxW {
            h *= maxW / w
            w = maxW
        }
        var box = ImageBox(file: file)
        box.x = margin
        box.y = margin
        box.width = w
        box.height = h
        model.setImages([box], pageID: newID)
        pageViews[newID]?.syncImages([box])
    }

    /// 剪刀框到的是筆記（v12.10）：新旁頁用同一種紙，把框裡的筆跡、文字方塊、圖片複製過去。
    /// 往左上角靠，但只移動「整數格」，所以新頁上的字跟格線的相對位置和原本一樣（貼圖片的話格線會對不上）
    private func cropInkToSidePage(source: NotePage, rect: CGRect, row: PageRow, left: Bool) {
        flushAll()
        let drawing = pageViews[source.id]?.canvas.drawing ?? Store.loadDrawing(source.id)
        let picked = drawing.strokes.filter { rect.contains(CGPoint(x: $0.renderBounds.midX, y: $0.renderBounds.midY)) }
        let texts = (source.texts ?? []).filter { rect.contains(CGPoint(x: $0.x, y: $0.y)) }
        let images = (source.images ?? []).filter { rect.contains(CGPoint(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2)) }
        guard !picked.isEmpty || !texts.isEmpty || !images.isEmpty else {
            showMessage("scissors", "框裡沒有筆跡")
            return
        }
        let newPage = NotePage(spec: source.spec, paper: source.paper)
        clearCropRect()
        guard let newID = insertSidePage(rowID: row.id, at: left ? 0 : row.pages.count, page: newPage, jump: false) else { return }
        let unitX = PaperRenderer.gridUnit
        let unitY = source.paperStyle.pattern == 4 ? PaperRenderer.wideLine : PaperRenderer.gridUnit
        let dx = -floor(max(0, rect.minX - unitX) / unitX) * unitX
        let dy = -floor(max(0, rect.minY - unitY) / unitY) * unitY
        let move = CGAffineTransform(translationX: dx, y: dy)
        let moved = PKDrawing(strokes: picked.map {
            PKStroke(ink: $0.ink, path: $0.path, transform: $0.transform.concatenating(move), mask: $0.mask)
        })
        Store.saveDrawing(moved, pageID: newID)
        pageViews[newID]?.replaceSilently(moved, updateBaseline: true)
        if !texts.isEmpty {
            var copies = texts
            for i in copies.indices {
                copies[i].id = UUID()
                copies[i].x += dx
                copies[i].y += dy
            }
            model.setTexts(copies, pageID: newID)
            pageViews[newID]?.syncTexts(copies)
        }
        if !images.isEmpty {
            var copies: [ImageBox] = []
            for box in images {
                guard let image = Store.loadImage(box.file, pageID: source.id),
                      let file = Store.saveImage(image, pageID: newID) else { continue }
                var copy = box
                copy.id = UUID()
                copy.file = file
                copy.x += dx
                copy.y += dy
                copies.append(copy)
            }
            model.setImages(copies, pageID: newID)
            pageViews[newID]?.syncImages(copies)
        }
        showMessage(left ? "arrow.left.square" : "arrow.right.square", left ? "筆跡已貼到最左邊的新旁頁" : "筆跡已貼到最右邊的新旁頁")
    }

    /// 新增旁頁：插在某一張（index）的左邊或右邊（在右 1 往左新增，新頁插在主頁和右 1 中間）
    @discardableResult
    func insertSidePage(rowID: UUID, nextTo index: Int, left: Bool, page: NotePage) -> UUID? {
        insertSidePage(rowID: rowID, at: left ? index : index + 1, page: page)
    }

    /// 在這一列的第 position 張插入一頁，跳過去；可以復原（復原會回到原本看的那一張）
    /// jump = false：新增後畫面留在原本那一張（截圖模式連續截圖用）
    @discardableResult
    func insertSidePage(rowID: UUID, at position: Int, page: NotePage, jump: Bool = true) -> UUID? {
        if isBoard { return nil }                              // 白板只有一張頁面（v12.8：所有新增旁頁的路都擋在這裡）
        guard let r = model.notebook.rows.firstIndex(where: { $0.id == rowID }),
              let rv = rowViews[rowID] else { return nil }
        let oldIndex = rv.currentIndex
        let oldInPage = rv.ranges.indices.contains(oldIndex) ? rv.contentOffset.x - rv.ranges[oldIndex].lo : 0
        let count = model.notebook.rows[r].pages.count
        let pos = min(max(position, 0), count)
        model.notebook.rows[r].pages.insert(page, at: pos)
        if pos <= model.notebook.rows[r].mainIndex { model.notebook.rows[r].mainIndex += 1 }
        model.save()
        rebuild()
        // 畫面先停在原本那張，再滑到新的那張
        let shown = oldIndex >= pos ? oldIndex + 1 : oldIndex
        if !jump {
            rv.currentIndex = shown
            rv.contentOffset.x = rv.offsetFor(shown, inPage: oldInPage)
            publishFocus()
            let newID = page.id
            history.registerUndo(withTarget: self) { notebook in
                notebook.undoInsertSidePage(rowID: rowID, pageID: newID, returnIndex: oldIndex)
            }
            return newID
        }
        rv.contentOffset.x = rv.offsetFor(shown, inPage: 0)
        rv.currentIndex = pos
        if r != focusRow { scrollToRow(r, animated: false) }
        rv.setContentOffset(CGPoint(x: rv.offsetFor(pos, inPage: 0), y: 0), animated: true)
        publishFocus()
        refocus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.jump(toRow: r, page: pos)                       // 保險：一定停在新的那張
        }
        let pageID = page.id
        history.registerUndo(withTarget: self) { notebook in
            notebook.undoInsertSidePage(rowID: rowID, pageID: pageID, returnIndex: oldIndex)
        }
        return pageID
    }

    /// 「⋯ → 往左／往右新增旁頁」：以目前這一頁為準
    func addSidePageNextToCurrent(left: Bool) {
        let rows = model.notebook.rows
        guard rows.indices.contains(focusRow), let rv = rowViews[rows[focusRow].id] else { return }
        let row = rows[focusRow]
        let main = row.pages[row.mainIndex]
        let page = NotePage(spec: main.spec, paper: main.paper)
        insertSidePage(rowID: row.id, nextTo: rv.currentIndex, left: left, page: page)
    }

    // MARK: 紙膠帶

    private(set) var tapeMode = false
    private let tapePan = UIPanGestureRecognizer()          // 紙膠帶工具：Pencil 拉一個矩形
    private let tapeTap = UITapGestureRecognizer()          // 紙膠帶工具：Pencil 點一下打開／遮住
    private let tapePreview = CAShapeLayer()
    private var tapeStart = CGPoint.zero
    private(set) var revealedTapes = Set<UUID>()           // 打開中的紙膠帶（不存檔）
    private let tapeDeleteButton = UIButton(type: .system)
    private var tapeToDelete: (pageID: UUID, id: UUID)?

    func isTapeRevealed(_ id: UUID) -> Bool { revealedTapes.contains(id) }
    /// 紙膠帶都遮著（沒有打開的）（v12.9.2，白板設定面板的開關）
    var allTapesCovered: Bool { revealedTapes.isEmpty }

    private func setUpTape() {
        let pencil = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        tapePan.addTarget(self, action: #selector(handleTapePan(_:)))
        tapePan.allowedTouchTypes = pencil
        tapePan.delegate = self
        tapePan.isEnabled = false
        addGestureRecognizer(tapePan)
        tapeTap.addTarget(self, action: #selector(handleTapeTap(_:)))
        tapeTap.allowedTouchTypes = pencil
        tapeTap.isEnabled = false
        addGestureRecognizer(tapeTap)
        tapePreview.fillColor = UIColor(red: 0.62, green: 0.64, blue: 0.67, alpha: 0.6).cgColor
        tapePreview.strokeColor = nil
        layer.addSublayer(tapePreview)

        var config = UIButton.Configuration.filled()
        config.title = "刪除紙膠帶"
        config.image = UIImage(systemName: "trash")
        config.imagePadding = 6
        config.baseBackgroundColor = UIColor(white: 0.16, alpha: 0.96)
        config.baseForegroundColor = .systemRed
        config.cornerStyle = .capsule
        tapeDeleteButton.configuration = config
        tapeDeleteButton.addAction(UIAction { [weak self] _ in self?.deleteTape() }, for: .touchUpInside)
        tapeDeleteButton.isHidden = true
        tapeDeleteButton.sizeToFit()
        addSubview(tapeDeleteButton)
    }

    /// 筆盒選了紙膠帶：畫布暫停書寫，Pencil 改成拉紙膠帶
    func setTapeMode(_ on: Bool) {
        tapeMode = on
        tapePan.isEnabled = on && !cropMode
        tapeTap.isEnabled = on && !cropMode
        tapePreview.path = nil
        if on {
            dismissShapeEditor()
            endTextSelection()
        }
        applyCanvasDrawingAllowed()
    }

    @objc private func handleTapePan(_ g: UIPanGestureRecognizer) {
        if readOnly { return }
        let p = g.location(in: self)
        switch g.state {
        case .began:
            let t = g.translation(in: self)
            tapeStart = CGPoint(x: p.x - t.x, y: p.y - t.y)
            tapePreview.path = UIBezierPath(rect: rect(from: tapeStart, to: p)).cgPath
        case .changed:
            tapePreview.path = UIBezierPath(rect: rect(from: tapeStart, to: p)).cgPath
        case .ended:
            tapePreview.path = nil
            createTape(rect(from: tapeStart, to: p))
        default:
            tapePreview.path = nil
        }
    }

    @objc private func handleTapeTap(_ g: UITapGestureRecognizer) {
        if let hit = tapeHit(at: g.location(in: self)) { toggleTape(hit.1.id) }
    }

    /// 點到哪一條紙膠帶
    private func tapeHit(at p: CGPoint) -> (NotePageView, TapeBox)? {
        for pv in pageViews.values {
            for view in pv.tapeViews.values where view.convert(view.bounds, to: self).contains(p) {
                return (pv, view.box)
            }
        }
        return nil
    }

    func toggleTape(_ id: UUID) {
        if revealedTapes.contains(id) { revealedTapes.remove(id) } else { revealedTapes.insert(id) }
        for pv in pageViews.values { pv.refreshTapeStates() }
    }

    /// 「⋯ → 紙膠帶」：整本全部打開或全部遮住
    func setAllTapes(revealed: Bool) {
        revealedTapes = []
        if revealed {
            for row in model.notebook.rows {
                for page in row.pages {
                    for t in page.tapes ?? [] { revealedTapes.insert(t.id) }
                }
            }
        }
        for pv in pageViews.values { pv.refreshTapeStates() }
    }

    /// 拉完：貼在框到最多的那一頁
    private func createTape(_ r0: CGRect) {
        var best: NotePageView?
        var bestArea: CGFloat = 0
        for pv in pageViews.values {
            let overlap = pv.convert(pv.bounds, to: self).intersection(r0)
            if overlap.isNull { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                best = pv
                bestArea = area
            }
        }
        guard let pv = best else { return }
        let r = r0.intersection(pv.convert(pv.bounds, to: self))
        guard r.width > 12, r.height > 8 else { return }
        let s = pv.bounds.width / max(pv.page.spec.width, 1)
        let local = pv.convert(r, from: self)
        var tape = TapeBox()
        tape.x = local.minX / s
        tape.y = local.minY / s
        tape.width = local.width / s
        tape.height = local.height / s
        let id = pv.page.id
        let old = model.tapes(of: id)
        let new = old + [tape]
        model.setTapes(new, pageID: id)
        pv.syncTapes(new)
        history.registerUndo(withTarget: self) { notebook in
            notebook.restoreTapes(pageID: id, to: old)
        }
    }

    func restoreTapes(pageID: UUID, to tapes: [TapeBox]) {
        hideTapeDelete()
        let current = model.tapes(of: pageID)
        model.setTapes(tapes, pageID: pageID)
        pageViews[pageID]?.syncTapes(tapes)
        history.registerUndo(withTarget: self) { notebook in
            notebook.restoreTapes(pageID: pageID, to: current)
        }
        var rect = CGRect.null
        for t in tapes where !current.contains(t) { rect = rect.union(CGRect(x: t.x, y: t.y, width: t.width, height: t.height)) }
        for t in current where !tapes.contains(t) { rect = rect.union(CGRect(x: t.x, y: t.y, width: t.width, height: t.height)) }
        reveal(pageID: pageID, pageRect: rect)
    }

    private func showTapeDelete(at p: CGPoint, pageID: UUID, id: UUID) {
        tapeToDelete = (pageID, id)
        tapeDeleteButton.sizeToFit()
        let size = tapeDeleteButton.bounds.size
        tapeDeleteButton.frame = CGRect(x: p.x - size.width / 2, y: p.y - size.height - 24,
                                        width: size.width, height: size.height)
        tapeDeleteButton.isHidden = false
        bringSubviewToFront(tapeDeleteButton)
    }

    private func hideTapeDelete() {
        tapeDeleteButton.isHidden = true
        tapeToDelete = nil
    }

    private func deleteTape() {
        guard let target = tapeToDelete else { return }
        hideTapeDelete()
        let old = model.tapes(of: target.pageID)
        let new = old.filter { $0.id != target.id }
        model.setTapes(new, pageID: target.pageID)
        pageViews[target.pageID]?.syncTapes(new)
        let pageID = target.pageID
        history.registerUndo(withTarget: self) { notebook in
            notebook.restoreTapes(pageID: pageID, to: old)
        }
    }

    // MARK: 套索

    /// 筆盒選了套索：畫布暫停書寫，Pencil 改成畫套索
    func setLassoMode(_ on: Bool) {
        lassoMode = on
        lassoPan.isEnabled = on && !readOnly
        applyCanvasDrawingAllowed()
        if !on {
            lassoPoints = []
            lassoLayer.path = nil
        }
    }

    /// PencilKit 有時會自己把畫布的書寫打開：每次 Pencil 碰到螢幕都重新確認一次
    private func enforceLassoMode() {
        applyCanvasDrawingAllowed()
        if lassoPan.isEnabled != (lassoMode && !readOnly) { lassoPan.isEnabled = lassoMode && !readOnly }
    }

    @objc private func handleLasso(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            dismissShapeEditor()
            let t = g.translation(in: self)
            lassoPoints = [CGPoint(x: p.x - t.x, y: p.y - t.y), p]   // 補回手勢開始前移動的那一小段
        case .changed:
            lassoPoints.append(p)
        case .ended:
            lassoPoints.append(p)
            finishLasso()
        default:
            lassoPoints = []
        }
        if let first = lassoPoints.first, lassoPoints.count > 1 {
            // 畫的時候只顯示畫出來的線；放開時才自動接起頭尾、處理頁面邊緣
            let path = UIBezierPath()
            path.move(to: first)
            for q in lassoPoints.dropFirst() { path.addLine(to: q) }
            lassoLayer.path = path.cgPath
        } else {
            lassoLayer.path = nil
        }
    }

    /// 放開時：找出圈內的筆跡（一筆有一半以上的點在圈內就算），出現選取框
    private func finishLasso() {
        defer {
            lassoPoints = []
            lassoLayer.path = nil
        }
        guard lassoPoints.count >= 3 else { return }
        endTextSelection()                              // 正在輸入的文字方塊先收起來（它的範圍才是對的）
        let settings = PenBoxModel.shared
        // 套索大部分落在哪一頁，就選那一頁（從頁面外的灰色區域開始畫也沒關係）
        var target: NotePageView?
        var bestCount = 0
        for pv in pageViews.values {
            let count = lassoPoints.filter { pv.bounds.insetBy(dx: -40, dy: -40).contains(pv.convert($0, from: self)) }.count
            if count > bestCount {
                bestCount = count
                target = pv
            }
        }
        guard let pv = target else { return }
        let s = pv.bounds.width / max(pv.page.spec.width, 1)
        let w = pv.page.spec.width
        let h = pv.page.spec.height
        // 超出頁面或碰到頁面邊緣的部分壓回邊緣：畫 C 字碰到最旁邊，就會沿著邊緣圍起來
        let polygon = UIBezierPath()
        var pagePoints: [CGPoint] = []                  // 套索經過的點（頁面座標）
        for (i, q) in lassoPoints.enumerated() {
            let local = pv.convert(q, from: self)
            var x = local.x / s
            var y = local.y / s
            let edge: CGFloat = 12 / s                      // 離邊緣 12 點以內就算碰到邊緣
            if x < edge { x = 0 }
            if x > w - edge { x = w }
            if y < edge { y = 0 }
            if y > h - edge { y = h }
            let pagePoint = CGPoint(x: min(max(x, 0), w), y: min(max(y, 0), h))
            if i == 0 { polygon.move(to: pagePoint) } else { polygon.addLine(to: pagePoint) }
            pagePoints.append(pagePoint)
        }
        polygon.close()                                 // 頭尾自動接起來
        var hits: [Int] = []
        for (i, stroke) in pv.canvas.drawing.strokes.enumerated() {
            let isMarker = isHighlighter(stroke)
            if isMarker && !settings.lassoHighlighter { continue }
            if !isMarker && !settings.lassoHandwriting { continue }
            let pts = stroke.path.interpolatedPoints(by: .distance(4)).map { $0.location.applying(stroke.transform) }
            guard !pts.isEmpty else { continue }
            // 圈到什麼就選什麼：一筆只要有一部分在圈內就算
            if pts.contains(where: { polygon.contains($0) }) { hits.append(i) }
        }
        // 圖片：圈到一點就算（v12.2；v12.1 要圈住一半以上，使用者覺得選不到）。固定住的圖片不選
        var pickedImages: [ImageBox] = []
        if settings.lassoImages {
            for box in model.images(of: pv.page.id) where !box.isLocked {
                if Self.imageTouched(box, polygon: polygon, points: pagePoints) { pickedImages.append(box) }
            }
        }
        // 文字方塊（v12.2）：圈到一點就算；固定住的不選
        var pickedTexts: [SelectionEditorView.PickedText] = []
        if settings.lassoTexts {
            for box in model.texts(of: pv.page.id) where !box.isLocked {
                guard let view = pv.textViews[box.id] else { continue }
                let fr = view.frame
                let rect = CGRect(x: fr.minX / s, y: fr.minY / s, width: fr.width / s, height: fr.height / s)
                if Self.rectTouched(rect, polygon: polygon, points: pagePoints) {
                    pickedTexts.append(SelectionEditorView.PickedText(box: box, rect: rect))
                }
            }
        }
        guard !hits.isEmpty || !pickedImages.isEmpty || !pickedTexts.isEmpty else { return }
        if hits.isEmpty, pickedTexts.isEmpty, pickedImages.count == 1 {
            selectImage(pickedImages[0], on: pv)                         // 只圈到一張圖片：用圖片自己的選取框
            return
        }
        if hits.isEmpty, pickedImages.isEmpty, pickedTexts.count == 1, let view = pv.textViews[pickedTexts[0].box.id] {
            dismissShapeEditor()
            activate(view, edit: false)                                  // 只圈到一個文字方塊：用文字方塊自己的選取
            return
        }
        let strokesNow = pv.canvas.drawing.strokes
        let single = pickedImages.isEmpty && pickedTexts.isEmpty && hits.count == 1
            && strokesNow.indices.contains(hits[0]) && isHighlighter(strokesNow[hits[0]])
        showSelection(on: pv, indices: hits, allowLine: single, images: pickedImages,   // 單獨一條螢光筆：預設兩端點
                      texts: pickedTexts)
    }

    /// 一個矩形範圍有沒有被套索碰到：套索的線經過它，或它有一部分在圈起來的範圍裡
    private static func rectTouched(_ rect: CGRect, polygon: UIBezierPath, points: [CGPoint]) -> Bool {
        for p in points where rect.contains(p) { return true }
        for i in 0..<5 {
            for j in 0..<5 {
                let p = CGPoint(x: rect.minX + rect.width * CGFloat(i) / 4, y: rect.minY + rect.height * CGFloat(j) / 4)
                if polygon.contains(p) { return true }
            }
        }
        return false
    }

    /// 圖片有沒有被套索碰到（圖片可能轉過角度）：套索的線經過它，或它有一部分在圈起來的範圍裡
    private static func imageTouched(_ box: ImageBox, polygon: UIBezierPath, points: [CGPoint]) -> Bool {
        let quad = SelectionEditorView.quad(of: box)
        for p in points where quad.contains(p) { return true }
        let cx = box.x + box.width / 2
        let cy = box.y + box.height / 2
        let c = cos(box.rotation)
        let s = sin(box.rotation)
        for i in 0..<7 {
            for j in 0..<7 {
                let lx = (CGFloat(i) / 6 - 0.5) * box.width
                let ly = (CGFloat(j) / 6 - 0.5) * box.height
                let p = CGPoint(x: cx + lx * c - ly * s, y: cy + lx * s + ly * c)
                if polygon.contains(p) { return true }
            }
        }
        return false
    }

    // MARK: 工具（筆盒和 Apple 工具列都可以換筆）

    /// 筆盒選了工具：套用到所有已載入的畫布，之後新載入的頁面也會用它
    private var adaptiveInk = false            // 萬用筆：每一頁依背景決定顏色
    private var adaptiveLight = UIColor.black  // 萬用筆在淺色頁面的顏色
    private var adaptiveDark = UIColor.white   // 萬用筆在深色頁面的顏色

    func setTool(_ tool: PKTool, adaptive: Bool = false) {
        lastTool = tool
        adaptiveInk = adaptive
        if adaptive {
            let pair = PenBoxModel.shared.currentAdaptiveColors
            adaptiveLight = pair.light
            adaptiveDark = pair.dark
        }
        for pv in pageViews.values { pv.canvas.tool = scaledTool(tool, for: pv.page) }
    }

    /// 筆盒的粗細以 A4 為準，換算成這一頁實際的粗細；萬用筆依這一頁的背景換成黑或白
    private func scaledTool(_ tool: PKTool, for page: NotePage) -> PKTool {
        let k = pageScaleFactor(page.spec)
        if let ink = tool as? PKInkingTool {
            if !adaptiveInk && abs(k - 1) < 0.01 { return tool }
            var color = ink.color
            if adaptiveInk {
                let alpha = ink.color.cgColor.alpha
                color = (page.isDarkBackground ? adaptiveDark : adaptiveLight).withAlphaComponent(alpha)
            }
            return PKInkingTool(ink.inkType, color: color, width: ink.width * k)
        }
        if abs(k - 1) < 0.01 { return tool }
        if let eraser = tool as? PKEraserTool, #available(iOS 16.4, *),
           eraser.eraserType == .bitmap || eraser.eraserType == .vector {
            return PKEraserTool(eraser.eraserType, width: eraser.width * k)
        }
        return tool
    }

    /// 現在畫布能不能用筆寫（套索模式不行；文字方塊選取中，框外照樣可以畫）
    private var canvasDrawingAllowed: Bool { !lassoMode && !cropMode && !tapeMode && !frameMode }

    private func applyCanvasDrawingAllowed() {
        let allowed = canvasDrawingAllowed && !readOnly
        for pv in pageViews.values where pv.canvas.drawingGestureRecognizer.isEnabled != allowed {
            pv.canvas.drawingGestureRecognizer.isEnabled = allowed
        }
    }

    /// 在 Apple 工具列上換了筆：記下來，筆盒取消選取
    private func appleToolChosen() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self = self else { return }
            if let tool = self.pageViews.values.first?.canvas.tool { self.lastTool = tool }
            self.adaptiveInk = false
            self.setLassoMode(false)
            PenBoxModel.shared.useApple()
        }
    }

    // MARK: Apple Pencil 點兩下：依照「設定 > Apple Pencil」裡選的動作

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        handlePencilDoubleTap()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        handlePencilDoubleTap()
    }

    private func handlePencilDoubleTap() {
        let box = PenBoxModel.shared
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser:
            box.toggleEraser()
        case .switchPrevious:
            box.togglePrevious()
        case .showColorPalette, .showInkAttributes:
            box.requestSettings()
        default:
            break
        }
    }

    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        appleToolChosen()
    }

    @available(iOS 18.0, *)
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        appleToolChosen()
    }

    enum ExportMode {
        case allSidePages
        case sidePages(row: Int)
        case wholeNotebook
        case changedSidePages(since: Date)         // v12.9.2：只匯出這個時間之後改過的旁頁
    }

    /// 這一頁最後改的時間：文字、圖片、紙膠帶看 page.modified，筆跡看筆跡檔的修改時間
    private func lastModified(_ page: NotePage) -> Date {
        var d = page.modified ?? Date.distantPast
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Store.drawingURL(page.id).path),
           let m = attrs[.modificationDate] as? Date {
            d = max(d, m)
        }
        if BoardTiles.isTiled(page.id), let m = BoardTiles.modified(page.id) { d = max(d, m) }   // 分區儲存的頁（v12.11.0）
        return d
    }

    /// 匯出成 PDF（存在暫存資料夾），回傳檔案位置；沒有可匯出的頁面就回傳 nil
    /// 白板匯出成一頁 PDF（v12.5）：範圍是所有筆跡、圖片、文字方塊，四周留一點空白。
    /// PDF 一頁最大 14400 點，太大就整頁等比例縮小；筆跡的圖最大 8000 像素
    /// region：只匯出這一塊（區塊的匯出用）；nil：所有內容的範圍
    private func exportBoardPage(_ page: NotePage, ctx: UIGraphicsPDFRendererContext, area region: CGRect? = nil) {
        let drawing = Store.loadDrawing(page.id)
        var area = drawing.strokes.isEmpty ? CGRect.null : drawing.bounds
        for box in page.images ?? [] { area = area.union(SelectionEditorView.imageBounds(of: box)) }
        for t in page.texts ?? [] {
            area = area.union(CGRect(x: t.x, y: t.y, width: t.width + 10, height: t.fontSize * 1.6))
        }
        if area.isNull { area = CGRect(x: 0, y: 0, width: 595, height: 842) }
        area = area.insetBy(dx: -40, dy: -40)
        if let r = region { area = r }
        area = area.intersection(CGRect(x: 0, y: 0, width: page.spec.width, height: page.spec.height))
        let k = min(1, 14_400 / max(area.width, area.height, 1))
        let pageBounds = CGRect(x: 0, y: 0, width: area.width * k, height: area.height * k)
        ctx.beginPage(withBounds: pageBounds, pageInfo: [:])
        let rect = CGRect(x: -area.minX * k, y: -area.minY * k, width: page.spec.width * k, height: page.spec.height * k)
        let cg = ctx.cgContext
        cg.saveGState()
        cg.clip(to: pageBounds)
        let inkScale = min(3, 8000 / max(area.width, area.height, 1))
        PageRenderer.draw(page, in: cg, rect: rect, inkScale: inkScale, drawing: drawing, region: area)
        cg.restoreGState()
    }

    func exportPDF(_ mode: ExportMode, order: SideOrder) -> URL? {
        flushAll()
        var items: [(NotePage, String)] = []
        for (r, row) in model.notebook.rows.enumerated() {
            if case .sidePages(let only) = mode, only != r { continue }
            let main = row.mainIndex
            let right = Array((main + 1)..<row.pages.count)
            let left = Array((0..<main).reversed())
            var indices: [Int]
            switch order {
            case .rightFirst: indices = right + left
            case .leftFirst: indices = left + right
            case .visual: indices = Array(0..<row.pages.count).filter { $0 != main }
            }
            if case .wholeNotebook = mode {               // 整本：主頁也要
                indices = order == .visual ? Array(0..<row.pages.count) : [main] + indices
            }
            // 標上對應的課本頁碼（主頁是 PDF 的話），檢查的時候知道是哪一題（v12.9.2）
            let book = row.pages[main].pdf.map { "（課本 p.\($0.index + 1)）" } ?? ""
            for i in indices {
                if case .changedSidePages(let since) = mode, lastModified(row.pages[i]) < since { continue }
                let d = i - main
                let side = d == 0 ? "" : (d < 0 ? "　左 \(-d)" : "　右 \(d)")
                items.append((row.pages[i], "第 \(r + 1) 頁" + book + side))
            }
        }
        guard !items.isEmpty else { return nil }

        let suffix: String
        switch mode {
        case .allSidePages: suffix = "旁頁"
        case .sidePages(let r): suffix = "第\(r + 1)頁的旁頁"
        case .wholeNotebook: suffix = "整本"
        case .changedSidePages: suffix = "改過的旁頁"
        }
        let title = model.meta.title.replacingOccurrences(of: "/", with: "-")
        let url = StorageReport.exportURL.appendingPathComponent("\(title)-\(suffix).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let labelStyle: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.gray
        ]
        do {
            try renderer.writePDF(to: url) { ctx in
                for (page, label) in items {
                    if page.spec.flat == true {
                        exportBoardPage(page, ctx: ctx)                 // 白板：只匯出有寫東西的範圍
                        continue
                    }
                    let rect = CGRect(x: 0, y: 0, width: page.spec.width, height: page.spec.height)
                    ctx.beginPage(withBounds: rect, pageInfo: [:])
                    PageRenderer.draw(page, in: ctx.cgContext, rect: rect, inkScale: 3)
                    (label as NSString).draw(at: CGPoint(x: 8, y: 6), withAttributes: labelStyle)
                }
            }
        } catch {
            return nil
        }
        switch mode {
        case .allSidePages, .changedSidePages:
            UserDefaults.standard.set(Date(), forKey: "lastSideExport." + model.meta.id.uuidString)   // 記住這次匯出的時間
        default:
            break
        }
        return url
    }

    // MARK: 復原、重做、停筆變形

    @objc private func historyChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let u = self.history.canUndo
            let r = self.history.canRedo
            if self.model.canUndo != u { self.model.canUndo = u }
            if self.model.canRedo != r { self.model.canRedo = r }
        }
    }

    /// 右上角的復原、重做按鈕（跟雙指、三指點一樣）
    func performUndo() { undoAction() }
    func performRedo() { redoAction() }

    @objc private func undoAction() {
        endTextSelection()
        dismissShapeEditor()
        guard history.canUndo else { return }
        undoManager?.undo()
        showToast("arrow.uturn.backward")
    }

    @objc private func redoAction() {
        endTextSelection()
        dismissShapeEditor()
        guard history.canRedo else { return }
        undoManager?.redo()
        showToast("arrow.uturn.forward")
    }

    // 復原、重做時在畫面上方閃一下圖示
    private let toast = UIImageView()

    private func showToast(_ symbol: String) {
        toast.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .bold))
        toast.tintColor = .white
        toast.contentMode = .center
        toast.backgroundColor = UIColor(white: 0.25, alpha: 0.9)
        toast.layer.cornerRadius = 16
        toast.clipsToBounds = true
        toast.frame = CGRect(x: bounds.midX - 40, y: 16, width: 80, height: 80)
        if toast.superview == nil { addSubview(toast) }
        bringSubviewToFront(toast)
        toast.layer.removeAllAnimations()
        toast.alpha = 1
        UIView.animate(withDuration: 0.35, delay: 0.45, options: [.curveEaseOut]) {
            self.toast.alpha = 0
        }
    }

    // 拷貝、剪下時在畫面上方跳一下「圖示 + 已拷貝」
    private let messageToast = UIView()
    private let messageIcon = UIImageView()
    private let messageLabel = UILabel()

    func showMessage(_ symbol: String, _ text: String) {
        if messageToast.superview == nil {
            messageToast.backgroundColor = UIColor(white: 0.2, alpha: 0.92)
            messageToast.layer.cornerRadius = 22
            messageIcon.tintColor = .white
            messageIcon.contentMode = .scaleAspectFit
            messageLabel.textColor = .white
            messageLabel.font = .systemFont(ofSize: 16, weight: .semibold)
            messageToast.addSubview(messageIcon)
            messageToast.addSubview(messageLabel)
            addSubview(messageToast)
        }
        messageIcon.image = UIImage(systemName: symbol)
        messageLabel.text = text
        messageLabel.sizeToFit()
        let width = 16 + 22 + 8 + messageLabel.bounds.width + 18
        messageToast.frame = CGRect(x: bounds.midX - width / 2, y: topReserved + 16, width: width, height: 44)  // 白板鋪到工具列下面（v12.8）
        messageIcon.frame = CGRect(x: 16, y: 11, width: 22, height: 22)
        messageLabel.frame = CGRect(x: 46, y: 0, width: messageLabel.bounds.width, height: 44)
        bringSubviewToFront(messageToast)
        messageToast.layer.removeAllAnimations()
        messageToast.alpha = 1
        UIView.animate(withDuration: 0.35, delay: 0.9, options: [.curveEaseOut]) {
            self.messageToast.alpha = 0
        }
    }

    /// Pencil 一碰到筆跡就按住不動：中斷正在畫的點，選取那一筆
    private func selectByPencilHold(at start: CGPoint, on pv: NotePageView) -> Bool {
        let countBefore = pv.strokeCountAtBegin
        let local = pv.convert(start, from: self)
        let s = pv.bounds.width / max(pv.page.spec.width, 1)
        let pagePoint = CGPoint(x: local.x / s, y: local.y / s)
        guard let index = StrokeHitTest.index(at: pagePoint, in: pv.canvas.drawing, tolerance: 14 / s),
              index < countBefore, isHighlighter(pv.canvas.drawing.strokes[index]) else { return false }  // 只有螢光筆
        let canvas = pv.canvas
        canvas.drawingGestureRecognizer.isEnabled = false
        canvas.drawingGestureRecognizer.isEnabled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if canvas.drawing.strokes.count > countBefore {        // 按住時畫出的小點拿掉
                var cleaned = canvas.drawing
                cleaned.strokes = Array(cleaned.strokes.prefix(countBefore))
                pv.replaceSilently(cleaned, updateBaseline: true)
            }
            self.showSelection(on: pv, indices: [index], allowLine: true)
        }
        return true
    }

    /// Pencil 停住時呼叫：判斷這一筆像什麼圖形，像的話當下就換成標準圖形
    private func snapWhileHolding(_ viewPoints: [CGPoint]) -> Bool {
        guard !lassoMode, !cropMode, !tapeMode, let start = viewPoints.first else { return false }
        // 找出這一筆畫在哪一頁
        guard let pv = pageViews.values.first(where: { $0.bounds.contains($0.convert(start, from: self)) }),
              let tool = pv.canvas.tool as? PKInkingTool else { return false }
        let canvas = pv.canvas
        // 筆是從調整框上開始的（正在拖控制點），不算畫線
        if let editor = shapeEditor, editor.point(inside: editor.convert(start, from: self), with: nil) {
            return false
        }
        // 筆一碰到就按住不動：如果按在筆跡上，就選取那一筆（不是畫圖形）
        let moved = viewPoints.map { hypot($0.x - start.x, $0.y - start.y) }.max() ?? 0
        if moved < 8 {
            return false            // v12.3：拿掉「Pencil 按住筆跡來選取」，改成手指長按（handleSelectPress）
        }
        guard snapOn(.shapes) else { return false }        // 「⋯ → 停筆」關掉了：照原樣留下手畫的線
        let z = max(canvas.zoomScale, 0.0001)
        let pts = viewPoints.map { p -> CGPoint in
            let q = canvas.convert(p, from: self)
            return CGPoint(x: q.x / z, y: q.y / z)              // 換成頁面座標
        }
        let isMarker = isHighlighterInk(tool.inkType, tool.color)
        // 螢光筆停住只會變直線；其他筆才判斷圖形
        guard let shape = isMarker ? ShapeSnapper.markerLine(for: pts) : ShapeSnapper.shapePoints(for: pts)
        else { return false }

        if isMarker, let a = shape.points.first, let b = shape.points.last {
            // 螢光筆不中斷：顯示預覽直線，等放開再處理（PencilKit 被中斷時常常不會留下那一筆）
            pendingMarkerLine = (pv.page.id, a, b)
            let s = pv.bounds.width / max(pv.page.spec.width, 1)
            let guide = UIBezierPath()
            guide.move(to: pv.convert(CGPoint(x: a.x * s, y: a.y * s), to: self))
            guide.addLine(to: pv.convert(CGPoint(x: b.x * s, y: b.y * s), to: self))
            markerGuide.path = guide.cgPath
            return true
        }

        // 其他筆（v11.18 起）：不中斷正在畫的這一筆，先畫一個預覽，放開筆之後再用真正畫完的那一筆換成標準圖形。
        // 以前會當場中斷，PencilKit 有時不會留下那一筆，只能借別的筆跡的數值來畫；
        // 頁面上沒有可借的筆跡時（例如剛新增的空白旁頁），畫出來的圖形會看不見。
        pendingShape = (pv.page.id, shape.points, pts.last ?? CGPoint.zero, shape.kind == ShapeKind.line)
        let s = pv.bounds.width / max(pv.page.spec.width, 1)
        let guide = UIBezierPath()
        for (i, q) in shape.points.enumerated() {
            let v = pv.convert(CGPoint(x: q.x * s, y: q.y * s), to: self)
            if i == 0 { guide.move(to: v) } else { guide.addLine(to: v) }
        }
        markerGuide.path = guide.cgPath
        return true
    }

    /// 停住時判斷出的圖形（頁面座標）；放開筆時換上去。holdEnd：停住那一刻筆尖的位置；isLine：是直線（不是圖形）
    private var pendingShape: (pageID: UUID, points: [CGPoint], holdEnd: CGPoint, isLine: Bool)?

    /// 手寫（不是螢光筆）放開筆之後：停住過就換成標準圖形；虛線筆切成一段一段
    func finishPenStroke(on pv: NotePageView?, countBefore: Int) {
        guard let pv = pv else { return }
        let pending = pendingShape
        pendingShape = nil
        if pending != nil { markerGuide.path = nil }
        let dash = PenBoxModel.shared.currentDash
        let drawing = pv.canvas.drawing
        guard drawing.strokes.count == countBefore + 1, let drawn = drawing.strokes.last,
              !isHighlighter(drawn) else { return }
        var points: [CGPoint]?
        var isLine = false                                          // 變出來的是直線還是圖形（決定要不要跳出調整框）
        if let p = pending, p.pageID == pv.page.id {
            let pts = drawn.path.interpolatedPoints(by: .distance(3)).map { $0.location.applying(drawn.transform) }
            let end = pts.last ?? p.holdEnd
            if hypot(end.x - p.holdEnd.x, end.y - p.holdEnd.y) < 15 {
                points = p.points                                   // 停住之後就放開：用停住時的圖形
                isLine = p.isLine
            } else if let again = ShapeSnapper.shapePoints(for: pts) {
                points = again.points                               // 停住之後又繼續畫：以整筆重新判斷
                isLine = again.kind == ShapeKind.line
            }
        }
        guard let shape = points else {
            // 沒有變形：虛線筆把這一筆切段（只是換個樣子，復原時直接回到畫這筆之前）
            guard dash != 0 else { return }
            let pieces = DashMaker.dashed(drawn, style: dash)
            guard pieces.count > 1 else { return }
            var cut = drawing
            cut.strokes.removeLast()
            cut.strokes.append(contentsOf: pieces)
            pv.replaceSilently(cut, updateBaseline: true)
            return
        }
        // 標準圖形的每一點都照「真正畫出來的這一筆」的數值，粗細一定跟這支筆一樣
        let shapeStroke = ShapeSnapper.makeStroke(points: shape, ink: drawn.ink, template: drawn, width: 4)
        let pieces: [PKStroke] = dash == 0 ? [shapeStroke] : DashMaker.dashed(shapeStroke, style: dash)
        var snapped = drawing
        snapped.strokes.removeLast()
        snapped.strokes.append(contentsOf: pieces)
        ShapeSnapper.setDrawing(snapped, on: pv.canvas)          // 登記一步：雙指點一下會回到手畫的線
        // 直線通常畫完就繼續寫，圖形才需要調整：兩種各自有開關（v12.1）
        if snapOn(isLine ? SnapSettings.Item.lineEditor : SnapSettings.Item.shapeEditor) {
            showSelection(on: pv, indices: Array(countBefore..<snapped.strokes.count), allowLine: pieces.count == 1)
        }
    }

    /// 停筆的設定（「⋯ → 停筆」或首頁的設定）：這本筆記本有自己的設定就用它，沒有用共用的
    private func snapOn(_ item: SnapSettings.Item) -> Bool {
        SnapSettings.value(item, notebook: model.meta.id)
    }


}
