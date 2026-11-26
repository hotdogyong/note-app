import Foundation
import Network
import SwiftUI
import UIKit
import PencilKit

// RemoteAccess.swift：讓 Mac 上的 Claude 透過區網讀寫筆記（v12.17.0，使用者要求：像 Notion 那樣讓 Claude 直接幫忙輸入）
//
// 做法：首頁「設定 → 讓 Claude 連進來」打開後，App 在 Wi-Fi 上開一個小型的 HTTP 服務（埠 8765，Bonjour 名稱 _noteapp._tcp）。
// Mac 上的 tools/noteapp.py 先用 iPad 畫面上的 6 位數配對碼換一把鑰匙（存在 Mac 的 ~/.config/noteapp/，不在 repo 裡），
// 之後每次請求都帶著鑰匙。App 進背景時服務關掉，回到前景再開（iPadOS 不讓背景的 App 一直開著）。
//
// 改打開中的那本：走畫面（NotebookView.remoteApply），可以用「上一步」復原；沒打開的：直接讀寫檔案。
// 所有座標都是頁面座標（A4 頁是 595 × 842；白板是整張大頁面）。字級 size 跟文字工具列上的數字一樣（以 A4 為準）。

// MARK: - 服務的開關、配對

@MainActor
final class RemoteAccess: ObservableObject {
    static let shared = RemoteAccess()
    static let port: UInt16 = 8765
    static let serviceType = "_noteapp._tcp"

    private static let enabledKey = "claudeLink.enabled"
    private static let tokensKey = "claudeLink.tokens"

    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: RemoteAccess.enabledKey) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }
    @Published private(set) var status = "關閉"
    @Published private(set) var pairCode = RemoteAccess.newCode()
    @Published private(set) var address = ""
    @Published private(set) var log: [String] = []           // 最近做了什麼（設定面板列出來）
    @Published private(set) var pairedCount = (UserDefaults.standard.stringArray(forKey: RemoteAccess.tokensKey) ?? []).count

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "claude.link", qos: .userInitiated)
    private var wrongCodes = 0
    private var observing = false

    private static func newCode() -> String { String(format: "%06d", Int.random(in: 0 ... 999_999)) }

    /// App 啟動時呼叫一次：打開過的話就開服務；之後跟著 App 進出前景開關
    func boot(library: LibraryModel) {
        RemoteAPI.library = library
        if !observing {
            observing = true
            let center = NotificationCenter.default
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RemoteAccess.shared.resume() }
            }
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RemoteAccess.shared.stop(keepStatus: true) }
            }
        }
        if enabled { start() }
    }

    private func resume() {
        if enabled && listener == nil { start() }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l: NWListener
            if let fixed = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!) {
                l = fixed
            } else {
                l = try NWListener(using: params)                 // 8765 被占用：讓系統挑一個
            }
            l.service = NWListener.Service(name: "筆記軟體", type: Self.serviceType)
            let q = queue
            l.newConnectionHandler = { conn in
                RemoteConnection(conn, queue: q).start()
            }
            l.stateUpdateHandler = { state in
                // 只把看得懂的文字傳回主執行緒（狀態本身不一定能跨執行緒傳）
                let info: (kind: Int, text: String)
                switch state {
                case .ready: info = (0, "")
                case .failed(let error): info = (1, error.localizedDescription)
                case .waiting(let error): info = (2, error.localizedDescription)
                default: info = (3, "")
                }
                let kind = info.kind, text = info.text
                Task { @MainActor in RemoteAccess.shared.listenerChanged(kind: kind, text: text) }
            }
            l.start(queue: q)
            listener = l
            status = "啟動中…"
        } catch {
            status = "開不起來：\(error.localizedDescription)"
        }
    }

    func stop(keepStatus: Bool = false) {
        listener?.cancel()
        listener = nil
        status = keepStatus && enabled ? "App 在背景：回到前景會再開" : "關閉"
    }

    private func listenerChanged(kind: Int, text: String) {
        switch kind {
        case 0:
            let port = listener?.port?.rawValue ?? Self.port
            address = (Self.wifiAddress() ?? "（找不到 Wi-Fi 位址）") + ":\(port)"
            status = "等待連線"
        case 1:
            status = "出錯了：\(text)"
            listener?.cancel()
            listener = nil
            // 網路換了（例如換 Wi-Fi）會讓服務失效：過一下再開一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated { RemoteAccess.shared.resume() }
            }
        case 2:
            status = "等待網路：\(text)"
        default:
            break
        }
    }

    // MARK: 配對

    var tokens: [String] { UserDefaults.standard.stringArray(forKey: Self.tokensKey) ?? [] }

    func authorized(_ r: RemoteRequest) -> Bool {
        guard let auth = r.headers["authorization"], auth.hasPrefix("Bearer ") else { return false }
        let token = String(auth.dropFirst(7))
        return !token.isEmpty && tokens.contains(token)
    }

    /// 配對碼對了就發一把鑰匙；錯 5 次換一組碼
    func pair(code: String) -> String? {
        guard enabled else { return nil }
        guard code == pairCode else {
            wrongCodes += 1
            if wrongCodes >= 5 {
                wrongCodes = 0
                pairCode = Self.newCode()
                note("配對碼錯太多次，已換一組新的")
            }
            return nil
        }
        wrongCodes = 0
        pairCode = Self.newCode()
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0 ... 255) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        var list = tokens
        list.append(token)
        UserDefaults.standard.set(list, forKey: Self.tokensKey)
        pairedCount = list.count
        note("Mac 配對成功")
        return token
    }

    func unpairAll() {
        UserDefaults.standard.removeObject(forKey: Self.tokensKey)
        pairedCount = 0
        pairCode = Self.newCode()
        note("已取消所有配對")
    }

    func note(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.insert(f.string(from: Date()) + "　" + text, at: 0)
        if log.count > 30 { log.removeLast(log.count - 30) }
    }

    /// iPad 在 Wi-Fi 上的 IPv4 位址（設定面板顯示；Mac 找不到 Bonjour 時可以手動輸入）
    static func wifiAddress() -> String? {
        var result: String?
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return nil }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = start
        while let p = ptr {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if name == "en0" || (result == nil && name.hasPrefix("en")) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let len = host.firstIndex(of: 0) ?? host.count
                        result = String(decoding: host[..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if name == "en0" { break }
                    }
                }
            }
            ptr = ifa.ifa_next
        }
        return result
    }
}

