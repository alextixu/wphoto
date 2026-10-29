import SwiftUI
import UIKit

/// 捏合縮放、拖曳平移、雙擊放大／還原（UIScrollView 實作，手感與相簿一致）
/// 放大到比目前的圖還細時，從原檔讀原始解析度換上去；縮回原大小再換回來
/// 未縮放時往下拖：照片跟著手指下移並略縮小，拖夠遠／夠快放開就關閉檢視器（進度與完成透過 closure 回報）
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let url: URL
    /// 下拉關閉的進度 0…1（外層用來把黑底變淡、藏頂列）；放開彈回時會收到 0
    var onDismissProgress: ((CGFloat) -> Void)? = nil
    /// 拖超過門檻放開：外層負責 dismiss
    var onDismiss: (() -> Void)? = nil

    func makeUIView(context: Context) -> ZoomScrollView {
        let sv = ZoomScrollView()
        sv.delegate = context.coordinator
        sv.onDismissProgress = onDismissProgress
        sv.onDismiss = onDismiss
        sv.setImage(image, url: url)
        let dbl = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        sv.addGestureRecognizer(dbl)
        return sv
    }

    func updateUIView(_ sv: ZoomScrollView, context: Context) {
        sv.onDismissProgress = onDismissProgress
        sv.onDismiss = onDismiss
        sv.setImage(image, url: url)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomScrollView)?.centerImage()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            (scrollView as? ZoomScrollView)?.zoomDidEnd()
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? ZoomScrollView else { return }
            if sv.zoomScale > 1 {
                sv.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: sv.imageView)
                let w = sv.bounds.width / 3, h = sv.bounds.height / 3
                sv.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
        }
    }
}

final class ZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    private var url: URL?
    /// 依畫面大小解碼的圖（PhotoPage 給的）
    private var baseImage: UIImage?
    private var fullResTask: Task<Void, Never>?
    private var showingFullRes = false

    /// 下拉關閉的進度（0…1）；放開彈回時回 0
    var onDismissProgress: ((CGFloat) -> Void)?
    /// 拖超過門檻放開時呼叫
    var onDismiss: (() -> Void)?

    /// 下拉關閉手勢。delegate 用獨立物件而不是 scroll view 自己：UIScrollView 私下就是自己那組 pan／pinch 的 delegate，
    /// 在子類別實作 UIGestureRecognizerDelegate 會把那些內部判斷一起蓋掉（例如捏合＋平移同時辨識）
    private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
    private lazy var dismissPanDelegate = DismissPanDelegate(scrollView: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1
        maximumZoomScale = 10
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        // 透明：黑底由 SwiftUI 那層畫，下拉關閉時才能跟著變淡
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        // 單指才算下拉（兩指是捏合縮放）；沒縮放時 contentSize == bounds，scroll view 自己不會捲，不會搶手勢
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.delegate = dismissPanDelegate
        addGestureRecognizer(dismissPan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage, url: URL) {
        if url != self.url {
            fullResTask?.cancel()
            fullResTask = nil
            showingFullRes = false
            self.url = url
            baseImage = image
            imageView.image = image
            setZoomScale(1, animated: false)
            setNeedsLayout()
        } else if image !== baseImage {
            // 同一張照片因畫面變大重新解碼：正在看原始解析度就不換
            baseImage = image
            if !showingFullRes { imageView.image = image }
        }
    }

    /// 縮放結束：一個圖片像素已被放大到超過一個螢幕像素就讀原始解析度；縮回原大小則換回並釋放記憶體
    func zoomDidEnd() {
        if zoomScale <= minimumZoomScale + 0.01 {
            fullResTask?.cancel()
            fullResTask = nil
            if showingFullRes {
                imageView.image = baseImage
                showingFullRes = false
            }
            return
        }
        guard !showingFullRes, fullResTask == nil, let url, let image = imageView.image,
              image.size.width > 0, image.size.height > 0 else { return }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        guard fit * zoomScale * traitCollection.displayScale > image.scale else { return }
        fullResTask = Task { [weak self] in
            let full = await Task.detached(priority: .userInitiated) {
                ImageLoading.fullImage(url: url)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.fullResTask = nil
            guard let full, self.url == url, self.zoomScale > self.minimumZoomScale + 0.01 else { return }
            // 原檔沒有比較大（小照片）也標記為已是原圖，之後不再重讀
            if self.longEdge(full) > self.longEdge(image) { self.imageView.image = full }
            self.showingFullRes = true
        }
    }

    private func longEdge(_ image: UIImage) -> CGFloat {
        max(image.size.width, image.size.height) * image.scale
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 下拉中 imageView 有 transform，這時改 frame 結果未定義；放開後 transform 會回 identity 再排
        guard imageView.transform.isIdentity else { return }
        if zoomScale == 1 {
            imageView.frame = bounds
            contentSize = bounds.size
        }
        centerImage()
    }

    func centerImage() {
        guard imageView.transform.isIdentity else { return }
        var f = imageView.frame
        f.origin.x = f.width < bounds.width ? (bounds.width - f.width) / 2 : 0
        f.origin.y = f.height < bounds.height ? (bounds.height - f.height) / 2 : 0
        imageView.frame = f
    }

    // MARK: - 下拉關閉

    /// 只有沒縮放、而且一開始就是明顯往下的拖曳才接手；其他情況讓捲動／分頁手勢處理
    fileprivate func dismissPanShouldBegin(_ g: UIPanGestureRecognizer) -> Bool {
        guard zoomScale <= minimumZoomScale + 0.01 else { return false }
        let v = g.velocity(in: self)
        return v.y > 0 && v.y > abs(v.x) * 1.5
    }

    @objc private func handleDismissPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        let dy = max(0, t.y)
        switch g.state {
        case .changed:
            // 跟著手指下移（左右只跟一半）並略縮小，最多縮到 0.75
            let scale = 1 - min(dy / 1200, 0.25)
            imageView.transform = CGAffineTransform(translationX: t.x * 0.5, y: dy).scaledBy(x: scale, y: scale)
            onDismissProgress?(min(dy / 240, 1))
        case .ended, .cancelled:
            let v = g.velocity(in: self)
            if dy > 120 || v.y > 900 {
                onDismiss?()
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                    self.imageView.transform = .identity
                }
                onDismissProgress?(0)
            }
        default:
            break
        }
    }
}

/// 下拉手勢的 delegate：判斷交給 ZoomScrollView，這裡只負責不和 scroll view 自己的 pan 同時辨識
private final class DismissPanDelegate: NSObject, UIGestureRecognizerDelegate {
    private weak var scrollView: ZoomScrollView?

    init(scrollView: ZoomScrollView) {
        self.scrollView = scrollView
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let scrollView, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        return scrollView.dismissPanShouldBegin(pan)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // 和 scroll view 自己的 pan 互斥，放大時才不會一邊捲一邊拉；其他手勢也維持預設的不同時辨識
        false
    }
}
