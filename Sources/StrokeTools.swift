import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit

// StrokeTools.swift：筆跡相關：停筆變形（ShapeSnapper）、虛線、筆跡點擊判斷、筆跡的選取框（SelectionEditorView）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

// MARK: - 8. 停筆變形：畫完停住約半秒，當下就變成直線、三角形、四邊形、圓或橢圓

/// 記錄 Pencil 這一筆經過的點；停住約 0.45 秒（還沒抬筆）就通知
final class PencilHoldTracker: UIGestureRecognizer {
    /// 回傳 true 代表已經變形，這一筆不再觸發
    var onHold: (([CGPoint]) -> Bool)?
    var onTouchDown: (() -> Void)?
    private(set) var points: [CGPoint] = []
    private var stillPoint = CGPoint.zero
    private var holdTask: Task<Void, Never>?
    private var fired = false
    private let radius: CGFloat = 5

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        onTouchDown?()
        let p = t.location(in: view)
        points = [p]
        stillPoint = p
        fired = false
        scheduleHold()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        let samples = event.coalescedTouches(for: t) ?? [t]
        for sample in samples { points.append(sample.location(in: view)) }
        let p = t.location(in: view)
        if hypot(p.x - stillPoint.x, p.y - stillPoint.y) > radius {
            stillPoint = p
            scheduleHold()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        holdTask?.cancel()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        holdTask?.cancel()
        state = .failed
    }

    override func reset() {
        super.reset()
        holdTask?.cancel()
    }

    private func scheduleHold() {
        holdTask?.cancel()
        guard !fired else { return }
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self = self, !Task.isCancelled, !self.fired else { return }
            if self.onHold?(self.points) == true { self.fired = true }
        }
    }
}

enum ShapeKind {
    case line
    case closed
}

struct SnappedShape {
    var kind: ShapeKind
    var points: [CGPoint]      // 頁面座標
}

@MainActor
enum ShapeSnapper {
    /// 輸入一筆的點（頁面座標），回傳標準圖形；不像任何圖形就回傳 nil
    static func shapePoints(for raw: [CGPoint]) -> SnappedShape? {
        let pts = resample(raw, step: 3)
        guard pts.count >= 4, let s = pts.first, let e = pts.last else { return nil }
        let xs = pts.map { $0.x }
        let ys = pts.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let w = maxX - minX
        let h = maxY - minY
        let size = max(w, h)
        guard size >= 30 else { return nil }        // 約 1 公分以下不處理，避免把手寫字變形
        let chord = hypot(e.x - s.x, e.y - s.y)

        // 1. 直線：頭尾距離接近整筆的大小，而且中間的點都貼近這條線
        if chord > 0.75 * size {
            let maxDeviation = pts.map { distance($0, lineFrom: s, to: e) }.max() ?? 0
            guard maxDeviation <= max(6, 0.1 * chord) else { return nil }
            let ends = snapLineAngle(s, e)
            return SnappedShape(kind: .line, points: linePoints(ends.0, ends.1))
        }
        guard w >= 12, h >= 12 else { return nil }

        // 2. 三角形、四邊形、橢圓、圓都試著套一次，選平均偏差最小的（頭尾不用剛好接上）
        var bestError = CGFloat.greatestFiniteMagnitude
        var best: [CGPoint]?

        let corners = findCorners(pts, size: size)
        for k in [3, 4] where corners.count >= k && corners.count <= k + 2 {
            let polygon = keepSharpest(corners, count: k)
            let error = meanError(pts, size: size) { distance($0, toPolygon: polygon) }
            if error < bestError {
                bestError = error
                // 四邊形一律整理成矩形（接近正方形就變正方形）；三角形把接近水平、垂直的邊拉正
                best = polygonPoints(k == 4 ? regularRectangle(polygon) : regularTriangle(polygon))
            }
        }

        let c = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let rx = w / 2
        let ry = h / 2
        let ellipseError = meanError(pts, size: size) { distance($0, toEllipseCenter: c, rx: rx, ry: ry) }
        if ellipseError < bestError {
            bestError = ellipseError
            if abs(rx - ry) / max(rx, ry) < 0.15 {
                let r = (rx + ry) / 2
                best = ellipsePoints(c, r, r)
            } else {
                best = ellipsePoints(c, rx, ry)
            }
        }

        // 只畫了一部分的圓弧，用最小平方法找圓心和半徑
        if let circle = fitCircle(pts), circle.r < 2 * size {
            let error = meanError(pts, size: size) { abs(hypot($0.x - circle.c.x, $0.y - circle.c.y) - circle.r) }
            if error < bestError {
                bestError = error
                best = ellipsePoints(circle.c, circle.r, circle.r)
            }
        }

        // 平均偏差超過圖形大小的 6%，代表畫的不像任何一種，就不變形
        guard bestError < 0.06, let points = best else { return nil }
        return SnappedShape(kind: .closed, points: points)
    }

    /// 螢光筆：停住時一律變成從起點到終點的直線（接近水平、垂直時轉正，容許 8 度）
    static func markerLine(for raw: [CGPoint]) -> SnappedShape? {
        guard let a = raw.first, let b = raw.last, hypot(b.x - a.x, b.y - a.y) >= 20 else { return nil }
        let ends = snapLineAngle(a, b, step: .pi / 2, tolerance: 8)
        return SnappedShape(kind: .line, points: linePoints(ends.0, ends.1))
    }

