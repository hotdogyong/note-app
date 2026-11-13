import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// BoardMarks.swift：白板的圖釘、區塊（資料、畫面上的樣子、右上角的清單）（v12.7）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

/// 圖釘：記住白板上的一個位置和當時的縮放，點了就跳過去
struct BoardPin: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var x: CGFloat                    // 頁面座標
    var y: CGFloat
    var percent: CGFloat = 1          // 放的時候是幾 %（1 = 100%）
    var hidden: Bool? = nil           // 在白板上藏起來（清單裡還在）
    var group: String? = nil          // 分組的名稱；nil = 不分組
    var color: Int? = nil             // PinStyle.palette 的第幾個（v12.8；舊的圖釘沒有：藍色）
    var symbol: String? = nil         // PinStyle.symbols 裡的一個（v12.8；舊的圖釘沒有：星星）
    var pageID: UUID? = nil           // 筆記本的圖釘（v12.9）：釘在哪一頁（x、y 是那一頁的座標，percent 存當時的 zoom）；白板的是 nil

    var isHidden: Bool { hidden ?? false }
    var colorIndex: Int { color ?? 0 }
    var symbolName: String { symbol ?? "star.fill" }
}

/// 圖釘的顏色、符號（v12.8，照 GUGA 的樣子：水滴形、白邊、中間一個白色符號）
@MainActor
enum PinStyle {
    static let palette: [Int] = [0x4B63F5, 0xF5C84B, 0xEE6B4A, 0xF3BFC2, 0x8A97EE,
                                 0xE5A66A, 0xE8CE63, 0xA6CF8A, 0x000000, 0x808080]
    /// SF Symbols 的名稱；一兩個字的（數字）直接寫字
    static let symbols: [String] = ["star.fill", "heart.fill", "pin.fill", "flame.fill", "tag.fill",
                                    "flag.fill", "paperclip", "number", "plus", "xmark",
                                    "checkmark", "exclamationmark", "questionmark", "lightbulb.fill", "book.fill",
                                    "bookmark.fill", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

    static func uiColor(_ index: Int) -> UIColor {
        let hex = palette[min(max(index, 0), palette.count - 1)]
        return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func isText(_ symbol: String) -> Bool { symbol.count <= 2 }

    /// 名稱的字色：黑色、灰色的圖釘在深色白板上看不清楚，名稱改用淺灰
    static func labelColor(_ index: Int) -> UIColor {
        index >= 8 ? UIColor(white: 0.82, alpha: 1) : uiColor(index)
    }

    /// 水滴形：上面是圓，下面收成尖端（尖端在 rect 的下緣中間）
    static func dropPath(in rect: CGRect) -> UIBezierPath {
        let r = rect.width / 2
        let c = CGPoint(x: rect.midX, y: rect.minY + r)
        let d = max(rect.maxY - c.y, r + 1)
        let beta = acos(r / d)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addArc(withCenter: c, radius: r, startAngle: CGFloat.pi / 2 + beta,
                    endAngle: CGFloat.pi / 2 - beta + 2 * CGFloat.pi, clockwise: true)
        path.close()
        return path
    }

    /// 右上角圖釘清單的按鈕（v12.8.2，照 GUGA：實心水滴、中間挖空一顆星）。單色，顏色跟其他工具列按鈕一樣
    static let toolbarIcon: UIImage = {
        let size = CGSize(width: 19, height: 24)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            dropPath(in: CGRect(origin: CGPoint.zero, size: size).insetBy(dx: 0.5, dy: 0.5)).fill()
            let config = UIImage.SymbolConfiguration(pointSize: 9, weight: .black)
            if let star = UIImage(systemName: "star.fill", withConfiguration: config) {
                let k = 10 / max(star.size.width, star.size.height, 1)
                let w = star.size.width * k
                let h = star.size.height * k
                let c = CGPoint(x: size.width / 2, y: size.width / 2)
                star.draw(in: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), blendMode: .destinationOut, alpha: 1)
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()

    /// 圖釘的圖示（清單、編輯畫面用）
    static func image(color: Int, symbol: String, width: CGFloat) -> UIImage {
        let marker = PinMarkerView(frame: CGRect(x: 0, y: 0, width: width, height: width * 1.26))
        marker.configure(color: color, symbol: symbol)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: marker.bounds.size, format: format).image { ctx in
            marker.layer.render(in: ctx.cgContext)
        }
    }
}

/// 一個水滴形的圖釘圖示：顏色填滿、白邊、中間白色符號
final class PinMarkerView: UIView {
    private let shape = CAShapeLayer()
    private let icon = UIImageView()
    private let text = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        shape.strokeColor = UIColor.white.cgColor
        shape.lineWidth = 2.5
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.35
        shape.shadowRadius = 3
        shape.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(shape)
        icon.tintColor = UIColor.white
        icon.contentMode = .scaleAspectFit
        addSubview(icon)
        text.textColor = UIColor.white
        text.textAlignment = .center
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(color: Int, symbol: String) {
        shape.fillColor = PinStyle.uiColor(color).cgColor
        if PinStyle.isText(symbol) {
            icon.isHidden = true
            text.isHidden = false
            text.text = symbol
        } else {
            icon.isHidden = false
            text.isHidden = true
            icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(weight: .bold))
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = bounds.insetBy(dx: 1.5, dy: 1.5)
        shape.frame = bounds
        shape.path = PinStyle.dropPath(in: inner).cgPath
        shape.shadowPath = shape.path
        let r = inner.width / 2
        let side = r * 1.0
        let c = CGPoint(x: inner.midX, y: inner.minY + r)
        icon.frame = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        text.font = UIFont.systemFont(ofSize: r * 1.15, weight: .heavy)
        text.frame = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    }
}

/// 區塊（像 FigJam 的 Section）：白板上一個有名字、有顏色的方框，拖標題時裡面的東西一起移動
struct BoardFrame: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var x: CGFloat                    // 頁面座標
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var color = 0                     // BoardFrame.palette 的第幾個
    var locked: Bool? = nil           // 鎖定：不能拖、改大小、刪除（v12.8.3）
    var stash: FrameStash? = nil      // 收合時，裡面的東西收在這裡（v12.8.3）；nil = 展開

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isLocked: Bool { locked ?? false }
    var isCollapsed: Bool { stash != nil }

    static let palette: [(name: String, hex: Int)] = [
        ("藍", 0x4A90E2), ("橘", 0xF0A23B), ("綠", 0x5DBB63), ("紫", 0x9B6BD6), ("紅", 0xE5534B), ("灰", 0x9AA0A6)
    ]

    static func uiColor(_ index: Int) -> UIColor {
        let i = min(max(index, 0), palette.count - 1)
        return uiColorHex(palette[i].hex)
    }

    private static func uiColorHex(_ hex: Int) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 區塊收合時收起來的東西（v12.8.3）：筆跡、圖片、文字方塊、裡面的小區塊、圖釘。
/// 記下收合時區塊的左上角，展開時區塊被搬過的話，東西跟著平移
struct FrameStash: Codable, Hashable {
    var originX: CGFloat
    var originY: CGFloat
    var drawing: Data                 // PKDrawing 的資料
    var images: [ImageBox] = []
    var texts: [TextBox] = []
    var frames: [BoardFrame] = []
    var pins: [BoardPin] = []
}

/// 白板上會收觸控的記號（圖釘、區塊標題、區塊的角）：筆記本畫面的手勢（點一下、長按、套索）遇到它們就讓開
class BoardMarkView: UIView {}

/// 一開始先問一下要不要接這次觸控的長按（v12.8.2）：按下去的位置不對就直接放棄，不會擋到別的手勢
final class GatedLongPress: UILongPressGestureRecognizer {
    var gate: ((CGPoint) -> Bool)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if let check = gate, let touch = touches.first, !check(touch.location(in: view)) {
            state = .failed
        }
    }
}

/// 區塊的底（在筆跡下面）：淡淡的顏色加邊框
final class BoardFrameBodyView: UIView {
    var selected = false { didSet { refresh() } }
    var colorIndex = 0 { didSet { refresh() } }
    var collapsed = false { didSet { if collapsed != oldValue { refresh() } } }
    private let dash = CAShapeLayer()                   // 收合時：虛線框（裡面的東西收起來了）

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 10
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        let c = BoardFrame.uiColor(colorIndex)
        if collapsed {
            backgroundColor = c.withAlphaComponent(0.04)
            layer.borderWidth = 0
            dash.isHidden = false
            dash.strokeColor = c.withAlphaComponent(selected ? 0.95 : 0.6).cgColor
            dash.lineWidth = selected ? 2.5 : 1.5
        } else {
            backgroundColor = c.withAlphaComponent(0.10)
            layer.borderColor = c.withAlphaComponent(selected ? 0.95 : 0.55).cgColor
            layer.borderWidth = selected ? 2.5 : 1.5
            dash.isHidden = true
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if dash.superlayer == nil {
            dash.fillColor = nil
            dash.lineDashPattern = [8, 6]
            layer.addSublayer(dash)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dash.frame = bounds
        dash.path = UIBezierPath(roundedRect: bounds, cornerRadius: 10).cgPath
        CATransaction.commit()
    }
}

/// 區塊的標題（在筆跡上面，大小固定不隨縮放）：點一下選取，按住拖可以把整個區塊連內容一起移動
final class BoardFrameTitleView: BoardMarkView {
    let frameID: UUID
    weak var host: NotebookView?
    private let label = UILabel()
    private let yield = ScrollYield()

