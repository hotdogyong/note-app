import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// TextAndImage.swift：圖片選取框、文字方塊、數學式（KaTeX）、文字工具列
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

/// 圖片的選取框（v12.15.1 照 GUGA 改樣子）：拖中間移動；四個角（黑色中空點）等比例縮放；右邊外面的 ⟳ 旋轉；
/// 四邊中間的灰點往外拉＝拉出一條線和一個文字方塊（卡片也一樣）；右下角「裁剪」「放大看」；下面有工具列
final class ImageEditorView: UIView {
    weak var host: NotebookView?
    weak var pageView: NotePageView?
    private(set) var box: ImageBox
    private let outline = CAShapeLayer()
    private let handleLayer = CAShapeLayer()            // 四個角
    private let dotLayer = CAShapeLayer()               // 四邊中間的灰點
    private let cropShade = CAShapeLayer()              // 裁剪中：框外面變暗
    private let cropBorder = CAShapeLayer()
    private let bar = UIView()
    private var barItems: [UIView] = []
    private let cropBar = UIView()                      // 裁剪中：取消、完成
    private let press = UILongPressGestureRecognizer()
    private let yield = ScrollYield()

    private enum Mode: Equatable {
        case idle, move, scale, rotate, cardOpen, cardPreview, cardPrev, cardNext, sourceOpen, crop, expand
        case link(Int)                                  // 從四邊中間的點拉線：0 上、1 右、2 下、3 左
        case cropCorner(Int), cropMove
    }

    private static func icon(_ name: String, size: CGFloat, weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    // 右邊外面的旋轉鈕（灰色圓、⟳）
    private let rotateIcon: UIImageView = {
        let view = UIImageView(image: ImageEditorView.icon("arrow.clockwise", size: 15, weight: .bold))
        view.contentMode = .center
        view.tintColor = UIColor.white
        view.backgroundColor = UIColor(white: 0.5, alpha: 0.9)
        view.layer.cornerRadius = 15
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        return view
    }()
    // 右下角：裁剪、放大看
    private let toolPill = UIView()
    private let cropIcon = UIImageView(image: ImageEditorView.icon("crop", size: 17))
    private let expandIcon = UIImageView(image: ImageEditorView.icon("arrow.up.left.and.arrow.down.right", size: 16))
    private static let pillSize = CGSize(width: 84, height: 38)

    // 從浮動視窗剪下來的圖（v12.15.0）：選取後左下角一顆 ‹，按了回到剪下來的地方。大小跟著圖在畫面上的大小（v12.15.1）
    private let sourceButton: UIImageView = {
        let view = UIImageView(image: ImageEditorView.icon("chevron.left", size: 13, weight: .bold))
        view.contentMode = .center
        view.tintColor = UIColor.white
        view.backgroundColor = UIColor(white: 0.35, alpha: 0.9)
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }()

    private var hasSourceButton: Bool { box.link == nil && box.sourceNotebook != nil && !box.isLocked && !cropping }

    /// 圖在畫面上比較短的那一邊有多長（點）
    private var shownSide: CGFloat { min(box.width, box.height) * scale }

    /// ‹ 的直徑（點）：圖小就跟著小，22～30
    private var sourceSide: CGFloat { min(max(shownSide * 0.2, 22), 30) }

    /// ‹ 的中心（頁面座標）：圖片裡面的左下角
    private var sourceButtonCenter: CGPoint {
        let s = max(scale, 0.0001)
        let side = sourceSide / s
        let gap = 8 / s
        return rotated(CGPoint(x: -box.width / 2 + gap + side / 2, y: box.height / 2 - gap - side / 2))
    }

    /// 右下角的裁剪、放大看：一般圖片才有，而且圖在畫面上要夠大
    private var hasToolPill: Bool {
        box.link == nil && !box.isLocked && !cropping && box.width * scale > 150 && box.height * scale > 80
    }

    /// 右下角那一塊的中心（頁面座標）
    private var toolPillCenter: CGPoint {
        let s = max(scale, 0.0001)
        let gap = 8 / s
        return rotated(CGPoint(x: box.width / 2 - gap - Self.pillSize.width / 2 / s,
                               y: box.height / 2 - gap - Self.pillSize.height / 2 / s))
    }

    private static let cardModes: [Mode] = [.cardOpen, .cardPreview, .cardPrev, .cardNext]
    // 白板上的筆記本卡片（v12.12.3，照 GUGA）：選取之後左上角才出現兩顆按鈕——開浮動視窗、在卡片上預覽；
    // 預覽中，封面下緣左右各多一顆翻頁。按鈕只是圖，按到哪一顆由 modeAt 判斷（跟拖曳用同一個手勢）
    private static let cardButtonSide: CGFloat = 38
    private let cardButtons: [UIImageView] = ["macwindow.on.rectangle", "book", "chevron.left", "chevron.right"].map { name in
        let view = UIImageView(image: ImageEditorView.icon(name, size: 17))
        view.contentMode = .center
        view.tintColor = UIColor.white
        view.backgroundColor = UIColor(white: 0.08, alpha: 0.86)
        view.layer.cornerRadius = 10
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }
    private var mode = Mode.idle
    private var startBox: ImageBox
    private var startPoint = CGPoint.zero
    private var startAngle: CGFloat = 0
    private var startDistance: CGFloat = 1
    private var fixedCorner = CGPoint.zero        // 拖角縮放：對角固定不動（頁面座標）
    private var startDiagonal = CGPoint.zero      // 從固定的角到被拖的角
    private let lockButton = UIButton(type: .system)
    // 裁剪（v12.15.1）：範圍用圖片自己的比例座標（0～1，不管旋轉）
    private var cropping = false
    private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var cropStart = CGRect(x: 0, y: 0, width: 1, height: 1)

    init(box: ImageBox, pageView: NotePageView, host: NotebookView) {
        self.box = box
        self.startBox = box
        super.init(frame: pageView.bounds)
        self.pageView = pageView
        self.host = host
        backgroundColor = .clear
        outline.fillColor = nil
        outline.strokeColor = UIColor.systemBlue.cgColor
        outline.lineWidth = 1.5
        layer.addSublayer(outline)
        cropShade.fillColor = UIColor(white: 0, alpha: 0.5).cgColor
        cropShade.fillRule = .evenOdd
        layer.addSublayer(cropShade)
        cropBorder.fillColor = nil
        cropBorder.strokeColor = UIColor.white.cgColor
        cropBorder.lineWidth = 2
        layer.addSublayer(cropBorder)
        dotLayer.fillColor = UIColor(white: 0.62, alpha: 1).cgColor
        dotLayer.strokeColor = UIColor(white: 1, alpha: 0.85).cgColor
        dotLayer.lineWidth = 1
        layer.addSublayer(dotLayer)
        handleLayer.fillColor = UIColor.white.cgColor          // 黑色中空點（照 GUGA）
        handleLayer.strokeColor = UIColor.black.cgColor
        handleLayer.lineWidth = 2.5
        layer.addSublayer(handleLayer)
        press.minimumPressDuration = 0
        press.delegate = yield
        press.addTarget(self, action: #selector(handlePress(_:)))
        addGestureRecognizer(press)
        for button in cardButtons { addSubview(button) }
        addSubview(sourceButton)
        addSubview(rotateIcon)
        toolPill.backgroundColor = UIColor(white: 0.12, alpha: 0.82)
        toolPill.layer.cornerRadius = Self.pillSize.height / 2
        toolPill.isUserInteractionEnabled = false
        for v in [cropIcon, expandIcon] {
            v.tintColor = UIColor.white
            v.contentMode = .center
            toolPill.addSubview(v)
        }
        addSubview(toolPill)
        setUpBar()
        setUpCropBar()
    }

    /// 卡片按鈕的中心（頁面座標）。0、1：左上角由左到右；2、3：封面下緣的左、右
    private func cardButtonCenter(_ index: Int) -> CGPoint {
        let s = max(scale, 0.0001)
        let side = Self.cardButtonSide / s
        let gap = 8 / s
        let w = box.width / 2
        let h = box.height / 2
        let caption = CardCover.captionHeight * box.width / CardCover.width      // 標題那一條在頁面上的高度
        switch index {
        case 0: return rotated(CGPoint(x: -w + gap + side / 2, y: -h + gap + side / 2))
        case 1: return rotated(CGPoint(x: -w + gap * 2 + side * 1.5, y: -h + gap + side / 2))
        case 2: return rotated(CGPoint(x: -w + gap + side / 2, y: h - caption - gap - side / 2))
        default: return rotated(CGPoint(x: w - gap - side / 2, y: h - caption - gap - side / 2))
        }
    }

    /// 現在有幾顆卡片按鈕（不是卡片、或固定住：0）
    private var cardButtonCount: Int {
        guard box.link != nil, !box.isLocked else { return 0 }
        return box.previewPage != nil ? 4 : 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ newBox: ImageBox) {
        box = newBox
        refreshLock()
        setNeedsLayout()
    }

    private var scale: CGFloat {
        guard let pv = pageView else { return 1 }
        return pv.bounds.width / max(pv.page.spec.width, 1)
    }

    private var imageCenter: CGPoint { CGPoint(x: box.x + box.width / 2, y: box.y + box.height / 2) }

    private func rotated(_ p: CGPoint) -> CGPoint {
        let c = cos(box.rotation)
        let s = sin(box.rotation)
        return CGPoint(x: imageCenter.x + p.x * c - p.y * s, y: imageCenter.y + p.x * s + p.y * c)
    }

    /// 頁面座標 → 圖片自己的座標（以中心為原點、轉回沒旋轉的方向）
    private func local(_ p: CGPoint) -> CGPoint {
        let dx = p.x - imageCenter.x
        let dy = p.y - imageCenter.y
        let c = cos(-box.rotation)
        let s = sin(-box.rotation)
        return CGPoint(x: dx * c - dy * s, y: dx * s + dy * c)
    }

    /// 圖片的比例座標（0～1）→ 頁面座標
    private func fromUnit(_ u: CGPoint) -> CGPoint {
        rotated(CGPoint(x: (u.x - 0.5) * box.width, y: (u.y - 0.5) * box.height))
    }

    /// 四個角（頁面座標）
    private var corners: [CGPoint] {
        let w = box.width / 2
        let h = box.height / 2
        return [rotated(CGPoint(x: -w, y: -h)), rotated(CGPoint(x: w, y: -h)),
                rotated(CGPoint(x: w, y: h)), rotated(CGPoint(x: -w, y: h))]
    }

    /// 四邊中間的灰點（頁面座標）：在邊的外面一點
    private var sideDots: [CGPoint] {
        let d = 20 / max(scale, 0.0001)
        let w = box.width / 2
        let h = box.height / 2
        return [rotated(CGPoint(x: 0, y: -h - d)), rotated(CGPoint(x: w + d, y: 0)),
                rotated(CGPoint(x: 0, y: h + d)), rotated(CGPoint(x: -w - d, y: 0))]
    }

    /// 旋轉鈕（頁面座標）：右邊那個灰點的再外面
    private var rotateHandle: CGPoint {
        rotated(CGPoint(x: box.width / 2 + 58 / max(scale, 0.0001), y: 0))
    }

    private var canEdit: Bool { !box.isLocked && !cropping }

    private func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: p.y * scale) }

