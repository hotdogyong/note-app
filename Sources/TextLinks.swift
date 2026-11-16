import SwiftUI
import UIKit

// TextLinks.swift：文字方塊的外框樣式、方塊之間的連線（v12.13.0，照 GUGA；使用者給了截圖）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）
//
// 外框樣式：TextBox.fill（顏色；nil＝沒有樣式）、fillMode（0 整個填滿、1 外框＋上面一條、2 只有外框）、shape（0 方、1 圓角、2 圓頭）。
//   選取文字方塊 → 下面工具列的調色盤 →「卡片樣式」面板；可以「存成預設」（之後新的文字方塊都用它）、「套用預設」、「清除」。
// 連線：選取文字方塊時四邊各有一個灰色的點；從點往外拉，放開的地方會多一個文字方塊，中間一條直角轉彎、有箭頭的線。
//   拉到另一個已經有的文字方塊上：直接連過去。資料在 NotePage.links；方塊搬動、改大小時線自己跟著。
//   刪掉其中一個方塊，線就不畫了（復原方塊，線會回來）。目前不能單獨選取、刪除一條線。

/// 兩個文字方塊之間的連線
struct BoxLink: Codable, Hashable, Identifiable {
    var id = UUID()
    var from: UUID
    var fromSide: Int          // 從哪一邊出來：0 上、1 右、2 下、3 左
    var to: UUID
    var toSide: Int            // 接到哪一邊
    // 線的樣子（v12.14.0；點一下線 → 跳出的小工具列可以改）。都是 nil＝預設：灰色、實線、粗細 2、箭頭在尾端、直角轉彎
    var rgb: [Double]? = nil
    var dash: Bool? = nil
    var width: Double? = nil
    var arrow: Int? = nil      // 0 尾端有箭頭、1 沒有箭頭、2 兩端都有
    var route: Int? = nil      // 0 直角轉彎、1 直線、2 曲線
}

/// 存成預設的文字方塊樣式（存在 UserDefaults；名稱是 textDefault 開頭，會跟著設定備份）
struct TextStyleDefault: Codable, Equatable {
    var fill: [Double]?
    var fillMode: Int?
    var shape: Int?

    static let key = "textDefaultStyle"

    static func load() -> TextStyleDefault? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TextStyleDefault.self, from: data)
    }

    static func save(_ style: TextStyleDefault?) {
        if let style = style, style.fill != nil, let data = try? JSONEncoder().encode(style) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

enum TextBoxStyle {
    /// 面板上的 12 個顏色（第一個是「無」）
    static let palette: [[Double]?] = [
        nil, [0.05, 0.05, 0.05], [1, 1, 1], [0.5, 0.5, 0.5],
        [0.96, 0.76, 0.76], [0.27, 0.33, 0.83], [0.94, 0.44, 0.29], [0.97, 0.78, 0.31],
        [0.90, 0.65, 0.42], [0.92, 0.83, 0.42], [0.68, 0.82, 0.53], [0.53, 0.58, 0.95]
    ]
    /// 從點拉出來的新方塊，來源沒有樣式時用這個（淡紫藍的圓角外框，照 GUGA）
    static let linkedFill: [Double] = [0.53, 0.58, 0.95]

    /// 外框比文字多出去多少（頁面座標）
    static let padX: CGFloat = 8
    static let padY: CGFloat = 5

    static func color(_ rgb: [Double]) -> UIColor {
        UIColor(red: rgb.count > 0 ? rgb[0] : 0.5, green: rgb.count > 1 ? rgb[1] : 0.5,
                blue: rgb.count > 2 ? rgb[2] : 0.5, alpha: 1)
    }

    /// 外框的範圍：文字的範圍往外多一圈（圓頭的左右再多留一點，字才不會頂到圓弧）
    static func frame(content: CGRect, shape: Int, scale: CGFloat) -> CGRect {
        let extra = shape == 2 ? content.height * 0.28 : 0
        return content.insetBy(dx: -padX * scale - extra, dy: -padY * scale)
    }

    /// 文字的顏色跟填滿的顏色太接近（白底白字）時，換成看得到的黑或白；其他情況不動
    static func readable(text: [Double], fill: [Double]?, mode: Int?) -> [Double] {
        guard let fill = fill, (mode ?? 0) == 0 else { return text }
        func light(_ c: [Double]) -> Double {
            0.299 * (c.count > 0 ? c[0] : 0) + 0.587 * (c.count > 1 ? c[1] : 0) + 0.114 * (c.count > 2 ? c[2] : 0)
        }
        if abs(light(fill) - light(text)) >= 0.3 { return text }
        return light(fill) > 0.55 ? [0.08, 0.08, 0.08, 1] : [1, 1, 1, 1]
    }

    static func path(_ rect: CGRect, shape: Int, scale: CGFloat) -> UIBezierPath {
        switch shape {
        case 0: return UIBezierPath(rect: rect)
        case 2: return UIBezierPath(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2)
        default: return UIBezierPath(roundedRect: rect, cornerRadius: 9 * scale)
        }
    }

    /// 「上面一條」的高度
    static func bandHeight(_ scale: CGFloat) -> CGFloat { 7 * scale }

    /// 直接畫出來（匯出 PDF、縮圖用）。rect：外框的範圍
    static func draw(_ box: TextBox, rect: CGRect, scale: CGFloat) {
        guard let rgb = box.fill, let ctx = UIGraphicsGetCurrentContext() else { return }
        let shape = path(rect, shape: box.shape ?? 1, scale: scale)
        let tint = color(rgb)
        switch box.fillMode ?? 0 {
        case 0:
            tint.setFill()
            shape.fill()
        case 1:
            ctx.saveGState()
            shape.addClip()
            tint.setFill()
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bandHeight(scale)))
            ctx.restoreGState()
            tint.setStroke()
            shape.lineWidth = 2 * scale
            shape.stroke()
        default:
            tint.setStroke()
            shape.lineWidth = 2 * scale
            shape.stroke()
        }
    }
}

