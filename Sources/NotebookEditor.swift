import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// NotebookEditor.swift：筆記本畫面的 SwiftUI 外框：NotebookModel、NotebookEditorView、「⋯」選單、新增頁面選單、面板（縮略圖／書籤／大綱／旁頁）、分享
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

/// 右上角的新增頁面：向上、向下、向左、向右（左右以目前這一頁為準）
struct NewPageMenu: View {
    @ObservedObject var model: NotebookModel

    var body: some View {
        Menu {
            Button {
                model.documentView?.insertRow(at: model.focusRow)
            } label: {
                Label("向上新增頁面", systemImage: "arrow.up.doc")
            }
            Button {
                model.documentView?.insertRow(at: model.focusRow + 1)
            } label: {
                Label("向下新增頁面", systemImage: "arrow.down.doc")
            }
            Button {
                model.documentView?.addSidePageNextToCurrent(left: true)
            } label: {
                Label("向左新增旁頁", systemImage: "arrow.left.square")
            }
            Button {
                model.documentView?.addSidePageNextToCurrent(left: false)
            } label: {
                Label("向右新增旁頁", systemImage: "arrow.right.square")
            }
            Divider()
            Button {
                model.documentView?.insertMarkdownPage()
            } label: {
                Label("向下新增 Markdown 頁", systemImage: "doc.richtext")
            }
        } label: {
            Image(systemName: "doc.badge.plus")
        }
    }
}

/// 左上角的剪刀：開關截圖模式
struct CropButton: View {
    @ObservedObject var model: NotebookModel

    var body: some View {
        let active: Bool = model.cropActive
        return Button {
            model.documentView?.setCropMode(!active)
        } label: {
            Image(systemName: active ? "scissors.circle.fill" : "scissors")
        }
    }
}

/// 膠囊的底：iOS 26 以上用系統的玻璃（跟以前系統工具列一樣），以前的系統用毛玻璃
struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

/// 筆記本左下角的 %：點了跳到哪個大小（v12.8.4）。貼合整頁、貼合寬度，或記住現在的大小
struct ZoomPresetMenu: View {
    @ObservedObject var model: NotebookModel
    @AppStorage("notebookZoomPreset") private var preset = "width"          // 跟 NotebookView.zoomPresetKey 一樣

    private var custom: Double? { (preset == "page" || preset == "width") ? nil : Double(preset) }

    private var currentName: String {
        if preset == "page" { return "貼合整頁" }
        if preset == "width" { return "100%" }
        if let z = custom { return "\(Int((z * 100).rounded()))%" }
        return "100%"
    }

    var body: some View {
        Menu {
            Button {
                preset = "width"
            } label: {
                Label("100%（貼合寬度）", systemImage: preset == "width" ? "checkmark" : "arrow.left.and.right")
            }
            Button {
                preset = "page"
            } label: {
                Label("貼合整頁", systemImage: preset == "page" ? "checkmark" : "rectangle.portrait")
            }
            Button {
                if let z = model.documentView?.currentZoom { preset = String(format: "%.4f", Double(z)) }
            } label: {
                let now = Int(((model.documentView?.currentZoom ?? 1) * 100).rounded())
                Label("記住現在的大小（\(now)%）", systemImage: custom != nil ? "checkmark" : "plus.magnifyingglass")
            }
        } label: {
            Label("左下角 % 點了跳到：\(currentName)", systemImage: "percent")
        }
    }
}

/// 白板的「⋯」最上面（v12.8）：加大、格線、底色。筆記本的「頁面」那一區（變更範本、旁頁、移頁）白板用不到
struct BoardMenuSection: View {
    @ObservedObject var model: NotebookModel

    private var paper: PaperStyle { model.notebook.rows.first?.pages.first?.paperStyle ?? PaperStyle() }

    private var patternBinding: Binding<Int> {
        Binding(get: { paper.pattern }, set: { value in
            var p = paper
            p.pattern = value
            model.documentView?.setBoardPaper(p)
        })
    }

    private var colorBinding: Binding<Int> {
        Binding(get: { paper.color }, set: { value in
            var p = paper
            p.color = value
            model.documentView?.setBoardPaper(p)
        })
    }

    var body: some View {
        Section("白板") {
            Picker(selection: patternBinding) {
                ForEach(0..<PaperStyle.patternNames.count, id: \.self) { (i: Int) in
                    Text(PaperStyle.patternNames[i]).tag(i)
                }
            } label: {
                Label("格線", systemImage: "grid")
            }
            .pickerStyle(.menu)
            Picker(selection: colorBinding) {
                ForEach(0..<PaperStyle.colorNames.count, id: \.self) { (i: Int) in
                    Text(PaperStyle.colorNames[i]).tag(i)
                }
            } label: {
                Label("底色", systemImage: "paintpalette")
            }
            .pickerStyle(.menu)
            Button {
                model.documentView?.enlargeBoard()
            } label: {
                Label("加大白板（往右、往下各加一倍）", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
    }
}

/// 白板的匯出（v12.8）：目前畫面、全部內容；單一區塊在區塊的工具列匯出
struct BoardExportSection: View {
    @ObservedObject var model: NotebookModel

    var body: some View {
        Section("匯出（PDF）") {
            Button {
                model.documentView?.exportBoard(onlyVisible: true)
            } label: {
                Label("匯出目前畫面", systemImage: "rectangle.dashed")
            }
            Button {
                model.documentView?.exportBoard(onlyVisible: false)
            } label: {
                Label("匯出白板上所有內容", systemImage: "square.and.arrow.up")
            }
            Button {
                model.documentView?.exportAllFrames()
            } label: {
                Label("匯出所有區塊（一個區塊一頁）", systemImage: "rectangle.stack")
            }
        }
    }
}

/// 筆記本右上角「⋯」：分成頁面、編輯、檢視、匯出、刪除幾個區塊
/// 每本筆記本自己的設定（v12.9）：在筆記本裡改的存在「<鍵>.<筆記本編號>」，只影響那一本；
/// 沒改過的跟著預設（首頁「設定」裡的，存在「<鍵>」）。新文字方塊的預設、頁面後面的底色用這個；
/// 筆、停筆、套索各自有自己的一套（penOwn.、snapOwn.、lassoOwn.）
@MainActor
enum NotebookPrefs {
    static let keys = [TextDefaults.sizeKey, TextDefaults.colorKey, TextDefaults.boldKey, "notebookBackdrop"]

    static func key(_ base: String, _ id: UUID) -> String { base + "." + id.uuidString }

    static func object(_ base: String, _ id: UUID?) -> Any? {
        let d = UserDefaults.standard
        if let id = id, let v = d.object(forKey: key(base, id)) { return v }
        return d.object(forKey: base)
    }

    static func set(_ value: Any, _ base: String, _ id: UUID?) {
        if let id = id {
            UserDefaults.standard.set(value, forKey: key(base, id))
        } else {
            UserDefaults.standard.set(value, forKey: base)
        }
    }

    /// 這本有沒有自己改過
    static func hasOwn(_ id: UUID) -> Bool {
        keys.contains { UserDefaults.standard.object(forKey: key($0, id)) != nil }
            || UserDefaults.standard.object(forKey: "lassoOwn." + id.uuidString) != nil
    }

    /// 這本回到預設
    static func reset(_ id: UUID) {
        for k in keys { UserDefaults.standard.removeObject(forKey: key(k, id)) }
    }

    /// 這本的設定變成預設（其他沒改過的筆記本也跟著用）
    static func makeDefault(_ id: UUID) {
        for k in keys {
            if let v = UserDefaults.standard.object(forKey: key(k, id)) { UserDefaults.standard.set(v, forKey: k) }
        }
    }
}

/// 新文字方塊的預設字級、顏色、粗體（v11.30；v12.9 起每本筆記本各自記住，見 NotebookPrefs）
@MainActor
enum TextDefaults {
    static let sizeKey = "textDefaultSize"
    static let colorKey = "textDefaultColor"      // "auto" 或 6 位色碼
    static let boldKey = "textDefaultBold"
    static let sizes: [Int] = [8, 10, 12, 14, 16, 18, 20, 24, 28]

    /// 某一本筆記本的預設（v12.9：每本各自記住）
    static func size(_ id: UUID?) -> CGFloat {
        let v = (NotebookPrefs.object(sizeKey, id) as? Double) ?? 0
        return v > 0 ? CGFloat(v) : 14
    }

    static func bold(_ id: UUID?) -> Bool { (NotebookPrefs.object(boldKey, id) as? Bool) ?? false }

    static func rgba(_ id: UUID?) -> [Double]? {
        guard let hex = NotebookPrefs.object(colorKey, id) as? String, hex != "auto",
              let c = PenSettingsView.parseHex(hex) else { return nil }
        return [c[0], c[1], c[2], 1]
    }

    /// 字級（以 A4 為準）；沒設定過＝14
    static var size: CGFloat {
        let v = UserDefaults.standard.double(forKey: sizeKey)
        return v > 0 ? CGFloat(v) : 14
    }

    static var bold: Bool { UserDefaults.standard.bool(forKey: boldKey) }

    /// 顏色；nil＝自動（深色紙白字、淺色紙黑字）
    static var rgba: [Double]? {
        guard let hex = UserDefaults.standard.string(forKey: colorKey), hex != "auto",
              let c = PenSettingsView.parseHex(hex) else { return nil }
        return [c[0], c[1], c[2], 1]
    }
}

/// 停筆的設定：要不要自動變形、哪些情況變形後要跳出調整框。
/// 每本筆記本各自記住（v12.2）：在筆記本裡改的項目存在 snapOwn.<筆記本編號>（一個 [項目: 開關]），只影響那一本；
/// 那一本沒改過的項目，跟著首頁「設定」裡的預設（存在 snap.<項目>）。
enum SnapSettings {
    enum Item: String, CaseIterable {
        case shapes          // 停住自動拉直、變成圖形
        case lineEditor      // 一般的筆畫出直線之後，跳出調整框
        case shapeEditor     // 畫出圖形（三角形、四邊形、圓）之後，跳出調整框
        case markerEditor    // 螢光筆拉直之後，跳出調整框
        case holdSelect      // Pencil 按在筆跡上不動：選取那一筆

        var title: String {
            switch self {
            case .shapes: return "停住自動拉直、變成圖形"
            case .lineEditor: return "直線"
            case .shapeEditor: return "圖形（三角形、四邊形、圓）"
            case .markerEditor: return "螢光筆"
            case .holdSelect: return "Pencil 按住筆跡來選取"
            }
        }

        var symbol: String {
            switch self {
            case .shapes: return "wand.and.stars"
            case .lineEditor: return "line.diagonal"
            case .shapeEditor: return "triangle"
            case .markerEditor: return "highlighter"
            case .holdSelect: return "hand.tap"
            }
        }
    }

    /// 還沒設定過時的預設值。直線、螢光筆預設不跳調整框（通常畫完就繼續寫）；
    /// 圖形和按住選取沿用 v11.17 的「變形後跳出調整框」開關
    private static func fallback(_ item: Item) -> Bool {
        let defaults = UserDefaults.standard
        switch item {
        case .shapes:
            return defaults.object(forKey: "snapShapes") as? Bool ?? true
        case .lineEditor, .markerEditor:
            return false
        case .shapeEditor, .holdSelect:
            return defaults.object(forKey: "snapShowEditor") as? Bool ?? true
        }
    }

    private static func globalKey(_ item: Item) -> String { "snap." + item.rawValue }
    private static func ownKey(_ notebook: UUID) -> String { "snapOwn." + notebook.uuidString }

    /// 預設（首頁「設定」改的）
    static func globalValue(_ item: Item) -> Bool {
        UserDefaults.standard.object(forKey: globalKey(item)) as? Bool ?? fallback(item)
    }

    /// 這本筆記本自己改過的項目
    private static func own(_ notebook: UUID) -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: ownKey(notebook)) as? [String: Bool] ?? [:]
    }

    /// 這本筆記本有沒有自己改過任何一項
    static func hasOwn(_ notebook: UUID?) -> Bool {
        guard let id = notebook else { return false }
        return !own(id).isEmpty
    }

    /// 這本筆記本全部回到預設
    static func resetOwn(_ notebook: UUID) {
        UserDefaults.standard.removeObject(forKey: ownKey(notebook))
    }

    /// 現在要用的值：這本筆記本改過就用它的，沒改過用預設。notebook = nil：只看預設
    static func value(_ item: Item, notebook: UUID?) -> Bool {
        if let id = notebook, let saved = own(id)[item.rawValue] { return saved }
        return globalValue(item)
    }

    /// 改設定。notebook 有值：只記在這本筆記本；nil：改預設
    static func set(_ item: Item, _ on: Bool, notebook: UUID?) {
        if let id = notebook {
            var dict = own(id)
            dict[item.rawValue] = on
            UserDefaults.standard.set(dict, forKey: ownKey(id))
        } else {
            UserDefaults.standard.set(on, forKey: globalKey(item))
        }
    }
}

/// 停筆設定的內容（幾個 Section），筆記本的「⋯ → 停筆設定」和首頁的「設定」共用。
/// notebookID 有值：顯示、修改的是這本筆記本的設定；nil：預設
struct SnapSettingsSections: View {
    let notebookID: UUID?
    @State private var revision = 0            // 改了設定就 +1，畫面重新讀一次

