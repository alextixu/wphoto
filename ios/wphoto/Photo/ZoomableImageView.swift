import SwiftUI
import UIKit

/// 捏合縮放、拖曳平移、雙擊放大／還原（UIScrollView 實作，手感與相簿一致）
/// 放大到比目前的圖還細時，從原檔讀原始解析度換上去；縮回原大小再換回來
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let url: URL

    func makeUIView(context: Context) -> ZoomScrollView {
        let sv = ZoomScrollView()
        sv.delegate = context.coordinator
        sv.setImage(image, url: url)
        let dbl = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        sv.addGestureRecognizer(dbl)
        return sv
    }

    func updateUIView(_ sv: ZoomScrollView, context: Context) {
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1
        maximumZoomScale = 10
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
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
        if zoomScale == 1 {
            imageView.frame = bounds
            contentSize = bounds.size
        }
        centerImage()
    }

    func centerImage() {
        var f = imageView.frame
        f.origin.x = f.width < bounds.width ? (bounds.width - f.width) / 2 : 0
        f.origin.y = f.height < bounds.height ? (bounds.height - f.height) / 2 : 0
        imageView.frame = f
    }
}
