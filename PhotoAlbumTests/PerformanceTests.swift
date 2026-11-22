import SwiftData
import XCTest
@testable import PhotoAlbum

/// 사진이 많을 때 자주 도는 경로의 시간을 잰다. 기준을 넘으면 실패한다.
/// 기준은 시뮬레이터(맥) 기준이라 실제 기기보다 넉넉하지 않다. 느려지는 변화를 잡는 용도다.
@MainActor
final class PerformanceTests: XCTestCase {
    private var container: ModelContainer!
    private var store: AlbumStore!

    override func setUp() async throws {
        container = try ModelContainer(
            for: Album.self, Photo.self, AlbumPhoto.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store = AlbumStore(context: container.mainContext)
    }

    private func assets(_ count: Int, prefix: String = "p", start: Double = 1_400_000_000) -> [(id: String, takenAt: Date?)] {
        (0..<count).map { (id: "\(prefix)\($0)", takenAt: Date(timeIntervalSince1970: start + Double($0) * 3600)) }
    }

    /// 걸린 시간(ms)을 출력하고 돌려준다.
    @discardableResult
    private func time(_ label: String, _ body: () throws -> Void) rethrows -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        try body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("PERF \(label): \(String(format: "%.1f", ms)) ms")
        return ms
    }

    func testLargeAlbum() throws {
        let album = store.createAlbum(title: "큰 앨범")
        XCTAssertLessThan(time("add 3000 new") { store.add(assets(3000), to: album) }, 2000)
        let other = store.createAlbum(title: "다른 앨범")
        XCTAssertLessThan(time("add 3000 already in another album") { store.add(assets(3000), to: other) }, 2000)

        // 앱을 새로 켠 것처럼 다른 문맥에서 읽는다. 처음 한 번은 사진을 저장소에서 불러오느라 느리다.
        let fresh = ModelContext(container)
        let cold = try XCTUnwrap(fresh.fetch(FetchDescriptor<Album>(predicate: #Predicate { $0.title == "큰 앨범" })).first)
        XCTAssertLessThan(time("count + cover, cold (보관함 카드)") { _ = (cold.photoCount, cold.coverIdentifier) }, 5)
        let cache = OrderedLinksCache()
        XCTAssertLessThan(time("ordered links, cold (앨범 처음 열기)") { _ = cache.links(of: cold) }, 1000)
        // 캐러셀을 넘길 때마다 화면이 다시 그려진다. 이때는 저장해 둔 목록을 써야 한다.
        XCTAssertLessThan(time("ordered links x100, cached (캐러셀 넘기기)") {
            for _ in 0..<100 { _ = cache.links(of: cold) }
        }, 5)
        XCTAssertLessThan(time("count + cover x100, warm") {
            for _ in 0..<100 { _ = (cold.photoCount, cold.coverIdentifier) }
        }, 5)
        XCTAssertLessThan(time("summary, warm (앨범 부제)") { _ = cold.summary }, 50)
    }

    func testQueriesScaleWithMatchesNotLibrary() {
        // 앨범 20개에 사진 6,000장.
        for index in 0..<20 {
            let album = store.createAlbum(title: "앨범 \(index)")
            store.add(assets(300, prefix: "a\(index)-", start: 1_300_000_000 + Double(index) * 2_000_000), to: album)
        }
        let incoming = (0..<60).map { PhotoSignature(takenAt: Date(timeIntervalSince1970: 1_300_000_000 + Double($0) * 7200)) }

        var found: [BackgroundQueries.SuggestionResult] = []
        let suggestions = time("suggestions query, cold") {
            found = BackgroundQueries.suggestions(in: ModelContext(container), signatures: incoming, excluding: [])
        }
        XCTAssertFalse(found.isEmpty)
        XCTAssertLessThan(suggestions, 300)

        let memories = time("memories query, cold") {
            _ = BackgroundQueries.memories(in: ModelContext(container), today: Date(timeIntervalSince1970: 1_700_000_000))
        }
        XCTAssertLessThan(memories, 300)
    }
}
