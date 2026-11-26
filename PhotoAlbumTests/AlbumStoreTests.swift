import SwiftData
import XCTest
@testable import PhotoAlbum

@MainActor
final class AlbumStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var store: AlbumStore { AlbumStore(context: context) }

    override func setUp() async throws {
        container = try ModelContainer(
            for: Album.self, Photo.self, AlbumPhoto.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    override func tearDown() async throws {
        container = nil
    }

    private func count<T: PersistentModel>(_ type: T.Type) -> Int {
        (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
    }

    private func ids(_ album: Album) -> [String] {
        album.orderedLinks.compactMap { $0.photo?.assetIdentifier }
    }

    // MARK: 정리 탭 앨범 표시

    func testOrganizeShowsEveryAlbumOfAPhotoButHidesLockedAlbumNames() {
        let year = store.createAlbum(title: "2024년")
        let jeju = store.createAlbum(title: "24년 제주 여행")
        let secret = store.createAlbum(title: "비밀")
        store.add(ids: ["a", "b"], to: year)
        store.add(ids: ["a"], to: jeju)
        store.add(ids: ["c"], to: secret)
        store.setLocked(secret, true)

        let names = OrganizeView.albumNames(in: context)
        XCTAssertEqual(Set(names["a"] ?? []), ["2024년", "24년 제주 여행"], "한 사진이 든 앨범을 모두 보여 준다")
        XCTAssertEqual(names["b"], ["2024년"])
        XCTAssertEqual(names["c"], [], "잠긴 앨범에만 든 사진은 앨범에 들었다는 것만 알린다")
        XCTAssertNil(names["d"], "앨범에 없는 사진은 미정리로 남는다")
        XCTAssertEqual(OrganizeView.label(names["c"]), "앨범에 든 사진")
        XCTAssertEqual(OrganizeView.label(nil), "미정리 사진")
    }

    // MARK: 앨범 CRUD

    func testCreateRenameDeleteAlbum() {
        let album = store.createAlbum(title: "  제주 가족여행 ")
        XCTAssertEqual(album.title, "제주 가족여행")
        XCTAssertEqual(count(Album.self), 1)

        store.rename(album, to: "제주 2021")
        XCTAssertEqual(album.title, "제주 2021")

        store.rename(album, to: "   ")
        XCTAssertEqual(album.title, AlbumStore.untitled)

        store.delete(album)
        XCTAssertEqual(count(Album.self), 0)
    }

    func testNewAlbumGoesToFront() {
        let first = store.createAlbum(title: "A")
        let second = store.createAlbum(title: "B")
        XCTAssertLessThan(second.sortIndex, first.sortIndex)
    }

    // MARK: 사진 CRUD

    func testAddKeepsOrderAndSkipsDuplicates() {
        let album = store.createAlbum(title: "A")
        store.add(ids: ["p1", "p2"], to: album)
        let added = store.add(ids: ["p2", "p3", "p3"], to: album)

        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(ids(album), ["p1", "p2", "p3"])
        XCTAssertEqual(count(Photo.self), 3)
        XCTAssertEqual(count(AlbumPhoto.self), 3)
    }

    func testPhotoBelongsToSeveralAlbums() throws {
        let trip = store.createAlbum(title: "제주 가족여행")
        let year = store.createAlbum(title: "2021년")
        store.add(ids: ["p1", "p2"], to: trip)
        store.add(ids: ["p1"], to: year)

        XCTAssertEqual(count(Photo.self), 2, "같은 사진은 한 번만 저장된다")
        XCTAssertEqual(count(AlbumPhoto.self), 3)

        let photo = try XCTUnwrap(year.orderedLinks.first?.photo)
        XCTAssertEqual(Set(store.albums(containing: photo).map(\.title)), ["제주 가족여행", "2021년"])
    }

    func testRemoveFromOneAlbumKeepsTheOther() throws {
        let trip = store.createAlbum(title: "제주 가족여행")
        let year = store.createAlbum(title: "2021년")
        store.add(ids: ["p1", "p2", "p3"], to: trip)
        store.add(ids: ["p1"], to: year)

        store.remove(try XCTUnwrap(trip.orderedLinks.first))

        XCTAssertEqual(ids(trip), ["p2", "p3"])
        XCTAssertEqual(trip.orderedLinks.map(\.position), [0, 1], "빠진 자리를 메운다")
        XCTAssertEqual(ids(year), ["p1"])
        XCTAssertEqual(count(Photo.self), 3)
    }

    func testRemovingFromLastAlbumDropsPhotoReference() throws {
        let album = store.createAlbum(title: "A")
        store.add(ids: ["p1"], to: album)

        store.remove(try XCTUnwrap(album.orderedLinks.first))

        XCTAssertEqual(count(Photo.self), 0)
        XCTAssertEqual(count(AlbumPhoto.self), 0)
        XCTAssertEqual(count(Album.self), 1)
    }

    func testDeleteAlbumKeepsPhotosUsedElsewhere() {
        let trip = store.createAlbum(title: "제주 가족여행")
        let year = store.createAlbum(title: "2021년")
        store.add(ids: ["p1", "p2"], to: trip)
        store.add(ids: ["p1"], to: year)

        store.delete(trip)

        XCTAssertEqual(count(Album.self), 1)
        XCTAssertEqual(ids(year), ["p1"])
        XCTAssertEqual(count(Photo.self), 1, "다른 앨범에 없는 p2만 사라진다")
        XCTAssertEqual(count(AlbumPhoto.self), 1)
    }

    func testSetAlbumsAddsAndRemovesMemberships() throws {
        let a = store.createAlbum(title: "A")
        let b = store.createAlbum(title: "B")
        let c = store.createAlbum(title: "C")
        store.add(ids: ["p1", "p2"], to: a)
        store.add(ids: ["p1"], to: b)
        let photo = try XCTUnwrap(a.orderedLinks.first?.photo)

        store.setAlbums([b, c], for: photo)

        XCTAssertEqual(ids(a), ["p2"])
        XCTAssertEqual(ids(b), ["p1"])
        XCTAssertEqual(ids(c), ["p1"])
        XCTAssertEqual(count(AlbumPhoto.self), 3)
    }

    func testMoveReordersWithinOneAlbumOnly() throws {
        let a = store.createAlbum(title: "A")
        let b = store.createAlbum(title: "B")
        store.add(ids: ["p1", "p2", "p3"], to: a)
        store.add(ids: ["p1", "p2", "p3"], to: b)

        store.move(try XCTUnwrap(a.orderedLinks.first), by: 2)
        XCTAssertEqual(ids(a), ["p2", "p3", "p1"])
        XCTAssertEqual(ids(b), ["p1", "p2", "p3"], "순서는 앨범마다 따로다")

        store.move(try XCTUnwrap(a.orderedLinks.last), by: 5)
        XCTAssertEqual(ids(a), ["p2", "p3", "p1"], "끝을 넘어가지 않는다")
    }

    func testCoverFallsBackWhenCoverPhotoIsRemoved() throws {
        let album = store.createAlbum(title: "A")
        store.add(ids: ["p1", "p2"], to: album)
        let second = try XCTUnwrap(album.orderedLinks.last)

        store.setCover(album, to: second.photo)
        XCTAssertEqual(album.coverIdentifier, "p2")

        store.remove(second)
        XCTAssertEqual(album.coverIdentifier, "p1")
    }

    func testRemovedPhotoCanBeRestoredToSamePlace() throws {
        let album = store.createAlbum(title: "A")
        store.add(ids: ["p1", "p2", "p3"], to: album)
        let middle = try XCTUnwrap(album.orderedLinks.dropFirst().first)
        store.setCover(album, to: middle.photo)

        let removed = try XCTUnwrap(store.remove(middle))
        XCTAssertEqual(ids(album), ["p1", "p3"])
        XCTAssertEqual(count(Photo.self), 2)

        XCTAssertNotNil(store.restore(removed, to: album))
        XCTAssertEqual(ids(album), ["p1", "p2", "p3"])
        XCTAssertEqual(album.coverIdentifier, "p2", "표지였던 사진은 표지로 돌아온다")
        XCTAssertEqual(count(Photo.self), 3)

        XCTAssertNil(store.restore(removed, to: album), "이미 들어 있으면 다시 넣지 않는다")
        XCTAssertEqual(count(AlbumPhoto.self), 3)
    }
}
