import Foundation

/// 사진 보관함의 사진 한 장에 대해 자동 분류가 보는 단서.
struct LibraryPhoto: Sendable, Equatable {
    let id: String
    let takenAt: Date?
    let latitude: Double?
    let longitude: Double?
    var scenes: Set<SceneCategory> = []
}

/// 자동 분류가 알아보는 장면. Apple Vision 장면 분류(`VNClassifyImageRequest`)의 이름을 묶는다.
enum SceneCategory: String, CaseIterable, Codable, Sendable {
    case pets, food, beach, mountain

    /// 새로 만들 앨범의 이름. 같은 이름의 앨범이 이미 있으면 거기에 채운다.
    var albumTitle: String {
        switch self {
        case .pets: "반려동물"
        case .food: "음식"
        case .beach: "바다"
        case .mountain: "산"
        }
    }

    var symbol: String {
        switch self {
        case .pets: "pawprint.fill"
        case .food: "fork.knife"
        case .beach: "water.waves"
        case .mountain: "mountain.2.fill"
        }
    }

    /// Vision 분류 이름 → 장면. 이름은 `VNClassifyImageRequest.supportedIdentifiers()`(revision 2)에서 확인했다.
    static let identifiers: [String: SceneCategory] = [
        "dog": .pets, "cat": .pets, "adult_cat": .pets, "kitten": .pets, "bulldog": .pets, "sheepdog": .pets,
        "food": .food, "dessert": .food, "frozen_dessert": .food, "cake": .food, "birthday_cake": .food,
        "cupcake": .food, "cheesecake": .food, "pancake": .food, "seafood": .food,
        "beach": .beach, "ocean": .beach, "shore": .beach,
        "mountain": .mountain, "hill": .mountain,
    ]

    /// 이 정도 확신이 있어야 장면으로 친다. 틀린 사진이 앨범에 들어가는 것이 빠지는 것보다 나쁘다.
    static let minimumConfidence: Float = 0.6

    static func categories(from observations: [(identifier: String, confidence: Float)]) -> Set<SceneCategory> {
        Set(observations.compactMap { $0.confidence >= minimumConfidence ? identifiers[$0.identifier] : nil })
    }
}

/// 자동 분류가 보는 사람 한 명의 요약(얼굴로 찾은 사람).
struct PersonSnapshot: Sendable, Equatable {
    let id: UUID
    let name: String?
    let isHidden: Bool
    let assetIDs: [String]
}

/// 자동 분류가 보는 앨범 한 개의 요약. 모델 객체 대신 값으로 넘겨 백그라운드에서 쓴다.
struct AlbumSnapshot: Sendable, Equatable {
    let id: UUID
    let title: String
    let kind: AlbumKind
    let assetIDs: Set<String>
}

struct Coordinate: Sendable, Equatable {
    let latitude: Double
    let longitude: Double

    /// 두 지점 사이 거리(km). 구면 위 대원 거리.
    func distance(to other: Coordinate) -> Double {
        let radius = 6371.0
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(other.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// 자동 분류 제안 하나: 사진 몇 장을 새 앨범으로 만들거나, 이미 있는 앨범에 채우자는 것.
struct AutoSuggestion: Identifiable, Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case year(Int)
        case trip(start: Date, end: Date)
        case scene(SceneCategory)
        case person(UUID)
    }

    /// 같은 묶음이면 다시 계산해도 같은 값. 숨긴 제안을 기억하는 데 쓴다.
    let id: String
    let source: Source
    /// 만들 앨범 이름, 또는 채울 앨범의 이름.
    var title: String
    /// 넣을 사진. 채울 앨범에 이미 든 사진은 뺐다. 찍은 순서.
    let assetIDs: [String]
    /// 채울 앨범. nil이면 새로 만든다.
    let targetAlbumID: UUID?
    let newKind: AlbumKind
    /// 여행의 가운데 지점. 지명을 붙이는 데 쓴다.
    let center: Coordinate?

    var symbol: String {
        switch source {
        case .year: "calendar"
        case .trip: "airplane"
        case .scene(let scene): scene.symbol
        case .person: "person.crop.circle"
        }
    }
}

/// 사진 보관함을 연도·여행·장면으로 묶어 앨범을 제안한다. 상태 없는 계산이라 어느 스레드에서 불러도 된다.
enum AutoClassifier {
    struct Thresholds: Sendable {
        /// 새 연도 앨범을 제안할 최소 사진 수. 이미 있는 연도 앨범을 채울 때는 한 장이라도 제안한다.
        var yearMinimum = 10
        var tripMinimum = 12
        var sceneMinimum = 8
        /// 새 인물 앨범을 제안할 최소 사진 수.
        var personMinimum = 10
        /// 이보다 오래 사진이 끊기면 다른 묶음으로 본다.
        var tripGap: TimeInterval = 48 * 3600
        var tripMaxDays = 30.0
        /// 집(가장 많이 찍은 곳)에서 이만큼 떨어져야 여행으로 본다.
        var awayKilometers = 30.0
        /// 이미 한 앨범에 이만큼 들어 있는 여행은 정리된 것으로 보고 제안하지 않는다.
        var alreadyOrganizedShare = 0.8
    }

