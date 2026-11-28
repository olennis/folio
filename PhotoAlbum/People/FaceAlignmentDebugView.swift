#if DEBUG
import ImageIO
import Photos
import SwiftUI

/// 정렬 디버그 화면(DEBUG 빌드 전용). 정렬 품질이 정확도를 좌우하므로 dlib 결과와 나란히 본다.
///
/// - dlib 샘플: dlib이 만든 칩 | 같은 dlib 5점으로 우리가 만든 칩 | Vision 5점으로 우리가 만든 칩.
///   아래에 각 칩의 임베딩이 dlib 임베딩과 얼마나 떨어졌는지(0.6 미만이면 같은 사람)와 Vision 점 오차를 적는다.
/// - 내 사진: 최근 사진에서 찾은 얼굴과 5점, 정렬한 칩 위에 dlib 기준 자리(빨강)와 실제 점(초록)을 겹쳐 본다.
///   두 색이 거의 겹쳐야 정렬이 맞다.
struct FaceAlignmentDebugView: View {
    private enum Source: String, CaseIterable { case dlib = "dlib 샘플", library = "내 사진" }
    @State private var source = Source.dlib
    @State private var rows: [Row] = []
    @State private var status = ""

    struct Row: Identifiable {
        let id = UUID()
        let title: String
        let images: [(label: String, image: CGImage?)]
        let points: [CGPoint]?
        let detail: String
    }

    var body: some View {
        List {
            Picker("보기", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title).font(.footnote.weight(.semibold))
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(Array(row.images.enumerated()), id: \.offset) { index, item in
                            VStack(spacing: 2) {
                                chip(item.image, points: index == row.images.count - 1 ? row.points : nil)
                                Text(item.label).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(row.detail).font(.caption.monospacedDigit())
                }
            }
        }
        .navigationTitle("얼굴 정렬 디버그")
        .task(id: source) { await load() }
    }

    private func chip(_ image: CGImage?, points: [CGPoint]?) -> some View {
        ZStack {
            if let image { Image(decorative: image, scale: 1).resizable().interpolation(.none) } else { Color.gray }
            if let points {
                // 빨강: dlib 기준 자리, 초록: 실제 랜드마크를 칩 좌표로 옮긴 자리.
                Canvas { context, size in
                    let k = size.width / CGFloat(FaceGeometry.chipSize)
                    for p in FaceGeometry.chipPoints() {
                        context.fill(Path(ellipseIn: CGRect(x: p.x * k - 3, y: p.y * k - 3, width: 6, height: 6)), with: .color(.red))
                    }
                    for p in points {
                        context.stroke(Path(ellipseIn: CGRect(x: p.x * k - 4, y: p.y * k - 4, width: 8, height: 8)), with: .color(.green), lineWidth: 1.5)
                    }
                }
            }
        }
        .frame(width: 100, height: 100)
    }

    private func load() async {
        rows = []
        status = "불러오는 중…"
        let source = source
        let result = await Task.detached(priority: .userInitiated) { () -> ([Row], String) in
            switch source {
            case .dlib: return Self.dlibRows()
            case .library: return Self.libraryRows()
            }
        }.value
        rows = result.0
        status = result.1
    }

    // MARK: dlib 샘플

    private struct Sample: Decodable {
        let image: String
        let chip: String
        let points: [[Double]]
        let embedding: [Float]
    }