    private func setUpBar() {
        bar.backgroundColor = UIColor(white: 0.16, alpha: 0.96)
        bar.layer.cornerRadius = 22
        // 第一個：固定（鎖住後不能移動、縮放、旋轉，再按一次解開）
        lockButton.addAction(UIAction { [weak self] _ in self?.host?.toggleImageLock() }, for: .touchUpInside)
        bar.addSubview(lockButton)
        barItems.append(lockButton)
        let items: [(String, UIColor, () -> Void)] = [
            ("doc.on.doc", .white, { [weak self] in self?.host?.copyImage(cut: false) }),
            ("scissors", .white, { [weak self] in self?.host?.copyImage(cut: true) }),
            ("plus.square.on.square", .white, { [weak self] in self?.host?.duplicateImage() }),
            ("square.3.layers.3d", .white, { [weak self] in self?.host?.toggleImageLayer() }),
            ("arrow.down.right.and.arrow.up.left", .white, { [weak self] in self?.host?.miniImage() }),   // 縮成小圖（v12.8.3）
            ("trash", .systemRed, { [weak self] in self?.host?.deleteImage() })
        ]
        var all = items
        if box.link != nil {
            // 卡片（v12.12.4）：拿掉「縮成小圖」。那顆的圖示看起來像「打開」，使用者按了之後卡片縮成一小塊、
            // 再點只會彈出封面的大圖，以為卡片不見、視窗打不開
            all.remove(at: 4)
            // 卡片（v12.13.0）：拿掉拷貝、剪下。貼出來的只是一張封面的圖（不是卡片、按了不會開），
            // 剪下的話原本的卡片就沒了。要再放一張：下面的「複製」，或長按白板 →「匯入現有的」
            all.remove(at: 1)
            all.remove(at: 0)
            // 卡片（v12.12.3）：改卡片下面顯示的名稱（不會改到筆記本的檔名）
            all.insert(("pencil", .white, { [weak self] in self?.host?.editCardCaption() }), at: 0)
        }
        for item in all {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: item.0), for: .normal)
            b.tintColor = item.1
            let action = item.2
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            bar.addSubview(b)
            barItems.append(b)
        }
        addSubview(bar)
        refreshLock()
    }

    private func setUpCropBar() {
        cropBar.backgroundColor = UIColor(white: 0.16, alpha: 0.96)
        cropBar.layer.cornerRadius = 22
        let items: [(String, UIColor, () -> Void)] = [
            ("取消", .white, { [weak self] in self?.endCrop(apply: false) }),
            ("完成", .systemYellow, { [weak self] in self?.endCrop(apply: true) })
        ]
        for (i, item) in items.enumerated() {
            let b = UIButton(type: .system)
            b.setTitle(item.0, for: .normal)
            b.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
            b.tintColor = item.1
            let action = item.2
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            b.frame = CGRect(x: CGFloat(i) * 80, y: 0, width: 80, height: 44)
            cropBar.addSubview(b)
        }
        cropBar.isHidden = true
        addSubview(cropBar)
    }

    /// 固定鈕的樣子；固定時框變橘色虛線、沒有控制點
    private func refreshLock() {
        let locked = box.isLocked
        lockButton.setImage(UIImage(systemName: locked ? "lock.fill" : "lock.open"), for: .normal)
        lockButton.tintColor = locked ? .systemOrange : .white
        outline.strokeColor = (locked ? UIColor.systemOrange : UIColor.systemBlue).cgColor
        outline.lineDashPattern = locked ? [6, 4] : nil
    }

    // MARK: 裁剪

    private func startCrop() {
        cropping = true
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        setNeedsLayout()
    }

    /// 結束裁剪：apply = true 就把框外面切掉（存成一張新的圖，原本的檔案留著，復原回得去）
    private func endCrop(apply: Bool) {
        let r = cropRect
        cropping = false
        defer { setNeedsLayout() }
        guard apply, r.width < 0.995 || r.height < 0.995, let pv = pageView,
              let image = Store.loadImage(box.file, pageID: pv.page.id) else { return }
        let size = CGSize(width: max(image.size.width * r.width, 1), height: max(image.size.height * r.height, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let cropped = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(at: CGPoint(x: -image.size.width * r.minX, y: -image.size.height * r.minY))
        }
        guard let file = Store.saveImage(cropped, pageID: pv.page.id) else { return }
        var changed = box
        let center = fromUnit(CGPoint(x: r.midX, y: r.midY))
        changed.width = box.width * r.width
        changed.height = box.height * r.height
        changed.x = center.x - changed.width / 2
        changed.y = center.y - changed.height / 2
        changed.file = file
        if let source = box.sourceRect {                      // 剪下來的範圍也跟著縮
            changed.sourceRect = CGRect(x: source.minX + source.width * r.minX, y: source.minY + source.height * r.minY,
                                        width: source.width * r.width, height: source.height * r.height)
        }
        box = changed
        host?.imageEdited(box, commit: true)
    }

    private func toUnit(_ p: CGPoint) -> CGPoint {
        let l = local(p)
        return CGPoint(x: min(max(l.x / max(box.width, 1) + 0.5, 0), 1), y: min(max(l.y / max(box.height, 1) + 0.5, 0), 1))
    }

    private var cropCorners: [CGPoint] {
        let r = cropRect
        return [fromUnit(CGPoint(x: r.minX, y: r.minY)), fromUnit(CGPoint(x: r.maxX, y: r.minY)),
                fromUnit(CGPoint(x: r.maxX, y: r.maxY)), fromUnit(CGPoint(x: r.minX, y: r.maxY))]
    }

    // MARK: 版面

    override func layoutSubviews() {
        super.layoutSubviews()
        if let pv = pageView { frame = pv.bounds }
        let s = max(scale, 0.0001)
        let pts = corners.map { toView($0) }
        let path = UIBezierPath()
        path.move(to: pts[0])
        for q in pts.dropFirst() { path.addLine(to: q) }
        path.close()
        let handles = UIBezierPath()
        let dots = UIBezierPath()
        if canEdit {
            for q in pts { handles.append(UIBezierPath(ovalIn: CGRect(x: q.x - 8, y: q.y - 8, width: 16, height: 16))) }
            for d in sideDots.map({ toView($0) }) { dots.append(UIBezierPath(ovalIn: CGRect(x: d.x - 6.5, y: d.y - 6.5, width: 13, height: 13))) }
        }
        let shade = UIBezierPath()
        let border = UIBezierPath()
        if cropping {
            shade.append(path)
            let c = cropCorners.map { toView($0) }
            border.move(to: c[0])
            for q in c.dropFirst() { border.addLine(to: q) }
            border.close()
            shade.append(border)
            for q in c { handles.append(UIBezierPath(ovalIn: CGRect(x: q.x - 9, y: q.y - 9, width: 18, height: 18))) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.path = path.cgPath
        handleLayer.path = handles.cgPath
        dotLayer.path = dots.cgPath
        cropShade.path = cropping ? shade.cgPath : nil
        cropBorder.path = cropping ? border.cgPath : nil
        CATransaction.commit()
        // 旋轉鈕
        rotateIcon.isHidden = !canEdit
        rotateIcon.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
        rotateIcon.center = toView(rotateHandle)
        // 工具列放在圖片下面（裁剪中換成「取消、完成」）
        let maxY = max(pts.map { $0.y }.max() ?? 0, toView(sideDots[2]).y + 8)
        let midX = pts.map { $0.x }.reduce(0, +) / 4
        let w: CGFloat = CGFloat(barItems.count) * 50
        bar.isHidden = cropping
        bar.frame = CGRect(x: midX - w / 2, y: maxY + 14, width: w, height: 44)
        for (i, b) in barItems.enumerated() {
            b.frame = CGRect(x: CGFloat(i) * 50, y: 0, width: 50, height: 44)
        }
        cropBar.isHidden = !cropping
        cropBar.frame = CGRect(x: midX - 80, y: maxY + 14, width: 160, height: 44)
        // 卡片的按鈕
        let visible = cropping ? 0 : cardButtonCount
        for (i, button) in cardButtons.enumerated() {
            button.isHidden = i >= visible
            guard i < visible else { continue }
            button.bounds = CGRect(x: 0, y: 0, width: Self.cardButtonSide, height: Self.cardButtonSide)
            button.center = toView(cardButtonCenter(i))
            bringSubviewToFront(button)
        }
        // ‹（剪下來的圖）
        sourceButton.isHidden = !hasSourceButton
        if hasSourceButton {
            let side = sourceSide
            sourceButton.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            sourceButton.layer.cornerRadius = side / 2
            sourceButton.center = toView(sourceButtonCenter)
            bringSubviewToFront(sourceButton)
        }
        // 右下角的裁剪、放大看
        toolPill.isHidden = !hasToolPill
        if hasToolPill {
            toolPill.bounds = CGRect(origin: CGPoint.zero, size: Self.pillSize)
            toolPill.center = toView(toolPillCenter)
            cropIcon.frame = CGRect(x: 4, y: 0, width: 38, height: Self.pillSize.height)
            expandIcon.frame = CGRect(x: 42, y: 0, width: 38, height: Self.pillSize.height)
            bringSubviewToFront(toolPill)
        }
        _ = s
        bringSubviewToFront(bar)
        bringSubviewToFront(cropBar)
    }

    /// 只有圖片、控制點、工具列的地方才攔觸控；其他地方照常（寫字、捲動）
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if !bar.isHidden && bar.frame.contains(point) { return true }
        if !cropBar.isHidden && cropBar.frame.contains(point) { return true }
        return modeAt(point) != Mode.idle
    }

    private func modeAt(_ v: CGPoint) -> Mode {
        let s = max(scale, 0.0001)
        let p = CGPoint(x: v.x / s, y: v.y / s)
        if cropping {
            for (i, c) in cropCorners.enumerated() where hypot((p.x - c.x) * s, (p.y - c.y) * s) < 26 { return .cropCorner(i) }
            let u = local(p)
            let r = cropRect
            let ux = u.x / max(box.width, 1) + 0.5
            let uy = u.y / max(box.height, 1) + 0.5
            if r.contains(CGPoint(x: ux, y: uy)) { return .cropMove }
            return .idle
        }
        if box.isLocked { return .idle }                 // 固定：圖片上照常寫字、捲動
        if hypot((p.x - rotateHandle.x) * s, (p.y - rotateHandle.y) * s) < 22 { return .rotate }
        for (i, d) in sideDots.enumerated() where hypot((p.x - d.x) * s, (p.y - d.y) * s) < 17 { return .link(i) }
        // 卡片的按鈕要比角先判斷（v12.13.0）：「開視窗」那一顆就在左上角旁邊
        for i in 0 ..< cardButtonCount {
            let c = cardButtonCenter(i)
            if abs((p.x - c.x) * s) <= 23 && abs((p.y - c.y) * s) <= 23 { return Self.cardModes[i] }
        }
        if hasSourceButton {
            let c = sourceButtonCenter
            if hypot((p.x - c.x) * s, (p.y - c.y) * s) <= max(sourceSide / 2 + 6, 18) { return .sourceOpen }
        }
        if hasToolPill {
            let c = toolPillCenter
            let dx = (p.x - c.x) * s
            let dy = (p.y - c.y) * s
            if abs(dx) <= Self.pillSize.width / 2 && abs(dy) <= Self.pillSize.height / 2 { return dx < 0 ? .crop : .expand }
        }
        for c in corners where hypot((p.x - c.x) * s, (p.y - c.y) * s) < 24 { return .scale }
        let l = local(p)
        let pad = 8 / s
        if abs(l.x) <= box.width / 2 + pad && abs(l.y) <= box.height / 2 + pad { return .move }
        return .idle
    }

    @objc private func handlePress(_ g: UILongPressGestureRecognizer) {
        let s = max(scale, 0.0001)
        let v = g.location(in: self)
        let p = CGPoint(x: v.x / s, y: v.y / s)
        switch g.state {
        case .began:
            mode = modeAt(v)
            startBox = box
            startPoint = p
            cropStart = cropRect
            startAngle = atan2(p.y - imageCenter.y, p.x - imageCenter.x)
            startDistance = max(hypot(p.x - imageCenter.x, p.y - imageCenter.y), 1)
            if case .link(let side) = mode { host?.imageLinkDrag(box, side: side, state: .began, at: v) }
            if mode == .scale {
                // 按到哪個角：它的對角固定不動（拉右下角時左上角不動）
                let cs = corners
                var grabbed = 0
                var best = CGFloat.greatestFiniteMagnitude
                for (i, c) in cs.enumerated() {
                    let d = hypot(p.x - c.x, p.y - c.y)
                    if d < best { best = d; grabbed = i }
                }
                fixedCorner = cs[(grabbed + 2) % 4]
                startDiagonal = CGPoint(x: cs[grabbed].x - fixedCorner.x, y: cs[grabbed].y - fixedCorner.y)
            }
        case .changed:
            let c = CGPoint(x: startBox.x + startBox.width / 2, y: startBox.y + startBox.height / 2)
            switch mode {
            case .move:
                box.x = startBox.x + p.x - startPoint.x
                box.y = startBox.y + p.y - startPoint.y
            case .scale:
                // 對角固定，等比例縮放：手指投影到對角線上，算出變成幾倍
                let minK = 20 / max(min(startBox.width, startBox.height), 1)
                let d = startDiagonal
                let lengthSquared = max(d.x * d.x + d.y * d.y, 1)
                let k = max(minK, ((p.x - fixedCorner.x) * d.x + (p.y - fixedCorner.y) * d.y) / lengthSquared)
                box.width = startBox.width * k
                box.height = startBox.height * k
                // 新的中心＝固定的角往被拖的角走一半
                let nc = CGPoint(x: fixedCorner.x + d.x * k / 2, y: fixedCorner.y + d.y * k / 2)
                box.x = nc.x - box.width / 2
                box.y = nc.y - box.height / 2
            case .rotate:
                var angle = startBox.rotation + atan2(p.y - c.y, p.x - c.x) - startAngle
                // 接近 0°、90°、180°、270° 自動對齊
                let quarter = CGFloat.pi / 2
                let nearest = (angle / quarter).rounded() * quarter
                if abs(angle - nearest) < 0.06 { angle = nearest }
                box.rotation = angle
            case .link(let side):
                host?.imageLinkDrag(box, side: side, state: .changed, at: v)
                return
            case .cropCorner(let i):
                let u = toUnit(p)
                var r = cropRect
                let minSide: CGFloat = 0.06
                if i == 0 || i == 3 { let x = min(u.x, r.maxX - minSide); r.size.width = r.maxX - x; r.origin.x = x }
                if i == 1 || i == 2 { r.size.width = max(u.x - r.minX, minSide) }
                if i == 0 || i == 1 { let y = min(u.y, r.maxY - minSide); r.size.height = r.maxY - y; r.origin.y = y }
                if i == 2 || i == 3 { r.size.height = max(u.y - r.minY, minSide) }
                cropRect = r
                setNeedsLayout()
                return
            case .cropMove:
                let a = toUnit(startPoint)
                let b = toUnit(p)
                var r = cropStart
                r.origin.x = min(max(r.minX + b.x - a.x, 0), 1 - r.width)
                r.origin.y = min(max(r.minY + b.y - a.y, 0), 1 - r.height)
                cropRect = r
                setNeedsLayout()
                return
            case .idle, .cardOpen, .cardPreview, .cardPrev, .cardNext, .sourceOpen, .crop, .expand:
                return
            }
            setNeedsLayout()
            host?.imageEdited(box, commit: false)
        case .ended, .cancelled, .failed:
            let pressed = mode
            mode = .idle
            switch pressed {
            case .link(let side):
                host?.imageLinkDrag(box, side: side, state: g.state == .ended ? .ended : .cancelled, at: v)
                return
            case .cropCorner, .cropMove:
                return
            case .sourceOpen:
                if g.state == .ended, modeAt(v) == .sourceOpen { host?.openImageSource(box) }
                return
            case .crop:
                if g.state == .ended, modeAt(v) == .crop { startCrop() }
                return
            case .expand:
                if g.state == .ended, modeAt(v) == .expand, let pv = pageView, let host = host {
                    let shown = box
                    host.endImageSelection()
                    host.showImageViewer(shown, on: pv)
                }
                return
            default:
                break
            }
            // 選取中的卡片：點標題那一條（沒有拖動）＝改卡片名稱（v12.15.0，使用者要求）
            if pressed == .move, g.state == .ended, box.link != nil,
               hypot(p.x - startPoint.x, p.y - startPoint.y) * s < 8 {
                let ly = local(p).y
                let caption = CardCover.captionHeight * box.width / CardCover.width
                if ly > box.height / 2 - caption {
                    if box != startBox { host?.imageEdited(box, commit: true) }
                    host?.editCardCaption()
                    return
                }
            }
            if let index = Self.cardModes.firstIndex(of: pressed) {
                // 卡片的按鈕：手指放開時還在同一顆上才算按到
                if g.state == .ended, modeAt(v) == pressed { host?.cardButton(index, box: box) }
                return
            }
            if pressed != .idle, box != startBox { host?.imageEdited(box, commit: true) }
        default:
            break
        }
    }
}

/// 讓頁面捲動等某個手勢先判斷（拖文字方塊時頁面不會跟著捲）
@MainActor
final class ScrollYield: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView || other is UIPinchGestureRecognizer
    }

    // 按在文字方塊的角上：只交給那個角，整個方塊不跟著拖
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let v = touch.view, v.tag == TextBoxView.handleTag, gestureRecognizer.view !== v { return false }
        if touch.view is UIControl { return false }               // 按鈕自己處理
        return true
    }
}