    static func suggestions(
        photos: [LibraryPhoto],
        albums: [AlbumSnapshot],
        people: [PersonSnapshot] = [],
        dismissed: Set<String> = [],
        thresholds: Thresholds = Thresholds(),
        calendar: Calendar = .current
    ) -> [AutoSuggestion] {
        let dated = photos.filter { $0.takenAt != nil }.sorted { $0.takenAt! < $1.takenAt! }
        let all = trips(dated, albums: albums, thresholds: thresholds, calendar: calendar)
            + years(dated, albums: albums, thresholds: thresholds, calendar: calendar)
            + scenes(dated, albums: albums, thresholds: thresholds)
            + Self.people(people, photos: photos, albums: albums, thresholds: thresholds)
        return all.filter { !dismissed.contains($0.id) }
    }

    // MARK: 연도

    static func years(
        _ dated: [LibraryPhoto],
        albums: [AlbumSnapshot],
        thresholds: Thresholds,
        calendar: Calendar
    ) -> [AutoSuggestion] {
        var byYear: [Int: [String]] = [:]
        for photo in dated {
            byYear[calendar.component(.year, from: photo.takenAt!), default: []].append(photo.id)
        }
        var result: [AutoSuggestion] = []
        for year in byYear.keys.sorted(by: >) {
            let ids = byYear[year] ?? []
            let target = albums.first { $0.kind == .year && Album.year(in: $0.title) == year }
            let missing = ids.filter { !(target?.assetIDs.contains($0) ?? false) }
            let enough = target == nil ? missing.count >= thresholds.yearMinimum : !missing.isEmpty
            guard enough else { continue }
            result.append(AutoSuggestion(
                id: "year-\(year)",
                source: .year(year),
                title: target?.title ?? "\(year)년",
                assetIDs: missing,
                targetAlbumID: target?.id,
                newKind: .year,
                center: nil
            ))
        }
        return result
    }

    // MARK: 여행

    static func trips(
        _ dated: [LibraryPhoto],
        albums: [AlbumSnapshot],
        thresholds: Thresholds,
        calendar: Calendar
    ) -> [AutoSuggestion] {
        guard let home = home(of: dated) else { return [] }
        var result: [AutoSuggestion] = []
        let away = runs(dated, gap: thresholds.tripGap).flatMap {
            awayStretches($0, home: home, kilometers: thresholds.awayKilometers)
        }
        for run in away {
            guard run.count >= thresholds.tripMinimum,
                  let start = run.first?.takenAt, let end = run.last?.takenAt,
                  end.timeIntervalSince(start) <= thresholds.tripMaxDays * 86400
            else { continue }
            let spots = run.compactMap { photo -> Coordinate? in
                guard let latitude = photo.latitude, let longitude = photo.longitude else { return nil }
                return Coordinate(latitude: latitude, longitude: longitude)
            }
            // 위치가 있는 사진이 어느 정도 있어야 어디였는지 말할 수 있다.
            guard spots.count >= 3, spots.count * 2 >= run.count else { continue }
            // 평균 좌표는 두 곳을 다녀오면 그 사이 엉뚱한 곳이 된다. 가장 많이 찍은 곳으로 이름을 붙인다.
            guard let center = Self.home(of: run), center.distance(to: home) > thresholds.awayKilometers else { continue }
            let ids = run.map(\.id)
            let organized = albums.contains { album in
                Double(ids.filter(album.assetIDs.contains).count) >= Double(ids.count) * thresholds.alreadyOrganizedShare
            }
            guard !organized else { continue }
            result.append(AutoSuggestion(
                id: "trip-\(Int(start.timeIntervalSince1970))",
                source: .trip(start: start, end: end),
                title: "\(monthTitle(start, calendar: calendar)) 여행",
                assetIDs: ids,
                targetAlbumID: nil,
                newKind: .place,
                center: center
            ))
        }
        return result.reversed()  // 최근 여행이 먼저
    }

