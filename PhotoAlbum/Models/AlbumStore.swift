import Foundation
import SwiftData

/// 앨범에서 뺀 사진 한 장의 기록. 실행 취소에 쓴다.
struct RemovedPhoto: Equatable {
    let token = UUID()
    let albumID: UUID
    let assetIdentifier: String
    let takenAt: Date?
    let position: Int
    let wasCover: Bool
    var title: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var placeName: String? = nil
}

/// 앨범과 사진 연결을 바꾸는 모든 동작. 뷰는 모델을 직접 고치지 않고 여기를 거친다.
@MainActor
struct AlbumStore {
    let context: ModelContext

    static let untitled = "제목 없는 앨범"

    // MARK: 앨범

    @discardableResult
    func createAlbum(title: String, kind: AlbumKind? = nil) -> Album {
        let all = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        let front = (all.map(\.sortIndex).min() ?? 1) - 1
        let album = Album(title: Self.clean(title), sortIndex: front)
        // 종류를 정하지 않았으면 이름으로 짐작한다("2015년" → 연도).
        album.kind = kind ?? AlbumKind.inferred(from: title)
        context.insert(album)
        save()
        return album
    }

    func rename(_ album: Album, to title: String) {
        album.title = Self.clean(title)
        save()
    }

    func setKind(_ album: Album, to kind: AlbumKind) {
        album.kind = kind
        save()
    }

    /// 앨범을 잠그거나 푼다. 잠글 수 있는지(Pro, 기기 암호)는 화면에서 먼저 확인한다.
    func setLocked(_ album: Album, _ locked: Bool) {
        album.isLocked = locked
        save()
    }

    /// 앨범을 열었다고 기록한다.
    func markOpened(_ album: Album, at date: Date = .now) {
        album.lastOpenedAt = date
        album.openCount += 1
        save()
    }

    /// 사진에 이름을 붙인다. 비우면 이름을 지운다.
    func setTitle(_ photo: Photo, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        photo.title = trimmed.isEmpty ? nil : trimmed
        save()
    }

    /// 앨범을 지운다. 사진 원본과 다른 앨범의 연결은 그대로 남는다.
    func delete(_ album: Album) {
        let photos = album.links.compactMap(\.photo)
        for link in album.links { unlink(link) }
        context.delete(album)
        purgeOrphans(photos)
        save()
    }

    // MARK: 앨범 안의 사진

    /// 사진을 앨범 끝에 넣는다. 이미 들어 있는 사진은 건너뛴다.
    @discardableResult
    func add(_ assets: [(id: String, takenAt: Date?)], to album: Album) -> [AlbumPhoto] {
        var present = Set(album.links.compactMap { $0.photo?.assetIdentifier })
        var position = (album.links.map(\.position).max() ?? -1) + 1
        var added: [AlbumPhoto] = []
        // 이미 다른 앨범에 있는 사진은 한 번에 찾아 둔다(사진마다 따로 찾으면 수천 장에서 느리다).
        var existing = photos(for: assets.map(\.id).filter { !present.contains($0) })
        for asset in assets where !present.contains(asset.id) {
            let photo = existing[asset.id] ?? {
                let new = Photo(assetIdentifier: asset.id, takenAt: asset.takenAt)
                context.insert(new)
                existing[asset.id] = new
                return new
            }()
            let link = AlbumPhoto(position: position)
            context.insert(link)
            link.album = album
            link.photo = photo
            present.insert(asset.id)
            position += 1
            added.append(link)
        }
        album.refreshStats()
        save()
        return added
    }

    @discardableResult
    func add(ids: [String], to album: Album) -> [AlbumPhoto] {
        add(ids.map { (id: $0, takenAt: nil) }, to: album)
    }

    /// 사진을 이 앨범에서만 뺀다. 어느 앨범에도 남지 않게 되면 사진 참조도 지운다.
    /// 돌려받은 값을 `restore`에 넘기면 같은 자리로 되돌릴 수 있다.
    @discardableResult
    func remove(_ link: AlbumPhoto) -> RemovedPhoto? {
        let album = link.album
        let photo = link.photo
        var removed: RemovedPhoto?
        if let album, let photo {
            let wasCover = album.coverAssetIdentifier == photo.assetIdentifier
            removed = RemovedPhoto(
                albumID: album.id,
                assetIdentifier: photo.assetIdentifier,
                takenAt: photo.takenAt,
                position: album.orderedLinks.firstIndex { $0.id == link.id } ?? link.position,
                wasCover: wasCover,
                title: photo.title,
                latitude: photo.latitude,
                longitude: photo.longitude,
                placeName: photo.placeName
            )
            if wasCover { album.coverAssetIdentifier = nil }
        }
        unlink(link)
        if let album {
            reindex(album)
            album.refreshStats()
        }
        if let photo { purgeOrphans([photo]) }
        save()
        return removed
    }