    /// 直線接近水平、垂直或 45 度時（差 4 度以內），以中點為軸轉正
    static func snapLineAngle(_ a: CGPoint, _ b: CGPoint,
                              step: CGFloat = .pi / 4, tolerance: CGFloat = 4) -> (CGPoint, CGPoint) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let snapped = (angle / step).rounded() * step
        guard abs(angle - snapped) < tolerance * .pi / 180 else { return (a, b) }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let half = hypot(b.x - a.x, b.y - a.y) / 2
        let d = CGPoint(x: cos(snapped) * half, y: sin(snapped) * half)
        return (CGPoint(x: mid.x - d.x, y: mid.y - d.y), CGPoint(x: mid.x + d.x, y: mid.y + d.y))
    }

    static func rotate(_ p: CGPoint, around c: CGPoint, by t: CGFloat) -> CGPoint {
        let x = p.x - c.x
        let y = p.y - c.y
        return CGPoint(x: c.x + x * cos(t) - y * sin(t), y: c.y + x * sin(t) + y * cos(t))
    }

    /// 四個轉角 → 標準矩形。先找出主要方向（傾斜 12 度以內就轉正），再取對邊的平均位置
    static func regularRectangle(_ corners: [CGPoint]) -> [CGPoint] {
        guard corners.count == 4 else { return corners }
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        for i in 0..<4 {
            let a = corners[i]
            let b = corners[(i + 1) % 4]
            let t = atan2(b.y - a.y, b.x - a.x)
            sx += cos(4 * t)
            sy += sin(4 * t)
        }
        var theta = atan2(sy, sx) / 4                      // 以 90 度為週期的平均方向
        if abs(theta) < 12 * .pi / 180 { theta = 0 }
        let c = CGPoint(x: corners.map { $0.x }.reduce(0, +) / 4, y: corners.map { $0.y }.reduce(0, +) / 4)
        let straight = corners.map { rotate($0, around: c, by: -theta) }
        let xs = straight.map { $0.x }.sorted()
        let ys = straight.map { $0.y }.sorted()
        var left = (xs[0] + xs[1]) / 2
        var right = (xs[2] + xs[3]) / 2
        var top = (ys[0] + ys[1]) / 2
        var bottom = (ys[2] + ys[3]) / 2
        let w = right - left
        let h = bottom - top
        if abs(w - h) / max(w, h) < 0.12 {                 // 長寬差不到 12%：當成正方形
            let side = (w + h) / 2
            let mx = (left + right) / 2
            let my = (top + bottom) / 2
            left = mx - side / 2
            right = mx + side / 2
            top = my - side / 2
            bottom = my + side / 2
        }
        let rect = [CGPoint(x: left, y: top), CGPoint(x: right, y: top),
                    CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)]
        return rect.map { rotate($0, around: c, by: theta) }
    }

    /// 三角形：接近水平或垂直的邊（差 8 度以內）拉正
    static func regularTriangle(_ corners: [CGPoint]) -> [CGPoint] {
        var result = corners
        for i in 0..<result.count {
            let j = (i + 1) % result.count
            let a = result[i]
            let b = result[j]
            let angle = abs(atan2(b.y - a.y, b.x - a.x)) * 180 / .pi     // 0 到 180 度
            if min(angle, 180 - angle) < 8 {
                let y = (a.y + b.y) / 2
                result[i].y = y
                result[j].y = y
            } else if abs(angle - 90) < 8 {
                let x = (a.x + b.x) / 2
                result[i].x = x
                result[j].x = x
            }
        }
        return result
    }

    static func meanError(_ pts: [CGPoint], size: CGFloat, _ d: (CGPoint) -> CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for p in pts { total += d(p) }
        return total / CGFloat(pts.count) / size
    }

    /// 把點重新取樣成間距固定的點
    static func resample(_ pts: [CGPoint], step: CGFloat) -> [CGPoint] {
        guard var last = pts.first else { return [] }
        var out = [last]
        var carry: CGFloat = 0
        for p in pts.dropFirst() {
            var dx = p.x - last.x
            var dy = p.y - last.y
            var length = hypot(dx, dy)
            while carry + length >= step && length > 0 {
                let t = (step - carry) / length
                let q = CGPoint(x: last.x + dx * t, y: last.y + dy * t)
                out.append(q)
                last = q
                dx = p.x - last.x
                dy = p.y - last.y
                length = hypot(dx, dy)
                carry = 0
            }
            carry += length
            last = p
        }
        if let end = pts.last, out.last != end { out.append(end) }
        return out
    }

    /// 最小平方法擬合圓（Kåsa 方法）
    static func fitCircle(_ pts: [CGPoint]) -> (c: CGPoint, r: CGFloat)? {
        let n = CGFloat(pts.count)
        let mx = pts.reduce(CGFloat(0)) { $0 + $1.x } / n
        let my = pts.reduce(CGFloat(0)) { $0 + $1.y } / n
        var suu: CGFloat = 0, svv: CGFloat = 0, suv: CGFloat = 0
        var suuu: CGFloat = 0, svvv: CGFloat = 0, suvv: CGFloat = 0, svuu: CGFloat = 0
        for p in pts {
            let u = p.x - mx
            let v = p.y - my
            suu += u * u
            svv += v * v
            suv += u * v
            suuu += u * u * u
            svvv += v * v * v
            suvv += u * v * v
            svuu += v * u * u
        }
        let det = suu * svv - suv * suv
        guard abs(det) > 1e-6 else { return nil }
        let b1 = 0.5 * (suuu + suvv)
        let b2 = 0.5 * (svvv + svuu)
        let uc = (b1 * svv - b2 * suv) / det
        let vc = (suu * b2 - suv * b1) / det
        let r = (uc * uc + vc * vc + (suu + svv) / n).squareRoot()
        return (c: CGPoint(x: uc + mx, y: vc + my), r: r)
    }

    /// 用道格拉斯－普克演算法（Douglas–Peucker）把筆畫簡化成折線，再去掉幾乎沒有轉彎的點
    static func findCorners(_ pts: [CGPoint], size: CGFloat) -> [CGPoint] {
        var simplified = douglasPeucker(pts, epsilon: 0.05 * size)
        if simplified.count > 2, let a = simplified.first, let b = simplified.last,
           hypot(b.x - a.x, b.y - a.y) < 0.12 * size {
            simplified.removeLast()                               // 頭尾接上了：終點和起點算同一處
        }
        var changed = true
        while changed && simplified.count > 2 {
            changed = false
            for i in 0..<simplified.count {
                let a = simplified[(i - 1 + simplified.count) % simplified.count]
                let b = simplified[i]
                let c = simplified[(i + 1) % simplified.count]
                let tooClose = hypot(b.x - a.x, b.y - a.y) < 0.12 * size
                if tooClose || turnAngle(a, b, c) < 35 {
                    simplified.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return simplified
    }

    static func douglasPeucker(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2, let first = pts.first, let last = pts.last else { return pts }
        var maxDistance: CGFloat = 0
        var index = 0
        for i in 1..<(pts.count - 1) {
            let d = distance(pts[i], lineFrom: first, to: last)
            if d > maxDistance {
                maxDistance = d
                index = i
            }
        }
        guard maxDistance > epsilon else { return [first, last] }
        let left = douglasPeucker(Array(pts[0...index]), epsilon: epsilon)
        let right = douglasPeucker(Array(pts[index...]), epsilon: epsilon)
        return Array(left.dropLast()) + right
    }

    /// 只留下轉得最急的 count 個轉角
    static func keepSharpest(_ corners: [CGPoint], count: Int) -> [CGPoint] {
        var result = corners
        while result.count > count {
            var weakest = 0
            var weakestAngle = CGFloat.greatestFiniteMagnitude
            for i in 0..<result.count {
                let a = result[(i - 1 + result.count) % result.count]
                let angle = turnAngle(a, result[i], result[(i + 1) % result.count])
                if angle < weakestAngle {
                    weakestAngle = angle
                    weakest = i
                }
            }
            result.remove(at: weakest)
        }
        return result
    }

    /// 在 b 點轉了幾度（0 度 = 直直往前）
    static func turnAngle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let v1 = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let l1 = hypot(v1.x, v1.y)
        let l2 = hypot(v2.x, v2.y)
        guard l1 > 0, l2 > 0 else { return 0 }
        let cosine = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)))
        return acos(cosine) * 180 / .pi
    }

    static func distance(_ p: CGPoint, lineFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs(dx * (a.y - p.y) - dy * (a.x - p.x)) / length
    }

    static func distance(_ p: CGPoint, segmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func distance(_ p: CGPoint, toPolygon corners: [CGPoint]) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0..<corners.count {
            best = min(best, distance(p, segmentFrom: corners[i], to: corners[(i + 1) % corners.count]))
        }
        return best
    }

    /// 點到橢圓的距離（沿著從中心出發的射線量）
    static func distance(_ p: CGPoint, toEllipseCenter c: CGPoint, rx: CGFloat, ry: CGFloat) -> CGFloat {
        let dx = p.x - c.x
        let dy = p.y - c.y
        let rho = hypot(dx / rx, dy / ry)
        guard rho > 0 else { return min(rx, ry) }
        return abs(rho - 1) * hypot(dx, dy) / rho
    }

    static func rectCorners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    static func linePoints(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
        var points = [a, a]
        for i in 0...20 {
            let t = CGFloat(i) / 20
            points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        points.append(b)
        points.append(b)
        return points
    }

    static func ellipsePoints(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> [CGPoint] {
        var points: [CGPoint] = []
        for i in 0...75 {
            let t = CGFloat(i) / 72 * 2 * .pi
            points.append(CGPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t)))
        }
        return points
    }

    /// 多邊形：每個轉角重複三次，讓轉角保持尖銳；每條邊中間補點
    static func polygonPoints(_ corners: [CGPoint]) -> [CGPoint] {
        var points: [CGPoint] = []
        for i in 0...corners.count {
            let a = corners[i % corners.count]
            points.append(contentsOf: [a, a, a])
            if i == corners.count { break }
            let b = corners[(i + 1) % corners.count]
            for k in 1..<8 {
                let t = CGFloat(k) / 8
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return points
    }

    /// 在新位置建立一個筆畫點，其他數值全部照抄 sample。
    /// iOS 17 之後要連 secondaryScale 一起帶上，粗細才會跟原本一樣（少了它會變超細或看不見）
    static func makePoint(_ location: CGPoint, time: TimeInterval, from sample: PKStrokePoint,
                          azimuth: CGFloat? = nil, fixSize: CGSize? = nil) -> PKStrokePoint {
        let az = azimuth ?? sample.azimuth
        // fixSize：範本是別支筆畫的，粗細改成這支筆的粗細、不透明
        let size = fixSize ?? sample.size
        let opacity: CGFloat = fixSize == nil ? sample.opacity : 1
#if compiler(>=6.3)
        if #available(iOS 27.0, *) {
            // iPadOS 27 的筆畫點多了「透明度裁切門檻」和「邊緣抖動」，螢光筆的粗細看起來跟它們有關
            return PKStrokePoint(location: location, timeOffset: time, size: size,
                                 opacity: opacity, force: sample.force,
                                 azimuth: az, altitude: sample.altitude,
                                 secondaryScale: sample.secondaryScale,
                                 threshold: sample.threshold, lateralJitter: sample.lateralJitter)
        }
#endif
        if #available(iOS 17.0, *) {
            let p = PKStrokePoint(location: location, timeOffset: time, size: size,
                                  opacity: opacity, force: sample.force,
                                  azimuth: az, altitude: sample.altitude,
                                  secondaryScale: sample.secondaryScale)
            return PointExtras.copy(from: sample, to: p)     // 補上 iPadOS 27 的新數值
        }
        return PKStrokePoint(location: location, timeOffset: time, size: size,
                             opacity: opacity, force: sample.force,
                             azimuth: az, altitude: sample.altitude)
    }

    /// 把一筆拉直：每個點投影到 a→b 這條直線上，點本身的粗細、壓力、筆頭角度全部保留，
    /// 所以拉直後的粗細變化會跟原本畫的一模一樣（螢光筆用這個）
    static func straighten(_ stroke: PKStroke, from a: CGPoint, to b: CGPoint) -> PKStroke {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = max(dx * dx + dy * dy, 0.0001)
        var points: [PKStrokePoint] = []
        for p in stroke.path {
            let loc = p.location.applying(stroke.transform)
            let t = max(0, min(1, ((loc.x - a.x) * dx + (loc.y - a.y) * dy) / lengthSquared))
            points.append(makePoint(CGPoint(x: a.x + t * dx, y: a.y + t * dy), time: p.timeOffset, from: p))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: path, transform: .identity, mask: nil)
    }

    /// 螢光筆拉直：每個點都用「整筆粗細中間值的那一點」為底，只改位置和時間 → 整條一樣粗、完全直
    static func straightenUniform(_ stroke: PKStroke, from a: CGPoint, to b: CGPoint) -> PKStroke? {
        let original = Array(stroke.path)
        guard original.count >= 2 else { return nil }
        let base = original.sorted { $0.size.width < $1.size.width }[original.count / 2]
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = max(dx * dx + dy * dy, 0.0001)
        var points: [PKStrokePoint] = []
        for p in original {
            let loc = p.location.applying(stroke.transform)
            let t = max(0, min(1, ((loc.x - a.x) * dx + (loc.y - a.y) * dy) / lengthSquared))
            guard let q = PointPatch.moved(base, to: CGPoint(x: a.x + t * dx, y: a.y + t * dy),
                                           time: p.timeOffset) else { return nil }
            points.append(q)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: path, transform: .identity, mask: nil)
    }

    /// 無壓感墨水的拉直：每個點都照「粗細中間值的那一點」重建，只改位置
    static func straightenRebuilt(_ stroke: PKStroke, from a: CGPoint, to b: CGPoint) -> PKStroke {
        let original = Array(stroke.path)
        guard original.count >= 2 else { return stroke }
        let base = original.sorted { $0.size.width < $1.size.width }[original.count / 2]
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = max(dx * dx + dy * dy, 0.0001)
        var points: [PKStrokePoint] = []
        for p in original {
            let loc = p.location.applying(stroke.transform)
            let t = max(0, min(1, ((loc.x - a.x) * dx + (loc.y - a.y) * dy) / lengthSquared))
            points.append(makePoint(CGPoint(x: a.x + t * dx, y: a.y + t * dy), time: p.timeOffset, from: base))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: path, transform: .identity, mask: nil)
    }

    /// 不重建筆畫點：把整筆的頭尾對齊到 a→b（只沿著線的方向伸縮，粗細不變）
    static func align(_ stroke: PKStroke, from a: CGPoint, to b: CGPoint) -> PKStroke {
        guard let first = stroke.path.first, let last = stroke.path.last else { return stroke }
        let a0 = first.location.applying(stroke.transform)
        let b0 = last.location.applying(stroke.transform)
        let d0 = CGPoint(x: b0.x - a0.x, y: b0.y - a0.y)
        let d1 = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let k = hypot(d1.x, d1.y) / max(hypot(d0.x, d0.y), 0.001)
        let t = CGAffineTransform(translationX: -a0.x, y: -a0.y)
            .concatenating(CGAffineTransform(rotationAngle: -atan2(d0.y, d0.x)))
            .concatenating(CGAffineTransform(scaleX: k, y: 1))
            .concatenating(CGAffineTransform(rotationAngle: atan2(d1.y, d1.x)))
            .concatenating(CGAffineTransform(translationX: a.x, y: a.y))
        return PKStroke(ink: stroke.ink, path: stroke.path,
                        transform: stroke.transform.concatenating(t), mask: stroke.mask)
    }

    /// 沒有範本時用的預設點
    static func defaultPoint(_ location: CGPoint, time: TimeInterval, width: CGFloat) -> PKStrokePoint {
        let size = CGSize(width: max(width, 2), height: max(width, 2))
        if #available(iOS 17.0, *) {
            return PKStrokePoint(location: location, timeOffset: time, size: size, opacity: 1, force: 0.6,
                                 azimuth: 0, altitude: 1.0, secondaryScale: 1)
        }
        return PKStrokePoint(location: location, timeOffset: time, size: size, opacity: 1, force: 0.6,
                             azimuth: 0, altitude: 1.0)
    }

    /// 把一串點做成一筆。每個點的數值都從範本（真正畫出的筆跡）複製；沒有範本時才用預設值
    static func makeStroke(points: [CGPoint], ink: PKInk, template: PKStroke?, width: CGFloat,
                           fixSize: CGSize? = nil) -> PKStroke {
        var sample: PKStrokePoint?
        var azimuth: CGFloat?
        if let t = template, !t.path.isEmpty {
            let mid = t.path.count / 2
            sample = t.path[mid]
            // 直線：讓筆頭和新線條的夾角，跟原本那一點和筆畫方向的夾角一樣。
            // 螢光筆是斜切筆頭，夾角一樣，畫出來的粗細才會一樣
            if t.path.count >= 3, let first = points.first, let last = points.last, points.count >= 2 {
                let before = t.path[max(mid - 1, 0)].location
                let after = t.path[min(mid + 1, t.path.count - 1)].location
                let oldDirection = atan2(after.y - before.y, after.x - before.x)
                let newDirection = atan2(last.y - first.y, last.x - first.x)
                let straight = points.count <= 30 && hypot(last.x - first.x, last.y - first.y) > 1
                if straight, let s0 = sample {
                    azimuth = newDirection + (s0.azimuth - oldDirection)
                }
            }
        }
        var controls: [PKStrokePoint] = []
        for (i, p) in points.enumerated() {
            let time = TimeInterval(i) * 0.005
            if let sample = sample {
                controls.append(makePoint(p, time: time, from: sample, azimuth: azimuth, fixSize: fixSize))
            } else {
                controls.append(defaultPoint(p, time: time, width: width))
            }
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: Date())
        return PKStroke(ink: ink, path: path, transform: .identity, mask: nil)
    }

    /// 換掉筆跡（頁面會自動登記一步復原）
    static func setDrawing(_ new: PKDrawing, on canvas: PKCanvasView) {
        if let page = canvas.delegate as? NotePageView {
            page.setDrawingRecorded(new)
        } else {
            canvas.drawing = new
        }
    }
}


