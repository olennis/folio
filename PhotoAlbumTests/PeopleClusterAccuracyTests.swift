import XCTest
@testable import PhotoAlbum

/// 실제 얼굴(LFW 10명 × 20장 + 낯선 얼굴 50명)로 묶기 정밀도·재현율을 잰다.
/// 임베딩은 tools/model-conversion/cluster_set.py가 변환한 Core ML 모델로 만들었다.
final class PeopleClusterAccuracyTests: XCTestCase {
    private struct Face: Decodable {
        let person: Int
        let embedding: [Float]
    }

    func testPrecisionAndRecallOnRealFaces() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cluster-set", withExtension: "json"))
        let faces = try JSONDecoder().decode([Face].self, from: Data(contentsOf: url))
        let vectors = faces.map(\.embedding), truth = faces.map(\.person)

        var lines: [String] = []
        for threshold: Float in [0.5, 0.55, 0.6] {
            let labels = ChineseWhispersClusterer(threshold: threshold).cluster(vectors)
            let m = ClusterMetrics.pairwise(predicted: labels, truth: truth)
            // 2장 이상 묶인 사람(앱에 보이는 사람) 수.
            let shown = Dictionary(grouping: labels, by: { $0 }).values.filter { $0.count >= 2 }.count
            lines.append(String(format: "임계값 %.2f: 정밀도 %.3f, 재현율 %.3f, 보이는 사람 %d명", threshold, m.precision, m.recall, shown))
            // 측정값보다 조금 낮게 잡은 바닥. 0.6에서는 Chinese Whispers가 닮은 두 사람을 이어 붙이는 일이 있어
            // 정밀도가 떨어진다(dlib 원본도 같다: LFW 표본 5개 평균 0.80). 0.5에서는 거의 섞이지 않는다.
            switch threshold {
            case 0.5:
                XCTAssertGreaterThan(m.precision, 0.97)
                XCTAssertGreaterThan(m.recall, 0.95)
            case 0.6:
                XCTAssertGreaterThan(m.precision, 0.7)
                XCTAssertGreaterThan(m.recall, 0.95)
            default:
                break
            }
        }
        print("인물 묶기 정확도 (얼굴 \(faces.count)개)\n" + lines.joined(separator: "\n"))
    }
}