enum BoxLinkPath {
    /// 某一邊的中點
    static func anchor(_ rect: CGRect, side: Int) -> CGPoint {
        switch side {
        case 0: return CGPoint(x: rect.midX, y: rect.minY)
        case 1: return CGPoint(x: rect.maxX, y: rect.midY)
        case 2: return CGPoint(x: rect.midX, y: rect.maxY)
        default: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// 那一邊朝外的方向
    static func normal(_ side: Int) -> CGPoint {
        switch side {
        case 0: return CGPoint(x: 0, y: -1)
        case 1: return CGPoint(x: 1, y: 0)
        case 2: return CGPoint(x: 0, y: 1)
        default: return CGPoint(x: -1, y: 0)
        }
    }

    /// 從 start（fromSide 那一邊的中點）拉到 p：線要接到新方塊的哪一邊。
    /// 往前拉（順著出來的方向）：接對面那一邊；往旁邊、往回拉：接上面或下面（左邊或右邊）
    static func arrivalSide(from start: CGPoint, fromSide: Int, to p: CGPoint) -> Int {
        let n = normal(fromSide)
        let dx = p.x - start.x
        let dy = p.y - start.y
        let ahead = dx * n.x + dy * n.y
        if fromSide == 1 || fromSide == 3 {
            if ahead > 30 { return (fromSide + 2) % 4 }
            return dy >= 0 ? 0 : 2
        }
        if ahead > 30 { return (fromSide + 2) % 4 }
        return dx >= 0 ? 3 : 1
    }

    /// rect 的四邊裡，中點離 p 最近的那一邊
    static func nearestSide(_ rect: CGRect, to p: CGPoint) -> Int {
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for side in 0 ..< 4 {
            let a = anchor(rect, side: side)
            let d = hypot(a.x - p.x, a.y - p.y)
            if d < bestDistance {
                bestDistance = d
                best = side
            }
        }
        return best
    }

    static func color(_ link: BoxLink) -> UIColor {
        guard let rgb = link.rgb else { return UIColor(white: 0.62, alpha: 1) }
        return TextBoxStyle.color(rgb)
    }

    /// 兩個方塊互相面對的那兩邊（一鍵整理用）：左右隔得比較開就接左右邊，上下隔得比較開就接上下邊
    static func facingSides(_ a: CGRect, _ b: CGRect) -> (Int, Int) {
        let gapX = max(b.minX - a.maxX, a.minX - b.maxX)
        let gapY = max(b.minY - a.maxY, a.minY - b.maxY)
        let dx = b.midX - a.midX
        let dy = b.midY - a.midY
        let horizontal = (gapX > 0 || gapY > 0) ? gapX >= gapY : abs(dx) >= abs(dy)
        if horizontal { return dx >= 0 ? (1, 3) : (3, 1) }
        return dy >= 0 ? (2, 0) : (0, 2)
    }

    /// 箭頭：尖端在 tip，指向 d（單位向量）
    private static func addArrow(to path: CGMutablePath, tip: CGPoint, direction d: CGPoint, scale: CGFloat) {
        let size = 9 * scale
        let back = CGPoint(x: -d.x * size, y: -d.y * size)
        let side = CGPoint(x: -d.y * size * 0.6, y: d.x * size * 0.6)
        path.move(to: CGPoint(x: tip.x + back.x + side.x, y: tip.y + back.y + side.y))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x + back.x - side.x, y: tip.y + back.y - side.y))
    }