/// 虛線、點線：把畫好的一筆切成一段一段。每一段直接用 PencilKit 自己沿著這一筆算出來的點，
/// 所以粗細、iPadOS 27 的新數值都跟原本那一筆一樣（不自己填數值）
enum DashMaker {
    /// style：1 虛線、2 點線
    static func dashed(_ stroke: PKStroke, style: Int) -> [PKStroke] {
        let control = Array(stroke.path)
        guard control.count >= 2 else { return [stroke] }
        let widths: [CGFloat] = control.map { max($0.size.width, $0.size.height) }.sorted()
        let width: CGFloat = max(widths[widths.count / 2], 0.5)
        // 筆頭是圓的，畫出來每段兩端各多半個筆寬：間隔要比筆寬大才看得出空隙
        let dashLength: CGFloat = style == 2 ? max(width * 0.05, 0.2) : max(width * 2.5, 4)
        let gapLength: CGFloat = style == 2 ? max(width * 2.4, 3) : max(width * 2.5, 4)
        let step: CGFloat = min(max(width * 0.25, 0.4), 2)
        let pts: [PKStrokePoint] = Array(stroke.path.interpolatedPoints(by: .distance(step)))
        guard pts.count >= 2 else { return [stroke] }
        // 每個點離起點的距離（沿著筆畫量）
        var dist: [CGFloat] = [0]
        var total: CGFloat = 0
        for k in 1..<pts.count {
            let a = pts[k - 1].location
            let b = pts[k].location
            total += hypot(b.x - a.x, b.y - a.y)
            dist.append(total)
        }
        guard total > dashLength + gapLength else { return [stroke] }   // 太短：不切
        var pieces: [PKStroke] = []
        var segStart: CGFloat = 0
        var i = 0
        while segStart <= total && i < pts.count {
            let segEnd = segStart + dashLength
            while i < pts.count && dist[i] < segStart { i += 1 }
            guard i < pts.count else { break }
            var seg: [PKStrokePoint] = []
            var j = i
            while j < pts.count && dist[j] <= segEnd {
                seg.append(pts[j])
                j += 1
            }
            if seg.isEmpty {                     // 這一段裡剛好沒有點：用最近的那一點
                seg = [pts[i]]
                j = i + 1
            }
            if seg.count == 1 { seg.append(seg[0]) }   // 點線：同一個點兩次，畫出來是一個圓點
            let path = PKStrokePath(controlPoints: seg, creationDate: stroke.path.creationDate)
            pieces.append(PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: nil))
            segStart = segEnd + gapLength
            i = j
        }
        return pieces.isEmpty ? [stroke] : pieces
    }
}

/// 點一下筆跡要判斷點到哪一筆
@MainActor
enum StrokeHitTest {
    static func index(at p: CGPoint, in drawing: PKDrawing, tolerance: CGFloat) -> Int? {
        // v12.9.8：strokes 只拿一次。以前迴圈裡每一圈都重新拿整份（筆跡多時是筆數的平方，幾千筆就要等好幾秒，長按很慢才有反應）
        let strokes = drawing.strokes
        for i in strokes.indices.reversed() {
            let stroke = strokes[i]
            guard stroke.renderBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { continue }
            for point in stroke.path.interpolatedPoints(by: .distance(2)) {
                let location = point.location.applying(stroke.transform)
                if hypot(location.x - p.x, location.y - p.y) <= tolerance + point.size.width / 2 { return i }
            }
        }
        return nil
    }
}

/// 選取框：變形後自動出現，或用手指點一下筆跡出現。
/// 拖四角、四邊中點縮放（線條粗細不變）；拖框內移動；拖右邊的圓鈕旋轉；
/// 下方操作列：顏色、剪下、拷貝、刪除、更多（複製一份、完成）
final class SelectionEditorView: UIView, UIGestureRecognizerDelegate {
    weak var host: NotebookView?
    weak var pageView: NotePageView?
    let indices: [Int]                        // 被選取的筆畫在這一頁的位置（由小到大）
    private var baseStrokes: [PKStroke]       // 剛選取時的筆畫
    private let baseImages: [ImageBox]        // 套索一起圈到的圖片（剛選取時的樣子；v12.1）。跟筆跡一起移動、縮放、旋轉

