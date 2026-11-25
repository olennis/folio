import Foundation

/// 추천을 고를 때 보는 사진 한 장의 단서: 언제, 어디서 찍었나.
struct PhotoSignature: Equatable {
    var takenAt: Date?
    var latitude: Double?
    var longitude: Double?

    init(takenAt: Date? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.takenAt = takenAt
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ photo: Photo) {
        self.init(takenAt: photo.takenAt, latitude: photo.latitude, longitude: photo.longitude)
    }
}

struct AlbumSuggestion: Identifiable {
    let album: Album
    let reason: String
    var id: UUID { album.id }
}

/// 사진을 넣을 만한 앨범을 고른다. 이미 그 앨범에 있는 사진과 날짜·장소가 겹치는지를 본다.
enum Suggestions {
    /// 위도·경도 차이가 이 안이면 같은 곳으로 본다(약 5km).
    static let nearby = 0.05

    /// 넣으려는 사진들의 단서: 찍은 날(하루 구간), 찍은 연도, 찍은 곳.
    struct Clues {
        let days: [Range<Date>]
        let years: Set<Int>
        let spots: [(latitude: Double, longitude: Double)]

        var isEmpty: Bool { days.isEmpty && spots.isEmpty }

        init(_ signatures: [PhotoSignature], calendar: Calendar = .current) {
            let dates = signatures.compactMap(\.takenAt)
            days = Set(dates.map { calendar.startOfDay(for: $0) }).sorted().compactMap { start in
                calendar.date(byAdding: .day, value: 1, to: start).map { start..<$0 }
            }
            years = Set(dates.map { calendar.component(.year, from: $0) })
            // 가까운 곳은 하나로 친다(격자 한 칸 ≈ 5km).
            var seen: Set<String> = []
            var spots: [(Double, Double)] = []
            for item in signatures {
                guard let latitude = item.latitude, let longitude = item.longitude else { continue }
                let cell = "\(Int((latitude / nearby).rounded())),\(Int((longitude / nearby).rounded()))"
                if seen.insert(cell).inserted { spots.append((latitude, longitude)) }
            }
            self.spots = spots.map { (latitude: $0.0, longitude: $0.1) }
        }
    }

    /// 앨범을 직접 훑어 구한다. 테스트와 작은 데이터용. 앱은 `BackgroundQueries`가 조건 조회로 구한다.
    static func albums(
        for signatures: [PhotoSignature],
        among albums: [Album],
        excluding: Set<UUID> = [],
        calendar: Calendar = .current,
        limit: Int = 3
    ) -> [AlbumSuggestion] {
        let clues = Clues(signatures, calendar: calendar)
        guard !clues.isEmpty else { return [] }
        var sameDay: Set<UUID> = []
        var samePlace: Set<UUID> = []
        for album in albums where !excluding.contains(album.id) {
            for link in album.links where !link.isDeleted {
                guard let photo = link.photo else { continue }
                if let takenAt = photo.takenAt, contains(clues.days, takenAt) { sameDay.insert(album.id) }
                if let latitude = photo.latitude, let longitude = photo.longitude, isNear(clues, latitude, longitude) {
                    samePlace.insert(album.id)
                }
                if sameDay.contains(album.id) && samePlace.contains(album.id) { break }
            }
        }
        return rank(albums, sameDay: sameDay, samePlace: samePlace, years: clues.years, excluding: excluding, limit: limit)
    }

    static func isNear(_ clues: Clues, _ latitude: Double, _ longitude: Double) -> Bool {
        clues.spots.contains { abs($0.latitude - latitude) < nearby && abs($0.longitude - longitude) < nearby }
    }

    /// 겹치는 단서가 많은 앨범부터. 같으면 보관함 순서대로. 비밀 앨범은 추천하지 않는다.
    static func rank(
        _ albums: [Album],
        sameDay: Set<UUID>,
        samePlace: Set<UUID>,
        years: Set<Int>,
        excluding: Set<UUID>,
        limit: Int
    ) -> [AlbumSuggestion] {
        var scored: [(suggestion: AlbumSuggestion, score: Int, order: Int)] = []
        for (order, album) in albums.enumerated() where !excluding.contains(album.id) && !album.isLocked {
            let day = sameDay.contains(album.id)
            let place = samePlace.contains(album.id)
            let year = album.kind == .year && Album.year(in: album.title).map(years.contains) == true
            let reason: String
            let score: Int
            switch (day, place, year) {
            case (true, true, _): (reason, score) = ("촬영 날짜와 장소가 같아요", 4)
            case (true, false, _): (reason, score) = ("촬영 날짜가 같아요", 3)
            case (false, true, _): (reason, score) = ("촬영 장소가 가까워요", 2)
            case (false, false, true): (reason, score) = ("촬영 연도가 같아요", 1)
            default: continue
            }
            scored.append((AlbumSuggestion(album: album, reason: reason), score, order))
        }
        return scored
            .sorted { ($0.score, -$0.order) > ($1.score, -$1.order) }
            .prefix(limit)
            .map(\.suggestion)
    }

    /// 시작 순으로 정렬된 겹치지 않는 구간 가운데 `date`가 든 것이 있는지 이분 탐색으로 찾는다.
    static func contains(_ ranges: [Range<Date>], _ date: Date) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].upperBound <= date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < ranges.count && ranges[low].contains(date)
    }
}
