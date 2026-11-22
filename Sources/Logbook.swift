import SwiftUI
import UIKit

// Logbook.swift（v12.15.13）：日誌（照 GUGA 的 My Logbook）。首頁右上角的月曆鈕，右邊滑出一個面板：
// 上面是月曆（有改過東西的日子底下有點），下面是那一天：自己寫的日誌條、改過的筆記本和頁面（點了直接打開、跳到那一頁）。
// 「改過」的紀錄在 ActivityLog（v12.9.5 起開始記；只打開來看不算）

/// 自己寫的日誌條：存在資料位置的 _App資料/日誌.json（{ "2026-11-20": [ { id, text, time } ] }）
struct LogNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var time = Date()
}

@MainActor
enum LogNotes {
    private static var days: [String: [LogNote]] = [:]
    private static var loaded = false
    static var url: URL { Store.systemDir.appendingPathComponent("日誌.json") }

    static func notes(_ day: String) -> [LogNote] {
        load()
        return days[day] ?? []
    }

    static var daysWithNotes: Set<String> {
        load()
        return Set(days.filter { !$0.value.isEmpty }.keys)
    }

    static func set(_ notes: [LogNote], day: String) {
        load()
        days[day] = notes.isEmpty ? nil : notes
        Store.ensureDir(Store.systemDir)
        if let data = try? JSONEncoder().encode(days) {
            do { try data.write(to: url, options: .atomic) } catch { Store.reportWriteFailure(error) }
        }
    }

    private static func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: [LogNote]].self, from: data) {
            days = saved
        }
    }
}

/// 右邊滑出來的日誌面板
struct LogbookPanel: View {
    @EnvironmentObject private var library: LibraryModel
    let close: () -> Void
    @State private var month = Date()                  // 月曆顯示哪一個月（那個月裡的任一天）
    @State private var selected = Date()
    @State private var refresh = 0                     // 寫了日誌條之後重畫

