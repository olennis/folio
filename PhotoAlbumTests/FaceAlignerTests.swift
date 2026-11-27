import CoreGraphics
import ImageIO
import XCTest
@testable import PhotoAlbum

/// 얼굴 정렬과 임베딩을 dlib 원본 결과와 비교한다. 기준값은 tools/model-conversion에서 만들었다.
final class FaceAlignerTests: XCTestCase {
    private struct AlignmentFixture: Decodable {
        let image: String
        let points: [[Double]]
        let transform: [[Double]]
    }

    private struct FaceFixture: Decodable {
        let image: String
        let chip: String
        let points: [[Double]]
        let scale: Double
        let embedding: [Float]
    }

    private func url(_ name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        return try XCTUnwrap(Bundle(for: Self.self).url(forResource: base, withExtension: ext), "테스트 자료 \(name)")
    }

    private func decode<T: Decodable>(_ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url(name)))
    }

    private func image(_ name: String) throws -> RGBImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(try url(name) as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(RGBImage(cg))
    }

    private func points(_ raw: [[Double]]) -> [CGPoint] {
        raw.map { CGPoint(x: $0[0], y: $0[1]) }
    }

    // MARK: 변환 식

    func testChipTransformMatchesDlibForEveryFace() throws {
        let fixtures: [AlignmentFixture] = try decode("face-alignment.json")
        XCTAssertGreaterThanOrEqual(fixtures.count, 10)
        for fixture in fixtures {
            let chip = try XCTUnwrap(FaceGeometry.chip(for: points(fixture.points)))
            let t = chip.transform, e = fixture.transform
            let ours = [t.a, t.b, t.tx, t.c, t.d, t.ty]
            let dlib = [e[0][0], e[0][1], e[0][2], e[1][0], e[1][1], e[1][2]]
            for (a, b) in zip(ours, dlib) {
                XCTAssertEqual(a, b, accuracy: 1e-6, fixture.image)
            }
        }
    }

    func testSimilarityRecoversKnownTransform() throws {
        // 30도 돌리고 2배 키우고 옮긴 점은 그 변환으로 되돌아와야 한다.
        let from = FaceGeometry.chipPoints()
        let angle = Double.pi / 6, scale = 2.0
        let to = from.map {
            CGPoint(x: scale * (cos(angle) * $0.x - sin(angle) * $0.y) + 40,
                    y: scale * (sin(angle) * $0.x + cos(angle) * $0.y) - 15)
        }
        let m = try XCTUnwrap(FaceGeometry.similarity(from: from, to: to))
        XCTAssertEqual(m.a, scale * cos(angle), accuracy: 1e-9)
        XCTAssertEqual(m.c, scale * sin(angle), accuracy: 1e-9)
        XCTAssertEqual(m.tx, 40, accuracy: 1e-9)
        XCTAssertEqual(m.ty, -15, accuracy: 1e-9)
    }

    // MARK: 픽셀

    func testAlignedChipMatchesDlibChipPixels() throws {
        let faces: [FaceFixture] = try decode("faces.json")
        let aligner = DlibFaceAligner()
        for face in faces {
            let chip = try XCTUnwrap(aligner.chip(from: try image(face.image), landmarks: points(face.points)))
            let reference = try image(face.chip)
            var total = 0.0
            for i in stride(from: 0, to: chip.pixels.count, by: 4) {
                for c in 0..<3 { total += abs(Double(chip.pixels[i + c]) - Double(reference.pixels[i + c])) }
            }
            let mean = total / Double(150 * 150 * 3)
            if face.scale <= 2 {
                // 피라미드를 쓰지 않는 크기: dlib과 픽셀이 같아야 한다(소수점 처리 차이 1 이하).
                XCTAssertLessThan(mean, 0.05, "\(face.chip) 평균 차이 \(mean)")
            } else {
                // 큰 얼굴은 dlib 피라미드를 근사하므로 조금 다르다.
                XCTAssertLessThan(mean, 6, "\(face.chip) 평균 차이 \(mean)")
            }
        }
    }

    // MARK: 정렬 + 임베딩

    func testEmbeddingFromOurChipMatchesDlibEmbedding() throws {
        let faces: [FaceFixture] = try decode("faces.json")
        let embedder = try CoreMLFaceEmbedder(computeUnits: .cpuOnly)
        let aligner = DlibFaceAligner()
        let chips = try faces.map { try XCTUnwrap(aligner.chip(from: try image($0.image), landmarks: points($0.points))) }
        let vectors = try embedder.embeddings(for: chips)
        XCTAssertEqual(vectors.count, faces.count)
        for (face, vector) in zip(faces, vectors) {
            XCTAssertEqual(vector.count, 128)
            let distance = FaceVector.distance(vector, face.embedding)
            // 같은 칩이면 1e-3 안(1단계 동등성 테스트). 큰 얼굴은 피라미드 근사만큼 더 벌어진다.
            XCTAssertLessThan(distance, face.scale <= 2 ? 1e-2 : 0.08, "\(face.chip) 거리 \(distance)")
        }
        // 서로 다른 사람은 0.6보다 멀어야 한다(사진 두 장의 첫 얼굴은 다른 사람).
        XCTAssertGreaterThan(FaceVector.distance(vectors[0], vectors[2]), 0.6)
    }

    func testDlibChipThroughCoreMLMatchesDlibWithinParityTolerance() throws {
        let faces: [FaceFixture] = try decode("faces.json")
        let embedder = try CoreMLFaceEmbedder(computeUnits: .cpuOnly)
        let vectors = try embedder.embeddings(for: try faces.map { try image($0.chip) })
        for (face, vector) in zip(faces, vectors) {
            XCTAssertLessThan(FaceVector.distance(vector, face.embedding), 1e-3, face.chip)
        }
    }

    // MARK: Vision으로 찾은 얼굴

    /// Vision 랜드마크로 뽑은 5점이 dlib 5점과 얼마나 가까운지, 그 정렬로 만든 임베딩이 dlib과 얼마나 같은지.
    func testVisionLandmarksAlignCloseToDlib() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("시뮬레이터의 Vision 랜드마크는 CPU 경로라 크게 틀린다. 기기에서 돌린다.")
        #else
        let faces: [FaceFixture] = try decode("faces.json")
        let detector = VisionFaceDetector(minimumQuality: 0, minimumSide: 0)
        let embedder = try CoreMLFaceEmbedder(computeUnits: .cpuOnly)
        let aligner = DlibFaceAligner()
        var report: [String] = []
        for name in Set(faces.map(\.image)).sorted() {
            let rgb = try image(name)
            let found: [DetectedFace]
            do {
                found = try detector.detect(in: try XCTUnwrap(rgb.cgImage()))
            } catch {
                throw XCTSkip("이 환경에서는 Vision 얼굴 찾기가 돌지 않는다: \(error)")
            }
            for face in faces where face.image == name {
                let target = points(face.points)
                let eyes = hypot(target[0].x - target[2].x, target[0].y - target[2].y)
                // dlib 얼굴과 가장 가까운 Vision 얼굴.
                guard let match = found.min(by: { distance($0.landmarks[4], target[4]) < distance($1.landmarks[4], target[4]) }),
                      distance(match.landmarks[4], target[4]) < eyes
                else { XCTFail("\(face.chip): Vision이 얼굴을 못 찾았다"); continue }
                // 점 오차를 두 눈 바깥 거리로 나눈 값(정규화 오차).
                let error = zip(match.landmarks, target).map { distance($0, $1) }.reduce(0, +) / 5 / eyes
                let chip = try XCTUnwrap(aligner.chip(from: rgb, landmarks: match.landmarks))
                let vector = try XCTUnwrap(embedder.embeddings(for: [chip]).first)
                let gap = FaceVector.distance(vector, face.embedding)
                report.append(String(format: "%@ 점 오차 %.3f, dlib 임베딩과 거리 %.3f", face.chip, error, gap))
                XCTAssertLessThan(error, 0.08, face.chip)
                // 같은 사람 기준(0.6)보다 충분히 가까워야 같은 사람으로 묶인다.
                XCTAssertLessThan(gap, 0.3, face.chip)
            }
        }
        print("Vision 정렬 비교\n" + report.joined(separator: "\n"))
        #endif
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    // MARK: Vision 랜드마크 → dlib 5점

    func testDlibPointsAreOrderedByImagePosition() throws {
        // 눈 두 개(8점 윤곽)와 코. Vision이 어느 눈을 left라 부르든 이미지 오른쪽 눈이 0·1번이어야 한다.
        func ring(_ cx: Double, _ cy: Double) -> [CGPoint] {
            (0..<8).map { CGPoint(x: cx + 10 * cos(Double($0) * .pi / 4), y: cy + 4 * sin(Double($0) * .pi / 4)) }
        }
        let leftInImage = ring(100, 100), rightInImage = ring(160, 100)
        let nose = [CGPoint(x: 125, y: 140), CGPoint(x: 130, y: 146), CGPoint(x: 135, y: 140), CGPoint(x: 130, y: 120)]
        for (a, b) in [(leftInImage, rightInImage), (rightInImage, leftInImage)] {
            let p = try XCTUnwrap(VisionFaceDetector.dlibPoints(eyeA: a, eyeB: b, nose: nose))
            XCTAssertEqual(p[0].x, 170, accuracy: 1e-6) // 오른쪽 눈 바깥
            XCTAssertEqual(p[1].x, 150, accuracy: 1e-6) // 오른쪽 눈 안쪽
            XCTAssertEqual(p[2].x, 90, accuracy: 1e-6)  // 왼쪽 눈 바깥
            XCTAssertEqual(p[3].x, 110, accuracy: 1e-6) // 왼쪽 눈 안쪽
            XCTAssertEqual(p[4], CGPoint(x: 130, y: 146)) // 코 밑
        }
    }
}
