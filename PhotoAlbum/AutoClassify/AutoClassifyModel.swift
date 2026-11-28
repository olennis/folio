import CoreLocation
import Photos
import SwiftData
import SwiftUI

/// 정리 탭의 "자동 분류". 보관함을 훑어 제안을 만들고, 장면 분석을 뒤에서 이어 간다.
@MainActor
final class AutoClassifyModel: ObservableObject {
    static let shared = AutoClassifyModel()

    @Published private(set) var suggestions: [AutoSuggestion] = []
    /// 장면 분석 진행: 본 수와 전체 수. 분석 중이 아니면 nil.
    @Published private(set) var sceneProgress: (done: Int, total: Int)?
    @Published private(set) var isRefreshing = false

    private var sceneTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private static let dismissedKey = "autoClassify.dismissed"
    /// 지명을 한 번 붙인 여행은 다시 묻지 않는다.
    private var placeNames: [String: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var dismissed: Set<String> {
        Set(defaults.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    private var thresholds: AutoClassifier.Thresholds {
        var value = AutoClassifier.Thresholds()
        #if DEBUG
        // 캡처와 UI 테스트용: 시뮬레이터의 사진 몇 장으로도 제안이 나오게 한다(`-autoMinimum 1`).
        let minimum = defaults.integer(forKey: "autoMinimum")
        if minimum > 0 {
            value.yearMinimum = minimum
            value.tripMinimum = minimum
            value.sceneMinimum = minimum
            value.personMinimum = minimum
        }
        #endif
        return value
    }

    /// 제안을 다시 구한다. 보관함과 앨범을 백그라운드에서 읽는다.
    func refresh(container: ModelContainer) {
        refreshTask?.cancel()
        isRefreshing = true
        let dismissed = dismissed
        let thresholds = thresholds
        // 인물은 켜 둔 Pro 사용자만. 얼굴 저장소는 앨범 저장소와 따로 있다.
        let people = ProStore.shared.isPro && PeopleSettings.isEnabled ? PeopleIndexer.shared.container : nil
        refreshTask = Task {
            let found = await Self.compute(container: container, people: people, dismissed: dismissed, thresholds: thresholds)
            guard !Task.isCancelled else { return }
            // 카드는 바로 보여 주고, 여행 지명은 네트워크로 받아 오는 대로 고친다.
            suggestions = withKnownNames(found)
            isRefreshing = false
            let named = await named(found)
            guard !Task.isCancelled else { return }
            suggestions = named
        }
    }

    /// 아직 장면을 안 본 사진을 뒤에서 분석한다. 끝나면 제안을 다시 구한다. Pro에서만 부른다.
    func startSceneAnalysis(container: ModelContainer) {
        guard sceneTask == nil else { return }
        sceneTask = Task {
            let ids = await Task.detached(priority: .utility) { Self.libraryPhotos().map(\.id) }.value
            let pending = await SceneIndex.shared.pending(among: ids)
            guard !pending.isEmpty else {
                sceneTask = nil
                return
            }
            sceneProgress = (0, pending.count)
            var lastRefresh = 0
            await SceneIndex.shared.analyze(pending) { done in
                await MainActor.run {
                    let model = AutoClassifyModel.shared
                    model.sceneProgress = (done, pending.count)
                    // 많이 볼 때는 중간중간 제안을 새로 고친다.
                    if done - lastRefresh >= 500 {
                        lastRefresh = done
                        model.refresh(container: container)
                    }
                }
            }
            sceneProgress = nil
            sceneTask = nil
            refresh(container: container)
        }
    }

    func dismiss(_ suggestion: AutoSuggestion) {
        var set = dismissed
        set.insert(suggestion.id)
        defaults.set(Array(set), forKey: Self.dismissedKey)
        suggestions.removeAll { $0.id == suggestion.id }
    }

    /// 제안을 앨범에 반영한다. 새 앨범이면 만들고, 있는 앨범이면 채운다. 만든·채운 앨범을 돌려준다.
    @discardableResult
    func apply(_ suggestion: AutoSuggestion, title: String, assetIDs: [String], context: ModelContext) -> Album? {
        let store = AlbumStore(context: context)
        let album: Album
        if let id = suggestion.targetAlbumID,
           let existing = try? context.fetch(FetchDescriptor<Album>(predicate: #Predicate { $0.id == id })).first {
            album = existing
        } else {
            album = store.createAlbum(title: title, kind: suggestion.newKind)
        }
        let dates = PhotoLibrary.creationDates(for: assetIDs)
        store.add(assetIDs.map { (id: $0, takenAt: dates[$0]) }, to: album)
        suggestions.removeAll { $0.id == suggestion.id }
        // 인물 앨범 이름은 그 사람의 이름이 된다. 다시 묶어도 이 사람으로 남는다.
        if case .person(let id) = suggestion.source, suggestion.targetAlbumID == nil {
            Task { await PeopleIndexer.shared.rename(id, to: title) }
        }
        Task { await PhotoMetadata.refresh(context: context) }
        return album
    }

    // MARK: 계산

    nonisolated private static func compute(
        container: ModelContainer,
        people peopleContainer: ModelContainer?,
        dismissed: Set<String>,
        thresholds: AutoClassifier.Thresholds
    ) async -> [AutoSuggestion] {
        var photos = await Task.detached(priority: .userInitiated) { libraryPhotos() }.value
        let scenes = await SceneIndex.shared.scenes(for: photos.map(\.id))
        for index in photos.indices {
            if let found = scenes[photos[index].id] { photos[index].scenes = found }
        }
        let snapshot = photos
        return await Task.detached(priority: .userInitiated) {
            let albums = albumSnapshots(ModelContext(container))
            let people = peopleContainer.map { personSnapshots(ModelContext($0)) } ?? []
            return AutoClassifier.suggestions(photos: snapshot, albums: albums, people: people, dismissed: dismissed, thresholds: thresholds)
        }.value
    }

    /// 사진 보관함의 모든 사진. 이미지는 불러오지 않고 날짜와 위치만 읽는다.
    nonisolated static func libraryPhotos() -> [LibraryPhoto] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [] }
        var result: [LibraryPhoto] = []
        PHAsset.fetchAssets(with: .image, options: nil).enumerateObjects { asset, _, _ in
            let coordinate = asset.location?.coordinate
            result.append(LibraryPhoto(
                id: asset.localIdentifier,
                takenAt: asset.creationDate,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude
            ))
        }
        return result
    }

    nonisolated private static func personSnapshots(_ context: ModelContext) -> [PersonSnapshot] {
        ((try? context.fetch(FetchDescriptor<Person>())) ?? []).map {
            PersonSnapshot(id: $0.id, name: $0.name, isHidden: $0.isHidden, assetIDs: $0.assetIDs)
        }
    }

    nonisolated private static func albumSnapshots(_ context: ModelContext) -> [AlbumSnapshot] {
        let albums = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        return albums.map { album in
            AlbumSnapshot(
                id: album.id,
                title: album.title,
                kind: album.kind,
                assetIDs: Set(album.links.compactMap { $0.isDeleted ? nil : $0.photo?.assetIdentifier })
            )
        }
    }

    /// 이미 알아 둔 지명만 붙인다(네트워크를 기다리지 않는다).
    private func withKnownNames(_ found: [AutoSuggestion]) -> [AutoSuggestion] {
        found.map { item in
            var item = item
            if let name = placeNames[item.id] { item.title = "\(name) 여행" }
            return item
        }
    }

    /// 여행 제안에 지명을 붙인다("2024년 7월 여행" → "제주시 여행"). 실패하면 원래 이름을 둔다.
    private func named(_ found: [AutoSuggestion]) async -> [AutoSuggestion] {
        var result = found
        var asked = 0
        for index in result.indices {
            guard case .trip = result[index].source, let center = result[index].center else { continue }
            if placeNames[result[index].id] == nil, asked < 8 {
                asked += 1
                let location = CLLocation(latitude: center.latitude, longitude: center.longitude)
                if let name = await PhotoMetadata.placeName(at: location), !name.isEmpty {
                    placeNames[result[index].id] = name
                }
            }
            if let name = placeNames[result[index].id] { result[index].title = "\(name) 여행" }
        }
        return result
    }
}

extension AutoSuggestion {
    /// 카드와 확인 화면의 설명. "사진 48장 · 2024년 7월 3일–6일" / "‘2015년’에 빠진 사진 12장"
    var detail: String {
        let count = "사진 \(assetIDs.count.formatted())장"
        switch source {
        case .trip(let start, let end):
            let days = start.formatted(.dateTime.year().month().day())
            let last = end.formatted(.dateTime.month().day())
            return Calendar.current.isDate(start, inSameDayAs: end) ? "\(days) · \(count)" : "\(days)–\(last) · \(count)"
        case .year, .scene, .person:
            return targetAlbumID == nil ? "새 앨범 · \(count)" : "‘\(title)’에 빠진 \(count)"
        }
    }

    var reason: String {
        switch source {
        case .year: "같은 해에 찍은 사진"
        case .trip: "집에서 먼 곳에서 며칠 동안 찍은 사진"
        case .scene(let scene): "\(scene.albumTitle) 사진으로 보여요"
        case .person: "같은 사람이 나온 사진"
        }
    }
}
