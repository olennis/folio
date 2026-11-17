import SwiftData
import XCTest
@testable import PhotoAlbum

/// 앨범 종류, 사진 이름, 열람 기록, 추천, 홈 피드.
@MainActor
final class FeatureTests: XCTestCase {
    private var container: ModelContainer!
    private var store: AlbumStore!
    private var calendar = Calendar(identifier: .gregorian)

    override func setUp() async throws {
        container = try ModelContainer(
            for: Album.self, Photo.self, AlbumPhoto.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store = AlbumStore(context: container.mainContext)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 10))!
    }

    private func photo(_ id: String) throws -> Photo {
        try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<Photo>()).first { $0.assetIdentifier == id })
    }

    func testKindIsInferredFromYearTitleOrGivenExplicitly() {
        XCTAssertEqual(store.createAlbum(title: "2015년").kind, .year)
        XCTAssertEqual(store.createAlbum(title: " 2021 ").kind, .year)
        XCTAssertEqual(store.createAlbum(title: "2015년 제주").kind, .custom)
        XCTAssertEqual(store.createAlbum(title: "서윤", kind: .person).kind, .person)
        let album = store.createAlbum(title: "제주")
        store.setKind(album, to: .place)
        XCTAssertEqual(album.kind, .place)
    }

    func testPhotoTitleSurvivesRemoveAndUndo() throws {
        let album = store.createAlbum(title: "A")
        let link = try XCTUnwrap(store.add([(id: "p1", takenAt: day(2021, 11, 13))], to: album).first)
        let original = try photo("p1")
        store.setTitle(original, to: "  성산일출봉의 아침 ")
        original.placeName = "서귀포시"
        XCTAssertEqual(original.displayTitle, "성산일출봉의 아침")

        let removed = try XCTUnwrap(store.remove(link))
        store.restore(removed, to: album)
        let restored = try photo("p1")
        XCTAssertEqual(restored.title, "성산일출봉의 아침")
        XCTAssertEqual(restored.placeName, "서귀포시")

        store.setTitle(restored, to: "   ")
        XCTAssertNil(restored.displayTitle)
    }

    func testSummaryShowsPeriodPlaceAndCount() throws {
        let album = store.createAlbum(title: "제주 가족여행")
        store.add([(id: "a", takenAt: day(2021, 11, 13)), (id: "b", takenAt: day(2021, 11, 14))], to: album)
        try photo("a").placeName = "제주시"
        try photo("b").placeName = "제주시"
        XCTAssertEqual(album.periodText(calendar: calendar), "2021년 11월")
        XCTAssertEqual(album.placeText, "제주시")

        store.add([(id: "c", takenAt: day(2021, 3, 1))], to: album)
        XCTAssertEqual(album.periodText(calendar: calendar), "2021년")
        store.add([(id: "d", takenAt: day(2019, 3, 1))], to: album)
        XCTAssertEqual(album.periodText(calendar: calendar), "2019–2021")
        XCTAssertTrue(album.summary.hasSuffix("사진 4장"), album.summary)
    }

    func testOpeningAlbumsFeedsRecentAndFrequentPeople() {
        let trip = store.createAlbum(title: "제주")
        let child = store.createAlbum(title: "서윤", kind: .person)
        let friend = store.createAlbum(title: "민수", kind: .person)
        let unopened = store.createAlbum(title: "안 본 앨범")
        store.markOpened(trip, at: day(2026, 1, 1))
        store.markOpened(child, at: day(2026, 1, 2))
        store.markOpened(child, at: day(2026, 1, 3))
        store.markOpened(friend, at: day(2026, 1, 4))
        let all = [trip, child, friend, unopened]

        XCTAssertEqual(HomeFeed.recent(in: all).map(\.title), ["민수", "서윤", "제주"])
        XCTAssertEqual(HomeFeed.frequentPeople(in: all).map(\.title), ["서윤", "민수"])
    }

    func testMemoriesPickAlbumsWithPhotosTakenOnThisDayInEarlierYears() {
        let trip = store.createAlbum(title: "제주")
        let other = store.createAlbum(title: "다른 날")
        store.add([(id: "a", takenAt: day(2021, 11, 13)), (id: "b", takenAt: day(2021, 11, 13))], to: trip)
        store.add([(id: "c", takenAt: day(2020, 5, 5)), (id: "d", takenAt: day(2026, 11, 13))], to: other)

        let exact = HomeFeed.memories(in: [trip, other], today: day(2026, 11, 13), calendar: calendar)
        XCTAssertEqual(exact.map(\.album.title), ["제주"])
        XCTAssertEqual(exact.first?.headline, "5년 전 오늘")
        XCTAssertEqual(exact.first?.photoCount, 2)

        // 같은 날이 없으면 앞뒤 며칠까지 보고, 그때는 "오늘"이라고 하지 않는다.
        let near = HomeFeed.memories(in: [trip, other], today: day(2026, 11, 15), calendar: calendar)
        XCTAssertEqual(near.first?.headline, "5년 전 이맘때")
        XCTAssertTrue(HomeFeed.memories(in: [trip, other], today: day(2026, 8, 1), calendar: calendar).isEmpty)
    }

    func testSuggestionsRankSameDayAndPlaceFirst() throws {
        let trip = store.createAlbum(title: "제주 가족여행")
        let year = store.createAlbum(title: "2021년")
        let nearby = store.createAlbum(title: "제주 맛집")
        let unrelated = store.createAlbum(title: "도쿄")
        store.add([(id: "a", takenAt: day(2021, 11, 13))], to: trip)
        store.add([(id: "b", takenAt: day(2022, 1, 1))], to: nearby)
        store.add([(id: "c", takenAt: day(2019, 1, 1))], to: unrelated)
        for (id, latitude, longitude) in [("a", 33.46, 126.94), ("b", 33.47, 126.95), ("c", 35.68, 139.76)] {
            let item = try photo(id)
            item.latitude = latitude
            item.longitude = longitude
        }

        let incoming = [PhotoSignature(takenAt: day(2021, 11, 13), latitude: 33.458, longitude: 126.942)]
        let all = [trip, year, nearby, unrelated]
        let result = Suggestions.albums(for: incoming, among: all, calendar: calendar)
        XCTAssertEqual(result.map(\.album.title), ["제주 가족여행", "제주 맛집", "2021년"])
        XCTAssertEqual(result.map(\.reason), ["촬영 날짜와 장소가 같아요", "촬영 장소가 가까워요", "촬영 연도가 같아요"])

        let excluded = Suggestions.albums(for: incoming, among: all, excluding: [trip.id], calendar: calendar)
        XCTAssertFalse(excluded.contains { $0.album.id == trip.id })
        XCTAssertTrue(Suggestions.albums(for: [PhotoSignature()], among: all, calendar: calendar).isEmpty)
    }
}