// MARK: - 一個連線：讀一個 HTTP 請求、回一個回應、關掉

struct RemoteRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

struct RemoteResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ object: Any, status: Int = 200) -> RemoteResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return RemoteResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func error(_ status: Int, _ message: String) -> RemoteResponse {
        json(["error": message], status: status)
    }
}

final class RemoteConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private static let maxSize = 30_000_000

    init(_ conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn
        self.queue = queue
    }

    func start() {
        conn.stateUpdateHandler = { [self] state in
            if case .failed = state { conn.cancel() }
        }
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, done, error in
            if let data = data { buffer.append(data) }
            if buffer.count > Self.maxSize {
                send(.error(413, "太大了"))
                return
            }
            switch parse() {
            case .some(.some(let request)):
                Task { @MainActor in
                    let response = await RemoteAPI.handle(request)
                    self.send(response)
                }
            case .some(.none):
                send(.error(400, "看不懂的請求"))
            case .none:
                if done || error != nil {
                    conn.cancel()
                } else {
                    receive()
                }
            }
        }
    }

    /// nil：還沒收完；.some(nil)：格式錯；.some(request)：收完了
    private func parse() -> RemoteRequest?? {
        let marker = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: marker) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex ..< end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .some(nil) }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return .some(nil) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = buffer.subdata(in: bodyStart ..< bodyStart + length)
        let target = String(first[1])
        let pieces = target.split(separator: "?", maxSplits: 1).map(String.init)
        let path = (pieces.first ?? "/").removingPercentEncoding ?? (pieces.first ?? "/")
        var query: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map {
                    String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
                }
                if let k = kv.first { query[k] = kv.count > 1 ? kv[1] : "" }
            }
        }
        return .some(RemoteRequest(method: String(first[0]).uppercased(), path: path, query: query,
                                   headers: headers, body: body))
    }

    private func send(_ r: RemoteResponse) {
        let reason: String
        switch r.status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        let head = "HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + r.body, completion: .contentProcessed { [self] _ in
            conn.cancel()
        })
    }
}

// MARK: - API

struct RemoteError: Error {
    var status: Int
    var message: String
    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}

@MainActor
enum RemoteAPI {
    static weak var library: LibraryModel?

