import CoreLocation
import Photos
import SwiftData

/// 사진 보관함에서 촬영 위치를 읽어 와 `Photo`에 채우고, 좌표를 지명으로 푼다.
@MainActor
enum PhotoMetadata {
    private static var running = false
    private static let geocoder = CLGeocoder()
    /// 한 번에 지명으로 풀 곳의 수. 지오코더는 짧은 시간에 많이 부르면 거절한다.
    private static let placesPerRun = 20

    static func refresh(context: ModelContext) async {
        guard !running else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        running = true
        defer { running = false }

        let photos = (try? context.fetch(FetchDescriptor<Photo>())) ?? []
        fillCoordinates(photos.filter { !$0.locationChecked }, context: context)
        await resolvePlaces(photos.filter { $0.latitude != nil && $0.longitude != nil && $0.placeName == nil }, context: context)
    }

    private static func fillCoordinates(_ pending: [Photo], context: ModelContext) {
        guard !pending.isEmpty else { return }
        var byID: [String: Photo] = [:]
        for photo in pending { byID[photo.assetIdentifier] = photo }
        PHAsset.fetchAssets(withLocalIdentifiers: Array(byID.keys), options: nil).enumerateObjects { asset, _, _ in
            guard let photo = byID[asset.localIdentifier] else { return }
            if let coordinate = asset.location?.coordinate {
                photo.latitude = coordinate.latitude
                photo.longitude = coordinate.longitude
            }
            if photo.takenAt == nil { photo.takenAt = asset.creationDate }
        }
        for photo in pending { photo.locationChecked = true }
        try? context.save()
    }

    private static func resolvePlaces(_ unnamed: [Photo], context: ModelContext) async {
        guard !unnamed.isEmpty else { return }
        // 가까운 사진끼리 묶어 한 번만 묻는다(소수 둘째 자리, 약 1km).
        var groups: [String: [Photo]] = [:]
        for photo in unnamed {
            guard let latitude = photo.latitude, let longitude = photo.longitude else { continue }
            groups[String(format: "%.2f,%.2f", latitude, longitude), default: []].append(photo)
        }
        for group in groups.values.sorted(by: { $0.count > $1.count }).prefix(placesPerRun) {
            guard let first = group.first, let latitude = first.latitude, let longitude = first.longitude else { continue }
            let location = CLLocation(latitude: latitude, longitude: longitude)
            // 네트워크가 없거나 거절당하면 멈추고 다음 실행 때 이어서 한다.
            guard let place = try? await geocoder.reverseGeocodeLocation(location).first else { break }
            let name = place.locality ?? place.administrativeArea ?? place.country
            for photo in group where !photo.isDeleted { photo.placeName = name ?? "" }
        }
        try? context.save()
    }
}

extension PhotoLibrary {
    /// 아직 앨범에 넣지 않은 사진의 촬영 날짜와 위치.
    static func signatures(for identifiers: [String]) -> [PhotoSignature] {
        var result: [PhotoSignature] = []
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).enumerateObjects { asset, _, _ in
            result.append(PhotoSignature(
                takenAt: asset.creationDate,
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude
            ))
        }
        return result
    }
}
