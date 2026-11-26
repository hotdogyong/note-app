import Foundation
import UIKit
import CoreImage

// RemoteTools.swift：Claude 連進來時比較進階的工具（v12.17.1；RemoteAccess.swift 的延伸）
// 使用者回饋：一般 Claude 整排往下移要 30 幾個方塊一個一個改、方塊高度是估的要一直看截圖 →
//   batch：一次加、改、移、刪很多方塊和連線（打開中的只算一步「上一步」）
//   measure：畫面上量到的實際大小（數學式排好之後）
//   images：從 Mac 放一張圖進來；search：所有筆記本找字；open：叫 iPad 打開某本、跳到某頁某塊；ocr：手寫變文字

extension RemoteAPI {

    // MARK: 實際大小

    /// 改完之後量畫面上的實際大小（等數學式排好；沒開著的筆記本量不到，回空的）
    /// 不另外叫數學式排版（排版一次只能排一個，多叫會拖慢畫面上的）；還沒排好的數學式方塊不算量到
    static func measuredAfterChange(_ t: Target, page: NotePage) async -> [UUID: CGRect] {
        guard let view = t.view else { return [:] }
        try? await Task.sleep(nanoseconds: 500_000_000)         // 等畫面排好
        return view.remoteMeasured(page.id)                     // 數學式還是原文的不算量到（TextBoxView.mathNotShown）
    }

    /// GET /notebooks/{id}/measure?page=：這頁每個方塊畫面上的實際範圍（要開著）
    static func measure(_ key: String, query: [String: String]) async throws -> [String: Any] {
        let t = try target(key)
        guard t.view != nil else { throw RemoteError(400, "這本沒開著，量不到實際大小：先用 open 打開") }
        let loc = try page(query["page"], in: t)
        let page = t.data.rows[loc.row].pages[loc.index]
        let sizes = await measuredAfterChange(t, page: page)
        let boxes = (page.texts ?? []).map { boxDict($0, page: page, measured: sizes[$0.id]) }
        return ["page": loc.row + 1, "pageID": page.id.uuidString, "boxes": boxes,
                "note": "measured＝false：不在畫面附近（頁還沒載入）或數學式還沒排好，大小是估的；過一兩秒再量一次"]
    }

    // MARK: 批次