    /// 套索一起圈到的文字方塊（v12.2）：box 是資料，rect 是它在頁面上佔的範圍（頁面座標）
    struct PickedText {
        var box: TextBox
        var rect: CGRect
    }
    private let baseTexts: [PickedText]       // 剛選取時的樣子。跟著移動、等比例縮放；文字方塊不能旋轉，旋轉時只有位置跟著轉
    private var textAnchors: [UUID: CGRect] = [:]   // 每個文字方塊在畫面上實際的範圍（上次放手時）；拖曳中的預覽以它為準
    private let baseRect: CGRect              // 剛選取時的外框（頁面座標）

    // 目前相對於「剛選取時」的變化
    private var boxCenter: CGPoint            // 不能叫 center：UIView 本身就有 center 屬性
    private var boxSize: CGSize
    private var angle: CGFloat = 0

    // 直線模式（螢光筆、直線）：只有兩端各一個點，拖端點就能改長度和角度
    let lineMode: Bool
    private let baseA: CGPoint
    private let baseB: CGPoint
    private var lineA: CGPoint
    private var lineB: CGPoint
    private var startA = CGPoint.zero
    private var startB = CGPoint.zero

    private enum Drag {
        case idle
        case move
        case resize(Int)
        case rotate
    }

    private var drag = Drag.idle
    private var moved = false                          // 這次按下去之後真的有拖動才算編輯
    private var startCenter = CGPoint.zero
    private var startSize = CGSize.zero
    private var startAngle: CGFloat = 0
    private var startPoint = CGPoint.zero
    private var startDrawing = PKDrawing()

