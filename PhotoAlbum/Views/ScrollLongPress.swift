import SwiftUI
import UIKit

/// 스크롤 뷰 안에서 꾹 누른 뒤 끄는 손가락을 따라간다.
///
/// SwiftUI 제스처(LongPress + Drag)를 스크롤 내용에 붙이면 기기에서 스크롤이 막혀서
/// 둘러싼 `UIScrollView`에 UIKit 길게 누르기를 단다. 꾹 누르기 전에 움직이면 길게 누르기가
/// 실패하므로 스크롤은 그대로 되고, 누른 뒤에는 끄는 동안만 스크롤을 끈다.
/// 위치는 화면 전체 좌표(`.global`과 같은 창 좌표)로 넘긴다.
struct ScrollLongPress: UIViewRepresentable {
    var minimumDuration: TimeInterval = 0.3
    /// 이 점에서 시작해도 되는지. 격자 밖에서 꾹 누르면 시작하지 않는다.
    var shouldBegin: (CGPoint) -> Bool
    var onChange: (CGPoint) -> Void
    var onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.coordinator = context.coordinator
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer.minimumPressDuration = minimumDuration
    }

    static func dismantleUIView(_ probe: Probe, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// 화면에 붙으면 위로 올라가며 둘러싼 스크롤 뷰를 찾는다.
    final class Probe: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            coordinator?.attach(to: view as? UIScrollView)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ScrollLongPress?
        let recognizer = UILongPressGestureRecognizer()
        private weak var scrollView: UIScrollView?

        override init() {
            super.init()
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handle(_:)))
        }

        func attach(to scrollView: UIScrollView?) {
            guard let scrollView, scrollView !== self.scrollView else { return }
            detach()
            scrollView.addGestureRecognizer(recognizer)
            self.scrollView = scrollView
        }

        func detach() {
            scrollView?.removeGestureRecognizer(recognizer)
            scrollView?.panGestureRecognizer.isEnabled = true
            scrollView = nil
        }

        @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: nil)
            switch recognizer.state {
            case .began:
                // 끄는 동안 손가락이 화면을 밀지 않게 한다. 끝으로 가면 대신 저절로 넘긴다.
                scrollView?.panGestureRecognizer.isEnabled = false
                parent?.onChange(point)
            case .changed:
                parent?.onChange(point)
            case .ended, .cancelled, .failed:
                scrollView?.panGestureRecognizer.isEnabled = true
                parent?.onEnd()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            parent?.shouldBegin(gestureRecognizer.location(in: nil)) ?? false
        }

        // 칸의 탭이나 스크롤과 함께 인식되게 둔다. 길게 누르기가 시작되면 칸의 탭은 취소된다.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
