import SwiftUI

/// 시스템이 제공하는 전환과 재질을, 지원하는 OS에서만 쓰도록 감싼 것.
extension View {
    /// 눌렀을 때 이 뷰에서부터 커지며 열리는 줌 전환의 출발점(iOS 18 이상).
    @ViewBuilder
    func zoomSource(id: some Hashable, in namespace: Namespace.ID, cornerRadius: CGFloat) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace) {
                $0.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            self
        }
    }

    /// 줌 전환으로 열리는 화면(iOS 18 이상). 아래로 끌어 닫는 동작도 시스템이 처리한다.
    @ViewBuilder
    func zoomDestination(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }

    /// 사진 위에 올리는 라벨 배경. iOS 26에서는 Liquid Glass, 그 전에는 블러 재질.
    @ViewBuilder
    func labelGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