/// 文字方塊用的輸入框（v12.1）。
/// 從網頁、AI 的回覆選一小段拷貝時，剪貼簿裡「純文字」的那一份常常沒有條列的編號（1. 2. 3. 是畫出來的，不是字）；
/// 帶格式的那一份才有。貼上時先看帶格式的那一份有沒有條列，有的話把編號補回來再貼。
final class PasteTextView: UITextView {
    override func paste(_ sender: Any?) {
        if let text = ClipboardText.listAwareString(), !text.isEmpty {
            insertText(text)                         // 取代選取的文字，或插在游標的位置
            delegate?.textViewDidChange?(self)       // 確定文字方塊有收到（重複通知也沒關係）
            return
        }
        super.paste(sender)
    }
}

/// 把剪貼簿裡帶格式的內容（網頁、RTF）轉成純文字，保留條列的編號和符號
@MainActor
enum ClipboardText {
    /// 剪貼簿裡帶格式的那一份有條列時，回傳補回編號的文字；沒有條列（或沒有帶格式的內容）回傳 nil，照原本的方式貼
    static func listAwareString() -> String? {
        let board = UIPasteboard.general
        // 1. 網頁格式（v12.2）：自己讀 <ol>、<ul>、<li>，把編號補回來。v12.1 只靠系統轉換，實測補不回來
        for html in htmlCandidates(board) {
            if let text = HTMLListText.convert(html) { return text }
        }
        // 2. RTF：交給系統轉成文字，條列的每一行會是「（Tab）1.（Tab）內容」
        let kinds: [(String, NSAttributedString.DocumentType)] = [
            ("public.rtf", NSAttributedString.DocumentType.rtf),
            ("com.apple.flat-rtfd", NSAttributedString.DocumentType.rtfd)
        ]
        for kind in kinds {
            guard let data = board.data(forPasteboardType: kind.0), !data.isEmpty else { continue }
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            options[NSAttributedString.DocumentReadingOptionKey.documentType] = kind.1
            guard let rich = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else { continue }
            if let text = tidyLists(rich.string) { return text }
        }
        return nil
    }

    /// 剪貼簿裡的網頁內容：public.html，或網頁封存檔（從網頁畫面拷貝時會有）裡的主要內容
    static func htmlCandidates(_ board: UIPasteboard) -> [String] {
        var result: [String] = []
        if let value = board.value(forPasteboardType: "public.html") {
            if let text = value as? String {
                result.append(text)
            } else if let data = value as? Data, let text = decode(data) {
                result.append(text)
            }
        }
        if result.isEmpty, let data = board.data(forPasteboardType: "public.html"), let text = decode(data) {
            result.append(text)
        }
        let archives = ["com.apple.webarchive", "Apple Web Archive pasteboard type"]
        for type in archives {
            guard let data = board.data(forPasteboardType: type) else { continue }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { continue }
            guard let root = plist as? [String: Any], let main = root["WebMainResource"] as? [String: Any],
                  let body = main["WebResourceData"] as? Data, let text = decode(body) else { continue }
            result.append(text)
        }
        return result
    }

