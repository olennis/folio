import BackgroundTasks
import Network
import Photos
import SwiftData
import SwiftUI
import UIKit

/// 얼굴을 찾을 사진을 내주는 곳. 테스트에서는 가짜로 바꾼다.
protocol FacePhotoSource: Sendable {
    /// 보관함의 사진 ID(최근 사진부터).
    func assetIDs() -> [String]
    /// 얼굴을 찾을 이미지(긴 변 약 1024px, 바로 선 방향). iCloud에만 있는 사진은 `allowNetwork`일 때만 받는다.
    func image(for assetID: String, allowNetwork: Bool) -> CGImage?
}

/// 사진 보관함에서 사진을 읽는다.
struct PhotoKitFaceSource: FacePhotoSource {
    static let targetPixels: CGFloat = 1024

    func assetIDs() -> [String] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var ids: [String] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }

    func image(for assetID: String, allowNetwork: Bool) -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork
        var result: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: Self.targetPixels, height: Self.targetPixels),
            contentMode: .aspectFit,
            options: options
        ) { image, _ in result = image }
        guard let result else { return nil }
        return Self.upright(result)
    }

    /// 사진의 방향 정보를 반영해 바로 선 이미지로 그린다. 얼굴 찾기와 정렬이 같은 픽셀을 보게 한다.
    static func upright(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }
}

/// 인물 기능 설정. 동의하고 켠 사람만 얼굴을 분석한다.
enum PeopleSettings {
    static let enabledKey = "people.enabled"
    static let iCloudOnWiFiKey = "people.iCloudOnWiFi"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// iCloud에만 있는 사진을 Wi‑Fi일 때 내려받아 분석할지. 기본은 끔(기기에 있는 사진만).
    static var downloadsOnWiFi: Bool {
        get { UserDefaults.standard.bool(forKey: iCloudOnWiFiKey) }
        set { UserDefaults.standard.set(newValue, forKey: iCloudOnWiFiKey) }
    }
}

/// 얼굴 분석 한 단계: 사진 한 장 → 찾은 얼굴(상자·임베딩·품질). 테스트에서 가짜 부품을 넣는다.
struct FacePipeline: Sendable {
    var detector: any FaceDetecting
    var aligner: any FaceAligning
    var embedder: any FaceEmbedder

    func faces(in image: CGImage) throws -> [(box: CGRect, embedding: [Float], quality: Float)] {
        let found = try detector.detect(in: image)
        guard !found.isEmpty, let rgb = RGBImage(image) else { return [] }
        let chips = found.compactMap { face in aligner.chip(from: rgb, landmarks: face.landmarks).map { (face, $0) } }
        let vectors = try embedder.embeddings(for: chips.map(\.1))
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return zip(chips, vectors).map { item, vector in
            let box = item.0.box
            return (CGRect(x: box.minX / w, y: box.minY / h, width: box.width / w, height: box.height / h), vector, item.0.quality)
        }
    }
}

/// 보관함의 사진에서 얼굴을 찾아 사람별로 묶는다.
///
/// - 첫 분석은 충전 중이고 기기가 쉴 때 `BGProcessingTask`로 하고, 앱이 켜져 있으면 앞에서 조금씩 한다.
/// - 사진이 늘거나 지워지면(`PHPhotoLibraryChangeObserver`) 바뀐 사진만 다시 본다.
/// - 사진마다 기록을 남겨, 중간에 멈춰도 다음에 이어서 한다.
/// - 모든 처리는 기기 안에서만 한다. 얼굴 이미지와 임베딩을 밖으로 보내지 않는다.
@MainActor
final class PeopleIndexer: NSObject, ObservableObject {
    static let shared = PeopleIndexer()
    nonisolated static let backgroundTaskID = "dev.dh.sajincheop.people-index"

    /// 진행: 본 사진 수와 이번에 볼 전체 수. 쉬고 있으면 nil.
    @Published private(set) var progress: (done: Int, total: Int)?
    /// 사람 목록이 바뀔 때마다 올라간다. 화면이 다시 읽는 신호.
    @Published private(set) var revision = 0
    @Published private(set) var lastError: String?

