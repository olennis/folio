import Foundation
import SwiftData

/// 모든 사진을 훑어야 할 수 있는 계산은 화면을 멈추지 않도록 따로 만든 저장소 문맥에서 돌린다.
/// 또 앨범의 사진을 하나씩 따라가지 않고, 날짜·위치 조건으로 맞는 사진만 저장소에 물어본다.
/// 앱을 켜고 처음 읽는 사진은 저장소에서 한 장씩 불러와야 해서(3,000장에 약 0.3초) 훑는 방식은 사진이 늘수록 느려진다.
/// 결과는 모델 객체 대신 식별자로 돌려주고, 화면에서 자기 문맥의 앨범과 다시 잇는다.
enum BackgroundQueries {
    struct SuggestionResult: Sendable {
        let albumID: UUID
        let reason: String
    }

    struct MemoryResult: Sendable {
        let albumID: UUID
        let headline: String
        let coverIdentifier: String
    }

    /// 한 번에 물어볼 날짜와 장소의 수. 사진을 아주 많이 골라도 조회가 끝없이 늘지 않게 한다.
    static let maxDays = 30
    static let maxSpots = 20

    static func suggestions(
        container: ModelContainer,
        signatures: [PhotoSignature],
        excluding: Set<UUID>
    ) async -> [SuggestionResult] {
        await Task.detached(priority: .userInitiated) {
            suggestions(in: ModelContext(container), signatures: signatures, excluding: excluding)
        }.value
    }

    static func memories(container: ModelContainer, today: Date) async -> [MemoryResult] {
        await Task.detached(priority: .userInitiated) {
            memories(in: ModelContext(container), today: today)
        }.value
    }

    // MARK: 조회

    static func suggestions(
        in context: ModelContext,
        signatures: [PhotoSignature],
        excluding: Set<UUID>,
        calendar: Calendar = .current
    ) -> [SuggestionResult] {
        let clues = Suggestions.Clues(signatures, calendar: calendar)
        guard !clues.isEmpty else { return [] }
        let none = Date.distantPast
        let nowhere = 999.0
        let near = Suggestions.nearby

        var sameDay: Set<UUID> = []
        for day in clues.days.prefix(maxDays) {
            let start = day.lowerBound
            let end = day.upperBound
            let descriptor = FetchDescriptor<Photo>(predicate: #Predicate {
                ($0.takenAt ?? none) >= start && ($0.takenAt ?? none) < end
            })
            for photo in (try? context.fetch(descriptor)) ?? [] { sameDay.formUnion(albumIDs(of: photo)) }
        }
        var samePlace: Set<UUID> = []
        for spot in clues.spots.prefix(maxSpots) {
            let south = spot.latitude - near
            let north = spot.latitude + near
            let west = spot.longitude - near
            let east = spot.longitude + near
            let descriptor = FetchDescriptor<Photo>(predicate: #Predicate {
                ($0.latitude ?? nowhere) > south && ($0.latitude ?? nowhere) < north
                    && ($0.longitude ?? nowhere) > west && ($0.longitude ?? nowhere) < east
            })
            for photo in (try? context.fetch(descriptor)) ?? [] { samePlace.formUnion(albumIDs(of: photo)) }
        }
        let albums = (try? context.fetch(sortedAlbums)) ?? []
        return Suggestions.rank(albums, sameDay: sameDay, samePlace: samePlace, years: clues.years, excluding: excluding, limit: 3)
            .map { SuggestionResult(albumID: $0.album.id, reason: $0.reason) }
    }

    static func memories(in context: ModelContext, today: Date, calendar: Calendar = .current) -> [MemoryResult] {
        var oldest = FetchDescriptor<Photo>(predicate: #Predicate { $0.takenAt != nil }, sortBy: [SortDescriptor(\.takenAt)])
        oldest.fetchLimit = 1
        guard let earliest = (try? context.fetch(oldest))?.first?.takenAt else { return [] }
        let windows = HomeFeed.windows(today: today, firstYear: calendar.component(.year, from: earliest), calendar: calendar)
        let albums = (try? context.fetch(sortedAlbums)) ?? []
        var order: [UUID: Int] = [:]
        for (index, album) in albums.enumerated() { order[album.id] = index }

        let none = Date.distantPast
        var photos: [HomeFeed.DatedPhoto] = []
        for window in windows {
            let start = window.range.lowerBound
            let end = window.range.upperBound
            let descriptor = FetchDescriptor<Photo>(predicate: #Predicate {
                ($0.takenAt ?? none) >= start && ($0.takenAt ?? none) < end
            })
            for photo in (try? context.fetch(descriptor)) ?? [] {
                guard let takenAt = photo.takenAt else { continue }
                let orders = albumIDs(of: photo).compactMap { order[$0] }
                photos.append(HomeFeed.DatedPhoto(takenAt: takenAt, assetIdentifier: photo.assetIdentifier, albumOrders: orders))
            }
        }
        return HomeFeed.pick(photos, windows: windows, albums: albums)
            .map { MemoryResult(albumID: $0.album.id, headline: $0.headline, coverIdentifier: $0.coverIdentifier) }
    }

    private static func albumIDs(of photo: Photo) -> [UUID] {
        photo.links.compactMap { $0.isDeleted ? nil : $0.album?.id }
    }

    private static var sortedAlbums: FetchDescriptor<Album> {
        FetchDescriptor<Album>(sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.createdAt, order: .reverse)])
    }
}