    /// 一條連線：從 a（fromSide 那一邊）到 b（toSide 那一邊）。
    /// route：0 直角轉彎（轉角是圓的）、1 直線、2 曲線；arrow：0 b 那一頭有箭頭、1 沒有、2 兩頭都有
    static func path(from a: CGPoint, fromSide: Int, to b: CGPoint, toSide: Int, scale: CGFloat,
                     route: Int = 0, arrow: Int = 0) -> CGPath {
        let na = normal(fromSide)
        let nb = normal(toSide)
        let whole = CGMutablePath()
        var endDirection = CGPoint(x: -nb.x, y: -nb.y)
        var startDirection = CGPoint(x: -na.x, y: -na.y)
        if route == 1 {
            whole.move(to: a)
            whole.addLine(to: b)
            let length = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            endDirection = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
            startDirection = CGPoint(x: -endDirection.x, y: -endDirection.y)
        } else if route == 2 {
            let reach = max(40 * scale, hypot(b.x - a.x, b.y - a.y) * 0.4)
            whole.move(to: a)
            whole.addCurve(to: b, control1: CGPoint(x: a.x + na.x * reach, y: a.y + na.y * reach),
                           control2: CGPoint(x: b.x + nb.x * reach, y: b.y + nb.y * reach))
        } else {
            whole.addPath(elbow(from: a, fromSide: fromSide, to: b, toSide: toSide, scale: scale))
        }
        if arrow != 1 { addArrow(to: whole, tip: b, direction: endDirection, scale: scale) }
        if arrow == 2 { addArrow(to: whole, tip: a, direction: startDirection, scale: scale) }
        return whole
    }

    /// 直角轉彎的線（不含箭頭）
    private static func elbow(from a: CGPoint, fromSide: Int, to b: CGPoint, toSide: Int, scale: CGFloat) -> CGPath {
        let lead = 16 * scale
        let na = normal(fromSide)
        let nb = normal(toSide)
        let p1 = CGPoint(x: a.x + na.x * lead, y: a.y + na.y * lead)
        let q = CGPoint(x: b.x + nb.x * lead, y: b.y + nb.y * lead)
        var points: [CGPoint] = [a, p1]
        let aHorizontal = na.x != 0
        let bHorizontal = nb.x != 0
        if aHorizontal && bHorizontal && na.x == nb.x {
            // 兩頭都從同一側出來（v12.15.2：心智圖裡同一欄上下兩個）：往外繞成ㄈ字形，不要穿過中間
            let x = na.x < 0 ? min(p1.x, q.x) : max(p1.x, q.x)
            points.append(CGPoint(x: x, y: p1.y))
            points.append(CGPoint(x: x, y: q.y))
        } else if aHorizontal && bHorizontal {
            if (q.x - p1.x) * na.x >= 0 && na.x != nb.x {
                let midX = (p1.x + q.x) / 2
                points.append(CGPoint(x: midX, y: p1.y))
                points.append(CGPoint(x: midX, y: q.y))
            } else {
                let midY = (p1.y + q.y) / 2
                points.append(CGPoint(x: p1.x, y: midY))
                points.append(CGPoint(x: q.x, y: midY))
            }
        } else if !aHorizontal && !bHorizontal {
            if (q.y - p1.y) * na.y >= 0 && na.y != nb.y {
                let midY = (p1.y + q.y) / 2
                points.append(CGPoint(x: p1.x, y: midY))
                points.append(CGPoint(x: q.x, y: midY))
            } else {
                let midX = (p1.x + q.x) / 2
                points.append(CGPoint(x: midX, y: p1.y))
                points.append(CGPoint(x: midX, y: q.y))
            }
        } else if aHorizontal {
            points.append(CGPoint(x: q.x, y: p1.y))
        } else {
            points.append(CGPoint(x: p1.x, y: q.y))
        }
        points.append(q)
        points.append(b)
        // 拿掉重複的點、同一條線上中間的點
        var clean: [CGPoint] = []
        for p in points {
            if let last = clean.last, hypot(last.x - p.x, last.y - p.y) < 0.5 { continue }
            if clean.count >= 2 {
                let p0 = clean[clean.count - 2]
                let p1 = clean[clean.count - 1]
                let cross = (p1.x - p0.x) * (p.y - p1.y) - (p1.y - p0.y) * (p.x - p1.x)
                let dot = (p1.x - p0.x) * (p.x - p1.x) + (p1.y - p0.y) * (p.y - p1.y)
                if abs(cross) < 0.5 && dot >= 0 { clean.removeLast() }
            }
            clean.append(p)
        }
        let path = CGMutablePath()
        guard clean.count >= 2 else { return path }
        path.move(to: clean[0])
        let radius = 10 * scale
        for i in 1 ..< clean.count - 1 {
            let before = hypot(clean[i].x - clean[i - 1].x, clean[i].y - clean[i - 1].y)
            let after = hypot(clean[i + 1].x - clean[i].x, clean[i + 1].y - clean[i].y)
            path.addArc(tangent1End: clean[i], tangent2End: clean[i + 1], radius: min(radius, before / 2, after / 2))
        }
        path.addLine(to: clean[clean.count - 1])
        return path
    }
}

