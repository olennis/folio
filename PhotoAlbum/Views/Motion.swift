import SwiftUI

/// 앱 전체가 쓰는 움직임 값. 근거는 Apple의 Designing Fluid Interfaces(WWDC 2018).
enum Motion {
    /// 기본. 임계 감쇠라 튀지 않는다. 탭이나 프로그램이 일으킨 변화에 쓴다.
    static let settle = Animation.spring(response: 0.4, dampingFraction: 1.0)
    /// 손가락으로 던진 뒤에만 쓴다. 제스처가 운동량을 실었을 때만 약간 튄다.
    static let flick = Animation.spring(response: 0.35, dampingFraction: 0.8)
    /// 누르는 순간의 반응.
    static let press = Animation.easeOut(duration: 0.1)
    /// 동작 줄이기 설정일 때. 미끄러짐 대신 짧은 전환.
    static let reduced = Animation.easeInOut(duration: 0.2)

    /// 경계를 넘어 끌 때의 저항. 멀리 끌수록 덜 따라온다.
    static func rubberBand(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0 else { return 0 }
        return (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
    }
}

/// 손이 닿는 순간 살짝 눌리는 버튼. 반응은 손을 뗄 때가 아니라 닿을 때 시작한다.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? Motion.press : Motion.settle, value: configuration.isPressed)
    }
}

/// 되돌릴 수 있는 동작 뒤에 잠깐 뜨는 안내. 확인 창으로 막는 대신 실행 취소를 준다.
struct UndoBanner: View {
    let message: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(message).font(.subheadline)
            Button("실행 취소", action: undo)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
        .labelGlass(cornerRadius: 22)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .transition(.opacity.combined(with: .offset(y: 16)))
        .accessibilityElement(children: .contain)
    }
}