    static let width: CGFloat = 370
    private let orange = Color(red: 0.95, green: 0.42, blue: 0.27)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1                              // 星期日開頭（照 GUGA）
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Button(action: close) {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .foregroundStyle(Color.primary)
                Spacer()
                Text("My\nLogbook")
                    .font(.system(size: 34, weight: .heavy))
                    .multilineTextAlignment(.trailing)
                    .lineSpacing(-6)
            }
            monthCard
            ScrollView {
                VStack(spacing: 14) {
                    notesCard
                    modifiedCards
                }
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 0)
                .fill(Color(uiColor: .systemGray5))
                .ignoresSafeArea(edges: .bottom)
        )
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width > 80, abs(value.translation.height) < 120 { close() }   // 往右滑收起來
                }
        )
    }

    // MARK: 月曆

    private var monthCard: some View {
        let days = gridDays()
        let active = ActivityLog.activeDays().union(LogNotes.daysWithNotes)
        let monthIndex = calendar.component(.month, from: month)
        let year = calendar.component(.year, from: month)
        let thisYear = calendar.component(.year, from: Date())
        let names = ["一月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "十一月", "十二月"]
        return VStack(spacing: 10) {
            HStack(spacing: 18) {
                Text((year == thisYear ? "" : "\(year) 年 ") + names[monthIndex - 1])
                    .font(.system(size: 21, weight: .semibold))
                Spacer()
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                Button("Today") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        month = Date()
                        selected = Date()
                    }
                }
                .foregroundStyle(orange)
                .font(.system(size: 18, weight: .semibold))
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.primary)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { d in
                    Text(d).font(.system(size: 15)).foregroundStyle(.secondary)
                }
                ForEach(days, id: \.self) { day in
                    dayCell(day, inMonth: calendar.component(.month, from: day) == monthIndex,
                            marked: active.contains(ActivityLog.dayKey(day)))
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(uiColor: .systemBackground)))
        .id(refresh)
    }

    private func dayCell(_ day: Date, inMonth: Bool, marked: Bool) -> some View {
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        return VStack(spacing: 2) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 17, weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.6)))
                .frame(width: 36, height: 36)
                .background {
                    if isToday {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(orange)
                    } else if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(orange, lineWidth: 2)
                    }
                }
            Circle()
                .fill(marked ? (inMonth ? orange : orange.opacity(0.4)) : Color.clear)
                .frame(width: 5, height: 5)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                selected = day
                if !inMonth { month = day }
            }
        }
    }

    /// 這個月的格子：從包含 1 號那一週的星期日，到包含最後一天那一週的星期六
    private func gridDays() -> [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        let weekday = calendar.component(.weekday, from: first)              // 1＝星期日
        guard let start = calendar.date(byAdding: .day, value: -(weekday - 1), to: first),
              let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return [] }
        let lastWeekday = calendar.component(.weekday, from: last)
        guard let end = calendar.date(byAdding: .day, value: 7 - lastWeekday, to: last) else { return [] }
        var out: [Date] = []
        var d = start
        while d <= end {
            out.append(d)
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }

    private func shiftMonth(_ delta: Int) {
        if let m = calendar.date(byAdding: .month, value: delta, to: month) {
            withAnimation(.easeInOut(duration: 0.2)) { month = m }
        }
    }

    // MARK: 那一天

    private var dayKey: String { ActivityLog.dayKey(selected) }

    private var notesCard: some View {
        let notes = LogNotes.notes(dayKey)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(notes) { note in
                HStack(alignment: .top, spacing: 10) {
                    Text(note.time.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                    Text(note.text)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button {
                        edit(note)
                    } label: {
                        Label("修改", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        LogNotes.set(notes.filter { $0.id != note.id }, day: dayKey)
                        refresh += 1
                    } label: {
                        Label("刪除", systemImage: "trash")
                    }
                }
                Divider()
            }
            Button {
                TextPrompt.show(title: "日誌（" + selected.formatted(.dateTime.month().day()) + "）", initial: "") { text in
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    var list = LogNotes.notes(dayKey)
                    var note = LogNote(text: t)
                    if !calendar.isDateInToday(selected) {
                        note.time = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: selected) ?? selected
                    }
                    list.append(note)
                    LogNotes.set(list, day: dayKey)
                    refresh += 1
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("自訂日誌條", systemImage: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.secondary)
                    Text("輸入文字，記下這一天的事")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.7)))
        .id("notes-\(refresh)-\(dayKey)")
    }

    private func edit(_ note: LogNote) {
        TextPrompt.show(title: "修改日誌", initial: note.text) { text in
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var list = LogNotes.notes(dayKey)
            guard let i = list.firstIndex(where: { $0.id == note.id }) else { return }
            if t.isEmpty { list.remove(at: i) } else { list[i].text = t }
            LogNotes.set(list, day: dayKey)
            refresh += 1
        }
    }

    /// 那一天改過的筆記本：最後改的排前面；每本列出改過的頁（點了打開、跳到那一頁）
    @ViewBuilder
    private var modifiedCards: some View {
        let entries = ActivityLog.entries(on: selected)
        let books: [(meta: NotebookMeta, pages: [(id: UUID, first: Date, last: Date)])] = entries.compactMap { (id, pages) in
            guard let meta = library.notebook(id), meta.deletedAt == nil, meta.draftOf == nil else { return nil }   // 隨手記不列
            let list = pages.map { (id: $0.key, first: $0.value.first, last: $0.value.last) }.sorted { $0.last > $1.last }
            return (meta, list)
        }.sorted { ($0.pages.first?.last ?? .distantPast) > ($1.pages.first?.last ?? .distantPast) }
        if books.isEmpty {
            Text(calendar.isDateInToday(selected) ? "今天還沒有改過筆記" : "這天沒有改過的筆記")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else {
            ForEach(books, id: \.meta.id) { book in
                LogbookNotebookCard(meta: book.meta, pages: book.pages) { pageID in
                    open(book.meta, page: pageID)
                }
            }
        }
    }

    private func open(_ meta: NotebookMeta, page: UUID?) {
        if let page = page { library.pendingJump = PageJump(notebook: meta.id, page: page) }
        close()
        withAnimation(.easeInOut(duration: 0.25)) { library.openNotebook = meta }
    }
}

/// 日誌裡的一本：書名、改了幾頁、什麼時間；下面一頁一列
struct LogbookNotebookCard: View {
    let meta: NotebookMeta
    let pages: [(id: UUID, first: Date, last: Date)]
    let open: (UUID?) -> Void
    @State private var rows: [PageRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                open(nil)
            } label: {
                HStack {
                    Image(systemName: meta.isBoard == true ? "rectangle.dashed" : "book.closed.fill")
                        .foregroundStyle(Color.orange)
                    Text(meta.title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                    Spacer()
                    Text(span)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if meta.isBoard != true {
                ForEach(pages.prefix(12), id: \.id) { page in
                    Button {
                        open(page.id)
                    } label: {
                        HStack {
                            Text(label(page.id))
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Text(page.last.formatted(date: .omitted, time: .shortened))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                if pages.count > 12 {
                    Text("還有 \(pages.count - 12) 頁")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(uiColor: .systemBackground)))
        .onAppear { if rows.isEmpty { rows = Store.loadNotebook(meta.id).rows } }
    }

    private var span: String {
        let first = pages.map(\.first).min() ?? Date()
        let last = pages.map(\.last).max() ?? Date()
        let a = first.formatted(date: .omitted, time: .shortened)
        let b = last.formatted(date: .omitted, time: .shortened)
        let count = meta.isBoard == true ? "" : "\(pages.count) 頁 · "
        return count + (a == b ? a : a + "–" + b)
    }

    private func label(_ id: UUID) -> String {
        guard rows.contains(where: { $0.pages.contains { $0.id == id } }) else { return "（已經不在這本的頁）" }
        return NotebookView.pageLabel(id, in: rows)
    }
}
