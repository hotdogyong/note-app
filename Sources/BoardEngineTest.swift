import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// BoardEngineTest.swift：新白板引擎的測試版（v12.8.8，實驗用，不會存檔）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）
//
// 為什麼要測：現在的白板是「自己的捲動畫面＋一張跟白板一樣大的頁面＋只蓋住畫面附近的 PencilKit 畫布」，
// 縮放要自己算、放手後整個重排，所以一直卡。網路上大螢幕白板的做法（例如 InfiniteCanvas 用 1,000,000 × 1,000,000 的畫布）
// 是讓 PKCanvasView 自己當捲動畫面、用它內建的雙指縮放：PencilKit 只畫看得到的那一塊，縮放由系統處理，很順。
// 這個測試版就是這樣做：白板大小跟真的白板一樣（橫式 100 × 100 張 A4），底下墊格線和 30 張假圖片，看在你的 iPad 上順不順。
// 順的話，下一步就把真的白板換成這個做法（圖片、文字、區塊、圖釘再一個一個搬過來）。

struct BoardEngineTestView: View {
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            BoardEngineTestRepresentable()
                .ignoresSafeArea()
            HStack(spacing: 14) {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                }
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 1, height: 22)
                Text("新白板引擎（測試，不會存檔）")
                    .font(.system(size: 17, weight: .semibold))
            }
            .font(.system(size: 19, weight: .semibold))
            .padding(.horizontal, 18)
            .frame(height: 46)
            .modifier(GlassCapsule())
            .padding(.leading, 20)
            .padding(.top, 8)
        }
    }
}

struct BoardEngineTestRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> BoardEngineTestHost {
        BoardEngineTestHost()
    }

    func updateUIView(_ uiView: BoardEngineTestHost, context: Context) {}

    static func dismantleUIView(_ uiView: BoardEngineTestHost, coordinator: ()) {
        uiView.canvas.toolPicker.setVisible(false, forFirstResponder: uiView.canvas)
        uiView.canvas.resignFirstResponder()
    }
}

/// 外框（v12.8.9）：底色、格線（只跟畫面一樣大，照縮放和捲動位置畫）、畫布、左下角的百分比。
/// v12.8.8 的格線跟整張白板一樣大（幾千條線、每條幾萬點長），iPad 的畫面系統吃不消，整台當掉回到鎖定畫面
final class BoardEngineTestHost: UIView {
    let canvas = BoardEngineTestCanvas()
    let grid = GridView()
    let percentLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.19, alpha: 1)
        grid.paper = PaperStyle(pattern: 2, color: 0)
        grid.pageWidth = referencePageWidth
        grid.isUserInteractionEnabled = false
        addSubview(grid)
        addSubview(canvas)
        percentLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        percentLabel.textAlignment = .center
        percentLabel.backgroundColor = UIColor(white: 0.1, alpha: 0.8)
        percentLabel.textColor = UIColor.white
        percentLabel.layer.cornerRadius = 20
        percentLabel.clipsToBounds = true
        addSubview(percentLabel)
        canvas.host = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        percentLabel.frame = CGRect(x: 20, y: bounds.height - 80, width: 90, height: 40)
        syncGrid()
    }

    /// 格線只蓋住畫面（多一格），起點對齊白板上的格子
    func syncGrid() {
        let z = canvas.zoomScale
        let step = PaperRenderer.gridUnit * z
        guard step > 0.5, bounds.width > 0 else { return }
        let o = canvas.contentOffset
        let x0 = -(o.x.truncatingRemainder(dividingBy: step)) - step
        let y0 = -(o.y.truncatingRemainder(dividingBy: step)) - step
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grid.stepScale = z
        grid.frame = CGRect(x: x0, y: y0, width: bounds.width + 2 * step, height: bounds.height + 2 * step)
        CATransaction.commit()
        percentLabel.text = "\(Int((z / max(canvas.zoom100, 0.0001) * 100).rounded()))%"
    }
}

/// PKCanvasView 自己就是捲動畫面：手指捲動、雙指縮放都是系統做的
final class BoardEngineTestCanvas: PKCanvasView, PKCanvasViewDelegate {
    static let boardSize = CGSize(width: 100 * 842, height: 100 * 595)
    let toolPicker = PKToolPicker()
    weak var host: BoardEngineTestHost?
    private let under = UIView()                       // 筆跡底下：假圖片（跟著縮放）
    private var placed = false

    /// 白板的 100%：一張 A4 的寬剛好放滿畫面（跟現在的白板一樣）
    var zoom100: CGFloat { max(0.05, (bounds.width - 48) / referencePageWidth) }

    init() {
        super.init(frame: .zero)
        delegate = self
        drawingPolicy = .pencilOnly
        backgroundColor = UIColor.clear                    // 透明：底下那一層（格線、圖片）才看得到
        isOpaque = false
        overrideUserInterfaceStyle = .light
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        // 底下那一層：大小＝整張白板（頁面座標），縮放時跟著放大縮小
        under.layer.anchorPoint = CGPoint.zero
        under.bounds = CGRect(origin: CGPoint.zero, size: Self.boardSize)
        under.layer.position = CGPoint.zero
        under.isUserInteractionEnabled = false
        addSampleImages()
        insertSubview(under, at: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 30 張假圖片（模擬貼了很多圖片的白板）
    private func addSampleImages() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for i in 0..<30 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: format).image { ctx in
                UIColor(hue: CGFloat(i) / 30, saturation: 0.45, brightness: 0.85, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
                let text = "測試圖片 \(i + 1)" as NSString
                text.draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 80),
                                                                   .foregroundColor: UIColor.black])
            }
            let view = UIImageView(image: image)
            let cx = Self.boardSize.width / 2 + CGFloat((i % 6) - 3) * 900
            let cy = Self.boardSize.height / 2 + CGFloat((i / 6) - 2) * 700
            view.frame = CGRect(x: cx, y: cy, width: 600, height: 450)
            under.addSubview(view)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, !placed else { return }
        placed = true
        // 縮放範圍跟現在的白板一樣：5%～200%
        minimumZoomScale = zoom100 * 0.05
        maximumZoomScale = zoom100 * 2
        zoomScale = zoom100
        contentSize = CGSize(width: Self.boardSize.width * zoomScale, height: Self.boardSize.height * zoomScale)
        // 一開始在白板的正中間
        contentOffset = CGPoint(x: contentSize.width / 2 - bounds.width / 2, y: contentSize.height / 2 - bounds.height / 2)
        syncUnder()
        becomeFirstResponder()
        toolPicker.addObserver(self)
        toolPicker.setVisible(true, forFirstResponder: self)
    }

    /// 底下那一層跟著縮放（只是改一個 transform，GPU 做，不重畫）；格線（在外框）跟著捲動、縮放
    private func syncUnder() {
        under.transform = CGAffineTransform(scaleX: zoomScale, y: zoomScale)
        host?.syncGrid()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        syncUnder()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        host?.syncGrid()
    }
}