    /// POST /notebooks/{id}/batch：同一頁一次做很多事，打開中的筆記本只算一步「上一步」。順序：
    /// delete（方塊 id）→ deleteImages → update（[{id, text, x, y, width, size, color, frame, bold, align}]）
    /// → move（{ids 或 rect:{x,y,w,h}, dx, dy}；rect＝中心點在範圍裡的方塊和圖片）→ unlink（連線 id）
    /// → add（跟 texts 的 boxes 一樣）→ links（key 或 id）
    static func batch(_ key: String, _ body: [String: Any]) async throws -> [String: Any] {
        var t = try target(key)
        if t.meta.deletedAt != nil { throw RemoteError(400, "這本在最近刪除裡") }
        // 沒給 page：從要改的方塊找它在哪一頁
        var loc: (row: Int, index: Int)
        if body["page"] == nil, let first = firstBoxID(body), let found = try? findBox(t, first) {
            loc = (found.row, found.index)
        } else {
            loc = try page(body["page"], in: t)
        }
        var page = t.data.rows[loc.row].pages[loc.index]
        let board = t.isBoard
        let k = pageScaleFactor(page.spec)
        var texts = page.texts ?? []
        var links = page.links ?? []
        var images = page.images ?? []
        var imagesChanged = false
        var touched = Set<UUID>()
        var summary: [String] = []

        func index(_ s: String) throws -> Int {
            guard let id = UUID(uuidString: s), let i = texts.firstIndex(where: { $0.id == id }) else {
                throw RemoteError(404, "這頁沒有方塊 \(s)")
            }
            return i
        }

        if let list = body["delete"] as? [String], !list.isEmpty {
            for s in list {
                let gone = texts.remove(at: try index(s))
                links.removeAll { $0.from == gone.id || $0.to == gone.id }
            }
            summary.append("刪了 \(list.count) 個方塊")
        }
        if let list = body["deleteImages"] as? [String], !list.isEmpty {
            let ids = Set(list.compactMap { UUID(uuidString: $0) })
            let before = images.count
            images.removeAll { ids.contains($0.id) }
            links.removeAll { ids.contains($0.from) || ids.contains($0.to) }
            imagesChanged = true
            summary.append("刪了 \(before - images.count) 張圖")
        }
        if let list = body["update"] as? [[String: Any]], !list.isEmpty {
            page.texts = texts
            for change in list {
                guard let s = change["id"] as? String else { throw RemoteError(400, "update 每一項要有 id") }
                let i = try index(s)
                try applyChanges(&texts[i], change, page: page, board: board)
                touched.insert(texts[i].id)
            }
            summary.append("改了 \(list.count) 個方塊")
        }
        if let move = body["move"] as? [String: Any] {
            let dx = number(move["dx"]) ?? 0
            let dy = number(move["dy"]) ?? 0
            var ids = Set((move["ids"] as? [String] ?? []).compactMap { UUID(uuidString: $0) })
            if let r = move["rect"] as? [String: Any], let x = number(r["x"]), let y = number(r["y"]),
               let w = number(r["w"]), let h = number(r["h"]) {
                let rect = CGRect(x: x, y: y, width: w, height: h)
                page.texts = texts
                for b in texts {
                    let f = PageRenderer.textFrameRect(b, page: page)
                    if rect.contains(CGPoint(x: f.midX, y: f.midY)) { ids.insert(b.id) }
                }
                for img in images where rect.contains(CGPoint(x: img.x + img.width / 2, y: img.y + img.height / 2)) {
                    ids.insert(img.id)
                }
            }
            var moved = 0
            for i in texts.indices where ids.contains(texts[i].id) && !texts[i].isLocked {
                texts[i].x += dx
                texts[i].y += dy
                touched.insert(texts[i].id)
                moved += 1
            }
            for i in images.indices where ids.contains(images[i].id) && !images[i].isLocked {
                images[i].x += dx
                images[i].y += dy
                imagesChanged = true
                moved += 1
            }
            summary.append("移了 \(moved) 個")
        }
        if let list = body["unlink"] as? [String], !list.isEmpty {
            let ids = Set(list.compactMap { UUID(uuidString: $0) })
            links.removeAll { ids.contains($0.id) }
            summary.append("拿掉 \(list.count) 條線")
        }
        var keys: [String: UUID] = [:]
        var created: [(String?, UUID)] = []
        if let list = body["add"] as? [[String: Any]], !list.isEmpty {
            page.texts = texts
            var cursor = autoStart(page, view: t.view, board: board)
            if let x = number(body["x"]) { cursor.x = x }
            if let y = number(body["y"]) { cursor.y = y }
            let gap = number(body["gap"]) ?? 20 * k
            for d in list {
                let box = try makeBox(d, page: page, notebookID: t.meta.id, board: board, at: cursor)
                texts.append(box)
                page.texts = texts
                if let key = d["key"] as? String { keys[key] = box.id }
                created.append((d["key"] as? String, box.id))
                touched.insert(box.id)
                if d["x"] == nil && d["y"] == nil { cursor.y = PageRenderer.textFrameRect(box, page: page).maxY + gap }
            }
            summary.append("加了 \(list.count) 個方塊")
        }
        if let list = body["links"] as? [[String: Any]], !list.isEmpty {
            page.texts = texts
            links += try makeLinks(list, keys: keys, page: page)
            summary.append("加了 \(list.count) 條線")
        }
        guard !summary.isEmpty else { throw RemoteError(400, "batch 裡沒有要做的事（delete、update、move、unlink、add、links）") }

        page.texts = texts
        var focus = CGRect.null
        for b in texts where touched.contains(b.id) { focus = focus.union(PageRenderer.textFrameRect(b, page: page)) }
        commit(&t, row: loc.row, index: loc.index, texts: texts, links: links, images: imagesChanged ? images : nil,
               focus: focus.isNull ? nil : focus, message: summary.joined(separator: "、"))
        let saved = t.data.rows[loc.row].pages[loc.index]
        let sizes = await measuredAfterChange(t, page: saved)
        let keyOf = Dictionary(created.compactMap { k, id in k.map { (id, $0) } }, uniquingKeysWith: { a, _ in a })
        let boxes: [[String: Any]] = (saved.texts ?? []).filter { touched.contains($0.id) }.map { b in
            var d = boxDict(b, page: saved, measured: sizes[b.id])
            if let key = keyOf[b.id] { d["key"] = key }
            return d
        }
        let bottom = (saved.texts ?? []).map { PageRenderer.textFrameRect($0, page: saved).maxY }.max() ?? 0
        return ["page": loc.row + 1, "pageID": saved.id.uuidString, "done": summary, "boxes": boxes,
                "overflow": bottom > saved.spec.height]
    }

