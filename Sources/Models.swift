import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// Models.swift：共用的小工具與資料型別：螢光筆判斷、筆畫點重建、頁面／筆記本／資料夾的資料結構、封面與顏色
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

/// 筆的粗細、字的大小都以 A4 寬度為準：比 A4 大的頁面（例如 iEM 的 PDF）自動等比例放大，看起來一樣粗
let referencePageWidth: CGFloat = 595
/// 白板的大頁面（spec.flat）不放大：1 點就是 1 點，筆的粗細、字的大小跟 A4 筆記本一樣
func pageScaleFactor(_ spec: PageSpec) -> CGFloat {
    if spec.flat == true { return 1 }
    return max(spec.width, 1) / referencePageWidth
}

/// 文字方塊自動換行的寬度以多寬的頁面為準：一般頁面就是頁寬；白板的大頁面最寬算 700 點（不然一行會橫跨整張白板）
func textWrapWidth(_ spec: PageSpec) -> CGFloat {
    spec.flat == true ? min(spec.width, 700) : spec.width
}

/// 這一筆／這支筆算不算螢光筆：Apple 的螢光筆墨水，或半透明的無壓感墨水
func isHighlighterInk(_ type: PKInk.InkType, _ color: UIColor) -> Bool {
    if type == .marker { return true }
    // 用 cgColor 讀透明度：從檔案讀回來的顏色可能不在 getRed 認得的色彩空間，讀不到會被當成不透明
    // （v11.16 以前就是這樣：重開頁面後螢光筆被當成手寫，畫到課本字的上層）
    let alpha = color.cgColor.alpha
    if #available(iOS 17.0, *), type == .monoline { return alpha < 0.95 }
    return false
}

/// 螢光筆的記號（v11.18）：螢光筆畫完時，把那一筆的建立時間改成 2001-01-03 這個不可能出現的時間。
/// 重開頁面後墨水的種類、透明度不一定讀得回來（v11.17 實測：有的螢光筆重開後被當成手寫，蓋到課本字上面），
/// 建立時間會跟著存檔，移動、縮放、拉直時也會保留，用它判斷最可靠。
let highlighterStampTime: TimeInterval = 172_800
/// 這個時間以前畫的筆跡沒有記號，用舊的方法補判
let highlighterStampCutoff = Date(timeIntervalSinceReferenceDate: 816_000_000)   // 2026-11-10 左右

func hasHighlighterStamp(_ stroke: PKStroke) -> Bool {
    abs(stroke.path.creationDate.timeIntervalSinceReferenceDate - highlighterStampTime) < 3600
}

/// 蓋上螢光筆的記號（筆畫點原封不動，只換建立時間）
func stampedHighlighter(_ stroke: PKStroke) -> PKStroke {
    // 有壓感的螢光筆（Apple 的螢光筆墨水）不動：重建它的路徑在 iPadOS 27 可能改變粗細，它的墨水種類本來就認得出來
    if hasHighlighterStamp(stroke) || stroke.ink.inkType == .marker { return stroke }
    let path = PKStrokePath(controlPoints: Array(stroke.path),
                            creationDate: Date(timeIntervalSinceReferenceDate: highlighterStampTime))
    return PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask)
}

func isHighlighter(_ stroke: PKStroke) -> Bool {
    if hasHighlighterStamp(stroke) { return true }
    if isHighlighterInk(stroke.ink.inkType, stroke.ink.color) { return true }
    // 沒有記號的舊筆跡：很粗（約 2.8 mm 以上）的非手寫墨水，當成螢光筆
    guard stroke.path.creationDate < highlighterStampCutoff, !stroke.path.isEmpty else { return false }
    let type = stroke.ink.inkType
    if type == .pen || type == .pencil { return false }
    if #available(iOS 17.0, *) {
        if type == .fountainPen || type == .watercolor || type == .crayon { return false }
    }
    return stroke.path[stroke.path.count / 2].size.width >= 8
}

