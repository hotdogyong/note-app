import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC
import PDFKit
import UniformTypeIdentifiers
import WebKit
import PhotosUI

// InsertMenu.swift：長按空白處跳出的一圈按鈕（貼上、照片、相機、檔案、文字），以及照片、相機、檔案的選取畫面（v12.3）
// （筆記 App 的一部分；版本號與檔案清單在 ContentView.swift 開頭）

/// 要插入什麼：筆記本畫面（UIKit）按了一圈按鈕裡的某一個，告訴外面的 SwiftUI 畫面打開對應的選取畫面
enum InsertKind: Equatable {
    case photos        // 相簿
    case camera        // 相機
    case files         // 「檔案」App
}

/// 長按空白處跳出的一圈按鈕（仿 GUGA）。
/// 手指長按後不放開，這一圈從按的地方彈出去；手指滑到某一顆上面，那一顆變橘色、變大，上面出現名稱；
/// 在它上面放開就執行，在別的地方放開就收起來（縮回按的地方）。有些按鈕滑上去時，外面會再多出一顆（例如「相冊」外面的「相機」）。
/// 位置固定八格（順時針：貼上、圖釘、文件、相冊、錄音、新筆記本、子白板、新卡片），沒有功能的格子空著。
/// 這個畫面自己不收觸控：手指的位置由筆記本畫面的長按手勢傳進來（track、finish）。
final class RadialMenuView: UIView {
    struct Item {
        var symbol: String
        var title: String
        var tint: UIColor = UIColor.black           // 圖示的顏色（v12.6：不要全部黑色）
        var action: () -> Void
        var outerSymbol: String? = nil          // 滑到這一顆時，外圈多出來的那一顆
        var outerTitle: String? = nil
        var outerTint: UIColor = UIColor.black
        var outerAction: (() -> Void)? = nil
    }

    private let items: [Item?]                  // nil：那一格空著
    private var middle = CGPoint.zero
    private var spots: [CGPoint] = []           // 每一格的中心
    private var outerSpots: [CGPoint] = []      // 每一格外圈那一顆的中心
    private var circles: [UIView?] = []
    private var icons: [UIImageView?] = []
    private let dot = UIView()
    private let outerCircle = UIView()
    private let outerIcon = UIImageView()
    private let nameLabel = UILabel()
    private var shownOuter: Int?                // 現在外圈顯示的是哪一格的
    private var picked: Int?                    // 手指現在在哪一格上
    private var pickedOuter = false             // 手指在外圈那一顆上
    private var closing = false

    private static let orange = UIColor(red: 0.96, green: 0.76, blue: 0.30, alpha: 1)
    private static let half: CGFloat = 30       // 每一顆的半徑
    private static let config = UIImage.SymbolConfiguration(pointSize: 23, weight: .semibold)

