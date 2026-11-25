import XCTest
@testable import PhotoAlbum

/// 꾹 눌러 끌어 고르기: 손가락 위치 → 칸, 누른 칸부터 지금 칸까지의 선택.
final class GridSelectionTests: XCTestCase {
    /// 3열, 간격 2, 너비 302 → 칸 100, 한 칸 건너뛰는 길이 102.
    private let layout = GridSelection.Layout(columns: 3, spacing: 2, width: 302)
    private let items = (0..<10).map { "p\($0)" }

    func testPointMapsToCellAndClampsOutsideGrid() {
        XCTAssertEqual(layout.index(at: CGPoint(x: 10, y: 10), count: 10), 0)
        XCTAssertEqual(layout.index(at: CGPoint(x: 150, y: 10), count: 10), 1)
        XCTAssertEqual(layout.index(at: CGPoint(x: 250, y: 120), count: 10), 5)
        XCTAssertEqual(layout.index(at: CGPoint(x: 150, y: -40), count: 10), 1, "격자 위로 벗어나면 첫 줄")
        XCTAssertEqual(layout.index(at: CGPoint(x: 400, y: 10), count: 10), 2, "오른쪽 밖이면 마지막 열")
        XCTAssertEqual(layout.index(at: CGPoint(x: 250, y: 900), count: 10), 9, "아래로 벗어나면 마지막 칸")
        XCTAssertNil(layout.index(at: .zero, count: 0))
    }

    func testDraggingSelectsEverythingBetweenInReadingOrder() {
        let drag = GridSelection.Drag(anchor: 1, items: items, selected: ["p8"])
        XCTAssertTrue(drag.selecting)
        // 둘째 칸에서 다음 줄 첫 칸으로: 사이의 칸이 모두 골라진다.
        XCTAssertEqual(drag.selection(to: 3, in: items), ["p1", "p2", "p3", "p8"])
        // 거꾸로 끌어도 같다.
        XCTAssertEqual(drag.selection(to: 0, in: items), ["p0", "p1", "p8"])
        // 손가락이 되돌아오면 지나쳤던 칸은 원래대로.
        XCTAssertEqual(drag.selection(to: 1, in: items), ["p1", "p8"])
    }

    func testStartingOnSelectedPhotoDeselectsWhileDragging() {
        let drag = GridSelection.Drag(anchor: 2, items: items, selected: ["p2", "p3", "p4", "p9"])
        XCTAssertFalse(drag.selecting, "이미 고른 칸에서 시작하면 푼다")
        XCTAssertEqual(drag.selection(to: 4, in: items), ["p9"])
    }
}