// 這個開發環境能不能把筆畫點的所有數值（含 iPadOS 27 新增的）完整複製
#if compiler(>=6.3)
let canRebuildPointsFully = true
#else
let canRebuildPointsFully = false
#endif

/// 開發環境不認得 iPadOS 27 的新數值時，App 執行中直接向系統詢問、照原本那一筆補進新的點
enum PointExtras {
    static let keys = ["threshold", "lateralJitter"]

    private static func object(_ p: PKStrokePoint) -> NSObject? {
        (p as AnyObject) as? NSObject
    }

    private static func canSet(_ obj: NSObject, _ key: String) -> Bool {
        let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        return obj.responds(to: NSSelectorFromString(setter))
            || class_getInstanceVariable(type(of: obj), "_" + key) != nil
    }

    /// 測一次：設定得進去、讀得回來，才算可以用
    static let supported: Bool = {
        let p = PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: 4, height: 4),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        guard let d = object(p), d.responds(to: NSSelectorFromString("threshold")),
              canSet(d, "threshold") else { return false }
        d.setValue(0.37, forKey: "threshold")
        guard let back = (d as Any) as? PKStrokePoint, let r = object(back),
              let v = r.value(forKey: "threshold") as? Double else { return false }
        return abs(v - 0.37) < 0.001
    }()

    static func copy(from src: PKStrokePoint, to dst: PKStrokePoint) -> PKStrokePoint {
        guard supported, let s = object(src), let d = object(dst) else { return dst }
        for key in keys where s.responds(to: NSSelectorFromString(key)) && canSet(d, key) {
            d.setValue(s.value(forKey: key), forKey: key)
        }
        return (d as Any) as? PKStrokePoint ?? dst
    }
}

/// 不建立新的點，而是複製原本畫的點、只改位置和時間：iPadOS 27 的新數值會跟著原本的點一起保留
enum PointPatch {
    private static let sample = PKStrokePoint(location: CGPoint(x: 1234.5678, y: -987.654321),
                                              timeOffset: 0.4321, size: CGSize(width: 3.25, height: 5.75),
                                              opacity: 0.8125, force: 0.6, azimuth: 0.3125, altitude: 1.125)

    /// 在點的資料裡找出某幾個連續數值的位置
    private static func findOffset(of values: [Double], in p: PKStrokePoint) -> Int? {
        let size = MemoryLayout<PKStrokePoint>.size
        let need = values.count * 8
        guard size >= need else { return nil }
        var found: Int?
        withUnsafeBytes(of: p) { raw in
            var off = 0
            while off + need <= size {
                var ok = true
                for (k, v) in values.enumerated() {
                    if raw.loadUnaligned(fromByteOffset: off + k * 8, as: Double.self) != v {
                        ok = false
                        break
                    }
                }
                if ok {
                    found = off
                    break
                }
                off += 8
            }
        }
        return found
    }

    /// 測一次：改得動位置和時間、其他數值不變、組成筆畫後讀得回來，才算可以用
    static let offsets: (location: Int, time: Int)? = {
        let p = sample
        guard let lo = findOffset(of: [1234.5678, -987.654321], in: p),
              let to = findOffset(of: [0.4321], in: p), to != lo, to != lo + 8 else { return nil }
        var q = p
        withUnsafeMutableBytes(of: &q) { raw in
            raw.storeBytes(of: 42.0, toByteOffset: lo, as: Double.self)
            raw.storeBytes(of: 24.0, toByteOffset: lo + 8, as: Double.self)
            raw.storeBytes(of: 0.125, toByteOffset: to, as: Double.self)
        }
        guard q.location == CGPoint(x: 42, y: 24), q.timeOffset == 0.125,
              q.size == p.size, q.opacity == p.opacity, q.force == p.force,
              q.azimuth == p.azimuth, q.altitude == p.altitude else { return nil }
        let path = PKStrokePath(controlPoints: [q, q], creationDate: Date())
        guard let first = path.first, first.location == q.location else { return nil }
        return (lo, to)
    }()

    static var available: Bool { offsets != nil }

