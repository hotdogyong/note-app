import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// PenBox.swift：筆盒：筆的資料、PenBoxModel、PenBoxView、筆／套索／橡皮擦的設定
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

// MARK: - 10. 筆盒：自己的工具列（可以停靠在上下左右，每支筆各自記住種類、顏色、粗細）

enum PenKind: String, Codable, CaseIterable, Identifiable {
    case pen, pencil, marker, monoline, fountainPen, watercolor, crayon
    case pressurePen, pressureMarker            // 有壓感的版本（Apple 原本的原子筆、螢光筆）

    var isHighlighter: Bool { self == .marker || self == .pressureMarker }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .pen: return "原子筆"
        case .pressurePen: return "原子筆（壓感）"
        case .pencil: return "鉛筆"
        case .marker: return "螢光筆"
        case .pressureMarker: return "螢光筆（壓感）"
        case .monoline: return "代針筆"
        case .fountainPen: return "鋼筆"
        case .watercolor: return "水彩筆"
        case .crayon: return "蠟筆"
        }
    }

    var symbol: String {
        switch self {
        case .pen, .pressurePen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker, .pressureMarker: return "highlighter"
        case .monoline: return "pencil.line"
        case .fountainPen: return "signature"
        case .watercolor: return "paintbrush"
        case .crayon: return "scribble.variable"
        }
    }

    /// 粗細範圍（單位：點，1 點 ≈ 0.35 mm）
    var widthRange: ClosedRange<Double> {
        switch self {
        case .marker, .pressureMarker, .watercolor, .crayon: return 3...40
        default: return 0.5...30          // 0.18～10.6 mm（白板也夠粗）
        }
    }

    var inkType: PKInk.InkType {
        switch self {
        case .pen, .marker:                      // 原子筆、螢光筆：粗細固定，沒有壓感
            if #available(iOS 17.0, *) { return .monoline }
            return self == .pen ? .pen : .marker
        case .pressurePen: return .pen
        case .pressureMarker: return .marker
        case .pencil: return .pencil
        case .monoline:
            if #available(iOS 17.0, *) { return .monoline }
            return .pen
        case .fountainPen:
            if #available(iOS 17.0, *) { return .fountainPen }
            return .pen
        case .watercolor:
            if #available(iOS 17.0, *) { return .watercolor }
            return .marker
        case .crayon:
            if #available(iOS 17.0, *) { return .crayon }
            return .pencil
        }
    }
}

struct PenPreset: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: PenKind
    var rgba: [Double]          // 紅、綠、藍、不透明度（0～1）
    var width: Double
    var adaptive: Bool? = nil   // 萬用筆：依頁面背景換顏色
    var lightRGB: [Double]? = nil   // 萬用筆在淺色頁面（課本、白紙、米黃紙）的顏色；沒設定＝黑（v11.17）
    var darkRGB: [Double]? = nil    // 萬用筆在深色頁面（深灰紙、封面）的顏色；沒設定＝白（v11.17）
    var dash: Int? = nil            // 線條：0 或沒設定＝實線、1 虛線、2 點線（v11.17）
    var widths: [Double]? = nil     // 常用粗細（點）：筆盒的粗細鈕點一下換下一個（v11.19）

    var opacity: Double { rgba.count > 3 ? rgba[3] : 1 }

    var uiColor: UIColor {
        UIColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: opacity)
    }

    var isAdaptive: Bool { adaptive ?? false }
    var dashStyle: Int { dash ?? 0 }

    static let black: [Double] = [0, 0, 0]
    static let white: [Double] = [1, 1, 1]
    static let blue3F53D9: [Double] = [63.0 / 255, 83.0 / 255, 217.0 / 255]

    var lightValues: [Double] { (lightRGB?.count ?? 0) >= 3 ? lightRGB! : Self.black }
    var darkValues: [Double] { (darkRGB?.count ?? 0) >= 3 ? darkRGB! : Self.white }

    /// 萬用筆在淺色頁面、深色頁面各用什麼顏色（不含透明度）
    var lightColor: UIColor { PenPreset.color(lightValues) }
    var darkColor: UIColor { PenPreset.color(darkValues) }

    static func color(_ c: [Double]) -> UIColor {
        UIColor(red: c[0], green: c[1], blue: c[2], alpha: 1)
    }

    /// 常用粗細，照你排的順序（筆盒的粗細鈕就照這個順序換）
    var widthList: [Double] { widths ?? [] }

    /// 粗細的 mm 文字：0.2、0.25、1.5（不顯示多餘的 0）
    static func mmText(_ width: Double) -> String {
        let mm = width * 0.3528
        var text = mm < 1 ? String(format: "%.2f", mm) : String(format: "%.1f", mm)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// 兩個粗細算不算同一個（差不到 0.005 mm）
    static func sameWidth(_ a: Double, _ b: Double) -> Bool { abs(a - b) * 0.3528 < 0.005 }

    static let defaults: [PenPreset] = [
        PenPreset(kind: .pen, rgba: [1, 1, 1, 1], width: 4),
        PenPreset(kind: .pen, rgba: [0, 0, 0, 1], width: 4),
        PenPreset(kind: .pen, rgba: [1, 0.42, 0.42, 1], width: 4),
        PenPreset(kind: .pen, rgba: [0.45, 0.72, 1, 1], width: 4),
        PenPreset(kind: .pencil, rgba: [1, 1, 1, 1], width: 3),
        PenPreset(kind: .monoline, rgba: [1, 1, 1, 1], width: 2.5),
        PenPreset(kind: .fountainPen, rgba: [1, 1, 1, 1], width: 4),
        PenPreset(kind: .marker, rgba: [1, 0.85, 0.2, 0.5], width: 18)
    ]
}

enum PenSelection: Codable, Hashable {
    case preset(UUID)
    case eraser
    case lasso
    case tape               // 紙膠帶
    case apple              // 正在用 Apple 的工具列
}

enum PenDock: String, Codable {
    case leading, trailing, top, bottom

    var isVertical: Bool { self == .leading || self == .trailing }

    var alignment: Alignment {
        switch self {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }
}

enum PenCorner: String, Codable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
}

/// 一個筆盒：名字 + 裡面的筆
struct PenBoxSet: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var presets: [PenPreset]
}

/// 筆盒的狀態，所有筆記本共用，關掉 App 也會記住
@MainActor
final class PenBoxModel: ObservableObject {
    static let shared = PenBoxModel()

    @Published var presets: [PenPreset]                 // 目前這個筆盒的筆
    @Published private(set) var boxes: [PenBoxSet]       // 所有筆盒
    @Published private(set) var activeBox: UUID
    @Published var selection: PenSelection
    @Published var eraserPartial: Bool          // false：整筆擦掉；true：局部擦除
    @Published var eraserWidth: Double
    @Published var eraserWidths: [Double] = []      // 橡皮擦的常用大小（照排好的順序，v11.22）
    @Published var dock: PenDock
    @Published var collapsed: Bool
    @Published var minimized = false              // 縮成角落的小圓鈕
    @Published var corner = PenCorner.bottomTrailing
    @Published var lassoRectangle = false         // 套索：徒手或矩形
    @Published var lassoHandwriting = true        // 套索要不要選到手寫（螢光筆以外的筆跡）
    @Published var lassoHighlighter = true        // 套索要不要選到螢光筆
    @Published var lassoImages = true             // 套索要不要選到圖片（v12.1）
    @Published var lassoTexts = true              // 套索要不要選到文字方塊（v12.2）
    // 套索選項的預設（v12.9）：上面兩個是「現在這本」的；在筆記本裡改的存在 lassoOwn.<編號>，只影響那一本
    private var baseLassoImages = true
    private var baseLassoTexts = true