    private static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: String.Encoding.utf8) { return text }
        if let text = String(data: data, encoding: String.Encoding.utf16) { return text }
        return nil
    }

    /// 帶格式的文字轉出來，條列的每一行長得像「（Tab）1.（Tab）內容」。整理成「1. 內容」，巢狀的往內縮兩格。
    /// 完全沒有這種行就回傳 nil
    static func tidyLists(_ raw: String) -> String? {
        var found = false
        var lines: [String] = []
        for piece in raw.components(separatedBy: CharacterSet.newlines) {
            var tabs = 0
            var index = piece.startIndex
            while index < piece.endIndex, piece[index] == "\t" {
                tabs += 1
                index = piece.index(after: index)
            }
            if tabs > 0, let end = piece[index...].firstIndex(of: "\t") {
                let marker = String(piece[index..<end])
                if isListMarker(marker) {
                    let rest = String(piece[piece.index(after: end)...])
                    let indent = String(repeating: "  ", count: tabs - 1)
                    let mark = marker.allSatisfy({ $0.isNumber }) ? marker + "." : marker   // 只有數字：補上句點
                    lines.append(indent + mark + " " + rest)
                    found = true
                    continue
                }
            }
            lines.append(piece)
        }
        guard found else { return nil }
        return lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// 像不像條列的開頭：「1.」「12.」「3」「a)」「•」「◦」「-」這類
    private static func isListMarker(_ marker: String) -> Bool {
        if marker.isEmpty || marker.count > 6 { return false }
        if marker.hasSuffix(".") || marker.hasSuffix(")") { return true }
        if marker.allSatisfy({ $0.isNumber }) { return true }
        if marker.count == 1, let scalar = marker.unicodeScalars.first {
            return !CharacterSet.alphanumerics.contains(scalar)
        }
        return false
    }

    /// 除錯用（首頁「設定 → 剪貼簿內容」）：剪貼簿裡有哪些格式、轉出來長什麼樣子。貼上的結果不對時，截這一頁的圖就知道原因
    static func debugSummary() -> String {
        let board = UIPasteboard.general
        var out: [String] = []
        out.append("App 版本：" + appVersion)
        out.append("格式：" + board.types.joined(separator: "、"))
        let plain = board.string ?? ""
        out.append("純文字（前 150 字）：\n" + String(plain.prefix(150)))
        let htmls = htmlCandidates(board)
        out.append("網頁內容：\(htmls.count) 份")
        if let first = htmls.first {
            out.append("網頁內容（前 400 字）：\n" + String(first.prefix(400)))
        }
        if let text = listAwareString() {
            out.append("補回編號後（前 300 字）：\n" + String(text.prefix(300)))
        } else {
            out.append("補回編號：找不到條列")
        }
        return out.joined(separator: "\n\n")
    }
}

/// 很簡單的「網頁 → 純文字」（v12.2）：只為了把條列的編號補回來；粗體、連結這些格式都丟掉，只留文字和換行
enum HTMLListText {
    /// 一行一行組出文字
    private struct Builder {
        var lines: [String] = []
        var line = ""
        var markerOnly = false               // 這一行目前只有條列的編號（緊接著的段落標籤不要再換行）

        /// 把目前這一行收進去，開新的一行
        mutating func flush() {
            var text = line
            while text.hasSuffix(" ") { text.removeLast() }
            lines.append(text)
            line = ""
            markerOnly = false
        }

        /// 換行；這一行是空的、或只有編號，就不換
        mutating func newline() {
            if markerOnly || line.isEmpty { return }
            flush()
        }

        /// 段落之間空一行
        mutating func paragraph() {
            if markerOnly { return }
            newline()
            if let last = lines.last, !last.isEmpty { lines.append("") }
        }

        /// 條列的一項開始：新的一行，先放編號
        mutating func startItem(_ prefix: String) {
            if !line.isEmpty { flush() }
            line = prefix
            markerOnly = true
        }

        /// 條列的一項結束
        mutating func endItem() {
            if !line.isEmpty { flush() }
        }

        /// <br>：一定換行
        mutating func forceBreak() {
            flush()
        }

        /// 加文字。keep = true（在 <pre> 裡）：空白、換行照原樣
        mutating func add(_ text: String, keep: Bool) {
            if keep {
                let parts = text.components(separatedBy: "\n")
                for (k, part) in parts.enumerated() {
                    if k > 0 { flush() }
                    line += part
                    if !part.isEmpty { markerOnly = false }
                }
                return
            }
            var piece = ""
            var lastSpace = line.isEmpty || line.hasSuffix(" ")
            for ch in text {
                if ch.isWhitespace {
                    if !lastSpace { piece.append(" ") }
                    lastSpace = true
                } else {
                    piece.append(ch)
                    lastSpace = false
                }
            }
            if piece.isEmpty { return }
            line += piece
            if piece != " " { markerOnly = false }
        }
    }

    /// 沒有條列（<li>）就回傳 nil，照原本的方式貼
    static func convert(_ html: String) -> String? {
        guard html.lowercased().contains("<li") else { return nil }
        let chars = Array(html)
        let count = chars.count
        var builder = Builder()
        var orderedStack: [Bool] = []         // 目前在幾層條列裡；true = 有編號的（<ol>）
        var numberStack: [Int] = []           // 每一層下一項的編號
        var skip = 0                          // 在 <style>、<script>、<head>、<title> 裡：內容不要
        var pre = 0                           // 在 <pre> 裡：空白、換行照原樣
        var i = 0
        while i < count {
            if chars[i] != "<" {
                var j = i
                while j < count, chars[j] != "<" { j += 1 }
                if skip == 0 {
                    builder.add(decodeEntities(String(chars[i..<j])), keep: pre > 0)
                }
                i = j
                continue
            }
            // 註解 <!-- … -->
            if i + 3 < count, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                var j = i + 4
                while j + 2 < count, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") { j += 1 }
                i = min(j + 3, count)
                continue
            }
            var j = i + 1
            while j < count, chars[j] != ">" { j += 1 }
            if j >= count { break }
            let tag = String(chars[(i + 1)..<j]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
            i = j + 1
            var rest = Substring(tag)
            var closing = false
            if rest.hasPrefix("/") {
                closing = true
                rest = rest.dropFirst()
            }
            var name = ""
            for ch in rest {
                if ch.isLetter || ch.isNumber { name.append(ch) } else { break }
            }
            let attributes = String(rest.dropFirst(name.count))
            if name == "style" || name == "script" || name == "head" || name == "title" {
                if closing { skip = max(0, skip - 1) } else if !attributes.hasSuffix("/") { skip += 1 }
                continue
            }
            if skip > 0 { continue }
            let inList = !orderedStack.isEmpty
            switch name {
            case "br":
                builder.forceBreak()
            case "pre":
                if closing { pre = max(0, pre - 1) } else { pre += 1 }
                if inList { builder.newline() } else { builder.paragraph() }
            case "ol", "ul":
                if closing {
                    if !orderedStack.isEmpty {
                        orderedStack.removeLast()
                        numberStack.removeLast()
                    }
                    builder.newline()
                    if orderedStack.isEmpty { builder.paragraph() }
                } else {
                    if inList { builder.newline() } else { builder.paragraph() }
                    orderedStack.append(name == "ol")
                    numberStack.append(startNumber(attributes))
                }
            case "li":
                if closing {
                    builder.endItem()
                } else {
                    let depth = max(orderedStack.count, 1)
                    var prefix = String(repeating: "  ", count: depth - 1)
                    if let ordered = orderedStack.last, ordered, let number = numberStack.last {
                        prefix += "\(number). "
                        numberStack[numberStack.count - 1] = number + 1
                    } else {
                        prefix += "• "
                    }
                    builder.startItem(prefix)
                }
            case "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "table", "hr":
                if inList { builder.newline() } else { builder.paragraph() }
            case "div", "tr", "section", "article", "header", "footer", "dt", "dd":
                builder.newline()
            case "td", "th":
                if closing { builder.add("  ", keep: true) }
            default:
                break
            }
        }
        builder.flush()
        // 連續的空行併成一行，頭尾的空行拿掉
        var cleaned: [String] = []
        for text in builder.lines {
            if text.isEmpty, cleaned.last?.isEmpty ?? true { continue }
            cleaned.append(text)
        }
        while let last = cleaned.last, last.isEmpty { cleaned.removeLast() }
        let result = cleaned.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    /// <ol start="3"> 的 3；沒寫就是 1
    private static func startNumber(_ attributes: String) -> Int {
        guard let range = attributes.range(of: "start=") else { return 1 }
        var digits = ""
        for ch in attributes[range.upperBound...] {
            if ch == "\"" || ch == "'" {
                if digits.isEmpty { continue }
                break
            }
            if ch.isNumber { digits.append(ch) } else { break }
        }
        return Int(digits) ?? 1
    }

    /// &amp; &lt; &nbsp; &#8226; 這類寫法換回原本的字
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out.append(contentsOf: rest[..<amp])
            let after = rest[amp...]
            if let semi = after.firstIndex(of: ";"), after.distance(from: after.startIndex, to: semi) <= 10 {
                let name = String(after[after.index(after: after.startIndex)..<semi])
                if let decoded = entity(name) {
                    out.append(decoded)
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out.append("&")
            rest = after.dropFirst()
        }
        out.append(contentsOf: rest)
        return out
    }

    private static func entity(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default: break
        }
        var code: UInt32?
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            code = UInt32(String(name.dropFirst(2)), radix: 16)
        } else if name.hasPrefix("#") {
            code = UInt32(String(name.dropFirst()))
        }
        if let value = code, let scalar = Unicode.Scalar(value) { return String(Character(scalar)) }
        return nil
    }
}

/// 頁面上的一個文字方塊（用 UITextView 顯示；選取時可以用 Apple Pencil 直接寫字，iPad 會轉成文字）
final class TextBoxView: UIView, UITextViewDelegate {
    private(set) var box: TextBox
    let pageID: UUID
    private let pageWidth: CGFloat
    var wrapWidth: CGFloat?                          // 自動換行以多寬的頁面為準（白板用；沒設定就是頁寬）
    private var wrapPage: CGFloat { wrapWidth ?? pageWidth }
    private let pageHeight: CGFloat
    let textView = PasteTextView()                   // 貼上時會把條列的「1.」「•」補回來（v12.1）
    private let placeholder = UILabel()
    private let mathView = UIImageView()             // 數學式排好的樣子（不在編輯時）
    private var mathPending: String?                 // 正在等排版的那一份
    private var scale: CGFloat = 1
    var onChange: (() -> Void)?
    var onEditingChanged: (() -> Void)?
    // 外框樣式、連線（v12.13.0；TextLinks.swift）
    private let styleLayer = CAShapeLayer()          // 外框（填滿或只有線）
    private let bandLayer = CAShapeLayer()           // 「上面一條」
    private var dots: [UIView] = []                  // 四邊的點：0 上、1 右、2 下、3 左；往外拉＝連到另一個文字方塊
    var onLink: ((Int, UIGestureRecognizer.State, CGPoint) -> Void)?   // 哪一邊、手勢的狀態、手指在頁面視圖上的位置
    var onRelayout: (() -> Void)?                    // 位置、大小變了（連線要跟著重畫）
    var linked = false {                             // 有連線接著它：空的也留著、顯示「輸入文字」
        didSet { if linked != oldValue { refreshPlaceholder() } }
    }
    /// 外框的範圍（這個視圖自己的座標）：有樣式的比文字大一圈；沒有樣式就是文字的範圍
    private(set) var frameRect = CGRect.zero
    /// 外框的範圍（頁面座標）：連線接在它四邊的中點
    var linkRect: CGRect {
        let s = max(scale, 0.0001)
        return CGRect(x: box.x + (frameRect.minX - contentRect.minX) / s, y: box.y + (frameRect.minY - contentRect.minY) / s,
                      width: frameRect.width / s, height: frameRect.height / s)
    }

