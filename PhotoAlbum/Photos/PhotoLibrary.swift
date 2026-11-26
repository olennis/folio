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
    /// 식별자로 사진을 찾는 건 보관함 조회라 느리다. 스크롤하며 같은 사진을 다시 그릴 때 쓴다.
    private static let assets = NSCache<NSString, PHAsset>()
    /// 격자 썸네일. 스크롤해 되돌아왔을 때 빈칸 없이 바로 그린다.
    private static let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        return cache
    }()
    /// 이보다 작은 이미지만 썸네일로 기억한다. 크게 보는 사진은 메모리를 많이 써서 두지 않는다.
    private static let thumbnailPixels: CGFloat = 600

    static func asset(_ identifier: String) -> PHAsset? {
        guard !identifier.isEmpty else { return nil }
        if let cached = assets.object(forKey: identifier as NSString) { return cached }
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        if let asset { assets.setObject(asset, forKey: identifier as NSString) }
        return asset
    }

    private static func thumbnailKey(_ id: String, _ pixels: CGFloat, _ fill: Bool) -> NSString {
        "\(id)#\(Int(pixels))#\(fill)" as NSString
    }

    /// 전에 불러 둔 썸네일.
    static func cachedThumbnail(id: String, pixels: CGFloat, fill: Bool) -> UIImage? {
        guard pixels <= thumbnailPixels else { return nil }
        return thumbnails.object(forKey: thumbnailKey(id, pixels, fill))
    }

    /// 사진을 불러온다. 사진이 보관함에 없으면 nil. 빠른 저화질 뒤에 고화질이 한 번 더 올 수 있다.
    /// 돌려받은 요청 번호로 화면에서 사라진 칸의 요청을 취소할 수 있다.
    @discardableResult
    static func load(id: String, pixels: CGFloat, fill: Bool, completion: @escaping (UIImage) -> Void) -> PHImageRequestID? {
        guard let asset = asset(id) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        let key = pixels <= thumbnailPixels ? thumbnailKey(id, pixels, fill) : nil
        return images.requestImage(
            for: asset,
            targetSize: CGSize(width: pixels, height: pixels),
            contentMode: fill ? .aspectFill : .aspectFit,
            options: options
        ) { result, info in
            guard let result else { return }
            if let key, (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                thumbnails.setObject(result, forKey: key)
            }
            completion(result)
        }
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
    @State private var request: PHImageRequestID?
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
            // 빨리 스크롤해 지나간 칸의 요청이 쌓여 보이는 칸을 늦추지 않게 한다.
            .onDisappear { cancel() }
    }

    private func load() {
        cancel()
        let fill = contentMode == .fill
        if let cached = PhotoLibrary.cachedThumbnail(id: id, pixels: pixels, fill: fill) {
            image = cached
            missing = false
            return
        }
        image = nil
        request = PhotoLibrary.load(id: id, pixels: pixels, fill: fill) { image = $0 }
        missing = request == nil
    }

    private func cancel() {
        if let request { PhotoLibrary.images.cancelImageRequest(request) }
        request = nil
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
