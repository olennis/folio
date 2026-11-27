import Foundation

protocol FaceClustering: Sendable {
    /// 얼굴을 사람별로 묶는다. 돌려주는 값은 얼굴마다의 묶음 번호.
    /// - anchors: 사용자가 확정한 얼굴 → 고정 번호. 이 얼굴들은 번호가 바뀌지 않는다.
    /// - forbidden: 얼굴 → 가질 수 없는 번호("이 사람 아님").
    func cluster(_ embeddings: [[Float]], anchors: [Int: Int], forbidden: [Int: Set<Int>]) -> [Int]
}

/// dlib `chinese_whispers`와 같은 방식으로 얼굴을 묶는다.
///
/// 거리가 `threshold` 미만인 얼굴끼리 선(가중치 1)으로 잇고, 무작위로 고른 얼굴이 이웃에서 가장 많이 쓰는
/// 번호를 따라가게 하는 일을 `iterations × 얼굴 수`번 되풀이한다. 같은 입력이면 같은 결과가 나오게 씨앗을 고정한다.
struct ChineseWhispersClusterer: FaceClustering {
    /// 이 거리보다 가까우면 같은 사람으로 본다(dlib 기준 0.6).
    var threshold: Float = 0.6
    var iterations = 100
    var seed: UInt64 = 0x5EED

    func cluster(_ embeddings: [[Float]], anchors: [Int: Int] = [:], forbidden: [Int: Set<Int>] = [:]) -> [Int] {
        let n = embeddings.count
        guard n > 0 else { return [] }
        let neighbors = Self.neighbors(embeddings, threshold: threshold)

        // 확정한 얼굴은 그 번호로 고정하고, 나머지는 자기만의 번호로 시작한다.
        let offset = (anchors.values.max() ?? -1) + 1
        var labels = (0..<n).map { anchors[$0] ?? offset + $0 }
        var rng = SplitMix64(seed: seed)
        var votes: [Int: Int] = [:]
        for _ in 0..<(iterations * n) {
            let i = Int(rng.next() % UInt64(n))
            guard anchors[i] == nil, !neighbors[i].isEmpty else { continue }
            votes.removeAll(keepingCapacity: true)
            let banned = forbidden[i] ?? []
            for j in neighbors[i] where !banned.contains(labels[j]) {
                votes[labels[j], default: 0] += 1
            }
            // 가장 많은 번호. 같으면 작은 번호(결과가 실행마다 같도록).
            if let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
                labels[i] = best.key
            }
        }
        return labels
    }

    /// 얼굴마다 threshold 안의 이웃. 얼굴 수의 제곱만큼 거리를 잰다.
    static func neighbors(_ embeddings: [[Float]], threshold: Float) -> [[Int]] {
        let n = embeddings.count
        let limit = threshold * threshold
        var result = [[Int]](repeating: [], count: n)
        embeddings.withUnsafeBufferPointer { vectors in
            for i in 0..<n {
                let a = vectors[i]
                for j in (i + 1)..<max(n, i + 1) {
                    let b = vectors[j]
                    var sum: Float = 0
                    for k in 0..<min(a.count, b.count) {
                        let d = a[k] - b[k]
                        sum += d * d
                        if sum >= limit { break }
                    }
                    if sum < limit {
                        result[i].append(j)
                        result[j].append(i)
                    }
                }
            }
        }
        return result
    }

    /// 새 얼굴을 기존 사람의 중심과 비교해 가장 가까운 사람을 고른다. threshold 안에 없으면 nil.
    func nearest<ID>(_ embedding: [Float], among centroids: [(id: ID, centroid: [Float])], excluding: (ID) -> Bool = { _ in false }) -> ID? {
        var best: (id: ID, distance: Float)?
        for item in centroids where !excluding(item.id) {
            let distance = FaceVector.distance(embedding, item.centroid)
            if distance < threshold, distance < (best?.distance ?? .infinity) { best = (item.id, distance) }
        }
        return best?.id
    }
}

/// 씨앗을 고정할 수 있는 작은 난수 생성기.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 묶음 결과를 정답과 비교하는 지표(쌍 단위). 같은 사람 쌍을 얼마나 같이 묶었는지(재현율),
/// 같이 묶은 쌍이 얼마나 실제로 같은 사람인지(정밀도).
enum ClusterMetrics {
    static func pairwise(predicted: [Int], truth: [Int]) -> (precision: Double, recall: Double) {
        var tp = 0, fp = 0, fn = 0
        for i in 0..<predicted.count {
            for j in (i + 1)..<predicted.count {
                let same = truth[i] == truth[j], together = predicted[i] == predicted[j]
                if same && together { tp += 1 } else if together { fp += 1 } else if same { fn += 1 }
            }
        }
        let precision = tp + fp == 0 ? 1 : Double(tp) / Double(tp + fp)
        let recall = tp + fn == 0 ? 1 : Double(tp) / Double(tp + fn)
        return (precision, recall)
    }
}