    private func refreshPlaceholder() {
        let wanted = isUserInteractionEnabled || box.fill != nil || linked
        placeholder.isHidden = !wanted || !textView.text.isEmpty
    }

    static let insetX: CGFloat = 4      // 留白（頁面座標）

    /// 自動寬度最寬到多寬（頁面座標）：整頁扣掉左右留白，跟方塊在哪裡無關
    static func maxTextWidth(pageWidth: CGFloat) -> CGFloat {
        max(pageWidth - 16 - insetX * 2, 20)
    }
    static let insetY: CGFloat = 3

    static func font(for box: TextBox, scale: CGFloat) -> UIFont {
        let size = max(box.fontSize * scale, 1)
        return box.bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
    }

    static func alignment(_ a: Int) -> NSTextAlignment {
        switch a {
        case 1: return .center
        case 2: return .right
        default: return .left
        }
    }

    init(box: TextBox, pageID: UUID, pageWidth: CGFloat, pageHeight: CGFloat) {
        self.box = box
        self.pageID = pageID
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        super.init(frame: .zero)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainer.lineFragmentPadding = 0
        textView.text = box.text
        textView.delegate = self
        textView.overrideUserInterfaceStyle = .light
        placeholder.text = "輸入文字"
        placeholder.textColor = UIColor.systemGray
        placeholder.isUserInteractionEnabled = false
        addSubview(textView)
        addSubview(placeholder)
        mathView.isUserInteractionEnabled = false
        mathView.contentMode = .scaleToFill
        mathView.isHidden = true
        addSubview(mathView)
        zoneLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.05).cgColor
        zoneLayer.strokeColor = nil
        layer.insertSublayer(zoneLayer, at: 0)
        styleLayer.lineJoin = .round
        layer.insertSublayer(styleLayer, at: 1)                    // 在字的下面
        bandLayer.strokeColor = nil
        layer.insertSublayer(bandLayer, at: 2)
        borderLayer.fillColor = nil
        borderLayer.strokeColor = UIColor.systemBlue.cgColor
        borderLayer.lineWidth = 1.5
        layer.addSublayer(borderLayer)
        setActive(false)
    }

    private let zoneLayer = CAShapeLayer()       // 輸入中：整頁淡淡上色
    static let handleTag = 777
    private var handles: [UIView] = []           // 四個角：0 左上、1 右上、2 右下、3 左下
    private var resizeStart: TextBox?
    private let handleYield = ScrollYield()
    var onResize: ((CGFloat, CGFloat) -> Void)?  // 拖角時：新的 x、新的寬度（頁面座標）

    private func makeHandles() {
        guard handles.isEmpty else { return }
        for i in 0..<4 {
            let h = UIView(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
            h.tag = Self.handleTag
            h.backgroundColor = .white
            h.layer.cornerRadius = 11
            h.layer.borderColor = UIColor.systemBlue.cgColor
            h.layer.borderWidth = 2.5
            h.isHidden = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(dragHandle(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pan.delegate = handleYield
            h.addGestureRecognizer(pan)
            h.accessibilityIdentifier = "\(i)"
            addSubview(h)
            handles.append(h)
        }
    }

    private func makeDots() {
        guard dots.isEmpty else { return }
        for i in 0 ..< 4 {
            let d = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))     // 摸得到的範圍比看到的點大
            d.tag = Self.handleTag
            d.backgroundColor = .clear
            let dot = CALayer()
            dot.frame = CGRect(x: 9.5, y: 9.5, width: 13, height: 13)
            dot.cornerRadius = 6.5
            dot.backgroundColor = UIColor(white: 0.62, alpha: 1).cgColor
            dot.borderColor = UIColor(white: 1, alpha: 0.85).cgColor
            dot.borderWidth = 1
            d.layer.addSublayer(dot)
            d.isHidden = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(dragDot(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pan.delegate = handleYield
            d.addGestureRecognizer(pan)
            d.accessibilityIdentifier = "\(i)"
            addSubview(d)
            dots.append(d)
        }
    }

    /// 從四邊的點往外拉：交給 NotebookView（畫預覽的線；放開時多一個文字方塊，或連到已經有的那一個）
    @objc private func dragDot(_ g: UIPanGestureRecognizer) {
        guard let d = g.view, let i = Int(d.accessibilityIdentifier ?? ""), let sv = superview else { return }
        onLink?(i, g.state, g.location(in: sv))
    }

    /// 拖右邊的角：右邊跟著手指（改寬度）；拖左邊的角：左邊跟著手指；字的大小不變，只改換行的位置
    @objc private func dragHandle(_ g: UIPanGestureRecognizer) {
        guard let h = g.view, let i = Int(h.accessibilityIdentifier ?? ""), let sv = superview, !box.isLocked else { return }
        let s = max(scale, 0.0001)
        switch g.state {
        case .began:
            resizeStart = box
        case .changed:
            guard let start = resizeStart else { return }
            let dx = g.translation(in: sv).x / s
            let minW: CGFloat = 16
            if i == 1 || i == 2 {
                onResize?(start.x, max(minW, min(start.width + dx, pageWidth - start.x - 8 - Self.insetX * 2)))
            } else {
                let newX = min(max(start.x + dx, 0), start.x + start.width - minW)
                onResize?(newX, start.width + (start.x - newX))
            }
        default:
            resizeStart = nil
        }
    }

    // 角在框外面一點點，也要點得到
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        if isUserInteractionEnabled, frameRect.contains(point) { return true }      // 有外框的：框比視圖大一圈
        if dots.contains(where: { !$0.isHidden && $0.frame.contains(point) }) { return true }
        return handles.contains { !$0.isHidden && $0.frame.insetBy(dx: -8, dy: -8).contains(point) }
    }
    private let borderLayer = CAShapeLayer()     // 藍框：只框住實際的文字
    /// 實際文字的範圍（這個視圖自己的座標）；輸入中整個視圖會比它大（多了書寫區）
    private(set) var contentRect = CGRect.zero

    /// 手指只用來拖曳、點選，不在文字裡放游標（沒有鍵盤，游標用不到；也才能點書寫區退出）
    private func pencilOnlyTextGestures() {
        for g in textView.gestureRecognizers ?? [] {
            g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ newBox: TextBox) {
        box = newBox
        if textView.text != newBox.text { textView.text = newBox.text }
        relayout()
    }

    func apply(scale s: CGFloat) {
        scale = s
        relayout()
    }

    /// 選取中：藍框、可以點進去編輯或用 Pencil 寫；沒選取：不攔觸控（Pencil 照常在上面畫）
    func setActive(_ on: Bool) {
        isUserInteractionEnabled = on
        refreshPlaceholder()
        pencilOnlyTextGestures()
        relayout()
    }

    private func relayout() {
        let s = max(scale, 0.0001)
        let font = Self.font(for: box, scale: s)
        textView.font = font
        textView.textColor = box.color
        textView.textAlignment = Self.alignment(box.align)
        placeholder.font = font
        // 寬度依內容自動決定；最寬是整頁的寬度（v11.30 起跟位置無關：移動時不會重新換行、越拉越長）
        let maxWidth = Self.maxTextWidth(pageWidth: wrapPage)
        let measured = ((textView.text.isEmpty ? (placeholder.text ?? "") : textView.text) as NSString)
            .boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading],
                          attributes: [.font: Self.font(for: box, scale: 1)], context: nil)
        if let fixed = box.fixedWidth {
            box.width = max(16, min(fixed, maxWidth))          // 拖過角：用拖出來的寬度換行
        } else {
            box.width = min(maxWidth, ceil(measured.width) + 2)
        }
        let ix = Self.insetX * s
        let iy = Self.insetY * s
        textView.textContainerInset = UIEdgeInsets(top: iy, left: ix, bottom: iy, right: ix)
        // 實際文字的大小
        let editing = textView.isFirstResponder
        // 數學式：不在編輯時，有排好的圖片就用圖片的大小
        var mathImage: UIImage?
        if !editing && (box.isMarkdown || MathRenderer.containsMath(textView.text)) {     // Markdown 方塊也用排好的圖（v12.9）
            let request = MathRenderer.request(for: box, pageWidth: wrapPage)
            if let image = MathRenderer.shared.cached(request) {
                mathImage = image
                if box.fixedWidth == nil { box.width = max(16, image.size.width / MathRenderer.scaleFactor) }
            } else {
                let k = MathRenderer.key(request)
                if mathPending != k {
                    mathPending = k
                    MathRenderer.shared.render(request) { [weak self] image in
                        guard let self = self, self.mathPending == k else { return }
                        self.mathPending = nil
                        if image != nil { self.relayout() }
                    }
                }
            }
        }
        let contentW = box.width * s + ix * 2
        let fit = textView.sizeThatFits(CGSize(width: contentW, height: .greatestFiniteMagnitude)).height
        var contentH = max(fit, font.lineHeight + iy * 2)
        if let image = mathImage {
            contentH = image.size.height / MathRenderer.scaleFactor * s + iy * 2
        }
        textView.textColor = mathImage == nil ? box.color : .clear
        mathView.isHidden = mathImage == nil
        mathView.image = mathImage
        if editing {
            // 輸入中：整張頁面都是書寫區，文字用留白推到方塊的位置（寫到頁面右邊才換行）。
            // 白板（v12.5）：整張白板太大，書寫區只到方塊附近（左、上多留一點，右邊到換行的寬度，往下約 900 點）
            var area = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            if wrapWidth != nil {
                let left = max(0, box.x - 60)
                let top = max(0, box.y - 160)
                let right = min(pageWidth, box.x + maxWidth + Self.insetX * 2 + 8)
                let bottom = min(pageHeight, box.y + 900)
                area = CGRect(x: left, y: top, width: max(right - left, 40), height: max(bottom - top, 40))
            }
            // v12.14.0（使用者：基本上都用鍵盤，手寫的範圍不用那麼大）：淡藍色的書寫區（Pencil 寫了會變成字、手指點了算在方塊裡的範圍）
            // 只留方塊附近一圈；文字本身的排版還是照整塊 area 算（換行的位置不變），只是這個視圖變小了。
            // Markdown 頁那一整頁的方塊照舊（整頁都是打字的地方）
            var zone = area
            if !box.isMarkdownPage {
                // v12.15.0：預設沒有手寫區（使用者基本上都用鍵盤）：範圍就是方塊本身；設定裡「文字方塊的手寫區」打開才多一圈
                let handwriting = TextDefaults.handwriting
                let near = handwriting
                    ? CGRect(x: box.x - 14, y: box.y - 14, width: contentW / s + 14 + 70, height: contentH / s + 14 + 44)
                    : CGRect(x: box.x, y: box.y, width: contentW / s, height: contentH / s)
                if !near.intersection(area).isNull, near.width > 1, near.height > 1 { zone = near.intersection(area) }
            }
            frame = CGRect(x: zone.minX * s, y: zone.minY * s, width: zone.width * s, height: zone.height * s)
            textView.textContainerInset = UIEdgeInsets(top: (box.y - area.minY) * s + iy, left: (box.x - area.minX) * s + ix,
                                                       bottom: iy, right: (8 + Self.insetX) * s)
            contentRect = CGRect(x: (box.x - zone.minX) * s, y: (box.y - zone.minY) * s, width: contentW, height: contentH)
            textView.frame = CGRect(x: (area.minX - zone.minX) * s, y: (area.minY - zone.minY) * s,
                                    width: area.width * s, height: area.height * s)
        } else {
            frame = CGRect(x: box.x * s, y: box.y * s, width: contentW, height: contentH)
            contentRect = CGRect(x: 0, y: 0, width: contentW, height: contentH)
            textView.frame = bounds
        }
        placeholder.frame = contentRect.inset(by: UIEdgeInsets(top: iy, left: ix, bottom: iy, right: ix))
        if let image = mathImage {
            let w = image.size.width / MathRenderer.scaleFactor * s
            let h = image.size.height / MathRenderer.scaleFactor * s
            mathView.frame = CGRect(x: contentRect.minX + ix, y: contentRect.minY + iy, width: w, height: h)
        }
        refreshPlaceholder()
        // 外框樣式（v12.13.0）
        let styleShape = box.shape ?? 1
        frameRect = box.fill == nil ? contentRect : TextBoxStyle.frame(content: contentRect, shape: styleShape, scale: s)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let rgb = box.fill {
            let outline = TextBoxStyle.path(frameRect, shape: styleShape, scale: s).cgPath
            let tint = TextBoxStyle.color(rgb).cgColor
            let mode = box.fillMode ?? 0
            styleLayer.path = outline
            styleLayer.fillColor = mode == 0 ? tint : nil
            styleLayer.strokeColor = mode == 0 ? nil : tint
            styleLayer.lineWidth = max(2 * s, 1)
            if mode == 1 {
                let band = CGRect(x: frameRect.minX, y: frameRect.minY, width: frameRect.width, height: TextBoxStyle.bandHeight(s))
                bandLayer.path = outline.intersection(CGPath(rect: band, transform: nil))
                bandLayer.fillColor = tint
            } else {
                bandLayer.path = nil
            }
        } else {
            styleLayer.path = nil
            bandLayer.path = nil
        }
        if isUserInteractionEnabled {
            // 選取的藍框：有外框樣式的，框在外框的外面一點
            borderLayer.path = box.fill == nil
                ? UIBezierPath(roundedRect: contentRect, cornerRadius: 4).cgPath
                : TextBoxStyle.path(frameRect.insetBy(dx: -3, dy: -3), shape: styleShape, scale: s).cgPath
        } else {
            borderLayer.path = nil
        }
        borderLayer.strokeColor = (box.isLocked ? UIColor.systemOrange : UIColor.systemBlue).cgColor   // 固定：橘色虛線
        borderLayer.lineDashPattern = box.isLocked ? [6, 4] : nil
        // 淡淡上色：表示這一塊寫的都會變成文字（沒開手寫區就不上色，只有方塊本身）
        zoneLayer.path = editing && (TextDefaults.handwriting || box.isMarkdownPage) ? UIBezierPath(rect: bounds).cgPath : nil
        CATransaction.commit()
        // 選取（沒在輸入）時才顯示四個角
        makeHandles()
        let showHandles = isUserInteractionEnabled && !editing && !box.isLocked
        let corners = [CGPoint(x: frameRect.minX, y: frameRect.minY), CGPoint(x: frameRect.maxX, y: frameRect.minY),
                       CGPoint(x: frameRect.maxX, y: frameRect.maxY), CGPoint(x: frameRect.minX, y: frameRect.maxY)]
        for (i, h) in handles.enumerated() {
            h.isHidden = !showHandles
            h.center = corners[i]
            bringSubviewToFront(h)
        }
        // 四邊的點（v12.13.0）：選取（沒在輸入）時才有；Markdown 頁那一整頁的方塊沒有
        makeDots()
        let showDots = showHandles && !box.isMarkdownPage
        let out: CGFloat = 20
        let middles = [CGPoint(x: frameRect.midX, y: frameRect.minY - out), CGPoint(x: frameRect.maxX + out, y: frameRect.midY),
                       CGPoint(x: frameRect.midX, y: frameRect.maxY + out), CGPoint(x: frameRect.minX - out, y: frameRect.midY)]
        for (i, d) in dots.enumerated() {
            d.isHidden = !showDots
            d.center = middles[i]
            bringSubviewToFront(d)
        }
        onRelayout?()
    }

    /// 在某個位置放游標（沒在輸入的話先進入輸入）
    func placeCursor(at p: CGPoint, from view: UIView) {
        if !textView.isFirstResponder { textView.becomeFirstResponder() }   // 進入輸入後版面會變，所以之後再換算位置
        let local = textView.convert(p, from: view)
        if let pos = textView.closestPosition(to: local) {
            textView.selectedTextRange = textView.textRange(from: pos, to: pos)
        }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        pencilOnlyTextGestures()
        relayout()                                  // 展開書寫區
        onEditingChanged?()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        relayout()                                  // 收起書寫區
        onEditingChanged?()
    }

    func textViewDidChange(_ tv: UITextView) {
        pencilOnlyTextGestures()                    // 手寫轉文字後系統可能又加回手指的點擊
        box.text = tv.text
        relayout()
        onChange?()
    }
}

