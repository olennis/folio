import SwiftData

/// 저장소 구조의 버전. 출시한 뒤 모델을 바꿀 때는 이 파일에서 이어 간다.
///
/// 바꾸는 방법:
/// 1. 지금 모델(`Album`, `Photo`, `AlbumPhoto`)을 그대로 `FolioSchemaV1` 안에 복사해 얼려 둔다.
/// 2. 바뀐 모델로 `FolioSchemaV2`를 만들고 `versionIdentifier`를 올린다.
/// 3. `FolioMigrationPlan.schemas`에 V2를 더하고, `stages`에 V1 → V2 단계를 넣는다.
///    속성 추가처럼 단순한 변경은 `.lightweight`, 값을 옮겨야 하면 `.custom`.
/// 4. 이전 버전 저장소를 만들어 열어 보는 테스트를 꼭 추가한다.
enum FolioSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Album.self, Photo.self, AlbumPhoto.self]
    }
}

enum FolioMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [FolioSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
