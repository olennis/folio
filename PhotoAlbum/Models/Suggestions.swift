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

    static func albums(
        for signatures: [PhotoSignature],
        among albums: [Album],
        excluding: Set<UUID> = [],
        calendar: Calendar = .current,
        limit: Int = 3
    ) -> [AlbumSuggestion] {
        let dates = signatures.compactMap(\.takenAt)
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        let years = Set(dates.map { calendar.component(.year, from: $0) })
        let spots: [(Double, Double)] = signatures.compactMap { item in
            guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
            return (latitude, longitude)
        }
        guard !days.isEmpty || !spots.isEmpty else { return [] }

        var scored: [(suggestion: AlbumSuggestion, score: Int, order: Int)] = []
        for (order, album) in albums.enumerated() where !excluding.contains(album.id) {
            var sameDay = false
            var samePlace = false
            for link in album.orderedLinks {
                guard let photo = link.photo else { continue }
                if !sameDay, let takenAt = photo.takenAt, days.contains(calendar.startOfDay(for: takenAt)) {
                    sameDay = true
                }
                if !samePlace, let latitude = photo.latitude, let longitude = photo.longitude {
                    samePlace = spots.contains { abs($0.0 - latitude) < nearby && abs($0.1 - longitude) < nearby }
                }
                if sameDay && samePlace { break }
            }
            let sameYear = album.kind == .year && Album.year(in: album.title).map(years.contains) == true

            let reason: String
            let score: Int
            switch (sameDay, samePlace, sameYear) {
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
}
