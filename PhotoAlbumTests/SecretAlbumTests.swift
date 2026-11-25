import SwiftData
import XCTest
@testable import PhotoAlbum

/// 비밀 앨범: 잠금 상태, 본인 확인, 홈·추천에서 빠지는지.
@MainActor
final class SecretAlbumTests: XCTestCase {
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

    /// 본인 확인 결과를 정해 두고, 몇 번 물었는지 센다.
    private final class Checker {
        var result: SecretLock.Check
        var asked = 0
        init(_ result: SecretLock.Check) { self.result = result }
    }

    private func lock(_ checker: Checker) -> SecretLock {
        SecretLock { _ in
            checker.asked += 1
            return checker.result
        }
    }

    func testLockingIsSavedAndUnlockedAlbumsNeedNoCheck() async {
        let album = store.createAlbum(title: "비밀")
        let checker = Checker(.failed(.cancelled))
        let secret = lock(checker)
        XCTAssertTrue(secret.isOpen(album), "잠그지 않은 앨범은 늘 열려 있다")

        store.setLocked(album, true)
        XCTAssertTrue(album.isLocked)
        XCTAssertFalse(secret.isOpen(album))
        let result = await secret.open(album)
        XCTAssertEqual(result.failureValue, .cancelled)
        XCTAssertFalse(secret.isOpen(album), "취소하면 열리지 않는다")

        store.setLocked(album, false)
        XCTAssertTrue(secret.isOpen(album))
    }

    func testOpenAsksOnceUntilAppLeaves() async {
        let album = store.createAlbum(title: "비밀")
        let other = store.createAlbum(title: "다른 비밀")
        store.setLocked(album, true)
        store.setLocked(other, true)
        let checker = Checker(.passed)
        let secret = lock(checker)

        _ = await secret.open(album)
        _ = await secret.open(album)
        XCTAssertTrue(secret.isOpen(album))
        XCTAssertEqual(checker.asked, 1, "열어 둔 동안은 다시 묻지 않는다")
        XCTAssertFalse(secret.isOpen(other), "한 앨범을 열어도 다른 비밀 앨범은 잠겨 있다")

        secret.lockAll()
        XCTAssertFalse(secret.isOpen(album), "앱을 떠나면 다시 잠긴다")
    }

    func testDeviceWithoutPasscodeDoesNotTrapAlbum() async {
        let album = store.createAlbum(title: "비밀")
        store.setLocked(album, true)
        let secret = lock(Checker(.unavailable))
        _ = await secret.open(album)
        XCTAssertTrue(secret.isOpen(album))
    }

    func testKeepOpenWhenLockingFromInside() {
        let album = store.createAlbum(title: "비밀")
        let secret = lock(Checker(.failed(.failed)))
        secret.keepOpen(album)
        store.setLocked(album, true)
        XCTAssertTrue(secret.isOpen(album), "보던 앨범을 잠가도 바로 닫히지 않는다")
    }

    func testLockedAlbumsStayOutOfHomeAndSuggestions() throws {
        let open = store.createAlbum(title: "가족", kind: .person)
        let secret = store.createAlbum(title: "비밀", kind: .person)
        for album in [open, secret] {
            store.markOpened(album, at: day(2026, 1, 1))
        }
        store.add([(id: "a", takenAt: day(2021, 11, 13))], to: open)
        store.add([(id: "b", takenAt: day(2021, 11, 13)), (id: "c", takenAt: day(2021, 11, 13))], to: secret)
        store.setLocked(secret, true)
        try container.mainContext.save()
        let all = [open, secret]

        XCTAssertEqual(HomeFeed.recent(in: all).map(\.title), ["가족"])
        XCTAssertEqual(HomeFeed.frequentPeople(in: all).map(\.title), ["가족"])
        let today = day(2026, 11, 13)
        XCTAssertEqual(HomeFeed.memories(in: all, today: today, calendar: calendar).map(\.album.title), ["가족"])
        let queried = BackgroundQueries.memories(in: ModelContext(container), today: today, calendar: calendar)
        XCTAssertEqual(queried.map(\.albumID), [open.id], "사진이 더 많아도 비밀 앨범은 지난 오늘에 나오지 않는다")

        let incoming = [PhotoSignature(takenAt: day(2021, 11, 13))]
        XCTAssertEqual(Suggestions.albums(for: incoming, among: all, calendar: calendar).map(\.album.title), ["가족"])
        let suggested = BackgroundQueries.suggestions(
            in: ModelContext(container), signatures: incoming, excluding: [], calendar: calendar
        )
        XCTAssertEqual(suggested.map(\.albumID), [open.id])
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