// MARK: - 文字方塊裡的數學式（v11.28）：用 KaTeX 排好，存成圖片顯示

/// 文字方塊裡有 $…$、$$…$$、\(…\)、\[…\] 時，不在編輯中就顯示 KaTeX 排好的樣子。
/// 第一次用時從網路下載 KaTeX（存在 _App資料/KaTeX，之後離線也能用）；排好的圖片存在 _App資料/數學式快取。
/// 排版在一個看不到的網頁視圖裡做（放在畫面最底層），一次排一個，排好拍成圖片。
@MainActor
final class MathRenderer: NSObject, WKNavigationDelegate {
    static let shared = MathRenderer()
    static let katexVersion = "0.16.11"
    static let layoutRevision = "5"           // 排版方式改了就換：舊的快取圖片不再使用（4、5：v12.14.0 等字型、等畫完才拍，避開頂端的邊緣效果）
    static let webTop: CGFloat = 160          // 看不到的網頁放在離畫面頂端這麼遠的地方（避開狀態列底下的邊緣效果）
    /// 排版時放大的倍數（圖片比較清楚）：頁面上 1 點 = 網頁裡 2 px
    static let scaleFactor: CGFloat = 2

    struct Request {
        var text: String
        var width: CGFloat          // 換行寬度（頁面座標）
        var fixed: Bool             // true：寬度固定；false：最寬到 width，實際寬度照內容
        var fontSize: CGFloat
        var color: String           // CSS 顏色
        var bold: Bool
        var align: String           // left / center / right
        var markdown = false        // Markdown 排版（v12.9）
    }

    /// 這個文字方塊要不要用排好的圖片顯示：有數學式，或是 Markdown 方塊（v12.9）
    static func needsRender(_ box: TextBox) -> Bool {
        box.isMarkdown || containsMath(box.text)
    }

    /// 有沒有數學式的記號
    static func containsMath(_ text: String) -> Bool {
        text.contains("$") || text.contains("\\(") || text.contains("\\[")
    }

    /// 文字方塊要怎麼排（畫面上和匯出用同一套，排出來的圖片才會一樣）
    static func request(for box: TextBox, pageWidth: CGFloat) -> Request {
        let maxWidth = TextBoxView.maxTextWidth(pageWidth: pageWidth)
        let width = box.fixedWidth.map { max(16, min($0, maxWidth)) } ?? maxWidth
        let c = box.rgba
        let r = Int(((c.count > 0 ? c[0] : 1) * 255).rounded())
        let g = Int(((c.count > 1 ? c[1] : 1) * 255).rounded())
        let b = Int(((c.count > 2 ? c[2] : 1) * 255).rounded())
        let align = box.align == 1 ? "center" : (box.align == 2 ? "right" : "left")
        return Request(text: box.text, width: width, fixed: box.fixedWidth != nil, fontSize: box.fontSize,
                       color: "rgb(\(r),\(g),\(b))", bold: box.bold, align: align, markdown: box.isMarkdown)
    }

    static func key(_ r: Request) -> String {
        var parts = [katexVersion + "-" + layoutRevision, r.text, "\(Int(r.width * 10))", r.fixed ? "f" : "a", "\(Int(r.fontSize * 10))",
                     r.color, r.bold ? "b" : "n", r.align]
        if r.markdown { parts.append("md2") }               // Markdown 的另外存（一般的快取不受影響）；md2：v12.9.3 修好長頁空白後重排
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.joined(separator: "\u{1}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private var dir: URL { Store.systemDir.appendingPathComponent("KaTeX", isDirectory: true) }
    private var cacheDir: URL { Store.systemDir.appendingPathComponent("數學式快取", isDirectory: true) }
    private var readyMarker: URL { dir.appendingPathComponent("ok-\(Self.katexVersion)") }

    private var memory: [String: UIImage] = [:]
    private var failed: Set<String> = []
    private var waiting: [String: [(UIImage?) -> Void]] = [:]
    private var queue: [(key: String, request: Request)] = []
    private var busy = false
    private var downloading = false
    private var lastDownloadFailure: Date?
    private var webView: WKWebView?
    private var pageLoaded = false

    /// 已經排好的圖片（記憶體或磁碟）；沒有就 nil，不會開始排
    func cached(_ r: Request) -> UIImage? {
        let k = Self.key(r)
        if let image = memory[k] { return image }
        let url = cacheDir.appendingPathComponent(k + ".png")
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data, scale: UIScreen.main.scale) {
            memory[k] = image
            // 記下「最近用過」（v12.6）：清理時只刪 30 天沒用到的
            try? FileManager.default.setAttributes([FileAttributeKey.modificationDate: Date()], ofItemAtPath: url.path)
            return image
        }
        return nil
    }

    /// 清理數學式快取（v12.6）：刪掉 30 天沒用到的圖片。同一段數學式換了字級、寬度就會多存一張，不清理會越來越多。
    /// 刪掉的下次用到時會重新排版，不會影響內容
    func cleanCache() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [URLResourceKey.contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: keys) else { return }
        let limit = Date().addingTimeInterval(-30 * 24 * 3600)
        for file in files {
            let date = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? Date()
            if date < limit { try? fm.removeItem(at: file) }
        }
    }

    /// 要一張排好的圖片：有快取直接給；沒有就排隊排版，好了再呼叫 done（失敗給 nil）
    func render(_ r: Request, done: @escaping (UIImage?) -> Void) {
        if let image = cached(r) {
            done(image)
            return
        }
        let k = Self.key(r)
        if failed.contains(k) {
            done(nil)
            return
        }
        if waiting[k] != nil {
            waiting[k]?.append(done)
            return
        }
        waiting[k] = [done]
        queue.append((k, r))
        pump()
    }