    /// batch 沒給 page 時，用第一個提到的方塊找頁
    private static func firstBoxID(_ body: [String: Any]) -> String? {
        if let d = body["delete"] as? [String], let f = d.first { return f }
        if let u = body["update"] as? [[String: Any]], let f = u.first?["id"] as? String { return f }
        if let m = body["move"] as? [String: Any], let ids = m["ids"] as? [String], let f = ids.first { return f }
        return nil
    }

    // MARK: 圖片

    /// POST /notebooks/{id}/images：{page, data（base64 的 PNG／JPEG）, x, y, width, height, above}
    static func addImage(_ key: String, _ body: [String: Any]) throws -> [String: Any] {
        var t = try target(key)
        guard var b64 = body["data"] as? String else { throw RemoteError(400, "要有 data（base64 的圖）") }
        if let comma = b64.firstIndex(of: ","), b64.hasPrefix("data:") { b64 = String(b64[b64.index(after: comma)...]) }
        guard let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), var image = UIImage(data: raw) else {
            throw RemoteError(400, "看不懂這張圖（要 PNG 或 JPEG）")
        }
        image = downscaled(image, maxSide: 2400)                // 存檔空間有限：太大的先縮
        let loc = try page(body["page"], in: t)
        let page = t.data.rows[loc.row].pages[loc.index]
        let k = pageScaleFactor(page.spec)
        let start = autoStart(page, view: t.view, board: t.isBoard)
        let x = number(body["x"]) ?? start.x
        let y = number(body["y"]) ?? start.y
        let aspect = image.size.height / max(image.size.width, 1)
        var width = number(body["width"]) ?? min(image.size.width, 360 * k, page.spec.width - x - 20 * k)
        var height = number(body["height"]) ?? width * aspect
        if body["width"] == nil, let h = number(body["height"]) { width = h / max(aspect, 0.0001); height = h }
        guard let file = Store.saveImage(image, pageID: page.id) else { throw RemoteError(500, "圖存不進去（空間不夠？）") }
        var box = ImageBox(file: file)
        box.x = x
        box.y = y
        box.width = max(width, 8)
        box.height = max(height, 8)
        if body["above"] as? Bool == true { box.above = true }
        let images = (page.images ?? []) + [box]
        commit(&t, row: loc.row, index: loc.index, texts: page.texts ?? [], links: page.links ?? [], images: images,
               focus: CGRect(x: box.x, y: box.y, width: box.width, height: box.height), message: "放了 1 張圖")
        return ["page": loc.row + 1, "id": box.id.uuidString,
                "x": round1(box.x), "y": round1(box.y), "w": round1(box.width), "h": round1(box.height)]
    }

    static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let side = max(image.size.width, image.size.height) * image.scale
        guard side > maxSide else { return image }
        let k = maxSide / side
        let size = CGSize(width: image.size.width * image.scale * k, height: image.size.height * image.scale * k)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: 搜尋

    /// GET /search?q=&limit=：所有筆記本的文字方塊、大綱、名稱裡找字
    static func search(_ query: [String: String]) throws -> [String: Any] {
        guard let q = query["q"]?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { throw RemoteError(400, "要有 q") }
        let limit = min(max(Int(query["limit"] ?? "") ?? 60, 1), 300)
        var hits: [[String: Any]] = []
        var more = false
        func snippet(_ text: String) -> String {
            guard let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return String(text.prefix(80)) }
            let start = text.index(r.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(r.upperBound, offsetBy: 50, limitedBy: text.endIndex) ?? text.endIndex
            return (start > text.startIndex ? "…" : "") + text[start ..< end].replacingOccurrences(of: "\n", with: " ")
                + (end < text.endIndex ? "…" : "")
        }
        outer: for meta in Store.libraryCache.notebooks where meta.deletedAt == nil && meta.draftOf == nil {
            let base: [String: Any] = ["notebook": meta.title, "notebookID": meta.id.uuidString]
            if meta.title.localizedCaseInsensitiveContains(q) {
                hits.append(base.merging(["kind": "名稱"]) { a, _ in a })
            }
            let data = openView(meta.id)?.model.notebook ?? Store.loadNotebook(meta.id)
            var pageNumber: [UUID: Int] = [:]
            for (r, row) in data.rows.enumerated() {
                for p in row.pages {
                    pageNumber[p.id] = r + 1
                    for b in p.texts ?? [] where b.text.localizedCaseInsensitiveContains(q) {
                        if hits.count >= limit { more = true; break outer }
                        hits.append(base.merging(["kind": "方塊", "page": r + 1, "pageID": p.id.uuidString,
                                                  "box": b.id.uuidString, "x": round1(b.x), "y": round1(b.y),
                                                  "text": snippet(b.text)]) { a, _ in a })
                    }
                }
            }
            for o in data.outline ?? [] where o.title.localizedCaseInsensitiveContains(q) {
                if hits.count >= limit { more = true; break outer }
                hits.append(base.merging(["kind": "大綱", "page": pageNumber[o.pageID] ?? 0, "text": o.title]) { a, _ in a })
            }
        }
        return ["query": q, "hits": hits, "more": more,
                "note": "只找得到打字的文字方塊、大綱、名稱；手寫和課本 PDF 裡的字找不到（手寫可以用 ocr）"]
    }

    // MARK: 打開、跳頁

    /// POST /open：{notebook, page, rect:{x,y,w,h}}：iPad 打開那一本（開成分頁），跳到那一頁、把那一塊捲進畫面
    static func openNotebook(_ body: [String: Any]) throws -> [String: Any] {
        guard let library = library else { throw RemoteError(500, "首頁還沒準備好") }
        guard let key = body["notebook"] as? String else { throw RemoteError(400, "要有 notebook") }
        let t = try target(key)
        var rect: CGRect?
        if let r = body["rect"] as? [String: Any], let x = number(r["x"]), let y = number(r["y"]),
           let w = number(r["w"]), let h = number(r["h"]) {
            rect = CGRect(x: x, y: y, width: w, height: h)
        }
        var pageID: UUID?
        var pageNo: Int?
        if body["page"] != nil || (t.isBoard && rect != nil) {
            // 沒開著的時候 page("current") 不能用：先當第一頁
            let value: Any? = (body["page"] as? String) == "current" && t.view == nil ? (1 as Any?) : body["page"]
            let loc = try page(value ?? 1, in: t)
            pageID = t.data.rows[loc.row].pages[loc.index].id
            pageNo = loc.row + 1
        }
        let id = t.meta.id
        let front = frontView()?.model.meta.id == id
        if !front {
            library.openNotebook = library.notebook(id) ?? t.meta
        }
        if let pid = pageID {
            if front, let view = openView(id) {
                view.remoteShow(pageID: pid, rect: rect)
            } else {
                // 剛打開：等畫面排好、回到上次位置之後再跳
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                    MainActor.assumeIsolated { RemoteAPI.openView(id)?.remoteShow(pageID: pid, rect: rect) }
                }
            }
        }
        RemoteAccess.shared.note("打開「\(t.meta.title)」" + (pageNo.map { " 第 \($0) 頁" } ?? ""))
        var result: [String: Any] = ["opened": t.meta.title, "id": id.uuidString]
        if let n = pageNo { result["page"] = n }
        if !front { result["note"] = "剛打開，過 1～2 秒再讀 current" }
        return result
    }

    // MARK: 手寫辨識

    /// GET /notebooks/{id}/ocr?page=&x&y&w&h：把那一塊（含手寫）畫成圖，用系統的文字辨識變成文字（中文、英文）
    static func ocr(_ key: String, query: [String: String]) async throws -> [String: Any] {
        let t = try target(key)
        t.view?.remoteFlush()
        let loc = try page(query["page"], in: t)
        let page = t.data.rows[loc.row].pages[loc.index]
        let region = try imageRegion(page, query: query, view: t.view, board: t.isBoard)
        let pixelWidth = min(max(region.width * 1.6, 800), 1200)  // 手寫認得出來就好；大白板畫太大很慢（模擬器裡 1600 要 20 幾秒）
        let image = try renderRegion(page, region: region, pixelWidth: pixelWidth)
        guard var cg = image.cgImage else { throw RemoteError(500, "畫不出來") }
        if page.isDarkBackground, let inverted = invert(cg) { cg = inverted }   // 深色紙白字 → 白底黑字比較好認
        let text = await TextRecognizer.recognize(cg)
        return ["page": loc.row + 1, "region": rectDict(region), "text": text,
                "note": "系統的文字辨識：中英文手寫還可以，數學式、符號常常認錯，要對照 image 看"]
    }

    static func invert(_ cg: CGImage) -> CGImage? {
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let out = filter.outputImage else { return nil }
        return CIContext().createCGImage(out, from: input.extent)
    }
}
