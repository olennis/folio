import CoreML
import Foundation

protocol FaceEmbedder: Sendable {
    /// 정렬한 150x150 얼굴마다 128차원 임베딩을 만든다.
    func embeddings(for chips: [RGBImage]) throws -> [[Float]]
}

/// dlib 얼굴 인식 모델을 옮긴 Core ML 모델(`FaceEmbedding.mlpackage`)로 임베딩을 만든다.
/// 기기 안에서만 돈다. 유클리드 거리 0.6 미만이면 같은 사람으로 본다(dlib 기준).
final class CoreMLFaceEmbedder: FaceEmbedder, @unchecked Sendable {
    static let dimension = 128
    private let model: FaceEmbedding

    init(computeUnits: MLComputeUnits = .all) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try FaceEmbedding(configuration: configuration)
    }

    func embeddings(for chips: [RGBImage]) throws -> [[Float]] {
        guard !chips.isEmpty else { return [] }
        let inputs = try chips.map { chip -> FaceEmbeddingInput in
            guard let image = chip.cgImage() else { throw EmbedderError.badImage }
            return try FaceEmbeddingInput(imageWith: image)
        }
        // 한 번에 넘겨 Core ML이 묶어서 돌게 한다.
        return try model.predictions(inputs: inputs).map { output in
            let array = output.embedding
            return (0..<array.count).map { array[$0].floatValue }
        }
    }

    enum EmbedderError: Error {
        case badImage
    }
}

/// 임베딩 거리 계산.
enum FaceVector {
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }

    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors {
            for i in sum.indices { sum[i] += v[i] }
        }
        let n = Float(vectors.count)
        return sum.map { $0 / n }
    }

    static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
