import Foundation

/// 마지막으로 크게 본 사진. 미니 바가 이 자리로 돌아간다. 앱을 다시 켜도 남는다.
@MainActor
final class ViewingSession: ObservableObject {
    static let shared = ViewingSession()

    @Published private(set) var albumID: UUID?
    @Published private(set) var assetIdentifier: String?

    private let defaults: UserDefaults
    private static let albumKey = "viewing.albumID"
    private static let assetKey = "viewing.assetIdentifier"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        albumID = defaults.string(forKey: Self.albumKey).flatMap(UUID.init(uuidString:))
        assetIdentifier = defaults.string(forKey: Self.assetKey)
    }

    func record(album: Album, assetIdentifier: String) {
        guard albumID != album.id || self.assetIdentifier != assetIdentifier else { return }
        albumID = album.id
        self.assetIdentifier = assetIdentifier
        defaults.set(album.id.uuidString, forKey: Self.albumKey)
        defaults.set(assetIdentifier, forKey: Self.assetKey)
    }

    func clear() {
        albumID = nil
        assetIdentifier = nil
        defaults.removeObject(forKey: Self.albumKey)
        defaults.removeObject(forKey: Self.assetKey)
    }
}
