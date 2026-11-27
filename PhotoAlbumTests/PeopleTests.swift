import CoreGraphics
import SwiftData
import XCTest
@testable import PhotoAlbum

/// 사람 묶기·저장소·분석 흐름. 얼굴 찾기와 임베딩은 가짜 부품으로 바꿔 시뮬레이터에서도 돈다.
final class PeopleTests: XCTestCase {
    /// 사람마다 다른 방향의 단위 벡터 근처에 흩뿌린 가짜 임베딩. 같은 사람끼리는 0.3 안, 다른 사람과는 1 이상.
    static func embedding(person: Int, jitter: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 128)
        v[person] = 1
        var rng = SplitMix64(seed: UInt64(person * 1000 + jitter))
        for i in 0..<128 { v[i] += Float(Double(rng.next() % 1000) / 1000 - 0.5) * 0.04 }
        return v
    }

    // MARK: 묶기

    func testChineseWhispersSeparatesPeople() {
        var vectors: [[Float]] = [], truth: [Int] = []
        for person in 0..<5 {
            for j in 0..<8 { vectors.append(Self.embedding(person: person, jitter: j)); truth.append(person) }
        }
        let labels = ChineseWhispersClusterer().cluster(vectors)
        let metrics = ClusterMetrics.pairwise(predicted: labels, truth: truth)
        XCTAssertEqual(metrics.precision, 1)
        XCTAssertEqual(metrics.recall, 1)
        // 같은 입력이면 같은 결과.
        XCTAssertEqual(labels, ChineseWhispersClusterer().cluster(vectors))
    }

    func testAnchorsKeepLabelsAndForbiddenLabelIsNeverTaken() {
        let vectors = (0..<6).map { Self.embedding(person: 0, jitter: $0) }
        // 0번은 사람 7로 고정, 5번은 사람 7이 될 수 없다.
        let labels = ChineseWhispersClusterer().cluster(vectors, anchors: [0: 7], forbidden: [5: [7]])
        XCTAssertEqual(labels[0], 7)
        XCTAssertEqual(labels[1], 7, "고정점 주변의 같은 사람은 그 사람을 따른다")
        XCTAssertNotEqual(labels[5], 7, "'이 사람 아님'으로 뺀 얼굴은 그 사람이 되지 않는다")
    }

    func testThresholdIsConfigurable() {
        let a = Self.embedding(person: 0, jitter: 0)
        var b = a
        b[1] += 0.5 // 거리 0.5
        XCTAssertEqual(Set(ChineseWhispersClusterer(threshold: 0.6).cluster([a, b])).count, 1)
        XCTAssertEqual(Set(ChineseWhispersClusterer(threshold: 0.4).cluster([a, b])).count, 2)
    }

    // MARK: 저장소

    private func makeStore() throws -> (FaceStore, ModelContainer) {
        let container = try FaceStoreContainer.make(inMemory: true)
        return (FaceStore(modelContainer: container), container)
    }

    private func add(_ store: FaceStore, person: Int, count: Int, prefix: String) async {
        for j in 0..<count {
            await store.add(assetID: "\(prefix)-\(j)", faces: [(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), Self.embedding(person: person, jitter: j), 0.5)],
                            clusterer: ChineseWhispersClusterer())
        }
        await store.save()
    }

    @MainActor
    private func people(_ container: ModelContainer) -> [Person] {
        let context = ModelContext(container)
        return ((try? context.fetch(FetchDescriptor<Person>())) ?? []).sorted { $0.faces.count > $1.faces.count }
    }

    @MainActor
    func testReclusterMakesPeopleAndNewFacesJoinIncrementally() async throws {
        let (store, container) = try makeStore()
        await add(store, person: 0, count: 5, prefix: "a")
        await add(store, person: 1, count: 3, prefix: "b")
        await add(store, person: 2, count: 1, prefix: "c") // 한 장뿐이라 사람으로 만들지 않는다
        await store.recluster(using: ChineseWhispersClusterer())
        var found = people(container)
        XCTAssertEqual(found.map(\.faces.count), [5, 3])
        XCTAssertEqual(found[0].assetIDs.count, 5)
        XCTAssertNotNil(found[0].representativeFace)

        // 새 사진은 다시 묶지 않아도 가장 가까운 사람에게 바로 붙는다.
        await add(store, person: 1, count: 2, prefix: "b2")
        found = people(container)
        XCTAssertEqual(found.map(\.faces.count).sorted(), [5, 5])
        let unassigned = await store.unassignedCount()
        XCTAssertEqual(unassigned, 1)
    }

    @MainActor
    func testNameSurvivesReclusterAndMergeAndExclude() async throws {
        let (store, container) = try makeStore()
        await add(store, person: 0, count: 4, prefix: "a")
        await add(store, person: 1, count: 4, prefix: "b")
        await store.recluster(using: ChineseWhispersClusterer())
        var found = people(container)
        let first = found[0].id, second = found[1].id

        await store.rename(first, to: "  서윤  ")
        await store.recluster(using: ChineseWhispersClusterer())
        found = people(container)
        XCTAssertEqual(found.first { $0.id == first }?.name, "서윤", "이름 붙인 사람은 다시 묶어도 그대로")
        XCTAssertTrue(found.first { $0.id == first }?.isConfirmed ?? false)

        // 두 사람 합치기.
        await store.merge(second, into: first)
        found = people(container)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].faces.count, 8)

        // 이 사람 아님: 뺀 얼굴은 다시 묶어도 그 사람에게 돌아오지 않는다.
        let wrong = Set(found[0].faces.prefix(2).map(\.id))
        await store.exclude(faceIDs: wrong, from: first)
        await store.recluster(using: ChineseWhispersClusterer())
        found = people(container)
        let person = try XCTUnwrap(found.first { $0.id == first })
        XCTAssertTrue(person.faces.allSatisfy { !wrong.contains($0.id) })
        XCTAssertEqual(person.faces.count, 6)
    }

    @MainActor
    func testHideAndRemoveDeletedPhotos() async throws {
        let (store, container) = try makeStore()
        await add(store, person: 0, count: 3, prefix: "a")
        await store.recluster(using: ChineseWhispersClusterer())
        let id = try XCTUnwrap(people(container).first?.id)
        await store.setHidden(id, true)
        XCTAssertTrue(people(container).first?.isHidden ?? false)

        await store.remove(assetIDs: ["a-0", "a-1", "a-2"])
        XCTAssertTrue(people(container).isEmpty, "사진이 모두 지워지면 사람도 사라진다")
        let indexed = await store.indexedAssetIDs()
        XCTAssertTrue(indexed.isEmpty)
    }

    // MARK: 분석 흐름

    private struct FakeSource: FacePhotoSource {
        let ids: [String]
        func assetIDs() -> [String] { ids }
        func image(for assetID: String, allowNetwork: Bool) -> CGImage? {
            // 사진 ID를 1x1 이미지의 빨강 값에 담는다. 가짜 검출기가 다시 읽는다.
            var pixel: [UInt8] = [UInt8(ids.firstIndex(of: assetID) ?? 0), 0, 0, 255]
            return RGBImage(width: 1, height: 1, pixels: pixel).cgImage()
                ?? { pixel.removeAll(); return nil }()
        }
    }

    /// 사진 번호를 보고 "사람 = 번호 % 3" 얼굴 하나를 내준다.
    private struct FakeDetector: FaceDetecting {
        func detect(in image: CGImage) throws -> [DetectedFace] {
            [DetectedFace(box: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: FaceGeometry.chipPoints(), quality: 0.9)]
        }
    }

    private struct FakeAligner: FaceAligning {
        func chip(from image: RGBImage, landmarks: [CGPoint]) -> RGBImage? { image }
    }

    private struct FakeEmbedder: FaceEmbedder {
        func embeddings(for chips: [RGBImage]) throws -> [[Float]] {
            chips.map { chip in
                let index = Int(chip.pixels[0])
                return PeopleTests.embedding(person: index % 3, jitter: index)
            }
        }
    }

    func testIndexingResumesWithoutRedoingPhotosAndDropsDeletedOnes() async throws {
        let (store, container) = try makeStore()
        let pipeline = FacePipeline(detector: FakeDetector(), aligner: FakeAligner(), embedder: FakeEmbedder())
        let ids = (0..<30).map { "photo-\($0)" }

        // 첫 실행: 사진 30장, 사람 3명.
        await PeopleIndexer.run(store: store, source: FakeSource(ids: ids), pipeline: pipeline, clusterer: ChineseWhispersClusterer(),
                                reclusterEvery: 10, allowNetwork: false) { _, _ in }
        var indexed = await store.indexedAssetIDs()
        XCTAssertEqual(indexed.count, 30)
        let counts = await MainActor.run { people(container).map(\.faces.count) }
        XCTAssertEqual(counts, [10, 10, 10])

        // 다시 돌리면 볼 사진이 없다(진행 0/0).
        let seen = ProgressBox()
        await PeopleIndexer.run(store: store, source: FakeSource(ids: ids), pipeline: pipeline, clusterer: ChineseWhispersClusterer(),
                                reclusterEvery: 10, allowNetwork: false) { done, total in await seen.record(done, total) }
        let first = await seen.values.first
        XCTAssertEqual(first?.1, 0)

        // 사진 3장이 지워지고 2장이 늘면 그만큼만 바뀐다.
        let changed = Array(ids.dropFirst(3)) + ["photo-new-0", "photo-new-1"]
        let seen2 = ProgressBox()
        await PeopleIndexer.run(store: store, source: FakeSource(ids: changed), pipeline: pipeline, clusterer: ChineseWhispersClusterer(),
                                reclusterEvery: 10, allowNetwork: false) { done, total in await seen2.record(done, total) }
        let total = await seen2.values.first?.1
        XCTAssertEqual(total, 2, "새 사진 2장만 본다")
        indexed = await store.indexedAssetIDs()
        XCTAssertEqual(indexed, Set(changed))
    }

    func testCancelledIndexingResumesWhereItStopped() async throws {
        let (store, _) = try makeStore()
        let pipeline = FacePipeline(detector: FakeDetector(), aligner: FakeAligner(), embedder: FakeEmbedder())
        let ids = (0..<60).map { "photo-\($0)" }
        let task = Task {
            await PeopleIndexer.run(store: store, source: FakeSource(ids: ids), pipeline: pipeline, clusterer: ChineseWhispersClusterer(),
                                    reclusterEvery: 1000, allowNetwork: false, batch: 10) { done, _ in
                if done >= 20 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await task.value
        let partial = await store.indexedAssetIDs().count
        XCTAssertGreaterThanOrEqual(partial, 20)
        XCTAssertLessThan(partial, 60, "멈춘 곳까지만 기록한다")

        let seen = ProgressBox()
        await PeopleIndexer.run(store: store, source: FakeSource(ids: ids), pipeline: pipeline, clusterer: ChineseWhispersClusterer(),
                                reclusterEvery: 1000, allowNetwork: false) { done, total in await seen.record(done, total) }
        let total = await seen.values.first?.1
        XCTAssertEqual(total, 60 - partial, "남은 사진만 이어서 본다")
        let all = await store.indexedAssetIDs().count
        XCTAssertEqual(all, 60)
    }

    private actor ProgressBox {
        var values: [(Int, Int)] = []
        func record(_ done: Int, _ total: Int) { values.append((done, total)) }
    }
}

/// 자동 분류의 인물 앨범 제안.
final class PersonSuggestionTests: XCTestCase {
    private func photos(_ n: Int) -> [LibraryPhoto] {
        (0..<n).map { LibraryPhoto(id: "p\($0)", takenAt: Date(timeIntervalSince1970: Double(1_700_000_000 - $0 * 3600)), latitude: nil, longitude: nil) }
    }

    func testPersonWithEnoughPhotosIsSuggestedAsNewPersonAlbumInTakenOrder() {
        let ids = (0..<12).map { "p\($0)" }
        let person = PersonSnapshot(id: UUID(), name: nil, isHidden: false, assetIDs: ids)
        let found = AutoClassifier.people([person], photos: photos(12), albums: [], thresholds: .init())
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].newKind, .person)
        XCTAssertEqual(found[0].title, "이름 없는 인물")
        XCTAssertEqual(found[0].assetIDs.first, "p11", "찍은 순서(오래된 사진부터)")
        XCTAssertNil(found[0].targetAlbumID)
    }

    func testFewPhotosHiddenPeopleAndFullAlbumsAreNotSuggested() {
        let few = PersonSnapshot(id: UUID(), name: nil, isHidden: false, assetIDs: ["p0", "p1"])
        let hidden = PersonSnapshot(id: UUID(), name: nil, isHidden: true, assetIDs: (0..<12).map { "p\($0)" })
        XCTAssertTrue(AutoClassifier.people([few, hidden], photos: photos(12), albums: [], thresholds: .init()).isEmpty)

        // 같은 이름의 인물 앨범이 있으면 빠진 사진만 채운다. 다 들어 있으면 제안하지 않는다.
        let named = PersonSnapshot(id: UUID(), name: "서윤", isHidden: false, assetIDs: ["p0", "p1", "p2"])
        let album = AlbumSnapshot(id: UUID(), title: "서윤", kind: .person, assetIDs: ["p0"])
        let fill = AutoClassifier.people([named], photos: photos(3), albums: [album], thresholds: .init())
        XCTAssertEqual(fill.first?.targetAlbumID, album.id)
        XCTAssertEqual(Set(fill.first?.assetIDs ?? []), ["p1", "p2"])
        let full = AlbumSnapshot(id: UUID(), title: "서윤", kind: .person, assetIDs: ["p0", "p1", "p2"])
        XCTAssertTrue(AutoClassifier.people([named], photos: photos(3), albums: [full], thresholds: .init()).isEmpty)
    }
}