    static func handle(_ r: RemoteRequest) async -> RemoteResponse {
        let parts = r.path.split(separator: "/").map(String.init)
        let access = RemoteAccess.shared
        guard access.enabled else { return .error(403, "iPad 上「讓 Claude 連進來」是關的") }
        if r.method == "GET" && parts == ["ping"] {
            return .json(["app": "筆記軟體", "version": appVersion, "paired": access.authorized(r)])
        }
        if r.method == "POST" && parts == ["pair"] {
            let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
            let code = (body["code"] as? String) ?? (body["code"] as? Int).map { String(format: "%06d", $0) } ?? ""
            guard let token = access.pair(code: code) else { return .error(401, "配對碼不對（看 iPad 的設定畫面）") }
            return .json(["token": token])
        }
        guard access.authorized(r) else {
            return .error(401, "還沒配對：iPad「首頁 → 設定 → 讓 Claude 連進來」有配對碼")
        }
        do {
            let body = r.body.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:])
            switch (r.method, parts.count) {
            case ("GET", 1) where parts[0] == "notebooks":
                return .json(listNotebooks())
            case ("POST", 1) where parts[0] == "notebooks":
                return .json(try createNotebook(body))
            case ("GET", 1) where parts[0] == "current":
                return .json(current())
            case ("GET", 2) where parts[0] == "notebooks":
                return .json(try detail(parts[1], query: r.query))
            case ("GET", 3) where parts[0] == "notebooks" && parts[2] == "image":
                return try await image(parts[1], query: r.query)
            case ("POST", 3) where parts[0] == "notebooks" && parts[2] == "texts":
                return .json(try await addTexts(parts[1], body))
            case ("POST", 3) where parts[0] == "notebooks" && parts[2] == "batch":
                return .json(try await batch(parts[1], body))
            case ("POST", 3) where parts[0] == "notebooks" && parts[2] == "images":
                return .json(try addImage(parts[1], body))
            case ("GET", 3) where parts[0] == "notebooks" && parts[2] == "ocr":
                return .json(try await ocr(parts[1], query: r.query))
            case ("GET", 3) where parts[0] == "notebooks" && parts[2] == "measure":
                return .json(try await measure(parts[1], query: r.query))
            case ("GET", 1) where parts[0] == "search":
                return .json(try search(r.query))
            case ("POST", 1) where parts[0] == "open":
                return .json(try openNotebook(body))
            case ("PATCH", 4) where parts[0] == "notebooks" && parts[2] == "texts":
                return .json(try updateText(parts[1], box: parts[3], body))
            case ("DELETE", 4) where parts[0] == "notebooks" && parts[2] == "texts":
                return .json(try deleteText(parts[1], box: parts[3]))
            case ("POST", 3) where parts[0] == "notebooks" && parts[2] == "pages":
                return .json(try addPages(parts[1], body))
            case ("POST", 3) where parts[0] == "notebooks" && parts[2] == "outline":
                return .json(try addOutline(parts[1], body))
            default:
                return .error(404, "沒有這個功能：\(r.method) \(r.path)")
            }
        } catch let e as RemoteError {
            return .error(e.status, e.message)
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    // MARK: 找筆記本、找頁

    struct Target {
        let meta: NotebookMeta
        let view: NotebookView?
        var data: NotebookData
        var isBoard: Bool { data.board ?? false }
    }

    private static var liveNotebooks: [NotebookMeta] {
        Store.libraryCache.notebooks.filter { $0.deletedAt == nil && $0.draftOf == nil }
    }

    static func openView(_ id: UUID) -> NotebookView? {
        let views = NotebookView.openViews.allObjects.filter { $0.model.meta.id == id }
        return views.first(where: { $0.window != nil }) ?? views.first
    }

    /// 用編號或名稱找筆記本（名稱要完全一樣；同名的有好幾本就要用編號）
    static func target(_ key: String) throws -> Target {
        let all = liveNotebooks
        var meta: NotebookMeta?
        if key == "current" {
            guard let view = frontView() else { throw RemoteError(404, "iPad 上現在沒有打開的筆記本") }
            meta = all.first(where: { $0.id == view.model.meta.id }) ?? view.model.meta
        } else if let id = UUID(uuidString: key) {
            meta = all.first(where: { $0.id == id })
        } else {
            let same = all.filter { $0.title == key }
            if same.count > 1 { throw RemoteError(409, "有 \(same.count) 本叫「\(key)」，請用編號") }
            meta = same.first ?? {
                let near = all.filter { $0.title.localizedCaseInsensitiveContains(key) }
                return near.count == 1 ? near[0] : nil
            }()
        }
        guard let m = meta else { throw RemoteError(404, "找不到筆記本「\(key)」") }
        let view = openView(m.id)
        return Target(meta: m, view: view, data: view?.model.notebook ?? Store.loadNotebook(m.id))
    }

    /// 使用者現在在看的那一本（不是白板浮動視窗裡的優先）
    static func frontView() -> NotebookView? {
        let views = NotebookView.openViews.allObjects.filter { $0.window != nil }
        return views.first(where: { !$0.model.embedded }) ?? views.first
    }

    /// page：省略或 "current"＝畫面上那頁；數字＝第幾頁（1 開始，主頁）；"last"＝最後一頁；或頁的編號
    static func page(_ value: Any?, in t: Target) throws -> (row: Int, index: Int) {
        let rows = t.data.rows
        guard !rows.isEmpty else { throw RemoteError(404, "這本沒有頁") }
        if t.isBoard { return (0, 0) }
        if value == nil || (value as? String) == "current" {
            guard let view = t.view else { throw RemoteError(400, "這本沒打開：要寫 page（第幾頁）") }
            if let id = view.remoteVisibleRect()?.page, let loc = view.model.location(of: id) { return (loc.row, loc.page) }
            let r = min(max(view.model.focusRow, 0), rows.count - 1)
            return (r, rows[r].mainIndex)
        }
        if let n = value as? Int {
            guard n >= 1 && n <= rows.count else { throw RemoteError(400, "第 \(n) 頁不存在（共 \(rows.count) 頁）") }
            return (n - 1, rows[n - 1].mainIndex)
        }
        if let s = value as? String {
            if s == "last" { return (rows.count - 1, rows[rows.count - 1].mainIndex) }
            if let n = Int(s) { return try page(n, in: t) }
            if let id = UUID(uuidString: s) {
                for (r, row) in rows.enumerated() {
                    if let i = row.pages.firstIndex(where: { $0.id == id }) { return (r, i) }
                }
            }
        }
        throw RemoteError(404, "找不到這一頁：\(String(describing: value!))")
    }

    // MARK: 讀

    static func listNotebooks() -> [String: Any] {
        let lib = Store.libraryCache
        func folderPath(_ id: UUID?) -> String {
            var names: [String] = []
            var cur = id
            var guardCount = 0
            while let c = cur, let f = lib.folders.first(where: { $0.id == c }), guardCount < 20 {
                names.insert(f.name, at: 0)
                cur = f.parentID
                guardCount += 1
            }
            return names.joined(separator: "/")
        }
        let iso = ISO8601DateFormatter()
        let list: [[String: Any]] = liveNotebooks.sorted { $0.modified > $1.modified }.map { m in
            var d: [String: Any] = ["id": m.id.uuidString, "title": m.title, "board": m.isBoard ?? false,
                                    "folder": folderPath(m.folderID), "modified": iso.string(from: m.modified),
                                    "open": openView(m.id) != nil]
            if let b = m.boardID, let owner = lib.notebooks.first(where: { $0.id == b }) { d["inBoard"] = owner.title }
            return d
        }
        return ["notebooks": list]
    }

    static func current() -> [String: Any] {
        guard let view = frontView() else { return ["open": false] }
        let m = view.model
        var d: [String: Any] = ["open": true, "id": m.meta.id.uuidString, "title": m.meta.title, "board": m.isBoard,
                                "pages": m.notebook.rows.count]
        if let seen = view.remoteVisibleRect(), let loc = m.location(of: seen.page) {
            d["page"] = loc.row + 1
            d["side"] = loc.page
            d["pageID"] = seen.page.uuidString
            d["visible"] = rectDict(seen.rect)
        }
        let windows = NotebookView.openViews.allObjects.filter { $0.window != nil && $0.model.embedded }
        if !windows.isEmpty { d["windows"] = windows.map { $0.model.meta.title } }
        return d
    }

    static func rectDict(_ r: CGRect) -> [String: Any] {
        ["x": round1(r.minX), "y": round1(r.minY), "w": round1(r.width), "h": round1(r.height)]
    }

    static func round1(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }

    static func hex(_ c: [Double]?) -> String? {
        guard let c = c, c.count >= 3 else { return nil }
        return String(format: "#%02X%02X%02X", Int((c[0] * 255).rounded()), Int((c[1] * 255).rounded()), Int((c[2] * 255).rounded()))
    }

    static func boxDict(_ t: TextBox, page: NotePage, measured: CGRect? = nil) -> [String: Any] {
        let f = measured ?? PageRenderer.textFrameRect(t, page: page)
        var d: [String: Any] = ["id": t.id.uuidString, "text": t.text, "x": round1(f.minX), "y": round1(f.minY),
                                "w": round1(f.width), "h": round1(f.height),
                                "size": round1(t.fontSize / pageScaleFactor(page.spec)),
                                "color": hex(t.rgba) ?? "#FFFFFF"]
        if let fill = t.fill { d["frame"] = ["color": hex(fill) ?? "", "mode": t.fillMode ?? 0, "shape": t.shape ?? 1] }
        if t.bold { d["bold"] = true }
        if t.underline == true { d["underline"] = true }
        if t.isMarkdown { d["markdown"] = true }
        if t.sticky == true { d["sticky"] = true }
        if t.fixedWidth != nil { d["fixedWidth"] = true }
        d["measured"] = measured != nil                  // true：畫面上量到的實際大小；false：用字估的
        return d
    }

    static func detail(_ key: String, query: [String: String]) throws -> [String: Any] {
        let t = try target(key)
        let rows = t.data.rows
        let from = max(Int(query["from"] ?? "") ?? 1, 1)
        let to = min(Int(query["to"] ?? "") ?? rows.count, rows.count)
        let withText = query["texts"] != "0"
        var pages: [[String: Any]] = []
        if from <= to {
            for r in (from - 1) ... (to - 1) {
                let row = rows[r]
                for (i, p) in row.pages.enumerated() {
                    var d: [String: Any] = ["page": r + 1, "side": i, "main": i == row.mainIndex, "id": p.id.uuidString,
                                            "width": round1(p.spec.width), "height": round1(p.spec.height),
                                            "scale": round1(pageScaleFactor(p.spec) * 100) / 100,
                                            "dark": p.isDarkBackground,
                                            "paper": PaperStyle.patternNames[min(max(p.paperStyle.pattern, 0), 4)]
                                                + "／" + PaperStyle.colorNames[min(max(p.paperStyle.color, 0), 2)]]
                    if let pdf = p.pdf { d["pdf"] = ["file": pdf.file, "index": pdf.index] }
                    if p.cover != nil { d["cover"] = true }
                    if FileManager.default.fileExists(atPath: Store.drawingURL(p.id).path) || BoardTiles.isTiled(p.id) {
                        d["ink"] = true
                    }
                    if withText {
                        let sizes = t.view?.remoteMeasured(p.id) ?? [:]
                        d["texts"] = (p.texts ?? []).map { boxDict($0, page: p, measured: sizes[$0.id]) }
                        let links = (p.links ?? []).map { ["id": $0.id.uuidString, "from": $0.from.uuidString, "to": $0.to.uuidString,
                                                           "fromSide": $0.fromSide, "toSide": $0.toSide] as [String: Any] }
                        if !links.isEmpty { d["links"] = links }
                    } else {
                        d["textCount"] = (p.texts ?? []).count
                    }
                    let images = (p.images ?? []).map { b -> [String: Any] in
                        var x: [String: Any] = ["id": b.id.uuidString, "x": round1(b.x), "y": round1(b.y),
                                                "w": round1(b.width), "h": round1(b.height)]
                        if let c = b.caption { x["caption"] = c }
                        if b.link != nil { x["card"] = true }
                        return x
                    }
                    if !images.isEmpty { d["images"] = images }
                    pages.append(d)
                }
            }
        }
        var pageNumber: [UUID: Int] = [:]
        for (r, row) in rows.enumerated() { for p in row.pages { pageNumber[p.id] = r + 1 } }
        let outline = (t.data.outline ?? []).map { o -> [String: Any] in
            var d: [String: Any] = ["id": o.id.uuidString, "title": o.title, "page": pageNumber[o.pageID] ?? 0]
            if let p = o.parentID { d["parent"] = p.uuidString }
            return d
        }
        var result: [String: Any] = ["id": t.meta.id.uuidString, "title": t.meta.title, "board": t.isBoard,
                                     "pageCount": rows.count, "open": t.view != nil, "pages": pages, "outline": outline]
        if let view = t.view, let seen = view.remoteVisibleRect(), let loc = view.model.location(of: seen.page) {
            result["visible"] = ["page": loc.row + 1, "side": loc.page, "rect": rectDict(seen.rect)]
        }
        return result
    }

    /// 一頁（或白板的一塊）畫成 JPEG：Claude 用來看排版
    static func image(_ key: String, query: [String: String]) async throws -> RemoteResponse {
        let t = try target(key)
        t.view?.remoteFlush()
        let loc = try page(query["page"], in: t)
        let page = t.data.rows[loc.row].pages[loc.index]
        await renderMath(page, timeout: 4)
        let region = try imageRegion(page, query: query, view: t.view, board: t.isBoard)
        let pixelWidth = CGFloat(min(max(Double(query["width"] ?? "") ?? 1200, 200), 2400))
        let img = try renderRegion(page, region: region, pixelWidth: pixelWidth)
        guard let data = img.jpegData(compressionQuality: 0.82) else { throw RemoteError(500, "畫不出來") }
        return RemoteResponse(status: 200, contentType: "image/jpeg", body: data)
    }

    /// 要畫哪一塊：給了 x、y、w、h 就用它；筆記本＝整頁；白板＝畫面看得到的那塊（沒開著就是所有方塊的範圍）
    static func imageRegion(_ page: NotePage, query: [String: String], view: NotebookView?, board: Bool) throws -> CGRect {
        let full = CGRect(x: 0, y: 0, width: page.spec.width, height: page.spec.height)
        var region = full
        if let x = Double(query["x"] ?? ""), let y = Double(query["y"] ?? ""),
           let w = Double(query["w"] ?? ""), let h = Double(query["h"] ?? "") {
            region = CGRect(x: x, y: y, width: w, height: h)
        } else if board {
            if let seen = view?.remoteVisibleRect() {
                region = seen.rect
            } else {
                let frames = (page.texts ?? []).map { PageRenderer.textFrameRect($0, page: page) }
                if let first = frames.first {
                    region = frames.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -80, dy: -80)
                } else {
                    region = CGRect(x: full.midX - 800, y: full.midY - 500, width: 1600, height: 1000)
                }
            }
        }
        region = region.intersection(full)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { throw RemoteError(400, "範圍不在頁面裡") }
        return region
    }

    /// 一頁的一塊畫成圖（寬 pixelWidth 像素）
    static func renderRegion(_ page: NotePage, region: CGRect, pixelWidth: CGFloat) throws -> UIImage {
        let full = CGRect(x: 0, y: 0, width: page.spec.width, height: page.spec.height)
        let k = pixelWidth / region.width
        let size = CGSize(width: pixelWidth, height: max(region.height * k, 1))
        guard size.height <= 6000 else { throw RemoteError(400, "範圍太長：把 h 改小或 width 改小") }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.scaleBy(x: k, y: k)
            cg.translateBy(x: -region.minX, y: -region.minY)
            PageRenderer.draw(page, in: cg, rect: full, inkScale: k, region: region)
        }
        return img
    }

    /// 數學式還沒排好的先排（匯出只畫排好的；最多等 8 秒）
    static func renderMath(_ page: NotePage, timeout: Double = 8) async {
        let width = textWrapWidth(page.spec)
        let requests = (page.texts ?? []).filter { MathRenderer.needsRender($0) }
            .map { MathRenderer.request(for: $0, pageWidth: width) }
            .filter { MathRenderer.shared.cached($0) == nil }
        guard !requests.isEmpty else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let wait = MathWait(count: requests.count, cont: cont)
            for req in requests {
                MathRenderer.shared.render(req) { _ in
                    MainActor.assumeIsolated { wait.oneDone() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated { wait.finish() }
            }
        }
    }

    // MARK: 寫：文字方塊

    static func color(_ value: Any?) -> [Double]? {
        guard var s = value as? String else { return nil }
        switch s.lowercased() {
        case "white": return [1, 1, 1, 1]
        case "black": return [0, 0, 0, 1]
        default: break
        }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return [Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, 1]
    }

    /// 外框：none、blue（淡紫藍圓角框）、default（跟點兩下新增的一樣）、"#RRGGBB"（那個顏色的外框），
    /// 或 {"color": "#RRGGBB", "mode": 0 填滿／1 外框＋上面一條／2 只有外框, "shape": 0 方／1 圓角／2 圓頭}
    static func applyFrame(_ value: Any?, to box: inout TextBox, dark: Bool) throws {
        var style = TextStyleDefault.load(dark: dark)
        if let s = value as? String {
            switch s {
            case "none": style = TextStyleDefault(fill: nil, fillMode: nil, shape: nil)
            case "blue": style = TextStyleDefault.builtIn
            case "default": break
            default:
                guard let c = color(s) else { throw RemoteError(400, "看不懂的 frame：\(s)") }
                style = TextStyleDefault(fill: Array(c.prefix(3)), fillMode: 2, shape: 1)
            }
        } else if let d = value as? [String: Any] {
            guard let c = color(d["color"]) else { throw RemoteError(400, "frame 要有 color") }
            style = TextStyleDefault(fill: Array(c.prefix(3)), fillMode: d["mode"] as? Int ?? 2, shape: d["shape"] as? Int ?? 1)
        }
        box.fill = style.fill
        box.fillMode = style.fill == nil ? nil : style.fillMode
        box.shape = style.fill == nil ? nil : style.shape
    }

    static func number(_ v: Any?) -> CGFloat? {
        if let d = v as? Double { return CGFloat(d) }
        if let i = v as? Int { return CGFloat(i) }
        if let s = v as? String, let d = Double(s) { return CGFloat(d) }
        return nil
    }

    /// 自動排的位置：白板＝畫面看得到的左上角往下排（沒打開就接在最下面的方塊下面）；筆記本＝接在這頁最下面的東西下面
    static func autoStart(_ page: NotePage, view: NotebookView?, board: Bool) -> CGPoint {
        let k = pageScaleFactor(page.spec)
        if board, let seen = view?.remoteVisibleRect(), seen.page == page.id {
            // 白板：接在畫面上看得到的東西下面（v12.17.1：以前一律從左上角放，圖蓋到標題）
            var bottom: CGFloat?
            var left = seen.rect.minX + 60
            let frames = (page.texts ?? []).map { PageRenderer.textFrameRect($0, page: page) }
                + (page.images ?? []).map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            for f in frames where f.intersects(seen.rect) && f.maxY > (bottom ?? -.infinity) {
                bottom = f.maxY
                left = max(f.minX, seen.rect.minX + 20)
            }
            if let b = bottom, b + 40 < seen.rect.maxY { return CGPoint(x: left, y: b + 24) }
            return CGPoint(x: seen.rect.minX + 60, y: seen.rect.minY + 60)
        }
        var bottom: CGFloat?
        var left: CGFloat = 40 * k
        for t in page.texts ?? [] {
            let f = PageRenderer.textFrameRect(t, page: page)
            if bottom == nil || f.maxY > bottom! {
                bottom = f.maxY
                if board { left = f.minX }
            }
        }
        for b in page.images ?? [] where !board || bottom != nil {
            bottom = max(bottom ?? 0, b.y + b.height)
        }
        if let b = bottom { return CGPoint(x: left, y: b + 24 * k) }
        if board { return CGPoint(x: page.spec.width / 2 - 300, y: page.spec.height / 2 - 200) }
        return CGPoint(x: 40 * k, y: 40 * k)
    }

    static func makeBox(_ d: [String: Any], page: NotePage, notebookID: UUID, board: Bool, at origin: CGPoint) throws -> TextBox {
        guard let text = d["text"] as? String else { throw RemoteError(400, "每個方塊都要有 text") }
        let k = pageScaleFactor(page.spec)
        var box = TextBox()
        box.text = text
        box.fontSize = (number(d["size"]) ?? TextDefaults.size(notebookID)) * k
        box.bold = (d["bold"] as? Bool) ?? TextDefaults.bold(notebookID)
        if d["underline"] as? Bool == true { box.underline = true }
        switch d["align"] as? String {
        case "center": box.align = 1
        case "right": box.align = 2
        default: box.align = 0
        }
        let dark = page.isDarkBackground
        box.rgba = color(d["color"]) ?? TextDefaults.rgba(notebookID) ?? (dark ? [1, 1, 1, 1] : [0, 0, 0, 1])
        try applyFrame(d["frame"], to: &box, dark: dark)
        box.rgba = TextBoxStyle.readable(text: box.rgba, fill: box.fill, mode: box.fillMode)
        if d["sticky"] as? Bool == true {
            box.sticky = true
            box.fill = NotebookView.stickyFill
            box.fillMode = 0
            box.rgba = [0.1, 0.1, 0.1, 1]
        }
        let x = number(d["x"]) ?? origin.x
        let y = number(d["y"]) ?? origin.y
        let markdown = d["markdown"] as? Bool == true
        if markdown { box.markdown = true }
        let maxRight = page.spec.width - x - 20 * k
        if let w = number(d["width"]) {
            box.fixedWidth = max(min(w, page.spec.width - x), 40)
            box.width = box.fixedWidth ?? w
        } else {
            let font = TextBoxView.font(for: box, scale: 1)
            let natural = text.components(separatedBy: "\n").map {
                ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 2
            }.max() ?? 40
            let limit = max(min((board ? 520 : 460) * k, maxRight), 120)
            if markdown || natural > limit {
                box.fixedWidth = limit
                box.width = limit
            } else {
                box.width = max(natural, 20)
            }
        }
        box.x = min(max(x, 0), max(page.spec.width - box.width - 10, 0))
        box.y = min(max(y, 0), max(page.spec.height - 30, 0))
        return box
    }

    /// 連線預設從哪一邊出來：右邊有空就右→左，不然下→上
    static func sides(_ a: CGRect, _ b: CGRect) -> (Int, Int) {
        if b.minX >= a.maxX - 4 { return (1, 3) }
        if b.maxX <= a.minX + 4 { return (3, 1) }
        if b.minY >= a.maxY - 4 { return (2, 0) }
        return (0, 2)
    }

    static func makeLinks(_ list: [[String: Any]], keys: [String: UUID], page: NotePage) throws -> [BoxLink] {
        var frames: [UUID: CGRect] = [:]
        for t in page.texts ?? [] { frames[t.id] = PageRenderer.textFrameRect(t, page: page) }
        func id(_ v: Any?) throws -> UUID {
            guard let s = v as? String else { throw RemoteError(400, "連線要有 from、to") }
            if let k = keys[s] { return k }
            if let u = UUID(uuidString: s), frames[u] != nil { return u }
            throw RemoteError(400, "連線找不到方塊：\(s)")
        }
        return try list.map { d in
            let a = try id(d["from"]), b = try id(d["to"])
            let auto = sides(frames[a] ?? .zero, frames[b] ?? .zero)
            var link = BoxLink(from: a, fromSide: d["fromSide"] as? Int ?? auto.0, to: b, toSide: d["toSide"] as? Int ?? auto.1)
            if let c = color(d["color"]) { link.rgb = Array(c.prefix(3)) }
            if d["dash"] as? Bool == true { link.dash = true }
            switch d["arrow"] as? String {
            case "none": link.arrow = 1
            case "both": link.arrow = 2
            default: break
            }
            switch d["route"] as? String {
            case "straight": link.route = 1
            case "curve": link.route = 2
            default: break
            }
            return link
        }
    }

    /// 一頁的文字方塊、連線改好之後寫回去：打開中的走畫面（可復原），沒打開的直接存檔
    static func commit(_ t: inout Target, row: Int, index: Int, texts: [TextBox], links: [BoxLink],
                       images: [ImageBox]? = nil, focus: CGRect?, message: String) {
        let pageID = t.data.rows[row].pages[index].id
        if let view = t.view {
            view.remoteApply(pageID: pageID, texts: texts, links: links, images: images, focus: focus, message: message)
            t.data = view.model.notebook
        } else {
            var data = Store.loadNotebook(t.meta.id)
            for r in data.rows.indices {
                if let i = data.rows[r].pages.firstIndex(where: { $0.id == pageID }) {
                    data.rows[r].pages[i].texts = texts.isEmpty ? nil : texts
                    data.rows[r].pages[i].links = links.isEmpty ? nil : links
                    if let images = images { data.rows[r].pages[i].images = images.isEmpty ? nil : images }
                    data.rows[r].pages[i].modified = Date()
                }
            }
            Store.saveNotebook(data, id: t.meta.id)
            ActivityLog.touch(pageID: pageID)
            t.data = data
        }
        library?.touchNotebook(t.meta.id)
        RemoteAccess.shared.note("「\(t.meta.title)」" + message)
    }

    /// POST /notebooks/{id}/texts：{page, boxes:[{key, text, x, y, width, size, color, frame, bold, align, markdown, sticky}], links:[{from, to}]}
    static func addTexts(_ key: String, _ body: [String: Any]) async throws -> [String: Any] {
        var t = try target(key)
        if t.meta.deletedAt != nil { throw RemoteError(400, "這本在最近刪除裡") }
        guard let list = body["boxes"] as? [[String: Any]], !list.isEmpty else { throw RemoteError(400, "要有 boxes") }
        let loc = try page(body["page"], in: t)
        var page = t.data.rows[loc.row].pages[loc.index]
        let board = t.isBoard
        let k = pageScaleFactor(page.spec)
        var cursor = autoStart(page, view: t.view, board: board)
        if let x = number(body["x"]) { cursor.x = x }
        if let y = number(body["y"]) { cursor.y = y }
        let gap = number(body["gap"]) ?? 20 * k
        var texts = page.texts ?? []
        var keys: [String: UUID] = [:]
        var created: [(String?, TextBox)] = []
        var union = CGRect.null
        for d in list {
            let box = try makeBox(d, page: page, notebookID: t.meta.id, board: board, at: cursor)
            texts.append(box)
            page.texts = texts
            if let key = d["key"] as? String { keys[key] = box.id }
            created.append((d["key"] as? String, box))
            let f = PageRenderer.textFrameRect(box, page: page)
            union = union.union(f)
            // 沒寫 y 的下一個方塊接在這個下面；寫了 x、y 的不影響自動排的位置
            if d["x"] == nil && d["y"] == nil { cursor.y = f.maxY + gap }
        }
        var links = page.links ?? []
        if let ls = body["links"] as? [[String: Any]] {
            links += try makeLinks(ls, keys: keys, page: page)
        }
        commit(&t, row: loc.row, index: loc.index, texts: texts, links: links, focus: union,
               message: "加了 \(created.count) 個文字方塊")
        let saved = t.data.rows[loc.row].pages[loc.index]
        let sizes = await measuredAfterChange(t, page: saved)
        let boxes: [[String: Any]] = created.map { key, box in
            var d = boxDict(box, page: saved, measured: sizes[box.id])
            if let key = key { d["key"] = key }
            return d
        }
        return ["page": loc.row + 1, "pageID": saved.id.uuidString, "boxes": boxes,
                "overflow": union.maxY > saved.spec.height,
                "note": sizes.isEmpty ? "這本沒開著：大小是用字估的，數學式排版後可能不同" : "measured＝true 的是畫面上量到的實際大小"]
    }

    static func findBox(_ t: Target, _ boxKey: String) throws -> (row: Int, index: Int, box: Int) {
        guard let id = UUID(uuidString: boxKey) else { throw RemoteError(400, "方塊編號不對") }
        for (r, row) in t.data.rows.enumerated() {
            for (i, p) in row.pages.enumerated() {
                if let b = (p.texts ?? []).firstIndex(where: { $0.id == id }) { return (r, i, b) }
            }
        }
        throw RemoteError(404, "找不到這個方塊")
    }

    /// PATCH /notebooks/{id}/texts/{box}：改字、位置、寬度、字級、顏色、外框
    static func updateText(_ key: String, box boxKey: String, _ body: [String: Any]) throws -> [String: Any] {
        var t = try target(key)
        let loc = try findBox(t, boxKey)
        let page = t.data.rows[loc.row].pages[loc.index]
        var texts = page.texts ?? []
        var box = texts[loc.box]
        try applyChanges(&box, body, page: page, board: t.isBoard)
        texts[loc.box] = box
        var after = page
        after.texts = texts
        commit(&t, row: loc.row, index: loc.index, texts: texts, links: page.links ?? [],
               focus: PageRenderer.textFrameRect(box, page: after), message: "改了 1 個文字方塊")
        return ["box": boxDict(box, page: after)]
    }

    /// 改一個方塊：text、x、y、width、size、bold、color、frame、align（PATCH 和 batch 共用）
    static func applyChanges(_ box: inout TextBox, _ body: [String: Any], page: NotePage, board: Bool) throws {
        let k = pageScaleFactor(page.spec)
        if let s = body["text"] as? String {
            box.text = s
            if box.fixedWidth == nil {
                // 自動寬度的方塊：照新的字重算寬度（太長就固定寬度換行）
                let font = TextBoxView.font(for: box, scale: 1)
                let natural = s.components(separatedBy: "\n").map {
                    ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 2
                }.max() ?? 40
                let limit = max(min((board ? 520 : 460) * k, page.spec.width - box.x - 20 * k), 120)
                if natural > limit {
                    box.fixedWidth = limit
                    box.width = limit
                } else {
                    box.width = max(natural, 20)
                }
            }
        }
        if let x = number(body["x"]) { box.x = x }
        if let y = number(body["y"]) { box.y = y }
        if let w = number(body["width"]) {
            box.fixedWidth = max(w, 40)
            box.width = box.fixedWidth ?? w
        }
        if let s = number(body["size"]) { box.fontSize = s * k }
        if let b = body["bold"] as? Bool { box.bold = b }
        if let u = body["underline"] as? Bool { box.underline = u ? true : nil }
        if let c = color(body["color"]) { box.rgba = c }
        if body["frame"] != nil { try applyFrame(body["frame"], to: &box, dark: page.isDarkBackground) }
        switch body["align"] as? String {
        case "left": box.align = 0
        case "center": box.align = 1
        case "right": box.align = 2
        default: break
        }
    }

    /// DELETE /notebooks/{id}/texts/{box}（連到它的線一起拿掉；打開中的可以用「上一步」復原）
    static func deleteText(_ key: String, box boxKey: String) throws -> [String: Any] {
        var t = try target(key)
        let loc = try findBox(t, boxKey)
        let page = t.data.rows[loc.row].pages[loc.index]
        var texts = page.texts ?? []
        let gone = texts.remove(at: loc.box)
        let links = (page.links ?? []).filter { $0.from != gone.id && $0.to != gone.id }
        commit(&t, row: loc.row, index: loc.index, texts: texts, links: links, focus: nil, message: "刪了 1 個文字方塊")
        return ["deleted": gone.id.uuidString]
    }

    // MARK: 寫：頁、大綱、新筆記本

    /// POST /notebooks/{id}/pages：{after: 第幾頁後面（0＝最前面；省略＝畫面上那頁後面，沒打開就最後面）, count, pages:[{boxes, links}]}
    static func addPages(_ key: String, _ body: [String: Any]) throws -> [String: Any] {
        let t = try target(key)
        if t.isBoard { throw RemoteError(400, "白板不能加頁") }
        let rows = t.data.rows
        let contents = body["pages"] as? [[String: Any]] ?? []
        let count = max(contents.count, (body["count"] as? Int) ?? 1)
        guard count <= 50 else { throw RemoteError(400, "一次最多 50 頁") }
        var at: Int
        if let a = body["after"] as? Int {
            at = min(max(a, 0), rows.count)
        } else if (body["after"] as? String) == "last" || t.view == nil {
            at = rows.count
        } else {
            at = min((try? page("current", in: t).row).map { $0 + 1 } ?? rows.count, rows.count)
        }
        // 紙張跟前一頁一樣（課本頁、封面的話用一般的紙）
        let refRow = rows.isEmpty ? nil : rows[max(min(at - 1, rows.count - 1), 0)]
        let ref = refRow.map { $0.pages[min($0.mainIndex, $0.pages.count - 1)] }
        var spec = PageSpec()
        var paper = PaperStyle()
        if let r = ref {
            if r.pdf == nil && r.cover == nil { spec = r.spec; paper = r.paperStyle }
            else if let anyPlain = rows.flatMap({ $0.pages }).first(where: { $0.pdf == nil && $0.cover == nil }) {
                spec = anyPlain.spec
                paper = anyPlain.paperStyle
            }
        }
        if let c = body["paper"] as? String {
            if c == "white" { paper.color = 1 } else if c == "dark" { paper.color = 0 } else if c == "cream" { paper.color = 2 }
        }
        var newRows: [PageRow] = []
        var created: [[String: Any]] = []
        for n in 0 ..< count {
            var page = NotePage(spec: spec, paper: paper)
            var keys: [String: UUID] = [:]
            var boxCount = 0
            if n < contents.count, let list = contents[n]["boxes"] as? [[String: Any]] {
                var cursor = autoStart(page, view: nil, board: false)
                for d in list {
                    let box = try makeBox(d, page: page, notebookID: t.meta.id, board: false, at: cursor)
                    page.texts = (page.texts ?? []) + [box]
                    if let key = d["key"] as? String { keys[key] = box.id }
                    let f = PageRenderer.textFrameRect(box, page: page)
                    if d["x"] == nil && d["y"] == nil { cursor.y = f.maxY + 20 * pageScaleFactor(spec) }
                    boxCount += 1
                }
                if let ls = contents[n]["links"] as? [[String: Any]] {
                    let links = try makeLinks(ls, keys: keys, page: page)
                    page.links = links.isEmpty ? nil : links
                }
            }
            page.modified = Date()
            var row = PageRow()
            row.pages = [page]
            newRows.append(row)
            created.append(["page": at + n + 1, "pageID": page.id.uuidString, "boxes": boxCount])
        }
        if let view = t.view {
            _ = view.remoteInsertRows(newRows, at: at)
        } else {
            var data = Store.loadNotebook(t.meta.id)
            data.rows.insert(contentsOf: newRows, at: min(at, data.rows.count))
            Store.saveNotebook(data, id: t.meta.id)
            for row in newRows { ActivityLog.touch(pageID: row.pages[0].id) }
        }
        library?.touchNotebook(t.meta.id)
        RemoteAccess.shared.note("「\(t.meta.title)」加了 \(count) 頁")
        return ["pages": created]
    }

    /// POST /notebooks/{id}/outline：{title, page, parent}（大綱多一項）
    static func addOutline(_ key: String, _ body: [String: Any]) throws -> [String: Any] {
        let t = try target(key)
        guard let title = body["title"] as? String, !title.isEmpty else { throw RemoteError(400, "要有 title") }
        let loc = try page(body["page"], in: t)
        var item = OutlineItem(title: title, pageID: t.data.rows[loc.row].pages[loc.index].id)
        if let p = body["parent"] as? String { item.parentID = UUID(uuidString: p) }
        if let view = t.view {
            view.model.notebook.outline = (view.model.notebook.outline ?? []) + [item]
            view.model.save()
        } else {
            var data = Store.loadNotebook(t.meta.id)
            data.outline = (data.outline ?? []) + [item]
            Store.saveNotebook(data, id: t.meta.id)
        }
        RemoteAccess.shared.note("「\(t.meta.title)」大綱加了「\(title)」")
        return ["id": item.id.uuidString]
    }

    /// POST /notebooks：{title, board, folder}（folder 是資料夾名稱；省略＝最外層）
    static func createNotebook(_ body: [String: Any]) throws -> [String: Any] {
        guard let library = library else { throw RemoteError(500, "首頁還沒準備好") }
        let title = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "未命名筆記本"
        var folder: UUID?
        if let name = body["folder"] as? String, !name.isEmpty {
            let matches = Store.libraryCache.folders.filter { $0.deletedAt == nil && $0.name == name }
            guard let f = matches.first else { throw RemoteError(404, "找不到資料夾「\(name)」") }
            folder = f.id
        }
        let meta: NotebookMeta
        if body["board"] as? Bool == true {
            meta = library.addBoard(in: folder, title: title, width: 100 * 842, height: 100 * 595)
        } else {
            meta = library.addNotebook(in: folder, title: title)
        }
        RemoteAccess.shared.note("新增了「\(meta.title)」")
        return ["id": meta.id.uuidString, "title": meta.title]
    }
}

