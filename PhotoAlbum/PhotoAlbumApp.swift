import Photos
import SwiftData
import SwiftUI

@main
struct PhotoAlbumApp: App {
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Album.self, Photo.self, AlbumPhoto.self)
        } catch {
            fatalError("저장소를 열 수 없습니다: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    // 단위 테스트가 앱을 호스트로 띄울 때는 권한을 묻지 않는다.
                    guard NSClassFromString("XCTestCase") == nil else { return }
                    await PhotoAccess.shared.requestIfNeeded()
                    #if DEBUG
                    DemoSeed.runIfRequested(context: container.mainContext)
                    #endif
                    await PhotoMetadata.refresh(context: container.mainContext)
                }
        }
        .modelContainer(container)
    }
}

#if DEBUG
/// 캡처용 실행 옵션(`-openAlbum`, `-openViewer`)이 앱 실행당 한 번만 동작하게 한다.
@MainActor
enum DebugLaunch {
    private static var openedAlbum = false
    private static var openedViewer = false

    static func consumeOpenAlbum() -> Bool {
        defer { openedAlbum = true }
        return !openedAlbum
    }

    static func consumeOpenViewer() -> Bool {
        defer { openedViewer = true }
        return !openedViewer
    }
}

/// `-seedDemo` 인자로 실행하면 기기의 사진으로 예시 앨범을 만든다. 앨범이 하나라도 있으면 아무것도 하지 않는다.
enum DemoSeed {
    private static let kinds: [String: AlbumKind] = [
        "2015년": .year, "서윤이 성장 앨범": .person, "제주 가족여행": .place,
    ]

    @MainActor
    static func runIfRequested(context: ModelContext) {
        guard CommandLine.arguments.contains("-seedDemo") else { return }
        let existing = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        guard existing.isEmpty else {
            // 종류가 생기기 전에 만든 예시 앨범에 종류를 채운다.
            for album in existing where album.kind == .custom {
                if let kind = kinds[album.title] { album.kind = kind }
            }
            try? context.save()
            return
        }

        var assets: [(id: String, takenAt: Date?)] = []
        PHAsset.fetchAssets(with: .image, options: nil).enumerateObjects { asset, _, _ in
            assets.append((asset.localIdentifier, asset.creationDate))
        }
        guard !assets.isEmpty else { return }

        let store = AlbumStore(context: context)
        let titles = ["2015년", "캠핑 모음", "서윤이 성장 앨범", "제주 가족여행"]
        for (index, title) in titles.enumerated() {
            let album = store.createAlbum(title: title, kind: kinds[title])
            // 같은 사진이 여러 앨범에 들어가도록 겹치게 넣는다.
            let rotated = Array(assets[(index % assets.count)...] + assets[..<(index % assets.count)])
            store.add(Array(rotated.prefix(max(3, assets.count - index))), to: album)
        }
    }
}
#endif