    static func moved(_ p: PKStrokePoint, to loc: CGPoint, time: TimeInterval) -> PKStrokePoint? {
        guard let o = offsets else { return nil }
        var q = p
        withUnsafeMutableBytes(of: &q) { raw in
            raw.storeBytes(of: Double(loc.x), toByteOffset: o.location, as: Double.self)
            raw.storeBytes(of: Double(loc.y), toByteOffset: o.location + 8, as: Double.self)
            raw.storeBytes(of: time, toByteOffset: o.time, as: Double.self)
        }
        return q
    }
}

/// 首頁顯示用：完整 = 開發環境就認得；搬移 = 改原本點的位置；補齊 = 執行時補上；基本 = 都不行
var pointRebuildLabel: String {
    if canRebuildPointsFully { return "完整" }
    if PointPatch.available { return "搬移" }
    return PointExtras.supported ? "補齊" : "基本"
}

// ============================================================
// 筆記 App　第三版
// 首頁：資料夾、筆記本（新增、重新命名、刪除）
// 筆記本：上下翻頁、旁頁左右滑動（離開自動收回）、拉動新增、
//         概覽、雙指縮放、停筆變直線／圓形
// 手指：滑動、雙指縮放、雙指點一下 = 復原、三指點一下 = 重做
// Apple Pencil：只負責書寫
// ============================================================


// MARK: - 1. 資料結構

struct PageSpec: Codable, Hashable {
    var width: CGFloat = 595      // A4 直式（單位：點）
    var height: CGFloat = 842
    var flat: Bool? = nil         // true：白板的大頁面（v12.3）。筆的粗細、字的大小不隨頁寬放大
}

/// PDF 的某一頁：file 是存在 App 文件資料夾裡的檔名，index 從 0 開始
struct PDFRef: Codable, Hashable {
    var file: String
    var index: Int
}

struct NotePage: Codable, Hashable, Identifiable {
    var id = UUID()
    var spec = PageSpec()
    var pdf: PDFRef? = nil          // 有值：背景是 PDF 的那一頁；沒有：深色方格
    var texts: [TextBox]? = nil     // 這一頁的文字方塊
    var paper: PaperStyle? = nil    // 紙張樣式（舊的頁面沒有：深灰方格）
    var cover: Int? = nil           // 有值：這一頁是封面（封面顏色的編號）
    var images: [ImageBox]? = nil   // 這一頁的圖片
    var tapes: [TapeBox]? = nil     // 這一頁的紙膠帶
    var modified: Date? = nil       // 文字、圖片、紙膠帶最後改的時間（v12.9.2；筆跡看筆跡檔的修改時間）
    var links: [BoxLink]? = nil     // 文字方塊之間的連線（v12.13.0；TextLinks.swift）
    var clips: [PageClip]? = nil    // 剪去白板的範圍（v12.15.1）：頁面上畫灰色虛線框，書籤面板列出來

    var paperStyle: PaperStyle { paper ?? PaperStyle() }
}

extension NotePage {
    /// 深色背景（深灰紙、封面）；課本 PDF、白紙、米黃紙是淺色。萬用筆、文字方塊的預設顏色都用這個判斷
    var isDarkBackground: Bool { pdf == nil && (cover != nil || paperStyle.isDark) }
}

/// 這一頁被剪去白板的一塊（v12.15.1，照 GUGA）
struct PageClip: Codable, Hashable, Identifiable {
    var id = UUID()
    var rect: CGRect
    var date = Date()
    var imageID: UUID? = nil        // 貼到白板上的那張圖（v12.15.2：框右下角的 → 跳到白板上那張圖）
    var rgb: UInt32? = nil          // 框的顏色（v12.15.3：點框 → 改顏色）；nil＝灰色
}

/// 筆記本剪去白板的框跟白板上的圖同步（v12.15.3，使用者要求）：白板上那張圖刪掉了，筆記本那邊的框就不顯示；
/// 復原把圖拿回來，框也回來。記在一張「被刪掉的圖」的清單（UserDefaults），筆記本讀框的時候濾掉
enum ClipSync {
    static let changed = Notification.Name("ClipSyncChanged")
    private static let key = "removedClipImages"

