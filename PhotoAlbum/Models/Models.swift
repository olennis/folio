import Foundation
import SwiftData

/// 기기 사진 보관함의 사진 한 장에 대한 참조. 원본을 복사하지 않고 식별자만 가진다.
@Model
final class Photo {
    /// PhotoKit `PHAsset.localIdentifier`
    @Attribute(.unique) var assetIdentifier: String
    var takenAt: Date?
    var addedAt: Date
    /// 사용자가 붙인 사진 이름. 사진에 붙으므로 어느 앨범에서 보든 같다.
    var title: String?
    var latitude: Double?
    var longitude: Double?
    /// 좌표를 풀어 쓴 지명(예: 제주시).
    var placeName: String?
    /// 사진 보관함에서 위치를 이미 확인했는지.
    var locationChecked: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \AlbumPhoto.photo)
    var links: [AlbumPhoto] = []

    init(assetIdentifier: String, takenAt: Date? = nil, addedAt: Date = .now) {
        self.assetIdentifier = assetIdentifier
        self.takenAt = takenAt
        self.addedAt = addedAt
    }

    /// 이름이 있으면 이름, 없으면 nil.
    var displayTitle: String? {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return title
    }
}

/// 앨범의 종류. 보관함에서 연도·인물·장소로 걸러 볼 때 쓴다.
enum AlbumKind: String, CaseIterable, Identifiable {
    case custom, year, person, place

    var id: String { rawValue }

    var label: String {
        switch self {
        case .custom: "일반"
        case .year: "연도"
        case .person: "인물"
        case .place: "장소"
        }
    }

    var symbol: String {
        switch self {
        case .custom: "rectangle.stack"
        case .year: "calendar"
        case .person: "person.crop.circle"
        case .place: "mappin.and.ellipse"
        }
    }

    /// 이름이 "2015" 또는 "2015년" 꼴이면 연도 앨범으로 본다.
    static func inferred(from title: String) -> AlbumKind {
        Album.year(in: title, exact: true) == nil ? .custom : .year
    }
}

