import SwiftUI
import UIKit
import Vision

// PageTools.swift（v12.15.11）：跳轉捷徑的選擇畫面、辨識文字（OCR）

/// 辨識出來的文字（顯示在一個可以選、可以拷貝的視窗）
struct OCRResult: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// 長按空白處「跳轉」：要在哪裡放捷徑
struct JumpPick: Identifiable {
    let id = UUID()
    let point: CGPoint
}

/// 用 iPad 內建的文字辨識（Vision）：繁中、英文，不用網路
enum TextRecognizer {
    static func recognize(_ image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) { () -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hant", "en-US"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ""
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}

/// 辨識結果：可以選一段拷貝，或整份拷貝
struct OCRSheet: View {
    let result: OCRResult
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .padding(12)
                .navigationTitle("辨識出來的文字（\(result.title)）")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("關閉") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(copied ? "已拷貝" : "全部拷貝") {
                            UIPasteboard.general.string = text
                            copied = true
                        }
                        .bold()
                    }
                }
        }
        .onAppear { text = result.text }
    }
}

/// 跳轉捷徑：先選哪一本（這一本或別本），再選哪一頁
struct JumpPickerSheet: View {
    @ObservedObject var library: LibraryModel
    let currentID: UUID
    let currentTitle: String
    let currentRows: [PageRow]
    let done: (PageJump, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var target: (meta: NotebookMeta?, title: String, rows: [PageRow])?

    var body: some View {
        if let target = target {
            NavigationStack {
                PageChoicePicker(title: target.title, rows: target.rows) { index in
                    let row = target.rows[index]
                    let page = row.pages.indices.contains(row.mainIndex) ? row.pages[row.mainIndex] : row.pages[0]
                    let label = target.meta == nil ? "→ 第 \(index + 1) 頁" : "→ \(target.title) 第 \(index + 1) 頁"
                    done(PageJump(notebook: target.meta?.id, page: page.id), label)
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
                MoveFolderLevel(library: library, folderID: nil, sourceID: currentID,
                                header: AnyView(Section("這一本") {
                                    Button {
                                        target = (nil, currentTitle, currentRows)
                                    } label: {
                                        Label(currentTitle, systemImage: "book.closed.fill")
                                    }
                                }),
                                pick: { meta in
                                    let rows = Store.loadNotebook(meta.id).rows
                                    if rows.isEmpty { return }
                                    target = (meta, meta.title, rows)
                                },
                                pickSection: "別本筆記本",
                                rootTitle: "跳到哪一本？",
                                allowCreate: false)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { dismiss() }
                    }
                }
            }
        }
    }
}

/// 選一頁（跳轉捷徑的目的地）：一格一頁，點了就選它
struct PageChoicePicker: View {
    let title: String
    let rows: [PageRow]
    let confirm: (Int) -> Void
    @State private var chosen = 0
    @State private var jump = ""

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("點一頁，捷徑就會跳到那一頁")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("第幾頁", text: $jump)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Button("跳過去") {
                        guard let n = Int(jump.trimmingCharacters(in: .whitespaces)), n >= 1, !rows.isEmpty else { return }
                        chosen = min(n, rows.count) - 1
                        withAnimation { proxy.scrollTo(chosen, anchor: .center) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 14)], spacing: 16) {
                        ForEach(rows.indices, id: \.self) { i in
                            PagePositionCell(page: rows[i].pages.indices.contains(rows[i].mainIndex)
                                                ? rows[i].pages[rows[i].mainIndex] : (rows[i].pages.first ?? NotePage()),
                                             number: i + 1,
                                             sides: rows[i].pages.count - 1,
                                             mark: chosen == i ? .after : .none,
                                             dimmed: false,
                                             label: "跳到這頁")
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { chosen = i }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("跳到「\(title)」的哪一頁？")
        .navigationBarTitleDisplayMode(.inline)
        .presentationSizing(.page)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("放捷徑") { if rows.indices.contains(chosen) { confirm(chosen) } }
                    .bold()
            }
        }
    }
}
// rebuild