    /// 改套索要不要選到圖片、文字方塊：在筆記本裡＝只改這一本；在首頁設定＝改預設
    func setLasso(images: Bool? = nil, texts: Bool? = nil) {
        if let v = images { lassoImages = v }
        if let v = texts { lassoTexts = v }
        if let id = notebookID {
            UserDefaults.standard.set([lassoImages, lassoTexts], forKey: "lassoOwn." + id.uuidString)
        } else {
            baseLassoImages = lassoImages
            baseLassoTexts = lassoTexts
            save()
        }
    }

    /// 這本筆記本的套索選項（沒改過＝預設）
    private func loadLasso(for id: UUID?) {
        if let id = id, let own = UserDefaults.standard.array(forKey: "lassoOwn." + id.uuidString) as? [Bool], own.count == 2 {
            lassoImages = own[0]
            lassoTexts = own[1]
        } else {
            lassoImages = baseLassoImages
            lassoTexts = baseLassoTexts
        }
    }

    /// 這本筆記本的套索選項回到預設（「這本的設定回到預設」用）
    func resetNotebookLasso(_ id: UUID) {
        UserDefaults.standard.removeObject(forKey: "lassoOwn." + id.uuidString)
        if notebookID == id { loadLasso(for: id) }
    }

    /// 把這本的套索選項設成預設
    func makeNotebookLassoDefault() {
        baseLassoImages = lassoImages
        baseLassoTexts = lassoTexts
        save()
    }
    @Published var reversed = false               // 反轉：橡皮擦、套索、紙膠帶、粗細放前面，筆放後面（v11.20）
    @Published private(set) var notebookID: UUID?        // 現在打開的筆記本（v12.3）；nil：在首頁
    @Published private(set) var usingOwn = false         // 這本筆記本的筆跟預設不一樣（它有自己的一份）
    @Published private(set) var version = 0
    @Published private(set) var settingsRequest = 0      // Pencil 點兩下要打開目前這支筆的設定
    private var previous: PenSelection?     // 筆的設定一有變化就 +1，筆記本畫面看到後套用到畫布

