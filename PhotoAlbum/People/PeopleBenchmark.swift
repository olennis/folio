#if DEBUG
import CoreGraphics
import Foundation
import os
import SwiftData
import UIKit

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
        /// 얼굴 특징값 사이 거리 분포(10%, 50%, 90%). 서로 다른 사람이 섞인 보관함이면 중앙값이 0.6을 넘는다.
        var pairDistances: [Float]
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
        private var chips = 0
        private(set) var exported: [[Float]] = []
        func export(_ vector: [Float]) -> Int { lock.lock(); defer { lock.unlock() }; exported.append(vector); return exported.count - 1 }
        func nextChip(limit: Int) -> Int? { lock.lock(); defer { lock.unlock() }; guard chips < limit else { return nil }; chips += 1; return chips }
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
            let chip = base.chip(from: image, landmarks: landmarks)
            timer.add("정렬", Date().timeIntervalSince(start))
            // 처음 몇 장은 눈으로 확인하려고 Documents/benchmark-chips에 남긴다.
            if let chip, let n = timer.nextChip(limit: 12), let cg = chip.cgImage(),
               let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("benchmark-chips") {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? UIImage(cgImage: cg).pngData()?.write(to: folder.appendingPathComponent("chip-\(n).png"))
                let scale = String(format: "%.2f", hypot(landmarks[0].x - landmarks[2].x, landmarks[0].y - landmarks[2].y))
                try? "\(image.width)x\(image.height) eyes \(scale) \(landmarks)".write(to: folder.appendingPathComponent("chip-\(n).txt"), atomically: true, encoding: .utf8)
            }
            return chip
        }
    }

    private struct TimedEmbedder: FaceEmbedder {
        let base: CoreMLFaceEmbedder
        let timer: Timer
        func embeddings(for chips: [RGBImage]) throws -> [[Float]] {
            let start = Date()
            let vectors = try base.embeddings(for: chips)
            timer.add("임베딩(Core ML)", Date().timeIntervalSince(start))
            // 묶는 방식 비교용(-peopleExport): 얼굴 이미지와 특징값을 짝지어 Documents/people-export에 남긴다.
            if UserDefaults.standard.bool(forKey: "peopleExport"),
               let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("people-export") {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (chip, vector) in zip(chips, vectors) {
                    let n = timer.export(vector)
                    if let cg = chip.cgImage() {
                        let small = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
                            .jpegData(withCompressionQuality: 0.8) { _ in UIImage(cgImage: cg).draw(in: CGRect(x: 0, y: 0, width: 96, height: 96)) }
                        try? small.write(to: folder.appendingPathComponent("face-\(n).jpg"))
                    }
                }
            }
            return vectors
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
                                clusterer: AverageLinkageClusterer(), reclusterEvery: 150, allowNetwork: false) { _, _ in }
        let seconds = Date().timeIntervalSince(start)
        peak.stop()
        if UserDefaults.standard.bool(forKey: "peopleExport"),
           let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("people-export") {
            try? JSONEncoder().encode(timer.exported).write(to: folder.appendingPathComponent("embeddings.json"))
        }
        let context = ModelContextBox(container: container)
        return Result(
            device: Memory.deviceModel(),
            photos: ids.count,
            faces: context.faces,
            people: context.people,
            largestPeople: context.sizes,
            unassignedFaces: context.unassigned,
            pairDistances: context.distances,
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
    let distances: [Float]
    init(container: ModelContainer) {
        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<Face>())) ?? []
        let vectors = all.prefix(300).map(\.vector)
        var gaps: [Float] = []
        for i in vectors.indices { for j in vectors.indices where j > i { gaps.append(FaceVector.distance(vectors[i], vectors[j])) } }
        gaps.sort()
        distances = gaps.isEmpty ? [] : [0.1, 0.5, 0.9].map { gaps[Int(Float(gaps.count - 1) * $0)] }
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