    private func finish(_ k: String, _ image: UIImage?) {
        if let image = image {
            memory[k] = image
            if let data = image.pngData() {
                Store.ensureDir(cacheDir)
                try? data.write(to: cacheDir.appendingPathComponent(k + ".png"), options: .atomic)
            }
        } else {
            failed.insert(k)
        }
        let callbacks = waiting.removeValue(forKey: k) ?? []
        for c in callbacks { c(image) }
    }

    /// 全部排隊的都放棄（KaTeX 下載不了）
    private func failAll() {
        let items = queue
        queue = []
        for item in items {
            let callbacks = waiting.removeValue(forKey: item.key) ?? []
            for c in callbacks { c(nil) }
        }
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: readyMarker.path) else {
            if let t = lastDownloadFailure, Date().timeIntervalSince(t) < 30 {
                failAll()                                    // 剛下載失敗：先不重試，照原文顯示
                return
            }
            download()
            return
        }
        guard let web = ensureWebView() else {
            failAll()
            return
        }
        guard pageLoaded else { return }                     // 頁面載入好會再呼叫
        busy = true
        let item = queue.removeFirst()
        renderNow(item.key, item.request, in: web)
    }

    // MARK: 下載 KaTeX（一次）

    private static let fontNames = [
        "KaTeX_AMS-Regular", "KaTeX_Caligraphic-Bold", "KaTeX_Caligraphic-Regular", "KaTeX_Fraktur-Bold",
        "KaTeX_Fraktur-Regular", "KaTeX_Main-Bold", "KaTeX_Main-BoldItalic", "KaTeX_Main-Italic",
        "KaTeX_Main-Regular", "KaTeX_Math-BoldItalic", "KaTeX_Math-Italic", "KaTeX_SansSerif-Bold",
        "KaTeX_SansSerif-Italic", "KaTeX_SansSerif-Regular", "KaTeX_Script-Regular", "KaTeX_Size1-Regular",
        "KaTeX_Size2-Regular", "KaTeX_Size3-Regular", "KaTeX_Size4-Regular", "KaTeX_Typewriter-Regular"
    ]

    private func download() {
        guard !downloading else { return }
        downloading = true
        let base = "https://cdn.jsdelivr.net/npm/katex@\(Self.katexVersion)/dist/"
        var files: [(remote: String, local: String)] = [
            ("katex.min.js", "katex.min.js"),
            ("katex.min.css", "katex.min.css"),
            ("contrib/auto-render.min.js", "auto-render.min.js")
        ]
        for name in Self.fontNames { files.append(("fonts/\(name).woff2", "fonts/\(name).woff2")) }
        let target = dir
        let marker = readyMarker
        Task { @MainActor in
            var ok = true
            Store.ensureDir(target.appendingPathComponent("fonts", isDirectory: true))
            for file in files {
                guard let url = URL(string: base + file.remote) else { ok = false; break }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 { ok = false; break }
                    try data.write(to: target.appendingPathComponent(file.local), options: .atomic)
                } catch {
                    ok = false
                    break
                }
            }
            if ok {
                try? Data("ok".utf8).write(to: marker)
            } else {
                self.lastDownloadFailure = Date()
            }
            self.downloading = false
            if ok { self.pump() } else { self.failAll() }
        }
    }

    /// Markdown 轉成 HTML（v12.9，自己寫的小轉換器，不用下載）：標題、粗體、斜體、刪除線、行內程式碼、程式碼區塊、
    /// 條列（可以縮排成好幾層、待辦 [ ] [x]）、引用、分隔線、表格、連結（只顯示文字）。數學式先保護起來，最後交給 KaTeX
    static let markdownJS = #"""
    function mdEsc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
    function mdInline(t){
      t = mdEsc(t);
      t = t.replace(/`([^`]+)`/g,'<code>$1</code>');
      t = t.replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>').replace(/__([^_]+)__/g,'<strong>$1</strong>');
      t = t.replace(/\*([^*\s][^*]*)\*/g,'<em>$1</em>');
      t = t.replace(/~~([^~]+)~~/g,'<del>$1</del>');
      t = t.replace(/==([^=]+)==/g,'<mark>$1</mark>');
      t = t.replace(/!\[([^\]]*)\]\(([^)]+)\)/g,'[$1]');
      t = t.replace(/\[([^\]]+)\]\(([^)]+)\)/g,'<u>$1</u>');
      t = t.replace(/\[\[([^\]|]+)(\|([^\]]+))?\]\]/g,function(m,a,b,c){return '<u>'+(c||a)+'</u>';});
      return t;
    }
    var mdBlockStart = /^(#{1,6}\s|```|\s*>|\s*([-*+]|\d+[.)])\s+|\s*(-{3,}|\*{3,}|_{3,})\s*$|\|)/;
    function mdList(lines,i){
      var html='', stack=[];
      while(i<lines.length){
        var m=lines[i].match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
        if(!m){
          if(stack.length && lines[i].trim()!=='' && /^\s{2,}/.test(lines[i])){ html+='<br>'+mdInline(lines[i].trim()); i++; continue; }
          break;
        }
        var ind=m[1].replace(/\t/g,'    ').length, type=/\d/.test(m[2])?'ol':'ul';
        while(stack.length && ind < stack[stack.length-1].ind){ html+='</li></'+stack.pop().type+'>'; }
        if(!stack.length || ind > stack[stack.length-1].ind){
          var start=''; if(type==='ol'){ var n=parseInt(m[2]); if(n!==1){ start=' start="'+n+'"'; } }
          html+='<'+type+start+'>'; stack.push({ind:ind,type:type});
        } else { html+='</li>'; }
        var t=m[3], task=t.match(/^\[([ xX])\]\s+(.*)$/);
        if(task){ t=(task[1]===' '?'☐ ':'☑ ')+task[2]; }
        html+='<li>'+mdInline(t); i++;
      }
      while(stack.length){ html+='</li></'+stack.pop().type+'>'; }
      return [html,i];
    }
    function mdTable(lines,i){
      function cells(l){ l=l.trim().replace(/^\|/,'').replace(/\|$/,''); return l.split('|').map(function(c){return c.trim();}); }
      var head=cells(lines[i]); i+=2;
      var html='<table><tr>'+head.map(function(c){return '<th>'+mdInline(c)+'</th>';}).join('')+'</tr>';
      while(i<lines.length && /^\s*\|/.test(lines[i])){
        html+='<tr>'+cells(lines[i]).map(function(c){return '<td>'+mdInline(c)+'</td>';}).join('')+'</tr>'; i++;
      }
      return [html+'</table>',i];
    }
    function mdBlocks(src){
      var lines=src.split('\n'), out=[], i=0;
      while(i<lines.length){
        var l=lines[i];
        if(/^```/.test(l)){ var code=[]; i++; while(i<lines.length && !/^```/.test(lines[i])){ code.push(mdEsc(lines[i])); i++; } i++;
          out.push('<pre><code>'+code.join('\n')+'</code></pre>'); continue; }
        var h=l.match(/^(#{1,6})\s+(.*)$/);
        if(h){ out.push('<h'+h[1].length+'>'+mdInline(h[2])+'</h'+h[1].length+'>'); i++; continue; }
        if(/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(l)){ out.push('<hr>'); i++; continue; }
        if(/^\s*>/.test(l)){ var q=[]; while(i<lines.length && /^\s*>/.test(lines[i])){ q.push(lines[i].replace(/^\s*>\s?/,'')); i++; }
          out.push('<blockquote>'+mdBlocks(q.join('\n'))+'</blockquote>'); continue; }
        if(/^\s*([-*+]|\d+[.)])\s+/.test(l)){ var r=mdList(lines,i); out.push(r[0]); i=r[1]; continue; }
        if(/^\s*\|/.test(l) && i+1<lines.length && /^\s*\|?\s*:?-{3,}/.test(lines[i+1])){ var t=mdTable(lines,i); out.push(t[0]); i=t[1]; continue; }
        if(l.trim()===''){ i++; continue; }
        var p=[]; while(i<lines.length && lines[i].trim()!=='' && (p.length===0 || !mdBlockStart.test(lines[i]))){ p.push(mdInline(lines[i])); i++; }
        out.push('<p>'+p.join('<br>')+'</p>');
      }
      return out.join('');
    }
    function mdToHtml(src){
      var math=[];
      src = src.replace(/\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\]|\\\([\s\S]+?\\\)|\$[^$\n]+?\$/g, function(m){ math.push(m); return '\u0001'+(math.length-1)+'\u0001'; });
      var html = mdBlocks(src);
      return html.replace(/\u0001(\d+)\u0001/g, function(m,n){ return mdEsc(math[parseInt(n)]); });
    }
    """#

    // MARK: 排版

    private static let shellHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="katex.min.css">
    <script src="katex.min.js"></script>
    <script src="auto-render.min.js"></script>
    <style>
    html, body { margin: 0; padding: 0; background: transparent; }
    #box { white-space: pre-wrap; overflow-wrap: break-word; line-height: 1.55;
           font-family: -apple-system, "PingFang TC", sans-serif; }
    .katex { font-size: 1.1em; }
    .katex-display { margin: 0.55em 0; }
    .katex-html:has(> .tag) { padding-right: 2.6em; }
    #box.md { white-space: normal; line-height: 1.5; }
    #box.md > :first-child { margin-top: 0; }
    #box.md > :last-child { margin-bottom: 0; }
    #box.md h1 { font-size: 1.7em; margin: 0.5em 0 0.3em; }
    #box.md h2 { font-size: 1.4em; margin: 0.5em 0 0.3em; }
    #box.md h3 { font-size: 1.2em; margin: 0.45em 0 0.25em; }
    #box.md h4, #box.md h5, #box.md h6 { font-size: 1.05em; margin: 0.4em 0 0.2em; }
    #box.md p { margin: 0.35em 0; }
    #box.md ul, #box.md ol { margin: 0.3em 0; padding-left: 1.5em; }
    #box.md li { margin: 0.12em 0; }
    #box.md blockquote { margin: 0.4em 0; padding-left: 0.8em; border-left: 3px solid currentColor; opacity: 0.8; }
    #box.md code { font-family: Menlo, monospace; font-size: 0.9em; background: rgba(127,127,127,0.22); padding: 0 0.25em; border-radius: 4px; }
    #box.md pre { background: rgba(127,127,127,0.16); padding: 0.5em 0.7em; border-radius: 6px; white-space: pre-wrap; }
    #box.md pre code { background: none; padding: 0; }
    #box.md hr { border: none; border-top: 1px solid currentColor; opacity: 0.4; margin: 0.6em 0; }
    #box.md table { border-collapse: collapse; margin: 0.4em 0; }
    #box.md th, #box.md td { border: 1px solid rgba(127,127,127,0.6); padding: 0.2em 0.55em; }
    #box.md mark { background: rgba(255,214,10,0.45); color: inherit; }
    </style></head><body><div id="box"></div>
    <script>
    async function renderBox(text, width, fixed, size, color, bold, align, md) {
      var b = document.getElementById('box');
      if (fixed) { b.style.display = 'block'; b.style.width = width + 'px'; b.style.maxWidth = ''; }
      else { b.style.display = 'inline-block'; b.style.width = 'auto'; b.style.maxWidth = width + 'px'; }
      b.style.fontSize = size + 'px';
      b.style.color = color;
      b.style.fontWeight = bold ? 'bold' : 'normal';
      b.style.textAlign = align;
      if (md) { b.className = 'md'; b.innerHTML = mdToHtml(text); }
      else { b.className = ''; b.textContent = text; }
      renderMathInElement(b, {
        delimiters: [
          {left: '$$', right: '$$', display: true},
          {left: '\\\\[', right: '\\\\]', display: true},
          {left: '$', right: '$', display: false},
          {left: '\\\\(', right: '\\\\)', display: false}
        ],
        throwOnError: false,
        macros: {'\\\\arraystretch': '1.35'}
      });
      // v12.14.0：先排一次版（這時候網頁才知道要哪些字型、開始載入），等字型都到了，再等兩個畫面更新才量、才拍。
      // 以前直接等 fonts.ready：字型還沒開始載入就算「好了」，拍到的式子少了斜體的字母（E、A、q…）；
      // 第一行的大標題上面也會多一條黑色、殘留的舊內容（網頁還沒畫完就拍）
      b.getBoundingClientRect();
      await document.fonts.ready;
      await new Promise(function(done) { requestAnimationFrame(function() { requestAnimationFrame(done); }); });
      var r = b.getBoundingClientRect();
      return [Math.ceil(r.width), Math.ceil(r.height)];
    }
    </script></body></html>
    """

    private func ensureWebView() -> WKWebView? {
        if let web = webView, web.window != nil { return web }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return nil }
        let web = webView ?? {
            let config = WKWebViewConfiguration()
            let w = WKWebView(frame: CGRect(x: 0, y: Self.webTop, width: 1200, height: 1600), configuration: config)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.scrollView.backgroundColor = .clear
            w.scrollView.isScrollEnabled = false
            w.scrollView.contentInsetAdjustmentBehavior = .never   // 不要因為狀態列往下推（v11.28 排好的式子被切掉下半）
            w.insetsLayoutMarginsFromSafeArea = false
            w.scrollView.topEdgeEffect.isHidden = true          // iPadOS 26 的頂端邊緣效果（見 renderNow）
            w.scrollView.bottomEdgeEffect.isHidden = true
            w.isUserInteractionEnabled = false
            w.navigationDelegate = self
            return w
        }()
        window.insertSubview(web, at: 0)                 // 最底層：被 App 畫面蓋住，看不到
        if webView == nil {
            webView = web
            let html = dir.appendingPathComponent("render.html")
            // Markdown 的轉換器（v12.9）放進同一頁
            let page = Self.shellHTML.replacingOccurrences(of: "</body>", with: "<script>" + Self.markdownJS + "</script></body>")
            try? Data(page.utf8).write(to: html, options: .atomic)
            pageLoaded = false
            web.loadFileURL(html, allowingReadAccessTo: dir)
        }
        return web
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.pageLoaded = true
            self.pump()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.failAll() }
    }

    private func renderNow(_ k: String, _ r: Request, in web: WKWebView) {
        let f = Self.scaleFactor
        let layoutWidth = r.width * f
        // v12.14.0：網頁不要放在畫面最上面（狀態列底下）。iPadOS 26 會在捲動畫面的頂端加一層模糊、變暗的邊緣效果，
        // 拍出來第一行（Markdown 的大標題）上面就多一條黑色、糊掉的字
        web.frame = CGRect(x: 0, y: Self.webTop, width: layoutWidth + 40, height: 3000)
        web.scrollView.contentInset = .zero
        web.scrollView.contentOffset = .zero
        let args: [String: Any] = [
            "text": r.text, "width": Double(layoutWidth), "fixed": r.fixed,
            "size": Double(r.fontSize * f), "color": r.color, "bold": r.bold, "align": r.align, "md": r.markdown
        ]
        web.callAsyncJavaScript("return await renderBox(text, width, fixed, size, color, bold, align, md);",
                                arguments: args, in: nil, in: .page) { result in
            // 先在這裡把結果換成數字，再回到主執行緒處理
            var w: Double = 0
            var h: Double = 0
            if case .success(let value) = result, let dims = value as? [Any], dims.count == 2 {
                w = (dims[0] as? NSNumber)?.doubleValue ?? 0
                h = (dims[1] as? NSNumber)?.doubleValue ?? 0
            }
            let width = w
            let height = h
            Task { @MainActor in
                self.snapshot(k, web: web, width: width, height: height)
            }
        }
    }

    private func snapshot(_ k: String, web: WKWebView, width w: Double, height h: Double) {
        guard w > 0, h > 0 else {
            finish(k, nil)
            busy = false
            pump()
            return
        }
        // v12.9.3 修正：排出來比網頁的高度（3000）還高時，超出的部分截不到，整張變空白（長的 Markdown 頁）
        let needHeight = CGFloat(h) + 20
        if web.frame.height < needHeight { web.frame.size.height = needHeight }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: w, height: h)
        config.afterScreenUpdates = true
        web.takeSnapshot(with: config) { image, _ in
            Task { @MainActor in
                self.finish(k, image)
                self.busy = false
                self.pump()
            }
        }
    }
}