    nonisolated private static func bundleImage(_ name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: "dlib-sample-" + (name as NSString).deletingPathExtension, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    nonisolated private static func dlibRows() -> ([Row], String) {
        guard let url = Bundle.main.url(forResource: "dlib-sample-faces", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([Sample].self, from: data),
              let embedder = try? CoreMLFaceEmbedder()
        else { return ([], "dlib 샘플이나 모델을 불러오지 못했습니다") }
        let aligner = DlibFaceAligner()
        let detector = VisionFaceDetector(minimumQuality: 0, minimumSide: 0)
        var rows: [Row] = []
        var cache: [String: (RGBImage, [DetectedFace])] = [:]
        for sample in samples {
            guard let cg = bundleImage(sample.image), let rgb = RGBImage(cg) else { continue }
            if cache[sample.image] == nil { cache[sample.image] = (rgb, (try? detector.detect(in: cg)) ?? []) }
            let found = cache[sample.image]!.1
            let target = sample.points.map { CGPoint(x: $0[0], y: $0[1]) }
            let ours = aligner.chip(from: rgb, landmarks: target)
            let eyes = hypot(target[0].x - target[2].x, target[0].y - target[2].y)
            let vision = found.min { hypot($0.landmarks[4].x - target[4].x, $0.landmarks[4].y - target[4].y) < hypot($1.landmarks[4].x - target[4].x, $1.landmarks[4].y - target[4].y) }
            let visionChip = vision.flatMap { aligner.chip(from: rgb, landmarks: $0.landmarks) }
            var distances: [String] = []
            for (label, chip) in [("dlib점", ours), ("Vision점", visionChip)] {
                if let chip, let v = try? embedder.embeddings(for: [chip]).first {
                    distances.append(String(format: "%@ %.3f", label, FaceVector.distance(v, sample.embedding)))
                }
            }
            var error = ""
            if let vision {
                let e = zip(vision.landmarks, target).map { hypot($0.x - $1.x, $0.y - $1.y) }.reduce(0, +) / 5 / eyes
                error = String(format: " · Vision 점 오차 %.3f", e)
            }
            let points = vision.flatMap { v in FaceGeometry.chip(for: v.landmarks).map { chipPoints(v.landmarks, chip: $0) } }
            rows.append(Row(
                title: sample.chip,
                images: [("dlib", bundleImage(sample.chip)), ("우리·dlib점", ours?.cgImage()), ("우리·Vision점", visionChip?.cgImage())],
                points: points,
                detail: "dlib 임베딩과 거리: " + distances.joined(separator: ", ") + error
            ))
        }
        return (rows, "거리 0.6 미만이면 같은 사람. Vision 점 오차는 두 눈 바깥 거리에 대한 평균 오차")
    }

    /// 이미지 위 점을 칩 좌표로 옮긴다(칩 변환의 역).
    nonisolated private static func chipPoints(_ points: [CGPoint], chip: FaceGeometry.Chip) -> [CGPoint] {
        let t = chip.transform
        let det = t.a * t.d - t.b * t.c
        return points.map { p in
            let x = p.x - t.tx, y = p.y - t.ty
            return CGPoint(x: (t.d * x - t.b * y) / det, y: (-t.c * x + t.a * y) / det)
        }
    }

    // MARK: 내 사진

    nonisolated private static func libraryRows() -> ([Row], String) {
        let source = PhotoKitFaceSource()
        let detector = VisionFaceDetector()
        let aligner = DlibFaceAligner()
        var rows: [Row] = []
        var looked = 0
        for id in source.assetIDs().prefix(80) {
            guard rows.count < 12, let image = source.image(for: id, allowNetwork: false) else { continue }
            looked += 1
            guard let faces = try? detector.detect(in: image), !faces.isEmpty, let rgb = RGBImage(image) else { continue }
            for face in faces.prefix(2) {
                guard let geometry = FaceGeometry.chip(for: face.landmarks),
                      let chip = aligner.chip(from: rgb, landmarks: face.landmarks) else { continue }
                let crop = image.cropping(to: face.box.insetBy(dx: -face.box.width * 0.2, dy: -face.box.height * 0.2))
                rows.append(Row(
                    title: String(id.prefix(8)),
                    images: [("얼굴", crop), ("정렬", chip.cgImage())],
                    points: chipPoints(face.landmarks, chip: geometry),
                    detail: String(format: "품질 %.2f · 얼굴 %.0fpx · 배율 %.2f", face.quality, min(face.box.width, face.box.height), geometry.scale)
                ))
            }
        }
        return (rows, "최근 사진 \(looked)장에서 얼굴 \(rows.count)개. 빨강은 dlib 기준 자리, 초록은 실제 점")
    }
}
#endif