    private func binding(_ item: SnapSettings.Item) -> Binding<Bool> {
        let id = notebookID
        return Binding(get: { SnapSettings.value(item, notebook: id) },
                       set: { on in
                           SnapSettings.set(item, on, notebook: id)
                           revision += 1
                       })
    }

    private func row(_ item: SnapSettings.Item) -> some View {
        Toggle(isOn: binding(item)) {
            Label(item.title, systemImage: item.symbol)
        }
    }

    var body: some View {
        _ = revision                                                   // 讀一下：改了設定就會重畫
        let snapOn = SnapSettings.value(SnapSettings.Item.shapes, notebook: notebookID)
        let own = SnapSettings.hasOwn(notebookID)
        return Group {
            Section {
                row(SnapSettings.Item.shapes)
            } header: {
                Text("畫完停住不放")
            } footer: {
                Text("筆畫完先不要離開螢幕，停約半秒：直的線會拉直，像三角形、四邊形、圓的會變成標準圖形。")
            }
            Section {
                row(SnapSettings.Item.lineEditor)
                row(SnapSettings.Item.shapeEditor)
                row(SnapSettings.Item.markerEditor)
            } header: {
                Text("變形後跳出調整框")
            } footer: {
                Text(snapOn ? "調整框可以再拉長、旋轉、換顏色。直線通常畫完就繼續寫，可以關掉；之後要調整，用套索圈起來，或長按螢光筆。"
                     : "要先打開上面的「停住自動拉直、變成圖形」，這三項才有作用。")
            }
            .disabled(!snapOn)                                         // 防呆：沒開自動變形就不能選
            Section {
                Text("要調整已經畫好的一筆：用手指長按它（v12.3 起任何筆跡都可以），或用套索圈起來。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let id = notebookID {
                Section {
                    Button {
                        SnapSettings.resetOwn(id)
                        revision += 1
                    } label: {
                        Label("這本筆記本回到預設", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!own)
                } footer: {
                    Text(own ? "這本筆記本有自己改過的項目，只影響這一本；沒改過的項目跟著首頁「設定」裡的預設。"
                         : "現在跟預設一樣。在這裡改的項目只會記在這本筆記本，下次打開還是這樣；其他筆記本不受影響。")
                }
            }
        }
    }
}

/// 筆記本裡的「⋯ → 停筆設定」
struct SnapSettingsSheet: View {
    let notebookID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                SnapSettingsSections(notebookID: notebookID)
            }
            .navigationTitle("停筆設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// 除錯用：看剪貼簿裡有什麼（首頁「設定 → 剪貼簿內容」）。貼上的結果不對時，截這一頁的圖給 Claude
struct ClipboardInfoView: View {
    @State private var info = "讀取中…"

    var body: some View {
        ScrollView {
            Text(info)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle("剪貼簿內容")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { info = ClipboardText.debugSummary() }
    }
}

struct NotebookMoreMenu: View {
    @ObservedObject var model: NotebookModel
    @Binding var sideOrderRaw: String
    @Binding var showDeleteConfirm: Bool
    @Binding var showTemplate: Bool
    @Binding var moveRequest: MoveRequest?
    let export: (NotebookView.ExportMode) -> Void
    // 新文字方塊的預設、頁面後面的底色：這本筆記本自己的（v12.9，見 NotebookPrefs）
    @State private var prefsTick = 0
    @State private var showPrefsReset = false
    @State private var showPrefsDefault = false

    private func prefBinding<T>(_ key: String, _ fallback: T, onSet: (() -> Void)? = nil) -> Binding<T> {
        let id = model.meta.id
        return Binding(get: {
            _ = prefsTick
            return (NotebookPrefs.object(key, id) as? T) ?? fallback
        }, set: { value in
            NotebookPrefs.set(value, key, id)
            prefsTick += 1
            onSet?()
        })
    }

    private var backdrop: Binding<String> {
        prefBinding("notebookBackdrop", "dark", onSet: { model.documentView?.applyBackdrop() })
    }
    private var textSize: Binding<Double> { prefBinding(TextDefaults.sizeKey, 14.0) }
    private var textColor: Binding<String> { prefBinding(TextDefaults.colorKey, "auto") }
    private var textBold: Binding<Bool> { prefBinding(TextDefaults.boldKey, false) }
    @State private var showHistory = false
    @State private var showSnap = false                      // 停筆設定（v12.2）
    @State private var showEngineTest = false                // 新白板引擎的測試（v12.8.8）

    /// 現在筆記本裡有的頁面（預覽歷史版本時標出「目前沒有這一頁」）
    private var currentPageIDs: Set<UUID> {
        var ids = Set<UUID>()
        for row in model.notebook.rows {
            for page in row.pages { ids.insert(page.id) }
        }
        return ids
    }

    private var currentIsPDF: Bool {
        guard let id = model.currentPageID, let page = model.page(id) else { return false }
        return page.pdf != nil
    }

    var body: some View {
        Menu {
            if model.isBoard {
                BoardMenuSection(model: model)               // 白板自己的設定（v12.8）
                Section("實驗") {
                    Button {
                        model.documentView?.flushAll()
                        showEngineTest = true
                    } label: {
                        Label("試用新白板引擎（不會存檔）", systemImage: "flask")
                    }
                }
            } else {
                pageSection
            }
            Section("編輯") {
                Button {
                    model.documentView?.pasteClipboard()
                } label: {
                    Label("貼上", systemImage: "doc.on.clipboard")
                }
            }
            Section("檢視") {
                Button {
                    model.documentView?.resetZoom()
                } label: {
                    Label("縮放回 100%", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                if !model.isBoard {
                    ZoomPresetMenu(model: model)                 // 左下角 % 點了跳到的大小（v12.8.4）
                }
                if !model.isBoard {                              // 白板鋪滿畫面，看不到頁面後面
                    Picker(selection: backdrop) {
                        Text("深灰").tag("dark")
                        Text("淺灰").tag("light")
                    } label: {
                        Label("頁面後面的底色", systemImage: "rectangle.on.rectangle")
                    }
                    .pickerStyle(.menu)
                }
            }
            snapSection
            textDefaultsSection
            prefsSection
            Section("歷史版本") {
                Button {
                    model.documentView?.manualSnapshot()
                } label: {
                    Label("保存目前版本", systemImage: "square.and.arrow.down.on.square")
                }
                Button {
                    model.documentView?.flushAll()
                    showHistory = true
                } label: {
                    Label("恢復歷史版本", systemImage: "clock.arrow.circlepath")
                }
            }
            Section("紙膠帶") {
                Button {
                    model.documentView?.setAllTapes(revealed: true)
                } label: {
                    Label("全部打開", systemImage: "eye")
                }
                Button {
                    model.documentView?.setAllTapes(revealed: false)
                } label: {
                    Label("全部遮住", systemImage: "eye.slash")
                }
            }
            if model.isBoard {
                BoardExportSection(model: model)
            } else {
                exportSection
            }
            if !model.isBoard {                                  // 白板只有一張頁面，不能刪
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("刪除目前頁面", systemImage: "trash")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(notebookID: model.meta.id, currentPages: currentPageIDs) { snapshot in
                model.documentView?.restoreSnapshot(snapshot)
            }
        }
        .sheet(isPresented: $showSnap) {
            SnapSettingsSheet(notebookID: model.meta.id)
        }
        .fullScreenCover(isPresented: $showEngineTest, onDismiss: { model.documentView?.refocus() }) {
            BoardEngineTestView(close: { showEngineTest = false })
        }
        .alert("這本的設定回到預設？", isPresented: $showPrefsReset) {
            Button("取消", role: .cancel) { }
            Button("回到預設", role: .destructive) {
                NotebookPrefs.reset(model.meta.id)
                PenBoxModel.shared.resetNotebookLasso(model.meta.id)
                prefsTick += 1
                model.documentView?.applyBackdrop()
            }
        } message: {
            Text("新文字方塊的字級、顏色、粗體，頁面後面的底色，套索要不要選到圖片、文字方塊，都改回首頁「設定」裡的預設。筆和停筆有自己的回到預設。")
        }
        .alert("把這本的設定設成預設？", isPresented: $showPrefsDefault) {
            Button("取消", role: .cancel) { }
            Button("設成預設") {
                NotebookPrefs.makeDefault(model.meta.id)
                PenBoxModel.shared.makeNotebookLassoDefault()
                prefsTick += 1
            }
        } message: {
            Text("其他沒有自己改過的筆記本也會跟著用這一組（新文字方塊的預設、底色、套索選項）。")
        }
    }

    /// 新文字方塊的預設：字級、顏色、粗體（已經有的文字方塊不會變）
    private var textDefaultsSection: some View {
        Section("新文字方塊的預設") {
            Picker(selection: textSize) {
                ForEach(TextDefaults.sizes, id: \.self) { size in
                    Text("\(size)").tag(Double(size))
                }
            } label: {
                Label("字級：\(Int(textSize.wrappedValue))", systemImage: "textformat.size")
            }
            .pickerStyle(.menu)
            Picker(selection: textColor) {
                Text("自動（深色紙白、淺色紙黑）").tag("auto")
                Text("白").tag("FFFFFF")
                Text("黑").tag("000000")
                Text("藍 3F53D9").tag("3F53D9")
                Text("紅").tag("E05A5A")
                Text("綠").tag("5FA85F")
            } label: {
                Label("顏色", systemImage: "paintpalette")
            }
            .pickerStyle(.menu)
            Toggle(isOn: textBold) {
                Label("粗體", systemImage: "bold")
            }
        }
    }

    /// 這本筆記本的設定（v12.9）：新文字方塊的預設、底色、套索選項 → 回到預設、設成預設
    private var prefsSection: some View {
        Section("這本筆記本的設定") {
            Button {
                showPrefsReset = true
            } label: {
                Label("這本的設定回到預設", systemImage: "arrow.uturn.backward")
            }
            .disabled(!NotebookPrefs.hasOwn(model.meta.id))
            Button {
                showPrefsDefault = true
            } label: {
                Label("把這本的設定設成預設", systemImage: "square.and.arrow.down")
            }
        }
    }

    /// 停筆（v12.2）：打開一張設定（這本筆記本自己的）；首頁的「設定」有同一組開關，那邊改的是預設
    private var snapSection: some View {
        Section("停筆") {
            Button {
                showSnap = true
            } label: {
                Label("停筆設定…", systemImage: "wand.and.stars")
            }
        }
    }

    private var pageSection: some View {
        Section("頁面") {
            if model.isOnSidePage {
                Button {
                    model.documentView?.returnToMain(row: model.focusRow)
                } label: {
                    Label("回到主頁", systemImage: "arrow.uturn.backward.square")
                }
            }
            Button {
                model.documentView?.flushAll()
                showTemplate = true
            } label: {
                Label("變更範本…", systemImage: "paintpalette")
            }
            .disabled(currentIsPDF)
            Button {
                if let id = model.currentPageID {
                    model.documentView?.flushAll()
                    moveRequest = MoveRequest(pageIDs: [id])
                }
            } label: {
                Label(model.isOnSidePage ? "把這張旁頁移到其他筆記本…" : "把這頁移到其他筆記本…",
                      systemImage: "tray.and.arrow.up")
            }
        }
    }

    /// 上次匯出旁頁的時間（v12.9.2，每本各自記住）
    private var lastSideExport: Date? {
        UserDefaults.standard.object(forKey: "lastSideExport." + model.meta.id.uuidString) as? Date
    }

    private var lastSideExportLabel: String {
        guard let d = lastSideExport else { return "匯出上次匯出之後改過的旁頁（還沒匯出過：全部）" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "M/d HH:mm"
        return "匯出上次匯出（\(f.string(from: d))）之後改過的旁頁"
    }

    private var exportSection: some View {
        Section("匯出") {
            Button {
                export(.allSidePages)
            } label: {
                Label("匯出所有旁頁（PDF）", systemImage: "square.and.arrow.up")
            }
            Button {
                export(.changedSidePages(since: Calendar.current.startOfDay(for: Date())))
            } label: {
                Label("匯出今天改過的旁頁", systemImage: "calendar")
            }
            Button {
                export(.changedSidePages(since: lastSideExport ?? Date.distantPast))
            } label: {
                Label(lastSideExportLabel, systemImage: "clock.arrow.circlepath")
            }
            Button {
                export(.sidePages(row: model.focusRow))
            } label: {
                Label("匯出這一頁的旁頁", systemImage: "square.and.arrow.up.on.square")
            }
            Button {
                export(.wholeNotebook)
            } label: {
                Label("匯出整本", systemImage: "doc.on.doc")
            }
            Menu {
                Picker("旁頁順序", selection: $sideOrderRaw) {
                    Text("先右後左（右1、右2…再左1、左2…）").tag(SideOrder.rightFirst.rawValue)
                    Text("先左後右（左1、左2…再右1、右2…）").tag(SideOrder.leftFirst.rawValue)
                    Text("照畫面由左到右").tag(SideOrder.visual.rawValue)
                }
            } label: {
                Label("匯出順序", systemImage: "arrow.left.arrow.right")
            }
        }
    }
}


// MARK: - 4. 筆記本畫面（SwiftUI 外框）

@MainActor
final class NotebookModel: ObservableObject {
    let meta: NotebookMeta
    @Published var notebook: NotebookData
    @Published var focusRow = 0
    @Published var focusPage = 0
    @Published var canPaste = false
    @Published var insertRequest: InsertKind?          // 要打開哪個選取畫面（相簿、相機、檔案；v12.3）
    @Published var shareFile: ExportFile?              // 要分享出去的檔案（白板區塊的匯出；v12.7）

    /// 這是白板（只有一張大頁面）
    var isBoard: Bool { notebook.board ?? false }
    @Published var canUndo = false
    @Published var cropActive = false                  // 截圖工具開著
    @Published var canRedo = false
    weak var documentView: NotebookView?
    /// 刪掉的頁放進最近刪除（v12.9.2）：由編輯畫面接到首頁的資料（NotebookView 拿不到首頁）
    var trashPages: (@MainActor ([PageRow]) -> Void)?

    init(meta: NotebookMeta) {
        self.meta = meta
        self.notebook = Store.loadNotebook(meta.id)
    }

    func save() { Store.saveNotebook(notebook, id: meta.id) }

    /// 目前看的那一頁（主頁或旁頁）
    var currentPageID: UUID? {
        guard notebook.rows.indices.contains(focusRow) else { return nil }
        let row = notebook.rows[focusRow]
        return row.pages.indices.contains(focusPage) ? row.pages[focusPage].id : nil
    }

    var isBookmarked: Bool {
        guard let id = currentPageID else { return false }
        return notebook.bookmarks?.contains(id) ?? false
    }

    func toggleBookmark() {
        guard let id = currentPageID else { return }
        var marks = notebook.bookmarks ?? []
        if let i = marks.firstIndex(of: id) { marks.remove(at: i) } else { marks.append(id) }
        notebook.bookmarks = marks
        save()
    }

    func toggleBookmark(pageID id: UUID) {
        var marks = notebook.bookmarks ?? []
        if let i = marks.firstIndex(of: id) { marks.remove(at: i) } else { marks.append(id) }
        notebook.bookmarks = marks
        save()
    }

    func addOutline(title: String, pageID: UUID) {
        var items = notebook.outline ?? []
        items.append(OutlineItem(title: title, pageID: pageID))
        notebook.outline = items
        save()
    }

    func removeBookmark(_ id: UUID) {
        notebook.bookmarks?.removeAll { $0 == id }
        save()
    }

    /// 某一頁在第幾列、列裡的第幾張
    func location(of pageID: UUID) -> (row: Int, page: Int)? {
        for (r, row) in notebook.rows.enumerated() {
            if let p = row.pages.firstIndex(where: { $0.id == pageID }) { return (r, p) }
        }
        return nil
    }

    /// 頁碼文字，例如「3」「3 右 1」
    func label(row r: Int, page p: Int) -> String {
        guard notebook.rows.indices.contains(r) else { return "" }
        let d = p - notebook.rows[r].mainIndex
        if d < 0 { return "\(r + 1)　左 \(-d)" }
        if d > 0 { return "\(r + 1)　右 \(d)" }
        return "\(r + 1)"
    }

    /// parent：加在哪一項底下（v12.11.0）；nil：最外層
    func addOutline(title: String, parent: UUID? = nil) {
        guard let id = currentPageID else { return }
        var items = notebook.outline ?? []
        var item = OutlineItem(title: title, pageID: id)
        item.parentID = parent
        items.append(item)
        if let parent = parent, let i = items.firstIndex(where: { $0.id == parent }) { items[i].collapsed = nil }   // 上一層打開，才看得到剛加的
        notebook.outline = items
        save()
    }

    /// 收合／展開
    func toggleOutline(_ id: UUID) {
        guard let i = notebook.outline?.firstIndex(where: { $0.id == id }) else { return }
        let folded = notebook.outline?[i].collapsed == true
        notebook.outline?[i].collapsed = folded ? nil : true
        save()
    }

    func renameOutline(_ id: UUID, to title: String) {
        guard let i = notebook.outline?.firstIndex(where: { $0.id == id }) else { return }
        notebook.outline?[i].title = title
        save()
    }

    func removeOutline(_ id: UUID) {
        // 底下的項目不跟著刪：往上接到它原本的上一層
        let items = notebook.outline ?? []
        let parent = items.first(where: { $0.id == id })?.parentID
        for i in items.indices where items[i].parentID == id { notebook.outline?[i].parentID = parent }
        notebook.outline?.removeAll { $0.id == id }
        save()
    }

    func texts(of pageID: UUID) -> [TextBox] {
        guard let loc = location(of: pageID) else { return [] }
        return notebook.rows[loc.row].pages[loc.page].texts ?? []
    }

    func setTexts(_ texts: [TextBox], pageID: UUID) {
        guard let loc = location(of: pageID) else { return }
        if notebook.rows[loc.row].pages[loc.page].texts ?? [] != texts {
            notebook.rows[loc.row].pages[loc.page].modified = Date()
            ActivityLog.touch(pageID: pageID)                  // 修改紀錄（v12.9.5）
        }
        notebook.rows[loc.row].pages[loc.page].texts = texts
        save()
    }

    func images(of pageID: UUID) -> [ImageBox] {
        guard let loc = location(of: pageID) else { return [] }
        return notebook.rows[loc.row].pages[loc.page].images ?? []
    }

    func setImages(_ images: [ImageBox], pageID: UUID) {
        guard let loc = location(of: pageID) else { return }
        if notebook.rows[loc.row].pages[loc.page].images ?? [] != images {
            notebook.rows[loc.row].pages[loc.page].modified = Date()
            ActivityLog.touch(pageID: pageID)                  // 修改紀錄（v12.9.5）
        }
        notebook.rows[loc.row].pages[loc.page].images = images
        save()
    }

    func tapes(of pageID: UUID) -> [TapeBox] {
        guard let loc = location(of: pageID) else { return [] }
        return notebook.rows[loc.row].pages[loc.page].tapes ?? []
    }

    func setTapes(_ tapes: [TapeBox], pageID: UUID) {
        guard let loc = location(of: pageID) else { return }
        if notebook.rows[loc.row].pages[loc.page].tapes ?? [] != tapes {
            notebook.rows[loc.row].pages[loc.page].modified = Date()
            ActivityLog.touch(pageID: pageID)                  // 修改紀錄（v12.9.5）
        }
        notebook.rows[loc.row].pages[loc.page].tapes = tapes
        save()
    }

    func page(_ id: UUID) -> NotePage? {
        guard let loc = location(of: id) else { return nil }
        return notebook.rows[loc.row].pages[loc.page]
    }

    var isOnSidePage: Bool {
        guard notebook.rows.indices.contains(focusRow) else { return false }
        return focusPage != notebook.rows[focusRow].mainIndex
    }

    /// 右上角的頁碼，例如「3 / 10　右 2」
    var pageLabel: String {
        guard notebook.rows.indices.contains(focusRow) else { return "" }
        let row = notebook.rows[focusRow]
        var text = "\(focusRow + 1) / \(notebook.rows.count)"
        let d = focusPage - row.mainIndex
        if d < 0 { text += "　左 \(-d)" }
        if d > 0 { text += "　右 \(d)" }
        return text
    }

    /// 移出頁面的說明（照實際要搬的頁）：「第 3 頁（含 2 張旁頁）」「第 3 頁（只有主頁）」「3　右 1」「共 5 頁」
    func moveSummary(_ pageIDs: [UUID]) -> String {
        let selected = Set(pageIDs)
        var hits: [(row: Int, page: Int)] = []
        for (r, row) in notebook.rows.enumerated() {
            for (p, page) in row.pages.enumerated() where selected.contains(page.id) { hits.append((r, p)) }
        }
        guard let first = hits.first else { return "沒有選到頁面" }
        if hits.count == 1 {
            let row = notebook.rows[first.row]
            if first.page == row.mainIndex {
                return row.pages.count > 1 ? "第 \(first.row + 1) 頁（只有主頁）" : "第 \(first.row + 1) 頁"
            }
            return label(row: first.row, page: first.page)
        }
        let rowsHit = Set(hits.map { $0.row })
        if rowsHit.count == 1 {
            let row = notebook.rows[first.row]
            if hits.count == row.pages.count {
                return "第 \(first.row + 1) 頁（含 \(row.pages.count - 1) 張旁頁）"
            }
        }
        return "共 \(hits.count) 頁"
    }

    /// 加上「這些主頁的所有旁頁」
    func withSidePages(_ pageIDs: [UUID]) -> [UUID] {
        var result = pageIDs
        var seen = Set(pageIDs)
        for row in notebook.rows where row.pages.indices.contains(row.mainIndex) {
            guard seen.contains(row.pages[row.mainIndex].id) else { continue }
            for page in row.pages where !seen.contains(page.id) {
                result.append(page.id)
                seen.insert(page.id)
            }
        }
        return result
    }

    /// 這些頁裡，主頁還有幾張旁頁沒選到（移出時問要不要一起搬）
    func unselectedSideCount(_ pageIDs: [UUID]) -> Int {
        withSidePages(pageIDs).count - Set(pageIDs).count
    }

    var deleteMessage: String {
        guard notebook.rows.indices.contains(focusRow) else { return "刪除目前頁面？" }
        let row = notebook.rows[focusRow]
        if focusPage == row.mainIndex && row.pages.count > 1 {
            return "刪除主頁會連同 \(row.pages.count - 1) 張旁頁一起刪除，無法復原。"
        }
        return "刪除目前頁面？無法復原。"
    }
}

struct NotebookEditorView: View {
    @EnvironmentObject private var library: LibraryModel
    @StateObject private var model: NotebookModel
    @State private var showOverview = false
    @State private var showDeleteConfirm = false
    @State private var showTemplate = false
    @State private var exportFile: ExportFile?
    @State private var nothingToExport = false
    @AppStorage("sideExportOrder") private var sideOrderRaw = SideOrder.rightFirst.rawValue
    @ObservedObject private var penBox = PenBoxModel.shared
    @State private var showPanel = false
    @State private var moveRequest: MoveRequest?            // 移出頁面（⋯ → 移到其他筆記本）
    @State private var showPins = false                     // 白板的圖釘清單（v12.7）
    @State private var showFrames = false                   // 白板的區塊清單
    @AppStorage("tabsCollapsed") private var tabsCollapsed = false      // 分頁那一排收起來（v12.8.4）
    private let onClose: (() -> Void)?

    init(meta: NotebookMeta, onClose: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: NotebookModel(meta: meta))
        self.onClose = onClose
    }

    /// 分頁下面那一排工具（v12.8.4，以前在系統的工具列裡）
    private var toolRow: some View {
        HStack(spacing: 12) {
            if tabsCollapsed {
                closeAndTitle                                      // 分頁收起來時：左上「× │ 名稱」（照 GUGA）
            }
            if !model.isBoard {
                toolCapsule { leadingTools }
            }
            Spacer(minLength: 0)
            toolCapsule { trailingTools }
        }
        .tint(Color.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background {
            if !model.isBoard {
                Color.black.ignoresSafeArea(edges: .top)      // 筆記本：黑色的工具列（跟以前系統的一樣）；白板：浮在白板上
            }
        }
    }

    /// 一個膠囊（v12.8.7：符號粗一點；iOS 26 以上用系統的玻璃，跟以前系統工具列的樣子一樣）
    @ViewBuilder
    private func toolCapsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let row = HStack(spacing: model.isBoard ? 22 : 30) {      // v12.9.8：筆記本的按鈕比較多，間隔拉開
            content()
        }
        .font(.system(size: 19, weight: .semibold))
        .padding(.horizontal, 18)
        .frame(height: 46)
        row.modifier(GlassCapsule())
    }

    /// 分頁收起來時左上角（v12.8.8，照 GUGA）：× 回首頁，右邊是名稱
    private var closeAndTitle: some View {
        HStack(spacing: 14) {
            Button {
                library.goHome()
            } label: {
                Image(systemName: "xmark")
            }
            Rectangle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 1, height: 22)
            Text(model.meta.title.count > 16 ? String(model.meta.title.prefix(15)) + "…" : model.meta.title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 19, weight: .semibold))
        .padding(.horizontal, 18)
        .frame(height: 46)
        .modifier(GlassCapsule())
    }

    /// 分頁收起來時：﹀ 放回來（放在 ＋ 的右邊）
    @ViewBuilder
    private var expandTabsButton: some View {
        if tabsCollapsed {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { tabsCollapsed = false }
            } label: {
                Image(systemName: "chevron.down")
            }
        }
    }

    /// 左邊：面板（顯示頁數）、概覽、剪刀（白板沒有）
    @ViewBuilder
    private var leadingTools: some View {
        Button {
            model.documentView?.flushAll()
            withAnimation(.easeOut(duration: 0.2)) { showPanel.toggle() }
        } label: {
            Label(model.pageLabel, systemImage: "square.grid.2x2")
                .labelStyle(.titleAndIcon)
                .monospacedDigit()
        }
        Button {
            model.documentView?.flushAll()
            showOverview = true
        } label: {
            Image(systemName: "rectangle.split.3x3")
        }
        CropButton(model: model)
    }

    /// 右邊：復原、重做；白板：圖釘、區塊、＋；筆記本：書籤、新增頁面；最後是 ⋯
    @ViewBuilder
    private var trailingTools: some View {
        Button {
            model.documentView?.performUndo()
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .disabled(!model.canUndo)
        Button {
            model.documentView?.performRedo()
        } label: {
            Image(systemName: "arrow.uturn.forward")
        }
        .disabled(!model.canRedo)
        if model.isBoard {
            BoardToolbarButtons(model: model, showPins: $showPins, showFrames: $showFrames)
            expandTabsButton
        } else {
            Button {
                model.toggleBookmark()
            } label: {
                Image(systemName: model.isBookmarked ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(model.isBookmarked ? Color.orange : Color.primary)
            }
            // 筆記本的圖釘清單（v12.9）
            Button {
                model.documentView?.flushAll()
                showPins = true
            } label: {
                Image(uiImage: PinStyle.toolbarIcon)
                    .renderingMode(.template)
            }
            .popover(isPresented: $showPins) {
                PinListView(model: model, close: { showPins = false })
            }
            NewPageMenu(model: model)
            expandTabsButton
        }
        if model.isBoard {
            BoardSettingsButton(model: model)                 // 白板：齒輪 → 白板樣式的面板（v12.9.1，照 GUGA）
        } else {
            NotebookMoreMenu(model: model, sideOrderRaw: $sideOrderRaw,
                             showDeleteConfirm: $showDeleteConfirm, showTemplate: $showTemplate,
                             moveRequest: $moveRequest,
                             export: { mode in export(mode) })
        }
    }

    var body: some View {
        DocumentRepresentable(model: model)
            // 白板（v12.8）：白板一路鋪到最上面，工具列浮在白板上（上面不要有一條黑色）
            .ignoresSafeArea(edges: model.isBoard ? Edge.Set.all : Edge.Set.bottom)
            .overlay {
                // 筆盒：拖把手可以停靠在上下左右
                GeometryReader { geo in
                    PenBoxView(box: penBox, containerSize: geo.size)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: penBox.alignment)
                }
                .coordinateSpace(name: "penbox")
                .ignoresSafeArea(.keyboard)                    // v12.9.8：鍵盤出來時筆盒留在原地，不要被推上去蓋住文字工具列
            }
            .overlay(alignment: .topLeading) {
                // 左邊的面板：縮略圖、書籤、大綱
                if showPanel {
                    NotePanel(model: model, close: { withAnimation(.easeOut(duration: 0.2)) { showPanel = false } },
                          onMove: { id in
                              model.documentView?.flushAll()
                              moveRequest = MoveRequest(pageIDs: [id])
                          })
                        .frame(width: 340)
                        .frame(maxHeight: .infinity)
                        .padding(12)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            // v12.8.4：系統的工具列（navigation bar）會被上面的分頁蓋住、看不到，改成自己排：
            // 最上面一排分頁，下面一排工具（兩個膠囊：左邊面板、概覽、剪刀；右邊復原、重做…⋯）。白板的話兩排都浮在白板上
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if !tabsCollapsed { NotebookTabBar() }      // 分頁那一排可以收起來（︿）
                    toolRow
                }
                .background(
                    // 量上面兩排的高度，告訴白板：那一塊的觸控交給按鈕（v12.8.8）
                    GeometryReader { g in
                        Color.clear
                            .onAppear { model.documentView?.topBarHeight = g.size.height }
                            .onChange(of: g.size.height) { _, h in model.documentView?.topBarHeight = h }
                    }
                )
            }
            .fullScreenCover(isPresented: $showOverview, onDismiss: { model.documentView?.refocus() }) {
                OverviewSheet(model: model, library: library)
            }
            .sheet(item: $moveRequest) { request in
                MovePagesSheet(library: library, sourceID: model.meta.id,
                               summary: { sides in model.moveSummary(sides ? model.withSidePages(request.pageIDs) : request.pageIDs) },
                               sideCount: request.askSides ? model.unselectedSideCount(request.pageIDs) : 0) { target, sides in
                    let ids = request.askSides && sides ? model.withSidePages(request.pageIDs) : request.pageIDs
                    let count = model.documentView?.movePages(ids, to: target.id) ?? 0
                    if count > 0 {
                        library.touchNotebook(target.id)
                        model.documentView?.showMessage("tray.and.arrow.up", "已移到「\(target.title)」\(count) 頁")
                    }
                }
            }
            .sheet(item: $exportFile, onDismiss: { model.documentView?.refocus() }) { file in
                ShareSheet(items: [file.url])
            }
            .sheet(item: $model.shareFile, onDismiss: { model.documentView?.refocus() }) { file in
                ShareSheet(items: [file.url])
            }
            .sheet(isPresented: $showTemplate) {
                templateSheet
            }
            .alert("沒有可以匯出的旁頁（或這段時間沒有改過）", isPresented: $nothingToExport) {
                Button("好", role: .cancel) { }
            }
            .confirmationDialog(model.deleteMessage, isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("刪除", role: .destructive) { model.documentView?.deleteCurrentPage() }
            }
            .overlay(alignment: .top) {
                // 最近刪除裡打開的（v12.6）：只能看
                if model.meta.deletedAt != nil {
                    Label("最近刪除裡的筆記本只能看；要改請先在「最近刪除」長按復原", systemImage: "lock")
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.regularMaterial))
                        .padding(.top, 8)
                }
            }
            .modifier(InsertPickers(model: model))               // 相簿、相機、檔案的選取畫面（v12.3）
            .onAppear {
                if SelfTest.scene == "outline" {                 // 自動測試：打開左邊面板（NotePanel 會自己切到大綱）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showPanel = true }
                }
                penBox.onBoard = model.isBoard
                penBox.enterNotebook(model.meta.id)              // 這本筆記本自己的筆（v12.3）
                applyPenBoxTool()
                let lib = library
                let title = model.meta.title
                let folder = model.meta.folderID
                model.trashPages = { [weak lib] rows in
                    lib?.trashDeletedPages(rows, title: title, folder: folder)
                }
            }
            .onChange(of: penBox.version) { _, _ in
                applyPenBoxTool()
            }
            .onChange(of: penBox.dock) { _, _ in
                model.documentView?.layoutBoardHUD()           // 白板左下角：筆盒停在下面時讓開
            }
            .onChange(of: penBox.minimized) { _, _ in
                model.documentView?.layoutBoardHUD()
            }
            .onDisappear {
                model.documentView?.flushAll()
                penBox.leaveNotebook(model.meta.id)
                if model.meta.deletedAt == nil { library.touchNotebook(model.meta.id) }
            }
    }

    private func applyPenBoxTool() {
        guard let doc = model.documentView else { return }
        if penBox.selection == .frame {                        // 區塊工具（v12.10）
            doc.setTapeMode(false)
            doc.setLassoMode(false)
            doc.startFrameMode()
            return
        }
        doc.leaveFrameTool()
        if penBox.selection == .lasso {
            doc.setTapeMode(false)
            doc.setLassoMode(true)
            return
        }
        if penBox.selection == .tape {
            doc.setLassoMode(false)
            doc.setTapeMode(true)
            return
        }
        doc.setTapeMode(false)
        if penBox.selection != .apple { doc.setLassoMode(false) }
        if let tool = penBox.currentTool { doc.setTool(tool, adaptive: penBox.currentAdaptive) }
    }

    /// 變更範本的視窗（目前這一頁）
    @ViewBuilder
    private var templateSheet: some View {
        if let id = model.currentPageID, let page = model.page(id) {
            ChangeTemplateSheet(page: page) { paper, cover, toAll, size, swapInk in
                model.documentView?.applyTemplate(paper: paper, cover: cover, toAll: toAll, size: size, swapInk: swapInk)
            }
        }
    }

    private func export(_ mode: NotebookView.ExportMode) {
        let order = SideOrder(rawValue: sideOrderRaw) ?? .rightFirst
        if let url = model.documentView?.exportPDF(mode, order: order) {
            exportFile = ExportFile(url: url)
        } else {
            nothingToExport = true
        }
    }
}

// MARK: - 左邊的面板：縮略圖、書籤、大綱

/// 面板裡的縮圖快取（每次打開面板重新產生，所以會是最新的筆跡）
@MainActor
final class ThumbStore: ObservableObject {
    private var cache: [UUID: UIImage] = [:]

    func image(for page: NotePage, width: CGFloat) -> UIImage {
        if let image = cache[page.id] { return image }
        let image = Thumbnail.image(for: page, width: width)
        cache[page.id] = image
        return image
    }
}

/// 大綱面板上的一列（我的大綱；v12.11.0）
struct OutlineLine: Identifiable {
    let item: OutlineItem
    let row: Int
    let page: Int
    let depth: Int
    let hasChildren: Bool
    var id: UUID { item.id }
}

/// 大綱面板上的一列（PDF 自帶的目錄）
struct PDFOutlineLine: Identifiable {
    let id: UUID
    let title: String
    let row: Int
    let page: Int
    let depth: Int
    let hasChildren: Bool
}

/// 往左滑露出來的按鈕
struct SwipeRowAction {
    let symbol: String
    let tint: Color
    let background: Color
    let run: () -> Void
}

/// 一列內容，往左滑露出右邊的按鈕（v12.11.0，大綱用；照 GUGA）。同一時間只有一列是滑開的（openID）
struct SwipeRow<Content: View>: View {
    let id: UUID
    @Binding var openID: UUID?
    let actions: [SwipeRowAction]
    @ViewBuilder let content: () -> Content
    @GestureState private var drag: CGFloat = 0

    private var actionsWidth: CGFloat { CGFloat(actions.count) * 54 }

    var body: some View {
        let open = openID == id
        let shift = min(0, max(-actionsWidth - 24, (open ? -actionsWidth : 0) + drag))
        return content()
            .overlay {
                if open {
                    // 滑開的時候點內容：先收回去
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { openID = nil } }
                }
            }
            .offset(x: shift)
            .background(alignment: .trailing) {
                HStack(spacing: 0) {
                    ForEach(actions.indices, id: \.self) { i in
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { openID = nil }
                            actions[i].run()
                        } label: {
                            Image(systemName: actions[i].symbol)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(actions[i].tint)
                                .frame(width: 54)
                                .frame(maxHeight: .infinity)
                                .background(actions[i].background)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: max(-shift, 0), alignment: .trailing)
                .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .simultaneousGesture(
                DragGesture(minimumDistance: 16)
                    .updating($drag) { value, state, _ in
                        if abs(value.translation.width) > abs(value.translation.height) { state = value.translation.width }
                    }
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        let end = (open ? -actionsWidth : 0) + value.predictedEndTranslation.width
                        withAnimation(.easeOut(duration: 0.2)) {
                            if end < -actionsWidth / 2 {
                                openID = id
                            } else if openID == id {
                                openID = nil
                            }
                        }
                    }
            )
    }
}

/// PDF 自帶的目錄（書籤）
struct PDFOutlineEntry: Identifiable {
    let id = UUID()
    let title: String
    let pageID: UUID
    let depth: Int
}

@MainActor
enum PDFOutlineReader {
    static func entries(for notebook: NotebookData) -> [PDFOutlineEntry] {
        // 每個 PDF 檔的第幾頁 → 筆記本裡的哪一頁；檔案照在筆記本裡出現的順序
        var files: [String] = []
        var map: [String: [Int: UUID]] = [:]
        for row in notebook.rows {
            for page in row.pages {
                guard let ref = page.pdf else { continue }
                if map[ref.file] == nil { files.append(ref.file) }
                map[ref.file, default: [:]][ref.index] = page.id
            }
        }
        var result: [PDFOutlineEntry] = []
        for file in files {
            guard let doc = PDFStore.document(file), let root = doc.outlineRoot, let pages = map[file] else { continue }
            func walk(_ item: PDFOutline, depth: Int) {
                for i in 0..<item.numberOfChildren {
                    guard let child = item.child(at: i) else { continue }
                    let target = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page
                    if let target = target, let pageID = pages[doc.index(for: target)] {
                        result.append(PDFOutlineEntry(title: child.label ?? "", pageID: pageID, depth: depth))
                    }
                    walk(child, depth: depth + 1)
                }
            }
            walk(root, depth: 0)
        }
        return result
    }
}

/// 輸入一段文字的小視窗（可以用鍵盤，也可以用 Apple Pencil 直接在框裡手寫）
@MainActor
enum TextPrompt {
    static func show(title: String, initial: String, done: @escaping (String) -> Void) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = (scene.windows.first { $0.isKeyWindow } ?? scene.windows.first)?.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController { top = next }
        let alert = UIAlertController(title: title, message: "鍵盤叫不出來的話，可以用 Apple Pencil 直接在框裡寫字。",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.text = initial
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "確定", style: .default) { _ in
            let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            done(text.isEmpty ? initial : text)
        })
        top.present(alert, animated: true)
    }
}

struct NotePanel: View {
    @ObservedObject var model: NotebookModel
    let close: () -> Void
    var onMove: (UUID) -> Void = { _ in }          // 移到其他筆記本（這一頁）
    @State private var dropRow: UUID?              // 縮略圖拖曳排列：正停在哪一頁上
    @State private var tab = 0
    @StateObject private var thumbs = ThumbStore()
    @State private var pdfOutline: [PDFOutlineEntry] = []
    @State private var pdfFolded: Set<UUID> = []      // PDF 目錄收合起來的項目（v12.11.0；只記到面板關掉）
    @State private var openOutline: UUID?             // 往左滑開、露出按鈕的那一項
    @State private var pendingDelete: (row: Int, page: Int)?
    @State private var showDelete = false
    @State private var sideRowID: UUID?               // 「旁頁」分頁要看哪一列；沒指定＝目前這一列

    private var deleteTitle: String {
        guard let d = pendingDelete, model.notebook.rows.indices.contains(d.row) else { return "刪除這一頁？" }
        let row = model.notebook.rows[d.row]
        if d.page == row.mainIndex && row.pages.count > 1 {
            return "刪除主頁會連同 \(row.pages.count - 1) 張旁頁一起刪除，無法復原。"
        }
        return "刪除這一頁？無法復原。"
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("縮略圖").tag(0)
                Text("旁頁").tag(3)
                Text("書籤").tag(1)
                Text("大綱").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(12)

            switch tab {
            case 0: thumbnailsTab
            case 3: sidePagesTab
            case 1: bookmarksTab
            default: outlineTab
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .onAppear {
            pdfOutline = PDFOutlineReader.entries(for: model.notebook)
            if SelfTest.scene == "outline" {                     // 自動測試：直接看大綱，第一項滑開
                tab = 2
                openOutline = model.notebook.outline?.first?.id
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $showDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                guard let d = pendingDelete, model.notebook.rows.indices.contains(d.row) else { return }
                if d.page == model.notebook.rows[d.row].mainIndex {
                    model.documentView?.deleteRow(d.row)
                } else {
                    model.documentView?.deleteSidePage(row: d.row, page: d.page)
                }
                pendingDelete = nil
            }
        }
    }

    /// 縮圖下面的「⋯」：大綱、書籤、新增頁面、刪除
    private func pageMenu(row r: Int, page p: Int) -> some View {
        let page = model.notebook.rows[r].pages[p]
        let marked = model.notebook.bookmarks?.contains(page.id) ?? false
        return Menu {
            Button {
                TextPrompt.show(title: "添加到大綱", initial: "第 \(r + 1) 頁") { text in
                    model.addOutline(title: text, pageID: page.id)
                }
            } label: {
                Label("添加到大綱", systemImage: "list.bullet.indent")
            }
            Button {
                model.toggleBookmark(pageID: page.id)
            } label: {
                Label(marked ? "移除書籤" : "加入書籤", systemImage: marked ? "bookmark.slash" : "bookmark")
            }
            if model.notebook.rows[r].pages.count > 1 {
                Button {
                    sideRowID = model.notebook.rows[r].id
                    tab = 3
                } label: {
                    Label("看這一頁的旁頁", systemImage: "square.on.square")
                }
            }
            Button {
                onMove(page.id)
            } label: {
                Label("移到其他筆記本…", systemImage: "tray.and.arrow.up")
            }
            Divider()
            Button {
                model.documentView?.insertRow(at: r)
            } label: {
                Label("在上方新增頁面", systemImage: "arrow.up.doc")
            }
            Button {
                model.documentView?.insertRow(at: r + 1)
            } label: {
                Label("在下方新增頁面", systemImage: "arrow.down.doc")
            }
            Divider()
            Button(role: .destructive) {
                pendingDelete = (r, p)
                showDelete = true
            } label: {
                Label("刪除這一頁", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 28)
                .contentShape(Rectangle())
        }
    }

    // 一張縮圖 + 頁碼；目前所在的頁用藍框
    private func cell(row r: Int, page p: Int) -> some View {
        let page = model.notebook.rows[r].pages[p]
        let current = r == model.focusRow && p == model.focusPage
        let marked = model.notebook.bookmarks?.contains(page.id) ?? false
        let row = model.notebook.rows[r]
        let sideCount = p == row.mainIndex ? row.pages.count - 1 : 0
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                model.documentView?.jump(toRow: r, page: p)
            } label: {
                Image(uiImage: thumbs.image(for: page, width: 140))
                    .resizable()
                    .scaledToFit()
                    .overlay(alignment: .bottomLeading) {
                        // 這一頁有幾張旁頁
                        if sideCount > 0 {
                            Label("\(sideCount) 張旁頁", systemImage: "square.on.square")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.black.opacity(0.7)))
                                .padding(5)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if marked {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(.orange)
                                .padding(4)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(current ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: current ? 3 : 1)
                    )
            }
            .buttonStyle(.plain)
            HStack {
                Text(model.label(row: r, page: p))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                pageMenu(row: r, page: p)
            }
        }
    }

    // 縮略圖：每一列的主頁
    private var thumbnailsTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Array(model.notebook.rows.enumerated()), id: \.element.id) { r, row in
                        cell(row: r, page: row.mainIndex)
                            .id(row.id)
                            // 長按拖到另一頁上：整列（含旁頁）移到那個位置
                            .draggable(row.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let text = items.first, let id = UUID(uuidString: text) else { return false }
                                model.documentView?.moveRow(id: id, toIndex: r)
                                return true
                            } isTargeted: { on in
                                if on { dropRow = row.id } else if dropRow == row.id { dropRow = nil }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(dropRow == row.id ? Color.orange : Color.clear, lineWidth: 3)
                            )
                    }
                }
                .padding(12)
            }
            .onAppear {
                if model.notebook.rows.indices.contains(model.focusRow) {
                    proxy.scrollTo(model.notebook.rows[model.focusRow].id, anchor: .center)
                }
            }
        }
    }

    /// 旁頁：一列的所有頁面（由左到右），點一下跳過去。旁頁很多時不用一張一張滑
    private var sidePagesTab: some View {
        let rows = model.notebook.rows
        let fallback = rows.indices.contains(model.focusRow) ? model.focusRow : 0
        let r: Int = sideRowID.flatMap { id in rows.firstIndex(where: { $0.id == id }) } ?? fallback
        return Group {
            if rows.indices.contains(r) {
                sidePagesList(row: r)
            } else {
                Color.clear
            }
        }
    }

    private func sidePagesList(row r: Int) -> some View {
        let row = model.notebook.rows[r]
        return VStack(spacing: 0) {
            HStack {
                Text("第 \(r + 1) 頁：\(row.pages.count - 1) 張旁頁")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if sideRowID != nil {
                    Button("看目前這一頁") { sideRowID = nil }
                        .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            if row.pages.count <= 1 {
                VStack(spacing: 8) {
                    Image(systemName: "square.on.square")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("這一頁還沒有旁頁")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(row.pages.indices, id: \.self) { p in
                                cell(row: r, page: p).id(row.pages[p].id)
                            }
                        }
                        .padding(12)
                    }
                    .onAppear {
                        if r == model.focusRow, row.pages.indices.contains(model.focusPage) {
                            proxy.scrollTo(row.pages[model.focusPage].id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // 書籤：照頁面順序排；長按可以拿掉
    private var bookmarksTab: some View {
        let marks = Set(model.notebook.bookmarks ?? [])
        var items: [(Int, Int, UUID)] = []
        for (r, row) in model.notebook.rows.enumerated() {
            for (p, page) in row.pages.enumerated() where marks.contains(page.id) { items.append((r, p, page.id)) }
        }
        return Group {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bookmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("按右上角的書籤，把這一頁加進來")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(items, id: \.2) { item in
                            cell(row: item.0, page: item.1)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        model.removeBookmark(item.2)
                                    } label: {
                                        Label("移除書籤", systemImage: "bookmark.slash")
                                    }
                                }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    // 大綱：自己加的 + PDF 自帶的；點一下跳過去
    private var outlineTab: some View {
        let mine = outlineTree()
        let mineIndent = mine.contains { $0.hasChildren || $0.depth > 0 }
        let fromPDF = pdfLines()
        let pdfIndent = fromPDF.contains { $0.hasChildren }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if mine.isEmpty && fromPDF.isEmpty {
                        Text("還沒有大綱。按下面的「添加大綱」，把目前這一頁加進來。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                    if !mine.isEmpty {
                        sectionTitle("我的大綱（往左滑：改名、加下一層、刪除）")
                        ForEach(mine) { line in
                            // v12.11.0：往左滑露出三顆按鈕（照 GUGA）；長按的選單也留著
                            SwipeRow(id: line.id, openID: $openOutline, actions: [
                                SwipeRowAction(symbol: "square.and.pencil", tint: Color.primary, background: Color.gray.opacity(0.35)) {
                                    renameOutline(line.item)
                                },
                                SwipeRowAction(symbol: "plus", tint: Color.black, background: Color.yellow) {
                                    addOutlineChild(line.item)
                                },
                                SwipeRowAction(symbol: "trash.fill", tint: Color.white, background: Color.red) {
                                    model.removeOutline(line.id)
                                }
                            ]) {
                                outlineRow(title: line.item.title, row: line.row, page: line.page, depth: line.depth,
                                           folded: line.hasChildren ? (line.item.collapsed == true) : nil,
                                           reserveChevron: mineIndent) {
                                    model.toggleOutline(line.id)
                                }
                            }
                            .contextMenu {
                                Button {
                                    renameOutline(line.item)
                                } label: {
                                    Label("重新命名", systemImage: "pencil")
                                }
                                Button {
                                    addOutlineChild(line.item)
                                } label: {
                                    Label("在底下加一項（目前這一頁）", systemImage: "plus")
                                }
                                Button(role: .destructive) {
                                    model.removeOutline(line.id)
                                } label: {
                                    Label("刪除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    if !fromPDF.isEmpty {
                        sectionTitle("PDF 自帶的目錄")
                        ForEach(fromPDF) { line in
                            outlineRow(title: line.title, row: line.row, page: line.page, depth: line.depth,
                                       folded: line.hasChildren ? pdfFolded.contains(line.id) : nil,
                                       reserveChevron: pdfIndent) {
                                if pdfFolded.contains(line.id) { pdfFolded.remove(line.id) } else { pdfFolded.insert(line.id) }
                            }
                        }
                    }
                }
                .padding(12)
            }
            Divider()
            Button {
                let initial = "第 \(model.focusRow + 1) 頁"
                TextPrompt.show(title: "添加大綱", initial: initial) { text in
                    model.addOutline(title: text)
                }
            } label: {
                Label("添加大綱", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    /// 大綱的一列。folded：有下一層的項目，目前是不是收合（左邊多一個箭頭，點它收合／展開）；nil：沒有下一層。
    /// reserveChevron：這份大綱有分層，沒有箭頭的列也留箭頭的位置，標題才會對齊
    private func outlineRow(title: String, row r: Int, page p: Int, depth: Int, folded: Bool? = nil,
                            reserveChevron: Bool = false, toggle: @escaping () -> Void = { }) -> some View {
        HStack(spacing: 0) {
            if let folded = folded {
                Button(action: toggle) {
                    Image(systemName: folded ? "chevron.right" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                model.documentView?.jump(toRow: r, page: p)
            } label: {
                HStack {
                    Text(title.isEmpty ? "（沒有標題）" : title)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Text(model.label(row: r, page: p))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                .padding(.leading, folded != nil ? 0 : (reserveChevron ? 30 : 12))
                .padding(.trailing, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.1)))
    }

    private func renameOutline(_ item: OutlineItem) {
        TextPrompt.show(title: "重新命名", initial: item.title) { text in
            model.renameOutline(item.id, to: text)
        }
    }

    /// 在這一項底下加一項，指到目前這一頁
    private func addOutlineChild(_ item: OutlineItem) {
        TextPrompt.show(title: "加在「\(item.title)」底下", initial: "第 \(model.focusRow + 1) 頁") { text in
            model.addOutline(title: text, parent: item.id)
        }
    }

    /// 我的大綱排成一層一層（v12.11.0）：同一層照頁面先後；收合的不列出底下的
    private func outlineTree() -> [OutlineLine] {
        var located: [(item: OutlineItem, row: Int, page: Int, order: Int)] = []
        for (i, item) in (model.notebook.outline ?? []).enumerated() {
            guard let loc = model.location(of: item.pageID) else { continue }
            located.append((item, loc.row, loc.page, i))
        }
        let ids = Set(located.map { $0.item.id })
        var children: [UUID?: [(item: OutlineItem, row: Int, page: Int, order: Int)]] = [:]
        for entry in located {
            var parent = entry.item.parentID
            if let p = parent, !ids.contains(p) || p == entry.item.id { parent = nil }   // 上一層不見了：放回最外層
            children[parent, default: []].append(entry)
        }
        var out: [OutlineLine] = []
        var seen = Set<UUID>()
        func visit(_ parent: UUID?, _ depth: Int) {
            let list = (children[parent] ?? []).sorted { a, b in (a.row, a.page, a.order) < (b.row, b.page, b.order) }
            for entry in list where !seen.contains(entry.item.id) {
                seen.insert(entry.item.id)
                let has = !(children[entry.item.id] ?? []).isEmpty
                out.append(OutlineLine(item: entry.item, row: entry.row, page: entry.page, depth: depth, hasChildren: has))
                if has && entry.item.collapsed != true { visit(entry.item.id, depth + 1) }
            }
        }
        visit(nil, 0)
        return out
    }

    /// PDF 自帶的目錄：收合的項目底下不列出來
    private func pdfLines() -> [PDFOutlineLine] {
        var list: [(entry: PDFOutlineEntry, row: Int, page: Int)] = []
        for entry in pdfOutline {
            guard let loc = model.location(of: entry.pageID) else { continue }
            list.append((entry, loc.row, loc.page))
        }
        var out: [PDFOutlineLine] = []
        var hiddenBelow: Int?
        for (i, item) in list.enumerated() {
            if let d = hiddenBelow {
                if item.entry.depth > d { continue }
                hiddenBelow = nil
            }
            let has = i + 1 < list.count && list[i + 1].entry.depth > item.entry.depth
            out.append(PDFOutlineLine(id: item.entry.id, title: item.entry.title, row: item.row, page: item.page,
                                      depth: item.entry.depth, hasChildren: has))
            if has && pdfFolded.contains(item.entry.id) { hiddenBelow = item.entry.depth }
        }
        return out
    }
}

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// 系統的分享面板（可以存到「檔案」、AirDrop、傳給其他 App）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DocumentRepresentable: UIViewRepresentable {
    let model: NotebookModel

    func makeUIView(context: Context) -> NotebookView {
        let view = NotebookView(model: model)
        model.documentView = view
        model.canPaste = NotebookView.hasClipboard
        return view
    }

    func updateUIView(_ uiView: NotebookView, context: Context) {}

    static func dismantleUIView(_ uiView: NotebookView, coordinator: ()) {
        uiView.flushAll()
        uiView.toolPicker.setVisible(false, forFirstResponder: uiView)
        uiView.resignFirstResponder()
    }
}

/// 白板右上角的按鈕（v12.7）：圖釘清單、區塊清單、新增
struct BoardToolbarButtons: View {
    @ObservedObject var model: NotebookModel
    @Binding var showPins: Bool
    @Binding var showFrames: Bool

    var body: some View {
        HStack(spacing: 22) {
            pinsButton
            framesButton
            addMenu
        }
    }

    private var pinsButton: some View {
        Button {
            model.documentView?.flushAll()
            showPins = true
        } label: {
            Image(uiImage: PinStyle.toolbarIcon)                    // 圖釘清單（新增圖釘在清單右上角；v12.8.2 換成 GUGA 那種圖示）
                .renderingMode(.template)
        }
        .popover(isPresented: $showPins) {
            PinListView(model: model, close: { showPins = false })
        }
    }

    private var framesButton: some View {
        Button {
            showFrames = true
        } label: {
            Image(systemName: "rectangle.3.group")
        }
        .popover(isPresented: $showFrames) {
            FrameListView(model: model, close: { showFrames = false })
        }
    }

    /// ＋（v12.8）：放東西到白板上（照片、圖片檔；筆記本、PDF、子白板下一版）。
    /// 圖釘、區塊改在各自的清單裡新增
    private var addMenu: some View {
        Menu {
            Section("放到畫面中間") {
                Button {
                    model.documentView?.insertFromToolbar(InsertKind.photos)
                } label: {
                    Label("相簿的照片", systemImage: "photo")
                }
                Button {
                    model.documentView?.insertFromToolbar(InsertKind.camera)
                } label: {
                    Label("拍照", systemImage: "camera")
                }
                Button {
                    model.documentView?.insertFromToolbar(InsertKind.files)
                } label: {
                    Label("檔案裡的圖片", systemImage: "folder")
                }
                Button {
                    model.documentView?.insertFromToolbar(InsertKind.photosMany)
                } label: {
                    Label("相簿的照片（一次選很多張）", systemImage: "photo.on.rectangle.angled")
                }
                Button {
                    model.documentView?.insertFromToolbar(InsertKind.filesMany)
                } label: {
                    Label("檔案裡的圖片（一次選很多個）", systemImage: "folder.badge.plus")
                }
            }
            Section("下一版") {
                Button {} label: {
                    Label("新筆記本／匯入筆記本", systemImage: "book.closed")
                }
                .disabled(true)
                Button {} label: {
                    Label("匯入 PDF", systemImage: "doc.richtext")
                }
                .disabled(true)
                Button {} label: {
                    Label("子白板", systemImage: "rectangle.on.rectangle.angled")
                }
                .disabled(true)
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}
