import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// BoardSettings.swift：白板右上角的設定面板（v12.9.1，照 GUGA 的「白板樣式設置」：上面是底色、格線的圓圈，下面一排一排的設定）
// v12.9.2：拿掉「貼上」（長按空白處的一圈按鈕就有）；字改成一般粗細；有開關的用系統開關；圓圈下面寫名稱、格線加說明
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

/// 白板右上角的齒輪：點了跳出設定面板（取代白板上原本的「⋯」選單）
struct BoardSettingsButton: View {
    @ObservedObject var model: NotebookModel
    @State private var showPanel = false
    @State private var showHistory = false
    @State private var showSnap = false
    @State private var showEngineTest = false

    var body: some View {
        Button {
            model.documentView?.flushAll()
            showPanel = true
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .popover(isPresented: $showPanel) {
            BoardSettingsPanel(model: model, open: { which in
                showPanel = false
                // 等面板收好再跳出下一個視窗
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    switch which {
                    case .history: showHistory = true
                    case .snap: showSnap = true
                    case .engineTest: showEngineTest = true
                    case .run(let action): action()
                    }
                }
            })
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
    }

    private var currentPageIDs: Set<UUID> {
        var ids = Set<UUID>()
        for row in model.notebook.rows {
            for page in row.pages { ids.insert(page.id) }
        }
        return ids
    }
}

/// 面板裡要另外打開的視窗
/// .run：先把面板收起來再做（匯出會跳出別的視窗，面板還開著會跳不出來）
enum BoardSettingsTarget {
    case history, snap, engineTest
    case run(@MainActor @Sendable () -> Void)
}

/// 白板樣式設置的面板
struct BoardSettingsPanel: View {
    @ObservedObject var model: NotebookModel
    let open: (BoardSettingsTarget) -> Void
    @State private var tick = 0                         // 改了設定：重畫

    private var paper: PaperStyle { model.notebook.rows.first?.pages.first?.paperStyle ?? PaperStyle() }

    /// 格線的簡短說明（圓圈下面的名稱只有兩三個字，這裡補一句）
    private static let patternNotes = [
        "什麼都不畫，最乾淨。",
        "淡淡的點，對齊用，比方格不搶眼。",
        "方格，畫圖、對齊公式最方便。",
        "窄的橫線，寫字比較密。",
        "寬的橫線，寫字比較鬆。"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("白板樣式")
                    .font(.title3.weight(.semibold))
                sectionTitle("底色")
                colorRow
                sectionTitle("格線")
                patternRow
                Text(patternNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .id(tick)
                group {
                    toggleRow("鎖定縮放（只能移動）", symbol: "lock", isOn: zoomLockBinding)
                    Divider()
                    toggleRow("紙膠帶全部遮住", symbol: "bandage", isOn: tapesBinding)
                }
                group {
                    navRow("停筆設定", symbol: "wand.and.stars") { open(.snap) }
                    Divider()
                    textSizeRow
                    Divider()
                    toggleRow("新文字方塊用粗體", symbol: "bold", isOn: boldBinding)
                }
                group {
                    actionRow("加大白板（往右、往下各加一倍）", symbol: "arrow.up.left.and.arrow.down.right") {
                        model.documentView?.enlargeBoard()
                    }
                }
                group {
                    actionRow("匯出目前畫面（PDF）", symbol: "rectangle.dashed") {
                        open(.run { [model] in model.documentView?.exportBoard(onlyVisible: true) })
                    }
                    Divider()
                    actionRow("匯出白板上所有內容（PDF）", symbol: "square.and.arrow.up") {
                        open(.run { [model] in model.documentView?.exportBoard(onlyVisible: false) })
                    }
                    Divider()
                    actionRow("匯出所有區塊（一個區塊一頁）", symbol: "rectangle.stack") {
                        open(.run { [model] in model.documentView?.exportAllFrames() })
                    }
                }
                group {
                    actionRow("保存目前版本", symbol: "square.and.arrow.down.on.square") {
                        model.documentView?.manualSnapshot()
                    }
                    Divider()
                    navRow("白板歷史版本", symbol: "clock.arrow.circlepath") { open(.history) }
                }
                group {
                    navRow("試用新白板引擎（實驗，不會存檔）", symbol: "flask") { open(.engineTest) }
                    Divider()
                    actionRow("壓力測試：先寫幾個字，再按這裡複製成 5,000 筆（可復原）", symbol: "scribble.variable") {
                        model.documentView?.addStressStrokes(5000)
                    }
                    Divider()
                    actionRow("壓力測試：複製成 20,000 筆（可復原）", symbol: "scribble.variable") {
                        model.documentView?.addStressStrokes(20000)
                    }
                }
            }
            .font(.body)
            .fontWeight(.regular)
            .padding(20)
        }
        .frame(width: 360, height: 620)
        .background(Color(uiColor: UIColor.systemGroupedBackground))
        .presentationCompactAdaptation(.popover)
    }