    /// 사진이 `gap`보다 오래 끊기는 곳에서 나눈 묶음들.
    static func runs(_ dated: [LibraryPhoto], gap: TimeInterval) -> [[LibraryPhoto]] {
        var result: [[LibraryPhoto]] = []
        var current: [LibraryPhoto] = []
        for photo in dated {
            if let last = current.last?.takenAt, photo.takenAt!.timeIntervalSince(last) > gap {
                result.append(current)
                current = []
            }
            current.append(photo)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 묶음에서 집을 떠나 있던 구간들. 매일 찍는 사람은 여행 앞뒤 일상 사진이 같은 묶음에 붙으므로 집에서 찍은 사진에서 자른다.
    /// 위치 없는 사진은 앞뒤가 모두 먼 곳일 때만 넣는다.
    static func awayStretches(_ run: [LibraryPhoto], home: Coordinate, kilometers: Double) -> [[LibraryPhoto]] {
        var result: [[LibraryPhoto]] = []
        var current: [LibraryPhoto] = []
        var unlocated: [LibraryPhoto] = []
        for photo in run {
            guard let latitude = photo.latitude, let longitude = photo.longitude else {
                if !current.isEmpty { unlocated.append(photo) }
                continue
            }
            if Coordinate(latitude: latitude, longitude: longitude).distance(to: home) > kilometers {
                current += unlocated + [photo]
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
            unlocated = []
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 가장 많이 찍은 곳(약 10km 격자). 위치가 있는 사진이 없으면 nil.
    static func home(of photos: [LibraryPhoto]) -> Coordinate? {
        var cells: [String: (count: Int, latitude: Double, longitude: Double)] = [:]
        for photo in photos {
            guard let latitude = photo.latitude, let longitude = photo.longitude else { continue }
            let key = "\(Int((latitude * 10).rounded())),\(Int((longitude * 10).rounded()))"
            var cell = cells[key] ?? (0, 0, 0)
            cell.count += 1
            cell.latitude += latitude
            cell.longitude += longitude
            cells[key] = cell
        }
        guard let best = cells.values.max(by: { $0.count < $1.count }) else { return nil }
        return Coordinate(latitude: best.latitude / Double(best.count), longitude: best.longitude / Double(best.count))
    }

    /// "2024년 7월"
    static func monthTitle(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return "\(parts.year ?? 0)년 \(parts.month ?? 0)월"
    }

    // MARK: 인물

    /// 같은 사람이 나온 사진을 인물 앨범으로. 이름을 붙인 사람은 같은 이름의 인물 앨범이 있으면 거기에 채운다.
    /// 숨긴 사람은 제안하지 않는다. 사진 순서는 찍은 순서.
    static func people(_ people: [PersonSnapshot], photos: [LibraryPhoto], albums: [AlbumSnapshot], thresholds: Thresholds) -> [AutoSuggestion] {
        let taken = Dictionary(photos.map { ($0.id, $0.takenAt ?? .distantPast) }, uniquingKeysWith: { a, _ in a })
        return people.filter { !$0.isHidden }.compactMap { person in
            let target = person.name.flatMap { name in albums.first { $0.kind == .person && $0.title == name } }
            let missing = person.assetIDs
                .filter { !(target?.assetIDs.contains($0) ?? false) }
                .sorted { (taken[$0] ?? .distantPast) < (taken[$1] ?? .distantPast) }
            let enough = target == nil ? missing.count >= thresholds.personMinimum : !missing.isEmpty
            guard enough else { return nil }
            return AutoSuggestion(
                id: "person-\(person.id.uuidString)",
                source: .person(person.id),
                title: target?.title ?? person.name ?? "이름 없는 인물",
                assetIDs: missing,
                targetAlbumID: target?.id,
                newKind: .person,
                center: nil
            )
        }
        .sorted { $0.assetIDs.count > $1.assetIDs.count }
    }

    // MARK: 장면

    static func scenes(_ dated: [LibraryPhoto], albums: [AlbumSnapshot], thresholds: Thresholds) -> [AutoSuggestion] {
        SceneCategory.allCases.compactMap { scene in
            let ids = dated.filter { $0.scenes.contains(scene) }.map(\.id)
            let target = albums.first { $0.title == scene.albumTitle }
            let missing = ids.filter { !(target?.assetIDs.contains($0) ?? false) }
            let enough = target == nil ? missing.count >= thresholds.sceneMinimum : !missing.isEmpty
            guard enough else { return nil }
            return AutoSuggestion(
                id: "scene-\(scene.rawValue)",
                source: .scene(scene),
                title: target?.title ?? scene.albumTitle,
                assetIDs: missing,
                targetAlbumID: target?.id,
                newKind: .custom,
                center: nil
            )
        }
    }
}
