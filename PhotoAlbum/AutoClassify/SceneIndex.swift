import Foundation
import Photos
import UIKit
import Vision

/// 사진마다 Vision으로 알아본 장면을 기기에 기록해 둔다. 한 번 본 사진은 다시 보지 않는다.
///
/// - 기록은 앱 지원 폴더의 JSON 파일 하나다. 저장소(SwiftData) 구조를 바꾸지 않으려고 따로 둔다.
/// - 사진 원본은 기기 밖으로 나가지 않는다. 작은 미리보기(360px)를 기기 안에서 분류한다.
/// - 시뮬레이터에서는 Vision 분류가 돌지 않는다(`Failed to create espresso context`). 그때는 장면 없음으로 기록한다.
actor SceneIndex {
    static let shared = SceneIndex()

    /// 사진 ID → 알아본 장면. 빈 배열은 "봤지만 해당 장면 없음".
    private var labels: [String: [SceneCategory]] = [:]
    private var loaded = false
    private let fileURL: URL
    /// 저장하지 않은 기록 수. 이만큼 모이면 파일에 쓴다.
    private var unsaved = 0

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return folder.appendingPathComponent("scene-index.json")
        }()
    }

    func scenes(for ids: [String]) -> [String: Set<SceneCategory>] {
        load()
        var result: [String: Set<SceneCategory>] = [:]
        for id in ids {
            if let found = labels[id], !found.isEmpty { result[id] = Set(found) }
        }
        return result
    }

    func pending(among ids: [String]) -> [String] {
        load()
        return ids.filter { labels[$0] == nil }
    }

    /// 아직 안 본 사진을 분류한다. `batch`장마다 `progress`(지금까지 본 수)를 부르고 기록을 저장한다.
    /// 작업이 취소되면 그때까지의 기록을 저장하고 멈춘다.
    func analyze(_ ids: [String], batch: Int = 50, progress: @Sendable (Int) async -> Void) async {
        load()
        var done = 0
        for chunk in stride(from: 0, to: ids.count, by: batch).map({ Array(ids[$0..<min($0 + batch, ids.count)]) }) {
            if Task.isCancelled { break }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil)
            var found: [String: [SceneCategory]] = [:]
            assets.enumerateObjects { asset, _, _ in
                found[asset.localIdentifier] = Self.classify(asset)
            }
            for id in chunk { labels[id] = found[id] ?? [] }
            done += chunk.count
            unsaved += chunk.count
            if unsaved >= 200 { save() }
            await progress(done)
            await Task.yield()
        }
        save()
    }

    /// 기록을 모두 지운다(설정에서 다시 분석할 때).
    func reset() {
        labels = [:]
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: 분류

    private static func classify(_ asset: PHAsset) -> [SceneCategory] {
        guard let image = thumbnail(asset)?.cgImage else { return [] }
        let request = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return []
        }
        let observations = (request.results ?? []).map { (identifier: $0.identifier, confidence: $0.confidence) }
        return Array(SceneCategory.categories(from: observations)).sorted { $0.rawValue < $1.rawValue }
    }

    /// 기기에 있는 작은 미리보기. iCloud에서 원본을 받아 오지는 않는다.
    private static func thumbnail(_ asset: PHAsset) -> UIImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        options.resizeMode = .fast
        var result: UIImage?
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: 360, height: 360), contentMode: .aspectFit, options: options
        ) { image, _ in result = image }
        return result
    }

    // MARK: 파일

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [SceneCategory]].self, from: data)
        else { return }
        labels = decoded
    }

    private func save() {
        unsaved = 0
        guard let data = try? JSONEncoder().encode(labels) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
