import Foundation

protocol FaceClustering: Sendable {
    /// 얼굴을 사람별로 묶는다. 돌려주는 값은 얼굴마다의 묶음 번호.
    /// - anchors: 사용자가 확정한 얼굴 → 고정 번호. 이 얼굴들은 번호가 바뀌지 않는다.
    /// - forbidden: 얼굴 → 가질 수 없는 번호("이 사람 아님").
    func cluster(_ embeddings: [[Float]], anchors: [Int: Int], forbidden: [Int: Set<Int>]) -> [Int]
}

/// 평균 연결(average linkage)로 얼굴을 묶는다. 앱이 쓰는 방식.
///
/// 두 묶음의 "모든 얼굴 쌍 거리의 평균"이 `threshold` 미만이면 합친다. 한 쌍만 가까워도 이어지는 Chinese Whispers와 달리
/// 닮은 얼굴 몇 장이 다리를 놓아 두 사람이 합쳐지는 일이 적다. 실제 보관함(아이 둘·어른 둘, 얼굴 912개)에서
/// Chinese Whispers 0.5는 909개를 한 사람으로 묶었고, 평균 연결 0.45는 네 사람을 따로 묶었다.
///
/// 얼굴이 `linkageLimit`보다 많으면 앞쪽(호출하는 쪽이 품질 순으로 넘긴다) 얼굴만 묶고, 나머지는 각 묶음과의
/// 평균 거리로 붙인다. 거리 표가 얼굴 수의 제곱이라 메모리를 막으려는 것이다(2,500개면 25MB).
struct AverageLinkageClusterer: FaceClustering {
    /// 묶음 사이 평균 거리가 이보다 작으면 같은 사람. 0.47부터 실제 보관함의 두 아이가 합쳐져 0.45로 둔다.
    /// 같은 사람이 둘로 나뉘는 것은 합치기로 쉽게 고치지만, 두 사람이 섞이면 고치기 어렵다.
    var threshold: Float = 0.45
    var linkageLimit = 2500

    func cluster(_ embeddings: [[Float]], anchors: [Int: Int] = [:], forbidden: [Int: Set<Int>] = [:]) -> [Int] {
        let total = embeddings.count
        guard total > 0 else { return [] }
        // 확정한 얼굴은 꼭 거리 표에 넣는다.
        let order = anchors.keys.sorted() + (0..<total).filter { anchors[$0] == nil }
        let core = Array(order.prefix(linkageLimit))
        let n = core.count

        // 얼굴 쌍 거리 표(n×n).
        var d = [Float](repeating: 0, count: n * n)
        for a in 0..<n {
            for b in (a + 1)..<max(n, a + 1) {
                let v = FaceVector.distance(embeddings[core[a]], embeddings[core[b]])
                d[a * n + b] = v
                d[b * n + a] = v
            }
        }
        var size = [Int](repeating: 1, count: n)
        var active = [Bool](repeating: true, count: n)
        var members = (0..<n).map { [$0] }
        // 묶음이 가진 확정 번호, 가질 수 없는 번호.
        var anchor = core.map { anchors[$0] }
        var banned = core.map { forbidden[$0] ?? [] }

        func merge(_ a: Int, _ b: Int) {
            let na = Float(size[a]), nb = Float(size[b])
            for k in 0..<n where active[k] && k != a && k != b {
                let v = (na * d[a * n + k] + nb * d[b * n + k]) / (na + nb)
                d[a * n + k] = v
                d[k * n + a] = v
            }
            size[a] += size[b]
            members[a] += members[b]
            members[b] = []
            anchor[a] = anchor[a] ?? anchor[b]
            banned[a].formUnion(banned[b])
            active[b] = false
        }
        func canMerge(_ a: Int, _ b: Int) -> Bool {
            if let x = anchor[a], let y = anchor[b], x != y { return false }
            if let x = anchor[a], banned[b].contains(x) { return false }
            if let y = anchor[b], banned[a].contains(y) { return false }
            return true
        }

        // 같은 사람으로 확정한 얼굴은 거리와 상관없이 먼저 합친다.
        var anchorRoot: [Int: Int] = [:]
        for i in 0..<n {
            guard let label = anchor[i] else { continue }
            if let root = anchorRoot[label] { merge(root, i) } else { anchorRoot[label] = i }
        }

        // 가까운 이웃 사슬(nearest-neighbor chain). 평균 연결은 합칠수록 거리가 줄지 않아 이 방식이 정확하다.
        var finished = [Bool](repeating: false, count: n)
        var chain: [Int] = []
        var remaining = (0..<n).filter { active[$0] }.count
        while remaining > 0 {
            if chain.isEmpty, let start = (0..<n).first(where: { active[$0] && !finished[$0] }) { chain.append(start) }
            guard let a = chain.last else { break }
            var best = -1
            var bestDistance = Float.infinity
            let previous = chain.count >= 2 ? chain[chain.count - 2] : -1
            for k in 0..<n where active[k] && !finished[k] && k != a && canMerge(a, k) {
                let v = d[a * n + k]
                if v < bestDistance || (v == bestDistance && k == previous) { best = k; bestDistance = v }
            }
            if best < 0 || bestDistance >= threshold {
                // 더 합칠 묶음이 없다.
                finished[a] = true
                remaining -= 1
                chain.removeLast()
                continue
            }
            if best == previous {
                chain.removeLast(2)
                let (keep, drop) = a < best ? (a, best) : (best, a)
                merge(keep, drop)
                remaining -= 1
            } else {
                chain.append(best)
            }
        }

        // 번호: 확정한 사람은 그 번호, 나머지는 확정 번호 뒤로.
        let offset = (anchors.values.max() ?? -1) + 1
        var labels = [Int](repeating: -1, count: total)
        var groups: [(label: Int, faces: [Int])] = []
        for root in 0..<n where active[root] {
            let label = anchor[root] ?? offset + core[root]
            for m in members[root] { labels[core[m]] = label }
            groups.append((label, members[root].map { core[$0] }))
        }

        // 거리 표에 못 넣은 얼굴은 묶음과의 평균 거리로 붙인다.
        var leftover: [Int] = []
        for i in order.dropFirst(n) {
            let ban = forbidden[i] ?? []
            var best: (label: Int, distance: Float)?
            for group in groups where !ban.contains(group.label) {
                let v = Self.averageDistance(embeddings[i], group.faces.lazy.map { embeddings[$0] })
                if v < threshold, v < (best?.distance ?? .infinity) { best = (group.label, v) }
            }
            if let best { labels[i] = best.label } else { leftover.append(i) }
        }
        // 어디에도 안 붙은 얼굴끼리 다시 묶는다(거리 표에 못 든 사람).
        if !leftover.isEmpty {
            let sub = cluster(leftover.map { embeddings[$0] })
            for (k, i) in leftover.enumerated() { labels[i] = offset + leftover[sub[k]] }
        }
        return labels
    }

