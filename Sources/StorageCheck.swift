import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// StorageCheck.swift：儲存空間檢查（v12.9.6）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）
//
// 使用者回報：開著 App 時 iPad 一直跳「裝置空間不足」，但設定裡看起來還有剩。
// 設定裡顯示的可用空間包含「系統需要時可以清掉的」（快取等），真正空著的可能少很多；
// 記憶體不夠時系統也會把記憶體暫存到儲存空間。這裡把兩種可用空間、這個 App 自己佔的、暫存檔都列出來，
// 並且可以清掉 App 自己的暫存（匯出時產生的 PDF、數學式快取），找出是誰在吃空間

/// 設定畫面裡的「儲存空間（檢查用）」
struct StorageCheckSection: View {
    @State private var report: StorageReport?
    @State private var working = false

    var body: some View {
        Section {
            if let r = report {
                row("真正空著的", r.freeNow)
                row("可用（含系統可清掉的，設定裡看到的接近這個）", r.freeImportant)
                row("這個 App 自己佔的（全部）", r.appTotal)
                row("　暫存（匯出的 PDF 等）", r.temp)
                row("　快取", r.caches)
                row("資料位置（筆記本、白板）", r.dataFolder)
                row("　數學式／Markdown 排好的圖", r.mathCache)
                row("　歷史版本", r.history)
            }
            Button {
                measure()
            } label: {
                Label(working ? "計算中…" : (report == nil ? "檢查儲存空間" : "重新檢查"), systemImage: "internaldrive")
            }
            .disabled(working)
            Button(role: .destructive) {
                StorageReport.clear(StorageReport.tempURL)
                StorageReport.clear(StorageReport.cachesURL)
                measure()
            } label: {
                Label("清掉暫存和快取（匯出過的 PDF 等，不會動到筆記）", systemImage: "trash")
            }
            Button(role: .destructive) {
                StorageReport.clear(StorageReport.mathCacheURL)
                measure()
            } label: {
                Label("清掉數學式／Markdown 的圖（之後會重新排）", systemImage: "function")
            }
        } header: {
            Text("儲存空間（檢查用）")
        } footer: {
            Text("「真正空著的」很少、但「可用」很多：是系統的快取佔著，系統需要時會自己清。開著 App 時「真正空著的」一直變少，可能是記憶體不夠、系統把記憶體暫存到儲存空間（關掉 App 或重開機就會回來）。")
        }
    }

    private func row(_ title: String, _ bytes: Int64?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(bytes.map { StorageReport.format($0) } ?? "—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func measure() {
        working = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)      // 先讓「計算中…」顯示出來
            report = StorageReport.make()
            working = false
        }
    }
}

/// 量出來的結果（位元組）
struct StorageReport {
    var freeNow: Int64?
    var freeImportant: Int64?
    var appTotal: Int64?
    var temp: Int64?
    var caches: Int64?
    var dataFolder: Int64?
    var mathCache: Int64?
    var history: Int64?

    static var tempURL: URL { FileManager.default.temporaryDirectory }
    /// 匯出的 PDF 放這裡（v12.9.7）：開 App 時只清這個子資料夾，不動暫存資料夾裡別的東西
    static var exportURL: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("筆記匯出", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var cachesURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }
    static var mathCacheURL: URL { Store.systemDir.appendingPathComponent("數學式快取", isDirectory: true) }

    static func make() -> StorageReport {
        var r = StorageReport()
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        if let values = try? home.resourceValues(forKeys: keys) {
            r.freeNow = values.volumeAvailableCapacity.map { Int64($0) }
            r.freeImportant = values.volumeAvailableCapacityForImportantUsage
        }
        r.appTotal = size(of: home)
        r.temp = size(of: tempURL)
        r.caches = size(of: cachesURL)
        r.dataFolder = size(of: Store.dir)
        r.mathCache = size(of: mathCacheURL)
        r.history = historySize()
        return r
    }

    /// 所有筆記本資料夾裡「歷史版本」的總大小
    private static func historySize() -> Int64 {
        var total: Int64 = 0
        guard let e = FileManager.default.enumerator(at: Store.dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        while let item = e.nextObject() as? URL {
            if item.lastPathComponent == "歷史版本" {
                total += size(of: item) ?? 0
                e.skipDescendants()
            }
        }
        return total
    }

    /// 資料夾（或檔案）的大小：所有檔案加起來
    static func size(of url: URL) -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: Set(keys))
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        while let item = e.nextObject() as? URL {
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// 清掉一個資料夾裡的東西（資料夾本身留著）
    static func clear(_ url: URL) {
        // 保險：資料位置在這個資料夾裡面的話不清（不會動到筆記）
        if Store.dir.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path) { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }

    static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }
}
