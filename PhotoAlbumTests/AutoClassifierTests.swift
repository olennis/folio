import XCTest
@testable import PhotoAlbum

/// 자동 분류의 계산(연도·여행·장면)을 사진 보관함 없이 만든 데이터로 확인한다.
final class AutoClassifierTests: XCTestCase {
    private var calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return value
    }()

    private let seoul = (37.56, 126.97)
    private let jeju = (33.50, 126.53)

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func photo(_ id: String, _ date: Date, at place: (Double, Double)? = nil, scenes: Set<SceneCategory> = []) -> LibraryPhoto {
        LibraryPhoto(id: id, takenAt: date, latitude: place?.0, longitude: place?.1, scenes: scenes)
    }

    /// 서울에서 매주 찍은 일상 사진(집이 서울이 되도록).
    private func everyday(_ count: Int, year: Int = 2024) -> [LibraryPhoto] {
        (0..<count).map { photo("home\($0)", date(year, 1, 1).addingTimeInterval(Double($0) * 7 * 86400), at: seoul) }
    }

    private var loose: AutoClassifier.Thresholds {
        var value = AutoClassifier.Thresholds()
        value.yearMinimum = 3
        value.tripMinimum = 4
        value.sceneMinimum = 2
        return value
    }

    // MARK: 연도

    func testYearSuggestsNewAlbumOnlyWithEnoughPhotos() {
        let photos = (0..<3).map { photo("a\($0)", date(2023, 5, $0 + 1)) } + [photo("b0", date(2022, 1, 1))]
        let found = AutoClassifier.suggestions(photos: photos, albums: [], thresholds: loose, calendar: calendar)
        let years = found.filter { if case .year = $0.source { true } else { false } }
        XCTAssertEqual(years.map(\.title), ["2023년"], "한 장뿐인 2022년은 새 앨범으로 제안하지 않는다")
        XCTAssertNil(years.first?.targetAlbumID)
        XCTAssertEqual(years.first?.newKind, .year)
        XCTAssertEqual(years.first?.assetIDs, ["a0", "a1", "a2"])
    }

    func testYearFillsExistingYearAlbumWithMissingPhotosOnly() {
        let album = AlbumSnapshot(id: UUID(), title: "2022년", kind: .year, assetIDs: ["b0"])
        let photos = [photo("b0", date(2022, 1, 1)), photo("b1", date(2022, 3, 1))]
        let found = AutoClassifier.suggestions(photos: photos, albums: [album], thresholds: loose, calendar: calendar)
        let year = found.first { $0.id == "year-2022" }
        XCTAssertEqual(year?.targetAlbumID, album.id, "이미 있는 연도 앨범에는 한 장이라도 채우자고 한다")
        XCTAssertEqual(year?.assetIDs, ["b1"])
        XCTAssertEqual(year?.detail, "‘2022년’에 빠진 사진 1장")
    }

    // MARK: 여행

    func testTripFarFromHomeIsSuggestedAndHomeIsNot() {
        let trip = (0..<5).map { photo("t\($0)", date(2024, 7, 3, hour: 9 + $0 * 6), at: jeju) }
        let found = AutoClassifier.trips(
            (everyday(20) + trip).sorted { $0.takenAt! < $1.takenAt! },
            albums: [], thresholds: loose, calendar: calendar
        )
        XCTAssertEqual(found.count, 1, "서울의 일상 사진은 여행이 아니다")
        XCTAssertEqual(found.first?.assetIDs, trip.map(\.id))
        XCTAssertEqual(found.first?.title, "2024년 7월 여행")
        XCTAssertEqual(found.first?.newKind, .place)
        XCTAssertEqual(found.first?.center?.latitude ?? 0, jeju.0, accuracy: 0.01)
    }

    /// 매일 찍는 사람: 여행 앞뒤 서울 사진이 48시간 안에 이어져도 여행은 제주 사진만, 이름은 제주로.
    func testDailyHomePhotosAroundTripAreTrimmed() {
        let before = (0..<12).map { photo("b\($0)", date(2024, 6, 20 + $0), at: seoul) }
        let trip = (0..<5).map { photo("t\($0)", date(2024, 7, 3, hour: 9 + $0 * 6), at: jeju) }
        let after = (0..<12).map { photo("a\($0)", date(2024, 7, 5 + $0), at: seoul) }
        let found = AutoClassifier.trips(everyday(20) + before + trip + after, albums: [], thresholds: loose, calendar: calendar)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.assetIDs, trip.map(\.id))
        XCTAssertEqual(found.first?.center?.latitude ?? 0, jeju.0, accuracy: 0.05, "서울과 제주의 평균(평택 근처)이 아니라 제주")
    }

    /// 두 곳을 다녀온 여행은 평균 지점이 아니라 더 많이 찍은 곳으로 이름을 붙인다.
    func testTripCenterIsWhereMostPhotosWereTaken() {
        let busan = (35.18, 129.08)
        let trip = (0..<6).map { photo("j\($0)", date(2024, 7, 3, hour: 8 + $0), at: jeju) }
            + (0..<3).map { photo("p\($0)", date(2024, 7, 4, hour: 8 + $0), at: busan) }
        let found = AutoClassifier.trips(everyday(20) + trip, albums: [], thresholds: loose, calendar: calendar)
        XCTAssertEqual(found.first?.center?.latitude ?? 0, jeju.0, accuracy: 0.05)
    }

    func testLongGapSplitsTwoTrips() {
        let first = (0..<4).map { photo("x\($0)", date(2024, 3, 1, hour: 8 + $0), at: jeju) }
        let second = (0..<4).map { photo("y\($0)", date(2024, 3, 10, hour: 8 + $0), at: jeju) }
        let found = AutoClassifier.trips(everyday(20) + first + second, albums: [], thresholds: loose, calendar: calendar)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first?.assetIDs, second.map(\.id), "최근 여행이 먼저 온다")
    }

    func testTripAlreadyInAnAlbumIsNotSuggested() {
        let trip = (0..<5).map { photo("t\($0)", date(2024, 7, 3, hour: 9 + $0), at: jeju) }
        let album = AlbumSnapshot(id: UUID(), title: "제주", kind: .place, assetIDs: Set(trip.map(\.id)))
        let found = AutoClassifier.trips(everyday(20) + trip, albums: [album], thresholds: loose, calendar: calendar)
        XCTAssertTrue(found.isEmpty)
    }

    func testTripNeedsLocations() {
        let trip = (0..<5).map { photo("t\($0)", date(2024, 7, 3, hour: 9 + $0)) }
        XCTAssertTrue(AutoClassifier.trips(everyday(20) + trip, albums: [], thresholds: loose, calendar: calendar).isEmpty)
    }

    // MARK: 장면

    func testScenesGroupIntoNamedAlbumsAndFillExisting() {
        let photos = [
            photo("d1", date(2024, 1, 1), scenes: [.pets]),
            photo("d2", date(2024, 1, 2), scenes: [.pets]),
            photo("f1", date(2024, 1, 3), scenes: [.food]),
            photo("f2", date(2024, 1, 4), scenes: [.food, .beach]),
        ]
        let food = AlbumSnapshot(id: UUID(), title: "음식", kind: .custom, assetIDs: ["f1"])
        let found = AutoClassifier.scenes(photos, albums: [food], thresholds: loose)
        XCTAssertEqual(found.map(\.title), ["반려동물", "음식"], "바다는 한 장이라 새 앨범 기준에 못 미친다")
        XCTAssertNil(found[0].targetAlbumID)
        XCTAssertEqual(found[1].targetAlbumID, food.id)
        XCTAssertEqual(found[1].assetIDs, ["f2"])
    }

    func testVisionLabelsMapToScenesAboveConfidence() {
        let scenes = SceneCategory.categories(from: [
            ("dog", 0.91), ("cake", 0.7), ("beach", 0.3), ("mountain", 0.6), ("car", 0.99),
        ])
        XCTAssertEqual(scenes, [.pets, .food, .mountain])
    }

    func testDismissedSuggestionsStayHidden() {
        let photos = (0..<3).map { photo("a\($0)", date(2023, 5, $0 + 1)) }
        XCTAssertFalse(AutoClassifier.suggestions(photos: photos, albums: [], thresholds: loose, calendar: calendar).isEmpty)
        XCTAssertTrue(AutoClassifier.suggestions(
            photos: photos, albums: [], dismissed: ["year-2023"], thresholds: loose, calendar: calendar
        ).isEmpty)
    }

    // MARK: 장면 기록

    func testSceneIndexRemembersAnalyzedPhotosAcrossLaunches() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scene-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let index = SceneIndex(fileURL: file)
        // 보관함에 없는 ID는 "봤지만 장면 없음"으로 기록된다.
        await index.analyze(["missing-1", "missing-2"]) { _ in }
        let pendingNow = await index.pending(among: ["missing-1", "missing-2", "new"])
        XCTAssertEqual(pendingNow, ["new"])

        let relaunched = SceneIndex(fileURL: file)
        let pendingAfterRelaunch = await relaunched.pending(among: ["missing-1", "new"])
        XCTAssertEqual(pendingAfterRelaunch, ["new"], "다시 켜도 본 사진은 다시 보지 않는다")
    }
}