    init(frameID: UUID) {
        self.frameID = frameID
        super.init(frame: .zero)
        layer.cornerRadius = 8
        label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        label.textColor = UIColor.white
        addSubview(label)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.minimumPressDuration = 0.18
        drag.allowableMovement = CGFloat.greatestFiniteMagnitude
        drag.delegate = yield
        addGestureRecognizer(drag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, color: Int, locked: Bool = false, collapsed: Bool = false) {
        // 收合：前面一個「▸」；鎖定：後面一個鎖頭（v12.8.3）
        let text = NSMutableAttributedString()
        let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        func symbol(_ name: String) {
            let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            if let image = UIImage(systemName: name, withConfiguration: config)?.withTintColor(UIColor.white, renderingMode: .alwaysOriginal) {
                text.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            }
        }
        if collapsed {
            symbol("chevron.right")
            text.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        text.append(NSAttributedString(string: name.isEmpty ? "區塊" : name, attributes: [.font: font, .foregroundColor: UIColor.white]))
        if locked {
            text.append(NSAttributedString(string: " ", attributes: [.font: font]))
            symbol("lock.fill")
        }
        label.attributedText = text
        backgroundColor = BoardFrame.uiColor(color).withAlphaComponent(collapsed ? 0.7 : 0.92)
    }

    /// 標題的大小（畫面上的點）
    func fittingWidth(max limit: CGFloat) -> CGFloat {
        let w = label.intrinsicContentSize.width + 20
        return min(max(w, 50), max(limit, 50))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 10, dy: 0)
    }

    @objc private func tapped() {
        host?.selectFrame(frameID)
    }

    @objc private func dragged(_ g: UILongPressGestureRecognizer) {
        host?.frameTitleDragged(frameID, gesture: g)
    }
}

/// 區塊選取時右下角的把手：拖它調整區塊的大小（裡面的東西不動）
final class BoardFrameHandleView: BoardMarkView {
    let frameID: UUID
    weak var host: NotebookView?
    private let yield = ScrollYield()