    /// frame：蓋住整個筆記本畫面；point：長按的位置
    init(frame: CGRect, at point: CGPoint, items: [Item?]) {
        self.items = items
        super.init(frame: frame)
        backgroundColor = UIColor.clear
        isUserInteractionEnabled = false
        let radius: CGFloat = 98
        let half = Self.half
        // 太靠邊就往裡面移，整圈都看得到
        let pad = radius + half + 8
        middle = point
        middle.x = min(max(middle.x, pad), max(frame.width - pad, pad))
        middle.y = min(max(middle.y, pad), max(frame.height - pad, pad))
        // 中間的圓點：在手指按的地方
        dot.frame = CGRect(x: point.x - 26, y: point.y - 26, width: 52, height: 52)
        dot.backgroundColor = UIColor(white: 0.6, alpha: 0.35)
        dot.layer.cornerRadius = 26
        addSubview(dot)
        let count = max(items.count, 1)
        for (i, entry) in items.enumerated() {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * 2 * CGFloat.pi / CGFloat(count)
            let spot = CGPoint(x: middle.x + cos(angle) * radius, y: middle.y + sin(angle) * radius)
            spots.append(spot)
            outerSpots.append(CGPoint(x: middle.x + cos(angle) * (radius + 86), y: middle.y + sin(angle) * (radius + 86)))
            guard let item = entry else {
                circles.append(nil)
                icons.append(nil)
                continue
            }
            let circle = Self.makeCircle()
            circle.center = spot
            let icon = UIImageView(image: UIImage(systemName: item.symbol, withConfiguration: Self.config))
            icon.tintColor = item.tint
            icon.contentMode = .center
            icon.frame = circle.bounds
            circle.addSubview(icon)
            addSubview(circle)
            circles.append(circle)
            icons.append(icon)
        }
        // 外圈的那一顆（平常藏起來）
        outerCircle.frame = CGRect(x: 0, y: 0, width: half * 2, height: half * 2)
        Self.style(outerCircle)
        outerIcon.contentMode = .center
        outerIcon.frame = outerCircle.bounds
        outerCircle.addSubview(outerIcon)
        outerCircle.isHidden = true
        addSubview(outerCircle)
        // 名稱
        nameLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        nameLabel.textColor = UIColor.white
        nameLabel.textAlignment = .center
        nameLabel.backgroundColor = UIColor(white: 0.15, alpha: 0.95)
        nameLabel.layer.cornerRadius = 9
        nameLabel.clipsToBounds = true
        nameLabel.isHidden = true
        addSubview(nameLabel)
        popOut()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func style(_ view: UIView) {
        view.backgroundColor = UIColor.white
        view.layer.cornerRadius = half
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.28
        view.layer.shadowRadius = 6
        view.layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    private static func makeCircle() -> UIView {
        let circle = UIView(frame: CGRect(x: 0, y: 0, width: half * 2, height: half * 2))
        style(circle)
        return circle
    }

    /// 從手指按的地方彈出去：全部同時、等速（v12.8：以前每顆錯開、還會回彈）
    private func popOut() {
        for (i, entry) in circles.enumerated() {
            guard let circle = entry else { continue }
            let target = spots[i]
            circle.center = dot.center
            circle.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
            circle.alpha = 0
            UIView.animate(withDuration: 0.11, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: {   // v12.9.8：0.2 → 0.11
                circle.center = target
                circle.transform = CGAffineTransform.identity
                circle.alpha = 1
            }, completion: nil)
        }
        dot.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        UIView.animate(withDuration: 0.11) { self.dot.transform = CGAffineTransform.identity }
    }

    /// 手指移到 p（這個畫面的座標）：更新哪一格被選中
    func track(_ p: CGPoint) {
        if closing { return }
        var newPick: Int?
        var onOuter = false
        if let parent = shownOuter, outerSpots.indices.contains(parent),
           hypot(p.x - outerSpots[parent].x, p.y - outerSpots[parent].y) < 42 {
            newPick = parent
            onOuter = true
        } else {
            for (i, spot) in spots.enumerated() where items[i] != nil && hypot(p.x - spot.x, p.y - spot.y) < 42 {
                newPick = i
            }
        }
        // 滑到有外圈的那一格：外圈出現；滑到別格：外圈收起來；滑到空的地方：先留著（手指正要滑過去）
        if let i = newPick, !onOuter, let item = items[i] {
            let before = shownOuter
            shownOuter = item.outerSymbol != nil ? i : nil
            if shownOuter != nil, shownOuter != before { popOuter(from: spots[i]) }
        }
        if newPick != picked || onOuter != pickedOuter {
            UISelectionFeedbackGenerator().selectionChanged()       // 換到另一顆：輕輕震一下
        }
        picked = newPick
        pickedOuter = onOuter
        refresh()
    }

    /// 外圈那一顆從裡面那一格彈出去
    private func popOuter(from start: CGPoint) {
        guard let parent = shownOuter else { return }
        outerCircle.isHidden = false
        outerCircle.center = start
        outerCircle.alpha = 0
        UIView.animate(withDuration: 0.09, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: {
            self.outerCircle.center = self.outerSpots[parent]
            self.outerCircle.alpha = 1
        }, completion: nil)
    }

    /// 放開手指：在某一顆上就執行它；整圈縮回按的地方再消失
    func finish(at p: CGPoint) {
        track(p)
        var action: (() -> Void)?
        if let i = picked, let item = items[i] {
            action = pickedOuter ? item.outerAction : item.action
        }
        close(then: action)
    }

    /// 收起來（縮回按的地方）；then：收完要做的事
    func close(then action: (() -> Void)? = nil) {
        if closing { return }
        closing = true
        nameLabel.isHidden = true
        let home = dot.center
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn], animations: {
            for entry in self.circles {
                guard let circle = entry else { continue }
                circle.center = home
                circle.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
                circle.alpha = 0
            }
            self.outerCircle.center = home
            self.outerCircle.alpha = 0
            self.dot.alpha = 0
        }, completion: { _ in
            self.removeFromSuperview()
        })
        if let run = action {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { run() }
        }
    }

