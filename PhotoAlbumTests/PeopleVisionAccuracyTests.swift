import CoreGraphics
import ImageIO
import XCTest
@testable import PhotoAlbum

/// 앱 경로 그대로(Vision 얼굴·랜드마크 → dlib 정렬 → Core ML → 묶기) LFW 사진으로 정밀도·재현율을 잰다.
/// 사진과 dlib 5점은 tools/model-conversion/vision_set.py가 만들었다(10명 × 20장 + 낯선 얼굴 50명).
/// 시뮬레이터의 Vision은 랜드마크가 틀려 기기에서만 돈다.
final class PeopleVisionAccuracyTests: XCTestCase {
    private struct Item: Decodable {
        let file: String
        let person: Int
        let points: [[Double]]?
    }

    private struct Sample {
        let person: Int
        let vision: [Float]
        let dlib: [Float]?
        let quality: Float
    }

    func testPrecisionAndRecallThroughVision() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("시뮬레이터의 Vision 랜드마크는 CPU 경로라 크게 틀린다. 기기에서 돈다.")
        #else
        let bundle = Bundle(for: Self.self)
        let manifest = try XCTUnwrap(bundle.url(forResource: "vision-set", withExtension: "json"))
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: manifest))
        // 품질 바닥은 따로 재려고 0으로 두고, 크기 바닥(60px)은 앱과 같게 둔다.
        let detector = VisionFaceDetector(minimumQuality: 0)
        let aligner = DlibFaceAligner()
        let embedder = try CoreMLFaceEmbedder()

        var samples: [Sample] = []
        var missed = 0
        // 두 눈 바깥 거리로 나눈 점별 오차(눈선 방향, 아래 방향). Vision 점이 dlib 점에서 한쪽으로 치우치는지 본다.
        var bias = [CGPoint](repeating: .zero, count: 5)
        var biasCount = 0
        var pointError: [Double] = []
        for item in items {
            let base = (item.file as NSString).deletingPathExtension
            let url = try XCTUnwrap(bundle.url(forResource: base, withExtension: "jpg"), item.file)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let rgb = try XCTUnwrap(RGBImage(cg))
            // LFW는 가운데 얼굴이 그 사람이다.
            let center = CGPoint(x: CGFloat(cg.width) / 2, y: CGFloat(cg.height) / 2)
            guard let face = try detector.detect(in: cg).min(by: { hypot($0.box.midX - center.x, $0.box.midY - center.y) < hypot($1.box.midX - center.x, $1.box.midY - center.y) }),
                  hypot(face.box.midX - center.x, face.box.midY - center.y) < 40,
                  let chip = aligner.chip(from: rgb, landmarks: face.landmarks)
            else { missed += 1; continue }
            var chips = [chip]
            if let raw = item.points {
                let target = raw.map { CGPoint(x: $0[0], y: $0[1]) }
                let eyes = hypot(target[0].x - target[2].x, target[0].y - target[2].y)
                let axis = CGPoint(x: (target[0].x - target[2].x) / eyes, y: (target[0].y - target[2].y) / eyes)
                for i in 0..<5 {
                    let dx = face.landmarks[i].x - target[i].x, dy = face.landmarks[i].y - target[i].y
                    bias[i].x += (dx * axis.x + dy * axis.y) / eyes
                    bias[i].y += (-dx * axis.y + dy * axis.x) / eyes
                }
                biasCount += 1
                pointError.append(zip(face.landmarks, target).map { hypot($0.x - $1.x, $0.y - $1.y) }.reduce(0, +) / 5 / eyes)
                if let ours = aligner.chip(from: rgb, landmarks: target) { chips.append(ours) }
            }
            let vectors = try embedder.embeddings(for: chips)
            samples.append(Sample(person: item.person, vision: vectors[0], dlib: vectors.count > 1 ? vectors[1] : nil, quality: face.quality))
        }

        var lines = ["사진 \(items.count)장, Vision이 못 찾음 \(missed)장"]
        let sorted = pointError.sorted()
        lines.append(String(format: "점 오차(눈 거리 대비) 중앙값 %.3f, 90%% %.3f, 최대 %.3f", sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.last ?? 0))
        let names = ["오른눈 바깥", "오른눈 안", "왼눈 바깥", "왼눈 안", "코 밑"]
        for i in 0..<5 {
            lines.append(String(format: "  %@ 치우침: 눈선 방향 %+.3f, 아래 방향 %+.3f", names[i], bias[i].x / CGFloat(biasCount), bias[i].y / CGFloat(biasCount)))
        }
        let gaps = samples.compactMap { s in s.dlib.map { FaceVector.distance(s.vision, $0) } }.sorted()
        lines.append(String(format: "같은 사진 Vision 칩과 dlib 점 칩의 임베딩 거리 중앙값 %.3f, 90%% %.3f", gaps[gaps.count / 2], gaps[gaps.count * 9 / 10]))

        let truth = samples.map(\.person)
        func measure(_ title: String, _ vectors: [[Float]], _ truth: [Int]) -> [Float: (precision: Double, recall: Double)] {
            var results: [Float: (precision: Double, recall: Double)] = [:]
            for threshold: Float in [0.45, 0.5, 0.55, 0.6] {
                let labels = ChineseWhispersClusterer(threshold: threshold).cluster(vectors)
                let m = ClusterMetrics.pairwise(predicted: labels, truth: truth)
                results[threshold] = m
                lines.append(String(format: "%@ 임계값 %.2f: 정밀도 %.3f, 재현율 %.3f", title, threshold, m.precision, m.recall))
            }
            return results
        }
        let vision = measure("Vision", samples.map(\.vision), truth)
        let withDlib = samples.filter { $0.dlib != nil }
        _ = measure("dlib 점", withDlib.compactMap(\.dlib), withDlib.map(\.person))
        for floor: Float in [0.25, 0.4] {
            let kept = samples.filter { $0.quality >= floor }
            let labels = ChineseWhispersClusterer().cluster(kept.map(\.vision))
            let m = ClusterMetrics.pairwise(predicted: labels, truth: kept.map(\.person))
            lines.append(String(format: "품질 %.2f 이상만(%d장): 정밀도 %.3f, 재현율 %.3f", floor, kept.count, m.precision, m.recall))
        }
        print("인물 묶기 정확도(Vision 경로)\n" + lines.joined(separator: "\n"))

        XCTAssertLessThan(missed, items.count / 20, "Vision이 얼굴을 너무 많이 놓친다")
        let current = try XCTUnwrap(vision[ChineseWhispersClusterer().threshold])
        XCTAssertGreaterThan(current.precision, 0.95)
        XCTAssertGreaterThan(current.recall, 0.9)
        #endif
    }
}