    private var patternNote: String {
        let i = min(max(paper.pattern, 0), Self.patternNotes.count - 1)
        return Self.patternNotes[i] + "縮得很小時格線會自動淡掉。"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    // MARK: 開關

    private var zoomLockBinding: Binding<Bool> {
        Binding(get: {
            _ = tick
            return model.documentView?.zoomLockSetting ?? false
        }, set: { value in
            model.documentView?.zoomLockSetting = value
            tick += 1
        })
    }

    private var tapesBinding: Binding<Bool> {
        Binding(get: {
            _ = tick
            return model.documentView?.allTapesCovered ?? true
        }, set: { value in
            model.documentView?.setAllTapes(revealed: !value)
            tick += 1
        })
    }

    private var boldBinding: Binding<Bool> {
        let id = model.meta.id
        return Binding(get: {
            _ = tick
            return TextDefaults.bold(id)
        }, set: { value in
            NotebookPrefs.set(value, TextDefaults.boldKey, id)
            tick += 1
        })
    }

    // MARK: 底色、格線

    private var colorRow: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(0..<PaperStyle.colorNames.count, id: \.self) { (i: Int) in
                Button {
                    var p = paper
                    p.color = i
                    model.documentView?.setBoardPaper(p)
                    tick += 1
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(Color(uiColor: PaperRenderer.background(PaperStyle(pattern: 0, color: i))))
                            .frame(width: 54, height: 54)
                            .overlay(Circle().stroke(Color.primary.opacity(paper.color == i ? 1 : 0.15),
                                                     lineWidth: paper.color == i ? 3 : 1))
                        Text(PaperStyle.colorNames[i])
                            .font(.caption)
                            .foregroundStyle(paper.color == i ? Color.primary : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var patternRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<PaperStyle.patternNames.count, id: \.self) { (i: Int) in
                Button {
                    var p = paper
                    p.pattern = i
                    model.documentView?.setBoardPaper(p)
                    tick += 1
                } label: {
                    VStack(spacing: 6) {
                        PatternSwatch(pattern: i, color: paper.color)
                            .frame(width: 54, height: 54)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.primary.opacity(paper.pattern == i ? 1 : 0.15),
                                                     lineWidth: paper.pattern == i ? 3 : 1))
                        Text(PaperStyle.patternNames[i])
                            .font(.caption)
                            .foregroundStyle(paper.pattern == i ? Color.primary : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 新文字方塊的字級（這一張白板自己的，見 NotebookPrefs）

    private var textSizeRow: some View {
        let id = model.meta.id
        let size = TextDefaults.size(id)
        return HStack {
            Label("新文字方塊的字級", systemImage: "textformat.size")
            Spacer()
            Menu {
                ForEach(TextDefaults.sizes, id: \.self) { (s: Int) in
                    Button("\(s)") {
                        NotebookPrefs.set(Double(s), TextDefaults.sizeKey, id)
                        tick += 1
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(Int(size))")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 12)
        .id(tick)
    }

    // MARK: 一排一排的樣子

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .background(Color(uiColor: UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func toggleRow(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: symbol)
        }
        .padding(.vertical, 8)
    }

    private func navRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                    .foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                    .foregroundStyle(Color.primary)
                Spacer()
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 紋理的小圓圈：空白、點、方格、直線窄、直線寬（顏色先算好再畫，畫的那一段不碰 PaperRenderer）
struct PatternSwatch: View {
    let pattern: Int
    let color: Int

    var body: some View {
        let style = PaperStyle(pattern: pattern, color: color)
        let bg = Color(uiColor: PaperRenderer.background(style))
        let line = Color(uiColor: PaperRenderer.lineColor(style))
        let dot = Color(uiColor: PaperRenderer.dotColor(style))
        let kind = pattern
        return Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: CGPoint.zero, size: size)), with: .color(bg))
            let step = size.width / 6
            if kind == 1 {
                var y = step
                while y < size.height {
                    var x = step
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)), with: .color(dot))
                        x += step
                    }
                    y += step
                }
            } else if kind == 2 {
                var p = Path()
                var v = step
                while v < size.width {
                    p.move(to: CGPoint(x: v, y: 0))
                    p.addLine(to: CGPoint(x: v, y: size.height))
                    p.move(to: CGPoint(x: 0, y: v))
                    p.addLine(to: CGPoint(x: size.width, y: v))
                    v += step
                }
                ctx.stroke(p, with: .color(line), lineWidth: 1)
            } else if kind == 3 || kind == 4 {
                var p = Path()
                let rowStep = kind == 3 ? step : step * 1.4
                var y = rowStep
                while y < size.height {
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                    y += rowStep
                }
                ctx.stroke(p, with: .color(line), lineWidth: 1)
            }
        }
    }
}
