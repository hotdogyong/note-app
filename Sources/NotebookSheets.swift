import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// NotebookSheets.swift：筆記本裡的視窗：歷史版本、變更範本、移出頁面、概覽（九宮格）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

/// 恢復筆記本歷史版本
struct HistorySheet: View {
    let notebookID: UUID
    let currentPages: Set<UUID>
    let onRestore: (SnapshotInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var list: [SnapshotInfo] = []
    @State private var filter = 0                 // 0 全部、1 自動保存、2 手動保存
    @State private var chosen: String?
    @State private var confirm = false
    @State private var pendingDelete: SnapshotInfo?
    @State private var showDeleteConfirm = false
    @State private var editing: SnapshotInfo?
    @State private var previewing: SnapshotInfo?

    private var filtered: [SnapshotInfo] {
        switch filter {
        case 1: return list.filter { !$0.manual }
        case 2: return list.filter { $0.manual }
        default: return list
        }
    }

    private var chosenTitle: String {
        list.first(where: { $0.id == chosen })?.displayTitle ?? ""
    }

    var body: some View {
        NavigationStack {
            listContent
                .navigationTitle("恢復筆記本歷史版本")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarItems }
                .navigationDestination(item: $previewing) { (snapshot: SnapshotInfo) in
                    SnapshotPreview(snapshot: snapshot, notebookID: notebookID, currentPages: currentPages) {
                        chosen = snapshot.id
                        previewing = nil
                        confirm = true
                    }
                }
                .background(dialogs)
                .onAppear { list = Store.snapshots(notebookID) }
        }
    }

    private var listContent: some View {
        List {
            Section {
                Picker("類型", selection: $filter) {
                    Text("全部").tag(0)
                    Text("自動保存").tag(1)
                    Text("手動保存").tag(2)
                }
                .pickerStyle(.segmented)
            }
            Section {
                if filtered.isEmpty {
                    Text("還沒有歷史版本")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { (snapshot: SnapshotInfo) in
                    row(snapshot)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                pendingDelete = snapshot
                                showDeleteConfirm = true
                            } label: {
                                Label("刪除", systemImage: "trash")
                            }
                            .tint(.red)
                            Button {
                                editing = snapshot
                            } label: {
                                Label("編輯", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }
            } footer: {
                Text("1. 變更範本前、刪除頁面前、有打開筆記本那天的第一次打開時會自動保存；內容跟最新一份一樣就不重複存。自動保存最多留 \(Store.autoSnapshotLimit) 份；手動保存會一直保留，只有自己刪才會消失。\n2. 點「預覽」看那個版本的每一頁；現在已經沒有的頁會標紅色。\n3. 恢復前會先自動保存目前的樣子（「恢復前」），恢復後 10 秒內可以按「反悔」。\n4. 左滑可以編輯標題、摘要，或刪除。")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("恢復") { confirm = true }
                .disabled(chosen == nil)
        }
    }

    private var dialogs: some View {
        Color.clear
            .confirmationDialog("恢復到「\(chosenTitle)」？", isPresented: $confirm, titleVisibility: .visible) {
                Button("恢復") { restoreChosen() }
            } message: {
                Text("整本筆記本會換成這個版本；目前的樣子會先自動保存一份「恢復前」，恢復後 10 秒內也可以按「反悔」。")
            }
            .confirmationDialog("刪除「\(pendingDelete?.displayTitle ?? "")」？", isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button("刪除", role: .destructive) { deletePending() }
            } message: {
                Text("這個歷史版本刪除後無法復原。")
            }
            .sheet(item: $editing) { (snapshot: SnapshotInfo) in
                EditSnapshotSheet(snapshot: snapshot) { updated in
                    Store.updateSnapshot(updated, notebook: notebookID)
                    list = Store.snapshots(notebookID)
                }
            }
    }

    private func row(_ snapshot: SnapshotInfo) -> some View {
        let selected: Bool = chosen == snapshot.id
        let icon: String = snapshot.manual ? "hand.raised" : "clock.arrow.circlepath"
        let renamed: Bool = snapshot.displayTitle != snapshot.reason
        return HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(snapshot.displayTitle)
                        .font(.body.weight(.medium))
                    if renamed { tag(snapshot.reason) }
                }
                Text("保存於 " + Self.dateText(snapshot.date) + "　共 \(snapshot.pageCount) 頁")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let note = snapshot.note, !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer()
            Button {
                previewing = snapshot
            } label: {
                Label("預覽", systemImage: "eye")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { chosen = snapshot.id }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func deletePending() {
        guard let item = pendingDelete else { return }
        Store.deleteSnapshot(item, notebook: notebookID)
        if chosen == item.id { chosen = nil }
        pendingDelete = nil
        list = Store.snapshots(notebookID)
    }

    private func restoreChosen() {
        guard let id = chosen, let snapshot = list.first(where: { $0.id == id }) else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onRestore(snapshot) }
    }
}

/// 編輯歷史版本的標題、摘要
struct EditSnapshotSheet: View {
    let snapshot: SnapshotInfo
    let onSave: (SnapshotInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String

    init(snapshot: SnapshotInfo, onSave: @escaping (SnapshotInfo) -> Void) {
        self.snapshot = snapshot
        self.onSave = onSave
        _title = State(initialValue: snapshot.title ?? "")
        _note = State(initialValue: snapshot.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(snapshot.reason, text: $title)
                        .font(.title3)
                } header: {
                    Text("標題")
                } footer: {
                    Text("空白的話顯示原本的原因（\(snapshot.reason)）。")
                }
                Section {
                    TextField("例如：第三章範例 3 寫完；刪掉重複的旁頁之前", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("摘要")
                } footer: {
                    Text("保存於 \(HistorySheet.dateText(snapshot.date))，共 \(snapshot.pageCount) 頁。鍵盤叫不出來時可以用 Apple Pencil 手寫，或先在備忘錄打好再貼上。")
                }
            }
            .navigationTitle("編輯歷史版本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save() }
                }
            }
        }
    }

    private func save() {
        var updated = snapshot
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.title = t.isEmpty ? nil : t
        updated.note = n.isEmpty ? nil : n
        onSave(updated)
        dismiss()
    }
}

/// 預覽歷史版本：那個版本的每一頁（現在已經沒有的頁標紅色）
struct SnapshotPageEntry: Identifiable {
    let id: UUID
    let page: NotePage
    let label: String
}

struct SnapshotPreview: View {
    let snapshot: SnapshotInfo
    let notebookID: UUID
    let currentPages: Set<UUID>
    let onRestore: () -> Void
    @State private var entries: [SnapshotPageEntry] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18)]