    private struct Saved: Codable {
        var presets: [PenPreset]
        var selection: PenSelection
        var eraserPartial: Bool
        var eraserWidth: Double
        var dock: PenDock
        var collapsed: Bool
        var minimized: Bool?          // 新版才有的設定：舊的存檔讀不到也沒關係
        var corner: PenCorner?
        var lassoRectangle: Bool?
        var lassoHandwriting: Bool?
        var lassoHighlighter: Bool?
        var boxes: [PenBoxSet]?
        var activeBox: UUID?
        var reversed: Bool?
        var eraserWidths: [Double]?
        var lassoImages: Bool?
        var lassoTexts: Bool?
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "penBox"),
           let saved = try? JSONDecoder().decode(Saved.self, from: data), !saved.presets.isEmpty {
            presets = saved.presets
            if case .apple = saved.selection {                 // Apple 工具列已拿掉，改回第一支筆
                selection = PenSelection.preset(saved.presets[0].id)
            } else {
                selection = saved.selection
            }
            eraserPartial = saved.eraserPartial
            eraserWidth = saved.eraserWidth
            dock = saved.dock
            collapsed = saved.collapsed
            minimized = saved.minimized ?? false
            corner = saved.corner ?? .bottomTrailing
            lassoRectangle = saved.lassoRectangle ?? false
            lassoHandwriting = saved.lassoHandwriting ?? true
            lassoHighlighter = saved.lassoHighlighter ?? true
            reversed = saved.reversed ?? false
            eraserWidths = saved.eraserWidths ?? []
            lassoImages = saved.lassoImages ?? true
            lassoTexts = saved.lassoTexts ?? true
            baseLassoImages = saved.lassoImages ?? true      // init 裡還不能讀 self 的屬性，直接從存檔拿
            baseLassoTexts = saved.lassoTexts ?? true
            // 舊版只有一個筆盒：把它當成「筆盒 1」
            let loadedBoxes = saved.boxes ?? [PenBoxSet(name: "筆盒 1", presets: saved.presets)]
            let active = saved.activeBox.flatMap { id in loadedBoxes.contains { $0.id == id } ? id : nil }
                ?? loadedBoxes[0].id
            boxes = loadedBoxes
            activeBox = active
        } else {
            presets = PenPreset.defaults
            selection = .preset(PenPreset.defaults[0].id)
            eraserPartial = false
            eraserWidth = 12
            dock = .trailing
            collapsed = false
            let first = PenBoxSet(name: "筆盒 1", presets: PenPreset.defaults)
            boxes = [first]
            activeBox = first.id
        }
    }

    /// 設定從備份讀回 UserDefaults 之後：重新載入（v12.4）
    func reloadFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: "penBox"),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), !saved.presets.isEmpty else { return }
        presets = saved.presets
        if case .apple = saved.selection {
            selection = PenSelection.preset(saved.presets[0].id)
        } else {
            selection = saved.selection
        }
        eraserPartial = saved.eraserPartial
        eraserWidth = saved.eraserWidth
        dock = saved.dock
        collapsed = saved.collapsed
        minimized = saved.minimized ?? false
        corner = saved.corner ?? PenCorner.bottomTrailing
        lassoRectangle = saved.lassoRectangle ?? false
        lassoHandwriting = saved.lassoHandwriting ?? true
        lassoHighlighter = saved.lassoHighlighter ?? true
        reversed = saved.reversed ?? false
        eraserWidths = saved.eraserWidths ?? []
        lassoImages = saved.lassoImages ?? true
        lassoTexts = saved.lassoTexts ?? true
        baseLassoImages = lassoImages
        baseLassoTexts = lassoTexts
        let loadedBoxes = saved.boxes ?? [PenBoxSet(name: "筆盒 1", presets: saved.presets)]
        let active = saved.activeBox.flatMap { id in loadedBoxes.contains { $0.id == id } ? id : nil }
            ?? loadedBoxes[0].id
        boxes = loadedBoxes
        activeBox = active
        notebookID = nil
        usingOwn = false
        version += 1
    }

    // MARK: 多個筆盒

    var activeBoxName: String { boxes.first { $0.id == activeBox }?.name ?? "" }

    // MARK: 每本筆記本自己的筆（v12.3）
    // 規則：筆記本平常跟著預設（目前這個筆盒）。在筆記本裡調順序、增減筆、改筆的設定，那一本就自動有自己的一份
    //（存在 UserDefaults 的 penOwn.<筆記本編號>），之後只影響它；預設的筆盒不會被改到。

    private static func ownKey(_ id: UUID) -> String { "penOwn." + id.uuidString }
    private static func selectionKey(_ id: UUID) -> String { "penSel." + id.uuidString }

    /// 預設的筆：目前這個筆盒裡存的
    private var basePresets: [PenPreset] {
        boxes.first(where: { $0.id == activeBox })?.presets ?? presets
    }

    /// 選的筆不在現在這組筆裡：改選第一支（橡皮擦、套索照舊）
    private func fixSelection() {
        if case .preset(let pid) = selection, !presets.contains(where: { $0.id == pid }) {
            selection = presets.first.map { PenSelection.preset($0.id) } ?? PenSelection.eraser
        }
    }

    /// 打開筆記本：換上它自己的筆（有的話），並回到上次在這本選的工具
    func enterNotebook(_ id: UUID) {
        if notebookID != nil { syncActive() }                 // 上一本還沒收好：先存
        notebookID = nil
        let base = basePresets
        var own: [PenPreset]?
        if let data = UserDefaults.standard.data(forKey: Self.ownKey(id)) {
            own = try? JSONDecoder().decode([PenPreset].self, from: data)
        }
        if let pens = own, !pens.isEmpty, pens != base {
            presets = pens
            usingOwn = true
        } else {
            presets = base
            usingOwn = false
        }
        notebookID = id
        loadLasso(for: id)                                     // 這本自己的套索選項（v12.9）
        if let data = UserDefaults.standard.data(forKey: Self.selectionKey(id)),
           let saved = try? JSONDecoder().decode(PenSelection.self, from: data), saved != PenSelection.apple {
            selection = saved
        }
        fixSelection()
        version += 1
    }

    /// 離開筆記本：存好它的筆，換回預設
    func leaveNotebook(_ id: UUID) {
        guard notebookID == id else { return }
        save()
        notebookID = nil
        loadLasso(for: nil)
        usingOwn = false
        presets = basePresets
        fixSelection()
    }

    /// 這本筆記本的筆回到預設
    func resetNotebookPens() {
        guard let id = notebookID else { return }
        UserDefaults.standard.removeObject(forKey: Self.ownKey(id))
        presets = basePresets
        usingOwn = false
        fixSelection()
        changed()
    }

    /// 把這本筆記本的筆設成預設（寫進目前這個筆盒）；其他沒有自己改過的筆記本也會跟著用這一組
    func makeNotebookPensDefault() {
        guard let id = notebookID, let i = boxes.firstIndex(where: { $0.id == activeBox }) else { return }
        boxes[i].presets = presets
        UserDefaults.standard.removeObject(forKey: Self.ownKey(id))
        usingOwn = false
        changed()
    }

    /// 目前這組筆寫回去：在首頁 → 寫回筆盒清單；在筆記本裡 → 跟預設不一樣就存成這本自己的，一樣就不留
    private func syncActive() {
        guard let i = boxes.firstIndex(where: { $0.id == activeBox }) else { return }
        if let id = notebookID {
            if presets != boxes[i].presets {
                if let data = try? JSONEncoder().encode(presets) {
                    UserDefaults.standard.set(data, forKey: Self.ownKey(id))
                }
                if !usingOwn { usingOwn = true }
            } else {
                UserDefaults.standard.removeObject(forKey: Self.ownKey(id))
                if usingOwn { usingOwn = false }
            }
            if let data = try? JSONEncoder().encode(selection) {
                UserDefaults.standard.set(data, forKey: Self.selectionKey(id))     // 這本上次選的工具
            }
            return
        }
        if boxes[i].presets != presets { boxes[i].presets = presets }
    }

    func switchBox(_ id: UUID) {
        guard id != activeBox, let target = boxes.first(where: { $0.id == id }) else { return }
        syncActive()
        activeBox = id
        presets = target.presets
        // 原本選的筆不在新筆盒裡：改選新筆盒的第一支筆（橡皮擦、套索照舊）
        if case .preset(let pid) = selection, !presets.contains(where: { $0.id == pid }) {
            selection = presets.first.map { PenSelection.preset($0.id) } ?? .eraser
        }
        changed()
    }

    func newBox() {
        syncActive()
        let fresh = PenPreset.defaults.map { preset -> PenPreset in
            var copy = preset
            copy.id = UUID()                            // 每個筆盒的筆各自獨立
            return copy
        }
        let set = PenBoxSet(name: "筆盒 \(boxes.count + 1)", presets: fresh)
        boxes.append(set)
        switchBox(set.id)
    }

    func renameBox(_ id: UUID, to name: String) {
        guard let i = boxes.firstIndex(where: { $0.id == id }) else { return }
        boxes[i].name = name
        save()
    }

    func deleteBox(_ id: UUID) {
        guard boxes.count > 1, let i = boxes.firstIndex(where: { $0.id == id }) else { return }
        if id == activeBox {
            let next = boxes[i == 0 ? 1 : 0].id
            switchBox(next)
        }
        boxes.removeAll { $0.id == id }
        save()
    }

    func save() {
        syncActive()
        // presets 欄位一律存預設的那一組（在筆記本裡時 presets 可能是那一本自己的）
        let saved = Saved(presets: basePresets, selection: selection, eraserPartial: eraserPartial,
                          eraserWidth: eraserWidth, dock: dock, collapsed: collapsed,
                          minimized: minimized, corner: corner,
                          lassoRectangle: lassoRectangle, lassoHandwriting: lassoHandwriting,
                          lassoHighlighter: lassoHighlighter, boxes: boxes, activeBox: activeBox,
                          reversed: reversed, eraserWidths: eraserWidths, lassoImages: baseLassoImages,
                          lassoTexts: baseLassoTexts)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: "penBox")
        }
    }

    func changed() {
        version += 1
        save()
    }

    func select(_ s: PenSelection) {
        if s != selection { previous = selection }
        selection = s
        changed()
    }

    /// Pencil 點兩下（設定為「切換到橡皮擦」）
    func toggleEraser() {
        if selection == .eraser {
            select(previous ?? presets.first.map { PenSelection.preset($0.id) } ?? .lasso)
        } else {
            select(.eraser)
        }
    }

    /// Pencil 點兩下（設定為「切換到上一個工具」）
    func togglePrevious() {
        guard let p = previous else { return }
        select(p)
    }

    func requestSettings() {
        settingsRequest += 1
    }

    /// 在 Apple 工具列上選了筆：筆盒取消選取
    func useApple() {
        guard selection != .apple else { return }
        selection = .apple
        save()
    }

    func update(_ preset: PenPreset) {
        guard let i = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[i] = preset
        changed()
    }

    func add(_ kind: PenKind) {
        let width = kind.isHighlighter ? 18.0 : 4.0
        let alpha = kind.isHighlighter ? 0.5 : 1.0
        let preset = PenPreset(kind: kind, rgba: [1, 1, 1, alpha], width: width)
        presets.append(preset)
        select(.preset(preset.id))
    }

    /// 筆盒的粗細鈕：換到這支筆的下一個常用粗細（最粗的下一個回到最細）
    func cycleWidth() {
        guard case .preset(let id) = selection, let i = presets.firstIndex(where: { $0.id == id }) else { return }
        let list = presets[i].widthList
        guard list.count >= 2 else { return }
        let w = presets[i].width
        let next: Double
        if let k = list.firstIndex(where: { PenPreset.sameWidth($0, w) }) {
            next = list[(k + 1) % list.count]                     // 照排好的順序，最後一個之後回到第一個
        } else {
            next = list[0]                                        // 目前的粗細不在清單裡：從第一個開始
        }
        presets[i].width = next
        changed()
    }

    /// 粗細鈕（選橡皮擦時）：換到下一個常用大小
    func cycleEraserWidth() {
        let list = eraserWidths
        guard list.count >= 2 else { return }
        if let k = list.firstIndex(where: { PenPreset.sameWidth($0, eraserWidth) }) {
            eraserWidth = list[(k + 1) % list.count]
        } else {
            eraserWidth = list[0]
        }
        changed()
    }

    /// 新增萬用筆：淺色頁面用 light、深色頁面用 dark
    func addAdaptive(_ kind: PenKind, light: [Double], dark: [Double]) {
        var preset = PenPreset(kind: kind, rgba: [light[0], light[1], light[2], 1], width: 4)
        preset.adaptive = true
        preset.lightRGB = light
        preset.darkRGB = dark
        presets.append(preset)
        select(.preset(preset.id))
    }

    /// 長按拖曳調整筆的順序（v12.1）：把這支筆移到第 index 個位置（超出範圍就放到最前或最後）
    func movePen(_ id: UUID, to index: Int) {
        guard let from = presets.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index, 0), presets.count - 1)
        guard target != from else { return }
        let pen = presets.remove(at: from)
        presets.insert(pen, at: target)
    }

    func duplicate(_ id: UUID) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        var copy = presets[i]
        copy.id = UUID()
        presets.insert(copy, at: i + 1)
        select(.preset(copy.id))
    }

    func delete(_ id: UUID) {
        guard presets.count > 1, let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets.remove(at: i)
        if selection == .preset(id) {
            selection = .preset(presets[min(i, presets.count - 1)].id)
        }
        changed()
    }

    /// 筆盒在畫面上要對齊的位置
    var alignment: Alignment { minimized ? corner.alignment : dock.alignment }

    /// 放開把手的位置：靠近角落就縮成圓鈕，否則停靠到最近的那一邊
    func drop(at p: CGPoint, in size: CGSize) {
        let zone: CGFloat = 150
        let nearLeft = p.x < zone, nearRight = p.x > size.width - zone
        let nearTop = p.y < zone, nearBottom = p.y > size.height - zone
        if (nearLeft || nearRight) && (nearTop || nearBottom) {
            minimized = true
            corner = nearTop ? (nearLeft ? .topLeading : .topTrailing) : (nearLeft ? .bottomLeading : .bottomTrailing)
        } else {
            minimized = false
            let distances: [(PenDock, CGFloat)] = [
                (.leading, p.x), (.trailing, size.width - p.x), (.top, p.y), (.bottom, size.height - p.y)
            ]
            if let nearest = distances.min(by: { $0.1 < $1.1 }) { dock = nearest.0 }
        }
        save()
    }

    /// 目前工具的圖示和顏色（縮成圓鈕時顯示）
    var currentSymbol: (String, UIColor?) {
        switch selection {
        case .preset(let id):
            guard let p = presets.first(where: { $0.id == id }) else { return ("pencil.tip", nil) }
            return (p.kind.symbol, p.uiColor)
        case .eraser: return ("eraser", nil)
        case .lasso: return ("lasso", nil)
        case .tape: return ("bandage", nil)
        case .apple: return ("applepencil", nil)
        }
    }

    /// 目前選的筆（橡皮擦、套索、紙膠帶時是 nil）
    var currentPreset: PenPreset? {
        guard case .preset(let id) = selection else { return nil }
        return presets.first(where: { $0.id == id })
    }

    /// 目前選的是萬用筆
    var currentAdaptive: Bool { currentPreset?.isAdaptive ?? false }

    /// 萬用筆在淺色、深色頁面的顏色
    var currentAdaptiveColors: (light: UIColor, dark: UIColor) {
        guard let p = currentPreset else { return (UIColor.black, UIColor.white) }
        return (p.lightColor, p.darkColor)
    }

    /// 目前這支筆的線條：0 實線、1 虛線、2 點線（螢光筆一律實線）
    var currentDash: Int {
        guard let p = currentPreset, !p.kind.isHighlighter else { return 0 }
        return p.dashStyle
    }

    var currentTool: PKTool? {
        switch selection {
        case .preset(let id):
            guard let p = presets.first(where: { $0.id == id }) else { return nil }
            return PKInkingTool(p.kind.inkType, color: p.uiColor, width: p.width)
        case .eraser:
            if #available(iOS 16.4, *) {
                return PKEraserTool(eraserPartial ? .bitmap : .vector, width: eraserWidth)   // 兩種都照設定的大小
            }
            return PKEraserTool(eraserPartial ? .bitmap : .vector)
        case .lasso, .tape, .apple:
            return nil              // 套索、紙膠帶由筆記本自己處理；Apple 工具列的工具不去動
        }
    }
}