    init(frameID: UUID) {
        self.frameID = frameID
        super.init(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        let dot = UIView(frame: CGRect(x: 6, y: 6, width: 18, height: 18))
        dot.backgroundColor = UIColor.white
        dot.layer.cornerRadius = 9
        dot.layer.borderColor = UIColor.systemBlue.cgColor
        dot.layer.borderWidth = 2.5
        dot.isUserInteractionEnabled = false
        addSubview(dot)
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.minimumPressDuration = 0
        drag.allowableMovement = CGFloat.greatestFiniteMagnitude
        drag.delegate = yield
        addGestureRecognizer(drag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func dragged(_ g: UILongPressGestureRecognizer) {
        host?.frameHandleDragged(frameID, gesture: g)
    }
}

/// 圖釘（大小固定不隨縮放；v12.8 改成 GUGA 的樣子）：水滴形的圖示加同色的名稱，尖端在釘的位置。
/// 點一下：上面出現黑色的小工具列（編輯、分組、藏起來、刪除）；按住拖：移動
final class BoardPinView: BoardMarkView {
    static let size = CGSize(width: 140, height: 66)
    static let markerSize = CGSize(width: 34, height: 43)
    let pinID: UUID
    weak var host: NotebookView?
    private let marker = PinMarkerView(frame: CGRect(x: (140 - 34) / 2, y: 0, width: 34, height: 43))
    private let label = UILabel()
    private let yield = ScrollYield()

    init(pinID: UUID) {
        self.pinID = pinID
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        addSubview(marker)
        label.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        label.textAlignment = .center
        label.frame = CGRect(x: 0, y: 45, width: Self.size.width, height: 19)
        label.shadowColor = UIColor(white: 0, alpha: 0.35)
        label.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(label)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.minimumPressDuration = 0.15                   // v12.9.8：0.3 → 0.15
        drag.allowableMovement = CGFloat.greatestFiniteMagnitude
        drag.delegate = yield
        addGestureRecognizer(drag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ pin: BoardPin) {
        marker.configure(color: pin.colorIndex, symbol: pin.symbolName)
        label.text = pin.name
        label.textColor = PinStyle.labelColor(pin.colorIndex)
    }

    /// 尖端放在 p（頁面視圖的座標）
    func place(tip p: CGPoint) {
        frame = CGRect(x: p.x - Self.size.width / 2, y: p.y - Self.markerSize.height, width: Self.size.width,
                       height: Self.size.height)
    }

    // 只有圖示和名稱的地方收觸控，旁邊的空白照常寫字
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if marker.frame.insetBy(dx: -8, dy: -6).contains(point) { return true }
        let w = min(label.intrinsicContentSize.width + 8, bounds.width)
        return CGRect(x: (bounds.width - w) / 2, y: label.frame.minY, width: w, height: label.frame.height).contains(point)
    }

    @objc private func tapped() {
        host?.pinTapped(pinID)
    }

    @objc private func dragged(_ g: UILongPressGestureRecognizer) {
        host?.pinDragged(pinID, gesture: g)
    }
}

/// 新增、編輯圖釘的卡片（v12.8，照 GUGA）：名稱、顏色、符號
struct PinEditorView: View {
    let isNew: Bool
    @State var pin: BoardPin
    let cancel: () -> Void
    let done: (BoardPin) -> Void
    @FocusState private var nameFocused: Bool

    private let colorColumns = Array(repeating: GridItem(.fixed(44), spacing: 12), count: 6)
    private let symbolColumns = Array(repeating: GridItem(.fixed(52), spacing: 14), count: 5)

    var body: some View {
        VStack(spacing: 14) {
            Text(isNew ? "新增圖釘" : "編輯圖釘")
                .font(.headline)
                .padding(.top, 18)
            nameField
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("顏色")
                        .font(.subheadline.weight(.semibold))
                    colorGrid
                    Text("符號")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 6)
                    symbolGrid
                }
                .padding(.horizontal, 20)
            }
            buttons
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: UIColor.systemGroupedBackground).ignoresSafeArea())
    }