/// 點一下連線跳出來的小工具列（v12.14.0）：顏色、粗細和虛實、箭頭、走法、刪除
final class LinkBar: UIView {
    private weak var host: NotebookView?
    private var items: [UIButton] = []
    static let size = CGSize(width: 260, height: 44)

    init(host: NotebookView) {
        self.host = host
        super.init(frame: CGRect(origin: CGPoint.zero, size: Self.size))
        backgroundColor = UIColor(white: 0.16, alpha: 0.96)
        layer.cornerRadius = 22

        let colors: [(String, [Double]?)] = [
            ("預設（灰）", nil), ("白", [1, 1, 1]), ("黑", [0.05, 0.05, 0.05]), ("紅", [1.0, 0.45, 0.45]),
            ("橘", [0.94, 0.44, 0.29]), ("黃", [0.97, 0.78, 0.31]), ("綠", [0.68, 0.82, 0.53]),
            ("藍", [0.45, 0.72, 1.0]), ("紫", [0.53, 0.58, 0.95])
        ]
        add("circle.fill", UIMenu(title: "線的顏色", children: colors.map { item in
            let tint = item.1.map { TextBoxStyle.color($0) } ?? UIColor(white: 0.62, alpha: 1)
            let swatch = UIImage(systemName: "circle.fill")?.withTintColor(tint, renderingMode: .alwaysOriginal)
            return UIAction(title: item.0, image: swatch) { [weak host] _ in host?.updateSelectedLink { $0.rgb = item.1 } }
        }))
        add("lineweight", UIMenu(title: "線的樣子", children: [
            UIAction(title: "實線", image: UIImage(systemName: "minus")) { [weak host] _ in host?.updateSelectedLink { $0.dash = nil } },
            UIAction(title: "虛線", image: UIImage(systemName: "ellipsis")) { [weak host] _ in host?.updateSelectedLink { $0.dash = true } },
            UIAction(title: "細") { [weak host] _ in host?.updateSelectedLink { $0.width = 1.2 } },
            UIAction(title: "中（預設）") { [weak host] _ in host?.updateSelectedLink { $0.width = nil } },
            UIAction(title: "粗") { [weak host] _ in host?.updateSelectedLink { $0.width = 4 } }
        ]))
        add("arrow.right", UIMenu(title: "箭頭", children: [
            UIAction(title: "尾端有箭頭", image: UIImage(systemName: "arrow.right")) { [weak host] _ in host?.updateSelectedLink { $0.arrow = nil } },
            UIAction(title: "兩端都有", image: UIImage(systemName: "arrow.left.and.right")) { [weak host] _ in host?.updateSelectedLink { $0.arrow = 2 } },
            UIAction(title: "沒有箭頭", image: UIImage(systemName: "minus")) { [weak host] _ in host?.updateSelectedLink { $0.arrow = 1 } },
            UIAction(title: "反過來（箭頭換到另一頭）", image: UIImage(systemName: "arrow.left.arrow.right")) { [weak host] _ in
                host?.updateSelectedLink { link in
                    let from = link.from
                    let side = link.fromSide
                    link.from = link.to
                    link.fromSide = link.toSide
                    link.to = from
                    link.toSide = side
                }
            }
        ]))
        add("point.topleft.down.curvedto.point.bottomright.up", UIMenu(title: "線怎麼走", children: [
            UIAction(title: "直角轉彎") { [weak host] _ in host?.updateSelectedLink { $0.route = nil } },
            UIAction(title: "直線") { [weak host] _ in host?.updateSelectedLink { $0.route = 1 } },
            UIAction(title: "曲線") { [weak host] _ in host?.updateSelectedLink { $0.route = 2 } }
        ]))
        let trash = UIButton(type: .system)
        trash.setImage(UIImage(systemName: "trash"), for: .normal)
        trash.tintColor = .systemRed
        trash.addAction(UIAction { [weak host] _ in host?.deleteSelectedLink() }, for: .touchUpInside)
        items.append(trash)
        addSubview(trash)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func add(_ symbol: String, _ menu: UIMenu) {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.tintColor = .white
        b.menu = menu
        b.showsMenuAsPrimaryAction = true
        items.append(b)
        addSubview(b)
    }

    /// 第一顆的顏色跟著線
    func refresh(_ link: BoxLink) {
        items.first?.tintColor = BoxLinkPath.color(link)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width / CGFloat(max(items.count, 1))
        for (i, item) in items.enumerated() {
            item.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height)
        }
    }
}

