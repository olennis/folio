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

    /// GPU는 쓰지 않는다. 앱이 백그라운드(`BGProcessingTask`, 화면 잠김)에 있으면 iOS가 GPU 작업을 막는데
    /// (`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`), Core ML은 그때 오류 없이 망가진 값을
    /// 돌려준다. Neural Engine과 CPU는 백그라운드에서도 돈다.
    init(computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        // 시뮬레이터에는 GPU·Neural Engine 추론 환경이 없다.
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = computeUnits
        #endif
        model = try FaceEmbedding(configuration: configuration)
    }

    func embeddings(for chips: [RGBImage]) throws -> [[Float]] {
        guard !chips.isEmpty else { return [] }
        let inputs = try chips.map { chip -> FaceEmbeddingInput in
            guard let image = chip.cgImage() else { throw EmbedderError.badImage }
            return try FaceEmbeddingInput(imageWith: image)
        }
        // 한 번에 넘겨 Core ML이 묶어서 돌게 한다.
        let vectors = try model.predictions(inputs: inputs).map { output in
            let array = output.embedding
            return (0..<array.count).map { array[$0].floatValue }
        }
        guard vectors.allSatisfy(Self.isValid) else { throw EmbedderError.invalidOutput }
        return vectors
    }

    /// dlib 임베딩은 길이가 1.2~1.6쯤이다. 숫자가 아니거나 0에 가까우면 추론이 망가진 것이다.
    static func isValid(_ vector: [Float]) -> Bool {
        guard vector.count == dimension, vector.allSatisfy(\.isFinite) else { return false }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0.5 && norm < 3
    }

    enum EmbedderError: Error {
        case badImage
        case invalidOutput
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