    private(set) var container: ModelContainer?
    private var store: FaceStore?
    private var task: Task<Void, Never>?
    private var source: any FacePhotoSource = PhotoKitFaceSource()
    private var pipeline: FacePipeline?
    var clusterer = AverageLinkageClusterer()
    /// 사람에 안 붙은 얼굴이 이만큼 쌓이면 전체를 다시 묶는다.
    var reclusterEvery = 150
    /// 도는 동안 사진이 바뀌었으면 끝난 뒤 한 번 더 본다.
    private var needsRerun = false
    private let wifi = NWPathMonitor(requiredInterfaceType: .wifi)
    private var onWiFi = false

    override init() {
        super.init()
        wifi.pathUpdateHandler = { path in
            let ok = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in PeopleIndexer.shared.onWiFi = ok }
        }
        wifi.start(queue: .global(qos: .utility))
    }

    /// 테스트에서 저장소·사진·부품을 바꿔 끼운다.
    func configure(container: ModelContainer, source: any FacePhotoSource, pipeline: FacePipeline) {
        stop()
        self.container = container
        store = FaceStore(modelContainer: container)
        self.source = source
        self.pipeline = pipeline
    }

    /// 앱이 켜질 때. 저장소를 열고, 켜 둔 사람이면 남은 사진을 이어서 본다.
    func prepare() {
        #if DEBUG
        if seedDemoIfRequested() { return }
        #endif
        if container == nil {
            do {
                let container = try FaceStoreContainer.make()
                self.container = container
                store = FaceStore(modelContainer: container)
            } catch {
                lastError = String(describing: error)
            }
        }
        PHPhotoLibrary.shared().register(self)
        if canRun { start() }
    }

    private var canRun: Bool {
        guard PeopleSettings.isEnabled, ProStore.shared.isPro else { return false }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// 앞에서 조금씩 분석한다. 이미 돌고 있으면 그대로 둔다.
    func start() {
        guard task == nil, let store else { return }
        if pipeline == nil {
            do {
                pipeline = FacePipeline(detector: VisionFaceDetector(), aligner: DlibFaceAligner(), embedder: try CoreMLFaceEmbedder())
            } catch {
                lastError = String(describing: error)
                return
            }
        }
        guard let pipeline else { return }
        let source = source
        let clusterer = clusterer
        let reclusterEvery = reclusterEvery
        let allowNetwork = PeopleSettings.downloadsOnWiFi && onWiFi
        task = Task { [weak self] in
            await Self.run(store: store, source: source, pipeline: pipeline, clusterer: clusterer,
                           reclusterEvery: reclusterEvery, allowNetwork: allowNetwork) { done, total in
                await MainActor.run {
                    self?.progress = total == 0 ? nil : (done, total)
                    self?.revision += 1
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.progress = nil
                self.task = nil
                self.revision += 1
                if self.needsRerun, !Task.isCancelled, self.canRun {
                    self.needsRerun = false
                    self.start()
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        progress = nil
    }

    /// 다 끝날 때까지 기다린다(테스트·백그라운드 작업용).
    func wait() async {
        await task?.value
    }

    /// 분석을 멈추고 저장된 얼굴 데이터를 모두 지운다. 기능을 끌 때.
    func deleteAll() {
        stop()
        store = nil
        container = nil
        FaceStoreContainer.deleteFiles()
        revision += 1
        if let container = try? FaceStoreContainer.make() {
            self.container = container
            store = FaceStore(modelContainer: container)
        }
    }

    #if DEBUG
    /// UI 테스트용(`-peopleReset YES`): 켜기 전 상태에서 시작한다. 앱이 뜰 때 한 번만 부른다.
    nonisolated static func resetIfRequested() {
        guard UserDefaults.standard.bool(forKey: "peopleReset") else { return }
        PeopleSettings.isEnabled = false
        FaceStoreContainer.deleteFiles()
    }

    /// UI 테스트·캡처용(`-peopleDemo YES`): 시뮬레이터는 Vision 얼굴 찾기가 돌지 않아, 메모리 저장소에
    /// 보관함 사진으로 두 사람을 만들어 둔다. 실제 분석은 하지 않는다.
    private func seedDemoIfRequested() -> Bool {
        guard UserDefaults.standard.bool(forKey: "peopleDemo") else { return false }
        // 켜짐 상태는 실행 인자(`-people.enabled YES`)로 준다. 기기 설정에 남기지 않는다.
        guard container == nil, let container = try? FaceStoreContainer.make(inMemory: true) else { return true }
        self.container = container
        let store = FaceStore(modelContainer: container)
        self.store = store
        let ids = PhotoKitFaceSource().assetIDs()
        Task {
            for (index, id) in ids.prefix(10).enumerated() {
                let person = index < 6 ? 0 : 1
                var vector = [Float](repeating: 0, count: 128)
                vector[person] = 1
                vector[2 + index] = 0.05
                await store.add(assetID: id, faces: [(CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4), vector, 0.8)],
                                clusterer: clusterer)
            }
            await store.recluster(using: clusterer)
            revision += 1
        }
        return true
    }
    #endif

    // MARK: 사용자 보정(화면에서 부른다)

    func rename(_ id: UUID, to name: String) async { await store?.rename(id, to: name); revision += 1 }
    func merge(_ source: UUID, into target: UUID) async { await store?.merge(source, into: target); revision += 1 }
    func exclude(faces: Set<UUID>, from person: UUID) async { await store?.exclude(faceIDs: faces, from: person); revision += 1 }
    func setHidden(_ id: UUID, _ hidden: Bool) async { await store?.setHidden(id, hidden); revision += 1 }

    // MARK: 분석

    /// 아직 안 본 사진을 차례로 본다. 보관함에서 사라진 사진의 얼굴은 지운다.
    nonisolated static func run(
        store: FaceStore,
        source: any FacePhotoSource,
        pipeline: FacePipeline,
        clusterer: AverageLinkageClusterer,
        reclusterEvery: Int,
        allowNetwork: Bool,
        batch: Int = 20,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async {
        let library = source.assetIDs()
        let indexed = await store.indexedAssetIDs()
        let current = Set(library)
        await store.remove(assetIDs: indexed.subtracting(current))
        let pending = library.filter { !indexed.contains($0) }
        guard !pending.isEmpty else {
            await progress(0, 0)
            return
        }
        await progress(0, pending.count)
        var done = 0
        var sinceRecluster = await store.unassignedCount()
        for start in stride(from: 0, to: pending.count, by: batch) {
            if Task.isCancelled { break }
            for id in pending[start..<min(start + batch, pending.count)] {
                if Task.isCancelled { break }
                done += 1
                // 사진 한 장의 임시 메모리(1024px 이미지, 칩)를 바로 돌려준다.
                // 사진을 못 불러왔거나(iCloud에만 있음) 분석이 실패하면 "본 사진"으로 남기지 않아 다음에 다시 본다.
                let faces: [(box: CGRect, embedding: [Float], quality: Float)]? = autoreleasepool {
                    guard let image = source.image(for: id, allowNetwork: allowNetwork) else { return nil }
                    return try? pipeline.faces(in: image)
                }
                guard let faces else { continue }
                let assigned = await store.add(assetID: id, faces: faces, clusterer: clusterer)
                sinceRecluster += faces.count - assigned
            }
            await store.save()
            if sinceRecluster >= reclusterEvery {
                await store.recluster(using: clusterer)
                sinceRecluster = await store.unassignedCount()
            }
            await progress(done, pending.count)
            await Task.yield()
        }
        // 다 봤으면(또는 멈췄으면) 남은 얼굴까지 한 번 묶는다.
        await store.save()
        await store.recluster(using: clusterer)
    }

    // MARK: 백그라운드 작업

    /// 앱이 뜰 때 한 번 등록한다(Info.plist의 BGTaskSchedulerPermittedIdentifiers와 같은 ID).
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in PeopleIndexer.shared.handle(task) }
        }
    }

    /// 남은 사진이 있으면 충전 중일 때 이어서 하도록 맡긴다.
    func scheduleBackgroundTask() {
        guard PeopleSettings.isEnabled, ProStore.shared.isPro else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(_ task: BGProcessingTask) {
        prepare()
        guard canRun else {
            task.setTaskCompleted(success: true)
            return
        }
        task.expirationHandler = { Task { @MainActor in PeopleIndexer.shared.stop() } }
        start()
        Task {
            await wait()
            task.setTaskCompleted(success: true)
        }
    }
}

extension PeopleIndexer: PHPhotoLibraryChangeObserver {
    /// 사진이 늘거나 지워지면 바뀐 사진만 다시 본다. 이미 본 사진은 기록이 있어 건너뛴다.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard self.canRun else { return }
            if self.task == nil { self.start() } else { self.needsRerun = true }
        }
    }
}