/// 「卡片樣式」面板（照 GUGA）：顏色的用法、顏色、形狀；下面三顆：套用預設、存成預設、清除
struct TextStylePanel: View {
    @State private var fill: [Double]?
    @State private var mode: Int
    @State private var shape: Int
    private let change: ([Double]?, Int, Int) -> Void
    private let tidy: (() -> Void)?              // 有值：這個方塊有連線，下面多一顆「一鍵整理」
    @State private var note = ""

    init(fill: [Double]?, mode: Int, shape: Int, tidy: (() -> Void)? = nil,
         change: @escaping ([Double]?, Int, Int) -> Void) {
        _fill = State(initialValue: fill)
        _mode = State(initialValue: mode)
        _shape = State(initialValue: shape)
        self.tidy = tidy
        self.change = change
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("卡片樣式")
                .font(.headline)
                .frame(maxWidth: .infinity)
            Divider()
            Text("顏色")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                choice("rectangle.fill", selected: mode == 0) { mode = 0; ensureColor(); push() }
                choice("rectangle.tophalf.inset.filled", selected: mode == 1) { mode = 1; ensureColor(); push() }
                choice("rectangle", selected: mode == 2) { mode = 2; ensureColor(); push() }
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(TextBoxStyle.palette.indices, id: \.self) { i in
                    swatch(TextBoxStyle.palette[i])
                }
            }
            Divider()
            Text("形狀")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                choice("square.fill", selected: shape == 0) { shape = 0; ensureColor(); push() }
                choice("app.fill", selected: shape == 1) { shape = 1; ensureColor(); push() }
                choice("capsule.fill", selected: shape == 2) { shape = 2; ensureColor(); push() }
            }
            Divider()
            HStack(spacing: 8) {
                action("套用預設") {
                    guard let saved = TextStyleDefault.load() else {
                        note = "還沒有存過預設"
                        return
                    }
                    fill = saved.fill
                    mode = saved.fillMode ?? 0
                    shape = saved.shape ?? 1
                    note = "已套用"
                    push()
                }
                action("存成預設") {
                    TextStyleDefault.save(TextStyleDefault(fill: fill, fillMode: mode, shape: shape))
                    note = fill == nil ? "預設改回沒有樣式" : "之後新的文字方塊都用這個樣式"
                }
                action("清除") {
                    fill = nil
                    note = ""
                    push()
                }
            }
            if let tidy = tidy {
                action("一鍵整理：跟它連在一起的全部", run: tidy)
            }
            if !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func push() {
        change(fill, mode, shape)
    }

    /// 還沒選顏色就先按了用法、形狀：先給一個顏色，才看得出變化
    private func ensureColor() {
        if fill == nil { fill = TextBoxStyle.linkedFill }
    }

    private func choice(_ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.16)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func swatch(_ rgb: [Double]?) -> some View {
        let selected = rgb == fill
        return Button {
            fill = rgb
            push()
        } label: {
            ZStack {
                if let rgb = rgb {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(uiColor: TextBoxStyle.color(rgb)))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.gray.opacity(0.35), lineWidth: 1))
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                    Image(systemName: "line.diagonal")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.red.opacity(0.8))
                }
            }
            .frame(height: 40)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func action(_ title: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.gray.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }
}
