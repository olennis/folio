import Photos
import SwiftData
import SwiftUI
import UIKit

/// 화면에 넘기는 사람 요약. 모델 객체 대신 값으로 넘겨 백그라운드 저장과 엇갈리지 않게 한다.
struct PersonSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String?
    let isHidden: Bool
    let isConfirmed: Bool
    /// 이 사람이 나온 사진(중복 없이).
    let assetIDs: [String]
    let faceAssetID: String?
    let faceBox: CGRect?

    var displayName: String { name ?? "이름 없음" }
    var photoCount: Int { assetIDs.count }
}

/// 사람 한 명의 얼굴 하나(사진과 상자).
struct FaceSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let assetID: String
    let box: CGRect
}

enum PeopleQuery {
    /// 사람 목록. 사진이 많은 순. 사진이 `minimumPhotos`장보다 적은 사람은 뺀다.
    static func people(in container: ModelContainer, includeHidden: Bool = false, minimumPhotos: Int = 2) -> [PersonSummary] {
        let context = ModelContext(container)
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        return people.compactMap { person -> PersonSummary? in
            guard includeHidden || !person.isHidden else { return nil }
            let assets = person.assetIDs
            guard assets.count >= minimumPhotos || person.isConfirmed else { return nil }
            let face = person.representativeFace
            return PersonSummary(
                id: person.id, name: person.name, isHidden: person.isHidden, isConfirmed: person.isConfirmed,
                assetIDs: assets, faceAssetID: face?.assetLocalIdentifier, faceBox: face?.box
            )
        }
        .sorted { ($0.name == nil ? 1 : 0, -$0.photoCount) < ($1.name == nil ? 1 : 0, -$1.photoCount) }
    }

    static func faces(of personID: UUID, in container: ModelContainer) -> [FaceSummary] {
        let context = ModelContext(container)
        let person = try? context.fetch(FetchDescriptor<Person>(predicate: #Predicate { $0.id == personID })).first
        return (person?.faces ?? []).map { FaceSummary(id: $0.id, assetID: $0.assetLocalIdentifier, box: $0.box) }
    }
}

/// 사진에서 얼굴 부분만 동그랗게 잘라 보여 준다.
struct FaceThumbnail: View {
    let assetID: String?
    let box: CGRect?
    var size: CGFloat = 72

    @State private var image: UIImage?

    var body: some View {
        Circle()
            .fill(Color(.tertiarySystemFill))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .task(id: "\(assetID ?? "")#\(box.map { "\($0)" } ?? "")") { image = await Self.load(assetID, box) }
            .accessibilityHidden(true)
    }

    private static let cache = NSCache<NSString, UIImage>()

    private static func load(_ assetID: String?, _ box: CGRect?) async -> UIImage? {
        guard let assetID, let box else { return nil }
        let key = "\(assetID)#\(box)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let asset = PhotoLibrary.asset(assetID) else { return nil }
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            var result: UIImage?
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 800, height: 800), contentMode: .aspectFit, options: options) { image, _ in result = image }
            guard let result, let cg = PhotoKitFaceSource.upright(result) else { return nil }
            // 얼굴 상자를 넉넉히 키워 정사각형으로 자른다.
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            let side = max(box.width * w, box.height * h) * 1.6
            let center = CGPoint(x: box.midX * w, y: box.midY * h)
            let crop = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
                .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            return cg.cropping(to: crop).map { UIImage(cgImage: $0) }
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