    static func averageDistance<S: Sequence>(_ embedding: [Float], _ members: S) -> Float where S.Element == [Float] {
        var sum: Float = 0
        var count = 0
        for m in members { sum += FaceVector.distance(embedding, m); count += 1 }
        return count == 0 ? .infinity : sum / Float(count)
    }

    /// 새 얼굴을 기존 사람의 얼굴들과 비교해, 평균 거리가 threshold 안에서 가장 가까운 사람을 고른다.
    /// 중심(평균 얼굴)과 비교하지 않는 것은, 여러 얼굴의 중심은 누구와도 가까워져 다른 사람까지 끌어오기 때문이다.
    func nearest<ID>(_ embedding: [Float], among people: [(id: ID, members: [[Float]])], excluding: (ID) -> Bool = { _ in false }) -> ID? {
        var best: (id: ID, distance: Float)?
        for person in people where !excluding(person.id) {
            let distance = Self.averageDistance(embedding, person.members)
            if distance < threshold, distance < (best?.distance ?? .infinity) { best = (person.id, distance) }
        }
        return best?.id
    }
}

/// dlib `chinese_whispers`와 같은 방식으로 얼굴을 묶는다. 비교용으로 남겨 둔다(PeopleClusterAccuracyTests).
/// 한 쌍만 가까워도 이어져, 서로 닮은 가족 얼굴이 많은 보관함에서는 모두 한 사람으로 번진다.
///
/// 거리가 `threshold` 미만인 얼굴끼리 선(가중치 1)으로 잇고, 무작위로 고른 얼굴이 이웃에서 가장 많이 쓰는
/// 번호를 따라가게 하는 일을 `iterations × 얼굴 수`번 되풀이한다. 같은 입력이면 같은 결과가 나오게 씨앗을 고정한다.
struct ChineseWhispersClusterer: FaceClustering {
    /// 이 거리보다 가까우면 같은 사람으로 잇는다. dlib의 두 얼굴 비교 기준은 0.6이지만, 이웃을 따라 번호가 번지는
    /// Chinese Whispers에서는 0.6이면 닮은 두 사람이 이어진다(LFW 정밀도 0.75). 0.5는 정밀도 1.000·재현율 0.980.
    var threshold: Float = 0.5
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
