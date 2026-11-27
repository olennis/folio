import Photos
import SwiftData
import SwiftUI

@main
struct PhotoAlbumApp: App {
    /// 저장소를 열지 못해도 앱을 끝내지 않는다. 데이터는 건드리지 않고 안내만 보여 준다.
    private let store: Result<ModelContainer, Error> = Result {
        var configuration = ModelConfiguration()
        #if DEBUG
        // UI 테스트용(`-inMemoryStore YES`): 앨범이 하나도 없는 빈 저장소로 켠다. 기기의 앨범은 건드리지 않는다.
        if UserDefaults.standard.bool(forKey: "inMemoryStore") {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        }
        #endif
        return try ModelContainer(
            for: Schema(versionedSchema: FolioSchemaV1.self),
            migrationPlan: FolioMigrationPlan.self,
            configurations: configuration
        )
    }

    init() {
        // 얼굴 분석을 충전 중에 이어서 하는 백그라운드 작업. 앱이 뜰 때 한 번 등록해야 한다.
        PeopleIndexer.registerBackgroundTask()
        #if DEBUG
        PeopleIndexer.resetIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            switch store {
            case .success(let container):
                RootView()
                    .task { await prepare(container) }
                    .modelContainer(container)
            case .failure(let error):
                StoreErrorView(error: error)
            }
        }
    }

    @MainActor
    private func prepare(_ container: ModelContainer) async {
        // 사진 수·부제를 저장해 두기 전에 만든 앨범을 한 번 센다.
        AlbumStore(context: container.mainContext).refreshMissingStats()
        // 단위 테스트가 앱을 호스트로 띄울 때는 권한을 묻지 않는다.
        guard NSClassFromString("XCTestCase") == nil else { return }
        ProStore.shared.start()
        await PhotoAccess.shared.requestIfNeeded()
        #if DEBUG
        DemoSeed.runIfRequested(context: container.mainContext)
        #endif
        await PhotoMetadata.refresh(context: container.mainContext)
        // 인물: 켜 둔 Pro 사용자면 남은 사진을 이어서 본다.
        PeopleIndexer.shared.prepare()
    }
}

/// 저장소를 열지 못했을 때. 대개 앱을 이전 버전으로 되돌렸거나 데이터 이전이 실패한 경우다.
/// 지우고 새로 만들면 앨범이 사라지므로, 여기서는 아무것도 지우지 않는다.
struct StoreErrorView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView {
            Label("앨범 정보를 열지 못했습니다", systemImage: "exclamationmark.triangle")
        } description: {
            Text("앱을 최신 버전으로 업데이트한 뒤 다시 열어 주세요. 사진 보관함의 사진은 그대로입니다.")
        } actions: {
            ShareLink(item: String(describing: error)) {
                Text("오류 내용 보내기")
            }
        }
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
