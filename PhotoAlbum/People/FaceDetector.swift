import CoreGraphics
import Foundation
import CoreML
import Vision

/// 사진 한 장에서 찾은 얼굴. 좌표는 모두 이미지 픽셀, 왼쪽 위가 원점이다.
struct DetectedFace: Equatable, Sendable {
    /// 얼굴 상자(픽셀).
    var box: CGRect
    /// dlib 5점 순서의 랜드마크: 이미지 오른쪽 눈 바깥·안쪽, 왼쪽 눈 바깥·안쪽, 코 밑.
    var landmarks: [CGPoint]
    /// Vision 얼굴 촬영 품질(0~1). 흐리거나 옆모습이면 낮다.
    var quality: Float
}

protocol FaceDetecting: Sendable {
    func detect(in image: CGImage) throws -> [DetectedFace]
}

/// Vision으로 얼굴을 찾고 랜드마크와 품질을 잰다. 품질이 낮거나 너무 작은 얼굴은 뺀다.
struct VisionFaceDetector: FaceDetecting {
    /// 이보다 품질이 낮은 얼굴은 뺀다. 흐린 얼굴·옆얼굴이 다른 사람과 섞이는 것을 막는다.
    static let minimumCaptureQuality: Float = 0.25
    /// 얼굴 상자의 짧은 변이 이보다 작으면 뺀다(픽셀).
    static let minimumFaceSide: CGFloat = 60
    /// 고개를 이보다 많이 돌린 얼굴(라디안, 약 30도)은 뺀다. dlib 모델은 정면 얼굴로 배워 옆얼굴끼리 서로 가깝게 나온다.
    static let maximumYaw: Double = 0.52

    var minimumQuality = Self.minimumCaptureQuality
    var minimumSide = Self.minimumFaceSide
    var maximumYaw = Self.maximumYaw

    func detect(in image: CGImage) throws -> [DetectedFace] {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let handler = VNImageRequestHandler(cgImage: image)

        let rectangles = VNDetectFaceRectanglesRequest()
        Self.prepare(rectangles)
        try handler.perform([rectangles])
        // 작은 얼굴은 랜드마크·품질을 재기 전에 뺀다.
        let candidates = (rectangles.results ?? []).filter {
            min($0.boundingBox.width * width, $0.boundingBox.height * height) >= minimumSide
        }
        guard !candidates.isEmpty else { return [] }

        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.constellation = .constellation76Points
        landmarks.inputFaceObservations = candidates
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = candidates
        Self.prepare(landmarks)
        Self.prepare(quality)
        try handler.perform([landmarks, quality])
        let marked = landmarks.results ?? []

        let qualities = (quality.results ?? []).map { ($0.boundingBox, $0.faceCaptureQuality ?? 0) }
        return marked.compactMap { face in
            let score = qualities.max { Self.overlap($0.0, face.boundingBox) < Self.overlap($1.0, face.boundingBox) }?.1 ?? 0
            guard score >= minimumQuality, abs(face.yaw?.doubleValue ?? 0) <= maximumYaw, let points = face.landmarks.flatMap({ Self.dlibPoints($0, width: width, height: height) })
            else { return nil }
            let box = face.boundingBox
            return DetectedFace(
                box: CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height),
                landmarks: points,
                quality: score
            )
        }
    }

    /// 두 상자가 겹치는 정도(IoU).
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }

    /// 시뮬레이터에는 Neural Engine·GPU 추론 환경이 없어 CPU로 돌린다. 기기에서는 Vision이 고른다.
    /// 시뮬레이터 CPU 경로의 랜드마크는 크게 틀리므로(눈·코가 얼굴 가운데로 몰린다) 정확도는 기기에서만 잰다.
    private static func prepare(_ request: VNRequest) {
        #if targetEnvironment(simulator)
        if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
            for stage in (try? request.supportedComputeStageDevices.keys).map(Array.init) ?? [] {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
    }

    /// Vision 랜드마크에서 dlib 5점에 해당하는 점을 뽑는다.
    static func dlibPoints(_ landmarks: VNFaceLandmarks2D, width: CGFloat, height: CGFloat) -> [CGPoint]? {
        let size = CGSize(width: width, height: height)
        // Vision 좌표는 왼쪽 아래가 원점이라 뒤집는다.
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint]? {
            guard let region, region.pointCount > 0 else { return nil }
            return region.pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: height - $0.y) }
        }
        guard let eyeA = points(landmarks.leftEye), let eyeB = points(landmarks.rightEye),
              let nose = points(landmarks.nose)
        else { return nil }
        return dlibPoints(eyeA: eyeA, eyeB: eyeB, nose: nose)
    }

    /// 두 눈 윤곽과 코 윤곽에서 dlib 5점을 고른다. Vision이 어느 눈을 left/right라 부르는지에 기대지 않고
    /// 이미지 위치로 정한다.
    static func dlibPoints(eyeA: [CGPoint], eyeB: [CGPoint], nose: [CGPoint]) -> [CGPoint]? {
        guard !eyeA.isEmpty, !eyeB.isEmpty, !nose.isEmpty else { return nil }
        let centerA = mean(eyeA), centerB = mean(eyeB)
        // dlib 0·1은 이미지 오른쪽 눈, 2·3은 왼쪽 눈.
        let (right, rightCenter, left, leftCenter) = centerA.x > centerB.x
            ? (eyeA, centerA, eyeB, centerB) : (eyeB, centerB, eyeA, centerA)
        // 눈꼬리: 두 눈을 잇는 선 위로 가장 바깥·안쪽 점.
        let axis = unit(CGPoint(x: rightCenter.x - leftCenter.x, y: rightCenter.y - leftCenter.y))
        func along(_ p: CGPoint) -> CGFloat { p.x * axis.x + p.y * axis.y }
        guard let rightOuter = right.max(by: { along($0) < along($1) }),
              let rightInner = right.min(by: { along($0) < along($1) }),
              let leftOuter = left.min(by: { along($0) < along($1) }),
              let leftInner = left.max(by: { along($0) < along($1) })
        else { return nil }
        // 코 밑: 눈선에 수직인 아래 방향으로 가장 낮은 점들 가운데 얼굴 가운데선에 가장 가까운 점.
        let down = CGPoint(x: -axis.y, y: axis.x)
        let middle = CGPoint(x: (rightCenter.x + leftCenter.x) / 2, y: (rightCenter.y + leftCenter.y) / 2)
        func depth(_ p: CGPoint) -> CGFloat { (p.x - middle.x) * down.x + (p.y - middle.y) * down.y }
        func side(_ p: CGPoint) -> CGFloat { abs((p.x - middle.x) * axis.x + (p.y - middle.y) * axis.y) }
        let lowest = nose.sorted { depth($0) > depth($1) }.prefix(3)
        guard let noseBottom = lowest.min(by: { side($0) < side($1) }) else { return nil }
        return [rightOuter, rightInner, leftOuter, leftInner, noseBottom]
    }

    private static func mean(_ points: [CGPoint]) -> CGPoint {
        let n = CGFloat(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }

    private static func unit(_ p: CGPoint) -> CGPoint {
        let length = max(hypot(p.x, p.y), .ulpOfOne)
        return CGPoint(x: p.x / length, y: p.y / length)
    }
}
