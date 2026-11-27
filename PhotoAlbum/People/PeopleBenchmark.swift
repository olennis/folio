#if DEBUG
import CoreGraphics
import Foundation
import os
import SwiftData

/// 첫 인덱싱 시간과 메모리를 잰다(DEBUG 전용, `-peopleBenchmark 1000`).
///
/// 보관함의 최근 사진 N장을 실제 부품(Vision·정렬·Core ML·묶기)으로 메모리 저장소에 분석한다. 기기의 얼굴 저장소와
/// 사용자의 인물 데이터는 건드리지 않는다. 결과는 콘솔(`PEOPLE_BENCHMARK`)과 Documents/people-benchmark.json에 남긴다.
enum PeopleBenchmark {
    struct Result: Codable {
        var device: String
        var photos: Int
        var faces: Int
        var people: Int
        /// 큰 사람부터 얼굴 수(최대 15명)와 아무에게도 안 붙은 얼굴 수.
        var largestPeople: [Int]
        var unassignedFaces: Int
        var seconds: Double
        var secondsPerPhoto: Double
        var peakMemoryMB: Double
        var startMemoryMB: Double
        var stages: [String: Double]
    }

    static func runIfRequested() {
        let count = UserDefaults.standard.integer(forKey: "peopleBenchmark")
        guard count > 0 else { return }
        Task.detached(priority: .userInitiated) {
            let result = await run(photos: count)
            let data = (try? JSONEncoder().encode(result)) ?? Data()
            let line = String(data: data, encoding: .utf8) ?? ""
            print("PEOPLE_BENCHMARK \(line)")
            Logger(subsystem: "dev.dh.sajincheop", category: "people").notice("PEOPLE_BENCHMARK \(line, privacy: .public)")
            if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: folder.appendingPathComponent("people-benchmark.json"))
            }
        }
    }

    /// 단계별 시간을 모으려고 부품을 감싼다.
    private final class Timer: @unchecked Sendable {
        private let lock = NSLock()
        private var totals: [String: Double] = [:]
        func add(_ stage: String, _ seconds: Double) { lock.lock(); totals[stage, default: 0] += seconds; lock.unlock() }
        var values: [String: Double] { lock.lock(); defer { lock.unlock() }; return totals }
    }

    private struct TimedSource: FacePhotoSource {
        let ids: [String]
        let timer: Timer
        func assetIDs() -> [String] { ids }
        func image(for assetID: String, allowNetwork: Bool) -> CGImage? {
            let start = Date()
            defer { timer.add("이미지 불러오기", Date().timeIntervalSince(start)) }
            return PhotoKitFaceSource().image(for: assetID, allowNetwork: false)
        }
    }

    private struct TimedDetector: FaceDetecting {
        let base = VisionFaceDetector()
        let timer: Timer
        func detect(in image: CGImage) throws -> [DetectedFace] {
            let start = Date()
            defer { timer.add("얼굴 찾기(Vision)", Date().timeIntervalSince(start)) }
            return try base.detect(in: image)
        }
    }

    private struct TimedAligner: FaceAligning {
        let base = DlibFaceAligner()
        let timer: Timer
        func chip(from image: RGBImage, landmarks: [CGPoint]) -> RGBImage? {
            let start = Date()
            defer { timer.add("정렬", Date().timeIntervalSince(start)) }
            return base.chip(from: image, landmarks: landmarks)
        }
    }

    private struct TimedEmbedder: FaceEmbedder {
        let base: CoreMLFaceEmbedder
        let timer: Timer
        func embeddings(for chips: [RGBImage]) throws -> [[Float]] {
            let start = Date()
            defer { timer.add("임베딩(Core ML)", Date().timeIntervalSince(start)) }
            return try base.embeddings(for: chips)
        }
    }

    static func run(photos count: Int) async -> Result {
        let timer = Timer()
        let ids = Array(PhotoKitFaceSource().assetIDs().prefix(count))
        let container = try! FaceStoreContainer.make(inMemory: true)
        let store = FaceStore(modelContainer: container)
        let pipeline = FacePipeline(
            detector: TimedDetector(timer: timer),
            aligner: TimedAligner(timer: timer),
            embedder: TimedEmbedder(base: try! CoreMLFaceEmbedder(), timer: timer)
        )
        let startMemory = Memory.footprintMB()
        let peak = PeakSampler()
        peak.start()
        let start = Date()
        await PeopleIndexer.run(store: store, source: TimedSource(ids: ids, timer: timer), pipeline: pipeline,
                                clusterer: ChineseWhispersClusterer(), reclusterEvery: 150, allowNetwork: false) { _, _ in }
        let seconds = Date().timeIntervalSince(start)
        peak.stop()
        let context = ModelContextBox(container: container)
        return Result(
            device: Memory.deviceModel(),
            photos: ids.count,
            faces: context.faces,
            people: context.people,
            largestPeople: context.sizes,
            unassignedFaces: context.unassigned,
            seconds: seconds,
            secondsPerPhoto: seconds / Double(max(ids.count, 1)),
            peakMemoryMB: max(peak.peakMB, Memory.peakFootprintMB()),
            startMemoryMB: startMemory,
            stages: timer.values
        )
    }
}

private struct ModelContextBox {
    let faces: Int
    let people: Int
    let sizes: [Int]
    let unassigned: Int
    init(container: ModelContainer) {
        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<Face>())) ?? []
        faces = all.count
        unassigned = all.filter { $0.person == nil }.count
        let counts = ((try? context.fetch(FetchDescriptor<Person>())) ?? []).map(\.faces.count).sorted(by: >)
        people = counts.filter { $0 >= 2 }.count
        sizes = Array(counts.prefix(15))
    }
}

/// 앱 전체 메모리 사용량(phys_footprint, 설정 앱·Xcode가 보여 주는 값).
enum Memory {
    static func footprintMB() -> Double { info().map { Double($0.phys_footprint) / 1_048_576 } ?? 0 }
    static func peakFootprintMB() -> Double { info().map { Double($0.ledger_phys_footprint_peak) / 1_048_576 } ?? 0 }

    private static func info() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    static func deviceModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
}

/// 0.2초마다 메모리를 재서 가장 큰 값을 기억한다.
private final class PeakSampler: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private(set) var peakMB: Double = 0

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.peakMB = max(self.peakMB, Memory.footprintMB())
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
#endif
