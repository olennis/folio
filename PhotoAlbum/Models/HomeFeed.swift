import Foundation

/// 홈에 꺼내 놓을 것을 고른다.
enum HomeFeed {
    /// 몇 년 전 오늘(또는 이맘때) 찍은 사진이 들어 있는 앨범.
    struct Memory: Identifiable {
        let album: Album
        let yearsAgo: Int
        /// 날짜가 정확히 오늘과 같으면 true, 앞뒤 며칠 안이면 false.
        let isExactDay: Bool
        let coverIdentifier: String
        let photoCount: Int
        var id: UUID { album.id }

        var headline: String { isExactDay ? "\(yearsAgo)년 전 오늘" : "\(yearsAgo)년 전 이맘때" }
    }

    /// 오늘과 날짜가 같은 사진이 없으면 앞뒤 이만큼까지 본다.
    static let window = 3

    static func memories(
        in albums: [Album],
        today: Date,
        calendar: Calendar = .current,
        limit: Int = 3
    ) -> [Memory] {
        struct Hit {
            var count = 0
            var cover = ""
        }
        let start = calendar.startOfDay(for: today)
        let thisYear = calendar.component(.year, from: start)
        // [정확히 오늘인가][몇 년 전][앨범 순서] → 맞는 사진
        var hits: [Bool: [Int: [Int: Hit]]] = [true: [:], false: [:]]

        for (order, album) in albums.enumerated() {
            for link in album.orderedLinks {
                guard let photo = link.photo, let takenAt = photo.takenAt else { continue }
                var parts = calendar.dateComponents([.year, .month, .day], from: takenAt)
                guard let year = parts.year, year < thisYear else { continue }
                parts.year = thisYear
                guard let anniversary = calendar.date(from: parts),
                      let gap = calendar.dateComponents([.day], from: start, to: anniversary).day,
                      abs(gap) <= window
                else { continue }
                var hit = hits[gap == 0]?[thisYear - year]?[order] ?? Hit()
                if hit.count == 0 { hit.cover = photo.assetIdentifier }
                hit.count += 1
                hits[gap == 0]?[thisYear - year, default: [:]][order] = hit
            }
        }

        let exact = !(hits[true] ?? [:]).isEmpty
        let chosen = hits[exact] ?? [:]
        var used: Set<Int> = []
        var result: [Memory] = []
        for yearsAgo in chosen.keys.sorted() {
            let candidates = (chosen[yearsAgo] ?? [:]).filter { !used.contains($0.key) }
            guard let best = candidates.max(by: { ($0.value.count, -$0.key) < ($1.value.count, -$1.key) }) else { continue }
            used.insert(best.key)
            result.append(Memory(
                album: albums[best.key],
                yearsAgo: yearsAgo,
                isExactDay: exact,
                coverIdentifier: best.value.cover,
                photoCount: best.value.count
            ))
        }
        return Array(result.prefix(limit))
    }

    /// 자주 여는 인물 앨범. 한 번도 열지 않은 앨범은 빼고 많이 연 순서로.
    static func frequentPeople(in albums: [Album], limit: Int = 3) -> [Album] {
        Array(albums
            .filter { $0.kind == .person && $0.openCount > 0 }
            .sorted { ($0.openCount, $0.lastOpenedAt ?? .distantPast) > ($1.openCount, $1.lastOpenedAt ?? .distantPast) }
            .prefix(limit))
    }

    /// 최근에 연 앨범. 방금 연 것이 먼저.
    static func recent(in albums: [Album], limit: Int = 8) -> [Album] {
        Array(albums
            .filter { $0.lastOpenedAt != nil }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .prefix(limit))
    }
}

/// 오늘 날짜. 캡처와 테스트에서는 실행 인자 `-today 2021-11-13`으로 바꿀 수 있다.
enum AppClock {
    static var today: Date {
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: "today") {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: text) { return date }
        }
        #endif
        return .now
    }
}