    private func refresh() {
        for (i, entry) in circles.enumerated() {
            guard let circle = entry, let icon = icons[i], let item = items[i] else { continue }
            let on = picked == i && !pickedOuter
            circle.backgroundColor = on ? Self.orange : UIColor.white
            UIView.animate(withDuration: 0.12) {
                circle.transform = on ? CGAffineTransform(scaleX: 1.28, y: 1.28) : CGAffineTransform.identity
            }
            icon.tintColor = on ? UIColor.white : item.tint
        }
        if let parent = shownOuter, let item = items[parent], let symbol = item.outerSymbol {
            outerCircle.isHidden = false
            outerIcon.image = UIImage(systemName: symbol, withConfiguration: Self.config)
            outerCircle.backgroundColor = pickedOuter ? Self.orange : UIColor.white
            UIView.animate(withDuration: 0.12) {
                self.outerCircle.transform = self.pickedOuter ? CGAffineTransform(scaleX: 1.28, y: 1.28) : CGAffineTransform.identity
            }
            outerIcon.tintColor = pickedOuter ? UIColor.white : item.outerTint
        } else {
            outerCircle.isHidden = true
        }
        // 名稱：放在被選中那一顆的上面
        guard let i = picked, let item = items[i] else {
            nameLabel.isHidden = true
            return
        }
        let text = pickedOuter ? (item.outerTitle ?? "") : item.title
        let spot = pickedOuter ? outerSpots[i] : spots[i]
        nameLabel.text = text
        let width = max(56, (text as NSString).size(withAttributes: [NSAttributedString.Key.font: nameLabel.font as Any]).width + 24)
        nameLabel.frame = CGRect(x: spot.x - width / 2, y: spot.y - Self.half * 1.3 - 46, width: width, height: 34)
        nameLabel.isHidden = text.isEmpty
        bringSubviewToFront(nameLabel)
    }
}

/// 照片、相機、檔案的選取畫面：掛在筆記本的 SwiftUI 外框上，選到圖片後交給筆記本畫面貼上
struct InsertPickers: ViewModifier {
    @ObservedObject var model: NotebookModel
    @State private var photoItem: PhotosPickerItem?

    private func showing(_ kind: InsertKind) -> Binding<Bool> {
        Binding(get: { model.insertRequest == kind },
                set: { on in
                    if !on, model.insertRequest == kind { model.insertRequest = nil }
                })
    }

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: showing(InsertKind.photos), selection: $photoItem, matching: PHPickerFilter.images)
            .onChange(of: photoItem) { _, item in
                guard let picked = item else { return }
                loadPhoto(picked)
            }
            .fileImporter(isPresented: showing(InsertKind.files), allowedContentTypes: [UTType.image]) { result in
                if case .success(let url) = result { loadFile(url) }
            }
            .fullScreenCover(isPresented: showing(InsertKind.camera)) {
                CameraPicker { image in
                    model.insertRequest = nil
                    if let image = image { model.documentView?.insertPickedImage(image) }
                }
                .ignoresSafeArea()
            }
    }

    /// 相簿選到的照片：讀成圖片後貼上
    private func loadPhoto(_ item: PhotosPickerItem) {
        Task { @MainActor in
            let data = try? await item.loadTransferable(type: Data.self)
            photoItem = nil
            if let data = data, let image = UIImage(data: data) {
                model.documentView?.insertPickedImage(image)
            } else {
                model.documentView?.showMessage("exclamationmark.triangle", "這張照片讀不出來")
            }
        }
    }

    /// 「檔案」App 選到的圖片檔
    private func loadFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            model.documentView?.insertPickedImage(image)
        } else {
            model.documentView?.showMessage("exclamationmark.triangle", "這個檔案不是圖片，或讀不出來")
        }
    }
}

/// 相機（系統的拍照畫面）。拍好或取消都會呼叫 onImage（取消時是 nil）
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage?) -> Void

    func makeCoordinator() -> CameraCoordinator {
        CameraCoordinator(onImage: onImage)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}

@MainActor
final class CameraCoordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let onImage: (UIImage?) -> Void

    init(onImage: @escaping (UIImage?) -> Void) {
        self.onImage = onImage
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        onImage(info[UIImagePickerController.InfoKey.originalImage] as? UIImage)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        onImage(nil)
    }
}
