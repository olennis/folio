import SwiftUI

/// 사진 격자에서 꾹 누른 채 끌어 여러 장을 고르는 계산. 화면과 떼어 두어 테스트한다.
///
/// 사진 앱처럼 누른 칸부터 손가락이 있는 칸까지 읽는 순서대로 고른다.
/// 누른 칸이 이미 골라져 있었으면 끄는 동안 반대로 푼다.
enum GridSelection {
    /// 정사각형 칸이 같은 간격으로 놓인 격자.
    struct Layout: Equatable {
        var columns: Int
        var spacing: CGFloat
        var width: CGFloat

        var cell: CGFloat { max((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 1) }
        /// 한 칸과 간격을 더한 길이. 줄과 열을 셀 때 쓴다.
        var stride: CGFloat { cell + spacing }

        /// 격자 왼쪽 위를 원점으로 한 점이 가리키는 줄. 격자 위로 벗어나면 음수.
        func row(at y: CGFloat) -> Int {
            Int((y / stride).rounded(.down))
        }

        /// 점이 가리키는 칸. 격자 밖으로 벗어나면 가장 가까운 첫·마지막 칸에 붙인다.
        func index(at point: CGPoint, count: Int) -> Int? {
            guard count > 0 else { return nil }
            let column = min(max(Int((point.x / stride).rounded(.down)), 0), columns - 1)
            let row = max(row(at: point.y), 0)
            return min(row * columns + column, count - 1)
        }
    }

    /// 끌기를 시작할 때 정해지는 것들.
    struct Drag: Equatable {
        /// 처음 누른 칸.
        let anchor: Int
        /// true면 고르고, false면 푼다.
        let selecting: Bool
        /// 끌기 전의 선택. 손가락이 되돌아가면 원래대로 돌아오게 여기서부터 다시 계산한다.
        let base: Set<String>

        init(anchor: Int, items: [String], selected: Set<String>) {
            self.anchor = anchor
            selecting = !selected.contains(items[anchor])
            base = selected
        }

        /// 손가락이 `current` 칸에 있을 때의 선택.
        func selection(to current: Int, in items: [String]) -> Set<String> {
            let range = items[min(anchor, current)...max(anchor, current)]
            return selecting ? base.union(range) : base.subtracting(range)
        }
    }
}