/// 等幾個數學式排好（全部好了或時間到，只繼續一次）
@MainActor
final class MathWait {
    private var left: Int
    private var cont: CheckedContinuation<Void, Never>?

    init(count: Int, cont: CheckedContinuation<Void, Never>) {
        left = count
        self.cont = cont
    }

    func oneDone() {
        left -= 1
        if left <= 0 { finish() }
    }

    func finish() {
        cont?.resume()
        cont = nil
    }
}

// MARK: - 設定面板裡的一段

struct RemoteAccessSection: View {
    @ObservedObject private var access = RemoteAccess.shared
    @State private var confirmUnpair = false

    var body: some View {
        Section {
            Toggle(isOn: $access.enabled) {
                Label("讓 Claude 連進來", systemImage: "sparkles")
            }
            if access.enabled {
                HStack {
                    Text("狀態")
                    Spacer()
                    Text(access.status).foregroundStyle(.secondary)
                }
                HStack {
                    Text("位址")
                    Spacer()
                    Text(access.address.isEmpty ? "—" : access.address)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("配對碼")
                    Spacer()
                    Text(access.pairCode)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .textSelection(.enabled)
                }
                if access.pairedCount > 0 {
                    Button(role: .destructive) {
                        confirmUnpair = true
                    } label: {
                        Text("取消所有配對（已配對 \(access.pairedCount) 台）")
                    }
                }
                if !access.log.isEmpty {
                    DisclosureGroup("最近的動作") {
                        ForEach(access.log, id: \.self) { line in
                            Text(line).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("打開後，同一個 Wi-Fi 上的 Mac 可以用配對碼連進來，讀筆記、加文字方塊和頁面。筆記軟體要開在前景才連得到；學校、咖啡廳的 Wi-Fi 常常擋裝置互連，可以用 Mac 的熱點。不用時關掉就好。")
        }
        .confirmationDialog("取消所有配對？", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("取消配對", role: .destructive) { access.unpairAll() }
        } message: {
            Text("Mac 要再輸入一次配對碼才能連進來。")
        }
    }
}