    var body: some View {
        let missing: Int = entries.filter { !currentPages.contains($0.id) }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("保存於 " + HistorySheet.dateText(snapshot.date) + "　" + snapshot.reason)
                    .foregroundStyle(.secondary)
                if let note = snapshot.note, !note.isEmpty {
                    Text(note)
                }
                if missing > 0 {
                    Label("這個版本裡有 \(missing) 頁現在已經沒有了（紅框的頁）", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(entries) { (entry: SnapshotPageEntry) in
                        cell(entry)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(snapshot.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("恢復這個版本") { onRestore() }
            }
        }
        .onAppear { if !loaded { load() } }
    }

    private func cell(_ entry: SnapshotPageEntry) -> some View {
        let gone: Bool = !currentPages.contains(entry.id)
        return VStack(spacing: 6) {
            SnapshotThumb(page: entry.page, snapshot: snapshot, notebookID: notebookID)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(gone ? Color.red : Color.clear, lineWidth: 3))
            Text(entry.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if gone {
                Text("目前沒有這一頁")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
    }

    private func load() {
        defer { loaded = true }
        guard let data = Store.snapshotNotebook(snapshot, notebook: notebookID) else { return }
        var list: [SnapshotPageEntry] = []
        for (r, row) in data.rows.enumerated() {
            for (p, page) in row.pages.enumerated() {
                let label: String
                if p == row.mainIndex {
                    label = "第 \(r + 1) 頁"
                } else if p < row.mainIndex {
                    label = "第 \(r + 1) 頁 左 \(row.mainIndex - p)"
                } else {
                    label = "第 \(r + 1) 頁 右 \(p - row.mainIndex)"
                }
                list.append(SnapshotPageEntry(id: page.id, page: page, label: label))
            }
        }
        entries = list
    }
}

/// 歷史版本裡某一頁的縮圖（用那個版本的筆跡）
struct SnapshotThumb: View {
    let page: NotePage
    let snapshot: SnapshotInfo
    let notebookID: UUID
    @State private var image: UIImage?

    var body: some View {
        let ratio: CGFloat = page.spec.width / max(page.spec.height, 1)
        return Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(ratio, contentMode: .fit)
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        .onAppear {
            if image == nil {
                let drawing = Store.snapshotDrawing(snapshot, notebook: notebookID, pageID: page.id)
                image = Thumbnail.image(for: page, width: 200, drawing: drawing)
            }
        }
    }
}


/// 變更範本：跟新建筆記本同一套樣子；封面頁換封面，一般頁換紙張
struct ChangeTemplateSheet: View {
    let page: NotePage
    /// 紙張、封面（不是封面頁就 nil）、套用到整本、新的大小（nil：不變）、黑白筆跡互換
    let onApply: (PaperStyle, Int?, Bool, CGSize?, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pattern = 2
    @State private var paperColor = 0
    @State private var coverIndex = 8
    @State private var sizeChoice = -1               // -1：維持原本
    @State private var orientChoice = 0              // 0 維持原本、1 縱向、2 橫向
    @State private var swapInk = false

    /// 選了新尺寸或方向才回傳大小
    private var newSize: CGSize? {
        if sizeChoice < 0 && orientChoice == 0 { return nil }
        let w0 = page.spec.width
        let h0 = page.spec.height
        var short: CGFloat = min(w0, h0)
        var long: CGFloat = max(w0, h0)
        if sizeChoice >= 0 && sizeChoice < paperSizes.count {
            short = paperSizes[sizeChoice].w
            long = paperSizes[sizeChoice].h
        }
        let landscape: Bool
        if orientChoice == 2 {
            landscape = true
        } else if orientChoice == 1 {
            landscape = false
        } else {
            landscape = w0 > h0
        }
        return landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }

    /// 這一頁原本的尺寸名稱（不是常見尺寸就寫寬×高）
    private var originalSizeName: String {
        let short: CGFloat = min(page.spec.width, page.spec.height)
        let long: CGFloat = max(page.spec.width, page.spec.height)
        for size in paperSizes where abs(size.w - short) < 2 && abs(size.h - long) < 2 { return size.name }
        return "\(Int(page.spec.width))×\(Int(page.spec.height))"
    }

    private var originalOrientName: String { page.spec.width > page.spec.height ? "橫向" : "縱向" }

    private var sizeLabel: String {
        sizeChoice >= 0 && sizeChoice < paperSizes.count ? paperSizes[sizeChoice].name : "維持原本（\(originalSizeName)）"
    }

    private var orientLabel: String {
        orientChoice == 1 ? "縱向" : (orientChoice == 2 ? "橫向" : "維持原本（\(originalOrientName)）")
    }

    private var isCover: Bool { page.cover != nil }
    private var style: PaperStyle { PaperStyle(pattern: pattern, color: paperColor) }

    private func size(height: CGFloat) -> CGSize {
        let ratio: CGFloat = page.spec.width / max(page.spec.height, 1)
        return CGSize(width: height * ratio, height: height)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        PagePreviewCard(title: isCover ? "封面" : "紙張",
                                        caption: isCover ? coverTemplate(coverIndex).name : PaperStyle.patternNames[pattern],
                                        image: PaperRenderer.preview(style, cover: isCover ? coverIndex : nil,
                                                                     size: size(height: 200), pageWidth: page.spec.width),
                                        highlighted: true)
                        VStack(spacing: 16) {
                            optionsForm
                            buttons
                        }
                        .frame(maxWidth: 460)
                    }
                    Divider()
                    if isCover { coverGrid } else { paperGrid }
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("變更範本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .onAppear {
            pattern = page.paperStyle.pattern
            paperColor = page.paperStyle.color
            coverIndex = page.cover ?? 8
        }
    }

    private var colorPicker: some View {
        Picker("紙張顏色", selection: $paperColor) {
            ForEach(0..<PaperStyle.colorNames.count, id: \.self) { (i: Int) in
                Text(PaperStyle.colorNames[i]).tag(i)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: paperColor) { _, newColor in
            // 深色紙、淺色紙互換時，自動打開黑白筆跡互換
            let nowDark: Bool = PaperStyle(pattern: 0, color: newColor).isDark
            swapInk = nowDark != page.paperStyle.isDark
        }
    }

    private var optionsForm: some View {
        VStack(spacing: 0) {
            if !isCover {
                colorPicker
                    .padding(.vertical, 12)
                Divider()
            }
            optionRow(title: "尺寸", value: sizeLabel) {
                Button("維持原本（\(originalSizeName)）") { sizeChoice = -1 }
                ForEach(0..<paperSizes.count, id: \.self) { (i: Int) in
                    Button(paperSizes[i].name) { sizeChoice = i }
                }
            }
            Divider()
            optionRow(title: "版式", value: orientLabel) {
                Button("維持原本（\(originalOrientName)）") { orientChoice = 0 }
                Button("縱向") { orientChoice = 1 }
                Button("橫向") { orientChoice = 2 }
            }
            if !isCover {
                Divider()
                Toggle("黑白筆跡互換", isOn: $swapInk)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func optionRow<Content: View>(title: String, value: String,
                                          @ViewBuilder items: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            Menu {
                items()
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var buttons: some View {
        if isCover {
            BlackButton(title: "套用到這個封面") { apply(all: false) }
        } else {
            HStack(spacing: 16) {
                BlackButton(title: "套用到這一頁") { apply(all: false) }
                BlackButton(title: "套用到整本") { apply(all: true) }
            }
        }
    }

    private var paperGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("紙張模板")
                .font(.title2.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(0..<PaperStyle.patternNames.count, id: \.self) { (i: Int) in
                        TemplateCard(name: PaperStyle.patternNames[i],
                                     image: PaperRenderer.preview(PaperStyle(pattern: i, color: paperColor), cover: nil,
                                                                  size: size(height: 150), pageWidth: page.spec.width),
                                     selected: i == pattern)
                            .onTapGesture { pattern = i }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var coverGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("封面模板")
                .font(.title2.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(0..<coverTemplates.count, id: \.self) { (i: Int) in
                        TemplateCard(name: coverTemplates[i].name,
                                     image: PaperRenderer.preview(style, cover: i, size: size(height: 150),
                                                                  pageWidth: page.spec.width),
                                     selected: i == coverIndex)
                            .onTapGesture { coverIndex = i }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func apply(all: Bool) {
        onApply(style, isCover ? coverIndex : nil, all, newSize, swapInk && !isCover)
        dismiss()
    }
}


/// 概覽：一列一行，主頁和旁頁由左到右排開（主頁有藍框）。
/// 長按任一張縮圖拖到別的列上，可以移動整列的位置；每張縮圖下方的「⋯」有各自的操作。
/// 移出頁面：要搬哪幾頁（主頁＝整列含旁頁）
struct MoveRequest: Identifiable {
    let id = UUID()
    let pageIDs: [UUID]
    var askSides = true             // 選到的主頁還有旁頁時，問要不要一起搬（概覽的選取模式自己選，不問）
    var copy = false                // 複製一份過去（v12.15.6）：原本這本不動
    var within = false              // 同一本裡換位置（v12.15.10）
}

/// 選頁面要放在哪裡（v12.15.10，使用者：400 多頁的筆記本，搬回去十幾頁不要都塞最後面；本子裡移動也要有拖以外的方法）。
/// 一格一頁（主頁的縮圖），點哪一頁就放在那頁後面；上面有「最前面」「最後面」和跳到第幾頁
struct PagePositionPicker: View {
    let title: String
    let rows: [PageRow]
    var moving: Set<UUID> = []                 // 同一本裡移動：被移的那幾列（變淡）
    let confirm: (Int) -> Void                 // 插在第幾列前面：0＝最前面，rows.count＝最後面
    @State private var position: Int
    @State private var jump = ""

    init(title: String, rows: [PageRow], moving: Set<UUID> = [], start: Int? = nil, confirm: @escaping (Int) -> Void) {
        self.title = title
        self.rows = rows
        self.moving = moving
        self.confirm = confirm
        _position = State(initialValue: min(max(start ?? rows.count, 0), rows.count))
    }

    private var summary: String {
        if position == 0 { return "放在最前面（第 1 頁前面）" }
        if position >= rows.count { return "放在最後面（第 \(rows.count) 頁後面）" }
        return "放在第 \(position) 頁後面"
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button("最前面") {
                        position = 0
                        withAnimation { proxy.scrollTo(0, anchor: .top) }
                    }
                    Button("最後面") {
                        position = rows.count
                        withAnimation { proxy.scrollTo(max(rows.count - 1, 0), anchor: .bottom) }
                    }
                    Spacer()
                    TextField("第幾頁", text: $jump)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { go(proxy) }
                    Button("跳過去") { go(proxy) }
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                Text(summary)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 8)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 14)], spacing: 16) {
                        ForEach(rows.indices, id: \.self) { i in
                            PagePositionCell(page: rows[i].pages.indices.contains(rows[i].mainIndex)
                                                ? rows[i].pages[rows[i].mainIndex] : (rows[i].pages.first ?? NotePage()),
                                             number: i + 1,
                                             sides: rows[i].pages.count - 1,
                                             mark: position == i + 1 ? .after : (position == 0 && i == 0 ? .before : .none),
                                             dimmed: moving.contains(rows[i].id))
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { position = (position == i + 1 && i == 0) ? 0 : i + 1 }
                        }
                    }
                    .padding(16)
                }
            }
            .onAppear {
                let target = min(max(position - 1, 0), max(rows.count - 1, 0))
                DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
            }
        }
        .navigationTitle("放在「\(title)」的哪裡？")
        .navigationBarTitleDisplayMode(.inline)
        .presentationSizing(.page)                     // 400 多頁：視窗大一點，一次看得到比較多頁
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("放在這裡") { confirm(position) }
                    .bold()
            }
        }
    }

    private func go(_ proxy: ScrollViewProxy) {
        guard let n = Int(jump.trimmingCharacters(in: .whitespaces)), n >= 1, !rows.isEmpty else { return }
        let page = min(n, rows.count)
        position = page
        withAnimation { proxy.scrollTo(page - 1, anchor: .center) }
    }
}

/// 位置選單的一格：縮圖、頁碼；選到的那一格旁邊一條藍線（放在這頁後面／前面）
struct PagePositionCell: View {
    enum Mark { case none, before, after }
    let page: NotePage
    let number: Int
    let sides: Int
    let mark: Mark
    let dimmed: Bool
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.9))
                if let image = image {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
            .aspectRatio(page.spec.width / max(page.spec.height, 1), contentMode: .fit)
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(mark == .none ? Color.secondary.opacity(0.3) : Color.accentColor, lineWidth: mark == .none ? 1 : 2.5))
            .overlay(alignment: mark == .before ? .leading : .trailing) {
                if mark != .none {
                    Capsule().fill(Color.accentColor).frame(width: 5).padding(.vertical, -4)
                        .offset(x: mark == .before ? -9 : 9)
                }
            }
            .opacity(dimmed ? 0.35 : 1)
            Text(sides > 0 ? "\(number)（＋\(sides)）" : "\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(mark == .none ? Color.secondary : Color.accentColor)
            if mark != .none {
                Text(mark == .before ? "放在這頁前面" : "放在這頁後面")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .task(id: page.id) {
            if let cached = PagePositionCell.cache.object(forKey: page.id.uuidString as NSString) {
                image = cached
                return
            }
            await Task.yield()
            let made = Thumbnail.image(for: page, width: 120)
            PagePositionCell.cache.setObject(made, forKey: page.id.uuidString as NSString)
            image = made
        }
    }

    static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        return cache
    }()
}

/// 同一本裡換位置（v12.15.10）：直接選放在第幾頁後面
struct WithinMoveSheet: View {
    @ObservedObject var model: NotebookModel
    let request: MoveRequest
    let done: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let ids = request.askSides ? model.withSidePages(request.pageIDs) : request.pageIDs
        let set = Set(ids)
        let movingRows = Set(model.notebook.rows.filter { row in row.pages.contains { set.contains($0.id) } }.map(\.id))
        let first = model.notebook.rows.firstIndex { movingRows.contains($0.id) }
        NavigationStack {
            PagePositionPicker(title: model.meta.title, rows: model.notebook.rows, moving: movingRows,
                               start: first.map { $0 + 1 }) { at in
                let count = model.documentView?.movePagesWithin(ids, insertAt: at) ?? 0
                dismiss()
                if count > 0 { done(count) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

/// 移出頁面：選要搬到哪一本筆記本，或新建一本
struct MovePagesSheet: View {
    @ObservedObject var library: LibraryModel
    let sourceID: UUID
    let summary: (Bool) -> String              // 一起搬旁頁 / 不搬時的說明，例如「第 3 頁（含 2 張旁頁）」
    var sideCount = 0                          // 選到的主頁還有幾張旁頁沒選（0：不問）
    var copy = false                           // 複製（不是搬）
    let onPick: (NotebookMeta, Bool, Int?) -> Void   // 目的地、旁頁要不要一起搬、插在目的地第幾列前面（nil＝最後面）
    @Environment(\.dismiss) private var dismiss
    @State private var withSides = true
    @State private var target: (meta: NotebookMeta, rows: [PageRow])?   // 選好哪一本：接著選放在哪裡（v12.15.10）

    var body: some View {
        if let target = target {
            NavigationStack {
                PagePositionPicker(title: target.meta.title, rows: target.rows) { at in
                    onPick(target.meta, withSides, at)
                    dismiss()
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            self.target = nil
                        } label: {
                            Label("換一本", systemImage: "chevron.left")
                        }
                    }
                }
            }
        } else {
            NavigationStack {
                // v12.6：像選檔案一樣一層一層進資料夾；每一層可以點某一本移過去，或在這一層新建一本
                MoveFolderLevel(library: library, folderID: nil, sourceID: sourceID, header: AnyView(headerSections),
                                pick: { meta in choose(meta) })
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { dismiss() }
                    }
                }
            }
        }
    }

    /// 選好哪一本：空的（剛新建的）直接放；有頁面的接著選放在哪裡
    private func choose(_ meta: NotebookMeta) {
        let rows = Store.loadNotebook(meta.id).rows
        if rows.isEmpty || meta.isBoard == true {
            onPick(meta, withSides, nil)
            dismiss()
        } else {
            target = (meta, rows)
        }
    }

    @ViewBuilder
    private var headerSections: some View {
        if sideCount > 0 {
            Section("這一頁還有 \(sideCount) 張旁頁") {
                Picker("旁頁", selection: $withSides) {
                    Text(copy ? "一起複製" : "一起搬").tag(true)
                    Text(copy ? "只複製主頁" : "只搬主頁").tag(false)
                }
                .pickerStyle(.segmented)
                Text(copy ? (withSides ? "旁頁跟著主頁一起複製過去，維持原本的左右順序。" : "只複製主頁，旁頁不帶過去。")
                          : (withSides ? "旁頁跟著主頁搬過去，維持原本的左右順序。"
                                       : "旁頁留在原處，最靠近的旁頁（右邊優先）會變成新的主頁。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            Text((copy ? "要複製：" : "要移出：") + summary(withSides))
                .font(.callout)
            Text(copy ? "選好哪一本之後，再選要放在第幾頁後面。筆跡、文字、圖片、PDF 頁都會帶過去，這一本不動。"
                      : "選好哪一本之後，再選要放在第幾頁後面。搬之前會自動保存一份歷史版本，搬錯可以從「⋯ → 恢復歷史版本」找回來。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let quick = library.quickNotebook, quick.id != sourceID {
            Section("隨手記") {
                MoveNotebookRow(library: library, meta: quick, pick: { meta in choose(meta) })
            }
        }
    }
}

/// 移出頁面：資料夾的一層（v12.6）。上面是子資料夾（點進去下一層），下面是這一層的筆記本（點了就移過去），
/// 最下面「在這裡新建筆記本」
struct MoveFolderLevel: View {
    @ObservedObject var library: LibraryModel
    let folderID: UUID?
    let sourceID: UUID
    var header: AnyView? = nil
    let pick: (NotebookMeta) -> Void

    private var title: String {
        folderID.flatMap { library.folder($0)?.name } ?? "所有文件"
    }

    /// 這一層的子資料夾（照首頁的順序，不含最近刪除裡的）
    private var subfolders: [NoteFolder] {
        library.items(in: folderID).compactMap { (ref: ItemRef) -> NoteFolder? in
            if case .folder(let id) = ref { return library.folder(id) }
            return nil
        }
    }

    private var notebooks: [NotebookMeta] {
        library.items(in: folderID).compactMap { (ref: ItemRef) -> NotebookMeta? in
            if case .notebook(let id) = ref, let meta = library.notebook(id), meta.id != sourceID, meta.deletedAt == nil {
                return meta
            }
            return nil
        }
    }

    var body: some View {
        List {
            if let header = header { header }
            if !subfolders.isEmpty {
                Section("資料夾") {
                    ForEach(subfolders) { (folder: NoteFolder) in
                        NavigationLink {
                            MoveFolderLevel(library: library, folderID: folder.id, sourceID: sourceID, pick: pick)
                        } label: {
                            Label {
                                Text(folder.name)
                            } icon: {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(folderColor(folder.colorIndex))
                            }
                        }
                    }
                }
            }
            Section(notebooks.isEmpty ? "這裡沒有筆記本" : "移到這一本") {
                ForEach(notebooks) { (meta: NotebookMeta) in
                    MoveNotebookRow(library: library, meta: meta, pick: pick)
                }
            }
            Section {
                Button {
                    let suggested = (library.notebook(sourceID)?.title ?? "筆記") + " 移出"
                    TextPrompt.show(title: "在「\(title)」新建筆記本", initial: suggested) { text in
                        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let meta = library.addNotebook(in: folderID, title: name.isEmpty ? suggested : name,
                                                       data: NotebookData(rows: []))
                        pick(meta)
                    }
                } label: {
                    Label("在「\(title)」新建筆記本並移過去…", systemImage: "plus.rectangle.on.rectangle")
                }
            }
        }
        .navigationTitle(folderID == nil ? "移到哪一本？" : title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 移出頁面：一本可以移過去的筆記本
struct MoveNotebookRow: View {
    @ObservedObject var library: LibraryModel
    let meta: NotebookMeta
    let pick: (NotebookMeta) -> Void

    var body: some View {
        Button {
            pick(meta)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: meta.isBoard == true ? "rectangle.dashed" : "book.closed")
                    .foregroundStyle(Color.accentColor)
                Text(meta.title)
                    .foregroundStyle(.primary)
            }
        }
    }
}

/// 移出頁面 → 新建筆記本：先選放在哪個資料夾（可以順便新增資料夾），再取名字
struct NewNotebookTargetView: View {
    @ObservedObject var library: LibraryModel
    let initialFolder: UUID?
    let suggestedName: String
    let onCreate: (NotebookMeta) -> Void
    @State private var folder: UUID?
    @State private var started = false

    private var folderName: String {
        folder.flatMap { library.folder($0)?.name } ?? "所有文件"
    }

    var body: some View {
        List {
            Section("放在哪裡") {
                folderRow(nil, name: "所有文件（最外層）", depth: 0)
                ForEach(library.moveTargets(excluding: []), id: \.id) { item in
                    folderRow(item.id, name: item.name.components(separatedBy: " / ").last ?? item.name,
                              depth: item.name.components(separatedBy: " / ").count)
                }
            }
            Section {
                Button {
                    TextPrompt.show(title: "在「\(folderName)」裡新增資料夾", initial: "") { text in
                        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        let created = library.addFolder(in: folder, name: name)
                        folder = created.id
                    }
                } label: {
                    Label("在「\(folderName)」裡新增資料夾…", systemImage: "folder.badge.plus")
                }
            }
        }
        .navigationTitle("新筆記本放在…")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("建立並移過去") {
                    TextPrompt.show(title: "新筆記本的名稱（放在「\(folderName)」）", initial: suggestedName) { text in
                        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let meta = library.addNotebook(in: folder, title: name.isEmpty ? suggestedName : name,
                                                       data: NotebookData(rows: []))
                        onCreate(meta)
                    }
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            if !started {
                started = true
                folder = initialFolder
            }
        }
    }

    private func folderRow(_ id: UUID?, name: String, depth: Int) -> some View {
        Button {
            folder = id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: id == nil ? "tray.full" : "folder.fill")
                    .foregroundStyle(id == nil ? Color.secondary : folderColor(id.flatMap { library.folder($0)?.colorIndex }))
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
                if folder == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.leading, CGFloat(max(depth - 1, 0)) * 18)
        }
    }
}

enum PendingDelete: Equatable {
    case row(Int)
    case page(row: Int, page: Int)
}

struct OverviewSheet: View {
    @ObservedObject var model: NotebookModel
    @ObservedObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selecting = false               // 選取模式：點縮圖是勾選，不是跳過去
    @State private var selected: Set<UUID> = []        // 勾選的頁（選哪張就是哪張）
    @State private var sidesWithMain = true            // 勾主頁時一起勾它的旁頁；關掉＝自由選
    @State private var moveRequest: MoveRequest?
    @State private var movedMessage: String?
    @State private var pendingDelete: PendingDelete?
    @State private var showDelete = false
    @State private var dropTarget: UUID?
    @State private var dropTargetPage: UUID?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        Text(selecting
                             ? "點縮圖勾選要移出的頁，勾到哪幾張就搬哪幾張。主頁沒搬走時，搬走的旁頁到了那本會各自變成一頁；主頁搬走、旁頁留下時，最靠近的旁頁變成新的主頁。"
                             : "長按縮圖拖到同一列的另一張上，兩張會交換位置（拖到主頁上，它就變成主頁）；拖到別的列上，可以移動整列。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        ForEach(Array(model.notebook.rows.enumerated()), id: \.element.id) { index, row in
                            rowLine(index: index, row: row)
                                .id(row.id)
                        }
                    }
                    .padding(20)
                }
                .onAppear {
                    // 打開時捲到目前這一頁（等畫面排好再捲，不然會停在第一頁）
                    let rows = model.notebook.rows
                    guard rows.indices.contains(model.focusRow) else { return }
                    let target = rows[model.focusRow].id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
            .navigationTitle(selecting ? "選取要移出的頁" : "概覽")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "取消選取" : "選取") {
                        selecting.toggle()
                        selected = []
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { selectionBar }
            .sheet(item: $moveRequest) { request in
                if request.within {
                    WithinMoveSheet(model: model, request: request) { count in
                        movedMessage = "已移動 \(count) 頁"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { movedMessage = nil }
                        selected = []
                        selecting = false
                    }
                } else {
                MovePagesSheet(library: library, sourceID: model.meta.id,
                               summary: { sides in model.moveSummary(sides ? model.withSidePages(request.pageIDs) : request.pageIDs) },
                               sideCount: request.askSides ? model.unselectedSideCount(request.pageIDs) : 0,
                               copy: request.copy) { target, sides, at in
                    let ids = request.askSides && sides ? model.withSidePages(request.pageIDs) : request.pageIDs
                    let count = request.copy ? (model.documentView?.copyPages(ids, to: target.id, at: at) ?? 0)
                                             : (model.documentView?.movePages(ids, to: target.id, at: at) ?? 0)
                    if count > 0 {
                        library.touchNotebook(target.id)
                        movedMessage = (request.copy ? "已複製到「" : "已移到「") + "\(target.title)」\(count) 頁"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { movedMessage = nil }
                    }
                    selected = []
                    selecting = false
                }
                }
            }
            .confirmationDialog(deleteTitle, isPresented: $showDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) { applyDelete() }
            }
        }
    }

    /// 下方：選了幾頁、移到其他筆記本；搬完顯示結果
    @ViewBuilder
    private var selectionBar: some View {
        if selecting {
            HStack(spacing: 16) {
                Picker("勾主頁時", selection: $sidesWithMain) {
                    Text("勾主頁＝含旁頁").tag(true)
                    Text("自由選").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Text(selected.isEmpty ? "還沒選" : "已選：\(model.moveSummary(Array(selected)))")
                    .font(.callout)
                Spacer()
                Button {
                    model.documentView?.flushAll()
                    moveRequest = MoveRequest(pageIDs: Array(selected), askSides: false, within: true)
                } label: {
                    Label("移到這本的…", systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(selected.isEmpty)
                Button {
                    model.documentView?.flushAll()
                    moveRequest = MoveRequest(pageIDs: Array(selected), askSides: false, copy: true)
                } label: {
                    Label("複製到其他筆記本…", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(selected.isEmpty)
                Button {
                    model.documentView?.flushAll()
                    moveRequest = MoveRequest(pageIDs: Array(selected), askSides: false)
                } label: {
                    Label("移到其他筆記本…", systemImage: "tray.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        } else if let text = movedMessage {
            Text(text)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(.regularMaterial))
                .padding(.bottom, 12)
        }
    }

    /// 這張有沒有勾
    private func isSelected(_ page: NotePage, in row: PageRow) -> Bool {
        selected.contains(page.id)
    }

    /// 點一下勾／取消。「勾主頁＝含旁頁」時，點主頁會連同這一列的旁頁一起勾或一起取消
    private func toggle(_ page: NotePage, in row: PageRow) {
        let isMain = row.pages.indices.contains(row.mainIndex) && row.pages[row.mainIndex].id == page.id
        if isMain && sidesWithMain {
            let ids = row.pages.map { $0.id }
            if selected.contains(page.id) {
                for id in ids { selected.remove(id) }
            } else {
                for id in ids { selected.insert(id) }
            }
        } else if selected.contains(page.id) {
            selected.remove(page.id)
        } else {
            selected.insert(page.id)
        }
    }

    private var deleteTitle: String {
        switch pendingDelete {
        case .row?: return "刪除這一頁和它的所有旁頁？"
        case .page?: return "刪除這張旁頁？"
        case nil: return "刪除？"
        }
    }

    /// 拖曳內容的格式是「列 ID|頁 ID」
    private func parseDrag(_ items: [String]) -> (row: UUID, page: UUID?)? {
        guard let text = items.first else { return nil }
        let parts = text.split(separator: "|").map { String($0) }
        guard let first = parts.first, let rowID = UUID(uuidString: first) else { return nil }
        let pageID = parts.count > 1 ? UUID(uuidString: parts[1]) : nil
        return (row: rowID, page: pageID)
    }

    private func applyDelete() {
        switch pendingDelete {
        case .row(let r)?: model.documentView?.deleteRow(r)
        case .page(let r, let p)?: model.documentView?.deleteSidePage(row: r, page: p)
        case nil: break
        }
        pendingDelete = nil
    }

    // 一列：左邊是頁碼，右邊是這一列的所有頁面
    @ViewBuilder
    private func rowLine(index: Int, row: PageRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                Text("\(index + 1)").font(.headline)
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
            }
            .frame(width: 34)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(row.pages.enumerated()), id: \.element.id) { pageIndex, page in
                        pageCell(rowIndex: index, row: row, pageIndex: pageIndex, page: page)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(dropTarget == row.id ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .dropDestination(for: String.self) { items, _ in
            guard let parsed = parseDrag(items) else { return false }
            model.documentView?.moveRow(id: parsed.row, toIndex: index)
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTarget = row.id
            } else if dropTarget == row.id {
                dropTarget = nil
            }
        }
    }

    // 一張縮圖：點一下跳過去；長按拖曳移動整列；「⋯」是這張頁面的操作
    @ViewBuilder
    private func pageCell(rowIndex: Int, row: PageRow, pageIndex: Int, page: NotePage) -> some View {
        let isMain = pageIndex == row.mainIndex
        let width: CGFloat = isMain ? 110 : 84
        let offset = pageIndex - row.mainIndex
        let caption = isMain ? "主頁" : (offset < 0 ? "左 \(-offset)" : "右 \(offset)")

        VStack(spacing: 4) {
            Image(uiImage: Thumbnail.image(for: page, width: width))
                .resizable()
                .scaledToFit()
                .frame(width: width)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isMain ? Color.accentColor : Color.gray.opacity(0.5), lineWidth: isMain ? 3 : 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(dropTargetPage == page.id ? Color.orange : Color.clear, lineWidth: 4)
                )
                .overlay(alignment: .topTrailing) {
                    if selecting {
                        let on = isSelected(page, in: row)
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(on ? Color.accentColor : Color.gray)
                            .background(Circle().fill(Color(uiColor: .systemBackground)))
                            .padding(4)
                    }
                }
                .opacity(selecting && !isSelected(page, in: row) ? 0.75 : 1)
                .shadow(radius: 1.5)
                .onTapGesture {
                    if selecting {
                        toggle(page, in: row)
                    } else {
                        model.documentView?.jump(toRow: rowIndex, page: pageIndex)
                        dismiss()
                    }
                }
                .draggable("\(row.id.uuidString)|\(page.id.uuidString)")
                .dropDestination(for: String.self) { items, _ in
                    guard let parsed = parseDrag(items) else { return false }
                    if parsed.row == row.id, let pageID = parsed.page {
                        // 同一列：兩張交換位置（主頁的位置不變，所以拖到主頁上的那張會變成主頁）
                        model.documentView?.swapPages(rowID: row.id, pageID: pageID, with: page.id)
                    } else {
                        // 別的列：移動整列
                        model.documentView?.moveRow(id: parsed.row, toIndex: rowIndex)
                    }
                    return true
                } isTargeted: { targeted in
                    if targeted {
                        dropTargetPage = page.id
                    } else if dropTargetPage == page.id {
                        dropTargetPage = nil
                    }
                }

            HStack(spacing: 2) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(isMain ? Color.accentColor : .secondary)
                Spacer(minLength: 0)
                Menu {
                    if isMain {
                        Button {
                            model.documentView?.addSidePage(row: rowIndex, left: true)
                        } label: {
                            Label("往左新增旁頁", systemImage: "arrow.left.square")
                        }
                        Button {
                            model.documentView?.addSidePage(row: rowIndex, left: false)
                        } label: {
                            Label("往右新增旁頁", systemImage: "arrow.right.square")
                        }
                        Button {
                            model.documentView?.insertRow(at: rowIndex)
                        } label: {
                            Label("在前面新增頁面", systemImage: "arrow.up.doc")
                        }
                        Button {
                            model.documentView?.insertRow(at: rowIndex + 1)
                        } label: {
                            Label("在後面新增頁面", systemImage: "arrow.down.doc")
                        }
                        Button {
                            model.documentView?.flushAll()
                            moveRequest = MoveRequest(pageIDs: [page.id], within: true)
                        } label: {
                            Label("移到這本的其他位置…", systemImage: "arrow.up.arrow.down")
                        }
                        Button {
                            model.documentView?.flushAll()
                            moveRequest = MoveRequest(pageIDs: [page.id], copy: true)
                        } label: {
                            Label("複製到其他筆記本…", systemImage: "doc.on.doc")
                        }
                        Button {
                            model.documentView?.flushAll()
                            moveRequest = MoveRequest(pageIDs: [page.id])
                        } label: {
                            Label("移到其他筆記本…", systemImage: "tray.and.arrow.up")
                        }
                        Divider()
                        Button(role: .destructive) {
                            pendingDelete = .row(rowIndex)
                            showDelete = true
                        } label: {
                            Label("刪除此頁（含旁頁）", systemImage: "trash")
                        }
                    } else {
                        Button {
                            model.documentView?.swapWithMain(row: rowIndex, page: pageIndex)
                        } label: {
                            Label("與主頁交換", systemImage: "arrow.left.arrow.right")
                        }
                        if pageIndex > 0 {
                            Button {
                                model.documentView?.moveSidePage(row: rowIndex, page: pageIndex, by: -1)
                            } label: {
                                Label("往左移", systemImage: "arrow.left")
                            }
                        }
                        if pageIndex < row.pages.count - 1 {
                            Button {
                                model.documentView?.moveSidePage(row: rowIndex, page: pageIndex, by: 1)
                            } label: {
                                Label("往右移", systemImage: "arrow.right")
                            }
                        }
                        Button {
                            model.documentView?.flushAll()
                            moveRequest = MoveRequest(pageIDs: [page.id], within: true)
                        } label: {
                            Label("移到這本的其他位置…", systemImage: "arrow.up.arrow.down")
                        }
                        Button {
                            model.documentView?.flushAll()
                            moveRequest = MoveRequest(pageIDs: [page.id], copy: true)
                        } label: {
                            Label("複製到其他筆記本…", systemImage: "doc.on.doc")
                        }
                        Button {
                            model.documentView?.flushAll()
                            moveRequest = MoveRequest(pageIDs: [page.id])
                        } label: {
                            Label("移到其他筆記本…", systemImage: "tray.and.arrow.up")
                        }
                        Divider()
                        Button(role: .destructive) {
                            pendingDelete = .page(row: rowIndex, page: pageIndex)
                            showDelete = true
                        } label: {
                            Label("刪除這張旁頁", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 22)
                }
            }
            .frame(width: width)
        }
    }
}
