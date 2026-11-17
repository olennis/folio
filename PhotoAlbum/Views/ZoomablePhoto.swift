import Photos
import SwiftUI
import UIKit

/// 두 손가락으로 확대하고 두 번 눌러 확대/복귀하는 사진. 관성과 탄성은 시스템 스크롤 뷰가 맡는다.
struct ZoomablePhoto: View {
    let id: String
    var onSingleTap: () -> Void

    @State private var image: UIImage?
    @ObservedObject private var access = PhotoAccess.shared

    var body: some View {
        ZoomScroll(image: image, onSingleTap: onSingleTap)
            .task(id: "\(id)#\(access.status.rawValue)") {
                image = nil
                PhotoLibrary.load(id: id, pixels: 2400, fill: false) { image = $0 }
            }
    }
}

private struct ZoomScroll: UIViewRepresentable {
    let image: UIImage?
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> ZoomingScrollView { ZoomingScrollView() }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.onSingleTap = onSingleTap
        view.setImage(image)
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    var onSingleTap: (() -> Void)?
    private let imageView = UIImageView()
    private var laidOutSize = CGSize.zero

    init() {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .black
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        single.require(toFail: double)
        addGestureRecognizer(single)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage?) {
        guard imageView.image !== image else { return }
        imageView.image = image
        fit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            fit()
        }
        center()
    }

    /// 확대하지 않은 상태에서 사진이 화면에 꼭 맞게 들어가도록 한다.
    private func fit() {
        zoomScale = 1
        guard let size = imageView.image?.size, size.width > 0, size.height > 0, bounds.width > 0 else {
            imageView.frame = bounds
            contentSize = bounds.size
            return
        }
        let ratio = min(bounds.width / size.width, bounds.height / size.height)
        imageView.frame = CGRect(x: 0, y: 0, width: size.width * ratio, height: size.height * ratio)
        contentSize = imageView.frame.size
        center()
    }

    private func center() {
        let x = max((bounds.width - contentSize.width) / 2, 0)
        let y = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    @objc private func singleTapped() { onSingleTap?() }

    /// 누른 지점을 중심으로 확대한다. 이미 확대돼 있으면 원래대로.
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