    private var nameField: some View {
        HStack(spacing: 10) {
            Image(uiImage: PinStyle.image(color: pin.colorIndex, symbol: pin.symbolName, width: 24))
            TextField("名稱", text: $pin.name)
                .focused($nameFocused)
                .submitLabel(.done)
            if !pin.name.isEmpty {
                Button {
                    pin.name = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(uiColor: UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 20)
    }

    private var colorGrid: some View {
        LazyVGrid(columns: colorColumns, alignment: .leading, spacing: 12) {
            ForEach(0..<PinStyle.palette.count, id: \.self) { (i: Int) in
                colorCell(i)
            }
        }
        .padding(14)
        .background(Color(uiColor: UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func colorCell(_ i: Int) -> some View {
        let on = pin.colorIndex == i
        return Button {
            pin.color = i
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(uiColor: PinStyle.uiColor(i)))
                .frame(width: 34, height: 34)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary, lineWidth: on ? 2.5 : 0))
        }
        .buttonStyle(.plain)
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: symbolColumns, alignment: .leading, spacing: 14) {
            ForEach(PinStyle.symbols, id: \.self) { (name: String) in
                symbolCell(name)
            }
        }
        .padding(14)
        .background(Color(uiColor: UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func symbolCell(_ name: String) -> some View {
        let on = pin.symbolName == name
        return Button {
            pin.symbol = name
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(uiColor: UIColor.tertiarySystemFill))
                if PinStyle.isText(name) {
                    Text(name)
                        .font(.system(size: 22, weight: .heavy))
                } else {
                    Image(systemName: name)
                        .font(.system(size: 21, weight: .bold))
                }
            }
            .foregroundStyle(Color.primary)
            .frame(width: 50, height: 50)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary, lineWidth: on ? 2.5 : 0))
        }
        .buttonStyle(.plain)
    }

    private var buttons: some View {
        HStack(spacing: 14) {
            Button {
                cancel()
            } label: {
                Text("取消")
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color(uiColor: UIColor.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            Button {
                var result = pin
                let name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
                result.name = name.isEmpty ? "圖釘" : name
                done(result)
            } label: {
                Text(isNew ? "新增" : "完成")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(uiColor: UIColor.systemBackground))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}

/// 打開圖釘的卡片（從最上層的畫面跳出來；上一個彈出的東西還在收的話，等它收完）
@MainActor
enum PinEditor {
    static func show(pin: BoardPin, isNew: Bool, done: @escaping (BoardPin) -> Void) {
        weak var controller: UIViewController?
        let view = PinEditorView(isNew: isNew, pin: pin, cancel: {
            controller?.dismiss(animated: true)
        }, done: { result in
            controller?.dismiss(animated: true)
            done(result)
        })
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .formSheet
        host.preferredContentSize = CGSize(width: 420, height: 600)
        controller = host
        Presenter.present(host)
    }
}

/// 從最上層的畫面跳出一個視窗；如果有東西正在收起來（例如剛關掉的清單），等一下再試（v12.8）
@MainActor
enum Presenter {
    static func present(_ vc: UIViewController, tries: Int = 0) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = (scene.windows.first { $0.isKeyWindow } ?? scene.windows.first)?.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        if top.isBeingDismissed || top.presentedViewController != nil || top.transitionCoordinator != nil {
            if tries < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { present(vc, tries: tries + 1) }
            }
            return
        }
        top.present(vc, animated: true)
    }
}

struct PinListView: View {
    @ObservedObject var model: NotebookModel
    let close: () -> Void

    private var pins: [BoardPin] { model.notebook.pins ?? [] }
    private var groups: [String] { model.notebook.pinGroups ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    TextPrompt.show(title: "新增圖釘分組", initial: "") { text in
                        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { model.documentView?.addPinGroup(name) }
                    }
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.title3)
                }
                Spacer()
                Text("圖釘")
                    .font(.headline)
                Spacer()
                Button {
                    close()
                    // 等清單收好再跳出圖釘的卡片（不然卡片會跟著清單一起被關掉）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.documentView?.addPinAtCenter() }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                }
            }
            .padding(14)
            Divider()
            if pins.isEmpty {
                Text("還沒有圖釘。長按空白處 → 圖釘，或按這裡右上角的 ＋（釘在畫面中間）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                List {
                    pinSection(nil, title: groups.isEmpty ? nil : "不分組")
                    ForEach(groups, id: \.self) { (group: String) in
                        pinSection(group, title: group)
                    }
                }
                .listStyle(.insetGrouped)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 340, height: 460, alignment: .top)        // v12.8：以前內容少時會置中，上面空一大塊
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private func pinSection(_ group: String?, title: String?) -> some View {
        let members = pins.filter { $0.group == group }
        if !members.isEmpty || group != nil {
            Section {
                ForEach(members) { (pin: BoardPin) in
                    pinRow(pin)
                }
            } header: {
                if let title = title { Text(title) }
            }
        }
    }

    private func pinRow(_ pin: BoardPin) -> some View {
        HStack(spacing: 10) {
            Image(uiImage: PinStyle.image(color: pin.colorIndex, symbol: pin.symbolName, width: 20))
            Button {
                close()
                model.documentView?.jumpToPin(pin.id)
            } label: {
                Text(pin.name)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button {
                model.documentView?.setPinHidden(pin.id, !pin.isHidden)
            } label: {
                Image(systemName: pin.isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button {
                close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.documentView?.editPin(pin.id) }
            } label: {
                Label("編輯（名稱、顏色、符號）", systemImage: "pencil")
            }
            Menu {
                Button("不分組") { model.documentView?.movePin(pin.id, toGroup: nil) }
                ForEach(groups, id: \.self) { (group: String) in
                    Button(group) { model.documentView?.movePin(pin.id, toGroup: group) }
                }
            } label: {
                Label("移到分組", systemImage: "folder")
            }
            Button(role: .destructive) {
                model.documentView?.deletePin(pin.id)
            } label: {
                Label("刪除", systemImage: "trash")
            }
        }
    }
}

/// 區塊清單：點名稱跳過去（整個區塊放進畫面）；區塊裡的區塊往內縮
struct FrameListView: View {
    @ObservedObject var model: NotebookModel
    let close: () -> Void
    @State private var editMode = EditMode.inactive

    private var frames: [BoardFrame] { model.notebook.frames ?? [] }

    /// 被別的區塊整個包住的，算它的子區塊（往內縮一層）
    private func depth(_ f: BoardFrame) -> Int {
        frames.contains { $0.id != f.id && $0.rect.contains(f.rect) } ? 1 : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if frames.isEmpty {
                Text("還沒有區塊。按這裡右上角的 ＋，再用 Pencil 拉一個方框；或用套索選一堆東西，按選取框上的虛線方框。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                List {
                    ForEach(frames) { (f: BoardFrame) in
                        row(f)
                    }
                    .onMove { source, destination in
                        model.documentView?.moveFrames(from: source, to: destination)
                    }
                }
                .listStyle(.plain)
                .environment(\.editMode, $editMode)
                Text("清單的順序＝依序看、匯出所有區塊的順序")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 340, height: 460, alignment: .top)        // v12.8：以前內容少時會置中，上面空一大塊
        .presentationCompactAdaptation(.popover)
    }

    /// 上面一排（v12.8.3）：排順序、依序看、匯出所有區塊、新增
    private var header: some View {
        HStack(spacing: 18) {
            Button {
                withAnimation { editMode = editMode == .active ? .inactive : .active }
            } label: {
                Text(editMode == .active ? "完成" : "排序")
            }
            .disabled(frames.count < 2)
            Menu {
                Button {
                    model.documentView?.sortFramesByPosition()
                } label: {
                    Label("照位置排（由上到下、由左到右）", systemImage: "arrow.down.right")
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .disabled(frames.count < 2)
            Spacer()
            Text("區塊")
                .font(.headline)
            Spacer()
            Button {
                close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.documentView?.startFrameTour(at: 0) }
            } label: {
                Image(systemName: "play.rectangle")
            }
            .disabled(frames.isEmpty)
            Button {
                close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.documentView?.exportAllFrames() }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(frames.isEmpty)
            Button {
                close()
                model.documentView?.startFrameMode()
            } label: {
                Image(systemName: "plus")
            }
        }
        .font(.title3)
        .padding(14)
    }

    private func row(_ f: BoardFrame) -> some View {
        Button {
            close()
            model.documentView?.jumpToFrame(f.id)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: BoardFrame.uiColor(f.color)))
                    .frame(width: 16, height: 16)
                Text(f.name.isEmpty ? "區塊" : f.name)
                    .foregroundStyle(.primary)
                Spacer()
                if f.isCollapsed {
                    Image(systemName: "rectangle.compress.vertical")
                        .foregroundStyle(.secondary)
                }
                if f.isLocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                }
            }
            .padding(.leading, CGFloat(depth(f)) * 22)
        }
    }
}