struct PenBoxView: View {
    @ObservedObject var box: PenBoxModel
    let containerSize: CGSize
    @State private var dragOffset: CGSize = .zero
    @State private var editing: PenSelection?
    @State private var showSwitcher = false
    @State private var movingPen: UUID?            // 長按拖曳中的那支筆（v12.1）
    @State private var movingFrom = 0              // 開始拖的時候它排第幾個
    @State private var askResetPens = false        // 「回到預設」先問一次（v12.4）
    @State private var askDefaultPens = false      // 「設成預設」先問一次

    var body: some View {
        Group {
            if box.minimized {
                bubble
            } else {
                fullBox
            }
        }
        .onChange(of: box.settingsRequest) { _, _ in
            if box.minimized { box.minimized = false }
            editing = box.selection                    // Pencil 點兩下：打開目前這支筆的設定
        }
    }

    private var dragToDock: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("penbox"))
            .onChanged { value in dragOffset = value.translation }
            .onEnded { value in
                dragOffset = .zero
                box.drop(at: value.location, in: containerSize)
            }
    }

    /// 縮在角落的小圓鈕：顯示目前的筆，點一下展開，拖曳可以換位置
    private var bubble: some View {
        let symbol = box.currentSymbol
        return ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbol.0)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 54, height: 54)
                .background(Circle().fill(.regularMaterial))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            if let color = symbol.1 {
                let pair = box.currentAdaptiveColors
                InkDot(color: Color(uiColor: color), adaptive: box.currentAdaptive,
                       light: Color(uiColor: pair.light), dark: Color(uiColor: pair.dark))
                    .frame(width: 14, height: 14)
                    .offset(x: -4, y: -4)
            }
        }
        .contentShape(Circle())
        .onTapGesture {
            box.minimized = false
            box.save()
        }
        .gesture(dragToDock)
        .offset(dragOffset)
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 28, trailing: 16))
    }

    private var fullBox: some View {
        let layout = box.dock.isVertical
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            handle
            if !box.collapsed {
                if box.reversed {
                    // 反轉：橡皮擦、套索、紙膠帶 → 粗細 → 筆
                    eraserButton
                    lassoButton
                    toolButton(.tape, symbol: "bandage")
                    groupDivider
                    widthButton
                    penGroup
                } else {
                    penGroup
                    widthButton
                    groupDivider
                    eraserButton
                    lassoButton
                    toolButton(.tape, symbol: "bandage")          // 紙膠帶
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .offset(dragOffset)
        .padding(edgePadding)
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: box.dock.isVertical ? 30 : 1, height: box.dock.isVertical ? 1 : 30)
    }

    /// 所有的筆，加上最後面的 ＋
    @ViewBuilder
    private var penGroup: some View {
                ForEach(box.presets) { preset in
                    penButton(preset)
                        .scaleEffect(movingPen == preset.id ? 1.22 : 1)       // 拖曳中的那支筆放大一點
                        .zIndex(movingPen == preset.id ? 1 : 0)
                        .simultaneousGesture(penMoveGesture(preset.id))
                }
                Menu {
                    ForEach(PenKind.allCases) { kind in
                        Button {
                            box.add(kind)
                            openSettingsForNewPen()
                        } label: {
                            Label("新增\(kind.name)", systemImage: kind.symbol)
                        }
                    }
                    Divider()
                    Button {
                        box.addAdaptive(.pen, light: PenPreset.black, dark: PenPreset.white)
                        openSettingsForNewPen()
                    } label: {
                        Label("新增萬用筆", systemImage: "circle.lefthalf.filled")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 36)
                }
    }

    /// 調整筆的順序（v12.1）：長按一支筆約 0.35 秒（筆會放大），再沿著筆盒的方向拖，每經過一格就跟旁邊的筆換位置
    private func penMoveGesture(_ id: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("penbox")))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if movingPen != id {
                    movingPen = id
                    movingFrom = box.presets.firstIndex(where: { $0.id == id }) ?? 0
                }
                guard let d = drag else { return }
                let along: CGFloat = box.dock.isVertical ? d.translation.height : d.translation.width
                let steps = Int((along / 44).rounded())          // 一格 = 筆 40 點 + 間距 4 點
                let target = movingFrom + steps
                withAnimation(.easeInOut(duration: 0.15)) {
                    box.movePen(id, to: target)
                }
            }
            .onEnded { _ in
                movingPen = nil
                box.save()
            }
    }

    /// 粗細鈕：顯示目前這支筆的粗細，點一下換下一個常用粗細；還沒設常用粗細時，點一下打開這支筆的設定
    private var widthButton: some View {
        let preset: PenPreset? = box.currentPreset
        let isEraser = box.selection == .eraser
        let count = isEraser ? box.eraserWidths.count : (preset?.widthList.count ?? 0)
        let usable = isEraser || preset != nil
        let text: String = isEraser ? PenPreset.mmText(box.eraserWidth) : (preset.map { PenPreset.mmText($0.width) } ?? "—")
        return Button {
            if isEraser {
                if count >= 2 { box.cycleEraserWidth() } else { editing = .eraser }
            } else if count >= 2 {
                box.cycleWidth()
            } else if let p = preset {
                editing = .preset(p.id)
            }
        } label: {
            VStack(spacing: 0) {
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(count >= 2 ? "mm ↻" : "mm")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(width: 40, height: 36)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .opacity(usable ? 1 : 0.4)
    }

    /// 新增一支筆之後：直接打開它的設定（選顏色、粗細）
    private func openSettingsForNewPen() {
        guard case .preset(let id) = box.selection else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {      // 等選單收起來
            editing = .preset(id)
        }
    }

    private var edgePadding: EdgeInsets {
        switch box.dock {
        case .leading: return EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 0)
        case .trailing: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 10)
        case .top: return EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0)
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: 24, trailing: 0)
        }
    }

    /// 把手：點一下切換筆盒（收合時點一下展開）；拖曳可以移到上下左右任一邊，拖到角落會縮成圓鈕
    private var handle: some View {
        Image(systemName: box.collapsed ? "pencil.tip.crop.circle" : "line.3.horizontal")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.75))
            .frame(width: 40, height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.9)))
            .contentShape(Rectangle())
            .onTapGesture {
                if box.collapsed {
                    box.collapsed = false
                    box.save()
                } else {
                    showSwitcher = true
                }
            }
            .gesture(dragToDock)
            .popover(isPresented: $showSwitcher) {
                switcher
            }
    }

    /// 切換筆盒：每個筆盒各自記住自己的筆
    private var switcher: some View {
        VStack(spacing: 0) {
            Text("切換筆盒")
                .font(.headline)
                .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(box.boxes) { set in
                        Button {
                            box.switchBox(set.id)
                            showSwitcher = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: set.id == box.activeBox ? "checkmark.circle.fill" : "pencil.tip.crop.circle")
                                    .font(.title3)
                                    .foregroundStyle(set.id == box.activeBox ? Color.accentColor : Color.secondary)
                                Text(set.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(set.presets.count) 支")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(set.id == box.activeBox ? Color.gray.opacity(0.12) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                TextPrompt.show(title: "重新命名筆盒", initial: set.name) { text in
                                    box.renameBox(set.id, to: text)
                                }
                            } label: {
                                Label("重新命名", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                box.deleteBox(set.id)
                            } label: {
                                Label("刪除這個筆盒", systemImage: "trash")
                            }
                            .disabled(box.boxes.count <= 1)
                        }
                        Divider().padding(.leading, 18)
                    }
                }
            }
            .frame(maxHeight: 320)
            VStack(spacing: 8) {
                Button {
                    box.newBox()
                    showSwitcher = false
                } label: {
                    Text("新建")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.15)))
                }
                .buttonStyle(.plain)
                HStack {
                    Button {
                        TextPrompt.show(title: "重新命名筆盒", initial: box.activeBoxName) { text in
                            box.renameBox(box.activeBox, to: text)
                        }
                    } label: {
                        Label("重新命名", systemImage: "pencil")
                            .font(.callout)
                    }
                    Spacer()
                    Button {
                        box.collapsed = true
                        box.save()
                        showSwitcher = false
                    } label: {
                        Label("收合筆盒", systemImage: "chevron.up.chevron.down")
                            .font(.callout)
                    }
                }
                .padding(.horizontal, 4)
                Toggle(isOn: Binding(get: { box.reversed },
                                     set: { box.reversed = $0; box.save() })) {
                    Label("反轉（橡皮擦、套索放前面）", systemImage: "arrow.left.arrow.right")
                        .font(.callout)
                }
                .padding(.horizontal, 4)
                Text("長按某個筆盒可以重新命名或刪除。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                notebookPens
            }
            .padding(14)
        }
        .frame(width: 300)
    }

    /// 這本筆記本自己的筆（v12.3）：在筆記本裡調整筆，只會記在這一本
    @ViewBuilder
    private var notebookPens: some View {
        if box.notebookID != nil {
            Divider()
                .padding(.vertical, 8)
            Text(box.usingOwn ? "這本筆記本有自己的筆：順序、增減、設定都只影響這一本。"
                 : "這本筆記本的筆跟預設一樣。在這本裡調整順序、增減或改設定，只會記在這一本。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button {
                    askResetPens = true
                } label: {
                    Label("回到預設", systemImage: "arrow.uturn.backward")
                        .font(.callout)
                }
                .disabled(!box.usingOwn)
                .alert("這本筆記本的筆回到預設？", isPresented: $askResetPens) {
                    Button("回到預設", role: .destructive) { box.resetNotebookPens() }
                    Button("取消", role: .cancel) { }
                } message: {
                    Text("這本筆記本自己調過的順序、增減的筆、改過的設定都會不見。")
                }
                Spacer()
                Button {
                    askDefaultPens = true
                } label: {
                    Label("設成預設", systemImage: "square.and.arrow.down")
                        .font(.callout)
                }
                .disabled(!box.usingOwn)
                .alert("把這本筆記本的筆設成預設？", isPresented: $askDefaultPens) {
                    Button("設成預設", role: .destructive) { box.makeNotebookPensDefault() }
                    Button("取消", role: .cancel) { }
                } message: {
                    Text("原本預設的那一組筆會被換掉；其他沒有自己調過的筆記本也會改用這一組。")
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 10)
        }
    }

    /// 選中的筆往畫面內側突出一點，比較好認
    private func sticksOut(_ selected: Bool) -> CGSize {
        guard selected else { return .zero }
        switch box.dock {
        case .leading: return CGSize(width: 6, height: 0)
        case .trailing: return CGSize(width: -6, height: 0)
        case .top: return CGSize(width: 0, height: 6)
        case .bottom: return CGSize(width: 0, height: -6)
        }
    }

    private func editingBinding(_ target: PenSelection) -> Binding<Bool> {
        Binding(get: { editing == target }, set: { if !$0 { editing = nil } })
    }

    private func presetBinding(_ id: UUID) -> Binding<PenPreset> {
        Binding(get: { box.presets.first(where: { $0.id == id }) ?? PenPreset.defaults[0] },
                set: { box.update($0) })
    }

    private func penButton(_ preset: PenPreset) -> some View {
        let selected = box.selection == .preset(preset.id)
        return Button {
            if selected {
                editing = .preset(preset.id)          // 已選中的再點一次：打開設定
            } else {
                box.select(.preset(preset.id))
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: preset.kind.symbol)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                InkDot(color: Color(uiColor: preset.uiColor), adaptive: preset.isAdaptive,
                       light: Color(uiColor: preset.lightColor), dark: Color(uiColor: preset.darkColor))
                    .frame(width: 12, height: 12)
                    .offset(x: -2, y: -2)
            }
            .overlay(alignment: .topTrailing) {
                // 虛線、點線的筆：右上角標一個小記號，不會不小心拿錯
                if !preset.kind.isHighlighter && preset.dashStyle != 0 {
                    Image(systemName: preset.dashStyle == 2 ? "circle.dotted" : "line.diagonal")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.8)))
                        .offset(x: 1, y: 1)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.28) : Color.clear))
            .offset(sticksOut(selected))
        }
        .buttonStyle(.plain)
        .popover(isPresented: editingBinding(.preset(preset.id))) {
            PenSettingsView(preset: presetBinding(preset.id),
                            onDuplicate: {
                                editing = nil
                                box.duplicate(preset.id)
                            },
                            onDelete: {
                                editing = nil
                                box.delete(preset.id)
                            })
        }
    }

    private var eraserButton: some View {
        let selected = box.selection == .eraser
        return Button {
            if selected { editing = .eraser } else { box.select(.eraser) }
        } label: {
            Image(systemName: "eraser")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.28) : Color.clear))
                .offset(sticksOut(selected))
        }
        .buttonStyle(.plain)
        .popover(isPresented: editingBinding(.eraser)) {
            EraserSettingsView(box: box)
        }
    }

    private var lassoButton: some View {
        let selected = box.selection == .lasso
        return Button {
            if selected { editing = .lasso } else { box.select(.lasso) }
        } label: {
            Image(systemName: "lasso")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.28) : Color.clear))
                .offset(sticksOut(selected))
        }
        .buttonStyle(.plain)
        .popover(isPresented: editingBinding(.lasso)) {
            LassoSettingsView(box: box)
        }
    }

    private func toolButton(_ tool: PenSelection, symbol: String) -> some View {
        let selected = box.selection == tool
        return Button {
            box.select(tool)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.28) : Color.clear))
                .offset(sticksOut(selected))
        }
        .buttonStyle(.plain)
    }
}

