import Photos
import SwiftUI

/// 사진 보관함 접근 권한 상태.
@MainActor
final class PhotoAccess: ObservableObject {
    static let shared = PhotoAccess()

    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var isFull: Bool { status == .authorized }

    func requestIfNeeded() async {
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
    }
}

enum PhotoLibrary {
    static let images = PHCachingImageManager()

    static func asset(_ identifier: String) -> PHAsset? {
        guard !identifier.isEmpty else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    /// 사진을 불러온다. 사진이 보관함에 없으면 false. 빠른 저화질 뒤에 고화질이 한 번 더 올 수 있다.
    @discardableResult
    static func load(id: String, pixels: CGFloat, fill: Bool, completion: @escaping (UIImage) -> Void) -> Bool {
        guard let asset = asset(id) else { return false }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        images.requestImage(
            for: asset,
            targetSize: CGSize(width: pixels, height: pixels),
            contentMode: fill ? .aspectFill : .aspectFit,
            options: options
        ) { result, _ in
            if let result { completion(result) }
        }
        return true
    }

    static func creationDates(for identifiers: [String]) -> [String: Date] {
        var dates: [String: Date] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).enumerateObjects { asset, _, _ in
            dates[asset.localIdentifier] = asset.creationDate
        }
        return dates
    }
}

/// 사진 보관함의 사진을 식별자로 불러와 그린다.
struct AssetImage: View {
    let id: String
    /// 불러올 긴 변의 픽셀 수
    var pixels: CGFloat = 900
    var contentMode: ContentMode = .fill
    var background = Color(.secondarySystemBackground)

    @State private var image: UIImage?
    @State private var missing = false
    @ObservedObject private var access = PhotoAccess.shared

    var body: some View {
        background
            .overlay {
                if let image {
                    // 채우기로 그리면 사진이 틀 밖으로 넘친다. 넘친 부분이 터치를 가로채지 않게 한다.
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else if missing {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: "\(id)#\(access.status.rawValue)") { load() }
    }

    private func load() {
        image = nil
        missing = !PhotoLibrary.load(id: id, pixels: pixels, fill: contentMode == .fill) { image = $0 }
    }
}

/// 전체 접근 권한이 없을 때 보여 주는 안내.
struct AccessBanner: View {
    @ObservedObject private var access = PhotoAccess.shared

    var body: some View {
        if access.status != .authorized && access.status != .notDetermined {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("모든 사진 접근을 허용해야 앨범의 사진이 보입니다.")
                    .font(.footnote)
                Spacer(minLength: 0)
                Button("설정") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 20)
        }
    }
}