@Model
final class Album {
    var id: UUID
    var title: String
    var createdAt: Date
    /// 보관함 카드 더미에서의 순서. 작을수록 앞.
    var sortIndex: Int
    /// 직접 고른 표지. 없으면 첫 사진을 쓴다.
    var coverAssetIdentifier: String?
    var kindRaw: String = AlbumKind.custom.rawValue
    /// 마지막으로 연 때. 홈의 "최근 본 앨범"에 쓴다.
    var lastOpenedAt: Date?
    /// 연 횟수. 홈의 "자주 보는 인물"에 쓴다.
    var openCount: Int = 0
    /// 사진 수와 첫 사진. 앨범을 그릴 때마다 사진 수천 장을 훑지 않도록 저장해 둔다. -1은 아직 세지 않음.
    var cachedCount: Int = -1
    var cachedFirstAsset: String?
    /// 부제에 쓰는 가장 이른·늦은 촬영일과 가장 많이 붙은 지명. 사진 수와 함께 갱신한다.
    var cachedEarliest: Date?
    var cachedLatest: Date?
    var cachedPlace: String?
    /// 사진 구성이나 순서가 바뀔 때마다 하나씩 오른다. 화면은 이 값이 바뀔 때만 목록을 다시 정렬한다.
    var revision: Int = 0
    /// 비밀 앨범. 열 때 Face ID를 묻고, 홈·추천·미니 바에 나오지 않는다(`SecretLock`).
    var isLocked: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \AlbumPhoto.album)
    var links: [AlbumPhoto] = []

    init(title: String, sortIndex: Int = 0, createdAt: Date = .now) {
        self.id = UUID()
        self.title = title
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }

    /// 이 앨범 안에서의 사진 순서대로 정렬한 연결.
    /// 저장소에 정렬해서 한 번에 물어본다. 연결을 하나씩 따라가면 처음 읽을 때 장마다 따로 불러와 3배쯤 느리다.
    var orderedLinks: [AlbumPhoto] {
        guard let context = modelContext, !isDeleted else { return scannedOrderedLinks }
        let albumID = id
        let descriptor = FetchDescriptor<AlbumPhoto>(
            predicate: #Predicate { $0.album?.id == albumID && $0.photo != nil },
            sortBy: [SortDescriptor(\.position)]
        )
        return (try? context.fetch(descriptor)) ?? scannedOrderedLinks
    }

    /// 저장소 없이 메모리에서 정렬한다. 저장된 속성은 읽을 때마다 비싸므로 한 번씩만 읽어 두고 정렬한다.
    private var scannedOrderedLinks: [AlbumPhoto] {
        var keyed: [(position: Int, link: AlbumPhoto)] = []
        keyed.reserveCapacity(links.count)
        for link in links where !link.isDeleted && link.photo != nil {
            keyed.append((link.position, link))
        }
        keyed.sort { $0.position < $1.position }
        return keyed.map(\.link)
    }

    /// 사진 수. `AlbumStore`가 바꿀 때마다 갱신해 둔 값을 쓴다.
    var photoCount: Int {
        cachedCount >= 0 ? cachedCount : links.reduce(0) { $0 + (!$1.isDeleted && $1.photo != nil ? 1 : 0) }
    }

    /// 직접 고른 표지, 없으면 첫 사진.
    var coverIdentifier: String? {
        coverAssetIdentifier ?? (cachedCount >= 0 ? cachedFirstAsset : orderedLinks.first?.photo?.assetIdentifier)
    }

    /// 사진 수, 첫 사진, 촬영 기간, 대표 지명을 다시 센다.
    /// 앨범의 사진이 바뀌거나 사진의 날짜·지명이 채워질 때 부른다(`AlbumStore`, `PhotoMetadata`).
    func refreshStats() {
        var count = 0
        var first: (position: Int, id: String)?
        var earliest: Date?
        var latest: Date?
        var places: [String: Int] = [:]
        for link in links where !link.isDeleted {
            guard let photo = link.photo else { continue }
            count += 1
            let position = link.position
            if first == nil || position < first!.position { first = (position, photo.assetIdentifier) }
            if let takenAt = photo.takenAt {
                if takenAt < (earliest ?? .distantFuture) { earliest = takenAt }
                if takenAt > (latest ?? .distantPast) { latest = takenAt }
            }
            if let name = photo.placeName, !name.isEmpty { places[name, default: 0] += 1 }
        }
        cachedCount = count
        cachedFirstAsset = first?.id
        cachedEarliest = earliest
        cachedLatest = latest
        cachedPlace = places.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        revision += 1
    }

    var kind: AlbumKind {
        get { AlbumKind(rawValue: kindRaw) ?? .custom }
        set { kindRaw = newValue.rawValue }
    }

    /// 이름에 들어 있는 네 자리 연도. `exact`면 이름 전체가 "2015" 또는 "2015년"일 때만.
    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    static func year(in title: String, exact: Bool = false) -> Int? {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if exact {
            if text.hasSuffix("년") { text.removeLast() }
            guard text.count == 4, text.allSatisfy(Self.isDigit) else { return nil }
        }
        // 숫자가 정확히 네 개 이어진 첫 토막을 연도로 본다.
        let runs = text.split(whereSeparator: { !Self.isDigit($0) })
        guard let run = runs.first(where: { $0.count == 4 }),
              let year = Int(run), (1800...2200).contains(year)
        else { return nil }
        return year
    }

    /// 사진들이 찍힌 기간. 한 달 안이면 "2021년 11월", 한 해 안이면 "2021년", 그 밖에는 "2019–2026".
    func periodText(calendar: Calendar = .current) -> String? {
        let first: Date
        let last: Date
        if cachedCount >= 0 {
            guard let earliest = cachedEarliest, let latest = cachedLatest else { return nil }
            (first, last) = (earliest, latest)
        } else {
            let dates = links.compactMap { $0.isDeleted ? nil : $0.photo?.takenAt }
            guard let earliest = dates.min(), let latest = dates.max() else { return nil }
            (first, last) = (earliest, latest)
        }
        let a = calendar.dateComponents([.year, .month], from: first)
        let b = calendar.dateComponents([.year, .month], from: last)
        guard let startYear = a.year, let endYear = b.year, let month = a.month else { return nil }
        if startYear != endYear { return "\(startYear)–\(endYear)" }
        return a.month == b.month ? "\(startYear)년 \(month)월" : "\(startYear)년"
    }

    /// 사진에 가장 많이 붙은 지명.
    var placeText: String? {
        if cachedCount >= 0 { return cachedPlace }
        var counts: [String: Int] = [:]
        for link in links where !link.isDeleted {
            if let name = link.photo?.placeName, !name.isEmpty { counts[name, default: 0] += 1 }
        }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// "2021년 11월 · 제주시 · 사진 128장"
    var summary: String {
        let parts = [periodText(), placeText, "사진 \(photoCount.formatted())장"]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// 사진과 앨범을 잇는 연결. 한 사진이 여러 앨범에 속할 수 있고, 순서는 앨범마다 따로 가진다.
/// (album, photo) 쌍은 하나만 존재한다 — `AlbumStore`가 보장한다.
@Model
final class AlbumPhoto {
    var id: UUID
    var album: Album?
    var photo: Photo?
    var position: Int
    var addedAt: Date

    init(position: Int, addedAt: Date = .now) {
        self.id = UUID()
        self.position = position
        self.addedAt = addedAt
    }
}

/// 앨범의 정렬된 사진 목록을 앨범이 바뀔 때까지 들고 있는다.
/// 캐러셀을 넘길 때마다 화면이 다시 그려지는데, 그때마다 수천 장을 다시 정렬하지 않게 한다.
final class OrderedLinksCache {
    private var key: (id: PersistentIdentifier, revision: Int)?
    private var value: [AlbumPhoto] = []

    func links(of album: Album) -> [AlbumPhoto] {
        let revision = album.revision
        if let key, key.id == album.persistentModelID, key.revision == revision { return value }
        value = album.orderedLinks
        key = (album.persistentModelID, revision)
        return value
    }
}