    static var removed: Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap { UUID(uuidString: $0) })
    }

    /// 白板的圖片改了：拿掉的記下來、拿回來的劃掉
    static func update(removed gone: Set<UUID>, added back: Set<UUID>) {
        guard !gone.isEmpty || !back.isEmpty else { return }
        var set = removed
        let before = set
        set.formUnion(gone)
        set.subtract(back)
        guard set != before else { return }
        UserDefaults.standard.set(set.map { $0.uuidString }, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// 頁面上的圖片（位置、大小是頁面座標；檔案放在筆記本資料夾的「圖片」裡）
struct ImageBox: Codable, Hashable, Identifiable {
    var id = UUID()
    var file: String
    var x: CGFloat = 0
    var y: CGFloat = 0
    var width: CGFloat = 100
    var height: CGFloat = 100
    var rotation: CGFloat = 0
    var above = false               // false：在筆跡下面（預設，像貼在紙上）；true：蓋在筆跡上面
    var locked: Bool? = nil         // 固定：不能移動、縮放、旋轉（v11.17）
    var mini: Bool? = nil           // 縮成小圖（v12.8.3）：頁面上只顯示一個小縮圖，點了彈出大圖
    var link: UUID? = nil           // 白板上的筆記本卡片（v12.12.0）：連到哪一本筆記本；圖是封面＋標題（BoardCards.swift）
    var caption: String? = nil      // 卡片上的標題（預設是筆記本的名稱，可以另外改）
    var previewPage: Int? = nil     // 卡片正在預覽第幾頁（v12.12.3；從 0 開始）；nil：顯示封面
    // 從浮動視窗裡剪下來貼到白板的圖（v12.15.0）：從哪一本、哪一頁、頁面上的哪一塊剪的。選取後左下角的 ‹ 會開那一本並跳到那裡
    var sourceNotebook: UUID? = nil
    var sourcePage: UUID? = nil
    var sourceRect: CGRect? = nil

    var isLocked: Bool { locked ?? false }
    var isMini: Bool { mini ?? false }

    /// 小圖在頁面上的大小：長邊 64 點、照原本的比例（左上角跟原本一樣）
    static let miniSide: CGFloat = 64
    var miniRect: CGRect {
        let k = Self.miniSide / max(width, height, 1)
        return CGRect(x: x, y: y, width: max(width * k, 16), height: max(height * k, 16))
    }
}

/// 紙膠帶：蓋住解答，點一下打開、再點一下遮住（位置、大小是頁面座標）
struct TapeBox: Codable, Hashable, Identifiable {
    var id = UUID()
    var x: CGFloat = 0
    var y: CGFloat = 0
    var width: CGFloat = 100
    var height: CGFloat = 30
}

/// 紙張：樣式 + 顏色
struct PaperStyle: Codable, Hashable {
    var pattern = 2                 // 0 空白、1 點狀紙、2 方格紙、3 直線窄、4 直線寬
    var color = 0                   // 0 深灰、1 白色、2 米黃

    static let patternNames = ["空白", "點狀紙", "方格紙", "直線窄", "直線寬"]
    static let colorNames = ["深灰", "白色", "米黃"]

    var isDark: Bool { color == 0 }
}

/// 紙張尺寸（點，直向）
let paperSizes: [(name: String, w: CGFloat, h: CGFloat)] = [
    (name: "A4", w: 595, h: 842), (name: "A3", w: 842, h: 1191), (name: "A5", w: 420, h: 595),
    (name: "B5", w: 499, h: 709), (name: "Letter", w: 612, h: 792)
]

/// 封面模板
struct CoverTemplate {
    let name: String
    let color: Int
    let spine: Int?          // 書背顏色；沒有就用半透明黑色
    let lines: Bool          // 右邊有幾條橫線（基礎系列）
    let group: Int           // 0 基礎、1 純色
}

/// 0–7 是純色（v11.0 建的封面沿用這幾個編號），8 之後是基礎系列
let coverTemplates: [CoverTemplate] = [
    CoverTemplate(name: "藍色", color: 0x3A4E6E, spine: nil, lines: false, group: 1),
    CoverTemplate(name: "紅色", color: 0x9C3B3B, spine: nil, lines: false, group: 1),
    CoverTemplate(name: "綠色", color: 0x3E6B4E, spine: nil, lines: false, group: 1),
    CoverTemplate(name: "黑色", color: 0x262626, spine: nil, lines: false, group: 1),
    CoverTemplate(name: "灰色", color: 0x7A7A7A, spine: nil, lines: false, group: 1),
    CoverTemplate(name: "棕色", color: 0x7A5A3E, spine: nil, lines: false, group: 1),
    CoverTemplate(name: "天藍", color: 0x5FB3DC, spine: nil, lines: false, group: 1),
    CoverTemplate(name: "粉紅", color: 0xE59AB5, spine: nil, lines: false, group: 1),
    CoverTemplate(name: "基礎藍色", color: 0x3D5070, spine: 0x22304A, lines: true, group: 0),
    CoverTemplate(name: "基礎黑色", color: 0x2A2D35, spine: 0x15171C, lines: true, group: 0),
    CoverTemplate(name: "基礎紅色", color: 0xE9DEDD, spine: 0xB98A8E, lines: true, group: 0),
    CoverTemplate(name: "基礎綠色", color: 0x4A6B57, spine: 0x2F4738, lines: true, group: 0),
    CoverTemplate(name: "基礎米色", color: 0xEDE6D6, spine: 0xB8A98A, lines: true, group: 0)
]

func coverTemplate(_ index: Int) -> CoverTemplate {
    coverTemplates[min(max(index, 0), coverTemplates.count - 1)]
}

/// 淺色封面上用深色線，深色封面上用淺色線
func coverIsLight(_ t: CoverTemplate) -> Bool {
    let r = Double((t.color >> 16) & 0xFF)
    let g = Double((t.color >> 8) & 0xFF)
    let b = Double(t.color & 0xFF)
    return (r * 0.299 + g * 0.587 + b * 0.114) > 160
}

func uiColor(hex: Int) -> UIColor {
    UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// 文字方塊（位置、寬度、字的大小都是頁面座標）
struct TextBox: Codable, Hashable, Identifiable {
    var id = UUID()
    var text = ""
    var x: CGFloat = 0
    var y: CGFloat = 0
    var width: CGFloat = 40          // 文字本身的寬度（不含留白），自動依內容計算
    var fontSize: CGFloat = 20
    var rgba: [Double] = [1, 1, 1, 1]
    var bold = false
    var align = 0                    // 0 靠左、1 置中、2 靠右
    var fixedWidth: CGFloat? = nil   // 拖過角的話：固定用這個寬度換行；沒有就自動依內容決定
    var locked: Bool? = nil          // 固定：不能移動、拉寬度（內容照樣可以改）（v11.17）
    var markdown: Bool? = nil        // Markdown 排版（v12.9）：標題、條列、粗體、表格…；Markdown 頁就是一個整頁寬的 Markdown 方塊
    var fill: [Double]? = nil        // 外框樣式的顏色（v12.13.0；TextLinks.swift）；nil＝沒有外框，就是單純的字
    var fillMode: Int? = nil         // 0 整個填滿、1 外框＋上面一條、2 只有外框
    var shape: Int? = nil            // 0 方、1 圓角、2 圓頭
    var tidyLevel: Int? = nil        // 一鍵整理排在第幾層（v12.15.0；-1＝沒接線）。再整理時用來算回原本的字級
    var jump: PageJump? = nil        // 跳轉捷徑（v12.15.11）：點一下跳到那一頁（別本的話開成分頁）
    var sticky: Bool? = nil          // 便利貼（v12.15.11）：黃底的方塊，可以收成一個小圖示
    var folded: Bool? = nil          // 便利貼收起來了
    var ink: Data? = nil             // 便利貼上手寫的字（v12.15.12）：PKDrawing，座標從便利貼左上角算起
    var branchFolded: Bool? = nil    // 心智圖（v12.16.0）：順著線往下的分支收起來了（TextLinks.swift 的 MindFold）
    var underline: Bool? = nil       // 整個方塊加底線（v12.17.5，使用者：標題要能畫記）

    var isLocked: Bool { locked ?? false }
    var isFolded: Bool { (sticky ?? false) && (folded ?? false) }
    var isMarkdown: Bool { markdown ?? false }

    var color: UIColor {
        UIColor(red: rgba.count > 0 ? rgba[0] : 1, green: rgba.count > 1 ? rgba[1] : 1,
                blue: rgba.count > 2 ? rgba[2] : 1, alpha: 1)
    }
}

/// 跳轉捷徑的目的地（v12.15.11）：notebook 是 nil 或等於這一本＝同一本
struct PageJump: Codable, Hashable {
    var notebook: UUID?
    var page: UUID
    var pin: UUID? = nil             // 白板（v12.15.12）：跳到這張白板上的圖釘
    var frame: UUID? = nil           // 或區塊
}

/// 一列 = 一張主頁 + 它的旁頁。pages 由左到右排列，mainIndex 指出哪一張是主頁。
struct PageRow: Codable, Hashable, Identifiable {
    var id = UUID()
    var pages: [NotePage] = [NotePage()]
    var mainIndex = 0
}

struct NotebookData: Codable {
    var rows: [PageRow] = [PageRow()]
    var bookmarks: [UUID]? = nil          // 加了書籤的頁面
    var outline: [OutlineItem]? = nil     // 自己加的大綱
    var outlineManual: Bool? = nil       // true：大綱照使用者拖的順序（v12.16.4）；沒有：同一層照頁碼排
    var lastPage: UUID? = nil             // 上次看到的那一頁（下次打開直接回到這裡）
    var board: Bool? = nil                // true：這是白板（v12.3）：只有一張大頁面，不能加頁，可以自由捲動
    var pins: [BoardPin]? = nil           // 白板的圖釘（v12.7）
    var frames: [BoardFrame]? = nil       // 白板的區塊（v12.7）
    var pinGroups: [String]? = nil        // 圖釘的分組（v12.7）
    var markdown: Bool? = nil             // true：Markdown 筆記本（v12.9.2）：新增的頁都是 Markdown 頁
    var pdfOutlineImported: Bool? = nil   // true：PDF 自帶的目錄已經搬進「我的大綱」（v12.11.1），面板不再另外列一份
}

/// Markdown 頁的方塊（v12.9.2）：整頁寬、固定（不能拖、不能拉寬度），用起來像一般的 Markdown 文件
@MainActor
func markdownPageBox(spec: PageSpec, text: String, fontSize: CGFloat, rgba: [Double]) -> TextBox {
    let k = pageScaleFactor(spec)
    var box = TextBox()
    box.markdown = true
    box.locked = true
    box.fontSize = fontSize * k
    box.x = 36 * k
    box.y = 36 * k
    box.fixedWidth = max(spec.width - 72 * k - TextBoxView.insetX * 2, 100)
    box.width = box.fixedWidth ?? 100
    box.rgba = rgba
    box.text = text
    return box
}

extension TextBox {
    /// Markdown 頁的那個整頁方塊（Markdown 而且固定）
    var isMarkdownPage: Bool { isMarkdown && isLocked }
}

/// 一份歷史版本（存在筆記本資料夾的「歷史版本」裡，一份一個資料夾）
struct SnapshotInfo: Codable, Hashable, Identifiable {
    var id: String              // 資料夾名稱
    var date: Date
    var manual: Bool            // true：手動保存（不會被自動刪除）
    var reason: String          // 變更範本前、刪除頁面前、每日自動、恢復前、手動保存
    var pageCount: Int
    var title: String? = nil    // 自己改的標題（沒改就顯示原因）
    var note: String? = nil     // 自己寫的摘要
    var fingerprint: String? = nil   // 內容的指紋：跟最新一份一樣就不重複存

    var displayTitle: String {
        if let t = title, !t.trimmingCharacters(in: .whitespaces).isEmpty { return t }
        return reason
    }
}

/// 自己加的大綱：標題 + 指到哪一頁
struct OutlineItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var pageID: UUID
    var parentID: UUID? = nil       // 上一層是哪一項（v12.11.0：大綱可以分層）；沒有：最外層
    var collapsed: Bool? = nil      // true：收合，底下的不列出來
}

struct NoteFolder: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var parentID: UUID?
    var colorIndex: Int? = nil        // 資料夾顏色（舊的資料夾沒有：用預設的藍色）
    var dirName: String? = nil        // 在資料位置裡的資料夾名稱
    var deletedAt: Date? = nil        // 有值：在「最近刪除」裡
    var pinned: Date? = nil           // 釘選的時間（v12.15.11）：排在最前面，側邊欄「釘選」也列出來
}

/// 資料夾可以選的顏色：深、中、淺三排
let folderPalette: [Int] = [
    0x8C2929, 0x8F4526, 0x8C5E1F, 0x2E6B2E, 0x3859A6, 0x664299, 0x85386B, 0x5C5C5C, 0x1F1F1F,
    0xEB6666, 0xED9E59, 0xEBC74C, 0x80D16B, 0x85B8F5, 0xC29EF0, 0xEB8CC2, 0xB2B2AD, 0xF7F7F7,
    0xF2ADB2, 0xF5D1A8, 0xF5EB8C, 0xBDF29E, 0xD1E3FA, 0xE3D4F7, 0xF5CCE3, 0xDEDED6
]
let defaultFolderColor = 13       // 中間那排的藍色

func folderColor(_ index: Int?) -> Color {
    let i = min(max(index ?? defaultFolderColor, 0), folderPalette.count - 1)
    let hex = folderPalette[i]
    let r = Double((hex >> 16) & 0xFF) / 255
    let g = Double((hex >> 8) & 0xFF) / 255
    let b = Double(hex & 0xFF) / 255
    return Color(red: r, green: g, blue: b)
}

struct NotebookMeta: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var folderID: UUID?
    var colorIndex = 0
    var modified = Date()
    var dirName: String? = nil        // 在資料位置裡的資料夾名稱
    var deletedAt: Date? = nil        // 有值：在「最近刪除」裡
    var isBoard: Bool? = nil          // true：白板（首頁顯示用；真正的依據是 NotebookData.board）
    var boardID: UUID? = nil          // 有值：這本的「家」在那張白板裡（v12.12.0），首頁不列出來；檔案還是放在 folderID 那個資料夾
    var pinned: Date? = nil           // 釘選的時間（v12.15.11）
    var draftOf: UUID? = nil          // 有值：這是那一本的「隨手記」（v12.16.0；Drafts.swift），首頁、搜尋、日誌都不列
}

/// 匯出旁頁的順序
enum SideOrder: String {
    case rightFirst     // 先右後左：右1、右2…，再左1、左2…
    case leftFirst      // 先左後右：左1、左2…，再右1、右2…
    case visual         // 照畫面由左到右：…左2、左1、右1、右2…
}

struct LibraryData: Codable {
    var folders: [NoteFolder] = []
    var notebooks: [NotebookMeta] = []
    var order: [UUID]? = nil           // 首頁自己排的順序（長按拖曳）；不在裡面的照修改時間排在前面
}

/// 跳回記號（v12.16.0）：某一頁的某個高度（頁面座標）。auto：跳頁前自動記的；false：自己按的
/// 白板（v12.16.1）：x、y 是那時畫面正中間在白板上的位置，zoom 是那時的縮放
struct PlaceMark: Identifiable, Equatable {
    let id = UUID()
    var page: UUID
    var x: CGFloat? = nil
    var y: CGFloat
    var zoom: CGFloat? = nil
    var date = Date()
    var auto: Bool
}