    /// `remove`로 뺀 사진을 원래 자리에 다시 넣는다. 이미 들어 있으면 아무것도 하지 않는다.
    @discardableResult
    func restore(_ removed: RemovedPhoto, to album: Album) -> AlbumPhoto? {
        guard album.id == removed.albumID,
              let link = add([(id: removed.assetIdentifier, takenAt: removed.takenAt)], to: album).first
        else { return nil }
        var ordered = album.orderedLinks.filter { $0.id != link.id }
        ordered.insert(link, at: min(max(removed.position, 0), ordered.count))
        for (index, item) in ordered.enumerated() { item.position = index }
        if removed.wasCover { album.coverAssetIdentifier = removed.assetIdentifier }
        album.refreshStats()
        // 사진 참조가 지워졌다가 새로 만들어졌으면 붙여 둔 이름과 위치를 돌려놓는다.
        if let photo = link.photo {
            photo.title = photo.title ?? removed.title
            photo.latitude = photo.latitude ?? removed.latitude
            photo.longitude = photo.longitude ?? removed.longitude
            photo.placeName = photo.placeName ?? removed.placeName
        }
        save()
        return link
    }

    /// 사진이 속한 앨범을 주어진 목록과 같게 맞춘다.
    func setAlbums(_ albums: [Album], for photo: Photo) {
        let wanted = Set(albums.map(\.id))
        for link in photo.links {
            guard let album = link.album else { continue }
            if !wanted.contains(album.id) {
                if album.coverAssetIdentifier == photo.assetIdentifier { album.coverAssetIdentifier = nil }
                unlink(link)
                reindex(album)
                album.refreshStats()
            }
        }
        let current = Set(photo.links.compactMap { $0.album?.id })
        for album in albums where !current.contains(album.id) {
            let link = AlbumPhoto(position: (album.links.map(\.position).max() ?? -1) + 1)
            context.insert(link)
            link.album = album
            link.photo = photo
            album.refreshStats()
        }
        purgeOrphans([photo])
        save()
    }

    /// 앨범 안에서 사진 순서를 `delta`칸 옮긴다.
    func move(_ link: AlbumPhoto, by delta: Int) {
        guard let album = link.album else { return }
        var ordered = album.orderedLinks
        guard let from = ordered.firstIndex(where: { $0.id == link.id }) else { return }
        let to = min(max(from + delta, 0), ordered.count - 1)
        guard to != from else { return }
        ordered.insert(ordered.remove(at: from), at: to)
        for (index, item) in ordered.enumerated() { item.position = index }
        album.refreshStats()
        save()
    }

    func setCover(_ album: Album, to photo: Photo?) {
        album.coverAssetIdentifier = photo?.assetIdentifier
        save()
    }

    func albums(containing photo: Photo) -> [Album] {
        photo.links.compactMap(\.album).sorted { $0.sortIndex < $1.sortIndex }
    }

    // MARK: 내부

    /// 저장해 둔 사진 수와 첫 사진이 없는 앨범을 센다. 이 값이 생기기 전에 만든 앨범을 위해 실행할 때 한 번 부른다.
    func refreshMissingStats() {
        let albums = (try? context.fetch(FetchDescriptor<Album>(predicate: #Predicate { $0.cachedCount < 0 }))) ?? []
        guard !albums.isEmpty else { return }
        for album in albums { album.refreshStats() }
        save()
    }

    private func photos(for identifiers: [String]) -> [String: Photo] {
        guard !identifiers.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { identifiers.contains($0.assetIdentifier) })
        let found = (try? context.fetch(descriptor)) ?? []
        return Dictionary(found.map { ($0.assetIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func unlink(_ link: AlbumPhoto) {
        link.album = nil
        link.photo = nil
        context.delete(link)
    }

    private func reindex(_ album: Album) {
        for (index, link) in album.orderedLinks.enumerated() { link.position = index }
    }

    private func purgeOrphans(_ photos: [Photo]) {
        for photo in photos where !photo.isDeleted && photo.links.isEmpty {
            context.delete(photo)
        }
    }

    private func save() {
        do { try context.save() } catch { assertionFailure("저장 실패: \(error)") }
    }

    private static func clean(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? untitled : trimmed
    }
}