/// 文字方塊下面的工具列：移動、顏色、大小、粗體、對齊、複製、刪除
final class TextBar: UIView {
    private weak var host: NotebookView?
    private var items: [UIView] = []
    private let sizeLabel = UILabel()
    private let colorButton = UIButton(type: .system)
    private let boldButton = UIButton(type: .system)
    private let alignButton = UIButton(type: .system)
    private let lockButton = UIButton(type: .system)
    private let markdownButton = UIButton(type: .system)     // Markdown 排版（v12.9）
    let styleButton = UIButton(type: .system)                // 卡片樣式（v12.13.0）

    init(host: NotebookView) {
        self.host = host
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.16, alpha: 0.96)
        layer.cornerRadius = 22

        // 把手：按住拖曳移動文字方塊
        let move = UIImageView(image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right"))
        move.tintColor = .white
        move.contentMode = .center
        move.isUserInteractionEnabled = true
        move.addGestureRecognizer(UIPanGestureRecognizer(target: host, action: #selector(NotebookView.textMovePan(_:))))
        items.append(move)

        let colors: [(String, UIColor)] = [
            ("白", .white), ("黑", .black),
            ("紅", UIColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 1)),
            ("藍", UIColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1)),
            ("黃", .systemYellow), ("綠", .systemGreen)
        ]
        colorButton.menu = UIMenu(title: "顏色", children: colors.map { item in
            let swatch = UIImage(systemName: "circle.fill")?.withTintColor(item.1, renderingMode: .alwaysOriginal)
            return UIAction(title: item.0, image: swatch) { [weak host] _ in host?.setTextColor(item.1) }
        })
        colorButton.showsMenuAsPrimaryAction = true
        items.append(colorButton)

        items.append(button("textformat.size.smaller") { [weak host] in host?.changeTextSize(-2) })
        sizeLabel.textColor = .white
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        sizeLabel.textAlignment = .center
        items.append(sizeLabel)
        items.append(button("textformat.size.larger") { [weak host] in host?.changeTextSize(2) })

        boldButton.addAction(UIAction { [weak host] _ in host?.toggleTextBold() }, for: .touchUpInside)
        boldButton.setImage(UIImage(systemName: "bold"), for: .normal)
        items.append(boldButton)
        alignButton.addAction(UIAction { [weak host] _ in host?.cycleTextAlign() }, for: .touchUpInside)
        items.append(alignButton)
        markdownButton.addAction(UIAction { [weak host] _ in host?.toggleTextMarkdown() }, for: .touchUpInside)
        markdownButton.setImage(UIImage(systemName: "doc.richtext"), for: .normal)
        items.append(markdownButton)                               // Markdown 排版開關（v12.9）
        styleButton.addAction(UIAction { [weak host] _ in host?.showTextStyle() }, for: .touchUpInside)
        styleButton.setImage(UIImage(systemName: "paintpalette"), for: .normal)
        items.append(styleButton)                                  // 卡片樣式：外框的顏色、形狀（v12.13.0）

        // 分隔線：前面是文字樣式，後面是剪下、拷貝、複製、刪除
        let divider = UIView()
        divider.backgroundColor = UIColor(white: 1, alpha: 0.3)
        divider.tag = 900
        items.append(divider)

        lockButton.addAction(UIAction { [weak host] _ in host?.toggleTextLock() }, for: .touchUpInside)
        items.append(lockButton)                                   // 固定：不能拖動、拉寬度
        items.append(button("scissors") { [weak host] in host?.cutText() })
        items.append(button("doc.on.doc") { [weak host] in host?.copyText() })
        items.append(button("plus.square.on.square") { [weak host] in host?.duplicateText() })
        let delete = button("trash") { [weak host] in host?.deleteText() }
        delete.tintColor = .systemRed
        items.append(delete)

        // 完成：輸入中 → 選取；選取 → 結束
        let done = button("checkmark.circle.fill") { [weak host] in host?.finishTextStep() }
        done.tintColor = .systemGreen
        items.append(done)

        for item in items { addSubview(item) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func button(_ symbol: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.tintColor = .white
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    /// 依目前文字方塊的樣式更新按鈕（size：以 A4 為準的字級）
    func refresh(_ box: TextBox, size: Int) {
        sizeLabel.text = "\(size)"
        boldButton.tintColor = box.bold ? .systemYellow : .white
        markdownButton.tintColor = box.isMarkdown ? .systemYellow : .white
        styleButton.tintColor = box.fill != nil ? .systemYellow : .white
        let alignSymbol = ["text.alignleft", "text.aligncenter", "text.alignright"][min(max(box.align, 0), 2)]
        alignButton.setImage(UIImage(systemName: alignSymbol), for: .normal)
        alignButton.tintColor = .white
        lockButton.setImage(UIImage(systemName: box.isLocked ? "lock.fill" : "lock.open"), for: .normal)
        lockButton.tintColor = box.isLocked ? .systemOrange : .white
        let size = CGSize(width: 24, height: 24)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let circle = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5))
            box.color.setFill()
            circle.fill()
            UIColor(white: 0.85, alpha: 1).setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
        }
        colorButton.setImage(image.withRenderingMode(.alwaysOriginal), for: .normal)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let dividers = items.filter { $0.tag == 900 }.count
        let gap: CGFloat = 12
        let w = (bounds.width - CGFloat(dividers) * gap) / CGFloat(max(items.count - dividers, 1))
        var x: CGFloat = 0
        for item in items {
            if item.tag == 900 {
                item.frame = CGRect(x: x + gap / 2 - 0.5, y: 10, width: 1, height: bounds.height - 20)
                x += gap
            } else {
                item.frame = CGRect(x: x, y: 0, width: w, height: bounds.height)
                x += w
            }
        }
    }
}