/// 某支筆的設定：種類、粗細（滑桿，細的那端比較好微調）、不透明度、顏色
/// 筆的顏色點；萬用筆顯示半黑半白
struct InkDot: View {
    let color: Color
    let adaptive: Bool
    var light: Color = .black          // 萬用筆：左上半邊＝淺色頁面用的顏色
    var dark: Color = .white           // 右下半邊＝深色頁面用的顏色

    var body: some View {
        Group {
            if adaptive {
                Circle().fill(LinearGradient(stops: [
                    .init(color: light, location: 0), .init(color: light, location: 0.5),
                    .init(color: dark, location: 0.5), .init(color: dark, location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                Circle().fill(color)
            }
        }
        .overlay(Circle().stroke(Color.gray.opacity(0.7), lineWidth: 1))
    }
}

struct PenSettingsView: View {
    @Binding var preset: PenPreset
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    @State private var side = 0                  // 萬用筆正在改哪一邊：0 淺色頁面、1 深色頁面
    @State private var contentHeight: CGFloat = 640   // 內容的高度（量出來的）

    static let swatches: [[Double]] = [
        [1, 1, 1], [0, 0, 0], [0.55, 0.55, 0.55], [1, 0.42, 0.42], [1, 0.62, 0.25], [1, 0.85, 0.2],
        [0.45, 0.85, 0.45], [0.3, 0.75, 0.75], [0.45, 0.72, 1], [0.35, 0.45, 1], [0.7, 0.5, 1], [1, 0.5, 0.8],
        PenPreset.blue3F53D9, [0.85, 0.2, 0.2], [0.1, 0.55, 0.3]
    ]

    /// 滑桿 0～1 對應到粗細：對數刻度，細的那一段拉得比較長（0.2、0.25、0.3 mm 都好調），粗的那端照樣到得了
    private var widthFraction: Binding<Double> {
        let r = preset.kind.widthRange
        let ratio = r.upperBound / r.lowerBound
        return Binding(
            get: {
                let w = min(max(preset.width, r.lowerBound), r.upperBound)
                return log(w / r.lowerBound) / log(ratio)
            },
            set: { preset.width = Self.rounded(r.lowerBound * pow(ratio, $0)) }
        )
    }

    /// 1 點 = 0.3528 mm
    static let mmPerPoint = 0.3528

    /// 粗細對齊到好讀的 mm 數：1 mm 以下每 0.01 mm、3 mm 以下每 0.05 mm、更粗每 0.1 mm
    static func rounded(_ width: Double) -> Double {
        let mm = width * mmPerPoint
        let step = mm < 1 ? 0.01 : (mm < 3 ? 0.05 : 0.1)
        return max((mm / step).rounded() * step, 0.01) / mmPerPoint
    }

    /// 微調一格：1 mm 以下每格 0.05 mm、3 mm 以下每格 0.1 mm、更粗每格 0.5 mm
    private func nudge(_ direction: Double) {
        let r = preset.kind.widthRange
        let mm = preset.width * Self.mmPerPoint
        let goingUp = direction > 0
        let step: Double
        if goingUp {
            step = mm < 0.999 ? 0.05 : (mm < 2.999 ? 0.1 : 0.5)
        } else {
            step = mm <= 1.001 ? 0.05 : (mm <= 3.001 ? 0.1 : 0.5)
        }
        // 先對齊到這一格的倍數，再走一格（0.27 → 0.30 或 0.25）
        let aligned = goingUp ? (floor(mm / step + 1e-6) + 1) * step : (ceil(mm / step - 1e-6) - 1) * step
        let width = aligned / Self.mmPerPoint
        preset.width = min(max(width, r.lowerBound), r.upperBound)
    }

    /// 常用粗細（點一下套用、長按移動或刪除、一鍵排序）
    private var favoriteWidths: some View {
        WidthFavorites(list: Binding(get: { preset.widthList },
                                     set: { preset.widths = $0.isEmpty ? nil : $0 }),
                       width: $preset.width,
                       target: "筆盒的粗細鈕")
    }

    private var widthLabel: String {
        let mm = preset.width * Self.mmPerPoint
        return mm < 1 ? String(format: "%.2f mm", mm) : String(format: "%.1f mm", mm)
    }

    private var opacity: Binding<Double> {
        Binding(
            get: { preset.opacity },
            set: { value in
                var c = preset.rgba
                while c.count < 4 { c.append(1) }
                c[3] = value
                preset.rgba = c
            }
        )
    }

    /// 目前要改的顏色（單色筆：筆的顏色；萬用筆：正在改的那一邊）
    private var editingRGB: [Double] {
        if preset.isAdaptive { return side == 0 ? preset.lightValues : preset.darkValues }
        return [preset.rgba[0], preset.rgba[1], preset.rgba[2]]
    }

    /// 選了某個顏色
    private func pick(_ c: [Double]) {
        guard c.count >= 3 else { return }
        let rgb = [c[0], c[1], c[2]]
        if preset.isAdaptive {
            if side == 0 {
                preset.lightRGB = rgb
                preset.rgba = [rgb[0], rgb[1], rgb[2], preset.opacity]     // 筆盒圖示的顏色跟淺色那邊一樣
            } else {
                preset.darkRGB = rgb
            }
        } else {
            preset.rgba = [rgb[0], rgb[1], rgb[2], preset.opacity]
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: {
                let c = editingRGB
                return Color(red: c[0], green: c[1], blue: c[2])
            },
            set: { newColor in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(newColor).getRed(&r, green: &g, blue: &b, alpha: &a)
                pick([Double(r), Double(g), Double(b)])
            }
        )
    }

    private func isCurrent(_ c: [Double]) -> Bool {
        let e = editingRGB
        return abs(c[0] - e[0]) < 0.02 && abs(c[1] - e[1]) < 0.02 && abs(c[2] - e[2]) < 0.02
    }

    /// 色碼（例如 3F53D9）
    static func hex(_ c: [Double]) -> String {
        guard c.count >= 3 else { return "" }
        let v = c.prefix(3).map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", v[0], v[1], v[2])
    }

    static func parseHex(_ text: String) -> [Double]? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let n = UInt32(t, radix: 16) else { return nil }
        return [Double((n >> 16) & 0xFF) / 255, Double((n >> 8) & 0xFF) / 255, Double(n & 0xFF) / 255]
    }

    private func askHex() {
        let initial = Self.hex(editingRGB)
        TextPrompt.show(title: "輸入色碼（例如 3F53D9）", initial: initial) { text in
            if let c = Self.parseHex(text) { pick(c) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("種類", selection: $preset.kind) {
                ForEach(PenKind.allCases) { kind in
                    Label(kind.name, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            widthAndOpacity
            if !preset.kind.isHighlighter {
                dashPicker
            }
            colorModePicker
            if preset.isAdaptive {
                adaptiveSides
            }
            swatchGrid
            HStack {
                ColorPicker("自訂顏色", selection: customColor, supportsOpacity: false)
                Button {
                    askHex()
                } label: {
                    Text("#" + Self.hex(editingRGB))
                        .font(.callout.monospaced())
                }
                .buttonStyle(.bordered)
            }
            Divider()
            HStack {
                Button {
                    onDuplicate()
                } label: {
                    Label("複製這支筆", systemImage: "plus.square.on.square")
                }
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("刪除", systemImage: "trash")
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(GeometryReader { g in
            Color.clear.preference(key: SettingsHeightKey.self, value: g.size.height)
        })
    }

    /// 內容太長（例如筆盒在下面、萬用筆的選項全開）時可以上下滑：
    /// 平常彈出框的高度剛好等於內容，螢幕放不下時系統會縮小它，這時就能滑
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 320)
        .frame(idealHeight: contentHeight, maxHeight: contentHeight)
        .onPreferenceChange(SettingsHeightKey.self) { h in
            if h > 0 { contentHeight = h }
        }
    }

    private var widthAndOpacity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("粗細")
                Spacer()
                Button {
                    nudge(-1)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                Text(widthLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 70)
                Button {
                    nudge(1)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            Slider(value: widthFraction, in: 0...1)
            favoriteWidths
            HStack {
                Text("不透明度")
                Spacer()
                Text("\(Int((preset.opacity * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: opacity, in: 0.1...1)
        }
    }

    /// 線條：實線、虛線、點線
    private var dashPicker: some View {
        let binding = Binding<Int>(get: { preset.dashStyle }, set: { preset.dash = $0 == 0 ? nil : $0 })
        return HStack {
            Text("線條")
            Picker("線條", selection: binding) {
                Text("實線").tag(0)
                Text("虛線").tag(1)
                Text("點線").tag(2)
            }
            .pickerStyle(.segmented)
        }
    }

    /// 顏色：單色，或萬用（淺色頁面、深色頁面各一種顏色）
    private var colorModePicker: some View {
        let binding = Binding<Bool>(
            get: { preset.isAdaptive },
            set: { on in
                if on {
                    preset.adaptive = true
                    // 第一次打開萬用：淺色頁面沿用目前的顏色（白色的筆就用黑），深色頁面用白
                    if preset.lightRGB == nil {
                        let c = [preset.rgba[0], preset.rgba[1], preset.rgba[2]]
                        let isWhite = c[0] > 0.9 && c[1] > 0.9 && c[2] > 0.9
                        preset.lightRGB = isWhite ? PenPreset.black : c
                    }
                    if preset.darkRGB == nil { preset.darkRGB = PenPreset.white }
                    let l = preset.lightValues
                    preset.rgba = [l[0], l[1], l[2], preset.opacity]
                    side = 0
                } else {
                    preset.adaptive = nil
                }
            })
        return VStack(alignment: .leading, spacing: 6) {
            Text("顏色")
            Picker("顏色", selection: binding) {
                Text("單色").tag(false)
                Text("萬用（依頁面深淺）").tag(true)
            }
            .pickerStyle(.segmented)
        }
    }

    /// 萬用筆：淺色頁面、深色頁面兩個顏色，點一邊再從下面選顏色
    private var adaptiveSides: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                sideButton(0, title: "淺色頁面", note: "課本、白紙、米黃紙", rgb: preset.lightValues)
                sideButton(1, title: "深色頁面", note: "深灰紙、封面", rgb: preset.darkValues)
            }
            HStack(spacing: 8) {
                quickPair("黑／白", light: PenPreset.black, dark: PenPreset.white)
                quickPair("藍／白", light: PenPreset.blue3F53D9, dark: PenPreset.white)
            }
        }
    }

    private func sideButton(_ index: Int, title: String, note: String, rgb: [Double]) -> some View {
        let selected = side == index
        return Button {
            side = index
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(red: rgb[0], green: rgb[1], blue: rgb[2]))
                    .overlay(Circle().stroke(Color.gray.opacity(0.6), lineWidth: 1))
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func quickPair(_ title: String, light: [Double], dark: [Double]) -> some View {
        Button {
            preset.lightRGB = light
            preset.darkRGB = dark
            preset.rgba = [light[0], light[1], light[2], preset.opacity]
        } label: {
            HStack(spacing: 6) {
                InkDot(color: .black, adaptive: true,
                       light: Color(red: light[0], green: light[1], blue: light[2]),
                       dark: Color(red: dark[0], green: dark[1], blue: dark[2]))
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
    }

    private var swatchGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 10), count: 6), spacing: 10) {
            ForEach(Self.swatches.indices, id: \.self) { i in
                swatch(Self.swatches[i])
            }
        }
    }

    private func swatch(_ c: [Double]) -> some View {
        let current = isCurrent(c)
        return Circle()
            .fill(Color(red: c[0], green: c[1], blue: c[2]))
            .overlay(Circle().stroke(current ? Color.accentColor : Color.gray.opacity(0.5),
                                     lineWidth: current ? 3 : 1))
            .frame(width: 30, height: 30)
            .onTapGesture {
                pick(c)
            }
    }
}

/// 常用粗細（筆和橡皮擦共用）：點一下套用；長按往前移、往後移、刪除；「＋ 目前」加到最後；
/// 「小 → 大」「大 → 小」一鍵排序。筆盒的粗細鈕照這個順序，點一下換下一個
struct WidthFavorites: View {
    @Binding var list: [Double]
    @Binding var width: Double
    var target: String

    var body: some View {
        let hasCurrent = list.contains { PenPreset.sameWidth($0, width) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("常用")
                    .font(.callout)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(list.indices, id: \.self) { i in
                            chip(list[i])
                        }
                        if !hasCurrent {
                            Button {
                                list.append(width)            // 加到最後面
                            } label: {
                                Label("目前", systemImage: "plus")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if list.count >= 2 {
                HStack(spacing: 8) {
                    Text("順序")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sortButton("小 → 大", ascending: true)
                    sortButton("大 → 小", ascending: false)
                }
            }
            Text(list.count >= 2 ? "\(target)照這個順序，點一下換下一個。長按可以移動或刪除。"
                                 : "加入兩個以上，\(target)就能點一下切換。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func sortButton(_ title: String, ascending: Bool) -> some View {
        let sorted = ascending ? list.sorted() : list.sorted(by: >)
        let isNow = list == sorted
        return Button {
            list = sorted
        } label: {
            Text(title)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(isNow ? Color.accentColor : Color.gray)
    }

    private func move(_ w: Double, by step: Int) {
        var l = list
        guard let i = l.firstIndex(where: { PenPreset.sameWidth($0, w) }) else { return }
        let j = i + step
        guard l.indices.contains(j) else { return }
        l.swapAt(i, j)
        list = l
    }

    private func chip(_ w: Double) -> some View {
        let current = PenPreset.sameWidth(w, width)
        let i = list.firstIndex(where: { PenPreset.sameWidth($0, w) }) ?? 0
        let count = list.count
        return Text(PenPreset.mmText(w))
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(current ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15)))
            .overlay(Capsule().stroke(current ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .onTapGesture {
                width = w
            }
            .contextMenu {
                if i > 0 {
                    Button {
                        move(w, by: -1)
                    } label: {
                        Label("往前移", systemImage: "arrow.left")
                    }
                }
                if i < count - 1 {
                    Button {
                        move(w, by: 1)
                    } label: {
                        Label("往後移", systemImage: "arrow.right")
                    }
                }
                Button(role: .destructive) {
                    list.removeAll { PenPreset.sameWidth($0, w) }
                } label: {
                    Label("刪除 \(PenPreset.mmText(w)) mm", systemImage: "trash")
                }
            }
    }
}

/// 筆的設定量內容高度用
struct SettingsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 套索設定：徒手或矩形，以及要選到哪些筆跡
struct LassoSettingsView: View {
    @ObservedObject var box: PenBoxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("套索")
                .font(.headline)
                .frame(maxWidth: .infinity)
            Text("選取內容包含")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Toggle("手寫", isOn: Binding(get: { box.lassoHandwriting },
                                        set: { box.lassoHandwriting = $0; box.save() }))
            Toggle("螢光筆", isOn: Binding(get: { box.lassoHighlighter },
                                         set: { box.lassoHighlighter = $0; box.save() }))
            Toggle("圖片", isOn: Binding(get: { box.lassoImages },
                                        set: { box.setLasso(images: $0) }))      // 在筆記本裡只改這一本（v12.9）
            Toggle("文字方塊", isOn: Binding(get: { box.lassoTexts },
                                          set: { box.setLasso(texts: $0) }))
            Text("不用畫成封閉的圈，放開時會自動把頭尾接起來；靠近頁面邊緣的筆跡，往頁面外繞過去就會被包進來。只想改字的顏色、不想動到螢光筆時，可以把「螢光筆」關掉再圈。圖片、文字方塊圈到一點就算（固定住的不會被選到）；只想圈圖片上面的字時，把「圖片」關掉，或先把圖片固定。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 280)
    }
}

struct EraserSettingsView: View {
    @ObservedObject var box: PenBoxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("橡皮擦")
                .font(.headline)
                .frame(maxWidth: .infinity)
            Picker("方式", selection: Binding(get: { box.eraserPartial },
                                             set: { box.eraserPartial = $0; box.changed() })) {
                Text("整筆擦掉").tag(false)
                Text("局部擦除").tag(true)
            }
            .pickerStyle(.segmented)
            HStack {
                Text("大小")
                Spacer()
                Text(String(format: "%.1f mm", box.eraserWidth * 0.3528))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { box.eraserWidth },
                                  set: { box.eraserWidth = PenSettingsView.rounded($0); box.changed() }),
                   in: 2...60)
            WidthFavorites(list: Binding(get: { box.eraserWidths },
                                         set: { box.eraserWidths = $0; box.save() }),
                           width: Binding(get: { box.eraserWidth },
                                          set: { box.eraserWidth = $0; box.changed() }),
                           target: "筆盒的大小鈕")
        }
        .padding(16)
        .frame(width: 300)
    }
}
