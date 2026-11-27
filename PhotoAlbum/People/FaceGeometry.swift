import CoreGraphics
import Foundation

/// dlib `get_face_chip(size: 150, padding: 0.25)`와 같은 얼굴 정렬 식.
///
/// tools/model-conversion/README.md의 "얼굴 정렬" 절을 그대로 옮겼다. 식을 바꾸면 dlib 칩과 비교하는
/// `FaceAlignerTests`가 깨진다.
enum FaceGeometry {
    static let chipSize = 150
    static let padding = 0.25

    /// dlib 5점 랜드마크 모델의 평균 얼굴(0~1). 순서: 0 이미지 오른쪽 눈 바깥, 1 같은 눈 안쪽,
    /// 2 이미지 왼쪽 눈 바깥, 3 같은 눈 안쪽, 4 코 밑. dlib `interpolation.h`의 값이다.
    static let template: [CGPoint] = [
        CGPoint(x: 0.8595674595992, y: 0.2134981538014),
        CGPoint(x: 0.6460604764104, y: 0.2289674387677),
        CGPoint(x: 0.1205750620789, y: 0.2137274526848),
        CGPoint(x: 0.3340850613712, y: 0.2290642403242),
        CGPoint(x: 0.4901123135679, y: 0.6277975316475),
    ]

    /// 칩 좌표의 기준점.
    static func chipPoints(size: Int = chipSize, padding: Double = padding) -> [CGPoint] {
        template.map {
            CGPoint(
                x: (padding + $0.x) / (2 * padding + 1) * Double(size),
                y: (padding + $0.y) / (2 * padding + 1) * Double(size)
            )
        }
    }

    /// 2x3 아핀 변환. 칩의 (x, y)가 이미지의 `(a*x + b*y + tx, c*x + d*y + ty)`로 간다.
    struct Affine: Equatable {
        var a, b, c, d, tx, ty: Double

        func apply(_ p: CGPoint) -> CGPoint {
            CGPoint(x: a * p.x + b * p.y + tx, y: c * p.x + d * p.y + ty)
        }
    }

    /// 칩을 뽑는 데 필요한 것: 칩 → 이미지 변환과 배율. 배율이 2보다 크면 dlib은 먼저 이미지를 줄인다.
    struct Chip: Equatable {
        let transform: Affine
        let angle: Double
        let scale: Double
    }

    /// 이미지 위 5점으로 칩 변환을 구한다. dlib `get_face_chip_details` + `extract_image_chip`과 같다.
    static func chip(for landmarks: [CGPoint], size: Int = chipSize, padding: Double = padding) -> Chip? {
        guard landmarks.count == 5 else { return nil }
        guard let m = similarity(from: chipPoints(size: size, padding: padding), to: landmarks) else { return nil }
        // chip_details: 변환에서 각도와 배율만 꺼낸다.
        let angle = atan2(m.c, m.a)
        let scale = hypot(m.a, m.c)
        let center = m.apply(CGPoint(x: Double(size) / 2, y: Double(size) / 2))
        // centered_drect는 폭에서 1을 빼고 잡는다.
        let half = (Double(size) * scale - 1) / 2
        let cosA = cos(angle), sinA = sin(angle)
        func corner(_ dx: Double, _ dy: Double) -> CGPoint {
            CGPoint(x: center.x + cosA * dx - sinA * dy, y: center.y + sinA * dx + cosA * dy)
        }
        // extract_image_chip: 칩의 (0,0), (n,0), (0,n)을 회전한 사각형 모서리에 맞춘다.
        let tl = corner(-half, -half), tr = corner(half, -half), bl = corner(-half, half)
        let n = Double(size - 1)
        let transform = Affine(
            a: (tr.x - tl.x) / n, b: (bl.x - tl.x) / n,
            c: (tr.y - tl.y) / n, d: (bl.y - tl.y) / n,
            tx: tl.x, ty: tl.y
        )
        return Chip(transform: transform, angle: angle, scale: scale)
    }

    /// `from`을 `to`에 맞추는 유사 변환(회전·배율·이동). 최소제곱(Umeyama), dlib `find_similarity_transform`과 같다.
    static func similarity(from: [CGPoint], to: [CGPoint]) -> Affine? {
        let n = Double(from.count)
        guard from.count == to.count, from.count >= 2 else { return nil }
        let meanF = CGPoint(x: from.map(\.x).reduce(0, +) / n, y: from.map(\.y).reduce(0, +) / n)
        let meanT = CGPoint(x: to.map(\.x).reduce(0, +) / n, y: to.map(\.y).reduce(0, +) / n)
        var sigma = 0.0
        // cov = Σ (t - meanT)(f - meanF)ᵀ / n
        var c00 = 0.0, c01 = 0.0, c10 = 0.0, c11 = 0.0
        for (f, t) in zip(from, to) {
            let fx = f.x - meanF.x, fy = f.y - meanF.y
            let tx = t.x - meanT.x, ty = t.y - meanT.y
            sigma += fx * fx + fy * fy
            c00 += tx * fx; c01 += tx * fy
            c10 += ty * fx; c11 += ty * fy
        }
        sigma /= n
        c00 /= n; c01 /= n; c10 /= n; c11 /= n
        guard sigma > 0 else { return nil }
        // 2x2 유사 변환의 닫힌 해: 회전은 cov의 "회전 부분", 배율은 그 크기 / sigma.
        // cov = [[p, -q], [q, p]] + (반사 부분) 꼴에서 회전 부분 (p, q)를 꺼낸다.
        let p = (c00 + c11) / 2
        let q = (c10 - c01) / 2
        let r = hypot(p, q)
        guard r > 0 else { return nil }
        // 반사 부분까지 포함한 특이값 합 = det 부호에 따라 다르다. 얼굴 정렬은 반사가 없으므로
        // Umeyama의 c = trace(D·S) / sigma 는 (s1 + s2 * sign(det)) / sigma 이고, 2x2에서 이는 2r / sigma 다.
        let scale = 2 * r / sigma
        let cosA = p / r, sinA = q / r
        let a = scale * cosA, b = -scale * sinA, c = scale * sinA, d = scale * cosA
        return Affine(
            a: a, b: b, c: c, d: d,
            tx: meanT.x - (a * meanF.x + b * meanF.y),
            ty: meanT.y - (c * meanF.x + d * meanF.y)
        )
    }
}
