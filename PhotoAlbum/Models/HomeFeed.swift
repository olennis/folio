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

    /// 지난 어느 해의 "그날" 앞뒤 며칠.
    struct Window {
        let range: Range<Date>
        let exactDay: Range<Date>
        let yearsAgo: Int
    }

    /// 촬영 날짜가 있는 사진 한 장과, 그 사진이 든 앨범들의 순서(앨범 목록에서의 자리).
    struct DatedPhoto {
        let takenAt: Date
        let assetIdentifier: String
        let albumOrders: [Int]
    }

    /// `firstYear`부터 작년까지, 해마다 오늘 날짜 앞뒤 `window`일의 구간.
    static func windows(today: Date, firstYear: Int, calendar: Calendar = .current) -> [Window] {
        let start = calendar.startOfDay(for: today)
        let thisYear = calendar.component(.year, from: start)
        let month = calendar.component(.month, from: start)
        let dayOfMonth = calendar.component(.day, from: start)
        var result: [Window] = []
        for year in max(firstYear, thisYear - 200)..<max(thisYear, firstYear) {
            guard let anniversary = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)),
                  let from = calendar.date(byAdding: .day, value: -window, to: anniversary),
                  let to = calendar.date(byAdding: .day, value: window + 1, to: anniversary),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: anniversary)
            else { continue }
            result.append(Window(range: from..<to, exactDay: anniversary..<nextDay, yearsAgo: thisYear - year))
        }
        return result
    }

    /// 앨범을 직접 훑어 구한다. 테스트와 작은 데이터용. 앱은 `BackgroundQueries`가 조건 조회로 구한다.
    static func memories(
        in albums: [Album],
        today: Date,
        calendar: Calendar = .current,
        limit: Int = 3
    ) -> [Memory] {
        var byAsset: [String: (takenAt: Date, orders: [Int])] = [:]
        for (order, album) in albums.enumerated() where !album.isLocked {
            for link in album.links where !link.isDeleted {
                guard let photo = link.photo, let takenAt = photo.takenAt else { continue }
                byAsset[photo.assetIdentifier, default: (takenAt, [])].orders.append(order)
            }
        }
        guard let earliest = byAsset.values.map(\.takenAt).min() else { return [] }
        let windows = windows(today: today, firstYear: calendar.component(.year, from: earliest), calendar: calendar)
        let photos = byAsset.map { DatedPhoto(takenAt: $0.value.takenAt, assetIdentifier: $0.key, albumOrders: $0.value.orders) }
        return pick(photos, windows: windows, albums: albums, limit: limit)
    }

    /// 구간에 든 사진을 앨범별로 모아, 해마다 사진이 가장 많은 앨범을 하나씩 고른다.
    /// 정확히 오늘 날짜인 사진이 하나라도 있으면 그것만 보고, 없으면 앞뒤 며칠을 본다.
    static func pick(_ photos: [DatedPhoto], windows: [Window], albums: [Album], limit: Int = 3) -> [Memory] {
        struct Hit {
            var count = 0
            var cover = ""
            var coverDate = Date.distantFuture
        }
        let ranges = windows.map(\.range)
        // [정확히 오늘인가][몇 년 전][앨범 순서] → 맞는 사진
        var hits: [Bool: [Int: [Int: Hit]]] = [true: [:], false: [:]]
        for photo in photos {
            guard let index = window(containing: photo.takenAt, in: ranges) else { continue }
            let found = windows[index]
            let isExact = found.exactDay.contains(photo.takenAt)
            for order in photo.albumOrders where albums.indices.contains(order) {
                var hit = hits[isExact]?[found.yearsAgo]?[order] ?? Hit()
                // 표지는 그 구간에서 가장 먼저 찍은 사진(같으면 식별자 순). 늘 같은 사진이 골라진다.
                if (photo.takenAt, photo.assetIdentifier) < (hit.coverDate, hit.cover) || hit.count == 0 {
                    hit.cover = photo.assetIdentifier
                    hit.coverDate = photo.takenAt
                }
                hit.count += 1
                hits[isExact]?[found.yearsAgo, default: [:]][order] = hit
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

    private static func window(containing date: Date, in ranges: [Range<Date>]) -> Int? {
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
        return low < ranges.count && ranges[low].contains(date) ? low : nil
    }

    /// 자주 여는 인물 앨범. 한 번도 열지 않은 앨범과 비밀 앨범은 빼고 많이 연 순서로.
    static func frequentPeople(in albums: [Album], limit: Int = 3) -> [Album] {
        Array(albums
            .filter { $0.kind == .person && $0.openCount > 0 && !$0.isLocked }
            .sorted { ($0.openCount, $0.lastOpenedAt ?? .distantPast) > ($1.openCount, $1.lastOpenedAt ?? .distantPast) }
            .prefix(limit))
    }

    /// 최근에 연 앨범. 방금 연 것이 먼저. 비밀 앨범은 빼고.
    static func recent(in albums: [Album], limit: Int = 8) -> [Album] {
        Array(albums
            .filter { $0.lastOpenedAt != nil && !$0.isLocked }
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