    // 控制點：0 左上、1 右上、2 右下、3 左下、4 上、5 右、6 下、7 左（以框的中心為原點的方向）
    private static let signs: [CGPoint] = [
        CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1), CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1),
        CGPoint(x: 0, y: -1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0)
    ]

    private let frameLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let contentLayer = CAShapeLayer()           // 框裡的小虛線：實際選到的範圍
    private weak var colorSwatch: UIButton?
    private var baseOutline: CGPath?                    // 選到的筆跡外形（頁面座標，剛選取時）

    /// 沿著每一筆的形狀畫一圈，全部合併成一個不規則的輪廓（沒選到的筆跡不會被框進去）
    static func outline(of strokes: [PKStroke], pad: CGFloat) -> CGPath? {
        guard #available(iOS 16.0, *) else { return nil }
        let all = CGMutablePath()
        for stroke in strokes {
            let t = stroke.transform
            let pts = stroke.path.interpolatedPoints(by: .distance(4)).map { $0.location.applying(t) }
            guard let first = pts.first else { continue }
            let line = CGMutablePath()
            line.move(to: first)
            if pts.count == 1 { line.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            for q in pts.dropFirst() { line.addLine(to: q) }
            let k = sqrt(abs(t.a * t.d - t.b * t.c))
            let ink = (stroke.path.map { $0.size.width }.max() ?? 2) * k
            all.addPath(line.copy(strokingWithWidth: ink + pad * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
        }
        return all.isEmpty ? nil : all.normalized()
    }

    /// 操作列的顏色鈕：選到的都是同一個顏色就顯示那個顏色；不只一種顏色就顯示灰色
    private func updateColorSwatch() {
        guard let button = colorSwatch else { return }
        var found: [(CGFloat, CGFloat, CGFloat)] = []
        for stroke in baseStrokes {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            stroke.ink.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let same = found.contains { abs($0.0 - r) < 0.03 && abs($0.1 - g) < 0.03 && abs($0.2 - b) < 0.03 }
            if !same { found.append((r, g, b)) }
            if found.count > 1 { break }
        }
        let fill: UIColor
        if found.count == 1, let c = found.first {
            fill = UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        } else {
            fill = .systemGray
        }
        let size = CGSize(width: 26, height: 26)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let circle = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5))
            fill.setFill()
            circle.fill()
            UIColor(white: 0.85, alpha: 1).setStroke()           // 細細的淺色外圈：黑色在深色操作列上也看得到
            circle.lineWidth = 1.5
            circle.stroke()
        }
        button.setImage(image.withRenderingMode(.alwaysOriginal), for: .normal)
    }

    // 移動時：畫布上先拿掉選取的筆跡，改用一張圖跟著手指（不會跟不上，拖出頁面也看得到）
    private var dragBase: PKDrawing?
    private var preview: UIImageView?
    private var previewOrigin = CGPoint.zero

    /// 單獨一條螢光筆的四角框可以自由拉長拉寬；其他（手寫）一律等比例
    private var uniformScale: Bool {
        !(baseImages.isEmpty && baseTexts.isEmpty && indices.count == 1 && isHighlighter(baseStrokes[0]))
    }

    /// 這個選取裡有沒有圖片、文字方塊
    var hasImages: Bool { !baseImages.isEmpty }
    var hasTexts: Bool { !baseTexts.isEmpty }

    /// 圖片（含旋轉）在頁面上佔的範圍
    static func imageBounds(of box: ImageBox) -> CGRect {
        if box.isMini { return box.miniRect }                   // 縮成小圖（v12.8.3）
        let cx = box.x + box.width / 2
        let cy = box.y + box.height / 2
        let c = abs(cos(box.rotation))
        let s = abs(sin(box.rotation))
        let w = box.width * c + box.height * s
        let h = box.width * s + box.height * c
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// 圖片的四個角連成的外框（頁面座標）
    static func quad(of box: ImageBox) -> CGPath {
        if box.isMini { return CGPath(rect: box.miniRect, transform: nil) }
        let cx = box.x + box.width / 2
        let cy = box.y + box.height / 2
        let c = cos(box.rotation)
        let s = sin(box.rotation)
        let path = CGMutablePath()
        let corners: [CGPoint] = [CGPoint(x: -0.5, y: -0.5), CGPoint(x: 0.5, y: -0.5),
                                  CGPoint(x: 0.5, y: 0.5), CGPoint(x: -0.5, y: 0.5)]
        for (i, corner) in corners.enumerated() {
            let lx = corner.x * box.width
            let ly = corner.y * box.height
            let p = CGPoint(x: cx + lx * c - ly * s, y: cy + lx * s + ly * c)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// 完整的筆跡（移動中畫布上暫時少了選取的部分）
    var fullDrawing: PKDrawing? { dragBase ?? pageView?.canvas.drawing }
    private let rotateIcon = UIImageView(image: UIImage(systemName: "arrow.triangle.2.circlepath"))
    private let bar = UIView()
    private var barButtons: [UIButton] = []

    /// images、texts：套索一起圈到的圖片、文字方塊（可以沒有筆跡）
    init?(pageView: NotePageView, host: NotebookView, indices: [Int], allowLine: Bool = false,
          images: [ImageBox] = [], texts: [PickedText] = []) {
        let strokes = pageView.canvas.drawing.strokes
        let valid = indices.filter { strokes.indices.contains($0) }.sorted()
        guard !valid.isEmpty || !images.isEmpty || !texts.isEmpty else { return nil }
        var rect = CGRect.null
        for i in valid { rect = rect.union(strokes[i].renderBounds) }
        for box in images { rect = rect.union(Self.imageBounds(of: box)) }
        for item in texts { rect = rect.union(item.rect) }
        guard !rect.isNull else { return nil }
        self.indices = valid
        self.baseStrokes = valid.map { strokes[$0] }
        self.baseImages = images
        self.baseTexts = texts
        var anchors: [UUID: CGRect] = [:]
        for item in texts { anchors[item.box.id] = item.rect }
        self.textAnchors = anchors
        self.baseRect = rect
        self.boxCenter = CGPoint(x: rect.midX, y: rect.midY)
        self.boxSize = rect.size
        if allowLine, images.isEmpty, texts.isEmpty, valid.count == 1,
           let ends = Self.lineEndpoints(of: strokes[valid[0]]) {
            lineMode = true
            baseA = ends.0
            baseB = ends.1
        } else {
            lineMode = false
            baseA = .zero
            baseB = .zero
        }
        self.lineA = baseA
        self.lineB = baseB
        self.pageView = pageView
        self.host = host
        super.init(frame: pageView.bounds)
        backgroundColor = .clear

        frameLayer.fillColor = UIColor.clear.cgColor
        frameLayer.strokeColor = UIColor.systemBlue.cgColor
        frameLayer.lineWidth = 1.5
        layer.addSublayer(frameLayer)
        handleLayer.fillColor = UIColor.systemBlue.cgColor
        handleLayer.strokeColor = UIColor.white.cgColor
        handleLayer.lineWidth = 2
        layer.addSublayer(handleLayer)
        contentLayer.fillColor = UIColor.clear.cgColor
        contentLayer.strokeColor = UIColor(red: 1.0, green: 0.36, blue: 0.36, alpha: 1).cgColor   // 紅色：跟外面的藍框分開
        contentLayer.lineWidth = 1.5
        contentLayer.lineDashPattern = [6, 4]
        // 虛線慢慢流動（像 GUGA 那樣），一看就知道是選取範圍
        let ants = CABasicAnimation(keyPath: "lineDashPhase")
        ants.fromValue = 0
        ants.toValue = -10                                     // 一段虛線加空白的長度
        ants.duration = 0.6
        ants.repeatCount = .infinity
        ants.isRemovedOnCompletion = false
        contentLayer.add(ants, forKey: "ants")
        contentLayer.shadowColor = UIColor.white.cgColor           // 白色光暈：深色背景上也看得清楚
        contentLayer.shadowOpacity = 1
        contentLayer.shadowRadius = 1.5
        contentLayer.shadowOffset = .zero
        layer.insertSublayer(contentLayer, below: frameLayer)

        rotateIcon.tintColor = .white
        rotateIcon.backgroundColor = .systemBlue
        rotateIcon.contentMode = .center
        rotateIcon.layer.cornerRadius = 15
        rotateIcon.clipsToBounds = true
        rotateIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        addSubview(rotateIcon)
        rotateIcon.isHidden = lineMode                 // 直線拖端點就能旋轉，不需要旋轉鈕

        setUpBar()

        // 按下去就開始拖（不用等移動），才不會被捲動搶走
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.delegate = self
        addGestureRecognizer(press)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 操作列

    private func makeButton(_ symbol: String, tint: UIColor = .white) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = tint
        barButtons.append(button)
        bar.addSubview(button)
        return button
    }

    private func setUpBar() {
        bar.backgroundColor = UIColor(white: 0.16, alpha: 0.96)
        bar.layer.cornerRadius = 22
        addSubview(bar)

        let colors: [(String, UIColor)] = [
            ("白", .white), ("黑", .black),
            ("紅", UIColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 1)),
            ("藍", UIColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1)),
            ("黃", .systemYellow), ("綠", .systemGreen)
        ]
        let colorButton = makeButton("circle.fill")
        colorSwatch = colorButton
        updateColorSwatch()
        colorButton.menu = UIMenu(title: "顏色", children: colors.map { item in
            let swatch = UIImage(systemName: "circle.fill")?.withTintColor(item.1, renderingMode: .alwaysOriginal)
            return UIAction(title: item.0, image: swatch) { [weak self] _ in self?.setColor(item.1) }
        })
        colorButton.showsMenuAsPrimaryAction = true

        // 剪下、拷貝（放進剪貼簿，之後到別處貼上）、複製（直接在旁邊多一份）、刪除
        makeButton("scissors").addTarget(self, action: #selector(cutTapped), for: .touchUpInside)
        makeButton("doc.on.doc").addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        makeButton("plus.square.on.square").addTarget(self, action: #selector(duplicateTapped), for: .touchUpInside)
        makeButton("trash", tint: .systemRed).addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        // 白板（v12.8.2）：用選到的範圍建立區塊
        if pageView?.page.spec.flat == true {
            makeButton("rectangle.dashed").addTarget(self, action: #selector(frameTapped), for: .touchUpInside)
        }

        // 「⋯」：直線（螢光筆）可以改成四角框來放大縮小、旋轉；單獨一條螢光筆的四角框可以改回直線
        var more: [UIAction] = []
        if lineMode {
            more.append(UIAction(title: "放大縮小、旋轉", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
                self?.switchMode(toLine: false)
            })
        } else if baseImages.isEmpty, baseTexts.isEmpty, indices.count == 1, isHighlighter(baseStrokes[0]),
                  Self.lineEndpoints(of: baseStrokes[0]) != nil {
            more.append(UIAction(title: "改回直線", image: UIImage(systemName: "line.diagonal")) { [weak self] _ in
                self?.switchMode(toLine: true)
            })
        }
        if !more.isEmpty {
            let moreButton = makeButton("ellipsis.circle")
            moreButton.menu = UIMenu(children: more)
            moreButton.showsMenuAsPrimaryAction = true
        }
    }

    private func switchMode(toLine: Bool) {
        guard let pv = pageView, let host = host else { return }
        let keep = indices
        DispatchQueue.main.async {                             // 等選單收起來再換
            host.showSelection(on: pv, indices: keep, allowLine: toLine)
        }
    }

    // MARK: 座標換算

    private var scale: CGFloat {
        guard let spec = pageView?.page.spec, spec.width > 0 else { return 1 }
        return bounds.width / spec.width
    }

    /// 一筆幾乎是直線的話，回傳它的兩個端點（頁面座標）
    static func lineEndpoints(of stroke: PKStroke) -> (CGPoint, CGPoint)? {
        let pts = stroke.path.interpolatedPoints(by: .distance(3)).map { $0.location.applying(stroke.transform) }
        guard let a = pts.first, let b = pts.last else { return nil }
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length >= 12 else { return nil }
        let maxDeviation = pts.map { ShapeSnapper.distance($0, lineFrom: a, to: b) }.max() ?? 0
        return maxDeviation <= max(3, 0.05 * length) ? (a, b) : nil
    }

    /// 從「剛選取時」到「現在」的變換：移到原點 → 縮放 → 旋轉 → 移到目前中心
    private var currentTransform: CGAffineTransform {
        if lineMode {
            // 把原本的兩端移到現在的兩端：等比例縮放 + 旋轉 + 平移
            // 先轉成水平 → 只沿著線的方向伸縮（垂直方向不動，所以粗細不變）→ 轉到新角度 → 移到新位置
            let d0 = CGPoint(x: baseB.x - baseA.x, y: baseB.y - baseA.y)
            let d1 = CGPoint(x: lineB.x - lineA.x, y: lineB.y - lineA.y)
            let k = hypot(d1.x, d1.y) / max(hypot(d0.x, d0.y), 0.001)
            return CGAffineTransform(translationX: -baseA.x, y: -baseA.y)
                .concatenating(CGAffineTransform(rotationAngle: -atan2(d0.y, d0.x)))
                .concatenating(CGAffineTransform(scaleX: k, y: 1))
                .concatenating(CGAffineTransform(rotationAngle: atan2(d1.y, d1.x)))
                .concatenating(CGAffineTransform(translationX: lineA.x, y: lineA.y))
        }
        let sx = boxSize.width / max(baseRect.width, 0.001)
        let sy = boxSize.height / max(baseRect.height, 0.001)
        return CGAffineTransform(translationX: -baseRect.midX, y: -baseRect.midY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: boxCenter.x, y: boxCenter.y))
    }

    /// 框座標（以中心為原點、未旋轉）→ 頁面座標
    private func pagePoint(local: CGPoint, center c: CGPoint, angle a: CGFloat) -> CGPoint {
        CGPoint(x: c.x + local.x * cos(a) - local.y * sin(a),
                y: c.y + local.x * sin(a) + local.y * cos(a))
    }

    /// 頁面座標 → 框座標
    private func localPoint(page p: CGPoint, center c: CGPoint, angle a: CGFloat) -> CGPoint {
        let dx = p.x - c.x
        let dy = p.y - c.y
        return CGPoint(x: dx * cos(-a) - dy * sin(-a), y: dx * sin(-a) + dy * cos(-a))
    }

    /// 框在畫面上至少 110 點見方：四角的控制點不會擠在一起，小東西也有空間按中間移動（回傳頁面座標的半寬、半高，含留白）
    private var paddedHalf: CGSize {
        let s = scale
        let minScreen: CGFloat = 110
        let padW = max(10, (minScreen - boxSize.width * s) / 2) / s
        let padH = max(10, (minScreen - boxSize.height * s) / 2) / s
        return CGSize(width: boxSize.width / 2 + padW, height: boxSize.height / 2 + padH)
    }

    /// 框夠大才顯示四邊中點，小的時候只留四個角
    private var visibleHandleCount: Int {
        lineMode ? 2 : 4                                // 只有四個角（四邊中點會把字拉變形，拿掉）
    }

    private func handlePoints() -> [CGPoint] {
        if lineMode { return [lineA, lineB] }
        let half = paddedHalf
        let all = Self.signs.map {
            pagePoint(local: CGPoint(x: $0.x * half.width, y: $0.y * half.height), center: boxCenter, angle: angle)
        }
        return Array(all.prefix(visibleHandleCount))
    }

    /// 旋轉鈕：框的右邊再往外 44 個螢幕點（離右上、右下角夠遠，不會按錯）
    private func rotatePoint() -> CGPoint {
        pagePoint(local: CGPoint(x: paddedHalf.width + 44 / scale, y: 0), center: boxCenter, angle: angle)
    }

    // MARK: 畫框

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = scale
        let toView = { (p: CGPoint) -> CGPoint in CGPoint(x: p.x * s, y: p.y * s) }
        let hs = handlePoints().map(toView)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if lineMode {
            frameLayer.path = nil                       // 直線只顯示兩端的點
            contentLayer.path = nil
        } else {
            // 實際選到的範圍：沿著筆跡形狀的不規則輪廓（框為了好按會留白，所以另外標出真正的範圍）
            if baseOutline == nil, s > 0 { baseOutline = Self.outline(of: baseStrokes, pad: 7 / s) }
            let m = currentTransform.concatenating(CGAffineTransform(scaleX: s, y: s))
            let content = CGMutablePath()
            if let outline = baseOutline { content.addPath(outline, transform: m) }
            for box in baseImages { content.addPath(Self.quad(of: box), transform: m) }   // 圖片：沿著四個邊
            for item in currentTexts() {                                                   // 文字方塊：它現在佔的範圍
                content.addRect(CGRect(x: item.rect.minX * s, y: item.rect.minY * s,
                                       width: item.rect.width * s, height: item.rect.height * s))
            }
            if indices.count == 1, baseImages.isEmpty, baseTexts.isEmpty {
                contentLayer.path = nil                 // 只選到一筆（例如剛變形出來的圖形）：藍框就夠了，不再描一圈紅線（v12.2）
            } else if !content.isEmpty {
                contentLayer.path = content
            } else {
                let hw = boxSize.width / 2, hh = boxSize.height / 2
                let cs = [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh), CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)]
                    .map { toView(pagePoint(local: $0, center: boxCenter, angle: angle)) }
                let inner = UIBezierPath()
                inner.move(to: cs[0])
                for c in cs.dropFirst() { inner.addLine(to: c) }
                inner.close()
                contentLayer.path = inner.cgPath
            }
            let outline = UIBezierPath()
            outline.move(to: hs[0])
            outline.addLine(to: hs[1])
            outline.addLine(to: hs[2])
            outline.addLine(to: hs[3])
            outline.close()
            frameLayer.path = outline.cgPath
        }
        let dots = UIBezierPath()
        for h in hs {
            dots.append(UIBezierPath(ovalIn: CGRect(x: h.x - 8, y: h.y - 8, width: 16, height: 16)))
        }
        handleLayer.path = dots.cgPath
        CATransaction.commit()

        let r = toView(rotatePoint())
        rotateIcon.frame = CGRect(x: r.x - 15, y: r.y - 15, width: 30, height: 30)

        // 操作列放在框的下方，離控制點遠一點，才不會擋到右下角
        let xs = hs.map { $0.x } + (lineMode ? [] : [r.x])
        let ys = hs.map { $0.y }
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let barSize = CGSize(width: 300, height: 44)
        var y = maxY + 40
        if y + barSize.height > bounds.height - 4 { y = minY - 40 - barSize.height }
        // v12.9.8：會被下面的筆盒（或畫面底）擋住時，改放在框的上面
        if let host = host {
            let bottomInHost = convert(CGPoint(x: 0, y: y + barSize.height), to: host).y
            if bottomInHost > host.bounds.height - 8 - host.bottomObstruction { y = minY - 40 - barSize.height }
        }
        let x = min(max((minX + maxX) / 2 - barSize.width / 2, 4), max(4, bounds.width - barSize.width - 4))
        bar.frame = CGRect(x: x, y: max(4, y), width: barSize.width, height: barSize.height)
        let w = barSize.width / CGFloat(max(barButtons.count, 1))
        for (i, button) in barButtons.enumerated() {
            button.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: barSize.height)
        }
    }

    // MARK: 觸控

    private func dragMode(at v: CGPoint) -> Drag {
        let s = scale
        let p = CGPoint(x: v.x / s, y: v.y / s)
        // 控制點優先（四角先於四邊），再來才是旋轉鈕，最後是框內移動
        var best: (Int, CGFloat)?
        for (i, h) in handlePoints().enumerated() {
            let d = hypot((h.x - p.x) * s, (h.y - p.y) * s)
            if d < 22, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (i, d) }
        }
        if let hit = best { return .resize(hit.0) }
        if lineMode {
            let hs = handlePoints()
            let d = ShapeSnapper.distance(p, segmentFrom: hs[0], to: hs[1]) * s
            return d < 20 ? .move : .idle
        }
        let r = rotatePoint()
        if hypot((r.x - p.x) * s, (r.y - p.y) * s) < 24 { return .rotate }
        let q = localPoint(page: p, center: boxCenter, angle: angle)
        let half = paddedHalf
        if abs(q.x) <= half.width && abs(q.y) <= half.height { return .move }
        return .idle
    }

    // 只有碰到控制點、框、旋轉鈕、操作列才由選取框處理；其他地方照常書寫、捲動
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if case .idle = dragMode(at: point) { return bar.frame.contains(point) }
        return true
    }

    // 操作列上的按鈕交給按鈕自己處理（控制點優先）
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if case .idle = dragMode(at: touch.location(in: self)) { return false }
        return true
    }

    // 手指按在控制點或框上時，上下、左右捲動和雙指縮放都要等選取框先處理，
    // 才不會一拖右下角就被當成往右或往下滑
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView || other is UIPinchGestureRecognizer
    }

    // 手指位置一律用「筆記本畫面」的座標：它不會捲動，方向也跟看到的一致
    //（Swift Playgrounds 裡系統的螢幕座標方向跟畫面不一樣，不能用）
    private var lastHostPoint: CGPoint?                  // 手指目前的位置（自動捲動時用）
    private var hostStart = CGPoint.zero                 // 按下去時手指的位置
    private var scrollShift: CGFloat = 0                 // 這次拖曳中自動捲動累積了多少（往下捲為正）
    private var scrollShiftX: CGFloat = 0                // 這次拖曳中左右自動捲動累積了多少（往右捲為正；v12.1）

    private func hostPoint(_ g: UIGestureRecognizer) -> CGPoint {
        g.location(in: host ?? self)
    }

    /// 移動量 = 手指移動的量 + 自動捲動的量，換成頁面座標（不經過頁面位置換算，捲動時不會跑掉）
    private func moveDelta(hostPoint w: CGPoint) -> CGPoint {
        let s = max(scale, 0.0001)
        return CGPoint(x: (w.x - hostStart.x + scrollShiftX) / s, y: (w.y - hostStart.y + scrollShift) / s)
    }

    private func applyMove(_ d: CGPoint) {
        boxCenter = CGPoint(x: startCenter.x + d.x, y: startCenter.y + d.y)
        lineA = CGPoint(x: startA.x + d.x, y: startA.y + d.y)
        lineB = CGPoint(x: startB.x + d.x, y: startB.y + d.y)
    }

    /// 畫面自動捲動了 dy 個螢幕點：手指沒動，選取框跟著手指
    func scrolled(by dy: CGFloat) {
        guard case .move = drag, let w = lastHostPoint else { return }
        scrollShift += dy
        moved = true
        applyMove(moveDelta(hostPoint: w))
        beginMovePreview()
        movePreview()
        previewImages()
        setNeedsLayout()
    }

    /// 這一列左右自動捲動了 dx 個螢幕點（拖到畫面左右邊緣，捲到隔壁那一頁）：手指沒動，選取框跟著手指
    func scrolledSideways(by dx: CGFloat) {
        guard case .move = drag, let w = lastHostPoint else { return }
        scrollShiftX += dx
        moved = true
        applyMove(moveDelta(hostPoint: w))
        beginMovePreview()
        movePreview()
        previewImages()
        setNeedsLayout()
    }

    /// 選取框（含控制點）在筆記本畫面上的範圍
    func boxRectInHost() -> CGRect {
        guard let host = host else { return .null }
        let s = scale
        let pts = handlePoints().map { CGPoint(x: $0.x * s, y: $0.y * s) }
        guard let first = pts.first else { return .null }
        var r = CGRect(origin: first, size: .zero)
        for q in pts.dropFirst() { r = r.union(CGRect(origin: q, size: .zero)) }
        return convert(r, to: host)
    }

    @objc private func handlePress(_ g: UILongPressGestureRecognizer) {
        let s = scale
        let v = g.location(in: self)
        let p = CGPoint(x: v.x / s, y: v.y / s)
        lastHostPoint = hostPoint(g)
        switch g.state {
        case .began:
            drag = dragMode(at: v)
            hostStart = hostPoint(g)
            scrollShift = 0
            scrollShiftX = 0
            startCenter = boxCenter
            startSize = boxSize
            startAngle = angle
            startPoint = p
            startA = lineA
            startB = lineB
            moved = false
            startDrawing = pageView?.canvas.drawing ?? PKDrawing()
        case .changed:
            switch drag {
            case .idle:
                return
            default:
                if g.numberOfTouches > 1 { return }        // 兩隻以上手指（雙指點復原）不算拖曳
                if hypot((p.x - startPoint.x) * s, (p.y - startPoint.y) * s) < 3 && !moved { return }
                moved = true
            }
            switch drag {
            case .idle:
                return
            case .move:
                applyMove(moveDelta(hostPoint: hostPoint(g)))
                host?.selectionDragged(to: hostPoint(g), box: boxRectInHost())   // 拖到畫面邊緣：自動捲動
                beginMovePreview()
                movePreview()
                previewImages()
                setNeedsLayout()
                return
            case .rotate:
                let a0 = atan2(startPoint.y - startCenter.y, startPoint.x - startCenter.x)
                let a1 = atan2(p.y - startCenter.y, p.x - startCenter.x)
                angle = startAngle + (a1 - a0)
            case .resize(let i):
                if lineMode {
                    moveEndpoint(i, to: p)
                } else {
                    resize(handle: i, to: p)
                }
            }
            apply(commit: false)
            setNeedsLayout()
        case .ended, .cancelled, .failed:
            host?.stopAutoScroll()
            if case .idle = drag { return }
            if moved {
                if case .move = drag, let host = host, host.transferSelection(self) {
                    drag = .idle                           // 拖到別頁：已經搬過去了
                    return
                }
                apply(commit: true)                        // 沒拖動就不登記復原
            } else {
                endMovePreview(restore: true)
            }
            drag = .idle
        default:
            break
        }
    }

    /// 拖控制點：對邊固定不動，在框自己的方向上（考慮旋轉）伸縮。
    /// 用「手指移動了多少」來算，所以控制點畫在留白外框上也不會跳一下
    /// 拖四個角：對角固定，等比例放大縮小（字不會被拉變形）
    private func resize(handle i: Int, to p: CGPoint) {
        let sign = Self.signs[i]
        if sign.x != 0 && sign.y != 0 {
            // 對角固定（v11.17 以前以中心為準）
            let q = localPoint(page: p, center: startCenter, angle: startAngle)
            let q0 = localPoint(page: startPoint, center: startCenter, angle: startAngle)
            // 往外拉為正：水平、垂直各拉了多少
            let dx = (q.x - q0.x) * sign.x
            let dy = (q.y - q0.y) * sign.y
            if uniformScale {
                // 手寫：對角固定、等比例。兩個方向拉的量合起來算比例，往哪拉都順，縮小也不會突然跳很小
                let fx = -sign.x * startSize.width / 2             // 固定的那個角（框自己的座標）
                let fy = -sign.y * startSize.height / 2
                let bx = max(abs(q0.x - fx), 0.5)
                let by = max(abs(q0.y - fy), 0.5)
                let minK = 4 / max(max(startSize.width, startSize.height), 0.001)
                let k = max(minK, 1 + (dx + dy) / (bx + by))
                boxSize = CGSize(width: startSize.width * k, height: startSize.height * k)
                let localCenter = CGPoint(x: sign.x * (k - 1) * startSize.width / 2,
                                          y: sign.y * (k - 1) * startSize.height / 2)
                boxCenter = pagePoint(local: localCenter, center: startCenter, angle: startAngle)
                return
            } else {
                // 螢光筆：對角固定，拖的那個角跟著手指（長度、粗細分開拉）
                let newW = max(4, startSize.width + dx)
                let newH = max(1, startSize.height + dy)
                boxSize = CGSize(width: newW, height: newH)
                let localCenter = CGPoint(x: sign.x * (newW - startSize.width) / 2,
                                          y: sign.y * (newH - startSize.height) / 2)
                boxCenter = pagePoint(local: localCenter, center: startCenter, angle: startAngle)
                return
            }
        }
        let q = localPoint(page: p, center: startCenter, angle: startAngle)
        let q0 = localPoint(page: startPoint, center: startCenter, angle: startAngle)
        let minSize: CGFloat = 4
        var newWidth = startSize.width
        var newHeight = startSize.height
        var localCenter = CGPoint.zero
        if sign.x != 0 {
            newWidth = max(minSize, startSize.width + sign.x * (q.x - q0.x))
            localCenter.x = -sign.x * startSize.width / 2 + sign.x * newWidth / 2
        }
        if sign.y != 0 {
            newHeight = max(minSize, startSize.height + sign.y * (q.y - q0.y))
            localCenter.y = -sign.y * startSize.height / 2 + sign.y * newHeight / 2
        }
        boxSize = CGSize(width: newWidth, height: newHeight)
        boxCenter = pagePoint(local: localCenter, center: startCenter, angle: startAngle)
    }

    /// 直線拖端點：另一端固定；接近水平、垂直或 45 度時（3 度以內）自動對齊
    private func moveEndpoint(_ i: Int, to p: CGPoint) {
        let fixed = i == 0 ? startB : startA
        var moving = CGPoint(x: (i == 0 ? startA.x : startB.x) + p.x - startPoint.x,
                             y: (i == 0 ? startA.y : startB.y) + p.y - startPoint.y)
        let dx = moving.x - fixed.x
        let dy = moving.y - fixed.y
        let length = hypot(dx, dy)
        let angleNow = atan2(dy, dx)
        let step = CGFloat.pi / 4
        let snapped = (angleNow / step).rounded() * step
        if length > 0, abs(angleNow - snapped) < 3 * .pi / 180 {
            moving = CGPoint(x: fixed.x + cos(snapped) * length, y: fixed.y + sin(snapped) * length)
        }
        if i == 0 { lineA = moving } else { lineB = moving }
    }

    // MARK: 寫回畫布

    /// 把變換直接套到每個點上（點的粗細不變），所以放大後線條不會變粗
    static func bake(_ stroke: PKStroke, _ t: CGAffineTransform) -> PKStroke {
        let full = stroke.transform.concatenating(t)
        let turn = atan2(full.b, full.a)              // 這次變換轉了幾度：筆頭角度要跟著轉，螢光筆粗細才不會變
        var points: [PKStrokePoint] = []
        for p in stroke.path {
            points.append(ShapeSnapper.makePoint(p.location.applying(full), time: p.timeOffset, from: p,
                                                 azimuth: p.azimuth + turn))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        var mask: UIBezierPath?
        if let original = stroke.mask?.copy() as? UIBezierPath {
            original.apply(full)
            mask = original
        }
        return PKStroke(ink: stroke.ink, path: path, transform: .identity, mask: mask)
    }

    func currentStrokes() -> [PKStroke] {
        let t = currentTransform
        if lineMode {
            // 直線：直接套變換、不重建筆畫點，原本每一點的所有數值（含新版 iPadOS 的隱藏屬性）都保留
            // 建立新的筆跡物件（PencilKit 才會重畫），但沿用原本的筆畫點
            return baseStrokes.map { stroke in
                PKStroke(ink: stroke.ink, path: stroke.path,
                         transform: stroke.transform.concatenating(t), mask: stroke.mask)
            }
        }
        // 四角框只有等比例縮放和旋轉：直接套變換，不重建筆畫點（粗細跟著等比例變，所有資料完整保留）
        return baseStrokes.map { stroke in
            PKStroke(ink: stroke.ink, path: stroke.path,
                     transform: stroke.transform.concatenating(t), mask: stroke.mask)
        }
    }

    /// 一起選到的圖片現在的樣子：跟筆跡套同一個變換（位置、等比例大小、角度）
    func currentImages() -> [ImageBox] {
        if baseImages.isEmpty { return [] }
        let t = currentTransform
        let k = sqrt(abs(t.a * t.d - t.b * t.c))          // 等比例放大了幾倍
        let turn = angle
        return baseImages.map { (box: ImageBox) -> ImageBox in
            var next = box
            let c = CGPoint(x: box.x + box.width / 2, y: box.y + box.height / 2).applying(t)
            next.width = box.width * k
            next.height = box.height * k
            next.x = c.x - next.width / 2
            next.y = c.y - next.height / 2
            next.rotation = box.rotation + turn
            return next
        }
    }

    /// 一起選到的文字方塊現在的樣子：位置跟著變換走，大小（字級、寬度）等比例；不會旋轉
    func currentTexts() -> [PickedText] {
        if baseTexts.isEmpty { return [] }
        let t = currentTransform
        let k = sqrt(abs(t.a * t.d - t.b * t.c))
        return baseTexts.map { (item: PickedText) -> PickedText in
            var next = item
            let c = CGPoint(x: item.rect.midX, y: item.rect.midY).applying(t)
            let w = item.rect.width * k
            let h = item.rect.height * k
            next.rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
            // 方塊的左上角在它佔的範圍裡的相對位置不變
            next.box.x = next.rect.minX + (item.box.x - item.rect.minX) * k
            next.box.y = next.rect.minY + (item.box.y - item.rect.minY) * k
            next.box.fontSize = min(max(item.box.fontSize * k, 4), 400)
            next.box.width = item.box.width * k
            if let fixed = item.box.fixedWidth { next.box.fixedWidth = fixed * k }
            return next
        }
    }

    /// 拖曳中：文字方塊用變形的方式跟著動（不重新排版，放手才真的改字級、位置）
    private func previewTexts() {
        guard !baseTexts.isEmpty, let pv = pageView else { return }
        let s = scale
        for item in currentTexts() {
            guard let view = pv.textViews[item.box.id], let anchor = textAnchors[item.box.id] else { continue }
            let k = item.rect.width / max(anchor.width, 0.001)
            let dx = (item.rect.midX - anchor.midX) * s
            let dy = (item.rect.midY - anchor.midY) * s
            view.transform = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: dx, ty: dy)   // 以方塊中心放大，再移過去
        }
    }

    /// 版面要重排了（拖曳途中新增頁面）：文字方塊先恢復原狀；重排完，下一格預覽會再套回去
    func prepareForRelayout() {
        guard let pv = pageView else { return }
        for item in baseTexts { pv.textViews[item.box.id]?.transform = CGAffineTransform.identity }
    }

    /// 放手：把文字方塊的新位置、大小寫進資料（登記復原）
    private func commitTexts() {
        guard !baseTexts.isEmpty, let pv = pageView, let host = host else { return }
        let now = currentTexts()
        var all = host.textsNow(pv.page.id)
        for item in now {
            pv.textViews[item.box.id]?.transform = CGAffineTransform.identity
            textAnchors[item.box.id] = item.rect
            guard let i = all.firstIndex(where: { $0.id == item.box.id }) else { continue }
            all[i].x = item.box.x
            all[i].y = item.box.y
            all[i].fontSize = item.box.fontSize
            all[i].width = item.box.width
            all[i].fixedWidth = item.box.fixedWidth
        }
        host.setTextsRecorded(all, pageID: pv.page.id)
        // 重新排版後實際的範圍（字級變了，寬度是重新量的）：下次拖曳的預覽以它為準
        let s = max(scale, 0.0001)
        for item in now {
            guard let view = pv.textViews[item.box.id] else { continue }
            let fr = view.frame
            textAnchors[item.box.id] = CGRect(x: fr.minX / s, y: fr.minY / s, width: fr.width / s, height: fr.height / s)
        }
    }

    /// 文字方塊放回資料裡記的位置（拖到一半取消、選取框被收起來）
    private func resetTexts() {
        guard !baseTexts.isEmpty, let pv = pageView, let host = host else { return }
        for item in baseTexts { pv.textViews[item.box.id]?.transform = CGAffineTransform.identity }
        pv.syncTexts(host.textsNow(pv.page.id))
    }

    /// 拖曳中：圖片直接跟著動（只動畫面，還沒寫進資料）；文字方塊也一起
    private func previewImages() {
        previewTexts()
        guard !baseImages.isEmpty, let pv = pageView else { return }
        for box in currentImages() { pv.layoutImage(box) }
    }

    /// 放手：把圖片的新位置寫進資料（登記復原；跟筆跡的那一步合成同一步）；文字方塊也一起
    private func commitImages() {
        commitTexts()
        guard !baseImages.isEmpty, let pv = pageView, let host = host else { return }
        var all = host.imagesNow(pv.page.id)
        for box in currentImages() {
            if let i = all.firstIndex(where: { $0.id == box.id }) { all[i] = box }
        }
        host.setImagesRecorded(all, pageID: pv.page.id)
    }

    /// 圖片放回資料裡記的位置（拖到一半取消、選取框被收起來）
    private func resetImages() {
        resetTexts()
        guard !baseImages.isEmpty, let pv = pageView, let host = host else { return }
        pv.syncImages(host.imagesNow(pv.page.id))
    }

    /// 拖曳中直接更新；放手時登記一次復原
    /// 開始移動：畫布上拿掉選取的筆跡，換成一張跟著手指走的圖
    private func beginMovePreview() {
        guard dragBase == nil, let pv = pageView else { return }
        let strokes = currentStrokes()
        let rect = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        let s = scale
        var image = UIImage()
        let d = PKDrawing(strokes: strokes)
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = d.image(from: rect, scale: s * max(traitCollection.displayScale, 1))
        }
        let full = pv.canvas.drawing
        var hidden = full
        for i in indices.sorted(by: >) where hidden.strokes.indices.contains(i) { hidden.strokes.remove(at: i) }
        dragBase = full
        pv.replaceSilently(hidden, updateBaseline: false)
        let iv = UIImageView(image: image)
        iv.frame = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
        insertSubview(iv, at: 0)
        preview = iv
        // 照片是在框已經被拖動一小段之後才拍的：扣掉這一段，回到按下去時的位置
        previewOrigin = CGPoint(x: iv.frame.minX - (boxCenter.x - startCenter.x) * s,
                                y: iv.frame.minY - (boxCenter.y - startCenter.y) * s)
    }

    private func movePreview() {
        guard let iv = preview else { return }
        let s = scale
        iv.frame.origin = CGPoint(x: previewOrigin.x + (boxCenter.x - startCenter.x) * s,
                                  y: previewOrigin.y + (boxCenter.y - startCenter.y) * s)
    }

    /// 結束移動的預覽（restore = true：把畫布放回原本完整的樣子）
    func endMovePreview(restore: Bool) {
        preview?.removeFromSuperview()
        preview = nil
        if restore, let base = dragBase { pageView?.replaceSilently(base, updateBaseline: false) }
        if restore { resetImages() }
        dragBase = nil
    }

    // 選取框被收起來時，移動到一半的筆跡、圖片要放回去
    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil {
            if dragBase != nil {
                endMovePreview(restore: true)
            } else {
                resetImages()
            }
        }
    }

    private func apply(commit: Bool) {
        guard let pv = pageView else {
            host?.dismissShapeEditor()
            return
        }
        let canvas = pv.canvas
        var updated = dragBase ?? canvas.drawing
        if let last = indices.last, !updated.strokes.indices.contains(last) {
            host?.dismissShapeEditor()
            return
        }
        for (k, stroke) in currentStrokes().enumerated() { updated.strokes[indices[k]] = stroke }
        if commit {
            endMovePreview(restore: false)
            if !indices.isEmpty {
                host?.recordingSelection { pv.setDrawingRecorded(updated) }   // 登記一步：從拖之前到現在
            }
            commitImages()
        } else {
            if !indices.isEmpty { pv.replaceSilently(updated, updateBaseline: false) }  // 拖曳中途不登記
            previewImages()
        }
    }

    // MARK: 操作列的功能

    private func setColor(_ color: UIColor) {
        // 只換色相，每一筆保留自己原本的透明度（螢光筆還是半透明，字還是不透明）
        baseStrokes = baseStrokes.map { stroke in
            var alpha: CGFloat = 1
            stroke.ink.color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            var colored = stroke
            colored.ink = PKInk(stroke.ink.inkType, color: color.withAlphaComponent(alpha))
            return colored
        }
        startDrawing = pageView?.canvas.drawing ?? PKDrawing()
        apply(commit: true)
        updateColorSwatch()
    }

    // 拷貝、剪下：筆跡、圖片、文字方塊一起（v12.9.2；以前只有筆跡）
    @objc private func copyTapped() {
        host?.copyToClipboard(currentStrokes(), from: pageView?.page, message: "已拷貝",
                              images: currentImages(), texts: currentTexts().map { $0.box })
        host?.dismissShapeEditor()                     // 拷貝完收起選取框
    }

    @objc private func cutTapped() {
        host?.copyToClipboard(currentStrokes(), from: pageView?.page, message: "已剪下",
                              images: currentImages(), texts: currentTexts().map { $0.box })
        deleteSelection()
    }

    @objc private func deleteTapped() {
        deleteSelection()
    }

    /// 白板：選到的筆跡、圖片、文字方塊的範圍 → 建立區塊（v12.8.2）
    @objc private func frameTapped() {
        var r = CGRect.null
        for stroke in currentStrokes() { r = r.union(stroke.renderBounds) }
        for box in currentImages() { r = r.union(Self.imageBounds(of: box)) }
        for item in currentTexts() { r = r.union(item.rect) }
        guard !r.isNull, let host = host else { return }
        host.dismissShapeEditor()                      // 先把選取框收好（移動、縮放過的話會先寫進去）
        host.createFrame(around: r)
    }

    /// 刪除選到的筆跡（和圖片）；兩者合成一步復原
    private func deleteSelection(includeImages: Bool = true) {
        if let pv = pageView {
            let canvas = pv.canvas
            if !indices.isEmpty {
                var updated = canvas.drawing
                for i in indices.sorted(by: >) where updated.strokes.indices.contains(i) {
                    updated.strokes.remove(at: i)
                }
                if let host = host {
                    host.recordingSelection { ShapeSnapper.setDrawing(updated, on: canvas) }
                } else {
                    ShapeSnapper.setDrawing(updated, on: canvas)
                }
            }
            if includeImages, !baseImages.isEmpty, let host = host {
                let gone = Set(baseImages.map { $0.id })
                let rest = host.imagesNow(pv.page.id).filter { !gone.contains($0.id) }
                host.setImagesRecorded(rest, pageID: pv.page.id)
            }
            if includeImages, !baseTexts.isEmpty, let host = host {
                let gone = Set(baseTexts.map { $0.box.id })
                let rest = host.textsNow(pv.page.id).filter { !gone.contains($0.id) }
                host.setTextsRecorded(rest, pageID: pv.page.id)
            }
        }
        host?.dismissShapeEditor()
    }

    @objc private func duplicateTapped() {
        duplicate()
    }

    private func duplicate() {
        guard let canvas = pageView?.canvas, let pv = pageView, let host = host else { return }
        let offset = CGAffineTransform(translationX: 20, y: 20)
        let copies = currentStrokes().map { stroke in               // 新的筆跡物件、沿用原本的筆畫點
            PKStroke(ink: stroke.ink, path: stroke.path,
                     transform: stroke.transform.concatenating(offset), mask: stroke.mask)
        }
        var updated = canvas.drawing
        let start = updated.strokes.count
        updated.strokes.append(contentsOf: copies)
        if !copies.isEmpty { ShapeSnapper.setDrawing(updated, on: canvas) }
        // 圖片也多一份（往右下錯開一點）
        var newImages: [ImageBox] = []
        for box in currentImages() {
            var copy = box
            copy.id = UUID()
            copy.x += 20
            copy.y += 20
            newImages.append(copy)
        }
        if !newImages.isEmpty {
            host.setImagesRecorded(host.imagesNow(pv.page.id) + newImages, pageID: pv.page.id)
        }
        // 文字方塊也多一份
        var newTexts: [PickedText] = []
        for item in currentTexts() {
            var copy = item
            copy.box.id = UUID()
            copy.box.x += 20
            copy.box.y += 20
            copy.rect = copy.rect.offsetBy(dx: 20, dy: 20)
            newTexts.append(copy)
        }
        if !newTexts.isEmpty {
            host.setTextsRecorded(host.textsNow(pv.page.id) + newTexts.map { $0.box }, pageID: pv.page.id)
        }
        host.showSelection(on: pv, indices: Array(start..<(start + copies.count)), images: newImages,
                           texts: newTexts)
    }
}
